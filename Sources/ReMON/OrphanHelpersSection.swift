import ReMONCore
import SwiftUI

extension HelperKind {
    var icon: String {
        switch self {
        case .mcpServer: "puzzlepiece.extension"
        case .browser: "globe"
        case .devServer: "server.rack"
        case .languageServer: "text.cursor"
        case .buildDaemon: "hammer"
        case .workflowAgent: "flowchart"
        case .other: "gearshape"
        }
    }
}

/// 정리 화면의 '남은 보조 프로세스' 구역(G2): 세션이 끝났는데 남은 MCP 서버·브라우저·개발 서버 등.
/// ReMON이 세션 하위로 직접 본 것만 보인다(이름만으로 고르지 않음). 줄을 펼치면 '왜 실행 중?' 카드.
struct OrphanHelpersSection: View {
    @ObservedObject var model: AppModel
    @State private var expanded: ProcessKey?

    var body: some View {
        let helpers = model.orphanHelpers
        let targets = model.orphanHelperTargets
        let idleMinutes = Int(model.monitor.helpers.settings.idleAfter / 60)
        CleanupBox(title: "남은 보조 프로세스 \(helpers.count)개" + (helpers.isEmpty ? "" : " · \(Fmt.size(helpers.reduce(0) { $0 + $1.footprint }))"),
                   hint: "세션이 끝났는데 남은 MCP 서버·브라우저·개발 서버 · ReMON이 직접 본 것만") {
            Button { model.optimizeHelpers() } label: { Label("쉬는 것 모두 끝내기 \(targets.count)", systemImage: "wind") }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(targets.isEmpty)
                .help("\(idleMinutes)분 넘게 CPU를 쓰지 않은 것만 · SIGTERM 후 남으면 SIGKILL")
        } content: {
            if helpers.isEmpty {
                Text("없습니다. 에이전트 세션이 끝난 뒤에도 남은 하위 프로세스가 생기면 여기에 보입니다(ReMON을 켠 뒤 세션 하위로 직접 본 것만).")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(helpers) { helper in
                    row(helper, idleMinutes: idleMinutes)
                    if expanded == helper.id {
                        model.whyCard(pid: helper.top.pid)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                            .padding(.leading, 22)
                    }
                }
            }
            let suspected = model.suspectedOrphans
            if !suspected.isEmpty {
                Divider()
                Text("추정 고아 \(suspected.count)개 · 부모 없는 개발 서버(1시간+) · 관찰 이력 없음 — 직접 띄운 서버일 수 있어 자동 정리하지 않습니다")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                ForEach(suspected) { helper in
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.diamond").font(.system(size: 11)).foregroundStyle(.orange).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(helper.command.isEmpty ? helper.name : helper.command).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Text("\(helper.origin.project) · \(Fmt.duration(Date().timeIntervalSince(helper.startTime))) 실행 · 프로세스 \(helper.members.count)개")
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .help(helper.command)
                        Spacer(minLength: 6)
                        Text(Fmt.size(helper.footprint)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                        Button { expanded = expanded == helper.id ? nil : helper.id } label: { Image(systemName: expanded == helper.id ? "chevron.up" : "questionmark.circle") }
                            .help("왜 실행 중?").controlSize(.small)
                        Button("멈추기") { model.terminateSuspected(helper) }.controlSize(.small)
                    }
                    if expanded == helper.id {
                        model.whyCard(pid: helper.top.pid)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
                            .padding(.leading, 22)
                    }
                }
            }
        }
    }

    private func row(_ helper: OrphanHelper, idleMinutes: Int) -> some View {
        HStack(spacing: 8) {
            // 워크플로 잔재(주인 세션이 하위 에이전트로 띄운 일꾼이 남은 것)는 보라색으로 구분한다.
            Image(systemName: helper.kind.icon).font(.system(size: 11)).foregroundStyle(helper.origin.workflowResidue ? .purple : .teal).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(helper.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(helper.kind.label).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if helper.members.count > 1 { Text("프로세스 \(helper.members.count)개").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }
                let owner = helper.origin.workflowResidue ? "주인 세션" : "세션"
                Text("\(helper.origin.label) · " + (helper.origin.sessionEndedAt.map { "\(owner) \(Fmt.ago($0)) 종료" } ?? "\(owner) 종료"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            .help(helper.command)
            Spacer(minLength: 6)
            DetailCard.Tag(text: idleText(helper), color: helper.idle ? .green : .orange)
            Text(Fmt.size(helper.footprint)).font(.system(size: 11, weight: .semibold).monospacedDigit())
            HStack(spacing: 4) {
                Button { expanded = expanded == helper.id ? nil : helper.id } label: { Image(systemName: expanded == helper.id ? "chevron.up" : "questionmark.circle") }
                    .help("왜 실행 중?")
                Button("끝내기") { model.terminateHelper(helper) }
            }
            .controlSize(.small)
        }
    }

    private func idleText(_ helper: OrphanHelper) -> String {
        guard helper.cpuReadable else { return "CPU 모름" }
        if helper.idle { return helper.idleFor < 60 ? "쉼 1분 미만" : "쉼 \(Fmt.duration(helper.idleFor))" }
        return helper.cpuPercent >= 1 ? "CPU \(Fmt.percent(helper.cpuPercent))" : "최근 움직임"
    }
}
