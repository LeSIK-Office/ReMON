import ReMONCore
import SwiftUI

// 지도 조사 전에는 아는 자료를, 조사 뒤에는 실제 경로를 중복 없이 합친 구성을 보여 준다.
// 정리 후보는 조치 직전에 사용 여부·보호 정책을 다시 확인하므로 실제 확보 공간과 다를 수 있다.

struct DiskCompositionRow: Identifiable, Equatable {
    var tag: DiskTag
    var total: UInt64
    var reclaimable: UInt64
    var id: String { tag.rawValue }

    var color: Color { DiskCompositionRow.color(for: tag) }

    /// 실제 경로만 한 번씩 센다. 부모 용량은 자식과 나머지로 나누고, 여러 태그 중 지도와 같은 대표 태그를 쓴다.
    static func summarize(_ roots: [DiskNode]) -> [DiskCompositionRow] {
        var totals: [DiskTag: DiskCompositionRow] = [:]
        var seen = Set<String>()
        func visit(_ node: DiskNode, budget: UInt64, cleanableParent: Bool = false) -> UInt64 {
            guard !node.isVirtual, seen.insert(node.path).inserted else { return 0 }
            let bytes = min(node.bytes, budget)
            let cleanable = cleanableParent || node.actions.contains(.trash) || node.actions.contains(.prune)
                || (node.actions.contains(.deletePermanently) && node.isSafeToDeletePermanently)
            var remaining = bytes
            for child in node.children ?? [] {
                remaining -= visit(child, budget: remaining, cleanableParent: cleanable)
            }
            let tag = DiskTag.dominant(node.tags.subtracting([.large])) ?? .userFile
            if remaining > 0 {
                var row = totals[tag] ?? DiskCompositionRow(tag: tag, total: 0, reclaimable: 0)
                row.total += remaining
                if cleanable { row.reclaimable += remaining }
                totals[tag] = row
            }
            return bytes
        }
        for root in DiskMapTree.outermost(roots.filter { !$0.isVirtual }) { _ = visit(root, budget: root.bytes) }
        return totals.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
    }

    static func color(for tag: DiskTag) -> Color {
        switch tag {
        case .cache: .teal
        case .regenerable: .mint
        case .aiTranscript: .purple
        case .aiData: .indigo
        case .gitByproduct: .orange
        case .docker: .blue
        case .xcode: .cyan
        case .homebrew: .brown
        case .temp: .yellow
        case .trash: .gray
        case .download: .pink
        case .backup: Color(red: 0.6, green: 0.4, blue: 0.2)
        case .snapshot: Color(red: 0.4, green: 0.5, blue: 0.6)
        case .swap: Color(red: 0.8, green: 0.5, blue: 0.3)
        case .system: Color(white: 0.45)
        case .bundle: .green
        case .large: .red
        case .userFile: Color(white: 0.7)
        }
    }
}

extension AppModel {
    /// 꼬리표별 합계(큰 것부터). 지도 조사 결과가 있으면 그것을, 없으면 지금 아는 자료로.
    var diskComposition: [DiskCompositionRow] {
        var totals: [DiskTag: (total: UInt64, reclaimable: UInt64)] = [:]
        func add(_ tag: DiskTag, _ bytes: UInt64, reclaimable: UInt64 = 0) {
            guard bytes > 0 else { return }
            totals[tag, default: (0, 0)].total += bytes
            totals[tag, default: (0, 0)].reclaimable += reclaimable
        }
        if let rows = diskMapComposition, !rows.isEmpty {
            for row in rows { add(row.tag, row.total, reclaimable: row.reclaimable) }
        } else {
            let active = Set((office?.sessions ?? []).compactMap(\.cwd))
            for item in diskItems {
                let tier = CacheDeletionPolicy.tier(for: item, activeDirectories: active)
                let now = tier != .trashOnly && CacheDeletionPolicy.blockReason(for: item) == nil ? item.bytes : 0
                switch item.category {
                case .regenerable:
                    let group = DiskCatalog.group(of: item)
                    let tag: DiskTag = group == .xcode || group == .simulators ? .xcode : group == .homebrew ? .homebrew : group == .projects ? .regenerable : .cache
                    add(tag, item.bytes, reclaimable: now)
                case .temporary: add(.temp, item.bytes, reclaimable: now)
                case .trash: add(.trash, item.bytes)
                case .aiLogs: add(.aiTranscript, item.bytes)
                case .bigDatabase: add(.aiData, item.bytes)
                case .keep: add(.system, item.bytes)
                }
            }
            for project in leftovers {
                add(.gitByproduct, project.worktrees.reduce(UInt64(0)) { $0 + $1.bytes }, reclaimable: project.cleanableBytes)
            }
            add(.swap, system.swap.used)
        }
        return totals.map { DiskCompositionRow(tag: $0.key, total: $0.value.total, reclaimable: $0.value.reclaimable) }.sorted { $0.total > $1.total }
    }
}

/// 분류별 막대 + 줄: 기계 카드·대시보드 카드에 같이 쓴다.
struct DiskCompositionView: View {
    let rows: [DiskCompositionRow]
    var compact = false
    var onSelect: ((DiskTag) -> Void)? = nil

    var body: some View {
        let total = rows.reduce(UInt64(0)) { $0 + $1.total }
        let reclaimable = rows.reduce(UInt64(0)) { $0 + $1.reclaimable }
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("조사한 용량 · \(Fmt.size(total))").font(.system(size: 12, weight: .semibold))
                if reclaimable > 0 { Text("정리 후보 \(Fmt.size(reclaimable)) · 실행 전 재확인").font(.system(size: 10.5)).foregroundStyle(.teal) }
            }
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(rows) { row in
                        RoundedRectangle(cornerRadius: 2).fill(row.color)
                            .frame(width: proxy.size.width * CGFloat(Double(row.total) / Double(max(1, total))))
                            .help("\(row.tag.label) · \(Fmt.gb(row.total))")
                    }
                }
            }
            .frame(height: compact ? 8 : 12)
            ForEach(rows.prefix(compact ? 5 : 10)) { row in
                Button { onSelect?(row.tag) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(row.color).frame(width: 7, height: 7)
                        Text(row.tag.label).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 4)
                        if !compact, row.reclaimable > 0 { Text("후보 \(Fmt.size(row.reclaimable))").font(.system(size: 9.5)).foregroundStyle(.teal) }
                        Text(Fmt.size(row.total)).font(.system(size: 11, weight: .semibold).monospacedDigit()).fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onSelect == nil)
            }
            if rows.isEmpty { Text("아직 디스크를 조사하지 않았습니다.").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}
