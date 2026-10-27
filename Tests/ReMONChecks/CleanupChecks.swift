import Darwin
import Foundation
import ReMONCore

// 3단계(정리) · 2단계(경보) 검사. 실제 종료·삭제는 더미 프로세스·더미 폴더로만 한다(사양 12장).

let checkRoot = "/private/tmp/remon-check"

func dummyBinary() -> String {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--dummy"), index + 1 < arguments.count {
        let path = arguments[index + 1]
        guard FileManager.default.isExecutableFile(atPath: path) else {
            fputs("FAIL DummyAgent 실행 파일이 없습니다. swift build 전체를 먼저 실행하세요.\n", stderr)
            exit(2)
        }
        return path
    }
    // 릴리스·디버그 중 더 최근에 빌드된 쪽(예전 릴리스 빌드가 남아 새 시험 플래그를 모르는 일이 있었다).
    let candidates = ["release", "debug"].map { FileManager.default.currentDirectoryPath + "/.build/\($0)/DummyAgent" }
    guard let path = candidates.filter({ FileManager.default.isExecutableFile(atPath: $0) }).max(by: { modifiedDate($0) < modifiedDate($1) }) else {
        fputs("FAIL DummyAgent 실행 파일이 없습니다. swift build 전체를 먼저 실행하세요.\n", stderr)
        exit(2)
    }
    return path
}

func modifiedDate(_ path: String) -> Date {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
}

@discardableResult
func spawnDummy(_ name: String, _ arguments: [String], environment: [String: String]? = nil) -> Process {
    let fm = FileManager.default
    let path = checkRoot + "/bin/" + name
    try? fm.createDirectory(atPath: checkRoot + "/bin", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: checkRoot + "/work", withIntermediateDirectories: true)
    // 복사본이 원본보다 오래됐으면 새로 복사한다(시험 플래그가 늘어난 더미를 써야 한다).
    let source = dummyBinary()
    if !fm.fileExists(atPath: path) || modifiedDate(path) < modifiedDate(source) {
        try? fm.removeItem(atPath: path)
        try? fm.copyItem(atPath: source, toPath: path)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments + ["--lifetime", "90"]
    process.currentDirectoryURL = URL(fileURLWithPath: checkRoot + "/work")
    if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
        fputs("FAIL 더미 프로세스를 실행하지 못했습니다: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
    Thread.sleep(forTimeInterval: 0.4) // 자식 생성 대기
    return process
}

/// 루트와 그 아래 하위 프로세스 기록.
func tree(_ root: Int32) -> [ProcRecord] {
    let records = ProcessSampler().sample()
    var children: [Int32: [ProcRecord]] = [:]
    for record in records { children[record.ppid, default: []].append(record) }
    guard let top = records.first(where: { $0.pid == root }) else { return [] }
    var result = [top]
    var queue = [root]
    while let pid = queue.popLast() {
        for child in children[pid] ?? [] { result.append(child); queue.append(child.pid) }
    }
    return result
}

func session(for members: [ProcRecord], kind: AgentKind = .claudeCode, state: SessionState = .waiting, cpu: Double = 0, last: Date? = nil) -> AgentSession {
    let root = members[0]
    return AgentSession(id: root.key, kind: kind, rootPID: root.pid, pids: members.map(\.pid), footprint: members.reduce(0) { $0 + $1.footprint },
                        cpuPercent: cpu, startTime: root.startTime, cwd: checkRoot + "/work", state: state, lastActivity: last)
}

final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(Int32, Int32)] = []
    func record(_ pid: Int32, _ signal: Int32) -> Int32 {
        lock.lock(); calls.append((pid, signal)); lock.unlock()
        return 0
    }
}

func cleanupCheck() {
    try? FileManager.default.removeItem(atPath: checkRoot)
    let audit = AuditLog(url: URL(fileURLWithPath: checkRoot + "/actions.jsonl"))
    var evidence: [String: Any] = [:]

    // 1) 보호 목록: 기록용 송신기로 신호 시도가 0건인지 증명한다.
    let recorder = SignalRecorder()
    let guarded = SessionTerminator(registry: TerminationRegistry())
    guarded.audit = audit
    guarded.signalSender = { recorder.record($0, $1) }
    let context = ProtectionContext(pinnedKeys: ["pinned-key"])
    var cases: [(String, AgentSession, [ProcRecord], [Int32: [String: String]], String)] = []
    let me = tree(getpid()).prefix(1).map { $0 }
    cases.append(("ReMON 자신", session(for: me), me, [:], ""))
    let launcher = tree(getppid()).prefix(1).map { $0 }
    cases.append(("ReMON을 띄운 세션", session(for: launcher), launcher, [:], ""))
    let launchd = ProcessSampler().sample().filter { $0.pid == 1 }
    cases.append(("시스템(launchd)", session(for: launchd), launchd, [:], ""))
    let pinnedDummy = spawnDummy("claude", ["--children", "1"])
    let pinnedMembers = tree(pinnedDummy.processIdentifier)
    cases.append(("보호 고정", session(for: pinnedMembers), pinnedMembers, [:], "pinned-key"))
    let harness = spawnDummy("harness", ["--children", "1"], environment: ["CFFIXED_USER_HOME": checkRoot + "/fakehome"])
    let harnessMembers = tree(harness.processIdentifier)
    var harnessEnvironment: [Int32: [String: String]] = [:]
    for member in harnessMembers { harnessEnvironment[member.pid] = ProcessSampler.readArguments(pid: member.pid)?.environment ?? [:] }
    cases.append(("측정 하네스(CFFIXED_USER_HOME)", session(for: harnessMembers), harnessMembers, harnessEnvironment, ""))
    var orcaRecord = pinnedMembers[0]
    orcaRecord.path = "/Applications/Orca.app/Contents/MacOS/Orca"
    cases.append(("Orca 호스트", session(for: [orcaRecord]), [orcaRecord], [:], ""))
    var protectionRows: [[String: Any]] = []
    for (name, target, members, environment, pin) in cases {
        let plan = guarded.plan(session: target, members: members, environments: environment, context: context, pinKey: pin)
        let outcome = guarded.execute(plan, dryRun: false, force: true, footprints: [:]) { _ in true }
        check(!plan.blockers.isEmpty && outcome.blocked, "보호: \(name) → 차단(\(plan.blockers.first ?? "없음"))")
        protectionRows.append(["case": name, "blockers": plan.blockers, "blocked": outcome.blocked])
    }
    check(recorder.calls.isEmpty, "보호 목록 대상 종료 시도 \(recorder.calls.count)건(\(cases.count)개 사례, 실제 신호 대신 기록용 송신기)")
    check(SessionTerminator.isAlive(harnessMembers[0].key) && SessionTerminator.isAlive(pinnedMembers[0].key), "보호된 더미 프로세스는 살아 있음")
    evidence["protection"] = protectionRows
    pinnedDummy.terminate(); harness.terminate()

    // 2) 정상 종료: 드라이런 → 실제(SIGTERM). 대상·회수량이 같아야 한다.
    let real = SessionTerminator(registry: TerminationRegistry())
    real.audit = audit
    let polite = spawnDummy("claude", ["--children", "2"])
    let politeMembers = tree(polite.processIdentifier)
    let politeSession = session(for: politeMembers)
    let footprints = Dictionary(uniqueKeysWithValues: politeMembers.map { ($0.key, $0.footprint) })
    let plan = real.plan(session: politeSession, members: politeMembers, environments: [:], context: ProtectionContext(), pinKey: "x")
    let dry = real.execute(plan, dryRun: true, force: false, footprints: footprints) { _ in false }
    check(dry.dryRun && SessionTerminator.isAlive(politeMembers[0].key), "드라이런: 실제로 종료하지 않음(\(dry.terminated.count)개 예정)")
    let started = Date()
    let done = real.execute(plan, dryRun: false, force: false, footprints: footprints) { _ in false }
    let elapsed = Date().timeIntervalSince(started)
    check(done.remaining.isEmpty && !done.killedRemaining, String(format: "정상 종료(SIGTERM): %d개 모두 종료, %.1f초, SIGKILL 없음", done.terminated.count, elapsed))
    check(Set(dry.terminated) == Set(done.terminated) && dry.reclaimed == done.reclaimed, "드라이런과 실제 결과 일치(대상 \(done.terminated.count)개 · \(done.reclaimed)바이트)")
    evidence["graceful"] = ["targets": done.terminated.count, "seconds": elapsed, "dry_reclaimed": dry.reclaimed, "real_reclaimed": done.reclaimed]

    // 3) 고집 센 프로세스: SIGTERM 무시 → 5초 뒤 남은 것만 재확인 후 SIGKILL.
    let stubborn = spawnDummy("claude", ["--children", "1", "--ignore-term"])
    let stubbornMembers = tree(stubborn.processIdentifier)
    let stubbornPlan = real.plan(session: session(for: stubbornMembers), members: stubbornMembers, environments: [:], context: ProtectionContext(), pinKey: "x")
    var asked: [ProcessKey] = []
    let stubbornStart = Date()
    let stubbornOutcome = real.execute(stubbornPlan, dryRun: false, force: false, footprints: [:]) { remaining in asked = remaining; return true }
    let stubbornElapsed = Date().timeIntervalSince(stubbornStart)
    check(!asked.isEmpty && stubbornOutcome.killedRemaining && stubbornOutcome.remaining.isEmpty, String(format: "SIGTERM 무시 → %.1f초 뒤 남은 %d개 재확인 → SIGKILL로 모두 종료", stubbornElapsed, asked.count))
    check(stubbornElapsed >= 4.8, "SIGKILL 전에 5초 기다림")

    // 4) 재확인 거절: 남은 하위는 그대로 둔다.
    let declined = spawnDummy("claude", ["--children", "1", "--ignore-term"])
    let declinedMembers = tree(declined.processIdentifier)
    let declinedPlan = real.plan(session: session(for: declinedMembers), members: declinedMembers, environments: [:], context: ProtectionContext(), pinKey: "x")
    let declinedOutcome = real.execute(declinedPlan, dryRun: false, force: false, footprints: [:]) { _ in false }
    check(!declinedOutcome.remaining.isEmpty, "재확인을 거절하면 남은 \(declinedOutcome.remaining.count)개를 종료하지 않음")
    for key in declinedOutcome.remaining { kill(key.pid, SIGKILL) }

    // 5) 강제 종료(쫓아내기): 즉시 SIGKILL, 사유 기록은 evicted.
    let registry = TerminationRegistry()
    let forceTerminator = SessionTerminator(registry: registry)
    forceTerminator.audit = audit
    let target = spawnDummy("claude", ["--children", "2"])
    let targetMembers = tree(target.processIdentifier)
    let forcePlan = forceTerminator.plan(session: session(for: targetMembers), members: targetMembers, environments: [:], context: ProtectionContext(), pinKey: "x")
    let forced = forceTerminator.execute(forcePlan, dryRun: false, force: true, footprints: [:]) { _ in true }
    check(forced.remaining.isEmpty && registry.reason(for: targetMembers[0].key) == .evictedByReMON, "강제 종료: \(forced.terminated.count)개 즉시 종료 · 사유 '쫓겨남'")

    // 6) 파일: 금지 경로, 열린 파일, 휴지통(드라이런 → 실제).
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    for forbidden in ["/", home, home + "/DEV", home + "/Library", "/System/Library", "/Volumes/HSKim-LaCie", "relative/path"] {
        var refused = false
        do { _ = try SafeFileOps.validate(forbidden) } catch { refused = true }
        check(refused, "삭제 금지 경로 거부: \(forbidden)")
    }
    let heldDirectory = checkRoot + "/held"
    try? FileManager.default.createDirectory(atPath: heldDirectory, withIntermediateDirectories: true)
    let holder = spawnDummy("holder", ["--children", "0", "--hold-file", heldDirectory + "/open.txt"])
    // 부하가 큰 Mac에서는 더미가 파일을 여는 데 0.4초 넘게 걸린다 — 실제로 열릴 때까지(최대 5초) 기다린다.
    let openDeadline = Date().addingTimeInterval(5)
    while Date() < openDeadline, !ProcessSampler.openFiles(pid: holder.processIdentifier).contains(where: { $0.hasSuffix("/held/open.txt") }) { usleep(100_000) }
    var inUse = false
    do { _ = try SafeFileOps.moveToTrash(heldDirectory, userPIDs: [holder.processIdentifier], dryRun: false, bytes: 0, audit: audit) } catch SafeFileOps.Failure.inUse { inUse = true } catch {}
    check(inUse && FileManager.default.fileExists(atPath: heldDirectory), "열린 파일이 있는 폴더는 휴지통으로 옮기지 않음")
    holder.terminate()
    let cache = checkRoot + "/project/.build"
    try? FileManager.default.createDirectory(atPath: cache + "/debug", withIntermediateDirectories: true)
    for i in 0..<20 { FileManager.default.createFile(atPath: cache + "/debug/obj\(i).o", contents: Data(repeating: UInt8(i), count: 4096)) }
    _ = try? SafeFileOps.moveToTrash(cache, userPIDs: [], dryRun: true, bytes: 0, audit: audit)
    check(FileManager.default.fileExists(atPath: cache), "휴지통 드라이런: 그대로 있음")
    let blockedVaultPath = checkRoot + "/vault-is-a-file"
    FileManager.default.createFile(atPath: blockedVaultPath, contents: Data("금고를 쓸 수 없는 상황".utf8))
    let blockedVault = RecoveryVault(folder: URL(fileURLWithPath: blockedVaultPath))
    blockedVault.audit = audit
    var refusedTrash = false, refusedDelete = false
    do { _ = try SafeFileOps.moveToTrash(cache, userPIDs: [], dryRun: false, bytes: 0, audit: audit, vault: blockedVault) } catch { refusedTrash = true }
    do { try SafeFileOps.deletePermanently(cache, userPIDs: [], dryRun: false, bytes: 0, audit: audit, vault: blockedVault) } catch { refusedDelete = true }
    check(refusedTrash && refusedDelete && FileManager.default.fileExists(atPath: cache + "/debug/obj0.o"),
          "금고 쓰기 실패: 휴지통·영구 삭제 모두 실행 전에 중단, 더미 원본 보존")
    let pendingVault = RecoveryVault(folder: URL(fileURLWithPath: checkRoot + "/pending-file-vault"))
    pendingVault.audit = audit
    let pending = RecoveryEntry(kind: .trash, status: .retiring, project: "시험", title: "옮기는 중", reason: "시험", bytes: 1)
    do {
        try pendingVault.add(pending)
        _ = pendingVault.settleRetiring()
        check(pendingVault.entry(pending.id)?.status == .retiring, "세션 종료 확인이 진행 중인 파일 정리 기록을 완료로 바꾸지 않음")
    } catch { check(false, "더미 금고 준비 실패: \(error)") }
    let trashed = try? SafeFileOps.moveToTrash(cache, userPIDs: [], dryRun: false, bytes: 0, audit: audit)
    check(!FileManager.default.fileExists(atPath: cache) && trashed.map { FileManager.default.fileExists(atPath: $0.path) } == true, "휴지통 이동: 원래 자리에서 사라지고 휴지통에 있음")
    if let trashed { try? FileManager.default.removeItem(at: trashed) } // 시험용 더미만 지운다

    let auditLines = (try? String(contentsOfFile: checkRoot + "/actions.jsonl", encoding: .utf8))?.split(separator: "\n").count ?? 0
    check(auditLines >= 10, "감사 기록 \(auditLines)줄(시험 전용 파일)")
    evidence["audit_lines"] = auditLines
    writeEvidence("cleanup-checks.json", evidence)
}

/// 외장 이전: ExFAT 디스크 이미지를 '외장 볼륨'으로 만들어 sparsebundle 경로 전체를 검사한다.
func migrationCheck() {
    let root = checkRoot + "/migration"
    try? FileManager.default.removeItem(atPath: root)
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let image = root + "/exfat.dmg"
    _ = Shell.run("/usr/bin/hdiutil", ["create", "-size", "200m", "-fs", "ExFAT", "-volname", "REMONCHK", image], timeout: 120)
    guard let attach = Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-plist", image], timeout: 60),
          let plist = try? PropertyListSerialization.propertyList(from: Data(attach.utf8), format: nil) as? [String: Any],
          let volume = (plist["system-entities"] as? [[String: Any]])?.compactMap({ $0["mount-point"] as? String }).first else {
        check(false, "ExFAT 시험 이미지 연결 실패"); return
    }
    check(ExternalMigrator.filesystemType(volume).lowercased() == "exfat", "시험 볼륨 파일 시스템: \(ExternalMigrator.filesystemType(volume)) (\(volume))")
    let source = root + "/src/old-logs"
    try? FileManager.default.createDirectory(atPath: source + "/2026/09", withIntermediateDirectories: true)
    var expected: [String: Data] = [:]
    for i in 0..<30 {
        let data = Data((0..<(1000 + i * 337)).map { UInt8(($0 * 7 + i) % 251) })
        let path = source + "/2026/09/rollout-\(i).jsonl"
        FileManager.default.createFile(atPath: path, contents: data)
        expected[path] = data
    }
    try? FileManager.default.createSymbolicLink(atPath: source + "/latest", withDestinationPath: "2026/09/rollout-29.jsonl")
    let before = ExternalMigrator.tally(source)
    let migrator = ExternalMigrator(manifestURL: URL(fileURLWithPath: root + "/migrations.json"))
    migrator.audit = AuditLog(url: URL(fileURLWithPath: root + "/actions.jsonl"))
    do {
        let dry = try migrator.migrate(source: source, toVolume: volume, userPIDs: [], dryRun: true)
        check(dry.files == before.files && FileManager.default.fileExists(atPath: source + "/2026"), "외장 이전 드라이런: \(dry.files)개 예정, 원본 그대로")
        let record = try migrator.migrate(source: source, toVolume: volume, userPIDs: [], dryRun: false)
        var info = stat()
        lstat(source, &info)
        check((info.st_mode & S_IFMT) == S_IFLNK, "원래 자리에 링크를 남김")
        check(record.imagePath?.hasSuffix(ExternalMigrator.imageName) == true, "ExFAT이라 APFS sparsebundle 안에 담음: \(record.imagePath ?? "-")")
        let after = ExternalMigrator.tally(record.destination)
        check(after.files == before.files && after.bytes == before.bytes, "파일 수·크기 일치: \(after.files)개 · \(after.bytes)바이트")
        let readBack = expected.allSatisfy { path, data in (try? Data(contentsOf: URL(fileURLWithPath: path))) == data }
        check(readBack, "링크를 통해 30개 파일 내용이 원본과 바이트 단위로 같음")
        check(migrator.status(record) == .ok, "이전 기록 상태: 링크 정상")
        try migrator.undo(record, dryRun: false)
        lstat(source, &info)
        let restored = ExternalMigrator.tally(source)
        check((info.st_mode & S_IFMT) == S_IFDIR && restored.files == before.files && restored.bytes == before.bytes, "되돌리기: 원래 폴더로 복원, \(restored.files)개 · \(restored.bytes)바이트")
        let restoredContent = expected.allSatisfy { path, data in (try? Data(contentsOf: URL(fileURLWithPath: path))) == data }
        check(restoredContent, "되돌린 파일 내용도 바이트 단위로 같음")
        writeEvidence("migration-checks.json", ["volume_fs": ExternalMigrator.filesystemType(volume), "files": before.files, "bytes": before.bytes, "image": record.imagePath ?? "", "destination": record.destination])
        if let archive = try? migrator.attach(record.imagePath ?? "") { _ = Shell.run("/usr/bin/hdiutil", ["detach", archive], timeout: 60) }
    } catch {
        check(false, "외장 이전 시험 오류: \(error)")
    }
    _ = Shell.run("/usr/bin/hdiutil", ["detach", volume], timeout: 60)
    try? FileManager.default.removeItem(atPath: root)
}

/// 경보 3종(사양 11-2): 판정 규칙을 가상 부하로, 디스크는 실제 측정값 + 임계값 조정으로 재현.
func alertsCheck() {
    var settings = AlertSettings()
    var system = SystemSnapshot()
    system.disk.available = 40 * 1_073_741_824
    system.swap.used = 20 * 1_073_741_824
    check(AlertRules.evaluate(system: system, swapMinuteAgo: 20 * 1_073_741_824, settings: settings).isEmpty, "평상시: 경보 없음")
    system.disk.available = 10 * 1_073_741_824
    check(AlertRules.evaluate(system: system, swapMinuteAgo: nil, settings: settings) == [.diskLow], "디스크 여유 10GB < 15GB → 디스크 경보")
    system.disk.available = 40 * 1_073_741_824
    system.swap.used = UInt64(21.5 * 1_073_741_824)
    check(AlertRules.evaluate(system: system, swapMinuteAgo: 20 * 1_073_741_824, settings: settings) == [.swapSurge], "스왑 1분에 1.5GB 증가 → 스왑 급증 경보")
    system.swap.used = UInt64(20.5 * 1_073_741_824)
    check(AlertRules.evaluate(system: system, swapMinuteAgo: 20 * 1_073_741_824, settings: settings).isEmpty, "스왑 1분에 0.5GB 증가 → 경보 없음")
    system.pressure = .critical
    check(AlertRules.evaluate(system: system, swapMinuteAgo: nil, settings: settings) == [.pressureCritical], "메모리 압박 위험 → 압박 경보")
    // 실제 측정값으로: 지금 디스크 여유보다 1GB 큰 임계값이면 실제 수치로 경보가 난다.
    let live = SystemSampler().sample()
    settings.diskThreshold = live.disk.available + 1_073_741_824
    check(AlertRules.evaluate(system: live, swapMinuteAgo: nil, settings: settings).contains(.diskLow), "실측 디스크 여유 \(Fmt.gb(live.disk.available)) + 임계 조정 → 디스크 경보 발생")
    writeEvidence("alerts-checks.json", ["live_disk_available": live.disk.available, "live_swap_used": live.swap.used, "live_pressure": live.pressure.label])
}
