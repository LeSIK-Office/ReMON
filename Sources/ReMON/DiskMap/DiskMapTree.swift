import Foundation
import ReMONCore

// 디스크 지도의 나무 다루기(순수 함수). 화면·조사기와 무관하게 찾기·바꾸기·지우기·합치기·태그로 골라내기만 한다.

/// 필터 결과 한 줄: 칸 + (필터로 깊은 곳에서 찾았을 때) 지금 단계에서 본 위치.
struct DiskMapItem: Identifiable, Equatable {
    var id: String { node.path }
    let node: DiskNode
    /// 지금 단계 기준 상위 경로(예: "shop-web › .claude"). 지금 단계 바로 아래면 nil.
    var context: String? = nil
}

enum DiskMapTree {
    /// a가 b의 조상인가(경로 기준).
    static func isAncestor(_ a: String, of b: String) -> Bool {
        a == "/" ? b != "/" && b.hasPrefix("/") : b.hasPrefix(a + "/")
    }

    static func find(_ path: String, in nodes: [DiskNode]) -> DiskNode? {
        for node in nodes {
            if node.path == path { return node }
            if let children = node.children, let found = find(path, in: children) { return found }
        }
        return nil
    }

    /// 뿌리부터 path까지의 경로들(포함). 나무에 없으면 nil.
    static func chain(to path: String, in nodes: [DiskNode]) -> [String]? {
        for node in nodes {
            if node.path == path { return [node.path] }
            if let children = node.children, let rest = chain(to: path, in: children) { return [node.path] + rest }
        }
        return nil
    }

    /// path 칸을 바꾸고, 크기·파일 수가 달라지면 조상들에도 차이를 반영한다. 찾았으면 true.
    @discardableResult
    static func replace(_ path: String, in nodes: inout [DiskNode], with transform: (inout DiskNode) -> Void) -> Bool {
        for index in nodes.indices {
            if nodes[index].path == path {
                transform(&nodes[index])
                return true
            }
            guard nodes[index].children != nil else { continue }
            let before = find(path, in: nodes[index].children ?? [])
            guard let before else { continue }
            var children = nodes[index].children ?? []
            replace(path, in: &children, with: transform)
            let after = find(path, in: children)
            nodes[index].children = children
            if let after {
                nodes[index].bytes = adjusted(nodes[index].bytes, by: Int64(after.bytes) - Int64(before.bytes))
                nodes[index].fileCount = max(0, nodes[index].fileCount + after.fileCount - before.fileCount)
            }
            return true
        }
        return false
    }

    /// path 칸을 나무에서 빼고, 조상들의 크기·파일 수에서 덜어낸다. 뺀 칸을 돌려준다.
    @discardableResult
    static func remove(_ path: String, in nodes: inout [DiskNode]) -> DiskNode? {
        if let index = nodes.firstIndex(where: { $0.path == path }) { return nodes.remove(at: index) }
        for index in nodes.indices {
            guard var children = nodes[index].children, let removed = remove(path, in: &children) else { continue }
            nodes[index].children = children
            nodes[index].bytes = adjusted(nodes[index].bytes, by: -Int64(removed.bytes))
            nodes[index].fileCount = max(0, nodes[index].fileCount - removed.fileCount)
            return removed
        }
        return nil
    }

    /// 새 조사 결과를 예전 나무에 합친다: 값은 새것, 새 조사가 내려가지 않은 곳은 예전에 펼친 자식을 남긴다(들어가 있던 단계가 사라지지 않게).
    static func merge(old: DiskNode?, new: DiskNode) -> DiskNode {
        var result = new
        guard let oldChildren = old?.children else { return result }
        if let newChildren = new.children {
            var byPath: [String: DiskNode] = [:]
            for child in oldChildren where byPath[child.path] == nil { byPath[child.path] = child }
            result.children = newChildren.map { merge(old: byPath[$0.path], new: $0) }
        } else if new.isDirectory {
            result.children = oldChildren
        }
        return result
    }

    /// 태그가 하나라도 맞는 가장 바깥 칸들(맞은 칸 안으로는 더 들어가지 않는다 — 겹쳐 세지 않음). 펼친 곳까지만 본다.
    static func maximalMatches(in nodes: [DiskNode], tags: Set<DiskTag>, trail: [String] = []) -> [DiskMapItem] {
        var result: [DiskMapItem] = []
        for node in nodes {
            if !node.tags.isDisjoint(with: tags) {
                result.append(DiskMapItem(node: node, context: trail.isEmpty ? nil : trail.joined(separator: " › ")))
            } else if let children = node.children {
                result += maximalMatches(in: children, tags: tags, trail: trail + [node.name])
            }
        }
        return result
    }

    /// 태그가 맞는 칸 전부(안쪽까지 — 그 묶음에서 할 수 있는 조치를 모을 때).
    static func allMatches(in nodes: [DiskNode], tags: Set<DiskTag>) -> [DiskNode] {
        var result: [DiskNode] = []
        for node in nodes {
            if !node.tags.isDisjoint(with: tags) { result.append(node) }
            if let children = node.children { result += allMatches(in: children, tags: tags) }
        }
        return result
    }

    /// 필터 결과 = 펼친 나무에서 맞은 칸 + (아직 펼치지 않은 곳에 있는) 큰 파일 중 맞은 것. 이미 센 칸 아래의 큰 파일은 다시 세지 않는다.
    static func matches(in level: [DiskNode], under base: String?, largeFiles: [DiskNode], tags: Set<DiskTag>) -> [DiskMapItem] {
        var items = maximalMatches(in: level, tags: tags)
        let covered = items.map(\.node.path)
        for file in largeFiles where !file.tags.isDisjoint(with: tags) {
            if let base, !isAncestor(base, of: file.path) { continue }
            // 이미 센 칸(같은 경로·조상)이면 뺀다. 나무에 같은 파일이 있어도 태그가 안 맞아 빠졌다면(예: '큰 파일'은 큰 파일 목록만 붙인다) 여기서 센다.
            if covered.contains(where: { $0 == file.path || isAncestor($0, of: file.path) }) { continue }
            let parent = (file.path as NSString).deletingLastPathComponent
            items.append(DiskMapItem(node: file, context: DiskMapFormat.shortPath(parent, relativeTo: base)))
        }
        return items
    }

    /// 폴더 크기 − 자식 합(따로 나누지 않은 바로 아래 파일). 자식을 아직 모르거나 차이가 작으면(1%·50MB 이하) 0.
    static func looseBytes(of node: DiskNode) -> UInt64 {
        guard let children = node.children else { return 0 }
        let sum = children.reduce(UInt64(0)) { $0 + $1.bytes }
        guard node.bytes > sum else { return 0 }
        let rest = node.bytes - sum
        return rest > max(node.bytes / 100, 50 * 1_048_576) ? rest : 0
    }

    static func sortedBySize(_ nodes: [DiskNode]) -> [DiskNode] {
        nodes.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 서로 겹치는 것(조상·자손)이 있으면 조상만 남긴다 — 묶음 조치에서 같은 것을 두 번 옮기지 않게.
    static func outermost(_ nodes: [DiskNode]) -> [DiskNode] {
        nodes.filter { node in !nodes.contains { $0.path != node.path && isAncestor($0.path, of: node.path) } }
    }

    private static func adjusted(_ value: UInt64, by delta: Int64) -> UInt64 {
        delta >= 0 ? value &+ UInt64(delta) : value - min(value, UInt64(-delta))
    }
}

/// 디스크 지도 표기: 1MB 미만은 KB, 그 위는 앱 공통 규칙(Fmt.size: MB → GB 소수 1자리).
enum DiskMapFormat {
    static func size(_ bytes: UInt64) -> String {
        bytes < 1_048_576 ? String(format: "%.0fKB", Double(bytes) / 1024) : Fmt.size(bytes)
    }

    /// 끝까지 세지 못한 칸은 '하한'임을 숫자 옆에 붙인다.
    static func size(_ node: DiskNode) -> String {
        size(node.bytes) + (node.partial ? "⋯" : "")
    }

    static func home(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// base 아래 경로는 "A › B"처럼 줄여 보인다(base가 없으면 ~ 경로).
    static func shortPath(_ path: String, relativeTo base: String?) -> String {
        guard let base, DiskMapTree.isAncestor(base, of: path) else { return home(path) }
        return path.dropFirst(base.count + 1).split(separator: "/").joined(separator: " › ")
    }

    static func share(_ part: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "" }
        let value = Double(part) / Double(total) * 100
        return value < 1 ? "1% 미만" : String(format: "%.0f%%", value)
    }
}
