import Darwin
import Foundation
import ReMONCore

// 사라진 세션의 원인 판정 · 복구 기록 · Orca 환경 변수 짝짓기(10-25 대표 지시: "이런 원인을 찾고 복구하려면 어떻게 하는지를 구축하라").
// 실제 종료는 이 시험이 띄운 더미 sleep에만 보낸다(대표님 프로세스는 건드리지 않는다).

/// 자식이 아닌 더미(sh가 띄우고 바로 끝나 launchd 자식이 됨)를 만들고 pid를 돌려준다.
private func orphanDummy(_ command: String) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "(\(command)) >/dev/null 2>&1 & echo $!"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    process.waitUntilExit()
    return Int32(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

private func waitExit(_ watcher: ExitWatcher, _ pid: Int32, since: Date) -> ExitWatcher.Exit? {
    for _ in 0..<40 {
        if let exit = watcher.exits(for: [pid], since: since).first { return exit }
        usleep(100_000)
    }
    return nil
}

func departureCheck() {
    // 1) 종료 감시기: 신호·종료 코드를 정확히 받는다(자식 아닌 더미).
    let watcher = ExitWatcher()
    let since = Date()
    var cases: [(String, Int32, Int32?, DepartureCause)] = []
    for (label, command, signal, cause) in [("SIGTERM", "/bin/sleep 3011", SIGTERM, DepartureCause.terminated), ("SIGKILL", "/bin/sleep 3012", SIGKILL, .forceKilled),
                                            ("SIGHUP", "/bin/sleep 3013", SIGHUP, .terminalClosed), ("SIGSEGV", "/bin/sleep 3014", SIGSEGV, .crash)] {
        let pid = orphanDummy(command)
        guard pid > 0 else { check(false, "\(label) 더미를 띄우지 못함"); continue }
        usleep(150_000)
        watcher.watch([pid])
        usleep(100_000)
        kill(pid, signal)
        cases.append((label, pid, signal, cause))
    }
    let normal = orphanDummy("/bin/sleep 1; exit 0"), failing = orphanDummy("/bin/sleep 1; exit 3")
    usleep(150_000)
    watcher.watch([normal, failing])
    cases += [("exit 0", normal, nil, .normal), ("exit 3", failing, nil, .error)]
    for (label, pid, signal, cause) in cases {
        guard let exit = waitExit(watcher, pid, since: since) else { check(false, "\(label): 종료 기록 없음"); continue }
        let report = DepartureForensics.analyze(exits: [exit], byReMON: false, tail: nil, crashReport: nil, pressure: nil)
        let ok = signal.map { exit.signal == $0 } ?? (exit.exitCode == (label == "exit 0" ? 0 : 3))
        check(ok && report.cause == cause && !report.estimated, "\(label) → \(exit.describe) → '\(report.summary)'")
    }

    // 2) 원인 우선순위: ReMON 기록 > 메모리 > 신호 > 크래시 보고서 > 대화 기록 끝
    let now = Date()
    check(DepartureForensics.analyze(exits: [ExitWatcher.Exit(pid: 1, time: now, status: 9, memoryKill: true)], byReMON: false, tail: nil, crashReport: nil, pressure: "위험").cause == .memory,
          "메모리 부족 강제 종료 표시가 있으면 'macOS가 메모리 부족으로 강제 종료'")
    check(DepartureForensics.analyze(exits: [ExitWatcher.Exit(pid: 1, time: now, status: 15, memoryKill: false)], byReMON: true, tail: nil, crashReport: nil, pressure: nil).cause == .remon,
          "ReMON이 신호를 보냈으면 'ReMON이 정리'")
    let codexInterrupted = TranscriptTail(kind: .interrupted, time: now, text: "작업 중단(interrupted)")
    check(DepartureForensics.analyze(exits: [ExitWatcher.Exit(pid: 1, time: now, status: 0, memoryKill: false)], byReMON: false, tail: codexInterrupted, crashReport: nil, pressure: nil).cause == .interrupted,
          "코드 0이어도 기록 끝이 '작업 중단'이면 '중단됨'(Codex가 중단 신호 뒤 정상 코드로 나가는 모양)")
    let guess = DepartureForensics.analyze(exits: [], byReMON: false, tail: codexInterrupted, crashReport: nil, pressure: "주의")
    check(guess.cause == .interrupted && guess.estimated && guess.evidence.contains { $0.contains("메모리 압박 주의") }, "종료 상태를 못 받으면 기록·정황으로 '추정' 표시(\(guess.summary))")

    // 3) 대화 기록 끝 읽기: Codex 'turn_aborted · interrupted' · Claude '/exit'
    let folder = checkRoot + "/departure"
    try? FileManager.default.removeItem(atPath: folder)
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    let rollout = folder + "/rollout.jsonl"
    writeLines(rollout, [["timestamp": "2026-10-25T03:05:38.297Z", "type": "event_msg", "payload": ["type": "token_count"]],
                         ["timestamp": "2026-10-25T03:05:38.383Z", "type": "event_msg", "payload": ["type": "turn_aborted", "reason": "interrupted"]]])
    let codexTail = DepartureForensics.transcriptTail(rollout, kind: .codexCLI)
    check(codexTail?.kind == .interrupted && codexTail?.text.contains("interrupted") == true, "Codex 기록 끝 = 작업 중단(interrupted)")
    let claudeLog = folder + "/claude.jsonl"
    writeLines(claudeLog, [["type": "assistant", "message": ["content": [["type": "text", "text": "완료"]]]],
                           ["type": "user", "message": ["content": "<command-name>/exit</command-name>"]]])
    check(DepartureForensics.transcriptTail(claudeLog, kind: .claudeCode)?.kind == .userExit, "Claude 기록 끝 = 사용자가 /exit")

    // 4) 사라짐 기록: 복구 키가 있으면 '보관 중'(정신교육실), 없으면 '사라짐' · ReMON이 이미 적은 세션은 다시 안 적음
    let vault = RecoveryVault(folder: URL(fileURLWithPath: folder + "/vault"))
    vault.audit = AuditLog(url: URL(fileURLWithPath: folder + "/actions.jsonl"))
    let process = spawnDummy("claude", [])
    let members = tree(process.processIdentifier)
    var session = session(for: members, kind: .claudeCode, state: .working)
    let id = UUID().uuidString.lowercased()
    let log = folder + "/projects/-work/\(id).jsonl"
    claudeTranscript(log, cwd: folder, id: id)
    session.logPath = log
    session.registrySessionID = id
    session.registryKind = "interactive"
    session.launchArgv = ["claude", "--model", "opus"]
    kill(members[0].pid, SIGKILL)
    if process.isRunning { process.terminate() }
    let report = DepartureForensics.analyze(exits: [ExitWatcher.Exit(pid: members[0].pid, time: Date(), status: 9, memoryKill: false)], byReMON: false, tail: nil, crashReport: nil, pressure: nil)
    let entry = DepartureRecorder.record(session, report: report, vault: vault)
    check(entry?.status == .held && entry?.departure == DepartureCause.forceKilled.rawValue && entry?.resumeArgs == ["claude", "--resume", id, "--model", "opus"]
          && entry?.backup.map { FileManager.default.fileExists(atPath: $0) } == true && entry?.note?.contains("신호 9") == true,
          "스스로 끝난 세션 → 금고 '보관 중' · 끝난 까닭 '강제 종료' · 원래 옵션으로 복귀 명령 · 기록 보관본")
    check(DepartureRecorder.record(session, report: report, vault: vault) == nil, "같은 세션을 두 번 적지 않음")
    var empty = session
    empty.id = ProcessKey(pid: 99_991, start: 1)
    empty.rootPID = 99_991
    empty.logPath = nil
    empty.registrySessionID = UUID().uuidString.lowercased()
    let gone = DepartureRecorder.record(empty, report: report, vault: vault)
    check(gone?.status == .gone && gone?.departure == DepartureCause.forceKilled.rawValue, "대화 기록이 없는 세션은 '사라짐'으로만(정신교육실 인물 없음 · 무엇이 있었는지 기록)")
    let restored = RecoveryRestorer.restoreSession(entry!, vault: vault, sessions: [], registry: [:], launcher: { _ in (true, "시험", "터미널 새 창에서 이어 엽니다") })
    check(restored.ok, "사라진 세션도 정신교육실 복귀 경로 그대로(\(restored.message))")
}

/// Orca 환경 변수(ORCA_AGENT_PANE · ORCA_TERMINAL_HANDLE)로 정확히 짝짓는다 — 제목이 같은 다른 세션이 있어도.
func orcaEnvironmentPairingCheck() {
    let fake = FakeProcesses()
    let folder = "/Users/test/DEV/STOREARC"
    let shellA = fake.add("zsh", "/bin/zsh", ["-zsh"], cwd: folder, env: ["ORCA_AGENT_PANE": "tab-1:leaf-1", "ORCA_TAB_ID": "tab-1"])
    let viewer = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude"], parent: shellA.pid, cwd: folder, env: ["ORCA_AGENT_PANE": "tab-1:leaf-1", "ORCA_TAB_ID": "tab-1"])
    let shellB = fake.add("zsh", "/bin/zsh", ["-zsh"], cwd: folder)
    let other = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude"], parent: shellB.pid, cwd: folder, env: ["ORCA_TERMINAL_HANDLE": "term_b"])
    let shellC = fake.add("zsh", "/bin/zsh", ["-zsh"], cwd: folder)
    let leftover = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude"], parent: shellC.pid, cwd: folder, env: ["ORCA_AGENT_PANE": "tab-9:leaf-9"])
    let terminals = [
        OrcaTerminal(handle: "term_a", title: "같은 제목", worktreePath: folder, agent: "claude", lastOutputAt: Date(), connected: true, tabId: "tab-1", leafId: "leaf-1"),
        OrcaTerminal(handle: "term_b", title: "같은 제목", worktreePath: folder, agent: "claude", lastOutputAt: Date(), connected: true, tabId: "tab-2", leafId: "leaf-2"),
        OrcaTerminal(handle: "term_old", title: "", worktreePath: folder, agent: nil, lastOutputAt: nil, connected: true, orphaned: true, tabId: "pty:x", leafId: "leaf-9"),
    ]
    let detector = SessionDetector()
    detector.catalog = AgentCatalog(defaults: nil, initial: AgentCatalog.State())
    detector.claudeRegistry = ClaudeRegistry(directory: NSTemporaryDirectory() + "remon-env-registry-\(getpid())")
    let result = detector.detect(records: fake.records, sampler: fake, orca: terminals)
    func session(_ record: ProcRecord) -> AgentSession? { result.sessions.first { $0.rootPID == record.pid } }
    check(session(viewer)?.orcaHandle == "term_a" && session(viewer)?.tabState == .open, "ORCA_AGENT_PANE(탭:창) → 그 탭에 정확히 짝지음")
    check(session(other)?.orcaHandle == "term_b", "ORCA_TERMINAL_HANDLE → 그 터미널에 정확히 짝지음(제목이 같아도 섞이지 않음)")
    check(session(leftover)?.orcaHandle == "term_old" && session(leftover)?.tabLeftover == true, "환경 변수가 가리키는 창을 Orca가 '닫힌 탭'으로 알려 주면 잔재")
}
