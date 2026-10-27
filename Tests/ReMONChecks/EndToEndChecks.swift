import Darwin
import Foundation
import ReMONCore

// 세션 한 바퀴를 끝까지(더미만): 감지 → 상태가 기록 시각을 따름 → 금고 먼저 정리 → 복귀 → 사라진 세션의 원인·기록 → 일하는 중이면 신호 0건.
// 실제 핵심 타입(SessionDetector · SessionTerminator · SessionRetirer · RecoveryRestorer · ExitWatcher · DepartureForensics · DepartureRecorder)을
// 그대로 쓰고, 프로세스는 이 시험이 띄운 DummyAgent(+ 그 /bin/sleep 자식)만 다룬다.
// - 감지기에는 더미 프로세스 기록만 넣는다(대표님 세션은 감지 대상에 들어가지도 않는다).
// - 감지기가 보는 홈(~/.claude/projects)은 임시 폴더다: 감지기를 만드는 순간에만 CFFIXED_USER_HOME을 바꿔 둔다. 대화 기록 · 레지스트리 ·
//   금고 · 감사 기록도 모두 /private/tmp/remon-check/e2e 아래 — 대표님의 ~/.claude · 금고 · 감사 기록은 건드리지 않는다.
// - 신호는 이 시험이 띄운 pid(시작 시각까지 같은 것)에만 간다. 끝나면(중간에 실패해도) defer로 남은 더미를 모두 끝낸다.

/// 이 시험이 띄운 프로세스 장부(루트와 자식, 시작 시각 포함).
final class DummyLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var _keys: [ProcessKey] = []

    func add(_ members: [ProcRecord]) { lock.lock(); _keys += members.map(\.key); lock.unlock() }
    var keys: [ProcessKey] { lock.lock(); defer { lock.unlock() }; return _keys }
    func owns(_ pid: Int32) -> Bool { keys.contains { $0.pid == pid && SessionTerminator.isAlive($0) } }

    /// 살아 있는 것(같은 시작 시각)을 모두 SIGKILL로 끝내고, 3초 뒤에도 남은 수를 돌려준다.
    @discardableResult
    func killAll() -> Int {
        for key in keys where SessionTerminator.isAlive(key) { kill(key.pid, SIGKILL) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, keys.contains(where: SessionTerminator.isAlive) { usleep(50_000) }
        return keys.filter(SessionTerminator.isAlive).count
    }
}

/// 더미 하나: 프로세스 트리(루트 + /bin/sleep) · 대화 id · 기록 파일.
private struct E2EDummy {
    var members: [ProcRecord]
    var id: String
    var log: String
    var root: ProcRecord { members[0] }
}

private func jsonLine(_ object: [String: Any]) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data(), as: UTF8.self)
}

/// 같은 파일인가(정식 경로로). 임시 홈이 /private/tmp 아래면 Foundation이 홈을 /tmp/…로 바꿔 돌려주므로(경로 표준화가 /private를 뗀다)
/// 감지기가 적는 경로와 시험이 만든 경로의 글자가 다를 수 있다.
private func samePath(_ lhs: String?, _ rhs: String) -> Bool {
    guard let lhs else { return false }
    return SafeFileOps.canonical(lhs) == SafeFileOps.canonical(rhs)
}

/// 감지기를 임시 홈으로 만든다(홈은 만들 때 정해진다). 바꾼 환경 변수는 바로 되돌린다.
private func sandboxedDetector(home: String, registry: String) -> SessionDetector {
    let previous = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
    setenv("CFFIXED_USER_HOME", home, 1)
    defer { if let previous { setenv("CFFIXED_USER_HOME", previous, 1) } else { unsetenv("CFFIXED_USER_HOME") } }
    let detector = SessionDetector()
    detector.catalog = AgentCatalog(defaults: nil, initial: AgentCatalog.State())
    detector.claudeRegistry = ClaudeRegistry(directory: registry)
    return detector
}

func endToEndCheck() {
    print("— e2e: 더미 세션 한 바퀴(감지 → 상태 → 금고 먼저 정리 → 복귀 → 바깥 SIGHUP 원인·기록 → busy면 신호 0건)")
    let started = Date()
    let failuresBefore = failures
    let fm = FileManager.default
    let root = checkRoot + "/e2e"
    try? fm.removeItem(atPath: root)
    let home = root + "/home"
    let project = root + "/proj"
    let registryDir = home + "/.claude/sessions"
    // 감지기 규칙과 같은 인코딩: 영문·숫자·_·- 말고는 '-'(…/remon-check/e2e/proj → -private-tmp-remon-check-e2e-proj).
    let encoded = project.map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII || $0 == "_" || $0 == "-" ? String($0) : "-" }.joined()
    let projectsDir = home + "/.claude/projects/" + encoded
    for folder in [project, projectsDir, registryDir] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }

    let ledger = DummyLedger()
    defer {
        // 중간에 돌아가도(실패) 이 시험이 띄운 더미는 모두 끝낸다.
        ledger.killAll()
        if failures == failuresBefore { try? fm.removeItem(atPath: root) }
    }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let sampler = ProcessSampler()

    /// Claude처럼 보이는 더미를 띄우고(실행 파일 이름 claude), 대화 기록(임시 홈의 ~/.claude/projects)과 레지스트리 항목을 적는다.
    /// reuse: 같은 대화를 이어 쓰는 세션(새 기록 없이 레지스트리 id만 같게) · status: 레지스트리 상태(busy 등, 없으면 기록 시각으로 판정).
    func spawn(_ label: String, last: Date, status: String? = nil, reuse: String? = nil) -> E2EDummy? {
        let process = spawnDummy("claude", ["--children", "1"])
        // 부하가 큰 Mac에서는 자식(/bin/sleep)이 0.4초보다 늦게 뜬다 — 트리가 다 보일 때까지(최대 2초) 기다린다.
        var members = tree(process.processIdentifier)
        let deadline = Date().addingTimeInterval(2)
        while members.count < 2, Date() < deadline { usleep(100_000); members = tree(process.processIdentifier) }
        ledger.add(members)
        guard members.count >= 2 else { check(false, "\(label) 더미를 띄우지 못함(프로세스 \(members.count)개)"); return nil }
        let id = reuse ?? UUID().uuidString.lowercased()
        let log = projectsDir + "/" + id + ".jsonl"
        if reuse == nil {
            writeLines(log, [["type": "user", "cwd": project, "sessionId": id, "timestamp": iso.string(from: last.addingTimeInterval(-20)),
                              "message": ["role": "user", "content": "\(label): 로그인 버그 고쳐줘"]],
                             ["type": "assistant", "cwd": project, "sessionId": id, "timestamp": iso.string(from: last),
                              "message": ["role": "assistant", "content": [["type": "text", "text": "네, 고치고 있습니다"]]]]])
        }
        var entry: [String: Any] = ["pid": Int(members[0].pid), "sessionId": id, "cwd": project, "kind": "interactive",
                                    "startedAt": Int(members[0].startTime.timeIntervalSince1970 * 1000)]
        if let status { entry["status"] = status; entry["statusUpdatedAt"] = Int(Date().timeIntervalSince1970 * 1000) }
        fm.createFile(atPath: registryDir + "/\(members[0].pid).json", contents: try? JSONSerialization.data(withJSONObject: entry))
        return E2EDummy(members: members, id: id, log: log)
    }

    /// 더미 트리 기록만 골라 감지한다(대표님 프로세스는 감지기에 넣지 않는다).
    func detect(_ dummy: E2EDummy, with detector: SessionDetector, now: Date) -> AgentSession? {
        let records = sampler.sample()
        let pids = Set([dummy.root.pid] + liveDescendants(of: dummy.root.pid, in: records).map(\.pid))
        return detector.detect(records: records.filter { pids.contains($0.pid) }, sampler: sampler, orca: [], now: now).sessions.first { $0.rootPID == dummy.root.pid }
    }

    func members(of dummy: E2EDummy) -> (records: [ProcRecord], environments: [Int32: [String: String]]) {
        let records = tree(dummy.root.pid)
        var environments: [Int32: [String: String]] = [:]
        for record in records { environments[record.pid] = ProcessSampler.readArguments(pid: record.pid)?.environment ?? [:] }
        return (records, environments)
    }

    // ── ① 감지 · 상태 ──
    let base = Date().addingTimeInterval(-30)   // 마지막 기록 = 30초 전
    guard let a = spawn("세션 A", last: base) else { return }
    let detector = sandboxedDetector(home: home, registry: registryDir)
    let looked = detector.claudeProjectDirectories(for: project)
    check(looked.count == 1 && samePath(looked.first, projectsDir), "감지기의 ~/.claude/projects = 임시 폴더(\(looked.first ?? "없음")) — 대표님 기록 폴더를 보지 않음")
    let fresh = detect(a, with: detector, now: base.addingTimeInterval(30))
    check(fresh?.kind == .claudeCode && samePath(fresh?.logPath, a.log) && fresh?.logLinkIsEstimate == false && fresh?.registrySessionID == a.id
          && fresh?.pids.count == a.members.count && fresh?.displayTitle == "세션 A: 로그인 버그 고쳐줘",
          "① 감지: 더미(pid \(a.root.pid) · 하위 \(fresh?.childCount ?? -1)개) → Claude 세션 · 기록 정확히 연결 · 레지스트리 id 일치 · 제목 '\(fresh?.displayTitle ?? "-")'")
    let ladder: [(TimeInterval, SessionState, String)] = [(30, .working, "30초"), (20 * 60, .waiting, "20분"), (5 * 3600, .idle, "5시간"), (30 * 3600, .longIdle, "30시간")]
    var ladderOK = true
    var ladderSeen: [String] = []
    for (offset, expected, label) in ladder {
        let state = detect(a, with: detector, now: base.addingTimeInterval(offset))?.state
        ladderSeen.append("\(label) \(state?.label ?? "없음")")
        if state != expected { ladderOK = false }
    }
    check(ladderOK, "① 상태가 마지막 기록 시각을 따름(가짜 지금): " + ladderSeen.joined(separator: " · "))
    // 30시간 뒤 새 기록이 붙으면 다시 '일함', 그 뒤로 25시간 조용하면 다시 '오래 쉼'(정리 후보).
    let later = base.addingTimeInterval(30 * 3600)
    appendLine(a.log, jsonLine(["type": "assistant", "cwd": project, "sessionId": a.id, "timestamp": iso.string(from: later.addingTimeInterval(-10)),
                                "message": ["role": "assistant", "content": [["type": "text", "text": "다시 시작합니다"]]]]))
    let revived = detect(a, with: detector, now: later)
    let candidate = detect(a, with: detector, now: later.addingTimeInterval(25 * 3600))
    check(revived?.state == .working && candidate?.state == .longIdle,
          "① 새 기록이 붙으면 다시 '\(revived?.state.label ?? "-")'(\(revived?.stateReason ?? "-")) → 25시간 조용하면 '\(candidate?.state.label ?? "-")'")

    // ── ② 정리: 금고에 먼저 적고(종료 직전 → 보관 중) · 기록 보관본 · 프로세스 끝 ──
    let audit = AuditLog(url: URL(fileURLWithPath: root + "/actions.jsonl"))
    let vault = RecoveryVault(folder: URL(fileURLWithPath: root + "/vault"))
    vault.audit = audit
    let registry = TerminationRegistry()
    let terminator = SessionTerminator(registry: registry)
    terminator.audit = audit
    let order = OrderProbe()
    terminator.signalSender = { pid, signal in
        // 이 시험이 띄운 pid에만 보낸다. 신호 순간 금고에 '종료 직전' 항목과 기록 보관본이 이미 있는지 적는다.
        guard ledger.owns(pid) else { return -1 }
        let ready = vault.all().contains { $0.pid == pid && $0.status == .retiring && ($0.backup.map { FileManager.default.fileExists(atPath: $0) } ?? false) }
        order.note(ready, pid, signal)
        return kill(pid, signal)
    }
    let retirer = SessionRetirer(vault: vault, terminator: terminator)
    retirer.audit = audit
    var retiredEntry: RecoveryEntry?
    if let candidate {
        let info = members(of: a)
        let plan = terminator.plan(session: candidate, members: info.records, environments: info.environments, context: ProtectionContext(), pinKey: "e2e")
        let prepared = retirer.prepare(plan: plan, registrySessionID: a.id, argv: ProcessSampler.readArguments(pid: a.root.pid)?.argv ?? [], registryKind: "interactive",
                                       reason: "e2e 시험(오래 쉼)", requireKey: true)
        check(plan.blockers.isEmpty && prepared.key.allowsAutoCleanup, "② 정리 준비: 보호 차단 없음 · \(prepared.key.label)")
        let outcome = retirer.execute(prepared, dryRun: false, force: false, footprints: Dictionary(uniqueKeysWithValues: info.records.map { ($0.key, $0.footprint) })) { _ in false }
        retiredEntry = outcome.entry
        let first = order.signals.first
        check(order.seen.first == true && first?.0 == a.root.pid && first?.1 == SIGTERM,
              "② 금고가 먼저: SIGTERM 순간 금고에 '종료 직전(retiring)' 항목 + 기록 보관본이 이미 있음(신호 \(order.signals.count)건)")
        check(retiredEntry?.status == .held && retiredEntry?.resumeID == a.id && retiredEntry?.resumeArgs == ["claude", "--resume", a.id],
              "② 끝나자 금고 '보관 중' · 복구 키 \(a.id.prefix(8)) · 복귀 명령 \(retiredEntry?.resumeArgs ?? [])")
        let backup = retiredEntry?.backup
        check(backup.map { fm.fileExists(atPath: $0) && inode($0) != nil && inode($0) == inode(a.log) } == true, "② 대화 기록 보관본(하드링크 · 같은 inode): \(backup ?? "없음")")
        check(info.records.allSatisfy { !SessionTerminator.isAlive($0.key) } && outcome.termination?.remaining.isEmpty == true && registry.reason(for: a.root.key) == .releasedByReMON,
              "② 더미 프로세스 \(info.records.count)개(루트 + 자식) 모두 끝남 · ReMON 종료 기록 '정리' · \(outcome.message)")
    } else {
        check(false, "② 정리 후보(오래 쉼) 감지 실패")
    }

    // ── ③ 복귀: 가짜 실행기(기록만) → 실행함 · 보관 중 → 복귀 중 / 같은 대화를 잇는 세션이 돌고 있으면 이미 돌아옴 ──
    if let entry = retiredEntry {
        let launches = LaunchRecorder()
        let launcher: RecoveryLauncher = { launch in launches.record(launch); return (true, "시험", "기록만 했습니다(실행 안 함)") }
        let restored = RecoveryRestorer.restoreSession(entry, vault: vault, sessions: [], registry: [:], launcher: launcher)
        let launched: Bool = { if case .launched = restored { return true }; return false }()
        let launch = launches.launches.first
        check(launched && vault.entry(entry.id)?.status == .restoring && launches.launches.count == 1 && launch?.arguments == ["claude", "--resume", a.id] && launch?.cwd == project,
              "③ 복귀: '\(restored.message)' · 금고 보관 중 → \(vault.entry(entry.id)?.status.rawValue ?? "-") · 실행기에 넘긴 명령 \(launch?.arguments ?? []) · 폴더 \(launch?.cwd ?? "-")")
        // 복귀한 세션(같은 대화 id로 다시 뜬 더미)이 돌고 있으면 다시 열지 않는다.
        if let resumed = spawn("복귀한 세션 A", last: Date(), reuse: a.id) {
            let running = detect(resumed, with: sandboxedDetector(home: home, registry: registryDir), now: Date())
            let again = RecoveryRestorer.restoreSession(vault.entry(entry.id) ?? entry, vault: vault, sessions: running.map { [$0] } ?? [], registry: [:], launcher: launcher)
            let already: Bool = { if case .alreadyRunning = again { return true }; return false }()
            check(samePath(running?.logPath, a.log) && already && vault.entry(entry.id)?.status == .restored && launches.launches.count == 1,
                  "③ 같은 대화를 잇는 세션(pid \(resumed.root.pid) · 같은 기록에 연결)이 돌고 있으면 '\(again.message)' · 금고 '\(vault.entry(entry.id)?.status.rawValue ?? "-")' · 실행기 다시 안 부름")
        }
    } else {
        check(false, "③ 복귀할 금고 항목이 없음(②에서 정리 실패)")
    }

    // ── ④ 사라짐: 바깥에서 SIGHUP(터미널이 닫힐 때와 같은 신호) → 종료 감시기 → 원인 '터미널 닫힘' → 금고 '보관 중' · departure ──
    if let b = spawn("세션 B", last: Date().addingTimeInterval(-3 * 3600)) {
        let session = detect(b, with: sandboxedDetector(home: home, registry: registryDir), now: Date())
        let watcher = ExitWatcher()
        let since = Date()
        watcher.watch([b.root.pid])
        usleep(100_000)
        if ledger.owns(b.root.pid) { kill(b.root.pid, SIGHUP) }
        var exit: ExitWatcher.Exit?
        for _ in 0..<40 {
            if let found = watcher.exits(for: [b.root.pid], since: since).first { exit = found; break }
            usleep(100_000)
        }
        let byReMON = registry.reason(for: b.root.key) != nil
        let tail = session?.logPath.flatMap { DepartureForensics.transcriptTail($0, kind: .claudeCode) }
        let report = DepartureForensics.analyze(exits: exit.map { [$0] } ?? [], byReMON: byReMON, tail: tail, crashReport: nil, pressure: nil)
        check(samePath(session?.logPath, b.log) && exit?.signal == SIGHUP && !byReMON && report.cause == .terminalClosed && !report.estimated,
              "④ 바깥 SIGHUP → 감시기 '\(exit?.describe ?? "기록 없음")' · ReMON 종료 기록 없음 · 원인 '\(report.summary)'")
        if let session {
            let recorded = DepartureRecorder.record(session, report: report, vault: vault)
            check(recorded?.status == .held && recorded?.departure == DepartureCause.terminalClosed.rawValue && recorded?.departure == "terminalClosed" && recorded?.resumeID == b.id
                  && recorded?.backup.map { fm.fileExists(atPath: $0) } == true,
                  "④ 사라짐 기록: 금고 '\(recorded?.status.rawValue ?? "-")'(대화 기록 있음) · departure '\(recorded?.departure ?? "-")' · 복귀 명령 \(recorded?.resumeArgs ?? []) · 기록 보관본")
        } else {
            check(false, "④ 세션 B 감지 실패")
        }
        if let candidate {
            check(DepartureRecorder.record(candidate, report: report, vault: vault) == nil, "④ ReMON이 정리한 세션 A는 '사라짐'으로 다시 적지 않음")
        }
    }

    // ── ⑤ 안전: 레지스트리 상태 busy인 세션은 신호 직전 확인에서 멈춘다 — 신호 0건 ──
    if let d = spawn("세션 D", last: Date().addingTimeInterval(-6 * 3600), status: "busy") {
        let session = detect(d, with: sandboxedDetector(home: home, registry: registryDir), now: Date())
        check(session?.state == .working && session?.stateReason.contains("busy") == true, "⑤ 레지스트리 상태 busy → '\(session?.state.label ?? "-")'(\(session?.stateReason ?? "-"))")
        let recorder = SignalRecorder()
        let guarded = SessionTerminator(registry: TerminationRegistry())
        guarded.audit = audit
        guarded.signalSender = { recorder.record($0, $1) }
        let guardedRetirer = SessionRetirer(vault: vault, terminator: guarded)
        guardedRetirer.audit = audit
        if let session {
            let info = members(of: d)
            let plan = guarded.plan(session: session, members: info.records, environments: info.environments, context: ProtectionContext(), pinKey: "e2e")
            let prepared = guardedRetirer.prepare(plan: plan, registrySessionID: d.id, argv: ProcessSampler.readArguments(pid: d.root.pid)?.argv ?? [], registryKind: "interactive",
                                                  reason: "e2e 시험(오래된 판정)", requireKey: true)
            let pid = d.root.pid
            let folder = registryDir
            // 앱과 같은 마지막 확인: 신호 바로 앞에서 레지스트리를 다시 읽는다.
            let preSignal: @Sendable () -> String? = {
                guard let status = ClaudeRegistry(directory: folder).load()[pid]?.status else { return nil }
                if status == "busy" { return "신호 직전 확인: 레지스트리 상태 busy(일하는 중)" }
                if status == "waiting" { return "신호 직전 확인: 입력을 기다리는 중" }
                return nil
            }
            let outcome = guardedRetirer.execute(prepared, dryRun: false, force: false, footprints: [:], preSignalCheck: preSignal) { _ in false }
            check(prepared.key.allowsAutoCleanup && outcome.aborted?.contains("busy") == true && recorder.calls.isEmpty && SessionTerminator.isAlive(d.root.key)
                  && !vault.all().contains { $0.resumeID == d.id },
                  "⑤ busy 세션 정리 시도 → '\(outcome.aborted ?? "멈추지 않음")' · 신호 \(recorder.calls.count)건 · 프로세스 살아 있음 · 금고 기록 없음")
        }
    }

    // ── 정리: 이 시험이 띄운 더미를 모두 끝낸다(defer도 한 번 더 확인) ──
    let left = ledger.killAll()
    check(left == 0, "더미 프로세스 \(ledger.keys.count)개(루트 · 자식) 모두 정리 · 남은 것 \(left)개")
    let elapsed = Date().timeIntervalSince(started)
    check(elapsed < 60, String(format: "e2e 전체 %.1f초 < 60초", elapsed))
}
