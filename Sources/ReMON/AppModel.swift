import AppKit
import Combine
import ReMONCore
import ServiceManagement

/// 메뉴 막대 수치로 고를 수 있는 항목.
enum MenuMetric: String, CaseIterable, Identifiable, Codable {
    case cpu, memory, swap, disk, sessions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "메모리 여유"
        case .swap: "스왑"
        case .disk: "디스크 여유"
        case .sessions: "일하는 세션"
        }
    }
}

/// 사용자 설정(UserDefaults). 보호 고정은 재시작 뒤에도 유지되도록 작업 폴더·기록 파일로 기억한다.
final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var menuMetrics: [MenuMetric] { didSet { defaults.set(menuMetrics.map(\.rawValue), forKey: "menuMetrics") } }
    @Published var diskThresholdGB: Double { didSet { defaults.set(diskThresholdGB, forKey: "diskThresholdGB") } }
    @Published var dryRun: Bool { didSet { defaults.set(dryRun, forKey: "dryRun") } }
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin") } }
    @Published var pinnedSessions: Set<String> { didSet { defaults.set(Array(pinnedSessions), forKey: "pinnedSessions") } }
    /// 상황별 연출(출근·퇴출·트레이너·청소·과열)이 생기면 카메라가 그 자리로 다가갔다가 돌아온다.
    @Published var autoZoom: Bool { didSet { defaults.set(autoZoom, forKey: "autoZoom") } }
    /// 감사 판정에 쓰는 모델(로그인된 Claude CLI의 --model). 대표 지시(10-24): Opus.
    @Published var auditModel: String { didSet { defaults.set(auditModel, forKey: "auditModel") } }
    /// 재교육 때 터미널에 보내는 지시.
    @Published var reeducationMessage: String { didSet { defaults.set(reeducationMessage, forKey: "reeducationMessage") } }
    /// 메모리 압박 때 정리 가능한 세션을 알린다. 종료는 사용자가 목록을 확인한 뒤 결정한다.
    @Published var autoMemoryCleanup: Bool { didSet { defaults.set(autoMemoryCleanup, forKey: "autoMemoryCleanup") } }
    @Published var showRightSidebar: Bool { didSet { defaults.set(showRightSidebar, forKey: "showRightSidebar") } }
    /// 정리한 세션의 복구 키·기록 보관본을 두는 기간(일). 지나면 보관본을 지운다.
    @Published var recoveryRetentionDays: Double { didSet { defaults.set(recoveryRetentionDays, forKey: "recoveryRetentionDays") } }

    init() {
        menuMetrics = (defaults.stringArray(forKey: "menuMetrics") ?? ["cpu", "memory"]).compactMap(MenuMetric.init(rawValue:))
        diskThresholdGB = defaults.object(forKey: "diskThresholdGB") as? Double ?? 15
        dryRun = defaults.bool(forKey: "dryRun")
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        pinnedSessions = Set(defaults.stringArray(forKey: "pinnedSessions") ?? [])
        autoZoom = defaults.object(forKey: "autoZoom") as? Bool ?? true
        auditModel = defaults.string(forKey: "auditModel") ?? "opus"
        // 이제 '자동 정리'가 아니라 '정리 가능 알림'이다(세션을 끝내는 결정은 사람이). 알림은 기본 켬.
        autoMemoryCleanup = defaults.object(forKey: "autoMemoryCleanup") as? Bool ?? true
        reeducationMessage = defaults.string(forKey: "reeducationMessage") ?? "지금까지 한 일을 세 줄로 보고하고, 남은 작업을 이어서 끝내라."
        showRightSidebar = defaults.object(forKey: "showRightSidebar") as? Bool ?? true
        recoveryRetentionDays = defaults.object(forKey: "recoveryRetentionDays") as? Double ?? 30
    }

    /// 예전 형식(기록 파일 → 작업 폴더 → pid). 규칙은 SessionPins(핵심 모듈, 검사 대상)에 있다.
    static func pinKey(_ session: AgentSession) -> String { SessionPins.legacyKey(session) }
}

/// 층 안내판 한 줄: 장면이 건물 배치와 세션으로 만든다.
struct FloorSummary: Identifiable, Equatable {
    enum Kind: Equatable { case roof, team, hall, lobby, machines }
    let id: Int          // 건물 층 번호(0 = 기계실)
    let kind: Kind
    let title: String
    let subtitle: String
    let focus: OfficeFocus
    var people: Int = 0
    var working: Int = 0
    var waiting: Int = 0
    var warn = false
}

/// 창 왼쪽 내비게이션: 사무실(그래픽) · 대시보드(카드) · 정리.
enum OfficePage: String, CaseIterable, Identifiable {
    case office = "사무실", dashboard = "대시보드", cleanup = "정리", diskMap = "디스크 지도"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .office: "building.2"
        case .dashboard: "square.grid.2x2"
        case .cleanup: "sparkles"
        case .diskMap: "square.grid.3x3.square"
        }
    }
}

/// 사무실 카메라가 보고 있는 곳. 방 탭과 장면이 함께 쓴다.
enum OfficeFocus: Hashable {
    case all
    case room(String)
    case region(OfficeRegion)
    /// 건물 층 번호(0 = 기계실). 한 층 단위 보기.
    case floor(Int)

    var label: String {
        switch self {
        case .all: "전체"
        case .room(let name): name
        case .region(let region): region.label
        case .floor(let index): "\(index)층"
        }
    }

    var isFloor: Bool { if case .floor = self { true } else { false } }
}

/// 방이 아닌 고정 구역. 사람(에이전트)·도구(앱)·기계(CPU·RAM·디스크)를 나눠 둔다.
enum OfficeRegion: String, CaseIterable, Hashable {
    case situationRoom, machineRoom, lobby, toolRoom, hall, rooftop
    var label: String {
        switch self {
        case .situationRoom: "상황실"
        case .lobby: "로비"
        case .toolRoom: "도구실"
        case .machineRoom: "기계실"
        case .hall: "대기실"
        case .rooftop: "옥상"
        }
    }
}

/// 기계실의 기계(도구가 아닌 하드웨어 자원).
enum MachineKind: String, CaseIterable, Identifiable {
    case cpu, ram, disk, swap, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cpu: "CPU 엔진"
        case .ram: "RAM 탱크"
        case .disk: "디스크 저장고"
        case .swap: "스왑 창고"
        case .system: "시스템 랙"
        }
    }
}

struct EventLogEntry: Identifiable, Equatable {
    enum Tone { case arrive, leave, evict, trainer, alert, info, cleanup }
    let id = UUID()
    let time: Date
    let tone: Tone
    let text: String
    /// 누르면 이동할 대상(살아 있으면 그 세션·앱을 고른다).
    var sessionKey: ProcessKey? = nil
    var appID: String? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published var system = SystemSnapshot()
    @Published var office: OfficeSnapshot?
    @Published var log: [EventLogEntry] = []
    @Published var history: [HistoryPoint] = []
    @Published var selectedSession: ProcessKey?
    @Published var selectedApp: String?
    @Published var suggestions: [CleanupSuggestion] = []
    @Published var diskItems: [DiskItem] = []
    @Published var diskScanning = false
    @Published var diskScannedAt: Date?
    @Published var migrations: [ExternalMigrator.Record] = []
    @Published var lastActionMessage: String?
    /// 에이전트 부산물(워크트리·브랜치) 조사 결과.
    @Published var leftovers: [ProjectLeftovers] = []
    @Published var leftoversScanning = false
    @Published var leftoversScannedAt: Date?
    @Published var leftoversNote: String?
    @Published var auditRunning = false
    @Published var lastAudit: AuditReport?
    @Published var auditReportPresented = false
    /// 판정을 기다리는 동안만 있다(버튼에 경과 시간 · 누르면 취소). 판정이 오면 비운다 — 조치 중에는 취소하지 않는다.
    @Published var auditJudging: AuditJudging?
    /// 위험 감지 패널: 지금 도는 최적화와 마지막 결과(버튼 아래 한 줄). 누르면 반드시 무언가 보이게 한다(10-25 '눌러도 반응이 없어').
    @Published var optimizeBusy: OptimizeKind?
    @Published var optimizeNotes: [OptimizeKind: OptimizeNote] = [:]
    /// 프로젝트(방)마다 쌓인 서류(커밋·푸시·배포)와 치울 것(부산물·캐시). 사이드바 '청소하기'의 근거.
    @Published var projectGarbage: [String: ProjectGarbage] = [:]
    @Published var projectCleaning: Set<String> = []
    /// 방마다 쌓인 짐(워크트리·브랜치·서류) — 장면이 책상 서류 → 상자 → 벽 쌓기로 그린다.
    @Published var roomClutter: [String: RoomClutter] = [:]
    /// 최근 1시간의 git 사건(대사·축하용).
    var recentGitEvents: [GitEvent] = []
    /// 디스크 지도 조사 결과의 꼬리표별 합계(지도 가게가 채운다). nil이면 캐시 조사 등 지금 아는 자료로 구성한다.
    @Published var diskMapComposition: [DiskCompositionRow]?
    /// 디스크 지도(구조 탐색·조치). 페이지를 옮겨도 상태가 남도록 모델이 들고 있다.
    let diskMap = DiskMapStore()
    private var diskMapObserver: AnyCancellable?
    var diskMapObservers: [AnyCancellable] = []
    /// 재고 조사 실측 기준점(조치 직전 디스크 여유) · 마지막으로 연출에 알린 체크 상태.
    var inventoryFreeBefore: UInt64?
    var lastInventoryChecked: Set<String> = []
    let gitWatcher = GitEventWatcher(projectName: { SessionDetector.projectName(for: $0) })
    /// 상황실 사장을 눌렀을 때: '대표 할 일' 카드.
    @Published var selectedBoss = false
    /// 워크플로실 로봇을 눌렀을 때: (주인 세션, 하위 에이전트).
    @Published var selectedSubagent: (session: AgentSession, info: SubagentInfo)?
    /// 복구 금고 화면용 사본(정리한 세션·파일·브랜치를 되돌리는 기록).
    @Published var recovery: [RecoveryEntry] = []
    /// 정신교육실 인물·복구함 줄을 눌렀을 때 고른 금고 항목.
    @Published var selectedRecovery: String?
    private var lastAutoMemoryCleanup = Date.distantPast
    /// 앱 시작 시각. 시작 직후의 압박 상태는 '새 경고'가 아니므로 자동 정리하지 않는다(켜자마자 세션이 꺼지는 일 방지).
    private let launchedAt = Date()
    @Published var selectedMachine: MachineKind?
    @Published var page: OfficePage = .office
    /// 장면이 알려 주는 현재 카메라 초점(방 탭 선택 표시용).
    @Published var focus: OfficeFocus = .all
    /// 자동 줌 중 화면 위에 띄우는 한 줄 설명(예: "출근 · STOREARC · Codex").
    @Published var caption: String?
    /// 왼쪽 층 안내판(플로우 인디케이터)용 층 요약(위층부터).
    @Published var floors: [FloorSummary] = []
    /// 카메라가 지금 보고 있는 층 번호.
    @Published var viewportFloor: Int = 1

    let settings = Settings()
    let monitor = Monitor()
    /// 세션 프로세스의 끝(종료 코드·신호·메모리 부족 강제 종료)을 지켜본다 — 사라진 세션의 원인 판정 근거.
    let exitWatcher = ExitWatcher()
    let migrator = ExternalMigrator()
    private let scanner = DiskScanner()
    private var terminator: SessionTerminator!
    /// 정리 = 복구 키를 금고에 먼저 적고 종료(SessionRetirer). 키 없는 세션은 묶음·자동 정리에서 뺀다.
    let vault: RecoveryVault
    private(set) var retirer: SessionRetirer!
    let claudeRegistry = ClaudeRegistry()
    var lastRecoverySync = Date.distantPast
    /// 지금 정리 중인 세션(같은 세션을 두 경로가 동시에 정리하지 않게).
    var retiringKeys = Set<ProcessKey>()
    var lastVaultExpire = Date.distantPast
    /// 사무실 장면(창이 있을 때만). 사건과 스냅샷을 한 번에 넘겨 출근·퇴근 연출 순서를 보장한다.
    weak var scene: OfficeScene?
    private var cancellables: Set<AnyCancellable> = []

    init(vault: RecoveryVault = .shared) {
        self.vault = vault
        if let data = try? Data(contentsOf: vault.folder.appendingPathComponent("last-audit.json")) {
            lastAudit = try? JSONDecoder().decode(AuditReport.self, from: data)
        }
        terminator = SessionTerminator(registry: monitor.terminations)
        retirer = SessionRetirer(vault: vault, terminator: terminator)
        vault.sessionRetention = settings.recoveryRetentionDays * 86_400
        recovery = vault.all()
        monitor.alertSettings.diskThreshold = UInt64(settings.diskThresholdGB * Fmt.gib)
        monitor.onSystem = { [weak self] snapshot in
            self?.system = snapshot
        }
        monitor.onOffice = { [weak self] snapshot, events in
            guard let self else { return }
            self.office = snapshot
            self.refreshVisibleInventories()
            self.exitWatcher.watch(snapshot.sessions.filter { !$0.isEphemeral }.flatMap { Array($0.pids.prefix(32)) })
            self.scene?.update(snapshot: snapshot, events: events)
            if !events.isEmpty { self.record(events) }
            for event in events {
                if case .departed(_, let reason) = event.kind, let session = event.sessionSnapshot, !session.isEphemeral {
                    self.recordDeparture(session, reason: reason, at: event.time)
                }
            }
            self.refreshSuggestions()
            self.syncRecovery()
        }
        diskMap.onActionLog = { [weak self] line in self?.append(.cleanup, line) }
        connectDiskMapScene()
        // 지도 조사 결과 → 기계 카드·대시보드의 분류별 구성(치울 수 있는 양은 그 꼬리표 칸들의 조치로 판단).
        diskMapObserver = diskMap.$roots.receive(on: DispatchQueue.main).sink { [weak self] roots in
            self?.diskMapComposition = roots.isEmpty ? nil : DiskCompositionRow.summarize(roots)
        }
        monitor.onAlert = { [weak self] alert in
            self?.append(.alert, "\(alert.title) · 원인 후보: \(alert.causes.joined(separator: ", "))")
            Alerts.post(alert)
        }
        settings.$diskThresholdGB.sink { [weak self] value in self?.monitor.alertSettings.diskThreshold = UInt64(value * Fmt.gib) }.store(in: &cancellables)
        settings.$recoveryRetentionDays.sink { [weak self] days in self?.vault.sessionRetention = days * 86_400 }.store(in: &cancellables)
        history = monitor.history.all()
        migrations = migrator.records()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.history = self?.monitor.history.all() ?? [] }
        }
    }

    func start() {
        // 앱이 띄운 감사 판정(`claude -p`) 같은 일꾼은 세션 명단·방에 넣지 않는다(감시 시작 전에 한 번 정한다).
        monitor.detector.excludedAncestor = getpid()
        monitor.start()
        // git 사건(커밋·푸시·배포)은 .git 파일 몇 개의 stat이라 15초마다 본다.
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollGitEvents() } }
        applyLoginItem()
    }

    /// 전체 폴더 조사는 화면이 필요할 때만 한다. 상주 중에는 실시간 계측·세션 감시만 계속한다.
    func refreshVisibleInventories(now: Date = Date()) {
        guard monitor.foreground, office != nil else { return }
        if diskScannedAt.map({ now.timeIntervalSince($0) >= 6 * 3600 }) ?? true { scanDisk() }
        if leftoversScannedAt.map({ now.timeIntervalSince($0) >= 6 * 3600 }) ?? true { scanLeftovers() }
    }

    /// 창이 열려 장면이 붙으면 잡동사니를 다시 그린다.
    func attachScene(_ scene: OfficeScene?) {
        self.scene = scene
        pushClutter()
    }

    var selected: AgentSession? {
        guard let key = selectedSession else { return nil }
        return office?.sessions.first { $0.id == key }
    }

    /// 이 세션의 대화 id: 정확히 연결된 기록 파일 이름, 없으면 Claude 레지스트리 sessionId.
    func conversationID(for session: AgentSession) -> String? {
        if let log = session.logPath, !session.logLinkIsEstimate, let id = SessionLogReader.threadID(fromPath: log) { return id }
        return session.kind == .claudeCode ? claudeRegistry.load()[session.rootPID]?.sessionId : nil
    }

    func isPinned(_ session: AgentSession) -> Bool {
        !settings.pinnedSessions.isDisjoint(with: SessionPins.keys(session, conversationID: conversationID(for: session)))
    }

    func togglePin(_ session: AgentSession) {
        let conversation = conversationID(for: session)
        if isPinned(session) {
            settings.pinnedSessions.subtract(SessionPins.keys(session, conversationID: conversation))
        } else {
            settings.pinnedSessions.formUnion(SessionPins.storedKeys(session, conversationID: conversation))
        }
        append(.info, isPinned(session) ? "보호 고정 · \(session.project)" : "보호 해제 · \(session.project)")
    }

    func append(_ tone: EventLogEntry.Tone, _ text: String, session: ProcessKey? = nil, app: String? = nil) {
        // 같은 안내가 10분 안에 되풀이되면 한 번만(사건 기록이 같은 줄로 뒤덮이지 않게). 정리·퇴출·경보는 매번 남긴다.
        if tone == .info || tone == .trainer, let last = log.first(where: { $0.tone == tone }), last.text == text, Date().timeIntervalSince(last.time) < 600 { return }
        log.insert(EventLogEntry(time: Date(), tone: tone, text: text, sessionKey: session, appID: app), at: 0)
        if log.count > 300 { log.removeLast(log.count - 300) }
    }

    /// 직전 스냅샷의 잠깐 세션(퇴근 사건엔 세션 정보가 없어 여기서 거른다).
    private var ephemeralKeys = Set<ProcessKey>()
    private var lastSpikeLog: [ProcessKey: Date] = [:]

    private func record(_ events: [OfficeEvent]) {
        let current = Set((office?.sessions ?? []).filter(\.isEphemeral).map(\.id))
        defer { ephemeralKeys = current }
        let ephemeral = current.union(ephemeralKeys)
        for event in events {
            // 보조 호출·임시 세션의 출근·퇴근은 기록하지 않는다(몇 초마다 들락날락해 기록을 덮는다).
            switch event.kind {
            case .arrived(let key), .departed(let key, _):
                if ephemeral.contains(key) || event.sessionSnapshot?.isEphemeral == true { continue }
            default: break
            }
            let tone: EventLogEntry.Tone
            var key: ProcessKey?
            switch event.kind {
            case .arrived(let k): tone = .arrive; key = k
            case .departed(let k, let reason): tone = reason == .evictedByReMON ? .evict : .leave; key = k
            case .pressureChanged(_, let to):
                tone = to == .normal ? .info : .trainer
                if to != .normal { DispatchQueue.main.async { [weak self] in self?.cleanMemory(auto: true) } }
            case .cleanup, .tidy: tone = .cleanup
            case .diskLow, .swapMoved: tone = .alert
            case .cpuSpike(let k, _):
                // CPU 폭주는 세션마다 10분에 한 번만 기록한다(같은 세션이 몇 초마다 다시 기록을 덮던 문제).
                if let last = lastSpikeLog[k], Date().timeIntervalSince(last) < 600 { continue }
                lastSpikeLog[k] = Date()
                tone = .alert; key = k
            case .stateChanged: continue // 상태 변화는 캐릭터 동작으로 보여 준다
            default: tone = .info
            }
            append(tone, event.text, session: key)
        }
    }

    /// 사건 기록 줄을 누르면: 그 세션이 아직 있으면 사무실에서 고르고, 앱이면 앱을 고른다.
    func open(_ entry: EventLogEntry) {
        if let key = entry.sessionKey, let session = office?.sessions.first(where: { $0.id == key }) {
            selectSession(session)
        } else if let id = entry.appID, office?.apps.contains(where: { $0.id == id }) == true {
            selectedSession = nil
            selectedMachine = nil
            selectedApp = id
            page = .office
        } else if entry.sessionKey != nil {
            lastActionMessage = "이미 퇴근한 세션입니다"
        }
    }

    // MARK: 메모리 정리(실제로 비운다)

    /// 정리 대상: 고아 세션 + 3시간 넘게 쉰 세션. 일하는 중·입력 대기·보호 고정·보호 규칙 대상은 빼고, 메모리 큰 순.
    func memoryCleanupTargets() -> [AgentSession] {
        let now = Date()
        return (office?.sessions ?? []).filter { session in
            // 묶음·자동 경로는 '확인' 등급 상태만(추정 상태로는 세션을 끝내지 않는다 — 10-25 사고).
            guard session.stateConfidence == .confirmed, session.state == .orphan || session.state == .longIdle else { return false }
            let silence = session.lastActivity.map { now.timeIntervalSince($0) } ?? now.timeIntervalSince(session.startTime)
            return session.state == .orphan || silence >= 3 * 3600
        }
        .filter { !isPinned($0) && plan(for: $0).blockers.isEmpty }
        .sorted { $0.footprint > $1.footprint }
    }

    /// 메모리 정리: 트레이너가 들어오고, 대상 세션을 정상 종료(SIGTERM → 5초 → 남은 하위 재확인)한 뒤
    /// 12초 후 실제 메모리 사용량을 다시 재서 전후를 기록한다. auto면 알림만 보낸다.
    func cleanMemory(auto: Bool) {
        let targets = memoryCleanupTargets()
        if auto {
            // 자동 '정리'는 없다(10-25 사고 뒤): 메모리 경고 때는 정리 가능한 세션을 세어 알리기만 하고, 끝내는 결정은 사람이 패널에서 한다.
            guard settings.autoMemoryCleanup, Date().timeIntervalSince(launchedAt) > 120, Date().timeIntervalSince(lastAutoMemoryCleanup) > 600 else { return }
            lastAutoMemoryCleanup = Date()
            let keyed = targets.filter { recoveryKey(for: $0).allowsAutoCleanup }
            guard !keyed.isEmpty else { return }
            let bytes = keyed.reduce(UInt64(0)) { $0 + $1.footprint }
            append(.trainer, "메모리 압박 · 정리 가능한 세션 \(keyed.count)개 · 예상 \(Fmt.gb(bytes)) — 위험 감지 패널의 '메모리 최적화'에서 확인 뒤 정리합니다")
            optimizeNotes[.memory] = OptimizeNote(text: "정리 가능 \(keyed.count)개 · 예상 \(Fmt.gb(bytes)) · 누르면 목록을 확인합니다", good: true)
            Alerts.post(ReMONAlert(kind: .cleanupAvailable, title: "메모리 압박 · 정리 가능한 세션 \(keyed.count)개",
                                   body: "예상 \(Fmt.gb(bytes)) · ReMON 위험 감지 패널에서 목록을 확인한 뒤 정리할 수 있습니다", causes: keyed.prefix(3).map { "\($0.project) \(Fmt.size($0.footprint))" }))
            return
        } else if targets.isEmpty {
            Confirm.info(title: "정리할 세션이 없습니다", text: "오래 쉰(3시간+)·고아 세션이 없습니다. 일하는 중·입력 대기·보호 고정 세션은 정리하지 않습니다.")
            return
        }
        let before = system.memory.used
        releaseMany(targets, title: "메모리 정리", reason: "메모리 정리")
        // 실제 효과 측정(종료·회수에 몇 초 걸린다)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            self.monitor.refreshNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let after = self.system.memory.used
                let delta = Int64(before) - Int64(after)
                // 실측 = 실제로 끝난 대상의 메모리 합(시스템 수치는 참고).
                let measured = targets.filter { !SessionTerminator.isAlive($0.id) }.reduce(UInt64(0)) { $0 + $1.footprint }
                self.append(.cleanup, "메모리 정리 결과 · 실측 회수 \(Fmt.gb(measured)) · 시스템 메모리 \(Fmt.gb(before)) → \(Fmt.gb(after))(참고)" + (delta > 0 ? " (−\(Fmt.gb(UInt64(delta))))" : ""))
                self.scene?.trainerAnnounce(measured: measured, text: "시스템 메모리 \(Fmt.gb(before)) → \(Fmt.gb(after))")
            }
        }
    }

    func selectBoss() {
        selectedSession = nil
        selectedApp = nil
        selectedMachine = nil
        selectedSubagent = nil
        selectedBoss = true
        scene?.select(nil)
    }

    func selectSubagent(_ key: ProcessKey, _ info: SubagentInfo) {
        guard let owner = scene?.subagentOwner(key) ?? office?.sessions.first(where: { $0.id == key }) else { return }
        selectedSession = nil
        selectedApp = nil
        selectedMachine = nil
        selectedBoss = false
        selectedSubagent = (owner, info)
    }

    /// 기록 보관소(금고의 방)를 누르면 정리 페이지의 복구함으로.
    func openVault() {
        selectedSubagent = nil
        page = .cleanup
        append(.info, "복구 금고 · \(vaultCounts.total)건 · \(Fmt.gb(vaultCounts.bytes))")
    }

    // MARK: 묶음 관리

    /// 여러 세션을 한 번에 정리(퇴근)한다. 막힌 세션은 빼고, 확인은 한 번만 받는다.
    func releaseMany(_ targets: [AgentSession], title: String, reason: String? = nil) {
        let keyed = targets.map { (plan: plan(for: $0), key: recoveryKey(for: $0)) }
        let allowed = keyed.filter { $0.plan.blockers.isEmpty && $0.key.allowsAutoCleanup }
        let blocked = keyed.filter { !$0.plan.blockers.isEmpty }
        // 묶음 정리는 되돌릴 수 있는 것만: 복구 키가 없으면 빼고, 세션 카드에서 하나씩(경고 확인 후)만 정리한다.
        let keyless = keyed.filter { $0.plan.blockers.isEmpty && !$0.key.allowsAutoCleanup }
        guard !allowed.isEmpty else {
            let lines = blocked.map { "\($0.plan.session.project): \($0.plan.blockers[0])" } + keyless.map { "\($0.plan.session.project): \($0.key.label)" }
            Confirm.info(title: "정리할 수 있는 세션이 없습니다", text: lines.joined(separator: "\n") + (keyless.isEmpty ? "" : "\n\n복구 키가 없는 세션은 세션 카드에서 하나씩만 정리할 수 있습니다."))
            return
        }
        let bytes = allowed.reduce(UInt64(0)) { $0 + $1.plan.session.footprint }
        var text = allowed.prefix(12).map { "• \($0.plan.session.project) · \($0.plan.session.kind.label) · \($0.plan.session.state.label) · \(Fmt.size($0.plan.session.footprint)) · \($0.key.label)" }.joined(separator: "\n")
        if allowed.count > 12 { text += "\n… 외 \(allowed.count - 12)개" }
        if !blocked.isEmpty { text += "\n\n제외(보호): " + blocked.map { "\($0.plan.session.project)(\($0.plan.blockers[0]))" }.joined(separator: ", ") }
        if !keyless.isEmpty { text += "\n\n제외(복구 키 없음 — 세션 카드에서 하나씩만): " + keyless.map(\.plan.session.project).joined(separator: ", ") }
        let warned = allowed.filter { !$0.plan.warnings.isEmpty }
        if !warned.isEmpty { text += "\n\n주의: " + warned.map { "\($0.plan.session.project) — \($0.plan.warnings[0])" }.joined(separator: "; ") }
        text += "\n\n복구 키를 금고에 먼저 적고 SIGTERM → 5초 대기 → 남은 하위만 재확인 후 종료합니다. 정리한 세션은 정신교육실에서 같은 대화로 복귀시킬 수 있습니다." + (settings.dryRun ? "\n드라이런: 실제로 종료하지 않고 결과만 기록합니다." : "")
        guard Confirm.ask(title: "\(title) · \(allowed.count)개 · 약 \(Fmt.gb(bytes))", text: text, action: settings.dryRun ? "드라이런" : "모두 정리") else { return }
        for item in allowed { execute(item.plan, force: false, reason: reason ?? title, requireKey: true) }
    }

    /// 정리 제안 실행(메뉴 패널·대시보드에서 누를 때).
    func perform(_ suggestion: CleanupSuggestion) {
        switch suggestion.action {
        case .sessions(let keys):
            let targets = (office?.sessions ?? []).filter { keys.contains($0.id) }
            releaseMany(targets, title: suggestion.title, reason: suggestion.title)
        case .trashPaths(let paths):
            let items = diskItems.filter { paths.contains($0.path) }
            trashMany(items, title: suggestion.title)
        case .migratePaths, .info:
            page = .cleanup
        }
    }

    /// 여러 파일 항목을 휴지통으로(확인 한 번). 열린 파일·금지 경로 검사는 항목마다 그대로 한다.
    func trashMany(_ items: [DiskItem], title: String) {
        guard !items.isEmpty else { return }
        let bytes = items.reduce(UInt64(0)) { $0 + $1.bytes }
        let list = items.prefix(12).map { "• " + $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " (\(Fmt.gb($0.bytes)))" }.joined(separator: "\n")
        guard Confirm.ask(title: "\(title) · \(items.count)곳 · \(Fmt.gb(bytes))", text: list + "\n\n휴지통으로 옮깁니다(비우지 않음)." + (settings.dryRun ? "\n드라이런: 옮기지 않고 결과만 기록합니다." : ""), action: settings.dryRun ? "드라이런" : "휴지통으로") else { return }
        for item in items { trash(item, confirmed: true) }
    }

    // MARK: 부산물(워크트리·브랜치)

    /// 읽기 전용 조사(git·orca 명령 수십 개, 수 초). 백그라운드에서 돌고 끝나면 방마다 잡동사니로 그린다.
    func scanLeftovers() {
        guard !leftoversScanning else { return }
        leftoversScanning = true
        let sessions = office?.sessions ?? []
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = LeftoverScanner.report(sessions: sessions, orcaTerminals: nil, orcaWorktrees: nil)
            DispatchQueue.main.async {
                guard let self else { return }
                self.leftovers = report.projects.sorted { $0.cleanableCount != $1.cleanableCount ? $0.cleanableCount > $1.cleanableCount : $0.project < $1.project }
                self.leftoversScanning = false
                self.leftoversScannedAt = Date()
                let cleanable = report.projects.reduce(0) { $0 + $1.cleanableCount }
                self.leftoversNote = String(format: "저장소 %d개 · %.1f초 · 치울 수 있음 %d개", report.repoCount, report.elapsed, cleanable)
                if !report.skippedRepos.isEmpty { self.leftoversNote! += " · 건너뜀 \(report.skippedRepos.count)" }
                self.pushClutter()
                self.refreshProjectGarbage()
            }
        }
    }

    private func pushClutter() {
        // 짐 장부(워크트리·브랜치·서류 전부)는 refreshProjectGarbage가 RoomClutter로 장면에 넘긴다(옛 개수 호출은 새 장부가 오면 무시된다).
        refreshProjectGarbage()
    }

    var leftoverCleanableTotal: Int { leftovers.reduce(0) { $0 + $1.cleanableCount } }

    /// 청소: 확인 한 번 → 항목마다 직전에 재검사하며 치운다 → 방마다 청소 인력이 들어온다.
    func cleanLeftovers(_ targets: [ProjectLeftovers]? = nil) {
        let projects = (targets ?? leftovers).filter { $0.cleanableCount > 0 }
        guard !projects.isEmpty else { return }
        let count = projects.reduce(0) { $0 + $1.cleanableCount }
        let bytes = projects.reduce(UInt64(0)) { $0 + $1.cleanableBytes }
        var lines: [String] = []
        for project in projects {
            let worktrees = project.worktrees.filter(\.verdict.isCleanable)
            let branches = project.branches.filter(\.verdict.isCleanable)
            var parts: [String] = []
            if !worktrees.isEmpty { parts.append("워크트리 \(worktrees.count)개") }
            if !branches.isEmpty { parts.append("브랜치 \(branches.count)개") }
            lines.append("• \(project.project): " + parts.joined(separator: " · "))
        }
        let text = lines.prefix(14).joined(separator: "\n") + (lines.count > 14 ? "\n… 외 \(lines.count - 14)개 방" : "") +
            "\n\n병합됐고, 커밋 안 된 변경이 없고, 아무도 쓰지 않는 것만 치웁니다. 항목마다 직전에 다시 확인하고, 하나라도 바뀌었으면 건너뜁니다. 브랜치는 `git branch -d`(강제 아님)" + (OrcaBridge.executable != nil ? ", Orca 워크트리는 `orca worktree rm`(강제 아님)" : "") + "입니다." +
            (settings.dryRun ? "\n\n드라이런: 실제로 치우지 않고 결과만 기록합니다." : "")
        guard Confirm.ask(title: "부산물 청소 · \(count)개 · \(Fmt.gb(bytes))", text: text, action: settings.dryRun ? "드라이런" : "청소하기") else { return }
        let dryRun = settings.dryRun
        let sessions = office?.sessions ?? []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = LeftoverCleaner.clean(projects, dryRun: dryRun, sessions: sessions, vault: RecoveryVault.shared)
            DispatchQueue.main.async {
                guard let self else { return }
                let done = results.filter { $0.ok && !$0.skipped }
                // '미확인'(지운 뒤 확인이 안 됨)은 건너뜀과 다르다 — 지워졌을 수도 있으니 따로 센다(코덱스 규칙 5·6).
                let unverified = results.filter { !$0.ok && $0.message.hasPrefix("미확인") }
                let skipped = results.filter { ($0.skipped || !$0.ok) && !$0.message.hasPrefix("미확인") }
                self.lastActionMessage = "청소 \(done.count)개 완료" + (skipped.isEmpty ? "" : " · 건너뜀 \(skipped.count)개(\(skipped.prefix(2).map(\.message).joined(separator: "; ")))")
                    + (unverified.isEmpty ? "" : " · 미확인 \(unverified.count)개(\(unverified.prefix(2).map(\.message).joined(separator: "; ")))")
                self.append(.cleanup, (dryRun ? "드라이런 · " : "") + self.lastActionMessage!)
                if !dryRun {
                    // 방마다 청소 인력 한 번씩(연출은 순서대로 들어온다)
                    let byProject = Dictionary(grouping: done, by: \.project)
                    for (project, items) in byProject.sorted(by: { $0.key < $1.key }) {
                        let bytes = items.reduce(UInt64(0)) { $0 + $1.bytes }
                        self.monitor.emit(OfficeEvent(kind: .tidy(reclaimedBytes: bytes, project: project, items: items.count), text: "청소 · \(project) · \(items.count)개" + (bytes > 0 ? " · \(Fmt.gb(bytes))" : "")))
                    }
                }
                self.scanLeftovers()
            }
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func activate(_ app: AppGroup) {
        runningInstances(app).first?.activate()
    }

    func icon(for app: AppGroup) -> NSImage? {
        runningInstances(app).first?.icon
    }

    // MARK: 정리 제안

    func refreshSuggestions() {
        var result: [CleanupSuggestion] = []
        let sessions = office?.sessions ?? []
        let groups = Dictionary(grouping: sessions.filter { $0.state == .longIdle || $0.state == .orphan || $0.state == .idle }) { $0.kind }
        for (kind, members) in groups {
            let bytes = members.reduce(UInt64(0)) { $0 + $1.footprint }
            let label = members.allSatisfy { $0.state == .orphan } ? "고아" : "오래 쉰"
            result.append(CleanupSuggestion(id: "sessions-\(kind.rawValue)", title: "\(label) \(kind.label) 세션 \(members.count)개", detail: members.map(\.project).joined(separator: ", "),
                                            reclaimBytes: bytes, action: .sessions(members.map(\.id))))
        }
        let leftovers = sessions.filter(\.tabLeftover)
        if !leftovers.isEmpty {
            result.insert(CleanupSuggestion(id: "tab-leftovers", title: "탭 닫힌 세션 \(leftovers.count)개", detail: leftovers.map(\.project).joined(separator: ", "),
                                            reclaimBytes: leftovers.reduce(0) { $0 + $1.footprint }, action: .sessions(leftovers.map(\.id))), at: 0)
        }
        // 주인 앱이 실행 중이거나 명령으로 정리하는 항목(pnpm·Go 등)·보기만 하는 항목은 제안하지 않는다.
        let caches = diskItems.filter { $0.category == .regenerable && CacheDeletionPolicy.blockReason(for: $0) == nil }
        if !caches.isEmpty {
            result.append(CleanupSuggestion(id: "caches", title: "빌드·패키지 캐시 \(caches.count)곳", detail: caches.prefix(3).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", "),
                                            reclaimBytes: caches.reduce(0) { $0 + $1.bytes }, action: .trashPaths(caches.map(\.path))))
        }
        if let trash = diskItems.first(where: { $0.category == .trash }), trash.bytes > 0 {
            result.append(CleanupSuggestion(id: "trash", title: "휴지통", detail: "Finder에서 비우면 공간이 돌아옵니다", reclaimBytes: trash.bytes, action: .info))
        }
        let logs = diskItems.filter { $0.category == .aiLogs }
        if !logs.isEmpty {
            result.append(CleanupSuggestion(id: "logs", title: "오래된 AI 기록 \(logs.count)묶음", detail: "외장 이전 대상", reclaimBytes: logs.reduce(0) { $0 + $1.bytes }, action: .migratePaths(logs.map(\.path))))
        }
        suggestions = result.sorted { $0.reclaimBytes > $1.reclaimBytes }
    }

    func scanDisk(then completion: (() -> Void)? = nil) {
        guard !diskScanning else { return }
        diskScanning = true
        let active = Set((office?.sessions ?? []).compactMap(\.cwd))
        let scanner = self.scanner
        DispatchQueue.global(qos: .background).async {
            let items = scanner.scan(activeDirectories: active)
            DispatchQueue.main.async { [weak self] in
                self?.diskItems = items
                self?.diskScanning = false
                self?.diskScannedAt = Date()
                self?.refreshProjectGarbage()
                self?.refreshSuggestions()
                completion?()
            }
        }
    }

    // MARK: 세션 정리 · 강제 종료

    private func members(of session: AgentSession) -> (records: [ProcRecord], environments: [Int32: [String: String]], footprints: [ProcessKey: UInt64]) {
        let pids = Set(session.pids)
        let records = (office?.processes ?? []).filter { pids.contains($0.pid) }
        var environments: [Int32: [String: String]] = [:]
        for record in records { environments[record.pid] = ProcessSampler.readArguments(pid: record.pid)?.environment ?? [:] }
        return (records, environments, Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0.footprint) }))
    }

    func plan(for session: AgentSession) -> SessionTerminator.Plan {
        let info = members(of: session)
        // 고정 판정은 여러 키로 한다(isPinned) — 종료기에는 결과만 넘긴다.
        let context = ProtectionContext(pinnedKeys: isPinned(session) ? ["pinned"] : [])
        return terminator.plan(session: session, members: info.records, environments: info.environments, context: context, pinKey: "pinned")
    }

    /// 정리하기(퇴근시키기): 미리보기 → 확인 → SIGTERM → 5초 → 남은 하위는 재확인 후 SIGKILL.
    func release(_ session: AgentSession) {
        let plan = plan(for: session)
        guard plan.blockers.isEmpty else {
            scene?.shout(session.id, reason: plan.blockers[0])
            Confirm.info(title: "종료할 수 없는 세션입니다", text: plan.blockers.joined(separator: "\n"))
            scene?.calmDown(session.id)
            append(.info, "정리 차단 · \(session.project) · \(plan.blockers[0])")
            return
        }
        let warnings = plan.warnings.isEmpty ? "" : "\n\n주의:\n• " + plan.warnings.joined(separator: "\n• ")
        let key = recoveryKey(for: session)
        let recoveryText = "\n\n" + recoveryLine(key)
        // 복구 키가 없으면 되돌릴 수 없다 → 제목에 경고, 기본 버튼은 '취소'(Enter 한 번으로 지나가지 않게).
        let title = key.allowsAutoCleanup ? "\(session.project) 세션을 정리할까요?" : "⚠️ 되돌릴 수 없음 · \(session.project) 세션을 정리할까요?"
        guard Confirm.ask(title: title, text: plan.preview + warnings + recoveryText + (settings.dryRun ? "\n\n드라이런: 실제로 종료하지 않고 결과만 기록합니다." : ""),
                          action: settings.dryRun ? "드라이런" : "정리하기", destructive: !key.allowsAutoCleanup) else { return }
        execute(plan, force: false, reason: "수동 정리")
    }

    /// 강제 종료(쫓아내기): 이유가 있으면 직원이 소리치는 동안 별도 확인을 받는다.
    func evict(_ session: AgentSession) {
        let plan = plan(for: session)
        guard plan.blockers.isEmpty else {
            scene?.shout(session.id, reason: plan.blockers[0])
            Confirm.info(title: "강제 종료할 수 없는 세션입니다", text: plan.blockers.joined(separator: "\n"))
            scene?.calmDown(session.id)
            append(.info, "강제 종료 차단 · \(session.project) · \(plan.blockers[0])")
            return
        }
        if let reason = plan.warnings.first { scene?.shout(session.id, reason: reason) }
        let text = plan.preview + (plan.warnings.isEmpty ? "" : "\n\n종료하면 안 되는 이유:\n• " + plan.warnings.joined(separator: "\n• ")) + "\n\n하위 프로세스까지 즉시 SIGKILL로 끝냅니다. 저장되지 않은 작업은 사라집니다.\n" + recoveryLine(recoveryKey(for: session))
        // 데모 모드의 더미 프로세스(/private/tmp/remon-dummy/ 아래 실행 파일)만 확인 창을 건너뛴다. 실제 세션은 항상 확인을 받는다.
        let autoConfirm = DemoDirector.isDummy(session, processes: office?.processes ?? [])
        if autoConfirm {
            append(.info, "데모 · 더미 세션 강제 종료(자동 확인) · 이유: \(plan.warnings.first ?? "없음")")
        } else if !Confirm.ask(title: "강제 종료 확인", text: text, action: settings.dryRun ? "드라이런" : "그래도 종료", destructive: true) {
            scene?.calmDown(session.id)
            return
        }
        let start = { [weak self] in
            guard let self else { return }
            if !self.settings.dryRun, let worker = self.scene?.worker(for: session.id) { self.scene?.evict(worker, shout: plan.warnings.first) }
            self.execute(plan, force: true, reason: "강제 종료")
        }
        // 자동 확인 때도 소리치는 장면이 보이도록 잠시 둔다.
        if autoConfirm { DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: start) } else { start() }
    }

    func executeTermination(_ plan: SessionTerminator.Plan, force: Bool, reason: String = "수동 정리", requireKey: Bool = false, auto: Bool = false, allowWaiting: Bool = false) {
        execute(plan, force: force, reason: reason, requireKey: requireKey, auto: auto, allowWaiting: allowWaiting)
    }

    /// 정리 실행: 복구 키를 금고에 먼저 적고(실패하면 종료 안 함) → SIGTERM → 결과를 금고에 반영한다.
    /// requireKey: 묶음·자동 경로 — 키(또는 잃을 대화 없음)가 없으면 종료하지 않는다. auto: 남은 하위를 묻지 않고 남겨 둔다.
    /// allowWaiting: 대표님이 '오래 입력 대기 세션도 정리'를 확인한 경우에만 — 신호 직전 '입력 대기'여도 멈추지 않는다(일하는 중이면 멈춤).
    private func execute(_ plan: SessionTerminator.Plan, force: Bool, reason: String = "수동 정리", requireKey: Bool = false, auto: Bool = false, allowWaiting: Bool = false) {
        guard !retiringKeys.contains(plan.session.id) else { return }
        // 결정(감사 판정·확인 창) 뒤 수십 초가 지날 수 있다 → 지금 스냅샷과 비교해 일을 시작했으면 취소한다(10-25 검토).
        guard let current = office?.sessions.first(where: { $0.id == plan.session.id }) else {
            append(.info, "정리하지 않음 · \(plan.session.project) · 이미 끝난 세션입니다", session: plan.session.id); return
        }
        if (current.state == .working || current.state == .waiting) && current.state != plan.session.state {
            append(.info, "정리하지 않음 · \(plan.session.project) · 결정 뒤 상태가 '\(current.state.label)'로 바뀌었습니다", session: plan.session.id); return
        }
        if let now = current.lastActivity, now > (plan.session.lastActivity ?? .distantPast).addingTimeInterval(1) {
            append(.info, "정리하지 않음 · \(plan.session.project) · 결정 뒤 새 활동이 있습니다(\(Fmt.ago(now)))", session: plan.session.id); return
        }
        retiringKeys.insert(plan.session.id)
        let info = members(of: plan.session)
        let dryRun = settings.dryRun
        let retirer = self.retirer!
        let registryEntry = claudeRegistry.load()[plan.session.rootPID]
        let prepared = retirer.prepare(plan: plan, registrySessionID: registryEntry?.sessionId, argv: ProcessSampler.readArguments(pid: plan.session.rootPID)?.argv ?? [],
                                       registryKind: registryEntry?.kind, reason: reason, requireKey: requireKey)
        // 신호 바로 앞: Claude 레지스트리가 일하는 중(busy)이면, 묶음·자동 경로에선 입력 대기(waiting)도 취소.
        let pid = plan.session.rootPID, isClaude = plan.session.kind == .claudeCode
        let preSignal: @Sendable () -> String? = {
            guard isClaude, let status = ClaudeRegistry().load()[pid]?.status else { return nil }
            if status == "busy" { return "신호 직전 확인: 레지스트리 상태 busy(일하는 중)" }
            if requireKey && !allowWaiting && status == "waiting" { return "신호 직전 확인: 입력을 기다리는 중" }
            return nil
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = retirer.execute(prepared, dryRun: dryRun, force: force, footprints: info.footprints, preSignalCheck: preSignal) { remaining in
                // 자동 정리는 확인할 사람이 없으니 남은 하위를 강제로 끝내지 않는다(기록만).
                guard !auto else { return false }
                return DispatchQueue.main.sync { Confirm.ask(title: "하위 프로세스 \(remaining.count)개가 남았습니다", text: "SIGTERM 후 5초가 지나도 끝나지 않았습니다. 남은 하위만 SIGKILL로 끝낼까요?", action: "남은 것만 종료", destructive: true) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.retiringKeys.remove(plan.session.id)
                let outcome = result.termination
                let terminated = result.aborted == nil && outcome.map { !$0.dryRun && !$0.blocked } == true
                self.lastActionMessage = result.message
                self.append(terminated ? .cleanup : .info, result.message, session: plan.session.id)
                if terminated, let entry = result.entry, entry.status == .held {
                    self.append(.trainer, "정신교육실 보관 · \(entry.project) · 복구 키 \(entry.resumeID?.prefix(8) ?? "")")
                }
                // 탭이 닫힌 세션이었다면 Orca에 남은 고아 PTY(빈 셸)도 닫아 Orca 목록을 깨끗하게 한다.
                if terminated, plan.session.tabState == .closed, let handle = plan.session.orcaHandle,
                   let orca = OrcaBridge.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        // 짝짓기는 추정이라, 닫기 직전에 다시 읽어 그 터미널이 '탭 닫힘'이고 에이전트가 없을 때만 닫는다(다른 세션의 PTY를 닫지 않게).
                        guard let fresh = OrcaBridge.list()?.first(where: { $0.handle == handle }), fresh.orphaned, (fresh.agent ?? "").isEmpty else {
                            DispatchQueue.main.async { self.append(.info, "Orca 고아 PTY 닫기 보류(아직 에이전트가 보이거나 목록에 없음) · " + plan.session.project) }
                            return
                        }
                        let closed = Shell.capture(orca, ["terminal", "close", "--terminal", handle, "--json"], timeout: 10)
                        DispatchQueue.main.async { self.append(closed.succeeded ? .cleanup : .info, (closed.succeeded ? "Orca 고아 PTY 닫음 · " : "Orca 고아 PTY 닫기 실패 · ") + plan.session.project) }
                    }
                }
                // 강제 종료는 경비원이 맡는다. 트레이너(정리 운동)는 정리하기·파일 정리 때만 온다.
                if terminated, !force, let outcome, outcome.reclaimed > 0 {
                    self.monitor.emit(OfficeEvent(kind: .cleanup(reclaimedBytes: outcome.reclaimed, summary: outcome.message), text: "정리 · \(plan.session.project) · \(Fmt.gb(outcome.reclaimed)) 회수"))
                }
                self.syncRecovery(force: true)
                self.monitor.refreshNow()
            }
        }
    }

    func copyResume(_ session: AgentSession) {
        guard let command = session.resumeCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        append(.info, "이어 열기 명령 복사 · \(session.project)")
    }

    func revealTerminal(_ session: AgentSession) {
        // tmux 안의 세션: 그 창을 고르고 화면을 띄운 앱을 앞으로(Orca 탭이 다른 pane을 보여 주고 있을 수 있어 tmux가 먼저).
        if session.terminalHost == "tmux" {
            DispatchQueue.global().async { [weak self] in
                let result = TmuxBridge.reveal(sessionRoot: session.rootPID, start: session.id.start)
                DispatchQueue.main.async {
                    if let bundle = result.host?.bundleID { NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate() }
                    else if result.host?.name == "Orca" { NSWorkspace.shared.runningApplications.first { $0.localizedName == "Orca" }?.activate() }
                    if !result.ok || result.host == nil { self?.append(.info, "터미널로 이동 · \(session.project) · \(result.message)") }
                }
            }
            return
        }
        if let handle = session.orcaHandle, let orca = OrcaBridge.candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            DispatchQueue.global().async { _ = Shell.run(orca, ["terminal", "switch", "--terminal", handle], timeout: 5) }
            NSWorkspace.shared.runningApplications.first { $0.localizedName == "Orca" }?.activate()
            return
        }
        if let host = session.terminalHost, let bundle = TerminalHosts.bundleIdentifier(for: host) {   // 터미널 표(Warp·WezTerm·kitty·VS Code 등 포함)
            NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
        }
    }

    // MARK: 앱 종료(사양 5장: 일반 앱은 terminate, 강제 종료는 별도 확인)

    var selectedAppGroup: AppGroup? {
        guard let id = selectedApp else { return nil }
        return office?.apps.first { $0.id == id }
    }

    private func runningInstances(_ app: AppGroup) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == app.id }
    }

    func appBlockers(_ app: AppGroup) -> [String] {
        var reasons: [String] = []
        if app.category == .system { reasons.append("시스템 앱입니다") }
        if app.category == .host { reasons.append("에이전트 터미널 호스트(\(app.name))입니다") }
        if app.id == Bundle.main.bundlePath { reasons.append("ReMON 자신입니다") }
        let protected = ["Finder", "Dock", "WindowServer", "loginwindow", "SystemUIServer"]
        if protected.contains(app.name) { reasons.append("macOS 필수 앱입니다") }
        let harness = app.pids.contains { ProcessSampler.readArguments(pid: $0)?.environment["CFFIXED_USER_HOME"] != nil }
        if harness { reasons.append("측정·시험 하네스가 띄운 인스턴스입니다(CFFIXED_USER_HOME)") }
        if runningInstances(app).isEmpty { reasons.append("앱 단위로 종료할 수 있는 실행 인스턴스를 찾지 못했습니다") }
        return reasons
    }

    func quitApp(_ app: AppGroup) {
        let blockers = appBlockers(app)
        guard blockers.isEmpty else { Confirm.info(title: "종료할 수 없는 앱입니다", text: blockers.joined(separator: "\n")); return }
        guard Confirm.ask(title: "\(app.name)을(를) 종료할까요?", text: "메모리 \(Fmt.gb(app.footprint)) · 프로세스 \(app.pids.count)개\n저장하지 않은 문서가 있으면 앱이 직접 물어봅니다." + (settings.dryRun ? "\n\n드라이런입니다." : ""), action: settings.dryRun ? "드라이런" : "종료") else { return }
        if settings.dryRun {
            AuditLog.shared.write(action: "app.terminate", target: app.name, bytes: app.footprint, result: "dry-run", dryRun: true)
            append(.info, "드라이런 · 앱 종료 · \(app.name)")
            return
        }
        for instance in runningInstances(app) { instance.terminate() }
        AuditLog.shared.write(action: "app.terminate", target: app.name, bytes: app.footprint, result: "requested", dryRun: false)
        append(.leave, "앱 종료 요청 · \(app.name) · \(Fmt.gb(app.footprint))")
    }

    func forceQuitApp(_ app: AppGroup) {
        let blockers = appBlockers(app)
        guard blockers.isEmpty else { Confirm.info(title: "강제 종료할 수 없는 앱입니다", text: blockers.joined(separator: "\n")); return }
        let shout = "저장 안 한 문서가 있을지도 몰라요! (\(Fmt.gb(app.footprint)))"
        guard Confirm.ask(title: "\(app.name) 강제 종료", text: "저장하지 않은 문서는 사라집니다. 앱이 묻지 않고 즉시 끝납니다.\n메모리 \(Fmt.gb(app.footprint)) · 프로세스 \(app.pids.count)개\n\n끝내기 전에 복구 금고에 적어 두므로 복구함에서 '다시 띄우기'로 열 수 있습니다(문서는 돌아오지 않습니다).", action: settings.dryRun ? "드라이런" : "그래도 강제 종료", destructive: true) else { return }
        if settings.dryRun {
            AuditLog.shared.write(action: "app.force", target: app.name, bytes: app.footprint, result: "dry-run", dryRun: true)
            append(.info, "드라이런 · 앱 강제 종료 · \(app.name)")
            return
        }
        let instances = runningInstances(app)
        guard let held = recordForceQuit(app, instances: instances) else { return }   // 금고에 먼저 적지 못하면 끝내지 않는다(ProcessCareActions.swift)
        scene?.evictStaff(app.id, shout: shout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            for instance in instances { instance.forceTerminate() }
            self?.settleForceQuit(held, instances: instances)
        }
        AuditLog.shared.write(action: "app.force", target: app.name, bytes: app.footprint, result: "requested", dryRun: false)
        append(.evict, "앱 강제 종료 · \(app.name) · \(Fmt.gb(app.footprint))")
        selectedApp = nil
    }

    // MARK: 파일 정리 · 외장 이전

    var userPIDs: [Int32] { (office?.processes ?? []).filter { $0.memorySource == .kernel }.map(\.pid) }

    func trash(_ item: DiskItem, permanently: Bool = false, confirmed: Bool = false) {
        let title = permanently ? "영구 삭제할까요?" : "휴지통으로 옮길까요?"
        let text = "\(item.path)\n\(Fmt.gb(item.bytes)) · \(item.category.label)\n\(item.category.actionHint)" + (settings.dryRun ? "\n\n드라이런: 실제로 옮기지 않습니다." : "")
        guard confirmed || Confirm.ask(title: title, text: text, action: settings.dryRun ? "드라이런" : (permanently ? "영구 삭제" : "휴지통으로"), destructive: permanently) else { return }
        do {
            if permanently {
                try SafeFileOps.deletePermanently(item.path, userPIDs: userPIDs, dryRun: settings.dryRun, bytes: item.bytes, vault: vault,
                                                  project: "", reason: "영구 삭제", regeneration: CacheDeletionPolicy.regenerationHint(for: item))
            } else {
                _ = try SafeFileOps.moveToTrash(item.path, userPIDs: userPIDs, dryRun: settings.dryRun, bytes: item.bytes, vault: vault,
                                                project: item.path.hasPrefix(NSHomeDirectory() + "/DEV/") ? SessionDetector.projectName(for: item.path) : "", reason: "파일 정리")
            }
            append(.cleanup, "\(settings.dryRun ? "드라이런 · " : "")\(permanently ? "영구 삭제" : "휴지통") · \((item.path as NSString).lastPathComponent) · \(Fmt.gb(item.bytes))")
            if !settings.dryRun {
                diskItems.removeAll { $0.path == item.path }
                // 파일 정리는 청소 인력이 맡는다(트레이너는 메모리 정리 담당).
                let project = item.path.hasPrefix(NSHomeDirectory() + "/DEV/") ? SessionDetector.projectName(for: item.path) : nil
                monitor.emit(OfficeEvent(kind: .tidy(reclaimedBytes: item.bytes, project: project, items: 1), text: "청소 · \((item.path as NSString).lastPathComponent) · \(Fmt.gb(item.bytes))"))
            }
        } catch {
            Confirm.info(title: "정리하지 못했습니다", text: String(describing: error))
            append(.info, "정리 실패 · \(error)")
        }
    }

    func migrate(_ item: DiskItem, to volume: String) {
        let type = ExternalMigrator.filesystemType(volume)
        let note = ["exfat", "msdos"].contains(type.lowercased()) ? "\(type) 볼륨이라 APFS 이미지(\(ExternalMigrator.imageName)) 안에 담습니다." : "\(type) 볼륨에 바로 복사합니다."
        guard Confirm.ask(title: "외장으로 옮길까요?", text: "\(item.path)\n→ \(volume)\n\(note)\n파일 수·크기가 일치할 때만 원본을 지우고 원래 자리에 링크를 남깁니다." + (settings.dryRun ? "\n\n드라이런입니다." : ""), action: settings.dryRun ? "드라이런" : "옮기기") else { return }
        let dryRun = settings.dryRun
        let pids = userPIDs
        append(.info, "외장 이전 시작 · \((item.path as NSString).lastPathComponent)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let record = try self?.migrator.migrate(source: item.path, toVolume: volume, userPIDs: pids, dryRun: dryRun)
                DispatchQueue.main.async {
                    guard let self, let record else { return }
                    self.append(.cleanup, "\(dryRun ? "드라이런 · " : "")외장 이전 완료 · \(record.files)개 · \(Fmt.gb(record.bytes))")
                    self.migrations = self.migrator.records()
                    if !dryRun { self.diskItems.removeAll { $0.path == item.path } }
                }
            } catch {
                DispatchQueue.main.async {
                    Confirm.info(title: "외장 이전 실패", text: String(describing: error))
                    self?.append(.info, "외장 이전 실패 · \(error)")
                }
            }
        }
    }

    func undo(_ record: ExternalMigrator.Record) {
        guard Confirm.ask(title: "되돌릴까요?", text: "\(record.destination)\n→ \(record.source)", action: settings.dryRun ? "드라이런" : "되돌리기") else { return }
        let dryRun = settings.dryRun
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                try self?.migrator.undo(record, dryRun: dryRun)
                DispatchQueue.main.async {
                    self?.append(.cleanup, "\(dryRun ? "드라이런 · " : "")되돌리기 완료 · \((record.source as NSString).lastPathComponent)")
                    self?.migrations = self?.migrator.records() ?? []
                }
            } catch {
                DispatchQueue.main.async { Confirm.info(title: "되돌리기 실패", text: String(describing: error)) }
            }
        }
    }

    func attachImage(_ path: String) {
        DispatchQueue.global().async { [weak self] in
            let result = try? self?.migrator.attach(path)
            DispatchQueue.main.async { self?.append(.info, result != nil ? "이미지 연결 · \(result!)" : "이미지 연결 실패 · \(path)") }
        }
    }

    // MARK: 로그인 실행

    func applyLoginItem() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        do {
            if settings.launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            append(.info, "로그인 실행 설정 실패 · \(error.localizedDescription)")
        }
    }
}

/// 확인 창(모달). 파괴적 행동은 기본 버튼이 '취소'다.
enum Confirm {
    static func ask(title: String, text: String, action: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = destructive ? .critical : .warning
        if destructive {
            alert.addButton(withTitle: "취소")
            let button = alert.addButton(withTitle: action)
            button.hasDestructiveAction = true
            NSApp.activate(ignoringOtherApps: true)
            return alert.runModal() == .alertSecondButtonReturn
        }
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 버튼 여럿 중 하나(첫 버튼이 기본). 고른 버튼의 순서(0부터)를 돌려준다.
    static func choose(title: String, text: String, buttons: [String]) -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        for button in buttons { alert.addButton(withTitle: button) }
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    static func info(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "확인")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
