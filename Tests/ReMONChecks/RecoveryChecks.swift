import Darwin
import Foundation
import ReMONCore

// 복구 금고 검사: 금고 먼저(종료 신호 전에 기록) · 직전 활동이면 취소 · 금고 기록 실패면 종료 안 함 · 보관본으로 되살리기 ·
// 휴지통 · git 되돌리기 · 영구 삭제 등급. 실제 종료·삭제는 더미 프로세스·더미 폴더·더미 저장소로만 한다.

let recoveryRoot = checkRoot + "/recovery"

final class OrderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _seen: [Bool] = []
    private var _signals: [(Int32, Int32)] = []
    func note(_ value: Bool, _ pid: Int32, _ signal: Int32) { lock.lock(); _seen.append(value); _signals.append((pid, signal)); lock.unlock() }
    var seen: [Bool] { lock.lock(); defer { lock.unlock() }; return _seen }
    var signals: [(Int32, Int32)] { lock.lock(); defer { lock.unlock() }; return _signals }
}

final class LaunchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _launches: [RecoveryLaunch] = []
    func record(_ launch: RecoveryLaunch) { lock.lock(); _launches.append(launch); lock.unlock() }
    var launches: [RecoveryLaunch] { lock.lock(); defer { lock.unlock() }; return _launches }
}

func writeLines(_ path: String, _ objects: [[String: Any]]) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    let text = objects.map { String(decoding: (try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])) ?? Data(), as: UTF8.self) }.joined(separator: "\n") + "\n"
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
}

func appendLine(_ path: String, _ text: String) {
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data((text + "\n").utf8))
    try? handle.close()
}

func inode(_ path: String) -> UInt64? {
    var info = stat()
    return stat(path, &info) == 0 ? UInt64(info.st_ino) : nil
}

func claudeTranscript(_ path: String, cwd: String, id: String) {
    writeLines(path, [["type": "user", "cwd": cwd, "sessionId": id, "message": ["role": "user", "content": "더미 대화"]],
                      ["type": "assistant", "cwd": cwd, "sessionId": id, "message": ["role": "assistant", "content": [["type": "text", "text": "네"]]]]])
}

func recoveryCheck() {
    let fm = FileManager.default
    try? fm.removeItem(atPath: recoveryRoot)
    try? fm.createDirectory(atPath: recoveryRoot, withIntermediateDirectories: true)
    let audit = AuditLog(url: URL(fileURLWithPath: recoveryRoot + "/actions.jsonl"))
    func makeVault(_ folder: String) -> RecoveryVault {
        let vault = RecoveryVault(folder: URL(fileURLWithPath: folder))
        vault.audit = audit
        return vault
    }
    let vault = makeVault(recoveryRoot + "/vault")

    // 1) 금고: 두 인스턴스(개발판·설치판)가 동시에 써도 잃지 않는다 · 깨진 파일은 버리지 않고 옆으로.
    let other = makeVault(recoveryRoot + "/vault")
    let group = DispatchGroup()
    for (index, store) in [vault, other].enumerated() {
        group.enter()
        DispatchQueue.global().async {
            for n in 0..<40 { try? store.add(RecoveryEntry(kind: .deleted, status: .gone, project: "시험", title: "t\(index)-\(n)", reason: "시험")) }
            group.leave()
        }
    }
    group.wait()
    check(vault.all().count == 80 && other.all().count == 80, "금고: 두 인스턴스가 동시에 80건을 써도 잃지 않음(flock + 매번 다시 읽기) · \(vault.all().count)건")
    let corrupt = makeVault(recoveryRoot + "/vault-corrupt")
    try? fm.createDirectory(atPath: recoveryRoot + "/vault-corrupt", withIntermediateDirectories: true)
    fm.createFile(atPath: recoveryRoot + "/vault-corrupt/vault.json", contents: Data("{깨짐".utf8))
    let emptied = corrupt.all().isEmpty
    let aside = ((try? fm.contentsOfDirectory(atPath: recoveryRoot + "/vault-corrupt")) ?? []).contains { $0.hasPrefix("vault.corrupt-") }
    let addedAfter = (try? corrupt.add(RecoveryEntry(kind: .deleted, status: .gone, project: "시험", title: "새 기록", reason: "시험"))) != nil
    check(emptied && aside && addedAfter && corrupt.all().count == 1, "금고: 깨진 파일은 vault.corrupt-*.json으로 옮겨 보존하고 새로 시작")
    // 새 판이 적은 모르는 종류: 그 항목만 원문 보존, 나머지는 그대로 읽고, 다시 써도 사라지지 않는다.
    let mixed = makeVault(recoveryRoot + "/vault-mixed")
    try? fm.createDirectory(atPath: recoveryRoot + "/vault-mixed", withIntermediateDirectories: true)
    try? mixed.add(RecoveryEntry(kind: .deleted, status: .gone, project: "시험", title: "아는 항목", reason: "시험"))
    if var array = (try? JSONSerialization.jsonObject(with: Data(contentsOf: mixed.fileURL))) as? [Any] {
        array.append(["id": "future-1", "kind": "futureKind", "status": "held", "createdAt": 0, "updatedAt": 0, "project": "미래", "title": "새 판 항목", "reason": "x", "bytes": 0])
        try? JSONSerialization.data(withJSONObject: array).write(to: mixed.fileURL)
    }
    let readable = mixed.all().count
    try? mixed.add(RecoveryEntry(kind: .deleted, status: .gone, project: "시험", title: "두 번째", reason: "시험"))
    let kept = String(decoding: (try? Data(contentsOf: mixed.fileURL)) ?? Data(), as: UTF8.self).contains("future-1")
    check(readable == 1 && mixed.all().count == 2 && kept, "금고: 모르는 종류 항목은 원문 보존, 아는 항목은 읽고, 다시 써도 남음(판 섞임 대비)")

    // 2) 이어 열기 키 — Claude
    let work = checkRoot + "/work"
    try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)
    let claudeID = UUID().uuidString.lowercased()
    let claudeLog = recoveryRoot + "/projects/-dummy/\(claudeID).jsonl"
    claudeTranscript(claudeLog, cwd: work, id: claudeID)
    var claude = AgentSession(id: ProcessKey(pid: 999_998, start: 1), kind: .claudeCode, rootPID: 999_998, pids: [999_998], cwd: "/엉뚱한/폴더", project: "시험")
    claude.logPath = claudeLog
    let argv = ["claude", "--model", "opus", "--dangerously-skip-permissions", "--settings", "/tmp/s.json", "--resume", "old-id", "--mcp-config", "x.json"]
    let exact = ResumeKey.resolve(claude, registrySessionID: claudeID, argv: argv)
    check(exact.key?.id == claudeID && exact.key?.cwd == work && exact.key?.arguments == ["claude", "--resume", claudeID, "--model", "opus", "--dangerously-skip-permissions"],
          "Claude 키: 기록 파일 id · 기록에 적힌 폴더 · 안전 플래그만(--settings·--mcp-config·옛 --resume 제외) → \(exact.key?.arguments.joined(separator: " ") ?? exact.label)")
    var estimated = claude; estimated.logLinkIsEstimate = true
    check(!ResumeKey.resolve(estimated, registrySessionID: nil, argv: []).allowsAutoCleanup, "Claude 키: 추정 연결이면 불확실(자동 정리 금지)")
    check(!ResumeKey.resolve(claude, registrySessionID: UUID().uuidString.lowercased(), argv: []).allowsAutoCleanup, "Claude 키: 레지스트리 id와 기록 파일이 다르면 불확실")
    let summaryOnly = recoveryRoot + "/projects/-dummy/\(UUID().uuidString.lowercased()).jsonl"
    writeLines(summaryOnly, [["type": "summary", "summary": "요약뿐"]])
    var empty = claude; empty.logPath = summaryOnly
    if case .nothingToLose = ResumeKey.resolve(empty, registrySessionID: nil, argv: []) { check(true, "Claude 키: 대화 없는 기록은 '잃을 것 없음'") } else { check(false, "Claude 키: 대화 없는 기록은 '잃을 것 없음'") }
    var unlinked = claude; unlinked.logPath = nil
    if case .nothingToLose = ResumeKey.resolve(unlinked, registrySessionID: UUID().uuidString.lowercased(), argv: [], claudeProjects: recoveryRoot + "/projects") {
        check(true, "Claude 키: 레지스트리 id의 기록이 어디에도 없으면 새 세션('잃을 것 없음')")
    } else { check(false, "Claude 키: 레지스트리 id의 기록이 어디에도 없으면 새 세션('잃을 것 없음')") }
    check(!ResumeKey.resolve(unlinked, registrySessionID: claudeID, argv: [], claudeProjects: recoveryRoot + "/projects").allowsAutoCleanup, "Claude 키: 기록은 있는데 연결 전이면 불확실")
    check(!ResumeKey.resolve(unlinked, registrySessionID: nil, argv: []).allowsAutoCleanup, "Claude 키: 기록·레지스트리 모두 없으면 불확실")

    // 3) 이어 열기 키 — Codex(주 스레드는 session_meta.parent_thread_id가 빈 것 하나)
    let mainID = UUID().uuidString.lowercased(), subID = UUID().uuidString.lowercased()
    let codexDir = recoveryRoot + "/codex/sessions/2026/10/25"
    let mainLog = codexDir + "/rollout-2026-10-25T00-00-00-\(mainID).jsonl", subLog = codexDir + "/rollout-2026-10-25T00-01-00-\(subID).jsonl"
    writeLines(mainLog, [["type": "session_meta", "payload": ["id": mainID, "cwd": work, "parent_thread_id": NSNull()]]])
    writeLines(subLog, [["type": "session_meta", "payload": ["id": subID, "cwd": work, "parent_thread_id": mainID]]])
    var codex = AgentSession(id: ProcessKey(pid: 999_997, start: 1), kind: .codexCLI, rootPID: 999_997, pids: [999_997], cwd: work, project: "시험")
    codex.logPath = subLog   // 조사기가 하위 스레드를 주로 골랐어도
    codex.extraLogPaths = [mainLog]
    let codexArgv = ["node", "/x/codex.js", "resume", "old", "-m", "gpt-5", "--yolo", "-c", "foo=bar", "--remote-auth-token-env", "TOKEN", "-s", "workspace-write"]
    let codexKey = ResumeKey.resolve(codex, registrySessionID: nil, argv: codexArgv)
    check(codexKey.key?.id == mainID && codexKey.key?.arguments == ["codex", "resume", mainID, "-m", "gpt-5", "--dangerously-bypass-approvals-and-sandbox", "-s", "workspace-write"],
          "Codex 키: 하위 스레드 말고 주 스레드 id · 안전 플래그만(-c·인증 환경변수 제외) → \(codexKey.key?.arguments.joined(separator: " ") ?? codexKey.label)")
    let secondTop = codexDir + "/rollout-2026-10-25T00-02-00-\(UUID().uuidString.lowercased()).jsonl"
    writeLines(secondTop, [["type": "session_meta", "payload": ["id": (secondTop as NSString).lastPathComponent.dropFirst(28).dropLast(6), "cwd": work]]])
    var twoTops = codex; twoTops.extraLogPaths = [mainLog, secondTop]
    check(!ResumeKey.resolve(twoTops, registrySessionID: nil, argv: []).allowsAutoCleanup, "Codex 키: 주 스레드가 둘이면 불확실")
    let mismatch = codexDir + "/rollout-2026-10-25T00-03-00-\(UUID().uuidString.lowercased()).jsonl"
    writeLines(mismatch, [["type": "session_meta", "payload": ["id": UUID().uuidString.lowercased(), "cwd": work]]])
    var mismatched = codex; mismatched.logPath = mismatch; mismatched.extraLogPaths = []
    check(!ResumeKey.resolve(mismatched, registrySessionID: nil, argv: []).allowsAutoCleanup, "Codex 키: 파일 이름과 session_meta id가 다르면 불확실")

    // 4) OpenCode · 인용
    var open = AgentSession(id: ProcessKey(pid: 999_996, start: 1), kind: .opencode, rootPID: 999_996, pids: [999_996], cwd: work, project: "시험")
    open.logPath = nil
    check(ResumeKey.resolve(open, registrySessionID: nil, argv: ["opencode", "-s", "ses_123"]).key?.arguments == ["opencode", "--session", "ses_123"]
          && !ResumeKey.resolve(open, registrySessionID: nil, argv: ["opencode"]).allowsAutoCleanup, "OpenCode 키: 실행 인자의 -s만 인정, 없으면 복구 불가")
    check(ResumeKey.quote("a b'c") == "'a b'\\''c'" && ResumeKey.quote("/x/y-z") == "/x/y-z", "셸 인용: 공백·작은따옴표 안전")
    check(ResumeKey.safeFlags(.claudeCode, argv: ["claude", "--setting-sources", "", "--model", "haiku", "=x", "--model="]) == ["--model", "haiku"],
          "안전 플래그: 빈 인자·'='로 시작하는 인자가 와도 죽지 않음(실전 검사 회귀)")

    // 5) 금고 먼저 → 종료(실제 SIGTERM, 더미 프로세스)
    let process = spawnDummy("claude", ["--children", "1"])
    let members = tree(process.processIdentifier)
    var dummy = session(for: members, kind: .claudeCode, state: .longIdle)
    let dummyID = UUID().uuidString.lowercased()
    let dummyLog = recoveryRoot + "/projects/-work/\(dummyID).jsonl"
    claudeTranscript(dummyLog, cwd: work, id: dummyID)
    dummy.logPath = dummyLog
    let terminator = SessionTerminator(registry: TerminationRegistry())
    terminator.audit = audit
    let probe = OrderProbe()
    terminator.signalSender = { pid, signal in
        probe.note(vault.all().contains { $0.resumeID == dummyID && $0.status == .retiring }, pid, signal)
        return kill(pid, signal)
    }
    let retirer = SessionRetirer(vault: vault, terminator: terminator)
    retirer.audit = audit
    let plan = terminator.plan(session: dummy, members: members, environments: [:], context: ProtectionContext(), pinKey: "x")
    let prepared = retirer.prepare(plan: plan, registrySessionID: dummyID, argv: ["claude", "--model", "haiku"], reason: "시험", requireKey: true)
    let outcome = retirer.execute(prepared, dryRun: false, force: false, footprints: [:]) { _ in false }
    let held = outcome.entry
    check(probe.seen.first == true, "금고 먼저: SIGTERM을 보내는 순간 금고에 이미 '종료 직전' 기록이 있음")
    check(held?.status == .held && !SessionTerminator.isAlive(members[0].key), "종료 후 보관: 더미 종료됨 · 상태 \(held?.status.rawValue ?? "없음") · \(outcome.message)")
    let backupOK = held?.backup.map { inode($0) == inode(dummyLog) && fm.contentsEqual(atPath: $0, andPath: dummyLog) } ?? false
    check(backupOK, "기록 보관본: 하드링크(같은 inode · 같은 내용, 추가 공간 0)")
    let reread = makeVault(recoveryRoot + "/vault").entry(held?.id ?? "")
    check(reread?.resumeArgs == ["claude", "--resume", dummyID, "--model", "haiku"] && reread?.cwd == work, "금고 다시 읽기: 복구 명령·폴더가 디스크에 남음")

    // 6) 계획 뒤 기록이 바뀌면(일을 시작함) 취소
    let busyProcess = spawnDummy("claude", [])
    let busyMembers = tree(busyProcess.processIdentifier)
    var busy = session(for: busyMembers, kind: .claudeCode, state: .longIdle)
    let busyID = UUID().uuidString.lowercased()
    let busyLog = recoveryRoot + "/projects/-work/\(busyID).jsonl"
    claudeTranscript(busyLog, cwd: work, id: busyID)
    busy.logPath = busyLog
    let quiet = SessionTerminator(registry: TerminationRegistry())
    quiet.audit = audit
    let busyRetirer = SessionRetirer(vault: vault, terminator: quiet)
    busyRetirer.audit = audit
    let busyPrepared = busyRetirer.prepare(plan: quiet.plan(session: busy, members: busyMembers, environments: [:], context: ProtectionContext(), pinKey: "x"),
                                           registrySessionID: busyID, argv: ["claude"], reason: "시험", requireKey: true)
    Thread.sleep(forTimeInterval: 0.05)
    appendLine(busyLog, #"{"type":"user","message":"방금 일 시작"}"#)
    let busyOutcome = busyRetirer.execute(busyPrepared, dryRun: false, force: false, footprints: [:]) { _ in false }
    check(busyOutcome.aborted?.contains("기록이 바뀌었") == true && SessionTerminator.isAlive(busyMembers[0].key) && !vault.all().contains { $0.resumeID == busyID },
          "직전 활동: 계획 뒤 기록이 바뀌면 종료 취소 · 금고에도 안 남김")

    // 7) 금고에 못 적으면 종료하지 않는다(fail-closed)
    fm.createFile(atPath: recoveryRoot + "/not-a-folder", contents: Data("x".utf8))
    let brokenVault = makeVault(recoveryRoot + "/not-a-folder/vault")
    let recorder = SignalRecorder()
    let guarded = SessionTerminator(registry: TerminationRegistry())
    guarded.audit = audit
    guarded.signalSender = { recorder.record($0, $1) }
    let failRetirer = SessionRetirer(vault: brokenVault, terminator: guarded)
    failRetirer.audit = audit
    let failPrepared = failRetirer.prepare(plan: guarded.plan(session: busy, members: busyMembers, environments: [:], context: ProtectionContext(), pinKey: "x"),
                                           registrySessionID: busyID, argv: ["claude"], reason: "시험", requireKey: true)
    let failOutcome = failRetirer.execute(failPrepared, dryRun: false, force: false, footprints: [:]) { _ in false }
    check(failOutcome.aborted?.contains("기록하지 못했") == true && recorder.calls.isEmpty && SessionTerminator.isAlive(busyMembers[0].key),
          "fail-closed: 금고 기록 실패면 신호 0건 · 프로세스 그대로")

    // 8) 복구 키 없음: 자동 경로는 거절, 수동 경로는 종료하되 '복구 불가'로 기록
    var vague = busy; vague.logLinkIsEstimate = true
    let vagueAuto = busyRetirer.execute(busyRetirer.prepare(plan: quiet.plan(session: vague, members: busyMembers, environments: [:], context: ProtectionContext(), pinKey: "x"),
                                                            registrySessionID: nil, argv: [], reason: "시험", requireKey: true), dryRun: false, force: false, footprints: [:]) { _ in false }
    check(vagueAuto.aborted?.contains("복구 키가 없어") == true && SessionTerminator.isAlive(busyMembers[0].key), "자동 경로: 복구 키가 불확실하면 종료하지 않음")
    let dry = busyRetirer.execute(busyRetirer.prepare(plan: quiet.plan(session: busy, members: busyMembers, environments: [:], context: ProtectionContext(), pinKey: "x"),
                                                      registrySessionID: busyID, argv: [], reason: "시험", requireKey: true), dryRun: true, force: false, footprints: [:]) { _ in false }
    check(dry.entry == nil && SessionTerminator.isAlive(busyMembers[0].key) && dry.message.contains("복구 키 확보"), "드라이런: 금고에 안 남기고 종료 안 함 · 복구 키 상태만 알려 줌")
    let vagueManual = busyRetirer.execute(busyRetirer.prepare(plan: quiet.plan(session: vague, members: busyMembers, environments: [:], context: ProtectionContext(), pinKey: "x"),
                                                              registrySessionID: nil, argv: [], reason: "시험", requireKey: false), dryRun: false, force: false, footprints: [:]) { _ in false }
    check(vagueManual.entry?.status == .gone && vagueManual.entry?.note?.contains("복구 키 없음") == true && !SessionTerminator.isAlive(busyMembers[0].key),
          "수동 경로: 경고 후 종료 가능 · 금고엔 '복구 키 없음'으로 기록")

    // 9) 되살리기: 원본 기록이 지워졌어도 보관본으로 되돌리고, 같은 명령·폴더로 연다
    if let held {
        let original = (try? Data(contentsOf: URL(fileURLWithPath: dummyLog))) ?? Data()
        try? fm.removeItem(atPath: dummyLog)
        let launches = LaunchRecorder()
        let launcher: RecoveryLauncher = { launch in launches.record(launch); return (true, "시험", "시험 실행기") }
        let result = RecoveryRestorer.restoreSession(vault.entry(held.id)!, vault: vault, sessions: [], registry: [:], launcher: launcher)
        let restoredData = (try? Data(contentsOf: URL(fileURLWithPath: dummyLog))) ?? Data()
        check(result.ok && restoredData == original && !original.isEmpty, "되살리기: 지워진 기록을 보관본에서 되돌림(내용 동일 \(original.count)바이트)")
        check(launches.launches.first?.arguments == ["claude", "--resume", dummyID, "--model", "haiku"] && launches.launches.first?.cwd == work && vault.entry(held.id)?.status == .restoring,
              "되살리기: 금고의 명령·폴더 그대로 실행 · 상태 '복귀 확인 중'")
        var back = dummy; back.logPath = dummyLog; back.rootPID = 777_777
        RecoveryRestorer.reconcile(vault: vault, sessions: [back], registry: [:])
        check(vault.entry(held.id)?.status == .restored, "복귀 확인: 같은 대화를 쓰는 세션이 보이면 '복귀함'")
        // 확인 시간 초과 → 다시 보관
        var waiting = RecoveryEntry(kind: .session, status: .held, project: "시험", title: "대기", reason: "시험")
        waiting.resumeID = UUID().uuidString.lowercased(); waiting.resumeArgs = ["claude", "--resume", waiting.resumeID!]; waiting.cwd = work
        try? vault.add(waiting)
        _ = RecoveryRestorer.restoreSession(waiting, vault: vault, sessions: [], registry: [:], launcher: launcher)
        RecoveryRestorer.reconcile(vault: vault, sessions: [], registry: [:], now: Date().addingTimeInterval(200))
        check(vault.entry(waiting.id)?.status == .held && vault.entry(waiting.id)?.note?.contains("확인 안 됨") == true, "복귀 확인 2분 초과: 다시 '보관 중'(터미널 확인 안내)")
        var running = AgentSession(id: ProcessKey(pid: 1, start: 1), kind: .claudeCode, rootPID: 888_888, pids: [888_888], cwd: work, project: "시험")
        running.logPath = recoveryRoot + "/x/\(waiting.resumeID!).jsonl"
        let already = RecoveryRestorer.restoreSession(vault.entry(waiting.id)!, vault: vault, sessions: [running], registry: [:], launcher: launcher)
        if case .alreadyRunning = already { check(vault.entry(waiting.id)?.status == .restored, "이미 돌아와 있으면 다시 열지 않음") } else { check(false, "이미 돌아와 있으면 다시 열지 않음") }
        var lost = waiting; lost.id = UUID().uuidString.lowercased(); lost.cwd = recoveryRoot + "/없는-폴더"; lost.status = .held
        try? vault.add(lost)
        check(!RecoveryRestorer.restoreSession(lost, vault: vault, sessions: [], registry: [:], launcher: launcher).ok, "원래 폴더가 없으면 실패로 알림(엉뚱한 폴더에서 열지 않음)")
    } else {
        check(false, "되살리기 시험 건너뜀(보관 항목 없음)")
    }

    // 10) 휴지통 되돌리기(진짜 휴지통 · 더미 폴더)
    let trashMe = recoveryRoot + "/trash-me-\(UUID().uuidString.prefix(6))"
    try? fm.createDirectory(atPath: trashMe + "/sub", withIntermediateDirectories: true)
    fm.createFile(atPath: trashMe + "/a.txt", contents: Data("가".utf8))
    fm.createFile(atPath: trashMe + "/sub/b.txt", contents: Data("나".utf8))
    let trashed = try? SafeFileOps.moveToTrash(trashMe, userPIDs: [], dryRun: false, bytes: 6, audit: audit, vault: vault, project: "시험", reason: "시험")
    let trashEntry = vault.all().first { $0.kind == .trash && $0.originalPath == trashMe }
    check(trashed != nil && !fm.fileExists(atPath: trashMe) && trashEntry?.trashedPath == trashed?.path, "휴지통: 옮긴 위치를 금고에 기록")
    if let trashEntry {
        let back = RecoveryRestorer.restoreTrash(trashEntry, vault: vault)
        let content = (try? String(contentsOfFile: trashMe + "/sub/b.txt", encoding: .utf8)) ?? ""
        check(back.ok && content == "나" && vault.entry(trashEntry.id)?.status == .restored, "휴지통 되돌리기: 원래 자리 · 내용 그대로")
    }
    try? fm.removeItem(atPath: trashMe)

    // 11) git: 치운 브랜치·워크트리를 같은 커밋으로(실제 git, 더미 저장소)
    let git = LeftoverTools.findGit()
    let gitRoot = recoveryRoot + "/git"
    let repo = gitRoot + "/repo"
    @discardableResult func g(_ arguments: [String]) -> CommandResult { setupGit(git, arguments) }
    g(["init", "-q", "-b", "main", repo])
    g(["-C", repo, "config", "user.name", "ReMON Check"]); g(["-C", repo, "config", "user.email", "check@remon.invalid"])
    fm.createFile(atPath: repo + "/.gitignore", contents: Data("node_modules/\n".utf8)); g(["-C", repo, "add", "-A"]); g(["-C", repo, "commit", "-q", "-m", "c1"])
    g(["-C", repo, "checkout", "-q", "-b", "feature/merged"])
    fm.createFile(atPath: repo + "/f.txt", contents: Data("f".utf8)); g(["-C", repo, "add", "-A"]); g(["-C", repo, "commit", "-q", "-m", "c2"])
    g(["-C", repo, "checkout", "-q", "main"]); g(["-C", repo, "merge", "-q", "--no-ff", "-m", "merge", "feature/merged"])
    let featureHead = g(["-C", repo, "rev-parse", "feature/merged"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let wtPath = gitRoot + "/wt/clean"
    g(["-C", repo, "worktree", "add", "-q", "-b", "wt/clean", wtPath, "main"])
    let wtHead = g(["-C", wtPath, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let tools = LeftoverTools(git: git, orca: nil)
    var options = LeftoverScanOptions()
    options.projectName = { _ in "recovery" }
    let report = LeftoverScanner.report(devRoot: gitRoot, sessions: [], orcaTerminals: [], orcaWorktrees: [], tools: tools, options: options)
    let results = LeftoverCleaner.clean(report.projects, dryRun: false, audit: audit, tools: tools, options: options, vault: vault)
    let gitEntries = vault.all().filter { ($0.kind == .branch || $0.kind == .worktree) && $0.repo.map { SafeFileOps.canonical($0) == SafeFileOps.canonical(repo) } == true }
    check(results.contains { $0.ok && !$0.skipped } && gitEntries.contains { $0.kind == .branch && $0.head == featureHead } && gitEntries.contains { $0.kind == .worktree && $0.head == wtHead },
          "git 청소: 지운 브랜치·워크트리의 커밋을 금고에 기록(\(gitEntries.count)건)")
    for entry in gitEntries { _ = RecoveryRestorer.restoreGit(entry, vault: vault, git: git) }
    let branchBack = g(["-C", repo, "rev-parse", "refs/heads/feature/merged"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let wtBack = fm.fileExists(atPath: wtPath) ? g(["-C", wtPath, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    check(branchBack == featureHead && wtBack == wtHead, "git 되돌리기: 브랜치 \(featureHead.prefix(8)) · 워크트리 \(wtHead.prefix(8)) 같은 커밋으로 되살림")

    // 12) 영구 삭제 등급: 순수 캐시·쉬는 프로젝트 산출물만, 쓰는 중·최근·잠금 파일 없는 node_modules·사용자 데이터는 휴지통
    let home = NSHomeDirectory()
    let old = Date().addingTimeInterval(-3 * 86_400)
    let project = recoveryRoot + "/proj"
    try? fm.createDirectory(atPath: project + "/node_modules", withIntermediateDirectories: true)
    let lockless = DiskItem(path: project + "/node_modules", category: .regenerable, bytes: 1, modified: old, note: "")
    let tierLockless = CacheDeletionPolicy.tier(for: lockless, activeDirectories: [])
    fm.createFile(atPath: project + "/package-lock.json", contents: Data("{}".utf8))
    let tiers: [(DiskItem, Set<String>, CacheDeletionPolicy.Tier, String)] = [
        (DiskItem(path: home + "/.npm/_cacache", category: .regenerable, bytes: 1, modified: Date(), note: ""), [], .pureCache, "npm 캐시 → 영구"),
        (DiskItem(path: project + "/.build", category: .regenerable, bytes: 1, modified: old, note: ""), [], .rebuildable, "쉬는 프로젝트 .build → 영구"),
        (DiskItem(path: project + "/.build", category: .regenerable, bytes: 1, modified: old, note: ""), [project], .trashOnly, "세션이 쓰는 프로젝트 .build → 휴지통"),
        (DiskItem(path: project + "/.build", category: .regenerable, bytes: 1, modified: Date(), note: ""), [], .trashOnly, "하루 안에 바뀐 .build → 휴지통"),
        (DiskItem(path: project + "/node_modules", category: .regenerable, bytes: 1, modified: old, note: ""), [], .rebuildable, "잠금 파일 있는 node_modules → 영구"),
        (DiskItem(path: home + "/.codex/logs", category: .aiLogs, bytes: 1, modified: old, note: ""), [], .trashOnly, "AI 기록 → 영구 삭제 안 함"),
    ]
    let tierResults = tiers.map { CacheDeletionPolicy.tier(for: $0.0, activeDirectories: $0.1, running: RunningApps.empty) == $0.2 }
    check(tierResults.allSatisfy { $0 } && tierLockless == .trashOnly, "영구 삭제 등급: " + tiers.map(\.3).joined(separator: " · ") + " · 잠금 파일 없는 node_modules → 휴지통")
    // 카탈로그 등급: A는 주인 앱이 꺼져 있을 때만 영구 · C·기본 제외·권장 명령이 있는 항목은 영구 삭제 안 함 · B는 쉬는 것만
    let fakeOwner = CacheOwner("시험 앱", bundleIDs: ["com.remon.check.fake"])
    let ownerOn = RunningApps(bundleIDs: ["com.remon.check.fake"])
    let gradedA = DiskItem(path: recoveryRoot + "/graded-cache", category: .regenerable, bytes: 1, modified: Date(), note: "", grade: .a, owner: fakeOwner,
                           entryID: "check.graded", hint: "시험 도구가 다시 받습니다")
    let gradedCases: [(DiskItem, RunningApps, CacheDeletionPolicy.Tier, String)] = [
        (gradedA, .empty, .pureCache, "A·주인 꺼짐 → 영구"),
        (gradedA, ownerOn, .trashOnly, "A·주인 실행 중 → 휴지통만"),
        (DiskItem(path: recoveryRoot + "/archives", category: .keep, bytes: 1, modified: old, note: "", grade: .c, defaultExcluded: true), .empty, .trashOnly, "C → 영구 안 함"),
        (DiskItem(path: recoveryRoot + "/playwright", category: .regenerable, bytes: 1, modified: old, note: "", grade: .b, defaultExcluded: true), .empty, .trashOnly, "기본 제외 B → 휴지통만"),
        (DiskItem(path: home + "/Library/pnpm/store", category: .regenerable, bytes: 1, modified: old, note: ""), .empty, .trashOnly, "옛 pnpm 저장소 → pnpm store prune 안내"),
        (DiskItem(path: recoveryRoot + "/support", category: .regenerable, bytes: 1, modified: old, note: "", grade: .b, entryID: "xcode.deviceSupport"), .empty, .rebuildable, "B·쉼 → 영구"),
        (DiskItem(path: recoveryRoot + "/support", category: .regenerable, bytes: 1, modified: Date(), note: "", grade: .b, entryID: "xcode.deviceSupport"), .empty, .trashOnly, "B·하루 안 → 휴지통만"),
    ]
    let gradedResults = gradedCases.map { CacheDeletionPolicy.tier(for: $0.0, activeDirectories: [], running: $0.1) == $0.2 }
    check(gradedResults.allSatisfy { $0 } && CacheDeletionPolicy.blockReason(for: gradedA, running: ownerOn) == "시험 앱 실행 중 — 종료한 뒤 정리합니다"
          && CacheDeletionPolicy.blockReason(for: gradedA, running: RunningApps.empty) == nil && CacheDeletionPolicy.regenerationHint(for: gradedA) == "시험 도구가 다시 받습니다",
          "카탈로그 등급: " + gradedCases.map(\.3).joined(separator: " · ") + " · 결과 \(gradedResults.map { $0 ? "✓" : "✗" }.joined())")
    let junk = recoveryRoot + "/junk-cache"
    try? fm.createDirectory(atPath: junk, withIntermediateDirectories: true)
    try? SafeFileOps.deletePermanently(junk, userPIDs: [], dryRun: false, bytes: 1, audit: audit, vault: vault, project: "시험", reason: "시험", regeneration: "다시 받음")
    check(!fm.fileExists(atPath: junk) && vault.all().contains { $0.kind == .deleted && $0.originalPath?.hasSuffix("/junk-cache") == true && $0.restoreHint == "다시 받음" && !$0.restorable },
          "영구 삭제: 무엇을 지웠고 어떻게 다시 생기는지 기록(되돌리기 버튼 없음)")

    // 13) 만료: 30일 지난 세션 보관본 삭제 · 비워진 휴지통 항목 만료
    var stale = RecoveryEntry(kind: .session, status: .held, project: "시험", title: "오래됨", reason: "시험", now: Date().addingTimeInterval(-31 * 86_400))
    let staleBackup = recoveryRoot + "/stale-backup.jsonl"
    fm.createFile(atPath: staleBackup, contents: Data("x".utf8))
    stale.backup = staleBackup; stale.resumeID = UUID().uuidString.lowercased()
    try? vault.add(stale)
    var emptiedTrash = RecoveryEntry(kind: .trash, status: .held, project: "시험", title: "비워짐", reason: "시험")
    emptiedTrash.trashedPath = recoveryRoot + "/없는-휴지통-항목"
    try? vault.add(emptiedTrash)
    let expired = vault.expire()
    check(expired >= 2 && vault.entry(stale.id)?.status == .expired && !fm.fileExists(atPath: staleBackup) && vault.entry(emptiedTrash.id)?.status == .expired,
          "만료: 30일 지난 세션 보관본 삭제 · 비워진 휴지통 항목 만료(\(expired)건)")

    for p in [process, busyProcess] where p.isRunning { p.terminate() }
}

/// 진단 보고서: 실제 수집으로 만들고, 홈 경로·세션 제목이 들어가지 않는지 본다(읽기 전용).
func diagnosticsCheck() {
    let sampler = ProcessSampler()
    let detector = SessionDetector()
    _ = detector.detect(records: sampler.sample(), sampler: sampler, orca: [])
    Thread.sleep(forTimeInterval: 1)
    let records = sampler.sample()
    let sessions = detector.detect(records: records, sampler: sampler, orca: OrcaBridge.list() ?? []).sessions
    var system = SystemSnapshot()
    let systemSampler = SystemSampler()
    _ = systemSampler.sample()
    Thread.sleep(forTimeInterval: 0.5)
    system = systemSampler.sample()
    let report = DiagnosticsReport.build(system: system, sessions: sessions, processes: records, appVersion: "검사", vault: RecoveryVault.shared.all(),
                                         actionsLog: AuditLog.shared.url)
    let titles = sessions.compactMap(\.title).filter { $0.count > 6 }
    check(report.hasPrefix("ReMON 진단 보고서") && report.split(separator: "\n").count > 12, "진단 보고서 생성 · \(report.split(separator: "\n").count)줄")
    check(!report.contains(NSHomeDirectory()), "진단 보고서: 홈 경로 없음(~로 줄임)")
    check(!titles.contains { report.contains($0) }, "진단 보고서: 세션 제목 \(titles.count)개 중 들어간 것 없음")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remon-diagnostics-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let log = AuditLog(url: folder.appendingPathComponent("actions.jsonl"))
    let privateTitle = "PRIVATE-SESSION-TITLE-" + UUID().uuidString
    log.write(action: "session.terminate", target: privateTitle, result: "blocked: " + privateTitle + " /private/project/secret", dryRun: false)
    let redacted = DiagnosticsReport.build(system: system, sessions: sessions, processes: records, appVersion: "검사", vault: [], actionsLog: log.url)
    check(!redacted.contains(privateTitle) && !redacted.contains("/private/project/secret") && redacted.contains("session.terminate · blocked"),
          "진단 행동 기록: 대상·상세 결과의 제목과 경로를 제외하고 조치·상태만 표시")
    print(report.split(separator: "\n").prefix(8).joined(separator: "\n"))
}

/// 10-25 독립 검토가 찾은 결함의 회귀 검사(신호 뒤 기록 유지 · 일시 정지 · 임시 파일 · 금고 읽기 실패 · 고정 키 · 시작 폴더 ·
/// 복귀 두 번 누르기 · git 사전 기록 · 무시 파일 목록 · 휴지통 권한 · 움직인 브랜치).
func recoveryHardeningCheck() {
    let fm = FileManager.default
    let root = recoveryRoot + "-hard"
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    let audit = AuditLog(url: URL(fileURLWithPath: root + "/actions.jsonl"))
    func makeVault(_ folder: String) -> RecoveryVault { let vault = RecoveryVault(folder: URL(fileURLWithPath: folder)); vault.audit = audit; return vault }
    let vault = makeVault(root + "/vault")
    let work = checkRoot + "/work"
    try? fm.createDirectory(atPath: work, withIntermediateDirectories: true)
    func retirerFor(_ terminator: SessionTerminator) -> SessionRetirer { terminator.audit = audit; let r = SessionRetirer(vault: vault, terminator: terminator); r.audit = audit; return r }
    func dummySession(_ name: String, _ args: [String]) -> (Process, [ProcRecord], AgentSession, String) {
        let process = spawnDummy(name, args)
        let members = tree(process.processIdentifier)
        var session = session(for: members, kind: .claudeCode, state: .longIdle)
        let id = UUID().uuidString.lowercased()
        let log = root + "/projects/-work/\(id).jsonl"
        claudeTranscript(log, cwd: work, id: id)
        session.logPath = log
        return (process, members, session, id)
    }

    // 1) SIGTERM을 무시해 5초 안에 안 끝나도 금고 기록·보관본을 지우지 않는다 → 나중에 끝나면 보관으로 바뀐다.
    let (stubborn, stubbornMembers, stubbornSession, stubbornID) = dummySession("claude", ["--ignore-term"])
    let t1 = SessionTerminator(registry: TerminationRegistry()); t1.waitSeconds = 1
    let r1 = retirerFor(t1)
    let o1 = r1.execute(r1.prepare(plan: t1.plan(session: stubbornSession, members: stubbornMembers, environments: [:], context: ProtectionContext(), pinKey: "x"),
                                   registrySessionID: stubbornID, argv: ["claude"], reason: "시험", requireKey: true), dryRun: false, force: false, footprints: [:]) { _ in false }
    let waiting = vault.all().first { $0.resumeID == stubbornID }
    check(waiting?.status == .retiring && waiting?.backup.map { fm.fileExists(atPath: $0) } == true && SessionTerminator.isAlive(stubbornMembers[0].key),
          "신호 뒤 안 끝나도 금고 기록·보관본 유지(종료 대기) · \(o1.message)")
    kill(stubbornMembers[0].pid, SIGKILL); Thread.sleep(forTimeInterval: 0.5)
    let settled = vault.settleRetiring()
    check(settled.contains { $0.resumeID == stubbornID && $0.status == .held }, "나중에 끝나면 settleRetiring이 '보관 중'으로 바꿈")
    for member in stubbornMembers { kill(member.pid, SIGKILL) }

    // 2) 일시 정지(Ctrl-Z) 세션: 자동 경로는 손대지 않고, 수동 경로는 SIGCONT로 깨워 끝낸다.
    let (paused, pausedMembers, pausedSession, pausedID) = dummySession("claude", [])
    kill(pausedMembers[0].pid, SIGSTOP); Thread.sleep(forTimeInterval: 0.3)
    let t2 = SessionTerminator(registry: TerminationRegistry()); t2.waitSeconds = 2
    let r2 = retirerFor(t2)
    let plan2 = t2.plan(session: pausedSession, members: pausedMembers, environments: [:], context: ProtectionContext(), pinKey: "x")
    let auto2 = r2.execute(r2.prepare(plan: plan2, registrySessionID: pausedID, argv: ["claude"], reason: "시험", requireKey: true), dryRun: false, force: false, footprints: [:]) { _ in false }
    check(auto2.aborted?.contains("일시 정지") == true && SessionTerminator.isAlive(pausedMembers[0].key), "일시 정지 세션: 자동 경로는 정리하지 않음")
    let manual2 = r2.execute(r2.prepare(plan: plan2, registrySessionID: pausedID, argv: ["claude"], reason: "시험", requireKey: false), dryRun: false, force: false, footprints: [:]) { _ in false }
    check(manual2.entry?.status == .held && !SessionTerminator.isAlive(pausedMembers[0].key), "일시 정지 세션: 수동 경로는 SIGCONT로 깨워 종료 · 보관")
    if paused.isRunning { paused.terminate() }

    // 3) 신호 직전 확인이 이유를 돌려주면 신호 0건
    let (busy, busyMembers, busySession, busyID) = dummySession("claude", [])
    let recorder = SignalRecorder()
    let t3 = SessionTerminator(registry: TerminationRegistry()); t3.signalSender = { recorder.record($0, $1) }
    let r3 = retirerFor(t3)
    let o3 = r3.execute(r3.prepare(plan: t3.plan(session: busySession, members: busyMembers, environments: [:], context: ProtectionContext(), pinKey: "x"),
                                   registrySessionID: busyID, argv: ["claude"], reason: "시험", requireKey: true), dryRun: false, force: false, footprints: [:],
                        preSignalCheck: { "레지스트리 상태 busy" }) { _ in false }
    check(o3.aborted == "레지스트리 상태 busy" && recorder.calls.isEmpty && !vault.all().contains { $0.resumeID == busyID }, "신호 직전 확인(busy)이면 신호 0건 · 금고에도 안 남김")
    if busy.isRunning { busy.terminate() }

    // 4) 임시 파일은 영구 삭제하지 않는다(휴지통만)
    let temp = DiskItem(path: "/private/tmp/AdAppMgrRollBackBackup", category: .temporary, bytes: 146_000_000, modified: Date().addingTimeInterval(-10 * 86_400), note: "임시", grade: .a, entryID: "temp.old")
    check(CacheDeletionPolicy.tier(for: temp, activeDirectories: []) == .trashOnly, "임시 파일(롤백 백업 등)은 영구 삭제 대상이 아님 → 휴지통만")

    // 5) 금고 파일을 못 읽으면 던지고(정리 중단) 덮어쓰지 않는다
    let locked = makeVault(root + "/vault-locked")
    try? locked.add(RecoveryEntry(kind: .deleted, status: .gone, project: "시험", title: "원래 항목", reason: "시험"))
    let before = (try? Data(contentsOf: locked.fileURL)) ?? Data()
    chmod(locked.fileURL.path, 0o000)
    let threw = (try? locked.add(RecoveryEntry(kind: .deleted, status: .gone, project: "시험", title: "새 항목", reason: "시험"))) == nil
    chmod(locked.fileURL.path, 0o600)
    check(threw && (try? Data(contentsOf: locked.fileURL)) == before, "금고 읽기 실패 → 기록 거절(던짐) · 원래 파일 그대로")

    // 6) 고정 키: 기록 없는 새 세션을 고정 → 첫 기록이 생겨도 여전히 고정
    var fresh = AgentSession(id: ProcessKey(pid: 4242, start: 99), kind: .claudeCode, rootPID: 4242, pids: [4242], cwd: work, project: "시험")
    let stored = SessionPins.storedKeys(fresh, conversationID: nil)
    fresh.logPath = root + "/projects/-work/\(UUID().uuidString.lowercased()).jsonl"
    let stillPinned = !stored.isDisjoint(with: SessionPins.keys(fresh, conversationID: SessionLogReader.threadID(fromPath: fresh.logPath!)))
    let otherInFolder = AgentSession(id: ProcessKey(pid: 5151, start: 7), kind: .claudeCode, rootPID: 5151, pids: [5151], cwd: work, project: "시험")
    check(stillPinned && stored.isDisjoint(with: SessionPins.keys(otherInFolder, conversationID: nil)), "고정 키: 첫 기록이 생겨도 고정 유지 · 같은 폴더의 다른 세션은 고정 안 됨")

    // 7) 복귀 폴더: 기록의 첫 cwd(시작 폴더) 우선, 마지막 cwd는 대체
    let moved = root + "/moved-worktree"
    try? fm.createDirectory(atPath: moved, withIntermediateDirectories: true)
    let cwdID = UUID().uuidString.lowercased()
    let cwdLog = root + "/projects/-work/\(cwdID).jsonl"
    writeLines(cwdLog, [["type": "user", "cwd": work, "sessionId": cwdID, "message": ["role": "user", "content": "시작"]],
                        ["type": "assistant", "cwd": moved, "sessionId": cwdID, "message": ["role": "assistant", "content": "옮김"]]])
    var cwdSession = AgentSession(id: ProcessKey(pid: 6161, start: 1), kind: .claudeCode, rootPID: 6161, pids: [6161], cwd: work, project: "시험")
    cwdSession.logPath = cwdLog
    let cwdKey = ResumeKey.resolve(cwdSession, registrySessionID: cwdID, argv: []).key
    check(cwdKey?.cwd == work && cwdKey?.fallbackCwds.contains(moved) == true, "복귀 폴더: 시작 폴더 우선 · 옮겨 간 폴더는 대체")

    // 8) 복귀 두 번 누르기 → 한 번만 실행 · 실행 실패면 다시 '보관 중'
    var twice = RecoveryEntry(kind: .session, status: .held, project: "시험", title: "두 번", reason: "시험")
    twice.resumeID = UUID().uuidString.lowercased(); twice.resumeArgs = ["claude", "--resume", twice.resumeID!]; twice.cwd = work
    try? vault.add(twice)
    let launches = LaunchRecorder()
    let ok: RecoveryLauncher = { launches.record($0); return (true, "시험", "시험") }
    let first = RecoveryRestorer.restoreSession(twice, vault: vault, sessions: [], registry: [:], launcher: ok)
    let second = RecoveryRestorer.restoreSession(twice, vault: vault, sessions: [], registry: [:], launcher: ok)
    check(first.ok && !second.ok && launches.launches.count == 1, "복귀 두 번 누르기: 한 번만 실행")
    var failing = twice; failing.id = UUID().uuidString.lowercased(); failing.status = .held
    try? vault.add(failing)
    _ = RecoveryRestorer.restoreSession(failing, vault: vault, sessions: [], registry: [:], launcher: { _ in (false, "시험", "실패") })
    check(vault.entry(failing.id)?.status == .held, "복귀 실행 실패 → 다시 '보관 중'")

    // 9) 무시 파일: 배포본이 들 수 있는 dist·build·target·.venv·로그는 '다시 생기는 것'이 아니다
    let lr = LeftoverRules.self
    _ = lr
    check(!IgnoredFiles.isRegenerable("dist/ReMON-0.2.0.dmg") && !IgnoredFiles.isRegenerable("build/app") && !IgnoredFiles.isRegenerable("target/release/x")
          && !IgnoredFiles.isRegenerable(".venv/bin/python") && !IgnoredFiles.isRegenerable("server.log") && IgnoredFiles.isRegenerable("node_modules/a/index.js")
          && IgnoredFiles.isRegenerable(".build/debug/x"), "무시 파일: dist·build·target·.venv·로그는 보존, node_modules·.build만 재생성")

    // 10) 휴지통 항목: 권한 오류는 '비워짐'이 아니다
    let guarded = root + "/no-access"
    try? fm.createDirectory(atPath: guarded + "/inner", withIntermediateDirectories: true)
    chmod(guarded, 0o000)
    var trashEntry = RecoveryEntry(kind: .trash, status: .held, project: "시험", title: "권한", reason: "시험")
    trashEntry.trashedPath = guarded + "/inner"
    try? vault.add(trashEntry)
    vault.expire()
    chmod(guarded, 0o700)
    check(vault.entry(trashEntry.id)?.status == .held, "휴지통 항목: 권한 오류로 안 보이면 만료하지 않음")

    // 11) 되돌린 세션의 보관본은 정리한다
    var restoredEntry = RecoveryEntry(kind: .session, status: .restored, project: "시험", title: "되돌림", reason: "시험")
    let extra = root + "/extra-backup.jsonl"
    fm.createFile(atPath: extra, contents: Data("x".utf8))
    restoredEntry.backup = extra
    try? vault.add(restoredEntry)
    vault.expire()
    check(!fm.fileExists(atPath: extra) && vault.entry(restoredEntry.id)?.backup == nil, "되돌린 세션의 보관본 삭제(공간 회수)")

    // 12) git: 금고에 못 적으면 그 항목은 치우지 않는다 · 브랜치가 움직였으면 기록된 커밋으로 분리 체크아웃
    let git = LeftoverTools.findGit()
    let repo = root + "/git/repo"
    @discardableResult func g(_ arguments: [String]) -> CommandResult { setupGit(git, arguments) }
    g(["init", "-q", "-b", "main", repo]); g(["-C", repo, "config", "user.name", "ReMON Check"]); g(["-C", repo, "config", "user.email", "check@remon.invalid"])
    fm.createFile(atPath: repo + "/a.txt", contents: Data("a".utf8)); g(["-C", repo, "add", "-A"]); g(["-C", repo, "commit", "-q", "-m", "c1"])
    let wt = root + "/git/wt/clean"
    g(["-C", repo, "worktree", "add", "-q", "-b", "wt/clean", wt, "main"])
    let head = g(["-C", wt, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    var options = LeftoverScanOptions(); options.projectName = { _ in "hard" }
    let tools = LeftoverTools(git: git, orca: nil)
    let report = LeftoverScanner.report(devRoot: root + "/git", sessions: [], orcaTerminals: [], orcaWorktrees: [], tools: tools, options: options)
    fm.createFile(atPath: root + "/vault-file", contents: Data())
    let brokenVault = makeVault(root + "/vault-file/sub")
    let blocked = LeftoverCleaner.clean(report.projects, dryRun: false, audit: audit, tools: tools, options: options, vault: brokenVault)
    check(fm.fileExists(atPath: wt) && blocked.allSatisfy { $0.skipped }, "git 청소: 금고에 못 적으면 치우지 않음(\(blocked.count)건 건너뜀)")
    _ = LeftoverCleaner.clean(report.projects, dryRun: false, audit: audit, tools: tools, options: options, vault: vault)
    let wtEntry = vault.all().first { $0.kind == .worktree && $0.worktreePath.map { SafeFileOps.canonical($0) == SafeFileOps.canonical(wt) } == true }
    check(wtEntry?.status == .held && !fm.fileExists(atPath: wt), "git 청소: 먼저 기록(종료 대기) → 성공 뒤 보관")
    // 브랜치를 다른 커밋으로 옮긴 뒤 되살리기
    g(["-C", repo, "checkout", "-q", "wt/clean"]); fm.createFile(atPath: repo + "/b.txt", contents: Data("b".utf8)); g(["-C", repo, "add", "-A"]); g(["-C", repo, "commit", "-q", "-m", "moved"]); g(["-C", repo, "checkout", "-q", "main"])
    if let wtEntry {
        let result = RecoveryRestorer.restoreGit(wtEntry, vault: vault, git: git)
        let restoredHead = g(["-C", wt, "rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        check(result.ok && restoredHead == head && result.message.contains("움직여"), "브랜치가 움직였으면 기록된 커밋으로 분리 체크아웃하고 그대로 보고 · \(result.message)")
    }
}

/// 관찰 이력 없는 추정 고아: 부모가 사라져 launchd 아래로 간 개발 서버(더미 'vite')만 잡고, 제외 목록·나이 기준을 지킨다.
func suspectedOrphanCheck() {
    // 자식을 'vite'라는 이름의 더미로 띄운다(기본 자식은 /bin/sleep이라 개발 서버로 보이지 않는다).
    let vite = checkRoot + "/bin/vite"
    try? FileManager.default.createDirectory(atPath: checkRoot + "/bin", withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: vite)
    try? FileManager.default.copyItem(atPath: dummyBinary(), toPath: vite)
    let parent = spawnDummy("devparent", ["--children", "1", "--child-binary", vite])
    let before = tree(parent.processIdentifier)
    let children = before.dropFirst().map(\.pid)
    kill(parent.processIdentifier, SIGKILL)
    Thread.sleep(forTimeInterval: 0.8)
    let records = ProcessSampler().sample()
    let found = SuspectedOrphanScanner.scan(records: records, exclude: [], minAge: 0)
    let mine = found.filter { children.contains($0.top.pid) }
    check(!children.isEmpty && !mine.isEmpty && mine.allSatisfy { $0.kind == .devServer && $0.parentPID == 1 }, "추정 고아: 부모 잃은 개발 서버(더미 vite) 감지 · \(mine.count)개")
    check(SuspectedOrphanScanner.scan(records: records, exclude: Set(children), minAge: 0).allSatisfy { !children.contains($0.top.pid) }, "추정 고아: 이미 아는 프로세스(제외 목록)는 빼고")
    check(SuspectedOrphanScanner.scan(records: records, exclude: [], minAge: 3600).allSatisfy { !children.contains($0.top.pid) }, "추정 고아: 1시간 안 된 것은 빼고")
    for pid in children { kill(pid, SIGKILL) }
}


/// 이 Mac의 추정 고아 목록(읽기 전용 진단).
func suspectsProbe() {
    let records = ProcessSampler().sample()
    if let r = records.first(where: { $0.pid == 93312 }) {
        let argv = ProcessSampler.readArguments(pid: r.pid)?.argv ?? []
        print("93312 name=\(r.name) path=\(r.path ?? "nil") ppid=\(r.ppid) uid=\(r.uid) argv=\(argv.prefix(5)) kind=\(HelperKind.classify(name: r.name, path: r.path, argv: argv).rawValue)")
    } else { print("93312 not in sample") }
    for s in SuspectedOrphanScanner.scan(records: records, exclude: []) { print("suspect", s.top.pid, s.name, s.command.prefix(60), s.members.count) }
}

/// 건강 점수: 요인별 감점과 조치 연결.
func healthCheck() {
    var calm = SystemSnapshot()
    calm.memory.physical = 24 << 30; calm.memory.free = 8 << 30
    calm.disk.total = 460 << 30; calm.disk.available = 200 << 30
    let good = HealthScore.compute(system: calm, sessions: [], orphanHelpers: 0, suspected: 0, crashLoops: 0)
    var busy = calm
    busy.pressure = .warning; busy.swap = SwapStats(total: 24 << 30, used: 21 << 30); busy.disk.available = 15 << 30
    var orphan = AgentSession(id: ProcessKey(pid: 1, start: 1), kind: .claudeCode, rootPID: 1, pids: [1], project: "시험", state: .orphan)
    orphan.footprint = 1 << 30
    let bad = HealthScore.compute(system: busy, sessions: [orphan, orphan], orphanHelpers: 1, suspected: 1, crashLoops: 1)
    let ids = Set(bad.factors.map(\.id))
    check(good.score == 100 && good.factors.isEmpty, "건강 점수: 여유 있는 Mac은 100점 · 감점 없음")
    check(ids == ["pressure", "swap", "disk", "leftover", "helpers", "startup"] && bad.score == 100 - (15 + 22 + 20 + 6 + 5 + 5) && bad.grade == "위험",
          "건강 점수: 압박·스왑·디스크·고아 세션·보조 프로세스·반복 크래시 감점 → \(bad.score)점(\(bad.grade))")
    check(bad.factors.first { $0.id == "swap" }?.action == .optimizeMemory && bad.factors.first { $0.id == "disk" }?.action == .optimizeStorage, "건강 점수: 감점마다 조치 연결(스왑→메모리 최적화 · 디스크→저장소 정리)")
}
