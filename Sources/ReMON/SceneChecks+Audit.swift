import Foundation
import ReMONCore

// 감사 판정 검사(10-25 대표 지적: 150초 고정 한도에 걸려 '판정을 받지 못했습니다' 창이 뜸).
// 규칙 판정은 순수 함수로, 판정 실행(스트림·멈춤·취소·오류)은 가짜 claude 스크립트로 재현한다 — 실제 모델은 부르지 않는다.
// `audit-live`만 로그인된 claude에 가짜 명단 하나를 실제로 물어 걸린 시간을 잰다(all에 넣지 않음).

extension SceneChecks {
    static func auditReportFlow() {
        print("— audit-report: 조치 불가 위험 표시 · 가짜 세션 감사 → 보고서 표시·보존")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remon-audit-report-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = RecoveryVault(folder: folder)
        var working = session(94_001, "가짜 프로젝트", .working, order: 0)
        working.tabState = .closed
        working.stateConfidence = .confirmed
        var waiting = session(94_002, "가짜 프로젝트", .waiting, order: 1)
        waiting.tabState = .closed
        waiting.stateConfidence = .confirmed
        let model = AppModel(vault: vault)
        model.office = OfficeSnapshot(time: Date(), system: SystemSnapshot(), sessions: [working, waiting], apps: [], processCount: 2, unaccountedMemory: 0, standbyClaudeSpares: 0)
        check(model.risks.process == nil && model.processOptimizationCandidates().isEmpty, "일하는 중·입력 대기인 탭 잔재는 최적화 위험 카드에서 제외")
        model.runAudit()
        RunLoop.main.run(until: Date().addingTimeInterval(8))
        let saved = (try? Data(contentsOf: folder.appendingPathComponent("last-audit.json"))).flatMap { try? JSONDecoder().decode(AuditReport.self, from: $0) }
        check(!model.auditRunning && model.auditReportPresented && saved?.summary == "칭찬 1 · 유지 1 · 재교육 0 · 종료 0", "가짜 세션 감사 완료 뒤 보고서 열기·로컬 저장")
        check(AppModel(vault: vault).lastAudit == saved && saved?.details.contains("가짜 프로젝트") == true, "앱 재시작 뒤 마지막 감사 보고서 다시 읽기")
    }

    static func auditRules() {
        print("— audit-rules: 규칙으로 정할 세션은 모델에 묻지 않음")
        func fact(_ id: String, _ state: SessionState, idle: Int, pinned: Bool = false, blockers: [String] = []) -> AuditRunner.Fact {
            AuditRunner.Fact(id: id, project: "P", kind: "Claude Code", role: "", state: state.rawValue, idleMinutes: idle, ageHours: 10, memoryMB: 1536, cpu: 3, children: 0,
                             title: "작업", pinned: pinned, terminal: true, blockers: blockers, warnings: [], confirmed: true)
        }
        let cases: [(AuditRunner.Fact, String?)] = [
            (fact("w", .working, idle: 0), "praise"), (fact("q", .waiting, idle: 9000), "keep"), (fact("p", .longIdle, idle: 900, pinned: true), "keep"),
            (fact("b", .longIdle, idle: 900, blockers: ["Orca 탭 열림"]), "keep"), (fact("o", .orphan, idle: 500), "evict"), (fact("s", .idle, idle: 30), "keep"),
            (fact("l", .longIdle, idle: 420), nil), (fact("i", .idle, idle: 200), nil),
        ]
        let wrong = cases.filter { AuditRunner.localVerdict($0.0)?.verdict != $0.1 }
        check(wrong.isEmpty, "일하는 중=칭찬 · 입력 대기·고정·보호·2시간 미만=유지 · 고아=퇴출 · 2시간 넘게 쉼=모델에 물음" + (wrong.isEmpty ? "" : " · 틀림 \(wrong.map(\.0.id))"))
        check(AuditRunner.localVerdict(fact("q", .waiting, idle: 9000))?.reason.contains("6일") == true, "이유에 수치(입력 대기 6일 · 1.5GB)")
    }

    static func auditRunner() {
        print("— audit-runner: 가짜 claude로 스트림 판정 · 멈춤 · 취소 · 로그인 오류")
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("remon-audit-fake-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func script(_ name: String, _ body: String) -> String {
            let path = folder.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: path, contents: Data(("#!/bin/sh\ncat > /dev/null\n" + body).utf8), attributes: [.posixPermissions: 0o755])
            return path
        }
        let saved = (AuditRunner.claudeCommand, AuditRunner.stallLimit, AuditRunner.totalLimit)
        defer { (AuditRunner.claudeCommand, AuditRunner.stallLimit, AuditRunner.totalLimit) = saved }
        AuditRunner.stallLimit = 3
        AuditRunner.totalLimit = 20

        let tool = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"StructuredOutput","input":{"verdicts":[{"id":"s1","verdict":"evict","reason":"9시간 쉼"},{"id":"s2","verdict":"reeducate","reason":"작업 미완"}]}}]}}"#
        AuditRunner.claudeCommand = script("ok.sh", """
        echo '{"type":"system","subtype":"init"}'
        for i in 1 2 3 4; do echo '{"type":"system","subtype":"thinking_tokens"}'; sleep 1; done
        echo '\(tool)'
        echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.12}'
        """)
        // 4초 동안 생각 신호만 오다가(멈춤 한도 3초보다 길지만 신호가 계속 옴) 답이 온다 → 성공해야 한다.
        let started = Date()
        let ok = AuditRunner.run(prompt: "명단", model: "opus", judging: AuditJudging(asked: 2))
        if case .success(let (response, cost, _)) = ok {
            check(response.verdicts.count == 2 && cost == 0.12, "신호가 이어지는 동안은 기다림 → 판정 2개 · 비용 \(cost ?? -1) · \(String(format: "%.1f", Date().timeIntervalSince(started)))초")
        } else { check(false, "정상 스트림인데 실패: \(ok)") }

        AuditRunner.claudeCommand = script("stall.sh", "echo '{\"type\":\"system\",\"subtype\":\"init\"}'\nexec sleep 67\n")
        let stallStart = Date()
        let stalled = AuditRunner.run(prompt: "명단", model: "opus", judging: AuditJudging(asked: 1))
        let stallSeconds = Date().timeIntervalSince(stallStart)
        if case .failure(let failure) = stalled { check(failure.kind == .stalled && stallSeconds < 8, "응답이 멈추면 한도(3초) 뒤 중단 · \(String(format: "%.1f", stallSeconds))초 · \(failure.message)") }
        else { check(false, "멈춘 스트림이 성공으로 나옴") }
        check(!processAlive(named: "sleep 67", under: folder.path), "멈춘 판정 프로세스가 남지 않음(exec로 셸을 바꿔 끝냄)")

        AuditRunner.claudeCommand = script("slow.sh", "for i in $(seq 1 30); do echo '{\"type\":\"system\",\"subtype\":\"thinking_tokens\"}'; sleep 1; done\n")
        let judging = AuditJudging(asked: 1)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { judging.cancel() }
        let cancelStart = Date()
        let cancelled = AuditRunner.run(prompt: "명단", model: "opus", judging: judging)
        if case .failure(let failure) = cancelled { check(failure.kind == .cancelled && Date().timeIntervalSince(cancelStart) < 5, "취소하면 바로 멈춤(\(String(format: "%.1f", Date().timeIntervalSince(cancelStart)))초)") }
        else { check(false, "취소가 듣지 않음") }

        AuditRunner.claudeCommand = script("login.sh", "echo '{\"type\":\"result\",\"subtype\":\"error\",\"is_error\":true,\"result\":\"Invalid API key · Please run /login\"}'\n")
        if case .failure(let failure) = AuditRunner.run(prompt: "명단", model: "opus", judging: AuditJudging(asked: 1)) { check(failure.kind == .login, "로그인 오류는 '확인할 일'로 구분(\(failure.message))") }
        else { check(false, "로그인 오류가 성공으로 나옴") }

        AuditRunner.claudeCommand = folder.appendingPathComponent("없는-claude").path
        if case .failure(let failure) = AuditRunner.run(prompt: "명단", model: "opus", judging: AuditJudging(asked: 1)) { check(failure.kind == .login || failure.kind == .launch, "claude가 없으면 설치·로그인 안내 대상(\(failure.kind))") }
        else { check(false, "없는 명령이 성공으로 나옴") }
    }

    /// 실제 로그인된 claude에 가짜 명단(오래 쉰 세션 3개)을 물어 시간을 잰다. 비용이 드니 명시적으로만 돈다.
    static func auditLive() {
        print("— audit-live: 실제 \(ProcessInfo.processInfo.environment["REMON_AUDIT_MODEL"] ?? "opus")에 가짜 명단 3개")
        let facts = (1...3).map { i in
            AuditRunner.Fact(id: "s\(i)", project: "SAMPLE\(i)", kind: "Codex", role: "", state: SessionState.longIdle.rawValue, idleMinutes: 300 * i, ageHours: 20, memoryMB: 900 * i,
                             cpu: 0, children: 1, title: ["결제 모듈 리팩터링 중간", "", "README 오타 수정 완료"][i - 1], pinned: false, terminal: i != 3, blockers: [], warnings: [],
                             confirmed: true, lastRequest: ["결제 모듈 리팩터링 마저 해", "아까 그거 정리", "README 오타 고쳐"][i - 1],
                             lastReply: ["절반까지 바꿨습니다. 다음은 환불 경로입니다.", "네.", "오타 3곳을 고쳤습니다. 끝났습니다."][i - 1])
        }
        let system = SystemSnapshot()
        let started = Date()
        let result = AuditRunner.run(prompt: AuditRunner.prompt(facts: facts, system: system), model: ProcessInfo.processInfo.environment["REMON_AUDIT_MODEL"] ?? "opus", judging: AuditJudging(asked: 3))
        switch result {
        case .success(let (response, cost, seconds)):
            check(response.verdicts.count == 3, String(format: "판정 %d개 · %.0f초 · $%.3f · ", response.verdicts.count, seconds, cost ?? -1) + response.verdicts.map { "\($0.id)=\($0.verdict)(\($0.reason))" }.joined(separator: " "))
        case .failure(let failure):
            check(false, String(format: "실패 %.0f초 · ", Date().timeIntervalSince(started)) + failure.message)
        }
    }

    private static func processAlive(named needle: String, under folder: String) -> Bool {
        let result = Shell.capture("/bin/ps", ["-axo", "pid=,ppid=,command="], timeout: 5)
        let hits = result.stdout.split(separator: "\n").filter { $0.contains(needle) && !$0.contains("ps -axo") }
        for hit in hits { print("    남은 프로세스: \(hit)") }
        return !hits.isEmpty
    }

    /// 메모리 최적화가 함께 정리할 '오래 입력 대기' 세션 고르기(확인 창 뒤에만 정리).
    static func longWaitingRule() {
        print("— long-waiting: 6시간 넘게 입력 대기인 세션만 · 보호 제외 · 큰 것부터")
        let now = Date()
        func waiting(_ pid: Int32, hours: Double, mb: UInt64, state: SessionState = .waiting) -> AgentSession {
            var session = SceneChecks.session(pid, "P\(pid)", state, order: 0)
            session.lastActivity = now.addingTimeInterval(-hours * 3600)
            session.footprint = mb << 20
            return session
        }
        let sessions = [waiting(1, hours: 7, mb: 900), waiting(2, hours: 2, mb: 3000), waiting(3, hours: 30, mb: 3500), waiting(4, hours: 50, mb: 800, state: .longIdle), waiting(5, hours: 9, mb: 1200)]
        let picked = AppModel.longWaiting(sessions, now: now) { $0.rootPID == 5 }
        check(picked.map(\.rootPID) == [3, 1], "고른 세션 \(picked.map(\.rootPID)) — 30시간·7시간 대기(큰 것부터) · 2시간 대기 제외 · 오래 쉼(대기 아님) 제외 · 보호 제외")
    }
}
