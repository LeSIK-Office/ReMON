import AppKit
import ReMONCore
import SwiftUI

// 세션 자원 화면 — 컨텍스트 막대 · 기록 크기 · 메모리 · 누적 토큰 · 인계 권고.
// 숫자와 문구는 ReMONCore의 ContextText가 만든다(ReMONChecks context가 같은 문구를 검사한다). 금액은 쓰지 않는다.

/// 컨텍스트 막대: 창 크기를 알 때만 그린다. 70% 이상 주황 · 90% 이상 빨강.
struct ContextBar: View {
    let fill: Double
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(Self.color(fill))
                    .frame(width: max(height, proxy.size.width * CGFloat(min(1, max(0, fill)))))
            }
        }
        .frame(height: height)
        .accessibilityLabel("컨텍스트 \(ContextText.percent(fill))")
    }

    static func color(_ fill: Double) -> Color {
        fill >= 0.9 ? .red : fill >= ContextMetrics.handoffThreshold ? .orange : .teal
    }
}

/// 인계 프롬프트 복사 — 클립보드에만 넣는다. 어떤 터미널에도 보내지 않는다(사용자가 그 세션에 직접 붙여 넣는다).
struct HandoffCopyButton: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ContextText.handoffPrompt(for: session), forType: .string)
            model.append(.info, "인계 프롬프트 복사 · \(session.project)")
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(copied ? "복사했습니다" : "인계 프롬프트 복사", systemImage: copied ? "checkmark" : "doc.on.clipboard")
        }
        .help("인계서를 써 달라는 요청문을 클립보드에 복사합니다. 그 세션의 터미널에 직접 붙여 넣으세요.")
    }
}

/// 인계 권고 줄: 권고 표시 + 복사 버튼.
struct HandoffAdvice: View {
    @ObservedObject var model: AppModel
    let session: AgentSession

    var body: some View {
        HStack(spacing: 6) {
            Label("인계 권고", systemImage: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.orange)
            Spacer(minLength: 4)
            HandoffCopyButton(model: model, session: session)
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
        }
    }
}

/// 사람(세션) 상세 아래 '세션 자원' — 컨텍스트 막대 · 기록·메모리 · 누적 토큰 · 인계 권고.
struct SessionContextSection: View {
    @ObservedObject var model: AppModel
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 6) {
                Text("세션 자원").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                if session.contextTokens != nil, session.logLinkIsEstimate { DetailCard.Tag(text: "기록 연결 추정", color: .gray) }
                Spacer()
            }
            if let context = ContextText.context(session) {
                Text(context).font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                if let fill = session.contextFill {
                    ContextBar(fill: fill)
                } else {
                    Text("모델 창 크기가 기록에 없어 비율은 표시하지 않습니다.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Text(session.logPath == nil ? "기록이 연결되지 않아 컨텍스트를 알 수 없습니다." : "기록 끝부분에서 사용량을 아직 찾지 못했습니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(ContextText.storage(session)).font(.system(size: 11).monospacedDigit())
            if let total = ContextText.cumulative(session) {
                Text(total).font(.system(size: 11).monospacedDigit())
            }
            if let path = session.logPath, let name = ContextMetrics.shared.reading(forPath: path)?.model {
                Text("모델 \(name)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            if ContextText.needsHandoff(session) {
                HandoffAdvice(model: model, session: session)
                Text("컨텍스트가 70% 이상 찼습니다. 인계서를 받아 새 세션에서 이어 가기를 권합니다.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 대시보드 '컨텍스트가 큰 세션' — 점유율이 높은 순 3개(창 크기를 모르면 토큰 순으로 뒤에).
struct ContextLeadersCard: View {
    @ObservedObject var model: AppModel
    var availableWidth: CGFloat = 960

    var body: some View {
        let sessions = model.office?.sessions ?? []
        let leaders = ContextText.leaders(sessions)
        let read = sessions.filter { $0.contextTokens != nil }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("컨텍스트가 큰 세션").font(.system(size: 14, weight: .bold))
                Spacer()
                Text("컨텍스트를 읽은 세션 \(read)/\(sessions.count)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if leaders.isEmpty {
                Text("컨텍스트를 읽은 세션이 아직 없습니다. Claude Code·Codex 기록이 연결되면 나타납니다.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: min(max(1, leaders.count), max(1, Int((availableWidth + 12) / 262)))), alignment: .leading, spacing: 12) {
                ForEach(leaders) { session in
                    CardBox(accent: ContextText.needsHandoff(session) ? .orange : nil) {
                        ContextLeaderRow(model: model, session: session)
                    }
                }
            }
        }
    }
}

struct ContextLeaderRow: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(session: session).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text("\(session.kind.shortLabel) · \(session.project)").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                if let context = ContextText.context(session) {
                    Text(context + (session.logLinkIsEstimate ? " · 기록 연결 추정" : ""))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                }
                if let fill = session.contextFill { ContextBar(fill: fill, height: 5) }
                Text(ContextText.storage(session))
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                if let cumulative = ContextText.cumulative(session) {
                    Text(cumulative).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                }
                if ContextText.needsHandoff(session) {
                    Text("인계 권고").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.orange)
                    HandoffCopyButton(model: model, session: session).buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.primary.opacity(0.05) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.selectSession(session) }
        .help("누르면 사무실에서 이 세션을 고릅니다")
    }
}

/// 대표님 답을 기다리는 세션 한 줄(대시보드 맨 위). 기다리는 세션이 없으면 그리지 않는다.
struct WaitingBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let line = ContextText.waitingLine(model.office?.sessions ?? []) {
            HStack(spacing: 8) {
                Image(systemName: "hourglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                Text(line).font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button("상황실 보기") { model.focusOn(.region(.situationRoom)) }.controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
        }
    }
}
