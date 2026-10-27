import AppKit
import ReMONCore
import SpriteKit

// 디스크 저장고 꼬리표별 진열(10-25 대표 지시 '디스크 지도를 기계실에서도 · 연출로').
// 선반 4개 × 3단 × 4칸 = 48칸, 1칸 = 디스크 전체의 1/48 — 예전처럼 실제 사용량을 따라 짐꾼이 한 칸씩 바꾼다(WarehouseNode).
// 그 칸들을 꼬리표(DiskTag)별로 나눠 색칠한다: 바이트에 비례(가장 큰 나머지) · 비어 있지 않은 꼬리표는 최소 1칸 ·
// 꼬리표 합계가 실제 사용량보다 작으면 남는 몫은 '기타'(원래 골판지 상자). 치울 수 있는 몫만큼은 옅은 점선 테두리.
// 재고 조사(Inventory.swift)가 내려 둔 상자는 선반에서 빈칸으로 남고, 정리 명령을 마친 꼬리표는 상자가 작아진다 — 둘 다 실측 때 풀린다.

extension DiskTag {
    /// 선반 · 탁자 상자 색(앱 디스크 구성 색과 같은 계열의 픽셀 색).
    var stockColor: PixelColor {
        switch self {
        case .cache: PixelColor(0x2BA59B)          // 청록
        case .regenerable: PixelColor(0x7ED9B4)    // 민트
        case .aiTranscript: PixelColor(0x9B6BD6)   // 보라
        case .aiData: PixelColor(0x5D6BD8)         // 남보라
        case .gitByproduct: PixelColor(0xE8873A)   // 주황
        case .docker: PixelColor(0x3B82E0)         // 파랑
        case .xcode: PixelColor(0x45C6E6)          // 하늘
        case .homebrew: PixelColor(0x8E6239)       // 갈색
        case .temp: PixelColor(0xE6C34A)           // 노랑
        case .trash: PixelColor(0x8D939B)          // 회색
        case .download: PixelColor(0xE57FA6)       // 분홍
        case .backup: PixelColor(0xA8743A)         // 황갈색
        case .snapshot: PixelColor(0x6B809A)       // 청회색
        case .swap: PixelColor(0xCF8450)           // 구리색
        case .system: PixelColor(0x585E66)         // 짙은 회색
        case .bundle: PixelColor(0x5BB45B)         // 초록
        case .large: PixelColor(0xD9483F)          // 빨강
        case .userFile: PixelColor(0xCDD0D5)       // 옅은 회색
        }
    }

    /// 선반 · 탁자 꼬리표(칸이 좁아 짧게). 긴 이름은 label.
    var shelfLabel: String {
        switch self {
        case .cache: "캐시"
        case .regenerable: "재생성"
        case .aiTranscript: "AI 기록"
        case .aiData: "AI 데이터"
        case .gitByproduct: "git"
        case .docker: "Docker"
        case .xcode: "Xcode"
        case .homebrew: "brew"
        case .temp: "임시"
        case .trash: "휴지통"
        case .download: "다운로드"
        case .backup: "백업"
        case .snapshot: "스냅샷"
        case .swap: "스왑"
        case .system: "시스템"
        case .bundle: "앱"
        case .large: "큰 파일"
        case .userFile: "사용자"
        }
    }
}

/// 선반 칸 나누기. 순서는 꼬리표 고정 순서(DiskTag.allCases)이고 '기타'는 맨 뒤 — 크기가 조금 바뀌어도 색 자리가 뛰지 않게.
enum DiskStockPlan {
    struct Slice: Equatable {
        /// nil = 기타(꼬리표 합계 밖의 실제 사용량).
        var tag: DiskTag?
        var count: Int
        /// 이 묶음 상자 중 점선(치울 수 있음)으로 그릴 수.
        var dashed: Int
    }

    /// total칸을 꼬리표별로 나눈다: 실제 사용량(used, 꼬리표 합계보다 작으면 합계)에 대한 바이트 비율 × total을 가장 큰 나머지로 반올림.
    /// 비어 있지 않은 꼬리표는 최소 1칸('기타'는 비율대로). 칸이 꼬리표 수보다 적으면 작은 꼬리표부터 이번엔 선반에서 빠진다(지도 목록에는 그대로 있다).
    /// 점선 수 = 치울 수 있는 비율 × 칸 수(치울 수 있는 양이 있으면 최소 1).
    static func allocate(total: Int, groups: [DiskStockGroup], used: UInt64) -> [Slice] {
        var bytes: [DiskTag: UInt64] = [:], reclaim: [DiskTag: UInt64] = [:]
        for group in groups where group.bytes > 0 {
            bytes[group.tag, default: 0] += group.bytes
            reclaim[group.tag, default: 0] += min(group.reclaimable, group.bytes)
        }
        let tags = DiskTag.allCases.filter { (bytes[$0] ?? 0) > 0 }
        let sum = tags.reduce(UInt64(0)) { $0 + (bytes[$1] ?? 0) }
        let denominator = max(used, sum)
        var entries: [(tag: DiskTag?, bytes: UInt64)] = tags.map { ($0, bytes[$0] ?? 0) }
        if denominator > sum { entries.append((nil, denominator - sum)) }
        let n = max(0, total)
        guard n > 0, denominator > 0 else { return entries.map { Slice(tag: $0.tag, count: 0, dashed: 0) } }
        let ideal = entries.map { Double($0.bytes) / Double(denominator) * Double(n) }
        var counts = ideal.map { Int($0.rounded(.down)) }
        for index in entries.indices where entries[index].tag != nil && counts[index] == 0 { counts[index] = 1 }
        var assigned = counts.reduce(0, +)
        while assigned > n {
            // 넘침: 이상값보다 가장 많이 받은 쪽부터 덜어 낸다(꼬리표는 1칸 · 기타는 0칸 아래로 내리지 않는다).
            let floorOf: (Int) -> Int = { entries[$0].tag == nil ? 0 : 1 }
            if let index = entries.indices.filter({ counts[$0] > floorOf($0) }).max(by: { Double(counts[$0]) - ideal[$0] < Double(counts[$1]) - ideal[$1] }) {
                counts[index] -= 1
            } else if let index = entries.indices.filter({ counts[$0] > 0 }).min(by: { entries[$0].bytes < entries[$1].bytes }) {
                counts[index] = 0   // 모두 1칸인데도 넘침: 가장 작은 꼬리표가 이번엔 빠진다
            } else {
                break
            }
            assigned -= 1
        }
        while assigned < n, let index = entries.indices.max(by: { ideal[$0] - Double(counts[$0]) < ideal[$1] - Double(counts[$1]) }) {
            counts[index] += 1
            assigned += 1
        }
        return entries.indices.map { index in
            let count = counts[index]
            var dashed = 0
            if let tag = entries[index].tag, count > 0, let all = bytes[tag], all > 0, let free = reclaim[tag], free > 0 {
                dashed = min(count, max(1, Int((Double(free) / Double(all) * Double(count)).rounded())))
            }
            return Slice(tag: entries[index].tag, count: count, dashed: dashed)
        }
    }
}

/// 디스크 저장고 · 재고 조사 소품 픽셀 그림.
enum DiskStockArt {
    static let rubber = PixelColor(0x1C2128)
    static let markRed = PixelColor(0xE0453F)
    static let keepGreen = PixelColor(0x3FAE55)

    /// 선반 상자(9×8): 꼬리표 색 상자 + 윗면 빛 + 테이프 + 송장. '기타'는 원래 골판지 상자 그대로. 치울 수 있으면 테두리를 한 칸씩 걸러 옅게(점선).
    static func shelfBox(_ tag: DiskTag?, dashed: Bool, variant: Int) -> PixelCanvas {
        var c: PixelCanvas
        if let tag {
            c = PixelCanvas(9, 8)
            let body = variant % 2 == 0 ? tag.stockColor : tag.stockColor.lighter(0.07)
            c.box(0, 0, 9, 8, fill: body, rounded: false)
            c.hline(1, 1, 7, body.lighter(0.25))
            let tape = body.lighter(0.42)
            c.hline(1, 3, 7, tape); c.vline(4, 1, 2, tape)
            c.dot(2, 5, body.darker(0.22)); c.dot(1, 6, body.darker(0.22))
            c.rect(5, 5, 3, 1, Pal.paper)
        } else {
            c = Furniture.box(variant)
        }
        if dashed {
            // 옅은 점선: 테두리를 두 칸 켜고 두 칸 끄는 짧은 줄로(바둑판처럼 보이지 않게), 흰빛을 반쯤만 섞는다.
            for y in 0..<8 { for x in 0..<9 where x == 0 || x == 8 || y == 0 || y == 7 {
                let along = (x == 0 || x == 8) ? y : x
                if along % 4 < 2 { c.dot(x, y, PixelColor(0xF4F1E8, alpha: 120)) }
            } }
        }
        return c
    }

    /// 탁자 위 항목 상자(7×6, 선반 상자보다 작게): 꼬리표 색 + 윗면 빛 + 테이프. 스티커는 노드가 따로 붙인다.
    static func itemBox(_ tag: DiskTag) -> PixelCanvas {
        var c = PixelCanvas(7, 6)
        let body = tag.stockColor
        c.box(0, 0, 7, 6, fill: body, rounded: false)
        c.hline(1, 1, 5, body.lighter(0.25))
        c.vline(3, 1, 2, body.lighter(0.42))
        return c
    }

    /// 스티커(3×2): 폐기 = 빨강 · 보관 = 초록(윗줄 가운데 밝은 점).
    static func sticker(marked: Bool) -> PixelCanvas {
        var c = PixelCanvas(3, 2)
        let color = marked ? markRed : keepGreen
        c.rect(0, 0, 3, 2, color)
        c.dot(1, 0, color.lighter(0.55))
        return c
    }

    /// 상자를 깔 때 튀는 날개(4×2) — 상자 색.
    static func flap(_ tag: DiskTag?) -> PixelCanvas {
        var c = PixelCanvas(4, 2)
        let body = tag?.stockColor ?? Pal.cardboard
        c.rect(0, 0, 4, 2, body)
        c.hline(0, 1, 4, body.darker(0.3))
        return c
    }

    /// 상자 속(4×3): 서류 묶음(흰 종이 + 줄).
    static func contents() -> PixelCanvas {
        var c = PixelCanvas(4, 3)
        c.rect(0, 0, 4, 3, Pal.paper)
        c.hline(0, 1, 3, PixelColor(0x9AA3AF)); c.dot(3, 2, PixelColor(0xC9C2B2))
        return c
    }

    /// 분류 탁자(가로 width, 11px): 원목 작업대 상판(밝은 윗면 · 나뭇결 · 짙은 앞 모서리 — 회색 벽 · 바닥 위험 띠와 섞이지 않게) · 철제 다리 셋 · 아래 가로대. 윗면 = 바닥선 + 11.
    static func sortingTable(width: Int) -> PixelCanvas {
        var c = PixelCanvas(width, 11)
        c.rect(0, 0, width, 3, Pal.oak)
        c.hline(0, 0, width, Pal.oak.lighter(0.3))
        c.hline(0, 2, width, Pal.oakDark)
        for x in stride(from: 5, to: width - 3, by: 13) { c.hline(x, 1, 4, Pal.oakMid) }   // 나뭇결
        c.dot(0, 1, Pal.oakDark); c.dot(width - 1, 1, Pal.oakDark)
        for x in [2, width / 2 - 1, width - 4] { c.rect(x, 3, 2, 8, MachineArt.steelDark) }
        c.hline(2, 8, width - 4, MachineArt.steel)
        return c
    }

    /// 손수레(10×14, 원점 왼쪽 위): 왼쪽 위 손잡이 · 기둥 · 앞으로 나온 짐판(윗면 = 바닥 + 2) · 뒤 바퀴. 직원은 늘 손수레 왼쪽에 선다.
    static func handTruck() -> PixelCanvas {
        var c = PixelCanvas(10, 14)
        c.hline(0, 0, 3, MachineArt.steelDark); c.dot(0, 1, MachineArt.steelDark)           // 손잡이
        c.vline(2, 0, 12, MachineArt.steelLight); c.vline(3, 1, 11, MachineArt.steel)       // 기둥
        c.dot(4, 4, MachineArt.steel); c.dot(4, 8, MachineArt.steel)                        // 가로대 끝
        c.rect(3, 12, 7, 2, MachineArt.steel); c.hline(3, 12, 7, MachineArt.steelLight)     // 짐판
        c.box(0, 10, 4, 4, fill: rubber); c.dot(1, 11, MachineArt.steelLight)              // 바퀴
        return c
    }

    /// 단말기 수레(18×20, 원점 왼쪽 위): 왼쪽 손잡이 · 철판 짐칸 · 바퀴 둘 · CRT 단말기(초록 글자 · 깜박이는 커서) · 자판. frame 0/1 = 글자가 바뀐다.
    static func terminalCart(_ frame: Int) -> PixelCanvas {
        var c = PixelCanvas(18, 20)
        c.hline(0, 7, 3, MachineArt.steelDark); c.vline(0, 8, 6, MachineArt.steelLight); c.vline(1, 8, 6, MachineArt.steelDark)   // 손잡이
        c.box(0, 13, 18, 3, fill: MachineArt.steel, rounded: false); c.hline(1, 14, 16, MachineArt.steelLight)                   // 짐칸
        for x in [2, 12] { c.box(x, 16, 4, 4, fill: rubber); c.dot(x + 1, 17, MachineArt.steelLight) }                             // 바퀴
        c.box(5, 1, 12, 10, fill: PixelColor(0xD9D3C3), outline: PixelColor(0x8A8475))                                          // 단말기 몸통
        c.rect(6, 2, 10, 7, PixelColor(0x0F2A1B))                                                                                   // 화면
        let green = PixelColor(0x52E08A)
        let widths = frame % 2 == 0 ? [7, 4, 5] : [5, 8, 3]
        for (row, width) in widths.enumerated() { c.hline(7, 3 + row * 2, width, green.with(alpha: row == 2 ? 255 : 170)) }
        if frame % 2 == 0 { c.dot(7 + widths[2] + 1, 7, green) }                                                                    // 커서
        c.rect(6, 11, 9, 2, PixelColor(0x5E5A4E)); c.hline(7, 11, 7, PixelColor(0x8F8A7A))                                        // 자판
        return c
    }

    /// 압축기 몸통(20×24, 원점 왼쪽 위): 위 경고등(꺼짐) · 투입구(어두운 속 — 누름판이 내려온다) · 노란 경고판 · 리벳 · 노랑·검정 띠 · 받침 · 오른쪽 레버 축.
    static func compactor() -> PixelCanvas {
        var c = PixelCanvas(20, 24)
        let s = MachineArt.steel, d = MachineArt.steelDark, l = MachineArt.steelLight
        c.box(0, 2, 18, 20, fill: s, outline: d, rounded: false)
        c.hline(1, 3, 16, l)
        c.rect(2, 4, 14, 9, PixelColor(0x15191F))
        c.vline(2, 4, 9, d); c.vline(15, 4, 9, d)
        c.box(4, 14, 10, 4, fill: Pal.mustard, outline: Pal.mustardShade, rounded: false)
        c.hline(6, 15, 6, Pal.black); c.hline(6, 16, 4, Pal.black)
        c.dot(2, 18, l); c.dot(15, 18, l)
        for x in 0..<18 { c.dot(x, 20, (x / 2) % 2 == 0 ? Pal.mustard : Pal.black) }
        c.rect(0, 22, 20, 2, d)
        c.rect(7, 0, 4, 2, PixelColor(0x6E2A2E)); c.hline(7, 0, 4, PixelColor(0x8E3A3E))
        c.rect(18, 9, 2, 4, d); c.dot(18, 10, MachineArt.brass)
        return c
    }

    /// 압축기 경고등(켜짐, 4×2).
    static func compactorLamp() -> PixelCanvas {
        var c = PixelCanvas(4, 2)
        c.rect(0, 0, 4, 2, Pal.alarm)
        c.hline(0, 0, 4, Pal.alarm.lighter(0.35))
        return c
    }

    /// 누름판(12×4): 위로 피스톤 대 · 아래 판.
    static func compactorPress() -> PixelCanvas {
        var c = PixelCanvas(12, 4)
        c.rect(5, 0, 2, 2, MachineArt.steelLight)
        c.rect(0, 2, 12, 2, MachineArt.steelLight); c.hline(0, 3, 12, MachineArt.steel)
        return c
    }

    /// 레버(5×17, 축 = 가운데 줄): up = 손잡이가 위 · down = 아래로 젖힘. 빨간 손잡이 공.
    static func compactorLever(down: Bool) -> PixelCanvas {
        var c = PixelCanvas(5, 17)
        let rod = MachineArt.steelLight, ball = Pal.alarm
        if down {
            c.vline(2, 8, 7, rod); c.rect(1, 14, 3, 3, ball); c.dot(1, 14, ball.lighter(0.4))
        } else {
            c.vline(2, 2, 7, rod); c.rect(1, 0, 3, 3, ball); c.dot(1, 0, ball.lighter(0.4))
        }
        c.dot(2, 8, MachineArt.brass)
        return c
    }
}

/// 디스크 저장고 진열: 선반 틀 넷 + 칸마다 상자 하나(꼬리표 색). 칸 수(count)는 짐꾼이 맞추는 실제 사용량(WarehouseNode)이다.
/// 재고 조사가 내려 둔 상자(out)는 선반에서 숨기고(빈칸), 정리 명령(prune)을 마친 꼬리표(shrunk)는 상자가 작아진다 — 둘 다 실측(re-measure) 때 풀린다.
/// 창고 노드가 건물 원점(0, 0)에 있으므로 여기 좌표가 곧 건물 좌표다.
final class DiskShelves: SKNode {
    static let capacity = 48
    /// 선반 안 상자 자리(선반 왼쪽 기준 x · 바닥선 위 y — 위 단 · 가운데 단 · 아래 단). 원래 선반 그림(Furniture.warehouseShelf)과 같은 자리.
    static let columnXs: [CGFloat] = [2, 9, 16, 22]
    static let rowYs: [CGFloat] = [26, 15, 4]
    static let boxSize = CGSize(width: 9, height: 8)
    static let shrinkScale: CGFloat = 0.6

    private var frames: [SKSpriteNode] = []
    private var boxes: [SKSpriteNode] = []
    private(set) var floorLine: CGFloat = 0
    private(set) var groups: [DiskStockGroup] = []
    private(set) var usedBytes: UInt64 = 0
    private(set) var count = 0
    private(set) var plan: [DiskStockPlan.Slice] = []
    /// 칸마다 꼬리표(nil = 기타) · 점선 여부.
    private(set) var slotTags: [DiskTag?] = []
    private(set) var slotDashed: [Bool] = []
    /// 꼬리표별 선반에서 빠진 상자 수(재고 조사가 내려 둔 것 · 실측 전까지 비워 둔 칸). nil 키 = 기타.
    private(set) var out: [DiskTag?: Int] = [:]
    private(set) var shrunk: Set<DiskTag> = []
    /// 칸 배치가 바뀔 때(장면이 꼬리표 이름표를 다시 놓는다).
    var onLayout: (() -> Void)?

    override init() {
        super.init()
        let empty = TextureCache.shared.texture("shelf0.0") { Furniture.warehouseShelf(fill: 0) }
        for x in WarehouseNode.shelfXs {
            let frame = SKSpriteNode(texture: empty)
            frame.anchorPoint = .zero
            frame.size = CGSize(width: 30, height: 34)
            frame.position.x = x
            addChild(frame)
            frames.append(frame)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 칸 하나의 상자 자리(아래 가운데). 칸 순서: 선반 왼쪽부터, 선반 안에서는 위 단 → 아래 단, 단 안에서는 왼쪽 → 오른쪽(예전 채움 순서 그대로).
    static func slotPoint(_ index: Int, floorLine: CGFloat) -> CGPoint {
        let shelf = min(WarehouseNode.shelfXs.count - 1, max(0, index) / 12), k = max(0, index) % 12
        return CGPoint(x: WarehouseNode.shelfXs[shelf] + columnXs[k % 4] + 4.5, y: floorLine + rowYs[k / 4])
    }

    static func texture(_ tag: DiskTag?, dashed: Bool, variant: Int) -> SKTexture {
        TextureCache.shared.texture("disk-box-\(tag?.rawValue ?? "rest")-\(dashed ? 1 : 0)-\(variant % 2)") { DiskStockArt.shelfBox(tag, dashed: dashed, variant: variant) }
    }

    func place(floorLine: CGFloat) {
        self.floorLine = floorLine
        for frame in frames { frame.position.y = floorLine }
        layoutBoxes()
    }

    /// 꼬리표 합계(디스크 지도) · 실제 사용량. 바뀌었을 때만 다시 나눈다.
    func setStock(_ groups: [DiskStockGroup], used: UInt64) {
        guard groups != self.groups || (used != usedBytes && used > 0) else { return }
        self.groups = groups
        if used > 0 { usedBytes = used }
        replan()
    }

    /// 짐꾼이 맞춘 칸 수(실제 사용량 × 48). 사용량 바이트는 칸 수가 바뀔 때만 따라간다 — 2초마다 조금씩 흔들리는 값에 색이 깜박이지 않게.
    func show(count value: Int, used: UInt64) {
        let clamped = max(0, min(Self.capacity, value))
        guard clamped != count || plan.isEmpty && clamped > 0 else { return }
        count = clamped
        if used > 0 { usedBytes = used }
        replan()
    }

    private func replan() {
        plan = DiskStockPlan.allocate(total: count, groups: groups, used: usedBytes)
        slotTags = []
        slotDashed = []
        for slice in plan {
            for index in 0..<slice.count {
                slotTags.append(slice.tag)
                slotDashed.append(index >= slice.count - slice.dashed)
            }
        }
        layoutBoxes()
        onLayout?()
    }

    private func layoutBoxes() {
        while boxes.count > slotTags.count { boxes.removeLast().removeFromParent() }
        while boxes.count < slotTags.count {
            let box = SKSpriteNode()
            box.anchorPoint = CGPoint(x: 0.5, y: 0)
            box.size = Self.boxSize
            addChild(box)
            boxes.append(box)
        }
        var ordinal: [DiskTag?: Int] = [:]
        for (index, tag) in slotTags.enumerated() {
            let box = boxes[index]
            box.texture = Self.texture(tag, dashed: slotDashed[index], variant: index)
            box.position = Self.slotPoint(index, floorLine: floorLine)
            box.zPosition = 0.1 + CGFloat(index % 4) * 0.01
            let nth = ordinal[tag, default: 0]
            ordinal[tag] = nth + 1
            let total = allocated(tag)
            box.isHidden = nth >= total - min(total, out[tag] ?? 0)
            if box.action(forKey: "shrink") == nil { box.setScale(tag.map { shrunk.contains($0) } ?? false ? Self.shrinkScale : 1) }
        }
    }

    // MARK: 재고 조사가 쓰는 손잡이

    /// 그 꼬리표에 나눈 칸 수 · 지금 선반에 보이는 수.
    func allocated(_ tag: DiskTag?) -> Int { plan.first { $0.tag == tag }?.count ?? 0 }
    func visible(_ tag: DiskTag?) -> Int { allocated(tag) - min(allocated(tag), out[tag] ?? 0) }
    var visibleTotal: Int { boxes.filter { !$0.isHidden }.count }
    func dashedCount(_ tag: DiskTag?) -> Int { plan.first { $0.tag == tag }?.dashed ?? 0 }
    /// 선반에 칸이 있는 묶음(꼬리표 · 기타).
    var stockedTags: [DiskTag?] { plan.filter { $0.count > 0 }.map(\.tag) }

    /// 그 꼬리표 상자 자리(아래 가운데), 진열 순서대로. last: 뒤에서 몇 개만.
    func points(_ tag: DiskTag?) -> [CGPoint] {
        slotTags.indices.filter { slotTags[$0] == tag }.map { Self.slotPoint($0, floorLine: floorLine) }
    }

    /// 그 꼬리표 상자 중 뒤에서 count개를 선반에서 뺀 것으로(빈칸) — 0이면 모두 제자리.
    func setOut(_ tag: DiskTag?, _ value: Int) {
        out[tag] = max(0, value)
        layoutBoxes()
    }

    func outCount(_ tag: DiskTag?) -> Int { out[tag] ?? 0 }

    /// 실측: 빠진 칸 · 작아진 상자를 모두 푼다.
    func clearOut() {
        out = [:]
        shrunk = []
        for box in boxes { box.removeAction(forKey: "shrink") }
        layoutBoxes()
    }

    /// 정리 명령을 마친 꼬리표: 그 상자들이 바닥 쪽으로 작아진다(실측 때 실제 칸으로 다시 그린다).
    func shrink(_ tags: [DiskTag]) {
        shrunk.formUnion(tags)
        for (index, tag) in slotTags.enumerated() {
            guard let tag, tags.contains(tag) else { continue }
            boxes[index].run(.scale(to: Self.shrinkScale, duration: 0.3), withKey: "shrink")
        }
    }

    /// 검수용: 그 꼬리표 상자가 작아진 채인가(보이는 상자 모두 축소 배율).
    func isShrunk(_ tag: DiskTag) -> Bool {
        let list = slotTags.indices.filter { slotTags[$0] == tag }.map { boxes[$0] }
        return !list.isEmpty && shrunk.contains(tag) && list.allSatisfy { $0.xScale < 0.99 || $0.action(forKey: "shrink") != nil }
    }

    /// 꼬리표 이름표 자리: 꼬리표마다 보이는 상자가 가장 많이 모인 한 단(같은 선반 · 같은 단)의 가운데 · 상자 윗면. boxes = 그 단의 상자 수.
    /// avoidBottom: 분류 탁자가 펴져 아래 단을 가리는 동안은 아래 단을 이름표 자리로 쓰지 않는다(가려진 상자에 글자를 달지 않는다 —
    /// 아래 단에만 있는 꼬리표는 그동안 이름표가 없다).
    func labelAnchors(avoidBottom: Bool = false) -> [(tag: DiskTag?, point: CGPoint, boxes: Int, total: Int)] {
        var segments: [String: (tag: DiskTag?, xs: [CGFloat], y: CGFloat)] = [:]
        var order: [String] = []
        for (index, tag) in slotTags.enumerated() where !boxes[index].isHidden {
            let shelf = index / 12, row = (index % 12) / 4
            if avoidBottom, row == 2 { continue }
            let key = "\(tag?.rawValue ?? "rest")-\(shelf)-\(row)"
            let point = Self.slotPoint(index, floorLine: floorLine)
            if segments[key] == nil { segments[key] = (tag, [], point.y + Self.boxSize.height); order.append(key) }
            segments[key]?.xs.append(point.x)
        }
        var best: [DiskTag?: (point: CGPoint, boxes: Int)] = [:]
        var tags: [DiskTag?] = []
        for key in order {
            guard let segment = segments[key], let first = segment.xs.first, let last = segment.xs.last else { continue }
            if best[segment.tag] == nil { tags.append(segment.tag) }
            if (best[segment.tag]?.boxes ?? 0) < segment.xs.count {
                best[segment.tag] = (CGPoint(x: (first + last) / 2, y: segment.y), segment.xs.count)
            }
        }
        return tags.compactMap { tag in best[tag].map { (tag, $0.point, $0.boxes, visible(tag)) } }
    }

    /// 검수용: 칸마다(꼬리표 · 보이는가 · 상자 아래 가운데).
    var slotProbes: [(tag: DiskTag?, visible: Bool, point: CGPoint, scale: CGFloat)] {
        boxes.enumerated().map { (slotTags[$0.offset], !$0.element.isHidden, $0.element.position, $0.element.xScale) }
    }
}
