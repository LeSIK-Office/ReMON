import Darwin
import Foundation

/// 세션 자원 — 컨텍스트 점유(마지막 호출 기준 토큰) · 모델 창 크기 · 누적 토큰 · 기록 파일 크기를 기록(jsonl) 꼬리에서 읽는다.
/// 대화가 길면 세션 메모리도 커지기 쉽다(10-25 대표 관찰: 2.2GB rollout을 쥔 Codex 세션 RSS ≈ 7GB). 그래서 컨텍스트를 세션 자원으로 보여 준다.
///
/// 읽는 법 — 원문은 저장하지 않고 숫자만 남긴다.
/// - Claude Code(`~/.claude/projects/<폴더>/<id>.jsonl`): 마지막 assistant 줄 `message.usage`의 input + cache_read_input + cache_creation_input.
///   기록에 창 크기가 없어 비운다(모델 이름으로 지어내지 않는다). `message.model`은 표시용으로만 둔다.
///   하위 에이전트 줄(isSidechain)과 사용량이 0인 합성 줄(<synthetic>·API 오류)은 건너뛴다.
/// - Codex(`~/.codex/sessions/…/rollout-*.jsonl`): 마지막 `event_msg`/`token_count`(info가 null인 줄은 건너뜀)의
///   last_token_usage.total_tokens(없으면 input_tokens) · model_context_window · total_token_usage.total_tokens(누적).
///
/// 비용 — 사무실 창이 열려 있으면 수집 큐에서 2초마다 부른다.
/// - 꼬리만 읽는다: 64KB에서 시작해 사용량 줄이 없으면 512KB까지. 이어 쓴 파일은 새로 붙은 양 + 줄 경계 여유 32KB만 본다
///   (최소 64KB · 그 안에 사용량 줄이 없으면 지난번 값이 여전히 마지막 사용량이다).
/// - 경로마다 (크기, 수정 시각)이 그대로면 다시 읽지 않는다. 바뀐 파일만 해석한다.
/// - 한 번에 해석하는 시간을 `parseBudget`(25ms)으로 묶는다. 넘으면 나머지는 지난 값을 쓰고 다음 주기에 읽는다(매번 최소 1개는 해석).
public final class ContextMetrics: @unchecked Sendable {
    public static let shared = ContextMetrics()

    /// 인계 권고 기준: 컨텍스트 점유율 70% 이상.
    public static let handoffThreshold = 0.7
    /// 처음 읽는 꼬리 크기와 최대 크기.
    public static let firstWindow: UInt64 = 64 << 10
    public static let maxWindow: UInt64 = 512 << 10
    /// 이어 쓴 파일을 다시 볼 때 새로 붙은 양 앞에 더 보는 여유(지난번에 쓰다 만 줄이 끝났을 수 있다).
    static let lineMargin: UInt64 = 32 << 10

    /// 기록에서 읽은 숫자(원문 없음).
    public struct Reading: Sendable, Equatable {
        public var contextTokens: Int?
        public var contextWindow: Int?
        public var totalTokens: Int?
        /// 표시용 모델 이름(Claude 기록에만 있다). 창 크기 추정에 쓰지 않는다.
        public var model: String?

        public init(contextTokens: Int? = nil, contextWindow: Int? = nil, totalTokens: Int? = nil, model: String? = nil) {
            self.contextTokens = contextTokens
            self.contextWindow = contextWindow
            self.totalTokens = totalTokens
            self.model = model
        }
    }

    private struct FileKey: Equatable {
        var size: UInt64
        var seconds: Int
        var nanoseconds: Int
    }

    private struct Entry {
        var key: FileKey
        var reading: Reading
        var lastUsed: Date
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var reads = 0
    private var parseCount = 0

    /// 한 번의 enrich에서 해석에 쓰는 시간 상한(초). 넘으면 나머지 파일은 다음 주기로 미룬다.
    public var parseBudget: TimeInterval = 0.025

    public init() {}

    /// 꼬리를 디스크에서 읽은 횟수(시험용).
    public var fileReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    /// 캐시를 못 써서 기록을 해석한 횟수(시험용).
    public var parses: Int { lock.lock(); defer { lock.unlock() }; return parseCount }

    /// 이 기록 파일에서 마지막으로 읽은 값(화면의 모델 이름 표시용). 디스크는 건드리지 않는다.
    public func reading(forPath path: String) -> Reading? {
        lock.lock(); defer { lock.unlock() }
        return cache[path]?.reading
    }

    /// 세션마다 기록 파일 크기 · 컨텍스트 토큰 · 창 크기 · 누적 토큰을 채운다. 기록이 없으면 그대로 둔다(nil).
    public func enrich(_ sessions: inout [AgentSession], now: Date = Date()) {
        let started = DispatchTime.now().uptimeNanoseconds
        var parsedThisPass = 0
        for index in sessions.indices {
            guard let path = sessions[index].logPath, let key = Self.fileKey(path) else { continue }
            sessions[index].transcriptBytes = key.size
            lock.lock()
            let cached = cache[path]
            if cached?.key == key { cache[path]?.lastUsed = now }
            lock.unlock()
            let reading: Reading?
            if let cached, cached.key == key {
                reading = cached.reading
            } else if parsedThisPass == 0 || Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 < parseBudget {
                // 이어 쓰기만 했다면(크기가 줄지 않음) 지난 값을 이어받을 수 있다. 줄었으면 다른 내용이라 처음부터 읽는다.
                let previous = cached.flatMap { $0.key.size <= key.size ? $0 : nil }
                let fresh = autoreleasepool { parse(path: path, size: key.size, previous: previous) }
                parsedThisPass += 1
                lock.lock()
                cache[path] = Entry(key: key, reading: fresh, lastUsed: now)
                parseCount += 1
                lock.unlock()
                reading = fresh
            } else {
                // 이번 주기 예산을 다 썼다: 지난 값을 쓰고, 캐시 키가 그대로라 다음 주기에 읽는다.
                reading = cached?.reading
            }
            sessions[index].contextTokens = reading?.contextTokens
            sessions[index].contextWindow = reading?.contextWindow
            sessions[index].totalTokens = reading?.totalTokens
        }
        // 10분 넘게 어느 세션도 가리키지 않은 기록은 잊는다.
        lock.lock()
        cache = cache.filter { now.timeIntervalSince($0.value.lastUsed) < 600 }
        lock.unlock()
    }

    // MARK: - 파일

    private static func fileKey(_ path: String) -> FileKey? {
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { return nil }
        return FileKey(size: UInt64(info.st_size), seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    /// 꼬리를 64KB부터 읽고, 사용량 줄이 없으면 한도까지 늘린다. 한도: 처음 읽는 파일은 512KB,
    /// 이어 쓴 파일은 새로 붙은 양 + 줄 경계 여유 32KB(64KB~512KB) — 그보다 앞은 지난번에 이미 본 곳이다.
    private func parse(path: String, size: UInt64, previous: Entry?) -> Reading {
        var limit = Self.maxWindow
        if let previous {
            let appended = size - previous.key.size
            limit = min(Self.maxWindow, max(Self.firstWindow, appended + Self.lineMargin))
        }
        var window = min(Self.firstWindow, size)
        while window > 0 {
            guard let data = readTail(path, size: size, length: window) else { break }
            if let found = Self.parse(tail: data, fromFileStart: window >= size) { return found }
            let next = min(limit, size)
            if next <= window { break }
            window = next
        }
        // 꼬리에 사용량 줄이 없다: 이어 쓰기만 했다면 지난 값이 여전히 마지막 사용량이다.
        return previous?.reading ?? Reading()
    }

    private func readTail(_ path: String, size: UInt64, length: UInt64) -> Data? {
        let count = Int(min(length, size))
        guard count > 0 else { return nil }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var data = Data(count: count)
        let got = data.withUnsafeMutableBytes { buffer in pread(descriptor, buffer.baseAddress, count, off_t(size - UInt64(count))) }
        guard got > 0 else { return nil }
        if got < count { data.count = got }
        lock.lock(); reads += 1; lock.unlock()
        return data
    }

    // MARK: - 해석(순수 함수 — 시험이 바로 부른다)

    private static let newline = UInt8(ascii: "\n")
    private static let codexMarker = Data("\"token_count\"".utf8)
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let assistantMarker = Data("\"assistant\"".utf8)

    /// 꼬리 바이트에서 마지막 사용량 줄을 뒤에서부터 찾는다. 맨 앞 조각은 줄 중간에서 시작했을 수 있어 버린다(파일 맨 앞이면 쓴다).
    /// 표식(따옴표까지 포함한 키 이름)이 있는 줄만 JSON으로 해석한다 — 문자열 안의 같은 글자는 \"로 이스케이프돼 걸리지 않는다.
    public static func parse(tail: Data, fromFileStart: Bool) -> Reading? {
        var end = tail.endIndex
        while end > tail.startIndex {
            let newlineIndex = tail[tail.startIndex..<end].lastIndex(of: newline)
            if newlineIndex == nil && !fromFileStart { return nil }
            let start = newlineIndex.map { $0 + 1 } ?? tail.startIndex
            if start < end, let reading = reading(line: tail[start..<end]) { return reading }
            guard let newlineIndex else { return nil }
            end = newlineIndex
        }
        return nil
    }

    /// 한 줄(JSON)에서 Claude assistant 사용량 또는 Codex token_count를 읽는다. 둘 다 아니면 nil.
    public static func reading(line: Data) -> Reading? {
        let codexCandidate = line.range(of: codexMarker) != nil
        let claudeCandidate = line.range(of: usageMarker) != nil && line.range(of: assistantMarker) != nil
        guard codexCandidate || claudeCandidate,
              let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
        return codexReading(object) ?? claudeReading(object)
    }

    static func claudeReading(_ object: [String: Any]) -> Reading? {
        guard object["type"] as? String == "assistant", (object["isSidechain"] as? Bool) != true,
              let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] else { return nil }
        let model = message["model"] as? String
        if model == "<synthetic>" { return nil }
        let context = (int(usage["input_tokens"]) ?? 0) + (int(usage["cache_read_input_tokens"]) ?? 0) + (int(usage["cache_creation_input_tokens"]) ?? 0)
        guard context > 0 else { return nil }
        return Reading(contextTokens: context, contextWindow: nil, totalTokens: nil, model: model)
    }

    static func codexReading(_ object: [String: Any]) -> Reading? {
        guard object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return nil }
        let total = int(last["total_tokens"]).flatMap { $0 > 0 ? $0 : nil }
        guard let context = total ?? int(last["input_tokens"]), context > 0 else { return nil }
        let window = int(info["model_context_window"]).flatMap { $0 > 0 ? $0 : nil }
        let cumulative = (info["total_token_usage"] as? [String: Any]).flatMap { int($0["total_tokens"]) }
        return Reading(contextTokens: context, contextWindow: window, totalTokens: cumulative, model: nil)
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

/// 세션 자원 표시 문구. 화면과 검사가 같은 문구를 쓴다. 금액은 쓰지 않는다(검증된 가격표가 없다).
public enum ContextText {
    /// 950 → "950" · 175_400 → "175k" · 1_250_000 → "1.3M" · 4_758_808_771 → "4.8B"
    public static func tokens(_ count: Int) -> String {
        let value = Double(max(0, count))
        if value < 1_000 { return "\(max(0, count))" }
        let thousands = (value / 1_000).rounded()
        if thousands < 1_000 { return "\(Int(thousands))k" }
        if value < 999_950_000 { return String(format: "%.1fM", value / 1_000_000) }
        return String(format: "%.1fB", value / 1_000_000_000)
    }

    /// 0.3684 → "37%"
    public static func percent(_ fill: Double) -> String {
        "\(Int((min(1, max(0, fill)) * 100).rounded()))%"
    }

    /// "컨텍스트 37% · 175k/475k"(창을 알 때) · "컨텍스트 567k 토큰"(모를 때) · nil(사용량을 아직 못 읽음)
    public static func context(_ session: AgentSession) -> String? {
        guard let used = session.contextTokens else { return nil }
        if let fill = session.contextFill, let window = session.contextWindow {
            return "컨텍스트 \(percent(fill)) · \(tokens(used))/\(tokens(window))"
        }
        return "컨텍스트 \(tokens(used)) 토큰"
    }

    /// 목록 한 줄용 짧은 표기: "컨텍스트 37%" · "컨텍스트 567k"
    public static func compact(_ session: AgentSession) -> String? {
        guard let used = session.contextTokens else { return nil }
        if let fill = session.contextFill { return "컨텍스트 \(percent(fill))" }
        return "컨텍스트 \(tokens(used))"
    }

    /// "기록 2.0GB · 메모리 7.0GB"(기록 크기를 모르면 "메모리 7.0GB")
    public static func storage(_ session: AgentSession) -> String {
        let memory = "메모리 \(Fmt.size(session.footprint))"
        guard let bytes = session.transcriptBytes else { return memory }
        return "기록 \(Fmt.size(bytes)) · \(memory)"
    }

    /// "누적 토큰 4.8B"(Codex처럼 기록에 누적 값이 있을 때만)
    public static func cumulative(_ session: AgentSession) -> String? {
        session.totalTokens.map { "누적 토큰 \(tokens($0))" }
    }

    /// 인계를 권하는가(점유율 70% 이상 — 창 크기를 알 때만).
    public static func needsHandoff(_ session: AgentSession) -> Bool {
        (session.contextFill ?? 0) >= ContextMetrics.handoffThreshold
    }

    /// 컨텍스트가 큰 세션: 점유율이 높은 순, 점유율을 모르면(창 크기 없음) 그 뒤에 토큰이 많은 순. 컨텍스트를 못 읽은 세션은 뺀다.
    public static func leaders(_ sessions: [AgentSession], limit: Int = 3) -> [AgentSession] {
        let known = sessions.filter { $0.contextTokens != nil }
        let ordered = known.sorted { lhs, rhs in
            let left = lhs.contextFill ?? -1, right = rhs.contextFill ?? -1
            if left != right { return left > right }
            let leftTokens = lhs.contextTokens ?? 0, rightTokens = rhs.contextTokens ?? 0
            if leftTokens != rightTokens { return leftTokens > rightTokens }
            return lhs.rootPID < rhs.rootPID
        }
        return Array(ordered.prefix(max(0, limit)))
    }

    /// "답을 기다리는 세션 2개 · 가장 오래 3시간"(기다리는 세션이 없으면 nil). 가장 오래 = 지금 − 마지막 기록.
    public static func waitingLine(_ sessions: [AgentSession], now: Date = Date()) -> String? {
        let waiting = sessions.filter { $0.state == .waiting }
        guard !waiting.isEmpty else { return nil }
        var line = "답을 기다리는 세션 \(waiting.count)개"
        if let oldest = waiting.compactMap(\.lastActivity).min() {
            line += " · 가장 오래 \(silence(now.timeIntervalSince(oldest)))"
        }
        return line
    }

    /// 조용했던 시간: "1분 미만" · "40분" · "3시간" · "2일"
    public static func silence(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        if value < 60 { return "1분 미만" }
        if value < 3_600 { return "\(value / 60)분" }
        if value < 86_400 { return "\(value / 3_600)시간" }
        return "\(value / 86_400)일"
    }

    /// 인계 프롬프트(클립보드에 복사할 요청문). 어떤 터미널에도 보내지 않는다 — 사용자가 직접 붙여 넣는다.
    public static func handoffPrompt(for session: AgentSession) -> String {
        let reason: String
        if let fill = session.contextFill, let used = session.contextTokens, let window = session.contextWindow {
            reason = "이 세션의 컨텍스트가 \(percent(fill)) 찼습니다(\(tokens(used))/\(tokens(window)) 토큰)."
        } else if let used = session.contextTokens {
            reason = "이 세션의 컨텍스트가 \(tokens(used)) 토큰입니다."
        } else {
            reason = "이 세션의 대화가 길어졌습니다."
        }
        return """
        \(reason) 새 세션이 바로 이어받을 수 있도록 지금까지의 작업을 짧은 인계서로 정리해 주세요.

        아래 네 가지만 간결하게 적어 주세요.
        1. 현재 목표 — 무엇을 왜 하고 있는지 한두 줄
        2. 끝낸 일 — 완료하고 확인까지 마친 것
        3. 남은 일 — 다음에 할 순서대로, 막힌 점이 있으면 함께
        4. 핵심 파일 — 경로와 왜 중요한지 한 줄씩

        새 작업은 시작하지 말고 인계서만 작성해 주세요. 마지막 줄에는 "인계서 작성 완료"라고 적어 주세요.
        """
    }
}
