import ReMONCore
import SwiftUI

// 디스크 지도 화면(10-25 대표 요청 "구조도 들어가서 볼 수 있게"): 위 막대(경로·합계·다시 조사·태그 필터) · 한눈에 띠 ·
// 트리맵 + 크기 순 목록 · 설명판(조치 버튼) · 큰 파일. 상태는 DiskMapStore 하나 — 페이지를 옮겨 다녀도 유지되도록 앱이 들고 있는다.

struct DiskMapPage: View {
    @ObservedObject var store: DiskMapStore
    @State private var width: CGFloat = 960

    init(store: DiskMapStore) {
        self.store = store
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "디스크 지도", subtitle: "들어가 보며 무엇이 얼마인지 확인합니다 · 기본은 휴지통 · 영구 삭제는 다시 생기는 캐시만 · 모든 조치는 복구 금고에 기록") {
                DiskMapScanControls(store: store)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    if store.isMockSource { mockBanner }
                    DiskMapTopBar(store: store)
                    if !store.glances.isEmpty { DiskMapGlanceStrip(store: store) }
                    mapRow
                    lowerRow
                }
                .padding(.horizontal, 18)
                .padding(.top, 2)
                .padding(.bottom, 18)
                .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width = $0 }
            }
        }
        .onAppear { store.scanIfNeeded() }
    }

    private var wide: Bool { width >= 900 }
    private var medium: Bool { width >= 640 }

    @ViewBuilder
    private var mapRow: some View {
        if medium {
            let height: CGFloat = wide ? 420 : 350
            HStack(alignment: .top, spacing: 12) {
                DiskMapTreemap(store: store).frame(height: height)
                DiskMapRankedList(store: store).frame(width: wide ? 330 : 270, height: height)
            }
        } else {
            VStack(spacing: 12) {
                DiskMapTreemap(store: store).frame(height: 300)
                DiskMapRankedList(store: store).frame(height: 320)
            }
        }
    }

    @ViewBuilder
    private var lowerRow: some View {
        if wide {
            HStack(alignment: .top, spacing: 12) {
                DiskMapDetailPane(store: store).frame(maxWidth: .infinity)
                DiskMapLargeFiles(store: store).frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 12) {
                DiskMapDetailPane(store: store)
                DiskMapLargeFiles(store: store)
            }
        }
    }

    private var mockBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("미리보기용 가짜 데이터입니다 — 실제 디스크를 읽지 않았고, 버튼도 실제 파일을 건드리지 않습니다. 실제 조사기를 연결하면 이 띠는 사라집니다.")
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: - 다시 조사(경과 시간)

struct DiskMapScanControls: View {
    @ObservedObject var store: DiskMapStore

    var body: some View {
        HStack(spacing: 8) {
            if store.dryRun() { DetailCard.Tag(text: "드라이런", color: .orange).help("설정의 드라이런이 켜져 있습니다 — 조치는 기록만 하고 실제로 옮기거나 지우지 않습니다") }
            if store.scanning, let started = store.scanStartedAt {
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text("조사 중 · \(max(0, Int(context.date.timeIntervalSince(started))))초째" + (store.largeScanning && !store.roots.isEmpty ? " · 큰 파일 찾는 중" : ""))
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            } else if let last = store.lastScan {
                Text("\(Fmt.ago(last)) 조사 · \(String(format: "%.1f", store.lastScanDuration ?? 0))초 걸림")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { store.rescan() } label: { Label("다시 조사", systemImage: "arrow.clockwise") }
                .disabled(store.scanning)
                .help("디스크를 읽기 전용으로 다시 살펴봅니다(들어가 있던 위치는 그대로)")
        }
    }
}

// MARK: - 위 막대: 경로 · 합계 · 태그 필터

struct DiskMapTopBar: View {
    @ObservedObject var store: DiskMapStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                breadcrumb
                Spacer(minLength: 8)
                totals
            }
            if !store.tagStats.isEmpty {
                DiskMapFlowLayout(spacing: 6, lineSpacing: 6) {
                    Text("태그").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.vertical, 4)
                    ForEach(store.tagStats) { stat in chip(stat) }
                    if !store.filter.isEmpty {
                        Button { store.filter = [] } label: { Label("필터 해제", systemImage: "xmark.circle.fill").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.vertical, 4)
                    }
                }
                Text(store.filter.isEmpty ? "개수 · 크기는 이 단계 아래 펼친 곳과 큰 파일 목록 기준입니다(태그 칸 안쪽은 겹쳐 세지 않음). 누르면 그 태그만 모아 봅니다."
                                          : "고른 태그만 모아 보는 중입니다 — 이 단계 아래 펼친 곳과 큰 파일 목록에서 찾았습니다. 폴더를 누르면 필터를 끄고 그 안으로 들어갑니다.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                if !store.path.isEmpty {
                    Button { store.goUp() } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)) }
                        .buttonStyle(.bordered).controlSize(.small).help("한 단계 위로")
                }
                crumb("디스크 전체", systemImage: "internaldrive", depth: 0, current: store.path.isEmpty)
                ForEach(Array(store.path.enumerated()), id: \.offset) { index, step in
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    crumb(index == 0 ? DiskMapFormat.home(step) : store.node(at: step)?.name ?? (step as NSString).lastPathComponent,
                          systemImage: nil, depth: index + 1, current: index == store.path.count - 1)
                }
            }
        }
        .frame(height: 26)
    }

    private func crumb(_ title: String, systemImage: String?, depth: Int, current: Bool) -> some View {
        Button { store.go(toDepth: depth) } label: {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
                Text(title).font(.system(size: 12.5, weight: current ? .bold : .regular)).lineLimit(1)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(current ? Color.accentColor.opacity(0.16) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(current ? Color.primary : Color.secondary)
    }

    @ViewBuilder
    private var totals: some View {
        if store.roots.isEmpty {
            Text(store.scanning ? "조사 중 — 끝나면 크기가 나옵니다" : "아직 조사 결과가 없습니다").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
        } else {
            levelTotals
        }
    }

    private var levelTotals: some View {
        HStack(spacing: 6) {
            Text(store.filter.isEmpty ? "이 단계" : "고른 태그").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(DiskMapFormat.size(store.levelTotal)).font(.system(size: 15, weight: .bold).monospacedDigit())
            if store.levelPartial {
                Text("⋯ 하한").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.orange)
                    .help("끝까지 세지 못한 칸이 있습니다(권한·시간 제한) — 실제는 이보다 클 수 있습니다")
            }
            Text("· \(store.displayed.count)칸").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func chip(_ stat: DiskMapStore.TagStat) -> some View {
        let on = store.filter.contains(stat.tag)
        return Button { store.toggleFilter(stat.tag) } label: {
            HStack(spacing: 5) {
                Circle().fill(stat.tag.mapColor).frame(width: 7, height: 7)
                Text(stat.tag.label).font(.system(size: 11, weight: .semibold))
                Text("\(stat.count) · \(DiskMapFormat.size(stat.bytes))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(on ? stat.tag.mapColor.opacity(0.26) : Color.primary.opacity(0.055)))
            .overlay(Capsule().strokeBorder(on ? stat.tag.mapColor.opacity(0.9) : Color.clear, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(on ? "\(stat.tag.label) 필터 끄기" : "\(stat.tag.label)만 모아 보기")
    }
}

// MARK: - 한눈에(Docker · Xcode · Homebrew · 임시 · 휴지통 · 스왑 · 스냅샷)

struct DiskMapGlanceStrip: View {
    @ObservedObject var store: DiskMapStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("한눈에").font(.system(size: 13, weight: .semibold))
                Text("누르면 맨 위에서 그것만 모아 봅니다").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], spacing: 8) {
                ForEach(store.glances) { glance in tile(glance) }
            }
        }
    }

    private func tile(_ glance: DiskMapStore.Glance) -> some View {
        let color = glance.tag.mapColor
        let found = glance.count > 0
        return Button { store.focus(glance) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: glance.tag.mapSymbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                    Text(glance.tag.label).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(found ? DiskMapFormat.size(glance.bytes) + (glance.partial ? "⋯" : "") : "못 찾음")
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(found ? Color.primary : Color.secondary)
                Text(Self.canDo(glance)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(found ? 0.1 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(color.opacity(found ? 0.3 : 0.12), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!found)
        .help(found ? "\(glance.tag.label) \(glance.count)곳 · " + Self.canDo(glance) : "아직 찾지 못했습니다 — 조사한 곳(펼친 곳·큰 파일)에 없습니다")
    }

    /// 그 묶음에서 할 수 있는 일(찾은 칸들의 허용 조치에서 정한다).
    static func canDo(_ glance: DiskMapStore.Glance) -> String {
        guard glance.count > 0 else { return "조사한 곳에서는 찾지 못했습니다" }
        if glance.actions.contains(.prune) {
            switch glance.tag {
            case .docker: return "docker 정리 명령 — 미리보기 뒤 실행"
            case .homebrew: return "brew cleanup — 미리보기 뒤 실행"
            default: return "정리 명령 — 미리보기 뒤 실행"
            }
        }
        if glance.actions.contains(.deletePermanently) { return "다시 생기는 것은 영구 삭제 · 나머지는 휴지통" }
        if glance.actions.contains(.trash) { return glance.tag == .temp ? "휴지통으로(임시 파일은 영구 삭제 안 함)" : "휴지통으로(되돌릴 수 있음)" }
        switch glance.tag {
        case .trash: return "Finder에서 비우면 공간이 돌아옵니다 · ReMON은 비우지 않음"
        case .swap: return "보기만 · 세션을 정리해 메모리가 줄면 macOS가 줄입니다"
        case .snapshot: return "보기만 · 공간이 모자라면 macOS가 먼저 지웁니다"
        default: return "보기만"
        }
    }
}

// MARK: - 크기 순 목록(다중 선택 → 묶음 휴지통)

struct DiskMapRankedList: View {
    @ObservedObject var store: DiskMapStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(store.filter.isEmpty ? "크기 순" : "고른 태그 · 크기 순").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(store.displayed.count)칸").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if !store.checkedNodes.isEmpty { bulkBar }
            if store.displayed.isEmpty {
                Text(store.isExpandingCurrent ? "펼치는 중입니다…" : store.scanning && store.roots.isEmpty ? "살펴보는 중입니다…" : "보일 칸이 없습니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 1) {
                        let shared = store.sharedTags
                    ForEach(store.displayed) { item in DiskMapRow(store: store, item: item, total: store.levelTotal, color: DiskTag.mapColor(for: item.node.tags, excluding: shared)) }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private var bulkBar: some View {
        let nodes = store.checkedNodes
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(nodes.count)개 선택 · \(DiskMapFormat.size(nodes.reduce(UInt64(0)) { $0 + $1.bytes }))").font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("선택 해제") { store.checked = [] }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { store.trashChecked() } label: { Label("선택한 것 휴지통으로", systemImage: "trash").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(nodes.contains { store.busy.contains($0.path) })
            Text("묶음은 휴지통만 — 영구 삭제는 하나씩 설명판에서").font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.accentColor.opacity(0.1)))
    }
}

struct DiskMapRow: View {
    @ObservedObject var store: DiskMapStore
    let item: DiskMapItem
    let total: UInt64
    /// 트리맵 칸과 같은 색(이 단계의 모든 칸에 붙은 태그는 빼고 고른 대표 태그).
    let color: Color
    @State private var hover = false

    var body: some View {
        let node = item.node
        let selected = store.selection == node.path
        let canTrash = node.actions.contains(.trash)
        HStack(alignment: .center, spacing: 6) {
            Toggle("", isOn: Binding(get: { store.checked.contains(node.path) },
                                     set: { on in if on { store.checked.insert(node.path) } else { store.checked.remove(node.path) } }))
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!canTrash)
                .help(canTrash ? "묶음 휴지통에 넣기" : "휴지통으로 옮길 수 없는 칸입니다(보기만)")
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 4, height: item.context == nil ? 30 : 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: node.isDirectory ? "folder" : "doc").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(node.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(DiskMapFormat.size(node.bytes)).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                }
                HStack(spacing: 4) {
                    ForEach(DiskTag.ordered(node.tags).prefix(2), id: \.self) { tag in
                        Text(tag.label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tag.mapColor)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(tag.mapColor.opacity(0.14)))
                            .lineLimit(1)
                    }
                    if node.partial {
                        Text("⋯ 하한").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.orange)
                            .help("끝까지 세지 못했습니다(권한·시간 제한) — 실제는 이보다 클 수 있습니다")
                    }
                    Spacer(minLength: 4)
                    shareBar(node)
                }
                if let context = item.context {
                    Text(context).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
            if node.isDirectory {
                Button { store.drillDown(node) } label: { Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).frame(width: 14, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("들어가 보기")
            } else {
                Color.clear.frame(width: 14, height: 24)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor.opacity(0.18) : hover || store.hovered == node.path ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if node.isDirectory { store.drillDown(node) } }
        .onTapGesture { store.select(node) }
        .onHover { inside in
            hover = inside
            if inside { store.hovered = node.path } else if store.hovered == node.path { store.hovered = nil }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func shareBar(_ node: DiskNode) -> some View {
        let fraction = total > 0 ? min(1, Double(node.bytes) / Double(total)) : 0
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.08))
            Capsule().fill(color.opacity(0.75)).frame(width: max(2, 44 * fraction))
        }
        .frame(width: 44, height: 4)
        .help("이 단계의 \(DiskMapFormat.share(node.bytes, of: total))")
    }
}

// MARK: - 설명판(무엇인지 · 할 수 있는 일)

struct DiskMapDetailPane: View {
    @ObservedObject var store: DiskMapStore

    var body: some View {
        CardBox {
            if let node = store.selectedNode ?? store.currentNode {
                detail(node)
            } else {
                overview
            }
        }
    }

    @ViewBuilder
    private func detail(_ node: DiskNode) -> some View {
        let color = DiskTag.mapColor(for: node.tags)
        let isCurrent = store.path.last == node.path
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(color.opacity(0.18))
                Image(systemName: DiskTag.dominant(node.tags)?.mapSymbol ?? (node.isDirectory ? "folder" : "doc")).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(node.name).font(.system(size: 14, weight: .bold)).lineLimit(2).textSelection(.enabled)
                DiskMapFlowLayout(spacing: 5, lineSpacing: 4) {
                    if isCurrent { DetailCard.Tag(text: "지금 들어와 있는 폴더", color: .accentColor) }
                    ForEach(DiskTag.ordered(node.tags), id: \.self) { tag in DetailCard.Tag(text: tag.label, color: tag.mapColor) }
                    if node.tags.isEmpty { DetailCard.Tag(text: "태그 없음", color: .gray) }
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text(DiskMapFormat.size(node.bytes)).font(.system(size: 18, weight: .bold).monospacedDigit())
                if node.partial { Text("하한").font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange) }
            }
        }
        VStack(alignment: .leading, spacing: 4) {
            DetailCard.Row(label: "경로", value: DiskMapFormat.home(node.path))
            DetailCard.Row(label: "크기", value: sizeLine(node))
            DetailCard.Row(label: "파일 수", value: "\(node.fileCount.formatted())개" + (node.partial ? " 이상" : ""))
            DetailCard.Row(label: "마지막 수정", value: node.modified.map { Fmt.ago($0) + " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "확인 안 됨")
            DetailCard.Row(label: "종류", value: node.isDirectory ? (node.tags.contains(.bundle) ? "번들(통째로 다룸)" : "폴더") : "파일")
        }
        if let hint = node.hint {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(hint).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
            }
        }
        if node.partial {
            Text("끝까지 세지 못했습니다(권한·시간 제한) — 숫자는 하한이고 실제는 더 클 수 있습니다.").font(.system(size: 10.5)).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        Text("할 수 있는 일").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
        actionButtons(node, isCurrent: isCurrent)
        actionNotes(node)
        if let note = store.note {
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    private func sizeLine(_ node: DiskNode) -> String {
        var parts = [DiskMapFormat.size(node.bytes) + (node.partial ? " 이상" : "")]
        let total = store.levelTotal
        if store.displayed.contains(where: { $0.node.path == node.path }), total > 0 { parts.append("이 단계의 \(DiskMapFormat.share(node.bytes, of: total))") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actionButtons(_ node: DiskNode, isCurrent: Bool) -> some View {
        let actions = node.actions
        let busy = store.busy.contains(node.path)
        DiskMapFlowLayout(spacing: 6, lineSpacing: 6) {
            if actions.contains(.trash) {
                Button { store.perform(.trash, on: node) } label: { Label("휴지통으로", systemImage: "trash") }
                    .buttonStyle(.borderedProminent)
                    .help("휴지통으로 옮깁니다(되돌릴 수 있음) · 복구 금고에 기록합니다")
            }
            if actions.contains(.deletePermanently) && node.isSafeToDeletePermanently {
                Button(role: .destructive) { store.perform(.deletePermanently, on: node) } label: { Label("영구 삭제", systemImage: "xmark.bin").foregroundStyle(.red) }
                    .buttonStyle(.bordered).tint(.red)
                    .help("휴지통을 거치지 않고 지웁니다 — 되돌릴 수 없고 다시 만들어질 때만 돌아옵니다")
            }
            if actions.contains(.prune) {
                Button { store.perform(.prune, on: node) } label: { Label("정리 명령 실행", systemImage: "terminal") }
                    .buttonStyle(.bordered)
                    .help("먼저 무엇을 지울지 미리보기를 보여 주고, 확인하면 실행합니다")
            }
            if actions.contains(.reveal) {
                Button { store.perform(.reveal, on: node) } label: { Label("Finder에서 보기", systemImage: "folder") }
                    .buttonStyle(.bordered)
            }
            if node.isDirectory && !isCurrent {
                Button { store.drillDown(node) } label: { Label("들어가 보기", systemImage: "arrow.down.forward.circle") }
                    .buttonStyle(.bordered)
            }
            if !node.isDirectory && DiskMapTree.find(node.path, in: store.roots) == nil {
                Button { store.locate(node.path) } label: { Label("지도에서 위치 보기", systemImage: "scope") }
                    .buttonStyle(.bordered)
            }
            if busy {
                ProgressView().controlSize(.small)
            }
        }
        .controlSize(.small)
        .disabled(busy)
    }

    @ViewBuilder
    private func actionNotes(_ node: DiskNode) -> some View {
        let actions = node.actions
        VStack(alignment: .leading, spacing: 4) {
            if actions.contains(.deletePermanently) && node.isSafeToDeletePermanently {
                Text("영구 삭제는 되돌릴 수 없습니다 — 다시 만들어질 때(재설치·재빌드·다시 받기)만 돌아옵니다.")
                    .foregroundStyle(.red)
            } else if actions.contains(.deletePermanently) {
                Text("영구 삭제는 막았습니다 — 사용자 파일·AI 기록·시스템 영역이 섞였을 수 있는 칸입니다. 휴지통을 쓰세요.")
                    .foregroundStyle(.secondary)
            }
            if actions.contains(.prune) {
                Text("정리 명령은 먼저 미리보기를 보여 드리고, 확인하면 실행합니다.").foregroundStyle(.secondary)
            }
            if !actions.contains(where: { $0 == .trash || $0 == .deletePermanently || $0 == .prune }) {
                Text(viewOnlyReason(node)).foregroundStyle(.secondary)
            }
            if actions.contains(where: { $0 == .trash || $0 == .deletePermanently || $0 == .prune }) {
                Label("휴지통·영구 삭제·정리 명령은 실행 전에 한 번 묻고, 모두 복구 금고에 기록합니다", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func viewOnlyReason(_ node: DiskNode) -> String {
        let tags = node.tags
        if tags.contains(.swap) { return "보기만 합니다 — 스왑은 macOS가 관리합니다. 메모리를 많이 쓰는 세션을 정리하면 줄어듭니다." }
        if tags.contains(.snapshot) { return "보기만 합니다 — 로컬 스냅샷은 Time Machine이 관리하고, 공간이 모자라면 macOS가 먼저 지웁니다." }
        if tags.contains(.aiTranscript) { return "보기만 합니다 — AI 대화 기록은 세션을 되살리는 복구 자원이라 지우지 않습니다." }
        if tags.contains(.trash) { return "이미 휴지통 안입니다 — Finder에서 '휴지통 비우기'를 하면 공간이 돌아옵니다(ReMON은 비우지 않습니다)." }
        if tags.contains(.system) { return "보기만 합니다 — macOS·관리자 영역입니다." }
        if tags.contains(.bundle) { return "앱·번들은 통째로 다룹니다 — 지우려면 Finder에서 휴지통으로 옮기세요." }
        return node.isDirectory ? "이 폴더 통째로는 조치하지 않습니다 — 안으로 들어가 필요 없는 것만 고르세요." : "보기만 합니다."
    }

    @ViewBuilder
    private var overview: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("디스크 지도").font(.system(size: 14, weight: .bold))
            if store.roots.isEmpty {
                Text(store.scanning ? "살펴보는 중입니다…" : "아직 조사하지 않았습니다").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Text("\(store.roots.count)곳 · \(DiskMapFormat.size(store.roots.reduce(UInt64(0)) { $0 + $1.bytes }))").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        Text("트리맵의 칸을 누르면 안으로 들어가고, 오른쪽 목록에서 고르면 여기에 무엇인지와 할 수 있는 일이 나옵니다. 기본은 휴지통이고, 영구 삭제는 다시 생기는 캐시에만 있습니다. 조치는 모두 복구 금고에 기록합니다.")
            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if !store.tagStats.isEmpty {
            Divider()
            Text("색 = 대표 태그").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            DiskMapFlowLayout(spacing: 8, lineSpacing: 5) {
                ForEach(DiskTag.ordered(Set(store.tagStats.map(\.tag))), id: \.self) { tag in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tag.mapColor.opacity(0.55)).frame(width: 10, height: 10)
                        Text(tag.label).font(.system(size: 10.5))
                    }
                }
            }
        }
        if let note = store.note {
            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 큰 파일

struct DiskMapLargeFiles: View {
    @ObservedObject var store: DiskMapStore
    @State private var showAll = false

    var body: some View {
        let files = store.largeFiles
        let visible = showAll ? Array(files.prefix(40)) : Array(files.prefix(10))
        CardBox {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("큰 파일").font(.system(size: 13, weight: .semibold))
                Text("\(Fmt.gb(store.largeFileMinimum)) 이상 · 뿌리 아래 전체").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                if store.largeScanning {
                    ProgressView().controlSize(.small)
                } else if !files.isEmpty {
                    Text("\(files.count)개 · \(DiskMapFormat.size(files.reduce(UInt64(0)) { $0 + $1.bytes }))").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if files.isEmpty {
                Text(store.largeScanning ? "큰 파일을 찾는 중입니다…" : store.lastScan == nil ? "조사하면 큰 파일을 찾아 보여 줍니다." : "기준을 넘는 파일을 찾지 못했습니다(시간 제한 안에서 찾은 것만 보입니다).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(spacing: 1) {
                ForEach(visible) { file in row(file) }
            }
            if files.count > 10 {
                Button(showAll ? "줄이기" : "더 보기 · \(min(files.count, 40) - 10)개") { showAll.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }
        }
    }

    private func row(_ file: DiskNode) -> some View {
        let tag = DiskTag.dominant(file.tags.subtracting([.large]))
        let selected = store.selection == file.path
        return HStack(spacing: 8) {
            Image(systemName: tag?.mapSymbol ?? "doc").font(.system(size: 11)).foregroundStyle(tag?.mapColor ?? .secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(DiskMapFormat.home((file.path as NSString).deletingLastPathComponent)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            if let tag {
                Text(tag.label).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(tag.mapColor)
                    .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(tag.mapColor.opacity(0.14))).lineLimit(1).fixedSize()
            }
            Text(Fmt.ago(file.modified)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Text(DiskMapFormat.size(file)).font(.system(size: 11.5, weight: .semibold).monospacedDigit()).frame(minWidth: 52, alignment: .trailing)
            Button { store.locate(file.path) } label: { Image(systemName: "scope").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("지도에서 위치 보기")
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { store.select(file) }
    }
}

// MARK: - 줄바꿈 배치(칩·버튼)

struct DiskMapFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            if x > 0 && x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: maxWidth.isFinite ? min(widest, maxWidth) : widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            size.width = min(size.width, bounds.width)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
