import Foundation

/// 가구·소품. 참고 사진 8장의 재질(월넛·트래버틴·머스터드 소파·초록 벨벳·흰 패널 문·야자수)을 픽셀로 옮겼다.
enum Furniture {
    static func desk() -> PixelCanvas {
        var c = PixelCanvas(24, 11)
        c.box(0, 0, 24, 3, fill: Pal.walnutLight, rounded: false)
        c.hline(1, 1, 22, Pal.walnut)
        c.rect(2, 3, 2, 8, Pal.walnutDark); c.rect(20, 3, 2, 8, Pal.walnutDark)
        c.box(14, 3, 8, 5, fill: Pal.walnut, rounded: false)
        c.hline(16, 5, 4, Pal.gold)
        return c
    }

    static func monitor(on: Bool, frame: Int = 0) -> PixelCanvas {
        var c = PixelCanvas(12, 11)
        c.box(0, 0, 12, 8, fill: on ? Pal.monitorOn : Pal.monitorOff, rounded: false)
        if on {
            for (index, y) in [2, 4, 6].enumerated() {
                let length = [6, 8, 5][(index + frame) % 3]
                c.hline(2, y, length, Pal.screenLine)
            }
            c.dot(9, 2, Pal.white)
        }
        c.rect(5, 8, 2, 2, Pal.metal); c.hline(3, 10, 6, Pal.outline)
        return c
    }

    static func keyboard() -> PixelCanvas {
        var c = PixelCanvas(8, 2)
        c.rect(0, 0, 8, 1, Pal.metalLight); c.hline(0, 1, 8, Pal.outline)
        return c
    }

    static func chair() -> PixelCanvas {
        var c = PixelCanvas(10, 15)
        c.box(0, 0, 4, 9, fill: Pal.black.lighter(0.25))
        c.box(0, 7, 10, 3, fill: Pal.black.lighter(0.25), rounded: false)
        c.vline(5, 10, 3, Pal.metal)
        c.hline(1, 13, 8, Pal.metal); c.dot(1, 14, Pal.outline); c.dot(8, 14, Pal.outline)
        return c
    }

    static func sofa() -> PixelCanvas {
        var c = PixelCanvas(36, 15)
        let m = Pal.mustard, d = Pal.mustardShade
        c.box(3, 0, 30, 8, fill: m)
        c.hline(4, 6, 28, d)
        c.box(0, 4, 8, 10, fill: m); c.box(28, 4, 8, 10, fill: m)
        c.box(5, 7, 26, 6, fill: m.lighter(0.08), rounded: false)
        c.hline(6, 11, 24, d)
        c.vline(18, 8, 4, d)
        c.dot(2, 14, Pal.walnutDark); c.dot(33, 14, Pal.walnutDark)
        return c
    }

    static func armchair() -> PixelCanvas {
        var c = PixelCanvas(15, 15)
        c.box(2, 0, 11, 9, fill: Pal.forest)
        c.vline(4, 2, 5, Pal.forestShade)
        c.box(1, 7, 13, 5, fill: Pal.forest.lighter(0.1), rounded: false)
        c.hline(0, 7, 15, Pal.teak); c.vline(0, 7, 8, Pal.teak); c.vline(14, 7, 8, Pal.teak)
        c.vline(2, 12, 3, Pal.teak); c.vline(12, 12, 3, Pal.teak)
        return c
    }

    static func coffeeTable() -> PixelCanvas {
        var c = PixelCanvas(20, 8)
        c.box(0, 0, 20, 3, fill: Pal.travertine, rounded: false)
        c.dot(4, 1, Pal.travertineSpeck); c.dot(12, 1, Pal.travertineSpeck); c.dot(16, 1, Pal.travertineSpeck)
        c.box(3, 3, 5, 5, fill: Pal.travertine, rounded: false); c.box(12, 3, 5, 5, fill: Pal.travertine, rounded: false)
        // 꽃병
        c.rect(9, -0, 2, 1, Pal.leaf)
        return c
    }

    static func flowers() -> PixelCanvas {
        var c = PixelCanvas(9, 10)
        for (x, y, color) in [(1, 1, PixelColor(0xB58BE0)), (4, 0, PixelColor(0xF29BB0)), (7, 2, PixelColor(0xF7D154)), (3, 3, PixelColor(0x8FB8F0)), (6, 4, PixelColor(0xF29BB0))] {
            c.rect(x, y, 2, 2, color)
        }
        c.vline(4, 4, 3, Pal.leafDark); c.dot(2, 5, Pal.leaf); c.dot(6, 6, Pal.leaf)
        c.box(2, 6, 5, 4, fill: Pal.glass.with(alpha: 255), rounded: false)
        return c
    }

    static func sideTable() -> PixelCanvas {
        var c = PixelCanvas(7, 9)
        for y in stride(from: 0, to: 9, by: 3) { c.box(0, y, 7, 3, fill: Pal.terracotta, rounded: true) }
        return c
    }

    static func fiddleFig() -> PixelCanvas {
        var c = PixelCanvas(16, 30)
        c.vline(8, 10, 14, Pal.walnutDark)
        let leaves: [(Int, Int)] = [(4, 2), (9, 0), (2, 7), (11, 5), (6, 9), (12, 11), (3, 13), (9, 15)]
        for (index, leaf) in leaves.enumerated() {
            c.box(leaf.0, leaf.1, 5, 5, fill: index % 2 == 0 ? Pal.leaf : Pal.leafDark)
            c.dot(leaf.0 + 1, leaf.1 + 1, Pal.leafLight)
        }
        c.box(4, 23, 9, 7, fill: Pal.concrete, rounded: true)
        c.hline(5, 24, 7, Pal.concrete.lighter(0.3))
        return c
    }

    static func palm() -> PixelCanvas {
        var c = PixelCanvas(20, 30)
        c.vline(10, 8, 15, Pal.oakDark)
        for i in 0..<5 {
            c.hline(2 + i, 3 + i, 7, Pal.leaf); c.hline(11 - i + 2, 3 + i, 7, Pal.leafDark)
        }
        c.hline(4, 2, 12, Pal.leafLight); c.hline(1, 8, 6, Pal.leaf); c.hline(13, 8, 6, Pal.leafDark)
        c.box(5, 22, 10, 8, fill: Pal.terracotta, rounded: true)
        return c
    }

    static func smallPlant() -> PixelCanvas {
        var c = PixelCanvas(9, 11)
        c.box(1, 0, 7, 6, fill: Pal.leaf); c.dot(3, 1, Pal.leafLight); c.dot(5, 3, Pal.leafDark)
        c.box(2, 6, 5, 5, fill: Pal.terracotta, rounded: false)
        return c
    }

    static func wallShelf() -> PixelCanvas {
        var c = PixelCanvas(28, 24)
        let colors = [PixelColor(0xD9534F), PixelColor(0x5B8DEF), PixelColor(0xF2C14E), PixelColor(0x3FA34D), PixelColor(0xE07A5F), PixelColor(0x9C7AD8)]
        for (row, y) in [6, 14, 22].enumerated() {
            c.hline(0, y, 28, Pal.black); c.dot(2, y + 1, Pal.walnut); c.dot(25, y + 1, Pal.walnut)
            var x = 2 + row
            var i = row
            while x < 24 {
                let h = 4 + (i % 3)
                c.rect(x, y - h, 2, h, colors[i % colors.count])
                x += 3 + (i % 2)
                i += 1
            }
        }
        c.box(20, 9, 4, 5, fill: Pal.terracotta) // 화병
        return c
    }

    static func tallWindow(night: Bool = false) -> PixelCanvas {
        var c = PixelCanvas(18, 34)
        c.box(3, 0, 12, 30, fill: night ? PixelColor(0x2D3E6E) : Pal.skyBottom)
        c.rect(4, 1, 10, 6, night ? PixelColor(0x26355E) : Pal.skyTop)
        c.vline(9, 1, 28, Pal.doorWhite); c.hline(4, 12, 10, Pal.doorWhite)
        c.hline(4, 22, 10, Pal.doorWhite)
        if !night { c.rect(5, 15, 3, 4, PixelColor(0xC96F52)); c.rect(11, 17, 3, 3, PixelColor(0xC96F52)) } // 건너편 벽돌집
        c.rect(0, 0, 4, 34, PixelColor(0xE9DECA)); c.vline(1, 0, 34, PixelColor(0xD6C8AE))
        c.rect(14, 0, 4, 34, PixelColor(0xE9DECA)); c.vline(16, 0, 34, PixelColor(0xD6C8AE))
        c.hline(2, 30, 14, Pal.doorWhite)
        return c
    }

    /// 1층 출입문(흰 패널 양문). state: 0 닫힘, 1 열림, 2 발차기 직후(문짝이 튕겨 나감).
    static func entranceDoor(_ state: Int) -> PixelCanvas {
        var c = PixelCanvas(30, 36)
        c.box(0, 0, 30, 36, fill: PixelColor(0xEFE6D4), rounded: false)
        c.rect(2, 2, 26, 34, state == 0 ? Pal.doorWhite : PixelColor(0xFFF4C8))
        if state == 0 {
            for x in [2, 15] {
                c.box(x, 2, 13, 34, fill: Pal.doorWhite, rounded: false)
                c.box(x + 3, 6, 7, 10, fill: Pal.doorWhite)
                c.box(x + 3, 20, 7, 12, fill: Pal.doorWhite)
                c.dot(x + 6, 11, Pal.doorShade); c.dot(x + 6, 26, Pal.doorShade)
            }
            c.vline(13, 16, 6, Pal.gold); c.vline(16, 16, 6, Pal.gold)
        } else {
            // 열린 문 너머의 밝은 바깥(나무·하늘)
            c.rect(3, 3, 24, 18, Pal.skyBottom)
            c.box(6, 9, 7, 9, fill: Pal.leaf); c.box(17, 7, 8, 10, fill: Pal.leafDark)
            c.rect(3, 21, 24, 15, Pal.travertine)
            let swing = state == 2 ? 3 : 0
            c.box(0 - swing, 2, 5, 34, fill: Pal.doorWhite, rounded: false); c.vline(3 - swing, 18, 3, Pal.gold)
            c.box(25 + swing, 2, 5, 34, fill: Pal.doorWhite, rounded: false); c.vline(26 + swing, 18, 3, Pal.gold)
        }
        c.hline(0, 0, 30, Pal.outline)
        return c
    }

    static func receptionDesk() -> PixelCanvas {
        var c = PixelCanvas(24, 14)
        c.box(0, 0, 24, 3, fill: Pal.travertine, rounded: false)
        c.box(1, 3, 22, 11, fill: Pal.walnut, rounded: false)
        for x in stride(from: 3, to: 22, by: 3) { c.vline(x, 4, 9, Pal.walnutDark) }
        c.box(17, -3, 5, 4, fill: Pal.gold) // 스탠드 조명
        return c
    }

    static func whiteboard() -> PixelCanvas {
        var c = PixelCanvas(100, 40)
        c.box(0, 0, 100, 38, fill: Pal.paper, rounded: false)
        c.hline(1, 1, 98, PixelColor(0xE8E8E8))
        c.box(0, 36, 100, 3, fill: Pal.metalLight, rounded: false)
        c.rect(80, 35, 5, 2, Pal.alarm); c.rect(88, 35, 5, 2, Pal.screenLine)
        return c
    }

    static func lounger() -> PixelCanvas {
        var c = PixelCanvas(30, 10)
        c.box(0, 3, 22, 4, fill: Pal.mustard, rounded: true)
        c.box(20, 0, 8, 7, fill: Pal.mustard)
        c.hline(2, 5, 18, Pal.mustardShade)
        c.vline(3, 7, 3, Pal.black); c.vline(24, 7, 3, Pal.black)
        c.dot(3, 9, Pal.metal); c.dot(24, 9, Pal.metal)
        return c
    }

    static func hammock() -> PixelCanvas {
        var c = PixelCanvas(34, 14)
        for x in 0..<34 {
            let sag = Int(4 * sin(Double(x) / 33 * .pi))
            c.dot(x, 3 + sag, Pal.oakDark.lighter(0.2))
            if x > 3 && x < 30 {
                c.rect(x, 5 + sag, 1, 3, x % 4 < 2 ? PixelColor(0x5B8DEF) : Pal.white)
            }
        }
        return c
    }

    static func recordShelf() -> PixelCanvas {
        var c = PixelCanvas(34, 50)
        c.box(0, 0, 34, 50, fill: Pal.oak, rounded: false)
        for y in stride(from: 9, to: 50, by: 10) {
            c.hline(1, y, 32, Pal.oakDark)
            for x in stride(from: 2, to: 32, by: 2) {
                let color = [PixelColor(0x2A2A34), PixelColor(0xD9534F), PixelColor(0xEAE0C8), PixelColor(0x5B8DEF), PixelColor(0x3B2A4A)][(x + y) % 5]
                c.rect(x, y - 7, 1, 7, color)
            }
        }
        // 사다리
        c.vline(26, 0, 50, Pal.oakDark.lighter(0.3)); c.vline(31, 0, 50, Pal.oakDark.lighter(0.3))
        for y in stride(from: 3, to: 50, by: 5) { c.hline(27, y, 4, Pal.oakDark.lighter(0.3)) }
        return c
    }

    static func lantern() -> PixelCanvas {
        var c = PixelCanvas(8, 9)
        c.vline(4, 0, 2, Pal.outline)
        c.box(0, 2, 8, 7, fill: PixelColor(0xFFF6DD))
        c.hline(1, 4, 6, PixelColor(0xF1E2B8)); c.hline(1, 6, 6, PixelColor(0xF1E2B8))
        return c
    }

    static func floorLamp() -> PixelCanvas {
        var c = PixelCanvas(9, 26)
        c.box(0, 0, 9, 6, fill: PixelColor(0xFFF2D6))
        c.vline(4, 6, 18, Pal.gold)
        c.hline(1, 24, 7, Pal.gold); c.hline(1, 25, 7, Pal.outline)
        return c
    }

    static func box(_ variant: Int = 0) -> PixelCanvas {
        var c = PixelCanvas(9, 8)
        c.box(0, 0, 9, 8, fill: variant % 2 == 0 ? Pal.cardboard : Pal.cardboard.lighter(0.08), rounded: false)
        c.hline(1, 3, 7, Pal.tape); c.vline(4, 1, 2, Pal.tape)
        c.dot(2, 5, Pal.cardboardShade); c.dot(6, 6, Pal.cardboardShade)
        return c
    }

    static func warehouseShelf(fill: Double) -> PixelCanvas {
        var c = PixelCanvas(30, 34)
        c.vline(0, 0, 34, Pal.metal); c.vline(29, 0, 34, Pal.metal)
        let slots = 12
        let filled = Int((fill * Double(slots)).rounded())
        var index = 0
        for y in [8, 19, 30] {
            c.hline(0, y, 30, Pal.metalLight); c.hline(0, y + 1, 30, Pal.metal)
            for x in [2, 9, 16, 22] {
                if index < filled { c.stamp(box(index), x, y - 8) }
                index += 1
            }
        }
        return c
    }

    static func elevatorDoor(open: Double) -> PixelCanvas {
        var c = PixelCanvas(20, 32)
        c.box(0, 0, 20, 32, fill: Pal.metal, rounded: false)
        c.rect(2, 4, 16, 28, PixelColor(0x40464F))
        let gap = Int(open * 7)
        c.box(2, 4, 8 - gap, 28, fill: Pal.metalLight, rounded: false)
        c.box(10 + gap, 4, 8 - gap, 28, fill: Pal.metalLight, rounded: false)
        c.rect(8, 1, 4, 2, Pal.badge)
        return c
    }

    static func fireplace(_ frame: Int) -> PixelCanvas {
        var c = PixelCanvas(24, 44)
        c.box(0, 0, 24, 44, fill: PixelColor(0x8A8F86), rounded: false)
        for (x, y) in [(3, 4), (12, 8), (6, 15), (16, 18), (4, 24), (14, 3), (18, 28)] { c.rect(x, y, 3, 2, PixelColor(0x6E7369)); c.dot(x + 1, y, PixelColor(0xA6AB9F)) }
        c.box(4, 30, 16, 14, fill: Pal.travertine, rounded: false)
        c.rect(6, 33, 12, 11, PixelColor(0x2B2420))
        let flame = frame % 3
        c.rect(8, 38 - flame, 3, 6 + flame, PixelColor(0xF59E3B)); c.rect(12, 37 + flame % 2, 3, 7, PixelColor(0xF7C948)); c.dot(10, 36, PixelColor(0xFFE29A))
        c.hline(7, 43, 10, Pal.oakDark)
        return c
    }

    static func column() -> PixelCanvas {
        var c = PixelCanvas(6, 44)
        c.box(0, 0, 6, 44, fill: PixelColor(0xB5714A), rounded: false)
        c.vline(2, 1, 42, PixelColor(0xC98762))
        c.box(0, 40, 6, 4, fill: Pal.concreteDark, rounded: false)
        return c
    }

    static func canopy(width: Int) -> PixelCanvas {
        var c = PixelCanvas(width, 8)
        for x in 0..<width {
            let sag = Int(3 * sin(Double(x % 40) / 39 * .pi))
            c.vline(x, sag, 3, Pal.white)
            c.dot(x, sag + 3, PixelColor(0xE6E1D6))
        }
        return c
    }

    static func wallArt(_ variant: Int) -> PixelCanvas {
        var c = PixelCanvas(10, 12)
        c.box(0, 0, 10, 12, fill: Pal.gold, rounded: false)
        c.rect(1, 1, 8, 10, Pal.paper)
        let colors = [PixelColor(0xE07A5F), PixelColor(0x5B8DEF), PixelColor(0x3FA34D), PixelColor(0xF2C14E)]
        c.rect(2, 3 + variant % 3, 6, 3, colors[variant % colors.count]); c.rect(3, 7, 3, 2, colors[(variant + 1) % colors.count])
        return c
    }

    static func rug() -> PixelCanvas {
        var c = PixelCanvas(44, 4)
        c.rect(0, 0, 44, 4, PixelColor(0xA8443A))
        for x in stride(from: 2, to: 42, by: 4) { c.dot(x, 1, PixelColor(0xE9C46A)); c.dot(x + 2, 2, PixelColor(0x2A9D8F)) }
        c.hline(0, 0, 44, PixelColor(0xE9C46A)); c.hline(0, 3, 44, PixelColor(0xE9C46A))
        return c
    }

    static func alarmLight(on: Bool) -> PixelCanvas {
        var c = PixelCanvas(6, 6)
        c.box(0, 1, 6, 5, fill: on ? Pal.alarm : Pal.alarm.darker(0.5))
        if on { c.dot(2, 2, Pal.white) }
        c.hline(1, 0, 4, Pal.metal)
        return c
    }

    static func panel() -> PixelCanvas {
        var c = PixelCanvas(20, 24)
        c.box(0, 0, 20, 24, fill: Pal.metal, rounded: false)
        for y in stride(from: 3, to: 20, by: 4) {
            c.dot(3, y, PixelColor(0x6EE7A0)); c.dot(6, y, Pal.alarm); c.hline(9, y, 8, Pal.metalLight)
        }
        return c
    }

    static func previewItems() -> [PixelCanvas] {
        [desk(), monitor(on: true), chair(), sofa(), armchair(), coffeeTable(), sideTable(), fiddleFig(), palm(), wallShelf(), tallWindow(), entranceDoor(0), entranceDoor(2),
         receptionDesk(), lounger(), hammock(), lantern(), floorLamp(), box(), warehouseShelf(fill: 0.6), elevatorDoor(open: 0.5), fireplace(0), column(), wallArt(1), alarmLight(on: true), panel(), flowers()]
    }
}
