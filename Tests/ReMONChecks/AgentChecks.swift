import Darwin
import Foundation
import ReMONCore

// 에이전트 서명 표 · 터미널 호스트 · 고아 규칙 검사. 합성 프로세스 표로만 돌린다(대표님 실제 세션은 읽지도 않는다).
// `agents-live`만 이 Mac에 설치된 CLI(gemini · cursor-agent)를 네트워크 차단 샌드박스 + 임시 홈에서 잠깐 띄워 실제 실행 모양을 확인한다.

/// 합성 프로세스 표: 감지기가 argv·작업 폴더를 여기서 읽는다.
final class FakeProcesses: ProcessDetailSource {
    private(set) var records: [ProcRecord] = []
    private var argv: [ProcessKey: [String]] = [:]
    private var cwd: [ProcessKey: String] = [:]
    private var nextPID: Int32 = 910_000   // macOS pid 상한(99999) 밖 → 실제 프로세스·Claude 레지스트리와 겹치지 않는다
    let started: Date

    init(started: Date = Date().addingTimeInterval(-600)) { self.started = started }

    private var environment: [ProcessKey: [String: String]] = [:]

    @discardableResult
    func add(_ name: String, _ path: String?, _ argv: [String], parent: Int32 = 1, cwd: String? = "/Users/test/DEV/샘플", tty: Bool = true, cpu: Double = 0,
             env: [String: String] = [:]) -> ProcRecord {
        nextPID += 1
        let record = ProcRecord(pid: nextPID, ppid: parent, name: name, path: path, startTime: started, cpuPercent: cpu, footprint: 40_000_000, ttyDevice: tty ? 0x1000_0003 : -1)
        records.append(record)
        self.argv[record.key] = argv
        if let cwd { self.cwd[record.key] = cwd }
        if !env.isEmpty { environment[record.key] = env }
        return record
    }

    /// pid → 열린 파일(Codex rollout 등)
    var open: [Int32: [String]] = [:]

    func arguments(for key: ProcessKey) -> ProcArgs? { argv[key].map { ProcArgs(executable: $0.first ?? "", argv: $0, environment: environment[key] ?? [:]) } }
    func workingDirectory(for key: ProcessKey, now: Date) -> String? { cwd[key] }
    func openFiles(for key: ProcessKey, pid: Int32) -> [String] { open[pid] ?? [] }
}

private func detector(_ state: AgentCatalog.State = AgentCatalog.State()) -> SessionDetector {
    let detector = SessionDetector()
    detector.catalog = AgentCatalog(defaults: nil, initial: state)
    return detector
}

private func expect(_ match: AgentMatch?, _ id: String?, role: String? = nil, helper: Bool = false, _ label: String) {
    guard let id else { check(match == nil, "아님 · \(label)\(match.map { " (잘못 잡음: \($0.kind.rawValue))" } ?? "")"); return }
    let ok = match?.kind.rawValue == id && match?.helper == helper && (role == nil || match?.role == role)
    check(ok, (helper ? "보조 · " : "맞음 · ") + label + (ok ? "" : " → 실제 \(match.map { "\($0.kind.rawValue)/\($0.role)/helper=\($0.helper)" } ?? "nil")"))
}

func agentsCheck() {
    // 1. 표 자체
    let all = AgentSignatures.all
    check(Set(all.map(\.id)).count == all.count, "서명 id 중복 없음(\(all.count)줄)")
    check(AgentSignatures.generic.allSatisfy { $0.resume == .unknown }, "표 에이전트는 모두 이어 열기 '모름'(이어 열기 키 없음)")
    check(AgentSignatures.generic.allSatisfy { !$0.commands.isEmpty && !($0.binaryNames.isEmpty && $0.scriptNames.isEmpty && $0.markers.isEmpty) }, "표 에이전트마다 명령·감지 근거가 있음")
    check(AgentSignatures.resume(for: .claudeCode).isKnown && AgentSignatures.resume(for: .codexCLI).isKnown, "Claude Code · Codex 이어 열기 알려짐")
    check(AgentSignatures.resume(for: .opencode) == .known("opencode --session <id>"), "OpenCode 이어 열기 = --session(이 Mac opencode --help로 확인)")
    check(AgentKind.allCases.count == AgentKind.builtIns.count + AgentSignatures.generic.count, "종류 목록 = 기본 \(AgentKind.builtIns.count) + 표 \(AgentSignatures.generic.count)")
    let gemini = AgentSignatures.generic[0].kind
    let encoded = try? JSONEncoder().encode([AgentKind.claudeCode, gemini])
    let decoded = encoded.flatMap { try? JSONDecoder().decode([AgentKind].self, from: $0) }
    check(decoded == [.claudeCode, gemini] && decoded?[1].name == "Gemini CLI", "종류 저장·복원(rawValue) · 이름 유지")
    check(AgentKind(rawValue: "nope") == nil && AgentKind(rawValue: "codexCLI") == .codexCLI, "모르는 종류는 nil, 아는 종류는 그대로")
    check(gemini.isGeneric && !AgentKind.claudeCode.isGeneric && gemini.teamName == "Gemini CLI팀" && AgentKind.codexCLI.teamName == "Codex팀", "표 종류 = 일반(이어 열기 없음) · 팀 이름")

    // 2. 판정(맞게 잡는 것)
    let nvmNode = "/Users/u/.nvm/versions/node/v24.13.1/bin/node"
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "--no-warnings=DEP0040", "/Users/u/.nvm/versions/node/v24.13.1/bin/gemini"]), "gemini", role: "대화형", "Gemini · nvm(#!/usr/bin/env -S node 옵션 건너뜀)")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: [nvmNode, "--max-old-space-size=8192", "/Users/u/.nvm/versions/node/v24.13.1/lib/node_modules/@google/gemini-cli/bundle/gemini.js"]), "gemini", "Gemini · 다시 띄운 자식(패키지 표식)")
    expect(AgentSignatures.match(name: "node", path: "/opt/homebrew/Cellar/node/25.1.0/bin/node", argv: ["/opt/homebrew/opt/node/bin/node", "/opt/homebrew/bin/gemini"]), "gemini", "Gemini · Homebrew")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "/opt/homebrew/bin/gemini", "-p", "요약해줘"]), "gemini", role: SessionDetector.helperRole, "Gemini -p · 일회성")
    expect(AgentSignatures.match(name: "node", path: "/Users/u/Library/Application Support/Zed/node/node-v22.20.0-darwin-arm64/bin/node",
                                 argv: ["node", "/Users/u/Library/Application Support/Zed/external_agents/gemini/node_modules/@google/gemini-cli/dist/index.js", "--experimental-acp"]),
           "gemini", role: AgentSignatures.editorRole, "Gemini · Zed가 띄운 ACP")
    let cursorDir = "/Users/u/.local/share/cursor-agent/versions/2026.10.01-e373342"
    expect(AgentSignatures.match(name: "node", path: cursorDir + "/node", argv: ["cursor-agent", "--use-system-ca", cursorDir + "/index.js"]), "cursorAgent", role: "대화형", "Cursor Agent · 번들 node + index.js")
    expect(AgentSignatures.match(name: "node", path: cursorDir + "/node", argv: ["agent", "--use-system-ca", cursorDir + "/index.js", "-p", "fix"]), "cursorAgent", role: SessionDetector.helperRole, "Cursor Agent -p · 일회성")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "/opt/homebrew/bin/copilot"]), "copilot", "Copilot CLI · npm")
    expect(AgentSignatures.match(name: "python3.12", path: "/Users/u/.local/share/uv/python/cpython-3.12.9-macos-aarch64-none/bin/python3.12",
                                 argv: ["/Users/u/.local/share/uv/tools/aider-chat/bin/python", "/Users/u/.local/bin/aider", "--model", "sonnet"]), "aider", "Aider · uv tool")
    expect(AgentSignatures.match(name: "python3", path: "/opt/homebrew/Cellar/python@3.12/3.12.9/bin/python3.12", argv: ["python3", "-m", "aider"]), "aider", "Aider · python -m")
    expect(AgentSignatures.match(name: "Python", path: "/Library/Developer/CommandLineTools/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python",
                                 argv: ["/usr/bin/python3", "/Users/u/Library/Python/3.9/bin/aider"]), "aider", "Aider · 프레임워크 python")
    expect(AgentSignatures.match(name: "amp", path: "/Users/u/.amp/bin/amp", argv: ["amp"]), "amp", "Amp · 자체 설치")
    expect(AgentSignatures.match(name: "goose", path: "/Users/u/.local/bin/goose", argv: ["goose", "session"]), "goose", role: "대화형", "Goose · ~/.local/bin")
    expect(AgentSignatures.match(name: "goose", path: "/opt/homebrew/Cellar/block-goose-cli/1.9.0/bin/goose", argv: ["goose"]), "goose", "Goose · Homebrew block-goose-cli")
    expect(AgentSignatures.match(name: "goose", path: "/usr/local/bin/goose", argv: ["goose", "session"]), "goose", "Goose · 표식 없음 + goose session")
    expect(AgentSignatures.match(name: "crush", path: "/opt/homebrew/Cellar/crush/0.12.0/bin/crush", argv: ["crush"]), "crush", "Crush")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "/Users/u/.npm-global/bin/qwen"]), "qwen", "Qwen Code")
    expect(AgentSignatures.match(name: "droid", path: "/Users/u/.local/bin/droid", argv: ["droid"]), "droid", role: "대화형", "Factory Droid")
    expect(AgentSignatures.match(name: "droid", path: "/Users/u/.local/bin/droid", argv: ["droid", "exec", "테스트 고쳐"]), "droid", role: SessionDetector.helperRole, "Droid exec · 일회성")
    expect(AgentSignatures.match(name: "python3.13", path: "/Users/u/.local/share/uv/python/cpython-3.13.1/bin/python3.13", argv: ["/Users/u/.local/share/uv/tools/kimi-cli/bin/python", "/Users/u/.local/bin/kimi"]), "kimi", "Kimi CLI")
    // npm 전역 설치처럼 bin/amp가 링크일 때: 링크를 따라간 실제 경로의 표식으로 인정한다(실제 임시 파일로 확인).
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("remon-agents-\(getpid())").path
    defer { try? FileManager.default.removeItem(atPath: temp) }
    try? FileManager.default.createDirectory(atPath: temp + "/lib/node_modules/@sourcegraph/amp/dist", withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: temp + "/bin", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: temp + "/lib/node_modules/@sourcegraph/amp/dist/main.js", contents: Data("//".utf8))
    try? FileManager.default.createSymbolicLink(atPath: temp + "/bin/amp", withDestinationPath: temp + "/lib/node_modules/@sourcegraph/amp/dist/main.js")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", temp + "/bin/amp"]), "amp", "Amp · npm 링크(실제 경로의 @sourcegraph/amp)")

    // 3. 판정(잡으면 안 되는 것 · 보조)
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "/Users/u/.npm/_npx/ab12/node_modules/.bin/mcp-server-filesystem", "/Users/u"]), nil, "MCP 서버 node")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "install", "-g", "@google/gemini-cli"]), nil, "npm으로 gemini 설치 중")
    expect(AgentSignatures.match(name: "copilot", path: "/opt/homebrew/Cellar/copilot-cli/1.34.0/bin/copilot", argv: ["copilot", "app", "ls"]), nil, "AWS Copilot CLI(같은 이름 Go 바이너리)")
    expect(AgentSignatures.match(name: "goose", path: "/Users/u/go/bin/goose", argv: ["goose", "postgres", "user=x dbname=y", "up"]), nil, "pressly/goose DB 마이그레이션")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "/nowhere/bin/amp"]), nil, "근거 없는 amp 스크립트(링크 아님)")
    expect(AgentSignatures.match(name: "python3", path: "/usr/bin/python3", argv: ["python3", "/Users/u/DEV/aider-notes/run.py"]), nil, "폴더 이름만 aider인 python 스크립트")
    expect(AgentSignatures.match(name: "rg", path: cursorDir + "/rg", argv: ["rg", "TODO"]), nil, "cursor-agent 폴더 안 rg")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "/opt/homebrew/bin/gemini", "--version"]), nil, "gemini --version(버전 확인)")
    expect(AgentSignatures.match(name: "goose", path: "/Users/u/.local/bin/goose", argv: ["goose", "mcp", "developer"]), "goose", helper: true, "goose mcp developer")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "/opt/homebrew/bin/gemini", "mcp", "list"]), "gemini", helper: true, "gemini mcp list")
    let workerDir = "/Users/u/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/share/cursor-agent/versions/2026.10.22-27dcf5f"
    expect(AgentSignatures.match(name: "node", path: workerDir + "/node", argv: ["…/agent-cli/.local/bin/cursor-agent", "--use-system-ca", workerDir + "/index.js",
                                                                                "--api-key", "FAKE-KEY", "--endpoint", "https://example.invalid", "worker", "start"]),
           "cursorAgent", helper: true, "Cursor 앱의 백그라운드 워커(worker start)")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "/opt/homebrew/bin/gemini"], disabled: ["gemini"]), nil, "설정에서 끈 Gemini")

    // 4. 직접 추가
    let acme = CustomAgent(name: "사내 에이전트", processName: "acme-agent", pathPattern: "")
    let bot = CustomAgent(name: "실험 봇", processName: "", pathPattern: "/opt/bot/")
    expect(AgentSignatures.match(name: "acme-agent", path: "/opt/acme/bin/acme-agent", argv: ["acme-agent"], custom: [acme]), acme.id, "직접 추가 · 프로세스 이름")
    expect(AgentSignatures.match(name: "node", path: nvmNode, argv: ["node", "/opt/bot/main.js"], custom: [bot]), bot.id, "직접 추가 · 경로 조각(node 스크립트)")
    check(AgentSignatures.match(name: "acme-agent", path: "/opt/acme/bin/acme-agent", argv: ["acme-agent"], custom: [acme])?.kind.name == "사내 에이전트", "직접 추가 · 표시 이름 유지")
    let rejected = [CustomAgent(name: "x", processName: "node", pathPattern: ""), CustomAgent(name: "x", processName: "", pathPattern: "/Users/"),
                    CustomAgent(name: "x", processName: "zsh", pathPattern: ""), CustomAgent(name: "", processName: "acme", pathPattern: ""), CustomAgent(name: "x", processName: "", pathPattern: "")]
    check(rejected.allSatisfy { $0.validationError != nil }, "너무 넓은 직접 추가 거부(node만 · /Users/ · zsh · 이름 없음 · 둘 다 비움): " + rejected.compactMap(\.validationError).joined(separator: " / "))
    let memory = AgentCatalog(defaults: nil)
    check(memory.upsert(rejected[0]) != nil && memory.current.custom.isEmpty && memory.upsert(acme) == nil && memory.current.custom == [acme], "카탈로그: 잘못된 정의는 저장 안 함 · 올바른 정의 저장")
    memory.setEnabled("gemini", false)
    check(!memory.isEnabled(gemini) && memory.isEnabled(.claudeCode), "카탈로그: 켜기·끄기")

    detectorScenarios()
    codexDaemonScenarios()
    signatureTable()
    installedOnThisMac()
}

/// Codex 기반 시설(app-server·exec-server·mcp-server·공유 데몬)은 세션이 아니라 도구, 데몬 모드 클라이언트는 추정 연결.
private func codexDaemonScenarios() {
    let fake = FakeProcesses()
    let nvm = "/Users/u/.nvm/versions/node/v24.13.1"
    let vendorPath = nvm + "/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex"
    let daemonPath = "/Users/u/.codex/packages/app-server-daemon/releases/0.163.0-aarch64-apple-darwin/bin/codex"
    let folder = "/Users/test/DEV/코덱스"
    // 데몬이 연 rollout 세 개: 최상위(이 폴더) · 하위 에이전트(같은 폴더, 더 최근) · 최상위(다른 폴더). 실제 임시 파일(첫 줄 session_meta).
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("remon-codex-\(getpid())/.codex/sessions/2026/10/25").path
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("remon-codex-\(getpid())").path) }
    func rollout(_ id: String, cwd: String, parent: String?, minutesAgo: Double) -> String {
        let path = base + "/rollout-2026-10-25T00-00-00-\(id).jsonl"
        let parentJSON = parent.map { "\"\($0)\"" } ?? "null"
        let stamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-minutesAgo * 60))
        let text = "{\"timestamp\":\"\(stamp)\",\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"\(cwd)\",\"parent_thread_id\":\(parentJSON),\"base_instructions\":\"\(String(repeating: "x", count: 30_000))\"}}\n"
            + "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"데몬 세션 요청 \(id.prefix(4))\"}}\n"
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-minutesAgo * 60)], ofItemAtPath: path)
        return path
    }
    let top = rollout("01a20000-0000-7000-8000-00000000000a", cwd: folder, parent: nil, minutesAgo: 1)
    let sub = rollout("01a20000-0000-7000-8000-00000000000b", cwd: folder, parent: "01a20000-0000-7000-8000-00000000000a", minutesAgo: 0.2)
    let other = rollout("01a20000-0000-7000-8000-00000000000c", cwd: "/Users/test/DEV/다른곳", parent: nil, minutesAgo: 0.5)

    let daemon = fake.add("codex", daemonPath, [daemonPath, "app-server", "--listen", "unix:///Users/u/.codex/app-server.sock"], cwd: "/", tty: false)
    let loop = fake.add("codex", daemonPath, [daemonPath, "app-server", "daemon", "pid-update-loop"], cwd: "/", tty: false)
    fake.open[daemon.pid] = [top, sub, other, "/Users/u/.codex/state_5.sqlite"]
    // 데몬 모드 TUI(--no-daemon 없음, rollout 없음): Ghostty → zsh → node 래퍼 → 공급 바이너리
    let ghostty = fake.add("ghostty", "/Applications/Ghostty.app/Contents/MacOS/ghostty", ["ghostty"], tty: false)
    let zsh = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: ghostty.pid, cwd: folder)
    let client = fake.add("node", nvm + "/bin/node", ["node", nvm + "/bin/codex"], parent: zsh.pid, cwd: folder)
    let clientVendor = fake.add("codex", vendorPath, [vendorPath], parent: client.pid, cwd: folder)
    // --no-daemon TUI가 아직 rollout을 열기 전 → 데몬 클라이언트가 아니다
    let zsh2 = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: ghostty.pid, cwd: folder)
    let direct = fake.add("node", nvm + "/bin/node", ["node", nvm + "/bin/codex", "--no-daemon"], parent: zsh2.pid, cwd: folder)
    _ = fake.add("codex", vendorPath, [vendorPath, "--no-daemon"], parent: direct.pid, cwd: folder)
    // pid 19954 모양: even-terminal(node, 부모 launchd) → node 래퍼 `codex app-server --listen ws://…` → 공급 바이너리
    let host = fake.add("node", nvm + "/bin/node", ["node", nvm + "/bin/even-terminal"], cwd: "/Users/u", tty: false)
    let wsWrapper = fake.add("node", nvm + "/bin/node", ["node", nvm + "/bin/codex", "app-server", "--listen", "ws://127.0.0.1:8765"], parent: host.pid, cwd: "/Users/u/DEV", tty: false)
    let wsVendor = fake.add("codex", vendorPath, [vendorPath, "app-server", "--listen", "ws://127.0.0.1:8765"], parent: wsWrapper.pid, cwd: "/Users/u/DEV", tty: false)
    // exec-server · mcp-server(부모 launchd) · Claude 세션 안 mcp-server · ChatGPT 앱 내장 CodexCLI.app app-server
    let exec = fake.add("codex", vendorPath, [vendorPath, "exec-server"], cwd: "/Users/u", tty: false)
    let mcpLoose = fake.add("codex", vendorPath, [vendorPath, "mcp-server"], cwd: "/Users/u", tty: false)
    let zsh3 = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: ghostty.pid, cwd: "/Users/test/DEV/클로드")
    let claude = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude"], parent: zsh3.pid, cwd: "/Users/test/DEV/클로드")
    let mcpInClaude = fake.add("codex", vendorPath, [vendorPath, "mcp-server"], parent: claude.pid, cwd: "/Users/test/DEV/클로드")
    let desktop = fake.add("codex", "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                           ["codex", "app-server", "--listen", "stdio://"], parent: claude.pid, cwd: "/Users/test/DEV/클로드")

    let result = detector().detect(records: fake.records, sampler: fake, orca: [])
    func session(_ root: ProcRecord) -> AgentSession? { result.sessions.first { $0.rootPID == root.pid } }
    let infra = [daemon, loop, wsWrapper, wsVendor, exec, mcpLoose]
    check(infra.allSatisfy { record in !result.sessions.contains { $0.rootPID == record.pid } }, "app-server·exec-server·mcp-server·공유 데몬·pid-update-loop → 세션 아님(pid 19954 모양 포함)")
    let server = result.apps.first { $0.id == "codex-server" }
    check(server.map { Set($0.pids).isSuperset(of: infra.map(\.pid)) && $0.category == .agentApp } ?? false,
          "Codex 기반 시설 → 도구 묶음 '\(server?.name ?? "-")' \(server?.pids.count ?? 0)개 프로세스")
    let claudeSession = session(claude)
    check(claudeSession.map { $0.pids.contains(mcpInClaude.pid) && $0.pids.contains(desktop.pid) } ?? false && session(mcpInClaude) == nil && session(desktop) == nil,
          "Claude 안에서 뜬 codex mcp-server · ChatGPT 앱 app-server → 그 세션 트리에 남음(별도 세션 아님)")
    let daemonClient = session(client)
    check(daemonClient?.kind == .codexCLI && daemonClient?.codexDaemonClient == true && daemonClient?.pids.contains(clientVendor.pid) == true, "데몬 모드 TUI(--no-daemon 없음 · rollout 없음) → Codex 세션 · 데몬 클라이언트 표시")
    check(daemonClient?.logPath == top && daemonClient?.logLinkIsEstimate == true, "데몬 클라이언트 ↔ 데몬이 연 최상위 rollout(같은 폴더) · 하위 에이전트·다른 폴더 제외 · 추정 표시")
    check(daemonClient.map { !$0.resumeKeyVerified && $0.role.contains("공유 데몬") } ?? false, "데몬 클라이언트 이어 열기 키 = 불확실(resumeKeyVerified false) · 역할 '\(daemonClient?.role ?? "-")'")
    check(daemonClient?.title == "데몬 세션 요청 01a2" && daemonClient?.state == .working, "데몬 클라이언트 제목·상태는 추정 rollout에서(\(daemonClient?.state.label ?? "-") — \(daemonClient?.stateReason ?? "-"))")
    let normal = session(direct)
    check(normal?.codexDaemonClient == false && normal?.logPath == nil, "--no-daemon TUI(rollout 열기 전) → 데몬 클라이언트 아님")
}

/// 감지기 통합: 터미널 호스트 · 같은 종류 자식 묶기 · 고아 규칙 · Orca · 보호.
private func detectorScenarios() {
    let fake = FakeProcesses()
    let nvmNode = "/Users/u/.nvm/versions/node/v24.13.1/bin/node"
    // Ghostty → login → zsh → gemini(부모) → gemini(다시 띄운 자식) → MCP 서버
    let ghostty = fake.add("ghostty", "/Applications/Ghostty.app/Contents/MacOS/ghostty", ["ghostty"], tty: false)
    let login = fake.add("login", "/usr/bin/login", ["login", "-flp", "u"], parent: ghostty.pid)
    let zsh1 = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: login.pid, cwd: "/Users/test/DEV/알파")
    let geminiParent = fake.add("node", nvmNode, ["node", "--no-warnings=DEP0040", "/Users/u/.nvm/versions/node/v24.13.1/bin/gemini"], parent: zsh1.pid, cwd: "/Users/test/DEV/알파")
    let geminiChild = fake.add("node", nvmNode, [nvmNode, "--max-old-space-size=8192", "/Users/u/.nvm/versions/node/v24.13.1/lib/node_modules/@google/gemini-cli/bundle/gemini.js"], parent: geminiParent.pid, cwd: "/Users/test/DEV/알파")
    let mcp = fake.add("node", nvmNode, ["node", "/Users/u/.npm/_npx/x/node_modules/.bin/mcp-server-git"], parent: geminiChild.pid)
    // 터미널.app → login → zsh → cursor-agent(+ rg)
    let terminal = fake.add("Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", ["Terminal"], tty: false)
    let login2 = fake.add("login", "/usr/bin/login", ["login", "-pf", "u"], parent: terminal.pid)
    let zsh2 = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: login2.pid, cwd: "/Users/test/DEV/베타")
    let cursorDir = "/Users/u/.local/share/cursor-agent/versions/2026.10.01-e373342"
    let cursor = fake.add("node", cursorDir + "/node", ["cursor-agent", "--use-system-ca", cursorDir + "/index.js"], parent: zsh2.pid, cwd: "/Users/test/DEV/베타")
    let rg = fake.add("rg", cursorDir + "/rg", ["rg", "TODO"], parent: cursor.pid)
    // 그 밖의 호스트: Warp · WezTerm · kitty · Alacritty · VS Code · iTerm(번들 밖 iTermServer) · SSH
    func hosted(_ hostName: String, _ hostPath: String, agent: (String, String, [String]), folder: String) -> ProcRecord {
        let host = fake.add(hostName, hostPath, [hostName], tty: false)
        let shell = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: host.pid, cwd: folder)
        return fake.add(agent.0, agent.1, agent.2, parent: shell.pid, cwd: folder)
    }
    let crush = hosted("stable", "/Applications/Warp.app/Contents/MacOS/stable", agent: ("crush", "/opt/homebrew/Cellar/crush/0.12.0/bin/crush", ["crush"]), folder: "/Users/test/DEV/워프")
    let qwen = hosted("wezterm-gui", "/Applications/WezTerm.app/Contents/MacOS/wezterm-gui", agent: ("node", nvmNode, ["node", "/Users/u/.npm-global/bin/qwen"]), folder: "/Users/test/DEV/웨즈")
    let droid = hosted("kitty", "/Applications/kitty.app/Contents/MacOS/kitty", agent: ("droid", "/Users/u/.local/bin/droid", ["droid"]), folder: "/Users/test/DEV/키티")
    let kimi = hosted("alacritty", "/Applications/Alacritty.app/Contents/MacOS/alacritty", agent: ("python3.13", "/usr/local/bin/python3.13", ["python3", "/Users/u/.local/bin/kimi"]), folder: "/Users/test/DEV/알라")
    let aider = hosted("Code Helper (Plugin)", "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)",
                       agent: ("python3.12", "/opt/homebrew/bin/python3.12", ["python3", "/Users/u/.local/bin/aider"]), folder: "/Users/test/DEV/코드")
    let copilot = hosted("iTermServer-3.5.", "/Users/u/Library/Application Support/iTerm2/iTermServer-3.5.4", agent: ("node", nvmNode, ["node", "/opt/homebrew/bin/copilot"]), folder: "/Users/test/DEV/아이텀")
    let ssh = hosted("sshd-session", "/usr/libexec/sshd-session", agent: ("node", nvmNode, ["node", "/opt/homebrew/bin/gemini"]), folder: "/Users/test/DEV/원격")
    // tmux: 서버는 launchd 아래(분리된 세션) → zsh(터미널 있음) → goose session
    let tmux = fake.add("tmux", "/opt/homebrew/Cellar/tmux/3.6a/bin/tmux", ["tmux", "new", "-d"], tty: false)
    let zsh3 = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: tmux.pid, cwd: "/Users/test/DEV/티먹스")
    let goose = fake.add("goose", "/Users/u/.local/bin/goose", ["goose", "session"], parent: zsh3.pid, cwd: "/Users/test/DEV/티먹스")
    // 창이 닫힌 뒤 살아남은 amp: 부모 launchd · 제어 터미널 없음
    let amp = fake.add("amp", "/Users/u/.amp/bin/amp", ["amp"], parent: 1, cwd: "/Users/test/DEV/고아", tty: false)
    // Orca 안 Gemini(Orca가 gemini 종류를 모름) — 잔재로 몰지 않아야 한다
    let orcaHost = fake.add("orca-daemon", "/Users/u/orca/daemon-host/orca-daemon", ["orca-daemon"], tty: false)
    let zsh4 = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: orcaHost.pid, cwd: "/Users/test/DEV/오르카")
    let orcaGemini = fake.add("node", nvmNode, ["node", "/opt/homebrew/bin/gemini"], parent: zsh4.pid, cwd: "/Users/test/DEV/오르카")
    // Cursor 앱 워커(부모 launchd, 터미널 없음) — 세션이 아니다
    let workerDir = "/Users/u/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/share/cursor-agent/versions/2026.10.22-27dcf5f"
    let worker = fake.add("node", workerDir + "/node", ["cursor-agent", "--use-system-ca", workerDir + "/index.js", "--api-key", "FAKE-KEY", "worker", "start"], tty: false)
    // CPU로 일하는 중인 Gemini · 버전 확인 중인 claude · 직접 추가 에이전트
    let busy = hosted("ghostty", "/Applications/Ghostty.app/Contents/MacOS/ghostty", agent: ("node", nvmNode, ["node", "/opt/homebrew/bin/gemini"]), folder: "/Users/test/DEV/바쁨")
    let busyRecord = fake.records.firstIndex { $0.pid == busy.pid }
    let versionProbe = hosted("ghostty", "/Applications/Ghostty.app/Contents/MacOS/ghostty", agent: ("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude", "--version"]), folder: "/Users/test/DEV/버전")
    let acme = CustomAgent(name: "사내 에이전트", processName: "acme-agent", pathPattern: "")
    let custom = hosted("ghostty", "/Applications/Ghostty.app/Contents/MacOS/ghostty", agent: ("acme-agent", "/opt/acme/bin/acme-agent", ["acme-agent"]), folder: "/Users/test/DEV/직접")
    // Claude 세션 안에서 잠깐 부른 gemini -p → 별도(중첩) 세션, 부모 세션 표시
    let claude = hosted("ghostty", "/Applications/Ghostty.app/Contents/MacOS/ghostty", agent: ("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude"]), folder: "/Users/test/DEV/중첩")
    let claudeShell = fake.add("zsh", "/bin/zsh", ["zsh", "-c", "gemini -p x"], parent: claude.pid, cwd: "/Users/test/DEV/중첩")
    let nestedGemini = fake.add("node", nvmNode, ["node", "/opt/homebrew/bin/gemini", "-p", "요약"], parent: claudeShell.pid, cwd: "/Users/test/DEV/중첩")

    var records = fake.records
    if let busyRecord { records[busyRecord].cpuPercent = 12 }
    let orca = [OrcaTerminal(handle: "t1", title: "claude 탭", worktreePath: "/Users/test/DEV/오르카", agent: "claude", lastOutputAt: nil, connected: true)]
    let result = detector(AgentCatalog.State(custom: [acme])).detect(records: records, sampler: fake, orca: orca)
    func session(_ root: ProcRecord) -> AgentSession? { result.sessions.first { $0.rootPID == root.pid } }

    let geminiSession = session(geminiParent)
    check(geminiSession?.kind.rawValue == "gemini" && session(geminiChild) == nil, "Gemini 부모·다시 띄운 자식 → 세션 1개")
    check(geminiSession.map { Set($0.pids).isSuperset(of: [geminiChild.pid, mcp.pid]) } ?? false, "Gemini 자식·MCP 서버는 부모 트리에 속함")
    check(geminiSession?.terminalHost == "Ghostty" && geminiSession?.resumeCommand == nil && geminiSession?.logPath == nil, "Gemini · 호스트 Ghostty · 이어 열기 명령 없음 · 기록 연결 없음")
    check(geminiSession?.state == .waiting, "Gemini · CPU 0 · 실행 10분 → 입력 대기(추정) — \(geminiSession?.stateReason ?? "-")")
    check(session(cursor)?.kind.rawValue == "cursorAgent" && session(cursor)?.terminalHost == "터미널" && session(cursor)?.pids.contains(rg.pid) == true && session(rg) == nil, "Cursor Agent · 터미널.app · rg는 트리에")
    let hosts: [(ProcRecord, String, String)] = [(crush, "crush", "Warp"), (qwen, "qwen", "WezTerm"), (droid, "droid", "kitty"), (kimi, "kimi", "Alacritty"),
                                                (aider, "aider", "VS Code"), (copilot, "copilot", "iTerm"), (ssh, "gemini", "SSH"), (goose, "goose", "tmux")]
    for (root, id, host) in hosts {
        let found = session(root)
        check(found?.kind.rawValue == id && found?.terminalHost == host, "\(id) · 호스트 \(host)" + (found == nil ? " (세션 없음)" : " → \(found!.kind.rawValue)/\(found!.terminalHost ?? "없음")"))
    }
    check(session(goose).map { $0.state != .orphan && $0.tabState == .outside } ?? false, "tmux 분리 세션은 잔재 아님 — \(session(goose)?.state.rawValue ?? "-") · \(session(goose)?.stateReason ?? "-")")
    check(session(amp)?.state == .orphan && session(amp)?.stateReason.hasPrefix("터미널 닫힘 · 부모 프로세스 없음") == true, "창 닫힌 뒤 남은 amp → 고아 '\(session(amp)?.stateReason ?? "-")'")
    check(session(orcaGemini).map { $0.terminalHost == "Orca" && $0.tabState == .outside && $0.state != .orphan } ?? false,
          "Orca 안 Gemini(Orca가 종류 모름) → 잔재로 몰지 않음 · 탭 \(session(orcaGemini)?.tabState.rawValue ?? "-")")
    check(session(worker) == nil && !result.sessions.contains { $0.pids.contains(worker.pid) }, "Cursor 앱 워커(부모 launchd) → 세션 아님")
    check(session(busy)?.state == .working, "CPU 12% Gemini → 일하는 중")
    check(session(versionProbe) == nil, "claude --version(버전 확인) → 세션 아님")
    check(session(custom)?.kind.isCustom == true && session(custom)?.kind.name == "사내 에이전트" && session(custom)?.resumeCommand == nil, "직접 추가 에이전트 → 세션 · 이름 · 이어 열기 없음")
    let nested = session(nestedGemini)
    check(session(claude)?.kind == .claudeCode && nested?.role == SessionDetector.helperRole && nested?.parentSession == claude.key && nested?.title == "요약",
          "Claude 안 gemini -p → 보조 호출 중첩 세션 · 제목은 프롬프트")
    let groups = Dictionary(uniqueKeysWithValues: result.apps.map { ($0.id, $0.category) })
    check(groups["/Applications/Ghostty.app"] == .host && groups["/System/Applications/Utilities/Terminal.app"] == .host && groups["/Applications/Warp.app"] == .host,
          "세션을 띄운 터미널 앱 = 터미널 호스트(종료 보호): Ghostty \(groups["/Applications/Ghostty.app"]?.rawValue ?? "-") · 터미널 \(groups["/System/Applications/Utilities/Terminal.app"]?.rawValue ?? "-") · Warp \(groups["/Applications/Warp.app"]?.rawValue ?? "-")")

    // 끈 기본 종류: Claude를 끄면 claude 프로세스가 세션이 되지 않는다.
    let off = detector(AgentCatalog.State(disabled: ["claudeCode"])).detect(records: records, sampler: fake, orca: [])
    check(!off.sessions.contains { $0.kind == .claudeCode } && off.sessions.contains { $0.kind.rawValue == "gemini" }, "Claude를 끄면 Claude 세션 없음(다른 종류는 그대로)")

    print("  합성 세션 \(result.sessions.count)개:")
    for item in result.sessions.sorted(by: { $0.project < $1.project }) {
        print("    [\(item.state.label)] \(item.kind.label) · \(item.role) · \(item.project) · 호스트 \(item.terminalHost ?? "없음") · 하위 \(item.childCount) — \(item.stateReason)")
    }
}

/// 보고용: 서명 표 한눈에.
private func signatureTable() {
    print("  서명 표:")
    for signature in AgentSignatures.all {
        var rule: [String] = []
        if !signature.detectedByTable { rule.append("전용 규칙") }
        if !signature.binaryNames.isEmpty { rule.append("실행 파일 " + signature.binaryNames.joined(separator: "·")) }
        if !signature.scriptNames.isEmpty { rule.append("스크립트 " + signature.scriptNames.joined(separator: "·")) }
        if !signature.markers.isEmpty { rule.append("표식 " + signature.markers.joined(separator: "·")) }
        if signature.nameNeedsEvidence { rule.append("실행 파일 이름만으론 불인정") }
        if signature.scriptNeedsEvidence { rule.append("스크립트 이름만으론 불인정") }
        if !signature.helperArguments.isEmpty { rule.append("보조 " + signature.helperArguments.joined(separator: "·")) }
        print("    \(signature.kind.name) [\(signature.id)] · 명령 \(signature.commands.joined(separator: ",")) · \(rule.joined(separator: " / ")) · 데이터 \(signature.dataFolders.joined(separator: ", ")) · 이어 열기 \(signature.resume.label)")
    }
}

/// 이 Mac 설치 확인(읽기 전용, 버전은 설치 경로·package.json에서 — 여기서는 프로세스를 띄우지 않는다).
private func installedOnThisMac() {
    let rows = AgentInventory.scan(probeVersions: false)
    print("  이 Mac 설치:")
    for row in rows {
        let path = row.path.map { AgentInventory.abbreviate($0) } ?? "없음"
        print("    \(row.kind.name): \(path)\(row.otherPaths.isEmpty ? "" : " (+\(row.otherPaths.count)곳)") · 버전 \(row.version ?? "-")\(row.versionSource.map { "(\($0))" } ?? "") · 데이터 \(row.dataFolder ?? "없음")\(row.nameOnly ? " · 이름만 일치" : "")")
    }
    for command in ["gemini", "cursor-agent"] {
        let which = Shell.run("/usr/bin/which", [command])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !which.isEmpty else { print("  SKIP \(command) 미설치"); continue }
        let row = rows.first { AgentSignatures.signature(for: $0.kind)?.commands.contains(command) == true }
        check(row?.installed == true && row?.version != nil, "설치 확인 · \(command)(which: \(AgentInventory.abbreviate(which))) → \(row?.path.map { AgentInventory.abbreviate($0) } ?? "못 찾음") · 버전 \(row?.version ?? "-")")
    }
    // 실제 설치의 실행 모양으로 판정: 셔뱅·실행 스크립트를 읽어 커널이 넘기는 argv를 그대로 만든다.
    if let gemini = rows.first(where: { $0.kind.rawValue == "gemini" }), let path = gemini.path {
        let script = gemini.resolvedPath ?? path
        let shebang = (try? String(contentsOfFile: script, encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? ""
        var argv = shebang.hasPrefix("#!") ? shebang.dropFirst(2).split(separator: " ").map(String.init) : ["node"]
        if argv.first == "/usr/bin/env" { argv.removeFirst(); if argv.first == "-S" { argv.removeFirst() } }
        argv.append(path)
        let node = argv.first.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/usr/local/bin/node"
        let match = AgentSignatures.match(name: "node", path: (node as NSString).resolvingSymlinksInPath, argv: argv)
        check(match?.kind.rawValue == "gemini", "실제 gemini 실행 모양(\(shebang)) → \(match?.kind.name ?? "못 잡음")")
    }
    if let cursor = rows.first(where: { $0.kind.rawValue == "cursorAgent" }), let resolved = cursor.resolvedPath {
        let launcher = (try? String(contentsOfFile: resolved, encoding: .utf8)) ?? ""
        let directory = (resolved as NSString).deletingLastPathComponent
        let usesNode = launcher.contains("\"$NODE_BIN\"") && launcher.contains("index.js")
        let match = AgentSignatures.match(name: "node", path: directory + "/node", argv: ["cursor-agent", "--use-system-ca", directory + "/index.js"])
        check(usesNode && FileManager.default.fileExists(atPath: directory + "/node") && match?.kind.rawValue == "cursorAgent",
              "실제 cursor-agent 실행 모양(번들 node + index.js, \(AgentInventory.abbreviate(directory))) → \(match?.kind.name ?? "못 잡음")")
    }
}

/// 이 Mac에 설치된 CLI를 실제로 잠깐 띄워 감지기가 진짜 프로세스 표에서 잡는지 확인한다.
/// 네트워크 차단 샌드박스 + 임시 홈(대표님 설정·인증 파일 무접촉), 띄운 프로세스만 pid로 끝낸다.
func agentsLiveCheck() {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("remon-agents-live-\(getpid())").path
    try? fm.createDirectory(atPath: root + "/home", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: root + "/work", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    let rows = AgentInventory.scan(probeVersions: false)
    for id in ["gemini", "cursorAgent"] {
        guard let row = rows.first(where: { $0.kind.rawValue == id }), let path = row.path else { print("SKIP \(id) 미설치"); continue }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // script로 가짜 터미널(PTY)을 붙여 대화형으로 띄운다. 샌드박스는 자식까지 이어진다.
        process.arguments = ["-q", "/dev/null", "/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", path]
        var environment = ["HOME": root + "/home", "TERM": "xterm-256color", "NO_COLOR": "1"]
        environment["PATH"] = [(path as NSString).deletingLastPathComponent, "/usr/bin", "/bin"].joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: root + "/work")
        process.standardInput = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { check(false, "\(id) 실행 실패: \(error)"); continue }
        Thread.sleep(forTimeInterval: 5)
        let sampler = ProcessSampler()
        let records = sampler.sample()
        let mine = descendants(of: process.processIdentifier, in: records)
        let result = detector().detect(records: records, sampler: sampler, orca: [])
        let sessions = result.sessions.filter { mine.contains($0.rootPID) }
        let shape = records.filter { mine.contains($0.pid) && $0.pid != process.processIdentifier }.map { record in
            "\(record.name)(\(record.pid)) " + (sampler.arguments(for: record.key)?.argv.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: " ") ?? "")
        }
        print("  \(id) 실제 프로세스: " + shape.joined(separator: " → "))
        check(sessions.count == 1 && sessions.first?.kind.rawValue == id, "실제 \(row.kind.name) 실행 → 세션 \(sessions.count)개 · \(sessions.first.map { "\($0.kind.name) · \($0.role) · 하위 \($0.childCount) · \($0.state.label)" } ?? "없음")")
        for pid in mine.sorted(by: >) { kill(pid, SIGTERM) }
        process.terminate()
        Thread.sleep(forTimeInterval: 0.5)
        for pid in mine where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}

private func descendants(of root: Int32, in records: [ProcRecord]) -> Set<Int32> {
    var children: [Int32: [Int32]] = [:]
    for record in records { children[record.ppid, default: []].append(record.pid) }
    var result: Set<Int32> = [root]
    var stack = [root]
    while let pid = stack.popLast() {
        for child in children[pid] ?? [] where result.insert(child).inserted { stack.append(child) }
    }
    return result
}

/// 앱이 직접 띄운 일꾼(감사 판정 `claude -p`)은 세션이 아니다(10-25: 감사 중 '감사실' 방이 생기던 문제). 합성 표로만 본다.
func selfSpawnCheck() {
    let fake = FakeProcesses()
    let app = fake.add("ReMON", "/Applications/ReMON.app/Contents/MacOS/ReMON", ["/Applications/ReMON.app/Contents/MacOS/ReMON"], cwd: "/", tty: false)
    let shell = fake.add("zsh", "/bin/zsh", ["/bin/zsh", "-lc", "'claude' '-p' '--tools' ''"], parent: app.pid, cwd: "/Users/u/Library/Application Support/ReMON/감사실", tty: false)
    let judge = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude", "-p", "--tools", "", "--no-session-persistence"], parent: shell.pid,
                         cwd: "/Users/u/Library/Application Support/ReMON/감사실", tty: false)
    let term = fake.add("zsh", "/bin/zsh", ["-zsh"], cwd: "/Users/test/DEV/샘플")
    let person = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude"], parent: term.pid, cwd: "/Users/test/DEV/샘플")
    let plain = detector().detect(records: fake.records, sampler: fake, orca: [])
    check(plain.sessions.contains { $0.rootPID == judge.pid }, "제외 설정이 없으면 앱 아래 claude -p도 세션으로 보임(시험 전제)")
    let guarded = detector()
    guarded.excludedAncestor = app.pid
    let result = guarded.detect(records: fake.records, sampler: fake, orca: [])
    check(!result.sessions.contains { $0.rootPID == judge.pid } && result.sessions.contains { $0.rootPID == person.pid },
          "앱 pid의 자손(감사 판정)은 세션에서 빠지고, 사람이 띄운 세션은 남음(세션 \(result.sessions.count)개)")
    check(!result.sessions.contains { $0.cwd?.hasSuffix("/ReMON/감사실") == true }, "'감사실' 폴더 세션 없음 → 방·직원이 생기지 않음")
}

/// 예비 프로세스를 몇 분 뒤 넘겨받은 Claude 백그라운드 세션도 세션으로 잡는다(10-25: 등록 시각만 보던 pid 재사용 판별이 이 세션을 '대기 인력'으로 숨김).
func claudeBackgroundDetectCheck() {
    check(ClaudeRegistry.procStartDate("Sun Oct 25 01:11:15 2026").map { Int($0.timeIntervalSince1970) } == 1_792_890_675 &&
          ClaudeRegistry.procStartDate("Sun Oct  5 01:11:15 2026") != nil, "레지스트리 procStart 읽기(UTC · 한 자리 날짜의 공백 두 칸)")
    let fake = FakeProcesses()
    let folder = NSTemporaryDirectory() + "remon-registry-\(getpid())"
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let host = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude", "bg-pty-host", "--bg-pty-host", "/tmp/cc/x.pty.sock"], cwd: "/Users/u", tty: false)
    let spare = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude", "bg-spare", "--bg-spare", "/tmp/cc/x.claim.sock"], parent: host.pid,
                         cwd: "/Users/test/DEV/샘플", tty: false)
    let idle = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude", "bg-spare", "--bg-spare", "/tmp/cc/y.claim.sock"], parent: host.pid, cwd: "/Users/u", tty: false)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    // 넘겨받은 시각(startedAt) = 프로세스 시작 + 6분 · procStart = 프로세스 시작
    let entry: [String: Any] = ["pid": Int(spare.pid), "sessionId": "beacda38-c76b-4d48-b491-1cc9a889de77", "cwd": "/Users/test/DEV/샘플", "kind": "bg", "status": "idle",
                                "startedAt": Int((fake.started.timeIntervalSince1970 + 360) * 1000), "procStart": formatter.string(from: fake.started)]
    FileManager.default.createFile(atPath: folder + "/\(spare.pid).json", contents: try? JSONSerialization.data(withJSONObject: entry))
    let detector = SessionDetector()
    detector.catalog = AgentCatalog(defaults: nil, initial: AgentCatalog.State())
    detector.claudeRegistry = ClaudeRegistry(directory: folder)
    let result = detector.detect(records: fake.records, sampler: fake, orca: [])
    let bg = result.sessions.first { $0.rootPID == spare.pid }
    check(bg?.role == "백그라운드" && !result.sessions.contains { $0.rootPID == idle.pid },
          "예비를 6분 뒤 넘겨받은 백그라운드 세션 → 세션('\(bg?.role ?? "없음")') · 넘겨받지 않은 예비는 대기 인력")
}

/// Claude 자동 업데이트가 옛 버전 파일을 지운 뒤에도 그 파일로 돌던 세션을 잡는다(10-25: 이름 '2.1.302'·경로 없음/ClaudeCode.app → 세션 7개가 13개였다).
func claudeDeletedBinaryCheck() {
    let fake = FakeProcesses()
    let term = fake.add("zsh", "/bin/zsh", ["-zsh"], cwd: "/Users/test/DEV/샘플")
    let gone = fake.add("2.1.303", nil, ["claude", "--resume", "c6845b2d-4bf5-49ad-9a4b-494547ef4576"], parent: term.pid, cwd: "/Users/test/DEV/샘플")
    let bundled = fake.add("2.1.302", "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", ["claude", "--dangerously-skip-permissions"], parent: term.pid, cwd: "/Users/test/DEV/샘플")
    let python = fake.add("3.12.1", nil, ["python3", "server.py"], parent: term.pid, cwd: "/Users/test/DEV/샘플")
    let detector = SessionDetector()
    detector.catalog = AgentCatalog(defaults: nil, initial: AgentCatalog.State())
    detector.claudeRegistry = ClaudeRegistry(directory: NSTemporaryDirectory() + "remon-empty-registry-\(getpid())")
    let result = detector.detect(records: fake.records, sampler: fake, orca: [])
    check(result.sessions.contains { $0.rootPID == gone.pid && $0.kind == .claudeCode }, "실행 파일이 지워진 Claude(이름 '2.1.303' · 경로 없음) → Claude 세션")
    check(result.sessions.contains { $0.rootPID == bundled.pid && $0.kind == .claudeCode }, "경로가 ~/.local/share/claude/ClaudeCode.app으로 바뀐 Claude → Claude 세션")
    check(!result.sessions.contains { $0.rootPID == python.pid }, "이름이 버전 꼴이어도 실행 인자가 claude가 아니면 세션 아님(python)")
    check(ProcessExplainer.role(pid: gone.pid, name: "2.1.303", path: nil, argv: ["claude", "--resume", "x"]) == .agent("Claude Code"), "프로세스 설명도 같은 규칙(이름 '2.1.303' → Claude Code)")
}

/// 10-25 사고 재현: 대표님이 Orca 탭의 대화형 Claude로 백그라운드 세션을 열어 보면 탭 제목이 백그라운드 세션 이름이 된다.
/// 예전 짝짓기는 '이름 = 제목' 점수로 탭을 백그라운드 세션에 주고, 실제로 탭에서 도는 대화형 창을 'Orca 목록에 없음 → 잔재 → 고아'로 몰았다.
/// 그 창은 자기 대화가 없어 '잃을 것 없음'이 됐고, 자동 메모리 정리가 키 없이 종료했다. 여기서는 그 모양을 그대로 만든다.
func backgroundViewerCheck() {
    let fake = FakeProcesses(started: Date().addingTimeInterval(-7 * 86_400))   // 7일 전에 떠서 조용한 창
    let folder = "/Users/test/DEV/STOREARC"
    let orcaHost = fake.add("Orca Helper", "/Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper", ["Orca Helper"], tty: false)
    let shell = fake.add("zsh", "/bin/zsh", ["-zsh"], parent: orcaHost.pid, cwd: folder)
    let viewer = fake.add("2.1.310", "/Users/u/.local/share/claude/versions/2.1.310", ["claude", "--dangerously-skip-permissions"], parent: shell.pid, cwd: folder)
    let daemon = fake.add("claude", "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", ["claude", "daemon", "run"], parent: orcaHost.pid, cwd: "/Users/u", tty: false)
    let host = fake.add("claude", "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", ["claude", "bg-pty-host", "--bg-pty-host", "/tmp/cc/a.pty.sock"], parent: daemon.pid, cwd: "/Users/u", tty: false)
    let background = fake.add("2.1.302", "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", ["claude bg-spare", "--bg-spare", "/tmp/cc/a.claim.sock"], parent: host.pid, cwd: folder, tty: false)
    // 레지스트리: 백그라운드 세션 이름 = 탭 제목 · 대화형 창은 자동 이름 · 둘 다 대화 기록 파일은 없음(시험 폴더)
    let registryFolder = NSTemporaryDirectory() + "remon-viewer-registry-\(getpid())"
    try? FileManager.default.createDirectory(atPath: registryFolder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: registryFolder) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    func write(_ record: ProcRecord, kind: String, name: String, session: String) {
        let entry: [String: Any] = ["pid": Int(record.pid), "sessionId": session, "cwd": folder, "kind": kind, "status": "idle", "name": name, "nameSource": kind == "bg" ? "user" : "derived",
                                    "startedAt": Int(fake.started.timeIntervalSince1970 * 1000), "procStart": formatter.string(from: fake.started)]
        FileManager.default.createFile(atPath: registryFolder + "/\(record.pid).json", contents: try? JSONSerialization.data(withJSONObject: entry))
    }
    write(background, kind: "bg", name: "DWG 매장 인테리어 CAD", session: "6b5531a1-cd6c-4a2b-b2cc-000000000001")
    write(viewer, kind: "interactive", name: "storearc-61", session: "c0ffee00-0000-4000-8000-000000000002")
    let tab = OrcaTerminal(handle: "term_dwg", title: "DWG 매장 인테리어 CAD", worktreePath: folder, agent: "claude", lastOutputAt: Date(), connected: true)
    let detector = SessionDetector()
    detector.catalog = AgentCatalog(defaults: nil, initial: AgentCatalog.State())
    detector.claudeRegistry = ClaudeRegistry(directory: registryFolder)
    let records = fake.records
    let result = detector.detect(records: records, sampler: fake, orca: [tab])
    let viewerSession = result.sessions.first { $0.rootPID == viewer.pid }
    let backgroundSession = result.sessions.first { $0.rootPID == background.pid }
    check(viewerSession?.orcaHandle == "term_dwg" && viewerSession?.tabState == .open, "탭은 실제로 그 안에서 도는 대화형 창에 붙음(\(viewerSession?.orcaHandle ?? "짝 없음"))")
    check(backgroundSession?.orcaHandle == nil && backgroundSession?.tabLeftover == false && backgroundSession?.tabUnknown == false, "백그라운드 세션은 Orca 탭을 갖지 않고 잔재로도 보지 않음")
    check(viewerSession.map { $0.state != .orphan && !$0.tabLeftover } == true, "대화형 창은 고아·탭 닫힘이 아님(상태 \(viewerSession?.state.label ?? "-") · \(viewerSession?.stateReason ?? "-"))")
    let key = viewerSession.map { ResumeKey.resolve($0, registrySessionID: "c0ffee00-0000-4000-8000-000000000002", argv: ["claude"], claudeProjects: registryFolder) }
    check(key.map { !$0.allowsAutoCleanup } == true, "대화 기록이 없는 창은 '잃을 것 없음'이어도 묶음·자동 정리 금지(\(key?.label ?? "-"))")
    // 짝을 못 찾아도(목록에 없음) 잔재가 아니다
    let lonely = detector.detect(records: records, sampler: fake, orca: [OrcaTerminal(handle: "other", title: "다른 탭", worktreePath: "/Users/test/DEV/다른곳", agent: "claude", lastOutputAt: nil, connected: true)])
    let unmatched = lonely.sessions.first { $0.rootPID == viewer.pid }
    check(unmatched.map { $0.tabUnknown && !$0.tabLeftover && $0.state != .orphan } == true, "Orca 목록에서 짝을 못 찾으면 '못 찾음(추정)'일 뿐 잔재·고아가 아님")
}
