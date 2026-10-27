import Darwin
import Foundation
import IOKit.pwr_mgt
import ReMONCore

// G2 남은 보조 프로세스 · G3 '왜 실행 중?' · G4 시작 항목 검사.
// 실제 종료·삭제는 이 검사가 띄운 더미 프로세스와 임시 폴더의 파일로만 한다.
// 실제 LaunchAgents·LaunchDaemons는 읽기만 한다(plist 읽기 · launchctl print/list). bootout·bootstrap·휴지통 이동은 가짜 실행기와 임시 plist로만.

// 이 검사 전용 폴더(공유 checkRoot 밖). 다른 검사·다른 에이전트가 checkRoot를 통째로 지워도(cleanup 검사는 시작할 때 지운다) 영향이 없다.
// 시작할 때 이 폴더만 비워 더미 사본이 늘 새 빌드다.
private let helperRoot = "/private/tmp/remon-helpers-check"
private let helperBin = helperRoot + "/bin"

/// 더미 실행 파일 사본(파일 이름이 프로세스 이름이 된다).
private func helperDummyCopy(_ name: String) -> String {
    let path = helperBin + "/" + name
    try? FileManager.default.createDirectory(atPath: helperBin, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: path) { try? FileManager.default.copyItem(atPath: dummyBinary(), toPath: path) }
    return path
}

/// spawnDummy와 같지만 이 검사 전용 폴더의 사본으로 띄운다.
@discardableResult
private func spawnHelper(_ name: String, _ arguments: [String], environment: [String: String]? = nil) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: helperDummyCopy(name))
    process.arguments = arguments + ["--lifetime", "90"]
    try? FileManager.default.createDirectory(atPath: helperRoot + "/work", withIntermediateDirectories: true)
    process.currentDirectoryURL = URL(fileURLWithPath: helperRoot + "/work")
    if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    Thread.sleep(forTimeInterval: 0.4) // 자식 생성 대기
    return process
}

private func childProcesses(of pid: Int32, in records: [ProcRecord]) -> [ProcRecord] { records.filter { $0.ppid == pid }.sorted { $0.pid < $1.pid } }

@discardableResult
private func helperWait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        usleep(100_000)
    }
    return condition()
}

/// launchd 아래로 떨어진 더미: sh가 뒤로 띄우고 바로 끝난다(분리된 에이전트 세션 흉내). pid를 돌려준다.
private func spawnDetachedDummy(_ path: String, _ arguments: [String]) -> Int32? {
    let line = ([path] + arguments).map(ResumeKey.quote).joined(separator: " ")
    // 'cd … && 명령 &'은 목록 전체가 하위 셸로 돌아 $!가 하위 셸 pid가 된다 → 명령만 뒤로 보낸다.
    let result = Shell.capture("/bin/sh", ["-c", "cd \(ResumeKey.quote(helperRoot + "/work")) || exit 1; \(line) </dev/null >/dev/null 2>&1 & echo $!"], timeout: 10)
    return Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
}

private func helperProcStat(_ pid: Int32) -> Int8? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_proc.p_stat
}

/// 우리 더미인지(실행 파일이 이 검사 폴더 아래, 또는 우리 더미가 띄운 /bin/sleep) 확인한 뒤에만 신호를 보낸다.
private func killHelperDummy(_ key: ProcessKey, _ signal: Int32 = SIGKILL) {
    guard SessionTerminator.isAlive(key) || helperProcStat(key.pid) == 5 else { return }
    // 지워진·바뀐 실행 파일은 proc_pidpath가 비어 실행 인자의 경로(/tmp/…)로 보인다 → 두 표기 모두 허용.
    let path = HelperGuard.executablePath(pid: key.pid) ?? ""
    guard path.hasPrefix(helperRoot + "/") || path.hasPrefix("/tmp/remon-helpers-check/") || path == "/bin/sleep" else { return }
    kill(key.pid, signal)
}

private final class HelperKeyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProcessKey] = []
    func set(_ keys: [ProcessKey]) { lock.lock(); stored = keys; lock.unlock() }
    var value: [ProcessKey] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// lsof로 같은 pid의 리슨 포트를 따로 읽어 대조한다(TCP LISTEN · UDP).
private func helperLsofPorts(_ pid: Int32) -> (tcp: Set<UInt16>, udp: Set<UInt16>) {
    let output = Shell.run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-i"], timeout: 15) ?? ""
    var tcp = Set<UInt16>(), udp = Set<UInt16>()
    for line in output.split(separator: "\n") {
        guard let range = line.range(of: #"127\.0\.0\.1:(\d+)"#, options: .regularExpression) else { continue }
        let port = UInt16(line[range].split(separator: ":").last ?? "") ?? 0
        if line.contains("TCP"), line.contains("(LISTEN)") { tcp.insert(port) }
        if line.contains("UDP") { udp.insert(port) }
    }
    return (tcp, udp)
}

// MARK: - G2 · G3

func helpersCheck() {
    let fm = FileManager.default
    try? fm.removeItem(atPath: helperRoot)
    try? fm.createDirectory(atPath: helperRoot, withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: helperRoot + "/work", withIntermediateDirectories: true)
    let audit = AuditLog(url: URL(fileURLWithPath: helperRoot + "/actions.jsonl"))
    let vault = RecoveryVault(folder: URL(fileURLWithPath: helperRoot + "/vault"))
    vault.audit = audit
    var evidence: [String: Any] = [:]
    var spawned: [ProcessKey] = []
    defer {
        for key in spawned { killHelperDummy(key) }
        try? FileManager.default.removeItem(atPath: helperRoot)   // 시험 찌꺼기(더미 사본·시험 금고·감사 기록)는 남기지 않는다
    }

    // 1) 더미 세션: claude(자식 MCP 2개, 각자 127.0.0.1 TCP·UDP) · codex(SIGTERM 무시하는 자식) · opencode(자식 /bin/sleep = 시스템 경로)
    //    · launcher(세션 아님, 자식 MCP 1개 = 관찰 안 된 프로세스) · launchd 아래로 분리된 claude(실제 감지기로 세션 인식, 자식 MCP 2개).
    let mcp = helperDummyCopy("mcp-helper")
    let parent = spawnHelper("claude", ["--children", "2", "--child-binary", mcp, "--child-arg", "@modelcontextprotocol/server-remon-check",
                                       "--child-arg", "--listen-tcp", "--child-arg", "0", "--child-arg", "--listen-udp", "--child-arg", "0"])
    let stubbornParent = spawnHelper("codex", ["--children", "1", "--child-binary", mcp, "--child-arg", "--ignore-term", "--child-arg", "@modelcontextprotocol/server-stubborn"])
    let systemParent = spawnHelper("opencode", ["--children", "1"])
    let launcher = spawnHelper("launcher", ["--children", "1", "--child-binary", mcp, "--child-arg", "@modelcontextprotocol/server-remon-check"])
    let detachedPID = spawnDetachedDummy(helperDummyCopy("claude"), ["--children", "2", "--child-binary", mcp, "--child-arg", "@modelcontextprotocol/server-detached", "--lifetime", "90"])
    let sampler = ProcessSampler()
    var records = sampler.sample()
    let parentPIDs = [parent.processIdentifier, stubbornParent.processIdentifier, systemParent.processIdentifier, launcher.processIdentifier]
    let expected = [2, 1, 1, 1]
    helperWait(6) {
        records = sampler.sample()
        let ok = zip(parentPIDs, expected).allSatisfy { childProcesses(of: $0.0, in: records).count == $0.1 }
        return ok && (detachedPID.map { childProcesses(of: $0, in: records).count == 2 } ?? false)
    }
    func key(_ pid: Int32) -> ProcessKey? { records.first { $0.pid == pid }?.key }
    // 실패해도 정리되도록 확인 전에 먼저 적어 둔다(정리는 검사 폴더 실행 파일·/bin/sleep만).
    let parentKeys = parentPIDs.compactMap(key)
    let c = childProcesses(of: parent.processIdentifier, in: records).map(\.key)
    let s = childProcesses(of: stubbornParent.processIdentifier, in: records).map(\.key)
    let z = childProcesses(of: systemParent.processIdentifier, in: records).map(\.key)
    let u = childProcesses(of: launcher.processIdentifier, in: records).map(\.key)
    let e = detachedPID.map { childProcesses(of: $0, in: records).map(\.key) } ?? []
    spawned.append(contentsOf: parentKeys)
    for group in [c, s, z, u, e] { spawned.append(contentsOf: group) }
    if let pid = detachedPID, let detached = key(pid) { spawned.append(detached) }
    guard let detachedPID, let detachedKey = key(detachedPID), HelperGuard.executablePath(pid: detachedPID) == helperDummyCopy("claude") else {
        check(false, "분리된 더미 claude를 띄우지 못함")
        return
    }
    guard c.count == 2, s.count == 1, z.count == 1, u.count == 1, e.count == 2, parentKeys.count == 4 else {
        check(false, "더미 자식 생성 실패: claude \(c.count)/2 · codex \(s.count)/1 · opencode \(z.count)/1 · launcher \(u.count)/1 · 분리 \(e.count)/2")
        return
    }
    // 소켓이 열릴 때까지(부하가 큰 Mac에서는 0.4초보다 늦다).
    helperWait(5) { c.allSatisfy { (ListeningSockets.list(pid: $0.pid) ?? []).count >= 2 } }

    func fake(_ root: Int32, _ kind: AgentKind, _ project: String) -> AgentSession {
        var value = session(for: tree(root), kind: kind)
        value.project = project
        return value
    }
    let fakeSessions = [fake(parent.processIdentifier, .claudeCode, "더미팀"), fake(stubbornParent.processIdentifier, .codexCLI, "더미팀"),
                        fake(systemParent.processIdentifier, .opencode, "더미팀")]
    let settings = HelperTracker.Settings(idleAfter: 2, activeCPUPercent: 0.5, grace: 0)
    let trackerA = HelperTracker(settings: settings)   // 더미 세션만 보는 추적기
    let trackerB = HelperTracker(settings: settings)   // 실제 감지기 결과를 받는 추적기(Monitor와 같은 경로)
    let detector = SessionDetector()
    records = sampler.sample()
    trackerA.observe(records: records, sessions: fakeSessions)
    var detected = detector.detect(records: records, sampler: sampler, orca: [])
    trackerB.observe(records: records, sessions: detected.sessions)
    check(detected.sessions.contains { $0.rootPID == detachedPID && $0.kind == .claudeCode }, "감지기: launchd 아래 더미 claude(pid \(detachedPID))를 Claude Code 세션으로 인식")
    check(trackerA.orphans.isEmpty && trackerA.trackedCount == 4, "세션이 살아 있는 동안: 남은 보조 프로세스 0개 · 하위 \(trackerA.trackedCount)개 기록")
    Thread.sleep(forTimeInterval: 1.0)
    records = sampler.sample()
    trackerA.observe(records: records, sessions: fakeSessions)
    detected = detector.detect(records: records, sampler: sampler, orca: [])
    trackerB.observe(records: records, sessions: detected.sessions)

    // 2) 부모만 SIGKILL → 자식은 launchd로 넘어간다.
    for key in parentKeys + [detachedKey] { killHelperDummy(key) }
    let orphanedKeys = c + s + z + u + e
    let reparented = helperWait(5) {
        records = sampler.sample()
        return orphanedKeys.allSatisfy { key in records.first { $0.key == key }?.ppid == 1 }
    }
    check(reparented, "부모만 SIGKILL → 자식 \(orphanedKeys.count)개 모두 launchd(pid 1) 아래로")
    records = sampler.sample()
    trackerA.observe(records: records, sessions: fakeSessions)   // 루트가 죽은 세션 목록을 그대로 줘도 무시해야 한다
    detected = detector.detect(records: records, sampler: sampler, orca: [])
    trackerB.observe(records: records, sessions: detected.sessions)
    let trackerC = HelperTracker(settings: settings)              // ReMON 재시작 흉내: 이력 없음
    trackerC.observe(records: records, sessions: detected.sessions)

    let orphansA = trackerA.orphans
    let membersA = Set(orphansA.flatMap(\.members))
    check(membersA == Set(c + s + z), "고아 분류: 세션 하위로 본 자식 4개만 남은 보조 프로세스(\(orphansA.count)묶음)")
    check(orphansA.allSatisfy { $0.parentPID == 1 && $0.footprint > 0 }, "남은 보조 프로세스: 부모 launchd · 메모리 \(Fmt.size(orphansA.reduce(0) { $0 + $1.footprint }))")
    let o1 = orphansA.first { $0.top == c[0] }, o2 = orphansA.first { $0.top == c[1] }, oS = orphansA.first { $0.top == s[0] }, oZ = orphansA.first { $0.top == z[0] }
    check(o1?.kind == .mcpServer && o1?.origin.sessionKey == parentKeys[0] && o1?.origin.agent == .claudeCode && o1?.origin.sessionEndedAt != nil,
          "종류·출신: MCP 서버 · 원래 세션 Claude Code(pid \(parentKeys[0].pid)) · 세션 종료 시각 기록")
    check(oZ?.kind == .other && oS?.origin.agent == .codexCLI, "패턴 없는 /bin/sleep은 '보조 프로세스', codex 쪽 출신도 구분")
    check(!membersA.contains(u[0]) && trackerA.origin(for: u[0]) == nil, "관찰 안 된 프로세스(부모 launchd · MCP 명령줄이 같아도)는 대상 아님")
    let membersB = Set(trackerB.orphans.filter { $0.origin.sessionKey == detachedKey }.flatMap(\.members))
    check(membersB == Set(e) && trackerB.orphans.allSatisfy { !$0.members.contains(u[0]) }, "실제 감지기 경로: 분리된 claude 세션의 자식 2개만 고아 · 관찰 안 된 것 제외")
    let liveOrigin = trackerB.origin(for: c[0])
    let originAlive = liveOrigin.map { origin in records.contains { $0.key == origin.sessionKey } }
    check(originAlive.map { alive in trackerB.orphans.contains { $0.members.contains(c[0]) } == !alive } == true,
          "실제 감지기: 기록한 주인 세션이 살아 있으면 보호, 끝났으면 고아(\(liveOrigin?.label ?? "출신 없음"))")
    check(trackerC.orphans.allSatisfy { Set($0.members).isDisjoint(with: orphanedKeys) }, "ReMON 재시작 뒤(이력 없음): 같은 프로세스도 대상 아님")

    // 쉬는 중: CPU 시간이 2초 넘게 늘지 않음(더미 자식은 잠만 잔다).
    Thread.sleep(forTimeInterval: 2.2)
    records = sampler.sample()
    trackerA.observe(records: records, sessions: [])
    let idleNow = trackerA.orphans.filter { Set(c).contains($0.top) }
    check(idleNow.count == 2 && idleNow.allSatisfy { $0.idle && $0.idleFor >= 2 && $0.cpuReadable }, "쉬는 중 판정: 2초 넘게 CPU 증가 없음 → idle(\(idleNow.map { String(format: "%.1f초", $0.idleFor) }.joined(separator: ", ")))")
    evidence["orphans"] = trackerA.orphans.map { ["top": Int($0.top.pid), "members": $0.members.count, "kind": $0.kind.rawValue, "footprint": $0.footprint,
                                                   "session": $0.origin.label, "idle": $0.idle, "idle_for": $0.idleFor] }

    // 3) 순수 규칙(합성 기록): 묶음 · 대표 종류 · 유예 · 쉬는 중 · 다른 세션에 다시 속함.
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let me = getuid()
    func rec(_ pid: Int32, _ ppid: Int32, _ name: String, _ path: String, cpu: UInt64 = 0) -> ProcRecord {
        ProcRecord(pid: pid, ppid: ppid, uid: me, name: name, start: Int64(pid) * 10, path: path, footprint: 10 << 20, cpuTimeNs: cpu)
    }
    let root = rec(900_001, 500, "claude", "/opt/test/claude")
    let npm = rec(900_002, 900_001, "npm", "/opt/homebrew/bin/npm")
    let node = rec(900_003, 900_002, "node", "/opt/test/node_modules/.bin/mcp-server-git")
    let busy = rec(900_004, 900_001, "worker", "/opt/test/worker")
    let quiet = rec(900_005, 900_001, "watcher", "/opt/test/watcher")
    let synthetic = AgentSession(id: root.key, kind: .claudeCode, rootPID: root.pid, pids: [root, npm, node, busy, quiet].map(\.pid), project: "합성")
    let pure = HelperTracker(settings: .init(idleAfter: 60, activeCPUPercent: 0.5, grace: 30))
    pure.observe(records: [root, npm, node, busy, quiet], sessions: [synthetic], now: base)
    func after(cpu: UInt64) -> [ProcRecord] {
        var n = npm; n.ppid = 1
        var b = busy; b.ppid = 1; b.cpuTimeNs = cpu
        var q = quiet; q.ppid = 1
        return [n, node, b, q]
    }
    pure.observe(records: after(cpu: 1_000_000_000), sessions: [synthetic], now: base.addingTimeInterval(10))
    check(pure.orphans.isEmpty, "유예 30초: 세션 종료 직후(10초)엔 목록에 올리지 않음")
    for step in 1...9 { pure.observe(records: after(cpu: UInt64(step + 1) * 1_000_000_000), sessions: [], now: base.addingTimeInterval(10 + Double(step) * 10)) }
    let grouped = pure.orphans
    let chain = grouped.first { $0.top == npm.key }
    check(chain?.members == [npm.key, node.key] && chain?.kind == .mcpServer && chain?.footprint == 20 << 20, "묶음: npm → node(mcp-server) 한 묶음 · 대표 종류 MCP 서버 · 메모리 합산")
    let busyHelper = grouped.first { $0.top == busy.key }, quietHelper = grouped.first { $0.top == quiet.key }
    check(quietHelper?.idle == true && busyHelper?.idle == false, "쉬는 중: CPU 그대로 100초 → idle · 10초마다 1초씩 쓰는 것(10%) → 아님")
    let adopter = rec(900_010, 1, "claude", "/opt/test/claude")
    var adopted = quiet; adopted.ppid = adopter.pid
    let adoptSession = AgentSession(id: adopter.key, kind: .claudeCode, rootPID: adopter.pid, pids: [adopter.pid, adopted.pid], project: "다른 방")
    var moved = after(cpu: 11_000_000_000).filter { $0.pid != quiet.pid }
    moved += [adopter, adopted]
    pure.observe(records: moved, sessions: [adoptSession], now: base.addingTimeInterval(120))
    check(!pure.orphans.contains { $0.members.contains(quiet.key) } && pure.origin(for: quiet.key)?.project == "다른 방", "다른 살아 있는 세션 아래로 다시 들어가면 고아 아님(출신도 새 세션으로)")
    // 안쪽 claude(바깥 세션에 합쳐져 하위로 보이던 것)는 바깥이 끝나면 스스로 세션 루트가 된다 → 고아가 아니라 세션.
    let outer = rec(900_020, 500, "claude", "/opt/test/claude"), inner = rec(900_021, 900_020, "claude", "/opt/test/claude"), tool = rec(900_022, 900_021, "node", "/opt/test/mcp-server-x")
    let nested = HelperTracker(settings: .init(idleAfter: 60, activeCPUPercent: 0.5, grace: 0))
    nested.observe(records: [outer, inner, tool], sessions: [AgentSession(id: outer.key, kind: .claudeCode, rootPID: outer.pid, pids: [outer.pid, inner.pid, tool.pid], project: "바깥")], now: base)
    var promoted = inner; promoted.ppid = 1
    nested.observe(records: [promoted, tool], sessions: [AgentSession(id: inner.key, kind: .claudeCode, rootPID: inner.pid, pids: [inner.pid, tool.pid], project: "안쪽")], now: base.addingTimeInterval(5))
    check(nested.orphans.isEmpty && nested.origin(for: inner.key) == nil && nested.origin(for: tool.key)?.project == "안쪽",
          "바깥 세션이 끝나 안쪽 claude가 세션 루트가 되면: 그 claude는 고아 아님(기록에서 빠짐) · 그 하위는 새 세션 소속")
    check(HelperKind.classify(name: "Google Chrome for Testing", path: "/Users/x/Library/Caches/ms-playwright/chromium-1140/chrome-mac/Chromium.app/Contents/MacOS/Chromium", argv: []) == .browser
          && HelperKind.classify(name: "node", path: "/opt/homebrew/bin/node", argv: ["node", "/x/node_modules/.bin/vite", "--port", "5173"]) == .devServer
          && HelperKind.classify(name: "java", path: "/usr/bin/java", argv: ["java", "-cp", "x", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.5"]) == .buildDaemon
          && HelperKind.classify(name: "node", path: "/opt/homebrew/bin/node", argv: ["node", "/x/typescript-language-server", "--stdio"]) == .languageServer
          && HelperKind.classify(name: "node", path: "/opt/homebrew/bin/node", argv: ["node", "/x/chrome-devtools-mcp/build/index.js"]) == .mcpServer
          && HelperKind.classify(name: "node", path: "/opt/homebrew/bin/node", argv: ["node", "invite-server.js"]) == .other,
          "종류 패턴: 브라우저 · 개발 서버 · 빌드 데몬 · 언어 서버 · MCP · 'invite'는 vite 아님")

    // 4) 리슨 포트(G3): 더미가 연 127.0.0.1 TCP·UDP를 커널 API로 찾고 lsof와 대조.
    let ours = ListeningSockets.list(pid: c[1].pid) ?? []
    let lsof = helperLsofPorts(c[1].pid)
    let oursTCP = Set(ours.filter { $0.proto == .tcp }.map(\.port)), oursUDP = Set(ours.filter { $0.proto == .udp }.map(\.port))
    check(!oursTCP.isEmpty && !oursUDP.isEmpty && ours.allSatisfy { $0.isLoopback && $0.address == "127.0.0.1" }, "리슨 포트: 더미의 TCP \(oursTCP.sorted()) · UDP \(oursUDP.sorted()) · 모두 127.0.0.1(이 Mac에서만)")
    check(oursTCP == lsof.tcp && oursUDP == lsof.udp, "lsof 대조: TCP \(lsof.tcp.sorted()) · UDP \(lsof.udp.sorted()) 일치")
    let wildcard = ListeningSocket(proto: .tcp, address: "0.0.0.0", port: 3000, isIPv6: false), lan = ListeningSocket(proto: .tcp, address: "192.168.0.7", port: 8080, isIPv6: false)
    check(!wildcard.isLoopback && wildcard.display == "*:3000" && !lan.isLoopback && ListeningSocket(proto: .udp, address: "::1", port: 53, isIPv6: true).isLoopback,
          "외부 인터페이스 판정: 0.0.0.0 · 192.168.x는 외부, ::1은 이 Mac만")
    evidence["sockets"] = ["ours_tcp": oursTCP.sorted().map(Int.init), "ours_udp": oursUDP.sorted().map(Int.init), "lsof_tcp": lsof.tcp.sorted().map(Int.init), "lsof_udp": lsof.udp.sorted().map(Int.init)]

    // 5) '왜 실행 중?'(G3): 남은 보조 프로세스 · 이 검사 자신 · 경고 6종.
    let why = ProcessExplainer.explain(pid: c[1].pid, origin: trackerA.origin(for: c[1]))
    check(why.exists && why.chain.map(\.pid) == [c[1].pid, 1] && why.helperKind == .mcpServer && why.origin?.sessionKey == parentKeys[0],
          "왜 실행 중(고아 MCP): 계보 pid \(c[1].pid) → launchd · 종류 MCP · 원래 세션 Claude Code(ReMON이 본 기록)")
    check(Set((why.sockets ?? []).map(\.port)) == oursTCP.union(oursUDP) && !why.warnings.contains { $0.kind == .publicListener }, "왜 실행 중: 리슨 포트 같음 · 외부 리슨 경고 없음")
    var assertion: IOPMAssertionID = 0
    let created = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "ReMON 검사" as CFString, &assertion)
    let selfWhy = ProcessExplainer.explain(pid: getpid(), sessions: detected.sessions)
    if created == kIOReturnSuccess { IOPMAssertionRelease(assertion) }
    let hops = selfWhy.chain.map { "\($0.name)(\($0.pid))" + ($0.roleLabel.map { "[\($0)]" } ?? "") + ($0.note.map { "{\($0)}" } ?? "") }
    print("  계보: " + hops.joined(separator: " → "))
    check(selfWhy.chain.last?.pid == 1 && selfWhy.chain.contains { if case .agent = $0.role { return true }; return false }, "왜 실행 중(이 검사): launchd까지 \(selfWhy.chain.count)홉 · 에이전트 홉 표시")
    check(detected.sessions.contains { session in selfWhy.chain.contains { $0.pid == session.rootPID && $0.note?.contains(session.kind.label + " 세션") == true } },
          "에이전트 홉에 세션 정보(Claude·Codex 등 실제 감지기 결과) 붙음")
    check(selfWhy.git != nil, "작업 폴더·git: \(selfWhy.cwd ?? "-") · \(selfWhy.git.map { ($0.isWorktree ? "워크트리 " : "") + ($0.branch ?? $0.head ?? "?") } ?? "없음")")
    check(selfWhy.assertions.contains { $0.name == "ReMON 검사" } && selfWhy.warnings.contains { $0.kind == .preventsSleep }, "잠자기 방지 assertion 읽음(IOPMCopyAssertionsByProcess) · 경고")
    if let launchdHop = selfWhy.launchd { print("  launchd: \(launchdHop.label) · \(launchdHop.matchedBy)") }

    // 경고: 좀비 · 정지 · 실행 파일 삭제 · 실행 중 교체 · DYLD_* · 90일 초과(순수).
    let zombieParent = spawnHelper("zombie-parent", ["--children", "1"])
    let deleted = spawnHelper("deleted-dummy", ["--children", "0"])
    let replaced = spawnHelper("replaced-dummy", ["--children", "0"])
    let dyld = spawnHelper("dyld-dummy", ["--children", "0"], environment: ["DYLD_FALLBACK_LIBRARY_PATH": helperRoot + "/no-such-lib-dir"])
    records = sampler.sample()
    let extra = [zombieParent, deleted, replaced, dyld].compactMap { key($0.processIdentifier) }
    spawned += extra
    let zombieChild = childProcesses(of: zombieParent.processIdentifier, in: records).first?.key
    if let zombieChild { spawned.append(zombieChild); kill(zombieChild.pid, SIGKILL) }
    helperWait(3) { zombieChild.map { helperProcStat($0.pid) == 5 } ?? false }
    kill(zombieParent.processIdentifier, SIGSTOP)
    helperWait(3) { helperProcStat(zombieParent.processIdentifier) == 4 }
    try? fm.removeItem(atPath: helperBin + "/deleted-dummy")
    try? fm.removeItem(atPath: helperBin + "/replaced-dummy")
    try? fm.copyItem(atPath: dummyBinary(), toPath: helperBin + "/replaced-dummy")
    let zombieWhy = zombieChild.map { ProcessExplainer.explain(pid: $0.pid) }
    let stoppedWhy = ProcessExplainer.explain(pid: zombieParent.processIdentifier)
    let deletedWhy = ProcessExplainer.explain(pid: deleted.processIdentifier)
    let replacedWhy = ProcessExplainer.explain(pid: replaced.processIdentifier)
    let dyldWhy = ProcessExplainer.explain(pid: dyld.processIdentifier)
    kill(zombieParent.processIdentifier, SIGCONT)
    func has(_ explanation: ProcessExplanation?, _ kind: ProcessExplanation.Warning.Kind) -> Bool { explanation?.warnings.contains { $0.kind == kind } == true }
    check(has(zombieWhy, .zombie) && zombieWhy?.status == "좀비", "경고: 좀비(부모가 회수 안 함)")
    check(has(stoppedWhy, .stopped) && stoppedWhy.status == "정지", "경고: 정지(SIGSTOP)")
    check(has(deletedWhy, .executableDeleted), "경고: 실행 파일 삭제됨")
    check(has(replacedWhy, .executableReplaced) && !has(replacedWhy, .executableDeleted), "경고: 실행 중에 실행 파일이 바뀜(inode 비교)")
    check(has(dyldWhy, .dyld) && dyldWhy.warnings.first { $0.kind == .dyld }?.text.contains("DYLD_FALLBACK_LIBRARY_PATH") == true, "경고: DYLD_* 환경 변수")
    check(ProcessExplainer.ageWarning(start: Date().addingTimeInterval(-91 * 86_400)) != nil && ProcessExplainer.ageWarning(start: Date().addingTimeInterval(-89 * 86_400)) == nil,
          "경고: 90일 초과 실행(91일 → 경고, 89일 → 없음)")
    // launchd 라벨: 실제로 도는 내 LaunchAgent 하나(읽기 전용).
    let items = StartupItemScanner().scan(withState: false)
    let listed = StartupItemScanner.parseList(Shell.capture("/bin/launchctl", ["list"]).stdout)
    if let agent = items.first(where: { $0.domain == .userAgent && listed[$0.label]?.pid != nil }), let pid = listed[agent.label]?.pid {
        let agentWhy = ProcessExplainer.explain(pid: pid)
        check(agentWhy.launchd?.label == agent.label && agentWhy.launchd?.plistPath == agent.plistPath, "launchd 라벨: pid \(pid) → \(agent.label) (\(agentWhy.launchd?.matchedBy ?? "-"))")
    } else {
        print("SKIP launchd 라벨: 지금 도는 내 LaunchAgent가 없음")
    }

    // 6) 종료(G2): 보호 → 드라이런 → 신원 가드 → SIGTERM → 고집 센 것 SIGKILL → 시스템 경로 차단. 금고에는 기록만.
    let terminator = HelperTerminator(registry: TerminationRegistry())
    terminator.audit = audit
    terminator.waitSeconds = 1.5
    guard let o1, let o2, let oS, let oZ else { check(false, "고아 묶음을 찾지 못함"); return }
    let plan1 = terminator.plan(o1, records: records)
    check(plan1.blockers.isEmpty && plan1.identities.count == 1, "계획: 보호 규칙 통과(같은 사용자 · 검사 폴더 실행 파일)")
    check(plan1.warnings.contains { $0.contains("로컬 포트") } && !plan1.warnings.contains { $0.contains("외부 인터페이스") }, "경고: 로컬 포트를 연 보조 프로세스(브라우저가 쓰는 중일 수 있음)")
    let identity = plan1.identities[0]
    check(HelperGuard.matches(identity), "신원 확인: pid · 시작 시각 · 실행 경로가 같으면 통과")
    check(!HelperGuard.matches(.init(key: ProcessKey(pid: identity.key.pid, start: identity.key.start + 1_000_000), path: identity.path)), "pid 재사용(시작 시각 다름) → 거부")
    check(!HelperGuard.matches(.init(key: identity.key, path: identity.path + ".swapped")), "실행 경로 다름 → 거부")

    let plan2 = terminator.plan(o2, records: records)
    let dry = terminator.execute(plan2, dryRun: true, vault: vault) { _ in true }
    check(dry.dryRun && SessionTerminator.isAlive(c[1]), "드라이런: 실제로 종료하지 않음")
    let recorder = SignalRecorder()
    let guarded = HelperTerminator(registry: TerminationRegistry())
    guarded.audit = audit
    guarded.waitSeconds = 0.5
    guarded.signalSender = { recorder.record($0, $1) }
    var swapped = plan2
    swapped.identities = plan2.identities.map { .init(key: $0.key, path: $0.path + ".swapped") }
    let swappedOutcome = guarded.execute(swapped, dryRun: false, vault: vault) { _ in true }
    check(recorder.calls.isEmpty && swappedOutcome.refused == [c[1]] && SessionTerminator.isAlive(c[1]) && swappedOutcome.entry == nil,
          "신호 직전 가드: 경로가 바뀐 pid엔 SIGTERM·SIGKILL 모두 보내지 않음(신호 0건 · 살아 있음 · 금고 기록 없음)")
    var reused = plan2
    let forged = ProcessKey(pid: c[1].pid, start: c[1].start + 1_000_000)
    reused.identities = [.init(key: forged, path: plan2.identities[0].path)]
    reused.base.targets = [forged]
    reused.helper.top = forged
    reused.helper.members = [forged]
    let reusedOutcome = guarded.execute(reused, dryRun: false, vault: vault) { _ in true }
    check(recorder.calls.isEmpty && reusedOutcome.terminated.isEmpty && reusedOutcome.alreadyGone == [forged] && reusedOutcome.reclaimed == 0 && SessionTerminator.isAlive(c[1]),
          "pid 재사용 흉내(같은 pid · 다른 시작 시각): 신호 0건 · 진짜 프로세스는 살아 있음 · 회수량 0")

    let real = terminator.execute(plan1, dryRun: false, vault: vault) { _ in false }
    check(real.terminated == [c[0]] && !SessionTerminator.isAlive(c[0]) && !real.killedRemaining && real.reclaimed > 0,
          "SIGTERM 종료: \(real.message)")
    let entry = vault.all().first { $0.pid == c[0].pid && $0.processStart == c[0].start }
    // 프로세스 복구(10-25): 기록만 남기던 것(.deleted · .gone)에서, 끝내기 전에 다시 띄울 명령을 적는 보관 항목으로 바뀌었다.
    check(entry?.kind == .process && entry?.status == .held && entry?.restorable == true && entry?.resumeArgs?.isEmpty == false && entry?.exitReason == "SIGTERM으로 종료"
          && entry?.agent == AgentKind.claudeCode.rawValue && entry?.origin == "Claude Code · 더미팀",
          "금고: 다시 띄울 기록(.process · 보관 중 · 명령 \(entry?.resumeArgs?.count ?? 0)칸 · SIGTERM으로 종료 · 출신 \(entry?.origin ?? "-"))")
    let planS = terminator.plan(oS, records: records)
    let asked = HelperKeyBox()
    let started = Date()
    let stubborn = terminator.execute(planS, dryRun: false, vault: vault) { remaining in asked.set(remaining); return true }
    check(asked.value == [s[0]] && stubborn.killedRemaining && !SessionTerminator.isAlive(s[0]) && Date().timeIntervalSince(started) >= 1.4,
          String(format: "SIGTERM 무시 → %.1f초 뒤 남은 것 확인 → SIGKILL로 종료", Date().timeIntervalSince(started)))
    let planZ = terminator.plan(oZ, records: records)
    let blocked = terminator.execute(planZ, dryRun: false, vault: vault) { _ in true }
    check(planZ.blockers.contains { $0.contains("시스템 경로") } && blocked.blocked && SessionTerminator.isAlive(z[0]), "시스템 경로 실행 파일(/bin/sleep)은 차단 · 살아 있음")
    let cleanupTerminator = HelperTerminator(registry: TerminationRegistry())
    cleanupTerminator.audit = audit
    var leftover = 0
    for helper in [o2] + trackerB.orphans.filter({ $0.origin.sessionKey == detachedKey }) {
        let outcome = cleanupTerminator.execute(cleanupTerminator.plan(helper, records: records), dryRun: false, vault: vault) { _ in false }
        leftover += outcome.remaining.count
    }
    check(leftover == 0 && !SessionTerminator.isAlive(c[1]) && e.allSatisfy { !SessionTerminator.isAlive($0) }, "나머지 남은 보조 프로세스 3개(감지기 경로 포함)도 같은 흐름으로 종료")
    let auditText = (try? String(contentsOfFile: helperRoot + "/actions.jsonl", encoding: .utf8)) ?? ""
    check(auditText.components(separatedBy: "\"helper.terminate\"").count - 1 >= 7, "감사 기록: helper.terminate \(auditText.components(separatedBy: "\"helper.terminate\"").count - 1)줄(시험 전용 파일)")

    // 7) 비용: Monitor 훅(observe)을 실제 프로세스·세션으로 20번.
    records = sampler.sample()
    detected = detector.detect(records: records, sampler: sampler, orca: [])
    let costTracker = HelperTracker()
    let costStart = Date()
    for _ in 0..<20 { costTracker.observe(records: records, sessions: detected.sessions) }
    let perCall = Date().timeIntervalSince(costStart) / 20
    check(perCall < 0.005, String(format: "Monitor 훅 비용: observe %.2fms/회 (프로세스 %d · 세션 %d · 기록 %d)", perCall * 1000, records.count, detected.sessions.count, costTracker.trackedCount))

    // 8) 지금 Mac(읽기 전용): 새 추적기는 이력이 없어 대상 0개가 정상이다. 이름 패턴만으로 고르면 몇 개가 걸리는지 참고로 센다.
    let fresh = HelperTracker()
    fresh.observe(records: records, sessions: detected.sessions)
    let namesOnly = records.filter { $0.ppid == 1 && $0.uid == me && !spawned.contains($0.key) }.compactMap { record -> (String, HelperKind)? in
        let kind = HelperKind.classify(name: record.name, path: record.path, argv: sampler.arguments(for: record.key)?.argv ?? [])
        return kind == .other ? nil : (record.displayName, kind)
    }
    print("  지금 Mac: 남은 보조 프로세스(증거 있음) \(fresh.orphans.count)개 · 참고: 이름 패턴만으로는 launchd 아래 \(namesOnly.count)개(\(namesOnly.prefix(6).map { "\($0.0)=\($0.1.label)" }.joined(separator: ", "))) — 이력이 없어 대상 아님")
    check(fresh.orphans.isEmpty, "지금 Mac: 새 추적기(이력 없음) 대상 \(fresh.orphans.count)개 — 이름만으로 고른 \(namesOnly.count)개는 제외")
    evidence["live"] = ["orphans_with_evidence": fresh.orphans.count, "names_only_candidates": namesOnly.count, "observe_ms": perCall * 1000, "sessions": detected.sessions.count]
    writeEvidence("helpers-checks.json", evidence)
    try? fm.removeItem(atPath: helperBin + "/replaced-dummy")
}

// MARK: - G4

/// 가짜 launchctl: 명령을 기록하고 미리 정한 print 결과를 돌려준다(실제 launchd는 건드리지 않는다).
private final class FakeLaunchctl: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[String]] = []
    var prints: [String: String] = [:]
    var bootoutStatus: Int32 = 0
    var bootstrapStatus: Int32 = 0
    var onBootout: (@Sendable () -> Void)?

    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return _calls }
    func reset() { lock.lock(); _calls = []; lock.unlock() }

    func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> CommandResult {
        lock.lock()
        _calls.append(arguments)
        let prints = self.prints
        lock.unlock()
        switch arguments.first {
        case "print":
            let label = String(arguments[1].split(separator: "/").last ?? "")
            if let text = prints[label] { return CommandResult(status: 0, stdout: text) }
            return CommandResult(status: 113, stderr: "Bad request.\nCould not find service \"\(label)\" in domain for user gui: 501")
        case "bootout":
            onBootout?()
            if bootoutStatus == 0 {
                let label = String(arguments[1].split(separator: "/").last ?? "")
                lock.lock(); self.prints[label] = nil; lock.unlock()
                return CommandResult(status: 0)
            }
            return CommandResult(status: bootoutStatus, stderr: "Boot-out failed: \(bootoutStatus): Input/output error")
        case "bootstrap":
            return CommandResult(status: bootstrapStatus, stderr: bootstrapStatus == 0 ? "" : "Bootstrap failed: 5: Input/output error")
        default:
            return CommandResult(status: 0)
        }
    }
}

func startupCheck() {
    let fm = FileManager.default
    let root = "/private/tmp/remon-startup-check"   // 공유 checkRoot 밖(다른 검사가 지워도 영향 없음)
    try? fm.removeItem(atPath: root)
    let userFolder = root + "/user/LaunchAgents", globalFolder = root + "/global/LaunchAgents", daemonFolder = root + "/daemons"
    for folder in [userFolder, globalFolder, daemonFolder] { try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true) }
    let audit = AuditLog(url: URL(fileURLWithPath: root + "/actions.jsonl"))
    let vault = RecoveryVault(folder: URL(fileURLWithPath: root + "/vault"))
    vault.audit = audit
    var trashedLeftovers: [String] = []
    defer {
        for path in trashedLeftovers where fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) } // 시험용 plist만
        try? fm.removeItem(atPath: root)
    }
    // 픽스처가 가리킬 '있는 실행 파일'(실행하지는 않는다).
    let program = root + "/startup-program"
    try? fm.copyItem(atPath: dummyBinary(), toPath: program)
    func write(_ folder: String, _ name: String, _ plist: [String: Any], binary: Bool = false) {
        let data = try! PropertyListSerialization.data(fromPropertyList: plist, format: binary ? .binary : .xml, options: 0)
        fm.createFile(atPath: folder + "/" + name, contents: data)
    }
    write(userFolder, "check.fixture.ok.plist", ["Label": "check.fixture.ok", "ProgramArguments": [program, "--lifetime", "1"], "RunAtLoad": true])
    write(userFolder, "check.fixture.missing.plist", ["Label": "check.fixture.missing", "Program": root + "/no-such-binary", "RunAtLoad": true])
    write(userFolder, "check.fixture.crash.plist", ["Label": "check.fixture.crash", "ProgramArguments": [program], "KeepAlive": true])
    write(userFolder, "check.fixture.script.plist", ["Label": "check.fixture.script", "ProgramArguments": ["/bin/zsh", "-li", root + "/no-such-run.sh"], "KeepAlive": true, "RunAtLoad": true])
    write(userFolder, "check.fixture.once.plist", ["Label": "check.fixture.once", "ProgramArguments": [program], "KeepAlive": true])
    write(userFolder, "check.fixture.cond.plist",["Label": "check.fixture.cond", "ProgramArguments": ["sleep", "5"], "KeepAlive": ["SuccessfulExit": false]], binary: true)
    write(userFolder, "com.apple.fixture.plist", ["Label": "com.apple.fixture", "ProgramArguments": [program]])
    write(userFolder, "io.tailscale.fixture.plist", ["Label": "io.tailscale.fixture", "ProgramArguments": [program]])
    write(userFolder, "com.dreamsecurity.fixture.plist", ["Label": "com.dreamsecurity.fixture", "ProgramArguments": [program]])
    write(userFolder, "com.example.reset-helper.plist", ["Label": "com.example.reset-helper", "ProgramArguments": [program]])
    write(userFolder, "nolabel.plist", ["ProgramArguments": [program]])
    fm.createFile(atPath: userFolder + "/broken.plist", contents: Data("이건 plist가 아닙니다".utf8))
    write(globalFolder, "check.fixture.global.plist", ["Label": "check.fixture.global", "ProgramArguments": [program], "RunAtLoad": true])
    write(daemonFolder, "check.fixture.daemon.plist", ["Label": "check.fixture.daemon", "ProgramArguments": [program], "KeepAlive": true])

    let fake = FakeLaunchctl()
    fake.prints = [
        "check.fixture.ok": "gui/501/check.fixture.ok = {\n\tactive count = 0\n\tstate = not running\n\tprogram = \(program)\n\truns = 3\n\tlast exit code = 0\n}\n",
        "check.fixture.crash": "gui/501/check.fixture.crash = {\n\tstate = running\n\tprogram = \(program)\n\truns = 50987\n\tpid = 123\n\tlast exit code = 127\n\n\tresource coalition = {\n\t\tstate = active\n\t}\n}\n",
        "check.fixture.script": "gui/501/check.fixture.script = {\n\tstate = not running\n\truns = 12\n\tlast exit code = 127\n}\n",
        "check.fixture.once": "gui/501/check.fixture.once = {\n\tstate = spawn scheduled\n\truns = 1\n\tlast exit code = 78: EX_CONFIG\n}\n",
        "check.fixture.daemon": "system/check.fixture.daemon = {\n\tstate = running\n\tpid = 77\n\tlast exit code = (never exited)\n}\n"
    ]
    let uid = getuid()
    let scanner = StartupItemScanner(folders: [.init(.userAgent, userFolder), .init(.globalAgent, globalFolder), .init(.systemDaemon, daemonFolder)], uid: uid, run: fake.run)
    let items = scanner.scan()
    func item(_ label: String) -> StartupItem? { items.first { $0.label == label } }
    check(items.count == 14 && items.filter { $0.domain == .userAgent }.count == 12, "픽스처 plist \(items.count)개 읽음(내 12 · 전체 1 · 시스템 1)")
    let once = item("check.fixture.once")
    check(once?.lastRunFailed == true && once?.crashLoop == false && once?.state?.lastExitCode == 78 && once?.flagged == false,
          "한 번 실패하고 대기(runs 1 · 78 EX_CONFIG)는 반복 크래시가 아니라 '마지막 실행 실패'")
    let ok = item("check.fixture.ok"), missing = item("check.fixture.missing"), crash = item("check.fixture.crash")
    let script = item("check.fixture.script"), cond = item("check.fixture.cond"), daemon = item("check.fixture.daemon")
    check(ok?.runAtLoad == true && ok?.missingProgram == nil && ok?.crashLoop == false && ok?.state?.runs == 3 && ok?.state?.lastExitCode == 0 && ok?.canDisable == true,
          "정상 항목: RunAtLoad · 실행 파일 있음 · 실행 3회 · 마지막 종료 0 · 끌 수 있음")
    check(missing?.missingProgram == root + "/no-such-binary" && missing?.flagged == true, "실행 파일 없음 강조")
    check(crash?.crashLoop == true && crash?.state?.runs == 50987 && crash?.state?.pid == 123 && crash?.state?.running == true && crash?.state?.lastExitCode == 127,
          "반복 크래시: KeepAlive + 마지막 종료 127 · 50,987회 · 안쪽 블록의 state는 무시")
    check(script?.missingProgram == root + "/no-such-run.sh" && script?.crashLoop == true, "인터프리터가 실행할 스크립트가 없음(zsh -li <없는 run.sh>) + 반복 크래시")
    check(cond?.keepAlive == .conditional && cond?.resolvedProgram == "/bin/sleep" && cond?.missingProgram == nil, "바이너리 plist · 조건부 KeepAlive · 슬래시 없는 'sleep'은 기본 PATH에서 /bin/sleep")
    check(item("com.apple.fixture")?.protection?.contains("Apple") == true && item("io.tailscale.fixture")?.protection?.contains("VPN") == true
          && item("com.dreamsecurity.fixture")?.protection?.contains("국내") == true, "보호: Apple · VPN(tailscale) · 국내 보안 모듈(dreamsecurity)")
    check(item("com.example.reset-helper")?.protection == nil, "오탐 없음: 'reset'에 'eset'이 들어 있어도 보호 아님")
    let broken = items.first { $0.plistPath.hasSuffix("/broken.plist") }, nolabel = items.first { $0.plistPath.hasSuffix("/nolabel.plist") }
    check(broken?.readable == false && broken?.parseError != nil && nolabel?.hasLabel == false && nolabel?.canDisable == false, "깨진 plist·Label 없는 plist도 멈추지 않고 표시(끌 수 없음)")
    check(item("check.fixture.global")?.canDisable == false && daemon?.canDisable == false && daemon?.state?.lastExitCode == nil && daemon?.state?.lastExit == "(never exited)",
          "시스템 영역(전체 에이전트·데몬)은 보여 주기만 · 'never exited' 해석")
    let list = StartupItemScanner.parseList("PID\tStatus\tLabel\n943\t0\tcom.example.a\n-\t127\tcom.example.b\n-\t-9\tcom.example.c\n")
    check(list["com.example.a"]?.pid == 943 && list["com.example.b"]?.status == 127 && list["com.example.b"]?.pid == nil && list["com.example.c"]?.status == -9, "launchctl list 해석(PID · 종료 상태 · 신호)")

    // 끄기·다시 켜기(가짜 launchctl · 임시 폴더 plist).
    let manager = StartupItemManager(uid: uid, userAgentsFolder: userFolder, run: fake.run, audit: audit)
    fake.reset()
    let dry = manager.disable(ok!, vault: vault, dryRun: true)
    check(dry.ok && fm.fileExists(atPath: ok!.plistPath) && !fake.calls.contains { $0.first == "bootout" }, "드라이런: 끄지 않고 파일 그대로")
    fake.reset()
    let protected = manager.disable(item("io.tailscale.fixture")!, vault: vault, dryRun: false)
    let systemRefused = manager.disable(daemon!, vault: vault, dryRun: false)
    let outside = manager.disable(StartupItemScanner.parse(path: globalFolder + "/check.fixture.global.plist", domain: .userAgent), vault: vault, dryRun: false)
    check(!protected.ok && !systemRefused.ok && !outside.ok && fake.calls.isEmpty, "거부: 보호 항목 · 시스템 데몬 · 내 LaunchAgents 밖 plist — launchctl 호출 0건")
    fake.bootoutStatus = 5
    let bootoutFailed = manager.disable(crash!, vault: vault, dryRun: false)
    check(!bootoutFailed.ok && fm.fileExists(atPath: crash!.plistPath), "bootout 실패(5) → 파일을 옮기지 않음")
    fake.bootoutStatus = 0
    fake.reset()
    let scriptPath = script!.plistPath
    fake.onBootout = { try? FileManager.default.removeItem(atPath: scriptPath) }   // bootout 직후 plist가 사라짐 → 휴지통 이동 실패
    let rolledBack = manager.disable(script!, vault: vault, dryRun: false)
    fake.onBootout = nil
    check(!rolledBack.ok && rolledBack.message.contains("다시 켜 두었습니다") && fake.calls.contains { $0 == ["bootstrap", "gui/\(uid)", scriptPath] }, "휴지통 이동 실패 → bootstrap으로 원래대로")
    fake.reset()
    fake.prints["check.fixture.ok"] = "gui/501/check.fixture.ok = {\n\tstate = running\n\tpid = 4242\n\truns = 4\n}\n"
    let disabled = manager.disable(ok!, vault: vault, dryRun: false)
    let vaultEntry = vault.all().first { $0.originalPath == ok!.plistPath }
    if let trashed = vaultEntry?.trashedPath { trashedLeftovers.append(trashed) }
    check(disabled.ok && !fm.fileExists(atPath: ok!.plistPath) && fake.calls.contains { $0 == ["bootout", "gui/\(uid)/check.fixture.ok"] }, "끄기: launchctl bootout gui/\(uid)/check.fixture.ok → \(disabled.message)")
    check(vaultEntry?.kind == .trash && vaultEntry?.status == .held && StartupItemManager.isStartupEntry(vaultEntry!) && vaultEntry?.title == "check.fixture.ok"
          && vaultEntry?.restoreHint?.hasPrefix("launchctl bootstrap gui/\(uid) ") == true && vaultEntry.flatMap { $0.trashedPath.map(fm.fileExists) } == true,
          "금고: 휴지통 위치 · 라벨 · 다시 켜는 명령 기록")
    fake.reset()
    let restored = manager.restore(vaultEntry!, vault: vault)
    check(restored.ok && fm.fileExists(atPath: ok!.plistPath) && fake.calls.contains { $0 == ["bootstrap", "gui/\(uid)", ok!.plistPath] } && vault.entry(vaultEntry!.id)?.status == .restored,
          "다시 켜기: 휴지통 → 원래 자리 + launchctl bootstrap gui/\(uid) <plist> → \(restored.message)")

    // 실제 launchctl(부작용 없는 호출만): 없는 라벨 print · bootout, 없는 파일 bootstrap — 명령 형식이 받아들여지는지.
    let real = StartupItemScanner(folders: [], uid: uid)
    let nonexistent = "local.remon.check.nonexistent-\(getpid())"
    check(real.state(label: nonexistent, domain: .userAgent) == .notLoaded, "실제 launchctl print: 없는 라벨 → 로드 안 됨(113)")
    let bootout = Shell.capture("/bin/launchctl", ["bootout", "gui/\(uid)/\(nonexistent)"])
    let bootstrap = Shell.capture("/bin/launchctl", ["bootstrap", "gui/\(uid)", root + "/no-such.plist"])
    check(bootout.status == 3 && !(bootout.stderr + bootstrap.stderr).contains("Usage") && bootstrap.status != 0,
          "실제 launchctl bootout/bootstrap 형식: 없는 대상 → 3(No such process) · \(bootstrap.status), 사용법 오류 없음")

    // 실제 폴더(읽기 전용 스모크): 세 폴더 + launchctl print.
    let started = Date()
    let live = StartupItemScanner().scan()
    let elapsed = Date().timeIntervalSince(started)
    let flagged = live.filter(\.flagged)
    print(String(format: "  지금 Mac: 시작 항목 %d개(내 %d · 전체 %d · 시스템 %d) · 확인 필요 %d(실행 파일 없음 %d · 반복 크래시 %d) · 보호 %d · %.2f초",
                 live.count, live.filter { $0.domain == .userAgent }.count, live.filter { $0.domain == .globalAgent }.count, live.filter { $0.domain == .systemDaemon }.count,
                 flagged.count, live.filter { $0.missingProgram != nil }.count, live.filter(\.crashLoop).count, live.filter { $0.protection != nil }.count, elapsed))
    for item in flagged {
        print("    ! \(item.label) [\(item.domain.label)] " + (item.crashLoop ? "반복 크래시(종료 \(item.state?.lastExit ?? "?") · \(item.state?.runs.map(String.init) ?? "?")회) " : "") + (item.missingProgram.map { "없음: \($0)" } ?? ""))
    }
    check(!live.isEmpty && live.allSatisfy { !$0.plistPath.isEmpty }, "실제 LaunchAgents·LaunchDaemons 읽기(읽기 전용) \(live.count)개")
    let listedLive = StartupItemScanner.parseList(Shell.capture("/bin/launchctl", ["list"]).stdout)
    let comparable = live.filter { $0.domain != .systemDaemon && $0.state?.loaded == true && $0.state?.lastExitCode != nil && listedLive[$0.label] != nil }
    check(comparable.allSatisfy { listedLive[$0.label]?.status == $0.state?.lastExitCode }, "launchctl list 종료 상태와 print 마지막 종료 코드 일치(\(comparable.count)개 대조)")
    writeEvidence("startup-checks.json", ["live_total": live.count, "live_flagged": flagged.map(\.label), "crash_loops": live.filter(\.crashLoop).map(\.label),
                                          "missing": live.compactMap { item in item.missingProgram.map { "\(item.label): \($0)" } }, "protected": live.filter { $0.protection != nil }.count,
                                          "scan_seconds": elapsed])
}
