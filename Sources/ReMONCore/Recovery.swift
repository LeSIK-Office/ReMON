import Darwin
import Foundation

// 복구 금고 — "되돌릴 방법을 먼저 확보하고, 그다음에 정리한다."
// 세션: 종료 전에 이어 열기 키(세션 id)·기록 파일·폴더를 확인해 금고에 적고, 기록 파일을 하드링크로 보관한 뒤 SIGTERM.
//       키를 확보하지 못한 세션은 자동 정리하지 않는다(수동 정리는 경고 후 가능).
// 파일: 휴지통으로 옮긴 위치를 적어 되돌린다. 재생성 캐시를 영구 삭제하면 '되돌릴 수 없음 · 재생성 방법'만 남긴다.
// git: 지운 브랜치·워크트리의 커밋을 적어 같은 커밋으로 되살린다.
// 프로세스(세션이 아닌 남은 보조 프로세스·강제 종료한 앱): 끝내기 전에 실행 파일·인자(비밀값 가림)·폴더·정해진 환경 변수·출신을 적고,
//       못 적으면 끝내지 않는다. 복구함 '다시 띄우기'로 같은 폴더에서 같은 명령(앱은 open -b)을 실행한다.

public struct RecoveryEntry: Codable, Sendable, Equatable, Identifiable {
    /// codexArchive: Codex 자체 보관(`codex archive`) — `codex unarchive <id>`로 되돌린다(resumeID = 스레드 id).
    /// process: 세션이 아닌 프로세스(남은 보조 프로세스 · 강제 종료한 앱) — resumeArgs(명령) 또는 bundleID(앱)로 다시 띄운다.
    public enum Kind: String, Codable, Sendable { case session, trash, branch, worktree, deleted, codexArchive, process }
    public enum Status: String, Codable, Sendable {
        /// 종료 직전 기록(종료가 실패하면 지운다). 금고에 먼저 적지 못하면 종료하지 않는다.
        case retiring
        /// 보관 중 — 되돌릴 수 있다.
        case held
        /// 복귀 명령을 실행함 — 실제로 돌아왔는지 확인 중.
        case restoring
        case restored
        /// 보관 기간이 지났거나 휴지통을 비워 되돌릴 수 없다.
        case expired
        /// 기록만 남김(재생성 캐시 영구 삭제 · 대화 없는 세션 종료).
        case gone
    }

    public var id: String
    public var kind: Kind
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date
    public var project: String
    public var title: String
    /// 정리 이유(수동 정리 · 메모리 최적화 · 감사 퇴출 · 탭 닫힘 …)
    public var reason: String
    public var bytes: UInt64
    public var note: String?
    // 세션
    public var agent: String?
    public var resumeID: String?
    public var cwd: String?
    public var transcript: String?
    public var transcriptBytes: UInt64?
    /// 기록 파일 보관본(하드링크, 같은 볼륨이 아니면 복사본)
    public var backup: String?
    /// 그대로 붙여 쓸 수 있는 명령(cd 포함)
    public var resumeCommand: String?
    /// cd 없이 실행할 명령(터미널 창에서 폴더를 먼저 옮긴 뒤 실행)
    public var resumeArgs: [String]?
    /// 원래 폴더가 없을 때 차례로 쓸 폴더(기록의 마지막 폴더 · 세션 작업 폴더)
    public var fallbackCwds: [String]?
    /// 복구 키가 불확실할 때 추정으로 연결된 대화 id(되돌리기 버튼은 없고, 명령만 보여 준다)
    public var candidateID: String?
    public var terminalHost: String?
    /// 원래 터미널의 위치 정보. tmux면 TMUX 값("소켓,서버 pid,세션 번호") — 프로세스가 끝난 뒤에도 같은 서버·세션에 새 창을 연다.
    public var terminalDetail: String?
    /// Claude 백그라운드 세션의 짧은 id(`claude stop`·`attach`가 받는 값). 있으면 터미널 대신 백그라운드로 되살린다.
    public var backgroundJob: String?
    /// ReMON이 끄지 않았는데 사라진 세션의 끝난 까닭(DepartureCause rawValue). nil이면 ReMON이 정리한 것.
    public var departure: String?
    public var pid: Int32?
    /// 프로세스 시작 시각(ProcessKey.start) — pid 재사용과 구분, 정신교육실 인물의 생김새 씨앗.
    public var processStart: Int64?
    // 파일
    public var originalPath: String?
    public var trashedPath: String?
    // git
    public var repo: String?
    public var branch: String?
    public var head: String?
    public var worktreePath: String?
    /// 지우기 전 브랜치의 upstream(refs/remotes/origin/x · refs/heads/y).
    public var upstream: String?
    /// 지우기 전 결합 근거(git 이력: 조상 병합 · git cherry 동등 · squash patch-id 동등).
    public var evidence: String?
    /// 기본 브랜치에 조상으로 없던 커밋(전체 SHA) — 동등(squash·cherry-pick) 판정으로 지운 항목은 여기 SHA로 되살린다.
    public var commits: [String]?
    /// 지운 뒤 확인 결과(폴더 없음 · git/Orca 목록에서 빠짐 · 커밋 보존). 확인하지 못한 것은 '미확인'.
    public var verification: String?
    /// 사람이 직접 칠 수 있는 복구 명령(재생성 캐시는 재생성 방법)
    public var restoreHint: String?
    // 프로세스(세션이 아닌 보조 프로세스·앱). 다시 띄울 명령은 resumeArgs(cd 없음)·resumeCommand(cd 포함)에 둔다.
    /// 실행 파일 경로(앱은 번들 안 실행 파일)
    public var executable: String?
    /// 원래 실행 인자(비밀값은 ••••로 가림)
    public var processArgv: [String]?
    /// 남긴 환경 변수(정해진 이름만 — ProcessRecovery.environmentKeys). 다시 띄울 때는 PORT·NODE_ENV·HOST만 넘긴다.
    public var processEnvironment: [String: String]?
    /// 출신: 어느 세션의 보조 프로세스였는지("Claude Code · ReMON" · "워크플로 잔재 · ReMON") 또는 앱 번들 id
    public var origin: String?
    /// 앱이면 번들 id — 다시 띄우기는 open -b(NSWorkspace)
    public var bundleID: String?
    /// 끝난 방식(SIGTERM · SIGKILL · 강제 종료 · 신호 뒤 끝남). 끝난 것을 확인하기 전엔 nil.
    public var exitReason: String?

    public init(kind: Kind, status: Status, project: String, title: String, reason: String, bytes: UInt64 = 0, now: Date = Date()) {
        self.id = UUID().uuidString.lowercased()
        self.kind = kind
        self.status = status
        self.createdAt = now
        self.updatedAt = now
        self.project = project
        self.title = title
        self.reason = reason
        self.bytes = bytes
    }

    /// 지금 되돌릴 수 있는가(화면의 '복귀'·'되돌리기'·'다시 띄우기' 버튼).
    public var restorable: Bool {
        switch kind {
        case .session: return status == .held && resumeID != nil
        case .trash, .branch, .worktree, .codexArchive: return status == .held
        case .deleted: return false
        case .process: return status == .held && relaunchable
        }
    }

    /// 프로세스 항목을 다시 띄울 방법이 있는가: 앱(번들 id · 번들 경로) 또는 명령.
    public var relaunchable: Bool {
        guard kind == .process else { return false }
        return bundleID != nil || originalPath?.hasSuffix(".app") == true || resumeArgs?.isEmpty == false
    }

    /// 앱 항목인가(다시 띄우기 = open -b). 아니면 명령을 터미널에서 실행한다.
    public var isAppProcess: Bool { kind == .process && (bundleID != nil || ((resumeArgs?.isEmpty ?? true) && originalPath?.hasSuffix(".app") == true)) }
}

/// 금고 파일: ~/Library/Application Support/ReMON/Recovery/vault.json. 앱 두 개(개발판·설치판)가 함께 써도
/// 잃지 않게 매번 디스크에서 읽고 파일 잠금(flock) 안에서 고친 뒤 원자적으로 쓴다.
public final class RecoveryVault: @unchecked Sendable {
    /// REMON_VAULT_DIR로 다른 폴더를 쓸 수 있다(시험·시연용 — 대표 금고를 건드리지 않게).
    public static let shared = RecoveryVault(folder: ProcessInfo.processInfo.environment["REMON_VAULT_DIR"].map { URL(fileURLWithPath: $0) }
                                             ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ReMON/Recovery"))
    public let folder: URL
    public var audit = AuditLog.shared
    /// 세션 보관 기간(이 기간이 지나면 보관본을 지우고 만료). Claude 기본 기록 보관(30일)과 맞춘다.
    public var sessionRetention: TimeInterval = 30 * 86_400
    private let lock = NSLock()

    public init(folder: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ReMON/Recovery")) {
        self.folder = folder
    }

    public var fileURL: URL { folder.appendingPathComponent("vault.json") }
    public var backupFolder: URL { folder.appendingPathComponent("transcripts", isDirectory: true) }
    public var launchFolder: URL { folder.appendingPathComponent("launch", isDirectory: true) }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    /// 최근 것부터.
    public func all() -> [RecoveryEntry] {
        (try? locked { $0 })?.sorted { $0.createdAt > $1.createdAt } ?? []
    }

    public func entry(_ id: String) -> RecoveryEntry? { all().first { $0.id == id } }

    /// 정신교육실에 앉힐 세션(보관 중·복귀 확인 중).
    public var heldSessions: [RecoveryEntry] { all().filter { $0.kind == .session && ($0.status == .held || $0.status == .restoring) } }

    /// 다시 띄울 수 있는 프로세스(남은 보조 프로세스 · 강제 종료한 앱) — 보관 중·다시 띄우는 중.
    public var heldProcesses: [RecoveryEntry] { all().filter { $0.kind == .process && ($0.status == .held || $0.status == .restoring) } }

    /// 금고에 적는다. 실패하면 던진다 — 부르는 쪽은 실패 시 정리를 하지 않는다(fail-closed).
    @discardableResult
    public func add(_ entry: RecoveryEntry) throws -> RecoveryEntry {
        try locked { list in list.append(entry) }
        audit.write(action: "recovery.add", target: entry.title, bytes: entry.bytes, result: entry.status.rawValue, dryRun: false,
                    detail: ["kind": entry.kind.rawValue, "entry": entry.id, "resume": entry.resumeID ?? "", "project": entry.project])
        return entry
    }

    public func update(_ id: String, _ change: (inout RecoveryEntry) -> Void) throws {
        try locked { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            change(&list[index])
            list[index].updatedAt = Date()
        }
    }

    /// 항목과 보관본을 지운다(종료가 실패해 남길 이유가 없을 때).
    public func remove(_ id: String) throws {
        var backup: String?
        try locked { list in
            backup = list.first { $0.id == id }?.backup
            list.removeAll { $0.id == id }
        }
        if let backup { try? FileManager.default.removeItem(atPath: backup) }
    }

    /// 만료 처리: 오래된 세션 보관본 삭제, 비워진 휴지통 항목 만료, 끝난 항목은 90일 뒤 목록에서 뺀다. 만료한 수를 돌려준다.
    @discardableResult
    public func expire(now: Date = Date()) -> Int {
        var removedBackups: [String] = []
        var count = 0
        try? locked { list in
            for index in list.indices {
                var entry = list[index]
                switch (entry.kind, entry.status) {
                case (.session, .held) where now.timeIntervalSince(entry.createdAt) > sessionRetention:
                    entry.status = .expired
                    entry.note = "보관 기간(\(Int(sessionRetention / 86_400))일)이 지나 보관본을 지웠습니다"
                    if let backup = entry.backup { removedBackups.append(backup); entry.backup = nil }
                    count += 1
                case (.session, .restored), (.session, .gone):
                    // 대화가 원래 기록에 이어지므로 보관본은 더는 필요 없다.
                    if let backup = entry.backup { removedBackups.append(backup); entry.backup = nil }
                case (.process, .held) where now.timeIntervalSince(entry.createdAt) > sessionRetention:
                    // 오래된 명령은 폴더·도구가 바뀌어 맞지 않을 수 있다 — 버튼만 내리고 명령은 기록에 남긴다(복사해서 직접 실행 가능).
                    entry.status = .expired
                    entry.note = (entry.note.map { $0 + " · " } ?? "") + "보관 기간(\(Int(sessionRetention / 86_400))일)이 지나 만료 · 명령은 기록에 남음"
                    count += 1
                case (.trash, .held):
                    // 권한(전체 디스크 접근)이 없어 휴지통을 못 보는 것과 '비워짐'을 구분한다 — 없음이 확실할 때만 만료.
                    if let trashed = entry.trashedPath, Self.definitelyMissing(trashed) {
                        entry.status = .expired
                        entry.note = "휴지통에서 비워져 되돌릴 수 없습니다"
                        count += 1
                    }
                default:
                    break
                }
                if entry != list[index] { entry.updatedAt = now; list[index] = entry }
            }
            list.removeAll { [.restored, .expired, .gone].contains($0.status) && now.timeIntervalSince($0.updatedAt) > 90 * 86_400 }
        }
        settleRetiring(now: now)
        for path in removedBackups { try? FileManager.default.removeItem(atPath: path) }
        return count
    }

    /// 종료 신호를 보낸 항목(retiring): 프로세스가 끝났으면 보관(held)으로, 살아 있으면 그대로 둔다.
    /// 신호를 보낸 뒤에는 절대 지우지 않는다 — 멈춘(Ctrl-Z) 프로세스가 나중에 재개되며 끝나도 키가 남아야 한다.
    /// 돌려주는 것은 세션 항목만이다(정신교육실 알림용). 프로세스 항목(.process)도 같은 규칙으로 보관되지만 복구함에만 보인다.
    @discardableResult
    public func settleRetiring(now: Date = Date()) -> [RecoveryEntry] {
        var settled: [RecoveryEntry] = []
        try? locked { list in
            for index in list.indices where list[index].status == .retiring && (list[index].kind == .session || list[index].kind == .process) {
                let entry = list[index]
                let alive = entry.pid.map { pid in entry.processStart.map { SessionTerminator.isAlive(ProcessKey(pid: pid, start: $0)) } ?? (kill(pid, 0) == 0) } ?? false
                guard !alive else { continue }
                list[index].status = entry.resumeID != nil || entry.relaunchable ? .held : .gone
                list[index].note = (entry.note.map { $0 + " · " } ?? "") + "종료 확인"
                if entry.kind == .process, entry.exitReason == nil { list[index].exitReason = entry.isAppProcess ? "강제 종료 뒤 끝남" : "종료 신호 뒤 끝남" }
                list[index].updatedAt = now
                // 프로세스는 정신교육실에 앉지 않는다 — '정신교육실 보관 · 복구 키 보관' 알림이 나가지 않게 돌려주지 않는다.
                if entry.kind != .process { settled.append(list[index]) }
            }
        }
        return settled
    }

    /// 상태를 잠금 안에서 바꾼다(지금 상태가 from일 때만). 두 번 누르기·두 경로 동시 실행을 막는다.
    public func transition(_ id: String, from: RecoveryEntry.Status, to: RecoveryEntry.Status, note: String? = nil) throws -> Bool {
        try locked { list in
            guard let index = list.firstIndex(where: { $0.id == id }), list[index].status == from else { return false }
            list[index].status = to
            if let note { list[index].note = note }
            list[index].updatedAt = Date()
            return true
        }
    }

    /// 경로가 '없음'이 확실한가(ENOENT·ENOTDIR). 권한 오류는 모름으로 본다.
    static func definitelyMissing(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) == 0 { return false }
        return errno == ENOENT || errno == ENOTDIR
    }

    // MARK: 파일 잠금 + 원자적 쓰기

    private func locked<T>(_ body: (inout [RecoveryEntry]) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockPath = folder.appendingPathComponent(".lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { flock(fd, LOCK_UN); close(fd) }
        flock(fd, LOCK_EX)
        let loaded = try load()
        var list = loaded.entries
        let before = list
        let result = try body(&list)
        if list != before {
            var data = try Self.encoder.encode(list)
            // 이 판이 모르는 항목(새 판이 적은 종류)은 지우지 않고 원문 그대로 다시 적는다.
            if !loaded.unknown.isEmpty, var array = try JSONSerialization.jsonObject(with: data) as? [Any] {
                array += loaded.unknown
                data = try JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .sortedKeys])
            }
            try data.write(to: fileURL, options: [.atomic])
            chmod(fileURL.path, 0o600)
        }
        return result
    }

    /// 항목마다 따로 읽는다: 하나가 깨졌거나 이 판이 모르는 종류여도 나머지는 살리고, 모르는 것은 원문으로 보존한다.
    private func load() throws -> (entries: [RecoveryEntry], unknown: [Any]) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ([], []) }
        // 파일은 있는데 못 읽으면(권한·입출력 오류) 던진다 — 정리를 멈추고, 빈 금고로 덮어쓰지 않는다.
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else { return ([], []) }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            // 배열로도 읽히지 않는 깨진 금고는 버리지 않고 옆에 옮겨 둔다(사람이 열어 볼 수 있게).
            let aside = folder.appendingPathComponent("vault.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            audit.write(action: "recovery.vault", target: fileURL.path, result: "corrupt: moved to \(aside.lastPathComponent)", dryRun: false)
            return ([], [])
        }
        var entries: [RecoveryEntry] = [], unknown: [Any] = []
        for element in array {
            if let raw = try? JSONSerialization.data(withJSONObject: element), let entry = try? Self.decoder.decode(RecoveryEntry.self, from: raw) {
                entries.append(entry)
            } else {
                unknown.append(element)
            }
        }
        return (entries, unknown)
    }
}

// MARK: - 이어 열기 키

/// 세션을 다시 열 키. 기록 파일과 id가 서로 맞는 것을 확인했을 때만 exact.
public enum ResumeKey {
    public struct Key: Sendable, Equatable {
        public var agent: AgentKind
        public var id: String
        /// 이어 열 폴더(기록에 적힌 폴더 우선)
        public var cwd: String
        public var transcript: String?
        /// 실행할 명령(cd 없음). 예: ["claude", "--resume", "<id>", "--model", "opus"]
        public var arguments: [String]
        /// cwd가 없을 때 차례로 쓸 폴더
        public var fallbackCwds: [String] = []
        /// Claude 백그라운드 세션(`claude --bg`): 정리는 `claude stop <jobID>`, 복귀는 `claude --bg --resume <id>`(터미널 없이).
        public var background = false
        public var jobID: String?

        /// 사람이 그대로 붙여 쓸 수 있는 한 줄(cd 포함).
        public var command: String { "cd \(ResumeKey.quote(cwd)) && " + arguments.map(ResumeKey.quote).joined(separator: " ") }
    }

    public enum Result: Sendable, Equatable {
        /// 정확히 확보(기록 파일 존재 · id 검증)
        case exact(Key)
        /// 대화가 없어 잃을 것이 없다(새 세션 등)
        case nothingToLose(String)
        /// 연결이 추정이거나 기록이 둘 이상이라 확신할 수 없다 — 자동 정리 금지
        case uncertain(String)
        /// 이어 열기를 모르는 에이전트 — 자동 정리 금지
        case unsupported(String)

        public var key: Key? { if case .exact(let key) = self { return key }; return nil }
        /// 묶음·자동 정리(메모리·프로세스 최적화 · 감사 퇴출 · 자동 메모리 정리)를 해도 되는가 — 정확한 키가 있을 때만.
        /// '잃을 대화 없음'은 대화 기록이 안 보인다는 뜻일 뿐이다. 백그라운드 세션을 열어 보는 대화형 창, 첫 질문 전 세션도 여기 걸린다
        /// (10-25 사고: 대표님이 백그라운드 세션을 보던 Claude 창 2개를 자동 메모리 정리가 '새 세션'으로 보고 키 없이 종료). 이런 세션은 카드에서 하나씩만.
        public var allowsAutoCleanup: Bool {
            if case .exact = self { return true }
            return false
        }

        /// 화면 표시용 한 줄.
        public var label: String {
            switch self {
            case .exact(let key): "복구 키 확보 · \(key.id.prefix(8))"
            case .nothingToLose(let why): "잃을 대화 없음 · \(why)"
            case .uncertain(let why): "복구 키 불확실 · \(why)"
            case .unsupported(let why): "복구 불가 · \(why)"
            }
        }
    }

    static let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#

    static func isUUID(_ text: String) -> Bool { text.range(of: uuidPattern, options: .regularExpression) != nil }

    /// - registrySessionID: Claude 레지스트리(~/.claude/sessions/<pid>.json)의 sessionId
    /// - argv: 루트 프로세스의 실행 인자(원래 플래그를 이어 열기에 그대로 옮긴다 — 안전 목록만)
    /// - registryKind: 레지스트리의 kind("interactive" · "bg" …). "bg"면 백그라운드 세션으로 다룬다.
    public static func resolve(_ session: AgentSession, registrySessionID: String?, argv: [String], registryKind: String? = nil,
                               claudeProjects: String = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/projects") -> Result {
        switch session.kind {
        case .claudeCode: return resolveClaude(session, registrySessionID: registrySessionID, argv: argv, registryKind: registryKind, projects: claudeProjects)
        case .codexCLI: return resolveCodex(session, argv: argv)
        case .opencode: return resolveOpenCode(session, argv: argv)
        default: return .unsupported("\(session.kind.label)의 이어 열기 방법을 모릅니다")
        }
    }

    static func resolveClaude(_ session: AgentSession, registrySessionID: String?, argv: [String], registryKind: String? = nil, projects: String) -> Result {
        if let path = session.logPath {
            guard !session.logLinkIsEstimate else { return .uncertain("기록 연결이 추정입니다") }
            guard let id = SessionLogReader.threadID(fromPath: path), isUUID(id) else { return .uncertain("기록 파일 이름에서 세션 id를 읽지 못했습니다") }
            if let registry = registrySessionID, registry != id { return .uncertain("레지스트리 세션 id와 기록 파일이 다릅니다") }
            guard let size = fileSize(path), size > 0 else { return .uncertain("기록 파일이 비었거나 없습니다") }
            let facts = transcriptFacts(path)
            guard facts.hasConversation else { return .nothingToLose("기록에 대화가 없습니다") }
            // 시작 폴더(기록의 첫 cwd = 기록이 든 프로젝트 폴더) 우선. 세션 중 옮겨 간 워크트리는 지워질 수 있어 대체로만 둔다(10-25 검토).
            let ordered = [facts.firstCwd, facts.lastCwd, session.cwd].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let cwd = ordered.first(where: isDirectory) ?? ordered.first ?? NSHomeDirectory()
            var key = Key(agent: .claudeCode, id: id, cwd: cwd, transcript: path, arguments: ["claude", "--resume", id] + safeFlags(.claudeCode, argv: argv))
            key.fallbackCwds = ordered.filter { $0 != cwd }
            if registryKind == "bg" {
                // 백그라운드 세션은 자기 옵션(모델 등)을 저장해 둔다. 플래그를 붙이면 같은 세션을 잇지 않고 복사본을 만든다(10-25 실측) → 플래그 없이.
                key.arguments = ["claude", "--bg", "--resume", id]
                key.background = true
                key.jobID = String(id.prefix(8))
            }
            return .exact(key)
        }
        if let id = registrySessionID, isUUID(id) {
            // 레지스트리는 있는데 어디에도 <id>.jsonl이 없으면 아직 한 마디도 기록되지 않은 새 세션이다.
            let found = (try? FileManager.default.contentsOfDirectory(atPath: projects))?.contains { FileManager.default.fileExists(atPath: projects + "/" + $0 + "/" + id + ".jsonl") } ?? false
            if found { return .uncertain("기록 파일이 있지만 아직 연결되지 않았습니다(다음 주기에 다시 확인)") }
            return .nothingToLose("아직 대화 기록이 없는 새 세션")
        }
        return .uncertain("기록 파일을 찾지 못했습니다")
    }

    static func resolveCodex(_ session: AgentSession, argv: [String]) -> Result {
        guard let main = session.logPath, !session.logLinkIsEstimate else { return .uncertain("열린 rollout 기록을 찾지 못했습니다") }
        // 하위 스레드도 rollout을 연다 → session_meta의 parent_thread_id가 빈 것(주 스레드)이 정확히 하나여야 한다(10-25 실측: 6개 프로세스 모두 1개).
        let candidates = Array(Set([main] + session.extraLogPaths))
        let metas = candidates.compactMap { path -> (path: String, id: String, cwd: String?)? in
            guard let meta = codexMeta(path), meta.parent == nil else { return nil }
            return (path, meta.id, meta.cwd)
        }
        guard metas.count == 1, let top = metas.first else {
            return metas.isEmpty ? .uncertain("주 스레드 rollout을 확인하지 못했습니다") : .uncertain("주 스레드 rollout이 \(metas.count)개라 고를 수 없습니다")
        }
        guard isUUID(top.id), top.path.hasSuffix(top.id + ".jsonl") else { return .uncertain("rollout 파일 이름과 세션 id가 다릅니다") }
        let cwd = top.cwd ?? session.cwd ?? NSHomeDirectory()
        var key = Key(agent: .codexCLI, id: top.id, cwd: cwd, transcript: top.path, arguments: ["codex", "resume", top.id] + safeFlags(.codexCLI, argv: argv))
        key.fallbackCwds = [session.cwd].compactMap { $0 }.filter { $0 != cwd }
        return .exact(key)
    }

    static func resolveOpenCode(_ session: AgentSession, argv: [String]) -> Result {
        // OpenCode는 세션 id를 프로세스 밖에서 정확히 알 방법이 없다(DB에 자격 증명 표가 함께 있어 읽지 않는다). 실행 인자에 있을 때만.
        let id = flag(argv, ["--session", "-s"])
        guard let id, !id.isEmpty, let cwd = session.cwd else { return .unsupported("OpenCode는 실행 인자에 세션 id(-s)가 있을 때만 이어 열 수 있습니다") }
        return .exact(Key(agent: .opencode, id: id, cwd: cwd, transcript: nil, arguments: ["opencode", "--session", id]))
    }

    /// 원래 실행 플래그 중 이어 열기에 옮겨도 되는 것만(인증·설정 덮어쓰기·임의 경로 설정 파일은 옮기지 않는다).
    public static func safeFlags(_ agent: AgentKind, argv: [String]) -> [String] {
        let valued: Set<String>, plain: Set<String>, aliases: [String: String]
        switch agent {
        case .claudeCode:
            valued = ["--model", "--permission-mode", "--fallback-model", "--agent"]
            plain = ["--dangerously-skip-permissions"]
            aliases = [:]
        case .codexCLI:
            valued = ["-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval"]
            plain = ["--dangerously-bypass-approvals-and-sandbox", "--search"]
            aliases = ["--yolo": "--dangerously-bypass-approvals-and-sandbox"]
        default:
            return []
        }
        var result: [String] = []
        var index = 1
        while index < argv.count {
            let raw = argv[index]
            // 빈 인자('--setting-sources ""' 등)가 실제로 온다 — 나누기 전에 거른다(10-25 실전 검사에서 잡은 충돌).
            guard !raw.isEmpty else { index += 1; continue }
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0]
            if let alias = aliases[name], !result.contains(alias) {
                result.append(alias)
            } else if plain.contains(name), !result.contains(name) {
                result.append(name)
            } else if valued.contains(name) {
                if parts.count == 2 { if !parts[1].isEmpty { result += [name, parts[1]] } }
                else if index + 1 < argv.count, !argv[index + 1].hasPrefix("-") { result += [name, argv[index + 1]]; index += 1 }
            }
            index += 1
        }
        return result
    }

    static func flag(_ argv: [String], _ names: [String]) -> String? {
        for (index, value) in argv.enumerated() {
            for name in names {
                if value == name, index + 1 < argv.count { return argv[index + 1] }
                if value.hasPrefix(name + "=") { return String(value.dropFirst(name.count + 1)) }
            }
        }
        return nil
    }

    /// 셸에 안전한 인용.
    public static func quote(_ text: String) -> String {
        if !text.isEmpty, text.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) != nil { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: 기록 파일 읽기(끝부분만)

    struct TranscriptFacts { var firstCwd: String?; var lastCwd: String?; var hasConversation: Bool }

    /// Claude 기록 앞 256KB에서 첫 cwd(시작 폴더), 끝 256KB에서 마지막 cwd와 대화 여부를 본다.
    static func transcriptFacts(_ path: String) -> TranscriptFacts {
        var facts = TranscriptFacts(firstCwd: nil, lastCwd: nil, hasConversation: false)
        func objects(_ chunk: Data) -> [[String: Any]] {
            String(decoding: chunk, as: UTF8.self).split(separator: "\n").compactMap { line in
                guard line.hasPrefix("{") else { return nil }
                return try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            }
        }
        let head = objects(readHead(path, 256 * 1024)), tail = objects(readTail(path, 256 * 1024))
        facts.firstCwd = head.lazy.compactMap { $0["cwd"] as? String }.first { !$0.isEmpty }
        facts.lastCwd = tail.reversed().lazy.compactMap { $0["cwd"] as? String }.first { !$0.isEmpty } ?? facts.firstCwd
        facts.hasConversation = (tail + head).contains { ($0["type"] as? String).map { $0 == "user" || $0 == "assistant" } ?? false }
        return facts
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// Codex rollout 첫 줄(session_meta): id · cwd · parent_thread_id.
    static func codexMeta(_ path: String) -> (id: String, cwd: String?, parent: String?)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count < 4 * 1024 * 1024, !data.contains(0x0A), let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty { data += chunk }
        let line = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: true).first ?? Data()
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], (object["type"] as? String) == "session_meta",
              let payload = object["payload"] as? [String: Any], let id = payload["id"] as? String else { return nil }
        let parent = (payload["parent_thread_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (id, payload["cwd"] as? String, parent)
    }

    static func readTail(_ path: String, _ count: Int) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(count) ? size - UInt64(count) : 0
        try? handle.seek(toOffset: start)
        return (try? handle.readToEnd()) ?? Data()
    }

    static func readHead(_ path: String, _ count: Int) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: count)) ?? Data()
    }

    static func fileSize(_ path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_size)
    }
}

/// 기록 파일의 크기·수정 시각. 계획한 뒤 종료 직전까지 바뀌면(일을 시작했을 수 있음) 종료를 취소한다.
public struct TranscriptStamp: Sendable, Equatable {
    public var path: String
    public var size: UInt64
    public var modified: TimeInterval

    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        self.path = path
        self.size = UInt64(info.st_size)
        self.modified = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
    }

    /// 마지막 줄이 온전한 JSON인가(종료가 쓰기 중간을 끊지 않았는지).
    public static func lastLineIsValid(_ path: String) -> Bool {
        let tail = ResumeKey.readTail(path, 512 * 1024)
        guard let line = String(decoding: tail, as: UTF8.self).split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return true }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil
    }
}

// MARK: - 세션 정리(금고 먼저)

public final class SessionRetirer: @unchecked Sendable {
    public struct Prepared: Sendable {
        public var plan: SessionTerminator.Plan
        public var key: ResumeKey.Result
        public var stamp: TranscriptStamp?
        public var reason: String
        /// true면 복구 키(또는 잃을 것 없음)가 없을 때 종료하지 않는다 — 자동 정리 경로.
        public var requireKey: Bool
    }

    public struct Outcome: Sendable {
        public var termination: SessionTerminator.Outcome?
        public var entry: RecoveryEntry?
        /// 종료하지 않은 이유(복구 키 없음 · 직전 활동 · 금고 기록 실패)
        public var aborted: String?
        public var message: String
    }

    public let vault: RecoveryVault
    public let terminator: SessionTerminator
    public var audit = AuditLog.shared
    /// Claude 백그라운드 세션 공식 정지(`claude stop <id>`). 시험은 가짜로 바꾼다.
    public var backgroundStopper: @Sendable (_ job: String) -> (ok: Bool, message: String) = SessionRetirer.liveBackgroundStop

    public init(vault: RecoveryVault, terminator: SessionTerminator) {
        self.vault = vault
        self.terminator = terminator
    }

    public func prepare(plan: SessionTerminator.Plan, registrySessionID: String?, argv: [String], registryKind: String? = nil, reason: String, requireKey: Bool) -> Prepared {
        let key = ResumeKey.resolve(plan.session, registrySessionID: registrySessionID, argv: argv, registryKind: registryKind)
        let stamp = (key.key?.transcript ?? plan.session.logPath).flatMap { TranscriptStamp(path: $0) }
        return Prepared(plan: plan, key: key, stamp: stamp, reason: reason, requireKey: requireKey)
    }

    /// preSignalCheck: 신호 바로 앞에서 부르는 마지막 확인(예: Claude 레지스트리 상태가 busy·waiting이면 이유를 돌려준다).
    public func execute(_ prepared: Prepared, dryRun: Bool, force: Bool, footprints: [ProcessKey: UInt64],
                        preSignalCheck: (@Sendable () -> String?)? = nil,
                        confirmKill: @escaping @Sendable ([ProcessKey]) -> Bool) -> Outcome {
        let session = prepared.plan.session
        let target = "\(session.kind.label) \(session.project) pid \(session.rootPID)"
        func abort(_ why: String) -> Outcome {
            audit.write(action: "session.retire", target: target, result: "skipped: " + why, dryRun: dryRun, detail: ["recovery": prepared.key.label, "reason": prepared.reason])
            return Outcome(termination: nil, entry: nil, aborted: why, message: "정리하지 않음 · \(session.project) · \(why)")
        }
        // 보호 대상은 종료기가 막고 기록한다.
        guard prepared.plan.blockers.isEmpty else {
            let outcome = terminator.execute(prepared.plan, dryRun: dryRun, force: force, footprints: footprints, confirmKill: confirmKill)
            return Outcome(termination: outcome, entry: nil, aborted: outcome.message, message: outcome.message)
        }
        if prepared.requireKey, !prepared.key.allowsAutoCleanup { return abort("복구 키가 없어 자동 정리하지 않습니다(\(prepared.key.label))") }
        if dryRun {
            let outcome = terminator.execute(prepared.plan, dryRun: true, force: force, footprints: footprints, confirmKill: confirmKill)
            return Outcome(termination: outcome, entry: nil, aborted: nil, message: outcome.message + " · " + prepared.key.label)
        }
        // 계획 뒤에 기록이 바뀌었으면 일을 시작했을 수 있다 → 취소.
        if let stamp = prepared.stamp, TranscriptStamp(path: stamp.path) != stamp { return abort("계획한 뒤 기록이 바뀌었습니다(일을 시작했을 수 있음)") }
        guard let root = prepared.plan.targets.first(where: { $0.pid == session.rootPID }), SessionTerminator.isAlive(root) else {
            return abort("이미 끝난 세션입니다")
        }
        // 일시 정지(Ctrl-Z)된 세션은 사용자가 곧 이어 쓸 수 있다 → 묶음·자동 경로는 손대지 않는다(수동은 종료기가 SIGCONT로 깨워 끝낸다).
        if prepared.requireKey, SessionTerminator.isStopped(root) { return abort("일시 정지된 세션(Ctrl-Z)은 자동 정리하지 않습니다") }
        if let reason = preSignalCheck?() { return abort(reason) }

        // 1) 금고에 먼저 적는다(보관본 포함). 못 적으면 종료하지 않는다.
        var entry = Self.entry(for: session, key: prepared.key, reason: prepared.reason, status: .retiring, vault: vault)
        do { try vault.add(entry) } catch {
            if let backup = entry.backup { try? FileManager.default.removeItem(atPath: backup) }
            return abort("복구 금고에 기록하지 못했습니다(\(error.localizedDescription))")
        }

        // 2) 종료. Claude 백그라운드 세션은 공식 정지(`claude stop <id>`)를 먼저 쓴다 — 데몬 기록이 바로 '멈춤'이 되어, 곧바로 이어 열어도
        //    복사본이 생기지 않는다(10-25 실측: SIGTERM 4초 뒤 이어 열면 데몬이 아직 실행 중으로 알아 복사본을 만듦). 정지가 실패하거나
        //    프로세스가 남으면 아래 SIGTERM 경로가 그대로 끝낸다.
        if let key = prepared.key.key, key.background, let job = key.jobID {
            terminator.registry.record(root, .releasedByReMON)
            let stop = backgroundStopper(job)
            let deadline = Date().addingTimeInterval(6)
            while Date() < deadline, SessionTerminator.isAlive(root) { usleep(250_000) }
            let note = stop.ok ? "claude stop \(job)로 정지" : "claude stop 실패(\(stop.message)) → 종료 신호"
            try? vault.update(entry.id) { $0.note = ($0.note.map { $0 + " · " } ?? "") + note }
            audit.write(action: "session.bgstop", target: target, result: stop.ok ? "ok" : "failed: " + stop.message, dryRun: false, detail: ["job": job])
        }
        let outcome = terminator.execute(prepared.plan, dryRun: false, force: force, footprints: footprints, confirmKill: confirmKill)
        let rootGone = !SessionTerminator.isAlive(root)

        // 3) 결과 반영: 루트가 끝났으면 보관. 신호를 보낸 뒤 아직 살아 있으면 '종료 대기'로 그대로 둔다
        //    (나중에 끝나면 settleRetiring이 보관으로 바꾼다 — 신호 뒤에는 기록을 절대 지우지 않는다).
        guard rootGone else {
            try? vault.update(entry.id) { $0.note = ($0.note.map { $0 + " · " } ?? "") + "종료 신호 보냄 · 아직 끝나지 않음" }
            return Outcome(termination: outcome, entry: vault.entry(entry.id), aborted: nil, message: outcome.message + " · 종료 대기(금고 기록 유지)")
        }
        let restorable = entry.resumeID != nil
        try? vault.update(entry.id) { stored in
            stored.status = restorable ? .held : .gone
            stored.bytes = outcome.reclaimed > 0 ? outcome.reclaimed : stored.bytes
            if let transcript = stored.transcript {
                stored.transcriptBytes = ResumeKey.fileSize(transcript)
                if !TranscriptStamp.lastLineIsValid(transcript) { stored.note = (stored.note.map { $0 + " · " } ?? "") + "기록 마지막 줄이 온전하지 않음" }
            }
            entry = stored
        }
        let tail = restorable ? " · 정신교육실 보관(복구 키 \(entry.resumeID!.prefix(8)))" : (entry.note.map { " · \($0)" } ?? "")
        return Outcome(termination: outcome, entry: entry, aborted: nil, message: outcome.message + tail)
    }

    /// 세션 금고 항목(복구 키 · 기록 보관본 · 백그라운드 id). 정리하기 전(ReMON)과 스스로 끝난 뒤(사라짐 기록)가 함께 쓴다.
    public static func entry(for session: AgentSession, key: ResumeKey.Result, reason: String, status: RecoveryEntry.Status, vault: RecoveryVault) -> RecoveryEntry {
        var entry = RecoveryEntry(kind: .session, status: status, project: session.project, title: session.displayTitle, reason: reason, bytes: session.footprint)
        entry.agent = session.kind.rawValue
        entry.pid = session.rootPID
        entry.processStart = session.id.start
        entry.terminalHost = session.terminalHost
        if session.terminalHost == "tmux" { entry.terminalDetail = TmuxBridge.tmuxVariable(pid: session.rootPID, start: session.id.start) }
        entry.cwd = session.cwd
        switch key {
        case .exact(let key):
            entry.resumeID = key.id
            entry.cwd = key.cwd
            entry.fallbackCwds = key.fallbackCwds.isEmpty ? nil : key.fallbackCwds
            entry.transcript = key.transcript
            entry.resumeCommand = key.command
            entry.resumeArgs = key.arguments
            entry.backgroundJob = key.background ? key.jobID : nil
            if key.background { entry.terminalHost = "Claude 백그라운드" }
            entry.transcriptBytes = key.transcript.flatMap(ResumeKey.fileSize)
            if let transcript = key.transcript { entry.backup = Self.backup(transcript, entry: entry.id, into: vault.backupFolder) }
        case .nothingToLose(let why):
            entry.note = why
        case .uncertain(let why), .unsupported(let why):
            entry.note = "복구 키 없음 · " + why
            // 추정으로 연결된 기록이라도 보관본과 후보 id는 남긴다(되돌리기 버튼은 없지만 사람이 직접 시도할 수 있게).
            if let path = session.logPath, let id = SessionLogReader.threadID(fromPath: path) {
                entry.candidateID = id
                entry.transcript = path
                entry.backup = Self.backup(path, entry: entry.id, into: vault.backupFolder)
            }
        }
        return entry
    }

    /// `claude stop <id>`를 로그인 셸로(PATH 상속). 성공하면 CLI가 "stopped <id>"를 찍는다.
    public static let liveBackgroundStop: @Sendable (String) -> (ok: Bool, message: String) = { job in
        let result = Shell.capture("/bin/zsh", ["-lc", "exec claude stop " + ResumeKey.quote(job)], timeout: 20)
        let ok = result.stdout.contains("stopped " + job)
        let last = (result.stdout + "\n" + result.stderr).split(separator: "\n").map(String.init).last { !$0.isEmpty && !$0.contains("zoxide") } ?? ""
        return (ok, String(last.prefix(160)))
    }

    /// 기록 파일 보관본: 같은 볼륨이면 하드링크(공간 0 · 원본이 지워져도 남음), 아니면 512MB 이하만 복사.
    static func backup(_ transcript: String, entry: String, into folder: URL) -> String? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = folder.appendingPathComponent(entry + "-" + (transcript as NSString).lastPathComponent).path
        unlink(target)
        if link(transcript, target) == 0 { return target }
        guard let size = ResumeKey.fileSize(transcript), size <= 512 * 1_048_576, (try? FileManager.default.copyItem(atPath: transcript, toPath: target)) != nil else { return nil }
        return target
    }
}

// MARK: - 되돌리기

public struct RecoveryLaunch: Sendable, Equatable {
    public var arguments: [String]
    public var cwd: String
    public var title: String
    /// 원래 터미널(TerminalHosts 이름: Orca · Ghostty · iTerm · tmux · 터미널 …). 여기에 맞춰 연다.
    public var terminalHost: String?
    /// tmux면 서버·세션 위치(TMUX 값). 없으면 복귀할 때 살아 있는 서버에서 찾는다.
    public var terminalDetail: String?
    /// 원래 Orca에서 돌던 세션인가(예전 이름).
    public var preferOrca: Bool { terminalHost == "Orca" }

    public init(arguments: [String], cwd: String, title: String, terminalHost: String? = nil, terminalDetail: String? = nil) {
        self.arguments = arguments
        self.cwd = cwd
        self.title = title
        self.terminalHost = terminalHost
        self.terminalDetail = terminalDetail
    }
}

/// 이어 열기 실행기(시험에서는 가짜로 바꿔 명령만 받는다).
public typealias RecoveryLauncher = @Sendable (RecoveryLaunch) -> (ok: Bool, via: String, message: String)

/// Claude 백그라운드 세션 복귀기: 터미널 없이 `claude --bg --resume <id>`를 실행한다.
/// running: 이미 백그라운드에서 돌고 있어 열지 않음 · copy: CLI가 원래 세션 대신 복사본을 만들었을 때 그 짧은 id.
public typealias BackgroundLauncher = @Sendable (_ arguments: [String], _ cwd: String, _ job: String) -> (ok: Bool, running: Bool, copy: String?, message: String)

public enum RecoveryLaunchers {
    /// 실행기가 부르는 바깥 명령(open · orca). 시험은 open 호출만 가짜로 바꾼다(실제 창을 띄우지 않게).
    public static let defaultRunner: CommandRunner = { executable, arguments, timeout in Shell.capture(executable, arguments, timeout: timeout) }

    /// 원래 터미널에서 이어 연다: Orca → 그 작업 공간의 새 탭 · Ghostty → 새 인스턴스 창(`open -n -b com.mitchellh.ghostty --args -e` —
    /// Ghostty 도움말이 macOS에서 권하는 `open -na` 방식, -e는 명령이 끝나면 창과 인스턴스를 닫는다) ·
    /// iTerm → 새 창 · tmux → 그 서버(가능하면 같은 세션)의 새 창. 그 밖의 터미널이거나 위가 안 되면 macOS 터미널 새 창.
    /// 다른 앱에 맡긴 실행은 스크립트가 시작 표시(잠금 폴더)를 남겨야 성공으로 보고, markerWait 안에 안 생기면 터미널로 넘어간다 —
    /// 늦게라도 원래 앱이 스크립트를 돌리면 잠금을 보고 바로 닫혀, 같은 대화가 두 번 뜨지 않는다.
    public static func live(folder: URL, run: @escaping CommandRunner = defaultRunner, tmuxRun: @escaping CommandRunner = TmuxBridge.liveRunner,
                            markerWait: TimeInterval = 10) -> RecoveryLauncher {
        { launch in
            let line = launch.arguments.map(ResumeKey.quote).joined(separator: " ")
            let place = TerminalHosts.restorePlace(for: launch.terminalHost)
            var detour: String?
            if place == .orca {
                if let orca = OrcaBridge.executable {
                    let result = run(orca, ["terminal", "create", "--worktree", "path:" + launch.cwd, "--title", launch.title,
                                            "--command", "cd \(ResumeKey.quote(launch.cwd)) && \(line)", "--focus", "--json"], 20)
                    let failed = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])?["ok"] as? Bool == false
                    if result.succeeded && !failed { return (true, "Orca", "Orca 새 탭에서 이어 엽니다") }
                    // 응답이 늦은 것은 실패가 아닐 수 있다 → 터미널로 또 열면 같은 대화가 두 번 뜬다. 분명히 실패했을 때만 터미널로 넘어간다.
                    if result.timedOut { return (false, "Orca", "Orca가 응답하지 않습니다 — Orca 창에 새 탭이 생겼는지 확인한 뒤 다시 시도하세요") }
                    detour = "Orca에서 열지 못해"
                } else {
                    detour = "Orca가 없어"
                }
            }
            let script: URL
            do { script = try writeScript(launch, line: line, folder: folder) } catch {
                return (false, "터미널", "실행 파일을 만들지 못했습니다: \(error.localizedDescription)")
            }
            let started = script.path + ".started"
            switch place {
            case .ghostty:
                let opened = run("/usr/bin/open", ["-n", "-b", "com.mitchellh.ghostty", "--args", "-e", script.path], 15)
                if opened.succeeded, waitForStart(started, markerWait) { return (true, "Ghostty", "Ghostty 새 창에서 이어 엽니다") }
                detour = opened.succeeded ? "Ghostty에서 시작되지 않아" : "Ghostty를 열지 못해"
            case .iTerm:
                let opened = run("/usr/bin/open", ["-b", "com.googlecode.iterm2", script.path], 15)
                if opened.succeeded, waitForStart(started, markerWait) { return (true, "iTerm", "iTerm 새 창에서 이어 엽니다") }
                detour = opened.succeeded ? "iTerm에서 시작되지 않아" : "iTerm을 열지 못해"
            case .tmux:
                if let target = TmuxBridge.restoreTarget(cwd: launch.cwd, detail: launch.terminalDetail, run: tmuxRun) {
                    let opened = TmuxBridge.openWindow(target, cwd: launch.cwd, name: launch.title, command: ResumeKey.quote(script.path), run: tmuxRun)
                    if opened.ok, waitForStart(started, min(markerWait, 5)) { return (true, "tmux", opened.message) }
                    detour = opened.ok ? "tmux 창에서 시작되지 않아" : "tmux 새 창을 열지 못해"
                } else {
                    detour = "tmux 서버가 없어"
                }
            case .orca, .terminal:
                break
            }
            // .command 파일은 권한 요청 없이 터미널 새 창에서 실행된다. 정상 종료면 창이 닫히고(기본 설정),
            // 실패하면 종료 코드를 보여 주고 키를 누를 때까지 창을 남긴다(실패가 조용히 사라지지 않게).
            let opened = run("/usr/bin/open", ["-a", "Terminal", script.path], 10)
            return opened.succeeded ? (true, "터미널", (detour.map { $0 + " " } ?? "") + "터미널 새 창에서 이어 엽니다")
                : (false, "터미널", "터미널을 열지 못했습니다: \(opened.stderr.prefix(120))")
        }
    }

    /// 복귀 스크립트. 첫 줄의 mkdir이 시작 표시이자 잠금이다(먼저 시작한 창 하나만 이어 연다).
    static func writeScript(_ launch: RecoveryLaunch, line: String, folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        pruneLaunchFolder(folder)
        let script = folder.appendingPathComponent("resume-\(UUID().uuidString.prefix(8)).command")
        let body = """
        #!/bin/zsh
        # ReMON 복구: \(launch.title.replacingOccurrences(of: "\n", with: " "))
        mkdir \(ResumeKey.quote(script.path + ".started")) 2>/dev/null || { echo "ReMON: 이 복귀는 이미 다른 창에서 열렸습니다. 이 창은 닫습니다."; sleep 2; exit 0; }
        cd \(ResumeKey.quote(launch.cwd)) || { echo "ReMON: 폴더로 이동하지 못했습니다 — "\(ResumeKey.quote(launch.cwd)); read -k 1 "?아무 키나 누르면 닫습니다"; exit 1; }
        \(line)
        code=$?
        if [ $code -ne 0 ]; then echo; echo "ReMON: 복귀 명령이 종료 코드 $code로 끝났습니다."; read -k 1 "?아무 키나 누르면 닫습니다"; fi
        exit $code

        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o700)
        return script
    }

    /// 7일 지난 복귀 스크립트·시작 표시를 치운다(이미 돌고 있는 스크립트는 셸이 파일을 열어 두어 지워도 영향이 없다).
    static func pruneLaunchFolder(_ folder: URL, now: Date = Date()) {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("resume-") {
            let path = folder.appendingPathComponent(name).path
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date, now.timeIntervalSince(modified) > 7 * 86_400 else { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    static func waitForStart(_ marker: String, _ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: marker) {
            if Date() >= deadline { return false }
            usleep(150_000)
        }
        return true
    }

    /// 복귀가 열릴 곳(확인 창·복구함 안내). 실행기와 같은 선택 규칙 — 그 앱이 없으면 터미널, tmux는 서버가 없으면 터미널.
    public static func placeLabel(for entry: RecoveryEntry) -> String {
        if let job = entry.backgroundJob { return "Claude 백그라운드(터미널 없이, 같은 짧은 id \(job))" }
        switch TerminalHosts.restorePlace(for: entry.terminalHost) {
        case .orca: return OrcaBridge.executable != nil ? "Orca 새 탭" : "터미널 새 창"
        case .ghostty: return TerminalHosts.appInstalled("Ghostty.app") ? "Ghostty 새 창" : "터미널 새 창"
        case .iTerm: return TerminalHosts.appInstalled("iTerm.app") ? "iTerm 새 창" : "터미널 새 창"
        case .tmux: return "tmux 새 창(서버가 없으면 터미널 새 창)"
        case .terminal: return "터미널 새 창"
        }
    }
}

extension RecoveryLaunchers {
    /// 실제 백그라운드 복귀. 먼저 `claude agents --json`으로 같은 짧은 id가 떠 있는지 본다(떠 있는데 또 열면 복사본이 생긴다).
    public static let liveBackground: BackgroundLauncher = { arguments, cwd, job in
        if backgroundJobRunning(job) { return (true, true, nil, "이미 백그라운드에서 돌고 있습니다 · 터미널에서 보려면 claude attach \(job)") }
        let line = "cd \(ResumeKey.quote(cwd)) && exec " + arguments.map(ResumeKey.quote).joined(separator: " ")
        let result = Shell.capture("/bin/zsh", ["-lc", line], timeout: 60)
        let out = result.stdout
        if let range = out.range(of: #"copy as [0-9a-f]{8}"#, options: .regularExpression) {
            let copy = String(out[range].suffix(8))
            return (true, false, copy, "원래 세션이 아직 실행 중으로 보여 같은 대화의 복사본 \(copy)로 열었습니다 · claude attach \(copy)")
        }
        if out.contains("backgrounded · " + job) { return (true, false, nil, "백그라운드에서 다시 돌아갑니다 · 터미널에서 보려면 claude attach \(job)") }
        let last = (out + "\n" + result.stderr).split(separator: "\n").map(String.init).last { !$0.isEmpty && !$0.contains("zoxide") } ?? "출력 없음"
        return (false, false, nil, "백그라운드 복귀 실패: " + String(last.prefix(160)))
    }

    /// `claude agents --json`에 이 짧은 id가 pid와 함께(실행 중) 있는가.
    public static func backgroundJobRunning(_ job: String) -> Bool {
        let result = Shell.capture("/bin/zsh", ["-lc", "exec claude agents --json"], timeout: 20)
        guard let list = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]] else { return false }
        return list.contains { ($0["id"] as? String) == job && $0["pid"] != nil }
    }
}

public enum RecoveryRestorer {
    public enum Result: Sendable, Equatable {
        case launched(String)
        case alreadyRunning(String)
        case restored(String)
        case failed(String)

        public var ok: Bool { if case .failed = self { return false }; return true }
        public var message: String {
            switch self {
            case .launched(let text), .alreadyRunning(let text), .restored(let text), .failed(let text): text
            }
        }
    }

    /// 지금 실행 중인 세션 중 이 항목의 대화를 이어 쓰고 있는 것.
    public static func runningMatch(_ entry: RecoveryEntry, sessions: [AgentSession], registry: [Int32: String]) -> AgentSession? {
        guard entry.kind == .session, let id = entry.resumeID else { return nil }
        return sessions.first { session in
            session.logPath?.hasSuffix(id + ".jsonl") == true || registry[session.rootPID] == id || session.extraLogPaths.contains { $0.hasSuffix(id + ".jsonl") }
        }
    }

    public static func restoreSession(_ entry: RecoveryEntry, vault: RecoveryVault, sessions: [AgentSession], registry: [Int32: String], launcher: RecoveryLauncher,
                                      backgroundLauncher: BackgroundLauncher = RecoveryLaunchers.liveBackground) -> Result {
        guard entry.kind == .session, let args = entry.resumeArgs, let primary = entry.cwd else { return .failed("복구 키가 없는 항목입니다") }
        if let running = runningMatch(entry, sessions: sessions, registry: registry) {
            try? vault.update(entry.id) { $0.status = .restored; $0.note = "이미 실행 중 · pid \(running.rootPID)" }
            return .alreadyRunning("이미 돌아와 있습니다 · pid \(running.rootPID)")
        }
        // 잠금 안에서 '보관 중 → 복귀 중'으로 먼저 바꾼다(두 번 누르거나 두 곳에서 동시에 눌러도 한 번만 연다).
        guard (try? vault.transition(entry.id, from: .held, to: .restoring, note: "복귀 실행 중")) == true else {
            return .failed("이미 복귀를 진행 중이거나 보관 중인 항목이 아닙니다")
        }
        func revert(_ why: String) -> Result {
            _ = try? vault.transition(entry.id, from: .restoring, to: .held, note: why)
            return .failed(why)
        }
        // 기록 파일이 지워졌으면(에이전트의 기록 정리 등) 보관본을 원래 자리에 되돌린다.
        if let transcript = entry.transcript, !FileManager.default.fileExists(atPath: transcript) {
            guard let backup = entry.backup, FileManager.default.fileExists(atPath: backup) else { return revert("기록 파일과 보관본이 모두 없어 이어 열 수 없습니다") }
            try? FileManager.default.createDirectory(atPath: (transcript as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if link(backup, transcript) != 0 {
                do { try FileManager.default.copyItem(atPath: backup, toPath: transcript) } catch { return revert("보관본을 되돌리지 못했습니다: \(error.localizedDescription)") }
            }
        }
        // 시작 폴더 → (세션 중 옮겨 간 폴더 · 작업 폴더) 순서로 있는 곳에서 연다.
        guard let cwd = ([primary] + (entry.fallbackCwds ?? [])).first(where: ResumeKey.isDirectory) else {
            return revert("원래 폴더가 없습니다(\(primary)). 폴더를 먼저 되살린 뒤 다시 시도하세요")
        }
        // Claude 백그라운드 세션은 터미널을 열지 않고 백그라운드로 되살린다(같은 짧은 id · 저장된 옵션 그대로).
        if let job = entry.backgroundJob {
            let result = backgroundLauncher(args, cwd, job)
            if result.running {
                try? vault.update(entry.id) { $0.status = .restored; $0.note = result.message }
                return .alreadyRunning(result.message)
            }
            guard result.ok else { return revert(result.message) }
            try? vault.update(entry.id) { $0.note = result.message + (cwd == primary ? "" : " · 대체 폴더 \(cwd)") }
            vault.audit.write(action: "recovery.resume", target: entry.title, result: "launched via background" + (result.copy.map { " copy " + $0 } ?? ""), dryRun: false,
                              detail: ["entry": entry.id, "resume": entry.resumeID ?? "", "job": job])
            return .launched(result.message)
        }
        let result = launcher(RecoveryLaunch(arguments: args, cwd: cwd, title: "복귀 · " + entry.title, terminalHost: entry.terminalHost, terminalDetail: entry.terminalDetail))
        guard result.ok else { return revert(result.message) }
        try? vault.update(entry.id) { $0.note = result.message + (cwd == primary ? "" : " · 대체 폴더 \(cwd)") }
        vault.audit.write(action: "recovery.resume", target: entry.title, result: "launched via \(result.via)", dryRun: false, detail: ["entry": entry.id, "resume": entry.resumeID ?? ""])
        return .launched(result.message)
    }

    /// 휴지통에서 원래 자리로.
    public static func restoreTrash(_ entry: RecoveryEntry, vault: RecoveryVault) -> Result {
        guard entry.kind == .trash, let original = entry.originalPath, let trashed = entry.trashedPath else { return .failed("휴지통 위치가 없는 항목입니다") }
        guard FileManager.default.fileExists(atPath: trashed) else {
            try? vault.update(entry.id) { $0.status = .expired; $0.note = "휴지통에서 비워져 되돌릴 수 없습니다" }
            return .failed("휴지통에서 이미 비워졌습니다")
        }
        guard !FileManager.default.fileExists(atPath: original) else { return .failed("원래 자리에 같은 이름이 있어 덮어쓰지 않습니다: \(original)") }
        do {
            try FileManager.default.createDirectory(atPath: (original as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try FileManager.default.moveItem(atPath: trashed, toPath: original)
        } catch { return .failed("되돌리지 못했습니다: \(error.localizedDescription)") }
        try? vault.update(entry.id) { $0.status = .restored; $0.note = "원래 자리로 되돌림" }
        vault.audit.write(action: "recovery.untrash", target: original, bytes: entry.bytes, result: "ok", dryRun: false, detail: ["entry": entry.id])
        return .restored("원래 자리로 되돌렸습니다")
    }

    /// 지운 브랜치를 같은 커밋으로, 지운 워크트리를 같은 브랜치·커밋으로.
    public static func restoreGit(_ entry: RecoveryEntry, vault: RecoveryVault, git: String = LeftoverTools.findGit()) -> Result {
        guard let repo = entry.repo, let head = entry.head, !head.isEmpty else { return .failed("저장소·커밋 정보가 없는 항목입니다") }
        func run(_ args: [String]) -> CommandResult { Shell.capture(git, ["-C", repo] + args, timeout: 60) }
        var movedNote: String?
        guard run(["cat-file", "-e", head + "^{commit}"]).succeeded else { return .failed("커밋 \(head.prefix(8))을 저장소에서 찾지 못했습니다") }
        switch entry.kind {
        case .branch:
            guard let branch = entry.branch, !branch.hasPrefix("-") else { return .failed("브랜치 이름이 없습니다") }
            if run(["show-ref", "--verify", "--quiet", "refs/heads/" + branch]).succeeded { return .failed("같은 이름의 브랜치가 이미 있습니다: \(branch)") }
            let created = run(["branch", branch, head])
            guard created.succeeded else { return .failed("브랜치를 만들지 못했습니다: \(created.stderr.prefix(160))") }
        case .worktree:
            guard let path = entry.worktreePath else { return .failed("워크트리 경로가 없습니다") }
            guard !FileManager.default.fileExists(atPath: path) else { return .failed("그 자리에 이미 폴더가 있습니다: \(path)") }
            var args = ["worktree", "add", path]
            if let branch = entry.branch, !branch.hasPrefix("-") {
                if !run(["show-ref", "--verify", "--quiet", "refs/heads/" + branch]).succeeded {
                    guard run(["branch", branch, head]).succeeded else { return .failed("브랜치 \(branch)를 되살리지 못했습니다") }
                }
                // 그 사이 브랜치가 다른 커밋으로 움직였으면 기록된 커밋으로 분리 체크아웃한다(보고와 실제가 같게).
                let tip = run(["rev-parse", "refs/heads/" + branch]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if tip == head { args.append(branch) } else { args += ["--detach", head]; movedNote = "브랜치 \(branch)가 그 사이 \(tip.prefix(8))로 움직여, 기록된 커밋에 분리 체크아웃" }
            } else {
                args += ["--detach", head]
            }
            let added = run(args)
            guard added.succeeded else { return .failed("워크트리를 되살리지 못했습니다: \(added.stderr.prefix(160))") }
        default:
            return .failed("git 항목이 아닙니다")
        }
        let done = movedNote ?? "같은 커밋(\(head.prefix(8)))으로 되살림"
        try? vault.update(entry.id) { $0.status = .restored; $0.note = done }
        vault.audit.write(action: "recovery.git", target: entry.title, result: "ok", dryRun: false, detail: ["entry": entry.id, "repo": repo, "head": head])
        return .restored(done)
    }

    /// 앱 다시 띄우기(번들 id · 번들 경로). 실제로는 NSWorkspace(앱 쪽 — open -b와 같다), 시험은 가짜.
    public typealias AppOpener = @Sendable (_ bundleID: String?, _ bundlePath: String?) -> (ok: Bool, message: String)
    /// 이 항목과 같은 프로세스가 지금 떠 있으면 그 pid. since가 있으면 그 뒤에 시작한 것만.
    public typealias ProcessLookup = @Sendable (_ entry: RecoveryEntry, _ since: Date?) -> Int32?

    /// 프로세스 다시 띄우기: 앱은 open -b, 보조 프로세스는 원래 터미널(모르면 터미널)에서 원래 폴더로 옮긴 뒤 같은 명령.
    /// 보관 중 → 다시 띄우는 중(잠금 안에서 한 번만) → reconcile이 새 프로세스를 확인하면 되돌림. 실행이 실패하면 보관 중으로 돌린다.
    public static func restoreProcess(_ entry: RecoveryEntry, vault: RecoveryVault, launcher: RecoveryLauncher, appOpener: AppOpener,
                                      running: ProcessLookup = ProcessRecovery.runningMatch) -> Result {
        guard entry.kind == .process, entry.relaunchable else { return .failed("다시 띄울 명령이 없는 항목입니다") }
        // 이미 떠 있으면(사용자가 직접 다시 띄움) 또 띄우지 않는다 — 같은 포트를 두 번 열거나 같은 앱 창이 겹치지 않게.
        if entry.status == .held, let pid = running(entry, nil) {
            try? vault.update(entry.id) { $0.status = .restored; $0.note = "이미 떠 있음 · pid \(pid)" }
            return .alreadyRunning("이미 떠 있습니다 · pid \(pid)")
        }
        guard (try? vault.transition(entry.id, from: .held, to: .restoring, note: "다시 띄우는 중")) == true else {
            return .failed("이미 다시 띄우는 중이거나 보관 중인 항목이 아닙니다")
        }
        func revert(_ why: String) -> Result {
            _ = try? vault.transition(entry.id, from: .restoring, to: .held, note: why)
            return .failed(why)
        }
        if entry.isAppProcess {
            let opened = appOpener(entry.bundleID, entry.originalPath)
            guard opened.ok else { return revert(opened.message) }
            try? vault.update(entry.id) { $0.note = opened.message }
            vault.audit.write(action: "recovery.relaunch", target: entry.title, result: "launched via open -b", dryRun: false,
                              detail: ["entry": entry.id, "bundle": entry.bundleID ?? entry.originalPath ?? ""])
            return .launched(opened.message)
        }
        guard let arguments = entry.resumeArgs, !arguments.isEmpty else { return revert("다시 띄울 명령이 없습니다") }
        // 개발 서버·빌드 데몬은 폴더(package.json 등)가 중요하다 — 원래 폴더가 없으면 엉뚱한 곳에서 띄우지 않는다.
        let cwd = entry.cwd ?? NSHomeDirectory()
        guard ResumeKey.isDirectory(cwd) else { return revert("원래 폴더가 없습니다(\(cwd)). 폴더를 먼저 되살린 뒤 다시 시도하세요") }
        let result = launcher(RecoveryLaunch(arguments: arguments, cwd: cwd, title: "다시 띄우기 · " + entry.title,
                                             terminalHost: entry.terminalHost, terminalDetail: entry.terminalDetail))
        guard result.ok else { return revert(result.message) }
        try? vault.update(entry.id) { $0.note = result.message }
        vault.audit.write(action: "recovery.relaunch", target: entry.title, result: "launched via \(result.via)", dryRun: false,
                          detail: ["entry": entry.id, "executable": entry.executable ?? ""])
        return .launched(result.message)
    }

    /// Codex 스레드 보관 되돌리기: `codex unarchive <id>` 뒤 상태 DB에서 보관이 풀렸는지 확인한다.
    public static func restoreCodexArchive(_ entry: RecoveryEntry, vault: RecoveryVault, cli: CodexCLI? = CodexCLI.locate(), database: String? = CodexStateReader.locateDatabase()) -> Result {
        guard entry.kind == .codexArchive, let id = entry.resumeID, !id.isEmpty else { return .failed("스레드 id가 없는 항목입니다") }
        let outcome = CodexThreadArchiver.unarchive(id: id, database: database, cli: cli)
        guard outcome.ok else { return .failed(outcome.message) }
        try? vault.update(entry.id) { $0.status = .restored; $0.note = outcome.message }
        vault.audit.write(action: "recovery.codex-unarchive", target: entry.title, result: "ok", dryRun: false, detail: ["entry": entry.id, "thread": id])
        return .restored(outcome.message)
    }

    /// 매 주기: 복귀 확인 중인 세션이 실제로 돌아왔는지, 보관 중인 세션을 사용자가 직접 이어 열었는지 반영한다.
    /// 다시 띄우는 중인 프로세스는 같은 프로세스(실행 파일 · 폴더 · 인자, 앱은 실행 파일)가 새로 떴는지 본다(processLookup — 시험은 가짜).
    @discardableResult
    public static func reconcile(vault: RecoveryVault, sessions: [AgentSession], registry: [Int32: String], now: Date = Date(),
                                 processLookup: ProcessLookup = ProcessRecovery.runningMatch) -> [RecoveryEntry] {
        var changed: [RecoveryEntry] = []
        for entry in vault.all() where entry.kind == .process && entry.status == .restoring {
            // 다시 띄운 뒤에 시작한 것만 본다(15초 여유 — 금고 메모를 고친 시각이 실행 직후라서).
            if let pid = processLookup(entry, entry.updatedAt.addingTimeInterval(-15)) {
                try? vault.update(entry.id) { $0.status = .restored; $0.note = "다시 떠 있음 확인 · pid \(pid)" }
                if let updated = vault.entry(entry.id) { changed.append(updated) }
            } else if now.timeIntervalSince(entry.updatedAt) > 120 {
                let look = entry.isAppProcess ? "Dock에서 앱이 열렸는지 확인하세요" : "열린 터미널 창을 확인하세요"
                try? vault.update(entry.id) { $0.status = .held; $0.note = "다시 뜬 것을 확인하지 못했습니다 — " + look }
                if let updated = vault.entry(entry.id) { changed.append(updated) }
            }
        }
        for entry in vault.all() where entry.kind == .session && (entry.status == .restoring || entry.status == .held) {
            if let running = runningMatch(entry, sessions: sessions, registry: registry) {
                try? vault.update(entry.id) { stored in
                    stored.status = .restored
                    stored.note = (entry.status == .restoring ? "복귀 확인" : "직접 이어 열림") + " · pid \(running.rootPID)"
                }
                if let updated = vault.entry(entry.id) { changed.append(updated) }
            } else if entry.status == .restoring, now.timeIntervalSince(entry.updatedAt) > 120 {
                try? vault.update(entry.id) { $0.status = .held; $0.note = "복귀 확인 안 됨 — 열린 터미널 창을 확인하세요" }
                if let updated = vault.entry(entry.id) { changed.append(updated) }
            }
        }
        return changed
    }
}

// MARK: - 프로세스 복구(세션이 아닌 보조 프로세스·앱)

/// 끝내기 전에 남기는 실행 정보. 비밀값은 가리고, 환경 변수는 정해진 이름만 남긴다.
public struct ProcessLaunch: Sendable, Equatable {
    public var executable: String
    /// 원래 실행 인자(비밀값 가림)
    public var argv: [String]
    public var cwd: String?
    /// 남긴 환경 변수(ProcessRecovery.environmentKeys에 든 이름만)
    public var environment: [String: String]
    /// 가린 비밀값 수
    public var masked: Int
    /// 다시 띄울 명령(cd 없음). 넘길 환경 변수(PORT·NODE_ENV·HOST)가 있으면 /usr/bin/env K=V …를 앞에 붙인다.
    public var command: [String]

    public init(executable: String, argv: [String], cwd: String?, environment: [String: String], masked: Int, command: [String]) {
        self.executable = executable
        self.argv = argv
        self.cwd = cwd
        self.environment = environment
        self.masked = masked
        self.command = command
    }
}

/// 세션이 아닌 프로세스의 복구 기록: 읽기(실행 인자 · 폴더 · 환경 변수) · 비밀값 가리기 · 금고 항목 · 다시 떴는지 찾기.
public enum ProcessRecovery {
    /// 다시 띄울 때 넘기는 환경 변수(서버가 같은 포트·모드로 뜨게).
    public static let relaunchEnvironmentKeys: Set<String> = ["PORT", "NODE_ENV", "HOST"]
    /// 금고에 남기는 환경 변수 이름: 판정용으로 이미 읽는 이름(터미널·에이전트 표시) + 다시 띄울 때 넘기는 이름.
    /// 나머지(비밀값이 섞일 수 있음)는 읽자마자 버린다.
    public static let environmentKeys: Set<String> = ProcessSampler.keptEnvironmentKeys.union(relaunchEnvironmentKeys)
    public static let mask = "••••"

    /// 이름에 들어 있으면 값을 가리는 낱말(인자 이름 · NAME=값의 이름).
    static let secretWords = ["key", "token", "secret", "password", "passwd", "credential"]
    /// 이름과 상관없이 값 모양만으로 가리는 것: 알려진 토큰 형식 · Bearer 뒤 · URL 안의 비밀번호 · "password: 값".
    static let secretShapes: [(NSRegularExpression, String)] = [
        (#"sk-[A-Za-z0-9_\-]{16,}"#, mask),
        (#"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#, mask),
        (#"github_pat_[A-Za-z0-9_]{20,}"#, mask),
        (#"AKIA[0-9A-Z]{16}"#, mask),
        (#"xox[abprs]-[A-Za-z0-9\-]{10,}"#, mask),
        (#"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#, mask),
        (#"(?i)(bearer\s+)[A-Za-z0-9._~+/\-]+=*"#, "$1" + mask),
        (#"(://[^/\s:@]+):[^@\s/]+@"#, "$1:" + mask + "@"),
        (#"(?i)((?:password|passwd|secret|token|api[_-]?key)\s*:\s*)\S+"#, "$1" + mask)
    ].compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }

    /// 실행 인자의 비밀값을 ••••로 가린다: 이름에 key·token·secret·password가 든 인자의 값(--x=값 · NAME=값 · --x 값),
    /// 그리고 알려진 토큰 모양. 첫 칸(실행 파일)에는 이름 규칙을 쓰지 않는다. 이미 가린 인자를 다시 넣어도 같다(다시 뜬 것과 비교할 때).
    public static func maskSecrets(_ argv: [String]) -> (argv: [String], masked: Int) {
        var result = argv
        var masked = 0
        var maskNext = false
        for index in argv.indices {
            let argument = argv[index]
            if maskNext {
                maskNext = false
                // '--token 값'의 값. 다음 칸이 또 플래그면 값이 없는 것으로 본다.
                if !argument.hasPrefix("-") {
                    if argument != mask { masked += 1 }
                    result[index] = mask
                    continue
                }
            }
            if index > 0 {
                if let equals = argument.firstIndex(of: "="), equals != argument.startIndex {
                    let name = argument[..<equals]
                    if isSecretName(name) {
                        let value = argument[argument.index(after: equals)...]
                        if !value.isEmpty, value != mask[...] { masked += 1; result[index] = String(name) + "=" + mask }
                        continue
                    }
                } else if argument.hasPrefix("-"), isSecretName(argument[...]) {
                    maskNext = true
                    continue
                }
            }
            let shaped = maskShapes(argument)
            if shaped != argument { masked += 1; result[index] = shaped }
        }
        return (result, masked)
    }

    static func isSecretName(_ name: Substring) -> Bool {
        let lowered = name.drop { $0 == "-" }.lowercased()
        return !lowered.isEmpty && secretWords.contains { lowered.contains($0) }
    }

    static func maskShapes(_ text: String) -> String {
        var result = text
        for (pattern, template) in secretShapes {
            result = pattern.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return result
    }

    /// 다시 띄울 명령: 첫 칸이 이름뿐이고 실행 파일 이름과 같으면 전체 경로로 바꾼다(터미널의 PATH가 달라도 같은 실행 파일).
    /// 그 밖의 첫 칸(경로 · 프로세스가 스스로 바꾼 이름)은 그대로 둔다 — 실패하면 터미널 창에 종료 코드가 남는다.
    public static func command(executable: String, argv: [String], environment: [String: String]) -> [String] {
        var program = argv.isEmpty ? [executable] : argv
        if let first = program.first, !first.contains("/"), !executable.isEmpty, (executable as NSString).lastPathComponent == first { program[0] = executable }
        let passed = environment.filter { relaunchEnvironmentKeys.contains($0.key) && !$0.value.isEmpty }.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return passed.isEmpty ? program : ["/usr/bin/env"] + passed + program
    }

    /// 읽은 값으로 실행 정보를 만든다(가리기 · 환경 변수 거르기 · 명령 조립). 시험은 프로세스 없이 이것만 부른다.
    public static func launch(executable: String, argv: [String], cwd: String?, environment: [String: String]) -> ProcessLaunch {
        let masked = maskSecrets(argv)
        let kept = environment.filter { environmentKeys.contains($0.key) }
        return ProcessLaunch(executable: executable, argv: masked.argv, cwd: cwd, environment: kept, masked: masked.masked,
                             command: command(executable: executable, argv: masked.argv, environment: kept))
    }

    /// 살아 있는 프로세스에서 읽는다(같은 사용자만). 실행 인자를 못 읽으면 nil — 되살릴 방법이 없으니 부르는 쪽은 끝내지 않는다.
    public static func capture(pid: Int32) -> ProcessLaunch? {
        guard let raw = readLaunch(pid: pid) else { return nil }
        let executable = HelperGuard.executablePath(pid: pid) ?? raw.executable
        guard !executable.isEmpty || !raw.argv.isEmpty else { return nil }
        return launch(executable: executable, argv: raw.argv, cwd: ProcessExplainer.workingDirectory(pid), environment: raw.environment)
    }

    /// KERN_PROCARGS2: 실행 경로 · 인자 · 환경 변수(environmentKeys에 든 이름만 — 나머지는 읽자마자 버린다). ProcessSampler.readArguments와 같은 해석.
    static func readLaunch(pid: Int32) -> (executable: String, argv: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        func readString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        let executable = readString() ?? ""
        while index < size, buffer[index] == 0 { index += 1 }
        var argv: [String] = []
        for _ in 0..<max(0, argc) {
            guard let value = readString() else { break }
            argv.append(value)
            index += 1
        }
        var environment: [String: String] = [:]
        while index < size {
            guard let item = readString() else { break }
            index += 1
            if item.isEmpty { break }
            if let separator = item.firstIndex(of: "="), environmentKeys.contains(String(item[..<separator])) {
                environment[String(item[..<separator])] = String(item[item.index(after: separator)...])
            }
        }
        return (executable, argv, environment)
    }

    /// 출신 세션을 모를 때(관찰 이력 없음) 환경 변수로 원래 터미널을 짐작한다: Orca 변수 · TERM_PROGRAM · 앱 번들 id.
    static func terminalHost(environment: [String: String]) -> String? {
        if environment.keys.contains(where: { $0.hasPrefix("ORCA_") }) { return "Orca" }
        switch environment["TERM_PROGRAM"] {
        case "tmux": return "tmux"
        case "ghostty": return "Ghostty"
        case "iTerm.app": return "iTerm"
        case "Apple_Terminal": return "터미널"
        default: break
        }
        guard let bundle = environment["__CFBundleIdentifier"] else { return nil }
        return TerminalHosts.all.first { $0.bundleID == bundle }?.name
    }

    /// 남은 보조 프로세스 금고 항목. 맨 위 프로세스의 명령을 남긴다(다시 띄우면 하위는 그 명령이 다시 만든다).
    public static func helperEntry(_ helper: OrphanHelper, launch: ProcessLaunch, reason: String, status: RecoveryEntry.Status, now: Date = Date()) -> RecoveryEntry {
        var entry = RecoveryEntry(kind: .process, status: status, project: helper.origin.project, title: helper.displayName, reason: reason, bytes: helper.footprint, now: now)
        entry.agent = helper.origin.agent == SuspectedOrphanScanner.unobserved ? nil : helper.origin.agent.rawValue
        entry.pid = helper.top.pid
        entry.processStart = helper.top.start
        entry.origin = helper.origin.label
        entry.executable = launch.executable
        entry.processArgv = launch.argv
        entry.processEnvironment = launch.environment.isEmpty ? nil : launch.environment
        entry.cwd = launch.cwd ?? helper.origin.cwd
        entry.resumeArgs = launch.command
        entry.resumeCommand = (entry.cwd.map { "cd \(ResumeKey.quote($0)) && " } ?? "") + launch.command.map(ResumeKey.quote).joined(separator: " ")
        entry.terminalHost = helper.origin.terminalHost ?? terminalHost(environment: launch.environment)
        if entry.terminalHost == "tmux" { entry.terminalDetail = TmuxBridge.tmuxVariable(pid: helper.top.pid, start: helper.top.start) }
        var notes = ["\(helper.origin.label) · 프로세스 \(helper.members.count)개"]
        if launch.masked > 0 { notes.append("비밀값 \(launch.masked)개를 ••••로 가림 — 다시 띄우기 전에 명령을 확인하세요") }
        entry.note = notes.joined(separator: " · ")
        return entry
    }

    /// 강제 종료할 앱 금고 항목. 다시 띄우기는 번들 id로(open -b), 번들 id가 없으면 번들 경로로 연다.
    public static func appEntry(name: String, bundleID: String?, bundlePath: String?, executable: String?, pid: Int32, start: Int64?, footprint: UInt64,
                                launch: ProcessLaunch?, reason: String, status: RecoveryEntry.Status, now: Date = Date()) -> RecoveryEntry {
        var entry = RecoveryEntry(kind: .process, status: status, project: name, title: "앱 · \(name)", reason: reason, bytes: footprint, now: now)
        entry.pid = pid
        entry.processStart = start
        entry.bundleID = bundleID
        entry.origin = bundleID ?? bundlePath
        entry.originalPath = bundlePath
        entry.executable = executable ?? launch?.executable
        entry.processArgv = launch?.argv
        entry.processEnvironment = launch.flatMap { $0.environment.isEmpty ? nil : $0.environment }
        entry.resumeCommand = bundleID.map { "open -b \($0)" } ?? bundlePath.map { "open " + ResumeKey.quote($0) }
        entry.note = "강제 종료 전 기록 · 다시 띄우면 앱을 새로 엽니다(저장하지 않은 문서는 앱이 되살릴 수 있을 때만)"
        return entry
    }

    /// 지금 떠 있는 같은 프로세스: 앱은 같은 실행 파일(또는 같은 번들 안), 보조 프로세스는 실행 파일 · 폴더 · 인자(가린 뒤)가 같은 것.
    /// since가 있으면 그 뒤에 시작한 것만(다시 띄운 것 확인용). 내 사용자 프로세스만 본다.
    public static let runningMatch: RecoveryRestorer.ProcessLookup = { entry, since in
        guard entry.kind == .process else { return nil }
        let me = getuid()
        let floor = since.map { Int64($0.timeIntervalSince1970 * 1_000_000) }
        let bundle = entry.originalPath.flatMap { $0.hasSuffix(".app") ? $0 : nil }
        for info in ProcessSampler.allKinfo() {
            let pid = info.kp_proc.p_pid
            guard pid > 1, info.kp_eproc.e_ucred.cr_uid == me, info.kp_proc.p_stat != 5 else { continue }
            let started = info.kp_proc.p_un.__p_starttime
            if let floor, Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec) < floor { continue }
            guard let path = HelperGuard.executablePath(pid: pid) else { continue }
            if entry.isAppProcess {
                if path == entry.executable || bundle.map({ path.hasPrefix($0 + "/Contents/MacOS/") }) == true { return pid }
                continue
            }
            guard path == entry.executable else { continue }
            if let cwd = entry.cwd, ProcessExplainer.workingDirectory(pid) != cwd { continue }
            if let recorded = entry.processArgv, recorded.count > 1 {
                guard let argv = ProcessRecovery.readLaunch(pid: pid)?.argv,
                      Array(ProcessRecovery.maskSecrets(argv).argv.dropFirst()) == Array(recorded.dropFirst()) else { continue }
            }
            return pid
        }
        return nil
    }

    /// pid의 프로세스 키(시작 시각 포함). 없으면 nil.
    public static func processKey(pid: Int32) -> ProcessKey? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return ProcessKey(pid: pid, start: Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec))
    }
}

// MARK: - 영구 삭제해도 되는 캐시(공간 확보)

/// 휴지통으로 옮기면 공간이 돌아오지 않는다. 그래서 '다시 생기는 것'만 영구 삭제하고, 나머지는 휴지통으로 보낸다.
/// 등급(DiskCatalog): A = 순수 캐시 → 영구 삭제(주인 앱이 꺼져 있을 때만) · B = 다시 빌드·설치하면 생김 → 쉬는 것만 영구 삭제
/// (쓰는 세션 폴더 아님 · 하루 안에 안 바뀜 · node_modules는 잠금 파일 있음) · C = 지우지 않음. 기본 제외·권장 명령이 있는 항목도 영구 삭제하지 않는다.
/// 등급 없는 옛 항목은 표의 경로·빌드 산출물 이름으로 등급을 추정한다.
public enum CacheDeletionPolicy {
    public enum Tier: String, Sendable { case pureCache, rebuildable, trashOnly }

    /// running: 실행 중인 앱(nil이면 몇 초 안의 조사 결과를 다시 쓴다).
    public static func tier(for item: DiskItem, activeDirectories: Set<String>, now: Date = Date(), running: RunningApps? = nil) -> Tier {
        // 휴지통·AI 기록·큰 DB·보기만 묶음은 등급과 상관없이 영구 삭제하지 않는다.
        guard item.category == .regenerable else { return .trashOnly }
        guard !item.defaultExcluded, !item.permissionNeeded else { return .trashOnly }
        let inferred = item.grade == nil ? DiskCatalog.inferredGrade(for: item) : nil
        guard let grade = item.grade ?? inferred?.grade, grade != .c else { return .trashOnly }
        if let owner = item.owner, (running ?? RunningApps.recent()).isRunning(owner) { return .trashOnly }
        if let entry = (item.entryID ?? inferred?.entryID).flatMap(DiskCatalog.entry), entry.command != nil || entry.trashPreferred { return .trashOnly }
        if grade == .a { return .pureCache }
        let path = item.path
        let project = (path as NSString).deletingLastPathComponent
        let busy = activeDirectories.contains { $0 == project || $0.hasPrefix(project + "/") || project.hasPrefix($0 + "/") }
        if busy { return .trashOnly }
        // 하루 안에 바뀐 산출물·캐시는 빌드·설치 중일 수 있다.
        if let modified = item.modified, now.timeIntervalSince(modified) < 86_400 { return .trashOnly }
        if (path as NSString).lastPathComponent == "node_modules" {
            let locks = ["package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lockb", "bun.lock"]
            return locks.contains { FileManager.default.fileExists(atPath: project + "/" + $0) } ? .rebuildable : .trashOnly
        }
        return .rebuildable
    }

    /// 정리하지 않는 이유(보기만 · 주인 앱 실행 중 · 명령으로 정리 · 권한 없음). nil이면 정리할 수 있고 방법은 tier가 정한다.
    /// 기본 제외는 이유가 아니다 — 사람이 직접 고르면 휴지통으로 옮긴다.
    public static func blockReason(for item: DiskItem, running: RunningApps? = nil) -> String? {
        if item.permissionNeeded { return "권한이 없어 읽지 못했습니다" }
        switch item.category {
        case .trash, .aiLogs, .bigDatabase: return "이 묶음에서는 정리하지 않습니다(\(item.category.actionHint))"
        default: break
        }
        let grade = item.grade ?? DiskCatalog.inferredGrade(for: item)?.grade
        if grade == .c { return "보기만 하는 항목입니다 — " + (item.hint ?? "지우지 않습니다") }
        if let owner = item.owner, (running ?? RunningApps.recent()).isRunning(owner) { return "\(owner.name) 실행 중 — 종료한 뒤 정리합니다" }
        if let command = item.entryID.flatMap(DiskCatalog.entry)?.command { return "\(command.title) 명령으로 정리합니다" }
        return nil
    }

    public static func regenerationHint(for item: DiskItem) -> String {
        if let hint = item.hint ?? item.entryID.flatMap(DiskCatalog.entry)?.hint { return hint }
        let name = (item.path as NSString).lastPathComponent
        switch name {
        case "node_modules": return "프로젝트 폴더에서 npm/pnpm/yarn install로 다시 생깁니다"
        case ".build", ".build-test": return "swift build로 다시 생깁니다"
        case "DerivedData": return "Xcode가 다음 빌드 때 다시 만듭니다"
        case "_cacache": return "npm이 필요할 때 다시 받습니다"
        case "store": return "pnpm이 필요할 때 다시 받습니다"
        case "Yarn": return "Yarn이 필요할 때 다시 받습니다"
        case "Homebrew": return "Homebrew가 필요할 때 다시 받습니다"
        default: return item.category == .temporary ? "3일 넘은 임시 파일(macOS도 재시동 때 지웁니다)" : "다시 만들어지는 캐시입니다"
        }
    }
}

// MARK: - 보호 고정 키

/// 고정 판정에 쓰는 키: 대화 id(세션 동안 안 바뀜) · 프로세스(pid+시작 시각) · 예전 형식(기록 파일·작업 폴더).
/// 새 세션에 첫 기록이 생기거나 연결이 바뀌어도 고정이 풀리지 않게 하나라도 맞으면 고정으로 본다(10-25 검토).
public enum SessionPins {
    public static func legacyKey(_ session: AgentSession) -> String {
        "\(session.kind.rawValue)|\(session.logPath ?? session.cwd ?? "\(session.rootPID)")"
    }

    public static func keys(_ session: AgentSession, conversationID: String?) -> Set<String> {
        var keys: Set<String> = ["\(session.kind.rawValue)|proc:\(session.id.pid):\(session.id.start)", legacyKey(session)]
        if let conversationID { keys.insert("\(session.kind.rawValue)|conv:\(conversationID)") }
        if let log = session.logPath { keys.insert("\(session.kind.rawValue)|\(log)") }
        if let cwd = session.cwd { keys.insert("\(session.kind.rawValue)|\(cwd)") }
        return keys
    }

    /// 저장할 키: 바뀌지 않는 것(대화 id·프로세스)만 — 작업 폴더 키로 저장하면 같은 폴더의 다른 세션까지 고정된다.
    public static func storedKeys(_ session: AgentSession, conversationID: String?) -> Set<String> {
        keys(session, conversationID: conversationID).filter { $0.contains("|conv:") || $0.contains("|proc:") }
    }
}
