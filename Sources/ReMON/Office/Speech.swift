import Foundation
import ReMONCore

// 대사 생성(10-25 대표 요청: "소리만 지르지 말고 일·진행 상황 얘기도 해라 — 전체 코멘트를 풍부하게").
// 모든 줄은 실제 값에서 나온다(프로젝트·제목·기다린 시간·컨텍스트 %·커밋/푸시/배포·금고 수). 상황이 없을 때만 일반 대사.
// 장면은 여기서 받은 후보 중 하나를 Variety로 고른다(씨앗을 주면 재현된다).

struct SpeechContext {
    var sessions: [AgentSession] = []
    var system = SystemSnapshot()
    /// 최근 1시간의 git 사건(커밋·푸시·배포), 오래된 것부터.
    var recentGit: [GitEvent] = []
    var vault = VaultCounts()
    /// 마지막 감사 요약("칭찬 3 · 유지 6 · 재교육 0 · 종료 0")과 시각.
    var auditSummary: String?
    var auditTime: Date?
    /// 정신교육실 인원(복귀 대기).
    var retired = 0
    var now = Date()

    func silence(_ session: AgentSession) -> TimeInterval { now.timeIntervalSince(session.lastActivity ?? session.startTime) }
    var waiting: [AgentSession] { sessions.filter { $0.state == .waiting }.sorted { silence($0) > silence($1) } }
    var working: [AgentSession] { sessions.filter { $0.state == .working } }
    var longIdle: [AgentSession] { sessions.filter { $0.state == .longIdle || $0.state == .orphan } }
    var highContext: [AgentSession] { sessions.filter { ($0.contextFill ?? 0) >= 0.7 }.sorted { ($0.contextFill ?? 0) > ($1.contextFill ?? 0) } }
    func recentGit(for project: String, within seconds: TimeInterval) -> GitEvent? {
        recentGit.last { $0.project == project && now.timeIntervalSince($0.time) <= seconds }
    }
}

enum Speech {
    /// 짧은 제목(말풍선용).
    static func short(_ text: String, _ limit: Int = 14) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
    }

    static func percent(_ fill: Double?) -> String? { fill.map { "\(Int(($0 * 100).rounded()))%" } }

    // MARK: 사장

    /// 사장 대사 후보. 기분(mood)은 장면의 메모리 판단(panic·anxious·calm·elated)이고, 거기에 일·진행 상황 줄을 섞는다.
    static func boss(_ context: SpeechContext, mood: String) -> [String] {
        var lines: [String] = []
        // 1) 진행 상황: 배포·푸시·커밋
        if let deploy = context.recentGit.last(where: { $0.kind == .deploy }) {
            lines += ["\(deploy.project) 배포 나갔지? 수고했어", "\(deploy.label) 배포 확인했어", "배포했으면 서류 정리도 해"]
        }
        let pushes = context.recentGit.filter { $0.kind == .push }.count
        let commits = context.recentGit.filter { $0.kind == .commit }.count
        if pushes > 0 { lines.append("한 시간에 푸시 \(pushes)번, 좋아") }
        if commits > 0, let last = context.recentGit.last(where: { $0.kind == .commit }) { lines += ["\(last.project) 커밋 \(commits)개째네", "'\(short(last.label, 12))' 커밋 봤어"] }
        // 2) 기다리는 세션 = 내 답이 자원
        let waiting = context.waiting
        if let first = waiting.first {
            let wait = Fmt.duration(context.silence(first))
            lines += ["\(waiting.count)명이 내 답 기다리네… \(first.project)부터", "\(first.project) \(wait)째 기다리게 했네", "답장할 게 \(waiting.count)개"]
        }
        // 3) 일하는 세션의 실제 제목
        for session in context.working.prefix(3) where session.title != nil {
            lines.append("\(session.project)은 '\(short(session.displayTitle))' 하는 중이지?")
            if session.activeSubagents > 0 { lines.append("\(session.project) 하위 \(session.activeSubagents)명 돌리네, 토큰 값…") }
        }
        // 4) 컨텍스트가 큰 세션 → 인계
        if let big = context.highContext.first, let pct = percent(big.contextFill) {
            lines += ["\(big.project) \(big.kind.shortLabel) 컨텍스트 \(pct)… 인계 준비해", "\(big.project) 대화가 너무 길어, 새 세션으로 넘겨"]
        }
        // 5) 노는 세션·정신교육실·금고
        let idle = context.longIdle.count
        if idle > 0 { lines += ["강당에 \(idle)명 놀고 있어", "오래 쉬는 애들 \(idle)명, 정리할까 말까"] }
        if context.retired > 0 { lines.append("정신교육실에 \(context.retired)명 있어, 필요하면 복귀시켜") }
        if context.vault.files > 0 { lines.append("금고에 휴지통행 \(context.vault.files)건, 되돌릴 거 있나") }
        // 6) 감사 결과
        if let summary = context.auditSummary, let time = context.auditTime, context.now.timeIntervalSince(time) < 3 * 3600 {
            lines.append("감사 결과 \(summary)")
        }
        // 7) 기분 줄(메모리) — 상황 줄과 섞는다
        switch mood {
        case "panic":
            lines += ["으아아 메모리!", "스왑 \(Fmt.gb(context.system.swap.used)) 실화냐", "감사 불러! 당장!"]
            if let big = context.working.max(by: { $0.footprint < $1.footprint }) { lines.append("\(big.project)가 \(Fmt.gb(big.footprint)) 먹고 있어") }
        case "anxious":
            lines += ["메모리 왜 이래", "토큰 값…", "잠깐 뭐였더라"]
        case "elated":
            lines += ["오 잘 돌아간다!", "다들 일 잘하네", "이 맛에 사장 한다"]
            if !context.working.isEmpty { lines.append("\(context.working.count)명이 동시에 일하네") }
        default:
            lines += ["흠…", "커피 어디 갔지", "다음 뭐 시키지"]
            if context.recentGit.isEmpty && context.waiting.isEmpty { lines.append("오늘 커밋이 없네") }
        }
        return lines
    }

    // MARK: 직원(세션)

    /// 직원 대사 후보: 자기 세션의 실제 상태로 말한다.
    static func worker(_ session: AgentSession, _ context: SpeechContext) -> [String] {
        var lines: [String] = []
        if let event = context.recentGit(for: session.project, within: 300) {
            switch event.kind {
            case .deploy: lines += ["배포 끝!", "\(event.label) 나갔어요!", "서류 정리해야 하는데"]
            case .push: lines += ["푸시했어요", "\(event.label)로 올렸습니다"]
            case .commit: lines += ["커밋 하나 올렸어요", "'\(short(event.label, 10))' 커밋"]
            }
        }
        if let pct = percent(session.contextFill), (session.contextFill ?? 0) >= 0.7 {
            lines += ["컨텍스트 \(pct)… 인계서 쓸까요?", "대화가 \(pct) 찼어요", "새 세션으로 넘길 때 됐어요"]
        }
        switch session.state {
        case .working:
            if session.title != nil { lines += ["'\(short(session.displayTitle))' 진행 중", "지금 '\(short(session.displayTitle, 10))' 하는 중이에요"] }
            if session.activeSubagents > 0 { lines.append("하위 \(session.activeSubagents)명이랑 같이 해요") }
            if let phase = session.subagents.first(where: { $0.active && $0.kind == .workflow })?.phase { lines.append("워크플로 \(short(phase, 10)) 단계") }
            if session.footprint >= 3 << 30 { lines.append("\(Fmt.gb(session.footprint)) 쓰는 중… 미안해요") }
            lines += Lines.praiseWorking
        case .waiting:
            let wait = Fmt.duration(context.silence(session))
            lines += ["사장님 답 기다리는 중 · \(wait)", "입력 필요해요!", "다음 지시요?"]
            if session.title != nil { lines.append("'\(short(session.displayTitle, 10))' 어떻게 할까요?") }
            if context.silence(session) >= 6 * 3600 { lines.append("\(wait)째 기다려요… 잊으셨죠?") }
        case .idle:
            lines += ["방금 끝냈어요, 다음은요?", "잠깐 쉬는 중"] + Lines.idleFun
        case .longIdle:
            let idle = Fmt.duration(context.silence(session))
            lines += ["\(idle)째 지시가 없어요", "메모리 \(Fmt.gb(session.footprint)) 붙들고 있네요"]
            if session.resumeKeyVerified { lines.append("정리해도 돼요, 복구 키 있어요") }
            lines += Lines.hallSad
        case .orphan:
            lines += ["터미널이 사라졌어요", "탭이 닫혔는데 저는 남았어요"] + Lines.orphanLines
        }
        return lines
    }

    /// 하위 에이전트(로봇) 대사 후보.
    static func subagent(_ info: SubagentInfo, owner: AgentSession, _ context: SpeechContext) -> [String] {
        var lines: [String] = []
        if let phase = info.phase { lines += ["\(short(phase, 12)) 단계", "지금 \(short(phase, 10)) 중"] }
        if info.stale { lines += ["20분째 멈춤…", "주인이 안 불러요"] }
        if info.active { lines += ["\(owner.project) 일 거드는 중", "삐빅 · 작업 중"] } else { lines += ["대기 중", "다음 호출 기다려요"] }
        return lines
    }

    // MARK: 스태프

    static func trainer(_ context: SpeechContext) -> [String] {
        var lines = Lines.trainerEnter
        let waiting = context.waiting.count
        if waiting > 0 { lines.append("입력 대기 \(waiting)명… 사장님 답이 자원이에요") }
        if let big = context.highContext.first, let pct = percent(big.contextFill) { lines.append("\(big.project) 컨텍스트 \(pct), 인계가 다이어트!") }
        if context.system.swap.used >= 8 << 30 { lines.append("스왑 \(Fmt.gb(context.system.swap.used)), 쓰던 앱이 끝나야 줄어요") }
        return lines
    }

    static func janitor(project: String?, items: Int, bytes: UInt64, papers: Int) -> [String] {
        var lines = Lines.janitorEnter
        if let project {
            if items > 0 { lines.append("\(project) 부산물 \(items)개 치웠어요") }
            if bytes > 0 { lines.append("\(Fmt.gb(bytes)) 돌려받았어요") }
            if papers > 0 { lines.append("서류 \(papers)장 정리 · 물청소까지") }
        }
        return lines
    }

    static func archivist(_ counts: VaultCounts) -> [String] {
        var lines = ["금고 정리 중", "상자 번호 확인"]
        if counts.sessions > 0 { lines.append("복귀 가능한 세션 \(counts.sessions)개 보관 중") }
        if counts.files > 0 { lines.append("휴지통행 \(counts.files)건, 되돌릴 수 있어요") }
        if counts.processes > 0 { lines.append("끝낸 프로세스 \(counts.processes)개, 다시 띄울 수 있어요") }
        if counts.expired > 0 { lines.append("만료 \(counts.expired)건은 돌아오지 않아요") }
        return lines
    }
}
