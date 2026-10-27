import ReMONCore
import SwiftUI

/// 1MB 미만은 KB로(작은 로그·작업 공간이 '0MB'로 보이지 않게).
func catalogSize(_ bytes: UInt64) -> String {
    bytes < 1_048_576 ? String(format: "%.0fKB", Double(bytes) / 1024) : Fmt.size(bytes)
}

extension DiskGrade {
    var color: Color {
        switch self {
        case .a: .green
        case .b: .orange
        case .c: .secondary
        }
    }
}

/// 정리 화면의 개발 캐시 구역: 카탈로그 묶음(Xcode · 패키지 관리자 · 브라우저 …)마다 등급 · 주인 · 다시 생기는 방법을 보여 주고,
/// 고른 것만 확인 한 번으로 정리한다. 처음 선택은 주인 앱이 꺼진 A(순수 캐시)뿐이다.
struct DevCacheSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = DiskToolsStore.shared

    var body: some View {
        let items = model.catalogDiskItems
        let selected = items.filter { store.selection.contains($0.path) }
        let totals = Dictionary(grouping: items) { $0.grade ?? .c }.mapValues { $0.reduce(UInt64(0)) { $0 + $1.bytes } }
        CleanupBox(title: "개발 캐시 · " + DiskGrade.allCases.map { "\($0.rawValue) \(Fmt.gb(totals[$0] ?? 0))" }.joined(separator: " · "),
                   hint: "A 순수 캐시 · B 다시 빌드·설치 · C 보기만") {
            HStack(spacing: 6) {
                Button("추천 선택") { model.selectRecommendedCatalog() }.disabled(items.isEmpty)
                Button { model.cleanCatalog(selected) } label: {
                    Label("선택 정리 \(selected.count)곳 · \(catalogSize(selected.reduce(0) { $0 + $1.bytes }))", systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            }
            .controlSize(.small)
        } content: {
            if items.isEmpty {
                Text(model.diskScannedAt == nil ? "아직 조사하지 않았습니다. '다시 조사'를 누르면 읽기 전용으로 살펴봅니다." : "정리할 개발 캐시가 거의 없습니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(CatalogGroup.allCases, id: \.self) { group in
                    let members = items.filter { DiskCatalog.group(of: $0) == group }
                    let commands = ToolCommands.catalogCommands.filter { Self.group(of: $0) == group }
                    if !members.isEmpty || (!commands.isEmpty && model.diskScannedAt != nil) {
                        DevCacheGroup(model: model, group: group, items: members, commands: commands)
                    }
                }
            }
            Text("A는 영구 삭제해 공간을 바로 돌려받고 복구함에 다시 생기는 방법을 남깁니다. B는 쉬는 것(쓰는 세션 폴더 아님 · 하루 안에 안 바뀜)만 영구 삭제하고, 아니면 휴지통으로 옮깁니다. 주인 앱이 실행 중이면 건너뜁니다.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            model.syncCatalogSelection()
            if store.commandAvailability.isEmpty { model.refreshCommandAvailability() }
        }
        .onChange(of: model.diskScannedAt) { _, _ in model.syncCatalogSelection() }
    }

    /// 경로가 없는 명령 줄이 들어갈 묶음.
    static func group(of command: ToolCommand) -> CatalogGroup? {
        switch command.id {
        case ToolCommands.brewCleanup.id: .homebrew
        case ToolCommands.simctlUnavailable.id: .simulators
        default: nil
        }
    }
}

/// 묶음 하나: 머리(접기 · 합계 · 묶음 선택) + 항목 줄 + 명령 줄.
struct DevCacheGroup: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = DiskToolsStore.shared
    let group: CatalogGroup
    let items: [DiskItem]
    let commands: [ToolCommand]

    var body: some View {
        let selectable = items.filter { DevCacheRow.blocked($0) == nil }
        let chosen = selectable.filter { store.selection.contains($0.path) }
        let expanded = !store.collapsed.contains(group)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button {
                    if expanded { store.collapsed.insert(group) } else { store.collapsed.remove(group) }
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 12)
                }
                .buttonStyle(.plain)
                Text(group.label).font(.system(size: 12, weight: .semibold))
                Text("\(items.count)곳" + (chosen.isEmpty ? "" : " · 고름 \(chosen.count)")).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Text(catalogSize(items.reduce(0) { $0 + $1.bytes })).font(.system(size: 11, weight: .semibold).monospacedDigit())
                Toggle("", isOn: Binding(get: { !selectable.isEmpty && chosen.count == selectable.count },
                                         set: { model.toggleCatalogSelection(selectable.map(\.path), on: $0) }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(selectable.isEmpty).help("이 묶음에서 고를 수 있는 것 모두")
            }
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(items.prefix(40)) { item in DevCacheRow(model: model, item: item) }
                }
                .padding(.leading, 20)
                if items.count > 40 {
                    Text("… 외 \(items.count - 40)곳(\(catalogSize(items.dropFirst(40).reduce(0) { $0 + $1.bytes }))) — 묶음 선택에 함께 들어갑니다")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 20)
                }
                ForEach(commands) { command in DevCommandRow(model: model, command: command).padding(.leading, 20) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 항목 한 줄: 고르기 · 등급 · 경로 · 설명 · 상태 · 크기 · Finder · 권장 명령.
struct DevCacheRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = DiskToolsStore.shared
    let item: DiskItem

    /// 고를 수 없는 이유(조사 시점 기준 — 정리 직전에 주인 앱 실행을 다시 확인한다). 화면을 그릴 때 프로세스 목록을 읽지 않는다.
    static func blocked(_ item: DiskItem) -> String? {
        if item.permissionNeeded { return "권한 필요" }
        if let reason = item.skipReason { return reason }
        if item.grade == .c { return "보기만" }
        if let command = item.entryID.flatMap(DiskCatalog.entry)?.command { return "\(command.title) 명령으로 정리" }
        return nil
    }

    var body: some View {
        let blocked = Self.blocked(item)
        // 묶음 아래 명령 줄로 따로 보이는 명령(simctl·brew)은 줄마다 다시 달지 않는다.
        let command = item.entryID.flatMap(DiskCatalog.entry)?.command.flatMap { command in ToolCommands.catalogCommands.contains(command) ? nil : command }
        GridRow {
            Toggle("", isOn: Binding(get: { store.selection.contains(item.path) }, set: { model.toggleCatalogSelection([item.path], on: $0) }))
                .toggleStyle(.checkbox).labelsHidden().disabled(blocked != nil)
            DetailCard.Tag(text: item.grade?.rawValue ?? "-", color: item.grade?.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                Text(item.note).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.path + "\n" + (item.hint ?? ""))
            Text(status(blocked)).font(.system(size: 10.5)).foregroundStyle(blocked == nil ? Color.secondary : Color.orange).lineLimit(1)
                .help(item.hint ?? "")
            Text(item.permissionNeeded ? "권한 필요" : catalogSize(item.bytes)).font(.system(size: 11, weight: .semibold).monospacedDigit()).gridColumnAlignment(.trailing)
            HStack(spacing: 4) {
                Button { model.revealInFinder(item.path) } label: { Image(systemName: "folder") }.help("Finder에서 보기")
                if let command {
                    let reason = store.commandAvailability[command.id]
                    Button(command.title) { model.runToolCommand(command) }
                        .disabled(store.commandRunning != nil || (reason?.isEmpty == false))
                        .help(reason?.isEmpty == false ? reason! : command.detail)
                }
            }
            .controlSize(.small)
        }
    }

    private func status(_ blocked: String?) -> String {
        if let blocked { return blocked }
        if item.defaultExcluded { return "기본 제외 · 고르면 휴지통" }
        if item.entryID.flatMap(DiskCatalog.entry)?.trashPreferred == true { return "휴지통으로" }
        return item.grade == .a ? "영구 삭제" : "쉬면 영구 삭제"
    }
}

/// 경로 없이 도구에게 맡기는 정리(brew cleanup · simctl delete unavailable): 미리보기와 실행.
struct DevCommandRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = DiskToolsStore.shared
    let command: ToolCommand

    var body: some View {
        let reason = store.commandAvailability[command.id]
        let unavailable = reason?.isEmpty == false
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(command.commandLine).font(.system(size: 11, design: .monospaced))
                DetailCard.Tag(text: "B", color: DiskGrade.b.color)
                Text(unavailable ? reason! : command.detail).font(.system(size: 10.5)).foregroundStyle(unavailable ? Color.orange : Color.secondary).lineLimit(1)
                Spacer()
                if store.commandRunning == command.id { ProgressView().controlSize(.small) }
                if command.previewArguments != nil {
                    Button("미리보기") { model.runToolCommand(command, preview: true) }.disabled(store.commandRunning != nil || unavailable)
                }
                Button("실행") { model.runToolCommand(command) }.disabled(store.commandRunning != nil || unavailable)
            }
            .controlSize(.small)
            if command.tool == "brew" {
                Text("네트워크 연결 없이 실행합니다. 미리보기에도 Homebrew가 로컬 캐시를 갱신할 수 있습니다.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let output = store.commandOutput[command.id] {
                Text(output).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(8)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}
