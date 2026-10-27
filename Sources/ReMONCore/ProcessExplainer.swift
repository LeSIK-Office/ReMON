import Darwin
import Foundation
import IOKit.pwr_mgt

// '왜 실행 중?'(G3) — pid 하나에 대해 루트 권한 없이 모을 수 있는 근거를 모은다.
// 계보(launchd까지, 터미널·에이전트 홉 표시) · launchd 라벨 · 리슨 포트 · 잠자기 방지 · 작업 폴더와 git · 경고.
// 다른 사용자·루트 프로세스는 커널이 일부를 막는다 → 그 항목은 '권한 없음'으로 적고 나머지를 보여 준다.

// MARK: - 리슨 포트

/// 열려 있는 TCP 리슨 소켓·바인드된 UDP 소켓(PROC_PIDLISTFDS + PROC_PIDFDSOCKETINFO).
public struct ListeningSocket: Sendable, Hashable {
    public enum Proto: String, Sendable { case tcp, udp }
    public var proto: Proto
    /// "127.0.0.1" · "::1" · "0.0.0.0" · "::" · "192.168.0.3"
    public var address: String
    public var port: UInt16
    public var isIPv6: Bool

    public init(proto: Proto, address: String, port: UInt16, isIPv6: Bool) {
        self.proto = proto
        self.address = address
        self.port = port
        self.isIPv6 = isIPv6
    }

    public var isWildcard: Bool { address == "0.0.0.0" || address == "::" || address == "::ffff:0.0.0.0" }
    public var isLoopback: Bool { address.hasPrefix("127.") || address == "::1" || address.hasPrefix("::ffff:127.") }
    /// 화면 표기: 127.0.0.1:5173 · *:3000 · [::1]:8080
    public var display: String { (isWildcard ? "*" : (isIPv6 ? "[\(address)]" : address)) + ":\(port)" }
    public var scopeLabel: String { isLoopback ? "이 Mac에서만" : (isWildcard ? "모든 인터페이스 · 외부 접속 가능" : "외부 접속 가능") }
}

public enum ListeningSockets {
    /// nil = 파일 목록을 읽을 권한이 없음(다른 사용자·루트 프로세스).
    public static func list(pid: Int32) -> [ListeningSocket]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { raw in proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count)) }
        guard filled > 0 else { return nil }
        var result: [ListeningSocket] = []
        var seen = Set<ListeningSocket>()
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            guard info.psi.soi_family == AF_INET || info.psi.soi_family == AF_INET6 else { continue }
            let ini: in_sockinfo
            let proto: ListeningSocket.Proto
            if info.psi.soi_kind == SOCKINFO_TCP {
                guard info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
                proto = .tcp
            } else if info.psi.soi_kind == SOCKINFO_IN, info.psi.soi_protocol == IPPROTO_UDP {
                ini = info.psi.soi_proto.pri_in
                // 연결된 UDP(상대 포트가 있음)는 받는 소켓이 아니다.
                guard ini.insi_fport == 0 else { continue }
                proto = .udp
            } else {
                continue
            }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            guard port != 0 else { continue }
            let socket: ListeningSocket
            if ini.insi_vflag & UInt8(INI_IPV4) != 0 && ini.insi_vflag & UInt8(INI_IPV6) == 0 {
                var address = ini.insi_laddr.ina_46.i46a_addr4
                socket = ListeningSocket(proto: proto, address: ntop(AF_INET, &address, Int(INET_ADDRSTRLEN)), port: port, isIPv6: false)
            } else {
                var address = ini.insi_laddr.ina_6
                socket = ListeningSocket(proto: proto, address: ntop(AF_INET6, &address, Int(INET6_ADDRSTRLEN)), port: port, isIPv6: true)
            }
            if seen.insert(socket).inserted { result.append(socket) }
        }
        return result.sorted { ($0.proto.rawValue, $0.port) < ($1.proto.rawValue, $1.port) }
    }

    private static func ntop<T>(_ family: Int32, _ address: inout T, _ length: Int) -> String {
        var buffer = [CChar](repeating: 0, count: length)
        let ok = withUnsafePointer(to: &address) { pointer in inet_ntop(family, pointer, &buffer, socklen_t(length)) != nil }
        return ok ? String(cString: buffer) : "?"
    }
}

// MARK: - 잠자기 방지

public struct PowerAssertion: Sendable, Equatable {
    public var type: String
    public var name: String

    /// 시스템·화면 잠자기를 실제로 막는 종류인가.
    public var preventsSleep: Bool {
        ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"].contains(type)
    }

    public var typeLabel: String {
        switch type {
        case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion": "시스템 잠자기 방지"
        case "PreventSystemSleep": "시스템 잠자기 방지(덮개 포함)"
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": "화면 꺼짐 방지"
        case "PreventDiskIdle": "디스크 잠자기 방지"
        case "UserIsActive": "사용자 활동 표시"
        case "BackgroundTask": "백그라운드 작업"
        default: type
        }
    }
}

public enum PowerAssertions {
    /// IOPMCopyAssertionsByProcess — 권한 없이 모든 프로세스의 assertion을 돌려준다.
    public static func byProcess() -> [Int32: [PowerAssertion]] {
        var dictionary: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dictionary) == kIOReturnSuccess, let raw = dictionary?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [:] }
        var result: [Int32: [PowerAssertion]] = [:]
        for (pid, items) in raw {
            result[pid.int32Value] = items.map { PowerAssertion(type: $0["AssertType"] as? String ?? "?", name: $0["AssertName"] as? String ?? "") }
        }
        return result
    }

    public static func list(pid: Int32) -> [PowerAssertion] { byProcess()[pid] ?? [] }
}

// MARK: - git

public struct GitInfo: Sendable, Equatable {
    /// 저장소(또는 워크트리) 최상위 폴더
    public var root: String
    public var branch: String?
    /// 브랜치가 아닐 때(분리된 HEAD) 커밋 앞 8자리
    public var head: String?
    public var isWorktree: Bool

    /// 폴더에서 위로 올라가며 .git을 찾는다(git 명령 없이 HEAD 파일만 읽음).
    public static func find(from directory: String) -> GitInfo? {
        var current = (directory as NSString).standardizingPath
        for _ in 0..<64 {
            let dotGit = current + "/.git"
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                var gitDirectory = dotGit
                var worktree = false
                if !isDirectory.boolValue {
                    // 워크트리·서브모듈: "gitdir: <경로>"
                    guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8), let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDirectory = target.hasPrefix("/") ? target : (current as NSString).appendingPathComponent(target)
                    worktree = true
                }
                let head = (try? String(contentsOfFile: gitDirectory + "/HEAD", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if head.hasPrefix("ref: refs/heads/") {
                    return GitInfo(root: current, branch: String(head.dropFirst("ref: refs/heads/".count)), head: nil, isWorktree: worktree)
                }
                return GitInfo(root: current, branch: nil, head: head.isEmpty ? nil : String(head.prefix(8)), isWorktree: worktree)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
        return nil
    }
}

// MARK: - 설명

public struct ProcessExplanation: Sendable {
    public struct Hop: Sendable, Equatable, Identifiable {
        public enum Role: Sendable, Equatable {
            case launchd
            case terminal(String)
            case agent(String)
            case shell
            case app(String)
            case helper(HelperKind)
            case process
        }
        public var pid: Int32
        public var name: String
        public var path: String?
        public var uid: UInt32
        public var role: Role
        /// 세션 정보 등 덧붙임(예: "Claude Code 세션 · ReMON")
        public var note: String?
        public var id: Int32 { pid }

        public var roleLabel: String? {
            switch role {
            case .launchd: "시스템 시작 관리자"
            case .terminal(let name): "터미널 · \(name)"
            case .agent(let name): "에이전트 · \(name)"
            case .shell: "셸"
            case .app(let name): "앱 · \(name)"
            case .helper(let kind): kind.label
            case .process: nil
            }
        }
    }

    public struct Warning: Sendable, Equatable, Identifiable {
        public enum Kind: String, Sendable { case executableDeleted, executableReplaced, dyld, zombie, stopped, longRunning, publicListener, preventsSleep }
        public var kind: Kind
        public var text: String
        public var id: String { kind.rawValue }
    }

    public struct Launchd: Sendable, Equatable {
        /// launchd 바로 아래 홉(이 프로세스이거나 그 조상)
        public var pid: Int32
        public var label: String
        public var plistPath: String?
        /// "gui/501" · "system"
        public var domain: String
        /// 무엇으로 찾았는지(launchd 목록의 pid · plist 실행 경로)
        public var matchedBy: String
        public var state: LaunchdJobState?
        public var runAtLoad: Bool?
        public var keepAlive: StartupItem.KeepAlive?
        /// application.* 라벨 = Launch Services가 앱으로 띄운 것
        public var launchedAsApp: Bool { label.hasPrefix("application.") }
    }

    public var pid: Int32
    public var exists: Bool
    public var name: String = ""
    public var path: String?
    public var command: String?
    public var uid: UInt32 = 0
    public var user: String = ""
    public var ppid: Int32 = 0
    public var startTime: Date?
    /// 실행 중 · 대기 · 정지 · 좀비
    public var status: String = ""
    public var footprint: UInt64?
    /// 이 프로세스 → … → launchd
    public var chain: [Hop] = []
    public var launchd: Launchd?
    /// nil = 권한 없음
    public var sockets: [ListeningSocket]?
    public var assertions: [PowerAssertion] = []
    public var cwd: String?
    public var git: GitInfo?
    /// ReMON이 세션 하위로 본 기록(남은 보조 프로세스)
    public var origin: HelperOrigin?
    public var helperKind: HelperKind?
    public var warnings: [Warning] = []
    /// 권한 부족 등 못 읽은 항목
    public var notes: [String] = []
}

public enum ProcessExplainer {
    public static let longRunningDays: Double = 90
    static let terminalMarks: [(String, String)] = [("/Orca.app/", "Orca"), ("/orca/daemon-host/", "Orca"), ("/Ghostty.app/", "Ghostty"), ("/Terminal.app/", "터미널"),
                                                    ("/iTerm", "iTerm"), ("cmux", "cmux"), ("/Visual Studio Code.app/", "VS Code"), ("/Cursor.app/", "Cursor"),
                                                    ("/Warp.app/", "Warp"), ("/WezTerm.app/", "WezTerm"), ("/kitty.app/", "kitty"), ("/Alacritty.app/", "Alacritty")]
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "login", "nu"]

    /// - sessions: 지금 세션 목록(에이전트 홉에 프로젝트를 붙인다)
    /// - origin: 남은 보조 프로세스라면 그 출신 기록(HelperTracker.origin(for:))
    /// - run: launchctl 실행기(시험에서 바꾼다)
    public static func explain(pid: Int32, sessions: [AgentSession] = [], origin: HelperOrigin? = nil,
                               run: @escaping CommandRunner = { Shell.capture($0, $1, timeout: $2) }, now: Date = Date()) -> ProcessExplanation {
        var result = ProcessExplanation(pid: pid, exists: false)
        guard let info = kinfo(pid) else { return result }
        result.exists = true
        let me = getuid()
        let start = startDate(info)
        result.name = comm(info)
        result.ppid = info.kp_eproc.e_ppid
        result.uid = info.kp_eproc.e_ucred.cr_uid
        result.user = userName(result.uid)
        result.startTime = start
        result.status = statusLabel(info.kp_proc.p_stat)
        result.path = pidPath(pid)
        let arguments = ProcessSampler.readArguments(pid: pid)
        if let arguments {
            result.command = Redactor.redact(arguments.argv.joined(separator: " "))
        } else if pid > 0 {
            result.notes.append(result.uid == me ? "실행 인자를 읽지 못했습니다" : "다른 사용자 프로세스라 실행 인자·환경을 읽을 수 없습니다")
        }
        if let usage = rusage(pid) { result.footprint = usage.ri_phys_footprint }
        result.origin = origin
        let kind = HelperKind.classify(name: result.name, path: result.path, argv: arguments?.argv ?? [])
        result.helperKind = kind == .other ? nil : kind

        // 계보: 이 프로세스부터 launchd까지.
        let byRoot = Dictionary(sessions.map { ($0.rootPID, $0) }, uniquingKeysWith: { first, _ in first })
        var current: (pid: Int32, info: kinfo_proc)? = (pid, info)
        var visited = Set<Int32>()
        while let item = current, visited.insert(item.pid).inserted, visited.count <= 64 {
            let name = comm(item.info)
            let path = item.pid == pid ? result.path : pidPath(item.pid)
            var hop = ProcessExplanation.Hop(pid: item.pid, name: name, path: path, uid: item.info.kp_eproc.e_ucred.cr_uid, role: role(pid: item.pid, name: name, path: path,
                                                                                                                                           argv: item.pid == pid ? arguments?.argv : nil))
            if let session = byRoot[item.pid], session.id.start == startMicros(item.info) {
                hop.role = .agent(session.kind.label)
                hop.note = "\(session.kind.label) 세션 · \(session.project)"
            }
            result.chain.append(hop)
            let parent = item.info.kp_eproc.e_ppid
            guard item.pid > 1, parent >= 1, let parentInfo = kinfo(parent) else { break }
            current = (parent, parentInfo)
        }
        // 종류 이름표는 에이전트 아래서 돌거나(계보에 에이전트 홉) ReMON이 세션 하위로 본 것(origin)에만 붙인다 — 이름만으로 붙이지 않는다.
        let underAgent = result.chain.dropFirst().contains { if case .agent = $0.role { return true }; return false }
        if !underAgent && origin == nil {
            result.helperKind = nil
            if case .helper = result.chain.first?.role { result.chain[0].role = .process }
        }

        // launchd: launchd 바로 아래 홉(그것을 launchd가 띄웠다).
        if let index = result.chain.firstIndex(where: { $0.pid == 1 }), index > 0 {
            result.launchd = launchdInfo(for: result.chain[index - 1], run: run)
        } else if pid == 1 {
            result.notes.append("launchd 자신입니다(커널이 가장 먼저 띄움)")
        }

        result.sockets = ListeningSockets.list(pid: pid)
        if result.sockets == nil, pid > 0 { result.notes.append(result.uid == me ? "열린 파일 목록을 읽지 못했습니다" : "다른 사용자 프로세스라 리슨 포트를 읽을 수 없습니다") }
        result.assertions = PowerAssertions.list(pid: pid)
        result.cwd = workingDirectory(pid)
        if result.cwd == nil, result.uid != me { result.notes.append("다른 사용자 프로세스라 작업 폴더를 읽을 수 없습니다") }
        if let cwd = result.cwd, cwd != "/" { result.git = GitInfo.find(from: cwd) }

        // 경고
        var warnings: [ProcessExplanation.Warning] = []
        if let path = result.path {
            if !FileManager.default.fileExists(atPath: path) {
                warnings.append(.init(kind: .executableDeleted, text: "실행 파일이 지워졌습니다 — 업데이트·삭제 전 프로그램이 아직 돌고 있습니다(\(path))"))
            } else if executableReplaced(pid: pid, path: path) {
                warnings.append(.init(kind: .executableReplaced, text: "실행 중에 실행 파일이 바뀌었습니다 — 업데이트 전 버전이 돌고 있습니다"))
            }
        } else if let executable = arguments?.executable, !executable.isEmpty, !FileManager.default.fileExists(atPath: executable) {
            warnings.append(.init(kind: .executableDeleted, text: "실행 파일이 지워졌습니다 — 업데이트·삭제 전 프로그램이 아직 돌고 있습니다(\(executable))"))
        }
        let dyld = dyldEnvironment(pid: pid)
        if !dyld.isEmpty { warnings.append(.init(kind: .dyld, text: "DYLD_* 환경 변수가 있습니다(라이브러리 주입 가능): " + dyld.prefix(3).joined(separator: ", "))) }
        switch info.kp_proc.p_stat {
        case 5: warnings.append(.init(kind: .zombie, text: "좀비 프로세스입니다 — 이미 끝났지만 부모(pid \(result.ppid))가 회수하지 않았습니다"))
        case 4: warnings.append(.init(kind: .stopped, text: "정지 상태입니다(SIGSTOP 등) — CPU를 쓰지 않고 멈춰 있습니다"))
        default: break
        }
        if let start, let warning = ageWarning(start: start, now: now) { warnings.append(warning) }
        let exposed = (result.sockets ?? []).filter { !$0.isLoopback }
        if !exposed.isEmpty { warnings.append(.init(kind: .publicListener, text: "외부 인터페이스에서 포트를 열고 있습니다: " + exposed.prefix(4).map { "\($0.proto.rawValue.uppercased()) \($0.display)" }.joined(separator: ", "))) }
        let blocking = result.assertions.filter(\.preventsSleep)
        if !blocking.isEmpty { warnings.append(.init(kind: .preventsSleep, text: "잠자기를 막고 있습니다: " + blocking.prefix(2).map { "\($0.typeLabel)\($0.name.isEmpty ? "" : " · \($0.name)")" }.joined(separator: ", "))) }
        result.warnings = warnings
        return result
    }

    /// 90일 넘게 실행 중이면 경고(재시작으로 정리되는 누수·옛 버전).
    public static func ageWarning(start: Date, now: Date = Date()) -> ProcessExplanation.Warning? {
        let days = now.timeIntervalSince(start) / 86_400
        guard days > longRunningDays else { return nil }
        return .init(kind: .longRunning, text: "\(Int(days))일 넘게 실행 중입니다 — 오래된 버전이거나 메모리가 쌓였을 수 있습니다")
    }

    public static func role(pid: Int32, name: String, path: String?, argv: [String]?) -> ProcessExplanation.Hop.Role {
        if pid == 1 { return .launchd }
        let path = path ?? ""
        if let mark = terminalMarks.first(where: { path.contains($0.0) }) { return .terminal(mark.1) }
        if name == "tmux" { return .terminal("tmux") }
        if name == "sshd" || name == "sshd-session" { return .terminal("SSH") }
        // 업데이트로 옛 버전 파일이 지워지면 이름이 버전 번호('2.1.302')만 남는다 → 실행 인자 첫 칸으로도 본다(SessionDetector.isClaude와 같은 규칙).
        let versionName = name.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
        let first = argv?.first ?? ""
        if name == "claude" || path.hasSuffix("/.local/bin/claude") || path.contains("/.local/share/claude/")
            || ((path.isEmpty || versionName) && (first == "claude" || first.hasSuffix("/claude") || first.hasPrefix("claude "))) { return .agent("Claude Code") }
        if (name == "codex" && (path.contains("/@openai/codex") || path.isEmpty)) || path.contains("/@openai/codex/") { return .agent("Codex") }
        if name == "opencode" || path.contains("/@opencode/") { return .agent("OpenCode") }
        if shells.contains(name) || shells.contains("-" + name) { return .shell }
        if let range = path.range(of: ".app/") {
            let app = ((String(path[..<range.lowerBound]) + ".app") as NSString).lastPathComponent
            return .app((app as NSString).deletingPathExtension)
        }
        if let argv {
            let kind = HelperKind.classify(name: name, path: path, argv: argv)
            if kind != .other { return .helper(kind) }
        }
        return .process
    }

    /// launchd가 띄운 홉의 라벨: ① 사용자 도메인 목록(launchctl list)의 pid 일치 ② 세 폴더 plist의 실행 경로 일치 + launchctl print로 pid 확인.
    static func launchdInfo(for hop: ProcessExplanation.Hop, run: @escaping CommandRunner) -> ProcessExplanation.Launchd? {
        let uid = getuid()
        let scanner = StartupItemScanner(uid: uid, run: run)
        let items = scanner.scan(withState: false)
        let listed = run(StartupItemScanner.launchctl, ["list"], 10)
        if listed.succeeded, let match = StartupItemScanner.parseList(listed.stdout).first(where: { $0.value.pid == hop.pid }) {
            let item = items.first { $0.label == match.key && $0.domain != .systemDaemon }
            var info = ProcessExplanation.Launchd(pid: hop.pid, label: match.key, plistPath: item?.plistPath, domain: "gui/\(uid)",
                                                  matchedBy: "launchd 목록의 pid 일치", state: nil, runAtLoad: item?.runAtLoad, keepAlive: item?.keepAlive)
            if item != nil || !match.key.hasPrefix("application.") { info.state = scanner.state(label: match.key, domain: item?.domain ?? .userAgent) }
            return info
        }
        guard let path = hop.path, !path.isEmpty else { return nil }
        for item in items where item.program == path || item.resolvedProgram == path {
            let state = scanner.state(label: item.label, domain: item.domain)
            let confirmed = state.pid == hop.pid
            return ProcessExplanation.Launchd(pid: hop.pid, label: item.label, plistPath: item.plistPath, domain: item.domain == .systemDaemon ? "system" : "gui/\(uid)",
                                              matchedBy: confirmed ? "plist 실행 경로 + launchd pid 일치" : "plist 실행 경로 일치(pid는 다름)",
                                              state: state, runAtLoad: item.runAtLoad, keepAlive: item.keepAlive)
        }
        return nil
    }

    /// 매핑된 실행 파일(첫 영역들)의 inode가 지금 경로의 파일과 다르면 실행 중에 바뀐 것이다.
    static func executableReplaced(pid: Int32, path: String) -> Bool {
        var current = stat()
        guard stat(path, &current) == 0 else { return false }
        var region = proc_regionwithpathinfo()
        var address: UInt64 = 0
        let size = Int32(MemoryLayout<proc_regionwithpathinfo>.size)
        for _ in 0..<32 {
            guard proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &region, size) == size else { return false }
            let mapped = withUnsafeBytes(of: region.prp_vip.vip_path) { raw in String(cString: raw.bindMemory(to: CChar.self).baseAddress!) }
            if mapped == path || SafeFileOps.canonical(mapped) == SafeFileOps.canonical(path) {
                return region.prp_vip.vip_vi.vi_stat.vst_ino != current.st_ino || region.prp_vip.vip_vi.vi_stat.vst_dev != current.st_dev
            }
            let next = region.prp_prinfo.pri_address + region.prp_prinfo.pri_size
            guard next > address else { return false }
            address = next
        }
        return false
    }

    /// 환경 중 DYLD_*만(값은 라이브러리 경로라 그대로 보여 준다). 같은 사용자 프로세스에서만 읽힌다.
    public static func dyldEnvironment(pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        func next() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let value = String(decoding: buffer[start..<index], as: UTF8.self)
            index += 1
            return value
        }
        _ = next() // 실행 경로
        while index < size, buffer[index] == 0 { index += 1 }
        for _ in 0..<max(0, argc) { guard next() != nil else { return [] } }
        var result: [String] = []
        while let entry = next(), !entry.isEmpty {
            if entry.hasPrefix("DYLD_") { result.append(String(entry.prefix(200))) }
        }
        return result
    }

    // MARK: 커널 호출

    static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func comm(_ info: kinfo_proc) -> String { ProcessSampler.comm(info) }

    static func startMicros(_ info: kinfo_proc) -> Int64 {
        let tv = info.kp_proc.p_un.__p_starttime
        return Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec)
    }

    static func startDate(_ info: kinfo_proc) -> Date? {
        let micros = startMicros(info)
        return micros > 0 ? Date(timeIntervalSince1970: TimeInterval(micros) / 1_000_000) : nil
    }

    static func pidPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        return path.isEmpty ? nil : path
    }

    static func rusage(_ pid: Int32) -> rusage_info_v6? { ProcessSampler.rusage(pid) }

    public static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in String(cString: raw.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    static func userName(_ uid: UInt32) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return "uid \(uid)" }
        return String(cString: name)
    }

    static func statusLabel(_ stat: Int8) -> String {
        switch stat {
        case 1: "생성 중"
        case 2: "실행 중"
        case 3: "대기"
        case 4: "정지"
        case 5: "좀비"
        default: "알 수 없음(\(stat))"
        }
    }
}
