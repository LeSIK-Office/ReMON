import Darwin
import Foundation

// 에이전트가 남긴 보조 프로세스(G2) — MCP 서버·헤드리스 브라우저·개발 서버·언어 서버·빌드 데몬.
// 세션이 살아 있는 동안 하위 프로세스가 어느 세션 것인지 매 주기 적어 두고, 세션 루트가 끝난 뒤에도 남은 하위만
// '남은 보조 프로세스'로 분류한다(보통 launchd로 부모가 바뀐다).
// 증거 규칙: ReMON이 실제로 세션 하위로 본 프로세스만 대상이다. 명령줄 패턴은 종류 이름표에만 쓰고 대상 판정에는 쓰지 않는다.
// 이력은 메모리에만 둔다 — ReMON을 다시 켜면 그 전 이력은 모르므로 대상이 아니다.
// 워크플로 잔재: 세션이 하위 에이전트로 띄운 헤드리스 에이전트(세션 안의 claude -p · 그 세션을 부모로 둔 codex exec 등)는 주인이 끝나면
// 감지기가 스스로 세션 루트로 잡지만, 주인 세션이 남긴 일꾼이므로 '워크플로 잔재 · 프로젝트'라는 남은 보조 프로세스로 분류한다(쉬는 10분 규칙 그대로).

/// 보조 프로세스 종류(명령줄 패턴으로 붙이는 이름표). 대상 판정에는 쓰지 않는다.
/// workflowAgent는 패턴이 아니라 계보(주인 세션이 하위 에이전트로 띄움)로만 붙는다.
public enum HelperKind: String, Sendable, Codable, CaseIterable {
    case mcpServer, browser, devServer, languageServer, buildDaemon, workflowAgent, other

    public var label: String {
        switch self {
        case .mcpServer: "MCP 서버"
        case .browser: "헤드리스 브라우저"
        case .devServer: "개발 서버"
        case .languageServer: "언어 서버"
        case .buildDaemon: "빌드 데몬"
        case .workflowAgent: "워크플로 에이전트"
        case .other: "보조 프로세스"
        }
    }

    // 실행 파일 경로로 보는 브라우저(Playwright·Puppeteer·Chrome for Testing·에이전트가 띄운 Chrome).
    private static let browserPaths = ["chrome", "chromium", "msedge", "/ms-playwright/", "firefox", "webkit", "headless_shell", "/puppeteer/"]
    // 브라우저 자동화 드라이버(명령줄).
    private static let browserDrivers = ["playwright", "puppeteer", "run-driver", "chromedriver", "geckodriver", "webdriver"]
    private static let mcpWords = ["modelcontextprotocol", "fastmcp", "mcp-server", "mcp_server", "mcpserver"]
    private static let languageWords = ["language-server", "languageserver", "langserver", "tsserver", "pyright", "pylsp", "gopls", "rust-analyzer", "sourcekit-lsp",
                                        "clangd", "jdtls", "solargraph", "intelephense", "eslint_d", "lsp-proxy", "ruff server", "elixir-ls", "omnisharp", "csharp-ls",
                                        "terraform-ls", "marksman", "vtsls", "-lsp", "lsp-", "_lsp"]
    private static let buildWords = ["org.gradle.launcher.daemon", "gradledaemon", "org.jetbrains.kotlin.daemon", "kotlincompiledaemon", "kotlin-daemon", "sccache",
                                     "watchman", "esbuild --service", "turbo daemon", "nx/src/daemon", "buck2d", "bazel", "bloop"]
    // 짧은 단어는 경로·인자 토큰과 정확히 맞을 때만(예: 'vite'가 'invite'에 걸리지 않게).
    private static let devTokens: Set<String> = ["vite", "nodemon", "ts-node-dev", "storybook", "parcel", "metro", "uvicorn", "gunicorn", "puma", "live-server",
                                                 "http-server", "next-server", "webpack-dev-server", "concurrently"]
    private static let devPhrases = ["next dev", "next start", "webpack serve", "--watch", "tsx watch", "npm run dev", "npm start", "pnpm dev", "pnpm run dev", "yarn dev",
                                     "bun dev", "bun run dev", "astro dev", "remix dev", "nuxt dev", "nuxi dev", "expo start", "react-scripts start", "ng serve",
                                     "vue-cli-service serve", "gatsby develop", "hugo server", "jekyll serve", "http.server", "flask run", "runserver", "rails s",
                                     "rails server", "wrangler dev", "vercel dev", "netlify dev", "firebase emulators", "cargo watch", "dotnet watch", "turbo dev"]

    private static let mcpToken = try! NSRegularExpression(pattern: #"(^|[^a-z0-9])mcp([^a-z0-9]|$)"#)

    /// 이름표 고르기. 실행 파일이 브라우저면 브라우저, 그다음 MCP → 자동화 드라이버 → 언어 서버 → 빌드 데몬 → 개발 서버 순.
    public static func classify(name: String, path: String?, argv: [String]) -> HelperKind {
        let executable = (path?.isEmpty == false ? path! : (argv.first ?? name)).lowercased()
        let text = ([executable, name.lowercased()] + argv.map { $0.lowercased() }).joined(separator: " ")
        let tokens = Set(text.split(whereSeparator: { " /=@:,\"'".contains($0) }).map(String.init))
        // 시스템 WebKit(XPC) 같은 /System 아래 실행 파일은 브라우저 자동화가 아니다.
        if !executable.hasPrefix("/system/"), browserPaths.contains(where: executable.contains) { return .browser }
        if mcpWords.contains(where: text.contains) || mcpToken.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return .mcpServer }
        if browserDrivers.contains(where: text.contains) { return .browser }
        if languageWords.contains(where: text.contains) { return .languageServer }
        if buildWords.contains(where: text.contains) { return .buildDaemon }
        if devPhrases.contains(where: text.contains) || tokens.contains(where: { token in devTokens.contains(token) || devTokens.contains { token.hasPrefix($0 + ".") } }) { return .devServer }
        return .other
    }
}

/// 보조 프로세스가 어느 세션에서 나왔는지(ReMON이 세션 하위로 직접 본 기록).
public struct HelperOrigin: Sendable, Equatable {
    public var sessionKey: ProcessKey
    public var agent: AgentKind
    public var project: String
    public var title: String
    public var cwd: String?
    /// 이 세션 하위로 처음 본 시각
    public var firstSeen: Date
    /// 세션이 살아 있을 때 마지막으로 본 시각
    public var lastSeen: Date
    /// 세션 루트가 사라진 것을 처음 안 시각(살아 있으면 nil)
    public var sessionEndedAt: Date?
    /// 세션을 띄운 터미널(TerminalHosts 이름) — 다시 띄우기를 그 터미널에서 연다.
    public var terminalHost: String? = nil
    /// 주인 세션이 하위 에이전트로 띄운 헤드리스 에이전트가(또는 그 하위가) 주인이 끝난 뒤 남은 묶음.
    public var workflowResidue = false

    public var label: String { workflowResidue ? "워크플로 잔재 · \(project)" : "\(agent.label) · \(project)" }
}

/// 세션이 끝났는데 남은 보조 프로세스 묶음: 맨 위 프로세스 + 그 아래 같이 남은 하위(예: 브라우저 본체 + 렌더러).
public struct OrphanHelper: Identifiable, Sendable, Equatable {
    public var top: ProcessKey
    /// 맨 위 포함
    public var members: [ProcessKey]
    public var kind: HelperKind
    /// 대표 프로세스 이름
    public var name: String
    public var path: String?
    /// 가린 명령줄(대표 프로세스)
    public var command: String
    public var footprint: UInt64
    public var cpuPercent: Double
    public var uid: UInt32
    public var parentPID: Int32
    public var startTime: Date
    public var origin: HelperOrigin
    /// 묶음 전체가 CPU를 거의 쓰지 않은 시간(가장 최근에 움직인 구성원 기준). CPU를 못 읽으면 0.
    public var idleFor: TimeInterval
    /// idleFor가 설정한 시간(N분)을 넘었는가
    public var idle: Bool
    public var cpuReadable: Bool

    public var id: ProcessKey { top }
    public var pids: [Int32] { members.map(\.pid) }
    public var displayName: String { "\(kind.label) · \(name)" }
}

extension ProcRecord {
    /// 시험·합성 기록용 공개 초기화(멤버별 초기화는 모듈 밖에서 보이지 않는다). start는 µs.
    public init(pid: Int32, ppid: Int32, uid: UInt32, name: String, start: Int64, path: String?, footprint: UInt64 = 0, cpuTimeNs: UInt64 = 0,
                memorySource: MemorySource = .kernel) {
        self.init(pid: pid, ppid: ppid, uid: uid, name: name, startTime: Date(timeIntervalSince1970: TimeInterval(start) / 1_000_000),
                  key: ProcessKey(pid: pid, start: start), path: path, footprint: footprint, memorySource: memorySource, cpuTimeNs: cpuTimeNs, cpuPercent: 0)
    }
}

/// 세션 하위 계보 기록기. Monitor가 사무실 주기마다 observe를 부른다(감지 결과 재사용, 추가 커널 호출 없음).
public final class HelperTracker: @unchecked Sendable {
    public struct Settings: Sendable, Equatable {
        /// 이 시간 동안 CPU 시간이 거의 늘지 않으면 '쉬는 중'(N분).
        public var idleAfter: TimeInterval
        /// 주기 사이 CPU 사용이 이 값(한 코어 대비 %)을 넘어야 '움직임'으로 본다(타이머 같은 미세한 깨어남은 무시).
        public var activeCPUPercent: Double
        /// 세션이 끝난 직후엔 보조 프로세스도 스스로 끝나는 중일 수 있어 이 시간이 지난 뒤부터 목록에 올린다.
        public var grace: TimeInterval
        /// 기억하는 프로세스 수 상한(메모리 보호).
        public var capacity: Int

        public init(idleAfter: TimeInterval = 600, activeCPUPercent: Double = 0.5, grace: TimeInterval = 30, capacity: Int = 4000) {
            self.idleAfter = idleAfter
            self.activeCPUPercent = activeCPUPercent
            self.grace = grace
            self.capacity = capacity
        }
    }

    private struct Entry {
        var origin: HelperOrigin
        var cpuNs: UInt64
        var cpuAt: Date
        var activeAt: Date
        var cpuReadable: Bool
        /// 종류·가린 명령줄. 고아가 된 뒤 한 번만 읽는다.
        var label: (kind: HelperKind, command: String)?
        /// 세션이 하위 에이전트로 띄운 헤드리스 에이전트 프로세스(주인이 끝나면 워크플로 잔재).
        var subagent = false
        /// subagent 판정을 했는가(실행 인자는 프로세스마다 한 번만 읽는다).
        var agentChecked = false
    }

    private let lock = NSLock()
    private var entries: [ProcessKey: Entry] = [:]
    private var orphanList: [OrphanHelper] = []
    private var config: Settings
    /// 실행 인자 읽기(하위 에이전트 판정 · 이름표). 시험은 합성 기록의 인자를 넣는다.
    public var argumentReader: @Sendable (Int32) -> [String]? = { ProcessSampler.readArguments(pid: $0)?.argv }

    public init(settings: Settings = Settings()) {
        config = settings
    }

    public var settings: Settings {
        get { lock.lock(); defer { lock.unlock() }; return config }
        set { lock.lock(); config = newValue; lock.unlock() }
    }

    /// 마지막 observe 기준 남은 보조 프로세스(메모리 큰 순).
    public var orphans: [OrphanHelper] {
        lock.lock(); defer { lock.unlock() }
        return orphanList
    }

    /// 이 프로세스를 세션 하위로 본 기록('왜 실행 중?' 카드용). 본 적 없으면 nil.
    public func origin(for key: ProcessKey) -> HelperOrigin? {
        lock.lock(); defer { lock.unlock() }
        return entries[key]?.origin
    }

    public var trackedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// 매 사무실 주기: ① 살아 있는 세션의 하위(루트 제외)를 적고 ② 사라진 프로세스는 잊고
    /// ③ 루트가 끝난 세션의 남은 하위를 묶어 목록을 만든다.
    public func observe(records: [ProcRecord], sessions: [AgentSession], now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var byPID: [Int32: ProcRecord] = [:]
        byPID.reserveCapacity(records.count)
        for record in records { byPID[record.pid] = record }
        func live(_ key: ProcessKey) -> ProcRecord? {
            guard let record = byPID[key.pid], record.key == key else { return nil }
            return record
        }
        let threshold = config.activeCPUPercent
        let readArguments = argumentReader

        // ① 루트가 살아 있는 세션의 하위만(감지가 잠깐 놓친 세션이라도 루트가 살아 있으면 고아가 아니다).
        var underSession = Set<ProcessKey>()
        // 지금 세션 루트인 것(예: 바깥 claude가 끝나 스스로 세션이 된 안쪽 claude)은 보조 프로세스가 아니라 세션이다.
        // 단 주인 세션이 하위 에이전트로 띄운 헤드리스 에이전트(subagent)는 주인이 끝나면 워크플로 잔재로 본다(②).
        let liveSessions = sessions.filter { live($0.id) != nil }
        let liveRoots = Set(liveSessions.map(\.id))
        for session in liveSessions {
            for pid in session.pids where pid != session.rootPID {
                guard let record = byPID[pid] else { continue }
                underSession.insert(record.key)
                if var entry = entries[record.key] {
                    if entry.origin.sessionKey != session.id {
                        entry.origin = Self.origin(of: session, now: now)
                        entry.label = nil
                    } else {
                        entry.origin.lastSeen = now
                        entry.origin.project = session.project
                        entry.origin.title = session.displayTitle
                        entry.origin.sessionEndedAt = nil
                    }
                    if !entry.agentChecked {
                        entry.subagent = Self.isHeadlessAgent(record, arguments: readArguments)
                        entry.agentChecked = true
                    }
                    Self.track(&entry, record, now: now, threshold: threshold)
                    entries[record.key] = entry
                } else if entries.count < config.capacity {
                    entries[record.key] = Entry(origin: Self.origin(of: session, now: now), cpuNs: record.cpuTimeNs, cpuAt: now, activeAt: now,
                                                cpuReadable: record.memorySource == .kernel, label: nil,
                                                subagent: Self.isHeadlessAgent(record, arguments: readArguments), agentChecked: true)
                }
            }
        }
        // ①-2 다른 종류의 하위 세션(예: Claude 세션이 띄운 codex exec)은 감지기가 따로 세션 루트로 잡는다(parentSession = 주인).
        //      헤드리스·일회성 실행이면 그 루트를 주인 세션의 하위 에이전트로 적어 둔다(주인이 끝나면 워크플로 잔재).
        let liveByKey = Dictionary(liveSessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in liveSessions {
            guard let ownerKey = session.parentSession, let owner = liveByKey[ownerKey], Self.isHeadlessRole(session), let record = live(session.id) else { continue }
            if var entry = entries[session.id] {
                if entry.origin.sessionKey != owner.id {
                    entry.origin = Self.origin(of: owner, now: now)
                    entry.label = nil
                } else {
                    entry.origin.lastSeen = now
                    entry.origin.project = owner.project
                    entry.origin.title = owner.displayTitle
                    entry.origin.sessionEndedAt = nil
                }
                entry.subagent = true
                entry.agentChecked = true
                entries[session.id] = entry
            } else if entries.count < config.capacity {
                entries[session.id] = Entry(origin: Self.origin(of: owner, now: now), cpuNs: record.cpuTimeNs, cpuAt: now, activeAt: now,
                                            cpuReadable: record.memorySource == .kernel, label: nil, subagent: true, agentChecked: true)
            }
        }

        // ② 사라진 프로세스는 잊는다. 세션 밖에 있고 루트가 끝났으면 세션 종료 시각을 적는다.
        var kept: [ProcessKey: Entry] = [:]
        kept.reserveCapacity(entries.count)
        var orphanKeys: [ProcessKey] = []
        for (key, value) in entries {
            guard let record = live(key) else { continue }
            if liveRoots.contains(key) && !value.subagent { continue }
            var entry = value
            if !underSession.contains(key) {
                Self.track(&entry, record, now: now, threshold: threshold)
                // 루트가 살아 있으면(세션 중에 떨어져 나간 데몬 등) 아직 고아가 아니다 — 세션이 끝나면 그때 대상이 된다.
                if live(entry.origin.sessionKey) == nil {
                    let ended = entry.origin.sessionEndedAt ?? now
                    entry.origin.sessionEndedAt = ended
                    if now.timeIntervalSince(ended) >= config.grace { orphanKeys.append(key) }
                }
            }
            kept[key] = entry
        }
        entries = kept

        // ③ 묶기: 부모가 같은 세션의 남은 프로세스면 그 묶음에 넣는다(맨 위 = 부모가 남은 프로세스가 아닌 것, 보통 launchd 바로 아래).
        let orphanSet = Set(orphanKeys)
        var groups: [ProcessKey: [ProcessKey]] = [:]
        for key in orphanKeys {
            guard let session = entries[key]?.origin.sessionKey else { continue }
            var top = key
            var depth = 0
            while depth < 64, let record = live(top), let parent = byPID[record.ppid], parent.pid > 1,
                  orphanSet.contains(parent.key), entries[parent.key]?.origin.sessionKey == session {
                top = parent.key
                depth += 1
            }
            groups[top, default: []].append(key)
        }
        var list: [OrphanHelper] = []
        var childMap: [Int32: [ProcRecord]]?
        for (top, keys) in groups {
            guard let topRecord = live(top), let topEntry = entries[top] else { continue }
            var members = [top] + keys.filter { $0 != top }.sorted()
            // 하위 에이전트가 맨 위면 그 아래 도구까지 한 묶음으로: 감지기가 그것을 '보조 호출' 세션 루트로 잡으면 도구들은 그 세션 소속이라
            // 고아 목록에 오르지 않는다(남겨 두면 일꾼만 끝나고 도구가 따로 남는다).
            if topEntry.subagent {
                if childMap == nil { childMap = Dictionary(grouping: records, by: \.ppid) }
                var queue = [top.pid]
                var seen = Set(members.map(\.pid))
                while let pid = queue.popLast() {
                    for child in childMap?[pid] ?? [] where seen.insert(child.pid).inserted {
                        members.append(child.key)
                        queue.append(child.pid)
                    }
                }
            }
            var labels: [(key: ProcessKey, kind: HelperKind, command: String)] = []
            var footprint: UInt64 = 0
            var cpu = 0.0
            var idleFor = TimeInterval.infinity
            var readable = true
            for key in members {
                guard let record = live(key) else { continue }
                footprint += record.footprint
                cpu += record.cpuPercent
                guard var entry = entries[key] else { continue }
                if entry.label == nil {
                    let argv = readArguments(key.pid) ?? []
                    let command = Redactor.redact((argv.isEmpty ? [record.path ?? record.name] : argv).joined(separator: " "))
                    entry.label = (HelperKind.classify(name: record.name, path: record.path, argv: argv), String(command.prefix(400)))
                    entries[key] = entry
                }
                labels.append((key, entry.label!.kind, entry.label!.command))
                readable = readable && entry.cpuReadable
                idleFor = min(idleFor, now.timeIntervalSince(entry.activeAt))
            }
            // 대표: 하위 에이전트가 맨 위면 그것, 맨 위가 구체적인 종류면 맨 위, 아니면 처음 나오는 구체적인 구성원.
            let representative = (topEntry.subagent ? labels.first { $0.key == top } : nil)
                ?? labels.first { $0.key == top && $0.kind != .other } ?? labels.first { $0.kind != .other } ?? labels.first
            guard let representative, let representativeRecord = live(representative.key) else { continue }
            let idleTime = readable && idleFor.isFinite ? max(0, idleFor) : 0
            var origin = topEntry.origin
            origin.workflowResidue = members.contains { entries[$0]?.subagent == true }
            list.append(OrphanHelper(top: top, members: members, kind: topEntry.subagent ? .workflowAgent : representative.kind, name: representativeRecord.displayName,
                                     path: topRecord.path, command: representative.command, footprint: footprint, cpuPercent: cpu, uid: topRecord.uid,
                                     parentPID: topRecord.ppid, startTime: topRecord.startTime, origin: origin, idleFor: idleTime,
                                     idle: readable && idleTime >= config.idleAfter, cpuReadable: readable))
        }
        orphanList = list.sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.top < $1.top }
    }

    static func origin(of session: AgentSession, now: Date) -> HelperOrigin {
        HelperOrigin(sessionKey: session.id, agent: session.kind, project: session.project, title: session.displayTitle, cwd: session.cwd,
                     firstSeen: now, lastSeen: now, sessionEndedAt: nil, terminalHost: session.terminalHost)
    }

    /// 세션 안에서 하위 에이전트로 뜬 에이전트 프로세스인가: Claude 헤드리스 실행(-p · --print).
    /// 대화형으로 뜬 안쪽 claude(바깥이 끝나면 스스로 세션이 되는 것)는 하위 에이전트가 아니다. 이름·경로가 claude일 때만 실행 인자를 읽는다.
    /// Codex·OpenCode의 일회성 실행은 감지기가 따로 세션 루트로 잡으므로 ①-2(isHeadlessRole)에서 본다.
    static func isHeadlessAgent(_ record: ProcRecord, arguments: (Int32) -> [String]?) -> Bool {
        let path = record.path ?? ""
        let versionNamed = record.name.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil
        guard record.name == "claude" || path.hasSuffix("/.local/bin/claude") || path.contains("/.local/share/claude/") || versionNamed else { return false }
        guard let argv = arguments(record.pid), let first = argv.first else { return false }
        if versionNamed, !(first == "claude" || first.hasSuffix("/claude") || first.hasPrefix("claude ")) { return false }
        return argv.dropFirst().contains { $0 == "-p" || $0 == "--print" }
    }

    /// 감지기가 붙인 역할로 본 헤드리스·일회성 실행(claude -p '보조 호출' · codex exec · opencode run · 표 에이전트의 일회성 실행).
    static func isHeadlessRole(_ session: AgentSession) -> Bool {
        session.role == SessionDetector.helperRole || session.role.hasPrefix("exec 일회성") || (session.kind == .opencode && session.role == "일회성")
    }

    /// CPU 시간 증가율이 문턱을 넘으면 '움직임' 시각을 갱신한다. 처음 본 시각이 첫 움직임이다(그 전은 모른다).
    private static func track(_ entry: inout Entry, _ record: ProcRecord, now: Date, threshold: Double) {
        entry.cpuReadable = record.memorySource == .kernel
        let wall = now.timeIntervalSince(entry.cpuAt)
        guard wall > 0 else { return }
        if record.cpuTimeNs < entry.cpuNs || Double(record.cpuTimeNs - entry.cpuNs) / 1e9 / wall * 100 > threshold { entry.activeAt = now }
        entry.cpuNs = record.cpuTimeNs
        entry.cpuAt = now
    }
}

// MARK: - 종료(SessionTerminator 흐름 + 신호 직전 신원 확인)

/// 신호 직전 신원 확인: pid가 살아 있고(좀비 아님) 시작 시각·실행 경로가 계획 때와 같아야 한다.
public enum HelperGuard {
    /// proc_pidpath, 비면(실행 파일이 지워진 경우 등) KERN_PROCARGS2의 실행 경로. 계획 때와 신호 직전에 같은 방법으로 읽는다.
    public static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if !path.isEmpty { return path }
        }
        if let executable = ProcessSampler.readArguments(pid: pid)?.executable, !executable.isEmpty { return executable }
        return nil
    }

    public static func matches(_ identity: HelperTerminator.Identity) -> Bool {
        // 경로를 읽는 사이 pid가 바뀌었을 수 있어 시작 시각을 앞뒤로 두 번 본다.
        guard SessionTerminator.isAlive(identity.key) else { return false }
        guard executablePath(pid: identity.key.pid) == identity.path else { return false }
        return SessionTerminator.isAlive(identity.key)
    }
}

/// 신호 기록(송신 클로저가 @Sendable이라 잠금으로 보호).
final class SignalLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var delivered: [(pid: Int32, signal: Int32)] = []
    private var refused: [(pid: Int32, signal: Int32)] = []

    func deliver(_ pid: Int32, _ signal: Int32) { lock.lock(); delivered.append((pid, signal)); lock.unlock() }
    func refuse(_ pid: Int32, _ signal: Int32) { lock.lock(); refused.append((pid, signal)); lock.unlock() }
    var deliveredPIDs: Set<Int32> { lock.lock(); defer { lock.unlock() }; return Set(delivered.map(\.pid)) }
    var refusedPIDs: Set<Int32> { lock.lock(); defer { lock.unlock() }; return Set(refused.map(\.pid)) }
    var refusalCount: Int { lock.lock(); defer { lock.unlock() }; return refused.count }
}

/// 남은 보조 프로세스 종료: 보호 규칙 → 맨 위 SIGTERM → 기다림 → 남은 것만 확인 후 SIGKILL(SessionTerminator 그대로).
/// 송신 직전마다 pid·시작 시각·실행 경로를 다시 확인해 재사용된 pid에는 보내지 않는다. 신호 전에 금고에 다시 띄울 기록(.process)을 먼저 남기고,
/// 못 남기면 끝내지 않는다. 복구함 '다시 띄우기'가 같은 폴더에서 같은 명령을 실행한다.
public final class HelperTerminator: @unchecked Sendable {
    /// 예전 판(금고에 기록만 남기던 때)의 안내 — 지난 기록(.deleted)에 남아 있다.
    public static let restoreHint = "에이전트가 다시 띄우면 생깁니다"
    public static let defaultReason = "남은 보조 프로세스 정리"
    /// 시스템 경로 실행 파일은 건드리지 않는다(/usr/local·/opt/homebrew는 사용자 도구라 제외하지 않음).
    public static let systemPrefixes = ["/System/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/usr/lib/", "/bin/", "/sbin/", "/Library/Apple/", "/private/var/db/"]
    static let hostMarks = ["/Orca.app/", "/orca/daemon-host/", "/Ghostty.app/", "/Terminal.app/", "/iTerm", "cmux", "/Visual Studio Code.app/", "/Cursor.app/",
                            "/ChatGPT.app/", "/Codex.app/", "/Claude.app/", "/Aside", "/ReMON.app/", "/Warp.app/"]
    static let agentNames: Set<String> = ["claude", "codex", "opencode", "opencode.exe"]

    public struct Identity: Sendable, Equatable {
        public var key: ProcessKey
        public var path: String
        public init(key: ProcessKey, path: String) {
            self.key = key
            self.path = path
        }
    }

    public struct Plan: Sendable {
        public var helper: OrphanHelper
        /// 신호 직전에 맞춰 볼 신원(살아 있는 구성원)
        public var identities: [Identity]
        /// SessionTerminator에 넘기는 계획(보호 규칙·미리보기 포함)
        public var base: SessionTerminator.Plan
        public var footprints: [ProcessKey: UInt64]
        public var sockets: [ListeningSocket]
        /// 다시 띄울 정보(맨 위 프로세스의 실행 파일 · 인자 · 폴더 · 정해진 환경 변수). 못 읽으면 nil이고 계획이 막힌다.
        public var launch: ProcessLaunch?
        public var blockers: [String] { base.blockers }
        public var warnings: [String] { base.warnings }
        public var preview: String { base.preview }
        public var reclaimEstimate: UInt64 { base.reclaimEstimate }
    }

    public struct Outcome: Sendable {
        /// ReMON이 신호를 보내 끝난 것
        public var terminated: [ProcessKey]
        /// 신호 없이 이미 끝나 있던 것(스스로 끝남·재사용 의심 — 회수량에 넣지 않는다)
        public var alreadyGone: [ProcessKey]
        public var remaining: [ProcessKey]
        /// 신원이 바뀌어 신호를 보내지 않은 것
        public var refused: [ProcessKey]
        public var reclaimed: UInt64
        public var killedRemaining: Bool
        public var dryRun: Bool
        public var blocked: Bool
        /// 금고(.process): 끝내기 직전 retiring → 끝나면 held. 신호를 하나도 보내지 않았으면 지우고 nil.
        public var entry: RecoveryEntry?
        /// 끝내지 않은 이유(금고에 먼저 적지 못함 등). 이때 신호는 0건이다.
        public var aborted: String? = nil
        public var message: String
    }

    public let registry: TerminationRegistry
    public var audit = AuditLog.shared
    public var waitSeconds: TimeInterval = 5
    /// 실제 신호 송신. 신원 확인을 통과한 뒤에만 불린다(시험에서 기록용으로 바꾼다).
    public var signalSender: @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }

    public init(registry: TerminationRegistry = TerminationRegistry()) {
        self.registry = registry
    }

    public func plan(_ helper: OrphanHelper, records: [ProcRecord], context: ProtectionContext = ProtectionContext(), now: Date = Date()) -> Plan {
        var byKey: [ProcessKey: ProcRecord] = [:]
        for record in records { byKey[record.key] = record }
        let members = helper.members.compactMap { byKey[$0] }.filter { SessionTerminator.isAlive($0.key) }
        var blockers: [String] = []
        var identities: [Identity] = []
        var environments: [Int32: [String: String]] = [:]
        if members.isEmpty { blockers.append("이미 끝난 프로세스입니다") }
        var residueAgents = 0
        for record in members {
            environments[record.pid] = ProcessSampler.readArguments(pid: record.pid)?.environment ?? [:]
            if record.uid == 0 { blockers.append("루트 소유 프로세스입니다(pid \(record.pid))") }
            else if record.uid != getuid() { blockers.append("다른 사용자 프로세스입니다(pid \(record.pid))") }
            guard let path = HelperGuard.executablePath(pid: record.pid) else {
                blockers.append("실행 파일 경로를 확인하지 못해 신원을 다시 확인할 수 없습니다(pid \(record.pid))")
                continue
            }
            identities.append(Identity(key: record.key, path: path))
            if Self.systemPrefixes.contains(where: path.hasPrefix) { blockers.append("시스템 경로 실행 파일입니다(\(path))") }
            if Self.hostMarks.contains(where: path.contains) { blockers.append("터미널·에이전트 앱입니다(\((path as NSString).lastPathComponent))") }
            if Self.agentNames.contains(record.name) || path.contains("/.local/share/claude/") || path.contains("/@openai/codex") {
                // 워크플로 잔재(주인 세션이 하위 에이전트로 띄운 헤드리스 실행)는 주인이 끝난 일꾼이라 보조 프로세스로 끝낸다 — 경고만.
                if helper.origin.workflowResidue { residueAgents += 1 } else { blockers.append("에이전트 본체입니다(세션으로 관리합니다)") }
            }
        }
        // 다시 띄울 정보는 계획 때 읽는다(확인 창에 명령을 보여 주고, 끝내기 직전 금고에 그대로 적는다). 못 읽으면 되살릴 방법이 없어 끝내지 않는다.
        var launch: ProcessLaunch?
        if let top = members.first(where: { $0.key == helper.top }) {
            launch = ProcessRecovery.capture(pid: top.pid)
            if !SessionTerminator.isAlive(top.key) { launch = nil }   // 읽는 사이 pid가 바뀌었으면 그 명령은 믿지 않는다
        }
        if !members.isEmpty, launch == nil { blockers.append("다시 띄울 명령(실행 인자)을 읽지 못했습니다 — 복구 기록 없이 끝내지 않습니다") }
        let footprint = members.reduce(UInt64(0)) { $0 + $1.footprint }
        let session = AgentSession(id: helper.top, kind: helper.origin.agent, role: helper.kind.label, rootPID: helper.top.pid, pids: members.map(\.pid),
                                   footprint: footprint, cpuPercent: members.reduce(0) { $0 + $1.cpuPercent }, startTime: helper.startTime,
                                   cwd: helper.origin.cwd, project: "\(helper.origin.project) · 남은 \(helper.kind.label)", state: .orphan)
        var base = SessionTerminator(registry: registry).plan(session: session, members: members, environments: environments, context: context,
                                                              pinKey: "helper|\(helper.top.pid)|\(helper.top.start)")
        var seen = Set<String>()
        base.blockers = (base.blockers + blockers).filter { seen.insert($0).inserted }

        // 경고(종료는 가능): 포트를 열고 있음 · 아직 쉬는 중이 아님. 세션용 경고(이어 열기 등)는 보조 프로세스에 맞지 않아 쓰지 않는다.
        let sockets = members.flatMap { ListeningSockets.list(pid: $0.pid) ?? [] }
        var warnings: [String] = []
        let exposed = sockets.filter { !$0.isLoopback }
        if !exposed.isEmpty {
            warnings.append("외부 인터페이스에서 포트를 열고 있습니다(\(exposed.prefix(3).map(\.display).joined(separator: ", "))) · 다른 기기가 접속 중일 수 있습니다")
        }
        let local = sockets.filter { $0.isLoopback && $0.proto == .tcp }
        if !local.isEmpty { warnings.append("로컬 포트를 열고 있습니다(\(local.prefix(3).map(\.display).joined(separator: ", "))) · 브라우저나 다른 도구가 쓰는 중일 수 있습니다") }
        if !helper.cpuReadable {
            warnings.append("CPU 사용을 읽지 못해 쉬는 중인지 모릅니다")
        } else if !helper.idle {
            warnings.append(helper.cpuPercent >= 1 ? "지금 CPU \(Fmt.percent(helper.cpuPercent))를 쓰고 있습니다" : "아직 쉬는 중이 아닙니다(마지막 CPU 사용 \(Self.since(helper.idleFor)))")
        }
        if residueAgents > 0 { warnings.append("주인 세션이 끝난 뒤 남은 워크플로 에이전트(헤드리스 실행)입니다 · 끝내도 대화 기록 파일은 지우지 않습니다") }
        if let launch, launch.masked > 0 { warnings.append("명령의 비밀값 \(launch.masked)개를 가려 적습니다 — 다시 띄울 때 직접 채워야 할 수 있습니다") }
        base.warnings = warnings
        let ended = helper.origin.sessionEndedAt.map { Fmt.ago($0, now: now) } ?? "방금"
        var lines = [
            "대상: \(helper.kind.label) · \(helper.name) · pid \(helper.top.pid)" + (members.count > 1 ? " 외 \(members.count - 1)개" : ""),
            "원래 세션: \(helper.origin.label) · \(ended) 종료 · ReMON이 세션 하위로 직접 본 프로세스",
            "회수될 메모리(추정): \(Fmt.size(footprint))" + (helper.cpuReadable ? " · 마지막 CPU 사용 \(Self.since(helper.idleFor))" : ""),
            "명령: \(helper.command.prefix(160))"
        ]
        if let launch { lines.append("다시 띄우기(복구함): " + (launch.cwd.map { "cd \(ResumeKey.quote($0)) && " } ?? "") + launch.command.map(ResumeKey.quote).joined(separator: " ").prefix(220)) }
        base.preview = lines.joined(separator: "\n")
        return Plan(helper: helper, identities: identities, base: base, footprints: Dictionary(uniqueKeysWithValues: members.map { ($0.key, $0.footprint) }),
                    sockets: sockets, launch: launch)
    }

    /// confirmKill: SIGTERM 뒤 waitSeconds가 지나도 남은 것을 SIGKILL로 끝낼지(SessionTerminator와 같은 규칙).
    public func execute(_ plan: Plan, dryRun: Bool, vault: RecoveryVault?, reason: String = HelperTerminator.defaultReason,
                        confirmKill: @escaping @Sendable ([ProcessKey]) -> Bool) -> Outcome {
        let helper = plan.helper
        let target = "\(helper.kind.label) pid \(helper.top.pid) · \(helper.origin.label)"
        let keys = plan.identities.map(\.key)
        guard plan.blockers.isEmpty else {
            audit.write(action: "helper.terminate", target: target, result: "blocked: " + plan.blockers.joined(separator: "; "), dryRun: dryRun)
            return Outcome(terminated: [], alreadyGone: [], remaining: keys, refused: [], reclaimed: 0, killedRemaining: false, dryRun: dryRun, blocked: true,
                           entry: nil, message: "보호 대상이라 종료하지 않았습니다: " + plan.blockers.joined(separator: ", "))
        }
        if dryRun {
            audit.write(action: "helper.terminate", target: target, bytes: plan.reclaimEstimate, result: "dry-run", dryRun: true, detail: ["pids": keys.map { Int($0.pid) }])
            return Outcome(terminated: [], alreadyGone: [], remaining: keys, refused: [], reclaimed: 0, killedRemaining: false, dryRun: true, blocked: false,
                           entry: nil, message: "드라이런: \(helper.kind.label) \(keys.count)개를 종료하면 약 \(Fmt.size(plan.reclaimEstimate))를 회수합니다")
        }
        func abort(_ why: String) -> Outcome {
            audit.write(action: "helper.terminate", target: target, result: "skipped: " + why, dryRun: false)
            return Outcome(terminated: [], alreadyGone: [], remaining: keys, refused: [], reclaimed: 0, killedRemaining: false, dryRun: false, blocked: false,
                           entry: nil, aborted: why, message: "끝내지 않았습니다 · \(why)")
        }
        // 1) 금고에 먼저 적는다(다시 띄울 명령 · 폴더 · 출신 · 메모리). 못 적으면 끝내지 않는다 — 세션과 같은 금고 먼저(fail-closed).
        guard let vault else { return abort("복구 금고가 없어 다시 띄울 기록을 남길 수 없습니다") }
        guard let launch = plan.launch else { return abort("다시 띄울 명령을 읽지 못했습니다") }
        let recorded = ProcessRecovery.helperEntry(helper, launch: launch, reason: reason, status: .retiring)
        do { try vault.add(recorded) } catch { return abort("복구 금고에 기록하지 못했습니다(\(error.localizedDescription))") }

        // 2) 종료(보호 규칙 → 맨 위 SIGTERM → 기다림 → 남은 것만 확인 후 SIGKILL). 송신 직전마다 신원을 다시 확인한다.
        let ledger = SignalLedger()
        let identities = Dictionary(plan.identities.map { ($0.key.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let send = signalSender
        let terminator = SessionTerminator(registry: registry)
        terminator.audit = audit
        terminator.waitSeconds = waitSeconds
        terminator.signalSender = { pid, signal in
            guard let identity = identities[pid], HelperGuard.matches(identity) else {
                ledger.refuse(pid, signal)
                return -1
            }
            let result = send(pid, signal)
            if result == 0 { ledger.deliver(pid, signal) }
            return result
        }
        let base = terminator.execute(plan.base, dryRun: false, force: false, footprints: plan.footprints, confirmKill: confirmKill)

        let delivered = ledger.deliveredPIDs
        let topSignalled = delivered.contains(helper.top.pid)
        let remaining = keys.filter(SessionTerminator.isAlive)
        let gone = keys.filter { !remaining.contains($0) }
        // 맨 위에 신호를 보냈으면 함께 끝난 하위도 ReMON이 끝낸 것으로 본다.
        let terminated = gone.filter { topSignalled || delivered.contains($0.pid) }
        let alreadyGone = gone.filter { !terminated.contains($0) }
        let refusedPIDs = ledger.refusedPIDs
        let refused = remaining.filter { refusedPIDs.contains($0.pid) }
        let reclaimed = terminated.reduce(UInt64(0)) { $0 + (plan.footprints[$1] ?? 0) }

        // 3) 금고 반영: 신호를 하나도 보내지 않았으면(신원이 바뀜 · 이미 끝남) ReMON이 끝낸 것이 없으니 기록을 지운다.
        //    다 끝났으면 보관(held · 끝난 방식 · 실제 회수량). 신호를 보냈는데 아직 남았으면 종료 대기로 두고 settleRetiring이 나중에 보관으로 바꾼다.
        var entry: RecoveryEntry?
        if delivered.isEmpty {
            try? vault.remove(recorded.id)
        } else if remaining.isEmpty {
            try? vault.update(recorded.id) { stored in
                stored.status = .held
                stored.bytes = reclaimed > 0 ? reclaimed : stored.bytes
                stored.exitReason = base.killedRemaining ? "SIGTERM에 끝나지 않아 SIGKILL로 종료" : "SIGTERM으로 종료"
                stored.note = (stored.note.map { $0 + " · " } ?? "") + "종료 확인"
            }
            entry = vault.entry(recorded.id)
        } else {
            try? vault.update(recorded.id) { $0.note = ($0.note.map { $0 + " · " } ?? "") + "종료 신호 보냄 · 아직 \(remaining.count)개 남음" }
            entry = vault.entry(recorded.id)
        }
        let result = !refused.isEmpty ? "refused" : (!remaining.isEmpty ? "partial" : (terminated.isEmpty ? "already-gone" : "ok"))
        audit.write(action: "helper.terminate", target: target, bytes: reclaimed, result: result, dryRun: false,
                    detail: ["kind": helper.kind.rawValue, "session": helper.origin.label, "terminated": terminated.map { Int($0.pid) },
                             "remaining": remaining.map { Int($0.pid) }, "refused": refused.map { Int($0.pid) }, "already_gone": alreadyGone.map { Int($0.pid) },
                             "sigkill_remaining": base.killedRemaining, "guard_refusals": ledger.refusalCount])
        var parts: [String] = []
        if !terminated.isEmpty { parts.append("\(helper.kind.label) \(terminated.count)개 종료 · 약 \(Fmt.size(reclaimed)) 회수" + (entry != nil ? " · 복구함에서 다시 띄우기" : "")) }
        if !refused.isEmpty { parts.append("신원이 바뀐 프로세스 \(refused.count)개는 건드리지 않았습니다(pid 재사용 방지)") }
        else if !remaining.isEmpty { parts.append("\(remaining.count)개 프로세스가 남아 있습니다") }
        if terminated.isEmpty && remaining.isEmpty { parts.append("이미 끝난 프로세스입니다(신호를 보내지 않음)") }
        return Outcome(terminated: terminated, alreadyGone: alreadyGone, remaining: remaining, refused: refused, reclaimed: reclaimed,
                       killedRemaining: base.killedRemaining, dryRun: false, blocked: false, entry: entry, message: parts.joined(separator: " · "))
    }

    static func since(_ seconds: TimeInterval) -> String { seconds < 60 ? "방금" : "\(Fmt.duration(seconds)) 전" }
}

// MARK: - 관찰 이력 없는 추정 고아

/// 부모가 launchd인 사용자 개발 서버(npm run dev · vite · next dev 등)가 1시간 넘게 돌고 있으면 '추정 고아'로 보여 준다.
/// ReMON이 세션 하위로 본 적이 없으므로(앱을 켜기 전에 남았거나 직접 띄운 서버) 자동 정리에는 넣지 않는다 —
/// 목록 · '왜 실행 중?' · 확인을 받는 수동 멈추기만(10-25 Mole 실측: 2일 넘게 남은 npm run dev + vite 5188 포트).
public enum SuspectedOrphanScanner {
    /// 표시용 출처(대화 세션이 없으므로 '관찰 이력 없음').
    public static let unobserved = AgentKind.custom(id: "custom.관찰 이력 없음", name: "관찰 이력 없음")

    public static func scan(records: [ProcRecord], exclude: Set<Int32>, minAge: TimeInterval = 3600, now: Date = Date()) -> [OrphanHelper] {
        var children: [Int32: [ProcRecord]] = [:]
        for record in records { children[record.ppid, default: []].append(record) }
        let me = getuid()
        var result: [OrphanHelper] = []
        for record in records where record.ppid == 1 && record.uid == me && !exclude.contains(record.pid) && now.timeIntervalSince(record.startTime) >= minAge {
            let argv = ProcessSampler.readArguments(pid: record.pid)?.argv ?? []
            guard HelperKind.classify(name: record.name, path: record.path, argv: argv) == .devServer else { continue }
            var members = [record], queue = [record.pid]
            while let pid = queue.popLast() { for child in children[pid] ?? [] { members.append(child); queue.append(child.pid) } }
            let cwd = ProcessExplainer.workingDirectory(record.pid)
            let origin = HelperOrigin(sessionKey: ProcessKey(pid: 0, start: 0), agent: unobserved, project: cwd.map { SessionDetector.projectName(for: $0) } ?? "?",
                                      title: "관찰 이력 없음", cwd: cwd, firstSeen: record.startTime, lastSeen: record.startTime, sessionEndedAt: nil)
            let cpu = members.reduce(0.0) { $0 + $1.cpuPercent }
            result.append(OrphanHelper(top: record.key, members: members.map(\.key), kind: .devServer, name: record.displayName, path: record.path,
                                       command: Redactor.redact(argv.joined(separator: " ")), footprint: members.reduce(0) { $0 + $1.footprint }, cpuPercent: cpu,
                                       uid: record.uid, parentPID: record.ppid, startTime: record.startTime, origin: origin,
                                       idleFor: 0, idle: cpu < 0.5, cpuReadable: true))
        }
        return result.sorted { $0.startTime < $1.startTime }
    }
}
