import Darwin
import Foundation

public enum DiskCategory: String, Sendable, CaseIterable, Codable {
    case regenerable, temporary, trash, aiLogs, bigDatabase, keep

    public var label: String {
        switch self {
        case .regenerable: "재생성 캐시"
        case .temporary: "임시 파일"
        case .trash: "휴지통"
        case .aiLogs: "오래된 AI 기록"
        case .bigDatabase: "큰 DB"
        case .keep: "기본 제외·보기만"
        }
    }

    public var actionHint: String {
        switch self {
        case .regenerable: "휴지통으로 옮겨도 다시 빌드·설치하면 생깁니다"
        case .temporary: "열린 파일이 없고 3일 지난 것만"
        case .trash: "비우기는 기본 꺼짐 — Finder에서 직접 비우세요"
        case .aiLogs: "삭제가 아니라 외장 이전 대상"
        case .bigDatabase: "크기만 보여 주고 손대지 않습니다"
        case .keep: "묶음 정리에서 빠집니다 — 크기만 보여 줍니다"
        }
    }
}

/// 카탈로그 등급. A = 순수 캐시(영구 삭제해도 도구가 다시 받음) · B = 다시 빌드·설치해야 생김 · C = 지우지 않음(보기만).
public enum DiskGrade: String, Sendable, Codable, CaseIterable, Comparable {
    case a = "A", b = "B", c = "C"

    public var label: String {
        switch self {
        case .a: "순수 캐시"
        case .b: "다시 만들 수 있음"
        case .c: "보기만"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 캐시 주인: 앱 번들 id · 실행 파일 이름 · node/ruby/java 실행 인자 속 표지. 주인이 실행 중이면 그 캐시는 건너뛴다.
public struct CacheOwner: Sendable, Equatable, Hashable {
    public var name: String
    public var bundleIDs: [String]
    public var processNames: [String]
    /// 스크립트로 도는 도구(npm·yarn·Gradle 데몬 등)는 실행 파일이 node·java라 실행 인자로 알아본다.
    public var commandMarkers: [String]
    /// 실행 중인 .app 번들 이름(소문자, '.app' 뺌)으로 알아보는 앱(Electron 앱 폴더 이름 ↔ 번들 이름).
    public var appNames: [String]

    public init(_ name: String, bundleIDs: [String] = [], processNames: [String] = [], commandMarkers: [String] = [], appNames: [String] = []) {
        self.name = name
        self.bundleIDs = bundleIDs
        self.processNames = processNames
        self.commandMarkers = commandMarkers
        self.appNames = appNames
    }
}

public struct DiskItem: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var category: DiskCategory
    public var bytes: UInt64
    public var modified: Date?
    public var note: String
    public var permissionNeeded: Bool = false
    /// 카탈로그 등급. nil = 등급 없는 기존 항목(정책이 경로·이름으로 추정한다).
    public var grade: DiskGrade? = nil
    /// 실행 중이면 건너뛸 앱·프로세스.
    public var owner: CacheOwner? = nil
    /// 기본 제외: 묶음·자동 정리에서 빠지고, 하나씩 직접 고를 때만 휴지통으로.
    public var defaultExcluded: Bool = false
    /// 카탈로그 항목 id(화면 묶음 · 권장 명령 · 정책 예외).
    public var entryID: String? = nil
    /// 다시 생기는 방법(영구 삭제 시 금고에 남긴다).
    public var hint: String? = nil
    /// 조사 시점에 건너뛴 이유(주인 앱 실행 중 등). 정리 직전에 다시 확인한다.
    public var skipReason: String? = nil

    public init(path: String, category: DiskCategory, bytes: UInt64, modified: Date?, note: String, permissionNeeded: Bool = false) {
        self.path = path
        self.category = category
        self.bytes = bytes
        self.modified = modified
        self.note = note
        self.permissionNeeded = permissionNeeded
    }

    public init(path: String, category: DiskCategory, bytes: UInt64, modified: Date?, note: String, grade: DiskGrade?, owner: CacheOwner? = nil,
                defaultExcluded: Bool = false, entryID: String? = nil, hint: String? = nil, skipReason: String? = nil, permissionNeeded: Bool = false) {
        self.init(path: path, category: category, bytes: bytes, modified: modified, note: note, permissionNeeded: permissionNeeded)
        self.grade = grade
        self.owner = owner
        self.defaultExcluded = defaultExcluded
        self.entryID = entryID
        self.hint = hint
        self.skipReason = skipReason
    }
}

// MARK: - 실행 중인 앱(캐시 주인 판정)

/// 지금 실행 중인 사용자 프로세스 요약. 번들 id는 실행 파일이 든 가장 바깥 .app의 Info.plist에서 읽는다(AppKit 없이).
public struct RunningApps: Sendable, Equatable {
    public var bundleIDs: Set<String>
    public var processNames: Set<String>
    /// node·ruby·java·python·셸 프로세스의 실행 인자 한 줄. 메모리에서 표지 비교에만 쓰고 기록하지 않는다.
    public var commandLines: [String]
    /// 실행 중인 프로세스가 속한 바깥 .app 번들 이름(소문자, '.app' 뺌)
    public var appNames: Set<String>

    public init(bundleIDs: Set<String> = [], processNames: Set<String> = [], commandLines: [String] = [], appNames: Set<String> = []) {
        self.bundleIDs = bundleIDs
        self.processNames = processNames
        self.commandLines = commandLines
        self.appNames = appNames
    }

    /// 아무것도 실행 중이지 않음(시험·판정 끄기). Optional.none과 헷갈리지 않게 이름을 달리한다.
    public static let empty = RunningApps()

    public func isRunning(_ owner: CacheOwner) -> Bool {
        if owner.bundleIDs.contains(where: bundleIDs.contains) { return true }
        if owner.processNames.contains(where: processNames.contains) { return true }
        if owner.appNames.contains(where: { appNames.contains($0.lowercased()) }) { return true }
        guard !owner.commandMarkers.isEmpty else { return false }
        return commandLines.contains { line in owner.commandMarkers.contains { line.contains($0) } }
    }

    static let interpreters: Set<String> = ["node", "ruby", "java", "python", "python3", "Python", "bash", "sh", "zsh", "dash", "perl"]

    public static func live() -> RunningApps {
        let uid = getuid()
        var result = RunningApps()
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for info in ProcessSampler.allKinfo() where info.kp_eproc.e_ucred.cr_uid == uid && info.kp_proc.p_pid > 0 {
            let pid = info.kp_proc.p_pid
            let comm = ProcessSampler.comm(info)
            if !comm.isEmpty { result.processNames.insert(comm) }
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            let path = length > 0 ? String(cString: buffer) : ""
            let executable = path.isEmpty ? comm : (path as NSString).lastPathComponent
            result.processNames.insert(executable)
            if let id = bundleID(forExecutable: path) { result.bundleIDs.insert(id) }
            if let range = path.range(of: ".app/") {
                result.appNames.insert((String(path[..<range.lowerBound]) as NSString).lastPathComponent.lowercased())
            }
            if interpreters.contains(executable) || interpreters.contains(comm) || executable.hasPrefix("python") {
                if let argv = ProcessSampler.readArguments(pid: pid)?.argv, argv.count > 1 {
                    result.commandLines.append(String(argv.joined(separator: " ").prefix(4096)))
                }
            }
        }
        return result
    }

    /// 몇 초 안의 조사 결과를 다시 쓴다(정책이 항목마다 부를 때 프로세스 목록을 매번 읽지 않게).
    public static func recent(maxAge: TimeInterval = 3) -> RunningApps {
        recentBox.value(maxAge: maxAge)
    }

    private static let recentBox = RecentBox()
    private static let bundleCache = BundleCache()

    /// …/Foo.app/Contents/… → Foo.app의 CFBundleIdentifier(번들마다 한 번만 읽는다).
    static func bundleID(forExecutable path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return bundleCache.identifier(for: String(path[..<range.lowerBound]) + ".app")
    }

    private final class RecentBox: @unchecked Sendable {
        private let lock = NSLock()
        private var at = Date.distantPast
        private var cached = RunningApps()
        func value(maxAge: TimeInterval) -> RunningApps {
            lock.lock(); defer { lock.unlock() }
            if Date().timeIntervalSince(at) > maxAge { cached = RunningApps.live(); at = Date() }
            return cached
        }
    }

    private final class BundleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        private var missing: Set<String> = []
        func identifier(for bundle: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            if let value = values[bundle] { return value }
            if missing.contains(bundle) { return nil }
            let value = NSDictionary(contentsOfFile: bundle + "/Contents/Info.plist")?["CFBundleIdentifier"] as? String
            if let value { values[bundle] = value } else { missing.insert(bundle) }
            return value
        }
    }
}

// MARK: - 조사기

/// 정리 화면용 디스크 조사. 크기는 실제 할당량(st_blocks×512)으로 잰다(Foundation 열거의 누락 함정 회피).
/// 개발 캐시는 DiskCatalog 표(경로 · 등급 · 주인 · 기본 제외 · 재생성 방법)대로 찾는다.
public final class DiskScanner: @unchecked Sendable {
    public let home: String
    public var searchRoots: [String]
    public var maxDepth = 4
    public var tempAgeDays: Double = 3
    public var logAgeDays: Double = 14
    /// 이보다 작은 카탈로그 항목은 목록에 올리지 않는다(빈 캐시 폴더 소음). 시험에서는 0.
    public var minimumBytes: UInt64 = 1_048_576
    /// 진단 보고서처럼 작은 파일이 많은 항목은 한 번에 이만큼만 올린다(큰 것부터).
    public var maxOldFiles = 100
    /// 개발 캐시 표(시험에서 항목을 더한다).
    public var catalog: [CatalogEntry] = DiskCatalog.entries
    /// 실행 중인 앱 조사(시험에서 가짜로 바꾼다).
    public var runningProbe: @Sendable () -> RunningApps = { RunningApps.live() }
    var cancelled = false

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.home = home
        searchRoots = ["DEV", "orca/workspaces", ".codex/worktrees"].map { home + "/" + $0 }
    }

    public func cancel() { cancelled = true }

    /// activeDirectories: 지금 세션·프로세스가 쓰는 작업 폴더(그 아래 node_modules는 '쉬는 워크트리'가 아니므로 제외).
    public func scan(activeDirectories: Set<String>, now: Date = Date()) -> [DiskItem] {
        Self.withoutMaterializing { scanItems(activeDirectories: activeDirectories, now: now) }
    }

    private func scanItems(activeDirectories: Set<String>, now: Date) -> [DiskItem] {
        cancelled = false
        var items: [DiskItem] = []
        for root in searchRoots where FileManager.default.fileExists(atPath: root) {
            findCaches(in: root, depth: 0, active: activeDirectories, into: &items)
            if cancelled { return items }
        }
        items += catalogItems(running: runningProbe(), now: now)
        if cancelled { return items }
        for directory in ["/private/tmp", NSTemporaryDirectory()] {
            items += oldEntries(in: directory, olderThan: tempAgeDays, category: .temporary, note: "임시", now: now)
        }
        let trash = home + "/.Trash"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: trash) {
            let bytes = names.reduce(UInt64(0)) { $0 + Self.allocatedSize(trash + "/" + $1) }
            items.append(DiskItem(path: trash, category: .trash, bytes: bytes, modified: nil, note: "\(names.count)개 항목"))
        } else {
            items.append(DiskItem(path: trash, category: .trash, bytes: 0, modified: nil, note: "전체 디스크 접근 권한 필요", permissionNeeded: true))
        }
        items += aiLogs(now: now)
        let codex = home + "/.codex"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: codex) {
            for name in names where name.hasSuffix(".sqlite") {
                let path = codex + "/" + name
                let bytes = Self.allocatedSize(path) + Self.allocatedSize(path + "-wal") + Self.allocatedSize(path + "-shm")
                if bytes > 50 * 1_048_576 {
                    items.append(DiskItem(path: path, category: .bigDatabase, bytes: bytes, modified: Self.modified(path), note: "Codex DB · 손대지 않음", grade: .c, hint: "Codex가 쓰는 DB입니다 — 지우지 않습니다"))
                }
            }
        }
        return Self.unique(items).sorted { $0.bytes > $1.bytes }
    }

    /// 같은 경로가 두 번 잡히면 먼저 잡힌 것만 남긴다(목록 id = 경로).
    static func unique(_ items: [DiskItem]) -> [DiskItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.path).inserted }
    }

    private func findCaches(in directory: String, depth: Int, active: Set<String>, into items: inout [DiskItem]) {
        guard depth <= maxDepth, !cancelled, let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for name in names {
            let path = directory + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            switch name {
            case ".build", ".build-test", "DerivedData":
                let isXcode = name == "DerivedData"
                items.append(DiskItem(path: path, category: .regenerable, bytes: Self.allocatedSize(path), modified: Self.modified(path), note: "빌드 산출물",
                                      grade: .b, entryID: "project.build", hint: isXcode ? "Xcode가 다음 빌드 때 다시 만듭니다" : "swift build로 다시 생깁니다"))
            case "node_modules":
                let project = directory
                let busy = active.contains { $0 == project || $0.hasPrefix(project + "/") || project.hasPrefix($0 + "/") }
                if !busy {
                    items.append(DiskItem(path: path, category: .regenerable, bytes: Self.allocatedSize(path), modified: Self.modified(path), note: "쉬는 워크트리의 node_modules",
                                          grade: .b, entryID: "project.node_modules", hint: "프로젝트 폴더에서 npm/pnpm/yarn install로 다시 생깁니다"))
                }
            case ".git", ".swiftpm", "Pods":
                continue
            default:
                if name.hasPrefix(".") && name != ".scratch" { continue }
                autoreleasepool { findCaches(in: path, depth: depth + 1, active: active, into: &items) }
            }
        }
    }

    private func oldEntries(in directory: String, olderThan days: Double, category: DiskCategory, note: String, now: Date) -> [DiskItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        var items: [DiskItem] = []
        for name in names {
            // 시스템 데몬의 임시 폴더(com.apple.*)는 실행 중인 서비스가 쓴다 — 후보에서 뺀다(10-25 검토: fileproviderd).
            if name.hasPrefix("com.apple.") { continue }
            let path = (directory as NSString).appendingPathComponent(name)
            guard let modified = Self.modified(path), now.timeIntervalSince(modified) > days * 86_400 else { continue }
            // 맨 위 시각만 보면 안쪽이 방금 바뀐 폴더를 놓친다 → 안쪽 가장 최근 수정 시각으로 다시 본다(최대 2,000개).
            guard Self.newestModified(path, limit: 2_000, newerThan: now.addingTimeInterval(-days * 86_400)) == nil else { continue }
            let bytes = Self.allocatedSize(path)
            if bytes >= 10 * 1_048_576 {
                items.append(DiskItem(path: path, category: category, bytes: bytes, modified: modified, note: note,
                                      grade: .a, entryID: "temp.old", hint: "3일 넘은 임시 파일(휴지통으로만 옮깁니다 · macOS도 재시동 때 지웁니다)"))
            }
        }
        return items
    }

    /// 폴더 안에서 기준보다 최근에 바뀐 항목이 있으면 그 시각(없으면 nil). 개수 제한을 넘기면 '최근'으로 본다(보수적).
    static func newestModified(_ root: String, limit: Int, newerThan threshold: Date) -> Date? {
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.contentModificationDateKey], options: [], errorHandler: { _, _ in true }) else { return nil }
        var seen = 0
        for case let url as URL in enumerator {
            seen += 1
            if seen > limit { return Date() }
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date > threshold { return date }
        }
        return nil
    }

    /// 오래된 Codex rollout(월 폴더 단위)과 Claude 기록(프로젝트 폴더 단위 합계). 외장 이전 후보 — 지우지 않는다(C).
    private func aiLogs(now: Date) -> [DiskItem] {
        var items: [DiskItem] = []
        let sessions = home + "/.codex/sessions"
        for year in (try? FileManager.default.contentsOfDirectory(atPath: sessions)) ?? [] {
            for month in (try? FileManager.default.contentsOfDirectory(atPath: sessions + "/" + year)) ?? [] {
                let path = sessions + "/" + year + "/" + month
                guard let modified = Self.newestModification(path), now.timeIntervalSince(modified) > logAgeDays * 86_400 else { continue }
                items.append(DiskItem(path: path, category: .aiLogs, bytes: Self.allocatedSize(path), modified: modified, note: "Codex rollout \(year)-\(month)",
                                      grade: .c, hint: "대화 기록입니다 — 지우지 않고 외장으로 옮깁니다"))
            }
        }
        let projects = home + "/.claude/projects"
        for directory in (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [] {
            let path = projects + "/" + directory
            guard let modified = Self.newestModification(path), now.timeIntervalSince(modified) > logAgeDays * 86_400 else { continue }
            let bytes = Self.allocatedSize(path)
            if bytes > 20 * 1_048_576 {
                items.append(DiskItem(path: path, category: .aiLogs, bytes: bytes, modified: modified, note: "Claude 기록 · \(directory)",
                                      grade: .c, hint: "대화 기록입니다 — 지우지 않고 외장으로 옮깁니다"))
            }
        }
        return items
    }

    // MARK: - 크기

    public static func allocatedSize(_ path: String) -> UInt64 {
        allocatedSize(path, until: nil).bytes
    }

    /// deadline이 지나면 거기까지 센 값과 complete=false를 돌려준다(iCloud·가상 머신 폴더처럼 끝이 안 보이는 곳).
    public static func allocatedSize(_ path: String, until deadline: Date?) -> (bytes: UInt64, complete: Bool) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return (0, true) }
        if (info.st_mode & S_IFMT) != S_IFDIR { return (UInt64(info.st_blocks) * 512, true) }
        var total: UInt64 = 0
        guard let stream = fts_open_wrapper(path) else { return (0, true) }
        defer { fts_close(stream) }
        var visited = 0
        while let entry = fts_read(stream) {
            visited += 1
            if let deadline, visited % 2_000 == 0, Date() > deadline { return (total, false) }
            let pointer = entry.pointee
            switch Int32(pointer.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                if let stat = pointer.fts_statp { total += UInt64(stat.pointee.st_blocks) * 512 }
            case FTS_D:
                if let stat = pointer.fts_statp { total += UInt64(stat.pointee.st_blocks) * 512 }
            default: break
            }
        }
        return (total, true)
    }

    /// iCloud 등 파일 제공자가 관리하는 '내용 없는(dataless)' 파일·폴더를 열어도 내려받지 않게 하고 body를 돈다(이 스레드만, 끝나면 되돌림).
    /// 크기 조사가 네트워크로 목록·내용을 끌어오지 않게 한다 — 그런 폴더는 읽지 못한 것으로 센다.
    public static func withoutMaterializing<T>(_ body: () throws -> T) rethrows -> T {
        let previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        defer { if previous >= 0 { _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, previous) } }
        return try body()
    }

    private static func fts_open_wrapper(_ path: String) -> UnsafeMutablePointer<FTS>? {
        path.withCString { cPath in
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(paths[0]) }
            return fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }
    }

    public static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    static func newestModification(_ path: String) -> Date? {
        var newest = modified(path)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: path) {
            for name in names {
                if let date = modified(path + "/" + name), date > (newest ?? .distantPast) { newest = date }
            }
        }
        return newest
    }

    /// 폴더 전체에서 가장 최근 수정 시각(로그 폴더가 지금도 쓰이는지). 항목이 너무 많으면 limit에서 멈추고 '최근'으로 본다.
    static func newestModificationDeep(_ path: String, limit: Int = 20_000) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        if (info.st_mode & S_IFMT) != S_IFDIR { return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)) }
        guard let stream = fts_open_wrapper(path) else { return nil }
        defer { fts_close(stream) }
        var newest: Int = 0
        var seen = 0
        while let entry = fts_read(stream) {
            seen += 1
            if seen > limit { return Date() }
            guard let stat = entry.pointee.fts_statp else { continue }
            switch Int32(entry.pointee.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT, FTS_D:
                newest = max(newest, Int(stat.pointee.st_mtimespec.tv_sec))
            default: break
            }
        }
        return Date(timeIntervalSince1970: TimeInterval(newest))
    }
}
