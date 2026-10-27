import Foundation

/// 방(프로젝트) 분위기: 벽지 재질·무늬 · 색 조합 · 징두리 · 바닥재 · 창 · 천장 등 · 보조 조명 · 대표 소품 · 구석 소품 · 책상 마감.
/// 방 이름에서 결정적으로 고른다(FNV-1a 해시 → 축마다 따로 굴림). 같은 이름이면 재시작해도 같은 방 모습이다.
/// 타이니 타워처럼 방마다 색과 재질이 확 달라 보이게 하되, 색은 큐레이션한 팔레트 안에서만 섞어 서로 어울리게 한다.
struct RoomTheme: Equatable {
    enum Wall: Int, CaseIterable { case plaster, stripes, pinstripe, damask, brick, subway, woodPanel, shiplap, concrete, polka, gingham, herringbone, chevron, checker, leaves }
    enum Dado: Int, CaseIterable { case none, wood, panel, tile, rail }
    enum Floor: Int, CaseIterable { case herringbone, planks, parquet, checker, terrazzo, carpet, marble, concrete }
    enum Window: Int, CaseIterable { case doubleHung, arched, porthole, french, blinds, shutters, curtains, stainedGlass }
    enum Lamp: Int, CaseIterable { case dome, drum, globe, chandelier, tube, track, lantern, bulb, cone }
    enum Accent: Int, CaseIterable { case none, sconces, floorLamp }
    enum Decor: Int, CaseIterable { case none, clock, gallery, corkboard, neon, shelf, map, bunting, stringLights, records, poster, whiteboard }
    enum Corner: Int, CaseIterable { case none, snakePlant, cactus, coatRack, waterCooler, bookcase }

    var palette: RoomPalette
    var wall: Wall
    var dado: Dado
    var floor: Floor
    var window: Window
    var lamp: Lamp
    var accent: Accent
    var decor: Decor
    var corner: Corner
    /// 목재 톤(나무 벽·판재·마루·헤링본·책장).
    var wood: PixelColor
    /// 벽돌 색(칠한 벽돌이면 팔레트 벽색).
    var brick: PixelColor
    /// 가로 판재를 칠했는지(아니면 원목).
    var paintedBoards: Bool
    var deskFinish: Int
    var chair: PixelColor
    /// 창밖: 0 벽돌집 · 1 가로수 · 2 도시.
    var view: Int
    /// 1 = 책상마다 창, 2 = 하나 걸러 창(사이 칸엔 작은 액자).
    var windowEvery: Int
    /// 대표 소품을 걸 책상 순번(책상 수로 나눈 나머지를 쓴다)과 소품 모양 변형.
    var decorSlot: Int
    var variant: Int

    static let woods: [PixelColor] = [Pal.oak, PixelColor(0xE2B880), Pal.walnut, PixelColor(0xB9B0A3), PixelColor(0xA0522D), PixelColor(0xE6DCCD)]
    static let bricks: [PixelColor] = [PixelColor(0xB5533C), PixelColor(0x9E4A3A), PixelColor(0xC7764F), PixelColor(0xEDE8E0)]
    /// 무늬가 촘촘한 벽 — 바닥은 차분한 것만 고른다(벽·바닥 둘 다 요란하면 직원이 안 보인다).
    static let busyWalls: Set<Wall> = [.damask, .polka, .gingham, .herringbone, .chevron, .checker, .leaves, .brick, .subway]
    /// 재질 자체가 벽인 것 — 징두리를 덧대지 않는다.
    static let materialWalls: Set<Wall> = [.brick, .subway, .woodPanel, .shiplap, .concrete]

    /// '프로젝트 2'처럼 나뉜 방은 원래 프로젝트와 같은 테마를 쓴다(같은 팀은 같은 인테리어).
    static func baseName(_ name: String) -> String {
        guard let space = name.lastIndex(of: " ") else { return name }
        let suffix = name[name.index(after: space)...]
        guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber), let number = Int(suffix), number >= 2 else { return name }
        return String(name[..<space])
    }

    static func of(_ name: String) -> RoomTheme {
        // FNV-1a 64(문자열 해시값은 실행마다 바뀌므로 쓰지 않는다) → splitmix로 축마다 독립 굴림.
        var seed: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in baseName(name).utf8 { seed = (seed ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        func roll(_ salt: UInt64, _ count: Int) -> Int {
            var value = seed &+ salt &* 0x9E37_79B9_7F4A_7C15
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((value ^ (value >> 31)) % UInt64(max(1, count)))
        }
        func pick<T>(_ salt: UInt64, _ items: [T]) -> T { items[roll(salt, items.count)] }

        let palette = pick(1, RoomPalette.all)
        let wall = pick(2, Wall.allCases)
        let floor: Floor = busyWalls.contains(wall) ? pick(3, [.planks, .carpet, .concrete, .herringbone, .marble]) : pick(3, Floor.allCases)
        let dado: Dado = materialWalls.contains(wall) ? .none : pick(4, [.none, .wood, .panel, .tile, .rail, .panel, .rail])
        let accent: Accent = pick(9, [.none, .none, .sconces, .floorLamp])
        let wood = pick(11, woods)
        return RoomTheme(palette: palette, wall: wall, dado: dado, floor: floor,
                         window: pick(5, Window.allCases), lamp: pick(6, Lamp.allCases), accent: accent,
                         decor: pick(7, Decor.allCases), corner: accent == .floorLamp ? .none : pick(8, Corner.allCases),
                         wood: wood, brick: roll(12, 3) == 0 ? palette.wall : pick(13, bricks), paintedBoards: roll(14, 2) == 0,
                         deskFinish: roll(15, 5), chair: pick(16, [Pal.black.lighter(0.25), palette.accent, palette.dado, PixelColor(0xF1EFEA), wood.darker(0.1)]),
                         view: roll(17, 3), windowEvery: roll(18, 5) < 3 ? 1 : 2, decorSlot: roll(19, 8), variant: roll(20, 6))
    }

    /// 무늬 한 칸의 색(방 왼쪽 위 기준 좌표 lx·ly, 캔버스 좌표 gx·gy는 잡티용).
    func wallColor(_ lx: Int, _ ly: Int, _ gx: Int, _ gy: Int) -> PixelColor {
        let w = palette.wall, p = palette.pattern
        switch wall {
        case .plaster:
            return FloorPainter.hash(gx, gy, 3) % 23 == 0 ? w.darker(0.05) : w
        case .stripes:                                   // 넓은 줄무늬(5px씩)
            return (lx / 5) % 2 == 0 ? w : p
        case .pinstripe:                                 // 가는 줄(6px마다)
            return lx % 6 == 0 ? p.darker(0.1) : w
        case .damask:                                    // 엇갈린 마름모 문양
            let row = ly / 12, tx = (lx + (row % 2) * 6) % 12, ty = ly % 12
            return Self.damask(tx - 2, ty - 2) ? p : w
        case .brick:                                     // 엇갈려 쌓은 벽돌(8×4, 줄눈 1px)
            let row = ly / 4, bx = lx + (row % 2) * 4
            if ly % 4 == 3 || bx % 8 == 7 { return brick.lighter(0.42) }
            switch FloorPainter.hash(bx / 8, row, 17) % 5 {
            case 0: return brick.darker(0.09)
            case 1: return brick.lighter(0.07)
            default: return brick
            }
        case .subway:                                    // 지하철 타일(6×3, 줄눈 + 윤기)
            let row = ly / 3, tx = (lx + (row % 2) * 3) % 6, ty = ly % 3
            if ty == 2 || tx == 5 { return p.darker(0.08) }
            return tx == 0 && ty == 0 ? w.lighter(0.4) : w
        case .woodPanel:                                 // 세로 판재(7px)
            if lx % 7 == 0 { return wood.darker(0.2) }
            if FloorPainter.hash(gx, gy, 7) % 29 == 0 { return wood.darker(0.12) }
            return (lx / 7) % 2 == 0 ? wood : wood.lighter(0.1)
        case .shiplap:                                   // 가로 판재(5px) — 칠했거나 원목
            let board = paintedBoards ? w : wood
            if ly % 5 == 4 { return board.darker(0.2) }
            return ly % 5 == 0 ? board.lighter(0.12) : board
        case .concrete:                                  // 노출 콘크리트(거푸집 줄 + 폼타이 구멍)
            let base = PixelColor(0xC4C0B8)
            if ly % 12 == 11 { return base.darker(0.08) }
            if lx % 16 == 8 && ly % 12 == 5 { return base.darker(0.32) }
            return FloorPainter.hash(gx, gy, 5) % 13 == 0 ? base.darker(0.06) : base
        case .polka:                                     // 물방울(2×2, 엇갈림)
            let row = ly / 8, tx = (lx + (row % 2) * 4) % 8, ty = ly % 8
            return (tx == 2 || tx == 3) && (ty == 3 || ty == 4) ? p.darker(0.06) : w
        case .gingham:                                   // 깅엄 체크(4px 띠가 겹치는 곳은 진하게)
            let h = (ly / 4) % 2 == 0, v = (lx / 4) % 2 == 0
            return h && v ? p.darker(0.12) : (h || v) ? p : w
        case .herringbone:                               // 벽면 헤링본
            return ((lx + ly) / 3 + (lx - ly + 300) / 3) % 2 == 0 ? w : p
        case .chevron:                                   // 셰브런(지그재그 가로띠)
            return (ly + abs(lx % 8 - 4)) % 8 < 3 ? p : w
        case .checker:                                   // 큰 체크(6px)
            return ((lx / 6) + (ly / 6)) % 2 == 0 ? w : p
        case .leaves:                                    // 잎사귀 프린트
            let row = ly / 10, tx = (lx + (row % 2) * 5) % 10, ty = ly % 10
            return Self.leaf(tx - 3, ty - 3) ? p.darker(0.1) : w
        }
    }

    private static func damask(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < 7, y < 7 else { return false }
        let rows = ["...#...", "..#.#..", ".#.#.#.", "#.###.#", ".#.#.#.", "..#.#..", "...#..."]
        return Array(rows[y])[x] == "#"
    }

    private static func leaf(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < 4, y < 4 else { return false }
        let rows = [".##.", "####", ".##.", "..#."]
        return Array(rows[y])[x] == "#"
    }
}

/// 방 팔레트(벽 · 무늬 · 몰딩/창틀 · 징두리 · 강조 · 카펫/타일). 화사한 톤 위주, 파랑 계열을 넉넉히.
struct RoomPalette: Equatable {
    let wall: PixelColor, pattern: PixelColor, trim: PixelColor, dado: PixelColor, accent: PixelColor, carpet: PixelColor

    init(_ wall: UInt32, _ pattern: UInt32, _ trim: UInt32, _ dado: UInt32, _ accent: UInt32, _ carpet: UInt32) {
        self.wall = PixelColor(wall); self.pattern = PixelColor(pattern); self.trim = PixelColor(trim)
        self.dado = PixelColor(dado); self.accent = PixelColor(accent); self.carpet = PixelColor(carpet)
    }

    static let all: [RoomPalette] = [
        RoomPalette(0xCFE6F5, 0xA9CFEA, 0xFFFFFF, 0x7FA9CC, 0x2E6DA4, 0x4F7FB3),   // 하늘
        RoomPalette(0x3E5478, 0x324666, 0xEAD9A8, 0x26344F, 0xD9A441, 0x8E2F3A),   // 네이비 클럽
        RoomPalette(0xCFEFE3, 0xA8DCC8, 0xFFFFFF, 0x6FB8A0, 0xF28C8C, 0x5E9E8A),   // 민트
        RoomPalette(0xF8D8CC, 0xF2B8A6, 0xFFF7F0, 0xD9826B, 0x2E8C8C, 0xC9644E),   // 코랄
        RoomPalette(0xF3D98B, 0xE5C25E, 0x6B4A2E, 0x8E5A31, 0x3D6FA8, 0xB5532E),   // 머스터드
        RoomPalette(0xE3DAF2, 0xCBBDE6, 0xFFFFFF, 0x9C88C7, 0xF2C14E, 0x7E6AAE),   // 라벤더
        RoomPalette(0xFCE3C8, 0xF6CBA0, 0xFFFFFF, 0xE3A06B, 0x5B8DEF, 0xD98B5F),   // 피치
        RoomPalette(0x3E8A8C, 0x357678, 0xF2E6CF, 0x2A5E60, 0xF2A65A, 0x2E4A5C),   // 틸
        RoomPalette(0xF3E9D7, 0xE4D5BA, 0xFBF7EF, 0xC98F55, 0xC9A24A, 0xA8443A),   // 크림(기존 사무실 색)
        RoomPalette(0x4F535C, 0x43474F, 0xC7C2B8, 0x363940, 0xF2C14E, 0x5A5F69),   // 차콜 공장
        RoomPalette(0xF7D6DE, 0xEFB8C6, 0xFFFFFF, 0xC97A8E, 0x3A8FB7, 0xB85A74),   // 블러시
        RoomPalette(0xC9D3F5, 0xAAB8EC, 0xFFFFFF, 0x5D6FC4, 0xF28C5A, 0x4555A0),   // 페리윙클
        RoomPalette(0xFFF3B8, 0xFBE38A, 0xFFFFFF, 0x7BC4C4, 0xE0408A, 0x58A8A8),   // 레몬
        RoomPalette(0x8C3446, 0x7A2C3C, 0xE9C77B, 0x5E2230, 0xE9C77B, 0x3B2A4A),   // 버건디
        RoomPalette(0xB8CCD9, 0x9DB6C7, 0xF4F7FA, 0x4F6D85, 0xE07A5F, 0x3E5468),   // 스틸 블루
        RoomPalette(0xF2A65A, 0xE08A3C, 0x5C351D, 0x7A4A2A, 0xF7E3B5, 0x6B4430),   // 70년대 오렌지
        RoomPalette(0xF5F5F2, 0xE4E4DE, 0x2B2D42, 0xDADAD4, 0x2B2D42, 0x9AA3AF),   // 갤러리 화이트
        RoomPalette(0xBFEFF2, 0x96E0E6, 0xFFFFFF, 0x3FB2C2, 0xFF8A5B, 0x2E8FA0),   // 아쿠아
    ]
}

extension FloorPainter {
    /// 테마 방 한 칸: 벽 → 징두리 → 바닥 → 몰딩 → 벽 소품 → 창 → 벽 조명 → 가로지르는 장식 → 천장 등 → 의자·책상 → 구석 소품.
    /// 방 사이 벽과 명패(글자는 장면)는 team()이 그 위에 그린다. 층 텍스처를 다시 만들 때만 불린다(프레임마다 그리지 않음).
    static func themedRoom(_ c: inout PixelCanvas, room: BuildingLayout.Room, desks: [BuildingLayout.DeskSlot], floorTop: Int) {
        let t = RoomTheme.of(room.name), p = t.palette
        let x0 = room.x0, x1 = room.x1 - 2   // 오른쪽 2px은 방 사이 벽 자리
        let dadoTop = t.dado == .none ? floorTop : floorTop - 14
        for y in 0..<dadoTop { for x in x0..<x1 { c.dot(x, y, t.wallColor(x - x0, y, x, y)) } }
        themedDado(&c, x0, x1, dadoTop, floorTop, t)
        themedFloor(&c, x0, x1, floorTop, t)
        c.hline(x0, 0, x1 - x0, p.trim.lighter(0.2)); c.hline(x0, 1, x1 - x0, p.trim.darker(0.18))   // 천장 몰딩

        let roomDesks = desks.filter { $0.floor == room.floor && $0.deskX >= room.x0 && $0.deskX < room.x1 }.sorted { $0.deskX < $1.deskX }
        let decorDesk = roomDesks.isEmpty ? nil : roomDesks[t.decorSlot % roomDesks.count].deskX
        if let deskX = decorDesk { wallDecor(&c, t, centerX: deskX + 12) }
        if t.lamp == .track {   // 레일 조명: 천장 레일 한 줄
            c.hline(x0 + 3, 2, x1 - x0 - 6, Pal.outline); c.hline(x0 + 3, 3, x1 - x0 - 6, Pal.metal)
        }
        for (index, desk) in roomDesks.enumerated() {
            if t.windowEvery == 1 || index % 2 == 0 {
                let window = Furniture.themedWindow(t.window, trim: p.trim, accent: p.accent, view: t.view)
                let left = desk.deskX + 39 - window.canvas.width / 2
                c.stamp(window.canvas, left, floorTop - 12 + window.dy - window.canvas.height)
                if t.accent == .sconces && desk.deskX != decorDesk { c.stamp(Furniture.sconce(p.accent), left - 6, 28) }
            } else {
                c.stamp(Furniture.wallArt(t.variant + index), desk.deskX + 34, floorTop - 40)
            }
        }
        if t.decor == .bunting { c.stamp(Furniture.bunting(width: x1 - x0 - 6, colors: [p.accent, p.trim, p.dado, p.pattern.darker(0.2)]), x0 + 3, 18) }
        if t.decor == .stringLights { c.stamp(Furniture.stringLights(width: x1 - x0 - 6, colors: [PixelColor(0xFFE29A), p.accent.lighter(0.2), PixelColor(0xFFFFFF), PixelColor(0xF29BB0)]), x0 + 3, 18) }
        for desk in roomDesks {
            let lamp = Furniture.themedLamp(t.lamp, accent: t.lamp == .globe || t.lamp == .tube ? p.trim : p.accent)
            c.stamp(lamp, desk.deskX + 19 - lamp.width / 2, 0)
            c.stamp(Furniture.chair(color: t.chair), desk.deskX - 2, floorTop - 15 + 6)
            c.stamp(Furniture.desk(finish: t.deskFinish), desk.deskX + 10, floorTop - 11 + 6)
            c.stamp(Furniture.keyboard(), desk.deskX + 13, floorTop - 13 + 6)
        }
        // 구석(방 오른쪽 끝 바닥): 스탠드 조명 또는 소품 하나
        let corner: PixelCanvas? = {
            if t.accent == .floorLamp { return Furniture.floorLamp() }
            switch t.corner {
            case .none: return nil
            case .snakePlant: return Furniture.snakePlant(p.accent)
            case .cactus: return Furniture.cactus(Pal.terracotta)
            case .coatRack: return Furniture.coatRack(p.accent)
            case .waterCooler: return Furniture.waterCooler()
            case .bookcase: return Furniture.narrowBookcase(t.wood)
            }
        }()
        if let corner { c.stamp(corner, x1 - corner.width - 1, floorTop + 6 - corner.height) }
    }

    /// 대표 소품(책상 하나 위 벽, 가로 가운데 = centerX). 깃발·전구 줄은 방 전체라 따로 그린다.
    private static func wallDecor(_ c: inout PixelCanvas, _ t: RoomTheme, centerX: Int) {
        let p = t.palette
        let item: PixelCanvas?
        switch t.decor {
        case .none, .bunting, .stringLights: item = nil
        case .clock: item = Furniture.wallClock(p.accent)
        case .gallery: item = Furniture.galleryWall(p.accent, p.dado)
        case .corkboard: item = Furniture.corkboard()
        case .neon: item = Furniture.neonSign([PixelColor(0xFF3D9A), PixelColor(0x2FD8EE), PixelColor(0xFFC21F)][t.variant % 3], shape: (t.variant / 3 + t.variant) % 3)
        case .shelf: item = Furniture.wallShelf()
        case .map: item = Furniture.worldMap()
        case .records: item = Furniture.recordWall(p.accent)
        case .poster: item = Furniture.poster(p.accent, variant: t.variant)
        case .whiteboard: item = Furniture.miniWhiteboard()
        }
        guard let item else { return }
        c.stamp(item, centerX - item.width / 2, 34 - item.height / 2)
    }

    /// 징두리(벽 아래 14px): 없음이면 걸레받이만.
    private static func themedDado(_ c: inout PixelCanvas, _ x0: Int, _ x1: Int, _ top: Int, _ bottom: Int, _ t: RoomTheme) {
        let p = t.palette, w = x1 - x0
        switch t.dado {
        case .none:                                        // 걸레받이
            c.rect(x0, bottom - 3, w, 3, p.trim)
            c.hline(x0, bottom - 3, w, p.trim.lighter(0.25)); c.hline(x0, bottom - 1, w, p.trim.darker(0.2))
        case .wood:                                        // 원목 판재 + 두겁대
            for x in x0..<x1 {
                let lx = x - x0
                c.vline(x, top, bottom - top, lx % 5 == 0 ? t.wood.darker(0.22) : (lx / 5) % 2 == 0 ? t.wood : t.wood.lighter(0.08))
            }
            c.hline(x0, top, w, t.wood.darker(0.35)); c.hline(x0, top + 1, w, t.wood.lighter(0.25))
        case .panel:                                       // 칠한 판넬(틀 안의 돋을 판)
            c.rect(x0, top, w, bottom - top, p.dado)
            c.hline(x0, top, w, p.trim); c.hline(x0, top + 1, w, p.dado.darker(0.15))
            for x in stride(from: x0 + 4, to: x1 - 12, by: 16) { c.box(x, top + 4, 12, bottom - top - 7, fill: p.dado.lighter(0.12), outline: p.dado.darker(0.16)) }
        case .tile:                                        // 작은 정사각 타일 + 두겁대
            for y in top..<bottom { for x in x0..<x1 {
                let lx = x - x0, ly = y - top
                c.dot(x, y, lx % 4 == 3 || ly % 4 == 3 ? p.dado.lighter(0.35) : (lx / 4 + ly / 4) % 2 == 0 ? p.dado : p.dado.lighter(0.1))
            } }
            c.hline(x0, top, w, p.trim); c.hline(x0, top + 1, w, p.trim.darker(0.2))
        case .rail:                                        // 두겁대 + 아래 두 톤 칠
            c.rect(x0, top, w, bottom - top, p.dado)
            c.hline(x0, top, w, p.trim.lighter(0.2)); c.hline(x0, top + 1, w, p.trim.darker(0.15))
            c.rect(x0, bottom - 3, w, 3, p.trim); c.hline(x0, bottom - 1, w, p.trim.darker(0.2))
        }
    }

    /// 바닥 띠(높이 6).
    private static func themedFloor(_ c: inout PixelCanvas, _ x0: Int, _ x1: Int, _ top: Int, _ t: RoomTheme) {
        let p = t.palette, wood = t.wood
        for y in 0..<6 { for x in x0..<x1 {
            let lx = x - x0
            let color: PixelColor
            switch t.floor {
            case .herringbone:                              // 헤링본 마루
                color = [wood, wood.darker(0.12), wood.darker(0.25)][((x + y) / 3 + (x - y + 64) / 3) % 3]
            case .planks:                                   // 긴 마루판(3px 두 줄, 이음매 엇갈림)
                let row = y / 3, run = lx + row * 7
                color = y % 3 == 2 ? wood.darker(0.18) : run % 15 == 0 ? wood.darker(0.22) : [wood, wood.lighter(0.07), wood.darker(0.06)][(run / 15) % 3]
            case .parquet:                                  // 바구니 짜임 쪽마루
                let square = (lx / 6) % 2 == 0
                color = (square ? y % 2 == 1 : lx % 2 == 1) ? wood.darker(0.16) : wood
            case .checker:                                  // 흑백(또는 팔레트) 체크 타일
                let dark = ((lx / 3) + (y / 3)) % 2 == 0
                color = dark ? (t.variant % 2 == 0 ? PixelColor(0x2B2D42) : p.carpet) : PixelColor(0xF4F1EA)
            case .terrazzo:                                 // 테라초(드문드문 색 조각)
                switch FloorPainter.hash(x, y, 31) % 17 {
                case 0: color = p.accent.lighter(0.2)
                case 1: color = p.carpet.lighter(0.25)
                case 2: color = PixelColor(0xAFB3B9)
                default: color = PixelColor(0xEAE5DC)
                }
            case .carpet:                                   // 카펫(잔결)
                color = (lx + y * 2) % 4 == 0 ? p.carpet.darker(0.08) : p.carpet
            case .marble:                                   // 대리석(판마다 다른 사선 결 + 이음매)
                if lx % 24 == 23 { color = PixelColor(0xC9C4BB) } else {
                    let vein = (lx + 2 * y + FloorPainter.hash(lx / 24, 1, 37) % 9) % 12
                    color = vein == 0 ? PixelColor(0xC7C1B7) : vein == 1 ? PixelColor(0xDDD8D0) : PixelColor(0xF0EDE8)
                }
            case .concrete:                                 // 광택 콘크리트
                color = lx % 30 == 29 ? PixelColor(0x9E9A92) : FloorPainter.hash(x, y, 43) % 11 == 0 ? PixelColor(0xA9A59D) : PixelColor(0xB8B4AC)
            }
            c.dot(x, top + y, color)
        } }
        let edge: PixelColor = t.floor == .carpet ? p.carpet.darker(0.25) : PixelColor(0xFFFFFF, alpha: 70)
        c.hline(x0, top, x1 - x0, edge)
    }
}
