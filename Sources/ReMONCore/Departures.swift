import Darwin
import Foundation

// 세션이 사라졌을 때: 누가·왜 끝냈는지 증거로 판정하고, 복구 키가 있으면 금고에 적어 정신교육실에서 되살린다(10-25 대표 지시).
// 10-25 사고: ReMON이 Claude 창 두 개를 키 없이 끝냈고, 이어 STOREARC Codex가 원인 모르게 끝났다. 매번 사람이 로그를 뒤지지 않게 한다.

/// 세션 프로세스의 끝을 지켜본다 — kqueue EVFILT_PROC(NOTE_EXIT | NOTE_EXITSTATUS | NOTE_EXIT_DETAIL).
/// 자식이 아니어도 같은 사용자 프로세스면 종료 상태(정상 코드·신호)와 macOS 메모리 부족 강제 종료 표시를 받는다(10-25 실측:
/// 더미 sleep에 SIGTERM → 15, SIGKILL → 9, SIGHUP → 1, exit 3 → 0x300).
public final class ExitWatcher: @unchecked Sendable {
    public struct Exit: Sendable, Equatable {
        public var pid: Int32
        public var time: Date
        /// wait 상태: 하위 7비트 = 끝낸 신호, 8~15비트 = 종료 코드
        public var status: Int32
        /// macOS가 메모리 부족으로 강제 종료(jetsam)
        public var memoryKill: Bool

        public init(pid: Int32, time: Date, status: Int32, memoryKill: Bool) {
            self.pid = pid
            self.time = time
            self.status = status
            self.memoryKill = memoryKill
        }

        public var signal: Int32? { let value = status & 0x7F; return value != 0 && value != 0x7F ? value : nil }
        public var exitCode: Int32? { signal == nil ? (status >> 8) & 0xFF : nil }

        /// 사람이 읽는 한 줄. 예: "신호 15(SIGTERM)" · "종료 코드 0" · "메모리 부족 강제 종료(신호 9)"
        public var describe: String {
            if memoryKill { return "macOS 메모리 부족 강제 종료" + (signal.map { "(신호 \($0))" } ?? "") }
            if let signal { return "신호 \(signal)(\(ExitWatcher.signalName(signal)))" }
            return "종료 코드 \(exitCode ?? 0)"
        }

        /// 여러 프로세스가 함께 끝났을 때 가장 많은 것을 말해 주는 쪽을 고르는 순서.
        var severity: Int {
            if memoryKill { return 9 }
            switch signal {
            case .some(SIGSEGV), .some(SIGBUS), .some(SIGILL), .some(SIGABRT), .some(SIGTRAP), .some(SIGFPE), .some(SIGSYS): return 8
            case .some(SIGKILL): return 7
            case .some(SIGTERM): return 6
            case .some(SIGHUP): return 5
            case .some(SIGINT): return 4
            case .some: return 3
            case .none: return (exitCode ?? 0) == 0 ? 1 : 2
            }
        }
    }

    // sys/event.h 값(Darwin 모듈에 없는 것도 있어 직접 적는다).
    static let noteExit: UInt32 = 0x8000_0000
    static let noteExitStatus: UInt32 = 0x0400_0000
    static let noteExitDetail: UInt32 = 0x0200_0000
    static let noteExitMemory: Int = 0x0002_0000

    private let queue: Int32
    private let lock = NSLock()
    private var watched: [Int32: Date] = [:]
    private var exits: [Int32: Exit] = [:]

    public init() {
        queue = kqueue()
        let thread = Thread { [weak self] in self?.loop() }
        thread.name = "remon.exit-watcher"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// 지켜볼 pid를 더한다(이미 보고 있는 것은 건너뛴다). 이미 끝난 pid는 등록이 실패하고 조용히 넘어간다.
    public func watch(_ pids: [Int32]) {
        lock.lock()
        let fresh = pids.filter { $0 > 1 && watched[$0] == nil }
        for pid in fresh { watched[pid] = Date() }
        lock.unlock()
        for pid in fresh {
            var change = kevent(ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ENABLE),
                                fflags: Self.noteExit | Self.noteExitStatus | Self.noteExitDetail, data: 0, udata: nil)
            if kevent(queue, &change, 1, nil, 0, nil) != 0 {
                lock.lock(); watched[pid] = nil; lock.unlock()
            }
        }
    }

    /// 이 pid들이 `since` 뒤에 끝난 기록.
    public func exits(for pids: [Int32], since: Date) -> [Exit] {
        lock.lock(); defer { lock.unlock() }
        return pids.compactMap { exits[$0] }.filter { $0.time >= since.addingTimeInterval(-1) }
    }

    /// 시험용: 끝난 기록을 직접 넣는다.
    public func inject(_ exit: Exit) {
        lock.lock(); exits[exit.pid] = exit; lock.unlock()
    }

    private func loop() {
        var events = [Darwin.kevent](repeating: Darwin.kevent(), count: 32)
        var timeout = timespec(tv_sec: 1, tv_nsec: 0)
        while queue >= 0 {
            let count = kevent(queue, nil, 0, &events, Int32(events.count), &timeout)
            guard count > 0 else { continue }
            let now = Date()
            lock.lock()
            for event in events.prefix(Int(count)) where event.fflags & Self.noteExit != 0 {
                let pid = Int32(event.ident)
                exits[pid] = Exit(pid: pid, time: now, status: Int32(truncatingIfNeeded: event.data & 0xFFFF), memoryKill: event.data & Self.noteExitMemory != 0)
                watched[pid] = nil
            }
            // 10분 지난 기록은 버린다(pid 재사용과 섞이지 않게).
            exits = exits.filter { now.timeIntervalSince($0.value.time) < 600 }
            lock.unlock()
        }
    }

    public static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGQUIT: "SIGQUIT"
        case SIGILL: "SIGILL"
        case SIGTRAP: "SIGTRAP"
        case SIGABRT: "SIGABRT"
        case SIGFPE: "SIGFPE"
        case SIGKILL: "SIGKILL"
        case SIGBUS: "SIGBUS"
        case SIGSEGV: "SIGSEGV"
        case SIGPIPE: "SIGPIPE"
        case SIGTERM: "SIGTERM"
        default: "신호 \(signal)"
        }
    }
}

/// 세션이 끝난 까닭.
public enum DepartureCause: String, Codable, Sendable, CaseIterable {
    case remon, terminalClosed, interrupted, terminated, forceKilled, memory, crash, error, normal, unknown

    public var label: String {
        switch self {
        case .remon: "ReMON이 정리"
        case .terminalClosed: "터미널·탭이 닫힘(SIGHUP)"
        case .interrupted: "중단됨(Ctrl-C·작업 중단)"
        case .terminated: "다른 프로그램·사용자가 종료(SIGTERM)"
        case .forceKilled: "강제 종료(SIGKILL)"
        case .memory: "macOS가 메모리 부족으로 강제 종료"
        case .crash: "크래시"
        case .error: "오류로 끝남"
        case .normal: "정상 종료"
        case .unknown: "원인 미확인"
        }
    }

    /// 사람이 일부러 끝낸 것이 아닐 수 있는 것(정신교육실에 보이고 경고로 알린다). 정상 종료는 복구함 목록에만.
    public var abnormal: Bool { self != .normal && self != .remon }
}

public struct DepartureReport: Sendable, Equatable {
    public var cause: DepartureCause
    /// 종료 상태를 직접 받았으면 false(확인됨), 기록·정황으로만 정했으면 true(추정).
    public var estimated: Bool
    public var evidence: [String]
    public var summary: String { cause.label + (estimated ? "(추정)" : "") }
}

/// 대화 기록의 마지막 모습(끝나기 직전 무엇을 하고 있었나).
public struct TranscriptTail: Sendable, Equatable {
    public enum Kind: String, Sendable { case interrupted, error, completed, userExit, other }
    public var kind: Kind
    public var time: Date?
    public var text: String

    public init(kind: Kind, time: Date?, text: String) {
        self.kind = kind
        self.time = time
        self.text = text
    }
}

public enum DepartureForensics {
    /// 증거를 모아 원인을 정한다. 우선순위: ReMON 기록 → 종료 상태(메모리·신호·코드) → 크래시 보고서 → 대화 기록 끝.
    public static func analyze(exits: [ExitWatcher.Exit], byReMON: Bool, tail: TranscriptTail?, crashReport: String?, pressure: String?) -> DepartureReport {
        let exit = exits.max { $0.severity < $1.severity }
        var evidence: [String] = []
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        if let exit { evidence.append("종료 상태 " + exit.describe + " · " + clock.string(from: exit.time)) }
        if let tail { evidence.append("기록 마지막: " + tail.text + (tail.time.map { " · " + clock.string(from: $0) } ?? "")) }
        if let crashReport { evidence.append("크래시 보고서 " + crashReport) }
        if let pressure { evidence.append("그 시각 메모리 압박 " + pressure) }
        if byReMON { return DepartureReport(cause: .remon, estimated: false, evidence: evidence) }
        if let exit {
            if exit.memoryKill { return DepartureReport(cause: .memory, estimated: false, evidence: evidence) }
            if let signal = exit.signal {
                let cause: DepartureCause = switch signal {
                case SIGHUP: .terminalClosed
                case SIGINT: .interrupted
                case SIGTERM: .terminated
                case SIGKILL: .forceKilled
                default: .crash
                }
                return DepartureReport(cause: cause, estimated: false, evidence: evidence)
            }
            if crashReport != nil { return DepartureReport(cause: .crash, estimated: false, evidence: evidence) }
            if exit.exitCode == 0 {
                // 에이전트는 중단 신호를 받으면 작업을 멈추고 코드 0으로 나가기도 한다(Codex 'turn_aborted · interrupted').
                return DepartureReport(cause: tail?.kind == .interrupted ? .interrupted : .normal, estimated: false, evidence: evidence)
            }
            return DepartureReport(cause: .error, estimated: false, evidence: evidence)
        }
        if crashReport != nil { return DepartureReport(cause: .crash, estimated: true, evidence: evidence) }
        switch tail?.kind {
        case .interrupted: return DepartureReport(cause: .interrupted, estimated: true, evidence: evidence)
        case .error: return DepartureReport(cause: .error, estimated: true, evidence: evidence)
        case .userExit: return DepartureReport(cause: .normal, estimated: true, evidence: evidence)
        default: return DepartureReport(cause: .unknown, estimated: true, evidence: evidence)
        }
    }

    /// 기록 끝 64KB만 읽어 마지막 사건을 본다(대화 기록이 수 GB일 수 있다).
    public static func transcriptTail(_ path: String, kind: AgentKind) -> TranscriptTail? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let data = handle.readDataToEndOfFile()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst(size > 65_536 ? 1 : 0)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let time = (object["timestamp"] as? String).flatMap { iso.date(from: $0) }
            if kind == .codexCLI {
                guard let payload = object["payload"] as? [String: Any], let type = payload["type"] as? String else { continue }
                switch type {
                case "turn_aborted": return TranscriptTail(kind: .interrupted, time: time, text: "작업 중단(" + ((payload["reason"] as? String) ?? "") + ")")
                case "error", "stream_error": return TranscriptTail(kind: .error, time: time, text: "오류 · " + String(((payload["message"] as? String) ?? "").prefix(60)))
                case "task_complete": return TranscriptTail(kind: .completed, time: time, text: "작업 완료")
                case "token_count", "thread_settings_applied", "thread_goal_updated": continue
                default: return TranscriptTail(kind: .other, time: time, text: type)
                }
            } else {
                let message = object["message"] as? [String: Any]
                if object["isApiErrorMessage"] as? Bool == true { return TranscriptTail(kind: .error, time: time, text: "API 오류") }
                if object["type"] as? String == "user", let text = message?["content"] as? String {
                    if text.contains("<command-name>/exit</command-name>") || text.contains("<command-name>/quit</command-name>") {
                        return TranscriptTail(kind: .userExit, time: time, text: "사용자가 /exit")
                    }
                    if text.contains("[Request interrupted by user") { return TranscriptTail(kind: .interrupted, time: time, text: "사용자가 작업 중단") }
                }
                if let type = object["type"] as? String { return TranscriptTail(kind: .other, time: time, text: type == "assistant" ? "답변 중" : type) }
            }
        }
        return nil
    }

    /// 끝난 시각 ±2분 안에 생긴 크래시 보고서(이름이 프로세스 이름으로 시작).
    public static func crashReport(near time: Date, names: [String],
                                   folder: String = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Logs/DiagnosticReports") -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return nil }
        let lowered = names.map { $0.lowercased() }.filter { !$0.isEmpty }
        for file in files where file.hasSuffix(".ips") || file.hasSuffix(".crash") {
            let name = file.lowercased()
            guard lowered.contains(where: { name.hasPrefix($0) }) else { continue }
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: folder + "/" + file))?[.modificationDate] as? Date,
                  abs(modified.timeIntervalSince(time)) < 120 else { continue }
            return file
        }
        return nil
    }
}

/// ReMON이 끄지 않은 세션이 사라졌을 때 금고에 적는다: 복구 키가 있으면 '보관 중'(정신교육실에서 복귀), 없으면 '사라짐'(무엇이 있었는지만).
public enum DepartureRecorder {
    @discardableResult
    public static func record(_ session: AgentSession, report: DepartureReport, vault: RecoveryVault) -> RecoveryEntry? {
        // ReMON이 정리한 세션은 정리할 때 이미 적었다.
        if vault.all().contains(where: { $0.kind == .session && $0.pid == session.rootPID && $0.processStart == session.id.start }) { return nil }
        let key = ResumeKey.resolve(session, registrySessionID: session.registrySessionID, argv: session.launchArgv, registryKind: session.registryKind)
        var entry = SessionRetirer.entry(for: session, key: key, reason: "스스로 끝남 · " + report.summary, status: key.key == nil ? .gone : .held, vault: vault)
        entry.departure = report.cause.rawValue
        entry.note = ([report.summary] + report.evidence + [entry.note].compactMap { $0 }).joined(separator: " · ")
        do { try vault.add(entry) } catch {
            if let backup = entry.backup { try? FileManager.default.removeItem(atPath: backup) }
            return nil
        }
        vault.audit.write(action: "session.departed", target: "\(session.kind.label) \(session.project) pid \(session.rootPID)", result: report.cause.rawValue, dryRun: false,
                          detail: ["evidence": report.evidence.joined(separator: " | "), "restorable": key.key == nil ? "no" : "yes"])
        return entry
    }
}
