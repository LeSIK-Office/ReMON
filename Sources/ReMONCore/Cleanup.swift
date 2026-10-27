import Darwin
import Foundation

/// 모든 행동은 ~/Library/Logs/ReMON/actions.jsonl에 남긴다(시각·대상·크기·결과, 사양 5장).
public final class AuditLog: @unchecked Sendable {
    public static let shared = ProcessInfo.processInfo.environment["REMON_VAULT_DIR"].map {
        AuditLog(url: URL(fileURLWithPath: $0).appendingPathComponent("actions.jsonl"))
    } ?? AuditLog()
    private let lock = NSLock()
    public var url: URL

    public init(url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ReMON/actions.jsonl")) {
        self.url = url
    }

    public func write(action: String, target: String, bytes: UInt64 = 0, result: String, dryRun: Bool, detail: [String: Any] = [:]) {
        var entry: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "action": action, "target": target,
                                    "bytes": bytes, "result": result, "dryRun": dryRun]
        for (key, value) in detail { entry[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }
}

/// 종료 금지(하드 차단)와 소리칠 이유(경고)를 구분한다.
public struct ProtectionContext: Sendable {
    public var selfPID: Int32
    /// ReMON을 띄운 프로세스 조상들(이 앱을 띄운 세션 보호).
    public var launcherPIDs: Set<Int32>
    public var pinnedKeys: Set<String>

    public init(selfPID: Int32 = getpid(), launcherPIDs: Set<Int32> = ProtectionContext.ancestors(of: getpid()), pinnedKeys: Set<String> = []) {
        self.selfPID = selfPID
        self.launcherPIDs = launcherPIDs
        self.pinnedKeys = pinnedKeys
    }

    public static func ancestors(of pid: Int32) -> Set<Int32> {
        var result = Set<Int32>()
        var current = pid
        for _ in 0..<64 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { break }
            let parent = info.kp_eproc.e_ppid
            if parent <= 1 { break }
            result.insert(parent)
            current = parent
        }
        return result
    }
}

public enum Protection {
    public static let systemNames: Set<String> = ["launchd", "kernel_task", "WindowServer", "loginwindow", "Dock", "Finder", "SystemUIServer", "ControlCenter", "coreaudiod", "mds", "mds_stores", "opendirectoryd", "securityd", "trustd", "cfprefsd"]

    /// 하드 차단 사유(하나라도 있으면 종료 시도 자체를 하지 않는다).
    public static func blockers(for session: AgentSession, members: [ProcRecord], environments: [Int32: [String: String]], context: ProtectionContext, pinKey: String) -> [String] {
        var reasons: [String] = []
        let pids = Set(members.map(\.pid))
        if pids.contains(context.selfPID) { reasons.append("ReMON 자신이 이 세션 안에 있습니다") }
        if !pids.isDisjoint(with: context.launcherPIDs) || context.launcherPIDs.contains(session.rootPID) { reasons.append("ReMON을 띄운 세션입니다") }
        if context.pinnedKeys.contains(pinKey) { reasons.append("보호 고정된 세션입니다") }
        if members.contains(where: { $0.uid != getuid() || systemNames.contains($0.name) }) { reasons.append("시스템 프로세스가 포함돼 있습니다") }
        if members.contains(where: { environments[$0.pid]?["CFFIXED_USER_HOME"] != nil }) { reasons.append("측정·시험 하네스가 띄운 프로세스입니다(CFFIXED_USER_HOME)") }
        if members.contains(where: { ($0.path ?? "").contains("/Orca.app/") || ($0.path ?? "").contains("/orca/daemon-host/") }) { reasons.append("Orca 호스트입니다") }
        return reasons
    }

    /// 종료는 가능하지만 끌려가며 소리칠 이유.
    public static func warnings(for session: AgentSession, now: Date = Date()) -> [String] {
        var reasons: [String] = []
        if let last = session.lastActivity, now.timeIntervalSince(last) < 120 { reasons.append("\(Fmt.ago(last, now: now))까지 작업 기록이 있습니다") }
        if session.cpuPercent >= 5 { reasons.append("지금 CPU \(Fmt.percent(session.cpuPercent))를 쓰고 있습니다") }
        if session.state == .waiting { reasons.append("입력을 기다리는 중일 수 있습니다") }
        if session.childCount > 0 { reasons.append("하위 프로세스 \(session.childCount)개 · 메모리 \(Fmt.size(session.footprint))") }
        if session.resumeCommand == nil { reasons.append("이어 열기 명령을 만들지 못했습니다(기록 연결 없음)") }
        return reasons
    }
}

/// 세션 종료 순서(사양 5장): 미리보기 → 확인 → 루트 SIGTERM → 5초 대기 → 남은 하위만 SIGKILL(재확인) → 실제 회수량 기록.
public final class SessionTerminator: @unchecked Sendable {
    public struct Plan: Sendable {
        public var session: AgentSession
        public var targets: [ProcessKey]
        public var reclaimEstimate: UInt64
        public var blockers: [String]
        public var warnings: [String]
        public var preview: String
    }

    public struct Outcome: Sendable {
        public var terminated: [ProcessKey]
        public var remaining: [ProcessKey]
        public var reclaimed: UInt64
        public var killedRemaining: Bool
        public var dryRun: Bool
        public var blocked: Bool
        public var message: String
    }

    public let registry: TerminationRegistry
    public var audit = AuditLog.shared
    public var waitSeconds: TimeInterval = 5
    /// 신호 송신(시험에서 기록용으로 바꿔 '보호 대상 종료 시도 0건'을 증명한다).
    public var signalSender: @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }

    public init(registry: TerminationRegistry) { self.registry = registry }

    public func plan(session: AgentSession, members: [ProcRecord], environments: [Int32: [String: String]], context: ProtectionContext, pinKey: String) -> Plan {
        let blockers = Protection.blockers(for: session, members: members, environments: environments, context: context, pinKey: pinKey)
        let warnings = Protection.warnings(for: session)
        var lines = ["대상: \(session.kind.label) · \(session.project) · pid \(session.rootPID) 외 하위 \(session.childCount)개",
                     "회수될 메모리(추정): \(Fmt.size(session.footprint))",
                     "마지막 활동: \(Fmt.ago(session.lastActivity))"]
        if let resume = session.resumeCommand { lines.append("이어 열기: \(resume)") }
        return Plan(session: session, targets: members.map(\.key), reclaimEstimate: session.footprint, blockers: blockers, warnings: warnings, preview: lines.joined(separator: "\n"))
    }

    /// force=false: SIGTERM 후 남은 하위는 confirmKill이 true일 때만 SIGKILL. force=true: 확인을 이미 받은 강제 종료(SIGKILL 전체).
    public func execute(_ plan: Plan, dryRun: Bool, force: Bool, footprints: [ProcessKey: UInt64], confirmKill: @escaping @Sendable ([ProcessKey]) -> Bool) -> Outcome {
        let target = "\(plan.session.kind.label) \(plan.session.project) pid \(plan.session.rootPID)"
        guard plan.blockers.isEmpty else {
            audit.write(action: force ? "session.force" : "session.terminate", target: target, result: "blocked: " + plan.blockers.joined(separator: "; "), dryRun: dryRun)
            return Outcome(terminated: [], remaining: plan.targets, reclaimed: 0, killedRemaining: false, dryRun: dryRun, blocked: true, message: "보호 대상이라 종료하지 않았습니다: " + plan.blockers.joined(separator: ", "))
        }
        if dryRun {
            audit.write(action: force ? "session.force" : "session.terminate", target: target, bytes: plan.reclaimEstimate, result: "dry-run", dryRun: true, detail: ["pids": plan.targets.map { Int($0.pid) }])
            return Outcome(terminated: plan.targets, remaining: [], reclaimed: plan.reclaimEstimate, killedRemaining: false, dryRun: true, blocked: false,
                           message: "드라이런: \(plan.targets.count)개 프로세스를 종료하면 약 \(Fmt.size(plan.reclaimEstimate))를 회수합니다")
        }
        let root = plan.targets.first { $0.pid == plan.session.rootPID }
        if force {
            for key in plan.targets where Self.isAlive(key) {
                registry.record(key, .evictedByReMON)
                _ = signalSender(key.pid, SIGKILL)
            }
        } else if let root, Self.isAlive(root) {
            registry.record(root, .releasedByReMON)
            _ = signalSender(root.pid, SIGTERM)
            // 일시 정지(Ctrl-Z)된 프로세스는 SIGTERM이 보류된다 → 깨워야 실제로 끝난다(수동 정리에서만 여기까지 온다).
            if Self.isStopped(root) { _ = signalSender(root.pid, SIGCONT) }
        }
        let deadline = Date().addingTimeInterval(force ? 1.5 : waitSeconds)
        while Date() < deadline, plan.targets.contains(where: Self.isAlive) { usleep(250_000) }
        var remaining = plan.targets.filter(Self.isAlive)
        var killed = false
        if !remaining.isEmpty, !force, confirmKill(remaining) {
            // 재확인: 같은 pid라도 시작 시각이 같을 때만(재사용된 pid 보호).
            for key in remaining where Self.isAlive(key) {
                registry.record(key, .releasedByReMON)
                _ = signalSender(key.pid, SIGKILL)
            }
            killed = true
            let killDeadline = Date().addingTimeInterval(2)
            while Date() < killDeadline, remaining.contains(where: Self.isAlive) { usleep(100_000) }
            remaining = remaining.filter(Self.isAlive)
        }
        let terminated = plan.targets.filter { !remaining.contains($0) }
        let reclaimed = terminated.reduce(UInt64(0)) { $0 + (footprints[$1] ?? 0) }
        audit.write(action: force ? "session.force" : "session.terminate", target: target, bytes: reclaimed, result: remaining.isEmpty ? "ok" : "partial", dryRun: false,
                    detail: ["terminated": terminated.map { Int($0.pid) }, "remaining": remaining.map { Int($0.pid) }, "sigkill_remaining": killed])
        let message = remaining.isEmpty ? "\(terminated.count)개 프로세스 종료 · 약 \(Fmt.size(reclaimed)) 회수" : "\(remaining.count)개 프로세스가 남아 있습니다"
        return Outcome(terminated: terminated, remaining: remaining, reclaimed: reclaimed, killedRemaining: killed, dryRun: false, blocked: false, message: message)
    }

    /// 일시 정지(SSTOP)된 프로세스인지(같은 시작 시각일 때만).
    public static func isStopped(_ key: ProcessKey) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, key.pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        let tv = info.kp_proc.p_un.__p_starttime
        return Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec) == key.start && info.kp_proc.p_stat == 4
    }

    /// pid가 살아 있고, 시작 시각까지 같은 프로세스인지.
    public static func isAlive(_ key: ProcessKey) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, key.pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        let tv = info.kp_proc.p_un.__p_starttime
        let start = Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec)
        // 좀비(SZOMB)는 이미 끝난 것으로 본다.
        return start == key.start && info.kp_proc.p_stat != 5
    }
}

/// 파일 정리 안전장치: 절대 경로 확정, 홈·시스템·볼륨 루트 하드 금지, 열린 파일 확인, 기본은 휴지통.
public enum SafeFileOps {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAbsolute(String), forbidden(String), missing(String), inUse(String, [Int32]), failed(String)
        public var description: String {
            switch self {
            case .notAbsolute(let path): "절대 경로가 아닙니다: \(path)"
            case .forbidden(let path): "보호 경로라 지울 수 없습니다: \(path)"
            case .missing(let path): "경로가 없습니다: \(path)"
            case .inUse(let path, let pids): "열린 파일이 있습니다(pid \(pids.map(String.init).joined(separator: ","))): \(path)"
            case .failed(let message): message
            }
        }
    }

    /// - removal: 휴지통·영구 삭제(외장 이전은 false). allowClaudeTranscript: AI 데이터 위생이 Claude 기록 하나를 휴지통으로 옮길 때만.
    public static func validate(_ rawPath: String, removal: Bool = false, allowClaudeTranscript: Bool = false) throws -> URL {
        guard rawPath.hasPrefix("/"), !rawPath.isEmpty else { throw Failure.notAbsolute(rawPath) }
        // 마지막 항목이 링크면 링크 자체를 다룬다(외장 이전 링크를 지울 때 대상이 지워지면 안 됨). 부모만 실제 경로로 확정.
        // resolvingSymlinksInPath는 /private/tmp를 /tmp로 바꿔 커널이 알려 주는 열린 파일 경로(/private/…)와 어긋난다 → realpath 사용.
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL
        let parent = canonical(standardized.deletingLastPathComponent().path)
        let url = URL(fileURLWithPath: parent).appendingPathComponent(standardized.lastPathComponent)
        let path = url.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let forbiddenExact: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private", "/private/tmp", "/private/var", "/usr", "/bin", "/sbin", "/etc", "/var", "/tmp", "/opt", "/cores",
                                            home, home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/DEV", home + "/.Trash", home + "/.codex", home + "/.claude"]
        if forbiddenExact.contains(path) || path.count < 6 { throw Failure.forbidden(path) }
        if ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains(where: { path.hasPrefix($0) }) { throw Failure.forbidden(path) }
        let components = url.pathComponents
        if components.count <= 3 && components.first == "/" && components.dropFirst().first == "Volumes" { throw Failure.forbidden(path) } // 볼륨 루트
        // AI 대화 원본·첨부·자격 증명·Codex DB·AI 앱 로그인 데이터(AIDataProtection). ~/.claude/projects 안은 위생 기능의 기록 휴지통만.
        if AIDataProtection.reason(for: path, home: home, removal: removal, allowClaudeTranscript: allowClaudeTranscript) != nil { throw Failure.forbidden(path) }
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Failure.missing(path) }
        return url
    }

    /// 커널과 같은 정식 경로(realpath). 없는 경로면 그대로 돌려준다.
    public static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 해당 경로 아래 파일을 연 사용자 프로세스. lsof 대신 proc_pidinfo를 쓴다. 비교는 양쪽 모두 정식 경로로 한다.
    public static func openFileUsers(under rawPath: String, pids: [Int32]) -> [Int32] {
        let path = canonical(rawPath)
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return pids.filter { pid in
            ProcessSampler.openFiles(pid: pid).contains { file in
                file == path || file.hasPrefix(prefix) || file == rawPath || file.hasPrefix(rawPath.hasSuffix("/") ? rawPath : rawPath + "/")
            }
        }
    }

    /// 금고에 먼저 적고 휴지통으로 옮긴다. vault가 nil이면 호출자가 미리 기록한 조치다.
    public static func moveToTrash(_ rawPath: String, userPIDs: [Int32], dryRun: Bool, bytes: UInt64, audit: AuditLog = .shared,
                                   vault: RecoveryVault? = nil, project: String = "", reason: String = "파일 정리", allowClaudeTranscript: Bool = false,
                                   entry: RecoveryEntry? = nil) throws -> URL? {
        let url = try validate(rawPath, removal: true, allowClaudeTranscript: allowClaudeTranscript)
        let users = openFileUsers(under: url.path, pids: userPIDs)
        guard users.isEmpty else {
            audit.write(action: "file.trash", target: url.path, bytes: bytes, result: "blocked: in use", dryRun: dryRun)
            throw Failure.inUse(url.path, users)
        }
        if dryRun {
            audit.write(action: "file.trash", target: url.path, bytes: bytes, result: "dry-run", dryRun: true)
            return nil
        }
        var recorded = entry ?? RecoveryEntry(kind: .trash, status: .retiring, project: project, title: url.lastPathComponent, reason: reason, bytes: bytes)
        recorded.status = .retiring
        recorded.originalPath = url.path
        recorded.restoreHint = "Finder 휴지통에서 '되돌려 놓기'"
        if let vault { try vault.add(recorded) }
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch {
            if let vault { try? vault.remove(recorded.id) }
            audit.write(action: "file.trash", target: url.path, bytes: bytes, result: "error: \(error.localizedDescription)", dryRun: false)
            throw Failure.failed(error.localizedDescription)
        }
        audit.write(action: "file.trash", target: url.path, bytes: bytes, result: "ok", dryRun: false, detail: ["trashed_to": resulting?.path ?? ""])
        if let vault {
            do {
                try vault.update(recorded.id) {
                    $0.status = .held
                    $0.trashedPath = resulting?.path
                    if resulting == nil { $0.note = "휴지통 위치 미확인 · Finder에서 되돌려 놓기" }
                }
            } catch {
                if let trashed = resulting as URL?, !FileManager.default.fileExists(atPath: url.path),
                   (try? FileManager.default.moveItem(at: trashed, to: url)) != nil {
                    try? vault.remove(recorded.id)
                    throw Failure.failed("금고에 휴지통 위치를 기록하지 못해 원래 자리로 되돌렸습니다")
                }
                throw Failure.failed("휴지통으로 옮겼지만 금고 갱신에 실패했습니다. Finder 휴지통에서 되돌려 놓으세요")
            }
        }
        return resulting as URL?
    }

    /// 영구 삭제. 되돌릴 수 없으므로 재생성 캐시에만 쓰고, 무엇을 지웠고 어떻게 다시 생기는지를 금고에 남긴다.
    public static func deletePermanently(_ rawPath: String, userPIDs: [Int32], dryRun: Bool, bytes: UInt64, audit: AuditLog = .shared,
                                         vault: RecoveryVault? = nil, project: String = "", reason: String = "파일 정리", regeneration: String? = nil) throws {
        let url = try validate(rawPath, removal: true)
        let users = openFileUsers(under: url.path, pids: userPIDs)
        guard users.isEmpty else { throw Failure.inUse(url.path, users) }
        if dryRun {
            audit.write(action: "file.delete", target: url.path, bytes: bytes, result: "dry-run", dryRun: true)
            return
        }
        var entry = RecoveryEntry(kind: .deleted, status: .retiring, project: project, title: url.lastPathComponent, reason: reason, bytes: bytes)
        entry.originalPath = url.path
        entry.restoreHint = regeneration ?? "다시 만들어지는 캐시입니다"
        entry.note = "영구 삭제 예정 · 되돌릴 수 없음(재생성)"
        if let vault { try vault.add(entry) }
        do { try FileManager.default.removeItem(at: url) } catch {
            if let vault { try? vault.remove(entry.id) }
            audit.write(action: "file.delete", target: url.path, bytes: bytes, result: "error: \(error.localizedDescription)", dryRun: false)
            throw Failure.failed(error.localizedDescription)
        }
        audit.write(action: "file.delete", target: url.path, bytes: bytes, result: "ok", dryRun: false)
        if let vault {
            try vault.update(entry.id) { $0.status = .gone; $0.note = "영구 삭제 · 되돌릴 수 없음(재생성)" }
        }
    }
}

/// 메뉴 막대·정리 화면의 제안. 예상 회수량 순으로 보인다.
public struct CleanupSuggestion: Identifiable, Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case sessions([ProcessKey])
        case trashPaths([String])
        case migratePaths([String])
        case info
    }

    public var id: String
    public var title: String
    public var detail: String
    public var reclaimBytes: UInt64
    public var action: Action

    public init(id: String, title: String, detail: String, reclaimBytes: UInt64, action: Action) {
        self.id = id
        self.title = title
        self.detail = detail
        self.reclaimBytes = reclaimBytes
        self.action = action
    }
}
