import ReMONCore
import SwiftUI

// 디스크 지도의 트리맵: 지금 단계의 칸들을 크기 비례 사각형으로(정사각형에 가깝게) 나눠 그린다.
// 색 = 대표 태그, 글자 = 이름 + 크기, 큰 폴더 칸 안에는 한 단계 아래 칸까지(구조가 보이게).
// 마우스를 올리면 설명, 누르면 폴더는 들어가고 파일은 고른다.

/// Squarified 트리맵 배치(Bruls·Huizing·van Wijk 2000). 값의 순서대로 사각형을 돌려준다(0 이하는 크기 0).
/// 큰 값부터 넣어야 가장 정사각형에 가깝다.
enum DiskMapSquarify {
    static func layout(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var rects = Array(repeating: CGRect(origin: rect.origin, size: .zero), count: values.count)
        let order = values.indices.filter { values[$0] > 0 && values[$0].isFinite }
        let total = order.reduce(0.0) { $0 + values[$1] }
        guard total > 0, rect.width > 0, rect.height > 0 else { return rects }
        let scale = Double(rect.width) * Double(rect.height) / total
        var remaining = rect
        var start = 0
        while start < order.count {
            let side = Double(min(remaining.width, remaining.height))
            var sum = values[order[start]] * scale
            var end = start + 1
            if side <= 0.5 {
                // 남은 자리가 실처럼 가늘다(아주 작은 칸들): 나머지를 한 줄에 몰아 비율대로 나눈다 — 가는 변으로 나누지 않게.
                end = order.count
                sum = order[start...].reduce(0.0) { $0 + values[$1] * scale }
            } else {
                var rowMax = sum, rowMin = sum
                var worst = aspect(maxArea: rowMax, minArea: rowMin, sum: sum, side: side)
                while end < order.count {
                    let area = values[order[end]] * scale
                    let candidate = aspect(maxArea: max(rowMax, area), minArea: min(rowMin, area), sum: sum + area, side: side)
                    if candidate > worst { break }
                    sum += area; rowMax = max(rowMax, area); rowMin = min(rowMin, area); worst = candidate; end += 1
                }
            }
            let last = end == order.count
            let row = Array(order[start..<end])
            if remaining.width >= remaining.height {
                // 왼쪽에 세로 한 줄
                let width = last ? remaining.width : min(remaining.width, CGFloat(sum / Double(remaining.height)))
                var y = remaining.minY
                for (offset, index) in row.enumerated() {
                    let height = offset == row.count - 1 ? remaining.maxY - y : CGFloat(values[index] * scale / Double(width))
                    rects[index] = CGRect(x: remaining.minX, y: y, width: width, height: max(0, height))
                    y += height
                }
                remaining = CGRect(x: remaining.minX + width, y: remaining.minY, width: max(0, remaining.width - width), height: remaining.height)
            } else {
                // 위쪽에 가로 한 줄
                let height = last ? remaining.height : min(remaining.height, CGFloat(sum / Double(remaining.width)))
                var x = remaining.minX
                for (offset, index) in row.enumerated() {
                    let width = offset == row.count - 1 ? remaining.maxX - x : CGFloat(values[index] * scale / Double(height))
                    rects[index] = CGRect(x: x, y: remaining.minY, width: max(0, width), height: height)
                    x += width
                }
                remaining = CGRect(x: remaining.minX, y: remaining.minY + height, width: remaining.width, height: max(0, remaining.height - height))
            }
            start = end
        }
        return rects
    }

    /// 한 줄에서 가장 길쭉한 칸의 가로세로비(1에 가까울수록 정사각형).
    static func aspect(maxArea: Double, minArea: Double, sum: Double, side: Double) -> Double {
        guard sum > 0, side > 0, minArea > 0 else { return .infinity }
        let sumSquared = sum * sum, sideSquared = side * side
        return max(sideSquared * maxArea / sumSquared, sumSquared / (sideSquared * minArea))
    }
}

/// 트리맵 한 칸: 실제 칸 · 너무 작아 묶은 '그 외' · 폴더 바로 아래 파일(따로 나누지 않은 나머지).
struct DiskMapTile: Identifiable {
    enum Kind: Equatable { case node, rest(Int), loose }
    let id: String
    let kind: Kind
    let node: DiskNode?
    let bytes: UInt64
    var rect: CGRect = .zero
    /// 색을 고를 때 뺄 태그(같은 묶음의 모든 칸에 붙은 것 — 모두 같은 색이면 아무것도 말하지 않으므로).
    var shared: Set<DiskTag> = []
    /// 안쪽 칸(한 단계만). 좌표는 이 칸의 그림(테두리 안쪽) 기준.
    var children: [DiskMapTile] = []

    var color: Color { kind == .node ? DiskTag.mapColor(for: node?.tags ?? [], excluding: shared) : Color.gray }
    var isNested: Bool { !children.isEmpty }

    /// 안쪽 칸을 그릴 때 위쪽 이름 줄 높이.
    static let headerHeight: CGFloat = 19

    /// 칸 목록을 사각형으로 나눈다. 너무 작은 칸(면적 minArea 미만)·maxTiles 넘는 칸은 '그 외'로 묶는다.
    /// nest = 큰 폴더 칸 안에 (이미 펼친) 자식 칸을 한 단계 더 그린다.
    static func make(items: [DiskNode], looseBytes: UInt64, size: CGSize, maxTiles: Int = 40, minArea: CGFloat = 320, nest: Bool = true) -> [DiskMapTile] {
        let positive = DiskMapTree.sortedBySize(items.filter { $0.bytes > 0 })
        let total = Double(positive.reduce(UInt64(0)) { $0 + $1.bytes } + looseBytes)
        guard total > 0, size.width > 8, size.height > 8 else { return [] }
        let area = Double(size.width * size.height)
        let shared = DiskTag.shared(by: positive)
        var tiles: [DiskMapTile] = []
        var rest: [DiskNode] = []
        for node in positive {
            if tiles.count < maxTiles && Double(node.bytes) / total * area >= Double(minArea) {
                tiles.append(DiskMapTile(id: node.path, kind: .node, node: node, bytes: node.bytes, shared: shared))
            } else {
                rest.append(node)
            }
        }
        if rest.count == 1, let only = rest.first {
            tiles.append(DiskMapTile(id: only.path, kind: .node, node: only, bytes: only.bytes, shared: shared))
        } else if !rest.isEmpty {
            tiles.append(DiskMapTile(id: "·rest", kind: .rest(rest.count), node: nil, bytes: rest.reduce(0) { $0 + $1.bytes }))
        }
        if looseBytes > 0 { tiles.append(DiskMapTile(id: "·loose", kind: .loose, node: nil, bytes: looseBytes)) }
        tiles.sort { $0.bytes > $1.bytes }
        let rects = DiskMapSquarify.layout(tiles.map { Double($0.bytes) }, in: CGRect(origin: .zero, size: size))
        for index in tiles.indices { tiles[index].rect = rects[index] }
        guard nest else { return tiles }
        for index in tiles.indices {
            guard let node = tiles[index].node, node.isDirectory, let children = node.children, !children.isEmpty else { continue }
            let rect = tiles[index].rect
            // 그림은 사방 1pt 안쪽(칸 사이 틈). 그 안에서 이름 줄 아래를 자식 칸 자리로 쓴다.
            let inner = CGRect(x: 3, y: headerHeight + 1, width: rect.width - 2 - 6, height: rect.height - 2 - headerHeight - 4)
            guard rect.width >= 120, rect.height >= 92, inner.width >= 60, inner.height >= 44 else { continue }
            var sub = make(items: children, looseBytes: DiskMapTree.looseBytes(of: node), size: inner.size, maxTiles: 18, minArea: 220, nest: false)
            for k in sub.indices {
                sub[k].rect = sub[k].rect.offsetBy(dx: inner.minX, dy: inner.minY)
                // 안쪽 칸도 이 단계와 같은 규칙으로 색을 고른다 — 자기 태그가 다를 때만 바깥 칸과 다른 색.
                sub[k].shared = shared
            }
            tiles[index].children = sub
        }
        return tiles
    }
}

struct DiskMapTreemap: View {
    @ObservedObject var store: DiskMapStore

    var body: some View {
        let items = store.displayed.map(\.node)
        let loose = store.looseBytes
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let tiles = DiskMapTile.make(items: items, looseBytes: loose, size: proxy.size)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03))
                    ForEach(tiles) { tile in
                        tileView(tile)
                            .frame(width: max(0, tile.rect.width - 2), height: max(0, tile.rect.height - 2))
                            .offset(x: tile.rect.minX + 1, y: tile.rect.minY + 1)
                    }
                    if tiles.isEmpty { emptyState.frame(width: proxy.size.width, height: proxy.size.height) }
                }
            }
            hoverLine
        }
    }

    @ViewBuilder
    private func tileView(_ tile: DiskMapTile) -> some View {
        ZStack(alignment: .topLeading) {
            interactive(DiskMapTileView(tile: tile, selected: isSelected(tile), hovered: isHovered(tile), checked: isChecked(tile)), tile, parent: nil)
            ForEach(tile.children) { child in
                interactive(DiskMapTileView(tile: child, selected: isSelected(child), hovered: isHovered(child), checked: isChecked(child), compact: true), child, parent: tile.node)
                    .frame(width: max(0, child.rect.width - 1.5), height: max(0, child.rect.height - 1.5))
                    .offset(x: child.rect.minX + 0.75, y: child.rect.minY + 0.75)
            }
        }
    }

    private func isSelected(_ tile: DiskMapTile) -> Bool { tile.node.map { store.selection == $0.path } ?? false }
    private func isHovered(_ tile: DiskMapTile) -> Bool { tile.node.map { store.hovered == $0.path } ?? false }
    private func isChecked(_ tile: DiskMapTile) -> Bool { tile.node.map { store.checked.contains($0.path) } ?? false }

    /// 누르기·올리기·오른쪽 클릭·접근성. 안쪽 칸에서 나가면 바깥 칸을 다시 가리킨다.
    private func interactive<Content: View>(_ content: Content, _ tile: DiskMapTile, parent: DiskNode?) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                // 실제 칸은 들어가거나 고르고, 안쪽의 '그 외'·'폴더 안 파일' 묶음은 그 폴더로 들어가 모두 보여 준다.
                if let node = tile.node { store.activate(node) } else if let parent { store.drillDown(parent) }
            }
            .onHover { inside in
                guard let node = tile.node else { return }
                if inside { store.hovered = node.path } else if store.hovered == node.path { store.hovered = parent?.path }
            }
            .help(help(tile, parent: parent))
            .contextMenu {
                if let node = tile.node {
                    Button("자세히 보기") { store.select(node) }
                    if node.isDirectory { Button("들어가 보기") { store.drillDown(node) } }
                    if node.actions.contains(.reveal) { Button("Finder에서 보기") { store.perform(.reveal, on: node) } }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibility(tile))
            .accessibilityAddTraits(tile.node == nil ? [] : .isButton)
    }

    private func help(_ tile: DiskMapTile, parent: DiskNode?) -> String {
        switch tile.kind {
        case .node:
            guard let node = tile.node else { return "" }
            let tags = node.tags.isEmpty ? nil : DiskTag.ordered(node.tags).map(\.label).joined(separator: " · ")
            return ([node.name + " · " + DiskMapFormat.size(node)] + [tags, node.hint, node.isDirectory ? "누르면 안으로 들어갑니다" : nil].compactMap { $0 }).joined(separator: "\n")
        case .rest(let count): return "작은 칸 \(count)개 · \(DiskMapFormat.size(tile.bytes))" + (parent == nil ? " — 오른쪽 목록에서 모두 볼 수 있습니다" : " — 들어가면 모두 볼 수 있습니다")
        case .loose: return "이 폴더 바로 아래의 파일들 · \(DiskMapFormat.size(tile.bytes)) — 따로 나누지 않은 나머지입니다"
        }
    }

    private func accessibility(_ tile: DiskMapTile) -> String {
        switch tile.kind {
        case .node: (tile.node?.name ?? "") + ", " + DiskMapFormat.size(tile.bytes)
        case .rest(let count): "그 외 \(count)개, " + DiskMapFormat.size(tile.bytes)
        case .loose: "폴더 바로 아래 파일, " + DiskMapFormat.size(tile.bytes)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if store.isExpandingCurrent || (store.scanning && store.roots.isEmpty) {
                ProgressView().controlSize(.small)
                Text(store.roots.isEmpty ? "디스크를 살펴보는 중입니다…" : "이 폴더를 펼치는 중입니다…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if !store.filter.isEmpty {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 22)).foregroundStyle(.secondary)
                Text("고른 태그에 맞는 칸이 이 단계에는 없습니다(펼친 곳까지만 찾습니다).").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("필터 해제") { store.filter = [] }.controlSize(.small)
            } else if store.lastScan == nil {
                Image(systemName: "square.grid.3x3.square").font(.system(size: 22)).foregroundStyle(.secondary)
                Text("'다시 조사'를 누르면 디스크를 읽기 전용으로 살펴봅니다.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "tray").font(.system(size: 22)).foregroundStyle(.secondary)
                Text("비어 있습니다.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(20)
    }

    /// 마우스를 올린 칸의 설명 한 줄(툴팁은 늦게 뜨므로 아래에 바로 보여 준다).
    private var hoverLine: some View {
        HStack(spacing: 6) {
            if let node = store.hoveredNode {
                Circle().fill(DiskTag.mapColor(for: node.tags)).frame(width: 8, height: 8)
                Text(node.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(DiskMapFormat.size(node)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                ForEach(DiskTag.ordered(node.tags).prefix(3), id: \.self) { tag in
                    Text(tag.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tag.mapColor).lineLimit(1).fixedSize()
                }
                Text(node.hint ?? (node.isDirectory ? "누르면 안으로 들어갑니다" : "누르면 자세히 봅니다")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            } else {
                Image(systemName: "cursorarrow.rays").font(.system(size: 10)).foregroundStyle(.tertiary)
                Text("칸에 마우스를 올리면 무엇인지, 누르면 폴더는 안으로 들어가고 파일은 자세히 봅니다 · 오른쪽 클릭 = 들어가지 않고 보기")
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }
}

/// 트리맵 칸 하나(그림만 — 누르기는 DiskMapTreemap이 붙인다). compact = 큰 칸 안의 안쪽 칸.
struct DiskMapTileView: View {
    let tile: DiskMapTile
    let selected: Bool
    let hovered: Bool
    var checked = false
    var compact = false

    var body: some View {
        let color = tile.color
        let shape = RoundedRectangle(cornerRadius: compact ? 3.5 : 5, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(color.opacity(fillOpacity))
            if tile.kind != .node {
                // 묶음 칸은 빗금으로 '실제 한 칸이 아님'을 보인다.
                Hatch().stroke(color.opacity(0.22), lineWidth: 1).clipShape(shape)
            }
            shape.strokeBorder(selected ? Color.accentColor : color.opacity(hovered ? 0.95 : compact ? 0.45 : 0.6), lineWidth: selected ? 2.5 : 1)
            if tile.isNested { header } else { label }
            if checked && tile.rect.width >= 30 && tile.rect.height >= 22 {
                Image(systemName: "checkmark.circle.fill").font(.system(size: compact ? 10 : 13, weight: .semibold))
                    .foregroundStyle(Color.white, Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(compact ? 2 : 4)
            }
        }
    }

    private var fillOpacity: Double {
        if tile.kind != .node { return 0.14 }
        if tile.isNested { return hovered ? 0.24 : 0.13 }   // 바깥 칸은 옅게 — 안쪽 칸이 보이도록
        return hovered ? 0.5 : compact ? 0.34 : 0.3
    }

    private var title: String {
        switch tile.kind {
        case .node: tile.node?.name ?? ""
        case .rest(let count): "그 외 \(count)개"
        case .loose: "폴더 안 파일"
        }
    }

    private var sizeText: String { tile.node.map(DiskMapFormat.size) ?? DiskMapFormat.size(tile.bytes) }

    /// 안쪽 칸을 품은 큰 폴더: 위에 한 줄(이름 · 크기).
    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill").font(.system(size: 9)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(sizeText).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(height: DiskMapTile.headerHeight)
    }

    @ViewBuilder
    private var label: some View {
        let width = tile.rect.width, height = tile.rect.height
        if compact {
            if width >= 38 && height >= 30 {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 9.5, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    Text(sizeText).font(.system(size: 8.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 3).padding(.vertical, 2)
            } else if width >= 30 && height >= 14 {
                Text(title).font(.system(size: 8.5, weight: .semibold)).lineLimit(1).truncationMode(.tail).padding(.horizontal, 2).padding(.vertical, 1)
            }
        } else if width >= 54 && height >= 36 {
            let big = width >= 120 && height >= 48
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if tile.node?.isDirectory == true && width >= 90 { Image(systemName: "folder.fill").font(.system(size: 8.5)).foregroundStyle(.secondary) }
                    Text(title).font(.system(size: big ? 12 : 10.5, weight: .semibold)).lineLimit(height >= 64 && width < 110 ? 2 : 1).truncationMode(.middle)
                }
                Text(sizeText).font(.system(size: big ? 11 : 9.5).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                if let node = tile.node, width >= 150 && height >= 76 {
                    // 큰 칸은 무엇인지(태그)와 설명까지 — 빈 자리를 정보로 쓴다.
                    let tags = DiskTag.ordered(node.tags).prefix(2).map(\.label).joined(separator: " · ")
                    if !tags.isEmpty { Text(tags).font(.system(size: 10, weight: .semibold)).foregroundStyle(tile.color).lineLimit(1).padding(.top, 3) }
                    if let hint = node.hint, width >= 190 && height >= 120 {
                        Text(hint).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true).padding(.top, 1)
                    }
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 4)
        } else if width >= 34 && height >= 16 {
            Text(title).font(.system(size: 9, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 3).padding(.vertical, 2)
        }
    }

    /// 빗금(묶음 칸 표시).
    private struct Hatch: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 7
            }
            return path
        }
    }
}

// MARK: - 태그 색·순서(화면 전용)

extension DiskTag {
    /// 칸 색을 정하는 대표 태그 순서: '무엇인지'를 가장 잘 말해 주는 것부터(휴지통 > 스왑 > … > 사용자 파일 > 큰 파일).
    static let mapPriority: [DiskTag] = [.trash, .swap, .snapshot, .docker, .xcode, .homebrew, .aiTranscript, .aiData, .gitByproduct,
                                         .temp, .cache, .regenerable, .backup, .download, .system, .bundle, .userFile, .large]

    static func dominant(_ tags: Set<DiskTag>) -> DiskTag? { mapPriority.first { tags.contains($0) } }

    static func ordered(_ tags: Set<DiskTag>) -> [DiskTag] { mapPriority.filter { tags.contains($0) } }

    static func mapColor(for tags: Set<DiskTag>) -> Color { dominant(tags)?.mapColor ?? Color.gray }

    /// 같은 묶음의 모든 칸에 붙은 태그는 빼고 색을 고른다(남는 태그가 없으면 원래 대표 태그).
    static func mapColor(for tags: Set<DiskTag>, excluding shared: Set<DiskTag>) -> Color {
        (dominant(tags.subtracting(shared)) ?? dominant(tags))?.mapColor ?? Color.gray
    }

    /// 칸이 둘 이상일 때 모두에게 붙은 태그.
    static func shared(by nodes: [DiskNode]) -> Set<DiskTag> {
        guard nodes.count >= 2, let first = nodes.first?.tags else { return [] }
        return nodes.dropFirst().reduce(first) { $0.intersection($1.tags) }
    }

    var mapColor: Color {
        switch self {
        case .trash: .pink
        case .swap: .red
        case .snapshot: Color(red: 0.45, green: 0.52, blue: 0.62)
        case .docker: .blue
        case .xcode: .indigo
        case .homebrew: .brown
        case .aiTranscript: .teal
        case .aiData: .cyan
        case .gitByproduct: .purple
        case .temp: .yellow
        case .cache: .orange
        case .regenerable: .mint
        case .backup: Color(red: 0.55, green: 0.5, blue: 0.45)
        case .download: .green
        case .system: Color(red: 0.5, green: 0.5, blue: 0.55)
        case .bundle: Color(red: 0.35, green: 0.55, blue: 0.8)
        case .userFile: Color(red: 0.3, green: 0.5, blue: 0.95)
        case .large: Color(red: 0.82, green: 0.28, blue: 0.68)
        }
    }

    var mapSymbol: String {
        switch self {
        case .trash: "trash"
        case .swap: "memorychip"
        case .snapshot: "clock.arrow.circlepath"
        case .docker: "shippingbox"
        case .xcode: "hammer"
        case .homebrew: "mug"
        case .aiTranscript: "text.bubble"
        case .aiData: "brain"
        case .gitByproduct: "arrow.triangle.branch"
        case .temp: "hourglass"
        case .cache: "archivebox"
        case .regenerable: "arrow.clockwise"
        case .backup: "iphone"
        case .download: "arrow.down.circle"
        case .system: "gearshape"
        case .bundle: "app"
        case .userFile: "person"
        case .large: "scalemass"
        }
    }
}
