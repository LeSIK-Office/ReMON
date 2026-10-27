import Darwin
import Foundation

// 디스크 지도 조사기(10-25 대표 요청: "구조도 들어가서 보고, 필요 없는 건 아예 정리"). DiskTreeSource 계약의 실제 구현.
// - 크기: 병렬 getattrlistbulk(DiskTreeWalker) — 실제 할당량, 링크는 따라가지 않음, 다른 볼륨은 세지 않음, 시간 제한에 걸리면 partial(하한값).
// - 번들(.app·.framework·.photoslibrary·.xcodeproj …)은 통째로 한 칸(펼치지 않음 · 크기는 안까지 센다).
// - 캐시: 폴더마다 (그 폴더의 수정 시각, 잰 시각)으로 10분. 조사 때 바로 아래 폴더의 하위 폴더 크기까지 적어 두어, 펼치기는 형제를 다시 재지 않고
//   대개 조사 없이 끝난다(폴더 수정 시각은 바로 아래 항목이 바뀔 때만 바뀐다 — 깊은 곳의 변화는 10분 안에 놓칠 수 있다).
// - 태그·설명·조치는 DiskTreeRules(이미 있는 카탈로그·정책·보호 목록), 정리는 DiskTreeActions.
// - 다른 앱의 보관함(~/Library/Containers · Group Containers)은 전체 디스크 접근이 없으면 조사 때 들어가지 않는다(macOS 확인 창 방지) — 펼치면 잰다.
// 모두 읽기 전용이다. 메인 스레드 밖에서 부른다.

public final class DiskTreeScanner: DiskTreeSource, @unchecked Sendable {
    /// 마지막 호출 기록(걸린 시간 · 센 폴더·파일 수 · 끝까지 셌는지 · 캐시로 채운 칸 수).
    public struct Report: Sendable, Equatable {
        public var elapsed: TimeInterval = 0
        public var directories = 0
        public var files = 0
        public var complete = true
        public var cacheHits = 0
        public var measured = 0

        public init() {}
    }

    public let home: String
    public var cacheTTL: TimeInterval = 600
    public var parallelism = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    /// 이 크기 이상 파일·번들에 '큰 파일' 태그(기본 500MB)
    public var largeFileThreshold: UInt64 = 500 * 1_048_576
    /// largeFiles가 돌려줄 최대 개수
    public var largeFileLimit = 50
    public var tempAgeDays: Double = 7
    public var downloadAgeDays: Double = 30
    public var downloadMinimumBytes: UInt64 = 50 * 1_048_576
    public var simulatorIdleDays: Double = 90
    /// 다른 앱 보관함 안을 조사 때 잴지. nil = 전체 디스크 접근이 있을 때만(확인 창이 뜨지 않음).
    public var measuresOtherAppData: Bool?
    /// 사용자 임시 폴더(…/T)·캐시 폴더(…/C) — 정식 경로. 시험은 가짜 폴더로 바꾼다.
    public var temporaryFolders: [String]
    public var cacheFolders: [String]
    public var trashFolder: String
    public var downloadsFolder: String
    public var vmFolder = "/System/Volumes/VM"
    public var sleepImageFolder = "/private/var/vm"
    /// 설치된 앱을 찾는 폴더 — 설치된 앱의 데이터는 보기만, 찾지 못한 앱의 데이터(지운 앱의 찌꺼기)만 휴지통으로.
    public var applicationFolders: [String]
    public var catalog: [CatalogEntry] = DiskCatalog.entries
    public var runningProbe: @Sendable () -> RunningApps = { RunningApps.recent() }
    /// 작업 중인 폴더(B 등급 산출물을 쉬는 것으로 보지 않는다). 기본: 사용자 프로세스의 작업 폴더(홈·홈 최상위 폴더 자체는 뺀다).
    public var activeDirectoriesProbe: @Sendable () -> Set<String>
    /// 열린 파일 확인에 쓰는 사용자 프로세스
    public var userPIDsProbe: @Sendable () -> [Int32] = { ProcessPresence.sameUserPIDs() }
    /// 실행 중인 실행 파일(AI 앱 캐시 · 이전 CLI 버전 판정)
    public var executablesProbe: @Sendable () -> [RunningExecutable] = { RunningExecutable.collect(ProcessSampler().sample()) }
    /// docker · brew · tmutil 실행기(nil = 실제 실행). 시험은 정해진 출력을 돌려준다.
    public var commandRunner: CommandRunner?
    /// 부산물(워크트리·브랜치) 조사
    public var devRoot: String
    public var leftoverTools: LeftoverTools = .live
    public var leftoverOptions: LeftoverScanOptions
    public var sessionsProvider: @Sendable () -> [AgentSession] = { [] }

    private let lock = NSLock()
    private var sizes: [String: CachedSize] = [:]
    private var git: (at: Date, projects: [ProjectLeftovers])?
    private var brew: (at: Date, preview: HomebrewPreview)?
    private var generation = 0
    private var report = Report()

    struct CachedSize {
        var bytes: UInt64
        var files: Int
        var newest: Int
        var dirMtime: Int
        var at: Date
        var unreadable: Int
        var otherAppData: Bool
        var otherVolume: Bool
    }

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        self.home = home
        trashFolder = home + "/.Trash"
        downloadsFolder = home + "/Downloads"
        devRoot = home + "/DEV"
        applicationFolders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", home + "/Applications"]
        let folders = Self.userTemporaryFolders()
        temporaryFolders = folders.temporary
        cacheFolders = folders.caches
        var options = LeftoverScanOptions()
        options.codexWorktreesRoot = home + "/.codex/worktrees"
        leftoverOptions = options
        activeDirectoriesProbe = { Self.liveActiveDirectories(home: home) }
    }

    public var lastReport: Report { lock.lock(); defer { lock.unlock() }; return report }

    /// 진행 중인 조사를 멈춘다(그때까지 센 값은 partial로 돌아온다).
    public func cancel() { lock.lock(); generation += 1; lock.unlock() }

    // MARK: - 계약

    public func scan(roots: [String], budget: TimeInterval) -> [DiskNode] {
        let started = Date()
        let context = makeContext()
        var levels: [Level] = []
        var leaves: [Int: DiskNode] = [:]
        for (index, root) in roots.enumerated() {
            if let level = buildLevel(root, context: context) { levels.append(level) } else if let leaf = leafNode(root, budget: budget, context: context) { leaves[index] = leaf }
        }
        let measured = measure(&levels, budget: budget)
        var result: [DiskNode] = []
        var levelIndex = 0
        for (index, root) in roots.enumerated() {
            if let leaf = leaves[index] { result.append(leaf); continue }
            guard levelIndex < levels.count, levels[levelIndex].path == root else { continue }
            result.append(finishLevel(levels[levelIndex], as: nil, context: context))
            levelIndex += 1
        }
        record(started: started, measured)
        return result
    }

    public func expand(_ node: DiskNode, budget: TimeInterval) -> DiskNode {
        guard !node.isVirtual else { var same = node; if same.children == nil { same.children = [] }; return same }
        let started = Date()
        let context = makeContext()
        guard node.isDirectory, var level = buildLevel(node.path, context: context) else {
            var same = node
            if same.children == nil { same.children = [] }
            return same
        }
        var levels = [level]
        let measured = measure(&levels, budget: budget)
        level = levels[0]
        let expanded = finishLevel(level, as: node, context: context)
        record(started: started, measured)
        return expanded
    }

    public func largeFiles(under roots: [String], minimumBytes: UInt64, budget: TimeInterval) -> [DiskNode] {
        let started = Date()
        let context = makeContext()
        let walker = makeWalker()
        walker.collectBundles = true
        walker.largeThreshold = max(1, minimumBytes)
        walker.largeLimit = largeFileLimit
        var targets: [DiskTreeWalker.Target] = []
        var found: [DiskTreeWalker.LargeFile] = []
        for root in roots {
            var info = stat()
            guard lstat(root, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                targets.append(DiskTreeWalker.Target(path: root, split: false, device: info.st_dev))
            case S_IFREG where UInt64(info.st_blocks) * 512 >= minimumBytes:
                found.append(DiskTreeWalker.LargeFile(path: root, bytes: UInt64(info.st_blocks) * 512, modified: Int(info.st_mtimespec.tv_sec), isBundle: false))
            default:
                continue
            }
        }
        let result = walker.run(targets, deadline: .now() + budget)
        found += result.large
        var seen = Set<String>()
        let nodes = found.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }.filter { seen.insert($0.path).inserted }.prefix(largeFileLimit).map { file -> DiskNode in
            var node = DiskNode(path: file.path, bytes: file.bytes, fileCount: 1, isDirectory: false, modified: Date(timeIntervalSince1970: TimeInterval(file.modified)), children: [])
            DiskTreeRules.classify(&node, isBundle: file.isBundle, isLink: false, newest: node.modified, context: context)
            node.tags.insert(.large)
            if let kind = LargeFileKind.kind(for: node.name), !(node.hint ?? "").contains(kind.label) { node.hint = (node.hint ?? "") + " · \(kind.label)" }
            // 큰 파일 목록의 기본 조치는 보기 — 사용자 파일(다운로드 포함)만 휴지통으로.
            let trashable = node.actions.contains(.trash) && !node.tags.isDisjoint(with: [.userFile, .download])
            node.actions = trashable ? [.reveal, .trash] : (node.actions == [.none] ? [.none] : [.reveal])
            return node
        }
        var measured = MeasureStats()
        measured.directories = result.directories
        measured.files = result.files
        measured.complete = !result.timedOut
        measured.walked = targets.count
        record(started: started, measured)
        return Array(nodes)
    }

    public func invalidate(_ path: String) {
        lock.lock(); defer { lock.unlock() }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        sizes = sizes.filter { key, _ in key != path && !key.hasPrefix(prefix) }
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            sizes.removeValue(forKey: parent)
            parent = (parent as NSString).deletingLastPathComponent
        }
    }

    // MARK: - 경로 하나

    /// 경로 하나를 판정한다(정리 직전 다시 확인용). 폴더는 캐시(10분)의 크기·가장 최근 수정 시각을 쓰고, 없으면 그 폴더만 짧게(최대 budget초) 잰다 —
    /// 끝까지 못 세면 '최근에 바뀜'으로 본다(보수적: 영구 삭제·임시 파일 정리를 막는 쪽).
    public func describe(_ path: String, budget: TimeInterval = 5) -> DiskNode? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind = info.st_mode & S_IFMT
        let isLink = kind == S_IFLNK
        let isFolder = kind == S_IFDIR
        let isBundle = isFolder && DiskTreeRules.bundleExtensions.contains(DiskTreeWalker.pathExtension((path as NSString).lastPathComponent))
        let mtime = Int(info.st_mtimespec.tv_sec)
        let modified = Date(timeIntervalSince1970: TimeInterval(mtime))
        var node = DiskNode(path: path, bytes: UInt64(info.st_blocks) * 512, fileCount: kind == S_IFREG ? 1 : 0, isDirectory: isFolder && !isBundle, modified: modified,
                            children: isFolder && !isBundle ? nil : [])
        var newest = modified
        if isFolder {
            if let cached = cachedSize(path, mtime: mtime, opaque: currentOpaque()) {
                node.bytes = cached.bytes
                node.fileCount = cached.files
                node.partial = cached.unreadable > 0 || cached.otherAppData
                newest = Date(timeIntervalSince1970: TimeInterval(max(mtime, cached.newest)))
            } else {
                let walker = makeWalker()
                let result = walker.run([DiskTreeWalker.Target(path: path, split: false, device: info.st_dev)], deadline: .now() + max(0, budget))
                if let tally = result.tallies.first, !tally.timedOut {
                    node.bytes = tally.bytes
                    node.fileCount = tally.files
                    node.partial = tally.partial
                    newest = Date(timeIntervalSince1970: TimeInterval(max(mtime, tally.newest)))
                    store(result.tallies, opaque: walker.opaque)
                } else {
                    node.partial = true
                    newest = Date()
                }
            }
        }
        DiskTreeRules.classify(&node, isBundle: isBundle, isLink: isLink, newest: newest, context: makeContext())
        return node
    }

    // MARK: - 부산물 · 미리보기 · 정리 환경

    /// git 워크트리·브랜치 부산물을 조사해 둔다(디스크 지도의 워크트리 판정 · git 묶음). 읽기 전용 — LeftoverScanner와 같은 규칙.
    @discardableResult
    public func refreshGit(budget: TimeInterval = 20) -> [ProjectLeftovers] {
        var options = leftoverOptions
        options.repoBudget = min(options.repoBudget, max(2, budget))
        options.bytesTimeTotal = min(options.bytesTimeTotal, max(1, budget / 3))
        let report = LeftoverScanner.report(devRoot: devRoot, sessions: sessionsProvider(), orcaTerminals: nil, orcaWorktrees: nil, tools: leftoverTools, options: options)
        setLeftovers(report.projects)
        return report.projects
    }

    /// 다른 화면이 이미 조사한 부산물을 넣는다(시험·방 화면 재사용).
    public func setLeftovers(_ projects: [ProjectLeftovers]) {
        lock.lock(); git = (Date(), projects); lock.unlock()
    }

    public var leftovers: [ProjectLeftovers] {
        lock.lock(); defer { lock.unlock() }
        guard let git, Date().timeIntervalSince(git.at) < cacheTTL else { return [] }
        return git.projects
    }

    /// brew cleanup -n --prune=all 미리보기(10분 캐시). 네트워크는 차단하고 로컬 캐시 갱신 가능성은 표시한다.
    public func homebrewPreview(timeout: TimeInterval = 60) -> HomebrewPreview {
        lock.lock()
        if let brew, Date().timeIntervalSince(brew.at) < cacheTTL { lock.unlock(); return brew.preview }
        lock.unlock()
        var command = ToolCommands.brewCleanupAll
        command.timeout = timeout
        let result = ToolCommands.run(command, preview: true, home: home, runner: commandRunner)
        var preview: HomebrewPreview
        if result.status == 127 {
            preview = HomebrewPreview(error: "Homebrew가 없습니다")
        } else if !result.succeeded {
            let why = result.timedOut ? "시간 초과" : String((result.stderr.isEmpty ? result.stdout : result.stderr).trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
            preview = HomebrewPreview(error: "미리보기 실패: " + why)
        } else {
            preview = HomebrewPreview.parse(result.stdout + "\n" + result.stderr)
        }
        lock.lock(); brew = (Date(), preview); lock.unlock()
        return preview
    }

    /// Docker: CLI가 있고 엔진이 3초 안에 답하면 docker system df(읽기 전용).
    public func dockerUsage(timeout: TimeInterval = 3) -> (cli: String?, running: Bool, usage: [DockerUsage], note: String?) {
        guard let cli = ToolCommands.locate("docker", home: home) else { return (nil, false, [], "docker 명령이 없습니다") }
        let run = commandRunner ?? ToolCommands.defaultRunner(toolPath: cli)
        let version = run(cli, ["version", "--format", "{{.Server.Version}}"], timeout)
        guard version.succeeded, !version.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (cli, false, [], "Docker 엔진이 꺼져 있습니다(이미지·빌드 캐시 크기는 엔진을 켜면 보입니다)")
        }
        let df = run(cli, ["system", "df", "--format", "{{json .}}"], 20)
        guard df.succeeded else { return (cli, true, [], "docker system df 실패: " + String(df.stderr.prefix(160))) }
        return (cli, true, SystemData.parseDockerDF(df.stdout), nil)
    }

    /// DiskTreeActions에 넘길 환경(부산물 조사 결과 · 다시 판정 · 실행기).
    public func actionEnvironment(audit: AuditLog = .shared) -> DiskTreeActions.Environment {
        var environment = DiskTreeActions.Environment(audit: audit)
        environment.home = home
        environment.runner = commandRunner
        environment.leftovers = leftovers
        environment.leftoverTools = leftoverTools
        environment.leftoverOptions = leftoverOptions
        environment.sessions = sessionsProvider()
        environment.reclassify = { [weak self] path in self?.describe(path) }
        environment.afterChange = { [weak self] path in self?.invalidate(path) }
        return environment
    }

    // MARK: - 묶음 보기

    public func categories(budget: TimeInterval) -> [DiskNode] {
        let started = Date()
        let deadline = Date().addingTimeInterval(budget)
        // 부산물은 워크트리 판정에도 쓰이므로 먼저(남은 시간의 1/3까지).
        if leftovers.isEmpty, FileManager.default.fileExists(atPath: devRoot) { refreshGit(budget: max(2, budget / 3)) }
        let context = makeContext()
        var groups: [(id: String, tag: DiskTag, title: String, hint: String, children: [String], extra: [DiskNode])] = []

        // 스왑 · 잠자기 이미지
        let swapFiles = Self.swapFiles(vmFolder) + [sleepImageFolder + "/sleepimage"].filter { FileManager.default.fileExists(atPath: $0) }
        groups.append(("swap", .swap, "스왑·잠자기 이미지", DiskTreeRules.swapSummary(context), swapFiles, []))
        // 로컬 스냅샷
        let snapshots = SystemData.snapshots(runner: commandRunner)
        let purgeable = SystemData.volume("/").purgeable
        let snapshotNodes = (snapshots.names ?? []).map { name -> DiskNode in
            DiskNode(path: DiskNodeVirtual.path("snapshot", name), name: Self.snapshotLabel(name), bytes: 0, fileCount: 0, isDirectory: false, children: [], tags: [.snapshot],
                     hint: "로컬 스냅샷 — 크기는 macOS가 알려 주지 않습니다(정리 가능 공간에 들어 있음). 줄이려면 터미널에서 "
                        + "'tmutil thinlocalsnapshots / 50000000000 4'(공간이 모자라면 macOS가 스스로 지웁니다)", actions: [.none])
        }
        let snapshotHint = snapshots.names == nil ? (snapshots.note ?? "스냅샷 목록을 읽지 못했습니다")
            : (snapshotNodes.isEmpty ? "로컬 스냅샷 없음" : "로컬 스냅샷 \(snapshotNodes.count)개") + " · 정리 가능 공간(purgeable) \(Fmt.size(purgeable))"
        groups.append(("snapshot", .snapshot, "로컬 스냅샷", snapshotHint, [], snapshotNodes))
        // 휴지통
        let trashItems = Self.children(trashFolder).filter { ($0 as NSString).lastPathComponent != ".DS_Store" }
        let trashReadable = access(trashFolder, R_OK | X_OK) == 0 && (try? FileManager.default.contentsOfDirectory(atPath: trashFolder)) != nil
        groups.append(("trash", .trash, "휴지통", trashReadable ? "휴지통 \(trashItems.count)개 — 비우기는 Finder에서 직접 합니다(ReMON은 휴지통을 비우지 않습니다)"
                       : "권한이 없어 휴지통을 볼 수 없습니다(전체 디스크 접근 권한이 필요합니다)", trashItems, []))
        // 임시 파일(오래된 것만 — 판정이 남는 것: 휴지통·영구 삭제 가능 또는 열린 파일 때문에 남긴 것)
        var temporary: [String] = []
        for folder in temporaryFolders + cacheFolders {
            for path in Self.children(folder) where !(path as NSString).lastPathComponent.hasPrefix("com.apple.") {
                if let modified = DiskScanner.modified(path), Date().timeIntervalSince(modified) > tempAgeDays * 86_400 { temporary.append(path) }
            }
        }
        groups.append(("temp", .temp, "임시 파일", "\(Int(tempAgeDays))일 넘게 쓰이지 않은 임시 파일·캐시(macOS 서비스 몫 제외)", temporary, []))
        // Xcode
        var xcode: [String] = []
        for relative in ["Library/Developer/Xcode/DerivedData", "Library/Developer/Xcode/Archives", "Library/Developer/CoreSimulator/Caches",
                         "Library/Developer/Xcode/DocumentationCache", "Library/Developer/Xcode/DeviceLogs", "Library/Developer/Xcode/iOS Device Logs"] {
            if FileManager.default.fileExists(atPath: home + "/" + relative) { xcode.append(home + "/" + relative) }
        }
        xcode += Self.children(home + "/Library/Developer/Xcode").filter { ($0 as NSString).lastPathComponent.hasSuffix("DeviceSupport") }
        let devices = Self.children(home + "/Library/Developer/CoreSimulator/Devices").filter { path in
            guard let device = SimulatorDevice.read(path), !device.booted else { return false }
            return Date().timeIntervalSince(device.lastBooted ?? device.created ?? Date()) >= simulatorIdleDays * 86_400
        }
        xcode += devices
        groups.append(("xcode", .xcode, "Xcode", "DerivedData · 아카이브 · DeviceSupport · 시뮬레이터 캐시 · \(Int(simulatorIdleDays))일 넘게 안 쓴 시뮬레이터 \(devices.count)대", xcode, []))
        // 기기 백업
        let backups = Self.children(home + "/Library/Application Support/MobileSync/Backup")
        groups.append(("backup", .backup, "기기 백업", backups.isEmpty ? "기기 백업 없음(또는 전체 디스크 접근 권한이 필요)" : "iPhone·iPad 백업 \(backups.count)개", backups, []))

        // 크기: 한 번에 잰다(캐시 먼저).
        var allPaths = groups.flatMap(\.children)
        let downloadNodes = oldDownloads(context: context, budget: max(1, deadline.timeIntervalSinceNow / 3))
        let measuredSizes = measurePaths(&allPaths, context: context, deadline: deadline)

        var result: [DiskNode] = []
        for group in groups {
            var children = group.children.compactMap { measuredSizes[$0] } + group.extra
            children.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
            if group.id == "temp" { children = children.filter { $0.actions != [.reveal] || ($0.hint ?? "").contains("열어 둔") } }
            result.append(categoryNode(group.id, tag: group.tag, title: group.title, hint: group.hint, children: children))
        }
        result.insert(categoryNode("download", tag: .download, title: "오래된 큰 다운로드",
                                   hint: "\(Int(downloadAgeDays))일 넘게 지난 \(Fmt.size(downloadMinimumBytes)) 이상 파일", children: downloadNodes), at: 4)
        result.insert(dockerCategory(context: context, sizes: measuredSizes), at: 5)
        result.insert(homebrewCategory(context: context, deadline: deadline), at: 7)
        result.append(gitCategory(context: context))
        var stats = MeasureStats()
        stats.walked = allPaths.count
        record(started: started, stats)
        return result
    }

    // MARK: - 내부: 한 단계

    /// 폴더 하나의 바로 아래(크기는 캐시에서 채우거나 조사 대상으로 남긴다).
    struct Level {
        var path: String
        var device: dev_t
        var mtime: Int
        var complete: Bool
        var children: [Child]
    }

    struct Child {
        var node: DiskNode
        var isBundle: Bool
        var isLink: Bool
        var newest: Int
        /// 조사 대상이면 그 결과가 들어갈 자리
        var pending: Bool
        var unreadable = 0
        var timedOut = false
        var otherAppData = false
        var otherVolume = false
    }

    struct MeasureStats {
        var directories = 0
        var files = 0
        var complete = true
        var cacheHits = 0
        var walked = 0
    }

    func buildLevel(_ path: String, context: DiskTreeContext) -> Level? {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        if DiskTreeRules.bundleExtensions.contains(DiskTreeWalker.pathExtension((path as NSString).lastPathComponent)) { return nil }
        guard let listing = DiskTreeWalker.list(path) else { return nil }
        let opaque = currentOpaque()
        var children: [Child] = []
        for entry in listing.entries {
            let childPath = path == "/" ? "/" + entry.name : path + "/" + entry.name
            let modified = Date(timeIntervalSince1970: TimeInterval(entry.modified))
            switch entry.type {
            case 2:
                let isBundle = DiskTreeRules.bundleExtensions.contains(DiskTreeWalker.pathExtension(entry.name))
                var child = Child(node: DiskNode(path: childPath, name: entry.name, isDirectory: !isBundle, modified: modified, children: isBundle ? [] : nil),
                                  isBundle: isBundle, isLink: false, newest: entry.modified, pending: true)
                if let cached = cachedSize(childPath, mtime: entry.modified, opaque: opaque) {
                    child.pending = false
                    child.node.bytes = cached.bytes
                    child.node.fileCount = cached.files
                    child.newest = max(entry.modified, cached.newest)
                    child.unreadable = cached.unreadable
                    child.otherAppData = cached.otherAppData
                    child.otherVolume = cached.otherVolume
                }
                children.append(child)
            case 1, 5:
                children.append(Child(node: DiskNode(path: childPath, name: entry.name, bytes: entry.alloc, fileCount: entry.type == 1 ? 1 : 0, isDirectory: false,
                                                     modified: modified, children: []), isBundle: false, isLink: entry.type == 5, newest: entry.modified, pending: false))
            default:
                continue
            }
        }
        var level = Level(path: path, device: listing.device, mtime: listing.mtime, complete: listing.complete, children: children)
        // /private/var/vm: 스왑 파일은 따로 볼륨(/System/Volumes/VM)에 있다 — 같은 칸 아래에 보여 준다.
        if path == sleepImageFolder {
            for swapPath in Self.swapFiles(vmFolder) where !level.children.contains(where: { $0.node.path == swapPath }) {
                var swapInfo = stat()
                guard lstat(swapPath, &swapInfo) == 0 else { continue }
                level.children.append(Child(node: DiskNode(path: swapPath, bytes: UInt64(swapInfo.st_blocks) * 512, fileCount: 1, isDirectory: false,
                                                           modified: Date(timeIntervalSince1970: TimeInterval(swapInfo.st_mtimespec.tv_sec)), children: []),
                                            isBundle: false, isLink: false, newest: Int(swapInfo.st_mtimespec.tv_sec), pending: false))
            }
        }
        return level
    }

    /// 뿌리가 폴더가 아닐 때(파일 · 링크 · 번들 · 없음).
    func leafNode(_ path: String, budget: TimeInterval, context: DiskTreeContext) -> DiskNode? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind = info.st_mode & S_IFMT
        let isBundle = kind == S_IFDIR
        var node = DiskNode(path: path, bytes: UInt64(info.st_blocks) * 512, fileCount: kind == S_IFREG ? 1 : 0, isDirectory: false,
                            modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)), children: [])
        var newest = Int(info.st_mtimespec.tv_sec)
        if isBundle {
            let walked = makeWalker().run([DiskTreeWalker.Target(path: path, split: false, device: info.st_dev)], deadline: .now() + max(0, budget))
            if let tally = walked.tallies.first {
                node.bytes = tally.bytes
                node.fileCount = tally.files
                node.partial = tally.partial
                newest = max(newest, tally.newest)
            }
        }
        DiskTreeRules.classify(&node, isBundle: isBundle, isLink: kind == S_IFLNK, newest: Date(timeIntervalSince1970: TimeInterval(newest)), context: context)
        return node
    }

    /// 조사 대상 폴더를 한 번에(여러 단계·뿌리 함께) 잰다. 캐시에 결과를 적는다.
    func measure(_ levels: inout [Level], budget: TimeInterval) -> MeasureStats {
        var stats = MeasureStats()
        var targets: [DiskTreeWalker.Target] = []
        var slots: [(level: Int, child: Int)] = []
        for (levelIndex, level) in levels.enumerated() {
            for (childIndex, child) in level.children.enumerated() {
                if child.pending {
                    targets.append(DiskTreeWalker.Target(path: child.node.path, split: !child.isBundle, device: level.device))
                    slots.append((levelIndex, childIndex))
                } else if child.node.isDirectory || child.isBundle {
                    stats.cacheHits += 1
                }
            }
        }
        stats.walked = targets.count
        guard !targets.isEmpty else { return stats }
        let walker = makeWalker()
        let result = walker.run(targets, deadline: .now() + max(0, budget))
        stats.directories = result.directories
        stats.files = result.files
        stats.complete = !result.timedOut
        for (index, slot) in slots.enumerated() {
            let tally = result.tallies[index]
            var child = levels[slot.level].children[slot.child]
            child.node.bytes = tally.bytes
            child.node.fileCount = tally.files
            child.newest = max(child.newest, tally.newest)
            child.unreadable = tally.unreadable
            child.timedOut = tally.timedOut
            child.otherAppData = tally.otherAppData
            child.otherVolume = tally.otherVolume
            child.pending = false
            levels[slot.level].children[slot.child] = child
        }
        store(result.tallies, opaque: walker.opaque)
        return stats
    }

    /// 한 단계를 칸으로 마무리한다: 자식 판정 · 정렬 · 합계. node가 있으면(펼치기) 그 칸을 고쳐 돌려준다.
    func finishLevel(_ level: Level, as original: DiskNode?, context: DiskTreeContext) -> DiskNode {
        var children: [DiskNode] = []
        var newest = level.mtime
        for child in level.children {
            var node = child.node
            node.partial = child.timedOut || child.unreadable > 0 || child.otherAppData
            DiskTreeRules.classify(&node, isBundle: child.isBundle, isLink: child.isLink, newest: Date(timeIntervalSince1970: TimeInterval(child.newest)), context: context)
            if let note = Self.partialNote(timedOut: child.timedOut, unreadable: child.unreadable, otherAppData: child.otherAppData, otherVolume: child.otherVolume) {
                node.hint = (node.hint.map { $0 + " · " } ?? "") + note
            }
            newest = max(newest, child.newest)
            children.append(node)
        }
        children.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var node = original ?? DiskNode(path: level.path, modified: Date(timeIntervalSince1970: TimeInterval(level.mtime)))
        node.children = children
        node.bytes = children.reduce(0) { $0 + $1.bytes }
        node.fileCount = children.reduce(0) { $0 + $1.fileCount }
        node.isDirectory = true
        node.partial = !level.complete || children.contains(where: \.partial)
        node.modified = Date(timeIntervalSince1970: TimeInterval(level.mtime))
        DiskTreeRules.classify(&node, isBundle: false, isLink: false, newest: Date(timeIntervalSince1970: TimeInterval(newest)), context: context)
        if !level.complete { node.hint = (node.hint.map { $0 + " · " } ?? "") + "권한이 없어 이 폴더를 읽지 못했습니다(전체 디스크 접근 권한이 필요할 수 있음)" }
        else if children.contains(where: \.partial) { node.hint = (node.hint.map { $0 + " · " } ?? "") + "일부 칸을 끝까지 세지 못했습니다(숫자는 하한값)" }
        // 펼치기 전에 저장된 원래 이름(시뮬레이터 이름 등)은 판정이 다시 정한다.
        return node
    }

    static func partialNote(timedOut: Bool, unreadable: Int, otherAppData: Bool, otherVolume: Bool) -> String? {
        var notes: [String] = []
        if otherVolume { notes.append("다른 볼륨(마운트 지점) — 크기를 세지 않습니다") }
        if otherAppData { notes.append("다른 앱의 보관함 데이터 — macOS 확인 창을 피하려고 조사 때는 들어가지 않았습니다(펼치면 잽니다)") }
        if timedOut { notes.append("시간 제한으로 일부만 셌습니다(실제는 더 큼)") }
        if unreadable > 0 { notes.append("권한이 없어 읽지 못한 폴더 \(unreadable)개(전체 디스크 접근 권한이 필요할 수 있음)") }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }

    // MARK: - 내부: 여러 경로 한꺼번에(묶음 보기)

    /// 경로 목록을 칸으로 만든다(폴더는 캐시 → 조사, 파일은 바로). 없는 경로는 목록에서 뺀다.
    func measurePaths(_ paths: inout [String], context: DiskTreeContext, deadline: Date) -> [String: DiskNode] {
        var unique: [String] = []
        var seen = Set<String>()
        for path in paths where seen.insert(path).inserted { unique.append(path) }
        paths = unique
        let opaque = currentOpaque()
        var nodes: [String: DiskNode] = [:]
        var facts: [String: (isBundle: Bool, isLink: Bool, newest: Int)] = [:]
        var targets: [DiskTreeWalker.Target] = []
        for path in unique {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            if kind == S_IFDIR {
                let isBundle = DiskTreeRules.bundleExtensions.contains(DiskTreeWalker.pathExtension((path as NSString).lastPathComponent))
                var node = DiskNode(path: path, isDirectory: !isBundle, modified: modified, children: isBundle ? [] : nil)
                facts[path] = (isBundle, false, Int(info.st_mtimespec.tv_sec))
                if let cached = cachedSize(path, mtime: Int(info.st_mtimespec.tv_sec), opaque: opaque) {
                    node.bytes = cached.bytes
                    node.fileCount = cached.files
                    node.partial = cached.unreadable > 0 || cached.otherAppData
                    facts[path]?.newest = max(Int(info.st_mtimespec.tv_sec), cached.newest)
                } else {
                    // 묶음 보기는 경로를 콕 집어 고른 것이라 그 경로가 놓인 볼륨을 그대로 잰다.
                    targets.append(DiskTreeWalker.Target(path: path, split: !isBundle, device: info.st_dev))
                }
                nodes[path] = node
            } else {
                nodes[path] = DiskNode(path: path, bytes: UInt64(info.st_blocks) * 512, fileCount: kind == S_IFREG ? 1 : 0, isDirectory: false, modified: modified, children: [])
                facts[path] = (false, kind == S_IFLNK, Int(info.st_mtimespec.tv_sec))
            }
        }
        if !targets.isEmpty {
            let walker = makeWalker()
            let result = walker.run(targets, deadline: .now() + max(0.05, deadline.timeIntervalSinceNow))
            for (index, target) in targets.enumerated() {
                let tally = result.tallies[index]
                nodes[target.path]?.bytes = tally.bytes
                nodes[target.path]?.fileCount = tally.files
                nodes[target.path]?.partial = tally.partial
                if let fact = facts[target.path] { facts[target.path]?.newest = max(fact.newest, tally.newest) }
                if let note = Self.partialNote(timedOut: tally.timedOut, unreadable: tally.unreadable, otherAppData: tally.otherAppData, otherVolume: tally.otherVolume) {
                    nodes[target.path]?.hint = note
                }
            }
            store(result.tallies, opaque: walker.opaque)
        }
        for path in unique {
            guard var node = nodes[path], let fact = facts[path] else { continue }
            let note = node.hint
            DiskTreeRules.classify(&node, isBundle: fact.isBundle, isLink: fact.isLink, newest: Date(timeIntervalSince1970: TimeInterval(fact.newest)), context: context)
            if let note { node.hint = (node.hint.map { $0 + " · " } ?? "") + note }
            nodes[path] = node
        }
        return nodes
    }

    func categoryNode(_ id: String, tag: DiskTag, title: String, hint: String, children: [DiskNode]) -> DiskNode {
        DiskNode(path: DiskNodeVirtual.path("category", id), name: title, bytes: children.reduce(0) { $0 + $1.bytes }, fileCount: children.reduce(0) { $0 + $1.fileCount },
                 isDirectory: true, children: children, tags: [tag], hint: hint, actions: [.none], partial: children.contains(where: \.partial))
    }

    /// ~/Downloads에서 오래되고 큰 파일(번들은 한 덩어리).
    func oldDownloads(context: DiskTreeContext, budget: TimeInterval) -> [DiskNode] {
        var info = stat()
        guard lstat(downloadsFolder, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return [] }
        let walker = makeWalker()
        walker.collectBundles = true
        walker.largeThreshold = downloadMinimumBytes + 1
        walker.largeLimit = 500
        let result = walker.run([DiskTreeWalker.Target(path: downloadsFolder, split: false, device: info.st_dev)], deadline: .now() + budget)
        let limit = Date().addingTimeInterval(-downloadAgeDays * 86_400)
        return result.large.compactMap { file -> DiskNode? in
            var node = DiskNode(path: file.path, bytes: file.bytes, fileCount: 1, isDirectory: false, children: [])
            node.modified = file.isBundle ? DiskScanner.modified(file.path) : Date(timeIntervalSince1970: TimeInterval(file.modified))
            guard let modified = node.modified, modified < limit else { return nil }
            DiskTreeRules.classify(&node, isBundle: file.isBundle, isLink: false, newest: modified, context: context)
            return node
        }
    }

    func dockerCategory(context: DiskTreeContext, sizes: [String: DiskNode]) -> DiskNode {
        var children: [DiskNode] = []
        var disks: [String] = DiskTreeRules.dockerDisks.map { home + "/" + $0.relative }.filter { path in
            // 다른 앱 보관함 안은 그 앱이 설치됐을 때만 본다(확인 창을 괜히 띄우지 않게).
            if path.contains("/Library/Containers/") || path.contains("/Library/Group Containers/") {
                var info = stat()
                return lstat(path, &info) == 0
            }
            return FileManager.default.fileExists(atPath: path)
        }
        let raw = home + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
        if disks.contains(home + "/Library/Containers/com.docker.docker"), FileManager.default.fileExists(atPath: raw) {
            disks.removeAll { $0 == home + "/Library/Containers/com.docker.docker" }
            disks.append(raw)
        }
        var paths = disks
        let measured = measurePaths(&paths, context: context, deadline: Date().addingTimeInterval(10))
        children += paths.compactMap { measured[$0] ?? sizes[$0] }
        let status = dockerUsage()
        for row in status.usage {
            let bytes = DockerDiskUsage.bytes(row.size) ?? 0
            let reclaimable = DockerDiskUsage.bytes(row.reclaimable) ?? 0
            let command = DockerDiskUsage.command(forType: row.type)
            var hint = "\(row.type) \(row.total)개(사용 중 \(row.active)) · 전체 \(row.size) · 회수 가능 \(row.reclaimable)"
            if let command {
                hint += " — 정리 명령: \(command.commandLine)(\(command.detail)). 지운 것은 되돌릴 수 없습니다(금고에 '지움'으로만 남습니다)"
            } else if row.type.lowercased().contains("volume") {
                hint += " — 볼륨은 데이터라 지우지 않습니다"
            } else {
                hint += " — ReMON은 컨테이너를 지우지 않습니다(필요하면 docker container prune)"
            }
            children.append(DiskNode(path: DiskNodeVirtual.path("docker", row.type.lowercased().replacingOccurrences(of: " ", with: "-")), name: "Docker \(row.type)", bytes: bytes,
                                     fileCount: Int(row.total) ?? 0, isDirectory: false, children: [], tags: [.docker], hint: hint,
                                     actions: command != nil && reclaimable > 0 ? [.prune] : [.none]))
        }
        children.sort { $0.bytes > $1.bytes }
        let note = status.note.map { " · " + $0 } ?? ""
        return categoryNode("docker", tag: .docker, title: "Docker",
                            hint: "가상 머신 디스크는 그 도구로만 줄어듭니다 · 이미지·빌드 캐시는 정리 명령(미리보기 뒤 실행)" + note, children: children)
    }

    func homebrewCategory(context: DiskTreeContext, deadline: Date) -> DiskNode {
        let preview = homebrewPreview(timeout: max(5, min(60, deadline.timeIntervalSinceNow)))
        var children = preview.items.map { item -> DiskNode in
            // Cellar/<이름>/<버전> · vendor/portable-ruby/<버전>은 '이름 버전'으로 보여 준다.
            let parts = item.path.split(separator: "/").map(String.init)
            let name = parts.count >= 2 && (item.path.contains("/Cellar/") || item.path.contains("/vendor/")) ? parts[parts.count - 2] + " " + parts[parts.count - 1] : nil
            var node = DiskNode(path: item.path, name: name, bytes: item.bytes, fileCount: item.files ?? 1, isDirectory: false, modified: DiskScanner.modified(item.path), children: [])
            node.tags = [.homebrew, .regenerable]
            node.hint = "brew cleanup이 지울 옛 버전·설치 파일 — Homebrew 묶음의 정리 명령으로 한 번에 지웁니다"
            node.actions = [.reveal]
            return node
        }
        let cache = home + "/Library/Caches/Homebrew"
        if FileManager.default.fileExists(atPath: cache), !preview.items.contains(where: { $0.path.hasPrefix(cache + "/") }) {
            var paths = [cache]
            if let node = measurePaths(&paths, context: context, deadline: deadline)[cache] { children.append(node) }
        }
        children.sort { $0.bytes > $1.bytes }
        var hint = preview.error ?? "brew cleanup --prune=all 미리보기: \(preview.items.count)개 · 약 \(Fmt.size(preview.bytes))"
        hint += " · 네트워크 연결 없음 · 미리보기에도 로컬 캐시를 갱신할 수 있습니다"
        if preview.error == nil { hint += " — 정리 명령은 확인 뒤 실행합니다(필요하면 brew install로 다시 설치)" }
        var node = categoryNode("homebrew", tag: .homebrew, title: "Homebrew", hint: hint, children: children)
        node.path = DiskNodeVirtual.path("homebrew", "cleanup")
        node.actions = preview.error == nil && !preview.items.isEmpty ? [.prune] : [.none]
        return node
    }

    func gitCategory(context: DiskTreeContext) -> DiskNode {
        var children: [DiskNode] = []
        var kept = 0
        for project in leftovers {
            for item in project.worktrees where item.isClutter {
                switch item.verdict {
                case .cleanable(.pruneWorktreeMetadata):
                    children.append(DiskNode(path: DiskNodeVirtual.path("git-prune", item.path), name: "끊긴 워크트리 기록 · \((item.path as NSString).lastPathComponent)",
                                             isDirectory: false, children: [], tags: [.gitByproduct],
                                             hint: "\(project.project) · 폴더가 이미 없는 워크트리 기록 — git worktree prune으로 정리합니다(되살릴 것 없음)", actions: [.prune]))
                case .cleanable:
                    var node = DiskNode(path: item.path, bytes: item.bytes, isDirectory: true, modified: item.lastCommit, children: nil, partial: !item.bytesComplete)
                    DiskTreeRules.classify(&node, isBundle: false, isLink: false, newest: item.lastCommit, context: context)
                    node.name = "\(project.project) · " + (item.orcaDisplayName ?? (item.path as NSString).lastPathComponent)
                    children.append(node)
                case .keep:
                    kept += 1
                }
            }
            for branch in project.branches where branch.isClutter {
                guard branch.verdict.isCleanable else { kept += 1; continue }
                children.append(DiskNode(path: DiskNodeVirtual.path("git-branch", branch.repo + "#" + branch.name), name: "\(project.project) · 브랜치 \(branch.name)",
                                         isDirectory: false, modified: branch.lastCommit, children: [], tags: [.gitByproduct],
                                         hint: "병합된 브랜치 — git branch -d로 지웁니다(금고에 커밋 \(branch.head.prefix(8))을 적어 같은 커밋으로 되살림)", actions: [.prune]))
            }
        }
        children.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
        let hint = leftovers.isEmpty ? "부산물 조사 결과 없음(~/DEV 저장소가 없거나 조사 전)" : "정리 가능 \(children.count)개 · 보존 \(kept)개(변경·병합 안 됨·사용 중 등)"
        return categoryNode("git", tag: .gitByproduct, title: "git 부산물", hint: hint, children: children)
    }

    // MARK: - 내부: 캐시 · 설정

    func makeWalker() -> DiskTreeWalker {
        let walker = DiskTreeWalker()
        walker.parallelism = parallelism
        walker.opaque = currentOpaque()
        walker.bundleExtensions = DiskTreeRules.bundleExtensions
        lock.lock()
        let started = generation
        lock.unlock()
        walker.isCancelled = { [weak self] in
            guard let self else { return true }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.generation != started
        }
        return walker
    }

    func currentOpaque() -> Set<String> {
        let allowed = measuresOtherAppData ?? Self.hasFullDiskAccess(home: home)
        return allowed ? [] : [home + "/Library/Containers", home + "/Library/Group Containers"]
    }

    func cachedSize(_ path: String, mtime: Int, opaque: Set<String>) -> CachedSize? {
        lock.lock(); defer { lock.unlock() }
        guard let cached = sizes[path], Date().timeIntervalSince(cached.at) < cacheTTL, cached.dirMtime == mtime else { return nil }
        // 다른 앱 보관함을 건너뛴 값은 지금도 건너뛸 때만 쓴다.
        if cached.otherAppData, opaque.isEmpty { return nil }
        return cached
    }

    func store(_ tallies: [DiskTreeWalker.Tally], opaque: Set<String>) {
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        for tally in tallies where !tally.timedOut && !tally.missing && tally.dirMtime != 0 {
            sizes[tally.path] = CachedSize(bytes: tally.bytes, files: tally.files, newest: tally.newest, dirMtime: tally.dirMtime, at: now, unreadable: tally.unreadable,
                                           otherAppData: tally.otherAppData, otherVolume: tally.otherVolume)
        }
        if sizes.count > 200_000 { sizes = sizes.filter { now.timeIntervalSince($0.value.at) < cacheTTL } }
    }

    func record(started: Date, _ stats: MeasureStats) {
        var value = Report()
        value.elapsed = Date().timeIntervalSince(started)
        value.directories = stats.directories
        value.files = stats.files
        value.complete = stats.complete
        value.cacheHits = stats.cacheHits
        value.measured = stats.walked
        lock.lock(); report = value; lock.unlock()
    }

    func settings() -> DiskTreeSettings {
        DiskTreeSettings(home: home, largeFileThreshold: largeFileThreshold, tempAgeDays: tempAgeDays, downloadAgeDays: downloadAgeDays, downloadMinimumBytes: downloadMinimumBytes,
                         simulatorIdleDays: simulatorIdleDays, temporaryFolders: temporaryFolders.map(SafeFileOps.canonical), cacheFolders: cacheFolders.map(SafeFileOps.canonical),
                         trashFolder: trashFolder, downloadsFolder: downloadsFolder, vmFolder: vmFolder, sleepImageFolder: sleepImageFolder,
                         applicationFolders: applicationFolders, catalog: catalog)
    }

    func makeContext() -> DiskTreeContext {
        var index: [String: WorktreeLeftover] = [:]
        for project in leftovers {
            for item in project.worktrees {
                index[item.path] = item
                index[SafeFileOps.canonical(item.path)] = item
            }
        }
        lock.lock()
        let targets = Set(brew.map { Date().timeIntervalSince($0.at) < cacheTTL ? $0.preview.items.map(\.path) : [] } ?? [])
        lock.unlock()
        return DiskTreeContext(settings: settings(), now: Date(), running: runningProbe(), activeDirectories: activeDirectoriesProbe(), leftovers: index, brewTargets: targets,
                               userPIDs: userPIDsProbe, executables: executablesProbe)
    }

    // MARK: - 정적 도우미

    /// 사용자 임시(T)·캐시(C) 폴더: TMPDIR과 /private/var/folders/*/* 중 읽을 수 있는 것(다른 사용자·데몬 몫은 권한이 없어 빠진다).
    static func userTemporaryFolders() -> (temporary: [String], caches: [String]) {
        var temporary: [String] = [], caches: [String] = []
        func add(_ raw: String, _ list: inout [String]) {
            let trimmed = raw.hasSuffix("/") && raw.count > 1 ? String(raw.dropLast()) : raw
            let path = SafeFileOps.canonical(trimmed)
            if !list.contains(path), access(path, R_OK | X_OK) == 0 { list.append(path) }
        }
        let tmp = SafeFileOps.canonical(String(NSTemporaryDirectory().dropLast(NSTemporaryDirectory().hasSuffix("/") ? 1 : 0)))
        add(tmp, &temporary)
        if tmp.hasSuffix("/T") { add(String(tmp.dropLast(2)) + "/C", &caches) }
        let root = "/private/var/folders"
        for top in children(root) {
            for user in children(top) {
                add(user + "/T", &temporary)
                add(user + "/C", &caches)
            }
        }
        return (temporary, caches)
    }

    static func liveActiveDirectories(home: String) -> Set<String> {
        let topLevel = Set(((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).map { home + "/" + $0 })
        return Set(ProcessPresence.live().map(\.cwd).filter { $0.hasPrefix(home + "/") && !topLevel.contains($0) })
    }

    /// 전체 디스크 접근: 보호 폴더(~/Library/Safari · Mail · Messages)를 열 수 있는가. 하나도 없으면 모름 → false.
    static func hasFullDiskAccess(home: String) -> Bool {
        for name in ["Safari", "Mail", "Messages"] {
            let path = home + "/Library/" + name
            guard let directory = opendir(path) else { if errno == EPERM || errno == EACCES { return false }; continue }
            closedir(directory)
            return true
        }
        return false
    }

    static func children(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted().map { folder + "/" + $0 }
    }

    static func swapFiles(_ folder: String) -> [String] {
        children(folder).filter { ($0 as NSString).lastPathComponent.hasPrefix("swapfile") }
    }

    /// "com.apple.TimeMachine.2026-10-25-101010.local" → "Time Machine 2026-10-25 10:10:10"
    static func snapshotLabel(_ name: String) -> String {
        if let range = name.range(of: #"\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) {
            let stamp = name[range]
            let day = stamp.prefix(10), time = stamp.suffix(6)
            let clock = "\(time.prefix(2)):\(time.dropFirst(2).prefix(2)):\(time.suffix(2))"
            return (name.contains("TimeMachine") ? "Time Machine " : "스냅샷 ") + "\(day) \(clock)"
        }
        return name.contains("os.update") ? "macOS 업데이트 스냅샷" : name
    }
}
