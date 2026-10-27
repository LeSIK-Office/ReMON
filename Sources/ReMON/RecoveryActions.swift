import AppKit
import ReMONCore

/// 위험 상태(왼쪽 아래 최적화 버튼을 띄우는 조건).
/// 위험 감지 패널의 최적화 종류.
enum OptimizeKind: String { case memory, process, storage }

/// 버튼 아래 한 줄 결과(마지막 실행). good이면 무언가 실제로 정리됐다.
struct OptimizeNote: Equatable {
    var text: String
    var good: Bool
    var time = Date()
}

struct RiskState: Equatable {
    var memory: String?
    var process: String?
    var disk: String?
    var any: Bool { memory != nil || process != nil || disk != nil }
    var count: Int { [memory, process, disk].compactMap { $0 }.count }
}

// 복구 금고 · 위험 시 최적화(트레이너 · 청소 특공대). 정리 동작은 AppModel.execute(금고 먼저)를 거친다.
extension AppModel {
    // MARK: 복구 키

    func recoveryKey(for session: AgentSession) -> ResumeKey.Result {
        let entry = claudeRegistry.load()[session.rootPID]
        return ResumeKey.resolve(session, registrySessionID: entry?.sessionId, argv: ProcessSampler.readArguments(pid: session.rootPID)?.argv ?? [], registryKind: entry?.kind)
    }

    func recoveryLine(_ key: ResumeKey.Result) -> String {
        switch key {
        case .exact: "복구: \(key.label) — 정리해도 정신교육실에서 같은 대화로 복귀시킬 수 있습니다"
        case .nothingToLose: "복구: \(key.label)"
        case .uncertain, .unsupported: "⚠️ \(key.label) — 정리하면 이 대화는 이어 열 수 없습니다"
        }
    }

    // MARK: 금고 동기화

    /// 5초마다(또는 정리 직후): 복귀 확인 · 직접 이어 연 세션 반영 · 화면 사본 갱신 · 정신교육실 인물. 1시간마다 만료 처리.
    func syncRecovery(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastRecoverySync) > 5 else { return }
        lastRecoverySync = Date()
        let sessions = office?.sessions ?? []
        let registry = verifiedRegistry(sessions)
        for entry in vault.settleRetiring() where entry.status == .held { append(.trainer, "정신교육실 보관 · \(entry.project) · 종료 확인 뒤 복구 키 보관") }
        let changed = RecoveryRestorer.reconcile(vault: vault, sessions: sessions, registry: registry)
        for entry in changed {
            switch entry.status {
            case .restored: append(.arrive, (entry.kind == .process ? "다시 띄움 · " : "복귀 완료 · ") + "\(entry.project) · \(entry.title)")
            case .held: append(.alert, (entry.kind == .process ? "다시 띄우기 확인 안 됨 · \(entry.project) — 앱이 열렸는지, 터미널 창의 종료 코드를 확인하세요" : "복귀 확인 안 됨 · \(entry.project) — 열린 터미널 창을 확인하세요"))
            default: break
            }
        }
        if Date().timeIntervalSince(lastVaultExpire) > 3600 {
            lastVaultExpire = Date()
            let expired = vault.expire()
            if expired > 0 { append(.info, "복구함 만료 \(expired)건(보관 기간 지남·휴지통 비움)") }
        }
        let all = vault.all()
        if all != recovery { recovery = all }
        // 정신교육실: ReMON이 정리했거나 비정상으로 끝난 세션. 스스로 정상 종료한 것은 복구함 목록에만(방이 붐비지 않게).
        scene?.setRetired(all.filter { $0.kind == .session && ($0.status == .held || $0.status == .restoring) && $0.departure != DepartureCause.normal.rawValue }) { [weak self] id in self?.selectRecovery(id) }
        let counts = vaultCounts
        scene?.setVault(OfficeScene.VaultSummary(sessions: counts.sessions, files: counts.files, git: counts.git, processes: counts.processes, expired: counts.expired, bytes: counts.bytes))
        pushSpeechContext()
    }

    /// 레지스트리 pid → sessionId 중, 그 pid의 지금 프로세스 시작 시각과 레지스트리 시작 시각이 맞는 것만(남은 파일·pid 재사용 오판 방지).
    func verifiedRegistry(_ sessions: [AgentSession]) -> [Int32: String] {
        let starts = Dictionary(sessions.map { ($0.rootPID, $0.startTime) }, uniquingKeysWith: { first, _ in first })
        var result: [Int32: String] = [:]
        for (pid, entry) in claudeRegistry.load() {
            guard let id = entry.sessionId, let start = starts[pid] else { continue }
            if let registered = entry.startedAt, abs(registered.timeIntervalSince(start)) > 120 { continue }
            result[pid] = id
        }
        return result
    }

    var selectedRecoveryEntry: RecoveryEntry? {
        guard let id = selectedRecovery else { return nil }
        return recovery.first { $0.id == id }
    }

    func selectRecovery(_ id: String?) {
        selectedSession = nil
        selectedApp = nil
        selectedMachine = nil
        selectedBoss = false
        selectedRecovery = id
        scene?.select(nil)
    }

    // MARK: 되돌리기

    func restore(_ entry: RecoveryEntry) {
        switch entry.kind {
        case .session:
            let place = entry.backgroundJob != nil ? "Claude 백그라운드(터미널 없이, 같은 짧은 id \(entry.backgroundJob!))" : RecoveryLaunchers.placeLabel(for: entry)
            guard Confirm.ask(title: "\(entry.project) 세션을 복귀시킬까요?",
                              text: "\(entry.title)\n\n\(entry.resumeCommand ?? "")\n\n\(place)에서 같은 대화를 이어 엽니다. 기록 파일이 지워졌으면 보관본으로 먼저 되돌립니다." +
                                  (entry.backgroundJob.map { "\n복귀 뒤 터미널에서 보려면: claude attach \($0)" } ?? ""),
                              action: "복귀시키기") else { return }
            let sessions = office?.sessions ?? []
            let registry = verifiedRegistry(sessions)
            let vault = self.vault
            let launcher = RecoveryLaunchers.live(folder: vault.launchFolder)
            scene?.retiredStand(entry.id)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = RecoveryRestorer.restoreSession(entry, vault: vault, sessions: sessions, registry: registry, launcher: launcher)
                DispatchQueue.main.async { self?.finishRestore(entry, result) }
            }
        case .trash where StartupItemManager.isStartupEntry(entry):
            // 끈 시작 항목: plist를 되돌리고 launchd에 다시 올린다(다음 로그인을 기다리지 않음).
            guard Confirm.ask(title: "시작 항목을 다시 켤까요?", text: "\(entry.originalPath ?? entry.title)\n원래 자리로 되돌리고 바로 다시 올립니다.", action: "다시 켜기") else { return }
            restoreStartupItem(entry) { [weak self] in self?.syncRecovery(force: true) }
        case .trash:
            guard Confirm.ask(title: "원래 자리로 되돌릴까요?", text: "\(entry.trashedPath ?? "")\n→ \(entry.originalPath ?? "")", action: "되돌리기") else { return }
            finishRestore(entry, RecoveryRestorer.restoreTrash(entry, vault: vault))
            scanDisk()
        case .branch, .worktree:
            guard Confirm.ask(title: "같은 커밋으로 되살릴까요?", text: "\(entry.restoreHint ?? "")\n\n커밋 \(entry.head?.prefix(8) ?? "")에서 다시 만듭니다.", action: "되살리기") else { return }
            let vault = self.vault
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = RecoveryRestorer.restoreGit(entry, vault: vault)
                DispatchQueue.main.async {
                    self?.finishRestore(entry, result)
                    self?.scanLeftovers()
                }
            }
        case .deleted:
            Confirm.info(title: "되돌릴 수 없는 항목입니다", text: "\(entry.originalPath ?? entry.title)\n\n\(entry.restoreHint ?? "다시 만들어지는 캐시입니다")")
        case .codexArchive:
            restoreCodexThread(entry)   // AIDataActions.swift
        case .process:
            restoreProcess(entry)   // ProcessCareActions.swift
        }
    }

    private func finishRestore(_ entry: RecoveryEntry, _ result: RecoveryRestorer.Result) {
        lastActionMessage = result.message
        append(result.ok ? .arrive : .alert, (result.ok ? "되돌리기 · " : "되돌리기 실패 · ") + "\(entry.project) · \(entry.title) · \(result.message)")
        if !result.ok { Confirm.info(title: "되돌리지 못했습니다", text: result.message + (entry.resumeCommand.map { "\n\n직접 실행할 명령:\n\($0)" } ?? "")) }
        syncRecovery(force: true)
    }

    func copyRecoveryCommand(_ entry: RecoveryEntry) {
        guard let command = entry.resumeCommand ?? entry.restoreHint else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        append(.info, "복구 명령 복사 · \(entry.project)")
    }

    /// 보관 해제: 금고에서 빼고 보관본을 지운다(되돌릴 수 없게 됨).
    func forget(_ entry: RecoveryEntry) {
        guard Confirm.ask(title: "보관을 해제할까요?", text: "\(entry.title)\n이 항목과 기록 보관본을 지웁니다. 이후에는 복귀시킬 수 없습니다.", action: "보관 해제", destructive: true) else { return }
        try? vault.remove(entry.id)
        if selectedRecovery == entry.id { selectedRecovery = nil }
        syncRecovery(force: true)
    }

    // MARK: 진단 보고서 · 누적 정리량

    var recoveryTotals: DiagnosticsReport.Totals { DiagnosticsReport.totals(recovery) }

    /// 지원·문의용 진단 보고서를 클립보드로(경로는 ~, 비밀값·세션 제목·명령 인자는 넣지 않음).
    func copyDiagnostics() {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발판") + " (" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-") + ")"
        let text = DiagnosticsReport.build(system: system, sessions: office?.sessions ?? [], processes: office?.processes ?? [], appVersion: version,
                                           vault: recovery, actionsLog: AuditLog.shared.url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastActionMessage = "진단 보고서를 복사했습니다(\(text.split(separator: "\n").count)줄)"
        append(.info, lastActionMessage!)
    }

    // MARK: 위험 시 최적화

    /// 위험 = ReMON이 실제로 돌려받을 수 있거나 지금 나빠지는 것만(10-25 설계 감사: 스왑 ≥ 4GB 같은 절대 기준은 이 Mac에서 늘 켜져 있어 신호가 아니었다).
    /// 메모리: 정리 가능한 쉬는 세션 메모리 ≥ 1GB, 또는 스왑이 10분에 2GB 넘게 늘어남, 또는 압박 '위험'. 프로세스: 탭 닫힘·고아 세션·남은 보조 프로세스. 디스크: 여유가 기준(설정)×1.5 또는 10% 미만.
    var risks: RiskState {
        var state = RiskState()
        let reclaimable = memoryCleanupTargets().reduce(UInt64(0)) { $0 + $1.footprint }
        let growth = swapGrowth(minutes: 10)
        if system.pressure >= .critical || reclaimable >= UInt64(Fmt.gib) || growth >= 2 * UInt64(Fmt.gib) {
            var parts: [String] = []
            if reclaimable > 0 { parts.append("정리 가능 \(Fmt.gb(reclaimable))") }
            if growth >= 2 * UInt64(Fmt.gib) { parts.append("스왑 10분간 +\(Fmt.gb(growth))") }
            if system.pressure >= .critical { parts.append("압박 위험") }
            state.memory = parts.joined(separator: " · ")
        }
        let leftovers = processOptimizationCandidates().filter { recoveryKey(for: $0).allowsAutoCleanup }
        let helpers = orphanHelperNote
        if !leftovers.isEmpty || helpers != nil {
            state.process = [leftovers.isEmpty ? nil : "탭 닫힘·고아 \(leftovers.count)개 · \(Fmt.gb(leftovers.reduce(0) { $0 + $1.footprint }))", helpers].compactMap { $0 }.joined(separator: " · ")
        }
        let disk = system.disk
        if disk.total > 0, Double(disk.available) < max(settings.diskThresholdGB * 1.5 * Fmt.gib, Double(disk.total) * 0.10) {
            state.disk = "여유 \(Fmt.gb(disk.available))"
        }
        return state
    }

    /// 최근 N분 동안 스왑이 늘어난 양(24시간 기록 1분 1점). 기록이 짧으면 0.
    func swapGrowth(minutes: Double) -> UInt64 {
        let cutoff = Date().addingTimeInterval(-minutes * 60)
        guard let past = history.last(where: { $0.time <= cutoff }) ?? history.first, history.count >= 2 else { return 0 }
        return system.swap.used > past.swapUsed ? system.swap.used - past.swapUsed : 0
    }

    /// 입력 대기로 6시간 넘게 멈춘 세션(대표님 답을 잊은 것으로 보임). 메모리·스왑을 가장 많이 쥐고 있는 경우가 많아,
    /// 메모리 최적화에서 확인을 한 번 받은 뒤 함께 정리한다(복구 키를 금고에 적으니 정신교육실에서 언제든 복귀).
    func longWaitingTargets() -> [AgentSession] {
        Self.longWaiting(office?.sessions ?? [], now: Date()) { [self] in isPinned($0) || !plan(for: $0).blockers.isEmpty || $0.stateConfidence != .confirmed }
    }

    /// 고르기 규칙(장면 시험이 직접 부른다): 입력 대기 · 마지막 활동 6시간+ · 보호(고정·보호 규칙) 아님 · 큰 것부터.
    nonisolated static func longWaiting(_ sessions: [AgentSession], now: Date, held: (AgentSession) -> Bool) -> [AgentSession] {
        sessions.filter { session in
            guard session.state == .waiting else { return false }
            let silence = session.lastActivity.map { now.timeIntervalSince($0) } ?? now.timeIntervalSince(session.startTime)
            return silence >= 6 * 3600
        }
        .filter { !held($0) }
        .sorted { $0.footprint > $1.footprint }
    }

    /// 버튼 아래 결과 한 줄 + 사건 기록. 패널은 결과를 몇 분 동안 보여 준다.
    func noteOptimize(_ kind: OptimizeKind, _ text: String, good: Bool) {
        optimizeNotes[kind] = OptimizeNote(text: text, good: good)
        append(good ? .cleanup : .info, text)
    }

    /// 정리할 세션이 없을 때 이유를 숫자로(일하는 중 · 입력 대기 6시간 미만 · 잠깐 쉼 · 보호 · 복구 키 없음).
    private func nothingToRetire(keyless: Int) -> String {
        let sessions = office?.sessions ?? []
        let now = Date()
        func silence(_ session: AgentSession) -> TimeInterval { now.timeIntervalSince(session.lastActivity ?? session.startTime) }
        let working = sessions.filter { $0.state == .working }.count
        let freshWaiting = sessions.filter { $0.state == .waiting && silence($0) < 6 * 3600 }.count
        let shortIdle = sessions.filter { $0.state == .idle || ($0.state == .longIdle && silence($0) < 3 * 3600) }.count
        let held = sessions.filter { $0.state != .working && (isPinned($0) || !plan(for: $0).blockers.isEmpty) }.count
        var parts: [String] = []
        if working > 0 { parts.append("일하는 중 \(working)") }
        if freshWaiting > 0 { parts.append("입력 대기 \(freshWaiting)(6시간 미만)") }
        if shortIdle > 0 { parts.append("잠깐 쉼 \(shortIdle)(3시간 미만)") }
        if held > 0 { parts.append("보호 \(held)") }
        if keyless > 0 { parts.append("복구 키 없음 \(keyless)(세션 카드에서 하나씩)") }
        return parts.isEmpty ? "세션 없음" : parts.joined(separator: " · ")
    }

    /// 메모리 최적화: 트레이너가 들어와 복구 키를 확보한 오래 쉰(3시간+)·고아 세션을 정리하고, 6시간 넘게 입력 대기인 세션은
    /// 확인을 받은 뒤 함께 정리한다. 12초 뒤 실제 메모리·스왑 변화를 재서 짐꾼이 그만큼 상자를 빼 간다.
    func optimizeMemory() {
        retireForOptimization(memoryCleanupTargets(), waiting: longWaitingTargets(), kind: .memory, reason: "메모리 최적화", trainerText: "메모리 최적화! 오래 쉰 세션 정리")
    }

    /// 프로세스 최적화: Orca 탭이 닫혔거나 부모가 사라진 세션(프로세스만 남은 것)과, 세션이 끝난 뒤 남은 보조 프로세스(10분+ 쉼)를 정리한다.
    func optimizeProcesses() {
        let candidates = processOptimizationCandidates()
        let helperTargets = orphanHelperTargets
        if !helperTargets.isEmpty {
            optimizeHelpers(confirm: false)
            noteOptimize(.process, "프로세스 최적화 · 남은 보조 프로세스 \(helperTargets.count)개 정리 · 약 \(Fmt.size(helperTargets.reduce(0) { $0 + $1.footprint }))", good: true)
        }
        guard !candidates.isEmpty else {
            if helperTargets.isEmpty {
                let waitingHelpers = orphanHelpers.count
                let leftovers = (office?.sessions ?? []).filter { $0.tabLeftover || $0.state == .orphan }
                var why: [String] = []
                if waitingHelpers > 0 { why.append("남은 보조 프로세스 \(waitingHelpers)개는 아직 10분이 안 됐거나 보호 대상이라 기다림") }
                if !leftovers.isEmpty { why.append("탭 닫힘·고아 \(leftovers.count)개는 일하는 중·입력 대기·보호라 남김") }
                noteOptimize(.process, "프로세스 최적화 · 지금 끝낼 것 없음" + (why.isEmpty ? "" : " — " + why.joined(separator: " · ")), good: false)
            }
            return
        }
        retireForOptimization(candidates, waiting: [], kind: .process, reason: "프로세스 최적화(탭 닫힘·고아)", trainerText: "남은 프로세스 정리!")
    }

    func processOptimizationCandidates() -> [AgentSession] {
        (office?.sessions ?? []).filter {
            ($0.tabLeftover || $0.state == .orphan) && $0.stateConfidence == .confirmed && $0.state != .working && $0.state != .waiting && !isPinned($0) && plan(for: $0).blockers.isEmpty
        }
    }

    private func retireForOptimization(_ candidates: [AgentSession], waiting: [AgentSession], kind: OptimizeKind, reason: String, trainerText: String) {
        let plans = candidates.map { (plan: plan(for: $0), key: recoveryKey(for: $0)) }
        var ready = plans.filter { $0.plan.blockers.isEmpty && $0.key.allowsAutoCleanup }
        let waitingPlans = waiting.filter { session in !candidates.contains { $0.id == session.id } }.map { (plan: plan(for: $0), key: recoveryKey(for: $0)) }
        let waitingReady = waitingPlans.filter { $0.plan.blockers.isEmpty && $0.key.allowsAutoCleanup }
        let keyless = (plans + waitingPlans).filter { $0.plan.blockers.isEmpty && !$0.key.allowsAutoCleanup }
        // 세션을 끝내기 전에 대상 목록을 한 번 보여 준다(10-25 사고 뒤: 보는 사이 없이 세션이 끝나는 일이 없게).
        var includeWaiting = false
        if !ready.isEmpty || !waitingReady.isEmpty {
            func line(_ item: (plan: SessionTerminator.Plan, key: ResumeKey.Result), _ kind: String) -> String {
                let silence = Date().timeIntervalSince(item.plan.session.lastActivity ?? item.plan.session.startTime)
                return "• \(item.plan.session.project) · \(item.plan.session.kind.shortLabel) · \(Fmt.size(item.plan.session.footprint)) · \(kind) \(Fmt.duration(silence)) · \(item.plan.session.displayTitle.prefix(24))"
            }
            var text = ""
            if !ready.isEmpty { text += "오래 쉰·탭 닫힘 \(ready.count)개:\n" + ready.prefix(8).map { line($0, $0.plan.session.state == .orphan ? "탭 닫힘" : "쉼") }.joined(separator: "\n") + (ready.count > 8 ? "\n… 외 \(ready.count - 8)개" : "") + "\n\n" }
            if !waitingReady.isEmpty { text += "입력 대기로 6시간 넘게 멈춤 \(waitingReady.count)개:\n" + waitingReady.prefix(8).map { line($0, "입력 대기") }.joined(separator: "\n") + (waitingReady.count > 8 ? "\n… 외 \(waitingReady.count - 8)개" : "") + "\n\n" }
            text += "복구 키를 금고에 먼저 적고 정리합니다. 정신교육실에서 누르면 같은 대화로 돌아옵니다(백그라운드 세션은 백그라운드로)."
            let total = (ready + waitingReady).reduce(UInt64(0)) { $0 + $1.plan.session.footprint }
            let buttons = !ready.isEmpty && !waitingReady.isEmpty ? ["모두 정리", "오래 쉰·탭 닫힘만", "취소"] : ["정리", "취소"]
            let choice = Confirm.choose(title: "\(reason) · 세션 \(ready.count + waitingReady.count)개 · 약 \(Fmt.gb(total))", text: text, buttons: buttons)
            if choice == buttons.count - 1 {
                noteOptimize(kind, "\(reason) · 취소", good: false)
                return
            }
            if waitingReady.isEmpty || ready.isEmpty {
                includeWaiting = !waitingReady.isEmpty
                if ready.isEmpty { ready = waitingReady }
            } else {
                includeWaiting = choice == 0
                if includeWaiting { ready += waitingReady }
            }
        }
        guard !ready.isEmpty else {
            let detail = nothingToRetire(keyless: keyless.count)
            noteOptimize(kind, "\(reason) · 정리할 세션 없음 — \(detail)", good: false)
            // 글 한 줄만 남기면 '반응이 없다'고 느낀다(10-25 두 번 지적): 트레이너가 들어와 왜 없는지 말하고 나간다.
            if scene != nil {
                page = .office
                // 호루라기 말풍선은 짧게(앞의 두 이유만) — 전체 이유는 버튼 아래 줄과 사건 기록에.
                scene?.trainerVisit(reclaimed: 0, text: "정리할 세션이 없어요 · " + detail.components(separatedBy: " · ").prefix(2).joined(separator: " · "))
            }
            return
        }
        let before = (memory: system.memory.used, swap: system.swap.used)
        let bytes = ready.reduce(UInt64(0)) { $0 + $1.plan.session.footprint }
        optimizeBusy = kind
        optimizeNotes[kind] = OptimizeNote(text: "\(reason) · \(ready.count)개 정리 중 · 예상 \(Fmt.gb(bytes)) · 12초 뒤 실측합니다", good: true)
        page = .office
        scene?.trainerVisit(reclaimed: bytes, text: trainerText)
        let waitingIDs = Set(waitingReady.map(\.plan.session.id))
        for item in ready {
            executeTermination(item.plan, force: false, reason: reason, requireKey: true, auto: true, allowWaiting: includeWaiting && waitingIDs.contains(item.plan.session.id))
        }
        append(.trainer, "\(reason) · \(ready.count)개 정리(복구 키 보관) · 약 \(Fmt.gb(bytes))" + (keyless.isEmpty ? "" : " · 키 없는 \(keyless.count)개 제외"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self else { return }
            self.monitor.refreshNow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                // 실측 = 실제로 끝난 세션들의 메모리 합(시스템 수치는 다른 앱 변동과 섞여 참고로만).
                let gone = ready.filter { !SessionTerminator.isAlive($0.plan.session.id) }
                let measured = gone.reduce(UInt64(0)) { $0 + $1.plan.session.footprint }
                let swap = Int64(before.swap) - Int64(self.system.swap.used)
                let freedSwap = UInt64(max(0, swap))
                self.optimizeBusy = nil
                self.noteOptimize(kind, "\(reason) 결과 · 실측 회수 \(Fmt.gb(measured))(세션 \(gone.count)/\(ready.count) 종료) · 시스템 메모리 \(Fmt.gb(before.memory)) → \(Fmt.gb(self.system.memory.used))(참고)" +
                                  " · 스왑 \(Fmt.gb(before.swap)) → \(Fmt.gb(self.system.swap.used))" + (swap > 0 ? " (−\(Fmt.gb(freedSwap)))" : " (스왑은 쓰던 앱이 끝나야 줄어듭니다)"), good: gone.count > 0)
                self.scene?.trainerAnnounce(measured: measured, text: "시스템 메모리 \(Fmt.gb(before.memory)) → \(Fmt.gb(self.system.memory.used))")
                self.afterSwapMeasured(freedSwap)
            }
        }
    }

    /// 실제로 줄어든 스왑만큼 기계실 짐꾼이 상자를 빼 간다(1상자 ≈ 1GB · 0이면 둘러보고 '뺄 상자가 없네요').
    private func afterSwapMeasured(_ freedSwap: UInt64) {
        scene?.porterUnload(freedBytes: freedSwap, caption: freedSwap > 0 ? "스왑 \(Fmt.gb(freedSwap)) 줄었습니다 · 짐꾼이 상자를 빼 갑니다" : "스왑은 그대로입니다 · 쓰던 앱이 끝나야 줄어듭니다")
    }

    /// 저장소 정리: 청소 특공대가 '다시 생기는 것'만 영구 삭제(공간이 실제로 돌아온다)하고, 병합된 부산물을 치운다(금고 기록).
    /// 휴지통으로만 보낼 수 있는 것은 공간이 돌아오지 않으므로 여기서 다루지 않는다. 확인은 한 번.
    func optimizeStorage() {
        guard optimizeBusy != .storage || diskScanning == false else { return }
        if diskScannedAt == nil || Date().timeIntervalSince(diskScannedAt ?? .distantPast) > 1800 {
            // 조사는 10~20초 걸린다: 버튼에 진행을 띄워 '반응이 없다'고 느끼지 않게.
            optimizeBusy = .storage
            optimizeNotes[.storage] = OptimizeNote(text: "저장소 정리 · 먼저 디스크를 살펴보는 중…", good: true)
            append(.info, "저장소 정리 · 먼저 디스크를 살펴봅니다")
            scanDisk { [weak self] in
                self?.optimizeBusy = nil
                self?.optimizeStorage()
            }
            return
        }
        let active = Set((office?.sessions ?? []).compactMap(\.cwd))
        let deletable = diskItems.compactMap { item -> (item: DiskItem, tier: CacheDeletionPolicy.Tier)? in
            let tier = CacheDeletionPolicy.tier(for: item, activeDirectories: active)
            return tier == .trashOnly ? nil : (item, tier)
        }
        let leftoverProjects = leftovers.filter { $0.cleanableCount > 0 }
        let trashOnly = diskItems.filter { $0.category == .regenerable && CacheDeletionPolicy.tier(for: $0, activeDirectories: active) == .trashOnly }
        guard !deletable.isEmpty || !leftoverProjects.isEmpty else {
            noteOptimize(.storage, "저장소 정리 · 지금 영구 삭제할 캐시·부산물 없음" + (trashOnly.isEmpty ? "" : " — 휴지통으로만 옮길 항목 \(trashOnly.count)곳(\(Fmt.gb(trashOnly.reduce(0) { $0 + $1.bytes })))은 정리 화면에서 고르세요"), good: false)
            return
        }
        let bytes = deletable.reduce(UInt64(0)) { $0 + $1.item.bytes }
        var lines = deletable.prefix(10).map { "• " + $0.item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " · \(Fmt.gb($0.item.bytes)) · \($0.tier == .pureCache ? "순수 캐시" : "다시 빌드·설치")" }
        if deletable.count > 10 { lines.append("… 외 \(deletable.count - 10)곳") }
        if !leftoverProjects.isEmpty { lines.append("• 병합된 부산물 \(leftoverProjects.reduce(0) { $0 + $1.cleanableCount })개(워크트리·브랜치 — 복구함에서 되살림)") }
        let trashBytes = diskItems.first { $0.category == .trash }?.bytes ?? 0
        let text = lines.joined(separator: "\n") + "\n\n캐시는 영구 삭제해 공간을 바로 돌려받습니다(되돌리기 대신 다시 만들어짐). 쓰는 중인 프로젝트·하루 안에 바뀐 산출물·잠금 파일 없는 node_modules는 건드리지 않습니다." +
            (trashBytes > 0 ? "\n휴지통 \(Fmt.gb(trashBytes))는 Finder에서 직접 비우세요." : "") + (settings.dryRun ? "\n\n드라이런: 지우지 않고 결과만 기록합니다." : "")
        guard Confirm.ask(title: "저장소 정리 · 약 \(Fmt.gb(bytes)) 확보(영구 삭제)", text: text, action: settings.dryRun ? "드라이런" : "청소 특공대 출동", destructive: true) else { return }
        let dryRun = settings.dryRun
        let pids = userPIDs
        let sessions = office?.sessions ?? []
        let vault = self.vault
        let beforeFree = system.disk.available
        page = .office
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var freed: [String: (bytes: UInt64, items: Int)] = [:]
            var failures: [String] = []
            for (item, _) in deletable {
                let project = item.path.hasPrefix(NSHomeDirectory() + "/DEV/") ? SessionDetector.projectName(for: item.path) : "공용 캐시"
                do {
                    try SafeFileOps.deletePermanently(item.path, userPIDs: pids, dryRun: dryRun, bytes: item.bytes, vault: dryRun ? nil : vault, project: project,
                                                      reason: "저장소 정리", regeneration: CacheDeletionPolicy.regenerationHint(for: item))
                    freed[project, default: (0, 0)].bytes += item.bytes
                    freed[project, default: (0, 0)].items += 1
                } catch {
                    failures.append("\((item.path as NSString).lastPathComponent): \(error)")
                }
            }
            let results = leftoverProjects.isEmpty ? [] : LeftoverCleaner.clean(leftoverProjects, dryRun: dryRun, sessions: sessions, vault: dryRun ? nil : vault)
            DispatchQueue.main.async {
                guard let self else { return }
                let cleaned = results.filter { $0.ok && !$0.skipped }
                for (project, value) in freed.sorted(by: { $0.value.bytes > $1.value.bytes }) where !dryRun {
                    self.monitor.emit(OfficeEvent(kind: .tidy(reclaimedBytes: value.bytes, project: project == "공용 캐시" ? nil : project, items: value.items),
                                                  text: "청소 특공대 · \(project) · \(value.items)곳 · \(Fmt.gb(value.bytes))"))
                }
                let total = freed.values.reduce(UInt64(0)) { $0 + $1.bytes }
                self.append(.cleanup, (dryRun ? "드라이런 · " : "") + "저장소 정리 · 캐시 \(freed.values.reduce(0) { $0 + $1.items })곳 \(Fmt.gb(total))" +
                            (cleaned.isEmpty ? "" : " · 부산물 \(cleaned.count)개") + (failures.isEmpty ? "" : " · 건너뜀 \(failures.count)(\(failures.prefix(2).joined(separator: "; ")))"))
                self.diskItems.removeAll { item in !dryRun && deletable.contains { $0.item.path == item.path } && !FileManager.default.fileExists(atPath: item.path) }
                self.syncRecovery(force: true)
                self.monitor.refreshNow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !dryRun else { return }
                    let after = self.system.disk.available
                    self.append(.cleanup, "디스크 여유 \(Fmt.gb(beforeFree)) → \(Fmt.gb(after))" + (after > beforeFree ? " (+\(Fmt.gb(after - beforeFree)))" : ""))
                    self.scene?.janitorAnnounce(measured: after > beforeFree ? after - beforeFree : 0)
                    self.scanLeftovers()
                    self.refreshSuggestions()
                }
            }
        }
    }

    /// 위험이 둘 이상이면 한 번에: 세션(메모리·프로세스 대상의 합집합, 같은 세션을 두 번 정리하지 않음) → 저장소.
    func optimizeAll() {
        let state = risks
        if state.memory != nil || state.process != nil {
            var seen = Set<ProcessKey>()
            let leftovers = processOptimizationCandidates()
            let union = (leftovers + memoryCleanupTargets()).filter { seen.insert($0.id).inserted }
            if !orphanHelperTargets.isEmpty { optimizeHelpers(confirm: false) }
            retireForOptimization(union, waiting: state.memory != nil ? longWaitingTargets() : [], kind: state.memory != nil ? .memory : .process, reason: "한 번에 최적화", trainerText: "전부 최적화!")
        }
        if state.disk != nil { optimizeStorage() }
    }
}

// MARK: - 사라진 세션: 원인 판정 · 복구 기록(10-25 대표 지시)

extension AppModel {
    /// 세션이 사라지면 종료 상태(감시기) · 대화 기록 끝 · 크래시 보고서 · 그 시각 메모리 압박으로 원인을 정한다.
    /// ReMON이 끄지 않았으면 금고에 적는다 — 복구 키가 있으면 '보관 중'(정신교육실·복구함에서 복귀), 없으면 '사라짐'(무엇이 있었는지만).
    func recordDeparture(_ session: AgentSession, reason: DepartureReason, at time: Date) {
        let exits = exitWatcher.exits(for: session.pids, since: session.startTime)
        let pressure = system.pressure.label
        let vault = self.vault
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let tail = session.logPath.flatMap { DepartureForensics.transcriptTail($0, kind: session.kind) }
            let crash = DepartureForensics.crashReport(near: exits.map(\.time).max() ?? time, names: ["claude", "codex", "node", "opencode", "2.1."])
            let report = DepartureForensics.analyze(exits: exits, byReMON: reason != .left, tail: tail, crashReport: crash, pressure: pressure)
            var recorded: RecoveryEntry?
            if reason == .left {
                recorded = DepartureRecorder.record(session, report: report, vault: vault)
            } else if let mine = vault.all().first(where: { $0.kind == .session && $0.pid == session.rootPID && $0.processStart == session.id.start }), !report.evidence.isEmpty {
                // ReMON이 정리한 세션: 실제로 어떻게 끝났는지(종료 상태)를 금고 메모에 덧붙인다.
                try? vault.update(mine.id) { $0.note = ($0.note.map { $0 + " · " } ?? "") + report.evidence[0] }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                guard reason == .left else { self.syncRecovery(force: true); return }
                let restorable = recorded?.status == .held
                let tail = restorable ? " · 정신교육실·복구함에서 같은 대화로 복귀" : (recorded == nil ? "" : " · 복구 키 없음(무엇이 있었는지만 기록)")
                if report.cause.abnormal {
                    self.append(.alert, "세션이 끝남 · \(session.project) · \(session.kind.shortLabel) · \(report.summary)" + tail, session: session.id)
                } else {
                    self.append(.info, "세션 정상 종료 · \(session.project) · \(session.kind.shortLabel)" + (restorable ? " · 복구함에 복구 키 보관" : ""), session: session.id)
                }
                self.syncRecovery(force: true)
            }
        }
    }
}

