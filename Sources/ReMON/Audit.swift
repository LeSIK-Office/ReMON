import AppKit
import ReMONCore

/// 자동 정리(감사): 대표님 계정으로 로그인된 Claude Code CLI에 세션 명단을 보내 판정을 받고,
/// 감사관·비서 연출과 함께 실행한다. 종료는 한 번의 확인을 거치고, 재교육은 세션의 터미널(tmux 창 · Orca 탭)에 지시를 보낸다.
struct AuditVerdict: Identifiable, Equatable, Codable {
    enum Kind: String, Codable { case praise, keep, reeducate, evict }
    let id: ProcessKey
    let kind: Kind
    let reason: String
    var note: String? = nil   // 실행 단계에서 붙는 설명(예: 터미널 없음 → 유지)
}

struct AuditReport: Equatable, Codable {
    let time: Date
    let model: String
    let seconds: TimeInterval
    let costUSD: Double?
    var verdicts: [AuditVerdict]
    var summary: String
    var details: String
}

/// 감사 실패 사유(사람이 읽는 한국어). 종류에 따라 안내가 다르다 — 느린 판정에 '터미널에서 확인하라'고 하지 않는다.
struct AuditFailure: Error {
    enum Kind { case launch, login, stalled, timeout, cancelled, format }
    var kind: Kind
    let message: String
}

/// 판정 대기 상태(버튼 표시 · 취소). 읽기 스레드와 화면이 함께 보므로 잠금으로 지킨다.
final class AuditJudging: @unchecked Sendable, Equatable {
    let started = Date()
    let asked: Int
    private let lock = NSLock()
    private var cancelled = false
    init(asked: Int) { self.asked = asked }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    static func == (a: AuditJudging, b: AuditJudging) -> Bool { a === b }
}

enum AuditRunner {
    struct Fact: Codable {
        var id: String
        var project: String
        var kind: String
        var role: String
        var state: String
        var idleMinutes: Int
        var ageHours: Int
        var memoryMB: Int
        var cpu: Int
        var children: Int
        var title: String
        var pinned: Bool
        var terminal: Bool
        var blockers: [String]
        var warnings: [String]
        /// 상태 판정이 직접 증거(레지스트리·기록 시각·커널)에 기댔는가. false면 규칙으로 '유지'.
        var confirmed: Bool
        /// 대화 끝(가려서 한 줄씩): 제목보다 '끝난 일인가'를 더 잘 말해 준다.
        var lastRequest: String?
        var lastReply: String?
    }

    struct Response: Codable {
        struct Item: Codable { var id: String; var verdict: String; var reason: String }
        var verdicts: [Item]
    }

    static let schema = """
    {"type":"object","properties":{"verdicts":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"verdict":{"type":"string","enum":["praise","keep","reeducate","evict"]},"reason":{"type":"string"}},"required":["id","verdict","reason"]}}},"required":["verdicts"]}
    """

    /// 감사실 작업 폴더: 감사 프로세스가 세션으로 잡히면 이 이름의 방에 들어간다(앱은 이 폴더의 세션을 명단에서 뺀다).
    static var workingDirectory: String {
        let path = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()) + "/ReMON/감사실"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    static func prompt(facts: [Fact], system: SystemSnapshot) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(facts)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let pressure = system.pressure.label
        return """
        너는 이 Mac의 'AI 사무실' 감사관이다. 아래는 2시간 넘게 쉬고 있는 AI 에이전트 세션들이다(사람 한 명 = 세션 하나).
        일하는 중·입력 대기·보호 고정·고아 세션은 이미 규칙으로 정했으니, 이 명단만 판정해라. 길게 고민하지 말고 바로 답해라.
        판단 근거는 lastRequest(마지막 사용자 요청)와 lastReply(마지막 답변)다 — 답변이 완료 보고면 끝난 일, 요청이 남아 있는데 답이 중간이면 안 끝난 일. title은 보조.
        시스템: 메모리 압박 \(pressure), 메모리 사용 \(Fmt.gb(system.memory.used)) / \(Fmt.gb(system.memory.physical)), 스왑 \(Fmt.gb(system.swap.used)), 디스크 여유 \(Fmt.gb(system.disk.available)).
        - reeducate: 제목으로 보아 끝나지 않은 일이 있고 terminal이 true면, 터미널에 '상태 보고하고 이어서 끝내라' 지시를 보내 재투입.
        - evict: 오래 쉬고(longIdle) 제목이 비었거나 끝난 일이거나 terminal이 false면 퇴출. 메모리 압박이 '위험'이면 더 과감하게.
        - keep: 판단이 서지 않으면 그대로 둠.
        reason은 한국어 한 줄 14자 안팎, 근거가 되는 수치를 넣어라(예: "9시간 쉼 · 5.3GB").
        \(json)
        """
    }

    @MainActor
    static func facts(sessions: [AgentSession], model: AppModel) -> ([Fact], [String: ProcessKey]) {
        var map: [String: ProcessKey] = [:]
        var facts: [Fact] = []
        for (index, session) in sessions.enumerated() {
            let id = "s\(index + 1)"
            map[id] = session.id
            let plan = model.plan(for: session)
            let idle = session.lastActivity.map { Int(Date().timeIntervalSince($0) / 60) } ?? Int(Date().timeIntervalSince(session.startTime) / 60)
            // 2시간 넘게 쉰 세션만 대화 끝을 읽는다(모델에 물을 후보). 기록 끝 128KB만 본다.
            let exchange = session.logPath.flatMap { path in idle >= 120 && session.state != .working ? TranscriptPeek.lastExchange(path, kind: session.kind) : nil }
            facts.append(Fact(id: id, project: session.project, kind: session.kind.label, role: session.role, state: session.state.rawValue, idleMinutes: idle,
                              ageHours: Int(Date().timeIntervalSince(session.startTime) / 3600), memoryMB: Int(session.footprint / 1_048_576), cpu: Int(session.cpuPercent.rounded()),
                              children: session.childCount, title: String(session.displayTitle.prefix(60)), pinned: model.isPinned(session),
                              terminal: reeducationChannel(session) != nil, blockers: plan.blockers, warnings: plan.warnings,
                              confirmed: session.stateConfidence == .confirmed, lastRequest: exchange?.request, lastReply: exchange?.reply))
        }
        return (facts, map)
    }

    /// 재교육 지시를 보낼 통로(사람이 읽는 이름). tmux 안의 세션은 그 세션이 도는 pane, 아니면 Orca 터미널.
    /// 둘 다 아니면 nil — 아무 창에나 글자를 치지 않는다(Ghostty·터미널 등은 그 세션의 창을 정확히 집어 보낼 방법이 없다).
    static func reeducationChannel(_ session: AgentSession) -> String? {
        if session.terminalHost == "tmux" { return TmuxBridge.executable() != nil ? "tmux 창" : nil }
        if session.orcaHandle != nil, OrcaBridge.executable != nil { return "Orca 터미널" }
        return nil
    }

    /// 판정 대기 한도. Opus는 짧은 판정에도 생각을 길게 한다(10-25 실측: 세션 6개에 출력 7천~1만6천 토큰 · 70~160초,
    /// effort low·MAX_THINKING_TOKENS=0·alwaysThinkingEnabled=false 모두 줄지 않음). 그래서 '응답이 오고 있는 동안'은 기다리고,
    /// 스트림이 2분 넘게 조용할 때만 멈춘 것으로 본다. 전체는 8분까지.
    static var stallLimit: TimeInterval = 120
    static var totalLimit: TimeInterval = 480
    /// 판정 명령(장면 시험이 가짜 claude 스크립트로 바꿔 멈춤·취소·오류를 재현한다).
    static var claudeCommand = "claude"

    /// `claude -p`를 로그인 셸로 띄운다(PATH·node 환경 상속). 도구 없음·세션 저장 없음·MCP 없음·사용자 설정 없음.
    /// `exec`로 셸을 claude로 바꿔, 멈추거나 취소할 때 판정 프로세스가 남아 토큰을 더 쓰지 않게 한다.
    static func run(prompt: String, model: String, judging: AuditJudging) -> Result<(Response, Double?, TimeInterval), AuditFailure> {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let args = [claudeCommand, "-p", "--tools", "", "--no-session-persistence", "--strict-mcp-config", "--setting-sources", "", "--model", model, "--max-turns", "1",
                    "--output-format", "stream-json", "--verbose", "--json-schema", schema]
        let command = "exec " + args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        var environment = ProcessInfo.processInfo.environment
        environment["REMON_AUDIT"] = "1"
        environment["TERM"] = "dumb"
        process.environment = environment
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { return .failure(AuditFailure(kind: .launch, message: "claude를 실행하지 못했습니다: \(error.localizedDescription)")) }
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        // 줄 단위 JSON 사건: 마지막 신호 시각을 갱신하고, 결과(result)와 구조화 출력(StructuredOutput 도구 입력)을 챙긴다.
        let stream = AuditStream()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let handle = output.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    stream.take(buffer[buffer.startIndex..<newline])
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
                stream.touch()
            }
            if !buffer.isEmpty { stream.take(buffer) }
            group.leave()
        }
        var errData = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async { errData = error.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        func stop(_ kind: AuditFailure.Kind, _ message: String) -> Result<(Response, Double?, TimeInterval), AuditFailure> {
            process.terminate()
            _ = group.wait(timeout: .now() + 3)
            return .failure(AuditFailure(kind: kind, message: message))
        }
        while group.wait(timeout: .now() + 1) == .timedOut {
            if judging.isCancelled { return stop(.cancelled, "감사를 취소했습니다") }
            if Date().timeIntervalSince(stream.lastSignal) > stallLimit { return stop(.stalled, "판정 응답이 " + (stallLimit >= 60 ? "\(Int(stallLimit / 60))분" : "\(Int(stallLimit))초") + " 동안 멈췄습니다") }
            if Date().timeIntervalSince(started) > totalLimit { return stop(.timeout, "판정이 \(Int(totalLimit / 60))분 안에 끝나지 않았습니다") }
        }
        process.waitUntilExit()
        guard let root = stream.result else {
            // 셸이 명령을 못 찾음(127)·실행 못 함(126) → 설치·PATH 문제.
            if [126, 127].contains(process.terminationStatus) { return .failure(AuditFailure(kind: .launch, message: "claude 명령을 찾지 못했습니다(설치·PATH 확인)")) }
            let text = String(decoding: errData.prefix(300), as: UTF8.self)
            return .failure(AuditFailure(kind: text.isEmpty ? .login : .format, message: "판정 응답을 읽지 못했습니다 · \(text.isEmpty ? "출력 없음(로그인 상태를 확인하세요)" : text)"))
        }
        if root["is_error"] as? Bool == true {
            let text = String(String(describing: root["result"] ?? root["subtype"] ?? "").prefix(200))
            let login = ["login", "log in", "auth", "API key", "credit", "subscription"].contains { text.localizedCaseInsensitiveContains($0) }
            return .failure(AuditFailure(kind: login ? .login : .format, message: "Claude CLI 오류 · " + text))
        }
        let structured: Any? = root["structured_output"] ?? stream.structured ?? root["result"]
        var data: Data?
        if let dictionary = structured as? [String: Any] { data = try? JSONSerialization.data(withJSONObject: dictionary) }
        else if let text = structured as? String { data = text.data(using: .utf8) }
        guard let data, let response = try? JSONDecoder().decode(Response.self, from: data) else {
            return .failure(AuditFailure(kind: .format, message: "판정 형식이 맞지 않습니다"))
        }
        return .success((response, root["total_cost_usd"] as? Double, Date().timeIntervalSince(started)))
    }

    /// 규칙으로 정해지는 판정은 LLM에 묻지 않는다(빠르고, 반드시 지켜야 할 규칙을 LLM이 어길 일이 없다). 규칙 본문은 ReMONCore.AuditRules(시험과 공유).
    static func localVerdict(_ fact: Fact) -> Response.Item? {
        guard let state = SessionState(rawValue: fact.state) else { return nil }
        return AuditRules.localVerdict(state: state, idleMinutes: fact.idleMinutes, memoryMB: fact.memoryMB, cpu: fact.cpu, pinned: fact.pinned, blockers: fact.blockers, confirmed: fact.confirmed)
            .map { Response.Item(id: fact.id, verdict: $0.verdict, reason: $0.reason) }
    }
}

/// 판정 스트림 읽기 상태(읽기 스레드가 쓰고 기다리는 스레드가 읽는다).
private final class AuditStream: @unchecked Sendable {
    private let lock = NSLock()
    private var signal = Date()
    private var resultRoot: [String: Any]?
    private var toolInput: Any?
    var lastSignal: Date { lock.lock(); defer { lock.unlock() }; return signal }
    var result: [String: Any]? { lock.lock(); defer { lock.unlock() }; return resultRoot }
    var structured: Any? { lock.lock(); defer { lock.unlock() }; return toolInput }
    func touch() { lock.lock(); signal = Date(); lock.unlock() }
    func take(_ line: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        lock.lock(); defer { lock.unlock() }
        signal = Date()
        switch root["type"] as? String {
        case "result": resultRoot = root
        case "assistant":
            let content = (root["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if let tool = content.first(where: { $0["type"] as? String == "tool_use" && $0["name"] as? String == "StructuredOutput" }) { toolInput = tool["input"] }
        default: break
        }
    }
}

extension AppModel {
    /// 감사 시작: 감사관이 들어와 건물을 둘러보는 동안 판정을 받는다. 규칙으로 정해지는 세션(일하는 중·입력 대기·보호·고아·2시간 미만)은
    /// 바로 정하고, 제목을 읽어야 하는 '2시간 넘게 쉰 세션'만 로그인된 Claude(설정 모델)에 묻는다. 판정 → 확인 창 → 실행.
    func runAudit() {
        guard !auditRunning else { return }
        guard let office else { Confirm.info(title: "아직 세션을 읽지 못했습니다", text: "잠시 뒤 다시 시도해 주세요."); return }
        let targets = office.sessions.filter { $0.cwd?.hasSuffix("/ReMON/감사실") != true }
        guard !targets.isEmpty else { Confirm.info(title: "감사할 세션이 없습니다", text: "지금 실행 중인 AI 에이전트 세션이 없습니다."); return }
        auditRunning = true
        auditReportPresented = false
        page = .office
        scene?.auditorEnter()
        let (facts, map) = AuditRunner.facts(sessions: targets, model: self)
        let local = facts.compactMap(AuditRunner.localVerdict)
        let pending = facts.filter { fact in !local.contains { $0.id == fact.id } }
        let modelName = settings.auditModel
        append(.info, "감사 시작 · 세션 \(targets.count)개 · 규칙 판정 \(local.count)개 · " + (pending.isEmpty ? "모델에 물을 세션 없음" : "\(modelName) 판정 \(pending.count)개"))
        let judging = AuditJudging(asked: pending.count)
        auditJudging = judging
        let prompt = AuditRunner.prompt(facts: pending, system: system)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<(AuditRunner.Response, Double?, TimeInterval), AuditFailure>
            if pending.isEmpty {
                // 물을 것이 없으면 감사관이 한 바퀴 둘러볼 시간만 두고 판정한다.
                Thread.sleep(forTimeInterval: 6)
                result = judging.isCancelled ? .failure(AuditFailure(kind: .cancelled, message: "감사를 취소했습니다")) : .success((AuditRunner.Response(verdicts: []), nil, 0))
            } else {
                result = AuditRunner.run(prompt: prompt, model: modelName, judging: judging)
            }
            DispatchQueue.main.async { self?.finishAudit(result, local: local, pending: pending, map: map, targets: targets, model: modelName) }
        }
    }

    /// 판정을 기다리는 중에만 취소한다(조치가 시작된 뒤에는 취소하지 않는다). 판정 프로세스도 함께 끝낸다.
    func cancelAudit() { auditJudging?.cancel() }

    private func saveAuditReport(_ report: AuditReport) {
        lastAudit = report
        do {
            try JSONEncoder().encode(report).write(to: vault.folder.appendingPathComponent("last-audit.json"), options: .atomic)
        } catch {
            append(.alert, "감사 보고서 저장 실패 · \(error.localizedDescription)")
        }
    }

    private func finishAudit(_ result: Result<(AuditRunner.Response, Double?, TimeInterval), AuditFailure>, local: [AuditRunner.Response.Item], pending: [AuditRunner.Fact],
                             map: [String: ProcessKey], targets: [AgentSession], model: String) {
        auditJudging = nil
        var items = local
        var cost: Double?
        var seconds: TimeInterval = 0
        var skipped: String?
        switch result {
        case .failure(let failure):
            if failure.kind == .cancelled {
                auditRunning = false
                append(.info, "감사 취소")
                scene?.auditorLeave(line: "다음에 다시 오지")
                return
            }
            append(.alert, "감사 판정 실패 · \(failure.message)" + (pending.isEmpty ? "" : " · 오래 쉰 \(pending.count)개는 이번에 유지"))
            // 로그인·설치 문제만 대표님이 직접 확인할 일이다. 느린 판정은 기록과 감사관 대사로 알린다(창으로 막지 않음).
            if failure.kind == .launch || failure.kind == .login {
                Confirm.info(title: "감사 판정을 받지 못했습니다", text: failure.message + "\n\n터미널에서 `claude -p \"hi\"`가 되는지(설치·로그인) 확인해 주세요.")
            }
            skipped = failure.message
            items += pending.map { AuditRunner.Response.Item(id: $0.id, verdict: AuditVerdict.Kind.keep.rawValue, reason: "판정 못 받음 · 이번엔 유지") }
            guard local.contains(where: { $0.verdict != AuditVerdict.Kind.keep.rawValue }) else {
                auditRunning = false
                saveAuditReport(AuditReport(time: Date(), model: model, seconds: seconds, costUSD: nil, verdicts: [], summary: "감사 실패", details: failure.message))
                auditReportPresented = true
                scene?.auditorLeave(line: "판정이 늦어 오늘은 봐준다")
                return
            }
        case .success(let (response, answerCost, answerSeconds)):
            // 물어본 세션의 답만 받는다. 답이 빠진 세션은 유지.
            let answered = response.verdicts.filter { item in pending.contains { $0.id == item.id } }
            items += answered
            items += pending.filter { fact in !answered.contains { $0.id == fact.id } }.map { AuditRunner.Response.Item(id: $0.id, verdict: AuditVerdict.Kind.keep.rawValue, reason: "판정 없음 · 유지") }
            cost = answerCost
            seconds = answerSeconds
        }
        var verdicts: [AuditVerdict] = []
        for item in items {
            guard let key = map[item.id], let session = targets.first(where: { $0.id == key }), let kind = AuditVerdict.Kind(rawValue: item.verdict) else { continue }
            var verdict = AuditVerdict(id: key, kind: kind, reason: item.reason)
            // 안전망: 판정이 무엇이든 보호 대상·입력 대기는 유지한다.
            let plan = plan(for: session)
            if kind == .evict, !plan.blockers.isEmpty { verdict = AuditVerdict(id: key, kind: .keep, reason: item.reason, note: "보호 대상 · " + plan.blockers[0]) }
            if kind == .evict, session.state == .waiting { verdict = AuditVerdict(id: key, kind: .keep, reason: item.reason, note: "입력 대기 중") }
            if kind == .reeducate, AuditRunner.reeducationChannel(session) == nil { verdict = AuditVerdict(id: key, kind: .keep, reason: item.reason, note: "지시를 보낼 터미널이 없음") }
            // 퇴출은 오래 쉰·고아 세션만(LLM 판정이 틀려도 일하는 세션을 끊지 않게).
            if verdict.kind == .evict, session.state != .longIdle, session.state != .orphan { verdict = AuditVerdict(id: key, kind: .keep, reason: item.reason, note: "\(session.state.label) 상태라 퇴출하지 않음") }
            // 퇴출은 되돌릴 수 있을 때만: 복구 키가 없으면 유지.
            if verdict.kind == .evict, !recoveryKey(for: session).allowsAutoCleanup { verdict = AuditVerdict(id: key, kind: .keep, reason: item.reason, note: "복구 키 없음 · " + recoveryKey(for: session).label) }
            verdicts.append(verdict)
        }
        let evicts = verdicts.filter { $0.kind == .evict }
        let reeducates = verdicts.filter { $0.kind == .reeducate }
        let praises = verdicts.filter { $0.kind == .praise }
        let keeps = verdicts.filter { $0.kind == .keep }
        let summary = "칭찬 \(praises.count) · 유지 \(keeps.count) · 재교육 \(reeducates.count) · 종료 \(evicts.count)"
        append(.info, "감사 판정 · \(summary)" + (pending.isEmpty ? " · 규칙으로 모두 판정" : skipped == nil ? " · \(model) \(String(format: "%.0f", seconds))초" : " · 모델 판정 없이") + (cost.map { String(format: " · $%.3f", $0) } ?? ""))
        func line(_ verdict: AuditVerdict) -> String {
            let session = targets.first { $0.id == verdict.id }
            return "• \(session?.project ?? "?") · \(session?.kind.shortLabel ?? "") #\(session?.rootPID ?? 0) · \(session.map { Fmt.size($0.footprint) } ?? "") — \(verdict.reason)" + (verdict.note.map { " (\($0))" } ?? "")
        }
        var text = ""
        if !evicts.isEmpty { text += "종료(퇴출) \(evicts.count)개:\n" + evicts.map(line).joined(separator: "\n") + "\n\n" }
        if !reeducates.isEmpty { text += "재교육(터미널에 지시) \(reeducates.count)개:\n" + reeducates.map(line).joined(separator: "\n") + "\n\n" }
        if !praises.isEmpty { text += "칭찬 \(praises.count)개: " + praises.compactMap { v in targets.first { $0.id == v.id }?.project }.joined(separator: ", ") + "\n" }
        if !keeps.isEmpty { text += "유지 \(keeps.count)개: " + keeps.compactMap { v in targets.first { $0.id == v.id }?.project }.joined(separator: ", ") + "\n" }
        let details = [("종료", evicts), ("재교육", reeducates), ("칭찬", praises), ("유지", keeps)]
            .flatMap { label, group in group.map { "\(label) " + line($0) } }
            .joined(separator: "\n")
        let channels = Set(reeducates.compactMap { v in targets.first { $0.id == v.id }.flatMap(AuditRunner.reeducationChannel) }).sorted()
        text += "\n종료는 복구 키를 금고에 먼저 적고 SIGTERM → 5초 → 남은 하위만 재확인합니다(정신교육실에서 복귀 가능). 재교육은 \(channels.isEmpty ? "세션이 도는 Orca 터미널·tmux 창" : channels.joined(separator: "·"))에 아래 지시를 보냅니다:\n“\(settings.reeducationMessage)”"
        if let skipped { text += "\n\n모델 판정 실패(\(skipped)) — 2시간 넘게 쉰 세션은 이번에 유지합니다." }
        if settings.dryRun { text += "\n\n드라이런: 실제로 종료·전송하지 않습니다." }
        guard evicts.isEmpty && reeducates.isEmpty || Confirm.ask(title: "감사 결과 · \(summary)", text: text, action: settings.dryRun ? "드라이런" : "실행", destructive: !evicts.isEmpty) else {
            auditRunning = false
            append(.info, "감사 취소")
            scene?.auditorLeave(line: "오늘은 봐준다")
            return
        }
        let report = AuditReport(time: Date(), model: model, seconds: seconds, costUSD: cost, verdicts: verdicts, summary: summary, details: details)
        saveAuditReport(report)
        executeAudit(verdicts, targets: targets)
    }

    /// 판정 실행: 감사관이 강당을 급습 → 재교육 대상은 정신교육실에 모아 강사 수업, 끝 "지시 보냅니다!" 순간에 실제 지시 전송 →
    /// 퇴출 대상은 강당 단상 앞에 모아 이름(사유)을 부르는 순간 실제 정리(경비원이 끌고 나감) → 칭찬(짧게) → 퇴장.
    /// 실제 조치는 장부(AuditLedger)가 판정마다 정확히 한 번 한다: 연출이 그 순간에 부르고, 창이 닫히거나 오래 멈추거나 시한이 넘으면 감시가 연출 없이 남은 것을 한다.
    private func executeAudit(_ verdicts: [AuditVerdict], targets: [AgentSession]) {
        let byKey = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        let reeducates = verdicts.filter { $0.kind == .reeducate && byKey[$0.id] != nil }
        let evicts = verdicts.filter { $0.kind == .evict && byKey[$0.id] != nil }
        let praises = verdicts.filter { $0.kind == .praise && byKey[$0.id] != nil }.prefix(5)
        let dryRun = settings.dryRun
        let ledger = AuditLedger(
            reeducate: reeducates.map(\.id), evict: evicts.map(\.id),
            send: { [weak self] key in
                guard let self, let session = byKey[key] else { return }
                self.sendReeducation(session)
            },
            terminate: { [weak self] key in
                guard let self, let session = byKey[key] else { return }
                self.executeTermination(self.plan(for: session), force: false, reason: "감사 퇴출", requireKey: true)
            },
            finished: { [weak self] in
                guard let self else { return }
                self.auditRunning = false
                self.auditReportPresented = true
                self.monitor.refreshNow()
            })
        guard let scene else {
            // 창이 닫혀 있으면 연출 없이 조치만
            ledger.flush()
            return
        }
        let call = { (verdict: AuditVerdict) in OfficeScene.AuditCall(key: verdict.id, reason: verdict.reason) }
        scene.auditorExecute(
            reeducate: reeducates.map(call), evict: evicts.map(call), praise: praises.map(call),
            onReeducate: { [weak self] key in
                ledger.reeducate(key)
                return !dryRun && (self?.reeducationDeliverable(byKey[key]) ?? false)
            },
            onEvict: { [weak self] key in
                // 연출 판단(실제 판단은 executeTermination이 같은 기준으로 다시 한다): 판단은 정리 호출 전에 — 호출 뒤에는 '정리 중'이 섞인다.
                let animate = !dryRun && (self?.auditStillEvictable(byKey[key]) ?? false)
                ledger.evict(key)
                return animate
            },
            onFinish: { ledger.finish() })
        // 감시: 창을 닫으면(장면 사라짐) 바로, 20초 넘게 멈추거나 시한(보통 90초 연출 + 여유)이 넘으면 남은 조치를 연출 없이 하고 감사관을 내보낸다.
        let limit = 150 + 8 * Double(max(0, reeducates.count + evicts.count - 10))
        ledger.watch(limit: limit, scene: { [weak self, weak scene] in
            guard let self, let scene, self.scene === scene else { return .gone }
            return scene.view?.isPaused == false ? .running : .paused
        }, onTimeout: { [weak self] in
            self?.scene?.auditorLeave(line: "남은 건 기록만 합니다")
        })
    }

    /// 재교육 지시를 실제로 보낼 수 있는가(sendReeducation과 같은 조건: tmux 안의 세션 + tmux, 또는 Orca 터미널 핸들 + orca 실행 파일).
    private func reeducationDeliverable(_ session: AgentSession?) -> Bool {
        session.flatMap(AuditRunner.reeducationChannel) != nil
    }

    /// 퇴출 연출을 할지: 세션이 아직 있고, 결정 뒤 일을 시작하지 않았고, 새 활동이 없다(execute의 정리 전 확인과 같은 기준).
    /// 아니면 정리가 취소될 것이므로 끌려 나가는 장면 대신 놓아준다(끌려 나간 직원이 다시 나타나는 일 방지).
    private func auditStillEvictable(_ session: AgentSession?) -> Bool {
        guard let session, let current = office?.sessions.first(where: { $0.id == session.id }) else { return false }
        if (current.state == .working || current.state == .waiting) && current.state != session.state { return false }
        if let now = current.lastActivity, now > (session.lastActivity ?? .distantPast).addingTimeInterval(1) { return false }
        return true
    }

    /// 재교육 = 세션의 터미널에 지시 한 줄(tmux 안이면 그 pane, 아니면 Orca 터미널). 세션이 응답해 일하기 시작하면 상태가 바뀌어 교육실에서 자리로 돌아간다.
    private func sendReeducation(_ session: AgentSession) {
        let message = settings.reeducationMessage
        let target = "\(session.kind.label) \(session.project) pid \(session.rootPID)"
        if settings.dryRun { append(.info, "드라이런 · 재교육 지시 생략 · \(session.project)"); return }
        // tmux 안의 세션은 Orca보다 먼저 본다 — tmux 안에서는 Orca 탭이 다른 pane을 보여 주고 있을 수 있다. 보내기 직전 다시 확인하고, 어긋나면 보내지 않는다.
        if session.terminalHost == "tmux" {
            DispatchQueue.global().async { [weak self] in
                let result = TmuxBridge.sendLine(message, sessionRoot: session.rootPID, start: session.id.start)
                AuditLog.shared.write(action: "session.reeducate", target: target, result: result.ok ? "sent" : "failed: " + result.message, dryRun: false,
                                      detail: ["terminal": "tmux", "message": message, "outcome": result.message])
                DispatchQueue.main.async {
                    self?.append(result.ok ? .cleanup : .alert, (result.ok ? "재교육 지시 전송 · " : "재교육 지시 실패 · ") + session.project + " · " + result.message)
                }
            }
            return
        }
        guard let handle = session.orcaHandle, let orca = OrcaBridge.executable else {
            AuditLog.shared.write(action: "session.reeducate", target: target, result: "skipped: " + TmuxBridge.noTerminalMessage, dryRun: false)
            append(.alert, "재교육 지시 실패 · \(session.project) · \(TmuxBridge.noTerminalMessage)")
            return
        }
        AuditLog.shared.write(action: "session.reeducate", target: target, result: "sent", dryRun: false, detail: ["terminal": handle, "message": message])
        DispatchQueue.global().async { [weak self] in
            let result = Shell.capture(orca, ["terminal", "send", "--terminal", handle, "--text", message, "--enter", "--json"], timeout: 15)
            DispatchQueue.main.async {
                self?.append(result.status == 0 ? .cleanup : .alert, (result.status == 0 ? "재교육 지시 전송 · " : "재교육 지시 실패 · ") + session.project)
            }
        }
    }
}

/// 감사 실행 장부: 판정마다 실제 조치(재교육 지시 · 퇴출 정리)를 정확히 한 번만 한다.
/// 연출이 그 순간에 부르고(reeducate · evict), 연출이 끊기면(창 닫힘 · 오래 멈춤 · 시한 초과) 감시가 남은 것을 연출 없이 몰아서 한다(flush). 둘이 겹쳐도 한 번.
@MainActor
final class AuditLedger {
    enum SceneState { case running, paused, gone }
    /// 장면이 이만큼 계속 멈춰 있으면(창 최소화 · 다른 화면) 남은 조치를 연출 없이 한다.
    static let pauseLimit: TimeInterval = 20

    private var pendingReeducate: [ProcessKey]
    private var pendingEvict: [ProcessKey]
    private let send: (ProcessKey) -> Void
    private let terminate: (ProcessKey) -> Void
    private let finished: () -> Void
    private(set) var isFinished = false
    /// 검수용: 실제로 한 조치 순서(종류 · 세션) · 감시가 연출 없이 몰아서 했는가.
    private(set) var log: [(kind: AuditVerdict.Kind, key: ProcessKey)] = []
    private(set) var flushedByWatch = false
    private var started = Date()
    private var limit: TimeInterval = .infinity
    private var pausedSince: Date?
    private var sceneState: (() -> SceneState)?
    private var onTimeout: (() -> Void)?

    init(reeducate: [ProcessKey], evict: [ProcessKey], send: @escaping (ProcessKey) -> Void, terminate: @escaping (ProcessKey) -> Void, finished: @escaping () -> Void) {
        pendingReeducate = reeducate
        pendingEvict = evict
        self.send = send
        self.terminate = terminate
        self.finished = finished
    }

    /// 재교육 지시(수업 끝 순간). 이미 했거나 대상이 아니면 아무것도 하지 않는다.
    func reeducate(_ key: ProcessKey) {
        guard let index = pendingReeducate.firstIndex(of: key) else { return }
        pendingReeducate.remove(at: index)
        log.append((.reeducate, key))
        send(key)
    }

    /// 퇴출 정리(이름을 부르는 순간). 이미 했거나 대상이 아니면 아무것도 하지 않는다.
    func evict(_ key: ProcessKey) {
        guard let index = pendingEvict.firstIndex(of: key) else { return }
        pendingEvict.remove(at: index)
        log.append((.evict, key))
        terminate(key)
    }

    /// 연출 없이 남은 조치를 모두 하고 마친다(창이 닫혀 있을 때 · 감시).
    func flush() {
        for key in pendingReeducate { reeducate(key) }
        for key in pendingEvict { evict(key) }
        finish()
    }

    /// 연출이 끝났을 때(또는 감시가 끝낼 때): 혹시 남은 조치가 있으면 하고, 한 번만 마친다.
    func finish() {
        guard !isFinished else { return }
        for key in pendingReeducate { reeducate(key) }
        for key in pendingEvict { evict(key) }
        isFinished = true
        finished()
    }

    /// 감시 시작: 1초마다 장면 상태를 본다(끝날 때까지 장부를 붙잡아 둔다 — 장면이 사라져도 조치는 남지 않게).
    func watch(limit: TimeInterval, scene: @escaping () -> SceneState, onTimeout: @escaping () -> Void) {
        started = Date()
        self.limit = limit
        sceneState = scene
        self.onTimeout = onTimeout
        scheduleWatch()
    }

    private func scheduleWatch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !self.isFinished, let state = self.sceneState?() else { return }
            if !self.check(now: Date(), scene: state) { self.scheduleWatch() }
        }
    }

    /// 감시 한 번(타이머가 1초마다 부른다 — 장면 시험은 시각을 넣어 직접 부른다). 끝났으면 true.
    /// 장면이 사라지면(창 닫힘) 바로, 계속 멈춘 지 20초 · 시작부터 limit초가 지나면 남은 조치를 연출 없이 하고 onTimeout(감사관 퇴장).
    @discardableResult
    func check(now: Date, scene: SceneState) -> Bool {
        guard !isFinished else { return true }
        switch scene {
        case .gone:
            flushedByWatch = !pendingReeducate.isEmpty || !pendingEvict.isEmpty
            flush()
            return true
        case .paused:
            if pausedSince == nil { pausedSince = now }
        case .running:
            pausedSince = nil
        }
        let stalled = pausedSince.map { now.timeIntervalSince($0) >= Self.pauseLimit } ?? false
        guard stalled || now.timeIntervalSince(started) >= limit else { return false }
        flushedByWatch = !pendingReeducate.isEmpty || !pendingEvict.isEmpty
        flush()
        onTimeout?()
        return true
    }

    /// 장면 시험용: 감시 기준 시각을 정한다(가짜 시계).
    func startClock(at date: Date, limit: TimeInterval) {
        started = date
        self.limit = limit
    }
}
