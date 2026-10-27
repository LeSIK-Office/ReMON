import AppKit
import ReMONCore
import SpriteKit

// 방 안 짐(10-25 대표 요청 '워크트리 · 브랜치가 많을수록 책상 위 서류부터 짐 상자, 나중에는 사무실 벽에 쌓이고 — 프로젝트 단위로 청소하면 치워진다').
// 방(프로젝트)마다 RoomClutter(무게 = 워크트리 3 · 브랜치 1 · 서류 1, 단계 0~5)를 받아 짐 층을 그린다:
//   1 책상 앞 모서리에 걸친 낱장 · 2 모니터 옆 · 뒤 서류 더미 + 구석 상자 하나 · 3 책상 사이 바닥 상자 · 더미 위 바인더 · 4 뒷벽에 2단 · 앞줄 상자(통로가 좁아진다) · 기운 더미 ·
//   5 천장까지 쌓인 상자 탑(창 · 벽 장식을 가린다) · 쏟아진 서류 · 가끔 먼지 · '복잡' 표지.
// 자리: 의자 자리(직원이 앉는 곳) · 책상 · 앞 통로(바닥선 위 2px)에는 바닥 짐을 놓지 않는다. 짐은 늘 사람 뒤(z < 5)에 있다.
// 배치는 순수 계산(ClutterPlan)이다 — 방 이름 씨앗(Variety.Generator)이라 늘 같은 자리, 무게가 늘면 칸이 더해지기만 한다(단조).
// 치울 수 있는 몫 = 지금 배치에서 '남길 것만 있을 때의 배치'를 뺀 칸 → 노란 띠 · 점선. 청소 특공대는 정확히 그 칸만 치운다
// (상자는 들고 엘리베이터로 실어 내고, 서류 더미 · 바인더 · 낱장은 쓸어 담는다). 남은 칸은 다음 setClutter가 다시 그려도 제자리다.
// 서류(커밋 · 푸시 · 배포)는 같은 장부다: setPapers와 RoomClutter.papers는 같은 낱장 더미(Celebrate.swift)를 움직이고(나중에 온 값을 따른다),
// 낱장 자리(책상 사이 더미 × 5장)에 다 못 놓는 서류는 상자로 묶여 이 층의 무게에 더해진다.

/// 짐 픽셀(옆에서 본 정면 2D).
enum ClutterArt {
    /// 상자 크기: 큰 상자 10×7 · 작은 상자 8×6 · 좁은 상자 7×6(방 왼쪽 벽 틈).
    enum BoxSize: Int, CaseIterable {
        case big, small, narrow
        var width: Int { [10, 8, 7][rawValue] }
        var height: Int { [7, 6, 6][rawValue] }
    }

    static let tones: [PixelColor] = [Pal.cardboard, Pal.cardboard.lighter(0.08), PixelColor(0xB9864F), PixelColor(0xD4AB74)]
    /// 치울 수 있음 테이프 · '정리 중' 테이프의 노랑.
    static let caution = PixelColor(0xF2C230)
    static let dust = PixelColor(0xD6CCBA)

    /// 상자 앞면: 골판지 네 가지 색 · 윗날개 빛 · 오른쪽 그늘 · 윗날개 테이프 · 변형마다 흰 송장이나 매직 낙서(없기도 하다).
    /// 치울 수 있음 = 노란 테이프(윗날개 세로 + 가운데 가로 띠) — 갈색 테이프 상자와 멀리서도 갈린다.
    static func box(_ size: BoxSize, variant: Int, cleanable: Bool) -> PixelCanvas {
        let w = size.width, h = size.height
        var c = PixelCanvas(w, h)
        let body = tones[variant % tones.count]
        c.box(0, 0, w, h, fill: body, outline: body.darker(0.5), rounded: false)
        c.hline(1, 1, w - 2, body.lighter(0.24))                                   // 윗날개 빛
        c.vline(w - 2, 2, h - 3, body.darker(0.1))                                  // 오른쪽 그늘
        switch (variant / tones.count) % 3 {
        case 0: c.rect(2, h - 3, 2, 1, Pal.paper)                                   // 송장
        case 1: c.hline(2, h - 3, 3, body.darker(0.42))                             // 매직 낙서
        default: break
        }
        if cleanable {
            c.vline(w / 2, 1, h / 2 - 1, caution)
            c.hline(1, h / 2, w - 2, caution)
            c.dot(w - 2, h / 2, caution.darker(0.22))
        } else {
            c.vline(w / 2, 1, 2, Pal.tape)
        }
        return c
    }

    /// 책상 앞 모서리에 걸친 낱장(9×5): 위 두 줄은 책상 위에 비껴 누운 두 장(모니터 받침 앞), 아래 세 줄은 상판 앞면(짙은 나무)으로 늘어진다 —
    /// 멀리서도 흰 종이가 보인다. 치울 수 있음 = 오른쪽 노란 꼬리표.
    static func deskSheets(variant: Int, cleanable: Bool) -> PixelCanvas {
        var c = PixelCanvas(9, 5)
        let paper = variant % 2 == 0 ? Pal.paper : PixelColor(0xF3EAD2)
        let rim = PixelColor(0xA39A88)                                               // 옅은 테두리(밝은 벽 앞에서도 종이 모양이 보이게)
        c.hline(1 + variant % 2, 0, 7 - variant % 2, rim)                            // 위 장(비껴) 윗선
        c.hline(0, 1, 9, paper); c.dot(0, 1, rim); c.dot(8, 1, rim)                  // 책상 위에 누운 장
        c.dot(3, 1, PixelColor(0x8FA7B8)); c.dot(5, 1, PixelColor(0x8FA7B8))
        c.rect(1, 2, 6, 3, paper)                                                    // 앞으로 늘어진 부분
        c.vline(1, 2, 3, rim); c.vline(6, 2, 3, rim); c.hline(1, 4, 6, rim)
        c.hline(2, 3, 3, PixelColor(0x8FA7B8))                                       // 글줄
        if cleanable { c.vline(7, 2, 2, caution); c.dot(8, 2, caution) }
        return c
    }

    /// 서류 더미(10×h): 왼쪽 네 줄은 모니터 옆에, 나머지는 모니터 뒤에서 위로 솟는다. 흰 · 크림 낱장이 들쭉날쭉 쌓이고 가끔 하늘색 · 분홍 낱장 ·
    /// 위에 집게. 아래 두 줄 왼쪽(키보드 자리)은 키보드를 다시 그린다 — 더미가 키보드 뒤에 놓인 것처럼. 치울 수 있음 = 위쪽 노란 띠지.
    static func deskStack(height h: Int, variant: Int, cleanable: Bool) -> PixelCanvas {
        var c = PixelCanvas(10, h)
        let edge = PixelColor(0xB9B2A2)
        for y in 0..<h {
            let left = FloorPainter.hash(y, variant, 23) % 3 == 0 ? 1 : 0
            let right = FloorPainter.hash(y, variant, 29) % 3 == 0 ? 1 : 0
            let tint = FloorPainter.hash(y / 2, variant, 31) % 9
            let tone = tint == 0 ? PixelColor(0xCFE4F2) : tint == 1 ? PixelColor(0xF6D6DC) : y % 2 == 0 ? Pal.paper : PixelColor(0xEDE6D3)
            c.hline(left, y, 10 - left - right, tone)
            c.dot(left, y, edge); c.dot(9 - right, y, edge)
        }
        c.rect(4, 0, 3, 1, Pal.black); c.dot(5, 1, Pal.metal)                      // 집게
        if cleanable { c.hline(0, 2, 10, caution); c.hline(0, 3, 10, caution.darker(0.18)) }
        c.hline(0, h - 2, 4, Pal.metalLight); c.hline(0, h - 1, 4, Pal.outline)      // 앞의 키보드(왼쪽 네 칸)
        return c
    }

    /// 서류 더미 위에 눕힌 바인더 두 권(10×4): 색 책등 · 흰 라벨 · 고리. 치울 수 있음 = 노란 꼬리표.
    static func binders(variant: Int, cleanable: Bool) -> PixelCanvas {
        var c = PixelCanvas(10, 4)
        let spines = [PixelColor(0x2E6DA4), PixelColor(0xC0392B), PixelColor(0x2F8F5B), PixelColor(0x3B3B4F), PixelColor(0x1F8A8A), PixelColor(0x8E44AD)]
        for k in 0..<2 {
            let color = spines[(variant + k * 3) % spines.count]
            let y = k == 0 ? 2 : 0, x = k == 0 ? 0 : 1
            c.rect(x, y, 9, 2, color)
            c.hline(x, y + 1, 9, color.darker(0.28))
            c.rect(x + 3, y, 3, 1, Pal.paper)                                         // 라벨
            c.dot(x + 7, y, color.lighter(0.45))                                      // 고리
        }
        if cleanable { c.rect(9, 0, 1, 2, caution); c.dot(8, 2, caution) }
        return c
    }

    /// 바닥에 쏟아진 서류(w×3): 미끄러진 낱장 두세 장 + 바닥 그늘(밝은 바닥에서도 보이게).
    static func spill(width w: Int, variant: Int, cleanable: Bool) -> PixelCanvas {
        var c = PixelCanvas(w, 3)
        c.rect(2 + variant % 2, 0, w - 4 - variant % 2, 1, PixelColor(0xF3EAD2))
        c.rect(0, 1, w - 2, 1, Pal.paper)
        c.dot(3, 1, PixelColor(0x8FA7B8)); c.dot(5, 1, PixelColor(0x8FA7B8))
        c.hline(0, 2, w - 1, PixelColor(0x9A9488, alpha: 170))
        if cleanable { c.dot(w - 1, 1, caution); c.dot(w - 2, 0, caution) }
        return c
    }

    /// '복잡' 표지(11×7): 상자 탑에 테이프로 붙인 쪽지 — 빨간 테두리 · 매직 글씨 자국(글자는 가까이 다가가면 글자 층이 얹는다).
    static func complexSign() -> PixelCanvas {
        var c = PixelCanvas(11, 7)
        c.box(0, 0, 11, 7, fill: PixelColor(0xFFF6E0), outline: Pal.alarm, rounded: false)
        c.hline(2, 2, 3, Pal.alarm); c.hline(6, 2, 3, Pal.alarm)
        c.hline(2, 4, 7, Pal.alarm.darker(0.2))
        c.dot(0, 0, Pal.tape); c.dot(10, 0, Pal.tape)
        return c
    }

    /// '정리 중' 테이프(w×3): 노랑 · 검정 사선.
    static func cleaningTape(width w: Int) -> PixelCanvas {
        var c = PixelCanvas(w, 3)
        for y in 0..<3 { for x in 0..<w { c.dot(x, y, ((x + y) / 2) % 2 == 0 ? caution : Pal.black) } }
        return c
    }
}

/// 방 하나의 짐 배치(노드 없이 계산만). 같은 방 · 같은 무게면 늘 같은 결과(방 이름 씨앗 — 무게와 무관한 칸별 굴림).
/// 단조: 무게(units)가 늘면 칸이 더해지기만 하고, 같은 칸은 늘 같은 자리다 → 치울 몫 = plan(전체) − plan(남길 것).
struct ClutterPlan {
    /// 방 자리: 벽 · 바닥선 · 천장 · 책상 x · 창(건물 좌표) · 명패 · 씨앗.
    struct Site: Equatable {
        var x0: CGFloat
        var x1: CGFloat
        var line: CGFloat
        var top: CGFloat
        var deskXs: [CGFloat]
        var windows: [CGRect]
        var plate: CGRect
        var seed: UInt64
    }

    /// 바닥 짐을 쌓는 세로 칸: 책상 사이(11px) · 마지막 책상 오른쪽 구석(11px) · 오른쪽 벽 앞(8px, 4단계부터 기운 더미) · 왼쪽 벽 틈(7px).
    struct Column: Equatable {
        enum Kind { case gap, corner, wall, left }
        var id: String
        var x0: CGFloat
        var x1: CGFloat
        var kind: Kind
        var width: CGFloat { x1 - x0 }
    }

    struct Prop: Equatable {
        enum Kind: String { case deskSheet, deskStack, binders, box, spill, sign }
        var id: String
        var kind: Kind
        /// 건물 좌표(왼쪽 아래 원점, 돌리기 전).
        var frame: CGRect
        var z: CGFloat
        var variant: Int
        var size: ClutterArt.BoxSize = .big
        var column = ""
        var tier = 0
        var front = false
        /// 기운 더미: 회전(라디안, 시계 방향 음수)과 회전 중심(더미 아래 오른쪽 모서리).
        var rotation: CGFloat = 0
        var pivot: CGPoint = .zero
        var cleanable = false

        /// 노드 자리: 왼쪽 아래 모서리를 회전 중심 둘레로 돌린 점(노드는 그 점을 기준으로 같은 각도만큼 돈다).
        var origin: CGPoint { rotation == 0 ? frame.origin : ClutterPlan.rotate(frame.origin, about: pivot, by: rotation) }

        /// 돌린 뒤 실제로 차지하는 사각형.
        var bounds: CGRect {
            guard rotation != 0 else { return frame }
            let corners = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY), CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)]
                .map { ClutterPlan.rotate($0, about: pivot, by: rotation) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    /// 바닥 짐의 뒷줄 · 앞줄 높이(바닥선 위). 0~2px은 걷는 통로라 비운다.
    static let backRow: CGFloat = 4
    static let frontRow: CGFloat = 2
    /// 오른쪽 벽에 기댄 더미의 기울기(약 5°, 시계 방향).
    static let lean: CGFloat = -0.09

    static func rotate(_ point: CGPoint, about center: CGPoint, by angle: CGFloat) -> CGPoint {
        let dx = point.x - center.x, dy = point.y - center.y
        return CGPoint(x: center.x + dx * cos(angle) - dy * sin(angle), y: center.y + dx * sin(angle) + dy * cos(angle))
    }

    /// 방 이름 → 씨앗(FNV-1a 64 — 문자열 해시값은 실행마다 바뀌어 쓰지 않는다).
    static func seed(_ name: String) -> UInt64 {
        var seed: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in name.utf8 { seed = (seed ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return seed
    }

    /// 칸 하나의 굴림(0..<count): 방 씨앗 × 칸 이름 — 무게나 굴린 순서와 무관해서 같은 칸은 늘 같은 모양 · 자리다.
    static func roll(_ seed: UInt64, _ key: String, _ count: Int) -> Int {
        var generator = Variety.Generator(state: seed ^ Self.seed(key))
        return Int(generator.next() % UInt64(max(1, count)))
    }

    static func shuffled<T>(_ items: [T], seed: UInt64) -> [T] {
        var generator = Variety.Generator(state: seed)
        return items.shuffled(using: &generator)
    }

    /// 칸 순서(채우는 차례): 구석(첫 상자 자리) → 책상 사이(방마다 섞은 순서) → 오른쪽 벽 앞 → 왼쪽 벽 틈.
    static func columns(_ site: Site) -> [Column] {
        let xs = site.deskXs
        guard let first = xs.first, let last = xs.last else { return [] }
        let gaps = shuffled((0..<(xs.count - 1)).map { Column(id: "g\($0)", x0: xs[$0] + 35, x1: xs[$0] + 46, kind: .gap) }, seed: site.seed ^ 0x6A95)
        return [Column(id: "r1", x0: last + 35, x1: last + 46, kind: .corner)] + gaps +
            [Column(id: "r2", x0: last + 49, x1: site.x1 - 3, kind: .wall), Column(id: "lc", x0: site.x0 + 1, x1: first - 2, kind: .left)]
    }

    /// 4단계까지 쌓을 수 있는 높이: 그 칸 위 창의 아랫변(창은 5단계에만 가린다). 창이 없으면 천장 아래.
    static func windowTop(_ site: Site, _ x0: CGFloat, _ x1: CGFloat) -> CGFloat {
        site.windows.filter { $0.minX < x1 && $0.maxX > x0 }.map(\.minY).reduce(site.top - 8, min)
    }

    /// 5단계 탑의 높이: 천장 아래. 명패와 겹치는 칸은 명패 밑 짐 명판(가까이서 보이는 숫자 글자) 아래까지.
    static func towerTop(_ site: Site, _ column: Column) -> CGFloat {
        site.plate.minX < column.x1 && site.plate.maxX > column.x0 ? site.plate.minY - 9 : site.top - 8
    }

    /// 무게(units)만큼의 짐 칸들(치울 수 있음 표시 전). 단계 문턱은 RoomClutter와 같다(1 · 3 · 7 · 15 · 31).
    static func props(site: Site, units: Int) -> [Prop] {
        guard units > 0, !site.deskXs.isEmpty else { return [] }
        let level = RoomClutter(branches: units).level
        let n = site.deskXs.count
        let line = site.line
        var out: [Prop] = []

        // 책상: 앞 모서리에 걸친 낱장 → 서류 더미(모니터 옆 · 뒤에서 위로 솟음) → 더미 위에 눕힌 바인더. 책상마다 섞은 순서로.
        // 더미는 손(앉은 직원 오른쪽 끝 = 책상 x + 14)과 창(가장 넓은 덧문 창 왼쪽 = 책상 x + 27) 사이에만 둔다.
        let desks = shuffled(Array(0..<n), seed: site.seed ^ 0xDE5C)
        for i in desks.prefix(min(n, units)) {
            out.append(Prop(id: "d\(i)-sheet", kind: .deskSheet, frame: CGRect(x: site.deskXs[i] + 22, y: line + 8, width: 9, height: 5), z: 4.2, variant: roll(site.seed, "d\(i)-sheet", 4)))
        }
        func stackHeight(_ i: Int) -> CGFloat { CGFloat(14 + min(4, (units - 3) / 6) + roll(site.seed, "d\(i)-stack", 6) % 2) }   // 짐이 많을수록 높이(14~19)
        if units >= 3 {
            for i in desks.prefix(min(n, units - 2)) {
                out.append(Prop(id: "d\(i)-stack", kind: .deskStack, frame: CGRect(x: site.deskXs[i] + 17, y: line + 11, width: 10, height: stackHeight(i)), z: 3.9,
                                variant: roll(site.seed, "d\(i)-stack", 6)))
            }
        }
        if units >= 7 {
            // 바인더는 서류 더미가 있는 책상에만 놓인다(더미 책상 순서의 앞부분 — 남길 바인더 밑의 더미는 늘 남는다).
            for i in desks.prefix(min(n, 1 + (units - 7) / 2)) {
                out.append(Prop(id: "d\(i)-binders", kind: .binders, frame: CGRect(x: site.deskXs[i] + 17, y: line + 11 + stackHeight(i), width: 10, height: 4), z: 3.95,
                                variant: roll(site.seed, "d\(i)-binders", 6)))
            }
        }

        // 바닥 상자(뒷줄): 칸마다 아래부터 쌓는다.
        let columns = self.columns(site)
        func box(_ column: Column, tier: Int, on below: Prop?) -> Prop {
            let key = "\(column.id)-t\(tier)"
            let size: ClutterArt.BoxSize = column.width >= 10 ? (roll(site.seed, key + "s", 10) < 7 ? .big : .small) : column.width >= 8 ? .small : .narrow
            let w = CGFloat(size.width), h = CGFloat(size.height)
            let slack = max(0, column.width - w)
            let x = column.x0 + min(slack, max(0, (slack / 2).rounded(.down) + CGFloat(roll(site.seed, key + "x", 3) - 1)))
            let z = (column.kind == .wall ? 2.40 : 2.30) + CGFloat(tier) * 0.004
            return Prop(id: key, kind: .box, frame: CGRect(x: x, y: below?.frame.maxY ?? line + backRow, width: w, height: h), z: z,
                        variant: roll(site.seed, key + "v", ClutterArt.tones.count * 3), size: size, column: column.id, tier: tier)
        }
        var stacks: [String: [Prop]] = [:]
        let tier0 = units < 3 ? 0 : units < 7 ? 1 : units < 15 ? min(columns.count, 2 + (units - 7) / 2) : columns.count
        for column in columns.prefix(tier0) { stacks[column.id] = [box(column, tier: 0, on: nil)] }

        var fronts: [Prop] = []
        var spills: [Prop] = []
        if level >= 4 {
            // 2단(뒷벽): 4단계는 창 아래까지만 · 5단계는 모든 칸. 오른쪽 벽 앞은 따로(기운 더미).
            let tierColumns = columns.filter { $0.kind != .wall && stacks[$0.id] != nil }
            let eligible = tierColumns.filter { column in
                level >= 5 || box(column, tier: 1, on: stacks[column.id]?.last).frame.maxY <= windowTop(site, column.x0, column.x1)
            }
            for column in eligible.prefix(level >= 5 ? eligible.count : min(eligible.count, 1 + (units - 15) / 3)) {
                let next = box(column, tier: 1, on: stacks[column.id]?.last)
                stacks[column.id]?.append(next)
            }
            // 기운 더미: 오른쪽 벽 앞 더미가 벽에 기댄다(아래 오른쪽 모서리 중심) — 최대 3단, 4단계는 창 아래까지만.
            if let wall = columns.first(where: { $0.kind == .wall }), var stack = stacks[wall.id] {
                let pivot = CGPoint(x: wall.x1, y: line + backRow)
                for tier in 1..<3 {
                    var next = box(wall, tier: tier, on: stack.last)
                    next.rotation = lean; next.pivot = pivot
                    let bounds = next.bounds
                    if level < 5, bounds.maxY > windowTop(site, bounds.minX, bounds.maxX) { break }
                    stack.append(next)
                }
                stacks[wall.id] = stack.map { var prop = $0; prop.rotation = lean; prop.pivot = pivot; return prop }
            }
            // 앞줄(통로가 좁아진다): 구석 · 책상 사이 칸 앞에 작은 상자.
            let frontColumns = columns.filter { $0.kind == .gap || $0.kind == .corner }
            for column in frontColumns.prefix(min(frontColumns.count, 1 + (units - 15) / 4)) {
                let key = "\(column.id)-front"
                let size: ClutterArt.BoxSize = .small
                let slack = max(0, column.width - CGFloat(size.width))
                let x = column.x0 + min(slack, max(0, (slack / 2).rounded(.down) + CGFloat(roll(site.seed, key + "x", 3) - 1)))
                fronts.append(Prop(id: key, kind: .box, frame: CGRect(x: x, y: line + frontRow, width: CGFloat(size.width), height: CGFloat(size.height)), z: 2.45,
                                   variant: roll(site.seed, key + "v", ClutterArt.tones.count * 3), size: size, column: column.id, front: true))
            }
        }
        if level >= 5 {
            // 천장까지 쌓인 탑: 창이 있는 책상 사이 · 구석부터(창을 가린다) → 창 없는 칸 → 왼쪽 벽 틈. 같은 무리 안에서는 이미 고른 탑에서
            // 가장 먼 칸부터(탑이 방 한쪽에 몰리지 않고 방 전체가 차오르게). 칸의 절반까지만(방이 통째로 벽이 되지 않게).
            let tall = columns.filter { $0.kind == .gap || $0.kind == .corner }
            let windowed = tall.filter { column in site.windows.contains { $0.minX < column.x1 && $0.maxX > column.x0 } }
            var candidates: [Column] = []
            for group in [windowed, tall.filter { !windowed.contains($0) }, columns.filter { $0.kind == .left }] {
                var rest = group
                while !rest.isEmpty {
                    let far = candidates.isEmpty ? rest[0] : rest.max { lhs, rhs in
                        candidates.map { abs($0.x0 - lhs.x0) }.min()! < candidates.map { abs($0.x0 - rhs.x0) }.min()!
                    }!
                    candidates.append(far)
                    rest.removeAll { $0 == far }
                }
            }
            let towers = min(max(1, (candidates.count + 1) / 2), 1 + (units - 31) / 8)
            for column in candidates.prefix(towers) {
                guard var stack = stacks[column.id] else { continue }
                let limit = towerTop(site, column)
                while true {
                    let next = box(column, tier: stack.count, on: stack.last)
                    guard next.frame.maxY <= limit else { break }
                    stack.append(next)
                }
                stacks[column.id] = stack
            }
            // 쏟아진 서류: 칸 앞 바닥에 미끄러진 낱장.
            let spillColumns = columns.filter { $0.kind != .wall }
            for column in spillColumns.prefix(min(6, 2 + (units - 31) / 10)) {
                let key = "spill-\(column.id)"
                let w = min(10, column.width - 1)
                spills.append(Prop(id: key, kind: .spill, frame: CGRect(x: column.x0 + CGFloat(roll(site.seed, key, 2)), y: line + frontRow, width: w, height: 3), z: 2.56,
                                   variant: roll(site.seed, key + "v", 4)))
            }
        }
        for column in columns { out += stacks[column.id] ?? [] }
        return out + fronts + spills
    }

    /// '복잡' 표지: 탑이 있으면 가장 높은 탑의 2단 상자 앞면에 붙인다(5단계면 모든 칸에 2단이 있어 남는다). 없으면 구석 바닥에 세운다.
    static func sign(site: Site, props: [Prop]) -> Prop? {
        let columns = self.columns(site)
        let tops = Dictionary(grouping: props.filter { $0.kind == .box && !$0.front && $0.rotation == 0 }, by: \.column).mapValues { ($0.count, $0.map(\.frame).reduce(CGRect.null) { $0.union($1) }) }
        if let tallest = tops.filter({ $0.value.0 >= 3 }).max(by: { $0.value.1.maxY != $1.value.1.maxY ? $0.value.1.maxY < $1.value.1.maxY : $0.key > $1.key }) {
            let x = (tallest.value.1.midX - 5.5).rounded(.down)
            return Prop(id: "sign", kind: .sign, frame: CGRect(x: x, y: site.line + 12, width: 11, height: 7), z: 2.58, variant: 0, column: tallest.key)
        }
        guard let corner = columns.first else { return nil }
        return Prop(id: "sign", kind: .sign, frame: CGRect(x: corner.x0, y: site.line + frontRow, width: 11, height: 7), z: 2.58, variant: 0, column: corner.id)
    }

    /// 방 짐 배치 전체: 무게 = 워크트리 3 · 브랜치 1 · 낱장 자리에 못 놓은 서류 1(낱장은 Celebrate.swift가 따로 그린다).
    /// 치울 수 있음 = 남길 것(치울 수 없는 워크트리 · 브랜치)만 있을 때의 배치에 없는 칸. 단계 5면 '복잡' 표지(무게 아님 · 치울 몫 아님).
    static func plan(site: Site, clutter: RoomClutter, sheetCapacity: Int) -> [Prop] {
        let worktrees = max(0, clutter.worktrees), branches = max(0, clutter.branches)
        let cleanWorktrees = min(worktrees, max(0, clutter.cleanableWorktrees)), cleanBranches = min(branches, max(0, clutter.cleanableBranches))
        let overflow = max(0, clutter.papers - max(0, sheetCapacity))
        let units = worktrees * 3 + branches + overflow
        let keepUnits = (worktrees - cleanWorktrees) * 3 + (branches - cleanBranches)
        var all = props(site: site, units: units)
        let keep = Set(props(site: site, units: keepUnits).map(\.id))
        for index in all.indices { all[index].cleanable = !keep.contains(all[index].id) }
        if clutter.level >= 5, let sign = sign(site: site, props: all) { all.append(sign) }
        return all
    }

    /// 치울 몫을 걷어 간 뒤 남는 짐(다음 setClutter 전까지): 치울 수 있음 칸을 빼고, 남길 것만으로 5단계가 아니면 '복잡' 표지도 뗀다.
    static func remaining(_ clutter: RoomClutter) -> RoomClutter {
        RoomClutter(worktrees: max(0, clutter.worktrees - clutter.cleanableWorktrees), branches: max(0, clutter.branches - clutter.cleanableBranches), bytes: clutter.bytes)
    }
}

/// 방 짐 층의 상태 · 노드(장면이 하나 들고 있다).
final class ClutterLayer {
    /// 프로젝트 → 짐 장부(setClutter가 통째로 바꾸고, setPapers는 서류 수만 바꾼다).
    var state: [String: RoomClutter] = [:]
    /// 새 setClutter(RoomClutter)를 한 번이라도 받았나 — 받은 뒤에는 예전 setClutter(개수)를 무시한다(새 쪽이 우선).
    var rich = false
    /// 프로젝트 → 칸 id → 노드 · 마지막 배치.
    var nodes: [String: [String: SKSpriteNode]] = [:]
    var plans: [String: [ClutterPlan.Prop]] = [:]
    /// 청소 특공대가 치울 몫을 걷어 간 방 — 다음 setClutter까지 그 몫을 다시 그리지 않는다.
    var swept: Set<String> = []
    /// 청소 중인 방(그사이 온 장부는 청소가 끝난 뒤 그린다 — 들고 나갈 상자가 먼저 사라지지 않게).
    var cleaning: String?
    /// 글자: 방 짐 명판 · '작업 중' · '치울 수 있음' · '복잡' · 방 없는 짐 명판. 자리(건물 좌표)와 층을 기억한다(층 보기 중 다른 층 글자는 숨긴다).
    var labels: [String: (badge: TextBadge, point: CGPoint, floor: Int)] = [:]
    /// '정리 중' 테이프(노드 · 글자 · 건물 좌표).
    var tape: SKSpriteNode?
    var tapeText: TextBadge?
    var tapePoint: CGPoint = .zero
    /// 들고 나가는 상자(청소부 품에 얹은 노드).
    var carriedStack: [SKSpriteNode] = []
    /// 먼지 일정(장면 시험의 공용 난수를 흐트러뜨리지 않게 자기 씨앗).
    var random = Variety.Generator(state: 0xD057_C0FF)
    /// 검수용: 먼지 · 실어 낸 상자 · 쓸어 담은 칸 · '정리 중' 테이프를 띄운 적.
    var dustPuffs = 0
    var carried = 0
    var sweptProps = 0
    var tapeShown = 0
}

extension OfficeScene {
    // MARK: 짐 장부

    /// 방(프로젝트)별 짐 → 방 안 짐 층. 앱이 부산물 조사 · 서류 장부 · 청소 뒤 다시 계산해 부른다.
    /// 장부를 통째로 바꾼다: 없는 프로젝트는 짐을 치우고, 서류 낱장도 RoomClutter.papers로 맞춘다(setPapers와 같은 장부 — 나중에 온 값을 따른다).
    /// 이 API를 한 번이라도 받은 뒤에는 예전 setClutter(개수)를 무시한다.
    func setClutter(_ rooms: [String: RoomClutter]) {
        clutter.rich = true
        applyClutter(rooms.filter { !$0.value.isEmpty })
    }

    /// (예전) 방별 치울 수 있는 부산물 개수 — 새 API를 받기 전까지만 얇게 감싼다: 개수를 '치울 수 있는 브랜치'로 보고, 서류는 지금 장부를 둔다.
    func setClutter(_ counts: [String: Int]) {
        guard !clutter.rich else { return }
        var rooms: [String: RoomClutter] = [:]
        for (project, room) in clutter.state where room.papers > 0 { rooms[project] = RoomClutter(papers: room.papers) }
        for (project, count) in counts where count > 0 {
            var room = rooms[project] ?? RoomClutter()
            room.branches = count
            room.cleanableBranches = count
            rooms[project] = room
        }
        applyClutter(rooms)
    }

    private func applyClutter(_ rooms: [String: RoomClutter]) {
        clutter.state = rooms
        clutter.swept.removeAll()
        syncPaperSheets(rooms.compactMapValues { $0.papers > 0 ? $0.papers : nil })
        renderClutter(animated: true)
    }

    /// 서류 장부(setPapers)가 바뀌었다: 짐 장부의 서류 수만 바꿔 다시 그린다(낱장 자리를 넘친 서류는 상자로).
    func clutterPapersChanged(_ counts: [String: Int]) {
        var changed = false
        for project in Set(clutter.state.keys).union(counts.keys) {
            var room = clutter.state[project] ?? RoomClutter()
            let papers = max(0, counts[project] ?? 0)
            guard room.papers != papers else { continue }
            room.papers = papers
            clutter.state[project] = room.isEmpty ? nil : room
            changed = true
        }
        if changed { renderClutter(animated: true) }
    }

    /// 짐을 그릴 방: 서류 더미 · 축하 · 청소와 같은 규칙(이름이 같거나 '프로젝트 2'처럼 나뉜 방의 첫 방).
    func clutterRoomIndex(_ project: String) -> Int? {
        layout.rooms.firstIndex { $0.name == project || $0.name.hasPrefix(project + " ") }
    }

    /// 방 자리(건물 좌표): 책상 x · 창(RoomTheme와 같은 계산 — 프렌치 창은 아래 판넬을 뺀 유리) · 명패.
    func clutterSite(_ index: Int) -> ClutterPlan.Site {
        let room = layout.rooms[index]
        let floor = layout.floors[room.floor]
        let xs = Set((Array(layout.desks.values) + layout.spareDesks).filter { $0.room == index }.map(\.deskX)).sorted()
        let theme = RoomTheme.of(room.name)
        let floorTop = floor.height - BuildingLayout.slab - 6
        var windows: [CGRect] = []
        let window = Furniture.themedWindow(theme.window, trim: theme.palette.trim, accent: theme.palette.accent, view: theme.view)
        for (i, x) in xs.enumerated() where theme.windowEvery == 1 || i % 2 == 0 {
            let w = window.canvas.width, h = window.canvas.height
            let top = floorTop - 12 + window.dy - h
            var rect = CGRect(x: CGFloat(x + 39 - w / 2), y: CGFloat(floor.y + floor.height - top - h), width: CGFloat(w), height: CGFloat(h))
            if theme.window == .french { rect = CGRect(x: rect.minX, y: rect.minY + 7, width: rect.width, height: rect.height - 7) }
            windows.append(rect)
        }
        let plateWidth = min(60, room.x1 - room.x0 - 12)
        return ClutterPlan.Site(x0: CGFloat(room.x0), x1: CGFloat(room.x1), line: CGFloat(floor.floorLine), top: CGFloat(floor.y + floor.height),
                                deskXs: xs.map { CGFloat($0) }, windows: windows,
                                plate: CGRect(x: CGFloat(room.x0 + 6), y: CGFloat(floor.y + floor.height - 17), width: CGFloat(plateWidth), height: 9),
                                seed: ClutterPlan.seed(room.name))
    }

    /// 짐 층을 장부대로 다시 그린다(칸 id로 비교 — 그대로인 칸은 두고, 새 칸은 나타나고, 빠진 칸은 사라진다).
    func renderClutter(animated: Bool) {
        var drawn = cleaningProjects
        var roomless: [String] = []
        for project in clutter.state.keys.sorted() {
            drawn.insert(project)
            if let index = clutterRoomIndex(project) {
                guard !cleaningProjects.contains(project) else { continue }
                let site = clutterSite(index)
                let room = clutter.state[project] ?? RoomClutter()
                var plan = ClutterPlan.plan(site: site, clutter: room, sheetCapacity: paperSpots(project).count * 5)
                if clutter.swept.contains(project) {
                    let left = ClutterPlan.remaining(room)
                    plan.removeAll { $0.cleanable || ($0.kind == .sign && left.level < 5) }
                }
                applyClutterPlan(project, plan, animated: animated)
            } else {
                roomless.append(project)
            }
        }
        if !cleaningProjects.contains(where: { clutterRoomIndex($0) == nil }) { renderStorageClutter(roomless, animated: animated) }
        for project in Set(clutter.nodes.keys).union(clutter.plans.keys) where !drawn.contains(project) {
            for node in (clutter.nodes[project] ?? [:]).values { fadeAway(node, animated: animated) }
            clutter.nodes[project] = nil
            clutter.plans[project] = nil
        }
        refreshClutterLabels()
    }

    /// 건물을 다시 지었을 때(방이 옮겨 가거나 책상 수가 바뀜): 새 자리에 연출 없이.
    func relayoutClutter() {
        guard !clutter.state.isEmpty || !clutter.nodes.isEmpty else { return }
        renderClutter(animated: false)
    }

    private func fadeAway(_ node: SKNode, animated: Bool) {
        guard animated else { node.removeFromParent(); return }
        node.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
    }

    private func applyClutterPlan(_ project: String, _ plan: [ClutterPlan.Prop], animated: Bool) {
        var nodes = clutter.nodes[project] ?? [:]
        let ids = Set(plan.map(\.id))
        for (id, node) in nodes where !ids.contains(id) {
            nodes[id] = nil
            fadeAway(node, animated: animated)
        }
        for prop in plan {
            let key = Self.clutterTextureKey(prop)
            let node = nodes[prop.id] ?? {
                let made = SKSpriteNode()
                made.anchorPoint = .zero
                world.addChild(made)
                if animated { made.alpha = 0; made.run(.fadeIn(withDuration: 0.3), withKey: "appear") }
                return made
            }()
            if node.name != "clutter:" + key { node.texture = TextureCache.shared.texture(key) { Self.clutterCanvas(prop) } }
            node.name = "clutter:" + key
            node.size = prop.frame.size
            node.position = prop.origin
            node.zRotation = prop.rotation
            node.zPosition = prop.z
            nodes[prop.id] = node
        }
        clutter.nodes[project] = nodes.isEmpty ? nil : nodes
        clutter.plans[project] = plan.isEmpty ? nil : plan
    }

    static func clutterTextureKey(_ prop: ClutterPlan.Prop) -> String {
        let clean = prop.cleanable ? 1 : 0
        switch prop.kind {
        case .box: return "clutter-box-\(prop.size.rawValue)-\(prop.variant)-\(clean)"
        case .deskSheet: return "clutter-sheet-\(prop.variant % 2)-\(clean)"
        case .deskStack: return "clutter-stack-\(Int(prop.frame.height))-\(prop.variant)-\(clean)"
        case .binders: return "clutter-binders-\(prop.variant)-\(clean)"
        case .spill: return "clutter-spill-\(Int(prop.frame.width))-\(prop.variant % 2)-\(clean)"
        case .sign: return "clutter-sign"
        }
    }

    static func clutterCanvas(_ prop: ClutterPlan.Prop) -> PixelCanvas {
        switch prop.kind {
        case .box: return ClutterArt.box(prop.size, variant: prop.variant, cleanable: prop.cleanable)
        case .deskSheet: return ClutterArt.deskSheets(variant: prop.variant, cleanable: prop.cleanable)
        case .deskStack: return ClutterArt.deskStack(height: Int(prop.frame.height), variant: prop.variant, cleanable: prop.cleanable)
        case .binders: return ClutterArt.binders(variant: prop.variant, cleanable: prop.cleanable)
        case .spill: return ClutterArt.spill(width: Int(prop.frame.width), variant: prop.variant, cleanable: prop.cleanable)
        case .sign: return ClutterArt.complexSign()
        }
    }

    // MARK: 방 없는 프로젝트의 짐

    /// 방 없는 짐 자리: 기계실 디스크 저장고 오른쪽 틈(선반 428~458 · 실측 알림 자리 474 사이). 한 줄로 최대 5상자.
    static let storageX: CGFloat = 460
    static let storageMax = 5

    /// 방이 없는 프로젝트(세션이 없어 사무실에 방이 없음)의 짐: 기계실에 한 줄로 쌓는다 — 남길 것이 아래, 치울 것이 위(청소하면 위에서 걷힌다).
    /// 프로젝트마다 무게 5당 한 상자(1~3), 모두 합쳐 5상자까지. 치운 뒤에는 남은 상자가 내려앉는다(바로 다시 쌓는다).
    private func renderStorageClutter(_ projects: [String], animated: Bool) {
        let line = CGFloat(layout.floors[layout.basementIndex].floorLine)
        var keep: [(project: String, index: Int)] = [], clean: [(project: String, index: Int)] = []
        for project in projects.sorted() {
            guard let room = clutter.state[project], room.load > 0 else { continue }
            let total = min(3, max(1, (room.load + 4) / 5))
            let swept = clutter.swept.contains(project)
            let keepLoad = room.load - room.cleanableLoad
            var cleanable = room.cleanableLoad == 0 ? 0 : max(1, Int((Double(total) * Double(room.cleanableLoad) / Double(room.load)).rounded()))
            if keepLoad > 0 { cleanable = min(cleanable, total - 1) }
            let kept = keepLoad == 0 ? 0 : total - cleanable
            for index in 0..<kept { keep.append((project, index)) }
            if !swept { for index in 0..<cleanable { clean.append((project, kept + index)) } }
        }
        var plans: [String: [ClutterPlan.Prop]] = [:]
        var y = line + ClutterPlan.backRow
        for (slot, item) in (keep.map { ($0, false) } + clean.map { ($0, true) }).prefix(Self.storageMax).enumerated() {
            let key = "s-\(item.0.project)-\(item.0.index)"
            let size: ClutterArt.BoxSize = slot % 2 == 0 ? .big : .small
            let x = Self.storageX + (size == .big ? 0 : 1)
            plans[item.0.project, default: []].append(ClutterPlan.Prop(id: key, kind: .box, frame: CGRect(x: x, y: y, width: CGFloat(size.width), height: CGFloat(size.height)),
                                                                       z: 2.30 + CGFloat(slot) * 0.004, variant: ClutterPlan.roll(ClutterPlan.seed(item.0.project), key, ClutterArt.tones.count * 3),
                                                                       size: size, column: "storage", tier: slot, cleanable: item.1))
            y += CGFloat(size.height)
        }
        for project in projects { applyClutterPlan(project, plans[project] ?? [], animated: animated) }
    }

    // MARK: 글자(가까이 다가갔을 때만)

    /// 방 짐 명판(방 이름표 아래) · '작업 중'(남길 짐) · '치울 수 있음'(치울 짐) · '복잡'(5단계 표지) · 방 없는 짐 명판.
    func refreshClutterLabels() {
        var wanted: [String: (text: String, point: CGPoint, style: TextBadge.Style, color: NSColor?, floor: Int)] = [:]
        var roomless = RoomClutter()
        for (project, room) in clutter.state {
            let plan = clutter.plans[project] ?? []
            guard let index = clutterRoomIndex(project) else {
                roomless.worktrees += room.worktrees; roomless.branches += room.branches; roomless.papers += room.papers; roomless.bytes += room.bytes
                continue
            }
            let site = clutterSite(index), floor = layout.rooms[index].floor
            wanted["plate|\(project)"] = (Self.clutterPlateText(room), CGPoint(x: site.plate.midX, y: site.plate.minY - 5), .tiny, nil, floor)
            for (key, item) in Self.clutterTags(plan.filter { clutter.nodes[project]?[$0.id] != nil }, line: site.line) {
                wanted["\(key)|\(project)"] = (item.text, item.point, item.style, item.color, floor)
            }
        }
        if !roomless.isEmpty {
            // 기계실 이름표 줄(디스크 저장고 · 시스템 랙 사이) — 경고등(458, 바닥 위 44~50)을 가리지 않게.
            let line = CGFloat(layout.floors[layout.basementIndex].floorLine)
            wanted["plate|"] = ("방 없는 짐 · " + Self.clutterPlateText(roomless), CGPoint(x: Self.storageX + 5, y: line + 56), .tiny, nil, layout.basementIndex)
        }
        for (key, item) in clutter.labels where wanted[key] == nil {
            item.badge.removeFromParent()
            clutter.labels[key] = nil
        }
        for (key, item) in wanted {
            let badge = clutter.labels[key]?.badge ?? {
                let made = TextBadge(item.text, style: item.style, color: item.color ?? .white)
                overlay.addChild(made)
                return made
            }()
            badge.set(item.text)
            clutter.labels[key] = (badge, item.point, item.floor)
        }
        repositionClutterLabels()
    }

    /// 명판 글자: 워크트리 · 브랜치 · 서류 · 워크트리 디스크(1GB 미만은 MB, 워크트리 디스크가 0이면 뺀다).
    static func clutterPlateText(_ room: RoomClutter) -> String {
        "워크트리 \(room.worktrees) · 브랜치 \(room.branches) · 서류 \(room.papers)" + (room.bytes > 0 ? " · \(Fmt.size(room.bytes))" : "")
    }

    /// 꼬리표 자리(지금 놓인 짐에서): '치울 수 있음' = 가장 높은 치울 상자 위 · '작업 중' = 남길 상자(되도록 칸 전체가 남는 칸의 맨 위) 위.
    /// 상자가 없으면 책상 짐의 책상 앞판에. '복잡' 표지 글자는 표지 위에. 꼬리표끼리 · 표지와 겹치지 않게 다음 후보로 넘긴다.
    static func clutterTags(_ present: [ClutterPlan.Prop], line: CGFloat) -> [String: (text: String, point: CGPoint, style: TextBadge.Style, color: NSColor?)] {
        var tags: [String: (text: String, point: CGPoint, style: TextBadge.Style, color: NSColor?)] = [:]
        let sign = present.first { $0.kind == .sign }
        var taken: [CGRect] = sign.map { [$0.frame.insetBy(dx: -4, dy: -2)] } ?? []
        let boxes = present.filter { $0.kind == .box }
        let tops = Dictionary(grouping: boxes.filter { !$0.front }, by: \.column).compactMapValues { $0.max { $0.frame.maxY < $1.frame.maxY } }
        /// 칸 맨 위 상자 · 앞줄 상자는 그 위에, 칸 중간 상자는 그 앞면에(위는 다른 상자라), 책상 짐은 책상 앞판에.
        func point(_ prop: ClutterPlan.Prop) -> CGPoint {
            guard prop.kind == .box else { return CGPoint(x: prop.frame.midX, y: line + 5) }
            let top = prop.front || tops[prop.column]?.id == prop.id
            return CGPoint(x: prop.bounds.midX, y: top ? prop.bounds.maxY + 2 : prop.bounds.midY)
        }
        /// 꼬리표가 차지할 대략의 자리(가상 픽셀 — 가까이서 글자 약 14px 폭 · 4px 높이).
        func area(_ point: CGPoint) -> CGRect { CGRect(x: point.x - 8, y: point.y - 2.5, width: 16, height: 5) }
        func pick(_ candidates: [ClutterPlan.Prop]) -> CGPoint? {
            for prop in candidates {
                let spot = point(prop)
                guard !taken.contains(where: { $0.intersects(area(spot)) }) else { continue }
                taken.append(area(spot))
                return spot
            }
            return nil
        }
        let desk = present.filter { $0.kind != .box && $0.kind != .sign && $0.kind != .spill }
        let cleanBoxes = tops.values.filter(\.cleanable).sorted { $0.bounds.maxY != $1.bounds.maxY ? $0.bounds.maxY > $1.bounds.maxY : $0.id < $1.id }
            + boxes.filter { $0.front && $0.cleanable }.sorted { $0.id < $1.id }
        if let spot = pick(cleanBoxes + desk.filter(\.cleanable)) { tags["clean"] = ("치울 수 있음", spot, .tiny, nil) }
        let keptColumns = Set(Dictionary(grouping: boxes, by: \.column).filter { $0.value.allSatisfy { !$0.cleanable } }.keys)
        let keptBoxes = boxes.filter { !$0.cleanable && !$0.front }.sorted { lhs, rhs in
            let l = keptColumns.contains(lhs.column) && tops[lhs.column]?.id == lhs.id, r = keptColumns.contains(rhs.column) && tops[rhs.column]?.id == rhs.id
            return l != r ? l : lhs.bounds.maxY != rhs.bounds.maxY ? lhs.bounds.maxY > rhs.bounds.maxY : lhs.id < rhs.id
        }
        if let spot = pick(keptBoxes + boxes.filter { $0.front && !$0.cleanable } + desk.filter { !$0.cleanable }) { tags["work"] = ("작업 중", spot, .tiny, nil) }
        if let sign { tags["sign"] = ("복잡", CGPoint(x: sign.frame.midX, y: sign.frame.midY), .sign, NSColor(srgbRed: 0.8, green: 0.12, blue: 0.14, alpha: 1)) }
        return tags
    }

    /// 짐 글자를 카메라에 맞춘다(가까이 다가갔을 때만 · 층 보기 중에는 그 층만 보인다 · '정리 중'은 청소하는 동안 늘).
    func repositionClutterLabels() {
        let zoomed = lodZoomed ?? false
        for (_, item) in clutter.labels {
            item.badge.isHidden = !zoomed || offFocus(floor: item.floor)
            item.badge.position = CGPoint(x: item.point.x * pointsPerPixel, y: item.point.y * pointsPerPixel)
        }
        if let text = clutter.tapeText { text.position = CGPoint(x: clutter.tapePoint.x * pointsPerPixel, y: clutter.tapePoint.y * pointsPerPixel) }
    }

    // MARK: 5단계: 가끔 먼지

    /// 1초마다: 5단계 방은 가끔(약 다섯 번에 한 번) 상자 탑 꼭대기에서 먼지가 피어오른다.
    func clutterTick() {
        for project in clutter.plans.keys.sorted() where (clutter.state[project]?.level ?? 0) >= 5 && clutter.cleaning != project {
            guard Double.random(in: 0..<1, using: &clutter.random) < 0.2 else { continue }
            let tops = Dictionary(grouping: (clutter.plans[project] ?? []).filter { $0.kind == .box && !$0.front && clutter.nodes[project]?[$0.id] != nil }, by: \.column)
                .compactMap { $0.value.max { $0.frame.maxY < $1.frame.maxY } }.sorted { $0.id < $1.id }
            guard !tops.isEmpty else { continue }
            let top = tops[Int(clutter.random.next() % UInt64(tops.count))]
            Effects.burst(in: world, at: CGPoint(x: top.bounds.midX, y: top.bounds.maxY + 1), color: ClutterArt.dust, count: 4, spread: 7, rise: 8, duration: 0.9)
            clutter.dustPuffs += 1
        }
    }

    // MARK: 청소 특공대

    /// 치울 몫(그 방에서 치울 수 있음으로 표시된 칸): 상자는 들고 나가고, 서류 더미 · 바인더 · 낱장 · 쏟아진 서류는 쓸어 담는다.
    /// 남길 것만으로 5단계가 아니면 '복잡' 표지도 뗀다. 위에 있는 것부터(아래 것이 먼저 빠져 위 상자가 뜨지 않게).
    struct ClutterShare {
        var boxes: [SKSpriteNode] = []
        var sweepables: [SKSpriteNode] = []
        var ids: [String] = []
    }

    func clutterShare(_ project: String?) -> ClutterShare {
        guard let project, let plan = clutter.plans[project], let nodes = clutter.nodes[project] else { return ClutterShare() }
        let left = ClutterPlan.remaining(clutter.state[project] ?? RoomClutter())
        var share = ClutterShare()
        for prop in plan.sorted(by: { $0.bounds.maxY != $1.bounds.maxY ? $0.bounds.maxY > $1.bounds.maxY : $0.id < $1.id }) {
            guard prop.cleanable || (prop.kind == .sign && left.level < 5), let node = nodes[prop.id] else { continue }
            if prop.kind == .box { share.boxes.append(node) } else { share.sweepables.append(node) }
            share.ids.append(prop.id)
        }
        return share
    }

    /// 청소 시작(특공대가 방에 닿을 때): '정리 중' 테이프를 치고, 치울 몫을 장부에서 뗀다(다음 setClutter까지 다시 그리지 않는다) · 쓸 것은 비질하는 사람 쪽으로.
    func clutterSweep(_ project: String?, share: ClutterShare, toward collector: SKSpriteNode, floor: Int) {
        guard let project else { return }
        showCleaningTape(project, floor: floor)
        clutter.swept.insert(project)
        for id in share.ids { clutter.nodes[project]?[id] = nil }
        if clutter.nodes[project]?.isEmpty == true { clutter.nodes[project] = nil }
        for (index, node) in share.sweepables.enumerated() {
            node.removeAction(forKey: "appear")
            let target = CGPoint(x: collector.position.x + 4, y: collector.position.y + 12)
            node.run(.sequence([.wait(forDuration: Double(index) * 0.07),
                                .group([.move(to: target, duration: 0.4), .rotate(byAngle: 1.0, duration: 0.4), .fadeOut(withDuration: 0.4)]),
                                .removeFromParent()]))
            clutter.sweptProps += 1
        }
        if let first = share.sweepables.first { Effects.burst(in: world, at: first.position, color: ClutterArt.dust, count: 6, spread: 10, rise: 8, duration: 0.5) }
        refreshClutterLabels()
    }

    /// 상자 들기: 치울 상자가 위에 있는 것부터 하나씩 청소부 품으로 날아와 쌓인다(품에 넷까지 보이고 나머지는 그 속에 들어간다).
    func clutterPickUp(_ boxes: [SKSpriteNode], carrier: SKSpriteNode) {
        let gap = min(0.16, 1.4 / Double(max(1, boxes.count)))
        for (index, box) in boxes.enumerated() {
            box.removeAction(forKey: "appear")
            box.run(.sequence([
                .wait(forDuration: Double(index) * gap),
                .run { [weak self] in
                    guard let self else { return }
                    Effects.burst(in: self.world, at: CGPoint(x: box.position.x + box.size.width / 2, y: box.position.y + 2), color: ClutterArt.dust, count: 3, spread: 5, rise: 5, duration: 0.4)
                },
                .group([.move(to: CGPoint(x: carrier.position.x, y: carrier.position.y + 13 + CGFloat(min(index, 4)) * 6), duration: 0.35), .rotate(toAngle: 0, duration: 0.35)]),
                .run { [weak self, weak carrier] in
                    guard let self else { return }
                    box.removeFromParent()
                    self.clutter.carried += 1
                    guard let carrier, carrier.parent != nil, self.clutter.carriedStack.count < 4 else { return }
                    let held = SKSpriteNode(texture: box.texture, size: box.size)
                    held.anchorPoint = .zero
                    held.position = CGPoint(x: 0, y: 13 + self.clutter.carriedStack.reduce(0) { $0 + $1.size.height })
                    held.zPosition = 0.1
                    carrier.addChild(held)
                    self.clutter.carriedStack.append(held)
                }
            ]))
        }
    }

    /// 들고 있던 상자를 엘리베이터에 싣고 내린다(엘리베이터 문 앞에서 사라질 때).
    func clutterUnload() {
        clutter.carriedStack.forEach { $0.removeFromParent() }
        clutter.carriedStack = []
    }

    /// '정리 중' 테이프: 방을 가로지르는 노랑 · 검정 줄(직원 이름표 · 제목 풍선보다 위) + 가운데 글자. 청소가 끝나면 걷는다.
    private func showCleaningTape(_ project: String, floor: Int) {
        hideCleaningTape()
        let span: (CGFloat, CGFloat)
        let y: CGFloat
        if let index = clutterRoomIndex(project) {
            let room = layout.rooms[index]
            span = (CGFloat(room.x0 + 4), CGFloat(room.x1 - 6))
            y = line(room.floor) + 46
        } else {
            span = (Self.storageX - 14, Self.storageX + 14)
            y = line(layout.basementIndex) + 40
        }
        let width = Int(span.1 - span.0)
        let tape = SKSpriteNode(texture: TextureCache.shared.texture("clutter-tape-\(width)") { ClutterArt.cleaningTape(width: width) })
        tape.anchorPoint = .zero
        tape.size = CGSize(width: width, height: 3)
        tape.position = CGPoint(x: span.0, y: y)
        tape.zPosition = 4.8
        world.addChild(tape)
        clutter.tape = tape
        let text = TextBadge("정리 중", style: .tiny)
        overlay.addChild(text)
        clutter.tapeText = text
        clutter.tapePoint = CGPoint(x: (span.0 + span.1) / 2, y: y + 1.5)
        clutter.tapeShown += 1
        repositionClutterLabels()
    }

    func hideCleaningTape() {
        clutter.tape?.removeFromParent()
        clutter.tape = nil
        clutter.tapeText?.removeFromParent()
        clutter.tapeText = nil
    }

    /// 청소가 끝났다(특공대가 돌아감): 테이프를 걷고, 그사이 온 장부를 그린다(치운 몫은 다음 setClutter까지 다시 나오지 않는다).
    func clutterCleaningDone() {
        hideCleaningTape()
        clutterUnload()
        clutter.cleaning = nil
        renderClutter(animated: true)
    }

    // MARK: 검수용

    struct ClutterProbe {
        var id: String
        var kind: ClutterPlan.Prop.Kind
        var frame: CGRect
        var bounds: CGRect
        var z: CGFloat
        var rotation: CGFloat
        var cleanable: Bool
        /// 노드가 실제로 쓰는 그림이 '치울 수 있음' 그림인가(텍스처 열쇠 끝 -1).
        var cleanLook: Bool
        /// 노드 자리 = 배치 자리(왼쪽 아래 · 돌린 자리 포함).
        var placed: Bool
        var column: String
        var tier: Int
        var front: Bool
    }

    /// 그 방에 지금 놓인 짐(날아가는 중 · 사라지는 중인 노드는 빼고).
    func clutterProbes(_ project: String) -> [ClutterProbe] {
        let nodes = clutter.nodes[project] ?? [:]
        return (clutter.plans[project] ?? []).compactMap { prop in
            guard let node = nodes[prop.id] else { return nil }
            let key = node.name ?? ""
            let placed = abs(node.position.x - prop.origin.x) < 0.01 && abs(node.position.y - prop.origin.y) < 0.01 && abs(node.zRotation - prop.rotation) < 0.0001
            return ClutterProbe(id: prop.id, kind: prop.kind, frame: prop.frame, bounds: prop.bounds, z: node.zPosition, rotation: prop.rotation, cleanable: prop.cleanable,
                                cleanLook: key.hasSuffix("-1"), placed: placed, column: prop.column, tier: prop.tier, front: prop.front)
        }
    }

    /// 짐 글자(명판 · '작업 중' · '치울 수 있음' · '복잡' · 방 없는 짐 명판은 project ""): 글자 · 숨김.
    func clutterLabel(_ kind: String, _ project: String) -> (text: String, hidden: Bool)? {
        clutter.labels["\(kind)|\(project)"].map { ($0.badge.currentText, $0.badge.isHidden) }
    }

    var clutterTapeVisible: Bool { clutter.tape?.parent != nil }
    var clutterTapeText: String? { clutter.tapeText?.currentText }
    var clutterStats: (dust: Int, carried: Int, swept: Int, tapes: Int, held: Int) { (clutter.dustPuffs, clutter.carried, clutter.sweptProps, clutter.tapeShown, clutter.carriedStack.count) }
    var clutterCleaning: String? { clutter.cleaning }
}
