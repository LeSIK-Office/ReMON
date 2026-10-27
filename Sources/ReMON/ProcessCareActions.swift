import AppKit
import ReMONCore

// 남은 보조 프로세스(G2) · '왜 실행 중?'(G3) · 시작 항목(G4) · 프로세스 복구(다시 띄우기) 동작.
// 확장에는 저장 속성을 둘 수 없어 상태는 Monitor.helpers(추적기)와 각 화면(StartupItemsStore)이 가진다.
// 세션이 아닌 프로세스도 잃지 않는다: 끝내기 전에 금고에 실행 명령·폴더(앱은 번들 id)를 먼저 적고, 못 적으면 끝내지 않는다.

/// 같은 보조 프로세스를 두 경로가 동시에 끝내지 않게(메인 스레드 전용).
@MainActor private var terminatingHelpers = Set<ProcessKey>()

/// 동시 실행 결과 모음.
private final class OutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: HelperTerminator.Outcome] = [:]
    func set(_ index: Int, _ outcome: HelperTerminator.Outcome) { lock.lock(); values[index] = outcome; lock.unlock() }
    func all(_ count: Int) -> [HelperTerminator.Outcome] { lock.lock(); defer { lock.unlock() }; return (0..<count).compactMap { values[$0] } }
}

extension AppModel {
    // MARK: 남은 보조 프로세스(G2)

    /// 세션이 끝난 뒤 남은 보조 프로세스(ReMON이 세션 하위로 직접 본 것만). 메모리 큰 순, 사무실 주기마다 갱신.
    var orphanHelpers: [OrphanHelper] { monitor.helpers.orphans }

    /// '프로세스 최적화'가 끝낼 대상: N분(기본 10분) 넘게 쉬고 보호 규칙에 걸리지 않는 것.
    var orphanHelperTargets: [OrphanHelper] { orphanHelpers.filter { $0.idle && helperPlan(for: $0).blockers.isEmpty } }

    /// 위험 표시용 한 줄(없으면 nil). 예: "남은 보조 프로세스 3개 · 412MB"
    var orphanHelperNote: String? {
        let helpers = orphanHelperTargets
        guard !helpers.isEmpty else { return nil }
        return "남은 보조 프로세스 \(helpers.count)개 · \(Fmt.size(helpers.reduce(0) { $0 + $1.footprint }))"
    }

    func helperPlan(for helper: OrphanHelper) -> HelperTerminator.Plan {
        HelperTerminator(registry: monitor.terminations).plan(helper, records: office?.processes ?? [])
    }

    /// 하나: 미리보기 확인 → SIGTERM → 5초 뒤에도 남으면 다시 묻고 SIGKILL.
    func terminateHelper(_ helper: OrphanHelper) {
        let plan = helperPlan(for: helper)
        guard plan.blockers.isEmpty else {
            Confirm.info(title: "끝낼 수 없는 보조 프로세스입니다", text: plan.blockers.joined(separator: "\n"))
            append(.info, "보조 프로세스 정리 차단 · \(helper.displayName) · \(plan.blockers[0])")
            return
        }
        let warnings = plan.warnings.isEmpty ? "" : "\n\n주의:\n• " + plan.warnings.joined(separator: "\n• ")
        let text = plan.preview + warnings + "\n\nSIGTERM으로 끝내고, 5초 뒤에도 남으면 한 번 더 묻습니다. 끝내기 전에 실행 명령·폴더를 복구함에 먼저 적어 두어, 복구함 '다시 띄우기'로 같은 명령을 실행할 수 있습니다." + helperDryRunNote
        guard Confirm.ask(title: "\(helper.kind.label)을(를) 끝낼까요?", text: text, action: settings.dryRun ? "드라이런" : "끝내기") else { return }
        runHelperTerminations([plan], reason: "보조 프로세스 정리", single: true)
    }

    /// 묶음('프로세스 최적화'): 쉬는 남은 보조 프로세스를 한 번에. confirm=false면 확인 창 없이 실행하고 SIGTERM 뒤 남은 것은 SIGKILL하지 않고 둔다.
    func optimizeHelpers(confirm: Bool = true) {
        let plans = orphanHelpers.filter(\.idle).map { helperPlan(for: $0) }.filter { $0.blockers.isEmpty }
        guard !plans.isEmpty else {
            if confirm {
                Confirm.info(title: "끝낼 보조 프로세스가 없습니다",
                             text: "세션이 끝난 뒤 \(Int(monitor.helpers.settings.idleAfter / 60))분 넘게 쉬는 보조 프로세스가 없습니다. ReMON이 세션 하위로 직접 본 프로세스만 대상입니다.")
            }
            return
        }
        if confirm {
            let bytes = plans.reduce(UInt64(0)) { $0 + $1.reclaimEstimate }
            var text = plans.prefix(12).map { "• \($0.helper.kind.label) · \($0.helper.name) · \(Fmt.size($0.reclaimEstimate)) · \($0.helper.origin.label)" }.joined(separator: "\n")
            if plans.count > 12 { text += "\n… 외 \(plans.count - 12)개" }
            let warned = plans.filter { !$0.warnings.isEmpty }
            if !warned.isEmpty { text += "\n\n주의: " + warned.prefix(4).map { "\($0.helper.name) — \($0.warnings[0])" }.joined(separator: "; ") }
            text += "\n\nSIGTERM → 5초 대기 → 그래도 남은 것만 SIGKILL로 끝냅니다. 신호 직전마다 pid·시작 시각·실행 경로를 다시 확인하고, 끝내기 전에 각 명령을 복구함에 적습니다(다시 띄우기)." + helperDryRunNote
            guard Confirm.ask(title: "남은 보조 프로세스 정리 · \(plans.count)개 · 약 \(Fmt.size(bytes))", text: text, action: settings.dryRun ? "드라이런" : "모두 끝내기") else { return }
        }
        runHelperTerminations(plans, reason: "프로세스 최적화(남은 보조 프로세스)", single: false, killRemaining: confirm)
    }

    private var helperDryRunNote: String { settings.dryRun ? "\n\n드라이런: 실제로 끝내지 않고 결과만 기록합니다." : "" }

    /// 백그라운드에서 끝낸다(묶음은 동시에 — 각자 최대 5초 기다림). single이면 남은 것을 SIGKILL하기 전에 다시 묻는다.
    /// 관찰 이력 없는 추정 고아(부모 없는 개발 서버, 1시간+). 20초마다 다시 본다(인자 읽기를 매 화면 갱신마다 하지 않게).
    var suspectedOrphans: [OrphanHelper] {
        // 첫 스냅숏 전(프로세스 목록이 빔)에는 캐시하지 않는다 — 빈 결과를 20초 동안 보여 주던 문제.
        let processes = office?.processes ?? []
        if !processes.isEmpty, Date().timeIntervalSince(SuspectedCache.at) > 20 {
            let tracked = Set(orphanHelpers.flatMap(\.members).map(\.pid))
            let sessionPIDs = Set((office?.sessions ?? []).flatMap(\.pids))
            SuspectedCache.items = SuspectedOrphanScanner.scan(records: processes, exclude: tracked.union(sessionPIDs))
            SuspectedCache.at = Date()
        }
        return SuspectedCache.items
    }

    /// 추정 고아 멈추기: ReMON이 본 적 없는 프로세스라 더 강하게 확인한다(기본 버튼 취소).
    func terminateSuspected(_ helper: OrphanHelper) {
        let plan = helperPlan(for: helper)
        guard plan.blockers.isEmpty else {
            Confirm.info(title: "멈출 수 없는 프로세스입니다", text: plan.blockers.joined(separator: "\n"))
            return
        }
        let text = plan.preview + "\n\n부모 프로세스가 없는 개발 서버입니다(\(Fmt.duration(Date().timeIntervalSince(helper.startTime))) 실행). ReMON이 에이전트 세션 아래서 본 적이 없어, 직접 띄워 둔 서버일 수 있습니다. SIGTERM으로 멈추기 전에 실행 명령·폴더를 복구함에 적어 두어, 복구함 '다시 띄우기'로 같은 명령을 실행할 수 있습니다." + helperDryRunNote
        guard Confirm.ask(title: "⚠️ 관찰 이력 없음 · \(helper.name)을(를) 멈출까요?", text: text, action: settings.dryRun ? "드라이런" : "멈추기", destructive: true) else { return }
        SuspectedCache.at = .distantPast
        runHelperTerminations([plan], reason: "추정 고아 정리(관찰 이력 없음)", single: true)
    }

    private func runHelperTerminations(_ plans: [HelperTerminator.Plan], reason: String, single: Bool, killRemaining: Bool = true) {
        let fresh = plans.filter { !terminatingHelpers.contains($0.helper.top) }
        guard !fresh.isEmpty else { return }
        for plan in fresh { terminatingHelpers.insert(plan.helper.top) }
        let terminator = HelperTerminator(registry: monitor.terminations)
        let dryRun = settings.dryRun
        let vault = self.vault
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let box = OutcomeBox()
            DispatchQueue.concurrentPerform(iterations: fresh.count) { index in
                let outcome = terminator.execute(fresh[index], dryRun: dryRun, vault: dryRun ? nil : vault, reason: reason) { remaining in
                    guard single else { return killRemaining }
                    return DispatchQueue.main.sync {
                        Confirm.ask(title: "보조 프로세스 \(remaining.count)개가 남았습니다", text: "SIGTERM 후 5초가 지나도 끝나지 않았습니다. 남은 것만 SIGKILL로 끝낼까요?", action: "남은 것만 종료", destructive: true)
                    }
                }
                box.set(index, outcome)
            }
            let outcomes = box.all(fresh.count)
            DispatchQueue.main.async {
                guard let self else { return }
                for plan in fresh { terminatingHelpers.remove(plan.helper.top) }
                let reclaimed = outcomes.reduce(UInt64(0)) { $0 + $1.reclaimed }
                let ended = outcomes.reduce(0) { $0 + $1.terminated.count }
                // 금고에 먼저 적지 못해 끝내지 않은 것(신호 0건) — 조용히 넘기지 않고 알린다.
                let aborted = outcomes.filter { $0.aborted != nil }
                let summary: String
                if single, let outcome = outcomes.first {
                    summary = (dryRun ? "드라이런 · " : "") + outcome.message
                    if let why = outcome.aborted { Confirm.info(title: "끝내지 않았습니다", text: why + "\n\n다시 띄울 기록 없이 프로세스를 끝내지 않습니다.") }
                } else {
                    let left = outcomes.filter { !$0.remaining.isEmpty && !$0.dryRun && $0.aborted == nil }.count
                    summary = (dryRun ? "드라이런 · 보조 프로세스 \(fresh.count)개 대상" : "\(reason) · \(ended)개 종료 · 약 \(Fmt.size(reclaimed)) 회수" + (ended > 0 ? " · 복구함에서 다시 띄우기" : ""))
                        + (left > 0 ? " · 남음 \(left)개" : "") + (aborted.isEmpty ? "" : " · 금고 기록 실패로 남김 \(aborted.count)개(\(aborted[0].aborted!))")
                }
                self.lastActionMessage = summary
                self.append(ended > 0 ? .cleanup : .info, summary)
                if !dryRun, reclaimed > 0 {
                    self.monitor.emit(OfficeEvent(kind: .cleanup(reclaimedBytes: reclaimed, summary: summary), text: "보조 프로세스 정리 · \(Fmt.size(reclaimed)) 회수"))
                }
                self.syncRecovery(force: true)
                self.monitor.refreshNow()
            }
        }
    }

    // MARK: 앱 강제 종료 — 금고 먼저(다시 띄우기 = open -b)

    /// 강제 종료 직전: 번들 id · 실행 파일 · 메모리를 금고에 먼저 적는다(종료 대기). 못 적으면 nil — forceQuitApp은 끝내지 않는다.
    func recordForceQuit(_ app: AppGroup, instances: [NSRunningApplication]) -> RecoveryEntry? {
        guard let main = instances.first else {
            Confirm.info(title: "강제 종료하지 않았습니다", text: "\(app.name)의 실행 인스턴스를 찾지 못해 다시 띄울 기록을 남길 수 없습니다.")
            return nil
        }
        let pid = main.processIdentifier
        let key = office?.processes.first { $0.pid == pid }?.key ?? ProcessRecovery.processKey(pid: pid)
        let entry = ProcessRecovery.appEntry(name: app.name, bundleID: main.bundleIdentifier, bundlePath: main.bundleURL?.path ?? app.id,
                                             executable: main.executableURL?.path, pid: pid, start: key?.start, footprint: app.footprint,
                                             launch: ProcessRecovery.capture(pid: pid), reason: "앱 강제 종료", status: .retiring)
        do {
            return try vault.add(entry)
        } catch {
            Confirm.info(title: "강제 종료하지 않았습니다", text: "복구 금고에 먼저 적지 못했습니다(\(error.localizedDescription)).\n다시 띄울 기록 없이 앱을 끝내지 않습니다.")
            append(.alert, "앱 강제 종료 취소 · \(app.name) · 복구 금고 기록 실패")
            return nil
        }
    }

    /// 강제 종료 뒤: 끝난 것을 확인하면 보관(다시 띄우기 가능)으로. 아직 살아 있으면 종료 대기로 두고 settleRetiring이 나중에 바꾼다.
    func settleForceQuit(_ entry: RecoveryEntry, instances: [NSRunningApplication]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if instances.allSatisfy(\.isTerminated) {
                try? self.vault.update(entry.id) { stored in
                    guard stored.status == .retiring else { return }
                    stored.status = .held
                    stored.exitReason = "강제 종료(forceTerminate)"
                    stored.note = (stored.note.map { $0 + " · " } ?? "") + "종료 확인"
                }
            }
            self.syncRecovery(force: true)
        }
    }

    // MARK: 다시 띄우기(복구함 · 프로세스 항목)

    /// 명령(앱은 open -b)을 보여 주고 확인을 받은 뒤 실행한다. 보관 중 → 다시 띄우는 중 → 새 프로세스를 확인하면 되돌림(syncRecovery의 reconcile).
    func restoreProcess(_ entry: RecoveryEntry) {
        let app = entry.isAppProcess
        var text = "\(entry.title)\n\n\(entry.resumeCommand ?? "")\n\n"
        if app {
            text += "번들 id로 앱을 다시 엽니다(NSWorkspace · open -b와 같음). 저장하지 않았던 문서는 앱이 되살릴 수 있을 때만 돌아옵니다."
        } else {
            text += "\(RecoveryLaunchers.placeLabel(for: entry))에서 원래 폴더로 옮긴 뒤 같은 명령을 실행합니다."
            if entry.processArgv?.contains(where: { $0.contains(ProcessRecovery.mask) }) == true {
                text += "\n\n⚠️ 가린 비밀값(\(ProcessRecovery.mask))이 들어 있어 그대로는 실패할 수 있습니다 — 명령을 복사해 고친 뒤 직접 실행해도 됩니다."
            }
        }
        guard Confirm.ask(title: "다시 띄울까요?", text: text, action: "다시 띄우기") else { return }
        let vault = self.vault
        let launcher = RecoveryLaunchers.live(folder: vault.launchFolder)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RecoveryRestorer.restoreProcess(entry, vault: vault, launcher: launcher, appOpener: AppRelauncher.live)
            DispatchQueue.main.async { self?.finishProcessRestore(entry, result) }
        }
    }

    private func finishProcessRestore(_ entry: RecoveryEntry, _ result: RecoveryRestorer.Result) {
        lastActionMessage = result.message
        append(result.ok ? .arrive : .alert, (result.ok ? "다시 띄우기 · " : "다시 띄우기 실패 · ") + "\(entry.project) · \(entry.title) · \(result.message)")
        if !result.ok { Confirm.info(title: "다시 띄우지 못했습니다", text: result.message + (entry.resumeCommand.map { "\n\n직접 실행할 명령:\n\($0)" } ?? "")) }
        syncRecovery(force: true)
    }

    // MARK: 왜 실행 중?(G3)

    /// 상세 카드에 넣을 '왜 실행 중?' 카드(지금 세션 목록 · 남은 보조 프로세스 출신 기록을 채워 준다).
    func whyCard(pid: Int32) -> ProcessWhyCard {
        let key = office?.processes.first { $0.pid == pid }?.key
        return ProcessWhyCard(pid: pid, sessions: office?.sessions ?? [], origin: key.flatMap { monitor.helpers.origin(for: $0) })
    }

    // MARK: 시작 항목(G4)

    /// 최근에 끈 시작 항목(복구함 기록, 아직 휴지통에 있는 것).
    var disabledStartupEntries: [RecoveryEntry] { recovery.filter { StartupItemManager.isStartupEntry($0) && $0.status == .held } }

    /// 내 에이전트 끄기: launchctl bootout → plist 휴지통(복구함에서 다시 켬). 끝나면 completion(다시 조사).
    func disableStartupItem(_ item: StartupItem, completion: (() -> Void)? = nil) {
        if let blocker = item.disableBlocker {
            Confirm.info(title: "끌 수 없는 항목입니다", text: blocker)
            return
        }
        var facts = ["실행: \((item.resolvedProgram ?? item.program ?? "알 수 없음").replacingOccurrences(of: NSHomeDirectory(), with: "~"))"]
        if item.crashLoop { facts.append("반복 크래시: 마지막 종료 \(item.state?.lastExit ?? "?") · \(item.state?.runs.map { "\($0)회 실행" } ?? "")") }
        if let missing = item.missingProgram { facts.append("없는 파일: \(missing.replacingOccurrences(of: NSHomeDirectory(), with: "~"))") }
        if item.state?.running == true { facts.append("지금 실행 중(pid \(item.state?.pid.map(String.init) ?? "?")) — 끄면 함께 끝납니다") }
        let text = "\(item.label)\n\(item.plistPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))\n\n" + facts.joined(separator: "\n") +
            "\n\nlaunchctl bootout으로 지금 끄고 plist를 휴지통으로 옮깁니다. 복구함에서 다시 켤 수 있습니다(파일을 되돌리고 launchctl bootstrap)." + helperDryRunNote
        guard Confirm.ask(title: "시작 항목을 끌까요?", text: text, action: settings.dryRun ? "드라이런" : "끄기") else { return }
        let dryRun = settings.dryRun
        let vault = self.vault
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = StartupItemManager().disable(item, vault: vault, dryRun: dryRun)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastActionMessage = result.message
                self.append(result.ok ? .cleanup : .info, "시작 항목 · " + result.message)
                if !result.ok { Confirm.info(title: "끄지 못했습니다", text: result.message) }
                self.syncRecovery(force: true)
                completion?()
            }
        }
    }

    /// 다시 켜기: 휴지통에서 원래 자리로 + launchctl bootstrap. 시작 항목 기록이 아니면 일반 되돌리기로 넘긴다.
    func restoreStartupItem(_ entry: RecoveryEntry, completion: (() -> Void)? = nil) {
        guard StartupItemManager.isStartupEntry(entry) else { restore(entry); return }
        guard Confirm.ask(title: "시작 항목을 다시 켤까요?",
                          text: "\(entry.title)\n\((entry.trashedPath ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~")) → \((entry.originalPath ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~"))\n\n원래 자리로 되돌리고 launchctl bootstrap으로 켭니다.",
                          action: "다시 켜기") else { return }
        let vault = self.vault
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = StartupItemManager().restore(entry, vault: vault)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastActionMessage = result.message
                self.append(result.ok ? .arrive : .alert, "시작 항목 · " + result.message)
                if !result.ok { Confirm.info(title: "다시 켜지 못했습니다", text: result.message + (entry.restoreHint.map { "\n\n직접 실행할 명령:\n\($0)" } ?? "")) }
                self.syncRecovery(force: true)
                completion?()
            }
        }
    }

    /// 시스템 영역은 보여 주기만: 시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램.
    func openLoginItemsSettings() {
        guard let url = URL(string: StartupItemManager.loginItemsSettingsURL) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 추정 고아 목록 캐시(확장에는 저장 속성을 둘 수 없다).
@MainActor
private enum SuspectedCache {
    static var at = Date.distantPast
    static var items: [OrphanHelper] = []
}

/// 앱 다시 띄우기: NSWorkspace로 번들 id의 앱을 연다(open -b와 같다). 번들 id로 못 찾으면 원래 번들 경로로.
enum AppRelauncher {
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (ok: Bool, message: String) = (false, "응답 없음")
        func set(_ ok: Bool, _ message: String) { lock.lock(); stored = (ok, message); lock.unlock() }
        var value: (ok: Bool, message: String) { lock.lock(); defer { lock.unlock() }; return stored }
    }

    static let live: RecoveryRestorer.AppOpener = { bundleID, bundlePath in
        let url = bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } ?? bundlePath.map { URL(fileURLWithPath: $0) }
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return (false, "앱을 찾지 못했습니다(\(bundleID ?? bundlePath ?? "?")) — 지웠거나 옮긴 앱일 수 있습니다") }
        let reply = Reply()
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            reply.set(error == nil, error?.localizedDescription ?? "")
            done.signal()
        }
        guard done.wait(timeout: .now() + 20) == .success else { return (false, "앱이 20초 안에 열리지 않았습니다 — Dock을 확인하세요") }
        let name = url.deletingPathExtension().lastPathComponent
        return reply.value.ok ? (true, "\(name) 앱을 다시 열었습니다") : (false, "\(name) 앱을 열지 못했습니다: \(reply.value.message)")
    }
}
