import Darwin
import Foundation
import ReMONCore

// 워크플로 잔재 검사 — workflow-residue.
// ① 멈춘 워크플로(stale): 합성 기록 폴더(하위 에이전트 기록·메타·일지) + 가짜 시계.
// ② 주인 세션이 끝난 뒤 남은 하위 에이전트 프로세스 → 남은 보조 프로세스('워크플로 잔재 · 프로젝트'): 합성 프로세스 표 + 가짜 실행 인자.
// ③ 실제 더미로 종료기 경로까지: 에이전트 본체 차단 대신 경고 → 금고(.process). 실제 종료는 이 검사가 띄운 더미로만 한다.

private let wrRoot = "/private/tmp/remon-workflow-residue-check"   // 공유 checkRoot 밖

private func wrDummy(_ name: String) -> String {
    let path = wrRoot + "/bin/" + name
    try? FileManager.default.createDirectory(atPath: wrRoot + "/bin", withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) { try? FileManager.default.copyItem(atPath: dummyBinary(), toPath: path) }
    return path
}

/// 우리 더미(실행 파일이 이 검사 폴더 아래)인지 확인한 뒤에만 신호를 보낸다.
private func wrKill(_ key: ProcessKey) {
    guard SessionTerminator.isAlive(key) else { return }
    let path = HelperGuard.executablePath(pid: key.pid) ?? ""
    guard path.hasPrefix(wrRoot + "/") || path.hasPrefix("/tmp/remon-workflow-residue-check/") else { return }
    kill(key.pid, SIGKILL)
}

@discardableResult
private func wrWait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(100_000)
    }
    return condition()
}

func workflowResidueCheck() {
    let fm = FileManager.default
    try? fm.removeItem(atPath: wrRoot)
    try? fm.createDirectory(atPath: wrRoot + "/work", withIntermediateDirectories: true)
    var spawned: [ProcessKey] = []
    defer {
        for key in spawned { wrKill(key) }
        try? FileManager.default.removeItem(atPath: wrRoot)
    }

    // 1) 멈춘 워크플로(stale): 끝나지 않았는데(일지에 끝난 기록 없음) 20분 넘게 기록을 안 씀. 가짜 시계(now)로 판정.
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let sessionID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let project = wrRoot + "/projects/-check-proj"
    let log = project + "/" + sessionID + ".jsonl"
    let plain = project + "/" + sessionID + "/subagents"
    let workflow = plain + "/workflows/wf_check"
    try? fm.createDirectory(atPath: workflow, withIntermediateDirectories: true)
    fm.createFile(atPath: log, contents: Data("{\"type\":\"user\"}\n".utf8))
    func agent(_ folder: String, _ id: String, silentFor: TimeInterval, meta: [String: Any]) {
        let path = folder + "/agent-" + id + ".jsonl"
        fm.createFile(atPath: path, contents: Data("{\"type\":\"assistant\"}\n".utf8))
        try? fm.setAttributes([.modificationDate: base.addingTimeInterval(-silentFor)], ofItemAtPath: path)
        fm.createFile(atPath: folder + "/agent-" + id + ".meta.json", contents: try? JSONSerialization.data(withJSONObject: meta))
    }
    let workflowMeta: [String: Any] = ["agentType": "workflow-subagent", "workflowPhase": "collect", "model": "sonnet"]
    agent(workflow, "stuck", silentFor: 30 * 60, meta: workflowMeta.merging(["description": "collect:stuck"]) { $1 })
    agent(workflow, "busy", silentFor: 60, meta: workflowMeta.merging(["description": "collect:busy"]) { $1 })
    agent(workflow, "done", silentFor: 30 * 60, meta: workflowMeta.merging(["description": "collect:done"]) { $1 })
    agent(workflow, "edge", silentFor: 19 * 60, meta: workflowMeta.merging(["description": "collect:edge"]) { $1 })
    agent(plain, "task", silentFor: 30 * 60, meta: ["description": "일반 하위 에이전트"])
    fm.createFile(atPath: workflow + "/journal.jsonl", contents: Data("{\"type\":\"started\",\"agentId\":\"done\"}\n{\"type\":\"completed\",\"agentId\":\"done\"}\n".utf8))
    let infos = SubagentScanner().scanClaude(sessionLog: log, now: base)
    func info(_ id: String, in list: [SubagentInfo]) -> SubagentInfo? { list.first { $0.id == id } }
    check(infos.count == 5, "합성 기록: 하위 에이전트 \(infos.count)/5개 읽음(워크플로 4 · 일반 1)")
    check(info("stuck", in: infos)?.stale == true && info("stuck", in: infos)?.active == false && info("stuck", in: infos)?.kind == .workflow,
          "stale: 끝나지 않은 워크플로 에이전트가 30분 조용 → 멈춤(잔재 후보)")
    check(info("busy", in: infos)?.active == true && info("busy", in: infos)?.stale == false, "1분 전에 쓴 것은 일하는 중(active) · stale 아님")
    check(info("done", in: infos)?.stale == false, "일지에 완료(completed)가 있으면 30분 조용해도 stale 아님")
    check(info("edge", in: infos)?.stale == false, "경계: 19분 조용 → 아직 아님(20분부터)")
    check(info("task", in: infos)?.stale == false && info("task", in: infos)?.kind == .subagent, "일지가 없는 일반 하위 에이전트는 끝났는지 알 수 없어 stale 아님")
    let later = SubagentScanner().scanClaude(sessionLog: log, now: base.addingTimeInterval(20 * 60))
    check(info("busy", in: later)?.stale == true && info("edge", in: later)?.stale == true && info("done", in: later)?.stale == false,
          "가짜 시계 +20분: 1분·19분 조용하던 것도 20분을 넘겨 stale · 완료된 것은 그대로")

    // 2) 잔재(합성 프로세스 표 · 가짜 실행 인자). 추적기는 기본 10분 규칙(idleAfter 600초) · 유예 30초.
    let me = getuid()
    func rec(_ pid: Int32, _ ppid: Int32, _ name: String, _ path: String) -> ProcRecord {
        ProcRecord(pid: pid, ppid: ppid, uid: me, name: name, start: Int64(pid) * 10, path: path, footprint: 10 << 20, cpuTimeNs: 0)
    }
    let arguments: [Int32: [String]] = [910_002: ["claude", "-p", "collect notices"], 910_003: ["node", "/x/server.js"], 930_002: ["claude"]]
    let reader: @Sendable (Int32) -> [String]? = { arguments[$0] }

    // a. 같은 종류: 주인 claude 세션 안의 claude -p(하위 에이전트) + 그 도구(node).
    let owner = rec(910_001, 500, "claude", "/opt/test/claude"), worker = rec(910_002, 910_001, "claude", "/opt/test/claude"), tool = rec(910_003, 910_002, "node", "/opt/test/node")
    let ownerSession = AgentSession(id: owner.key, kind: .claudeCode, rootPID: owner.pid, pids: [owner.pid, worker.pid, tool.pid], project: "워크플로팀")
    let tracker = HelperTracker(settings: .init(idleAfter: 600, activeCPUPercent: 0.5, grace: 30))
    tracker.argumentReader = reader
    tracker.observe(records: [owner, worker, tool], sessions: [ownerSession], now: base)
    check(tracker.orphans.isEmpty && tracker.origin(for: worker.key)?.sessionKey == owner.key, "주인 세션이 살아 있는 동안: 하위 에이전트(claude -p)·도구 모두 고아 아님 · 출신 기록")
    var orphanWorker = worker
    orphanWorker.ppid = 1
    // 주인이 끝나면 감지기는 claude -p를 '보조 호출' 세션 루트로 잡고, 도구는 그 세션 소속이 된다.
    let workerSession = AgentSession(id: worker.key, kind: .claudeCode, role: SessionDetector.helperRole, rootPID: worker.pid, pids: [worker.pid, tool.pid], project: "워크플로팀")
    tracker.observe(records: [orphanWorker, tool], sessions: [workerSession], now: base.addingTimeInterval(10))
    check(tracker.orphans.isEmpty, "유예 30초: 주인이 끝난 직후(10초)엔 아직 목록에 없음")
    tracker.observe(records: [orphanWorker, tool], sessions: [workerSession], now: base.addingTimeInterval(45))
    let residue = tracker.orphans.first { $0.top == worker.key }
    check(residue?.origin.workflowResidue == true && residue?.origin.label == "워크플로 잔재 · 워크플로팀" && residue?.kind == .workflowAgent
          && residue?.members == [worker.key, tool.key] && residue?.origin.sessionKey == owner.key,
          "잔재: 주인이 끝난 뒤 남은 claude -p(+도구) → 남은 보조 프로세스 '\(residue?.origin.label ?? "-")' · \(residue?.kind.label ?? "-") · 묶음 \(residue?.members.count ?? 0)개")
    check(residue?.idle == false, "10분 규칙: 45초 만에는 쉬는 중 아님(자동 정리 대상 아님)")
    tracker.observe(records: [orphanWorker, tool], sessions: [workerSession], now: base.addingTimeInterval(590))
    let before = tracker.orphans.first { $0.top == worker.key }?.idle
    tracker.observe(records: [orphanWorker, tool], sessions: [workerSession], now: base.addingTimeInterval(605))
    let after = tracker.orphans.first { $0.top == worker.key }
    check(before == false && after?.idle == true && (after?.idleFor ?? 0) >= 600, "10분 규칙 그대로: CPU 그대로 590초 → 아님 · 605초 → 쉬는 중(자동 정리 대상)")

    // a'. 감지기가 그 claude -p를 세션으로 못 잡아도(세션 목록에 없음) 같은 묶음 · 같은 출신.
    let unseen = HelperTracker(settings: .init(idleAfter: 600, activeCPUPercent: 0.5, grace: 0))
    unseen.argumentReader = reader
    unseen.observe(records: [owner, worker, tool], sessions: [ownerSession], now: base)
    unseen.observe(records: [orphanWorker, tool], sessions: [], now: base.addingTimeInterval(5))
    let residueUnseen = unseen.orphans.first { $0.top == worker.key }
    check(residueUnseen?.origin.workflowResidue == true && residueUnseen?.members == [worker.key, tool.key] && unseen.orphans.count == 1,
          "감지기가 세션으로 못 잡은 경우도: 잔재 한 묶음(하위 에이전트 + 도구)")

    // b. 다른 종류: Claude 세션이 띄운 codex exec(감지기가 따로 세션 루트로 잡음 · parentSession = 주인).
    let owner2 = rec(920_001, 500, "claude", "/opt/test/claude"), exec = rec(920_002, 920_001, "codex", "/opt/test/@openai/codex/codex"), execTool = rec(920_003, 920_002, "node", "/opt/test/node")
    let owner2Session = AgentSession(id: owner2.key, kind: .claudeCode, rootPID: owner2.pid, pids: [owner2.pid], project: "코덱스팀")
    var execSession = AgentSession(id: exec.key, kind: .codexCLI, role: "exec 일회성", rootPID: exec.pid, pids: [exec.pid, execTool.pid], project: "코덱스팀")
    execSession.parentSession = owner2.key
    let cross = HelperTracker(settings: .init(idleAfter: 600, activeCPUPercent: 0.5, grace: 0))
    cross.argumentReader = reader
    cross.observe(records: [owner2, exec, execTool], sessions: [owner2Session, execSession], now: base)
    check(cross.orphans.isEmpty && cross.origin(for: exec.key)?.sessionKey == owner2.key, "다른 종류 하위 세션(codex exec · 부모 = Claude 세션)을 주인의 하위 에이전트로 기록")
    var orphanExec = exec
    orphanExec.ppid = 1
    var execAlone = execSession
    execAlone.parentSession = nil
    cross.observe(records: [orphanExec, execTool], sessions: [execAlone], now: base.addingTimeInterval(5))
    let residueCross = cross.orphans.first { $0.top == exec.key }
    check(residueCross?.origin.label == "워크플로 잔재 · 코덱스팀" && residueCross?.members == [exec.key, execTool.key] && residueCross?.kind == .workflowAgent,
          "다른 종류 잔재: 주인 Claude가 끝난 뒤 남은 codex exec(+도구) → '\(residueCross?.origin.label ?? "-")'")
    let interactive = AgentSession(id: exec.key, kind: .codexCLI, role: "대화형", rootPID: exec.pid, pids: [exec.pid], project: "코덱스팀")
    var interactiveChild = interactive
    interactiveChild.parentSession = owner2.key
    let crossInteractive = HelperTracker(settings: .init(idleAfter: 600, activeCPUPercent: 0.5, grace: 0))
    crossInteractive.observe(records: [owner2, exec], sessions: [owner2Session, interactiveChild], now: base)
    crossInteractive.observe(records: [orphanExec], sessions: [interactive], now: base.addingTimeInterval(5))
    check(crossInteractive.orphans.isEmpty, "대화형 하위 세션(헤드리스 아님)은 주인이 끝나도 세션 그대로 — 잔재 아님")

    // c. 대화형 안쪽 claude(-p 없음): 바깥이 끝나면 스스로 세션 루트가 된다 — 잔재가 아니다(기존 규칙 유지).
    let outer = rec(930_001, 500, "claude", "/opt/test/claude"), inner = rec(930_002, 930_001, "claude", "/opt/test/claude")
    let nested = HelperTracker(settings: .init(idleAfter: 600, activeCPUPercent: 0.5, grace: 0))
    nested.argumentReader = reader
    nested.observe(records: [outer, inner], sessions: [AgentSession(id: outer.key, kind: .claudeCode, rootPID: outer.pid, pids: [outer.pid, inner.pid], project: "바깥")], now: base)
    var promoted = inner
    promoted.ppid = 1
    nested.observe(records: [promoted], sessions: [AgentSession(id: inner.key, kind: .claudeCode, rootPID: inner.pid, pids: [inner.pid], project: "안쪽")], now: base.addingTimeInterval(5))
    check(nested.orphans.isEmpty && nested.origin(for: inner.key) == nil, "대화형 안쪽 claude(-p 없음)는 주인이 끝나면 세션 — 잔재 아님(기록에서 빠짐)")

    // 3) 실제 더미: 주인 더미 아래 'claude -p' 더미(하위 에이전트) → 주인만 SIGKILL → 잔재로 분류 → 종료기(에이전트 본체 차단 대신 경고) → 금고(.process).
    let ownerProcess = Process()
    ownerProcess.executableURL = URL(fileURLWithPath: wrDummy("owner"))
    ownerProcess.arguments = ["--children", "1", "--child-binary", wrDummy("claude"), "--child-arg", "-p", "--child-arg", "collect:notice", "--lifetime", "90"]
    ownerProcess.currentDirectoryURL = URL(fileURLWithPath: wrRoot + "/work")
    ownerProcess.standardOutput = FileHandle.nullDevice
    ownerProcess.standardError = FileHandle.nullDevice
    try! ownerProcess.run()
    var records = ProcessSampler().sample()
    wrWait(6) { records = ProcessSampler().sample(); return records.contains { $0.ppid == ownerProcess.processIdentifier } }
    guard let ownerRecord = records.first(where: { $0.pid == ownerProcess.processIdentifier }),
          let workerRecord = records.first(where: { $0.ppid == ownerProcess.processIdentifier }) else { check(false, "주인·하위 에이전트 더미를 띄우지 못함"); return }
    spawned += [ownerRecord.key, workerRecord.key]
    let live = HelperTracker(settings: .init(idleAfter: 1, activeCPUPercent: 0.5, grace: 0))
    live.observe(records: records, sessions: [AgentSession(id: ownerRecord.key, kind: .claudeCode, rootPID: ownerRecord.pid, pids: [ownerRecord.pid, workerRecord.pid],
                                                           startTime: ownerRecord.startTime, cwd: wrRoot + "/work", project: "잔재팀")])
    wrKill(ownerRecord.key)
    wrWait(5) { ProcessSampler().sample().first { $0.key == workerRecord.key }?.ppid == 1 }
    records = ProcessSampler().sample()
    let detectedWorker = AgentSession(id: workerRecord.key, kind: .claudeCode, role: SessionDetector.helperRole, rootPID: workerRecord.pid, pids: [workerRecord.pid], project: "잔재팀")
    live.observe(records: records, sessions: [detectedWorker])
    guard let liveResidue = live.orphans.first(where: { $0.top == workerRecord.key }) else { check(false, "실제 더미: 잔재로 분류되지 않음"); return }
    check(liveResidue.origin.label == "워크플로 잔재 · 잔재팀" && liveResidue.kind == .workflowAgent && liveResidue.name == "claude",
          "실제 더미: 주인만 SIGKILL → 남은 'claude -p' 더미가 '\(liveResidue.origin.label)' · \(liveResidue.kind.label)")
    let audit = AuditLog(url: URL(fileURLWithPath: wrRoot + "/actions.jsonl"))
    let terminator = HelperTerminator(registry: TerminationRegistry())
    terminator.audit = audit
    terminator.waitSeconds = 1.5
    let plan = terminator.plan(liveResidue, records: records)
    var asSession = liveResidue
    asSession.origin.workflowResidue = false
    let sessionPlan = terminator.plan(asSession, records: records)
    check(plan.blockers.isEmpty && plan.warnings.contains { $0.contains("워크플로 에이전트") } && sessionPlan.blockers.contains { $0.contains("에이전트 본체") },
          "종료 계획: 잔재 claude는 '에이전트 본체' 차단 대신 경고 · 같은 프로세스도 잔재가 아니면 차단")
    let vault = RecoveryVault(folder: URL(fileURLWithPath: wrRoot + "/vault"))
    vault.audit = audit
    let outcome = terminator.execute(plan, dryRun: false, vault: vault) { _ in true }
    let entry = vault.all().first { $0.kind == .process && $0.pid == workerRecord.pid && $0.processStart == workerRecord.key.start }
    check(outcome.terminated == [workerRecord.key] && !SessionTerminator.isAlive(workerRecord.key) && entry?.status == .held && entry?.origin == "워크플로 잔재 · 잔재팀"
          && entry?.resumeArgs.map { Array($0.suffix(6)) } == ["-p", "collect:notice", "--children", "0", "--lifetime", "95"],
          "잔재 정리: SIGTERM 종료 · 금고 .process(보관 중 · 출신 '\(entry?.origin ?? "-")' · 같은 명령으로 다시 띄우기)")
    var evidence: [String: Any] = [:]
    evidence["stale"] = infos.filter(\.stale).map(\.id)
    evidence["residue"] = residue?.origin.label ?? ""
    evidence["members"] = residue?.members.count ?? 0
    evidence["cross"] = residueCross?.origin.label ?? ""
    evidence["live_entry"] = entry?.resumeCommand ?? ""
    writeEvidence("workflow-residue.json", evidence)
}
