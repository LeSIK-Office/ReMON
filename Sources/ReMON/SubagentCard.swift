import ReMONCore
import SwiftUI

/// 하위 에이전트를 처음 본 시각(장면이 스냅샷마다 적는다). SubagentInfo에는 시작 시각이 없어서 카드의 '실행 시간'은 처음 본 뒤로 잰다(추정으로 표시).
@MainActor
final class SubagentSightings {
    static let shared = SubagentSightings()
    private var first: [String: Date] = [:]

    func note(_ agents: [SubagentInfo], at now: Date) {
        for agent in agents where first[agent.id] == nil { first[agent.id] = now }
        // 하루 넘게 지난 기록은 버린다(세션 하나에 하위 에이전트가 수백 개 쌓일 수 있다).
        if first.count > 4000 { first = first.filter { now.timeIntervalSince($0.value) < 86_400 } }
    }

    func firstSeen(_ id: String) -> Date? { first[id] }
}

/// 하위 에이전트(워크플로실 로봇 · 책상 옆 로봇) 카드. 장면의 onSelectSubagent로 받은 (주인 세션 · 하위 에이전트)를 보여 준다.
/// 보이는 값은 기록에서 읽은 것만: 이름 · 단계 · 워크플로 · 모델 · 마지막 활동(기록 파일 수정 시각). 시작 시각과 토큰은 SubagentInfo에 없어서
/// 실행 시간은 'ReMON이 처음 본 뒤'로(추정) 적고, 토큰은 '토큰 정보 없음'이라고 적는다 — 지어내지 않는다.
struct SubagentCard: View {
    let session: AgentSession
    let subagent: SubagentInfo

    /// 일하는 중(최근 2분 안 기록)으로 보이는데 마지막 기록이 20분 넘게 지났다 = 멈춤?(장면의 빨간 등과 같은 기준).
    static func isStale(_ agent: SubagentInfo, now: Date) -> Bool {
        agent.active && agent.lastActivity.map { now.timeIntervalSince($0) > OfficeScene.workflowStaleAfter } == true
    }

    static func kindLabel(_ kind: SubagentInfo.Kind) -> String {
        switch kind {
        case .workflow: "워크플로 에이전트"
        case .subagent: "하위 에이전트"
        case .thread: "하위 스레드(Codex)"
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            content(now: context.date)
        }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let stale = Self.isStale(subagent, now: now)
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: CharacterArt.robot(WorkerNode.robotDesign(subagent), frame: 0).nsImage())
                    .resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(subagent.label).font(.system(size: 14, weight: .bold)).lineLimit(3)
                    HStack(spacing: 5) {
                        DetailCard.Tag(text: Self.kindLabel(subagent.kind), color: subagent.kind == .workflow ? .orange : nil)
                        if stale {
                            DetailCard.Tag(text: "멈춤?", color: .red)
                        } else {
                            DetailCard.Tag(text: subagent.active ? "일하는 중" : "쉬는 중", color: subagent.active ? .green : .gray)
                        }
                    }
                }
            }
            if stale {
                Text("일하는 중으로 보이는데 마지막 기록이 \(Fmt.ago(subagent.lastActivity, now: now))입니다. 멈췄을 수 있어요 — 주인 세션의 터미널을 확인하세요.")
                    .font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.red.opacity(0.08)))
            }
            VStack(alignment: .leading, spacing: 4) {
                DetailCard.Row(label: "주인 세션", value: "\(session.project) · \(session.kind.shortName) · \(session.displayTitle)")
                DetailCard.Row(label: "주인 pid", value: "\(session.rootPID) · \(session.state.label)")
                DetailCard.Row(label: "이름", value: subagent.label)
                DetailCard.Row(label: "단계", value: subagent.phase ?? "단계 정보 없음")
                if let workflow = subagent.workflow { DetailCard.Row(label: "워크플로", value: workflow) }
                DetailCard.Row(label: "모델", value: subagent.model ?? "모델 정보 없음")
                DetailCard.Row(label: "실행 시간", value: runningText(now: now))
                DetailCard.Row(label: "마지막 활동", value: subagent.lastActivity.map { "\(Fmt.ago($0, now: now)) · 기록 파일 수정 시각" } ?? "기록 없음")
                DetailCard.Row(label: "토큰", value: "토큰 정보 없음")
            }
            Text("하위 에이전트는 주인 세션 안에서 돕니다. 정리는 주인 세션 카드에서 합니다.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 실행 시간: 시작 시각이 기록에 없어 ReMON이 처음 본 뒤로 잰다(추정). 처음 본 기록도 없으면 그렇다고 적는다.
    private func runningText(now: Date) -> String {
        guard let first = SubagentSightings.shared.firstSeen(subagent.id) else { return "시작 시각 정보 없음" }
        return "처음 본 뒤 \(Fmt.duration(now.timeIntervalSince(first))) · 추정(시작 시각 정보 없음)"
    }
}
