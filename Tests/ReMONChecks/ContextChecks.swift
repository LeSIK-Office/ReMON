import Foundation
import ReMONCore

// 세션 자원(컨텍스트 점유) 검사. 합성 기록을 임시 폴더에 실제와 같은 모양으로 쓴다:
// Claude Code assistant 줄의 message.usage · Codex event_msg/token_count(info가 null인 줄 포함).
// 마지막에 이 Mac의 실제 세션을 읽기 전용으로 훑어 숫자만 찍는다(대화 원문·제목은 찍지 않는다).

private func contextSession(_ pid: Int32, _ kind: AgentKind, log: String?, footprint: UInt64 = 0, state: SessionState = .working, lastActivity: Date? = nil) -> AgentSession {
    var session = AgentSession(id: ProcessKey(pid: pid, start: 1_760_000_000 + Int64(pid)), kind: kind, rootPID: pid, pids: [pid], footprint: footprint,
                               project: "시험", state: state, lastActivity: lastActivity)
    session.logPath = log
    return session
}

private func claudeAssistant(_ uuid: String, input: Int, cacheRead: Int, cacheCreation: Int, output: Int, model: String = "claude-opus-5-5", sidechain: Bool = false) -> String {
    "{\"parentUuid\":\"p-\(uuid)\",\"isSidechain\":\(sidechain),\"userType\":\"external\",\"cwd\":\"/tmp/remon-context\",\"sessionId\":\"11111111-2222-3333-4444-555555555555\",\"version\":\"2.1.300\","
        + "\"message\":{\"model\":\"\(model)\",\"id\":\"msg_\(uuid)\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"응답 \(uuid)\"}],"
        + "\"stop_reason\":\"end_turn\",\"stop_sequence\":null,\"usage\":{\"input_tokens\":\(input),\"cache_creation_input_tokens\":\(cacheCreation),\"cache_read_input_tokens\":\(cacheRead),"
        + "\"cache_creation\":{\"ephemeral_5m_input_tokens\":0,\"ephemeral_1h_input_tokens\":\(cacheCreation)},\"output_tokens\":\(output),\"service_tier\":\"standard\"}},"
        + "\"requestId\":\"req_\(uuid)\",\"type\":\"assistant\",\"uuid\":\"\(uuid)\",\"timestamp\":\"2026-10-25T01:00:00.000Z\"}\n"
}

private func claudeUser(_ text: String) -> String {
    "{\"parentUuid\":null,\"isSidechain\":false,\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(text)\"},\"uuid\":\"u-\(text.count)\",\"timestamp\":\"2026-10-25T01:00:00.000Z\"}\n"
}

/// 사용량이 없는 큰 줄(도구 결과). size바이트 남짓.
private func claudeToolResult(_ size: Int) -> String {
    "{\"parentUuid\":null,\"isSidechain\":false,\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"\(String(repeating: "x", count: size))\"}]},\"timestamp\":\"2026-10-25T01:00:01.000Z\"}\n"
}

private func codexTokenCount(last: Int, input: Int, window: Int, total: Int) -> String {
    "{\"timestamp\":\"2026-10-25T01:00:02.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{"
        + "\"total_token_usage\":{\"input_tokens\":\(total - 1000),\"cached_input_tokens\":\(total / 2),\"cache_write_input_tokens\":0,\"output_tokens\":1000,\"reasoning_output_tokens\":200,\"total_tokens\":\(total)},"
        + "\"last_token_usage\":{\"input_tokens\":\(input),\"cached_input_tokens\":\(input - 4000),\"cache_write_input_tokens\":0,\"output_tokens\":\(last - input),\"reasoning_output_tokens\":200,\"total_tokens\":\(last)},"
        + "\"model_context_window\":\(window)},\"rate_limits\":{\"primary\":{\"used_percent\":10.0,\"window_minutes\":300}}}}\n"
}

private let codexNullInfo = "{\"timestamp\":\"2026-10-25T01:00:03.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null,\"rate_limits\":{\"primary\":{\"used_percent\":12.0,\"window_minutes\":300}}}}\n"

private func writeFile(_ path: String, _ text: String) {
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
}

private func appendFile(_ path: String, _ text: String) {
    guard let handle = FileHandle(forWritingAtPath: path) else { return }
    handle.seekToEndOfFile()
    handle.write(Data(text.utf8))
    try? handle.close()
}

private func fileSize(_ path: String) -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
}

func contextCheck() {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remon-context-\(getpid())")
    try? FileManager.default.removeItem(at: folder)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    // 1) Claude: assistant 3줄 — 마지막 줄이 컨텍스트를 정한다. 그 뒤의 사용자 줄(중첩 usage·문자열 속 usage)은 무시.
    let claudePath = folder.appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl").path
    let nestedUsageUser = "{\"parentUuid\":null,\"isSidechain\":false,\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"toolu_2\",\"content\":\"done\"}]},"
        + "\"toolUseResult\":{\"status\":\"completed\",\"totalTokens\":90000,\"usage\":{\"input_tokens\":88000,\"cache_read_input_tokens\":1000,\"output_tokens\":500},\"content\":[{\"type\":\"text\",\"role\":\"assistant\"}]},"
        + "\"timestamp\":\"2026-10-25T01:00:05.000Z\"}\n"
    writeFile(claudePath, claudeUser("첫 요청")
        + claudeAssistant("a1", input: 10, cacheRead: 1_000, cacheCreation: 200, output: 50)
        + claudeToolResult(2_000)
        + claudeAssistant("a2", input: 12, cacheRead: 5_000, cacheCreation: 300, output: 70)
        + claudeToolResult(2_000)
        + claudeAssistant("a3", input: 5, cacheRead: 170_000, cacheCreation: 5_000, output: 900)
        + claudeUser("문자열 속 {\\\"type\\\":\\\"assistant\\\",\\\"message\\\":{\\\"usage\\\":{\\\"input_tokens\\\":999999}}} 는 무시")
        + nestedUsageUser)

    // 2) Codex: token_count 두 줄(뒤가 최신) + info:null 줄이 맨 끝.
    let codexPath = folder.appendingPathComponent("rollout-2026-10-25T01-00-00-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl").path
    writeFile(codexPath, "{\"timestamp\":\"2026-10-25T01:00:00.000Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\",\"cwd\":\"/tmp/remon-context\"}}\n"
        + codexTokenCount(last: 102_000, input: 100_000, window: 475_000, total: 102_000)
        + "{\"timestamp\":\"2026-10-25T01:00:01.000Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}}\n"
        + codexTokenCount(last: 175_000, input: 174_000, window: 475_000, total: 4_758_808_771)
        + codexNullInfo)

    let metrics = ContextMetrics()
    var sessions = [contextSession(101, .claudeCode, log: claudePath, footprint: 7 << 30), contextSession(102, .codexCLI, log: codexPath, footprint: 7 << 30),
                    contextSession(103, .opencode, log: nil)]
    metrics.enrich(&sessions)
    let claude = sessions[0], codex = sessions[1]
    check(claude.contextTokens == 175_005, "Claude: 마지막 assistant 줄 input 5 + cache_read 170,000 + cache_creation 5,000 = \(claude.contextTokens.map(String.init) ?? "nil") (기대 175005)")
    check(claude.contextWindow == nil && claude.contextFill == nil, "Claude: 창 크기는 기록에 없어 비움(지어내지 않음) → 점유율 nil")
    check(claude.totalTokens == nil, "Claude: 누적 토큰은 기록에 없어 nil")
    check(claude.transcriptBytes == fileSize(claudePath), "Claude: 기록 크기 \(claude.transcriptBytes ?? 0) = 파일 크기 \(fileSize(claudePath))")
    check(metrics.reading(forPath: claudePath)?.model == "claude-opus-5-5", "Claude: 모델 이름은 표시용으로만 보관")
    check(codex.contextTokens == 175_000 && codex.contextWindow == 475_000, "Codex: info:null 줄을 건너뛰고 마지막 token_count의 last 175,000 · 창 475,000")
    check(codex.totalTokens == 4_758_808_771, "Codex: 누적 total_token_usage.total_tokens 4,758,808,771")
    if let fill = codex.contextFill {
        check(abs(fill - 175_000.0 / 475_000.0) < 1e-9, String(format: "Codex: 점유율 %.4f = 175000/475000", fill))
    } else {
        check(false, "Codex: 점유율 nil")
    }
    check(sessions[2].contextTokens == nil && sessions[2].transcriptBytes == nil, "기록이 없는 세션은 그대로 nil")
    check(metrics.parses == 2 && metrics.fileReads == 2, "처음: 기록 2개를 한 번씩 읽음(해석 \(metrics.parses) · 읽기 \(metrics.fileReads))")

    // 3) 캐시: 같은 파일이면 다시 읽지 않는다 → 이어 쓰면 그 파일만 다시 읽는다.
    for _ in 0..<3 { metrics.enrich(&sessions) }
    check(metrics.parses == 2 && metrics.fileReads == 2, "변화 없음 ×3: 다시 읽지 않음(해석 \(metrics.parses) · 읽기 \(metrics.fileReads))")
    check(sessions[0].contextTokens == 175_005 && sessions[1].contextTokens == 175_000, "변화 없음: 캐시 값 그대로")
    appendFile(claudePath, claudeAssistant("a4", input: 7, cacheRead: 180_000, cacheCreation: 1_000, output: 300))
    metrics.enrich(&sessions)
    check(metrics.parses == 3 && metrics.fileReads == 3 && sessions[0].contextTokens == 181_007, "이어 쓰기: 그 파일만 다시 읽어 새 값 181,007 (해석 \(metrics.parses) · 읽기 \(metrics.fileReads) · \(sessions[0].contextTokens ?? -1))")
    appendFile(claudePath, claudeAssistant("a5", input: 0, cacheRead: 0, cacheCreation: 0, output: 0, model: "<synthetic>")
        + claudeAssistant("a6", input: 1, cacheRead: 900_000, cacheCreation: 0, output: 10, sidechain: true))
    metrics.enrich(&sessions)
    check(sessions[0].contextTokens == 181_007, "합성 줄(<synthetic> · 사용량 0)과 하위 에이전트 줄(isSidechain)은 건너뜀")

    // 4) 꼬리 확장: 사용량 줄이 끝에서 64KB보다 멀면 512KB까지 늘려 찾는다.
    let farPath = folder.appendingPathComponent("22222222-2222-3333-4444-555555555555.jsonl").path
    writeFile(farPath, claudeUser("긴 도구 결과") + claudeAssistant("f1", input: 3, cacheRead: 300_000, cacheCreation: 0, output: 10)
        + String(repeating: claudeToolResult(10_000), count: 10))
    let tail = ContextMetrics()
    var far = [contextSession(201, .claudeCode, log: farPath)]
    tail.enrich(&far)
    check(far[0].contextTokens == 300_003 && tail.fileReads == 2, "64KB 너머(\(fileSize(farPath) / 1024)KB 파일의 앞쪽) 사용량 줄: 64KB → 512KB로 늘려 찾음(읽기 \(tail.fileReads))")
    // 이어 쓴 양이 적으면(10KB) 64KB 한 번만 읽고, 꼬리에 새 사용량 줄이 없으면 지난 값을 이어받는다.
    appendFile(farPath, claudeToolResult(10_000))
    tail.enrich(&far)
    check(far[0].contextTokens == 300_003 && tail.fileReads == 3, "이어 쓰기 10KB(사용량 없음): 64KB 한 번만 읽고 지난 값 유지(읽기 \(tail.fileReads))")
    // 600KB가 붙어 사용량 줄이 512KB 밖으로 밀려도, 이어 쓰기만 했으니 지난 값이 여전히 마지막 사용량이다.
    appendFile(farPath, String(repeating: claudeToolResult(10_000), count: 60))
    tail.enrich(&far)
    check(far[0].contextTokens == 300_003 && tail.fileReads == 5, "이어 쓰기 600KB(사용량 없음): 64KB → 512KB 읽고 지난 값 유지(읽기 \(tail.fileReads))")
    // 처음 보는 파일인데 사용량 줄이 512KB 밖이면: 모른다(nil) — 기록 크기만 채운다.
    let fresh = ContextMetrics()
    var cold = [contextSession(202, .claudeCode, log: farPath)]
    fresh.enrich(&cold)
    check(cold[0].contextTokens == nil && cold[0].transcriptBytes == fileSize(farPath) && fresh.fileReads == 2,
          "처음 보는 파일 · 사용량 줄이 512KB 밖: 컨텍스트 nil · 기록 크기 \(cold[0].transcriptBytes ?? 0)B만 채움(읽기 \(fresh.fileReads))")
    // 파일이 줄면(다시 쓰임) 지난 값을 버리고 새로 읽는다.
    writeFile(farPath, claudeAssistant("r1", input: 2, cacheRead: 40_000, cacheCreation: 0, output: 5))
    tail.enrich(&far)
    check(far[0].contextTokens == 40_002, "파일이 줄면 지난 값을 버리고 새로 읽음 → 40,002")

    // 5) Codex: last_token_usage에 total_tokens가 없으면 input_tokens. info:null만 있으면 nil. 쓰다 만 마지막 줄은 건너뜀.
    let noTotal = "{\"timestamp\":\"t\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":91000,\"output_tokens\":10},\"model_context_window\":258400}}}\n"
    let fallback = ContextMetrics.parse(tail: Data(noTotal.utf8), fromFileStart: true)
    check(fallback?.contextTokens == 91_000 && fallback?.contextWindow == 258_400 && fallback?.totalTokens == nil, "Codex: total_tokens가 없으면 input_tokens 91,000 · 창 258,400")
    check(ContextMetrics.parse(tail: Data(codexNullInfo.utf8), fromFileStart: true) == nil, "Codex: info:null 줄만 있으면 nil")
    let partial = codexTokenCount(last: 50_000, input: 49_000, window: 475_000, total: 60_000) + String(codexTokenCount(last: 70_000, input: 69_000, window: 475_000, total: 80_000).prefix(120))
    check(ContextMetrics.parse(tail: Data(partial.utf8), fromFileStart: true)?.contextTokens == 50_000, "쓰다 만 마지막 줄은 건너뛰고 그 앞 줄 50,000")
    let cut = String(codexTokenCount(last: 50_000, input: 49_000, window: 475_000, total: 60_000).dropFirst(10))
    check(ContextMetrics.parse(tail: Data(cut.utf8), fromFileStart: false) == nil, "꼬리 맨 앞 조각(줄 중간에서 시작)은 해석하지 않음")

    // 6) 해석 예산: 0초면 주기마다 1개씩만 해석하고 나머지는 다음 주기로 미룬다(수집이 밀리지 않게).
    let budget = ContextMetrics()
    budget.parseBudget = 0
    var trio = [contextSession(301, .claudeCode, log: claudePath), contextSession(302, .codexCLI, log: codexPath), contextSession(303, .claudeCode, log: farPath)]
    var perPass: [Int] = []
    for _ in 0..<4 {
        budget.enrich(&trio)
        perPass.append(budget.parses)
    }
    check(perPass == [1, 2, 3, 3] && trio.allSatisfy { $0.contextTokens != nil }, "예산 0: 주기마다 1개씩 해석 \(perPass) → 3주기 뒤 모두 채움")

    // 7) contextFill: 창을 알 때만 · 1을 넘지 않음.
    var filled = contextSession(401, .codexCLI, log: nil)
    filled.contextTokens = 175_000; filled.contextWindow = 475_000
    var over = filled; over.contextTokens = 500_000
    var noWindow = filled; noWindow.contextWindow = nil
    var zeroWindow = filled; zeroWindow.contextWindow = 0
    check(abs((filled.contextFill ?? 0) - 0.368421) < 1e-6 && over.contextFill == 1 && noWindow.contextFill == nil && zeroWindow.contextFill == nil,
          "contextFill: 175k/475k = 0.3684 · 넘치면 1 · 창 없음/0이면 nil")

    // 8) 화면 문구(화면과 같은 함수): 막대 · 기록·메모리 · 누적 토큰 · 인계 권고 · 기다리는 세션.
    var codexCard = codex
    codexCard.transcriptBytes = 2_200_000_000
    var claudeCard = claude
    claudeCard.contextTokens = 567_000
    check(ContextText.context(codexCard) == "컨텍스트 37% · 175k/475k", "문구: \(ContextText.context(codexCard) ?? "nil")")
    check(ContextText.context(claudeCard) == "컨텍스트 567k 토큰", "문구: \(ContextText.context(claudeCard) ?? "nil")")
    check(ContextText.storage(codexCard) == "기록 2.0GB · 메모리 7.0GB", "문구: \(ContextText.storage(codexCard)) (2.2e9바이트 = 2.0GiB · Fmt 1024 기준)")
    check(ContextText.cumulative(codexCard) == "누적 토큰 4.8B" && ContextText.cumulative(claudeCard) == nil, "문구: \(ContextText.cumulative(codexCard) ?? "nil") · Claude는 누적 없음")
    check([950, 175_400, 999_499, 999_500, 1_260_000, 4_758_808_771].map(ContextText.tokens) == ["950", "175k", "999k", "1.0M", "1.3M", "4.8B"],
          "토큰 표기: \([950, 175_400, 999_499, 999_500, 1_260_000, 4_758_808_771].map(ContextText.tokens))")
    var atThreshold = filled; atThreshold.contextTokens = 332_500   // 332,500 / 475,000 = 0.70
    var below = filled; below.contextTokens = 332_000
    check(ContextText.needsHandoff(atThreshold) && !ContextText.needsHandoff(below) && !ContextText.needsHandoff(claudeCard), "인계 권고: 70% 이상만(69.9%·창 모름은 아님)")
    let prompt = ContextText.handoffPrompt(for: atThreshold)
    let wanted = ["70%", "현재 목표", "끝낸 일", "남은 일", "핵심 파일", "인계서 작성 완료"]
    check(wanted.allSatisfy(prompt.contains) && !prompt.contains("우리"), "인계 프롬프트: \(wanted.joined(separator: "·")) 포함 · '우리' 없음")
    var big = filled; big.rootPID = 501; big.contextTokens = 400_000                       // 84%
    var small = filled; small.rootPID = 502; small.contextTokens = 100_000                 // 21%
    var claudeBig = claudeCard; claudeBig.rootPID = 503; claudeBig.contextTokens = 800_000 // 창 모름
    var claudeSmall = claudeCard; claudeSmall.rootPID = 504; claudeSmall.contextTokens = 200_000
    let unknown = contextSession(505, .claudeCode, log: nil)
    let leaders = ContextText.leaders([claudeSmall, small, unknown, claudeBig, big])
    check(leaders.map(\.rootPID) == [501, 502, 503], "컨텍스트가 큰 세션: 점유율 순 → 창 모름은 토큰 순 → 못 읽은 세션 제외 \(leaders.map(\.rootPID))")
    let now = Date()
    let waiting = [contextSession(601, .claudeCode, log: nil, state: .waiting, lastActivity: now.addingTimeInterval(-(3 * 3600 + 600))),
                   contextSession(602, .codexCLI, log: nil, state: .waiting, lastActivity: now.addingTimeInterval(-1200)),
                   contextSession(603, .claudeCode, log: nil, state: .working, lastActivity: now.addingTimeInterval(-90_000))]
    check(ContextText.waitingLine(waiting, now: now) == "답을 기다리는 세션 2개 · 가장 오래 3시간", "기다리는 세션: \(ContextText.waitingLine(waiting, now: now) ?? "nil")")
    check(ContextText.waitingLine([waiting[2]], now: now) == nil, "기다리는 세션이 없으면 줄을 숨김")
    check([30.0, 2_400, 7_200, 200_000].map(ContextText.silence) == ["1분 미만", "40분", "2시간", "2일"], "조용한 시간 표기: \([30.0, 2_400, 7_200, 200_000].map(ContextText.silence))")

    contextLiveProbe()
}

/// 이 Mac의 실제 세션(읽기 전용): 숫자만 찍는다 — 종류 · pid · 방(폴더 이름) · 컨텍스트 · 기록 크기 · 메모리. 제목·대화 원문은 찍지 않는다.
private func contextLiveProbe() {
    let sampler = ProcessSampler()
    let detector = SessionDetector()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 0.5)
    var sessions = detector.detect(records: sampler.sample(), sampler: sampler, orca: OrcaBridge.list() ?? []).sessions
    guard !sessions.isEmpty else { print("SKIP 실행 중인 AI 세션 없음"); return }
    let metrics = ContextMetrics()
    let coldStart = DispatchTime.now().uptimeNanoseconds
    metrics.enrich(&sessions)
    let cold = Double(DispatchTime.now().uptimeNanoseconds - coldStart) / 1e6
    let coldParses = metrics.parses
    var again = sessions
    let steadyStart = DispatchTime.now().uptimeNanoseconds
    metrics.enrich(&again)
    let steady = Double(DispatchTime.now().uptimeNanoseconds - steadyStart) / 1e6
    let linked = sessions.filter { $0.logPath != nil }
    let known = sessions.filter { $0.contextTokens != nil }
    print(String(format: "live: 세션 %d · 기록 연결 %d · 컨텍스트 읽음 %d · 처음 %.1fms(해석 %d · 읽기 %d) · 다시 %.1fms(추가 해석 %d)",
                 sessions.count, linked.count, known.count, cold, coldParses, metrics.fileReads, steady, metrics.parses - coldParses))
    for session in sessions.sorted(by: { ($0.contextFill ?? -1, $0.contextTokens ?? -1) > ($1.contextFill ?? -1, $1.contextTokens ?? -1) }) where session.logPath != nil {
        let context = ContextText.context(session) ?? "컨텍스트 못 읽음"
        let total = ContextText.cumulative(session).map { " · " + $0 } ?? ""
        print("  \(session.kind.shortName) pid \(session.rootPID) · \(session.project) · \(session.state.label) · \(context)\(total) · \(ContextText.storage(session))\(session.logLinkIsEstimate ? " · 기록 연결 추정" : "")\(ContextText.needsHandoff(session) ? " · 인계 권고" : "")")
    }
    check(linked.isEmpty || !known.isEmpty, "live: 기록이 연결된 세션 \(linked.count)개 중 컨텍스트를 읽은 세션 \(known.count)개")
    check(steady < 50, String(format: "live: 캐시가 찬 뒤 한 주기 %.1fms < 50ms", steady))
}
