import Foundation
import ReMONCore

// 대사 생성기 검사: 모든 상황 줄이 실제 값(프로젝트·제목·시간·%·건수)을 담는다(10-25 대표 요청 "일·진행 상황도 말해라").
extension SceneChecks {
    static func speech() {
        print("— speech: 사장·직원·로봇·스태프 대사가 실제 값에서 나오는지")
        let now = Date()
        var working = session(401, "STOREARC", .working, order: 0)
        working.title = "DWG 매장 인테리어 CAD 변환"
        working.contextTokens = 444_000; working.contextWindow = 475_000
        var waiting = session(402, "COOKSUP_SYSTEM", .waiting, order: 1)
        waiting.lastActivity = now.addingTimeInterval(-7 * 3600)
        waiting.title = "인계서 읽고 온톨로지 코어"
        var idle = session(403, "LeCIE", .longIdle, order: 2)
        idle.lastActivity = now.addingTimeInterval(-5 * 3600)
        var context = SpeechContext()
        context.sessions = [working, waiting, idle]
        context.now = now
        context.recentGit = [GitEvent(project: "STOREARC", repo: "/r", kind: .commit, label: "결제 모듈 리팩터링", time: now.addingTimeInterval(-600)),
                             GitEvent(project: "STOREARC", repo: "/r", kind: .deploy, label: "origin/main", time: now.addingTimeInterval(-120))]
        context.vault = VaultCounts(sessions: 2, files: 3, git: 1, processes: 1, expired: 4, bytes: 1 << 30)
        context.auditSummary = "칭찬 3 · 유지 6 · 재교육 0 · 종료 0"; context.auditTime = now.addingTimeInterval(-900)
        context.retired = 2
        let boss = Speech.boss(context, mood: "calm")
        check(boss.contains { $0.contains("STOREARC 배포") } && boss.contains { $0.contains("7시간") && $0.contains("COOKSUP_SYSTEM") }, "사장: 배포·기다린 시간(7시간)·프로젝트 이름이 들어감")
        check(boss.contains { $0.contains("DWG 매장") } && boss.contains { $0.contains("93%") }, "사장: 하는 일 제목·컨텍스트 93%")
        check(boss.contains { $0.contains("정신교육실에 2명") } && boss.contains { $0.contains("감사 결과 칭찬 3") } && boss.contains { $0.contains("휴지통행 3건") }, "사장: 정신교육실·감사 결과·금고")
        let panic = Speech.boss(context, mood: "panic")
        check(panic.contains { $0.contains("으아아 메모리") } && panic.contains { $0.contains("배포") }, "사장(패닉): 메모리 줄과 진행 상황 줄이 섞임")
        let w1 = Speech.worker(working, context)
        check(w1.contains { $0.contains("DWG 매장") } && w1.contains { $0.contains("93%") } && w1.contains { $0.contains("배포 끝") }, "직원(일하는 중): 제목·컨텍스트·방금 배포")
        let w2 = Speech.worker(waiting, context)
        check(w2.contains { $0.contains("7시간") } && w2.contains { $0.contains("잊으셨죠") }, "직원(입력 대기 7시간): 기다린 시간 · 6시간 넘으면 '잊으셨죠'")
        let w3 = Speech.worker(idle, context)
        check(w3.contains { $0.contains("5시간") }, "직원(오래 쉼): 쉰 시간")
        let robot = Speech.subagent(SubagentInfo(id: "r1", label: "검토", model: nil, kind: .workflow, workflow: "review", phase: "Verify", lastActivity: now, active: true, stale: true), owner: working, context)
        check(robot.contains { $0.contains("Verify") } && robot.contains { $0.contains("20분째 멈춤") }, "로봇: 단계 이름 · 멈춤")
        let janitor = Speech.janitor(project: "STOREARC", items: 2, bytes: 600 << 20, papers: 5)
        check(janitor.contains { $0.contains("부산물 2개") } && janitor.contains { $0.contains("서류 5장") }, "청소부: 치운 수 · 서류")
        let archivist = Speech.archivist(context.vault)
        check(archivist.contains { $0.contains("세션 2개") } && archivist.contains { $0.contains("만료 4건") }, "기록관: 금고 건수")
    }
}
