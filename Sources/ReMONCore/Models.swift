import Foundation

/// AI 에이전트 종류 = 사무실의 팀. 기본 6종 + 서명 표(AgentSignatures)의 에이전트 + 사용자가 직접 추가한 에이전트.
/// 종류가 표에서 늘어도 화면은 종류마다 분기하지 않는다 — 이름·짧은 이름·후드 색을 종류가 들고 다닌다.
/// 예전 열거형과 같은 모양으로 쓴다(.claudeCode 비교·switch·rawValue·allCases). switch에는 default가 필요하다.
/// 같음·해시·저장(Codable)은 rawValue로만 본다.
public struct AgentKind: RawRepresentable, Hashable, Codable, Sendable, CaseIterable {
    public let rawValue: String
    /// 표시 이름("Gemini CLI")
    public let name: String
    /// 이름표·목록용 짧은 이름("Gemini")
    public let shortName: String
    /// 사무실 후드 색(0xRRGGBB)
    public let color: UInt32

    init(id: String, name: String, shortName: String, color: UInt32) {
        self.rawValue = id
        self.name = name
        self.shortName = shortName
        self.color = color
    }

    /// 아는 종류(기본·서명 표)와 직접 추가한 종류(custom.…)만 만든다. 모르는 값은 nil(예전 열거형과 같다).
    public init?(rawValue: String) {
        if let known = Self.registry[rawValue] {
            self = known
        } else if rawValue.hasPrefix(Self.customPrefix), rawValue.count > Self.customPrefix.count {
            self = Self.custom(id: rawValue, name: String(rawValue.dropFirst(Self.customPrefix.count)))
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let kind = AgentKind(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "알 수 없는 에이전트 종류 \(raw)"))
        }
        self = kind
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func == (lhs: AgentKind, rhs: AgentKind) -> Bool { lhs.rawValue == rhs.rawValue }
    public func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    public static let claudeCode = AgentKind(id: "claudeCode", name: "Claude Code", shortName: "Claude", color: 0xE8735A)
    public static let codexCLI = AgentKind(id: "codexCLI", name: "Codex CLI", shortName: "Codex", color: 0x2BA59B)
    public static let codexDesktop = AgentKind(id: "codexDesktop", name: "Codex Desktop", shortName: "Codex 앱", color: 0x3FA34D)
    public static let cursor = AgentKind(id: "cursor", name: "Cursor", shortName: "Cursor", color: 0x5B7BD5)
    public static let aside = AgentKind(id: "aside", name: "Aside", shortName: "Aside", color: 0x9C7AD8)
    public static let opencode = AgentKind(id: "opencode", name: "OpenCode", shortName: "OpenCode", color: 0xD9A441)

    /// 전용 규칙으로 감지하는 기본 종류(앱 묶음 3종 포함).
    public static let builtIns: [AgentKind] = [.claudeCode, .codexCLI, .codexDesktop, .cursor, .aside, .opencode]
    /// 기본 종류 + 서명 표의 종류(직접 추가한 종류는 설정마다 달라 빠진다).
    public static var allCases: [AgentKind] { builtIns + AgentSignatures.generic.map(\.kind) }
    private static let registry: [String: AgentKind] = Dictionary(allCases.map { ($0.rawValue, $0) }, uniquingKeysWith: { first, _ in first })

    public static let customPrefix = "custom."
    /// 사용자가 직접 추가한 에이전트. 색은 id에서 고른다(같은 에이전트는 늘 같은 색).
    public static func custom(id: String, name: String) -> AgentKind {
        let palette: [UInt32] = [0x8E8CD8, 0x5FB0A8, 0xC97B9B, 0x9DA65B, 0x6F9BD1, 0xC28F5C]
        let index = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count
        let label = name.isEmpty ? "직접 추가" : name
        return AgentKind(id: id, name: label, shortName: label, color: palette[index])
    }

    public var label: String { name }
    public var teamName: String { (self == .codexCLI ? "Codex" : name) + "팀" }
    /// 서명 표나 직접 추가로 들어온 종류(기본 6종이 아님). 기록 형식·이어 열기 키를 모른다.
    public var isGeneric: Bool { !Self.builtIns.contains(self) }
    public var isCustom: Bool { rawValue.hasPrefix(Self.customPrefix) }
}

/// 사양 4장 상태. 판정 근거 문자열을 함께 둔다.
/// 상태 판정이 무엇에 기댔는가. confirmed = 커널·레지스트리·기록 파일 시각 등 직접 증거 / estimated = CPU 패턴·실행 시간·제목 등 정황.
public enum StateConfidence: String, Codable, Sendable {
    case confirmed, estimated

    public var label: String { self == .confirmed ? "확인" : "추정" }
}

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case working, waiting, idle, longIdle, orphan

    public var label: String {
        switch self {
        case .working: "일하는 중"
        case .waiting: "기다림"
        case .idle: "쉼"
        case .longIdle: "오래 쉼"
        case .orphan: "고아"
        }
    }

    public var isResting: Bool { self == .idle || self == .longIdle }
}

public struct AgentSession: Identifiable, Sendable, Equatable {
    /// 잠깐 왔다 가는 세션(헤드리스 보조 호출·임시 폴더). 출근·퇴근 연출·기록·자동 줌을 하지 않는다.
    public var isEphemeral: Bool { role == SessionDetector.helperRole || project == "임시" }
    /// 이 세션 안에서 일하는 하위 에이전트(서브에이전트·워크플로·Codex 하위 스레드). 로봇으로 그린다.
    public var subagents: [SubagentInfo] = []
    /// Orca 탭 상태: 열림 · 닫힘(고아 PTY, 프로세스만 남음) · Orca가 모름(이전 실행 잔재) · Orca 밖.
    public enum TabState: String, Sendable { case open, closed, unknown, outside }
    public var tabState: TabState = .outside
    /// 탭이 닫혔는데 남은 세션(정리 대상)
    /// Orca가 그 탭을 닫힌 것(orphaned)으로 알려 준 경우만 잔재다. '목록에서 못 찾음'(unknown)은 짝짓기 추정이 빗나간 것일 수 있어
    /// 잔재·고아로 보지 않는다(10-25 사고: 백그라운드 세션을 보던 Claude 창이 탭을 빼앗겨 '이전 실행 잔재'로 몰려 종료됨).
    public var tabLeftover: Bool { tabState == .closed }
    /// Orca 아래서 도는데 Orca 목록에서 짝을 못 찾음(표시만).
    public var tabUnknown: Bool { tabState == .unknown }
    public var activeSubagents: Int { subagents.filter(\.active).count }
    /// Codex 0.163+ 공유 데몬 모드 클라이언트(--no-daemon 없이 실행, rollout은 데몬이 쥔다). 기록 연결과 이어 열기 키가 추정이다.
    public var codexDaemonClient: Bool = false
    /// 이어 열기 키를 믿어도 되는가: 명령이 있고 · 기록 연결이 정확하고(추정 아님) · 데몬 클라이언트가 아니다.
    /// 표·직접 추가 에이전트는 이어 열기 키가 없어 늘 false다(복구 시스템이 자동 정리하지 않게).
    public var resumeKeyVerified: Bool { resumeCommand != nil && !logLinkIsEstimate && !codexDaemonClient && !kind.isGeneric }

    public var id: ProcessKey
    public var kind: AgentKind
    public var role: String
    public var rootPID: Int32
    public var pids: [Int32]
    public var childCount: Int
    public var footprint: UInt64
    public var cpuPercent: Double
    public var startTime: Date
    public var cwd: String?
    public var project: String
    public var title: String?
    public var titleSource: String
    public var logPath: String?
    public var extraLogPaths: [String] = []
    public var logLinkIsEstimate: Bool
    public var lastActivity: Date?
    public var state: SessionState
    public var stateReason: String
    public var resumeCommand: String?
    public var parentSession: ProcessKey?
    public var terminalHost: String?
    public var command: String
    public var orcaHandle: String? = nil
    /// 끝난 뒤에는 실행 인자·Claude 레지스트리를 더 읽을 수 없다 → 감지할 때 담아 둔다(스스로 끝난 세션의 복구 키용).
    public var launchArgv: [String] = []
    public var registrySessionID: String? = nil
    public var registryKind: String? = nil
    /// 상태 판정의 증거 등급. 묶음·자동 조치는 '확인'만 다룬다(10-25 사고: 추정 상태 위에서 세션이 종료됨).
    public var stateConfidence: StateConfidence = .estimated
    /// 세션 자원 — 컨텍스트(마지막 호출 기준 토큰) · 모델 창 크기 · 누적 토큰 · 기록 파일 크기. 기록에서 읽는다(없으면 nil).
    public var contextTokens: Int? = nil
    public var contextWindow: Int? = nil
    public var totalTokens: Int? = nil
    public var transcriptBytes: UInt64? = nil
    /// 컨텍스트 점유율 0~1(창 크기를 알 때만).
    public var contextFill: Double? {
        guard let contextTokens, let contextWindow, contextWindow > 0 else { return nil }
        return min(1, Double(contextTokens) / Double(contextWindow))
    }

    public var displayTitle: String { title ?? "제목 없음" }
}

/// 세션이 아닌 앱 묶음(.app 번들 단위) 또는 시스템 묶음.
public struct AppGroup: Identifiable, Sendable, Equatable {
    public enum Category: String, Codable, Sendable { case app, agentApp, host, system, other }
    public var id: String
    public var name: String
    public var category: Category
    public var agentKind: AgentKind?
    public var pids: [Int32]
    public var footprint: UInt64
    public var cpuPercent: Double
    public var memorySourceNote: String?

    public init(id: String, name: String, category: Category, agentKind: AgentKind?, pids: [Int32], footprint: UInt64, cpuPercent: Double, memorySourceNote: String? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.agentKind = agentKind
        self.pids = pids
        self.footprint = footprint
        self.cpuPercent = cpuPercent
        self.memorySourceNote = memorySourceNote
    }
}

/// 사무실 사건 — 연출과 사건 기록의 공통 입력.
public struct OfficeEvent: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case arrived(ProcessKey)
        case departed(ProcessKey, DepartureReason)
        case stateChanged(ProcessKey, from: SessionState, to: SessionState)
        case pressureChanged(from: PressureLevel, to: PressureLevel)
        case swapMoved(deltaBytes: Int64)
        case diskLow(availableBytes: UInt64)
        case diskRecovered(availableBytes: UInt64)
        case cleanup(reclaimedBytes: UInt64, summary: String)
        /// 파일·부산물 청소(캐시·워크트리·브랜치) — 청소 인력이 맡는다. project가 있으면 그 방으로 간다.
        case tidy(reclaimedBytes: UInt64, project: String?, items: Int)
        case cpuSpike(ProcessKey, percent: Double)
    }

    public var id = UUID()
    public var time: Date
    public var kind: Kind
    public var text: String
    public var sessionSnapshot: AgentSession?

    public init(time: Date = Date(), kind: Kind, text: String, sessionSnapshot: AgentSession? = nil) {
        self.time = time
        self.kind = kind
        self.text = text
        self.sessionSnapshot = sessionSnapshot
    }
}

public enum DepartureReason: String, Sendable, Codable {
    case left          // 스스로 종료(또는 외부 종료 — 사유를 알 수 없으면 퇴근으로 본다)
    case releasedByReMON   // ReMON이 SIGTERM으로 정리
    case evictedByReMON    // ReMON이 강제 종료(SIGKILL·forceTerminate)
}

public struct OfficeSnapshot: Sendable {
    public var time: Date
    public var system: SystemSnapshot
    public var sessions: [AgentSession]
    public var apps: [AppGroup]
    public var processCount: Int
    public var unaccountedMemory: UInt64
    public var standbyClaudeSpares: Int
    public var processes: [ProcRecord]

    public init(time: Date, system: SystemSnapshot, sessions: [AgentSession], apps: [AppGroup], processCount: Int, unaccountedMemory: UInt64, standbyClaudeSpares: Int, processes: [ProcRecord] = []) {
        self.processes = processes
        self.time = time
        self.system = system
        self.sessions = sessions
        self.apps = apps
        self.processCount = processCount
        self.unaccountedMemory = unaccountedMemory
        self.standbyClaudeSpares = standbyClaudeSpares
    }

    public var workingCount: Int { sessions.filter { $0.state == .working || $0.state == .waiting }.count }
    public var restingCount: Int { sessions.filter { $0.state.isResting || $0.state == .orphan }.count }
}

// 본문에 초기화를 두면 멤버별 초기화가 사라지므로 확장에 둔다.
extension AgentSession {
    /// 시험·더미용 공개 초기화.
    public init(id: ProcessKey, kind: AgentKind, role: String = "대화형", rootPID: Int32, pids: [Int32], footprint: UInt64 = 0, cpuPercent: Double = 0,
                startTime: Date = Date(), cwd: String? = nil, project: String = "시험", state: SessionState = .waiting, lastActivity: Date? = nil) {
        self.id = id
        self.kind = kind
        self.role = role
        self.rootPID = rootPID
        self.pids = pids
        self.childCount = max(0, pids.count - 1)
        self.footprint = footprint
        self.cpuPercent = cpuPercent
        self.startTime = startTime
        self.cwd = cwd
        self.project = project
        self.title = nil
        self.titleSource = "시험"
        self.logPath = nil
        self.logLinkIsEstimate = false
        self.lastActivity = lastActivity
        self.state = state
        self.stateReason = "시험"
        self.resumeCommand = nil
        self.parentSession = nil
        self.terminalHost = nil
        self.command = ""
    }
}
