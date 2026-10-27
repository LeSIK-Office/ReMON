import Darwin
import Foundation
import ReMONCore

// 프로세스 복구(세션이 아닌 보조 프로세스·앱) 검사 — process-recovery.
// 끝내기 전에 금고에 먼저 적고(종료 대기) → 끝나면 보관 → 다시 띄우기(다시 띄우는 중 → 새 프로세스 확인 → 되돌림).
// 실제 종료·다시 띄우기는 이 검사가 띄운 더미(DummyAgent 사본)로만 한다. 앱 열기·터미널 창은 가짜 실행기로만(창을 띄우지 않는다).

// 이 검사 전용 폴더(공유 checkRoot 밖 — 다른 검사가 checkRoot를 지워도 영향 없음). 시작할 때 비우고 끝나면 지운다.
private let prRoot = "/private/tmp/remon-process-recovery-check"
private let prBin = prRoot + "/bin"
private let prWork = prRoot + "/work"

/// 잠금으로 보호한 모음(송신기·실행기 클로저가 @Sendable이라).
private final class PRBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    func add(_ item: T) { lock.lock(); items.append(item); lock.unlock() }
    var all: [T] { lock.lock(); defer { lock.unlock() }; return items }
}

/// 더미 사본(파일 이름이 프로세스 이름이 된다).
private func prDummy(_ name: String) -> String {
    let path = prBin + "/" + name
    try? FileManager.default.createDirectory(atPath: prBin, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) { try? FileManager.default.copyItem(atPath: dummyBinary(), toPath: path) }
    return path
}

/// 더미 환경: 바깥 터미널 흔적(Orca·tmux·번들 id)을 지우고 터미널로 고정, 다시 띄울 때 넘길 PORT·NODE_ENV, 그리고 금고에 남으면 안 되는 비밀 변수.
private func prEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("ORCA_") && !$0.key.hasPrefix("TMUX") && $0.key != "__CFBundleIdentifier" }
    environment["TERM_PROGRAM"] = "Apple_Terminal"
    environment["PORT"] = "4321"
    environment["NODE_ENV"] = "development"
    environment["REMON_CHECK_SECRET_TOKEN"] = "do-not-store-me"
    return environment
}

/// 부모 더미(가짜 세션 루트)가 helperName 더미 자식 하나를 helperArguments로 띄운다.
private func prSpawnPair(_ parentName: String, helperName: String, helperArguments: [String]) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: prDummy(parentName))
    process.arguments = ["--children", "1", "--child-binary", prDummy(helperName)] + helperArguments.flatMap { ["--child-arg", $0] } + ["--lifetime", "90"]
    try? FileManager.default.createDirectory(atPath: prWork, withIntermediateDirectories: true)
    process.currentDirectoryURL = URL(fileURLWithPath: prWork)
    process.environment = prEnvironment()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    return process
}

@discardableResult
private func prWait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(100_000)
    }
    return condition()
}

/// 우리 더미(실행 파일이 이 검사 폴더 아래)인지 확인한 뒤에만 신호를 보낸다.
private func prKill(_ key: ProcessKey, _ signal: Int32 = SIGKILL) {
    guard SessionTerminator.isAlive(key) else { return }
    let path = HelperGuard.executablePath(pid: key.pid) ?? ""
    guard path.hasPrefix(prRoot + "/") || path.hasPrefix("/tmp/remon-process-recovery-check/") else { return }
    kill(key.pid, signal)
}

/// 부모(가짜 Claude 세션 루트)만 SIGKILL → 자식이 launchd 아래로 가면, 세션 하위로 본 추적기가 남은 보조 프로세스로 분류한다.
private func prOrphan(_ parent: Process, project: String, tracker: HelperTracker, spawned: inout [ProcessKey]) -> (helper: OrphanHelper, child: ProcessKey, records: [ProcRecord])? {
    var records = ProcessSampler().sample()
    prWait(6) { records = ProcessSampler().sample(); return records.contains { $0.ppid == parent.processIdentifier } }
    guard let parentRecord = records.first(where: { $0.pid == parent.processIdentifier }),
          let childRecord = records.first(where: { $0.ppid == parent.processIdentifier }) else { return nil }
    spawned += [parentRecord.key, childRecord.key]
    let session = AgentSession(id: parentRecord.key, kind: .claudeCode, rootPID: parentRecord.pid, pids: [parentRecord.pid, childRecord.pid],
                               startTime: parentRecord.startTime, cwd: prWork, project: project)
    tracker.observe(records: records, sessions: [session])
    prKill(parentRecord.key)
    prWait(5) { ProcessSampler().sample().first { $0.key == childRecord.key }?.ppid == 1 }
    records = ProcessSampler().sample()
    tracker.observe(records: records, sessions: [])
    guard let helper = tracker.orphans.first(where: { $0.top == childRecord.key }) else { return nil }
    return (helper, childRecord.key, records)
}

func processRecoveryCheck() {
    let fm = FileManager.default
    try? fm.removeItem(atPath: prRoot)
    try? fm.createDirectory(atPath: prWork, withIntermediateDirectories: true)
    let audit = AuditLog(url: URL(fileURLWithPath: prRoot + "/actions.jsonl"))   // 시험 전용 감사 기록(대표 기록을 건드리지 않음)
    let vault = RecoveryVault(folder: URL(fileURLWithPath: prRoot + "/vault"))
    vault.audit = audit
    var spawned: [ProcessKey] = []
    let scripts = PRBox<Process>()
    defer {
        for key in spawned { prKill(key) }
        for shell in scripts.all where shell.isRunning { shell.terminate() }
        try? FileManager.default.removeItem(atPath: prRoot)   // 시험 찌꺼기(더미 사본·시험 금고·복귀 스크립트)는 남기지 않는다
    }

    // 0) 순수 규칙: 비밀값 가리기 · 환경 변수 거르기 · 다시 띄울 명령 조립.
    let sample = ["node", "server.js", "--api-key=sk-ABCDEFGHIJKLMNOPQRSTUVWX", "--token", "abc123", "--port", "3000", "DB_PASSWORD=hunter2",
                  "postgres://me:pw@localhost/db", "--header", "Authorization: Bearer abc.def.ghi", "--keep-alive"]
    let masked = ProcessRecovery.maskSecrets(sample)
    check(masked.argv == ["node", "server.js", "--api-key=••••", "--token", "••••", "--port", "3000", "DB_PASSWORD=••••",
                          "postgres://me:••••@localhost/db", "--header", "Authorization: Bearer ••••", "--keep-alive"] && masked.masked == 5,
          "비밀값 가리기: --x=값 · --x 값 · NAME=값 · URL 비밀번호 · Bearer 5개 → ••••(포트·--keep-alive는 그대로)")
    check(ProcessRecovery.maskSecrets(masked.argv).argv == masked.argv, "이미 가린 인자를 다시 가려도 같음(다시 뜬 프로세스와 비교용)")
    let pure = ProcessRecovery.launch(executable: "/opt/homebrew/bin/node", argv: ["node", "vite.js", "--port", "5173"], cwd: "/x",
                                      environment: ["PORT": "5173", "NODE_ENV": "development", "TERM_PROGRAM": "ghostty", "OPENAI_API_KEY": "sk-zzz", "HOME": "/Users/x"])
    check(pure.command == ["/usr/bin/env", "NODE_ENV=development", "PORT=5173", "/opt/homebrew/bin/node", "vite.js", "--port", "5173"]
          && pure.environment == ["PORT": "5173", "NODE_ENV": "development", "TERM_PROGRAM": "ghostty"],
          "명령 조립: PORT·NODE_ENV만 env로 넘김 · 첫 칸은 실행 파일 전체 경로 · 남기는 환경 변수는 정해진 이름만(API 키·HOME 버림)")

    // 1) 더미 보조 프로세스: 'claude' 더미 세션이 띄운 dev-helper(비밀값 인자 · PORT/NODE_ENV) → 부모만 SIGKILL → 남은 보조 프로세스.
    let secretKey = "sk-remonCHECKabcdefghijklmnop", secretToken = "remon-check-secret-value"
    let tracker = HelperTracker(settings: .init(idleAfter: 1, activeCPUPercent: 0.5, grace: 0))
    let parent = prSpawnPair("claude", helperName: "dev-helper", helperArguments: ["--api-key=" + secretKey, "--token", secretToken, "--port", "4321"])
    guard let first = prOrphan(parent, project: "복구팀", tracker: tracker, spawned: &spawned) else { check(false, "더미 보조 프로세스를 남은 보조 프로세스로 만들지 못함"); return }
    check(first.helper.origin.label == "Claude Code · 복구팀" && first.helper.parentPID == 1, "남은 보조 프로세스: 부모 SIGKILL → launchd 아래 · 출신 \(first.helper.origin.label)")

    // 2) 실제 종료기: 신호 순간 금고에 이미 '종료 대기'로 적혀 있고, 끝난 뒤 '보관 중'.
    let terminator = HelperTerminator(registry: TerminationRegistry())
    terminator.audit = audit
    terminator.waitSeconds = 1.5
    let seen = PRBox<RecoveryEntry.Status?>()
    terminator.signalSender = { pid, signal in
        seen.add(vault.all().first { $0.kind == .process && $0.pid == pid }?.status)
        return kill(pid, signal)
    }
    let plan = terminator.plan(first.helper, records: first.records)
    check(plan.blockers.isEmpty && plan.launch != nil && plan.preview.contains("다시 띄우기(복구함)"), "계획: 보호 규칙 통과 · 다시 띄울 명령을 계획 때 읽음 · 미리보기에 명령")
    check(plan.warnings.contains { $0.contains("비밀값 2개") }, "계획 경고: 가린 비밀값 2개(다시 띄울 때 직접 채워야 할 수 있음)")
    let outcome = terminator.execute(plan, dryRun: false, vault: vault) { _ in true }
    let entry = vault.all().first { $0.kind == .process && $0.pid == first.child.pid && $0.processStart == first.child.start }
    check(seen.all.first == .retiring, "금고 먼저: SIGTERM을 보내는 순간 금고 상태 = \(seen.all.first.flatMap { $0?.rawValue } ?? "기록 없음")(종료 대기)")
    check(outcome.terminated == [first.child] && !SessionTerminator.isAlive(first.child) && outcome.entry?.status == .held && entry?.status == .held && entry?.restorable == true,
          "종료 뒤: 더미 끝남 · 금고 '보관 중'(다시 띄우기 가능) · \(outcome.message)")
    let helperPath = prDummy("dev-helper")
    let expectedArgv = [helperPath, "--api-key=••••", "--token", "••••", "--port", "4321", "--children", "0", "--lifetime", "95"]
    check(entry?.processArgv == expectedArgv, "실행 인자: 비밀값 2개 ••••(키·토큰) · 나머지 그대로 — \(entry?.processArgv?.dropFirst().joined(separator: " ") ?? "-")")
    let raw = (try? String(contentsOf: vault.fileURL, encoding: .utf8)) ?? ""
    check(!raw.isEmpty && !raw.contains(secretKey) && !raw.contains(secretToken) && !raw.contains("do-not-store-me") && !raw.contains("REMON_CHECK_SECRET")
          && !raw.contains("MESSAGING_TOKEN"), "금고 파일에 비밀값 없음(인자의 키·토큰 · 비밀 환경 변수의 이름·값)")
    let environment = entry?.processEnvironment ?? [:]
    check(environment["PORT"] == "4321" && environment["NODE_ENV"] == "development" && Set(environment.keys).isSubset(of: ProcessRecovery.environmentKeys),
          "환경 변수: 정해진 이름만 남김(\(environment.keys.sorted().joined(separator: ",")))")
    check(entry?.cwd == prWork && entry?.executable == helperPath && entry?.origin == "Claude Code · 복구팀" && entry?.project == "복구팀"
          && entry?.agent == AgentKind.claudeCode.rawValue && (entry?.bytes ?? 0) > 0 && entry?.exitReason == "SIGTERM으로 종료",
          "기록: 폴더 · 실행 파일 · 출신 · 프로젝트 · 메모리 \(Fmt.size(entry?.bytes ?? 0)) · 끝난 방식 \(entry?.exitReason ?? "-")")
    let expectedCommand = ["/usr/bin/env", "NODE_ENV=development", "PORT=4321"] + expectedArgv
    let expectedLine = expectedCommand.map(ResumeKey.quote).joined(separator: " ")
    check(entry?.resumeArgs == expectedCommand && entry?.resumeCommand == "cd \(prWork) && " + expectedLine, "다시 띄울 명령: env PORT·NODE_ENV + 원래 명령(가림) · cd 원래 폴더")
    check(entry?.terminalHost == "터미널", "원래 터미널: 출신 세션의 터미널을 모를 때 환경 변수(TERM_PROGRAM=Apple_Terminal)로 → \(entry?.terminalHost ?? "-")")
    guard let held = entry else { return }

    // 3) 다시 띄우기(가짜 실행기): 받은 명령·폴더가 기록과 정확히 같다 · 두 번 눌러도 한 번만 · 확인이 안 되면 다시 보관 중.
    let launches = PRBox<RecoveryLaunch>()
    let fakeLauncher: RecoveryLauncher = { launch in launches.add(launch); return (true, "가짜", "가짜 실행기가 명령을 받았습니다") }
    let noApp: RecoveryRestorer.AppOpener = { _, _ in (false, "앱 항목이 아닙니다") }
    let nothingRunning: RecoveryRestorer.ProcessLookup = { _, _ in nil }
    let relaunched = RecoveryRestorer.restoreProcess(held, vault: vault, launcher: fakeLauncher, appOpener: noApp, running: nothingRunning)
    let again = RecoveryRestorer.restoreProcess(held, vault: vault, launcher: fakeLauncher, appOpener: noApp, running: nothingRunning)
    let firstLaunch = launches.all.first
    check(relaunched.ok && launches.all.count == 1 && firstLaunch?.arguments == held.resumeArgs && firstLaunch?.arguments == expectedCommand && firstLaunch?.cwd == prWork
          && firstLaunch?.terminalHost == "터미널" && vault.entry(held.id)?.status == .restoring,
          "다시 띄우기(가짜 실행기): 받은 명령·폴더가 기록과 정확히 같음 · 원래 터미널 · 상태 '다시 띄우는 중'")
    check(!again.ok && launches.all.count == 1, "두 번 눌러도 한 번만 실행(잠금 안에서 보관 중 → 다시 띄우는 중)")
    let unconfirmed = RecoveryRestorer.reconcile(vault: vault, sessions: [], registry: [:], now: Date().addingTimeInterval(130), processLookup: nothingRunning)
    check(unconfirmed.contains { $0.id == held.id && $0.status == .held } && vault.entry(held.id)?.note?.contains("확인하지 못했습니다") == true,
          "2분 넘게 새 프로세스가 안 보이면 다시 '보관 중'(다시 띄우기 버튼이 살아남)")

    // 4) 실제 실행기(RecoveryLaunchers.live) + 가짜 open(터미널이 .command를 돌린 것처럼 zsh로 바로 실행) → 같은 더미가 같은 폴더·환경으로 다시 뜬다.
    let opens = PRBox<(String, [String])>()
    let runner: CommandRunner = { executable, arguments, _ in
        opens.add((executable, arguments))
        guard executable == "/usr/bin/open", let script = arguments.last, script.hasSuffix(".command") else { return CommandResult(status: 1, stderr: "시험: 실제 실행 막음") }
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-f", script]
        // 바깥 환경을 물려받지 않게 최소 환경으로(PORT·NODE_ENV는 다시 띄울 명령이 직접 넘겨야 한다).
        shell.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        do { try shell.run() } catch { return CommandResult(status: 1, stderr: "\(error)") }
        scripts.add(shell)
        return CommandResult(status: 0)
    }
    let liveLauncher = RecoveryLaunchers.live(folder: vault.launchFolder, run: runner, tmuxRun: { _, _, _ in CommandResult(status: 1, stderr: "시험: tmux 없음") }, markerWait: 3)
    guard let heldAgain = vault.entry(held.id) else { check(false, "금고 항목이 사라짐"); return }
    let started = Date()
    let real = RecoveryRestorer.restoreProcess(heldAgain, vault: vault, launcher: liveLauncher, appOpener: noApp)   // 실제 조회: 같은 더미가 떠 있지 않아야 진행
    var restoredPID: Int32?
    prWait(10) { restoredPID = ProcessRecovery.runningMatch(heldAgain, started.addingTimeInterval(-2)); return restoredPID != nil }
    if let pid = restoredPID, let key = ProcessRecovery.processKey(pid: pid) { spawned.append(key) }
    let openCall = opens.all.first { $0.0 == "/usr/bin/open" }
    let script = openCall?.1.last.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
    check(real.ok && openCall.map { Array($0.1.prefix(2)) } == ["-a", "Terminal"] && script.contains("cd \(prWork) ||") && script.contains(expectedLine),
          "실제 실행기: 원래 터미널(터미널)용 .command 스크립트 — cd 원래 폴더 + 같은 명령 · \(real.message)")
    let restoredLaunch = restoredPID.flatMap { ProcessRecovery.capture(pid: $0) }
    check(restoredPID != nil && restoredLaunch?.executable == helperPath && restoredLaunch?.cwd == prWork && restoredLaunch?.environment["PORT"] == "4321"
          && restoredLaunch?.environment["NODE_ENV"] == "development" && Array((restoredLaunch?.argv ?? []).dropFirst()) == Array(expectedArgv.dropFirst()),
          "다시 뜸: pid \(restoredPID.map(String.init) ?? "-") · 같은 실행 파일 · 같은 폴더 · PORT=4321 · NODE_ENV=development · 같은 인자(가린 값 그대로)")
    _ = RecoveryRestorer.reconcile(vault: vault, sessions: [], registry: [:])
    check(vault.entry(held.id)?.status == .restored && vault.entry(held.id)?.note?.contains("pid \(restoredPID ?? -1)") == true,
          "확인: 새 프로세스(실행 파일·폴더·인자)가 보이면 '되돌림' · \(vault.entry(held.id)?.note ?? "-")")

    // 5) 앱 항목: 종료 대기 → (프로세스 끝남) 보관 → 가짜 opener로 번들 id 열기 → 다시 띄우는 중 → 확인되면 되돌림. 이미 떠 있으면 또 열지 않는다.
    let appEntry = ProcessRecovery.appEntry(name: "가짜 앱", bundleID: "com.remon.check.fakeapp", bundlePath: prRoot + "/Fake.app", executable: prRoot + "/Fake.app/Contents/MacOS/Fake",
                                            pid: 999_999, start: 1, footprint: 123 << 20, launch: nil, reason: "앱 강제 종료", status: .retiring)
    _ = try? vault.add(appEntry)
    let settled = vault.settleRetiring()
    let heldApp = vault.entry(appEntry.id)
    check(heldApp?.status == .held && heldApp?.restorable == true && heldApp?.exitReason == "강제 종료 뒤 끝남"
          && heldApp?.resumeCommand == "open -b com.remon.check.fakeapp" && heldApp?.isAppProcess == true,
          "앱: 종료 대기 → 프로세스가 끝나면 보관 중 · 끝난 방식 · 복사용 명령 open -b 번들 id")
    check(!settled.contains { $0.id == appEntry.id }, "보관으로 바뀐 프로세스 항목은 정신교육실 알림 목록에 넣지 않음(복구함에만)")
    let opened = PRBox<(String?, String?)>()
    let fakeOpener: RecoveryRestorer.AppOpener = { bundle, path in opened.add((bundle, path)); return (true, "가짜로 엶") }
    let appLaunch = heldApp.map { RecoveryRestorer.restoreProcess($0, vault: vault, launcher: fakeLauncher, appOpener: fakeOpener, running: nothingRunning) }
    check(appLaunch?.ok == true && opened.all.count == 1 && opened.all.first?.0 == "com.remon.check.fakeapp" && launches.all.count == 1 && vault.entry(appEntry.id)?.status == .restoring,
          "앱 다시 띄우기: opener가 번들 id(com.remon.check.fakeapp)를 받음 · 터미널 실행기는 안 씀 · 다시 띄우는 중")
    _ = RecoveryRestorer.reconcile(vault: vault, sessions: [], registry: [:], processLookup: { candidate, _ in candidate.id == appEntry.id ? 4242 : nil })
    check(vault.entry(appEntry.id)?.status == .restored, "앱: 새 프로세스가 보이면(가짜 조회 pid 4242) 되돌림")
    let runningApp = ProcessRecovery.appEntry(name: "떠 있는 앱", bundleID: "com.remon.check.running", bundlePath: nil, executable: nil, pid: 999_998, start: 1,
                                              footprint: 0, launch: nil, reason: "앱 강제 종료", status: .held)
    _ = try? vault.add(runningApp)
    let already = RecoveryRestorer.restoreProcess(runningApp, vault: vault, launcher: fakeLauncher, appOpener: fakeOpener, running: { _, _ in 777 })
    check(already == .alreadyRunning("이미 떠 있습니다 · pid 777") && opened.all.count == 1 && vault.entry(runningApp.id)?.status == .restored,
          "이미 떠 있으면 또 열지 않음(되돌림으로 표시)")

    // 6) 금고에 못 적으면 끝내지 않는다: 신호 0건 · 더미 살아 있음(금고 폴더 자리에 파일 · 금고 없음 두 경우).
    let blocker = prRoot + "/not-a-folder"
    fm.createFile(atPath: blocker, contents: Data("파일".utf8))
    let brokenVault = RecoveryVault(folder: URL(fileURLWithPath: blocker + "/vault"))
    brokenVault.audit = audit
    let tracker2 = HelperTracker(settings: .init(idleAfter: 1, activeCPUPercent: 0.5, grace: 0))
    let parent2 = prSpawnPair("claude", helperName: "dev-helper2", helperArguments: ["--port", "4322"])
    guard let second = prOrphan(parent2, project: "복구팀", tracker: tracker2, spawned: &spawned) else { check(false, "두 번째 더미를 남은 보조 프로세스로 만들지 못함"); return }
    let recorder = SignalRecorder()
    let guarded = HelperTerminator(registry: TerminationRegistry())
    guarded.audit = audit
    guarded.waitSeconds = 0.5
    guarded.signalSender = { recorder.record($0, $1) }
    let plan2 = guarded.plan(second.helper, records: second.records)
    let failedWrite = guarded.execute(plan2, dryRun: false, vault: brokenVault) { _ in true }
    let noVault = guarded.execute(plan2, dryRun: false, vault: nil) { _ in true }
    check(plan2.blockers.isEmpty && recorder.calls.isEmpty && failedWrite.aborted?.contains("복구 금고에 기록하지 못했습니다") == true && failedWrite.terminated.isEmpty
          && noVault.aborted != nil && SessionTerminator.isAlive(second.child),
          "금고 기록 실패 → 끝내지 않음: 신호 0건 · 더미 살아 있음 · \(failedWrite.aborted ?? "-")")

    // 7) 금고: 보관 기간 · 호환(새 필드 없는 예전 항목 · 모르는 종류 원문 보존) · all()에 kind == .process로 보임(보관실 요약용).
    let old = ProcessRecovery.appEntry(name: "오래된 앱", bundleID: "com.remon.check.old", bundlePath: nil, executable: nil, pid: 999_997, start: 1, footprint: 0,
                                       launch: nil, reason: "앱 강제 종료", status: .held, now: Date().addingTimeInterval(-31 * 86_400))
    _ = try? vault.add(old)
    let expiredCount = vault.expire()
    check(expiredCount >= 1 && vault.entry(old.id)?.status == .expired && vault.entry(old.id)?.resumeCommand != nil && vault.entry(old.id)?.restorable == false,
          "보관 기간(30일) 지난 프로세스 항목: 만료 · 버튼은 내리고 명령은 기록에 남김")
    let processEntries = vault.all().filter { $0.kind == .process }
    check(processEntries.count >= 4 && processEntries.contains { $0.id == held.id } && vault.heldProcesses.allSatisfy { $0.kind == .process },
          "RecoveryVault.all(): 프로세스 항목 \(processEntries.count)개(kind == .process) · heldProcesses \(vault.heldProcesses.count)개")
    let compat = RecoveryVault(folder: URL(fileURLWithPath: prRoot + "/compat"))
    compat.audit = audit
    try? fm.createDirectory(at: compat.folder, withIntermediateDirectories: true)
    let legacy = #"[{"id":"legacy-1","kind":"session","status":"held","createdAt":1800000000,"updatedAt":1800000000,"project":"옛","title":"옛 세션","reason":"수동","bytes":0,"resumeID":"11111111-2222-3333-4444-555555555555"},"#
        + #"{"id":"future-1","kind":"future-kind","status":"held","createdAt":1800000000,"updatedAt":1800000000,"project":"미래","title":"새 판 항목","reason":"?","bytes":0}]"#
    try? Data(legacy.utf8).write(to: compat.fileURL)
    let legacyEntry = compat.entry("legacy-1")
    _ = try? compat.add(runningApp)
    let rewritten = (try? String(contentsOf: compat.fileURL, encoding: .utf8)) ?? ""
    check(legacyEntry != nil && legacyEntry?.executable == nil && legacyEntry?.processArgv == nil && legacyEntry?.exitReason == nil && legacyEntry?.restorable == true
          && rewritten.contains("future-kind") && rewritten.contains("\"process\"") && compat.all().count == 2,
          "금고 호환: 새 필드 없는 예전 항목 읽힘 · 모르는 종류는 원문 보존 · 프로세스 항목 함께 저장")
    var evidence: [String: Any] = [:]
    let recorded: [String: Any] = ["argv": held.processArgv ?? [String](), "command": held.resumeArgs ?? [String](), "cwd": held.cwd ?? "", "origin": held.origin ?? "",
                                   "terminal": held.terminalHost ?? ""]
    evidence["entry"] = recorded
    evidence["restored_pid"] = Int(restoredPID ?? -1)
    evidence["signals_at_retiring"] = seen.all.count
    writeEvidence("process-recovery.json", evidence)
}
