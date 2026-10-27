import Darwin
import Foundation
import ReMONCore

// Claude 백그라운드 세션(`claude --bg`) 정리·복귀(10-25 대표 질문: "백그라운드 세션은 어떻게 할 건데?").
// 실측(CLI 2.1.310): `claude stop <짧은 id>`가 대화를 남기고 데몬 기록을 바로 '멈춤'으로 바꾼다 · `claude --bg --resume <id>`(플래그 없이)가
// 같은 짧은 id로 백그라운드에서 되살린다 · 플래그를 붙이거나 아직 실행 중으로 보이면 복사본을 만든다.
// 여기서는 더미 프로세스와 가짜 정지기·복귀기로 순서와 금고 기록만 본다(실제 claude는 `recovery-bg-live`).

final class BackgroundCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var _stops: [String] = []
    private var _launches: [(args: [String], cwd: String, job: String)] = []
    var stops: [String] { lock.lock(); defer { lock.unlock() }; return _stops }
    var launches: [(args: [String], cwd: String, job: String)] { lock.lock(); defer { lock.unlock() }; return _launches }
    func stop(_ job: String) { lock.lock(); _stops.append(job); lock.unlock() }
    func launch(_ args: [String], _ cwd: String, _ job: String) { lock.lock(); _launches.append((args, cwd, job)); lock.unlock() }
}

func recoveryBackgroundCheck() {
    let fm = FileManager.default
    let root = recoveryRoot + "-bg"
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    let audit = AuditLog(url: URL(fileURLWithPath: root + "/actions.jsonl"))
    let vault = RecoveryVault(folder: URL(fileURLWithPath: root + "/vault"))
    vault.audit = audit
    let work = checkRoot + "/work-bg"
    try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)

    // 1) 복구 키: 백그라운드면 플래그 없이 `claude --bg --resume <id>` · 대화형은 원래 플래그를 옮긴다.
    let process = spawnDummy("claude", [])
    let members = tree(process.processIdentifier)
    var bgSession = session(for: members, kind: .claudeCode, state: .longIdle)
    let id = UUID().uuidString.lowercased()
    let log = root + "/projects/-work-bg/\(id).jsonl"
    claudeTranscript(log, cwd: work, id: id)
    bgSession.logPath = log
    let bgKey = ResumeKey.resolve(bgSession, registrySessionID: id, argv: ["claude", "--model", "opus"], registryKind: "bg").key
    check(bgKey?.arguments == ["claude", "--bg", "--resume", id] && bgKey?.background == true && bgKey?.jobID == String(id.prefix(8)),
          "백그라운드 복구 키 = claude --bg --resume <id>(플래그 없음 — 붙이면 복사본) · 짧은 id \(bgKey?.jobID ?? "-")")
    let fgKey = ResumeKey.resolve(bgSession, registrySessionID: id, argv: ["claude", "--model", "opus"], registryKind: "interactive").key
    check(fgKey?.arguments == ["claude", "--resume", id, "--model", "opus"] && fgKey?.background == false, "대화형 세션은 그대로 claude --resume <id> + 원래 플래그")

    // 2) 정리: 공식 정지(claude stop)를 먼저 부르고, 끝나면 SIGTERM을 보내지 않는다 · 금고에 짧은 id·'Claude 백그라운드' 기록.
    let calls = BackgroundCalls()
    let recorder = SignalRecorder()
    let terminator = SessionTerminator(registry: TerminationRegistry())
    terminator.audit = audit
    terminator.waitSeconds = 1
    terminator.signalSender = { pid, signal in recorder.record(pid, signal) }
    let retirer = SessionRetirer(vault: vault, terminator: terminator)
    retirer.audit = audit
    let rootPID = members[0].pid
    retirer.backgroundStopper = { job in
        calls.stop(job)
        kill(rootPID, SIGTERM)   // 데몬이 세션을 멈추는 것을 흉내(신호 기록기는 거치지 않음)
        return (true, "stopped " + job)
    }
    let plan = terminator.plan(session: bgSession, members: members, environments: [:], context: ProtectionContext(), pinKey: "bg")
    let outcome = retirer.execute(retirer.prepare(plan: plan, registrySessionID: id, argv: ["claude"], registryKind: "bg", reason: "시험", requireKey: true),
                                  dryRun: false, force: false, footprints: [:]) { _ in false }
    let stored = vault.all().first { $0.resumeID == id }
    check(calls.stops == [String(id.prefix(8))] && recorder.calls.isEmpty && !SessionTerminator.isAlive(members[0].key),
          "정리 = claude stop \(id.prefix(8)) 먼저 · 끝났으니 종료 신호 0건(\(recorder.calls.count))")
    check(stored?.status == .held && stored?.backgroundJob == String(id.prefix(8)) && stored?.terminalHost == "Claude 백그라운드" &&
          stored?.resumeArgs == ["claude", "--bg", "--resume", id] && stored?.note?.contains("claude stop") == true && stored?.backup.map { fm.fileExists(atPath: $0) } == true,
          "금고: 보관 중 · 짧은 id · 'Claude 백그라운드' · 복귀 명령 · 기록 보관본(\(outcome.message))")
    if process.isRunning { process.terminate() }

    // 3) 정지가 실패하면 기존 SIGTERM 경로가 끝낸다.
    let process2 = spawnDummy("claude", [])
    let members2 = tree(process2.processIdentifier)
    var bg2 = session(for: members2, kind: .claudeCode, state: .longIdle)
    let id2 = UUID().uuidString.lowercased()
    let log2 = root + "/projects/-work-bg/\(id2).jsonl"
    claudeTranscript(log2, cwd: work, id: id2)
    bg2.logPath = log2
    let t2 = SessionTerminator(registry: TerminationRegistry())
    t2.audit = audit
    t2.waitSeconds = 2
    let r2 = SessionRetirer(vault: vault, terminator: t2)
    r2.audit = audit
    r2.backgroundStopper = { job in calls.stop(job); return (false, "daemon not reachable") }
    let plan2 = t2.plan(session: bg2, members: members2, environments: [:], context: ProtectionContext(), pinKey: "bg2")
    _ = r2.execute(r2.prepare(plan: plan2, registrySessionID: id2, argv: ["claude"], registryKind: "bg", reason: "시험", requireKey: true),
                   dryRun: false, force: false, footprints: [:]) { _ in false }
    let stored2 = vault.all().first { $0.resumeID == id2 }
    check(!SessionTerminator.isAlive(members2[0].key) && stored2?.status == .held && stored2?.note?.contains("실패") == true,
          "claude stop이 실패하면 종료 신호로 끝내고 보관(기록에 실패 사유)")
    if process2.isRunning { process2.terminate() }

    // 4) 복귀: 터미널을 열지 않고 백그라운드 복귀기 · 이미 떠 있으면 다시 열지 않음 · 복사본이면 그 id를 알림.
    guard let entry = stored else { return }
    let terminal = LaunchRecorder()
    let opened = RecoveryRestorer.restoreSession(entry, vault: vault, sessions: [], registry: [:], launcher: { terminal.record($0); return (true, "시험", "터미널") },
                                                 backgroundLauncher: { args, cwd, job in calls.launch(args, cwd, job); return (true, false, nil, "백그라운드에서 다시 돌아갑니다 · claude attach \(job)") })
    check(opened.ok && terminal.launches.isEmpty && calls.launches.first.map { $0.args == ["claude", "--bg", "--resume", id] && $0.cwd == work && $0.job == String(id.prefix(8)) } == true,
          "복귀 = 터미널 없이 claude --bg --resume(원래 폴더 · 같은 짧은 id) · \(opened.message)")
    _ = try? vault.transition(entry.id, from: .restoring, to: .held, note: "시험 되돌림")
    let already = RecoveryRestorer.restoreSession(vault.entry(entry.id)!, vault: vault, sessions: [], registry: [:], launcher: { _ in (true, "시험", "터미널") },
                                                  backgroundLauncher: { _, _, job in (true, true, nil, "이미 백그라운드에서 돌고 있습니다 · claude attach \(job)") })
    if case .alreadyRunning = already { check(vault.entry(entry.id)?.status == .restored, "이미 백그라운드에서 돌고 있으면 다시 열지 않고 '복귀됨'으로") }
    else { check(false, "이미 떠 있는 세션을 또 열려고 함") }
    guard let entry2 = stored2 else { return }
    let copied = RecoveryRestorer.restoreSession(entry2, vault: vault, sessions: [], registry: [:], launcher: { _ in (true, "시험", "터미널") },
                                                 backgroundLauncher: { _, _, _ in (true, false, "abcd1234", "원래 세션이 아직 실행 중으로 보여 같은 대화의 복사본 abcd1234로 열었습니다") })
    check(copied.ok && copied.message.contains("abcd1234"), "CLI가 복사본을 만들면 그 짧은 id를 알림(같은 대화)")
}

/// 실제 claude로 끝까지(명시적으로만 돈다): REMON_BG_LIVE_DIR(신뢰한 더미 폴더)의 백그라운드 더미 세션 하나를
/// ReMON 정리기(실제 `claude stop`)로 멈추고 ReMON 복귀기(실제 `claude --bg --resume`)로 같은 짧은 id를 되살린다. 그 폴더 밖 세션은 건드리지 않는다.
func recoveryBackgroundLiveCheck() {
    guard let folder = ProcessInfo.processInfo.environment["REMON_BG_LIVE_DIR"], let liveID = ProcessInfo.processInfo.environment["REMON_BG_LIVE_ID"] else {
        print("REMON_BG_LIVE_DIR · REMON_BG_LIVE_ID가 없어 건너뜀"); return
    }
    let real = (folder as NSString).resolvingSymlinksInPath
    let job = String(liveID.prefix(8))
    func agents() -> [[String: Any]] {
        let result = Shell.capture("/bin/zsh", ["-lc", "exec claude agents --json --all"], timeout: 20)
        return (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]]) ?? []
    }
    func pid(of job: String) -> Int? { agents().first { ($0["id"] as? String) == job }.flatMap { $0["pid"] as? Int } }
    // 0) 더미 깨우기(프롬프트 없이 — 모델을 부르지 않는다)
    if pid(of: job) == nil {
        _ = Shell.capture("/bin/zsh", ["-lc", "cd \(ResumeKey.quote(real)) && exec claude --bg --resume \(ResumeKey.quote(liveID))"], timeout: 60)
        Thread.sleep(forTimeInterval: 4)
    }
    guard let livePID = pid(of: job) else { check(false, "더미 세션을 깨우지 못함"); return }
    // 1) 감지: 그 폴더의 백그라운드 세션만
    let sampler = ProcessSampler()
    let detector = SessionDetector()
    _ = detector.detect(records: sampler.sample(), sampler: sampler, orca: [])
    Thread.sleep(forTimeInterval: 1)
    let records = sampler.sample()
    let sessions = detector.detect(records: records, sampler: sampler, orca: []).sessions
    guard let target = sessions.first(where: { $0.rootPID == Int32(livePID) && (($0.cwd ?? "") as NSString).resolvingSymlinksInPath == real }) else {
        check(false, "더미 세션(pid \(livePID))을 감지하지 못함 · 감지된 세션 \(sessions.count)개"); return
    }
    let registry = ClaudeRegistry().load()[target.rootPID]
    check(registry?.kind == "bg" && target.role == "백그라운드", "감지: 역할 '\(target.role)' · 레지스트리 kind \(registry?.kind ?? "-")")
    // 2) 정리(실제 claude stop) — 시험용 금고
    let vaultFolder = URL(fileURLWithPath: checkRoot + "/recovery-bg-live/vault")
    try? FileManager.default.removeItem(at: vaultFolder)
    let vault = RecoveryVault(folder: vaultFolder)
    let terminator = SessionTerminator(registry: TerminationRegistry())
    let retirer = SessionRetirer(vault: vault, terminator: terminator)
    let members = records.filter { target.pids.contains($0.pid) }
    let plan = terminator.plan(session: target, members: members, environments: [:], context: ProtectionContext(), pinKey: "live")
    let prepared = retirer.prepare(plan: plan, registrySessionID: registry?.sessionId, argv: ProcessSampler.readArguments(pid: target.rootPID)?.argv ?? [],
                                   registryKind: registry?.kind, reason: "시험", requireKey: true)
    let outcome = retirer.execute(prepared, dryRun: false, force: false, footprints: [:]) { _ in false }
    let entry = vault.all().first { $0.resumeID == liveID }
    let stopped = pid(of: job) == nil
    check(entry?.status == .held && entry?.backgroundJob == job && stopped && entry?.note?.contains("claude stop") == true,
          "정리: claude stop으로 멈춤 · 금고 보관 · 데몬 목록에서 실행 중 아님(\(outcome.message))")
    // 3) 복귀(실제 claude --bg --resume) — 곧바로 열어도 복사본이 아니라 같은 짧은 id여야 한다
    guard let held = entry else { return }
    let restored = RecoveryRestorer.restoreSession(held, vault: vault, sessions: [], registry: [:], launcher: { _ in (false, "시험", "터미널을 열면 안 됨") })
    Thread.sleep(forTimeInterval: 4)
    let back = pid(of: job)
    check(restored.ok && back != nil && !restored.message.contains("복사본"), "복귀: 같은 짧은 id \(job)로 백그라운드 실행 중(pid \(back.map(String.init) ?? "-")) · \(restored.message)")
    // 4) 정리: 더미를 다시 멈춘다(지우기는 시험 밖에서)
    _ = Shell.capture("/bin/zsh", ["-lc", "exec claude stop \(job)"], timeout: 20)
}
