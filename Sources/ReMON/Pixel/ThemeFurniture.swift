import Foundation

/// 방 테마용 가구·소품(창 8종 · 천장 등 9종 · 벽 소품 · 구석 소품 · 책상 마감 · 의자 색).
/// 모두 옆에서 본 정면 2D(원근 없음). 색은 방 팔레트에서 받는다. 같은 그림은 FloorPainter가 층 텍스처에 한 번만 찍는다.
extension Furniture {
    // MARK: 창

    /// 창밖 풍경(유리 안쪽 좌표). view 0 건너편 벽돌집 · 1 가로수(계절 색: 벚꽃 · 초록 · 단풍 · 눈) · 2 도시.
    static func windowView(_ x: Int, _ y: Int, _ w: Int, _ h: Int, view: Int, season: Season = .summer) -> PixelColor {
        switch view {
        case 1:
            let crown = h - 4 - (FloorPainter.hash(x / 2, 3, 41) % 3)
            if y >= crown { let tones = season.foliage; return (x + y) % 3 == 0 ? tones[2] : tones[1] }
        case 2:
            let tower = h - 4 - FloorPainter.hash(x / 3, 1, 29) % max(2, h / 3)
            if y >= tower { return (x % 3 == 1 && y % 3 == 0) ? PixelColor(0xE4EEF6) : PixelColor(0x9FB3C8) }
        default:
            let house = h * 11 / 20
            if (x >= 2 && x <= 4 && y >= house && y < house + 4) || (x >= w - 4 && x <= w - 2 && y >= house + 2 && y < house + 5) { return PixelColor(0xC96F52) }
        }
        return y < max(3, h / 5) ? Pal.skyTop : Pal.skyBottom
    }

    /// 유리 칠하기: inside가 참인 칸에 풍경을 넣는다.
    private static func glass(_ c: inout PixelCanvas, _ x0: Int, _ y0: Int, _ w: Int, _ h: Int, view: Int, season: Season = .summer, inside: (Int, Int) -> Bool = { _, _ in true }) {
        for y in 0..<h { for x in 0..<w where inside(x, y) { c.dot(x0 + x, y0 + y, windowView(x, y, w, h, view: view, season: season)) } }
    }

    /// 아치 윗부분 안쪽 판정(반원 + 직사각형). 정수 픽셀 중심 기준.
    private static func inArch(_ x: Int, _ y: Int, width w: Int, radius r: Double) -> Bool {
        let cx = Double(w - 1) / 2, cy = r
        if Double(y) >= cy { return true }
        let dx = Double(x) - cx, dy = Double(y) - cy
        return dx * dx + dy * dy <= r * r + 0.5
    }

    /// 테마 창. 반환한 캔버스는 가운데가 창 중심, 아래가 창턱 높이(dy는 기본 창턱에서 아래로 얼마나 내려오는지).
    static func themedWindow(_ style: RoomTheme.Window, trim: PixelColor, accent: PixelColor, view: Int) -> (canvas: PixelCanvas, dy: Int) {
        let o = Pal.outline, season = Season.current   // 창밖 가로수도 계절 색(층을 다시 그릴 때 반영)
        let casing = trim, casingShade = trim.darker(0.14), muntin = trim.lighter(0.35)
        switch style {
        case .doubleHung: // 오르내리창(위아래 두 짝 + 창살)
            var c = PixelCanvas(18, 34)
            c.rect(0, 0, 4, 34, casing); c.vline(1, 0, 34, casingShade)
            c.rect(14, 0, 4, 34, casing); c.vline(16, 0, 34, casingShade)
            c.box(3, 0, 12, 30, fill: Pal.skyBottom, outline: o, rounded: false)
            glass(&c, 4, 1, 10, 28, view: view, season: season)
            c.vline(9, 1, 28, muntin); c.hline(4, 14, 10, muntin); c.hline(4, 15, 10, casingShade)
            c.hline(2, 30, 14, casing.lighter(0.2)); c.hline(2, 31, 14, casingShade)
            return (c, 0)
        case .arched: // 아치창(쐐기돌)
            var c = PixelCanvas(17, 36)
            for y in 0..<36 { for x in 0..<17 where inArch(x, y, width: 17, radius: 8.5) { c.dot(x, y, casing) } }
            for y in 0..<34 { for x in 0..<13 where inArch(x, y, width: 13, radius: 6.5) { c.dot(x + 2, y + 2, o) } }
            glass(&c, 3, 3, 11, 30, view: view, season: season) { x, y in inArch(x, y, width: 11, radius: 5.5) }
            c.vline(8, 3, 30, muntin); c.hline(3, 18, 11, muntin)
            c.rect(7, 0, 3, 3, casingShade); c.dot(8, 0, casing.lighter(0.25))   // 쐐기돌
            c.hline(1, 33, 15, casing.lighter(0.2)); c.hline(1, 34, 15, casingShade)
            return (c, 0)
        case .porthole: // 둥근 현창(볼트 박힌 놋쇠 테)
            var c = PixelCanvas(16, 16)
            let ring = PixelColor(0xC9A24A)
            for y in 0..<16 { for x in 0..<16 {
                let dx = Double(x) - 7.5, dy = Double(y) - 7.5, d = dx * dx + dy * dy
                if d <= 56 { c.dot(x, y, d <= 30 ? windowView(x - 2, y - 2, 12, 12, view: view, season: season) : d <= 38 ? o : (y < 8 ? ring.lighter(0.2) : ring)) }
            } }
            for (x, y) in [(7, 1), (14, 7), (7, 14), (1, 7)] { c.dot(x, y, ring.darker(0.35)) }
            c.dot(5, 5, Pal.white); c.dot(6, 4, Pal.white)   // 유리 반사
            return (c, -14)
        case .french: // 바닥까지 내려오는 프렌치 창(창살 격자 + 아래 판넬)
            var c = PixelCanvas(18, 48)
            c.rect(0, 0, 18, 48, casing); c.vline(1, 0, 48, casingShade); c.vline(16, 0, 48, casingShade)
            c.box(2, 0, 14, 7, fill: Pal.skyTop, outline: o, rounded: false)
            glass(&c, 3, 1, 12, 5, view: 0) { _, _ in true }
            c.box(2, 7, 14, 34, fill: Pal.skyBottom, outline: o, rounded: false)
            glass(&c, 3, 8, 12, 32, view: view, season: season)
            c.rect(8, 7, 2, 34, casing); c.vline(8, 8, 32, casingShade)
            for y in [15, 23, 31] { c.hline(3, y, 5, muntin); c.hline(10, y, 5, muntin) }
            c.box(2, 41, 14, 7, fill: casing, outline: casingShade, rounded: false)
            c.dot(7, 30, PixelColor(0xC9A24A)); c.dot(10, 30, PixelColor(0xC9A24A))   // 손잡이
            return (c, 6)
        case .blinds: // 베니션 블라인드(위 절반 내림 + 줄)
            var c = PixelCanvas(18, 34)
            c.rect(0, 0, 4, 34, casing); c.vline(1, 0, 34, casingShade)
            c.rect(14, 0, 4, 34, casing); c.vline(16, 0, 34, casingShade)
            c.box(3, 0, 12, 30, fill: Pal.skyBottom, outline: o, rounded: false)
            glass(&c, 4, 1, 10, 28, view: view, season: season)
            let slat = accent.lighter(0.55)
            c.rect(3, 0, 12, 2, slat.darker(0.2))
            for y in stride(from: 2, to: 17, by: 2) { c.hline(4, y, 10, slat); c.hline(4, y + 1, 10, slat.darker(0.12)) }
            c.hline(3, 17, 12, slat.darker(0.3))
            c.vline(12, 2, 19, o.with(alpha: 150)); c.dot(12, 21, accent)
            c.hline(2, 30, 14, casing.lighter(0.2)); c.hline(2, 31, 14, casingShade)
            return (c, 0)
        case .shutters: // 덧문(양쪽으로 연 루버 덧문)
            var c = PixelCanvas(24, 34)
            c.box(6, 0, 12, 30, fill: Pal.skyBottom, outline: o, rounded: false)
            glass(&c, 7, 1, 10, 28, view: view, season: season)
            c.vline(12, 1, 28, muntin); c.hline(7, 14, 10, muntin)
            for x in [0, 18] {
                c.box(x, 0, 6, 30, fill: accent, outline: accent.darker(0.35), rounded: false)
                for y in stride(from: 3, to: 28, by: 2) { c.hline(x + 1, y, 4, accent.darker(0.18)) }
                c.dot(x == 0 ? 5 : 18, 6, Pal.metal); c.dot(x == 0 ? 5 : 18, 23, Pal.metal)   // 경첩
            }
            c.hline(5, 30, 14, casing.lighter(0.2)); c.hline(5, 31, 14, casingShade)
            return (c, 0)
        case .curtains: // 커튼(봉 + 양쪽 주름 커튼 + 묶음끈)
            var c = PixelCanvas(22, 38)
            c.box(5, 3, 12, 30, fill: Pal.skyBottom, outline: o, rounded: false)
            glass(&c, 6, 4, 10, 28, view: view, season: season)
            c.vline(11, 4, 28, muntin); c.hline(6, 17, 10, muntin)
            c.hline(4, 33, 14, casing.lighter(0.2)); c.hline(4, 34, 14, casingShade)
            for x in [1, 16] {
                for dx in 0..<5 {
                    let tone = dx % 2 == 0 ? accent : accent.darker(0.16)
                    c.vline(x + dx, 1, 35, tone)
                }
                c.hline(x, 20, 5, accent.lighter(0.35))   // 묶음끈
                c.hline(x, 36, 5, accent.darker(0.3))
            }
            c.hline(0, 0, 22, PixelColor(0xC9A24A)); c.dot(0, 1, PixelColor(0xC9A24A)); c.dot(21, 1, PixelColor(0xC9A24A))   // 커튼봉
            return (c, 2)
        case .stainedGlass: // 스테인드글라스(아치 + 색유리 + 납선)
            var c = PixelCanvas(17, 36)
            for y in 0..<36 { for x in 0..<17 where inArch(x, y, width: 17, radius: 8.5) { c.dot(x, y, casing) } }
            for y in 0..<34 { for x in 0..<13 where inArch(x, y, width: 13, radius: 6.5) { c.dot(x + 2, y + 2, o) } }
            let panes = [PixelColor(0xD9534F), PixelColor(0x5B8DEF), PixelColor(0xF2C14E), PixelColor(0x9C7AD8), PixelColor(0x4FB6A8), PixelColor(0xF29BB0)]
            for y in 0..<30 { for x in 0..<11 where inArch(x, y, width: 11, radius: 5.5) {
                let lead = x % 4 == 1 || y % 5 == 4
                let cell = panes[FloorPainter.hash(x / 4, y / 5, 61) % panes.count]
                c.dot(x + 3, y + 3, lead ? o.lighter(0.15) : (x + y) % 5 == 0 ? cell.lighter(0.25) : cell)
            } }
            c.rect(7, 0, 3, 3, casingShade)
            c.hline(1, 33, 15, casing.lighter(0.2)); c.hline(1, 34, 15, casingShade)
            return (c, 0)
        }
    }

    // MARK: 천장 등(가운데 = 불빛 중심, 맨 위 = 천장, 불빛 아래 끝 ≈ 10줄 — 밤 조명 위치와 맞춘다)

    static func themedLamp(_ style: RoomTheme.Lamp, accent: PixelColor) -> PixelCanvas {
        let o = Pal.outline, warm = PixelColor(0xFFF2B8)
        switch style {
        case .dome: // 반구 펜던트
            var c = PixelCanvas(7, 11)
            c.vline(3, 0, 6, o)
            c.box(0, 6, 7, 4, fill: accent)
            c.hline(1, 7, 2, accent.lighter(0.3))
            c.hline(1, 10, 5, warm)
            return c
        case .drum: // 천 드럼 갓
            var c = PixelCanvas(11, 11)
            c.vline(5, 0, 5, o)
            c.rect(0, 5, 11, 4, accent); c.hline(0, 5, 11, accent.lighter(0.3)); c.hline(0, 8, 11, accent.darker(0.22))
            c.vline(0, 5, 4, accent.darker(0.12)); c.vline(10, 5, 4, accent.darker(0.12))
            c.hline(3, 9, 5, warm); c.hline(4, 10, 3, warm.with(alpha: 160))
            return c
        case .globe: // 우윳빛 유리 구
            var c = PixelCanvas(7, 11)
            c.vline(3, 0, 4, o)
            c.box(0, 4, 7, 7, fill: PixelColor(0xFFF8E4), outline: PixelColor(0xD9CBA8))
            c.rect(2, 6, 3, 3, warm); c.dot(2, 5, Pal.white)
            return c
        case .chandelier: // 샹들리에(촛대 4개 + 크리스털)
            var c = PixelCanvas(13, 11)
            let brass = PixelColor(0xC9A24A)
            c.vline(6, 0, 4, brass.darker(0.3))
            c.rect(5, 4, 3, 2, brass)
            c.hline(1, 6, 11, brass); c.hline(2, 7, 9, brass.darker(0.25))
            for x in [1, 4, 8, 11] { c.vline(x, 3, 3, Pal.paper); c.dot(x, 2, PixelColor(0xFFC94A)) }
            for x in [3, 6, 9] { c.dot(x, 8, PixelColor(0xBFE6F2)); c.dot(x, 9, PixelColor(0x9BD4E6)) }
            c.dot(6, 10, brass)
            return c
        case .tube: // 매다는 형광등(전선 둘 + 확산판)
            var c = PixelCanvas(17, 11)
            c.vline(2, 0, 7, o.with(alpha: 170)); c.vline(14, 0, 7, o.with(alpha: 170))
            c.box(0, 7, 17, 3, fill: PixelColor(0xE6E9EE), outline: Pal.metal, rounded: false)
            c.hline(1, 9, 15, PixelColor(0xF4FBFF)); c.hline(2, 10, 13, PixelColor(0xEAF6FF, alpha: 150))
            return c
        case .track: // 레일 조명의 스폿 머리(레일은 방 단위로 따로 그린다)
            var c = PixelCanvas(7, 11)
            c.vline(3, 2, 4, o)
            c.box(1, 6, 5, 4, fill: accent, outline: accent.darker(0.4), rounded: false)
            c.hline(2, 10, 3, warm)
            return c
        case .lantern: // 둥근 종이 등(살대 줄 + 속불)
            var c = PixelCanvas(9, 12)
            c.vline(4, 0, 3, o)
            c.rect(3, 3, 3, 1, o)
            for y in 0..<7 { for x in 0..<9 {
                let dx = (Double(x) - 4) / 4.5, dy = (Double(y) - 3) / 3.5
                guard dx * dx + dy * dy <= 1 else { continue }
                let edge = dx * dx + dy * dy > 0.62
                c.dot(x, 4 + y, edge ? accent.darker(0.18) : y % 2 == 1 ? accent.darker(0.08) : accent)
            } }
            c.rect(3, 6, 3, 3, accent.lighter(0.45)); c.dot(4, 7, PixelColor(0xFFF2B8))
            c.rect(3, 11, 3, 1, o)
            return c
        case .bulb: // 에디슨 전구(긴 전선 + 철망)
            var c = PixelCanvas(7, 13)
            c.vline(3, 0, 8, o)
            c.rect(2, 7, 3, 2, PixelColor(0x3A3D44))
            c.rect(2, 9, 3, 3, PixelColor(0xFFE29A)); c.dot(3, 10, Pal.white)
            c.vline(1, 9, 3, Pal.metal); c.vline(5, 9, 3, Pal.metal); c.hline(2, 12, 3, Pal.metal)
            return c
        case .cone: // 원뿔 금속 갓(미드센추리)
            var c = PixelCanvas(11, 11)
            c.vline(5, 0, 4, o)
            for (row, half) in [(4, 1), (5, 2), (6, 3), (7, 4), (8, 5)] { c.hline(5 - half, row, half * 2 + 1, row == 4 ? accent.darker(0.2) : accent) }
            c.hline(1, 8, 9, accent.darker(0.25))
            c.hline(3, 9, 5, warm); c.hline(4, 10, 3, warm.with(alpha: 150))
            return c
        }
    }

    /// 벽 조명(위로 비추는 반달 갓).
    static func sconce(_ accent: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(5, 8)
        c.dot(1, 0, PixelColor(0xFFE7A0, alpha: 120)); c.dot(3, 0, PixelColor(0xFFE7A0, alpha: 120)); c.hline(1, 1, 3, PixelColor(0xFFE7A0, alpha: 170))
        c.box(0, 2, 5, 3, fill: accent, outline: accent.darker(0.35))
        c.hline(1, 2, 3, PixelColor(0xFFF2B8))
        c.vline(2, 5, 2, Pal.metal); c.rect(1, 7, 3, 1, Pal.metal)
        return c
    }

    // MARK: 책상 · 의자

    /// 책상 마감: 0 월넛(기본) · 1 오크 · 2 흰 상판 · 3 검정 · 4 메이플 + 흰 다리. 크기와 상판 높이는 기본 책상과 같다.
    static func desk(finish: Int) -> PixelCanvas {
        let (top, edge, leg, drawer, handle): (PixelColor, PixelColor, PixelColor, PixelColor, PixelColor) = {
            switch finish {
            case 1: return (Pal.oak.lighter(0.12), Pal.oakMid, Pal.oakDark, Pal.oak, Pal.metalLight)
            case 2: return (PixelColor(0xF4F3EE), PixelColor(0xD8D6CE), PixelColor(0xB7BDC6), PixelColor(0xE9E7E0), Pal.outline)
            case 3: return (PixelColor(0x4A4D55), PixelColor(0x35383F), PixelColor(0x26282D), PixelColor(0x3E4148), Pal.gold)
            case 4: return (PixelColor(0xE6C290), PixelColor(0xCDA46E), PixelColor(0xEDEBE5), PixelColor(0xEDEBE5), Pal.oakMid)
            default: return (Pal.walnutLight, Pal.walnut, Pal.walnutDark, Pal.walnut, Pal.gold)
            }
        }()
        var c = PixelCanvas(24, 11)
        c.box(0, 0, 24, 3, fill: top, rounded: false)
        c.hline(1, 1, 22, edge)
        c.rect(2, 3, 2, 8, leg); c.rect(20, 3, 2, 8, leg)
        c.box(14, 3, 8, 5, fill: drawer, rounded: false)
        c.hline(16, 5, 4, handle)
        return c
    }

    /// 의자(등받이·좌판 색만 바꾼 사무 의자).
    static func chair(color: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(10, 15)
        c.box(0, 0, 4, 9, fill: color)
        c.box(0, 7, 10, 3, fill: color, rounded: false)
        c.vline(1, 1, 6, color.lighter(0.2))
        c.vline(5, 10, 3, Pal.metal)
        c.hline(1, 13, 8, Pal.metal); c.dot(1, 14, Pal.outline); c.dot(8, 14, Pal.outline)
        return c
    }

    // MARK: 벽 소품(대표 소품)

    static func wallClock(_ accent: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(9, 9)
        for y in 0..<9 { for x in 0..<9 {
            let dx = Double(x) - 4, dy = Double(y) - 4, d = dx * dx + dy * dy
            if d <= 17 { c.dot(x, y, d <= 9 ? Pal.paper : accent.darker(0.15)) }
        } }
        c.vline(4, 2, 3, Pal.outline); c.hline(4, 4, 3, Pal.outline); c.dot(4, 4, Pal.alarm)
        for (x, y) in [(4, 1), (7, 4), (4, 7), (1, 4)] { c.dot(x, y, Pal.outline.with(alpha: 120)) }
        return c
    }

    /// 액자 셋(크기·틀이 다른 그림 모음).
    static func galleryWall(_ accent: PixelColor, _ second: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(24, 17)
        c.box(0, 0, 10, 13, fill: Pal.gold, rounded: false); c.rect(1, 1, 8, 11, Pal.paper)
        c.rect(2, 6, 6, 5, accent); c.box(3, 2, 4, 4, fill: PixelColor(0xF2C14E), outline: PixelColor(0xF2C14E))   // 해와 언덕
        c.box(12, 2, 7, 7, fill: Pal.outline, rounded: false); c.rect(13, 3, 5, 5, second.lighter(0.3)); c.rect(14, 5, 3, 2, second.darker(0.2))
        c.box(13, 10, 11, 7, fill: Pal.paper, outline: PixelColor(0xD8D2C4), rounded: false)
        c.hline(15, 13, 7, accent.darker(0.1)); c.hline(16, 12, 3, accent.lighter(0.2))
        return c
    }

    static func corkboard() -> PixelCanvas {
        var c = PixelCanvas(19, 13)
        c.box(0, 0, 19, 13, fill: PixelColor(0xC9A06B), outline: Pal.oakDark, rounded: false)
        for y in 1..<12 { for x in 1..<18 where FloorPainter.hash(x, y, 77) % 6 == 0 { c.dot(x, y, PixelColor(0xB58D5A)) } }
        c.rect(2, 2, 5, 5, PixelColor(0xF7E27A)); c.rect(9, 3, 4, 4, PixelColor(0xF29BB0)); c.rect(13, 2, 4, 5, Pal.paper)
        c.hline(14, 4, 2, Pal.screenLine); c.hline(14, 5, 2, Pal.screenLine)
        c.rect(4, 8, 6, 3, PixelColor(0x9FD3F2)); c.rect(12, 8, 4, 3, PixelColor(0xA8DCA0))
        for (x, y) in [(4, 2), (10, 3), (15, 2), (6, 8), (13, 8)] { c.dot(x, y, Pal.alarm) }
        return c
    }

    /// 네온사인(벽에 붙은 1px 관 + 두 겹 번짐). shape 0 하트 · 1 번개 · 2 음표.
    static func neonSign(_ color: PixelColor, shape: Int) -> PixelCanvas {
        var c = PixelCanvas(15, 13)
        let points: [(Int, Int)]
        switch shape {
        case 1: points = [(9, 2), (8, 3), (7, 4), (6, 5), (7, 6), (8, 6), (9, 6), (8, 7), (7, 8), (6, 9), (10, 5), (9, 5), (8, 5)]
        case 2: points = [(5, 2), (6, 2), (7, 2), (8, 2), (9, 2), (10, 2), (5, 3), (5, 4), (5, 5), (5, 6), (5, 7), (10, 3), (10, 4), (10, 5), (10, 6),
                          (3, 7), (4, 7), (3, 8), (4, 8), (5, 8), (8, 6), (9, 6), (8, 7), (9, 7), (10, 7)]
        default: points = [(4, 3), (5, 3), (9, 3), (10, 3), (3, 4), (6, 4), (8, 4), (11, 4), (3, 5), (7, 5), (11, 5), (4, 6), (10, 6), (5, 7), (9, 7), (6, 8), (8, 8), (7, 9)]
        }
        for (x, y) in points { for dy in -2...2 { for dx in -2...2 where abs(dx) + abs(dy) == 2 && c[x + dx, y + dy].a == 0 { c.dot(x + dx, y + dy, color.with(alpha: 55)) } } }
        for (x, y) in points { for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] { c.dot(x + dx, y + dy, color.with(alpha: 150)) } }
        for (x, y) in points { c.dot(x, y, color.lighter(0.35)) }
        return c
    }

    static func worldMap() -> PixelCanvas {
        var c = PixelCanvas(21, 14)
        c.box(0, 0, 21, 14, fill: PixelColor(0x8EC3E6), outline: Pal.walnut, rounded: false)
        let land = PixelColor(0xA8C98A), sand = PixelColor(0xE3CF9A)
        c.rect(2, 3, 5, 3, land); c.rect(3, 6, 3, 3, land); c.rect(4, 9, 2, 2, sand)          // 아메리카
        c.rect(9, 2, 3, 3, land); c.rect(9, 5, 3, 5, sand)                                     // 유럽·아프리카
        c.rect(13, 2, 6, 4, land); c.rect(15, 6, 2, 2, land); c.rect(16, 9, 3, 2, sand)        // 아시아·오세아니아
        c.dot(15, 4, Pal.alarm)                                                                 // 여기
        return c
    }

    /// 벽에 건 레코드 셋(색 앨범 표지 액자 안에 판).
    static func recordWall(_ accent: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(26, 8)
        for (i, sleeve) in [accent, PixelColor(0xF2C14E), PixelColor(0xE07A5F)].enumerated() {
            let x = i * 9
            c.box(x, 0, 8, 8, fill: sleeve, outline: Pal.outline, rounded: false)
            c.rect(x + 1, 1, 6, 6, Pal.black)
            for (dx, dy) in [(1, 1), (6, 1), (1, 6), (6, 6)] { c.dot(x + dx, dy, sleeve) }   // 둥근 판 모서리
            c.dot(x + 2, 2, PixelColor(0x4A4A55))                                               // 홈 반사
            c.rect(x + 3, 3, 2, 2, Pal.paper); c.dot(x + 4, 4, sleeve.darker(0.3))             // 가운데 라벨
        }
        return c
    }

    /// 포스터(해 지는 산 · 로켓 중 하나).
    static func poster(_ accent: PixelColor, variant: Int) -> PixelCanvas {
        var c = PixelCanvas(11, 15)
        c.box(0, 0, 11, 15, fill: accent.lighter(0.55), outline: Pal.outline, rounded: false)
        if variant % 2 == 0 {
            c.box(3, 2, 5, 5, fill: PixelColor(0xF2A65A), outline: PixelColor(0xF2A65A))
            for x in 1..<10 { let h = 4 - abs(x - 5) / 2 + (x % 3 == 0 ? 1 : 0); c.vline(x, 12 - h, h + 1, accent.darker(0.25)) }
        } else {
            c.vline(5, 3, 7, Pal.paper); c.vline(4, 4, 5, Pal.paper); c.vline(6, 4, 5, Pal.paper); c.dot(5, 2, Pal.alarm)
            c.dot(3, 8, Pal.alarm); c.dot(7, 8, Pal.alarm); c.dot(5, 5, PixelColor(0x5B8DEF))
            c.dot(4, 11, PixelColor(0xF2C14E)); c.dot(5, 12, PixelColor(0xF29B3B)); c.dot(6, 11, PixelColor(0xF2C14E))
        }
        c.hline(2, 13, 7, Pal.outline.with(alpha: 100))
        return c
    }

    static func miniWhiteboard() -> PixelCanvas {
        var c = PixelCanvas(21, 14)
        c.box(0, 0, 21, 13, fill: Pal.paper, outline: Pal.metal, rounded: false)
        c.hline(2, 3, 9, Pal.screenLine); c.hline(2, 5, 6, Pal.screenLine); c.hline(2, 7, 8, Pal.alarm.lighter(0.2))
        for (i, h) in [3, 5, 4, 7].enumerated() { c.rect(13 + i * 2, 11 - h, 1, h, i == 3 ? Pal.leaf : Pal.screenLine) }
        c.hline(1, 13, 19, Pal.metalLight); c.rect(4, 12, 3, 1, Pal.alarm)
        return c
    }

    /// 방을 가로지르는 삼각 깃발 줄(길이 = 방 너비). 줄이 살짝 처진다.
    static func bunting(width: Int, colors: [PixelColor]) -> PixelCanvas {
        var c = PixelCanvas(width, 8)
        func sag(_ x: Int) -> Int { Int((2.0 * sin(Double(x) / Double(max(1, width - 1)) * .pi)).rounded()) }
        for x in 0..<width { c.dot(x, sag(x), Pal.outline.with(alpha: 170)) }
        var i = 0
        for x in stride(from: 2, to: width - 4, by: 6) {
            let top = sag(x + 2) + 1, color = colors[i % colors.count]
            c.hline(x, top, 5, color); c.hline(x + 1, top + 1, 3, color); c.hline(x + 1, top + 2, 3, color.darker(0.12)); c.dot(x + 2, top + 3, color.darker(0.12))
            i += 1
        }
        return c
    }

    /// 방을 가로지르는 꼬마전구 줄.
    static func stringLights(width: Int, colors: [PixelColor]) -> PixelCanvas {
        var c = PixelCanvas(width, 7)
        func sag(_ x: Int) -> Int { Int((2.5 * sin(Double(x) / Double(max(1, width - 1)) * .pi)).rounded()) }
        for x in 0..<width { c.dot(x, sag(x), Pal.outline.with(alpha: 160)) }
        var i = 0
        for x in stride(from: 3, to: width - 2, by: 5) {
            let y = sag(x) + 1, color = colors[i % colors.count]
            c.dot(x, y, Pal.outline); c.rect(x, y + 1, 1, 2, color); c.dot(x, y + 3, color.with(alpha: 90))
            i += 1
        }
        return c
    }

    // MARK: 구석 소품(방 오른쪽 끝 바닥, 폭 8 이하)

    static func snakePlant(_ pot: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(7, 17)
        for (x, top) in [(1, 4), (2, 1), (3, 3), (4, 0), (5, 5)] {
            c.vline(x, top, 12 - top, x % 2 == 0 ? Pal.leafDark : Pal.leaf)
            c.dot(x, top, PixelColor(0xD8D27A))
        }
        c.box(0, 11, 7, 6, fill: pot, rounded: false); c.hline(1, 12, 5, pot.lighter(0.25))
        return c
    }

    static func cactus(_ pot: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(7, 13)
        c.box(2, 0, 3, 9, fill: Pal.leaf, outline: Pal.leafDark)
        c.box(0, 3, 2, 4, fill: Pal.leaf, outline: Pal.leafDark); c.box(5, 2, 2, 4, fill: Pal.leaf, outline: Pal.leafDark)
        c.dot(3, 2, Pal.leafLight); c.dot(3, 5, Pal.leafLight)
        c.box(1, 8, 5, 5, fill: pot, rounded: false)
        return c
    }

    static func coatRack(_ coat: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(8, 26)
        c.vline(3, 2, 22, Pal.walnut); c.vline(4, 2, 22, Pal.walnutLight)
        c.hline(1, 2, 6, Pal.walnutDark); c.dot(0, 3, Pal.walnutDark); c.dot(7, 3, Pal.walnutDark)
        c.hline(1, 24, 6, Pal.walnutDark); c.hline(0, 25, 8, Pal.outline)
        c.box(4, 3, 4, 11, fill: coat, outline: coat.darker(0.35), rounded: false)   // 걸린 코트
        c.box(0, 0, 4, 3, fill: Pal.black.lighter(0.25))                              // 모자
        return c
    }

    static func waterCooler() -> PixelCanvas {
        var c = PixelCanvas(7, 19)
        c.box(1, 0, 5, 6, fill: PixelColor(0x9FD8F2, alpha: 230), outline: PixelColor(0x5BA8D0))
        c.dot(2, 1, Pal.white)
        c.box(0, 6, 7, 13, fill: Pal.paper, outline: PixelColor(0xC9CED6), rounded: false)
        c.dot(2, 9, PixelColor(0x5B8DEF)); c.dot(4, 9, Pal.alarm)
        c.hline(1, 12, 5, PixelColor(0xC9CED6))
        return c
    }

    static func narrowBookcase(_ wood: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(8, 22)
        c.box(0, 0, 8, 22, fill: wood, outline: wood.darker(0.4), rounded: false)
        let spines = [PixelColor(0xD9534F), PixelColor(0x5B8DEF), PixelColor(0xF2C14E), PixelColor(0x2E5E8C), PixelColor(0xEAE0C8)]
        for (row, y) in [6, 12, 18].enumerated() {
            c.hline(1, y, 6, wood.darker(0.3))
            for x in 1..<7 where (x + row) % 4 != 0 { c.rect(x, y - 4 - (x + row) % 2, 1, 4 + (x + row) % 2, spines[(x + row * 2) % spines.count]) }
        }
        return c
    }

    // MARK: 기록 보관소(정면 2D — 깊이 표현 없이 앞면만)

    /// 보존 상자 앞면(8×7): 이름표 + 손잡이 구멍. tone 0 골판지 · 1 흰 보존 상자 · 2 남색.
    static func archiveBox(_ tone: Int) -> PixelCanvas {
        var c = PixelCanvas(8, 7)
        let fill = [Pal.cardboard, PixelColor(0xE9E4D8), PixelColor(0x46577A)][tone % 3]
        c.box(0, 0, 8, 7, fill: fill, outline: fill.darker(0.38), rounded: false)
        c.hline(1, 1, 6, fill.lighter(0.15))
        c.rect(2, 2, 4, 2, tone % 3 == 1 ? PixelColor(0xF2C14E) : Pal.paper)
        c.hline(3, 5, 2, Pal.outline)
        return c
    }

    /// 보존 서가(정면): 어두운 뒤판 · 기둥 · 선반 5단 · 칸마다 상자/바인더/장부/서류 묶음. seed로 칸 구성만 바꾼다.
    /// fillRows를 주면 그 단에만 물건을 그린다(금고: 위 네 단은 장면이 금고 항목 상자로 채우고, 의자에 가리는 맨 아랫단만 옛 장부).
    static func archiveStack(width: Int, height: Int, seed: Int, fillRows: ClosedRange<Int>? = nil) -> PixelCanvas {
        var c = PixelCanvas(width, height)
        let wood = Pal.oakMid, back = PixelColor(0x334050)
        c.rect(0, 0, width, height, back)
        let uprights = width > 40 ? [0, width / 2 - 1, width - 2] : [0, width - 2]
        let shelves = Array(stride(from: 0, to: height - 4, by: 11))
        let spines = [PixelColor(0x2E5E8C), PixelColor(0x8E3B46), PixelColor(0xD9A441), PixelColor(0x3F8F8A), PixelColor(0x6B7280), PixelColor(0xE07A5F), PixelColor(0x5B4A8A)]
        for (row, shelfY) in shelves.enumerated() {
            let floorY = row + 1 < shelves.count ? shelves[row + 1] : height - 3
            for column in 0..<(uprights.count - 1) where fillRows?.contains(row) ?? true {
                var x = uprights[column] + 2
                let end = uprights[column + 1]
                var step = 0
                while x < end - 1 {
                    let kind = FloorPainter.hash(seed * 31 + row, column * 17 + step, 53) % 10
                    step += 1
                    switch kind {
                    case 0...3 where end - x >= 9:                       // 보존 상자
                        c.stamp(archiveBox(kind == 3 ? 1 : kind == 2 && row % 2 == 0 ? 2 : 0), x, floorY - 7)
                        x += 9
                    case 4...6:                                          // 바인더 몇 권(색 등 + 흰 이름표 + 링 구멍)
                        let count = min(2 + kind % 3 + row % 2, (end - 1 - x) / 2)
                        for i in 0..<max(0, count) {
                            let color = spines[FloorPainter.hash(seed, row * 7 + column * 3 + step + i, 57) % spines.count]
                            let h = 7 + (i + step) % 2
                            c.rect(x, floorY - h, 2, h, color); c.vline(x + 1, floorY - h, h, color.darker(0.18))
                            c.hline(x, floorY - h + 2, 2, Pal.paper); c.dot(x, floorY - 2, Pal.outline.with(alpha: 160))
                            x += 2
                        }
                        x += 1
                    case 7 where end - x >= 7:                           // 가죽 장부 두 권(금박 띠)
                        for i in 0..<2 {
                            let color = [PixelColor(0x7A2E2E), PixelColor(0x2B3A55)][(i + row) % 2]
                            c.rect(x, floorY - 8, 3, 8, color); c.hline(x, floorY - 7, 3, Pal.gold); c.hline(x, floorY - 2, 3, Pal.gold)
                            x += 3
                        }
                        x += 1
                    case 8 where end - x >= 8:                           // 끈으로 묶은 서류 더미
                        c.rect(x, floorY - 4, 7, 4, Pal.paper); c.hline(x, floorY - 3, 7, PixelColor(0xE4DCCB)); c.hline(x, floorY - 1, 7, PixelColor(0xD8CFBC))
                        c.vline(x + 3, floorY - 4, 4, Pal.terracotta)
                        x += 8
                    default:
                        x += 2
                    }
                }
            }
            c.rect(0, shelfY, width, 2, wood); c.hline(0, shelfY, width, wood.lighter(0.25))
        }
        for x in uprights { c.rect(x, 0, 2, height, wood); c.vline(x, 0, height, wood.lighter(0.18)) }
        c.rect(0, height - 3, width, 3, Pal.oakDark); c.hline(0, height - 3, width, wood)   // 받침
        return c
    }

    /// 이동식 서가 사다리(정면, 레일 고리 + 바퀴). 기울이지 않고 수직으로 세운다.
    static func rollingLadder(height: Int) -> PixelCanvas {
        var c = PixelCanvas(8, height)
        let rail = Pal.oak.lighter(0.1), shade = Pal.oakDark
        c.rect(1, 0, 2, 2, Pal.gold); c.rect(5, 0, 2, 2, Pal.gold)   // 레일 고리
        c.vline(1, 2, height - 4, rail); c.vline(2, 2, height - 4, shade)
        c.vline(5, 2, height - 4, rail); c.vline(6, 2, height - 4, shade)
        for y in stride(from: 6, to: height - 3, by: 5) { c.hline(3, y, 2, rail); c.hline(3, y + 1, 2, shade) }
        c.rect(0, height - 2, 3, 2, Pal.outline); c.rect(5, height - 2, 3, 2, Pal.outline)   // 바퀴
        c.dot(1, height - 2, Pal.metalLight); c.dot(6, height - 2, Pal.metalLight)
        return c
    }

    /// 철제 서류 캐비닛(4단 서랍 · 이름표 · 손잡이).
    static func fileCabinet() -> PixelCanvas {
        var c = PixelCanvas(14, 28)
        let steel = PixelColor(0x8D9AA8)
        c.box(0, 0, 14, 28, fill: steel, outline: steel.darker(0.45), rounded: false)
        for i in 0..<4 {
            let y = 1 + i * 7
            c.hline(1, y, 12, steel.lighter(0.22)); c.hline(1, y + 6, 12, steel.darker(0.25))
            c.rect(5, y + 1, 4, 2, Pal.paper); c.hline(6, y + 2, 2, Pal.outline.with(alpha: 120))   // 이름표
            c.hline(5, y + 4, 4, PixelColor(0x4A5260))                                           // 손잡이
        }
        return c
    }

    /// 독서 의자(옆모습 윙체어). 등받이가 왼쪽 — 오른쪽을 보고 앉는 사람용. 반대쪽은 뒤집어 쓴다.
    static func readingChair(_ leather: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(14, 15)
        c.box(0, 0, 4, 13, fill: leather, outline: leather.darker(0.4))
        c.vline(1, 1, 10, leather.lighter(0.18))
        c.box(3, 9, 11, 4, fill: leather, outline: leather.darker(0.4), rounded: false)
        c.hline(4, 10, 9, leather.lighter(0.15))
        c.rect(1, 13, 2, 2, Pal.walnutDark); c.rect(11, 13, 2, 2, Pal.walnutDark)
        return c
    }

    /// 문서 보관장(위 유리장 + 아래 납작 서랍 5단). 윗면은 낮잠 자리라 이불·베개를 깐다.
    static func documentCabinet() -> PixelCanvas {
        var c = PixelCanvas(31, 38)
        let body = Pal.walnut, edge = Pal.walnutDark
        // 이불(접힌 체크 담요) + 베개(왼쪽 = 누운 사람 머리 쪽)
        let quilt = PixelColor(0x3D6FA8)
        c.box(5, 1, 25, 3, fill: quilt, outline: quilt.darker(0.35), rounded: false)
        for x in stride(from: 7, to: 29, by: 4) { c.dot(x, 2, PixelColor(0xE9C46A)) }
        c.vline(22, 1, 3, quilt.darker(0.2))   // 접힌 자리
        c.box(0, 0, 7, 4, fill: Pal.paper, outline: PixelColor(0xC9C2B2))
        c.hline(1, 1, 5, PixelColor(0xFFFFFF))
        // 윗판
        c.rect(0, 4, 31, 2, Pal.walnutLight); c.hline(0, 5, 31, edge)
        // 몸통: 유리장(서류철·두루마리)
        c.box(1, 6, 29, 32, fill: body, outline: edge, rounded: false)
        c.box(3, 8, 25, 10, fill: PixelColor(0xBFD9E6), outline: edge, rounded: false)
        c.vline(15, 8, 10, edge)
        for (i, color) in [PixelColor(0xE9E4D8), PixelColor(0xD9A441), PixelColor(0xE9E4D8), PixelColor(0x8E3B46)].enumerated() { c.rect(5 + i * 2, 11, 2, 7, color) }
        c.rect(17, 14, 9, 3, PixelColor(0xF1E7CF)); c.vline(17, 14, 3, PixelColor(0xC9B48A)); c.vline(25, 14, 3, PixelColor(0xC9B48A))   // 두루마리
        c.dot(4, 9, Pal.white); c.dot(18, 9, Pal.white)
        // 납작 서랍 5단(이름표 + 놋쇠 손잡이)
        for i in 0..<4 {
            let y = 19 + i * 4
            c.hline(2, y, 27, edge); c.hline(2, y + 1, 27, body.lighter(0.12))
            c.rect(6, y + 2, 3, 1, Pal.paper); c.hline(13, y + 2, 5, Pal.gold)
        }
        c.rect(1, 35, 29, 3, edge)
        return c
    }

    static func themePreviewItems() -> [PixelCanvas] {
        let accent = PixelColor(0x3D6FA8)
        var items = RoomTheme.Window.allCases.map { themedWindow($0, trim: Pal.doorWhite, accent: PixelColor(0xD9826B), view: $0.rawValue % 3).canvas }
        items += RoomTheme.Lamp.allCases.map { themedLamp($0, accent: accent) }
        items += [sconce(accent), wallClock(accent), galleryWall(accent, PixelColor(0xF2A65A)), corkboard(), neonSign(PixelColor(0xFF3D9A), shape: 0), neonSign(PixelColor(0x2FD8EE), shape: 1),
                  neonSign(PixelColor(0xFFC21F), shape: 2), worldMap(), recordWall(accent), poster(accent, variant: 0), poster(PixelColor(0xE07A5F), variant: 1), miniWhiteboard(),
                  snakePlant(Pal.terracotta), cactus(Pal.paper), coatRack(accent), waterCooler(), narrowBookcase(Pal.oak)]
        items += (0..<5).map { desk(finish: $0) }
        items += [chair(color: accent), chair(color: Pal.terracotta)]
        return items
    }
}
