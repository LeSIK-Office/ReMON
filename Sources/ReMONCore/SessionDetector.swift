import Darwin
import Foundation

/// 상태 판정 기본값(사양 4장). 설정에서 조정한다.
public struct DetectionSettings: Sendable, Codable, Equatable {
    public var workingWindow: TimeInterval = 120
    public var waitingLimit: TimeInterval = 3600
    public var idleLimit: TimeInterval = 86_400
    public var workingCPU: Double = 5
    public var orphanSilence: TimeInterval = 6 * 3600

    public init() {}
}

/// 프로세스 목록에서 AI 세션(루트 + 하위 트리)과 앱 묶음을 만든다.
public final class SessionDetector {
    public let logReader = SessionLogReader()
    private let subagentScanner = SubagentScanner()
    /// 시험은 임시 폴더의 레지스트리를 넣는다.
    public var claudeRegistry = ClaudeRegistry()
    public var settings = DetectionSettings()
    /// 에이전트 켜기·끄기와 직접 추가한 에이전트(설정 화면이 바꾼다). 시험은 메모리 카탈로그를 넣는다.
    public var catalog: AgentCatalog = .shared
    /// 이 pid의 자손은 세션으로 보지 않는다 — 앱이 직접 띄운 일꾼(감사 판정 `claude -p` 등). 10-25: 감사 중에 판정 프로세스가
    /// 세션으로 잡혀 '감사실' 방·직원이 생겼다. 앱은 자기 pid를 넣고, 더미 에이전트를 자식으로 띄우는 시험은 비워 둔다.
    public var excludedAncestor: Int32?
    /// 이번 감지에서 쓴 레지스트리(pid → 항목). 시작 시각이 프로세스와 맞는 것만.
    private var registry: [Int32: ClaudeRegistryEntry] = [:]
    /// 기록을 모르는 에이전트(표·직접 추가)의 마지막 CPU 활동 시각 — 상태 판정의 추정 근거.
    private var cpuActivity: [ProcessKey: Date] = [:]
    /// 이번 감지의 프로세스 정보 출처(열린 파일 읽기용). 감지가 끝나면 놓는다.
    private weak var detailSource: ProcessDetailSource?
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let selfUID = getuid()

    public init() {}

    /// Claude Code 프로세스인가. 자동 업데이트가 실행 중인 옛 버전 파일(~/.local/share/claude/versions/2.1.30x)을 지우면
    /// proc_pidpath가 비거나 같은 파일의 다른 이름(…/ClaudeCode.app/Contents/MacOS/claude)을 돌려주고, 프로세스 이름은 버전 번호('2.1.302')만 남는다.
    /// 10-25: 이렇게 백그라운드 2개·대화형 1개가 사무실에서 사라졌다 → ~/.local/share/claude/ 아래면 Claude, 경로가 비었거나 이름이 버전 번호면
    /// 실행 인자 첫 칸('claude' · '…/claude' · 'claude bg-spare')으로 본다(Codex의 argv[0] 대체 판별과 같은 이유).
    static func isClaude(_ record: ProcRecord, path: String, sampler: ProcessDetailSource) -> Bool {
        if record.name == "claude" || path.hasSuffix("/.local/bin/claude") || path.contains("/.local/share/claude/") { return true }
        guard path.isEmpty || record.name.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return false }
        guard let first = sampler.arguments(for: record.key)?.argv.first else { return false }
        return first == "claude" || first.hasSuffix("/claude") || first.hasPrefix("claude ")
    }

    public struct Result: Sendable {
        public var sessions: [AgentSession]
        public var apps: [AppGroup]
        public var standbySpares: Int
    }

    private enum RootRole {
        case claude(String)
        case codex(String)
        case opencode(String)
        /// 서명 표·직접 추가한 에이전트(종류, 역할)
        case generic(AgentKind, String)

        var kind: AgentKind {
            switch self {
            case .claude: .claudeCode
            case .codex: .codexCLI
            case .opencode: .opencode
            case .generic(let kind, _): kind
            }
        }
    }

    /// 기록 없이 CPU로만 '활동'을 추정하는 기준(하위 합계 %). 쉬는 TUI는 거의 0이다.
    static let activityCPU = 1.0

    public func detect(records: [ProcRecord], sampler: ProcessDetailSource, orca: [OrcaTerminal], now: Date = Date()) -> Result {
        let options = catalog.current
        detailSource = sampler
        defer { detailSource = nil }
        var byPID: [Int32: ProcRecord] = [:]
        var children: [Int32: [Int32]] = [:]
        for record in records {
            byPID[record.pid] = record
            children[record.ppid, default: []].append(record.pid)
        }

        // 0. Claude 레지스트리: pid 재사용을 막는다. 프로세스 시작 시각(procStart)이 적혀 있으면 그것과 2초 안,
        //    없으면(옛 버전) 등록 시각이 60초 안일 때만 쓴다. 백그라운드 세션은 예비 프로세스를 몇 분 뒤 넘겨받아 등록 시각이 크게 늦다
        //    (10-25: 예비를 넘겨받은 백그라운드 세션이 '대기 인력'으로 숨어 정리·복구 대상에서 빠졌다).
        registry = claudeRegistry.load().filter { pid, entry in
            guard let record = byPID[pid] else { return false }
            if let procStart = entry.procStart { return abs(procStart.timeIntervalSince(record.startTime)) < 2 }
            guard let started = entry.startedAt else { return true }
            return abs(started.timeIntervalSince(record.startTime)) < 60
        }

        // Codex 공급 프로세스 판별. CLI가 디스크에서 업데이트되면 실행 중인 옛 바이너리 파일이 사라져
        // proc_pidpath가 빈 값을 돌려준다(10-24 실측: Codex 10개 중 8개) → argv[0]의 실행 경로로 대신 본다.
        // npm(@openai/codex) 말고도 Homebrew(Caskroom·Cellar)와 Codex 자체 설치(~/.codex/packages/)를 본다 — 다른 Mac의 설치 방식.
        func isCodexVendor(_ record: ProcRecord) -> Bool {
            let path = record.path ?? ""
            let file = (path as NSString).lastPathComponent
            guard record.name == "codex" || file == "codex" || file.hasPrefix("codex-aarch64") || file.hasPrefix("codex-x86_64") else { return false }
            if path.contains("/@openai/codex") || path.contains("/.codex/packages/") || path.contains("/Caskroom/codex/") || path.contains("/Cellar/codex/") { return true }
            guard path.isEmpty, let first = sampler.arguments(for: record.key)?.argv.first else { return false }
            return first.contains("/@openai/codex")
        }

        // 표·직접 추가 에이전트 판정. 앱 번들 안 프로세스(python 프레임워크 제외)는 앱 묶음이 맡는다.
        // node·python은 argv를 봐야 알 수 있어 이름·경로로 먼저 거른다(argv는 프로세스마다 한 번만 읽고 캐시된다).
        let customNames = Set(options.custom.map(\.processName).filter { !$0.isEmpty })
        let customPaths = options.custom.map(\.pathPattern).filter { !$0.isEmpty }
        func genericMatch(_ record: ProcRecord) -> AgentMatch? {
            let path = record.path ?? ""
            if path.contains(".app/") && !path.contains("/Python.app/") { return nil }
            let file = (path as NSString).lastPathComponent
            let candidate = AgentSignatures.isInterpreter(record.name) || AgentSignatures.isInterpreter(file)
                || Self.tableBinaryNames.contains(record.name) || Self.tableBinaryNames.contains(file)
                || customNames.contains(record.name) || customNames.contains(file) || customPaths.contains(where: path.contains)
            guard candidate else { return nil }
            let argv = sampler.arguments(for: record.key)?.argv ?? [record.name]
            return AgentSignatures.match(name: record.name, path: record.path, argv: argv, custom: options.custom, disabled: options.disabled)
        }

        // 1. 루트 후보 분류
        var roots: [Int32: RootRole] = [:]
        var claudeInfra = Set<Int32>()
        var spares: [Int32] = []
        var codexVendors: [Int32] = []
        /// Codex 기반 시설(app-server·exec-server·mcp-server·공유 데몬): 세션이 아니라 도구로 묶는다.
        var codexInfra = Set<Int32>()
        /// 그중 공유 데몬(app-server-daemon · --listen unix://) — 데몬 모드 클라이언트의 rollout을 쥐고 있다.
        var codexDaemons: [Int32] = []
        for record in records where record.uid == selfUID {
            let path = record.path ?? ""
            if path.contains("/ChatGPT.app/") || path.contains("/Codex.app/") { continue } // Codex Desktop 내장 CLI(CodexCLI.app app-server 포함)는 앱으로 묶는다
            if record.name == "codex" || (path as NSString).lastPathComponent == "codex", path.contains("/.codex/packages/app-server-daemon/") {
                // Codex 0.163+ 공유 데몬(`codex app-server --listen unix://…`)과 그 `app-server daemon pid-update-loop`. 부모가 launchd라도 잔재가 아니다.
                codexInfra.insert(record.pid)
                if !(sampler.arguments(for: record.key)?.argv.contains("pid-update-loop") ?? false) { codexDaemons.append(record.pid) }
                continue
            }
            if Self.isClaude(record, path: path, sampler: sampler) {
                guard options.isEnabled(AgentKind.claudeCode.rawValue) else { continue }   // 설정에서 끈 종류는 세션으로 보지 않는다
                let argv = sampler.arguments(for: record.key)?.argv ?? []
                if argv.contains("--version") { continue }   // 버전 확인(설정 화면의 확인 포함)은 세션이 아니다
                if argv.contains("bg-pty-host") || argv.contains("--bg-pty-host") || (argv.contains("daemon") && argv.contains("run")) {
                    claudeInfra.insert(record.pid)
                } else if argv.contains("bg-spare") || argv.contains("--bg-spare") {
                    spares.append(record.pid)
                } else if argv.contains("-p") || argv.contains("--print") {
                    roots[record.pid] = .claude(Self.helperRole)   // 다른 프로그램이 잠깐 부르는 헤드리스 실행
                } else {
                    roots[record.pid] = .claude(argv.contains("--resume") || argv.contains("-r") ? "이어 열기" : "대화형")
                }
            } else if isCodexVendor(record) {
                if options.isEnabled(AgentKind.codexCLI.rawValue) { codexVendors.append(record.pid) }
            } else if record.name == "opencode" || record.name == "opencode.exe" || path.contains("/@opencode/") {
                guard options.isEnabled(AgentKind.opencode.rawValue) else { continue }
                let argv = sampler.arguments(for: record.key)?.argv ?? []
                if !argv.contains("serve") && !argv.contains("--version") { roots[record.pid] = .opencode(argv.contains("run") ? "일회성" : "대화형") }
            } else if let match = genericMatch(record) {
                // 보조(서버·MCP·워커)는 루트가 아니다 → 부모 세션 트리에 남거나, 부모가 없으면 기타 프로세스로 묶인다.
                if !match.helper { roots[record.pid] = .generic(match.kind, match.role) }
            }
        }
        for vendor in codexVendors {
            guard let record = byPID[vendor] else { continue }
            let argv = sampler.arguments(for: record.key)?.argv ?? []
            if argv.contains("--version") { continue }
            let role = Self.codexRole(argv)
            var wrapper: ProcRecord?
            if let parent = byPID[record.ppid], parent.name == "node",
               let parentArgv = sampler.arguments(for: parent.key)?.argv, parentArgv.count > 1, parentArgv[1].hasSuffix("/bin/codex") {
                wrapper = parent
            }
            // app-server·exec-server·mcp-server는 에이전트 세션이 아니라 기반 시설이다(node 래퍼·공급 바이너리 모두). 세션 트리 안에서 뜬 것은 그 세션에 남는다.
            if Self.isCodexServer(argv) {
                codexInfra.insert(vendor)
                if let wrapper { codexInfra.insert(wrapper.pid) }
                if argv.contains(where: { $0.hasPrefix("unix://") }) { codexDaemons.append(vendor) }
                continue
            }
            roots[wrapper?.pid ?? vendor] = .codex(role)
        }

        // 다른 Claude 세션 아래에서 뜬 claude(보조 호출 등)는 독립 세션이 아니라 그 세션의 일부로 본다.
        // 표·직접 추가 에이전트도 같은 종류 아래에서 뜬 것(메모리 한도를 올려 다시 띄운 자식 등)은 부모 세션의 일부다.
        for (pid, role) in roots {
            let kind = role.kind
            guard kind == .claudeCode || kind.isGeneric else { continue }
            var ancestor = byPID[pid].flatMap { byPID[$0.ppid] }
            var depth = 0
            while let item = ancestor, item.pid > 1, depth < 32 {
                if roots[item.pid]?.kind == kind { roots[pid] = nil; break }
                ancestor = byPID[item.ppid]
                depth += 1
            }
        }

        // bg-spare: 기록이 연결되면 백그라운드 세션, 아니면 대기 인력
        var standby = 0
        var spareSessionPIDs = Set<Int32>()
        for spare in spares {
            guard let record = byPID[spare] else { continue }
            // 레지스트리에 kind가 있고 예비(spare)가 아니면 실제 백그라운드 세션, 없으면 대기 인력(REA §3).
            if let entry = registry[spare], entry.kind != nil, !entry.spare {
                roots[spare] = .claude("백그라운드")
                spareSessionPIDs.insert(spare)
            } else if registry[spare] == nil, let cwd = sampler.workingDirectory(for: record.key, now: now), cwd != "/", claudeProjectDirectories(for: cwd).isEmpty == false, claudeRegistry.load().isEmpty {
                roots[spare] = .claude("백그라운드")   // 레지스트리를 못 읽는 버전: 예전 추정 규칙
                spareSessionPIDs.insert(spare)
            } else {
                standby += 1
            }
        }

        // 1-1. 앱 자신이 띄운 일꾼은 세션이 아니다(부모를 거슬러 올라가 excludedAncestor를 만나면 뺀다).
        if let ancestor = excludedAncestor {
            func descends(_ pid: Int32) -> Bool {
                var current = byPID[pid]?.ppid ?? 0
                var hops = 0
                while current > 1, hops < 64 {
                    if current == ancestor { return true }
                    current = byPID[current]?.ppid ?? 0
                    hops += 1
                }
                return false
            }
            roots = roots.filter { !descends($0.key) }
        }

        // 2. 하위 트리(다른 세션 루트에서 멈춤)
        var assigned = Set<Int32>()
        func subtree(of root: Int32) -> (pids: [Int32], nested: [Int32]) {
            var stack = [root]
            var pids: [Int32] = []
            var nested: [Int32] = []
            while let pid = stack.popLast() {
                pids.append(pid)
                for child in children[pid] ?? [] where child != pid {
                    if roots[child] != nil { nested.append(child); continue }
                    stack.append(child)
                }
            }
            return (pids, nested)
        }

        var sessions: [AgentSession] = []
        var nestedParent: [Int32: Int32] = [:]
        var claudeByDirectory: [String: [Int]] = [:]
        /// 세션을 띄운 터미널 앱 번들 — 앱 묶음에서 '터미널 호스트'로 보호한다(Orca와 같은 대우).
        var hostBundles = Set<String>()
        /// rollout을 쥐지 않은 Codex 공유 데몬 클라이언트(세션 인덱스)
        var codexDaemonClients: [Int] = []
        for (rootPID, role) in roots {
            guard let root = byPID[rootPID] else { continue }
            let tree = subtree(of: rootPID)
            for child in tree.nested { nestedParent[child] = rootPID }
            assigned.formUnion(tree.pids)
            let members = tree.pids.compactMap { byPID[$0] }
            let footprint = members.reduce(UInt64(0)) { $0 + $1.footprint }
            let cpu = members.reduce(0.0) { $0 + $1.cpuPercent }
            let argv = sampler.arguments(for: root.key)?.argv ?? []
            var session: AgentSession
            switch role {
            case .claude(let roleName):
                let cwd = registry[rootPID]?.cwd ?? sampler.workingDirectory(for: root.key, now: now)
                session = makeSession(root: root, kind: .claudeCode, role: roleName, pids: tree.pids, footprint: footprint, cpu: cpu, cwd: cwd, argv: argv)
                if let cwd { claudeByDirectory[cwd, default: []].append(sessions.count) }
            case .opencode(let roleName):
                let cwd = sampler.workingDirectory(for: root.key, now: now)
                session = makeSession(root: root, kind: .opencode, role: roleName, pids: tree.pids, footprint: footprint, cpu: cpu, cwd: cwd, argv: argv)
            case .codex(let roleName):
                let vendor = members.first(where: isCodexVendor) ?? root
                let cwd = Self.flagValue(argv, "-C") ?? Self.flagValue(argv, "--cd") ?? sampler.workingDirectory(for: vendor.key, now: now)
                session = makeSession(root: root, kind: .codexCLI, role: roleName, pids: tree.pids, footprint: footprint, cpu: cpu, cwd: cwd, argv: argv)
                // 한 프로세스가 주 스레드와 하위 에이전트 스레드 rollout을 함께 연다(실측: 주 1 + 하위 3).
                let rollouts = Array(Set(openFiles(for: vendor, now: now).filter { $0.contains("/.codex/") && $0.hasSuffix(".jsonl") && ($0.contains("/sessions/") || $0.contains("/archived_sessions/")) }))
                if !rollouts.isEmpty {
                    let resumeID = Self.flagValue(argv, "resume")
                    let main = rollouts.first { path in resumeID.map { path.hasSuffix($0 + ".jsonl") } ?? false } ?? Self.earliestCreated(rollouts)
                    session.logPath = main
                    session.logLinkIsEstimate = false
                    session.extraLogPaths = rollouts.filter { $0 != main }
                    if rollouts.count > 1 { session.role += " · 하위 에이전트 \(rollouts.count - 1)명" }
                } else if !(sampler.arguments(for: vendor.key)?.argv ?? argv).contains("--no-daemon") {
                    // Codex 0.163+ 공유 데몬 모드: TUI 클라이언트는 rollout을 쥐지 않는다(데몬이 쥔다, 10-25 실측). 세션으로 두되
                    // 기록 연결·이어 열기 키는 추정으로 표시한다(아래 3b에서 데몬이 연 최상위 rollout을 폴더·최근성으로 맞춘다).
                    session.codexDaemonClient = true
                    session.role += " · 공유 데몬"
                    codexDaemonClients.append(sessions.count)
                }
            case .generic(let kind, let roleName):
                // 기록 형식을 모르는 에이전트: 기록 연결·이어 열기 키가 없다(resumeCommand는 늘 nil). 일회성 실행은 프롬프트를 제목으로.
                let cwd = sampler.workingDirectory(for: root.key, now: now)
                session = makeSession(root: root, kind: kind, role: roleName, pids: tree.pids, footprint: footprint, cpu: cpu, cwd: cwd, argv: argv)
                if let prompt = AgentSignatures.promptArgument(argv: argv, kind: kind), let headline = Redactor.headline(prompt) {
                    session.title = headline
                    session.titleSource = "실행 인자(일회성 프롬프트)"
                }
            }
            session.launchArgv = argv
            session.registrySessionID = registry[rootPID]?.sessionId
            session.registryKind = registry[rootPID]?.kind
            let host = terminalHost(for: root, byPID: byPID)
            session.terminalHost = host?.name
            if let bundle = host?.bundle { hostBundles.insert(bundle) }
            sessions.append(session)
        }
        // Codex 기반 시설 트리(세션에 속하지 않은 것만) — 앱 묶음에서 도구로 보여 준다.
        var codexInfraTree = Set<Int32>()
        for pid in codexInfra where !assigned.contains(pid) {
            codexInfraTree.formUnion(subtree(of: pid).pids.filter { !assigned.contains($0) })
        }

        // 3b. Codex 공유 데몬 클라이언트: 데몬이 연 최상위 rollout(session_meta.parent_thread_id 없음)을 폴더 + 최근성으로 맞춘다(추정).
        //     `resume <id>`로 열었고 데몬이 그 rollout을 쥐고 있으면 그것을 먼저 고른다. TUI 안에서 /new로 바꿀 수 있어 그래도 추정이다.
        if !codexDaemonClients.isEmpty {
            var metas: [CodexRolloutMeta] = []
            for daemon in codexDaemons {
                guard let record = byPID[daemon] else { continue }
                for path in Set(openFiles(for: record, now: now)) where path.contains("/.codex/") && path.hasSuffix(".jsonl") && path.contains("sessions/") {
                    if let meta = codexMeta(path), meta.topLevel { metas.append(meta) }
                }
            }
            var claimed = Set<String>()
            for index in codexDaemonClients.sorted(by: { sessions[$0].startTime > sessions[$1].startTime }) {
                guard let cwd = sessions[index].cwd else { continue }
                let argv = sessions[index].command.split(separator: " ").map(String.init)
                let resumeID = Self.flagValue(argv, "resume")
                let start = sessions[index].startTime.addingTimeInterval(-2)
                let candidates = metas.filter { !claimed.contains($0.path) && ($0.cwd == cwd || cwd.hasPrefix($0.cwd + "/") || $0.cwd.hasPrefix(cwd + "/")) }
                let pick = candidates.first { meta in resumeID.map { meta.path.hasSuffix($0 + ".jsonl") } ?? false }
                    ?? candidates.filter { $0.modified >= start }.max { $0.modified < $1.modified }
                guard let pick else { continue }
                sessions[index].logPath = pick.path
                sessions[index].logLinkIsEstimate = true
                claimed.insert(pick.path)
            }
        }

        // 3. Claude 기록 연결. Claude는 기록 파일을 열어 두지 않는다(실측) →
        //    ① --resume <id>가 있으면 정확히 연결 ② 나머지는 시작 이후 수정된 기록 중 최근 것을 늦게 시작한 세션부터 가져간다(추정).
        //    일괄 재시작 뒤 기존 파일에 이어 쓰는 경우가 있어 생성 시각이 아니라 수정 시각으로 본다.
        for (cwd, indexes) in claudeByDirectory {
            let files = claudeLogFiles(for: cwd, now: now)
            var claimed = Set<String>()
            // ⓪ 레지스트리 sessionId → <sessionId>.jsonl (정확)
            for index in indexes {
                guard let id = registry[sessions[index].rootPID]?.sessionId else { continue }
                guard let path = files.first(where: { $0.path.hasSuffix(id + ".jsonl") })?.path ?? findClaudeLog(id: id, now: now) else { continue }
                sessions[index].logPath = path
                sessions[index].logLinkIsEstimate = false
                claimed.insert(path)
            }
            for index in indexes where sessions[index].logPath == nil {
                let argv = sessions[index].command.split(separator: " ").map(String.init)
                guard let resumeID = Self.flagValue(argv, "--resume") ?? Self.flagValue(argv, "-r") else { continue }
                // 처음 시작한 폴더(워크트리 등)에 기록이 남아 있을 수 있어 전체 프로젝트 폴더에서도 찾는다.
                guard let path = files.first(where: { $0.path.hasSuffix(resumeID + ".jsonl") })?.path ?? findClaudeLog(id: resumeID) else { continue }
                sessions[index].logPath = path
                sessions[index].logLinkIsEstimate = false
                claimed.insert(path)
            }
            // 대화형 세션이 대기(spare)보다 먼저, 늦게 시작한 세션이 먼저 가져간다.
            let order = indexes.sorted { lhs, rhs in
                let l = sessions[lhs].role == "백그라운드" ? 1 : 0, r = sessions[rhs].role == "백그라운드" ? 1 : 0
                return l != r ? l < r : sessions[lhs].startTime > sessions[rhs].startTime
            }
            for index in order where sessions[index].logPath == nil {
                let start = sessions[index].startTime.addingTimeInterval(-2)
                let candidates = files.filter { !claimed.contains($0.path) && $0.modified >= start }
                guard let best = candidates.max(by: { $0.modified < $1.modified }) else { continue }
                sessions[index].logPath = best.path
                sessions[index].logLinkIsEstimate = true
                claimed.insert(best.path)
            }
        }

        // 4a. 기록의 마지막 활동(하위 에이전트 스레드가 일하면 세션도 일하는 중)
        var infos = Array(repeating: SessionLogReader.Info(), count: sessions.count)
        for index in sessions.indices {
            if let parent = nestedParent[sessions[index].rootPID], let parentRecord = byPID[parent] { sessions[index].parentSession = parentRecord.key }
            var info = SessionLogReader.Info()
            if let path = sessions[index].logPath { info = logReader.read(path: path, kind: sessions[index].kind) }
            sessions[index].lastActivity = info.lastActivity
            for extra in sessions[index].extraLogPaths {
                if let other = logReader.read(path: extra, kind: sessions[index].kind).lastActivity, other > (sessions[index].lastActivity ?? .distantPast) {
                    sessions[index].lastActivity = other
                }
            }
            infos[index] = info
            // 하위 에이전트: Claude는 세션 폴더의 subagents 기록, Codex는 추가로 연 rollout(하위 스레드).
            switch sessions[index].kind {
            case .claudeCode:
                if let path = sessions[index].logPath, !sessions[index].logLinkIsEstimate { sessions[index].subagents = subagentScanner.scanClaude(sessionLog: path, now: now) }
            case .codexCLI:
                sessions[index].subagents = subagentScanner.scanCodex(extraLogs: sessions[index].extraLogPaths, now: now)
            default: break
            }
        }
        // 4b. Orca 터미널은 프로세스 하나에만 준다(1:1). 같은 폴더에 프로세스가 둘이고 터미널이 하나면
        //     예전엔 둘 다 같은 제목을 받아, 6일 쉰 세션이 지금 쓰는 세션 이름으로 보였다(10-24 실제 화면).
        let orcaFor = assignOrca(sessions: sessions, terminals: orca)
        let orcaAgents = Set(orca.compactMap(\.agent))
        let liveKeys = Set(sessions.map(\.id))
        cpuActivity = cpuActivity.filter { liveKeys.contains($0.key) }
        // 4c. 제목·이어 열기·상태
        for index in sessions.indices {
            var session = sessions[index]
            let info = infos[index]
            let match = orcaFor[index]
            // 기록이 정확히 연결되지 않은 세션만 터미널 출력 시각으로 보완한다. 터미널 출력은 TUI가 스피너·상태줄을
            // 다시 그릴 때도 갱신돼, 정확한 기록 시각을 덮으면 상태가 '입력 필요 ↔ 쉼'으로 깜박인다(10-24 실측).
            if session.logPath == nil || session.logLinkIsEstimate, let match, match.connected, let output = match.lastOutputAt,
               output > (session.lastActivity ?? .distantPast), output <= now.addingTimeInterval(60) {
                session.lastActivity = output
            }
            if let match { session.orcaHandle = match.handle.isEmpty ? nil : match.handle }
            // 기록을 모르는 에이전트(표·직접 추가): 하위 합계 CPU가 기준을 넘은 마지막 시각을 '활동'으로 본다(추정).
            if session.kind.isGeneric {
                if session.cpuPercent >= Self.activityCPU { cpuActivity[session.id] = now }
                if let active = cpuActivity[session.id], active > (session.lastActivity ?? .distantPast) { session.lastActivity = active }
            }
            // 탭 상태: 배정된 터미널이 고아면 '탭 닫힘', Orca 아래서 도는데 목록에 없으면 'Orca가 모름(이전 실행 잔재)'.
            // 표 에이전트는 Orca가 그 종류를 알아볼 때만(목록에 같은 agentIdentity가 있을 때) '모름'으로 본다 — 못 알아보는 종류를 잔재로 몰지 않는다.
            if let match {
                session.tabState = match.orphaned ? .closed : .open
            } else if session.terminalHost == "Orca", !orca.isEmpty, registry[session.rootPID]?.kind != "bg",
                      !session.kind.isGeneric || !orcaAgents.isDisjoint(with: Self.orcaIdentities(for: session.kind)) {
                session.tabState = .unknown
            }
            if session.kind == .claudeCode, let name = registry[session.rootPID]?.meaningfulName, let headline = Redactor.headline(name) {
                session.title = headline
                session.titleSource = "Claude 세션 이름(레지스트리)"
            } else if let match, !match.title.isEmpty {
                session.title = Redactor.headline(match.title)
                session.titleSource = "Orca 터미널 제목(1:1 배정)"
            } else if let title = info.title {
                session.title = title
                session.titleSource = "기록의 마지막 사용자 요청"
            } else if session.kind == .claudeCode, let name = registry[session.rootPID]?.name, let headline = Redactor.headline(name) {
                session.title = headline
                session.titleSource = "Claude 자동 이름(레지스트리)"
            }
            if let thread = info.threadID, let cwd = session.cwd {
                let quoted = cwd.replacingOccurrences(of: "'", with: "'\\''")
                switch session.kind {
                case .claudeCode: session.resumeCommand = "cd '\(quoted)' && claude --resume \(thread)"
                case .codexCLI: session.resumeCommand = "cd '\(quoted)' && codex resume \(thread)"
                default: break
                }
            }
            judge(&session, record: byPID[session.rootPID], now: now)
            // 주 에이전트는 조용해도 하위 에이전트가 일하면 일하는 중이다(워크플로를 기다리는 Claude가 '쉼'으로 보이던 문제).
            // 사용자 입력을 기다리는 상태(waiting)는 그대로 둔다.
            let working = session.subagents.filter(\.active)
            if !working.isEmpty, session.state != .waiting, session.state != .working {
                session.state = .working
                let workflow = working.first { $0.kind == .workflow }
                session.stateReason = "하위 에이전트 \(working.count)명 일하는 중" + (workflow.map { " · 워크플로 \($0.phase ?? $0.label)" } ?? "")
            }
            if let latest = working.compactMap(\.lastActivity).max(), latest > (session.lastActivity ?? .distantPast) { session.lastActivity = latest }
            if session.tabLeftover, session.state != .working, session.state != .waiting {
                session.state = .orphan
                session.stateConfidence = .confirmed   // Orca가 탭이 닫혔다고 직접 알려 준 것
                session.stateReason = "Orca 탭 닫힘 · 프로세스만 남음 · 마지막 기록 \(Fmt.ago(session.lastActivity, now: now))"
            }
            // Orca 밖 터미널: 창을 닫으면 보통 SIGHUP으로 함께 끝난다. 살아남아 부모가 launchd(1)로 바뀌고 제어 터미널도 없으면 잔재다
            // (레지스트리 상태로 판정한 Claude 포함). tmux 같은 화면 분할기의 분리된 세션은 부모·터미널이 그대로라 걸리지 않는다.
            // 일하는 중·입력 대기는 건드리지 않는다(탭 닫힘 규칙과 같다).
            if session.state.isResting, Self.terminalClosed(byPID[session.rootPID], host: session.terminalHost) {
                session.state = .orphan
                session.stateConfidence = .confirmed
                session.stateReason = "터미널 닫힘 · 부모 프로세스 없음 · 마지막 기록 \(Fmt.ago(session.lastActivity, now: now))"
            }
            sessions[index] = session
        }
        sessions.sort { ($0.project, $0.startTime) < ($1.project, $1.startTime) }

        // 5. 나머지 프로세스: 앱 묶음 · 시스템 · 기타
        var groups: [String: AppGroup] = [:]
        func add(_ record: ProcRecord, id: String, name: String, category: AppGroup.Category, kind: AgentKind? = nil) {
            var group = groups[id] ?? AppGroup(id: id, name: name, category: category, agentKind: kind, pids: [], footprint: 0, cpuPercent: 0)
            group.pids.append(record.pid)
            group.footprint += record.footprint
            group.cpuPercent += record.cpuPercent
            if record.memorySource == .top { group.memorySourceNote = "일부 top 기준" }
            groups[id] = group
        }
        for record in records where !assigned.contains(record.pid) {
            let path = record.path ?? ""
            if claudeInfra.contains(record.pid) || (spares.contains(record.pid) && !spareSessionPIDs.contains(record.pid)) {
                add(record, id: "claude-daemon", name: "Claude 데몬 · 대기", category: .agentApp, kind: .claudeCode)
            } else if codexInfraTree.contains(record.pid) {
                add(record, id: "codex-server", name: "Codex 서버 · 앱 서버·데몬", category: .agentApp, kind: .codexCLI)
            } else if let bundle = Self.outermostBundle(path) {
                let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
                // 에이전트 세션을 띄운 터미널 앱(Ghostty·터미널·Warp·VS Code 등)도 Orca처럼 '터미널 호스트'로 묶는다(종료하면 세션이 함께 끝난다).
                let hosting = record.uid == selfUID && hostBundles.contains(bundle)
                switch name {
                case "Orca": add(record, id: bundle, name: name, category: .host)
                case "ChatGPT", "Codex": add(record, id: bundle, name: "ChatGPT · Codex Desktop", category: .agentApp, kind: .codexDesktop)
                case "Aside": add(record, id: bundle, name: name, category: .agentApp, kind: .aside)
                case "Cursor": add(record, id: bundle, name: name, category: hosting ? .host : .agentApp, kind: .cursor)
                default:
                    let system = bundle.hasPrefix("/System/") || record.uid != selfUID
                    add(record, id: bundle, name: name, category: hosting ? .host : system ? .system : .app)
                }
            } else if record.uid != selfUID || ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/usr/bin/", "/Library/Apple/"].contains(where: { path.hasPrefix($0) }) || record.pid == 0 {
                add(record, id: "system", name: "시스템 프로세스", category: .system)
            } else {
                add(record, id: "other", name: "기타 사용자 프로세스", category: .other)
            }
        }
        let apps = groups.values.sorted { $0.footprint > $1.footprint }
        return Result(sessions: sessions, apps: apps, standbySpares: standby)
    }

    // MARK: - 판정

    func judge(_ session: inout AgentSession, record: ProcRecord?, now: Date) {
        if session.kind.isGeneric { judgeGeneric(&session, record: record, now: now); session.stateConfidence = .estimated; return }
        let cpu = session.cpuPercent
        // 증거 등급: 레지스트리 상태·정확히 연결된 기록 시각·커널의 부모 pid는 '확인', 추정 연결·CPU 패턴·실행 시간은 '추정'.
        session.stateConfidence = .estimated
        let estimate = session.logLinkIsEstimate ? " · 기록 연결은 추정" : ""
        // Claude 레지스트리 상태가 있으면 그것을 1차 신호로 쓴다(REA §3, §10 B9). 살아 있는 등록 세션은 고아가 아니다.
        if session.kind == .claudeCode, let entry = registry[session.rootPID], let status = entry.status {
            let last = [session.lastActivity, entry.statusUpdatedAt].compactMap { $0 }.max()
            session.lastActivity = last
            session.stateConfidence = .confirmed
            switch status {
            case "busy":
                session.state = .working; session.stateReason = "Claude 상태: 작업 중(busy)"
            case "shell":
                session.state = .working; session.stateReason = "Claude 상태: 셸 명령 실행 중"
            case "waiting":
                session.state = .waiting; session.stateReason = "Claude 상태: 입력 대기" + (entry.waitingFor.map { "(\($0))" } ?? "")
            default:
                let silence = last.map { now.timeIntervalSince($0) } ?? .infinity
                if cpu >= settings.workingCPU {
                    session.state = .working; session.stateReason = "하위 합계 CPU \(Fmt.percent(cpu)) · Claude 상태 \(status)"
                } else if silence < settings.waitingLimit {
                    session.state = .waiting; session.stateReason = "Claude 상태: 대기(idle) · 마지막 활동 \(Fmt.ago(last, now: now))"
                } else if silence < settings.idleLimit {
                    session.state = .idle; session.stateReason = "Claude 상태: 대기(idle) · 마지막 활동 \(Fmt.ago(last, now: now))"
                } else {
                    session.state = .longIdle; session.stateReason = "Claude 상태: 대기(idle) · 마지막 활동 \(Fmt.ago(last, now: now))"
                }
            }
            return
        }
        if let last = session.lastActivity {
            let silence = now.timeIntervalSince(last)
            session.stateConfidence = session.logLinkIsEstimate ? .estimated : .confirmed
            if silence < settings.workingWindow || cpu >= settings.workingCPU {
                session.state = .working
                session.stateReason = silence < settings.workingWindow ? "마지막 기록 \(Fmt.ago(last, now: now))\(estimate)" : "하위 합계 CPU \(Fmt.percent(cpu))"
                return
            }
            if record?.ppid == 1 && session.terminalHost == nil {
                session.state = .orphan
                session.stateConfidence = .confirmed
                session.stateReason = "터미널 닫힘 · 부모 프로세스 없음(launchd) · 마지막 기록 \(Fmt.ago(last, now: now))"
                return
            }
            if silence < settings.waitingLimit {
                session.state = .waiting
            } else if silence < settings.idleLimit {
                session.state = .idle
            } else {
                session.state = .longIdle
            }
            session.stateReason = "마지막 기록 \(Fmt.ago(last, now: now))\(estimate)"
            return
        }
        let age = now.timeIntervalSince(session.startTime)
        if cpu >= settings.workingCPU {
            session.state = .working
            session.stateReason = "기록 연결 없음 · 하위 합계 CPU \(Fmt.percent(cpu))"
        } else if record?.ppid == 1 && session.terminalHost == nil {
            session.state = .orphan
            session.stateConfidence = .confirmed
            session.stateReason = "터미널 닫힘 · 부모 프로세스 없음(launchd)"
        } else if age > settings.orphanSilence && cpu < 0.1 {
            // 기록이 없고 조용한 것만으로는 잔재라 할 수 없다(백그라운드 세션을 보는 창·첫 질문 전 세션). 고아가 아니라 '오래 쉼'.
            session.state = .longIdle
            session.stateReason = "기록 없음 + CPU 0이 \(Fmt.duration(age)) 지속(추정)"
        } else {
            session.state = age < settings.waitingLimit ? .waiting : .idle
            session.stateReason = "기록 연결 없음 · 실행 \(Fmt.duration(age))(추정)"
        }
    }

    /// 기록 형식을 모르는 에이전트(표·직접 추가)의 판정. 근거는 CPU와 부모·터미널뿐이라 모두 추정이다.
    /// 터미널이 살아 있으면 오래 조용해도 고아로 보지 않는다(쉼·오래 쉼) — 고아는 자동 메모리 정리 대상이라 열린 터미널의 세션을 잔재로 몰면 안 된다.
    func judgeGeneric(_ session: inout AgentSession, record: ProcRecord?, now: Date) {
        let cpu = session.cpuPercent
        let last = session.lastActivity
        if cpu >= settings.workingCPU {
            session.state = .working
            session.stateReason = "하위 합계 CPU \(Fmt.percent(cpu)) · 기록 없음(추정)"
            return
        }
        if let last, now.timeIntervalSince(last) < settings.workingWindow {
            session.state = .working
            session.stateReason = "CPU 활동 \(Fmt.ago(last, now: now)) · 기록 없음(추정)"
            return
        }
        if Self.terminalClosed(record, host: session.terminalHost) {
            session.state = .orphan
            session.stateReason = "터미널 닫힘 · 부모 프로세스 없음" + (last.map { " · 마지막 CPU 활동 \(Fmt.ago($0, now: now))" } ?? "")
            return
        }
        let silence = now.timeIntervalSince(last ?? session.startTime)
        session.state = silence < settings.waitingLimit ? .waiting : silence < settings.idleLimit ? .idle : .longIdle
        session.stateReason = (last.map { "마지막 CPU 활동 \(Fmt.ago($0, now: now))" } ?? "실행 \(Fmt.duration(silence)) · CPU 활동 없음") + " · 기록 없음(추정)"
    }

    /// 부모가 launchd(1)로 바뀌었고 제어 터미널도 없으며 터미널 호스트가 사슬에 없다 = 터미널 창이 닫힌 뒤 살아남은 프로세스.
    static func terminalClosed(_ record: ProcRecord?, host: String?) -> Bool {
        guard let record else { return false }
        return record.ppid == 1 && !record.hasTTY && host == nil
    }

    /// Orca `agentIdentity`로 짝지을 이름들.
    static func orcaIdentities(for kind: AgentKind) -> Set<String> {
        switch kind {
        case .claudeCode: ["claude"]
        case .codexCLI: ["codex"]
        case .opencode: ["opencode"]
        default: Set(AgentSignatures.signature(for: kind)?.orcaIdentities ?? [])
        }
    }

    /// 표 에이전트의 자체 실행 파일 이름(빠른 1차 거름용).
    static let tableBinaryNames = Set(AgentSignatures.generic.flatMap(\.binaryNames))

    // MARK: - 보조

    private func makeSession(root: ProcRecord, kind: AgentKind, role: String, pids: [Int32], footprint: UInt64, cpu: Double, cwd: String?, argv: [String]) -> AgentSession {
        AgentSession(
            id: root.key, kind: kind, role: role, rootPID: root.pid, pids: pids, childCount: max(0, pids.count - 1),
            footprint: footprint, cpuPercent: cpu, startTime: root.startTime, cwd: cwd, project: projectName(for: cwd),
            title: nil, titleSource: "없음", logPath: nil, logLinkIsEstimate: true, lastActivity: nil,
            state: .waiting, stateReason: "", resumeCommand: nil, parentSession: nil, terminalHost: nil,
            command: Redactor.redact(argv.joined(separator: " "))
        )
    }

    /// 다른 프로그램이 잠깐 부르는 헤드리스 실행(`claude -p`) 역할 이름. 몇 초~몇 분 만에 끝나 출근·퇴근 연출과 기록을 생략한다.
    public static let helperRole = "보조 호출"

    nonisolated(unsafe) private static let namer = SessionDetector()
    /// 앱 쪽(청소 대상 경로 → 방 이름)에서 쓰는 같은 규칙.
    public static func projectName(for path: String?) -> String { namer.projectName(for: path) }

    /// 작업 폴더 → 프로젝트(방) 이름. ~/DEV/X/…, ~/orca/workspaces/X/…, 그 외는 마지막 폴더.
    public func projectName(for cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "/" else { return "기타" }
        let parts = cwd.split(separator: "/").map(String.init)
        let homeParts = home.split(separator: "/").map(String.init)
        if parts.starts(with: homeParts) {
            let rest = Array(parts.dropFirst(homeParts.count))
            if rest.count >= 2, rest[0] == "DEV" { return rest[1] }
            if rest.count >= 3, rest[0] == "orca", rest[1] == "workspaces" { return rest[2] }
            if rest.count >= 3, rest[0] == ".codex", rest[1] == "worktrees" { return rest.count > 3 ? rest[3] : rest[2] }
            if rest.isEmpty { return "홈" }
        }
        // 임시 폴더(예: storearc-cli-<UUID>)는 UUID를 떼어 같은 방으로 모은다. macOS 임시 폴더 자체(T·tmp)는 '임시' 방.
        guard let last = parts.last else { return "기타" }
        if last == "T" || last == "tmp" || last == "TemporaryItems" { return "임시" }
        let pattern = #"[-_.]?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#
        if let range = last.range(of: pattern, options: .regularExpression) {
            let stem = String(last[..<range.lowerBound])
            return stem.isEmpty ? "임시" : stem
        }
        return last
    }

    /// 부모 사슬에서 처음 만나는 터미널·화면 분할기·SSH(TerminalHosts 표)와 그 앱 번들.
    private func terminalHost(for record: ProcRecord, byPID: [Int32: ProcRecord]) -> (name: String, bundle: String?)? {
        var current = byPID[record.ppid]
        var depth = 0
        while let item = current, item.pid > 1, depth < 32 {
            if let host = TerminalHosts.host(for: item) {
                return (host.name, host.multiplexer ? nil : item.path.flatMap(Self.outermostBundle))
            }
            current = byPID[item.ppid]
            depth += 1
        }
        return nil
    }

    /// Orca CLI에는 pid·tty가 없어(REA §5) 폴더 + 에이전트 종류로 짝짓는다. 터미널 하나는 세션 하나에만(1:1).
    /// 점수: ① 레지스트리 세션 이름 = 터미널 제목(정확) ② 터미널 마지막 출력과 세션 마지막 활동이 가까울수록 ③ 더 깊은 폴더(워크트리) 일치.
    func assignOrca(sessions: [AgentSession], terminals: [OrcaTerminal]) -> [Int: OrcaTerminal] {
        var result: [Int: OrcaTerminal] = [:]
        var usedSessions = Set<Int>(), usedTerminals = Set<Int>()
        // 1) 정확히: Orca가 탭 안 프로세스에 넣어 주는 환경 변수(ORCA_TERMINAL_HANDLE · ORCA_AGENT_PANE=탭:창 · ORCA_TAB_ID)로 짝짓는다.
        //    제목·폴더 추정이 빗나가 살아 있는 창을 잔재로 몰던 일(10-25 사고)을 뿌리에서 막는다. 백그라운드 세션은 데몬의 환경을 물려받아 제외.
        for (sessionIndex, session) in sessions.enumerated() where registry[session.rootPID]?.kind != "bg" {
            guard let environment = detailSource?.arguments(for: session.id)?.environment else { continue }
            var found: Int?
            if let handle = environment["ORCA_TERMINAL_HANDLE"], !handle.isEmpty {
                found = terminals.firstIndex { $0.handle == handle }
            }
            if found == nil, let pane = environment["ORCA_AGENT_PANE"], let colon = pane.firstIndex(of: ":") {
                let tab = String(pane[..<colon]), leaf = String(pane[pane.index(after: colon)...])
                found = terminals.firstIndex { $0.leafId == leaf && ($0.tabId == nil || $0.tabId == tab) }
            }
            if found == nil, let tab = environment["ORCA_TAB_ID"] {
                let inTab = terminals.indices.filter { terminals[$0].tabId == tab }
                if inTab.count == 1 { found = inTab[0] }
            }
            if let found, !usedTerminals.contains(found) {
                result[sessionIndex] = terminals[found]
                usedSessions.insert(sessionIndex)
                usedTerminals.insert(found)
            }
        }
        // 2) 환경 변수가 없는 세션(Orca 밖·옛 Orca)만 폴더·종류·제목으로 추정한다.
        var pairs: [(score: Double, session: Int, terminal: Int)] = []
        for (sessionIndex, session) in sessions.enumerated() where !usedSessions.contains(sessionIndex) {
            guard let cwd = session.cwd else { continue }
            // Claude 백그라운드 세션은 데몬 아래서 화면 없이 돈다 — Orca 탭은 그 세션을 '열어 보는' 대화형 창의 것이다.
            // 탭 제목이 백그라운드 세션 이름으로 바뀌어 이름 일치 점수로 탭을 빼앗아 가던 문제(10-25 사고).
            if registry[session.rootPID]?.kind == "bg" { continue }
            let agents = Self.orcaIdentities(for: session.kind)
            guard !agents.isEmpty else { continue }
            let generic = session.kind.isGeneric
            let name = registry[session.rootPID]?.name.map(OrcaBridge.cleanTitle)
            // 고아 PTY는 Orca가 에이전트 종류를 잃는 경우가 있어(agent nil) 폴더만 맞으면 낮은 점수로 짝짓는다.
            // 표 에이전트는 종류 이름이 정확히 같을 때만 짝짓는다(폴더만 맞는 닫힌 탭을 붙여 잔재로 모는 일을 막는다).
            for (terminalIndex, terminal) in terminals.enumerated() where (agents.contains(terminal.agent ?? "") || (!generic && terminal.orphaned && terminal.agent == nil))
                && (cwd == terminal.worktreePath || cwd.hasPrefix(terminal.worktreePath + "/")) {
                var score = Double(terminal.worktreePath.count) - (terminal.agent == nil ? 500_000 : 0)
                if let name, !name.isEmpty, name == terminal.title { score += 10_000_000 }
                if let output = terminal.lastOutputAt, let last = session.lastActivity {
                    score += 1_000_000 - min(1_000_000, abs(output.timeIntervalSince(last)))
                }
                pairs.append((score, sessionIndex, terminalIndex))
            }
        }
        for pair in pairs.sorted(by: { $0.score > $1.score }) where !usedSessions.contains(pair.session) && !usedTerminals.contains(pair.terminal) {
            result[pair.session] = terminals[pair.terminal]
            usedSessions.insert(pair.session)
            usedTerminals.insert(pair.terminal)
        }
        return result
    }

    public func claudeProjectDirectories(for cwd: String) -> [String] {
        let base = home + "/.claude/projects/"
        let keepUnderscore = cwd.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" || $0 == "-" ? String($0) : "-" }.joined()
        let replaceUnderscore = keepUnderscore.replacingOccurrences(of: "_", with: "-")
        return Array(Set([keepUnderscore, replaceUnderscore])).map { base + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    struct LogFile { var path: String; var created: Date; var modified: Date }

    private var directoryCache: [String: (files: [LogFile], at: Date)] = [:]
    private var openFilesCache: [ProcessKey: (paths: [String], at: Date)] = [:]

    /// 프로젝트 폴더의 jsonl 목록. 폴더당 5초 캐시(2초 주기마다 수백 개 stat을 반복하지 않기 위해).
    func claudeLogFiles(for cwd: String, now: Date = Date()) -> [LogFile] {
        var files: [LogFile] = []
        for directory in claudeProjectDirectories(for: cwd) {
            if let cached = directoryCache[directory], now.timeIntervalSince(cached.at) < 5 {
                files += cached.files
                continue
            }
            var listed: [LogFile] = []
            if let names = try? FileManager.default.contentsOfDirectory(atPath: directory) {
                for name in names where name.hasSuffix(".jsonl") {
                    var info = stat()
                    let path = directory + "/" + name
                    guard stat(path, &info) == 0 else { continue }
                    listed.append(LogFile(path: path, created: Date(timeIntervalSince1970: TimeInterval(info.st_birthtimespec.tv_sec)),
                                          modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))))
                }
            }
            directoryCache[directory] = (listed, now)
            files += listed
        }
        return files
    }

    private var resumeLookup: [String: (path: String?, at: Date)] = [:]

    /// ~/.claude/projects/*/<id>.jsonl 중 가장 최근에 수정된 것. id당 60초 캐시.
    func findClaudeLog(id: String, now: Date = Date()) -> String? {
        if let cached = resumeLookup[id], now.timeIntervalSince(cached.at) < 60 { return cached.path }
        let base = home + "/.claude/projects"
        let directories = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
        var best: (path: String, modified: Int)?
        for directory in directories {
            let path = base + "/" + directory + "/" + id + ".jsonl"
            var info = stat()
            guard stat(path, &info) == 0 else { continue }
            if best == nil || info.st_mtimespec.tv_sec > best!.modified { best = (path, info.st_mtimespec.tv_sec) }
        }
        resumeLookup[id] = (best?.path, now)
        return best?.path
    }

    /// 열린 파일 목록. 프로세스당 10초 캐시.
    func openFiles(for record: ProcRecord, now: Date) -> [String] {
        if let cached = openFilesCache[record.key], now.timeIntervalSince(cached.at) < 10 { return cached.paths }
        let paths = detailSource?.openFiles(for: record.key, pid: record.pid) ?? ProcessSampler.openFiles(pid: record.pid)
        openFilesCache[record.key] = (paths, now)
        if openFilesCache.count > 200 { openFilesCache = openFilesCache.filter { now.timeIntervalSince($0.value.at) < 60 } }
        return paths
    }

    static func earliestCreated(_ paths: [String]) -> String? {
        paths.min { lhs, rhs in
            var l = stat(), r = stat()
            stat(lhs, &l); stat(rhs, &r)
            return l.st_birthtimespec.tv_sec < r.st_birthtimespec.tv_sec
        }
    }

    /// Codex 기반 시설 하위 명령(app-server·exec-server·mcp-server, `app-server daemon …` 포함). 에이전트 세션이 아니다.
    static func isCodexServer(_ argv: [String]) -> Bool {
        argv.dropFirst().contains { ["app-server", "exec-server", "mcp-server"].contains($0) }
    }

    /// rollout 첫 줄(session_meta)의 폴더·부모 스레드. 첫 줄은 기본 지시문까지 담아 20KB를 넘는다(10-25 실측) → 512KB까지 읽고, 경로마다 한 번만 읽는다.
    struct CodexRolloutMeta {
        var path: String
        var cwd: String
        var topLevel: Bool
        var modified: Date
    }

    private var codexMetaCache: [String: (cwd: String, topLevel: Bool)] = [:]

    func codexMeta(_ path: String) -> CodexRolloutMeta? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        if let cached = codexMetaCache[path] { return CodexRolloutMeta(path: path, cwd: cached.cwd, topLevel: cached.topLevel, modified: modified) }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count < 512 << 10, let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty {
            data.append(chunk)
            if chunk.contains(0x0A) { break }
        }
        guard let line = data.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              object["type"] as? String == "session_meta", let payload = object["payload"] as? [String: Any], let cwd = payload["cwd"] as? String else { return nil }
        let parent = payload["parent_thread_id"] as? String ?? ""
        let topLevel = parent.isEmpty
        if codexMetaCache.count > 500 { codexMetaCache.removeAll() }
        codexMetaCache[path] = (cwd, topLevel)
        return CodexRolloutMeta(path: path, cwd: cwd, topLevel: topLevel, modified: modified)
    }

    static func codexRole(_ argv: [String]) -> String {
        let known: [String: String] = ["exec": "exec 일회성", "resume": "이어 열기", "app-server": "앱 서버", "mcp-server": "MCP 서버", "fork": "fork", "review": "리뷰", "cloud": "클라우드"]
        for argument in argv.dropFirst() where !argument.hasPrefix("-") {
            if let label = known[argument] { return label }
        }
        return "대화형"
    }

    static func flagValue(_ argv: [String], _ flag: String) -> String? {
        guard let index = argv.firstIndex(of: flag), index + 1 < argv.count else { return nil }
        return argv[index + 1]
    }

    static func outermostBundle(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }
}
