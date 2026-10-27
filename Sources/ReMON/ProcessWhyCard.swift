import ReMONCore
import SwiftUI

/// '왜 실행 중?' 카드(G3): pid 하나의 계보(launchd까지 · 터미널·에이전트 홉) · launchd 라벨 · 리슨 포트 · 잠자기 방지 · 작업 폴더와 git · 경고.
/// 루트 권한 없이 읽고, 다른 사용자·루트 프로세스는 못 읽은 항목을 '권한 없음'으로 적는다. 상세 카드 안에 넣어 쓴다(인스펙터 폭 330pt 기준).
/// 세션 목록과 남은 보조 프로세스 출신 기록은 AppModel.whyCard(pid:)가 채워 준다.
struct ProcessWhyCard: View {
    let pid: Int32
    var sessions: [AgentSession]
    var origin: HelperOrigin?
    @State private var explanation: ProcessExplanation?
    @State private var loading = false

    init(pid: Int32, sessions: [AgentSession] = [], origin: HelperOrigin? = nil) {
        self.pid = pid
        self.sessions = sessions
        self.origin = origin
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("왜 실행 중?").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("다시 살펴보기").disabled(loading)
            }
            if let explanation {
                if explanation.exists {
                    content(explanation)
                } else {
                    Text("pid \(pid) 프로세스가 없습니다(이미 끝났습니다).").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("살펴보는 중…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .task(id: pid) { await load() }
    }

    private func load() async {
        loading = true
        let pid = self.pid, sessions = self.sessions, origin = self.origin
        // launchctl·커널 호출이 있어 메인 스레드 밖에서 모은다.
        explanation = await Task.detached(priority: .userInitiated) { ProcessExplainer.explain(pid: pid, sessions: sessions, origin: origin) }.value
        loading = false
    }

    @ViewBuilder
    private func content(_ e: ProcessExplanation) -> some View {
        if !e.warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(e.warnings) { warning in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: Self.icon(for: warning.kind)).font(.system(size: 10))
                        Text(warning.text).font(.system(size: 10.5)).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Self.isSevere(warning.kind) ? Color.red : Color.orange)
                }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.orange.opacity(0.10)))
        }
        Text(Self.summary(e)).font(.system(size: 11.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        // 계보: 위가 launchd, 맨 아래가 이 프로세스.
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(e.chain.reversed().enumerated()), id: \.element.pid) { index, hop in
                HStack(spacing: 4) {
                    if index > 0 {
                        Text(String(repeating: " ", count: min(index - 1, 6) * 2) + "└").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                    Image(systemName: Self.icon(for: hop)).font(.system(size: 9.5)).foregroundStyle(Self.color(for: hop)).frame(width: 13)
                    Text(Self.title(for: hop)).font(.system(size: 11, weight: hop.pid == e.pid ? .bold : .regular)).lineLimit(1).truncationMode(.middle)
                    Text("\(hop.pid)").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .help((hop.roleLabel.map { $0 + "\n" } ?? "") + (hop.path ?? hop.name))
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            if let origin = e.origin {
                DetailCard.Row(label: "원래 세션", value: "\(origin.label) · " + (origin.sessionEndedAt.map { "\(Fmt.ago($0)) 종료" } ?? "실행 중") + " · ReMON이 직접 본 기록")
            }
            if let kind = e.helperKind { DetailCard.Row(label: "종류", value: kind.label) }
            if let launchd = e.launchd { DetailCard.Row(label: "launchd", value: Self.launchdText(launchd)) }
            DetailCard.Row(label: "리슨 포트", value: Self.portsText(e))
            if !e.assertions.isEmpty {
                DetailCard.Row(label: "잠자기", value: e.assertions.prefix(3).map { $0.typeLabel + ($0.name.isEmpty ? "" : " · \($0.name)") }.joined(separator: "\n"))
            }
            DetailCard.Row(label: "작업 폴더", value: e.cwd.map(Self.home) ?? "확인 안 됨")
            if let git = e.git {
                DetailCard.Row(label: "git", value: "\((git.root as NSString).lastPathComponent) · " + (git.branch ?? git.head.map { "분리된 HEAD \($0)" } ?? "?") + (git.isWorktree ? " · 워크트리" : ""))
            }
            DetailCard.Row(label: "실행 파일", value: e.path.map(Self.home) ?? "확인 안 됨")
            DetailCard.Row(label: "실행", value: "\(e.user) · \(e.status) · " + (e.startTime.map { "\(Fmt.ago($0)) 시작" } ?? "시작 시각 모름")
                           + (e.footprint.map { " · \(Fmt.size($0))" } ?? ""))
        }
        if let command = e.command, !command.isEmpty {
            Text(command).font(.system(size: 10, design: .monospaced)).lineLimit(4).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        ForEach(e.notes, id: \.self) { note in
            Text(note).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 문구

    /// 한 줄 답: 누가·왜 띄웠는가.
    static func summary(_ e: ProcessExplanation) -> String {
        if let origin = e.origin, origin.sessionEndedAt != nil {
            return "\(origin.label) 세션이 띄웠고, 세션이 끝난 뒤에도 남아 있습니다."
        }
        if let agent = e.chain.dropFirst().first(where: { if case .agent = $0.role { return true }; return false }) {
            let owner = agent.note ?? (agent.roleLabel ?? agent.name)
            return "\(owner) 아래에서 돌고 있습니다" + (e.helperKind.map { " · \($0.label)" } ?? "") + "."
        }
        if let launchd = e.launchd {
            if launchd.launchedAsApp { return "앱으로 실행됐습니다(Launch Services가 띄움)." }
            return "시작 항목(\(launchd.label))이라 launchd가 띄웠습니다" + (launchd.keepAlive?.isOn == true ? " · 꺼져도 다시 띄웁니다." : ".")
        }
        if let terminal = e.chain.dropFirst().first(where: { if case .terminal = $0.role { return true }; return false }), case .terminal(let name) = terminal.role {
            return "\(name)에서 직접 실행했습니다."
        }
        if e.pid == 1 { return "커널이 가장 먼저 띄운 시스템 시작 관리자입니다." }
        if e.ppid == 1 { return "launchd가 직접 관리합니다 — 실행한 부모가 끝나 넘어왔을 수 있습니다." }
        return "pid \(e.ppid) 아래에서 돌고 있습니다."
    }

    static func launchdText(_ info: ProcessExplanation.Launchd) -> String {
        var lines = [info.label + (info.launchedAsApp ? " · 앱으로 실행" : "")]
        if let plist = info.plistPath { lines.append(home(plist)) }
        if let state = info.state, state.loaded {
            var parts = [state.running ? "실행 중" : "멈춤"]
            if let runs = state.runs { parts.append("\(runs)회 실행") }
            if let exit = state.lastExit { parts.append("마지막 종료 \(exit)") }
            if info.keepAlive?.isOn == true { parts.append("다시 띄움") }
            lines.append(parts.joined(separator: " · "))
        }
        lines.append(info.matchedBy)
        return lines.joined(separator: "\n")
    }

    static func portsText(_ e: ProcessExplanation) -> String {
        guard let sockets = e.sockets else { return "권한 없음" }
        guard !sockets.isEmpty else { return "없음" }
        return sockets.prefix(6).map { "\($0.proto.rawValue.uppercased()) \($0.display) · \($0.scopeLabel)" }.joined(separator: "\n") + (sockets.count > 6 ? "\n… 외 \(sockets.count - 6)개" : "")
    }

    static func title(for hop: ProcessExplanation.Hop) -> String {
        switch hop.role {
        case .agent(let name): hop.note ?? name
        case .terminal(let name): name
        case .launchd: "launchd"
        case .app(let name): name
        case .helper(let kind): "\(hop.name) · \(kind.label)"
        case .shell, .process: hop.name
        }
    }

    static func icon(for hop: ProcessExplanation.Hop) -> String {
        switch hop.role {
        case .launchd: "gearshape.2"
        case .terminal: "terminal"
        case .agent: "person.crop.square"
        case .shell: "chevron.left.forwardslash.chevron.right"
        case .app: "app"
        case .helper(let kind): kind.icon
        case .process: "circle"
        }
    }

    static func color(for hop: ProcessExplanation.Hop) -> Color {
        switch hop.role {
        case .agent: .purple
        case .terminal: .blue
        case .helper: .teal
        case .launchd: .secondary
        default: .secondary
        }
    }

    static func icon(for kind: ProcessExplanation.Warning.Kind) -> String {
        switch kind {
        case .executableDeleted, .executableReplaced: "doc.badge.ellipsis"
        case .dyld: "exclamationmark.shield"
        case .zombie: "xmark.circle"
        case .stopped: "pause.circle"
        case .longRunning: "clock.badge.exclamationmark"
        case .publicListener: "network"
        case .preventsSleep: "moon.zzz"
        }
    }

    static func isSevere(_ kind: ProcessExplanation.Warning.Kind) -> Bool { kind == .dyld || kind == .publicListener }

    static func home(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}
