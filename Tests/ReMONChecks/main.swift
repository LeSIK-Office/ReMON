import Foundation
import ReMONCore

// 실행형 자체 검사. XCTest·swift-testing의 Command Line Tools 경로 함정을 피하려고 실행 파일로 둔다.
// 사용: swift run ReMONChecks <검사 이름> [--evidence <폴더>]

var failures = 0
func check(_ condition: Bool, _ message: String) {
    print((condition ? "PASS " : "FAIL ") + message)
    if !condition { failures += 1 }
}

func within(_ ours: Double, _ reference: Double, tolerance: Double = 0.05) -> Bool {
    if reference == 0 { return ours == 0 }
    return abs(ours - reference) / reference <= tolerance
}

func writeEvidence(_ name: String, _ object: Any) {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--evidence"), index + 1 < arguments.count else { return }
    let folder = URL(fileURLWithPath: arguments[index + 1])
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: folder.appendingPathComponent(name))
        print("evidence: \(folder.appendingPathComponent(name).path)")
    }
}

/// 같은 순간의 수치를 /usr/bin/top · sysctl vm.swapusage · df와 대조한다(사양 11-1, ±5%).
func metricsCheck() {
    let sampler = SystemSampler()
    _ = sampler.cpuUsage()
    let before = sampler.sample()
    let top = TopReader.run()
    let swapText = Shell.run("/usr/sbin/sysctl", ["-n", "vm.swapusage"]) ?? ""
    let dfText = Shell.run("/bin/df", ["-k", "/"]) ?? ""
    let after = sampler.sample()

    // vm.swapusage: "total = 29696.00M  used = 27962.69M  free = 1733.31M  (encrypted)"
    func swapField(_ name: String) -> Double? {
        guard let range = swapText.range(of: name + " = ") else { return nil }
        let token = swapText[range.upperBound...].split(whereSeparator: { $0 == " " }).first.map(String.init) ?? ""
        // .map(Double.init)은 UInt64에서 Double(bitPattern:)으로 해석돼 값이 깨진다 — 명시적으로 변환.
        return TopReader.parseSize(token).map { Double($0) }
    }
    let dfFields = dfText.split(separator: "\n").last?.split(separator: " ", omittingEmptySubsequences: true) ?? []
    let dfAvailable = dfFields.count > 3 ? (Double(dfFields[3]) ?? 0) * 1024 : 0

    let oursSwap = Double(before.swap.used + after.swap.used) / 2
    let oursDisk = Double(before.disk.available + after.disk.available) / 2
    let oursUsed = Double(before.memory.topUsed + after.memory.topUsed) / 2
    let oursWired = Double(before.memory.wired + after.memory.wired) / 2
    let oursCompressed = Double(before.memory.compressed + after.memory.compressed) / 2

    var record: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date())]
    if let phys = top?.physMem {
        record["top_physmem"] = ["used": phys.used, "wired": phys.wired, "compressor": phys.compressor, "unused": phys.unused]
        record["ours_memory"] = ["used_total_minus_free": oursUsed, "wired": oursWired, "compressed": oursCompressed,
                                 "activity_monitor_used": Double(after.memory.used), "app": Double(after.memory.appMemory), "cached_files": Double(after.memory.cachedFiles)]
        check(within(oursUsed, Double(phys.used)), "메모리 used(전체-free) \(Fmt.gb(UInt64(oursUsed))) vs top \(Fmt.gb(phys.used))")
        check(within(oursWired, Double(phys.wired), tolerance: 0.05), "wired \(Fmt.gb(UInt64(oursWired))) vs top \(Fmt.gb(phys.wired))")
        check(within(oursCompressed, Double(phys.compressor), tolerance: 0.05), "압축 \(Fmt.gb(UInt64(oursCompressed))) vs top \(Fmt.gb(phys.compressor))")
    } else {
        check(false, "top PhysMem 줄을 읽지 못함")
    }
    if let used = swapField("used") {
        record["swap"] = ["ours": oursSwap, "sysctl": used]
        check(within(oursSwap, used), "스왑 사용 \(Fmt.gb(UInt64(oursSwap))) vs vm.swapusage \(Fmt.gb(UInt64(used)))")
    } else {
        check(false, "vm.swapusage를 읽지 못함")
    }
    record["disk"] = ["ours_available": oursDisk, "df_available": dfAvailable, "important_usage": Double(after.disk.availableForImportantUsage), "vm_volume_used": Double(after.disk.swapVolumeUsed)]
    check(within(oursDisk, dfAvailable), "디스크 여유 \(Fmt.gb(UInt64(oursDisk))) vs df \(Fmt.gb(UInt64(dfAvailable)))")
    record["pressure"] = after.pressure.label
    record["cpu_percent"] = after.cpuPercent
    writeEvidence("metrics-vs-top-df.json", record)
}

/// top 보충값이 실제로 root 프로세스(WindowServer)를 채우는지.
func processCheck() {
    let sampler = ProcessSampler()
    let first = sampler.sample()
    let top = TopReader.run()
    sampler.updateTopFallback(top?.memoryByPID ?? [:])
    Thread.sleep(forTimeInterval: 1.0)
    let records = sampler.sample()
    let kernel = records.filter { $0.memorySource == .kernel }.count
    let topFilled = records.filter { $0.memorySource == .top }.count
    let missing = records.filter { $0.memorySource == .unavailable }.count
    print("processes \(records.count) (first pass \(first.count)) kernel=\(kernel) top=\(topFilled) unavailable=\(missing)")
    check(records.count > 100, "프로세스 목록 \(records.count)개")
    let windowServer = records.first { $0.name == "WindowServer" }
    check((windowServer?.footprint ?? 0) > 0, "WindowServer 메모리 \(Fmt.size(windowServer?.footprint ?? 0)) (\(windowServer?.memorySource.rawValue ?? "-"))")
    let busiest = records.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(5)
    for record in busiest { print(String(format: "  cpu %5.1f%%  %@ (%d)", record.cpuPercent, record.displayName, record.pid)) }
    let biggest = records.sorted { $0.footprint > $1.footprint }.prefix(8)
    for record in biggest { print("  mem \(Fmt.size(record.footprint))  \(record.displayName) (\(record.pid)) [\(record.memorySource.rawValue)]") }
}

/// 실제 Mac의 AI 세션 인식 결과(읽기 전용). 대표님 세션은 건드리지 않고 목록만 본다.
func sessionCheck() {
    let sampler = ProcessSampler()
    let detector = SessionDetector()
    let orca = OrcaBridge.list() ?? []
    let coldStart = Date()
    _ = detector.detect(records: sampler.sample(), sampler: sampler, orca: orca)
    let cold = Date().timeIntervalSince(coldStart)
    Thread.sleep(forTimeInterval: 2.0)
    let started = Date()
    let records = sampler.sample()
    let result = detector.detect(records: records, sampler: sampler, orca: orca)
    let elapsed = Date().timeIntervalSince(started)
    print(String(format: "cold %.0fms · steady %.0fms (sample+detect) · processes %d · sessions %d · standby spares %d · orca terminals %d", cold * 1000, elapsed * 1000, records.count, result.sessions.count, result.standbySpares, orca.count))
    var rows: [[String: Any]] = []
    for session in result.sessions {
        let line = "  [\(session.state.label)] \(session.kind.label) \(session.role) pid \(session.rootPID) · \(session.project) · 하위 \(session.childCount) · \(Fmt.size(session.footprint)) · CPU \(Fmt.percent(session.cpuPercent)) · \(Fmt.ago(session.lastActivity)) · \(session.terminalHost ?? "호스트 없음") · \(session.displayTitle) — \(session.stateReason)"
        print(line)
        rows.append(["kind": session.kind.rawValue, "role": session.role, "state": session.state.rawValue, "project": session.project, "children": session.childCount,
                     "footprint": session.footprint, "cpu": session.cpuPercent, "host": session.terminalHost ?? "", "log_linked": session.logPath != nil, "estimate": session.logLinkIsEstimate,
                     "title_source": session.titleSource, "reason": session.stateReason])
    }
    print("  apps:")
    for app in result.apps.prefix(10) { print("    \(app.name) [\(app.category.rawValue)] \(Fmt.size(app.footprint)) · 프로세스 \(app.pids.count)\(app.memorySourceNote.map { " · " + $0 } ?? "")") }
    // 종류별 세션 수(변경 전후 비교용)와 터미널 호스트 분포.
    let byKind = Dictionary(grouping: result.sessions, by: \.kind).map { "\($0.key.label) \($0.value.count)" }.sorted()
    print("  kinds: " + byKind.joined(separator: " · "))
    let byHost = Dictionary(grouping: result.sessions) { $0.terminalHost ?? "호스트 없음" }.map { "\($0.key) \($0.value.count)" }.sorted()
    print("  hosts: " + byHost.joined(separator: " · "))
    // 에이전트 도구 묶음(세션이 아닌 데몬·서버·앱): Codex app-server 등이 세션 대신 여기에 와야 한다.
    for app in result.apps where app.category == .agentApp || app.category == .host {
        print("  tool: \(app.name) [\(app.category.rawValue)] pids \(app.pids.sorted().prefix(8).map(String.init).joined(separator: ","))\(app.pids.count > 8 ? "…" : "")")
    }
    check(!result.sessions.isEmpty, "AI 세션 \(result.sessions.count)개 인식")
    // 다른 Mac(Claude·Codex·Orca가 없는 곳)에서도 돌도록: 설치되지 않은 것은 실패가 아니라 건너뜀으로 적는다.
    let installed = Set(AgentInventory.scan(probeVersions: false).filter(\.installed).map(\.kind))
    for kind in [AgentKind.claudeCode, .codexCLI] {
        if installed.contains(kind) { check(result.sessions.contains { $0.kind == kind }, "\(kind.label) 세션 인식") } else { print("SKIP \(kind.label) 미설치") }
    }
    check(elapsed < 0.15, String(format: "정상 주기 수집+인식 %.0fms < 150ms (2초 주기 대비 7.5%%)", elapsed * 1000))
    if OrcaBridge.executable != nil { check(!orca.isEmpty, "Orca 터미널 \(orca.count)개 읽음") } else { print("SKIP Orca CLI 없음 · 제목은 기록에서, 탭 상태는 'Orca 밖'") }
    for session in result.sessions {
        print("  탭 · \(session.project) \(session.kind.label) pid \(session.rootPID) · 호스트 \(session.terminalHost ?? "없음") · 탭 \(session.tabState.rawValue) · 상태 \(session.state.rawValue)")
    }
    for session in result.sessions where !session.subagents.isEmpty {
        let active = session.subagents.filter(\.active)
        print("  하위 에이전트 · \(session.project) pid \(session.rootPID) · 전체 \(session.subagents.count) · 일하는 중 \(active.count): " +
              active.prefix(9).map { "\($0.label)(\($0.model ?? "-"))" }.joined(separator: ", "))
    }
    writeEvidence("sessions-snapshot.json", ["time": ISO8601DateFormatter().string(from: Date()), "sessions": rows, "process_count": records.count])
}

/// 기록 읽기: 처음은 깊게, 이후는 이어 쓴 부분만 읽어도 시각·제목이 맞는지(합성 기록 파일).
func logReaderCheck() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remon-logreader-\(getpid())")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl").path
    func user(_ text: String, _ stamp: String) -> String {
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"},\"timestamp\":\"\(stamp)\"}\n"
    }
    func toolResult(_ size: Int, _ stamp: String) -> String {
        "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"content\":\"\(String(repeating: "x", count: size))\"}]},\"timestamp\":\"\(stamp)\"}\n"
    }
    func assistant(_ stamp: String) -> String { "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":\"ok\"},\"timestamp\":\"\(stamp)\"}\n" }
    func append(_ text: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
    }
    func date(_ stamp: String) -> Date? { ISO8601DateFormatter().date(from: stamp) }
    FileManager.default.createFile(atPath: path, contents: Data((user("첫 요청 정리해줘", "2026-10-24T10:00:00Z") + toolResult(3 << 20, "2026-10-24T10:00:05Z") + assistant("2026-10-24T10:00:10Z")).utf8))
    let reader = SessionLogReader()
    let first = reader.read(path: path, kind: .claudeCode)
    check(first.title == "첫 요청 정리해줘" && first.lastActivity == date("2026-10-24T10:00:10Z"), "처음 읽기: 3MB 도구 결과 너머의 요청 제목·마지막 시각")
    check(first.threadID == "11111111-2222-3333-4444-555555555555", "기록 파일 이름에서 스레드 ID")
    append(toolResult(200 << 10, "2026-10-24T10:01:00Z") + assistant("2026-10-24T10:01:30Z"))
    let second = reader.read(path: path, kind: .claudeCode)
    check(second.title == "첫 요청 정리해줘" && second.lastActivity == date("2026-10-24T10:01:30Z"), "이어 쓰기(요청 없음): 제목 유지 · 시각 갱신")
    append(user("두 번째 요청", "2026-10-24T10:02:00Z") + assistant("2026-10-24T10:02:10Z"))
    let third = reader.read(path: path, kind: .claudeCode)
    check(third.title == "두 번째 요청" && third.lastActivity == date("2026-10-24T10:02:10Z"), "이어 쓰기(새 요청): 제목 · 시각 갱신")
    append(toolResult(5 << 20, "2026-10-24T10:03:00Z"))
    let fourth = reader.read(path: path, kind: .claudeCode)
    check(fourth.title == "두 번째 요청" && fourth.lastActivity == date("2026-10-24T10:03:00Z"), "이어 쓰기(5MB 한 줄): 잘린 줄 끝의 시각")
    let unchanged = reader.read(path: path, kind: .claudeCode)
    check(unchanged == fourth, "변화 없음: 캐시 그대로")
}

/// SMC 팬·온도 읽기(읽기 전용). 값 범위와 읽기 비용만 확인한다.
func smcCheck() {
    let reader = SMCReader()
    let started = Date()
    let first = reader.read()
    let cold = Date().timeIntervalSince(started)
    let again = Date()
    for _ in 0..<20 { _ = reader.read() }
    let perRead = Date().timeIntervalSince(again) / 20
    print(String(format: "smc available %@ · fans %d · rpm %.0f (%.0f~%.0f) · cpu %.1f°C (%@) · first %.0fms · per read %.2fms",
                 first.available ? "yes" : "no", first.fanCount, first.fanRPM, first.fanMinRPM, first.fanMaxRPM, first.cpuTemperature, first.temperatureKey, cold * 1000, perRead * 1000))
    check(first.available, "SMC 읽기 가능")
    if first.fanCount > 0 { check(first.fanRPM >= first.fanMinRPM * 0.9 && first.fanRPM <= first.fanMaxRPM * 1.1, "팬 RPM이 최소~최대 범위 안") }
    check(first.cpuTemperature > 20 && first.cpuTemperature < 115, "CPU 온도가 20~115°C")
    check(perRead < 0.01, String(format: "읽기 비용 %.2fms < 10ms", perRead * 1000))
    writeEvidence("smc.json", ["fan_rpm": first.fanRPM, "fan_min": first.fanMinRPM, "fan_max": first.fanMaxRPM, "cpu_temp": first.cpuTemperature, "key": first.temperatureKey, "per_read_ms": perRead * 1000])
}

/// 진단: Codex 공급(vendor) 프로세스가 샘플러에서 어떻게 보이고 세션이 되는지.
func codexDebug() {
    let sampler = ProcessSampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 0.5)
    let records = sampler.sample()
    let codex = records.filter { ($0.path ?? "").contains("@openai/codex") || $0.name.hasPrefix("codex") || $0.name.contains("opencode") || ($0.path ?? "").contains("opencode") }
    for record in codex.sorted(by: { $0.pid < $1.pid }) {
        let path = record.path ?? "nil"
        print("pid \(record.pid) ppid \(record.ppid) uid \(record.uid) name=[\(record.name)] pathHasOpenai=\(path.contains("/@openai/codex")) tail=\(String(path.suffix(40)))")
    }
    let result = SessionDetector().detect(records: records, sampler: sampler, orca: OrcaBridge.list() ?? [])
    let codexSessions = result.sessions.filter { $0.kind == .codexCLI }
    print("codex sessions detected: \(codexSessions.count) → pids \(codexSessions.map(\.rootPID).sorted())")
    print("opencode sessions detected: \(result.sessions.filter { $0.kind == .opencode }.map { "\($0.rootPID) \($0.project) \($0.state.rawValue)" })")
}

let name = CommandLine.arguments.dropFirst().first ?? "all"
switch name {
case "metrics": metricsCheck()
case "processes": processCheck()
case "sessions": sessionCheck()
case "logreader": logReaderCheck()
case "smc": smcCheck()
case "codexdebug": codexDebug()
case "byproducts": byproductsCheck()
case "byproducts-rules": byproductsRulesCheck()
case "cleanup": cleanupCheck()
case "migration": migrationCheck()
case "alerts": alertsCheck()
case "recovery": recoveryCheck(); recoveryHardeningCheck()
case "recovery-live": recoveryLiveCheck()
case "diagnostics": diagnosticsCheck()
case "agents": agentsCheck()
case "terminal": terminalCheck()
case "selfspawn": selfSpawnCheck()
case "recovery-bg": recoveryBackgroundCheck()
case "recovery-bg-live": recoveryBackgroundLiveCheck()
case "claude-bg-detect": claudeBackgroundDetectCheck()
case "claude-deleted-binary": claudeDeletedBinaryCheck()
case "bg-viewer": backgroundViewerCheck()
case "departure": departureCheck()
case "e2e": endToEndCheck()
case "orca-env": orcaEnvironmentPairingCheck()
case "judgment": judgmentCheck()
case "gitevents": gitEventCheck()
case "room-clutter": roomClutterCheck()
case "sessions-probe": sessionsProbe()
case "registry-probe": registryProbe(CommandLine.arguments.dropFirst(2).compactMap { Int32($0) })
case "vault-probe": vaultProbe(CommandLine.arguments.dropFirst(2).first)
case "agents-live": agentsLiveCheck()
case "aidata": aiDataCheck()
case "diskcatalog": diskCatalogCheck()
case "helpers": helpersCheck(); suspectedOrphanCheck()
case "process-recovery": processRecoveryCheck()
case "workflow-residue": workflowResidueCheck()
case "suspects": suspectsProbe()
case "health": healthCheck()
case "molecompare": moleCompare()
case "appcache": appCacheCheck()
case "startup": startupCheck()
case "context": contextCheck()
case "disktree": diskTreeCheck()
case "disktree-probe": diskTreeProbe()
case "all":
    metricsCheck()
    processCheck()
default:
    print("unknown check: \(name)")
    failures += 1
}
print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
exit(failures == 0 ? 0 : 1)
