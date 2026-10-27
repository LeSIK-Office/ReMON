import ReMONCore
import SwiftUI

extension RecoveryEntry.Kind {
    var icon: String {
        switch self {
        case .session: "person.crop.circle.badge.clock"
        case .trash: "trash"
        case .branch: "arrow.triangle.branch"
        case .worktree: "folder.badge.gearshape"
        case .deleted: "sparkles"
        case .codexArchive: "archivebox"
        case .process: "gearshape.2"
        }
    }

    var label: String {
        switch self {
        case .session: "세션"
        case .trash: "휴지통"
        case .branch: "브랜치"
        case .worktree: "워크트리"
        case .deleted: "캐시 삭제"
        case .codexArchive: "Codex 보관"
        case .process: "프로세스"
        }
    }
}

extension RecoveryEntry {
    /// 되돌리기 버튼 이름: 세션은 복귀, 프로세스는 다시 띄우기, 나머지는 되돌리기.
    var restoreVerb: String {
        switch kind {
        case .session: backgroundJob != nil ? "백그라운드로 복귀" : "복귀시키기"
        case .process: "다시 띄우기"
        default: "되돌리기"
        }
    }
}

extension RecoveryEntry.Status {
    var label: String {
        switch self {
        case .retiring: "종료 대기"
        case .held: "보관 중"
        case .restoring: "복귀 확인 중"
        case .restored: "되돌림"
        case .expired: "만료"
        case .gone: "기록만"
        }
    }

    var color: Color {
        switch self {
        case .held: .purple
        case .restoring: .orange
        case .restored: .green
        case .retiring: .blue
        case .expired, .gone: .secondary
        }
    }
}

/// 정리 화면의 복구함: 되돌릴 수 있는 것(보관 중)을 위에, 지난 기록을 아래에.
struct RecoverySection: View {
    @ObservedObject var model: AppModel
    @State private var showHistory = false

    var body: some View {
        let live = model.recovery.filter { $0.status == .held || $0.status == .restoring || $0.status == .retiring }
        let history = model.recovery.filter { !live.contains($0) }
        let totals = model.recoveryTotals
        CleanupBox(title: "복구함 · 되돌릴 수 있음 \(live.filter(\.restorable).count)개",
                   hint: "누적 정리: 세션 \(totals.sessionsRetired)개 · 메모리 \(Fmt.gb(totals.memoryBytes)) · 디스크 \(Fmt.gb(totals.diskBytes)) · 되돌림 \(totals.restoredCount)건 · 세션 보관 \(Int(model.settings.recoveryRetentionDays))일") {
            Button(showHistory ? "지난 기록 숨기기" : "지난 기록 \(history.count)") { showHistory.toggle() }
                .controlSize(.small).disabled(history.isEmpty)
        } content: {
            if live.isEmpty && !showHistory {
                Text("보관 중인 항목이 없습니다. 세션·파일·부산물을 정리하면 여기서 되돌릴 수 있습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(live.prefix(30)) { entry in RecoveryRow(model: model, entry: entry) }
                if showHistory {
                    ForEach(history.prefix(40)) { entry in RecoveryRow(model: model, entry: entry) }
                }
            }
        }
    }
}

struct RecoveryRow: View {
    @ObservedObject var model: AppModel
    let entry: RecoveryEntry

    var body: some View {
        GridRow {
            HStack(spacing: 6) {
                Image(systemName: entry.kind.icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                Text(entry.project.isEmpty ? entry.kind.label : entry.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            if entry.kind == .process {
                // 프로세스: 다시 띄울 명령(앱은 open -b)을 줄에 바로 보여 준다.
                Text(entry.resumeCommand ?? entry.title).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help([entry.title, entry.origin, entry.resumeCommand, entry.note].compactMap { $0 }.joined(separator: "\n"))
            } else {
                Text(entry.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(entry.note ?? entry.title)
            }
            Text("\(entry.reason) · \(Fmt.ago(entry.createdAt))").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            DetailCard.Tag(text: entry.status.label, color: entry.status.color)
            HStack(spacing: 4) {
                if entry.restorable {
                    Button(entry.kind == .session ? "복귀" : entry.kind == .process ? "다시 띄우기" : "되돌리기") { model.restore(entry) }
                }
                if entry.resumeCommand != nil || entry.restoreHint != nil {
                    Button { model.copyRecoveryCommand(entry) } label: { Image(systemName: "doc.on.doc") }.help("복구 명령 복사")
                }
                if entry.kind == .session || entry.kind == .process { Button { model.selectRecovery(entry.id) } label: { Image(systemName: "info.circle") }.help("자세히") }
            }
            .controlSize(.small)
        }
    }
}

/// 정신교육실 인물(또는 복구함 줄)을 누르면 나오는 카드.
struct RecoveryCard: View {
    @ObservedObject var model: AppModel
    let entry: RecoveryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: entry.kind.icon).font(.system(size: 20)).foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.project).font(.system(size: 14, weight: .bold))
                    Text(entry.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                DetailCard.Tag(text: entry.status.label, color: entry.status.color)
            }
            VStack(alignment: .leading, spacing: 4) {
                DetailCard.Row(label: entry.departure == nil ? "정리 이유" : "끝난 까닭", value: entry.departure.flatMap(DepartureCause.init(rawValue:))?.label ?? entry.reason)
                DetailCard.Row(label: "정리 시각", value: entry.createdAt.formatted(date: .abbreviated, time: .shortened) + " · " + Fmt.ago(entry.createdAt))
                if let agent = entry.agent.flatMap(AgentKind.init(rawValue:)) { DetailCard.Row(label: "에이전트", value: agent.label) }
                if let id = entry.resumeID { DetailCard.Row(label: "복구 키", value: id) }
                if let cwd = entry.cwd { DetailCard.Row(label: "폴더", value: cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
                if let bytes = entry.transcriptBytes { DetailCard.Row(label: "대화 기록", value: Fmt.size(bytes) + (entry.backup != nil ? " · 보관본 있음" : " · 보관본 없음")) }
                if entry.bytes > 0 { DetailCard.Row(label: "회수", value: Fmt.size(entry.bytes)) }
                if let host = entry.terminalHost { DetailCard.Row(label: entry.backgroundJob != nil ? "실행 방식" : "원래 터미널", value: host) }
                if let job = entry.backgroundJob { DetailCard.Row(label: "백그라운드 id", value: "\(job) · 복귀 뒤 터미널에서 보려면 claude attach \(job)") }
                if let candidate = entry.candidateID { DetailCard.Row(label: "후보 키(추정)", value: candidate) }
                if entry.kind == .process {
                    if let origin = entry.origin { DetailCard.Row(label: entry.isAppProcess ? "앱" : "출신", value: origin) }
                    if let executable = entry.executable { DetailCard.Row(label: "실행 파일", value: executable.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }
                    if let environment = entry.processEnvironment?.filter({ ProcessRecovery.relaunchEnvironmentKeys.contains($0.key) }), !environment.isEmpty {
                        DetailCard.Row(label: "환경 변수", value: environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                    }
                    if let exit = entry.exitReason { DetailCard.Row(label: "끝난 방식", value: exit) }
                }
                if let note = entry.note { DetailCard.Row(label: "메모", value: note) }
            }
            if let command = entry.resumeCommand ?? entry.restoreHint {
                Text(command).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            }
            HStack(spacing: 6) {
                Button { model.restore(entry) } label: { Label(entry.restoreVerb, systemImage: entry.kind == .process ? "arrow.clockwise" : "arrow.uturn.backward").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).disabled(!entry.restorable)
                Button { model.copyRecoveryCommand(entry) } label: { Label("명령 복사", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                    .disabled(entry.resumeCommand == nil && entry.restoreHint == nil)
            }
            .controlSize(.small)
            if entry.status == .held {
                Button(role: .destructive) { model.forget(entry) } label: { Text("보관 해제").frame(maxWidth: .infinity) }.controlSize(.small)
            }
            Text(footer).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var footer: String {
        switch entry.kind {
        case .session:
            return "복귀시키면 \(RecoveryLaunchers.placeLabel(for: entry))에서 같은 대화를 이어 엽니다. 기록 파일이 지워졌어도 보관본으로 되돌립니다."
        case .process where entry.isAppProcess:
            return "다시 띄우면 \(entry.bundleID.map { "open -b \($0)" } ?? "번들 경로")로 앱을 새로 엽니다. 저장하지 않았던 문서는 앱이 되살릴 수 있을 때만 돌아옵니다."
        case .process:
            let masked = entry.processArgv?.contains { $0.contains(ProcessRecovery.mask) } == true
            return "다시 띄우면 \(RecoveryLaunchers.placeLabel(for: entry))에서 원래 폴더로 옮긴 뒤 같은 명령을 실행합니다." + (masked ? " 가린 비밀값(\(ProcessRecovery.mask))은 직접 채워야 할 수 있습니다." : "")
        default:
            return entry.restoreHint ?? ""
        }
    }
}

/// 왼쪽 아래: 위험할 때만 뜨는 최적화 버튼(메모리 · 프로세스 · 저장소). 누르면 트레이너·청소 특공대가 실제로 정리한다.
struct OptimizePanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let risks = model.risks
        // 위험이 사라져도 방금 한 일은 잠깐 확인할 수 있게 둔다.
        let recent = model.optimizeNotes.filter { Date().timeIntervalSince($0.value.time) < 30 }
        if risks.any || !recent.isEmpty || model.optimizeBusy != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: risks.any ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(risks.any ? .orange : .green)
                    Text(risks.any ? "위험 감지 · 최적화" : "최적화 결과").font(.system(size: 11, weight: .bold))
                    Spacer()
                    if risks.count > 1 {
                        Button("한 번에") { model.optimizeAll() }.controlSize(.mini).buttonStyle(.borderedProminent).tint(.orange).disabled(model.optimizeBusy != nil)
                    }
                }
                if let note = risks.memory ?? recent[.memory].map({ _ in "여유 \(Fmt.gb(model.system.memory.available)) · 스왑 \(Fmt.gb(model.system.swap.used))" }) {
                    button(.memory, "메모리 최적화", "figure.strengthtraining.traditional", note, .pink) { model.optimizeMemory() }
                }
                if let note = risks.process ?? recent[.process].map({ _ in "탭 닫힘·고아·남은 보조 프로세스" }) {
                    button(.process, "프로세스 최적화", "terminal", note, .purple) { model.optimizeProcesses() }
                }
                if let note = risks.disk ?? recent[.storage].map({ _ in "여유 \(Fmt.gb(model.system.disk.available))" }) {
                    button(.storage, "저장소 정리", "sparkles", note, .teal) { model.optimizeStorage() }
                }
                Text("세션은 복구 키를 보관한 뒤 정리합니다 · 정신교육실에서 복귀").font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill((risks.any ? Color.orange : Color.green).opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder((risks.any ? Color.orange : Color.green).opacity(0.35)))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    private func button(_ kind: OptimizeKind, _ title: String, _ icon: String, _ note: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        let busy = model.optimizeBusy == kind
        let result = model.optimizeNotes[kind].flatMap { Date().timeIntervalSince($0.time) < 30 ? $0 : nil }
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 11.5, weight: .semibold))
                        Text(note).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.mini) } else { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                if let result {
                    Text(result.text)
                        .font(.system(size: 9.5))
                        .foregroundStyle(result.good ? Color.primary : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 23)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(busy ? 0.24 : 0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.optimizeBusy != nil)
        .accessibilityLabel(title)
    }
}
