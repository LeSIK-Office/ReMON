import Foundation

/// 에이전트 CLI 서명 한 줄(표 기반 감지). 프로세스 이름·실행 경로·argv로 세션 루트를 찾고,
/// 설치 확인·데이터 폴더·이어 열기 지원을 함께 적는다. 새 에이전트는 줄 하나를 더하면 된다(화면 분기 없음).
public struct AgentSignature: Sendable, Identifiable {
    /// 이어 열기: 확인한 명령 형식만 적는다. 모르면 unknown — 이어 열기 키가 없으므로 복구 시스템이 자동 정리하지 않는다.
    public enum Resume: Sendable, Equatable {
        case known(String)
        case unknown

        public var isKnown: Bool { if case .known = self { true } else { false } }
        public var label: String {
            switch self {
            case .known(let command): command
            case .unknown: "모름"
            }
        }
    }

    public let kind: AgentKind
    public var id: String { kind.rawValue }
    /// 설치·버전 확인에 쓰는 명령 이름(검색 폴더에서 찾는다)
    public let commands: [String]
    /// 자체 실행 파일 이름(p_comm 또는 실행 경로의 끝 이름)
    public let binaryNames: [String]
    /// node·bun·deno·python이 실행하는 스크립트 이름(첫 비옵션 인자의 끝 이름, 확장자 제외) 또는 python -m 모듈 이름
    public let scriptNames: [String]
    /// 실행 경로·스크립트 경로·argv[0]에 이 조각이 있으면 확실한 근거(패키지 이름 등)
    public let markers: [String]
    /// 실행 파일 이름이 흔해(goose·copilot·amp) 이름만으로는 인정하지 않는다 → 표식(링크를 따라간 실제 경로 포함)이나 근거 하위 명령이 있어야 한다.
    public let nameNeedsEvidence: Bool
    /// node 스크립트 이름도 흔하다(amp: 옛 AMP 프로젝트 도구도 bin 이름이 amp) → 링크를 따라간 실제 스크립트 경로에 표식이 있어야 한다.
    public let scriptNeedsEvidence: Bool
    /// 이름만 같을 때 이 하위 명령이 있으면 근거로 본다(예: goose session)
    public let evidenceArguments: [String]
    /// argv에 이 낱말이 따로 있으면 세션이 아니라 보조 프로세스(서버·MCP·워커) — 부모 세션 트리에 속한다.
    public let helperArguments: [String]
    /// argv에 이 낱말이 있으면 다른 프로그램이 잠깐 부르는 일회성 실행(보조 호출)
    public let oneShotArguments: [String]
    /// 데이터 폴더 후보(~ 기준, 처음 찾은 것을 보여 준다)
    public let dataFolders: [String]
    public let resume: Resume
    /// Orca `agentIdentity` 값. 정확히 같을 때만 터미널을 짝짓는다(추측 값이 틀려도 짝이 안 생길 뿐이다).
    public let orcaIdentities: [String]
    /// false면 기본 감지 규칙(Claude·Codex·OpenCode 전용 코드)이 프로세스를 맡고, 표는 설치·폴더·이어 열기만 알려 준다.
    public let detectedByTable: Bool

    init(kind: AgentKind, commands: [String], binaryNames: [String] = [], scriptNames: [String] = [], markers: [String] = [],
         nameNeedsEvidence: Bool = false, scriptNeedsEvidence: Bool = false, evidenceArguments: [String] = [], helperArguments: [String] = [], oneShotArguments: [String] = [],
         dataFolders: [String], resume: Resume = .unknown, orcaIdentities: [String] = [], detectedByTable: Bool = true) {
        self.kind = kind
        self.commands = commands
        self.binaryNames = binaryNames
        self.scriptNames = scriptNames
        self.markers = markers
        self.nameNeedsEvidence = nameNeedsEvidence
        self.scriptNeedsEvidence = scriptNeedsEvidence
        self.evidenceArguments = evidenceArguments
        self.helperArguments = helperArguments
        self.oneShotArguments = oneShotArguments
        self.dataFolders = dataFolders
        self.resume = resume
        self.orcaIdentities = orcaIdentities
        self.detectedByTable = detectedByTable
    }
}

/// 감지 결과: 어떤 종류의 루트인지, 보조 프로세스인지, 역할 이름.
public struct AgentMatch: Sendable, Equatable {
    public var kind: AgentKind
    public var role: String
    /// 세션이 아니라 보조(서버·MCP·워커). 루트가 되지 않고 부모 세션 트리에 남는다.
    public var helper: Bool
}

/// 사용자가 설정에서 직접 추가한 에이전트. 이름 + 프로세스 이름 그리고/또는 경로 조각으로 찾는다. 이어 열기 키는 없다.
public struct CustomAgent: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var name: String
    /// 정확히 같은 프로세스 이름(실행 파일 이름 또는 node·python 스크립트 이름). 비우면 보지 않는다.
    public var processName: String
    /// 실행 경로·스크립트 경로에 들어 있는 조각. 비우면 보지 않는다. 둘 다 넣으면 둘 다 맞아야 한다.
    public var pathPattern: String

    public init(id: String = AgentKind.customPrefix + UUID().uuidString.prefix(8).lowercased(), name: String, processName: String, pathPattern: String) {
        self.id = id.hasPrefix(AgentKind.customPrefix) ? id : AgentKind.customPrefix + id
        self.name = name.trimmingCharacters(in: .whitespaces)
        self.processName = processName.trimmingCharacters(in: .whitespaces)
        self.pathPattern = pathPattern.trimmingCharacters(in: .whitespaces)
    }

    public var kind: AgentKind { AgentKind.custom(id: id, name: name) }

    /// 너무 넓어 모든 프로세스를 잡는 정의를 막는다(nil이면 저장해도 된다).
    public var validationError: String? {
        if name.isEmpty { return "이름을 넣어야 합니다" }
        if processName.isEmpty && pathPattern.isEmpty { return "프로세스 이름이나 경로 조각 중 하나는 넣어야 합니다" }
        if !processName.isEmpty && processName.count < 2 { return "프로세스 이름이 너무 짧습니다" }
        if ["zsh", "bash", "sh", "fish", "login", "tmux", "screen", "ssh", "sshd", "launchd", "git"].contains(processName) { return "셸·터미널 프로세스는 에이전트로 지정할 수 없습니다" }
        if AgentSignatures.isInterpreter(processName) && pathPattern.isEmpty { return "node·python 같은 실행기는 경로 조각도 함께 넣어야 합니다" }
        if !pathPattern.isEmpty {
            if pathPattern.count < 3 { return "경로 조각은 세 글자 이상이어야 합니다" }
            // 홈·시스템 폴더처럼 거의 모든 프로세스에 들어 있는 조각은 막는다.
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let trimmed = pathPattern.hasSuffix("/") ? String(pathPattern.dropLast()) : pathPattern
            let broad = ["/Users", "/opt", "/opt/homebrew", "/opt/homebrew/bin", "/usr", "/usr/local", "/usr/local/bin", "/usr/bin", "/bin",
                         "/Applications", "/System", "/Library", home, home + "/.local", home + "/.local/bin"]
            if broad.contains(trimmed) { return "경로 조각이 너무 넓습니다. 에이전트만의 폴더 이름을 넣어 주세요" }
        }
        return nil
    }
}

public enum AgentSignatures {
    static func kind(_ id: String, _ name: String, _ short: String, _ color: UInt32) -> AgentKind {
        AgentKind(id: id, name: name, shortName: short, color: color)
    }

    /// 전용 규칙으로 감지하는 기본 에이전트 — 표에는 설치·데이터 폴더·이어 열기 정보만 둔다.
    public static let builtIn: [AgentSignature] = [
        AgentSignature(kind: .claudeCode, commands: ["claude"], dataFolders: ["~/.claude"], resume: .known("claude --resume <id>"), orcaIdentities: ["claude"], detectedByTable: false),
        AgentSignature(kind: .codexCLI, commands: ["codex"], dataFolders: ["~/.codex"], resume: .known("codex resume <id>"), orcaIdentities: ["codex"], detectedByTable: false),
        // 10-25 이 Mac에서 `opencode --help`로 확인: "--session, -s string  Session ID to continue"(nvm @opencode/cli · Homebrew 2.1.0 둘 다).
        AgentSignature(kind: .opencode, commands: ["opencode"], dataFolders: ["~/.local/share/opencode", "~/.config/opencode"], resume: .known("opencode --session <id>"),
                       orcaIdentities: ["opencode"], detectedByTable: false),
    ]

    /// 표로 감지하는 에이전트. 이어 열기는 모두 '모름'(이 Mac에서 확인한 형식이 없다).
    /// 실행 모양은 10-25 이 Mac의 실제 설치(gemini: nvm 0.36 · Homebrew 0.46, cursor-agent 2026.10.01)와 각 프로젝트의 배포 형태를 따른다.
    public static let generic: [AgentSignature] = [
        // node 스크립트(npm·Homebrew). 메모리 한도를 올리려 자기 자신을 자식으로 다시 띄운다 → 자식은 같은 종류라 부모 트리에 묶인다.
        AgentSignature(kind: kind("gemini", "Gemini CLI", "Gemini", 0x4C8DF6), commands: ["gemini"], scriptNames: ["gemini"], markers: ["@google/gemini-cli"],
                       helperArguments: ["mcp", "extensions"], oneShotArguments: ["-p", "--prompt"], dataFolders: ["~/.gemini"], orcaIdentities: ["gemini"]),
        // 번들 node(versions/<버전>/node)가 index.js를 실행한다. rg·spawn-helper·워커는 같은 폴더에 있지만 이름이 달라 루트가 되지 않는다.
        // Cursor 앱이 띄우는 백그라운드 워커(… worker start, 부모 launchd)는 세션이 아니다.
        AgentSignature(kind: kind("cursorAgent", "Cursor Agent", "Cursor CLI", 0x6C7FE0), commands: ["cursor-agent"], binaryNames: ["cursor-agent", "cursor-agent-sea"],
                       markers: ["/cursor-agent/versions/"], helperArguments: ["worker", "mcp"], oneShotArguments: ["-p", "--print"],
                       dataFolders: ["~/.cursor/chats", "~/.cursor/cli-config.json"], orcaIdentities: ["cursor-agent", "cursor"]),
        // 같은 이름의 AWS Copilot CLI(Go 바이너리)가 있어 자체 실행 파일은 표식이 있어야 인정한다.
        AgentSignature(kind: kind("copilot", "GitHub Copilot CLI", "Copilot", 0x8B6FD0), commands: ["copilot"], binaryNames: ["copilot"], scriptNames: ["copilot"],
                       markers: ["@github/copilot"], nameNeedsEvidence: true, oneShotArguments: ["-p", "--prompt"], dataFolders: ["~/.copilot"], orcaIdentities: ["copilot"]),
        // python 스크립트(pipx·uv tool·Homebrew). `python -m aider`도 본다.
        AgentSignature(kind: kind("aider", "Aider", "Aider", 0x3BAF6A), commands: ["aider"], scriptNames: ["aider"], markers: ["aider-chat"],
                       oneShotArguments: ["-m", "--message", "--message-file"], dataFolders: ["~/.aider"], orcaIdentities: ["aider"]),
        AgentSignature(kind: kind("amp", "Amp", "Amp", 0xE0575B), commands: ["amp"], binaryNames: ["amp"], scriptNames: ["amp"], markers: ["@sourcegraph/amp", "/.amp/"],
                       nameNeedsEvidence: true, scriptNeedsEvidence: true, oneShotArguments: ["-x", "--execute"], dataFolders: ["~/.config/amp", "~/.local/share/amp"], orcaIdentities: ["amp"]),
        // 같은 이름의 DB 마이그레이션 도구(pressly/goose)가 있어 설치 경로 표식이나 goose 고유 하위 명령이 있어야 한다. `goose mcp …`는 보조.
        AgentSignature(kind: kind("goose", "Goose", "Goose", 0x7A8A99), commands: ["goose"], binaryNames: ["goose"], markers: ["block-goose", "/.local/bin/goose"],
                       nameNeedsEvidence: true, evidenceArguments: ["session", "s", "run", "web"], helperArguments: ["mcp"], oneShotArguments: ["run"],
                       dataFolders: ["~/.config/goose", "~/.local/share/goose"], orcaIdentities: ["goose"]),
        AgentSignature(kind: kind("crush", "Crush", "Crush", 0xC86BC0), commands: ["crush"], binaryNames: ["crush"], scriptNames: ["crush"], markers: ["@charmland/crush", "charmbracelet"],
                       oneShotArguments: ["run"], dataFolders: ["~/.config/crush", "~/.local/share/crush"], orcaIdentities: ["crush"]),
        // Gemini CLI 갈래라 실행 모양이 같다.
        AgentSignature(kind: kind("qwen", "Qwen Code", "Qwen", 0x7B5CE6), commands: ["qwen"], scriptNames: ["qwen"], markers: ["@qwen-code/qwen-code"],
                       helperArguments: ["mcp", "extensions"], oneShotArguments: ["-p", "--prompt"], dataFolders: ["~/.qwen"], orcaIdentities: ["qwen"]),
        AgentSignature(kind: kind("droid", "Factory Droid", "Droid", 0xF08A3C), commands: ["droid"], binaryNames: ["droid"], scriptNames: ["droid"], markers: ["@factory/cli"],
                       oneShotArguments: ["exec"], dataFolders: ["~/.factory"], orcaIdentities: ["droid"]),
        AgentSignature(kind: kind("kimi", "Kimi CLI", "Kimi", 0x3D7EFF), commands: ["kimi"], binaryNames: ["kimi"], scriptNames: ["kimi"], markers: ["kimi-cli"],
                       dataFolders: ["~/.kimi"], orcaIdentities: ["kimi"]),
    ]

    public static var all: [AgentSignature] { builtIn + generic }
    private static let byID: [String: AgentSignature] = Dictionary((builtIn + generic).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    public static func signature(for kind: AgentKind) -> AgentSignature? { byID[kind.rawValue] }

    /// 이어 열기 지원(표 기준). 직접 추가·표에 없는 종류는 모름.
    public static func resume(for kind: AgentKind) -> AgentSignature.Resume { byID[kind.rawValue]?.resume ?? .unknown }

    /// 에디터가 띄운 에이전트 세션(Agent Client Protocol) 역할 이름.
    public static let editorRole = "에디터 연결(ACP)"

    // MARK: - 실행 모양

    static func isInterpreter(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["node", "nodejs", "bun", "deno"].contains(lower) || lower.hasPrefix("python") || lower.hasPrefix("pypy")
    }

    /// 실행 파일 이름 · (실행기일 때) 스크립트와 모듈 · 그 뒤 인자.
    struct Launch {
        var executable: String
        var interpreter: Bool
        var script: String?
        var module: String?
        var rest: [String]
        var argv0: String

        init(name: String, path: String?, argv: [String]) {
            let tail = (path.map { ($0 as NSString).lastPathComponent }).flatMap { $0.isEmpty ? nil : $0 } ?? name
            executable = tail
            interpreter = AgentSignatures.isInterpreter(tail) || AgentSignatures.isInterpreter(name)
            argv0 = argv.first ?? ""
            script = nil
            module = nil
            rest = Array(argv.dropFirst())
            guard interpreter else { return }
            // node·python 옵션(-로 시작)을 건너뛴 첫 인자가 스크립트. python -m은 다음 인자가 모듈.
            var index = 1
            while index < argv.count {
                let argument = argv[index]
                if argument == "-m", index + 1 < argv.count {
                    module = argv[index + 1]
                    rest = Array(argv.dropFirst(index + 2))
                    return
                }
                if argument.hasPrefix("-") { index += 1; continue }
                script = argument
                rest = Array(argv.dropFirst(index + 1))
                return
            }
            rest = []
        }

        /// 스크립트의 끝 이름(확장자 제외)
        var scriptName: String? {
            guard let script else { return module }
            let last = (script as NSString).lastPathComponent
            for suffix in [".js", ".mjs", ".cjs", ".ts", ".py"] where last.hasSuffix(suffix) { return String(last.dropLast(suffix.count)) }
            return last
        }
    }

    private static func contains(_ markers: [String], in texts: [String]) -> Bool {
        markers.contains { marker in texts.contains { $0.contains(marker) } }
    }

    /// 링크를 따라간 실제 스크립트 경로(npm 전역 설치는 bin/amp → lib/node_modules/@sourcegraph/amp/…).
    private static func resolved(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        let real = (path as NSString).resolvingSymlinksInPath
        return real == path ? nil : real
    }

    // MARK: - 판정

    /// 프로세스 하나가 어떤 에이전트의 루트(또는 보조)인지. 기본 감지 대상(Claude·Codex·OpenCode)은 여기서 보지 않는다.
    /// - 직접 추가한 정의를 먼저, 그다음 표를 본다. 꺼 둔 종류(disabled)는 고르지 않는다.
    /// - 버전·도움말 확인(--version · --help)은 세션이 아니다(ReMON 자신의 버전 확인 포함).
    public static func match(name: String, path: String?, argv: [String], custom: [CustomAgent] = [], disabled: Set<String> = []) -> AgentMatch? {
        let launch = Launch(name: name, path: path, argv: argv)
        if launch.rest.contains("--version") || launch.rest.contains("--help") { return nil }
        for agent in custom where !disabled.contains(agent.id) && agent.validationError == nil {
            if matches(agent, launch: launch, name: name, path: path) {
                return AgentMatch(kind: agent.kind, role: "대화형", helper: false)
            }
        }
        for signature in generic where !disabled.contains(signature.id) {
            guard evidence(signature, launch: launch, name: name, path: path) else { continue }
            if signature.helperArguments.contains(where: launch.rest.contains) {
                return AgentMatch(kind: signature.kind, role: "보조", helper: true)
            }
            let role: String
            if signature.oneShotArguments.contains(where: launch.rest.contains) {
                role = SessionDetector.helperRole
            } else if launch.rest.contains("--experimental-acp") || launch.rest.contains("--acp") || launch.rest.first == "acp" {
                role = editorRole
            } else {
                role = "대화형"
            }
            return AgentMatch(kind: signature.kind, role: role, helper: false)
        }
        return nil
    }

    static func evidence(_ signature: AgentSignature, launch: Launch, name: String, path: String?) -> Bool {
        let places = [path ?? "", launch.script ?? "", launch.argv0]
        if launch.interpreter {
            let named = launch.scriptName.map(signature.scriptNames.contains) ?? false
            if contains(signature.markers, in: places) { return true }
            guard named else { return false }
            guard signature.scriptNeedsEvidence else { return true }
            // 스크립트 이름이 흔한 서명: 링크를 따라간 실제 스크립트 경로에 표식이 있어야 한다.
            return resolved(launch.script).map { contains(signature.markers, in: [$0]) } ?? false
        }
        guard signature.binaryNames.contains(launch.executable) || signature.binaryNames.contains(name) else { return false }
        guard signature.nameNeedsEvidence else { return true }
        if contains(signature.markers, in: places) { return true }
        if let real = resolved(path), contains(signature.markers, in: [real]) { return true }
        // 근거 하위 명령: 옵션을 건너뛴 첫 인자만 본다(옵션 값과 헷갈리지 않게).
        let subcommand = launch.rest.first { !$0.hasPrefix("-") }
        return subcommand.map(signature.evidenceArguments.contains) ?? false
    }

    static func matches(_ agent: CustomAgent, launch: Launch, name: String, path: String?) -> Bool {
        if !agent.processName.isEmpty {
            let names = [launch.executable, name] + (launch.interpreter ? [launch.scriptName ?? ""] : [])
            guard names.contains(agent.processName) else { return false }
        }
        if !agent.pathPattern.isEmpty {
            guard [path ?? "", launch.script ?? "", launch.argv0].contains(where: { $0.contains(agent.pathPattern) }) else { return false }
        }
        return true
    }

    /// 일회성 실행의 프롬프트(-p "…" 등) — 제목으로 쓴다. 대화형이면 nil.
    public static func promptArgument(argv: [String], kind: AgentKind) -> String? {
        guard let signature = signature(for: kind), !signature.oneShotArguments.isEmpty else { return nil }
        for (index, argument) in argv.enumerated() where signature.oneShotArguments.contains(argument) && index + 1 < argv.count {
            let value = argv[index + 1]
            if !value.hasPrefix("-") { return value }
        }
        return nil
    }
}

/// 에이전트 켜기·끄기와 직접 추가한 에이전트(UserDefaults). 감지기(모니터 큐)와 설정 화면(메인)이 함께 써서 잠금으로 보호한다.
public final class AgentCatalog: @unchecked Sendable {
    public static let shared = AgentCatalog(defaults: .standard)
    /// 설정이 바뀌면 메인 스레드에서 보낸다(화면 갱신용).
    public static let didChange = Notification.Name("ReMONAgentCatalogDidChange")

    public struct State: Sendable, Equatable {
        public var disabled: Set<String> = []
        public var custom: [CustomAgent] = []
        public func isEnabled(_ id: String) -> Bool { !disabled.contains(id) }
        public init(disabled: Set<String> = [], custom: [CustomAgent] = []) {
            self.disabled = disabled
            self.custom = custom
        }
    }

    private static let disabledKey = "agents.disabled"
    private static let customKey = "agents.custom"
    private let lock = NSLock()
    private var state: State
    private let defaults: UserDefaults?

    /// defaults가 nil이면 메모리에만 둔다(시험용).
    public init(defaults: UserDefaults?, initial: State = State()) {
        self.defaults = defaults
        var loaded = initial
        if let defaults {
            loaded.disabled = Set(defaults.stringArray(forKey: Self.disabledKey) ?? [])
            if let data = defaults.data(forKey: Self.customKey), let agents = try? JSONDecoder().decode([CustomAgent].self, from: data) { loaded.custom = agents }
        }
        state = loaded
    }

    public var current: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func isEnabled(_ kind: AgentKind) -> Bool { current.isEnabled(kind.rawValue) }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        update { if enabled { $0.disabled.remove(id) } else { $0.disabled.insert(id) } }
    }

    /// 같은 id면 고치고, 없으면 더한다. 잘못된 정의는 저장하지 않는다.
    @discardableResult
    public func upsert(_ agent: CustomAgent) -> String? {
        if let error = agent.validationError { return error }
        update { state in
            if let index = state.custom.firstIndex(where: { $0.id == agent.id }) { state.custom[index] = agent } else { state.custom.append(agent) }
        }
        return nil
    }

    public func removeCustom(id: String) {
        update { $0.custom.removeAll { $0.id == id }; $0.disabled.remove(id) }
    }

    private func update(_ change: (inout State) -> Void) {
        lock.lock()
        change(&state)
        let snapshot = state
        lock.unlock()
        if let defaults {
            defaults.set(Array(snapshot.disabled).sorted(), forKey: Self.disabledKey)
            defaults.set(try? JSONEncoder().encode(snapshot.custom), forKey: Self.customKey)
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }
}
