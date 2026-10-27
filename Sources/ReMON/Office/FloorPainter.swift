import Foundation

/// 층별 배경(정적 부분)을 한 장의 픽셀 캔버스로 그린다. 레이아웃이 바뀔 때만 다시 그린다.
/// 캔버스 좌표는 위가 0(천장), 아래가 바닥판. 움직이는 것(문·엘리베이터 문·불꽃·물결·모니터·상자)은 장면 노드로 따로 둔다.
enum FloorPainter {
    static func hash(_ x: Int, _ y: Int, _ seed: Int = 0) -> Int {
        var value = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ seed &* 2_147_483_647)
        value = (value ^ (value >> 13)) &* 1_274_126_177
        return Int(value ^ (value >> 16))
    }

    // MARK: 재질

    static func plaster(_ c: inout PixelCanvas, _ x0: Int, _ x1: Int, _ top: Int, _ bottom: Int, base: PixelColor = Pal.cream) {
        c.rect(x0, top, x1 - x0, bottom - top, base)
        for y in top..<bottom { for x in x0..<x1 where hash(x, y, 3) % 23 == 0 { c.dot(x, y, base.darker(0.04)) } }
        c.hline(x0, top, x1 - x0, base.lighter(0.3)); c.hline(x0, top + 1, x1 - x0, base.darker(0.06)) // 몰딩
    }

    static func wainscot(_ c: inout PixelCanvas, _ x0: Int, _ x1: Int, _ top: Int, _ bottom: Int) {
        c.rect(x0, top, x1 - x0, bottom - top, Pal.creamShade)
        c.hline(x0, top, x1 - x0, Pal.doorWhite)
        for x in stride(from: x0 + 6, to: x1 - 4, by: 18) { c.box(x, top + 3, 14, max(3, bottom - top - 5), fill: Pal.creamShade.lighter(0.12), outline: Pal.creamShade.darker(0.12)) }
    }

    /// 밝은 오크 목재 벽(참고 사진의 따뜻한 원목 느낌). 어두운 월넛은 화면을 무겁게 만들어 쓰지 않는다.
    static func walnutPanel(_ c: inout PixelCanvas, _ x0: Int, _ x1: Int, _ top: Int, _ bottom: Int) {
        for x in x0..<x1 {
            let plank = (x - x0) / 7
            let color = plank % 2 == 0 ? Pal.oak : Pal.oak.lighter(0.12)
            c.vline(x, top, bottom - top, (x - x0) % 7 == 0 ? Pal.oakMid : color)
        }
        for y in top..<bottom { for x in x0..<x1 where hash(x, y, 7) % 31 == 0 { c.dot(x, y, Pal.oakMid) } }
        c.hline(x0, top, x1 - x0, Pal.oakDark)
    }

    static func travertine(_ c: inout PixelCanvas, _ x0: Int, _ x1: Int, _ top: Int, _ bottom: Int) {
        c.rect(x0, top, x1 - x0, bottom - top, Pal.travertine)
        for y in top..<bottom {
            if (y - top) % 12 == 0 { c.hline(x0, y, x1 - x0, Pal.travertineSpeck) }
            for x in x0..<x1 where hash(x, y, 11) % 17 == 0 { c.dot(x, y, Pal.travertineSpeck) }
        }
        for y in stride(from: top, to: bottom, by: 12) {
            let offset = ((y - top) / 12) % 2 == 0 ? 0 : 14
            for x in stride(from: x0 + offset, to: x1, by: 28) { c.vline(x, y, min(12, bottom - y), Pal.travertineSpeck) }
        }
    }

    /// 헤링본 오크 바닥 띠(높이 6).
    static func herringbone(_ c: inout PixelCanvas, _ x0: Int, _ x1: Int, _ top: Int) {
        let tones = [Pal.oak, Pal.oakMid, Pal.oakDark.lighter(0.15)]
        for y in 0..<6 { for x in x0..<x1 {
            let zig = ((x + y) / 3 + (x - y + 64) / 3) % 3
            c.dot(x, top + y, tones[zig])
        } }
        c.hline(x0, top, x1 - x0, Pal.oak.lighter(0.25))
    }

    static func concrete(_ c: inout PixelCanvas, _ x0: Int, _ x1: Int, _ top: Int, _ bottom: Int) {
        c.rect(x0, top, x1 - x0, bottom - top, Pal.concrete)
        for y in stride(from: top + 12, to: bottom, by: 14) { c.hline(x0, y, x1 - x0, Pal.concreteDark.lighter(0.2)) }
        for y in top..<bottom { for x in x0..<x1 where hash(x, y, 5) % 19 == 0 { c.dot(x, y, Pal.concreteDark.lighter(0.1)) } }
    }

    static func slab(_ c: inout PixelCanvas, height: Int, tone: PixelColor = Pal.walnutDark) {
        let top = height - BuildingLayout.slab
        c.rect(0, top, BuildingLayout.width, BuildingLayout.slab, tone)
        c.hline(0, top, BuildingLayout.width, tone.lighter(0.25))
    }

    static func facade(_ c: inout PixelCanvas, height: Int) {
        for x in [0, BuildingLayout.width - 6] {
            c.rect(x, 0, 6, height, PixelColor(0xDCCDB2))
            for y in stride(from: 3, to: height, by: 8) { c.hline(x, y, 6, PixelColor(0xC9B897)) }
            c.vline(x + (x == 0 ? 5 : 0), 0, height, Pal.outline.with(alpha: 120))
        }
    }

    static func elevatorShaft(_ c: inout PixelCanvas, height: Int) {
        c.rect(BuildingLayout.elevatorX0, 0, BuildingLayout.elevatorX1 - BuildingLayout.elevatorX0, height, PixelColor(0x59606B))
        c.vline(BuildingLayout.elevatorX0 + 6, 0, height, PixelColor(0x6C747F)); c.vline(BuildingLayout.elevatorX1 - 7, 0, height, PixelColor(0x6C747F))
    }

    static func pendantLamp(_ c: inout PixelCanvas, _ x: Int, _ top: Int) {
        c.vline(x + 3, top, 6, Pal.outline)
        c.box(x, top + 6, 7, 4, fill: Pal.gold)
        c.hline(x + 1, top + 10, 5, PixelColor(0xFFF2B8))
    }

    // MARK: 층

    /// 기계실(지하): 맥북 속 같은 느낌 — 강철 벽·케이블 트레이·바닥 위험 띠. 엔진·탱크·랙·상자·선반은 장면 노드로 올린다.
    static func basement(height: Int) -> PixelCanvas {
        var c = PixelCanvas(BuildingLayout.width, height)
        let floorTop = height - BuildingLayout.slab - 6
        // 강철 패널 벽
        c.rect(6, 0, BuildingLayout.width - 12, floorTop, PixelColor(0x3A4350))
        for y in stride(from: 0, to: floorTop, by: 16) { c.hline(6, y, BuildingLayout.width - 12, PixelColor(0x2F3742)) }
        for x in stride(from: 36, to: BuildingLayout.width - 6, by: 48) { c.vline(x, 0, floorTop, PixelColor(0x2F3742)); c.dot(x + 2, 4, Pal.metalLight); c.dot(x + 2, 12, Pal.metalLight) }
        for y in 0..<floorTop { for x in 6..<(BuildingLayout.width - 6) where hash(x, y, 21) % 37 == 0 { c.dot(x, y, PixelColor(0x465060)) } }
        // 천장 케이블 트레이·배관·등
        c.hline(36, 3, 596, Pal.metal); c.hline(36, 4, 596, Pal.metalLight)
        c.hline(36, 7, 596, PixelColor(0xE07A5F)); c.hline(36, 9, 596, PixelColor(0x5DA9E9)); c.hline(36, 11, 596, PixelColor(0xE3B23C))
        for x in stride(from: 60, to: 620, by: 72) { c.rect(x, 12, 3, 5, Pal.metal); c.box(x - 6, 17, 15, 4, fill: PixelColor(0xFFF2B8), outline: Pal.metal) }
        // 구역 표지(왼쪽부터 CPU 엔진 · RAM 탱크 · 스왑 창고 · 디스크 저장고 · 시스템 랙): 벽에 띠
        for (index, x) in [36, 132, 200, 326, 472].enumerated() {
            c.rect(x, 24, 2, floorTop - 30, PixelColor(0x1F252E))
            c.rect(x + 4, 28, 18, 3, [PixelColor(0xE07A5F), PixelColor(0x5DA9E9), Pal.cardboard, Pal.leaf, PixelColor(0x9AA3AF)][index])
        }
        // 슈트 끝(1층에서 내려오는 미끄럼판)
        for i in 0..<34 { c.rect(BuildingLayout.chuteX - 34 + i, 8 + i, 6, 2, Pal.metalLight); c.dot(BuildingLayout.chuteX - 34 + i, 10 + i, Pal.metal) }
        // 바닥: 금속판 + 노랑·검정 위험 띠
        c.rect(6, floorTop, BuildingLayout.width - 12, 6, PixelColor(0x6B7280))
        for x in stride(from: 6, to: BuildingLayout.width - 6, by: 2) { c.dot(x, floorTop + 2, PixelColor(0x7C8592)); c.dot(x + 1, floorTop + 4, PixelColor(0x7C8592)) }
        for x in stride(from: 36, to: 468, by: 8) { c.rect(x, floorTop, 4, 1, Pal.mustard); c.rect(x + 4, floorTop, 4, 1, Pal.black) }
        // 시스템 랙 구역: 바닥 격자
        for x in stride(from: BuildingLayout.wingX0, to: BuildingLayout.wingX1, by: 6) { c.vline(x, floorTop, 6, PixelColor(0x4B5563)) }
        c.vline(BuildingLayout.wingX0 - 2, 0, height, PixelColor(0x1F252E))
        elevatorShaft(&c, height: height)
        facade(&c, height: height)
        slab(&c, height: height, tone: Pal.concreteDark)
        return c
    }

    /// 강당(대기실): 왼쪽 무대·연단, 두 줄 의자, 왼쪽 벽의 문. 별관은 정신교육실(칠판·책상 4개).
    static func hall(height: Int) -> PixelCanvas {
        var c = PixelCanvas(BuildingLayout.width, height)
        let floorTop = height - BuildingLayout.slab - 6
        plaster(&c, BuildingLayout.mainX0, BuildingLayout.mainX1, 0, floorTop, base: PixelColor(0xEADFCB))
        wainscot(&c, BuildingLayout.mainX0, BuildingLayout.mainX1, floorTop - 14, floorTop)
        // 커튼 두 폭(무대 뒤)과 현수막 자리(글자는 장면)
        for x in [BuildingLayout.hallStageX - 2, BuildingLayout.hallStageX + 26] { c.rect(x, 4, 6, floorTop - 20, PixelColor(0x8E2F3A)); for y in stride(from: 6, to: floorTop - 18, by: 4) { c.hline(x + 1, y, 2, PixelColor(0xA64452)) } }
        c.box(170, 8, 150, 12, fill: PixelColor(0x2B2D42), outline: Pal.gold)
        // 무대(살짝 높은 단) + 연단
        c.box(BuildingLayout.hallStageX - 4, floorTop - 4, 36, 10, fill: Pal.oakMid, outline: Pal.oakDark, rounded: false)
        c.box(BuildingLayout.hallStageX + 8, floorTop - 20, 10, 16, fill: Pal.walnut, outline: Pal.walnutDark, rounded: false)
        c.hline(BuildingLayout.hallStageX + 6, floorTop - 21, 14, Pal.walnutDark)
        // 의자 두 줄(뒷줄은 살짝 위, 어둡게)
        for i in 0..<BuildingLayout.hallSeatsPerRow {
            let back = BuildingLayout.hallSeatX0 + 7 + i * BuildingLayout.hallSeatPitch
            c.box(back - 4, floorTop - 12 - 12, 8, 3, fill: PixelColor(0x3B4A6B), outline: PixelColor(0x2C3858), rounded: false)
            c.rect(back - 3, floorTop - 9 - 12, 2, 9, PixelColor(0x2C3858))
        }
        for i in 0..<BuildingLayout.hallSeatsPerRow {
            let x = BuildingLayout.hallSeatX0 + i * BuildingLayout.hallSeatPitch
            c.box(x - 4, floorTop - 12, 8, 3, fill: PixelColor(0x4C5F8A), outline: Pal.navy, rounded: false)
            c.rect(x - 3, floorTop - 9, 2, 9, Pal.navy)
            c.rect(x - 4, floorTop - 3, 8, 3, PixelColor(0x4C5F8A))
        }
        herringbone(&c, BuildingLayout.mainX0, BuildingLayout.mainX1, floorTop)
        // 별관: 정신교육실
        let wing = BuildingLayout.wingX0
        plaster(&c, wing, BuildingLayout.wingX1, 0, floorTop, base: PixelColor(0xF1ECE0))
        c.box(BuildingLayout.classBoardX, 8, 120, 26, fill: PixelColor(0x2F5D3A), outline: Pal.oakDark, rounded: false)   // 칠판
        c.hline(BuildingLayout.classBoardX + 8, 16, 40, Pal.white.with(alpha: 180)); c.hline(BuildingLayout.classBoardX + 8, 22, 64, Pal.white.with(alpha: 160)); c.hline(BuildingLayout.classBoardX + 8, 28, 28, Pal.white.with(alpha: 140))
        c.rect(BuildingLayout.classBoardX, 34, 120, 2, Pal.oakDark)
        for x in BuildingLayout.classSeatXs {
            c.stamp(Furniture.chair(), x - 2, floorTop - 15 + 6)
            c.box(x + 6, floorTop - 10 + 6, 16, 3, fill: Pal.oak, outline: Pal.oakDark, rounded: false)
            c.rect(x + 7, floorTop - 7 + 6, 2, 7, Pal.oakDark); c.rect(x + 19, floorTop - 7 + 6, 2, 7, Pal.oakDark)
        }
        herringbone(&c, wing, BuildingLayout.wingX1, floorTop)
        c.vline(wing - 2, 0, height, Pal.walnutDark)
        elevatorShaft(&c, height: height)
        facade(&c, height: height)
        slab(&c, height: height)
        return c
    }

    /// 1층: 로비(36~226, 출입문 · 안내 데스크 · 소파) | 도구실(228~468, 앱 기계 랙 · 반입구) | 별관 기록 보관소(노드가 덮는다).
    /// 10-25: 예전엔 로비가 330까지 넓고 오른쪽 중정(벽난로 · 야자수) 앞에 앱 캐비닛이 겹쳐 섰다 — 대표 지적 '위치가 애매하다'.
    static func lobby(height: Int) -> PixelCanvas {
        var c = PixelCanvas(BuildingLayout.width, height)
        let floorTop = height - BuildingLayout.slab - 6
        let split = ToolRoom.x0 - 2
        // 로비 벽
        plaster(&c, BuildingLayout.mainX0, split, 0, floorTop)
        wainscot(&c, BuildingLayout.mainX0, split, floorTop - 16, floorTop)
        c.stamp(Furniture.tallWindow(), 158, floorTop - 46)
        c.stamp(Furniture.tallWindow(), 184, floorTop - 46)
        c.stamp(Furniture.wallArt(2), 133, floorTop - 46)
        for x in [100, 180] { pendantLamp(&c, x, 2) }
        c.stamp(Furniture.rug(), 156, floorTop + 1)
        c.stamp(Furniture.fiddleFig(), 128, floorTop - 30 + 6)
        c.stamp(Furniture.armchair(), BuildingLayout.lobbyArmchairs[0], floorTop - 15 + 6)
        c.stamp(Furniture.sofa(), BuildingLayout.lobbySofaX, floorTop - 15 + 6)
        c.stamp(Furniture.armchair(), BuildingLayout.lobbyArmchairs[1], floorTop - 15 + 6)
        c.stamp(Furniture.receptionDesk(), 86, floorTop - 14 + 6)
        c.stamp(Furniture.sideTable(), 216, floorTop - 9 + 6)
        herringbone(&c, BuildingLayout.mainX0, split, floorTop)
        toolRoom(&c, floorTop: floorTop)
        c.rect(split, 0, 2, floorTop + 6, Pal.walnutDark)   // 로비 | 도구실 벽
        // 별관 아래쪽(라이브러리 노드가 덮는다)
        c.rect(BuildingLayout.wingX0, 0, BuildingLayout.wingX1 - BuildingLayout.wingX0, height, Pal.oak)
        c.vline(BuildingLayout.wingX0 - 2, 0, height, Pal.walnutDark)
        elevatorShaft(&c, height: height)
        facade(&c, height: height)
        slab(&c, height: height)
        return c
    }

    /// 도구실(로비 층 228~468): 칠한 블록 벽 · 진회색 징두리와 노란 안전선 · 작업등 · 2단 팔레트 랙(파란 기둥 · 주황 보, 5칸 × 2단) ·
    /// 칸마다 콘센트(아래 단 · 위 단) · 게시판(+N) · 오른쪽 끝 반입구(위험 띠 문틀 · 셔터 하우징 · 셔터 뒤에 댄 트럭 짐칸) · 에폭시 바닥.
    /// 기계 · 셔터 · 기사 · 수레는 장면 노드(ToolRoom.swift)다. 캔버스 행 = 바닥선(84)에서 위로 잰 높이 h → 84 - h - 1.
    static func toolRoom(_ c: inout PixelCanvas, floorTop: Int) {
        let x0 = ToolRoom.x0, x1 = BuildingLayout.mainX1
        let base = floorTop + 6   // 바닥선(캔버스 행)
        func row(_ h: Int) -> Int { base - h - 1 }
        // 벽: 밝은 회청색 블록(12×6, 엇갈림)
        let wall = PixelColor(0xC9D1DB)
        for y in 0..<floorTop { for x in x0..<x1 {
            let course = y / 6, bx = (x - x0 + (course % 2) * 6) % 12
            let mortar = y % 6 == 5 || bx == 11
            c.dot(x, y, mortar ? wall.darker(0.09) : hash(x, y, 61) % 29 == 0 ? wall.darker(0.05) : wall)
        } }
        c.hline(x0, 0, x1 - x0, wall.lighter(0.35)); c.hline(x0, 1, x1 - x0, wall.darker(0.16))
        c.rect(x0, floorTop - 12, x1 - x0, 12, PixelColor(0x6B7685))
        c.hline(x0, floorTop - 12, x1 - x0, PixelColor(0xF2C230))
        for x in stride(from: x0 + 4, to: x1, by: 24) { c.vline(x, floorTop - 11, 11, PixelColor(0x5F6977)) }
        // 작업등(원뿔 갓)
        for x in ToolRoom.lampXs { let lamp = Furniture.themedLamp(.cone, accent: PixelColor(0x3F4650)); c.stamp(lamp, x - lamp.width / 2, 2) }
        // 바닥: 회색 에폭시 + 앞 안전선, 반입구 앞 노랑·검정 사선
        for y in floorTop..<base { for x in x0..<x1 { c.dot(x, y, hash(x, y, 67) % 11 == 0 ? PixelColor(0x7E8992) : PixelColor(0x8E9AA3)) } }
        c.hline(x0, floorTop, x1 - x0, PixelColor(0xB4BEC6))
        for y in (floorTop + 2)..<base { for x in Int(ToolRoom.dockLeft) - 4..<(Int(ToolRoom.dockLeft + ToolRoom.dockWidth) + 4) { c.dot(x, y, ((x + y) / 2) % 2 == 0 ? Pal.mustard : Pal.black) } }
        // 팔레트 랙: 기둥(칸 경계) · 위 단 보(높이 37~39) · 꼭대기 보(70~72)
        let blue = PixelColor(0x2E6DB4), orange = PixelColor(0xE8792B)
        let posts = (0...ToolRoom.bayXs.count).map { Int(ToolRoom.bayXs[0] - ToolRoom.bayHalf) + $0 * Int(ToolRoom.bayHalf * 2) }
        let left = posts.first ?? x0, right = (posts.last ?? x1) + 2
        for beam in [ToolRoom.upperY - 3, 70] {
            let top = row(Int(beam) + 2)
            c.rect(left, top, right - left, 3, orange); c.hline(left, top, right - left, orange.lighter(0.3)); c.hline(left, top + 2, right - left, orange.darker(0.25))
        }
        for x in posts {
            c.rect(x, row(72), 2, base - row(72), blue)
            c.vline(x, row(72), base - row(72), blue.lighter(0.25))
            for y in stride(from: row(70), to: base - 2, by: 3) { c.dot(x + 1, y, blue.darker(0.35)) }   // 구멍
            c.rect(x - 1, base - 1, 4, 1, PixelColor(0x3F4650))                                             // 바닥판
        }
        // 콘센트: 칸 오른쪽 기둥 왼편, 아래 단 · 위 단(바닥 · 선반 위 6~9px)
        for bx in ToolRoom.bayXs {
            for lift in [0, Int(ToolRoom.upperY)] {
                let x = Int(bx + ToolRoom.socketDX) - 1, y = row(lift + 9)
                c.box(x, y, 3, 4, fill: Pal.paper, outline: PixelColor(0x8A96A6), rounded: false)
                c.dot(x + 1, y + 1, Pal.outline); c.dot(x + 1, y + 2, Pal.outline)
            }
        }
        // 게시판(랙 끝과 반입구 사이): 코르크 · 메모 두 장 — '+N' 표지가 그 위에 붙는다
        let board = Int(ToolRoom.boardX)
        c.box(board - 6, row(38), 13, 12, fill: PixelColor(0xC89B61), outline: Pal.oakDark, rounded: false)
        c.rect(board - 4, row(36), 4, 3, Pal.paper); c.rect(board + 1, row(34), 4, 4, PixelColor(0xF2E38B)); c.dot(board - 2, row(36), Pal.alarm)
        // 반입구: 셔터 뒤에 트럭 짐칸(어두운 짐칸 · 흰 문틀 · 실린 상자) → 위험 띠 문틀 · 셔터 하우징 · 반입 그림 표지
        let dx = Int(ToolRoom.dockLeft), dw = Int(ToolRoom.dockWidth), dh = Int(ToolRoom.dockHeight)
        let open = row(dh - 1)
        c.rect(dx, open, dw, base - open, PixelColor(0x2B313B))
        c.rect(dx, open, dw, 2, PixelColor(0xE9ECEF)); c.rect(dx, open, 2, base - open, PixelColor(0xE9ECEF)); c.rect(dx + dw - 2, open, 2, base - open, PixelColor(0xE9ECEF))
        c.rect(dx + 2, base - 4, dw - 4, 4, PixelColor(0x4B5563)); c.hline(dx + 2, base - 4, dw - 4, PixelColor(0x6B7280))
        c.stamp(Furniture.box(0), dx + 4, base - 12); c.stamp(Furniture.box(1), dx + 14, base - 12); c.stamp(Furniture.box(0), dx + 9, base - 20)
        for side in [dx - 3, dx + dw] {
            for y in (open - 3)..<base { for x in side..<(side + 3) { c.dot(x, y, ((x + y) / 2) % 2 == 0 ? Pal.mustard : Pal.black) } }
        }
        c.box(dx - 4, open - 7, dw + 8, 6, fill: PixelColor(0x6B7280), outline: PixelColor(0x3F4650), rounded: false)
        c.hline(dx - 3, open - 4, dw + 6, PixelColor(0x4B5563))
        let sign = dx + dw / 2 - 6
        c.box(sign, open - 17, 13, 9, fill: PixelColor(0x2E7D4F), outline: PixelColor(0x1F5A38), rounded: false)
        c.box(sign + 2, open - 15, 5, 5, fill: Pal.cardboard, outline: Pal.cardboardShade, rounded: false)
        c.hline(sign + 8, open - 13, 3, Pal.white); c.dot(sign + 10, open - 14, Pal.white); c.dot(sign + 10, open - 12, Pal.white)   // 상자 → 화살표
    }

    static func team(height: Int, floorIndex: Int, rooms: [BuildingLayout.Room], desks: [BuildingLayout.DeskSlot], isTop: Bool, isLibraryUpper: Bool) -> PixelCanvas {
        var c = PixelCanvas(BuildingLayout.width, height)
        let floorTop = height - BuildingLayout.slab - 6
        let roomsHere = rooms.filter { $0.floor == floorIndex }
        var cursor = BuildingLayout.mainX0
        for room in roomsHere {
            // 방마다 다른 벽지·바닥·창·등·소품(방 이름에서 결정, RoomTheme.swift). 책상 가구도 여기서 같이 그린다.
            themedRoom(&c, room: room, desks: desks, floorTop: floorTop)
            c.rect(room.x1 - 2, 0, 2, floorTop + 6, Pal.walnutDark) // 방 사이 벽
            c.box(room.x0 + 6, 8, min(60, room.x1 - room.x0 - 12), 9, fill: Pal.walnutDark, outline: Pal.gold) // 명패(글자는 장면에서)
            cursor = room.x1
        }
        // 빈 공간: 공실
        if cursor < BuildingLayout.mainX1 {
            plaster(&c, cursor, BuildingLayout.mainX1, 0, floorTop, base: PixelColor(0xEFE7DA))
            herringbone(&c, cursor, BuildingLayout.mainX1, floorTop)
            if BuildingLayout.mainX1 - cursor > 40 {
                c.stamp(Furniture.smallPlant(), cursor + 10, floorTop - 11 + 6)
                c.box(cursor + (BuildingLayout.mainX1 - cursor) / 2 - 14, floorTop - 36, 28, 12, fill: Pal.paper) // '공실' 안내판
            }
        }
        // 별관
        let wing = BuildingLayout.wingX0
        if isLibraryUpper {
            c.rect(wing, 0, BuildingLayout.wingX1 - wing, height, Pal.oak)
        } else if isTop {
            walnutPanel(&c, wing, BuildingLayout.wingX1, 0, floorTop)
            herringbone(&c, wing, BuildingLayout.wingX1, floorTop)
            c.stamp(Furniture.whiteboard(), wing + 28, 8)
            c.stamp(Furniture.floorLamp(), wing + 8, floorTop - 26 + 6)
            c.stamp(Furniture.armchair(), wing + 60, floorTop - 15 + 6)
            c.stamp(Furniture.floorLamp(), wing + 140, floorTop - 26 + 6)
        } else {
            plaster(&c, wing, BuildingLayout.wingX1, 0, floorTop)
            herringbone(&c, wing, BuildingLayout.wingX1, floorTop)
            c.stamp(Furniture.armchair(), wing + 20, floorTop - 15 + 6)
            c.stamp(Furniture.armchair(), wing + 60, floorTop - 15 + 6)
            c.stamp(Furniture.fiddleFig(), wing + 120, floorTop - 30 + 6)
            c.stamp(Furniture.wallArt(floorIndex), wing + 44, 14)
        }
        c.vline(wing - 2, 0, height, Pal.walnutDark)
        elevatorShaft(&c, height: height)
        facade(&c, height: height)
        slab(&c, height: height)
        return c
    }

    /// 기록 보관소 = 복구 금고의 방(로비 층 별관). 옆에서 본 정면 2D — 앞을 보는 보존 서가 · 서류 캐비닛 · 놋쇠 명판.
    /// 서가 위 네 단과 서가 꼭대기(다락)는 비워 둔다 — 금고 항목 상자는 장면(Vault.swift)이 올리고, 레일에 건 이동식 사다리도 장면이 굴린다.
    /// 원근선 없이 수평·수직만 쓴다. 쉬는 자리와 맞춘다: 독서 의자 6개(482·500·518 / 572·600·616), 가운데 문서 보관장 윗면 = 낮잠 자리(548, 바닥 위 40).
    static func library(height: Int) -> PixelCanvas {
        let width = BuildingLayout.wingX1 - BuildingLayout.wingX0
        var c = PixelCanvas(width, height)
        let floorTop = height - BuildingLayout.slab - 6
        let wall = PixelColor(0x6F8AA3)
        // 벽: 차분한 스틸 블루 + 은은한 세로 판넬, 천장 몰딩, 사다리 레일(놋쇠)
        c.rect(0, 0, width, floorTop, wall)
        for x in stride(from: 6, to: width, by: 12) { c.vline(x, 2, floorTop - 2, wall.darker(0.07)) }
        c.hline(0, 0, width, Pal.cream); c.hline(0, 1, width, wall.darker(0.25))
        c.hline(0, 16, width, Pal.gold.lighter(0.15)); c.hline(0, 17, width, Pal.gold.darker(0.3))
        // 보존 서가 두 벽(벽에 붙여 세움 — 아래 끝 = 바닥 띠 뒤쪽). 의자에 가리는 맨 아랫단만 옛 장부를 꽂아 둔다.
        c.stamp(Furniture.archiveStack(width: 54, height: floorTop - 19, seed: 1, fillRows: 4...4), 2, 19)
        c.stamp(Furniture.archiveStack(width: 64, height: floorTop - 19, seed: 2, fillRows: 4...4), 94, 19)
        // 가운데: 문서 보관장(윗면 이불·베개 = 낮잠 자리). 누운 직원의 아래 끝이 윗판에 닿게 둔다.
        c.stamp(Furniture.documentCabinet(), 61, floorTop - 38)
        // 금고 명판(놋쇠, 글자 '금고 · N건 · X GB'는 장면이 올린다)
        c.box(62, 21, 30, 10, fill: Pal.gold, outline: Pal.gold.darker(0.45), rounded: false)
        c.hline(63, 22, 28, Pal.gold.lighter(0.35)); c.hline(63, 29, 28, Pal.gold.darker(0.2))
        for x in [64, 89] { c.dot(x, 24, Pal.gold.darker(0.5)); c.dot(x, 27, Pal.gold.darker(0.5)) }
        // (예전 서류 캐비닛 · 화분은 오른쪽 서가 앞을 가려 금고 상자 수가 안 보여 뺐다.)
        // 바닥: 짙은 월넛 마루(로비 헤링본과 구분)
        for y in 0..<6 { for x in 0..<width {
            let run = x + (y / 3) * 9
            c.dot(x, floorTop + y, y % 3 == 2 ? Pal.walnutDark : run % 18 == 0 ? Pal.walnutDark.lighter(0.1) : (run / 18) % 2 == 0 ? Pal.walnut : Pal.walnutLight)
        } }
        c.hline(0, floorTop, width, Pal.walnutLight.lighter(0.2))
        // 독서 의자: 왼쪽 셋은 오른쪽을, 오른쪽 셋은 왼쪽을 본다(장면의 독서 자세 방향과 같다)
        let leather = PixelColor(0x8E3B3B)
        for spot in [10, 28, 46] { c.stamp(Furniture.readingChair(leather), spot - 7, floorTop + 6 - 15) }
        for spot in [100, 128, 144] { c.stamp(Furniture.readingChair(leather).flippedHorizontally(), spot - 6, floorTop + 6 - 15) }
        // 독서등(놋쇠 펜던트)
        for x in [28, 128] { let lamp = Furniture.themedLamp(.dome, accent: Pal.gold); c.stamp(lamp, x - lamp.width / 2, 2) }
        c.rect(0, height - BuildingLayout.slab, width, BuildingLayout.slab, Pal.walnutDark)
        return c
    }

    static func roof(height: Int) -> PixelCanvas {
        var c = PixelCanvas(BuildingLayout.width, height)
        let deckTop = height - BuildingLayout.slab - 6
        // 루프톱 데크
        for y in deckTop..<(height - BuildingLayout.slab) { c.hline(0, y, 320, (y - deckTop) % 2 == 0 ? Pal.oakMid : Pal.oak) }
        for x in stride(from: 0, to: 320, by: 9) { c.vline(x, deckTop, 6, Pal.oakDark) }
        // 유리 캐노피 골조
        c.hline(30, 6, 280, Pal.black); c.hline(30, 7, 280, Pal.black.lighter(0.3))
        for x in stride(from: 30, through: 310, by: 40) { c.vline(x, 6, deckTop - 6, Pal.black) }
        c.rect(30, 8, 280, 3, Pal.glass.with(alpha: 90))
        // 화분과 선베드
        for (index, x) in [44, 92, 140, 188, 236].enumerated() {
            c.stamp(Furniture.lounger(), x, deckTop - 10 + 6)
            if index % 2 == 0 { c.stamp(Furniture.smallPlant(), x + 33, deckTop - 11 + 6) }
        }
        c.box(272, deckTop - 6 + 6, 10, 6, fill: Pal.mustard); c.box(290, deckTop - 6 + 6, 10, 6, fill: Pal.terracotta) // 빈백
        // 웰니스 풀(참고 사진 8): 기둥·흰 돛 캐노피·청록 수영장
        c.rect(320, deckTop, 312, 6, Pal.travertine)
        c.rect(340, deckTop + 1, 256, 5, Pal.water)
        for x in stride(from: 342, to: 594, by: 7) { c.hline(x, deckTop + 2, 3, Pal.waterLight) }
        for x in stride(from: 326, through: 626, by: 50) { c.stamp(Furniture.column(), x, deckTop - 44 + 6) }
        c.stamp(Furniture.canopy(width: 306), 324, 4)
        for x in [360, 420, 480, 540] {
            c.box(x, deckTop - 4, 22, 4, fill: Pal.white)
            for t in stride(from: x + 2, to: x + 20, by: 4) { c.vline(t, deckTop - 3, 2, PixelColor(0x2E6DA4)) }
        }
        c.rect(0, height - BuildingLayout.slab, BuildingLayout.width, BuildingLayout.slab, Pal.concreteDark)
        c.hline(0, height - BuildingLayout.slab, BuildingLayout.width, Pal.concrete)
        return c
    }

    /// 하늘·원경(하루 다섯 때 × 계절, Weather.swift의 Daypart·Season). 장면 전체 폭(2400)으로 깔리고 텍스처 아래 끝이 옥상 층 바닥에 붙는다.
    /// 화면에 실제로 보이는 건 아래쪽 120px 남짓(옥상 뒤 + 건물 위 여백)이라 그러데이션·해·달·별·구름을 모두 그 띠에 둔다.
    /// REMON_FAKE_TIME 디버그 시각이 있으면 장면이 넘긴 시(hour) 대신 그 시각으로 그린다.
    static func sky(width: Int, height: Int, hour: Int) -> PixelCanvas {
        let part = Daypart.of(hour: SceneClock.isFaked ? SceneClock.hour : hour), season = Season.current
        var c = PixelCanvas(width, height)
        let (top, bottom) = part.sky
        let band = 150
        func skyColor(_ y: Int) -> PixelColor { top.mixed(bottom, Double(Int(max(0, Double(y - (height - band)) / Double(band)) * 7)) / 7) }   // 8단 띠
        for y in 0..<height { c.hline(0, y, width, skyColor(y)) }
        // 건물 기준 가상 좌표 → 텍스처 좌표(장면이 하늘을 x -880에 깐다. above = 옥상 층 바닥에서 위로).
        func at(_ x: Int, _ above: Int) -> (x: Int, y: Int) { (880 + x, height - above) }
        func disc(_ center: (x: Int, y: Int), _ radius: Double, _ fill: PixelColor, halo: PixelColor?) {
            let reach = Int(radius) + 4
            for dy in -reach...reach { for dx in -reach...reach {
                let d = (Double(dx * dx + dy * dy)).squareRoot()
                if d <= radius { c.dot(center.x + dx, center.y + dy, fill) } else if let halo, d <= radius + 3, (dx + dy) % 2 == 0 { c.dot(center.x + dx, center.y + dy, halo) }
            } }
        }
        // 별(저녁 드문드문 · 깊은 밤 촘촘), 해·달 위치는 때마다 다르다(아침 동쪽 낮게 → 점심 높이 → 노을 서쪽 낮게, 달도 같은 길)
        if part.isDark {
            for i in 0..<(part == .night ? 160 : 60) {
                let x = hash(i, 1, 81) % width, y = height - 40 - hash(i, 2, 81) % 80
                c.dot(x, y, Pal.white.with(alpha: UInt8(120 + hash(i, 3, 81) % 120)))
            }
        }
        switch part {
        case .morning: disc(at(48, 38), 6, PixelColor(0xFFF0B8), halo: PixelColor(0xFFF6D8, alpha: 150))
        case .noon: disc(at(250, 80), 7, PixelColor(0xFFF1A8), halo: PixelColor(0xFFFBE0, alpha: 170))
        case .sunset: disc(at(600, 18), 9, PixelColor(0xFF8F4A), halo: PixelColor(0xFFC27A, alpha: 150))
        case .evening:   // 초승달(동쪽 낮게): 둥근 달에서 하늘색 원을 비껴 덮어 깎는다
            let moon = at(52, 46)
            disc(moon, 5, PixelColor(0xF5F0D0), halo: nil); disc((moon.x + 3, moon.y - 1), 4.5, skyColor(moon.y), halo: nil)
        case .night:     // 높이 뜬 보름달 + 무늬
            let moon = at(470, 80)
            disc(moon, 6, PixelColor(0xF5F0D0), halo: PixelColor(0xF5F0D0, alpha: 60))
            for (dx, dy) in [(-2, -1), (1, 2), (2, -2)] { c.dot(moon.x + dx, moon.y + dy, PixelColor(0xDCD6B4)) }
        }
        // 구름(점심 흰 구름 · 아침 분홍빛 · 노을 주황빛 · 저녁 어두운 구름 · 깊은 밤 없음)
        let clouds: [(light: PixelColor, shade: PixelColor)?] = [(PixelColor(0xFFF4F0), PixelColor(0xF7D6D0)), (Pal.cloud, PixelColor(0xE6F2FA)), (PixelColor(0xFFD6A8), PixelColor(0xE89A86)),
                                                                (PixelColor(0x5A5A8E), PixelColor(0x46457A)), nil]
        if let cloud = clouds[part.rawValue] {
            for i in 0..<7 {
                let x = 880 - 160 + hash(i, 7, 83) % 1000, y = height - 62 - hash(i, 8, 83) % 48, w = 18 + hash(i, 9, 83) % 16
                c.rect(x, y, w, 4, cloud.light); c.rect(x + 4, y - 3, w / 2, 3, cloud.light); c.hline(x + 1, y + 4, w - 2, cloud.shade)
            }
        }
        // 원경 스카이라인(성당 실루엣 포함, 참고 사진 4) + 계절 나무 + 겨울 지붕 눈 + 때마다 다른 창 불빛 비율
        let skyline: PixelColor = [PixelColor(0xC3CEDC), PixelColor(0xB8C7D6), PixelColor(0x8A6C9A), PixelColor(0x2C3363), PixelColor(0x0F1530)][part.rawValue]
        let window = part == .morning ? PixelColor(0xF4E6B8) : PixelColor(0xF7D774)
        let tones = season.foliage
        var x = 0
        var i = 0
        while x < width {
            let w = 12 + hash(i, 3) % 20, h = 10 + hash(i, 4) % 26
            c.rect(x, height - h, w, h, skyline)
            if season == .winter { c.hline(x, height - h, w, PixelColor(0xEEF3F8)); c.hline(x + 1, height - h + 1, w - 2, PixelColor(0xEEF3F8).mixed(skyline, 0.5)) }
            if part.cityLights > 0 {
                for wy in stride(from: height - h + 3, to: height - 2, by: 4) { for wx in stride(from: x + 2, to: x + w - 2, by: 4) where hash(wx, wy) % 100 < part.cityLights { c.dot(wx, wy, window) } }
            }
            if hash(i, 5) % 3 == 0 {   // 건물 사이 나무(계절 색, 어두운 때는 실루엣 쪽으로)
                let tree = x + w, crown = 6 + hash(i, 6) % 4
                let leaf = season == .winter ? tones[2] : tones[1].mixed(skyline, part.isDark ? 0.7 : 0.25)
                c.rect(tree + 1, height - 4, 1, 4, skyline.darker(0.2))
                c.box(tree - crown / 2 + 1, height - 4 - crown, crown, crown, fill: leaf, outline: leaf)
                if season == .winter { c.hline(tree - crown / 2 + 2, height - 4 - crown, crown - 2, PixelColor(0xEEF3F8)) }
            }
            x += w + 2
            i += 1
        }
        let cathedral = width / 3
        c.rect(cathedral, height - 40, 30, 40, skyline.darker(0.05)); c.rect(cathedral + 12, height - 58, 6, 18, skyline.darker(0.05)); c.dot(cathedral + 14, height - 61, skyline.darker(0.05))
        return c
    }

    /// 땅(계절): 봄 꽃 핀 잔디 · 여름 짙은 잔디 · 가을 마른 잔디와 낙엽 · 겨울 눈 덮임. 시간대 색조는 날씨 층이 덮는다.
    static func ground(width: Int, height: Int) -> PixelCanvas {
        let season = Season.current
        var c = PixelCanvas(width, height)
        let dirt = season == .winter ? PixelColor(0x7A6048) : PixelColor(0x8B6B4A)
        c.rect(0, 0, width, height, dirt)
        for y in 0..<height { for x in 0..<width where hash(x, y, 13) % 13 == 0 { c.dot(x, y, dirt.darker(0.15)) } }
        switch season {
        case .spring:
            c.rect(0, 0, width, 4, PixelColor(0x7CC46A)); c.hline(0, 0, width, PixelColor(0x9BD98A))
            for x in 0..<width where hash(x, 0, 87) % 9 == 0 { c.dot(x, hash(x, 1, 87) % 2, [PixelColor(0xF29BB0), PixelColor(0xF7D154), Pal.white][hash(x, 2, 87) % 3]) }
        case .summer:
            c.rect(0, 0, width, 4, PixelColor(0x4FA84A)); c.hline(0, 0, width, PixelColor(0x6FC25E))
            for x in 0..<width where hash(x, 3, 89) % 5 == 0 { c.dot(x, 1 + hash(x, 4, 89) % 3, Pal.leafDark) }
        case .autumn:
            c.rect(0, 0, width, 3, PixelColor(0xA89A50)); c.hline(0, 0, width, PixelColor(0xC2B266))
            for x in 0..<width where hash(x, 5, 91) % 4 == 0 { c.dot(x, hash(x, 6, 91) % 5, [PixelColor(0xE8873A), PixelColor(0xC0503A), PixelColor(0xF2C14E)][hash(x, 7, 91) % 3]) }
        case .winter:
            for x in 0..<width {
                let depth = 4 + hash(x / 3, 8, 93) % 2
                c.vline(x, 0, depth, PixelColor(0xF4F7FB)); c.dot(x, depth, PixelColor(0xD8E2EE))
            }
            for x in 0..<width where hash(x, 9, 93) % 11 == 0 { c.dot(x, 2, PixelColor(0xDCE6F2)) }
        }
        return c
    }
}
