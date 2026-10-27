import Darwin
import Foundation
import ReMONCore

// Orca 없이도 다 되는가(대표 지시: "오르카를 안쓰면 다른거 쓰던지 그냥 고스티나 기본 터미널 써도 다 돼야해").
// ① 터미널 닫힘·분리된 tmux·VS Code/Cursor 호스트 — 합성 프로세스 표(대표님 실제 세션은 읽지 않는다)
// ② 복귀 실행기의 터미널 선택 — 가짜 open(창을 띄우지 않고, '그 터미널이 스크립트를 돌린 것처럼' zsh로 직접 돌린다)
// ③ 비공개 tmux 서버(-L remon-term-check, 사용자 설정 안 읽음)에서 재교육 지시(send-keys)·복귀 새 창을 실제로.
//    tmux 명령은 비공개 소켓을 향한 것만 통과시키는 실행기로 돌린다 — 다른 tmux 서버에는 목록 조회조차 보내지 않는다.
// `terminal --ghostty`만 Ghostty 새 창을 하나 실제로 띄운다(한 줄 찍고 1초 뒤 스스로 닫힘). 터미널로 넘어가는 호출은 막는다.

let terminalSocketName = "remon-term-check"

func terminalCheck() {
    // 더미 에이전트 모드: pane 터미널에서 한 줄씩 받아 파일에 적는다. /bin/cat 같은 Apple 플랫폼 바이너리는 macOS가 환경 변수를
    // 다른 프로세스에 보여 주지 않아(10-25 실측: ps eww도 빈칸) 실제 에이전트(claude·node·codex)처럼 TMUX를 읽을 수 있는 이 실행 파일을 쓴다.
    if let index = CommandLine.arguments.firstIndex(of: "--dummy-reader"), index + 1 < CommandLine.arguments.count {
        dummyReader(CommandLine.arguments[index + 1])
    }
    let root = "/private/tmp/remon-terminal-check-\(getpid())"   // 공유 checkRoot 밖(다른 검사가 지워도 영향 없음)
    try? FileManager.default.removeItem(atPath: root)
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    terminalClosedScenarios()
    tmuxParsing(root)
    launcherSelection(root)
    tmuxLive(root)
    if CommandLine.arguments.contains("--ghostty") { ghosttyLive(root) } else { print("  (Ghostty 실제 창 검사는 `terminal --ghostty`)") }
}

/// 표준 입력의 줄을 파일에 덧붙인다. 입력이 끝나거나 120초가 지나면 스스로 끝난다(검사가 중간에 죽어도 남지 않게).
private func dummyReader(_ path: String) -> Never {
    DispatchQueue.global().asyncAfter(deadline: .now() + 120) { exit(0) }
    FileManager.default.createFile(atPath: path, contents: nil)
    while let line = readLine() {
        if let handle = FileHandle(forWritingAtPath: path) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
            try? handle.close()
        }
    }
    exit(0)
}

// MARK: - ① 감지: 터미널 닫힘 · 분리된 tmux · VS Code/Cursor

private func terminalClosedScenarios() {
    let fake = FakeProcesses(started: Date().addingTimeInterval(-4 * 3600))
    let claudePath = "/Users/u/.local/share/claude/versions/2.1.310"
    let nvmNode = "/Users/u/.nvm/versions/node/v24.13.1/bin/node"
    // (a) Ghostty 창이 닫힌 뒤 남은 Claude: 부모 launchd · 제어 터미널 없음 · 사슬에 터미널 없음
    let closedClaude = fake.add("claude", claudePath, ["claude"], parent: 1, cwd: "/Users/test/DEV/closed", tty: false)
    // 대조: 같은 Claude가 Ghostty 아래 그대로 있음(Ghostty → login → zsh → claude)
    let ghostty = fake.add("ghostty", "/Applications/Ghostty.app/Contents/MacOS/ghostty", ["ghostty"], tty: false)
    let login = fake.add("login", "/usr/bin/login", ["login", "-flp", "u"], parent: ghostty.pid)
    let ghosttyShell = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: login.pid, cwd: "/Users/test/DEV/open")
    let openClaude = fake.add("claude", claudePath, ["claude"], parent: ghosttyShell.pid, cwd: "/Users/test/DEV/open")
    // (a) 터미널.app 창이 닫힌 뒤 남은 Gemini(기록 없는 표 에이전트 — 판정이 따로다)
    let closedGemini = fake.add("node", nvmNode, ["node", "/opt/homebrew/bin/gemini"], parent: 1, cwd: "/Users/test/DEV/terminal-closed", tty: false)
    // (b) 분리된 tmux 세션: 서버(부모 launchd · 터미널 없음) → zsh(pane 터미널) → claude
    let server = fake.add("tmux", "/opt/homebrew/Cellar/tmux/3.6a/bin/tmux", ["tmux", "new", "-d", "-s", "work"], tty: false)
    let paneShell = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: server.pid, cwd: "/Users/test/DEV/tmux")
    let tmuxClaude = fake.add("claude", claudePath, ["claude"], parent: paneShell.pid, cwd: "/Users/test/DEV/tmux")
    // tmux 서버가 사라진 뒤(kill-server) SIGHUP을 견딘 Claude → 부모 launchd · 터미널 없음
    let killedClaude = fake.add("claude", claudePath, ["claude"], parent: 1, cwd: "/Users/test/DEV/tmux-killed", tty: false)
    // (c) VS Code · Cursor 내장 터미널: pty host(…Helper) → zsh → claude
    let code = fake.add("Code Helper", "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper",
                        ["Code Helper", "--type=utility", "--utility-sub-type=node.mojom.NodeService"], tty: false)
    let codeShell = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: code.pid, cwd: "/Users/test/DEV/vscode")
    let codeClaude = fake.add("claude", claudePath, ["claude"], parent: codeShell.pid, cwd: "/Users/test/DEV/vscode")
    let cursor = fake.add("Cursor Helper", "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper",
                          ["Cursor Helper", "--type=utility", "--utility-sub-type=node.mojom.NodeService"], tty: false)
    let cursorShell = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: cursor.pid, cwd: "/Users/test/DEV/cursor")
    let cursorClaude = fake.add("claude", claudePath, ["claude"], parent: cursorShell.pid, cwd: "/Users/test/DEV/cursor")

    // 레지스트리: Claude 세션 모두 'idle' · 상태 갱신 3시간 전(쉼 판정) — 고아인지는 부모·터미널만으로 갈린다.
    let registryFolder = NSTemporaryDirectory() + "remon-terminal-registry-\(getpid())"
    try? FileManager.default.createDirectory(atPath: registryFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: registryFolder) }
    for record in [closedClaude, openClaude, tmuxClaude, killedClaude, codeClaude, cursorClaude] {
        let cwd = fake.workingDirectory(for: record.key, now: Date()) ?? "/Users/test/DEV"
        let entry: [String: Any] = ["pid": Int(record.pid), "sessionId": UUID().uuidString.lowercased(), "cwd": cwd, "kind": "interactive", "status": "idle",
                                    "statusUpdatedAt": Int(Date().addingTimeInterval(-3 * 3600).timeIntervalSince1970 * 1000), "startedAt": Int(fake.started.timeIntervalSince1970 * 1000)]
        FileManager.default.createFile(atPath: registryFolder + "/\(record.pid).json", contents: try? JSONSerialization.data(withJSONObject: entry))
    }
    let detector = SessionDetector()
    detector.catalog = AgentCatalog(defaults: nil, initial: AgentCatalog.State())
    detector.claudeRegistry = ClaudeRegistry(directory: registryFolder)
    let result = detector.detect(records: fake.records, sampler: fake, orca: [])
    func session(_ record: ProcRecord) -> AgentSession? { result.sessions.first { $0.rootPID == record.pid } }
    func describe(_ record: ProcRecord) -> String { session(record).map { "\($0.state.label) · 호스트 \($0.terminalHost ?? "없음") · \($0.stateReason)" } ?? "세션 없음" }

    let closed = session(closedClaude)
    check(closed?.state == .orphan && closed?.terminalHost == nil && closed?.stateReason.hasPrefix("터미널 닫힘 · 부모 프로세스 없음 · 마지막 기록") == true,
          "(a) Ghostty 창이 닫힌 뒤 남은 Claude(부모 launchd · 터미널 없음 · 호스트 없음) → 고아 — \(describe(closedClaude))")
    check(session(openClaude).map { $0.terminalHost == "Ghostty" && $0.state.isResting } == true, "대조: Ghostty가 살아 있으면 같은 3시간 쉼도 고아 아님 — \(describe(openClaude))")
    check(session(closedGemini)?.state == .orphan && session(closedGemini)?.stateReason.hasPrefix("터미널 닫힘 · 부모 프로세스 없음") == true,
          "(a) 터미널.app 창이 닫힌 뒤 남은 Gemini → 고아 — \(describe(closedGemini))")
    check(session(tmuxClaude).map { $0.terminalHost == "tmux" && $0.state.isResting && $0.tabState == .outside } == true,
          "(b) 분리된 tmux 세션의 Claude(서버 살아 있음) → 고아 아님 · 호스트 tmux — \(describe(tmuxClaude))")
    check(session(killedClaude)?.state == .orphan, "tmux 서버가 사라진 뒤 남은 Claude → 고아 — \(describe(killedClaude))")
    check(session(codeClaude).map { $0.terminalHost == "VS Code" && $0.state != .orphan } == true, "(c) VS Code 내장 터미널의 Claude → 호스트 'VS Code' — \(describe(codeClaude))")
    check(session(cursorClaude).map { $0.terminalHost == "Cursor" && $0.state != .orphan } == true, "(c) Cursor 내장 터미널의 Claude → 호스트 'Cursor' — \(describe(cursorClaude))")
    let groups = Dictionary(uniqueKeysWithValues: result.apps.map { ($0.id, $0.category) })
    check(groups["/Applications/Visual Studio Code.app"] == .host && groups["/Applications/Cursor.app"] == .host && groups["/Applications/Ghostty.app"] == .host,
          "세션을 띄운 VS Code · Cursor · Ghostty = 터미널 호스트(종료 보호)")
    check(result.sessions.allSatisfy { $0.orcaHandle == nil && !$0.tabLeftover }, "Orca 없음(목록 빈칸): Orca 탭 상태로 판정한 세션 없음")
}

// MARK: - tmux 해석 · 복귀 장소 · 금고 필드

private func tmuxParsing(_ root: String) {
    let uid = getuid()
    check(TmuxBridge.socketPath(label: "default") == "/private/tmp/tmux-\(uid)/default" || ProcessInfo.processInfo.environment["TMUX_TMPDIR"] != nil,
          "기본 소켓 = /private/tmp/tmux-\(uid)/default(tmux 규칙: /tmp의 실제 경로)")
    let label = TmuxBridge.socketPath(label: "work")
    let cases: [([String], String?)] = [
        (["tmux"], nil), (["tmux", "new", "-s", "x"], nil), (["tmux", "-L", "work", "new-session", "-d"], label), (["tmux", "-Lwork", "new"], label),
        (["tmux", "-f", "/dev/null", "-L", "work", "new-session"], label), (["tmux", "-uL", "work"], label), (["tmux", "-S", "/tmp/x.sock", "attach"], "/tmp/x.sock"),
        (["tmux", "new", "-L", "late"], nil), (["tmux", "-c", "ls"], nil),
    ]
    let wrong = cases.filter { TmuxBridge.socket(fromServerArguments: $0.0) != $0.1 }
    check(wrong.isEmpty, "서버 argv → 소켓(-L 이름 · -L붙임 · -f 뒤 · 묶음 -uL · -S 경로 · 명령 뒤 옵션 무시 · -c는 서버 아님)" + (wrong.isEmpty ? "" : " — 틀림: \(wrong.map { $0.0.joined(separator: " ") })"))
    check(TmuxBridge.socketPath(label: "x", tmpdir: root).hasPrefix(root) || TmuxBridge.socketPath(label: "x", tmpdir: root).hasSuffix("/tmux-\(uid)/x"), "TMUX_TMPDIR가 있으면 그 아래")
    let parsed = TmuxBridge.location(fromTMUX: "/private/tmp/tmux-501/default,1234,7")
    check(parsed?.socket == "/private/tmp/tmux-501/default" && parsed?.serverPID == 1234 && parsed?.sessionID == "$7", "TMUX 값 → 소켓 · 서버 pid · 세션($7)")
    check(TmuxBridge.location(fromTMUX: "/tmp/a,b/sock,99,3")?.socket == "/tmp/a,b/sock" && TmuxBridge.location(fromTMUX: "엉망") == nil, "소켓 경로의 쉼표 · 깨진 값")
    let places: [(String?, TerminalHosts.RestorePlace)] = [("Orca", .orca), ("Ghostty", .ghostty), ("iTerm", .iTerm), ("tmux", .tmux), ("터미널", .terminal),
                                                          ("VS Code", .terminal), ("Warp", .terminal), (nil, .terminal)]
    check(places.allSatisfy { TerminalHosts.restorePlace(for: $0.0) == $0.1 }, "복귀 장소: Orca·Ghostty·iTerm·tmux는 그 터미널, 나머지(VS Code·Warp·모름)는 터미널.app")
    func entry(_ host: String?, job: String? = nil) -> RecoveryEntry {
        var value = RecoveryEntry(kind: .session, status: .held, project: "시험", title: "t", reason: "시험")
        value.terminalHost = host
        value.backgroundJob = job
        return value
    }
    let ghosttyLabel = TerminalHosts.appInstalled("Ghostty.app") ? "Ghostty 새 창" : "터미널 새 창"
    check(RecoveryLaunchers.placeLabel(for: entry("Ghostty")) == ghosttyLabel && RecoveryLaunchers.placeLabel(for: entry("VS Code")) == "터미널 새 창"
          && RecoveryLaunchers.placeLabel(for: entry("tmux")).hasPrefix("tmux 새 창") && RecoveryLaunchers.placeLabel(for: entry(nil)) == "터미널 새 창"
          && RecoveryLaunchers.placeLabel(for: entry("Orca")) == (OrcaBridge.executable != nil ? "Orca 새 탭" : "터미널 새 창")
          && RecoveryLaunchers.placeLabel(for: entry("Claude 백그라운드", job: "abcd1234")).hasPrefix("Claude 백그라운드"),
          "안내 문구: Ghostty→'\(ghosttyLabel)' · VS Code→터미널 · tmux→tmux 새 창 · Orca는 설치됐을 때만 'Orca 새 탭'(이 Mac: \(OrcaBridge.executable == nil ? "Orca 없음" : "Orca 있음"))")
    // 금고: 새 필드 저장·복원, 예전 항목(필드 없음)도 그대로 읽힌다.
    let vault = RecoveryVault(folder: URL(fileURLWithPath: root + "/vault-field"))
    vault.audit = AuditLog(url: URL(fileURLWithPath: root + "/actions.jsonl"))
    var stored = entry("tmux")
    stored.terminalDetail = "/private/tmp/tmux-501/default,1234,7"
    _ = try? vault.add(stored)
    check(vault.entry(stored.id)?.terminalDetail == stored.terminalDetail, "금고: terminalDetail 저장·복원")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    if let data = try? encoder.encode(entry("Ghostty")), var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        object.removeValue(forKey: "terminalDetail")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let old = (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? decoder.decode(RecoveryEntry.self, from: $0) }
        check(old != nil && old?.terminalDetail == nil && old?.terminalHost == "Ghostty", "금고: 예전 항목(terminalDetail 없음)도 읽힘")
    } else {
        check(false, "금고: 예전 항목 만들기 실패")
    }
}

// MARK: - ② 복귀 실행기: 터미널 선택(가짜 open)

final class OpenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, [String])] = []
    func add(_ executable: String, _ arguments: [String]) { lock.lock(); _calls.append((executable, arguments)); lock.unlock() }
    var calls: [(String, [String])] { lock.lock(); defer { lock.unlock() }; return _calls }
}

/// 가짜 open: 받은 명령을 적고, runs에 든 앱이면 '그 터미널이 스크립트를 돌린 것처럼' zsh로 직접 돌린다. fails면 앱이 없는 것처럼 실패.
/// open이 아닌 명령(orca 등)은 실제로 부르지 않고 실패로 돌려준다.
private func fakeOpen(_ recorder: OpenRecorder, runs: Set<String>, fails: Set<String> = []) -> CommandRunner {
    { executable, arguments, _ in
        recorder.add(executable, arguments)
        guard executable == "/usr/bin/open" else { return CommandResult(status: 1, stdout: "{\"ok\":false}", stderr: "시험: 실제 실행 막음") }
        let app = ["-b", "-a"].compactMap { flag in arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }.first ?? ""
        if fails.contains(app) { return CommandResult(status: 1, stderr: "Unable to find application \(app)") }
        if runs.contains(app), let script = arguments.last { _ = Shell.capture("/bin/zsh", [script], timeout: 15) }
        return CommandResult(status: 0)
    }
}

private let failingTmux: CommandRunner = { _, _, _ in CommandResult(status: 1, stderr: "시험: no server running") }

private func lines(_ path: String) -> [String] {
    ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

private func launcherSelection(_ root: String) {
    let folder = URL(fileURLWithPath: root + "/launch")
    func launch(_ host: String?, _ output: String) -> RecoveryLaunch {
        RecoveryLaunch(arguments: ["/bin/zsh", "-f", "-c", "print -r -- ran >> \(output)"], cwd: root, title: "복귀 · 시험", terminalHost: host)
    }
    // Ghostty가 스크립트를 돌림 → Ghostty
    var recorder = OpenRecorder()
    var output = root + "/out-ghostty.txt"
    var result = RecoveryLaunchers.live(folder: folder, run: fakeOpen(recorder, runs: ["com.mitchellh.ghostty"]), tmuxRun: failingTmux, markerWait: 2)(launch("Ghostty", output))
    let ghosttyCall = recorder.calls.first?.1 ?? []
    check(result.ok && result.via == "Ghostty" && lines(output) == ["ran"] && recorder.calls.count == 1 && Array(ghosttyCall.prefix(5)) == ["-n", "-b", "com.mitchellh.ghostty", "--args", "-e"],
          "Ghostty 세션 → open -n -b com.mitchellh.ghostty --args -e <스크립트> · '\(result.message)'")
    // Ghostty가 열렸는데 스크립트를 안 돌림 → 터미널로 넘어감 · 늦게 Ghostty가 돌려도 두 번 열리지 않음
    recorder = OpenRecorder()
    output = root + "/out-ghostty-late.txt"
    result = RecoveryLaunchers.live(folder: folder, run: fakeOpen(recorder, runs: ["Terminal"]), tmuxRun: failingTmux, markerWait: 0.6)(launch("Ghostty", output))
    check(result.ok && result.via == "터미널" && result.message.hasPrefix("Ghostty에서 시작되지 않아 터미널 새 창") && lines(output) == ["ran"],
          "Ghostty가 시작 표시를 안 남기면 터미널로 넘어감 · '\(result.message)'")
    if let script = recorder.calls.last?.1.last {
        let late = Shell.capture("/bin/zsh", [script], timeout: 10)
        check(late.status == 0 && late.stdout.contains("이미 다른 창에서 열렸습니다") && lines(output) == ["ran"], "늦게 Ghostty가 같은 스크립트를 돌려도 잠금을 보고 바로 닫힘(같은 대화 두 번 안 뜸)")
        let body = (try? String(contentsOfFile: script, encoding: .utf8)) ?? ""
        check(body.contains("mkdir ") && body.contains(".started") && body.contains("cd \(root) ||"), "스크립트: 첫 줄 잠금(mkdir …started) · cd 폴더")
    } else {
        check(false, "터미널로 넘어간 스크립트를 찾지 못함")
    }
    // iTerm 없음 → 터미널
    recorder = OpenRecorder()
    output = root + "/out-iterm.txt"
    result = RecoveryLaunchers.live(folder: folder, run: fakeOpen(recorder, runs: ["Terminal"], fails: ["com.googlecode.iterm2"]), tmuxRun: failingTmux, markerWait: 2)(launch("iTerm", output))
    check(result.ok && result.via == "터미널" && result.message.hasPrefix("iTerm을 열지 못해") && lines(output) == ["ran"] && recorder.calls.first?.1.prefix(2) == ["-b", "com.googlecode.iterm2"],
          "iTerm 세션인데 iTerm이 없으면 터미널 · '\(result.message)'")
    // iTerm이 스크립트를 돌림 → iTerm
    recorder = OpenRecorder()
    output = root + "/out-iterm-ok.txt"
    result = RecoveryLaunchers.live(folder: folder, run: fakeOpen(recorder, runs: ["com.googlecode.iterm2"]), tmuxRun: failingTmux, markerWait: 2)(launch("iTerm", output))
    check(result.ok && result.via == "iTerm" && lines(output) == ["ran"], "iTerm이 스크립트를 돌리면 iTerm · '\(result.message)'")
    // VS Code · 모름 → 바로 터미널(open -a Terminal 한 번)
    for host in ["VS Code", "Warp", nil] as [String?] {
        recorder = OpenRecorder()
        output = root + "/out-\((host ?? "none").replacingOccurrences(of: " ", with: "-")).txt"
        result = RecoveryLaunchers.live(folder: folder, run: fakeOpen(recorder, runs: ["Terminal"]), tmuxRun: failingTmux, markerWait: 2)(launch(host, output))
        check(result.ok && result.via == "터미널" && result.message == "터미널 새 창에서 이어 엽니다" && recorder.calls.count == 1 && recorder.calls[0].1.prefix(2) == ["-a", "Terminal"] && lines(output) == ["ran"],
              "\(host ?? "호스트 모름") 세션 → 터미널 새 창 · '\(result.message)'")
    }
    // Orca 세션: Orca가 없거나 실패하면 터미널(가짜 실행기가 orca 호출을 막는다 — 실제 Orca 탭은 만들지 않음)
    recorder = OpenRecorder()
    output = root + "/out-orca.txt"
    result = RecoveryLaunchers.live(folder: folder, run: fakeOpen(recorder, runs: ["Terminal"]), tmuxRun: failingTmux, markerWait: 2)(launch("Orca", output))
    let orcaPrefix = OrcaBridge.executable == nil ? "Orca가 없어" : "Orca에서 열지 못해"
    check(result.ok && result.via == "터미널" && result.message.hasPrefix(orcaPrefix) && lines(output) == ["ran"], "Orca 세션인데 Orca로 못 열면 터미널 · '\(result.message)'")
    // tmux 세션인데 서버가 없음 → 터미널
    recorder = OpenRecorder()
    output = root + "/out-tmux-gone.txt"
    result = RecoveryLaunchers.live(folder: folder, run: fakeOpen(recorder, runs: ["Terminal"]), tmuxRun: failingTmux, markerWait: 2)(launch("tmux", output))
    check(result.ok && result.via == "터미널" && result.message.hasPrefix("tmux 서버가 없어") && lines(output) == ["ran"], "tmux 세션인데 서버가 없으면 터미널 · '\(result.message)'")
}

// MARK: - ③ 비공개 tmux 서버: 재교육 지시 · 복귀 새 창

private func tmuxLive(_ root: String) {
    guard let tmux = TmuxBridge.executable() else { print("SKIP tmux 미설치 — tmux 실전 검사 건너뜀"); return }
    let socket = TmuxBridge.socketPath(label: terminalSocketName)
    // 비공개 소켓을 향한 명령만 통과(ReMON 코드가 다른 서버로 새는지도 함께 잡는다).
    let leaks = OpenRecorder()
    let guarded: CommandRunner = { executable, arguments, timeout in
        guard let index = arguments.firstIndex(of: "-S"), index + 1 < arguments.count, arguments[index + 1] == socket else {
            leaks.add(executable, arguments)
            return CommandResult(status: 1, stderr: "시험: 비공개 소켓이 아닌 tmux 명령 막음")
        }
        return TmuxBridge.liveRunner(executable, arguments, timeout)
    }
    @discardableResult func t(_ arguments: [String]) -> CommandResult { TmuxBridge.liveRunner(tmux, ["-S", socket] + arguments, 10) }
    t(["kill-server"])   // 지난 실행이 남긴 비공개 서버
    defer { t(["kill-server"]) }
    let recv = root + "/recv.txt"
    FileManager.default.createFile(atPath: recv, contents: Data())
    // 서버는 -L 이름으로 띄운다(argv에서 소켓을 계산하는 길까지 실제로 확인). 사용자 설정은 읽지 않는다(-f /dev/null).
    // pane 명령은 인자 여러 개 → 셸 없이 바로: zsh(pane) → 더미 에이전트(이 실행 파일의 --dummy-reader, pane 터미널에서 한 줄씩 받아 파일에 적음)
    let invoked = Bundle.main.executablePath ?? CommandLine.arguments[0]
    var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let exe = realpath(invoked, &resolvedBuffer).map { String(cString: $0) } ?? invoked   // .build/debug는 링크 — 커널이 돌려주는 실제 경로로 맞춘다
    let started = TmuxBridge.liveRunner(tmux, ["-L", terminalSocketName, "-f", "/dev/null", "new-session", "-d", "-s", "reedu", "-x", "120", "-y", "30", "-c", root,
                                               "/bin/zsh", "-f", "-c", "\(ResumeKey.quote(exe)) terminal --dummy-reader \(ResumeKey.quote(recv)); sleep 60"], 10)
    check(started.succeeded, "비공개 tmux 서버 시작(-L \(terminalSocketName) -f /dev/null)" + (started.succeeded ? "" : " — \(started.stderr)"))
    guard started.succeeded else { return }
    let panePID = Int32(t(["list-panes", "-t", "reedu", "-F", "#{pane_pid}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    var agent: ProcRecord?
    for _ in 0..<50 {
        agent = liveDescendants(of: panePID, in: ProcessSampler().sample()).first { $0.path == exe }
        if agent != nil { break }
        usleep(100_000)
    }
    guard let agent else { check(false, "더미 에이전트를 찾지 못함 · pane pid \(panePID)"); return }
    usleep(300_000)   // 더미가 입력을 기다리기 시작할 때까지
    let serverPID = Int32(t(["display-message", "-p", "#{pid}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    let sessionID = t(["display-message", "-p", "-t", "reedu", "#{session_id}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let server = TmuxBridge.runningServers().first { $0.pid == serverPID }
    check(server?.socket == socket, "실행 중 서버 찾기: 이름 tmux · 부모 launchd · argv '-L \(terminalSocketName)' → 소켓 \(server?.socket ?? "못 찾음")")

    // 금고용 TMUX 값(세션 프로세스 환경 변수) · pid 재사용 막기
    let detail = TmuxBridge.tmuxVariable(pid: agent.pid, start: agent.key.start)
    let location = detail.flatMap(TmuxBridge.location(fromTMUX:))
    check(location?.socket == socket && location?.serverPID == serverPID && location?.sessionID == sessionID, "세션 프로세스의 TMUX 값 → 서버 \(serverPID) · 세션 \(sessionID) (\(detail ?? "없음"))")
    check(TmuxBridge.tmuxVariable(pid: agent.pid, start: agent.key.start + 1) == nil, "시작 시각이 다르면(pid 재사용) TMUX 값을 읽지 않음")
    var session = AgentSession(id: agent.key, kind: .claudeCode, rootPID: agent.pid, pids: [agent.pid], cwd: root, project: "터미널시험")
    session.terminalHost = "tmux"
    let vault = RecoveryVault(folder: URL(fileURLWithPath: root + "/vault"))
    vault.audit = AuditLog(url: URL(fileURLWithPath: root + "/actions.jsonl"))
    let retired = SessionRetirer.entry(for: session, key: .nothingToLose("시험"), reason: "시험", status: .gone, vault: vault)
    check(retired.terminalHost == "tmux" && retired.terminalDetail != nil && retired.terminalDetail == detail, "정리할 때 금고 항목에 tmux 위치(terminalDetail)를 남김 · \(retired.terminalDetail ?? "없음")")

    // 재교육 지시: 그 pane에만 · 한 줄 + Enter
    let line = "echo ReMON 재교육 시험 \(UUID().uuidString.prefix(6))"
    let sent = TmuxBridge.sendLine(line, sessionRoot: agent.pid, start: agent.key.start, run: guarded)
    var received: [String] = []
    for _ in 0..<30 where !received.contains(line) { usleep(100_000); received = lines(recv) }
    check(sent.ok && received == [line], "재교육 지시 → tmux send-keys로 그 pane에 한 줄 전달 · '\(sent.message)' · 받은 줄 \(received)")
    let wrongStart = TmuxBridge.sendLine(line, sessionRoot: agent.pid, start: agent.key.start + 1, run: guarded)
    check(!wrongStart.ok && wrongStart.message == "세션이 이미 끝났습니다", "pid 재사용(시작 시각 다름)이면 보내지 않음 · '\(wrongStart.message)'")
    t(["copy-mode", "-t", "reedu"])
    let inMode = TmuxBridge.sendLine(line, sessionRoot: agent.pid, start: agent.key.start, run: guarded)
    t(["send-keys", "-t", "reedu", "-X", "cancel"])
    check(!inMode.ok && inMode.message.contains("복사·선택 모드"), "pane이 복사 모드면 보내지 않음 · '\(inMode.message)'")
    kill(agent.pid, SIGSTOP)
    usleep(200_000)
    let stopped = TmuxBridge.sendLine(line, sessionRoot: agent.pid, start: agent.key.start, run: guarded)
    kill(agent.pid, SIGCONT)
    check(!stopped.ok && stopped.message.contains("멈췄거나"), "세션이 멈춰 있으면(Ctrl-Z 꼴) 보내지 않음 · '\(stopped.message)'")
    usleep(300_000)
    check(lines(recv) == [line], "거절한 세 번은 아무 글자도 보내지 않음(받은 줄 그대로 1개)")
    // tmux 밖 프로세스(부모 launchd로 떼어 낸 sleep): 아무 창에도 치지 않는다
    let spawned = Shell.capture("/bin/sh", ["-c", "/bin/sleep 20 </dev/null >/dev/null 2>&1 & echo $!"], timeout: 5)
    if let loose = Int32(spawned.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), let record = ProcessSampler().sample().first(where: { $0.pid == loose }) {
        let outside = TmuxBridge.sendLine(line, sessionRoot: loose, start: record.key.start, run: guarded)
        check(!outside.ok && outside.message == TmuxBridge.noTerminalMessage, "tmux 밖 세션 → '\(outside.message)'")
        kill(loose, SIGTERM)
    } else {
        check(false, "tmux 밖 더미(sleep) 띄우기 실패")
    }

    // 복귀 새 창: 금고의 TMUX 값 → 같은 서버 · 같은 세션의 새 창
    let opens = OpenRecorder()
    let restored = root + "/restored.txt"
    let launch = RecoveryLaunch(arguments: ["/bin/zsh", "-f", "-c", "print -r -- restored >> \(restored); sleep 3"], cwd: root, title: "복귀 · 터미널 시험",
                                terminalHost: "tmux", terminalDetail: detail)
    let opened = RecoveryLaunchers.live(folder: URL(fileURLWithPath: root + "/launch-tmux"), run: fakeOpen(opens, runs: []), tmuxRun: guarded, markerWait: 5)(launch)
    var restoredLines: [String] = []
    for _ in 0..<30 where restoredLines.isEmpty { usleep(100_000); restoredLines = lines(restored) }
    let windows = t(["list-windows", "-t", "reedu", "-F", "#{window_name}"]).stdout.split(separator: "\n").map(String.init)
    check(opened.ok && opened.via == "tmux" && restoredLines == ["restored"] && windows.contains("복귀 · 터미널 시험") && opens.calls.isEmpty,
          "tmux 세션 복귀 → 같은 서버 · 세션 'reedu'의 새 창에서 실행(터미널 안 염) · '\(opened.message)' · 창 \(windows)")
    check(opened.message.contains("보는 화면이 없습니다"), "붙은 화면이 없는 세션이면 tmux attach 안내")
    // 금고 값이 없는 항목(스스로 끝난 세션 등): 살아 있는 서버 중 같은 폴더 pane이 있는 곳으로
    let discovered = root + "/restored-discovered.txt"
    var plain = launch
    plain.terminalDetail = nil
    plain.arguments = ["/bin/zsh", "-f", "-c", "print -r -- discovered >> \(discovered); sleep 3"]
    let viaDiscovery = RecoveryLaunchers.live(folder: URL(fileURLWithPath: root + "/launch-tmux"), run: fakeOpen(opens, runs: []), tmuxRun: guarded, markerWait: 5)(plain)
    var discoveredLines: [String] = []
    for _ in 0..<30 where discoveredLines.isEmpty { usleep(100_000); discoveredLines = lines(discovered) }
    check(viaDiscovery.ok && viaDiscovery.via == "tmux" && viaDiscovery.message.contains("'reedu'") && discoveredLines == ["discovered"] && opens.calls.isEmpty,
          "금고 값 없이 복귀 → 실행 중 서버에서 같은 폴더 pane이 있는 세션 'reedu'의 새 창 · '\(viaDiscovery.message)'")
    // 금고 값이 없을 때: 같은 폴더 pane이 있는 서버·세션을 찾는다 / 없으면 nil(→ 터미널)
    let found = TmuxBridge.restoreTarget(cwd: root, detail: nil, servers: server.map { [$0] } ?? [], run: guarded)
    check(found?.socket == socket && found?.session == sessionID, "금고 값 없이: 같은 폴더 pane이 있는 서버·세션 → \(found.map { "\($0.socket) \($0.session ?? "-")" } ?? "없음")")
    let nowhere = TmuxBridge.restoreTarget(cwd: "/private/tmp/remon-nowhere-\(getpid())", detail: nil, servers: server.map { [$0] } ?? [], run: guarded)
    check(nowhere == nil, "같은 폴더 pane도 기본 서버도 없으면 tmux로 열지 않음(→ 터미널)")

    // 터미널로 이동: 다른 창이 앞에 있어도 그 세션의 창·pane을 현재 창으로(글자는 보내지 않음)
    t(["new-window", "-t", "reedu:", "/bin/sleep", "30"])
    let before = t(["display-message", "-p", "-t", "reedu", "#{window_index} #{pane_id}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let revealed = TmuxBridge.reveal(sessionRoot: agent.pid, start: agent.key.start, run: guarded)
    let after = t(["display-message", "-p", "-t", "reedu", "#{window_index} #{pane_id}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    check(revealed.ok && before != after && after == "0 %0" && revealed.host == nil && revealed.message.contains("보는 화면이 없습니다") && lines(recv) == [line],
          "터미널로 이동(tmux): 앞의 창 \(before) → 세션의 창 \(after) · 글자 안 보냄 · '\(revealed.message)'")
    // 화면(클라이언트)이 다른 세션을 보고 있으면 그 화면을 이 세션으로 돌리고, 그 화면을 띄운 터미널을 돌려준다:
    // script로 가짜 터미널을 붙인 클라이언트(세션 other) → script → 이 검사 → 이 검사를 띄운 터미널
    t(["new-session", "-d", "-s", "other", "-c", root, "/bin/sleep", "60"])
    let client = Process()
    client.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    client.arguments = ["-q", "/dev/null", tmux, "-S", socket, "attach", "-t", "other"]
    var clientEnvironment = TmuxBridge.commandEnvironment
    clientEnvironment["TERM"] = "xterm-256color"
    client.environment = clientEnvironment
    client.standardInput = Pipe()
    client.standardOutput = FileHandle.nullDevice
    client.standardError = FileHandle.nullDevice
    if (try? client.run()) != nil {
        var attached = false
        for _ in 0..<40 where !attached { usleep(100_000); attached = !t(["list-clients", "-t", "other", "-F", "#{client_pid}"]).stdout.isEmpty }
        let records = ProcessSampler().sample()
        let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var expected: TerminalHost?
        var cursor = byPID[getpid()]
        while let item = cursor, item.pid > 1, expected == nil {
            if let host = TerminalHosts.host(for: item), !host.multiplexer { expected = host }
            cursor = byPID[item.ppid]
        }
        let withClient = TmuxBridge.reveal(sessionRoot: agent.pid, start: agent.key.start, run: guarded)
        let viewing = t(["list-clients", "-F", "#{client_session}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        check(attached && withClient.ok && viewing == "reedu" && withClient.host == expected && !withClient.message.contains("보는 화면이 없습니다"),
              "다른 세션(other)을 보던 화면을 그 세션(\(viewing))으로 돌리고, 그 화면을 띄운 터미널을 돌려줌(client → script → 이 검사 → \(expected?.name ?? "터미널 없음")) · '\(withClient.message)'")
        client.terminate()
    } else {
        check(false, "script로 tmux 클라이언트 붙이기 실패")
    }

    // 서버가 끝난 뒤의 복귀: 금고 값이 가리키는 서버가 없으면 터미널
    t(["kill-server"])
    usleep(300_000)
    let fallbackOpens = OpenRecorder()
    let fallbackOut = root + "/restored-fallback.txt"
    var stale = launch
    stale.arguments = ["/bin/zsh", "-f", "-c", "print -r -- fallback >> \(fallbackOut)"]
    let fallback = RecoveryLaunchers.live(folder: URL(fileURLWithPath: root + "/launch-tmux"), run: fakeOpen(fallbackOpens, runs: ["Terminal"]), tmuxRun: guarded, markerWait: 2)(stale)
    check(fallback.ok && fallback.via == "터미널" && fallback.message.hasPrefix("tmux 서버가 없어") && lines(fallbackOut) == ["fallback"],
          "tmux 서버가 사라졌으면 터미널 새 창 · '\(fallback.message)'")
    // 다른 서버 조회(list-panes)는 설계상 읽기뿐이다. 바꾸는 명령(new-window · send-keys)이 비공개 소켓 밖으로 간 일이 없어야 한다.
    let mutating = leaks.calls.filter { $0.1.contains("new-window") || $0.1.contains("send-keys") }
    check(mutating.isEmpty, "새 창·글자 보내기는 대상 서버(비공개 소켓)에만 · 밖으로 간 읽기 조회 \(leaks.calls.count)건은 시험 실행기가 막음"
          + (mutating.isEmpty ? "" : " — \(mutating.map { $0.1.joined(separator: " ") })"))
}

// MARK: - Ghostty 실제 창(terminal --ghostty)

private func ghosttyLive(_ root: String) {
    guard TerminalHosts.appInstalled("Ghostty.app") else { print("SKIP Ghostty 미설치"); return }
    let recorder = OpenRecorder()
    // Ghostty 열기만 실제로 한다. 터미널로 넘어가는 호출은 막는다(검사 중 터미널 창이 뜨지 않게).
    let run: CommandRunner = { executable, arguments, timeout in
        recorder.add(executable, arguments)
        guard executable == "/usr/bin/open", arguments.starts(with: ["-n", "-b", "com.mitchellh.ghostty"]) else { return CommandResult(status: 1, stderr: "시험: 터미널로 넘어가는 호출 막음") }
        return Shell.capture(executable, arguments, timeout: timeout)
    }
    let marker = root + "/ghostty-ran.txt"
    let folder = root + "/launch-ghostty"
    let launch = RecoveryLaunch(arguments: ["/bin/zsh", "-f", "-c", "print -r -- 'ReMON Ghostty 복귀 확인 — 1초 뒤 닫힙니다'; print -r -- $TERM_PROGRAM > \(marker); sleep 1"],
                                cwd: root, title: "복귀 · Ghostty 시험", terminalHost: "Ghostty")
    let begin = Date()
    let result = RecoveryLaunchers.live(folder: URL(fileURLWithPath: folder), run: run, markerWait: 10)(launch)
    let elapsed = Date().timeIntervalSince(begin)
    var ran: [String] = []
    for _ in 0..<30 where ran.isEmpty { usleep(100_000); ran = lines(marker) }
    check(result.ok && result.via == "Ghostty" && recorder.calls.count == 1, String(format: "Ghostty 새 창에서 이어 열기(실제 창) · '%@' · 시작 표시까지 %.1f초", result.message, elapsed))
    check(ran == ["ghostty"], "스크립트가 Ghostty 안에서 돌았음(TERM_PROGRAM=\(ran.first ?? "없음"))")
    func mine() -> [Int32] {
        ProcessSampler().sample().filter { record in
            (record.path ?? "").contains("/Ghostty.app/") && (ProcessSampler.readArguments(pid: record.pid)?.argv.contains { $0.hasPrefix(folder) } ?? false)
        }.map(\.pid)
    }
    var left = mine()
    for _ in 0..<40 where !left.isEmpty { usleep(250_000); left = mine() }
    check(left.isEmpty, "명령이 끝나면 Ghostty 창·인스턴스가 스스로 닫힘(-e → quit-after-last-window-closed)")
    for pid in left { kill(pid, SIGTERM) }   // 이 검사가 띄운 인스턴스만(argv에 검사 폴더)
}
