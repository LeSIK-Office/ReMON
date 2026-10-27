import Darwin
import Foundation

/// ReMON이 직접 종료한 프로세스 기록. 퇴근/쫓겨남 연출을 구분하는 근거다.
public final class TerminationRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [ProcessKey: (reason: DepartureReason, at: Date)] = [:]

    public init() {}

    public func record(_ key: ProcessKey, _ reason: DepartureReason) {
        lock.lock(); defer { lock.unlock() }
        // 강제 종료가 정리(SIGTERM)보다 우선한다.
        if let existing = entries[key], existing.reason == .evictedByReMON, reason != .evictedByReMON { return }
        entries[key] = (reason, Date())
    }

    public func reason(for key: ProcessKey) -> DepartureReason? {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { Date().timeIntervalSince($0.value.at) < 120 }
        return entries[key]?.reason
    }
}

public struct HistoryPoint: Codable, Sendable, Equatable {
    public var time: Date
    public var diskAvailable: UInt64
    public var swapUsed: UInt64
    public var memoryUsed: UInt64
    public var pressure: Int
    public var sessions: Int
}

/// 24시간 그래프용(1분 1점, 최대 1,440점). Application Support에 보관한다.
public final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [HistoryPoint] = []
    private let url: URL?
    private var lastSave = Date.distantPast

    public init(url: URL? = HistoryStore.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([HistoryPoint].self, from: data) {
            points = decoded.filter { Date().timeIntervalSince($0.time) < 86_400 }
        }
    }

    public static var defaultURL: URL? {
        if let folder = ProcessInfo.processInfo.environment["REMON_VAULT_DIR"] {
            return URL(fileURLWithPath: folder).appendingPathComponent("history.json")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("ReMON/history.json")
    }

    public func append(_ point: HistoryPoint) {
        lock.lock()
        points.append(point)
        points.removeAll { point.time.timeIntervalSince($0.time) > 86_400 }
        let shouldSave = point.time.timeIntervalSince(lastSave) > 300
        lock.unlock()
        if shouldSave { save() }
    }

    public func all() -> [HistoryPoint] {
        lock.lock(); defer { lock.unlock() }
        return points
    }

    public func save() {
        guard let url else { return }
        let snapshot = all()
        lastSave = Date()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}

public struct AlertSettings: Codable, Sendable, Equatable {
    public var diskThreshold: UInt64 = 15 * 1_073_741_824
    public var swapGrowthPerMinute: UInt64 = 1_073_741_824
    public var notifyCriticalPressure = true
    public init() {}
}

/// 경보 판정(사양 6장): 디스크 여유 임계 미만 · 스왑 1분 증가량 초과 · 메모리 압박 '위험'. 순수 함수라 가상 부하로 시험한다.
public enum AlertRules {
    public static func evaluate(system: SystemSnapshot, swapMinuteAgo: UInt64?, settings: AlertSettings) -> [ReMONAlert.Kind] {
        var kinds: [ReMONAlert.Kind] = []
        if system.disk.available < settings.diskThreshold { kinds.append(.diskLow) }
        if let before = swapMinuteAgo, system.swap.used > before, system.swap.used - before > settings.swapGrowthPerMinute { kinds.append(.swapSurge) }
        if settings.notifyCriticalPressure, system.pressure == .critical { kinds.append(.pressureCritical) }
        return kinds
    }
}

/// 메모리 압박 전환을 '유지된 변화'로만 알린다. 10-25 실측: 14시간에 104번 전환(평균 8분마다) → 사건 기록이 전환으로 뒤덮이고 자동 정리가 매번 시도됐다.
/// 새 단계가 hold 동안 이어질 때만 전환으로 친다. '위험'으로 올라가는 것은 바로 알린다.
public struct PressureGate: Sendable, Equatable {
    public var hold: TimeInterval
    public private(set) var reported: PressureLevel?
    private var candidate: (level: PressureLevel, since: Date)?

    public init(hold: TimeInterval = 300) { self.hold = hold }

    /// 전환이 확정되면 (이전, 현재)를 돌려준다.
    public mutating func observe(_ level: PressureLevel, now: Date) -> (from: PressureLevel, to: PressureLevel)? {
        guard let reported else { self.reported = level; candidate = nil; return nil }
        guard level != reported else { candidate = nil; return nil }
        if candidate?.level != level { candidate = (level, now) }
        let held = now.timeIntervalSince(candidate!.since)
        guard level == .critical || held >= hold else { return nil }
        self.reported = level
        candidate = nil
        return (reported, level)
    }

    public static func == (a: PressureGate, b: PressureGate) -> Bool { a.hold == b.hold && a.reported == b.reported }
}

public struct ReMONAlert: Sendable, Identifiable, Equatable {
    public enum Kind: String, Sendable { case diskLow, swapSurge, pressureCritical, cleanupAvailable }
    public var id = UUID()
    public var kind: Kind
    public var title: String
    public var body: String
    public var causes: [String]

    public init(kind: Kind, title: String, body: String, causes: [String]) {
        self.kind = kind
        self.title = title
        self.body = body
        self.causes = causes
    }
}

/// 수집 주기 관리: 시스템 1초, 사무실(프로세스·세션) 2초, top 보충 30초, Orca 제목 20초.
public final class Monitor: @unchecked Sendable {
    public var onSystem: ((SystemSnapshot) -> Void)?
    public var onOffice: ((OfficeSnapshot, [OfficeEvent]) -> Void)?
    public var onAlert: ((ReMONAlert) -> Void)?

    public let terminations = TerminationRegistry()
    public let history: HistoryStore
    public var alertSettings = AlertSettings()
    public var officeInterval: Int = 30
    /// 세션 목록은 열린 창에서 2초, 상주 중 30초. top은 30초/5분, Orca는 20초/2분. 시스템 계측은 항상 1초.
    public var foreground = false {
        didSet { officeInterval = foreground ? 2 : 30 }
    }

    private let queue = DispatchQueue(label: "remon.monitor", qos: .utility)
    private let systemSampler = SystemSampler()
    private let processSampler = ProcessSampler()
    public let detector = SessionDetector()
    /// 세션 하위 계보 기록 · 세션이 끝난 뒤 남은 보조 프로세스(G2).
    public let helpers = HelperTracker()
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var tick = 0
    private var lastSystem: SystemSnapshot?
    private var pressureGate = PressureGate()
    private var lastSwapEvent = Date.distantPast
    private var previous: [ProcessKey: AgentSession]?
    private var orcaTerminals: [OrcaTerminal] = []
    private var lastOrca = Date.distantPast
    private var lastTop = Date.distantPast
    private var topRunning = false
    private var swapWindow: [(Date, UInt64)] = []
    private var swapAnchor: UInt64?
    private var diskWasLow = false
    private var lastAlert: [ReMONAlert.Kind: Date] = [:]
    private var lastHistory = Date.distantPast
    private var latestOffice: OfficeSnapshot?
    private var lastRelief = Date.distantPast

    public init(history: HistoryStore = HistoryStore()) {
        self.history = history
    }

    public func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.step() }
        timer.resume()
        self.timer = timer
        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
        pressure.setEventHandler { [weak self] in self?.step(forceOffice: true) }
        pressure.resume()
        pressureSource = pressure
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
        history.save()
    }

    /// 정리 직후처럼 즉시 갱신이 필요할 때.
    public func refreshNow() {
        queue.async { [weak self] in self?.step(forceOffice: true) }
    }

    public func emit(_ event: OfficeEvent) {
        queue.async { [weak self] in
            guard let self, let office = self.latestOffice else { return }
            let callback = self.onOffice
            DispatchQueue.main.async { callback?(office, [event]) }
        }
    }

    private func step(forceOffice: Bool = false) {
        autoreleasepool {
            let now = Date()
            let system = systemSampler.sample(now: now)
            var events: [OfficeEvent] = []
            if let change = pressureGate.observe(system.pressure, now: now) {
                events.append(OfficeEvent(time: now, kind: .pressureChanged(from: change.from, to: change.to), text: "메모리 압박 \(change.from.label) → \(change.to.label)" + (change.to == .critical ? "" : " (5분 유지)")))
            }
            trackSwap(system, now: now, events: &events)
            trackDisk(system, events: &events)
            lastSystem = system
            let systemCallback = onSystem
            DispatchQueue.main.async { systemCallback?(system) }

            refreshTopIfNeeded(now: now)
            refreshOrcaIfNeeded(now: now)

            tick += 1
            guard forceOffice || tick % max(1, officeInterval) == 0 || previous == nil else {
                if !events.isEmpty, let office = latestOffice {
                    let callback = onOffice
                    DispatchQueue.main.async { callback?(office, events) }
                }
                return
            }
            let records = processSampler.sample(now: now)
            var result = detector.detect(records: records, sampler: processSampler, orca: orcaTerminals, now: now)
            ContextMetrics.shared.enrich(&result.sessions, now: now)   // 컨텍스트·누적 토큰·기록 크기(꼬리만 · 크기·수정 시각이 같으면 재사용)
            helpers.observe(records: records, sessions: result.sessions, now: now)
            let office = OfficeSnapshot(time: now, system: system, sessions: result.sessions, apps: result.apps,
                                        processCount: records.count, unaccountedMemory: system.memory.wired, standbyClaudeSpares: result.standbySpares, processes: records)
            events.append(contentsOf: diffSessions(result.sessions, now: now))
            latestOffice = office
            checkAlerts(system: system, office: office, now: now)
            if now.timeIntervalSince(lastHistory) >= 60 {
                lastHistory = now
                history.append(HistoryPoint(time: now, diskAvailable: system.disk.available, swapUsed: system.swap.used, memoryUsed: system.memory.used, pressure: system.pressure.rawValue, sessions: result.sessions.count))
            }
            let callback = onOffice
            DispatchQueue.main.async { callback?(office, events) }
            // 기록 꼬리 읽기 등으로 해제된 큰 버퍼를 운영체제에 돌려준다(빈 malloc 영역이 footprint로 남는 문제).
            if now.timeIntervalSince(lastRelief) > 30 {
                lastRelief = now
                malloc_zone_pressure_relief(nil, 0)
            }
        }
    }

    private func diffSessions(_ sessions: [AgentSession], now: Date) -> [OfficeEvent] {
        let current = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        defer { previous = current }
        guard let previous else { return [] } // 첫 측정은 이미 출근해 있던 것으로 본다
        var events: [OfficeEvent] = []
        for session in sessions where previous[session.id] == nil {
            events.append(OfficeEvent(time: now, kind: .arrived(session.id), text: "\(session.kind.label) 세션 출근 · \(session.project)", sessionSnapshot: session))
        }
        for (key, old) in previous where current[key] == nil {
            let reason = terminations.reason(for: key) ?? .left
            let verb = reason == .evictedByReMON ? "쫓겨남" : "퇴근"
            events.append(OfficeEvent(time: now, kind: .departed(key, reason), text: "\(old.kind.label) 세션 \(verb) · \(old.project)", sessionSnapshot: old))
        }
        for session in sessions {
            guard let old = previous[session.id] else { continue }
            if old.state != session.state {
                events.append(OfficeEvent(time: now, kind: .stateChanged(session.id, from: old.state, to: session.state), text: "\(session.project) · \(old.state.label) → \(session.state.label)", sessionSnapshot: session))
            }
            if session.cpuPercent >= 80, old.cpuPercent < 80 {
                events.append(OfficeEvent(time: now, kind: .cpuSpike(session.id, percent: session.cpuPercent), text: "\(session.project) CPU \(Fmt.percent(session.cpuPercent)) 폭주", sessionSnapshot: session))
            }
        }
        return events
    }

    private func trackSwap(_ system: SystemSnapshot, now: Date, events: inout [OfficeEvent]) {
        let used = system.swap.used
        let anchor = swapAnchor ?? used
        swapAnchor = anchor
        let delta = Int64(used) - Int64(anchor)
        // 1GB 넘게 움직였고 지난 사건에서 5분이 지났을 때만 적는다(0.5GB 오르내림이 1분마다 기록을 덮던 문제, 10-25). 짐꾼 연출은 스냅샷 값을 따로 따른다.
        if abs(delta) >= 1_073_741_824, now.timeIntervalSince(lastSwapEvent) >= 300 {
            events.append(OfficeEvent(time: now, kind: .swapMoved(deltaBytes: delta), text: delta > 0 ? "스왑 \(Fmt.gb(UInt64(delta))) 증가 · 상자가 지하로" : "스왑 \(Fmt.gb(UInt64(-delta))) 감소"))
            swapAnchor = used
            lastSwapEvent = now
        } else if abs(delta) >= 1_073_741_824 {
            swapAnchor = used   // 기록은 건너뛰어도 기준은 옮긴다(누적해서 한꺼번에 큰 수로 적지 않게)
        }
        swapWindow.append((now, used))
        swapWindow.removeAll { now.timeIntervalSince($0.0) > 61 }
    }

    private func trackDisk(_ system: SystemSnapshot, events: inout [OfficeEvent]) {
        let low = system.disk.available < alertSettings.diskThreshold
        if low != diskWasLow {
            events.append(OfficeEvent(time: system.time, kind: low ? .diskLow(availableBytes: system.disk.available) : .diskRecovered(availableBytes: system.disk.available),
                                      text: low ? "디스크 여유 \(Fmt.gb(system.disk.available)) · 임계 미만" : "디스크 여유 회복 · \(Fmt.gb(system.disk.available))"))
            diskWasLow = low
        }
    }

    private func checkAlerts(system: SystemSnapshot, office: OfficeSnapshot, now: Date) {
        var heavy: [(String, UInt64)] = office.sessions.map { ("\($0.kind.label) · \($0.project)", $0.footprint) }
        heavy += office.apps.filter { $0.category != .system }.map { ($0.name, $0.footprint) }
        let causes = heavy.sorted { $0.1 > $1.1 }.prefix(3).map { "\($0.0) \(Fmt.gb($0.1))" }
        func fire(_ kind: ReMONAlert.Kind, _ title: String, _ body: String) {
            if let last = lastAlert[kind], now.timeIntervalSince(last) < 600 { return }
            lastAlert[kind] = now
            let alert = ReMONAlert(kind: kind, title: title, body: body, causes: Array(causes))
            let callback = onAlert
            DispatchQueue.main.async { callback?(alert) }
        }
        let minuteAgo = swapWindow.first.flatMap { now.timeIntervalSince($0.0) >= 55 ? $0.1 : nil }
        for kind in AlertRules.evaluate(system: system, swapMinuteAgo: minuteAgo, settings: alertSettings) {
            switch kind {
            case .diskLow: fire(.diskLow, "디스크 여유 \(Fmt.gb(system.disk.available))", "임계 \(Fmt.gb(alertSettings.diskThreshold)) 미만입니다. 스왑이 늘면 더 줄어듭니다.")
            case .swapSurge: fire(.swapSurge, "스왑 급증 · 1분에 \(Fmt.gb(system.swap.used - (minuteAgo ?? 0)))", "메모리를 많이 쥔 세션·앱을 닫으면 줄어듭니다.")
            case .pressureCritical: fire(.pressureCritical, "메모리 압박 위험", "macOS가 메모리를 강하게 회수하는 중입니다.")
            case .cleanupAvailable: break   // 앱이 세션 목록을 알 때 직접 띄운다(AppModel.cleanMemory)
            }
        }
    }

    private func refreshTopIfNeeded(now: Date) {
        guard !topRunning, now.timeIntervalSince(lastTop) > (foreground ? 30 : 300) else { return }
        topRunning = true
        lastTop = now
        DispatchQueue.global(qos: .background).async { [weak self] in
            let output = TopReader.run()
            self?.queue.async {
                guard let self else { return }
                self.topRunning = false
                if let output { self.processSampler.updateTopFallback(output.memoryByPID) }
            }
        }
    }

    private func refreshOrcaIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastOrca) > (foreground ? 20 : 120) else { return }
        lastOrca = now
        DispatchQueue.global(qos: .background).async { [weak self] in
            let terminals = OrcaBridge.list() ?? []
            self?.queue.async { self?.orcaTerminals = terminals }
        }
    }
}
