import Darwin
import Foundation

/// 에이전트를 띄운 터미널(부모 프로세스 사슬에서 찾는다). 이름은 화면 표시용, 번들 ID는 '터미널로 이동'용.
public struct TerminalHost: Sendable, Equatable {
    public let name: String
    public let bundleID: String?
    /// 실행 경로 조각(앱 번들 등)
    let pathMarkers: [String]
    /// 프로세스 이름(p_comm 또는 실행 파일 이름) — 번들 밖에서 도는 터미널·화면 분할기
    let processNames: [String]
    /// 화면 분할기(tmux·screen·zellij): 창을 닫아도 세션이 살아 있다. 분리된(detached) 세션은 잔재가 아니다.
    public let multiplexer: Bool

    init(_ name: String, bundleID: String? = nil, paths: [String] = [], names: [String] = [], multiplexer: Bool = false) {
        self.name = name
        self.bundleID = bundleID
        self.pathMarkers = paths
        self.processNames = names
        self.multiplexer = multiplexer
    }
}

public enum TerminalHosts {
    /// 위에서부터 본다. 기존 이름(Orca·Ghostty·터미널·iTerm·cmux·VS Code·Cursor·tmux·SSH)은 그대로 둔다(설정·화면이 이 이름을 쓴다).
    /// 번들 ID는 각 앱의 Info.plist 값이다. 틀려도 '터미널로 이동'이 그 앱을 못 찾을 뿐이다.
    public static let all: [TerminalHost] = [
        TerminalHost("Orca", paths: ["/Orca.app/", "/orca/daemon-host/"]),
        TerminalHost("Ghostty", bundleID: "com.mitchellh.ghostty", paths: ["/Ghostty.app/"], names: ["ghostty"]),
        TerminalHost("터미널", bundleID: "com.apple.Terminal", paths: ["/Terminal.app/"]),
        // iTermServer는 번들 밖(~/Library/Application Support/iTerm2/)으로 복사돼 돌기도 해서 예전처럼 '/iTerm' 조각으로 본다.
        TerminalHost("iTerm", bundleID: "com.googlecode.iterm2", paths: ["/iTerm"], names: ["iTerm2"]),
        TerminalHost("Warp", bundleID: "dev.warp.Warp-Stable", paths: ["/Warp.app/", "/WarpPreview.app/"]),
        TerminalHost("WezTerm", bundleID: "com.github.wez.wezterm", paths: ["/WezTerm.app/"], names: ["wezterm-gui", "wezterm-mux-server"]),
        TerminalHost("kitty", bundleID: "net.kovidgoyal.kitty", paths: ["/kitty.app/"], names: ["kitty"]),
        TerminalHost("Alacritty", bundleID: "org.alacritty", paths: ["/Alacritty.app/"], names: ["alacritty"]),
        TerminalHost("Tabby", bundleID: "org.tabby", paths: ["/Tabby.app/"]),
        TerminalHost("Hyper", bundleID: "co.zeit.hyper", paths: ["/Hyper.app/"]),
        TerminalHost("Rio", bundleID: "com.raphaelamorim.rio", paths: ["/Rio.app/"]),
        TerminalHost("cmux", paths: ["cmux"]),
        TerminalHost("VS Code", bundleID: "com.microsoft.VSCode", paths: ["/Visual Studio Code.app/"]),
        TerminalHost("VS Code Insiders", bundleID: "com.microsoft.VSCodeInsiders", paths: ["/Visual Studio Code - Insiders.app/"]),
        TerminalHost("VSCodium", bundleID: "com.vscodium", paths: ["/VSCodium.app/"]),
        TerminalHost("Cursor", bundleID: "com.todesktop.230313mzl4w4u92", paths: ["/Cursor.app/"]),
        TerminalHost("Windsurf", bundleID: "com.exafunction.windsurf", paths: ["/Windsurf.app/"]),
        TerminalHost("Zed", bundleID: "dev.zed.Zed", paths: ["/Zed.app/", "/Zed Preview.app/"]),
        TerminalHost("JetBrains", paths: ["/IntelliJ IDEA", "/PyCharm", "/WebStorm", "/GoLand", "/RustRover", "/CLion", "/PhpStorm", "/Rider", "/Android Studio.app/"]),
        TerminalHost("tmux", names: ["tmux"], multiplexer: true),
        TerminalHost("screen", names: ["screen", "SCREEN"], multiplexer: true),
        TerminalHost("zellij", names: ["zellij"], multiplexer: true),
        TerminalHost("SSH", names: ["sshd", "sshd-session"]),
    ]

    /// 이 프로세스가 터미널(또는 화면 분할기·SSH)인지.
    public static func host(for record: ProcRecord) -> TerminalHost? {
        let path = record.path ?? ""
        let file = (path as NSString).lastPathComponent
        return all.first { host in
            host.pathMarkers.contains(where: path.contains) || host.processNames.contains(record.name) || (!file.isEmpty && host.processNames.contains(file))
        }
    }

    /// '터미널로 이동'에서 깨울 앱. 화면 분할기·SSH·Orca(CLI로 탭 전환)는 nil.
    public static func bundleIdentifier(for name: String) -> String? {
        all.first { $0.name == name }?.bundleID
    }

    public static func isMultiplexer(_ name: String?) -> Bool {
        guard let name else { return false }
        return all.first { $0.name == name }?.multiplexer ?? false
    }

    /// 복귀(이어 열기)를 열 곳. 원래 터미널을 알면 그 앱(tmux면 그 서버의 새 창)으로, 모르면 macOS 터미널.
    /// Warp·WezTerm·kitty·VS Code 등은 명령을 넘겨 새 창을 여는 방법이 앱마다 달라 터미널로 연다(어디서 돌던 세션이든 같은 대화로 돌아온다).
    public enum RestorePlace: String, Sendable { case orca, ghostty, iTerm, tmux, terminal }

    public static func restorePlace(for host: String?) -> RestorePlace {
        switch host {
        case "Orca": .orca
        case "Ghostty": .ghostty
        case "iTerm": .iTerm
        case "tmux": .tmux
        default: .terminal
        }
    }

    /// 앱이 흔한 자리(/Applications · ~/Applications)에 있는가 — 안내 문구용. 실제 실행은 open이 LaunchServices로 찾는다.
    public static func appInstalled(_ bundleName: String) -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/Applications/", home + "/Applications/"].contains { FileManager.default.fileExists(atPath: $0 + bundleName) }
    }
}

// MARK: - tmux

/// tmux 서버와 말하기: 복귀 새 창(new-window) · 재교육 지시(그 세션이 도는 pane 하나에만 send-keys) · 터미널로 이동(select-window).
/// 서버를 새로 띄우는 명령(new-session · start-server)은 쓰지 않는다 — 서버가 없으면 실패로 돌려주고 부르는 쪽이 다른 길로 간다.
/// 소켓은 늘 -S 경로로 명시한다(ReMON이 tmux 안에서 실행돼 TMUX 변수를 물려받아도 엉뚱한 서버를 보지 않게, 그 변수도 지운다).
/// 소켓 찾기: ① 세션 프로세스의 TMUX 환경 변수(정확) ② 서버 argv의 -L·-S ③ 기본 소켓. macOS는 Apple 플랫폼 바이너리(/bin/zsh 등)의
/// 환경 변수를 다른 프로세스에 보여 주지 않지만, 에이전트(claude·node·codex)는 플랫폼 바이너리가 아니라 ①이 된다(10-25 실측).
public enum TmuxBridge {
    /// tmux 서버 프로세스(부모 launchd로 분리된 것)와 그 소켓.
    public struct Server: Sendable, Equatable {
        public var pid: Int32
        public var path: String?
        public var socket: String

        public init(pid: Int32, path: String?, socket: String) {
            self.pid = pid
            self.path = path
            self.socket = socket
        }
    }

    /// TMUX 환경 변수("소켓,서버 pid,세션 번호") — tmux가 pane 안 프로세스마다 넣어 준다.
    public struct Location: Sendable, Equatable {
        public var socket: String
        public var serverPID: Int32?
        /// 세션 id("$3"). 서버가 그대로일 때만 뜻이 있다.
        public var sessionID: String?
    }

    public struct Pane: Sendable, Equatable {
        public var serverPID: Int32
        public var id: String
        public var pid: Int32
        public var sessionID: String
        public var sessionName: String
        public var inMode: Bool
        public var attached: Int
        public var currentPath: String
    }

    /// 복귀 새 창을 열 서버·세션.
    public struct Target: Sendable, Equatable {
        public var socket: String
        /// 세션 id("$3"). nil이면 tmux가 고른다(가장 최근에 쓴 세션).
        public var session: String?
        public var tmux: String

        public init(socket: String, session: String?, tmux: String) {
            self.socket = socket
            self.session = session
            self.tmux = tmux
        }
    }

    /// 실행 파일: 서버와 같은 바이너리를 먼저(판이 다르면 클라이언트·서버 규약이 안 맞는다), 없으면 흔한 설치 자리.
    public static func executable(preferring serverPath: String? = nil) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [serverPath].compactMap { $0 } + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux",
                                                          "/run/current-system/sw/bin/tmux", home + "/.nix-profile/bin/tmux", "/usr/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// tmux 명령 환경: 바깥의 TMUX · TMUX_PANE을 지운다(현재 세션 추정이 끼어들지 않게).
    public static var commandEnvironment: [String: String] {
        ProcessInfo.processInfo.environment.filter { $0.key != "TMUX" && $0.key != "TMUX_PANE" }
    }

    public static let liveRunner: CommandRunner = { executable, arguments, timeout in
        Shell.capture(executable, arguments, environment: TmuxBridge.commandEnvironment, timeout: timeout)
    }

    /// -L 이름 · 기본 소켓의 경로 — tmux 규칙 그대로: realpath(<TMUX_TMPDIR 또는 /tmp>/tmux-<uid>)/<이름>. macOS에서는 /private/tmp/tmux-501/default.
    public static func socketPath(label: String, tmpdir: String? = nil) -> String {
        let base = ((tmpdir?.isEmpty == false ? tmpdir! : "/tmp") as NSString).appendingPathComponent("tmux-\(getuid())")
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let resolved = realpath(base, &buffer).map { String(cString: $0) } ?? base
        return (resolved as NSString).appendingPathComponent(label)
    }

    /// 서버 실행 인자의 전역 옵션(명령 앞)에서 소켓: -S 경로 그대로, -L 이름은 경로로. 둘 다 없으면 nil(기본 소켓).
    /// macOS의 tmux 서버는 처음 띄운 클라이언트의 argv를 그대로 갖는다(10-25 실측: `tmux -L remon-term-check new-session -d …`).
    public static func socket(fromServerArguments argv: [String], tmpdir: String? = nil) -> String? {
        let valued: Set<Character> = ["c", "f", "L", "S", "T"]
        var index = 1
        while index < argv.count {
            let word = argv[index]
            guard word.hasPrefix("-"), word.count > 1, word != "--" else { break }
            var characters = Array(word.dropFirst())
            while let flag = characters.first {
                characters.removeFirst()
                guard valued.contains(flag) else { continue }
                var value = String(characters)
                if value.isEmpty, index + 1 < argv.count { index += 1; value = argv[index] }
                if flag == "S", value.hasPrefix("/") { return value }
                if flag == "L", !value.isEmpty { return socketPath(label: value, tmpdir: tmpdir) }
                if flag == "c" { return nil }   // `tmux -c 명령`은 서버가 아니다
                break
            }
            index += 1
        }
        return nil
    }

    public static func location(fromTMUX value: String) -> Location? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0].hasPrefix("/") else { return nil }
        // 소켓 경로에 쉼표가 있어도 뒤의 두 칸이 pid · 세션 번호다.
        let socket = parts.dropLast(2).joined(separator: ",")
        return Location(socket: socket, serverPID: Int32(parts[parts.count - 2]), sessionID: Int(parts[parts.count - 1]).map { "$\($0)" })
    }

    // MARK: 프로세스(sysctl)

    struct Proc: Sendable, Equatable {
        var pid: Int32
        var ppid: Int32
        var pgid: Int32
        /// 제어 터미널의 앞쪽(foreground) 프로세스 그룹
        var tpgid: Int32
        var stopped: Bool
        var name: String
        var start: Int64
        var uid: uid_t
    }

    static func process(_ pid: Int32) -> Proc? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Proc(pid: pid, ppid: info.kp_eproc.e_ppid, pgid: info.kp_eproc.e_pgid, tpgid: info.kp_eproc.e_tpgid,
                    stopped: info.kp_proc.p_stat == 4 /* SSTOP */, name: ProcessSampler.comm(info),
                    start: Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec), uid: info.kp_eproc.e_ucred.cr_uid)
    }

    /// 자신부터 launchd 앞까지의 부모 사슬.
    static func ancestry(of pid: Int32) -> [Proc] {
        var chain: [Proc] = []
        var current = process(pid)
        while let item = current, chain.count < 64 {
            chain.append(item)
            guard item.ppid > 1, item.ppid != item.pid else { break }
            current = process(item.ppid)
        }
        return chain
    }

    /// 다른 프로세스의 환경 변수 하나(같은 사용자만 읽힌다). 찾는 이름 말고는 읽자마자 버린다(비밀값을 들고 있지 않게).
    static func environmentValue(_ name: String, pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        func skipString() { while index < size, buffer[index] != 0 { index += 1 } }
        skipString()                                          // 실행 경로
        while index < size, buffer[index] == 0 { index += 1 } // 정렬용 빈칸
        for _ in 0..<max(0, argc) { skipString(); index += 1 }
        let prefix = Array((name + "=").utf8)
        while index < size {
            let start = index
            skipString()
            if index == start { break }
            if index - start >= prefix.count, Array(buffer[start..<(start + prefix.count)]) == prefix {
                return String(decoding: buffer[(start + prefix.count)..<index], as: UTF8.self)
            }
            index += 1
        }
        return nil
    }

    /// 세션 루트 프로세스의 TMUX 값. 시작 시각이 다르면(pid 재사용) 읽지 않는다. 복구 금고의 terminalDetail로 남겨, 프로세스가 끝난 뒤에도 같은 서버·세션에 새 창을 연다.
    public static func tmuxVariable(pid: Int32, start: Int64?) -> String? {
        guard let info = process(pid), info.uid == getuid(), start == nil || info.start == start else { return nil }
        guard let value = environmentValue("TMUX", pid: pid), location(fromTMUX: value) != nil else { return nil }
        return process(pid)?.start == info.start ? value : nil
    }

    /// 이 사용자의 tmux 서버들(이름 tmux · 부모 launchd). 소켓은 서버 자신의 argv와 TMUX_TMPDIR로 계산한다.
    public static func runningServers() -> [Server] {
        let uid = getuid()
        return ProcessSampler.allKinfo().compactMap { info -> Server? in
            let pid = info.kp_proc.p_pid
            guard info.kp_eproc.e_ppid == 1, info.kp_eproc.e_ucred.cr_uid == uid, ProcessSampler.comm(info) == "tmux" else { return nil }
            return server(pid: pid)
        }
    }

    static func server(pid: Int32) -> Server? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : nil
        let tmpdir = environmentValue("TMUX_TMPDIR", pid: pid)
        let argv = ProcessSampler.readArguments(pid: pid)?.argv ?? []
        return Server(pid: pid, path: path, socket: socket(fromServerArguments: argv, tmpdir: tmpdir) ?? socketPath(label: "default", tmpdir: tmpdir))
    }

    // MARK: 창 목록

    static let paneFormat = "#{pid}\t#{pane_id}\t#{pane_pid}\t#{session_id}\t#{session_name}\t#{pane_in_mode}\t#{session_attached}\t#{pane_current_path}"

    static func parsePanes(_ text: String) -> [Pane] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 8, let server = Int32(fields[0]), let pid = Int32(fields[2]), fields[1].hasPrefix("%") else { return nil }
            return Pane(serverPID: server, id: fields[1], pid: pid, sessionID: fields[3], sessionName: fields[4], inMode: fields[5] == "1",
                        attached: Int(fields[6]) ?? 0, currentPath: fields[7])
        }
    }

    /// 그 소켓 서버의 모든 pane. 서버가 없으면 빈 목록(서버를 띄우지 않는 명령이다).
    public static func panes(socket: String, tmux: String, run: CommandRunner = liveRunner) -> [Pane] {
        let result = run(tmux, ["-S", socket, "list-panes", "-a", "-F", paneFormat], 5)
        return result.succeeded ? parsePanes(result.stdout) : []
    }

    // MARK: 재교육 지시

    public static let noTerminalMessage = "지시를 보낼 수 있는 터미널이 없습니다 — Orca 또는 tmux 안의 세션만"

    /// 세션 루트의 부모 사슬에 tmux 서버가 있으면 그 서버에서 사슬 안의 pane을 찾는다(pane_pid가 루트 또는 그 조상).
    static func locatePane(root: Int32, start: Int64, run: CommandRunner) -> (pane: Pane, socket: String, tmux: String, server: Int32)? {
        let chain = ancestry(of: root)
        guard chain.first?.start == start, let serverIndex = chain.firstIndex(where: { $0.name == "tmux" }), serverIndex > 0 else { return nil }
        let serverPID = chain[serverIndex].pid
        let inside = Set(chain[..<serverIndex].map(\.pid))
        guard let server = server(pid: serverPID), let tmux = executable(preferring: server.path) else { return nil }
        var sockets: [String] = []
        if let value = tmuxVariable(pid: root, start: start), let location = location(fromTMUX: value), location.serverPID == serverPID { sockets.append(location.socket) }
        sockets.append(server.socket)
        sockets.append(socketPath(label: "default"))
        for socket in sockets.reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            if let pane = panes(socket: socket, tmux: tmux, run: run).first(where: { $0.serverPID == serverPID && inside.contains($0.pid) }) {
                return (pane, socket, tmux, serverPID)
            }
        }
        return nil
    }

    /// 재교육 지시 한 줄: 그 세션이 도는 pane에만 글자를 보내고 Enter. 보내기 직전에 다시 확인한다 —
    /// 세션이 그대로(pid·시작 시각) · pane의 프로세스가 아직 세션의 조상 · pane이 복사 모드가 아님 · 세션이 멈추지 않고 터미널 앞쪽(foreground)에서 돈다.
    /// 하나라도 어긋나면 보내지 않는다(아무 창에나 치지 않는다).
    public static func sendLine(_ text: String, sessionRoot root: Int32, start: Int64, run: CommandRunner = liveRunner, pause: TimeInterval = 0.3) -> (ok: Bool, message: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (false, "보낼 지시가 비었습니다") }
        guard process(root)?.start == start else { return (false, "세션이 이미 끝났습니다") }
        guard let found = locatePane(root: root, start: start, run: run) else { return (false, noTerminalMessage) }
        let pane = found.pane
        let fresh = ancestry(of: root)
        guard let head = fresh.first, head.start == start else { return (false, "세션이 이미 끝났습니다") }
        let check = run(found.tmux, ["-S", found.socket, "display-message", "-p", "-t", pane.id, "#{pid}\t#{pane_pid}\t#{pane_in_mode}"], 5)
        let fields = check.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t").map(String.init)
        guard check.succeeded, fields.count == 3, Int32(fields[0]) == found.server, let panePID = Int32(fields[1]),
              fresh.contains(where: { $0.pid == panePID }), panePID != found.server else { return (false, "tmux 창 \(pane.id)이 더는 이 세션을 품고 있지 않아 보내지 않았습니다") }
        guard fields[2] != "1" else { return (false, "tmux 창 \(pane.id)이 복사·선택 모드라 보내지 않았습니다") }
        guard !head.stopped, head.pgid == head.tpgid else { return (false, "세션이 멈췄거나 터미널 앞쪽에서 돌고 있지 않아 보내지 않았습니다") }
        let typed = run(found.tmux, ["-S", found.socket, "send-keys", "-t", pane.id, "-l", "--", text], 5)
        guard typed.succeeded else { return (false, "tmux send-keys 실패: \(typed.stderr.prefix(120))") }
        // 글자와 Enter를 한 번에 보내면 TUI가 붙여 넣기로 보고 Enter를 줄바꿈으로 삼키는 일이 있어 잠깐 띄운다.
        if pause > 0 { usleep(useconds_t(pause * 1_000_000)) }
        let entered = run(found.tmux, ["-S", found.socket, "send-keys", "-t", pane.id, "Enter"], 5)
        guard entered.succeeded else { return (false, "tmux Enter 실패: \(entered.stderr.prefix(120))") }
        return (true, "tmux 창 \(pane.id)(세션 \(pane.sessionName))에 보냈습니다")
    }

    // MARK: 터미널로 이동

    /// '터미널로 이동'(tmux): 그 세션이 도는 창·pane을 그 tmux 세션의 현재 창으로 바꾼다(글자는 보내지 않는다).
    /// 그 세션을 보는 화면(클라이언트)이 있으면 그 화면을 띄운 터미널(Ghostty·터미널·iTerm·Orca …)을 돌려준다 — 부르는 쪽이 그 앱을 앞으로 가져온다.
    public static func reveal(sessionRoot root: Int32, start: Int64, run: CommandRunner = liveRunner) -> (ok: Bool, host: TerminalHost?, message: String) {
        guard process(root)?.start == start else { return (false, nil, "세션이 이미 끝났습니다") }
        guard let found = locatePane(root: root, start: start, run: run) else { return (false, nil, "tmux 창을 찾지 못했습니다") }
        let base = ["-S", found.socket]
        let window = run(found.tmux, base + ["select-window", "-t", found.pane.id], 5)
        let pane = run(found.tmux, base + ["select-pane", "-t", found.pane.id], 5)
        guard window.succeeded, pane.succeeded else { return (false, nil, "tmux 창을 고르지 못했습니다: \((window.stderr + pane.stderr).prefix(120))") }
        var clients = run(found.tmux, base + ["list-clients", "-t", found.pane.sessionID, "-F", "#{client_pid}"], 5).stdout
            .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        let name = found.pane.sessionName
        if clients.isEmpty {
            // 그 세션을 보는 화면이 없으면 이 서버에서 가장 최근에 쓴 화면을 그 세션으로 돌린다(누른 사람이 원하는 '그 터미널로 이동').
            let all = run(found.tmux, base + ["list-clients", "-F", "#{client_activity}\t#{client_tty}\t#{client_pid}"], 5).stdout.split(separator: "\n").compactMap { line -> (Int, String, Int32)? in
                let fields = line.split(separator: "\t").map(String.init)
                guard fields.count == 3, let activity = Int(fields[0]), let pid = Int32(fields[2]) else { return nil }
                return (activity, fields[1], pid)
            }
            if let recent = all.max(by: { $0.0 < $1.0 }), run(found.tmux, base + ["switch-client", "-c", recent.1, "-t", found.pane.id], 5).succeeded { clients = [recent.2] }
        }
        guard !clients.isEmpty else { return (true, nil, "tmux 세션 '\(name)'의 그 창으로 옮겼습니다 — 이 세션을 보는 화면이 없습니다. tmux attach -t \(name)로 확인하세요") }
        let host = clients.lazy.compactMap(guiHost(above:)).first
        return (true, host, "tmux 세션 '\(name)'의 그 창으로 옮겼습니다" + (host.map { " · \($0.name)" } ?? ""))
    }

    /// 프로세스의 부모 사슬(자신 제외)에서 처음 만나는 화면 분할기가 아닌 터미널.
    public static func guiHost(above pid: Int32) -> TerminalHost? {
        for item in ancestry(of: pid).dropFirst() {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let length = proc_pidpath(item.pid, &buffer, UInt32(buffer.count))
            let record = ProcRecord(pid: item.pid, ppid: item.ppid, name: item.name, path: length > 0 ? String(cString: buffer) : nil)
            if let host = TerminalHosts.host(for: record), !host.multiplexer { return host }
        }
        return nil
    }

    // MARK: 복귀 새 창

    /// 복귀할 서버·세션: ① 금고에 적힌 TMUX 값의 서버가 살아 있으면 그 서버(서버가 그대로면 그 세션) ② 같은 폴더의 pane이 있는 서버·세션
    /// ③ 기본 소켓 서버 ④ 없으면 nil(부르는 쪽이 터미널로 연다).
    public static func restoreTarget(cwd: String, detail: String?, servers: [Server]? = nil, run: CommandRunner = liveRunner) -> Target? {
        // 같은 폴더(또는 그 안)의 pane이 있는 세션 — 같은 폴더 우선, 그다음 그 세션을 보는 화면이 있는 쪽.
        func score(_ pane: Pane) -> (Int, Int) { (pane.currentPath == cwd ? 1 : 0, pane.attached) }
        func best(_ panes: [Pane]) -> Pane? {
            panes.filter { $0.currentPath == cwd || $0.currentPath.hasPrefix(cwd + "/") }.max { score($0) < score($1) }
        }
        let known = servers ?? runningServers()
        if let detail, let location = location(fromTMUX: detail) {
            let path = known.first { $0.socket == location.socket }?.path
            if let tmux = executable(preferring: path) {
                let list = panes(socket: location.socket, tmux: tmux, run: run)
                if let first = list.first {
                    let sameServer = location.serverPID == first.serverPID
                    let session = sameServer && list.contains { $0.sessionID == location.sessionID } ? location.sessionID : best(list)?.sessionID
                    return Target(socket: location.socket, session: session, tmux: tmux)
                }
            }
        }
        var candidates = known.map { ($0.socket, $0.path) }
        if !candidates.contains(where: { $0.0 == socketPath(label: "default") }) { candidates.append((socketPath(label: "default"), nil)) }
        var fallback: Target?
        for (socket, path) in candidates {
            guard let tmux = executable(preferring: path) else { continue }
            let list = panes(socket: socket, tmux: tmux, run: run)
            guard !list.isEmpty else { continue }
            if let pane = best(list) { return Target(socket: socket, session: pane.sessionID, tmux: tmux) }
            if socket == socketPath(label: "default") { fallback = Target(socket: socket, session: nil, tmux: tmux) }
        }
        return fallback
    }

    /// 새 창을 열어 명령을 돌린다(창 이름의 #은 tmux 형식 문자라 뺀다). 새 창은 그 세션의 현재 창이 되어, 세션을 보는 화면에 바로 뜬다.
    public static func openWindow(_ target: Target, cwd: String, name: String, command: String, run: CommandRunner = liveRunner) -> (ok: Bool, message: String) {
        let safeName = String(name.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "\n", with: " ").prefix(40))
        var arguments = ["-S", target.socket, "new-window"]
        if let session = target.session { arguments += ["-t", session + ":"] }
        arguments += ["-c", cwd, "-n", safeName, "-P", "-F", "#{session_name}\t#{session_attached}\t#{window_index}", command]
        let result = run(target.tmux, arguments, 10)
        guard result.succeeded else { return (false, "tmux 새 창을 열지 못했습니다: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))") }
        let fields = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        let session = fields.first ?? "?"
        let window = fields.count > 2 ? " \(fields[2])번" : ""
        let watched = fields.count > 1 && (Int(fields[1]) ?? 0) > 0
        return (true, "tmux 세션 '\(session)'의 새 창\(window)에서 이어 엽니다" + (watched ? "" : " — 이 세션을 보는 화면이 없습니다. tmux attach -t \(session)로 확인하세요"))
    }
}
