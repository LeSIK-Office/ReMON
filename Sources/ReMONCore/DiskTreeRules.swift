import Darwin
import Foundation

// 디스크 지도의 태그 규칙 — 경로 하나에 '무엇인지(태그) · 왜(설명) · 무엇을 해도 되는지(조치)'를 붙인다.
// 이미 있는 지식을 그대로 쓴다: 개발 캐시 표(DiskCatalog) · 영구 삭제 정책(CacheDeletionPolicy) · AI 데이터 보호(AIDataProtection ·
// AIAppCacheCatalog · CLIVersionCatalog) · 부산물 판정(LeftoverRules) · 시스템 데이터 덩어리(SystemData). 홈 안에서 모르는 것은 '사용자 파일'
// (휴지통만), 홈 밖·macOS 영역은 보기만. 판정 순서가 곧 우선순위다: 스왑·임시 → 홈 밖 → AI 기록·자격 증명 → 휴지통 안 → git → Xcode →
// 표(캐시 등급) → 이름 규칙(빌드 산출물) → Homebrew·Docker·백업·다운로드 → 영역 규칙(~/Library) → 홈 최상위 → 사용자 파일.
// 마지막에 SafeFileOps.validate로 한 번 더 거른다 — 보호 경로면 휴지통·삭제 조치를 뺀다.

/// 조사 설정(조사 한 번 동안 바뀌지 않는 값).
struct DiskTreeSettings: Sendable {
    var home: String
    var largeFileThreshold: UInt64
    var tempAgeDays: Double
    var downloadAgeDays: Double
    var downloadMinimumBytes: UInt64
    var simulatorIdleDays: Double
    /// 사용자 임시 폴더(…/T) — 정식 경로
    var temporaryFolders: [String]
    /// 사용자 캐시 폴더(…/C) — 정식 경로
    var cacheFolders: [String]
    var trashFolder: String
    var downloadsFolder: String
    /// 스왑 파일이 놓이는 볼륨(/System/Volumes/VM)
    var vmFolder: String
    /// 잠자기 이미지 폴더(/private/var/vm)
    var sleepImageFolder: String
    /// 설치된 앱을 찾는 폴더(앱 데이터가 '지운 앱의 찌꺼기'인지 가린다)
    var applicationFolders: [String]
    var catalog: [CatalogEntry]
}

/// 조사 한 번(scan · expand · largeFiles · categories)이 쓰는 지금 상태. 비싼 것(열린 파일 · 실행 파일 · 휴지통 기록 · CLI 버전)은
/// 처음 필요할 때 한 번만 읽는다. 한 호출 안에서만 쓰고(스레드 하나) 공유하지 않는다.
final class DiskTreeContext {
    let settings: DiskTreeSettings
    let now: Date
    let running: RunningApps
    let activeDirectories: Set<String>
    let aiPaths: AIDataPaths
    let holders: [(title: String, path: String, manage: String)]
    /// 부산물 조사 결과(워크트리 경로 → 판정). 조사 전이면 비어 있다.
    let leftovers: [String: WorktreeLeftover]
    /// brew cleanup -n이 지울 경로(미리보기를 돌린 적이 있을 때만)
    let brewTargets: Set<String>
    private let userPIDs: @Sendable () -> [Int32]
    private let executablesProbe: @Sendable () -> [RunningExecutable]
    private var catalogCache: [String: CatalogMatch?] = [:]
    private var openFilesValue: [(pid: Int32, path: String)]?
    private var putBackValue: [String: TrashPutBack.Origin]?
    private var executablesValue: [RunningExecutable]?
    private var versionsValue: [String: CLIVersion]?
    private var swapValue: SwapStats?
    private var installedValue: (names: Set<String>, words: Set<String>, ids: Set<String>)?

    init(settings: DiskTreeSettings, now: Date, running: RunningApps, activeDirectories: Set<String>, leftovers: [String: WorktreeLeftover], brewTargets: Set<String>,
         userPIDs: @escaping @Sendable () -> [Int32], executables: @escaping @Sendable () -> [RunningExecutable]) {
        self.settings = settings
        self.now = now
        self.running = running
        self.activeDirectories = activeDirectories
        self.leftovers = leftovers
        self.brewTargets = brewTargets
        self.userPIDs = userPIDs
        executablesProbe = executables
        aiPaths = AIDataPaths(home: settings.home)
        holders = SystemData.holderCandidates(home: settings.home)
    }

    var home: String { settings.home }

    func catalogMatch(_ path: String, newest: Date? = nil) -> CatalogMatch? {
        if let cached = catalogCache[path] { return cached }
        let match = DiskCatalog.match(path, home: home, now: now, newest: newest, entries: settings.catalog)
        catalogCache[path] = match
        return match
    }

    func leftover(_ path: String) -> WorktreeLeftover? {
        leftovers[path] ?? leftovers[SafeFileOps.canonical(path)]
    }

    /// 이 경로(또는 그 아래) 파일을 연 사용자 프로세스. SafeFileOps.deletePermanently가 지우기 직전에 보는 것과 같은 확인이다.
    func openers(of path: String) -> [Int32] {
        if openFilesValue == nil {
            openFilesValue = userPIDs().flatMap { pid in ProcessSampler.openFiles(pid: pid).map { (pid, $0) } }
        }
        let canonical = SafeFileOps.canonical(path)
        let roots = Set([path, canonical])
        let pids = (openFilesValue ?? []).filter { file in roots.contains { file.path == $0 || file.path.hasPrefix($0 + "/") } }.map(\.pid)
        return Array(Set(pids)).sorted()
    }

    func putBack() -> [String: TrashPutBack.Origin] {
        if let putBackValue { return putBackValue }
        let value = TrashPutBack.read(settings.trashFolder)
        putBackValue = value
        return value
    }

    var executables: [RunningExecutable] {
        if let executablesValue { return executablesValue }
        let value = executablesProbe()
        executablesValue = value
        return value
    }

    var aiContext: AIDataContext { AIDataContext(now: now, executables: executables) }

    func cliVersion(_ path: String) -> CLIVersion? {
        if versionsValue == nil {
            let found = CLIVersionCatalog.scan(paths: aiPaths, options: AIDataOptions(), context: aiContext)
            versionsValue = Dictionary(found.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return versionsValue?[path]
    }

    var swap: SwapStats {
        if let swapValue { return swapValue }
        let value = SystemSampler().swap()
        swapValue = value
        return value
    }

    /// 이 이름(앱 데이터 폴더 · 보관함 · 설정 파일의 번들 id)의 앱이 설치돼 있는가. 앱 이름 · 이름의 낱말(4자 이상) · 번들 id(앞부분 포함)로 넓게 본다 —
    /// 잘못 '설치됨'으로 보면 보기만 하게 될 뿐이라 넓게 잡는 쪽이 안전하다.
    func appInstalled(_ rawName: String) -> Bool {
        if installedValue == nil {
            var names = Set<String>(), words = Set<String>(), ids = Set<String>()
            func add(_ bundle: String) {
                let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
                names.insert(name)
                for word in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) where word.count >= 4 { words.insert(String(word)) }
                if let id = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String { ids.insert(id.lowercased()) }
            }
            for folder in settings.applicationFolders {
                for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                    let path = folder + "/" + name
                    if name.hasSuffix(".app") { add(path); continue }
                    // 한 단계 아래(예: /Applications/Adobe Photoshop/Photoshop.app)
                    var info = stat()
                    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
                    for inner in (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") { add(path + "/" + inner) }
                }
            }
            installedValue = (names, words, ids)
        }
        guard let installed = installedValue else { return false }
        var name = rawName.lowercased()
        if name.hasSuffix(".plist") { name = String(name.dropLast(6)) }
        // 묶음 보관함의 팀 접두(10자)·'group.'은 뗀다.
        let pieces = name.split(separator: ".", maxSplits: 1).map(String.init)
        if pieces.count == 2, pieces[0].count == 10, pieces[0].allSatisfy({ $0.isLetter || $0.isNumber }), rawName.prefix(10).allSatisfy({ $0.isUppercase || $0.isNumber }) { name = pieces[1] }
        if name.hasPrefix("group.") { name = String(name.dropFirst("group.".count)) }
        if installed.ids.contains(name) || installed.names.contains(name) { return true }
        if name.count >= 4, installed.words.contains(name) { return true }
        if name.contains(".") {
            if installed.ids.contains(where: { $0.hasPrefix(name + ".") || name.hasPrefix($0 + ".") }) { return true }
            if let last = name.split(separator: ".").last, last.count >= 4, installed.words.contains(String(last)) || installed.names.contains(String(last)) { return true }
        }
        return false
    }

    func relative(_ path: String) -> String? {
        if path == home { return "" }
        guard path.hasPrefix(home + "/") else { return nil }
        return String(path.dropFirst(home.count + 1))
    }

    func days(since date: Date?) -> Int {
        guard let date else { return 0 }
        return max(0, Int(now.timeIntervalSince(date) / 86_400))
    }
}

/// 한 칸의 판정.
struct DiskTreeVerdict {
    var tags: Set<DiskTag>
    var hint: String
    var actions: [DiskNodeAction]
    /// 보여 줄 이름(시뮬레이터 기기 이름 · 백업 기기 이름 · 휴지통 원래 이름)
    var name: String?

    init(_ tags: Set<DiskTag>, _ hint: String, _ actions: [DiskNodeAction], name: String? = nil) {
        self.tags = tags
        self.hint = hint
        self.actions = actions
        self.name = name
    }
}

enum DiskTreeRules {
    // MARK: 표

    /// 통째로 한 칸으로 다루는 번들(안으로 펼치지 않는다).
    static let bundleExtensions: Set<String> = LargeFileFinder.packageExtensions.union(LargeFileFinder.libraryExtensions).union(
        ["xpc", "kext", "xcodeproj", "xcworkspace", "playground", "docset", "dsym", "prefpane", "qlgenerator", "mdimporter", "saver", "rtfd", "pages", "numbers",
         "key", "mlpackage", "scptd", "systemextension", "driver", "vst", "vst3", "component", "aaxplugin"])

    /// 홈 최상위의 기본 폴더(통째로 옮기지 않는다).
    static let standardFolders: Set<String> = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications", "Sites", "DEV", "Library"]

    /// 자격 증명·키(홈 기준). 내용은 읽지 않고 옮기지도 않는다.
    static let secrets = [".ssh", ".gnupg", ".aws", ".kube", ".azure", ".netrc", ".npmrc", ".git-credentials", ".config/gh", ".config/gcloud", ".docker/config.json",
                          ".pypirc", ".gem/credentials", ".cargo/credentials", ".cargo/credentials.toml", ".vault-token", ".password-store", ".terraform.d"]

    /// 대화 원본(홈 기준) — 세션을 되살리는 복구 자원이라 보기만.
    static let transcriptRoots = [".claude/projects", ".claude/file-history", ".claude/paste-cache", ".claude/sessions", ".codex/sessions", ".codex/archived_sessions",
                                  ".codex/attachments", ".codex/computer-use"]

    /// AI 도구 데이터 폴더(홈 기준). 표에 없는 안쪽은 그 도구·AI 데이터 화면에서 정리한다.
    static let aiRoots = [".claude", ".codex", ".gemini", ".cursor", ".aside", ".continue", ".windsurf", ".codeium", ".local/share/opencode", ".local/share/claude",
                          ".local/share/cursor-agent"] + AIDataProtection.appSupportFolders.map { "Library/Application Support/" + $0 }
        + AIAppCacheCatalog.libraryCaches.map { "Library/Caches/" + $0.name }

    /// Docker·가상 머신 디스크(홈 기준): 파일을 직접 지우지 않고 그 도구로 줄인다.
    static let dockerDisks: [(relative: String, title: String, manage: String)] = [
        (".colima", "Colima 가상 머신", "colima delete <프로필>로 지우거나 colima prune으로 줄입니다"),
        (".orbstack", "OrbStack", "OrbStack 설정에서 관리합니다"),
        (".lima", "Lima 가상 머신", "limactl delete <이름>으로 지웁니다"),
        ("Library/Containers/com.docker.docker", "Docker Desktop 디스크(Docker.raw)", "Docker Desktop › 설정 › Resources에서 줄이거나 docker 정리 명령을 씁니다"),
        ("Library/Group Containers/HUAQ24HBR6.dev.orbstack", "OrbStack 디스크(data.img)", "OrbStack 설정에서 관리합니다"),
    ]

    /// ~/Library 바로 아래에서 사용자가 안쪽 항목을 고를 수 있는 곳. 나머지는 macOS·앱이 관리한다(보기만).
    static let addOnAreas: Set<String> = ["Fonts", "Audio", "Screen Savers", "Services", "ColorPickers", "Input Methods", "Keyboard Layouts", "PreferencePanes", "QuickLook",
                                          "Spotlight", "Internet Plug-Ins", "Compositions", "Workflows", "Scripts", "Sounds", "Dictionaries"]
    /// Application Support 안의 macOS 데이터(com.apple.* 말고도).
    static let appleSupportNames: Set<String> = ["AddressBook", "CallHistoryDB", "CallHistoryTransactions", "CloudDocs", "CrashReporter", "Dock", "FileProvider", "Knowledge",
                                                 "iCloud", "icdd", "networkserviceproxy", "AppleMediaServices", "Animoji", "FaceTime", "accountsd", "CoreParsec",
                                                 "DifferentialPrivacy", "SyncServices", "ControlCenter", "DiskImages", "Ubiquity", "MobileSync", "App Store", "AppStore",
                                                 "Mail", "Safari", "Photos", "Shortcuts", "Siri", "Wallpaper", "NotificationCenter", "BackgroundTaskManagement", "StatusKit"]

    static let cloudHint = "클라우드 저장소 — 지우면 다른 기기에서도 사라집니다. 공간만 돌려받으려면 Finder에서 '다운로드한 항목 제거'를 씁니다"
    static let userFileHint = "사용자 파일 — 자동으로 지우지 않습니다. 직접 고르면 휴지통으로 옮깁니다(되돌리기 가능)"

    // MARK: 판정

    /// 칸의 태그 · 설명 · 조치(·이름)를 채운다. newest: 아래 전부의 가장 최근 수정 시각(모르면 nil — 항목 자신의 시각을 쓴다).
    static func classify(_ node: inout DiskNode, isBundle: Bool, isLink: Bool, newest: Date?, context: DiskTreeContext) {
        var verdict = decide(node, isBundle: isBundle, isLink: isLink, newest: newest, context: context)
        if isBundle {
            verdict.tags.insert(.bundle)
            let fileName = (node.path as NSString).lastPathComponent
            if LargeFileFinder.libraryExtensions.contains(DiskTreeWalker.pathExtension(fileName)) {
                verdict.actions.removeAll { $0 == .trash || $0 == .deletePermanently }
                verdict.hint = "사진·음악 같은 앱 보관함 — 그 앱에서 정리합니다(통째로 한 칸)"
            } else if fileName.hasSuffix(".app"), context.running.appNames.contains(String(fileName.dropLast(4)).lowercased()), verdict.actions.contains(.trash) {
                // 실행 중인 앱 번들은 어디에 있든 옮기지 않는다(열린 파일 확인만으로는 실행 파일 매핑을 못 본다).
                verdict.actions.removeAll { $0 == .trash || $0 == .deletePermanently }
                verdict.hint = "실행 중인 앱 — 끈 뒤 정리합니다"
            }
        }
        if (!node.isDirectory || isBundle), node.bytes >= context.settings.largeFileThreshold {
            verdict.tags.insert(.large)
            let kind = LargeFileKind.kind(for: node.name).map { " · \($0.label)" } ?? ""
            verdict.hint += " · 큰 파일\(kind)"
        }
        if isLink, let target = try? FileManager.default.destinationOfSymbolicLink(atPath: node.path) {
            verdict.hint = "링크 → \(target)(따라가지 않습니다 · 링크만 다룹니다) · " + verdict.hint
        }
        finish(&verdict, path: node.path)
        node.tags = verdict.tags
        node.hint = verdict.hint
        node.actions = verdict.actions
        if let name = verdict.name { node.name = name }
    }

    /// 마지막 거름: 영구 삭제는 사용자 파일·AI 기록·시스템·스왑·스냅샷과 함께 두지 않고, 휴지통·삭제는 SafeFileOps가 허락하는 경로에만.
    static func finish(_ verdict: inout DiskTreeVerdict, path: String) {
        if !verdict.tags.isDisjoint(with: [.userFile, .aiTranscript, .system, .swap, .snapshot]) { verdict.actions.removeAll { $0 == .deletePermanently } }
        if verdict.actions.contains(where: { $0 == .trash || $0 == .deletePermanently }) {
            do { _ = try SafeFileOps.validate(path, removal: true) } catch {
                verdict.actions.removeAll { $0 == .trash || $0 == .deletePermanently }
                verdict.hint += " · 보호 경로라 옮기지 않습니다"
            }
        }
        let order: [DiskNodeAction] = [.reveal, .trash, .prune, .deletePermanently]
        var actions = order.filter(verdict.actions.contains)
        if actions.isEmpty { actions = [.none] }
        verdict.actions = actions
    }

    static func decide(_ node: DiskNode, isBundle: Bool, isLink: Bool, newest: Date?, context ctx: DiskTreeContext) -> DiskTreeVerdict {
        let path = node.path
        let name = (path as NSString).lastPathComponent
        let latest = newest ?? node.modified
        if let verdict = swap(path, name: name, ctx) { return verdict }
        if let verdict = temporary(path, latest: latest, ctx) { return verdict }
        guard let rel = ctx.relative(path) else { return outside(path, name: name, isBundle: isBundle, ctx) }
        if rel.isEmpty { return DiskTreeVerdict([.userFile], "홈 폴더", [.reveal]) }
        if let verdict = ai(path, rel: rel, ctx) { return verdict }
        if let verdict = trash(path, name: name, ctx) { return verdict }
        if let verdict = secret(rel) { return verdict }
        if !isLink, let verdict = git(path, name: name, isDirectory: node.isDirectory, isBundle: isBundle, ctx) { return verdict }
        if let verdict = xcode(path, rel: rel, isDirectory: node.isDirectory, ctx) { return verdict }
        if !isLink, let match = ctx.catalogMatch(path, newest: newest) { return catalog(match, path: path, bytes: node.bytes, modified: latest, inherited: false, ctx) }
        if !isLink, let verdict = projectArtifact(path, rel: rel, name: name, isDirectory: node.isDirectory && !isBundle, bytes: node.bytes, modified: latest, ctx) { return verdict }
        if let verdict = inheritedCatalog(path, ctx) { return verdict }
        if let verdict = homebrew(rel, ctx) { return verdict }
        if let verdict = docker(rel, ctx) { return verdict }
        if let verdict = backup(path, rel: rel, ctx) { return verdict }
        if let verdict = download(path, isFileLike: !node.isDirectory || isBundle, bytes: node.bytes, modified: node.modified, ctx) { return verdict }
        if let verdict = holder(path, ctx) { return verdict }
        if rel == "Library" || rel.hasPrefix("Library/") { return library(rel, ctx) }
        if !rel.contains("/") { return homeTop(rel, isFolder: node.isDirectory || isBundle) }
        if rel.hasPrefix(".cache/") { return DiskTreeVerdict([.cache], "XDG 캐시 폴더 — 도구가 다시 만듭니다(주인을 몰라 휴지통으로만 옮깁니다)", [.reveal, .trash]) }
        return DiskTreeVerdict([.userFile], userFileHint, [.reveal, .trash])
    }

    // MARK: 규칙들

    static func swapSummary(_ ctx: DiskTreeContext) -> String {
        let swap = ctx.swap
        return "스왑 \(Fmt.size(swap.used)) 사용 중 / 전체 \(Fmt.size(swap.total))\(swap.encrypted ? "(암호화)" : "") — macOS가 메모리가 모자랄 때 씁니다. 지울 수 없고, "
            + "메모리를 많이 쓰는 앱·세션을 정리하면 줄어듭니다(재시동하면 비워집니다)"
    }

    static func swap(_ path: String, name: String, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        let vm = ctx.settings.vmFolder, sleep = ctx.settings.sleepImageFolder
        if path == sleep || path == vm { return DiskTreeVerdict([.swap, .system], swapSummary(ctx), [.none]) }
        if path == sleep + "/sleepimage" { return DiskTreeVerdict([.system], "잠자기(최대 절전) 이미지 — 메모리 내용을 담아 두는 파일로 macOS가 관리합니다", [.none]) }
        if path.hasPrefix(vm + "/") {
            if name.hasPrefix("swapfile") { return DiskTreeVerdict([.swap], swapSummary(ctx), [.none]) }
            return DiskTreeVerdict([.system], "가상 메모리 볼륨 — macOS가 관리합니다", [.none])
        }
        if path.hasPrefix(sleep + "/") { return DiskTreeVerdict([.system], "가상 메모리 폴더 — macOS가 관리합니다", [.none]) }
        return nil
    }

    static func temporary(_ path: String, latest: Date?, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        let limit = ctx.settings.tempAgeDays
        for root in ctx.settings.temporaryFolders where path == root || path.hasPrefix(root + "/") {
            if path == root { return DiskTreeVerdict([.temp], "사용자 임시 폴더(TMPDIR) — 통째로 옮기지 않고, 안쪽에서 오래된 것만 고릅니다", [.reveal]) }
            let first = path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init) ?? ""
            if first.hasPrefix("com.apple.") { return DiskTreeVerdict([.temp], "macOS 서비스의 임시 폴더 — 서비스가 스스로 정리합니다", [.reveal]) }
            let age = ctx.days(since: latest)
            if Double(age) < limit { return DiskTreeVerdict([.temp], "최근 \(Int(limit))일 안에 쓰인 임시 파일 — 쓰는 중일 수 있어 그대로 둡니다", [.reveal]) }
            let users = ctx.openers(of: path)
            if !users.isEmpty {
                return DiskTreeVerdict([.temp], "열어 둔 프로그램이 있는 임시 파일(pid \(users.prefix(3).map(String.init).joined(separator: ","))) — 그대로 둡니다", [.reveal])
            }
            return DiskTreeVerdict([.temp], "\(age)일 동안 쓰이지 않았고 연 프로그램이 없는 임시 파일 — 휴지통으로 옮겨도 됩니다(macOS도 재시동 때 지웁니다)", [.reveal, .trash])
        }
        for root in ctx.settings.cacheFolders where path == root || path.hasPrefix(root + "/") {
            if path == root { return DiskTreeVerdict([.cache], "사용자 캐시 폴더 — 통째로 옮기지 않고, 안쪽에서 오래된 것만 고릅니다", [.reveal]) }
            let first = path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init) ?? ""
            if first.hasPrefix("com.apple.") { return DiskTreeVerdict([.cache], "macOS 서비스의 캐시 — 지우지 않습니다(필요하면 macOS가 비웁니다)", [.none]) }
            let age = ctx.days(since: latest)
            if Double(age) < limit { return DiskTreeVerdict([.cache], "최근 \(Int(limit))일 안에 쓰인 캐시 — 쓰는 중일 수 있어 그대로 둡니다", [.reveal]) }
            let owner = DiskScanner.folderOwner(first)
            if ctx.running.isRunning(owner) { return DiskTreeVerdict([.cache], "\(owner.name) 실행 중 — 종료한 뒤 정리합니다", [.reveal]) }
            return DiskTreeVerdict([.cache], "\(age)일 동안 쓰이지 않은 앱 캐시 — 지우면 앱이 필요할 때 다시 만듭니다(순수 캐시)", [.reveal, .deletePermanently])
        }
        return nil
    }

    static func outside(_ path: String, name: String, isBundle: Bool, _ ctx: DiskTreeContext) -> DiskTreeVerdict {
        if path == "/Applications" { return DiskTreeVerdict([.system], "앱 폴더 — 통째로 다루지 않고 앱을 하나씩 고릅니다", [.reveal]) }
        if path.hasPrefix("/Applications/") {
            let rest = path.dropFirst("/Applications/".count)
            if isBundle, !rest.contains("/"), name.hasSuffix(".app") {
                let identifier = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String ?? ""
                if identifier.hasPrefix("com.apple.") { return DiskTreeVerdict([.system], "macOS 기본 앱 — 지우지 않습니다", [.reveal]) }
                let app = String(name.dropLast(4)).lowercased()
                if ctx.running.appNames.contains(app) || (!identifier.isEmpty && ctx.running.bundleIDs.contains(identifier)) {
                    return DiskTreeVerdict([.userFile], "실행 중인 앱 — 끈 뒤 정리합니다", [.reveal])
                }
                return DiskTreeVerdict([.userFile], "앱 — 휴지통으로 옮기면 앱이 지워집니다(앱이 남긴 설정·캐시는 따로 남습니다). 쓰지 않는 앱이면 정리해도 됩니다", [.reveal, .trash])
            }
            return DiskTreeVerdict([.system], "앱 폴더 안 — 보기만 합니다", [.reveal])
        }
        if path == "/Library/Developer" || path.hasPrefix("/Library/Developer/") {
            if let holder = ctx.holders.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                return DiskTreeVerdict([.xcode, .system], "\(holder.title) — \(holder.manage)", [.none])
            }
            let rest = String(path.dropFirst("/Library/Developer".count))
            if rest.hasPrefix("/CoreSimulator/Volumes") || rest.hasPrefix("/CoreSimulator/Images") || rest.hasPrefix("/CoreSimulator/Profiles/Runtimes") || rest.hasPrefix("/CoreSimulator/Cryptex") {
                return DiskTreeVerdict([.xcode, .system], "시뮬레이터 런타임 — 'xcrun simctl runtime delete <id>'로 지웁니다(관리자 권한 영역)", [.reveal])
            }
            if rest.hasPrefix("/CommandLineTools") { return DiskTreeVerdict([.xcode, .system], "Command Line Tools — 지우면 git·swift가 멈춥니다", [.none]) }
            return DiskTreeVerdict([.xcode, .system], "Xcode·시뮬레이터 시스템 영역(관리자 권한) — 보기만 합니다", [.reveal])
        }
        if let holder = ctx.holders.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
            return DiskTreeVerdict([.system], "\(holder.title) — \(holder.manage)", [.none])
        }
        for prefix in ["/opt/homebrew", "/usr/local/Cellar", "/usr/local/Homebrew"] where path == prefix || path.hasPrefix(prefix + "/") {
            if ctx.brewTargets.contains(path) {
                return DiskTreeVerdict([.homebrew, .regenerable], "Homebrew 옛 버전 — 'brew cleanup --prune=all'이 지울 대상입니다(Homebrew 묶음에서 한 번에 정리)", [.reveal])
            }
            return DiskTreeVerdict([.homebrew], "Homebrew 설치본 — brew로 관리합니다", [.reveal])
        }
        if path.hasPrefix("/private/var/folders") {
            return DiskTreeVerdict([.system], "macOS 임시·캐시 폴더 묶음 — 사용자 임시(T)·캐시(C) 안쪽만 정리 대상입니다(다른 사용자·서비스 몫은 보기만)", [.none])
        }
        return DiskTreeVerdict([.system], "시스템 영역 — 보기만 합니다", [.reveal])
    }

    static func ai(_ path: String, rel: String, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        func under(_ root: String) -> Bool { rel == root || rel.hasPrefix(root + "/") }
        if transcriptRoots.contains(where: under) {
            let memory = rel.hasPrefix(".claude/projects/") && rel.split(separator: "/").dropFirst(3).first == "memory"
            return DiskTreeVerdict([.aiTranscript], memory ? "Claude 프로젝트 메모리 — 지우지 않습니다"
                                   : "AI 대화 기록·첨부 — 세션을 되살리는 복구 자원이라 지우지 않습니다(외장 이전·정리는 AI 데이터 화면에서)", [.none])
        }
        if AIAppCacheCatalog.isKnownCache(path, paths: ctx.aiPaths) {
            let owner = (AIAppCacheCatalog.libraryCaches.first { ctx.aiPaths.caches + "/" + $0.name == path }?.owner)
                ?? (AIAppCacheCatalog.homeCaches.first { ctx.aiPaths.home + "/" + $0.relative == path }?.owner)
                ?? (AIAppCacheCatalog.supportApps.first { path.hasPrefix(ctx.aiPaths.appSupport + "/" + $0.folder + "/") }?.owner)
                ?? (AIAppCacheCatalog.homeProfiles.first { path.hasPrefix(ctx.aiPaths.home + "/" + $0.relative + "/") }?.owner)
            if let owner {
                let running = owner.runningPIDs(ctx.executables)
                if !running.isEmpty {
                    return DiskTreeVerdict([.aiData, .cache], "\(owner.label) 캐시 · \(owner.label) 실행 중 — 끄면 비울 수 있습니다(pid \(running.prefix(3).map(String.init).joined(separator: ",")))", [.reveal])
                }
                return DiskTreeVerdict([.aiData, .cache], "\(owner.label) 캐시 — 앱을 다시 열면 새로 만듭니다(순수 캐시)", [.reveal, .deletePermanently])
            }
        }
        if let reason = AIDataProtection.reason(for: path, home: ctx.home, removal: true) {
            return DiskTreeVerdict([.aiData], reason + " — 지우지 않습니다", [.none])
        }
        let versionFolders = [ctx.aiPaths.claudeVersions] + ctx.aiPaths.codexPackageRoots + ctx.aiPaths.cursorAgentRoots.map(\.versions)
        if versionFolders.contains(where: { path.hasPrefix($0 + "/") }), let version = ctx.cliVersion(path) {
            if let keep = version.keepReason { return DiskTreeVerdict([.aiData, .regenerable], "\(version.tool) \(version.version) — \(keep)", [.reveal]) }
            return DiskTreeVerdict([.aiData, .regenerable], "\(version.tool) 이전 버전 \(version.version) — \(version.regeneration)", [.reveal, .deletePermanently])
        }
        if let root = aiRoots.first(where: under) {
            let cache = AIAppCacheCatalog.libraryCaches.contains { "Library/Caches/" + $0.name == root }
            return DiskTreeVerdict(cache ? [.aiData, .cache] : [.aiData], cache ? "AI 앱 캐시 안 — 캐시 폴더째로 비웁니다" : "AI 도구 데이터 — 그 도구나 AI 데이터 화면에서 정리합니다", [.reveal])
        }
        return nil
    }

    static func trash(_ path: String, name: String, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        let folder = ctx.settings.trashFolder
        if path == folder { return DiskTreeVerdict([.trash], "휴지통 — 비우기는 Finder에서 직접 합니다(ReMON은 휴지통을 비우지 않습니다)", [.reveal]) }
        guard path.hasPrefix(folder + "/") else { return nil }
        let rest = path.dropFirst(folder.count + 1)
        guard !rest.contains("/") else { return DiskTreeVerdict([.trash], "휴지통 안의 항목 — 되돌리기·비우기는 Finder에서 합니다", [.reveal]) }
        let origin = ctx.putBack()[name]
        var hint = "휴지통 안 · 원래 위치: \(origin?.folder.map { $0.replacingOccurrences(of: ctx.home, with: "~") } ?? "알 수 없음")"
        if let original = origin?.name, original != name { hint += " · 휴지통 안 이름: \(name)" }
        hint += " — 되돌리기(되돌려 놓기)·비우기는 Finder에서 합니다"
        return DiskTreeVerdict([.trash], hint, [.reveal], name: origin?.name)
    }

    static func secret(_ rel: String) -> DiskTreeVerdict? {
        guard secrets.contains(where: { rel == $0 || rel.hasPrefix($0 + "/") }) else { return nil }
        return DiskTreeVerdict([.userFile], "자격 증명·키 — ReMON은 내용을 읽지도 옮기지도 않습니다", [.reveal])
    }

    static func git(_ path: String, name: String, isDirectory: Bool, isBundle: Bool, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        guard isDirectory, !isBundle else { return nil }
        if name == ".git" { return DiskTreeVerdict([.gitByproduct], "git 저장소 데이터 — 파일을 옮기면 저장소가 깨집니다(줄이려면 git gc)", [.reveal]) }
        var info = stat()
        guard lstat(path + "/.git", &info) == 0 else { return nil }
        // 저장소 자체(.git 폴더가 있음)는 통째로 옮기지 않는다 — 올리지 않은 커밋·변경이 있을 수 있다.
        if (info.st_mode & S_IFMT) == S_IFDIR {
            return DiskTreeVerdict([.userFile], "git 저장소 — 통째로 옮기지 않습니다(안쪽 빌드 산출물·워크트리만 골라 정리합니다)", [.reveal])
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        guard let item = ctx.leftover(path) else {
            return DiskTreeVerdict([.gitByproduct], "git 워크트리 — 부산물 조사 전이라 정리 판정이 없습니다(묶음 보기에서 조사합니다)", [.reveal])
        }
        if item.isMain { return nil }
        switch item.verdict {
        case .cleanable(let action) where action == .removeWorktree || action == .orcaRemoveWorktree:
            let manager = action == .orcaRemoveWorktree ? "Orca 작업 공간" : "git 워크트리"
            return DiskTreeVerdict([.gitByproduct], "\(manager) · 정리 가능(병합됨 · 커밋 안 된 변경 없음) — 지우면 커밋을 금고에 적어 두고 같은 커밋으로 되살립니다"
                                   + "(무시된 node_modules 등은 다시 설치)", [.reveal, .trash])
        case .cleanable:
            return DiskTreeVerdict([.gitByproduct], "git 워크트리 · 끊긴 기록 — 묶음 보기에서 정리합니다", [.reveal])
        case .keep(let reason):
            return DiskTreeVerdict([.gitByproduct], "git 워크트리 · 보존: \(reason)", [.reveal])
        }
    }

    static func xcode(_ path: String, rel: String, isDirectory: Bool, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        let archives = "Library/Developer/Xcode/Archives", devices = "Library/Developer/CoreSimulator/Devices"
        if rel == archives { return DiskTreeVerdict([.xcode, .userFile], "Xcode 아카이브 묶음 — 배포 원본·충돌 기호(dSYM)입니다. 필요 없는 것만 골라 휴지통으로 옮깁니다", [.reveal, .trash]) }
        if rel.hasPrefix(archives + "/") {
            return DiskTreeVerdict([.xcode, .userFile], "Xcode 아카이브 — 배포 원본·충돌 기호(dSYM)입니다. 필요 없으면 휴지통으로 옮길 수 있습니다(되돌리기 가능)", [.reveal, .trash])
        }
        guard rel.hasPrefix(devices + "/") else { return nil }
        let rest = rel.dropFirst(devices.count + 1)
        guard !rest.contains("/"), isDirectory else { return DiskTreeVerdict([.xcode], "시뮬레이터 기기 안 — 기기째로 다룹니다", [.reveal]) }
        guard let device = SimulatorDevice.read(path) else { return DiskTreeVerdict([.xcode], "시뮬레이터 기기 폴더(정보 없음) — 보기만 합니다", [.reveal]) }
        let label = device.runtime.isEmpty ? device.name : "\(device.name) · \(device.runtime)"
        if device.booted { return DiskTreeVerdict([.xcode], "실행 중인 시뮬레이터 — 끈 뒤 정리합니다", [.reveal], name: label) }
        let reference = device.lastBooted ?? device.created
        let age = ctx.days(since: reference)
        let when = device.lastBooted == nil ? "부팅한 적 없음 · 만든 지 \(age)일" : "마지막 부팅 \(age)일 전"
        if Double(age) >= ctx.settings.simulatorIdleDays {
            return DiskTreeVerdict([.xcode, .regenerable], "시뮬레이터 기기 · \(when) — 휴지통으로 옮기면 Xcode 목록에서 빠집니다(필요하면 Xcode에서 다시 만듭니다)",
                                   [.reveal, .trash], name: label)
        }
        return DiskTreeVerdict([.xcode], "시뮬레이터 기기 · \(when) — 최근 \(Int(ctx.settings.simulatorIdleDays))일 안이라 그대로 둡니다", [.reveal], name: label)
    }

    /// 표 항목: A → 캐시(영구 삭제, 주인이 꺼져 있을 때) · B → 다시 만들 수 있음(쉬는 것만 영구 삭제) · C → 보기만. inherited: 표 항목 안쪽의 칸.
    static func catalog(_ match: CatalogMatch, path: String, bytes: UInt64, modified: Date?, inherited: Bool, _ ctx: DiskTreeContext) -> DiskTreeVerdict {
        var tags: Set<DiskTag>
        switch match.grade {
        case .a: tags = [.cache]
        case .b: tags = [.regenerable]
        case .c: tags = match.entry.id.hasPrefix("models.") ? [.regenerable] : [.cache]
        }
        if match.entry.group == .xcode || match.entry.group == .simulators { tags.insert(.xcode) }
        if match.entry.group == .homebrew { tags.insert(.homebrew) }
        let hint = (inherited ? "\(match.note) 안 — " : "\(match.note) — ") + match.hint
        if match.grade == .c { return DiskTreeVerdict(tags, hint, [.none]) }
        let item = match.item(path: path, bytes: bytes, modified: modified, running: ctx.running)
        if let skip = item.skipReason { return DiskTreeVerdict(tags, hint + " · " + skip, [.reveal]) }
        if inherited {
            // 안쪽 조각: 순수 캐시는 조각도 영구 삭제할 수 있고, 그 밖은 휴지통만(정책은 표 항목째로 본다).
            return match.grade == .a && match.entry.command == nil && !match.entry.trashPreferred && !match.entry.defaultExcluded
                ? DiskTreeVerdict(tags, hint, [.reveal, .deletePermanently]) : DiskTreeVerdict(tags, hint, [.reveal, .trash])
        }
        if let command = match.entry.command { return DiskTreeVerdict(tags, hint + " · '\(command.title)' 명령으로 정리합니다", [.reveal, .prune]) }
        switch CacheDeletionPolicy.tier(for: item, activeDirectories: ctx.activeDirectories, now: ctx.now, running: ctx.running) {
        case .pureCache:
            return DiskTreeVerdict(tags, hint, [.reveal, .deletePermanently])
        case .rebuildable:
            return DiskTreeVerdict(tags, hint + " · 쉬는 중이라 영구 삭제할 수 있습니다", [.reveal, .trash, .deletePermanently])
        case .trashOnly:
            if let reason = CacheDeletionPolicy.blockReason(for: item, running: ctx.running) { return DiskTreeVerdict(tags, hint + " · " + reason, [.reveal]) }
            let why = match.entry.trashPreferred ? "다시 생기지 않는 상태가 섞여 휴지통으로만 옮깁니다"
                : match.entry.defaultExcluded ? "기본 제외 항목 — 직접 고를 때만 휴지통으로 옮깁니다" : "최근에 쓰였거나 작업 중이라 휴지통으로만 옮깁니다"
            return DiskTreeVerdict(tags, hint + " · " + why, [.reveal, .trash])
        }
    }

    /// 표 항목의 안쪽(펼쳐 들어간 캐시 안): 가장 가까운 위 항목의 판정을 물려받는다.
    static func inheritedCatalog(_ path: String, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > ctx.home.count, parent.hasPrefix(ctx.home + "/") {
            if let match = ctx.catalogMatch(parent) { return catalog(match, path: path, bytes: 0, modified: nil, inherited: true, ctx) }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// 프로젝트 빌드 산출물: .build · DerivedData · node_modules는 B(쉬는 것만 영구 삭제), 그 밖의 재생성 이름은 휴지통만.
    static func projectArtifact(_ path: String, rel: String, name: String, isDirectory: Bool, bytes: UInt64, modified: Date?, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        guard isDirectory, rel.contains("/"), !rel.hasPrefix("Library/") else { return nil }
        switch name {
        case ".build", ".build-test", "DerivedData", "node_modules":
            let id = name == "node_modules" ? "project.node_modules" : "project.build"
            var item = DiskItem(path: path, category: .regenerable, bytes: bytes, modified: modified, note: "빌드 산출물", grade: .b, entryID: id)
            item.hint = CacheDeletionPolicy.regenerationHint(for: item)
            let hint = "빌드 산출물 — " + (item.hint ?? "다시 만들어집니다")
            switch CacheDeletionPolicy.tier(for: item, activeDirectories: ctx.activeDirectories, now: ctx.now, running: ctx.running) {
            case .rebuildable, .pureCache:
                return DiskTreeVerdict([.regenerable], hint + " · 쉬는 중이라 영구 삭제할 수 있습니다", [.reveal, .trash, .deletePermanently])
            case .trashOnly:
                return DiskTreeVerdict([.regenerable], hint + " · 최근에 바뀌었거나 작업 중(또는 잠금 파일 없음)이라 휴지통으로만 옮깁니다", [.reveal, .trash])
            }
        default:
            guard IgnoredFiles.regenerableNames.contains(name) else { return nil }
            return DiskTreeVerdict([.regenerable], "다시 만들 수 있는 빌드·캐시 폴더(\(name)) — 휴지통으로 옮겨도 도구가 다시 만듭니다", [.reveal, .trash])
        }
    }

    static func homebrew(_ rel: String, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        if rel == "Library/Caches/Homebrew" {
            return DiskTreeVerdict([.homebrew, .cache], "Homebrew 캐시 — 'brew cleanup --prune=all'이 옛 버전·받아 둔 설치 파일을 직접 지웁니다(미리보기를 본 뒤 확인하고 실행)",
                                   [.reveal, .prune])
        }
        if rel.hasPrefix("Library/Caches/Homebrew/") { return DiskTreeVerdict([.homebrew, .cache], "Homebrew 캐시 안 — brew cleanup으로 정리합니다", [.reveal]) }
        return nil
    }

    static func docker(_ rel: String, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        if let disk = dockerDisks.first(where: { rel == $0.relative || rel.hasPrefix($0.relative + "/") }) {
            var hint = "\(disk.title) — 이미지·컨테이너가 든 가상 디스크입니다. 파일을 직접 지우면 깨지니 \(disk.manage)"
            if disk.relative == ".colima", rel == ".colima" {
                let external = [".colima/_lima/colima/disk", ".colima/_lima/_disks/colima/datadisk"]
                    .compactMap { try? FileManager.default.destinationOfSymbolicLink(atPath: ctx.home + "/" + $0) }.filter { $0.hasPrefix("/Volumes/") }
                if let first = external.first { hint += " · 기본 프로필 디스크는 외장 볼륨(\((first as NSString).deletingLastPathComponent))에 있습니다" }
            }
            return DiskTreeVerdict([.docker], hint, [.none])
        }
        if rel == ".docker" || rel.hasPrefix(".docker/") { return DiskTreeVerdict([.docker], "Docker 설정·컨텍스트 — 지우지 않습니다", [.reveal]) }
        return nil
    }

    static func backup(_ path: String, rel: String, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        let mobile = "Library/Application Support/MobileSync"
        guard rel == mobile || rel.hasPrefix(mobile + "/") else { return nil }
        let backups = mobile + "/Backup"
        if rel == backups { return DiskTreeVerdict([.backup], "iPhone·iPad 백업 — 기기별로 고릅니다(Finder › 기기 › 백업 관리와 같습니다)", [.reveal]) }
        guard rel.hasPrefix(backups + "/") else { return DiskTreeVerdict([.backup], "기기 백업 묶음 — 보기만 합니다", [.reveal]) }
        guard !rel.dropFirst(backups.count + 1).contains("/") else { return DiskTreeVerdict([.backup], "백업 안의 파일 — 백업째로 다룹니다", [.reveal]) }
        let info = DeviceBackup.read(path)
        let device = info.map { backup in backup.product.map { "\(backup.deviceName)(\($0))" } ?? backup.deviceName } ?? "기기"
        let when = info?.lastBackup.map { "마지막 백업 \(ctx.days(since: $0))일 전" } ?? "백업 날짜 모름"
        return DiskTreeVerdict([.backup], "\(device) 백업 · \(when) — 휴지통으로 옮기면 Finder 기기 목록에서 빠집니다(비우기 전까지 되돌릴 수 있음). "
                               + "다른 백업이 있는지 먼저 확인하세요", [.reveal, .trash], name: info?.deviceName)
    }

    static func download(_ path: String, isFileLike: Bool, bytes: UInt64, modified: Date?, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        let folder = ctx.settings.downloadsFolder
        if path == folder { return DiskTreeVerdict([.download], "다운로드 폴더 — 오래되고 큰 파일부터 고릅니다", [.reveal]) }
        guard path.hasPrefix(folder + "/") else { return nil }
        let age = ctx.days(since: modified)
        if isFileLike, bytes > ctx.settings.downloadMinimumBytes, Double(age) > ctx.settings.downloadAgeDays {
            return DiskTreeVerdict([.download, .large], "받은 지 \(age)일 · \(Fmt.size(bytes)) — 다시 받을 수 있는 설치 파일·압축 파일이면 휴지통으로 옮겨도 됩니다", [.reveal, .trash])
        }
        return DiskTreeVerdict([.download, .userFile], "다운로드한 파일 — 직접 고를 때만 휴지통으로 옮깁니다(되돌리기 가능)", [.reveal, .trash])
    }

    /// 시스템 데이터의 '보기만' 덩어리(가상 머신 · iCloud 로컬 사본 · 관리자 권한 캐시). 그 도구·앱에서 줄인다.
    static func holder(_ path: String, _ ctx: DiskTreeContext) -> DiskTreeVerdict? {
        guard let holder = ctx.holders.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) else { return nil }
        return DiskTreeVerdict([.system], "\(holder.title) — \(holder.manage)", [.none])
    }

    static func library(_ rel: String, _ ctx: DiskTreeContext) -> DiskTreeVerdict {
        let parts = rel.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return DiskTreeVerdict([.system], "앱·macOS 데이터 폴더(~/Library) — 통째로 다루지 않습니다", [.reveal]) }
        let area = parts[1]
        if area == "Mobile Documents" || area == "CloudStorage" { return DiskTreeVerdict([.userFile], cloudHint, [.reveal]) }
        if parts.count == 2 {
            switch area {
            case "Caches": return DiskTreeVerdict([.cache], "앱 캐시 묶음 — 안쪽 항목별로 정리합니다", [.reveal])
            case "Logs": return DiskTreeVerdict([], "로그 묶음 — 오래된 로그부터 정리합니다", [.reveal])
            case "Developer": return DiskTreeVerdict([.xcode], "Xcode·개발 도구 데이터 묶음", [.reveal])
            default: return DiskTreeVerdict([.system], "macOS·앱이 관리하는 폴더 — 통째로 옮기지 않습니다", [.reveal])
            }
        }
        let item = parts[2]
        switch area {
        case "Application Support":
            if item.hasPrefix("com.apple.") || appleSupportNames.contains(item) { return DiskTreeVerdict([.system], "macOS가 쓰는 데이터 — 보기만 합니다", [.reveal]) }
            let owner = DiskScanner.folderOwner(item)
            if ctx.running.isRunning(owner) { return DiskTreeVerdict([.userFile], "\(item) 실행 중 — 앱을 끈 뒤 정리합니다", [.reveal]) }
            // 설치된 앱의 데이터(브라우저 프로필 · 로그인 정보 등)는 그 앱이 관리한다 — 지운 앱의 찌꺼기만 휴지통으로.
            if ctx.appInstalled(item) { return DiskTreeVerdict([.userFile], "설치된 앱(\(item))의 데이터 — 그 앱 안에서 정리하거나 앱을 지운 뒤 정리합니다", [.reveal]) }
            if parts.count > 3 { return DiskTreeVerdict([.userFile], "\(item) 앱 데이터 안(설치된 앱을 찾지 못함) — 직접 고를 때만 휴지통으로 옮깁니다(되돌리기 가능)", [.reveal, .trash]) }
            return DiskTreeVerdict([.userFile], "설치된 앱을 찾지 못한 앱 데이터 — 지운 앱이 남긴 찌꺼기일 수 있습니다. 휴지통으로 옮기면 되돌릴 수 있습니다", [.reveal, .trash])
        case "Containers", "Group Containers":
            if item.hasPrefix("com.apple.") || item.contains(".com.apple.") || item.hasPrefix("group.com.apple.") {
                return DiskTreeVerdict([.system], "macOS 앱의 보관함 데이터 — 보기만 합니다", [.reveal])
            }
            // 묶음 보관함 이름은 팀 접두(10자) · 'group.'이 붙는다 — 떼어 낸 번들 id로도 실행 중인지 본다.
            var identifiers = [item]
            let pieces = item.split(separator: ".", maxSplits: 1).map(String.init)
            if pieces.count == 2, pieces[0].count == 10, pieces[0].allSatisfy({ $0.isUppercase || $0.isNumber }) { identifiers.append(pieces[1]) }
            if item.hasPrefix("group.") { identifiers.append(String(item.dropFirst("group.".count))) }
            if ctx.running.isRunning(CacheOwner(item, bundleIDs: identifiers)) { return DiskTreeVerdict([.userFile], "\(item) 실행 중 — 앱을 끈 뒤 정리합니다", [.reveal]) }
            if ctx.appInstalled(item) { return DiskTreeVerdict([.userFile], "설치된 앱의 보관함(\(item)) — 그 앱 안에서 정리하거나 앱을 지운 뒤 정리합니다", [.reveal]) }
            if parts.count > 3 { return DiskTreeVerdict([.userFile], "앱 보관함(\(item)) 안(설치된 앱을 찾지 못함) — 직접 고를 때만 휴지통으로 옮깁니다(되돌리기 가능)", [.reveal, .trash]) }
            return DiskTreeVerdict([.userFile], "설치된 앱을 찾지 못한 앱 보관함(샌드박스) 데이터 — 지운 앱이 남긴 찌꺼기일 수 있습니다. 휴지통으로 옮기면 되돌릴 수 있습니다", [.reveal, .trash])
        case "Caches":
            return DiskTreeVerdict([.cache], "캐시 묶음 안 — 항목별 판정이 없는 곳은 보기만 합니다", [.reveal])
        case "Logs":
            if item == "ReMON" { return DiskTreeVerdict([.system], "ReMON 기록(행동·감사 로그) — 지우지 않습니다", [.reveal]) }
            return DiskTreeVerdict([.regenerable], "앱 로그 — 30일 넘게 안 쓰이면 정리 대상입니다(지워도 다시 생깁니다)", [.reveal, .trash])
        case "Developer":
            return DiskTreeVerdict([.xcode, .userFile], "Xcode·개발 도구 데이터 — 직접 고를 때만 휴지통으로 옮깁니다", [.reveal, .trash])
        case "Preferences":
            if item.hasPrefix("com.apple.") || item.hasPrefix(".GlobalPreferences") || item == "ByHost" || item.hasPrefix("loginwindow") {
                return DiskTreeVerdict([.system], "macOS 설정 — 지우지 않습니다", [.reveal])
            }
            let identifier = item.hasSuffix(".plist") ? String(item.dropLast(6)) : item
            if ctx.running.isRunning(CacheOwner(identifier, bundleIDs: [identifier])) { return DiskTreeVerdict([.userFile], "실행 중인 앱의 설정 — 앱을 끈 뒤 정리합니다", [.reveal]) }
            if ctx.appInstalled(identifier) { return DiskTreeVerdict([.userFile], "설치된 앱의 설정 — 그 앱에서 바꿉니다", [.reveal]) }
            return DiskTreeVerdict([.userFile], "설치된 앱을 찾지 못한 설정 파일 — 지운 앱이 남긴 찌꺼기일 수 있습니다(휴지통으로 옮기면 되돌릴 수 있음)", [.reveal, .trash])
        case "Saved Application State":
            return DiskTreeVerdict([.regenerable], "창 복원 상태 — 지워도 됩니다(앱이 다시 만듭니다)", [.reveal, .trash])
        case "LaunchAgents":
            return DiskTreeVerdict([.system], "로그인 때 실행되는 항목 — 시작 항목 화면에서 관리합니다", [.reveal])
        case "pnpm", "org.swift.swiftpm":
            return DiskTreeVerdict([.userFile], "개발 도구 데이터 — 직접 고를 때만 휴지통으로 옮깁니다", [.reveal, .trash])
        default:
            if addOnAreas.contains(area) { return DiskTreeVerdict([.userFile], "사용자가 설치한 추가 기능 — 휴지통으로 옮기면 그 기능이 빠집니다", [.reveal, .trash]) }
            return DiskTreeVerdict([.system], "macOS·앱이 관리하는 데이터 — 보기만 합니다", [.reveal])
        }
    }

    static func homeTop(_ name: String, isFolder: Bool) -> DiskTreeVerdict {
        if isFolder {
            if standardFolders.contains(name) { return DiskTreeVerdict([.userFile], "홈 최상위 폴더 — 통째로 옮기지 않고 안쪽 항목만 고릅니다", [.reveal]) }
            if name.hasPrefix(".") { return DiskTreeVerdict([], "도구 폴더 — 안쪽 캐시만 골라 정리합니다", [.reveal]) }
            return DiskTreeVerdict([.userFile], "홈 최상위 폴더 — 통째로 옮기지 않고 안쪽 항목만 고릅니다", [.reveal])
        }
        if name.hasPrefix(".") { return DiskTreeVerdict([.userFile], "셸·도구 설정 파일 — 옮기지 않습니다", [.reveal]) }
        return DiskTreeVerdict([.userFile], userFileHint, [.reveal, .trash])
    }
}
