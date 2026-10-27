import AppKit
import ReMONCore
import SpriteKit

/// 기계실(지하) 배치: CPU 엔진 · RAM 탱크 · 스왑 창고 · 디스크 저장고 · 시스템 랙.
/// 사람(에이전트)과 구분되도록 하드웨어 자원은 모두 기계로 그린다.
enum MachineLayout {
    static let ranges: [(MachineKind, ClosedRange<CGFloat>)] = [
        (.cpu, 36...130), (.ram, 132...198), (.swap, 200...324), (.disk, 326...468), (.system, 472...632)
    ]
    static let cpuX: CGFloat = 40
    static let tankX: CGFloat = 148
    static let rackXs: [CGFloat] = [488, 522, 556, 590]

    static func kind(atX x: CGFloat) -> MachineKind? { ranges.first { $0.1.contains(x) }?.0 }

    static func rect(_ kind: MachineKind, floor: BuildingLayout.Floor) -> CGRect {
        let range = ranges.first { $0.0 == kind }?.1 ?? 36...632
        return CGRect(x: range.lowerBound - 6, y: CGFloat(floor.y) - 2, width: range.upperBound - range.lowerBound + 12, height: CGFloat(floor.height) + 10)
    }

    static func center(_ kind: MachineKind) -> CGFloat {
        let range = ranges.first { $0.0 == kind }?.1 ?? 36...632
        return (range.lowerBound + range.upperBound) / 2
    }
}

/// 기계 픽셀 그림.
enum MachineArt {
    static let steel = PixelColor(0x4B5563)
    static let steelDark = PixelColor(0x2F3742)
    static let steelLight = PixelColor(0x8A96A6)
    static let brass = PixelColor(0xC9A24A)

    /// CPU 엔진(86×42, 원점 왼쪽 위): 왼쪽 팬 자리, 가운데 실린더 칸 10개, 오른쪽 위 배기관, 아래 받침.
    static func engine() -> PixelCanvas {
        var c = PixelCanvas(86, 42)
        c.box(72, 0, 7, 12, fill: steelDark)                 // 배기관
        c.hline(71, 0, 9, steelLight)
        c.box(2, 10, 82, 27, fill: steel)                    // 몸체 y 10~36
        c.hline(3, 11, 80, steelLight)
        c.box(4, 13, 26, 22, fill: steelDark)                // 팬 틀 y 13~34
        for i in 0..<10 {                                     // 실린더 칸 y 13~32(막대는 장면이 올린다)
            let x = 34 + i * 5
            c.box(x, 13, 4, 20, fill: PixelColor(0x1C2128), rounded: false)
            c.dot(x + 1, 14, brass)
        }
        for x in stride(from: 6, to: 84, by: 12) { c.dot(x, 12, steelLight) }   // 리벳
        c.box(0, 36, 86, 6, fill: steelDark, rounded: false)   // 받침
        return c
    }

    /// 팬 날개 4프레임(22×22).
    static func fan(_ frame: Int) -> PixelCanvas {
        var c = PixelCanvas(22, 22)
        let center = 10.5
        for y in 0..<22 { for x in 0..<22 {
            let dx = Double(x) - center, dy = Double(y) - center
            let r = (dx * dx + dy * dy).squareRoot()
            if r > 10.5 { continue }
            if r > 9.2 { c.dot(x, y, steelLight); continue }
            if r < 2.2 { c.dot(x, y, brass); continue }
            let angle = atan2(dy, dx) + Double(frame) * .pi / 8
            let blade = (sin(angle * 2) + 1) / 2
            c.dot(x, y, blade > 0.62 ? PixelColor(0xC7D0DB) : PixelColor(0x252B33))
        } }
        return c
    }

    /// RAM 탱크(34×54): 꼭지·뚜껑, 유리 몸통(y 7~47), 눈금, 받침. 액체는 장면이 따로 올린다.
    static func tank() -> PixelCanvas {
        var c = PixelCanvas(34, 54)
        c.box(14, 0, 6, 3, fill: steelDark, rounded: false)   // 꼭지
        c.box(1, 2, 32, 5, fill: steel)                        // 뚜껑
        c.hline(2, 3, 30, steelLight)
        c.box(3, 7, 28, 41, fill: PixelColor(0xBFE6F2, alpha: 70), outline: steelLight, rounded: false)   // 유리
        c.vline(6, 10, 34, PixelColor(0xFFFFFF, alpha: 110))   // 반사광
        for i in 1...4 { c.hline(26, 7 + i * 8, 4, steelDark) } // 눈금
        c.box(0, 48, 34, 6, fill: steelDark, rounded: false)   // 받침
        return c
    }

    /// 서버 랙(28×46).
    static func rack() -> PixelCanvas {
        var c = PixelCanvas(28, 46)
        c.box(0, 0, 28, 46, fill: PixelColor(0x2A313B), outline: PixelColor(0x1E242C), rounded: false)
        for i in 0..<6 {
            let y = 4 + i * 7
            c.box(3, y, 22, 5, fill: PixelColor(0x39424E), outline: PixelColor(0x222830), rounded: false)
            c.hline(5, y + 2, 10, PixelColor(0x222830))
        }
        c.hline(0, 0, 28, steelLight)
        return c
    }

    // MARK: 도구실(앱 기계 · 반입구 · 리프트 수레)

    /// 도구(앱) 기계 네 크기(가로 × 세로). 0 작음 · 1 보통 · 2 큼 · 3 아주 큼. 위 단 선반(바닥선 +40)에 올라도 천장보 밑에 들어가게 28px까지.
    static let cabinetSizes: [(w: Int, h: Int)] = [(14, 18), (18, 22), (22, 25), (26, 28)]
    /// 화면 자리(캔버스 기준 x · y · 가로 · 세로)와 앞면 팬 자리(x · y · 지름).
    static func screenRect(_ size: Int) -> (x: Int, y: Int, w: Int, h: Int) { [(3, 5, 8, 5), (3, 5, 12, 7), (3, 5, 16, 8), (3, 5, 20, 10)][max(0, min(3, size))] }
    static func fanRect(_ size: Int) -> (x: Int, y: Int, s: Int) { [(3, 12, 3), (3, 14, 5), (3, 16, 5), (3, 18, 7)][max(0, min(3, size))] }

    /// 도구(앱) 캐비닛 몸통: 윗판 · 철판 몸통 · 화면 테두리 · 팬 구멍 · 통풍구 · 다리. 화면 · 팬 날개 · 경광등 · 표시등은 노드가 올린다.
    static func cabinet(_ size: Int) -> PixelCanvas {
        let (w, h) = cabinetSizes[max(0, min(3, size))]
        var c = PixelCanvas(w, h)
        let body = PixelColor(0x9AA3AF), edge = PixelColor(0x4B5563)
        c.box(0, 2, w, h - 4, fill: body, outline: edge, rounded: false)
        c.box(0, 0, w, 3, fill: PixelColor(0x6B7280), outline: PixelColor(0x3F4650), rounded: false)   // 윗판
        c.hline(1, 3, w - 2, body.lighter(0.25))
        let s = screenRect(size)
        c.box(s.x - 1, s.y - 1, s.w + 2, s.h + 2, fill: PixelColor(0x111827), outline: PixelColor(0x0B0F17), rounded: false)
        let f = fanRect(size)
        c.box(f.x - 1, f.y - 1, f.s + 2, f.s + 2, fill: PixelColor(0x2F3742), outline: edge, rounded: f.s > 3)
        for y in stride(from: f.y, to: f.y + f.s, by: 2) { c.hline(f.x + f.s + 2, y, w - f.x - f.s - 4, PixelColor(0x7C8592)) }   // 통풍구
        c.rect(1, h - 2, 3, 2, PixelColor(0x2F3742)); c.rect(w - 4, h - 2, 3, 2, PixelColor(0x2F3742))   // 다리
        return c
    }

    /// 앞면 팬 날개(지름 s, 4프레임).
    static func cabinetFan(_ s: Int, frame: Int) -> PixelCanvas {
        var c = PixelCanvas(s, s)
        let center = Double(s - 1) / 2
        for y in 0..<s { for x in 0..<s {
            let dx = Double(x) - center, dy = Double(y) - center
            let r = (dx * dx + dy * dy).squareRoot()
            guard r <= center + 0.3 else { continue }
            if r < 0.8 { c.dot(x, y, brass); continue }
            let blade = (sin((atan2(dy, dx) + Double(frame) * .pi / 4) * 2) + 1) / 2
            c.dot(x, y, blade > 0.55 ? PixelColor(0xC7D0DB) : PixelColor(0x252B33))
        } }
        return c
    }

    /// 기계 위 경광등(5×4): 받침 위 둥근 유리(3×3). 0 꺼짐(검붉음) · 1~4 빨간 등이 돈다(반짝이는 점이 왼쪽 → 가운데 → 오른쪽 → 뒤).
    static func beacon(_ frame: Int) -> PixelCanvas {
        var c = PixelCanvas(5, 4)
        let lit = frame > 0
        let glass = lit ? Pal.alarm : PixelColor(0x6E2A2E)
        c.rect(1, 0, 3, 3, glass)
        c.hline(1, 0, 3, lit ? Pal.alarm.lighter(0.3) : glass.lighter(0.15))
        c.hline(0, 3, 5, PixelColor(0x2F3742))
        if lit, frame < 4 { c.dot(frame, 1, Pal.white) }
        return c
    }

    /// 경광등 불빛(22×9, 반투명): 한쪽으로 퍼지는 빨간 부채꼴 — 밝은 벽 위에서도 보이게 가산 대신 보통 섞기.
    static func beaconGlow() -> PixelCanvas {
        var c = PixelCanvas(22, 9)
        for y in 0..<9 { for x in 0..<22 {
            let dx = Double(x) / 21, dy = abs(Double(y) - 4) / 4
            guard dy <= dx * 0.9 + 0.15 else { continue }
            let a = max(0, 0.7 - dx * 0.55 - dy * 0.2)
            if (x + y) % 2 == 0 || a > 0.4 { c.dot(x, y, PixelColor(0xFF2E2E, alpha: UInt8(a * 255))) }
        } }
        return c
    }

    /// 전원선: 기계 오른쪽 옆(바닥 위 3px)에서 처졌다가 칸 오른쪽 기둥의 콘센트(바닥 위 8px)에 꽂힌다. gap = 기계 옆면 → 콘센트 가로.
    static func cable(gap: Int) -> PixelCanvas {
        let w = max(3, gap), h = 8
        var c = PixelCanvas(w, h)
        let cord = PixelColor(0x2B2D33)
        for x in 0..<(w - 1) {
            let t = Double(x) / Double(max(1, w - 2))
            let y = Int((5 + 1.6 * sin(t * .pi) - 4 * t * t).rounded())   // 처졌다가 콘센트로 올라간다
            c.dot(x, max(1, min(h - 1, y)), cord)
        }
        c.rect(w - 2, 0, 2, 3, PixelColor(0x15171B))   // 플러그
        return c
    }

    /// 나무 배송 상자(기계보다 2px 큼): 판자 · 테두리 · 대각 버팀목 · 위 방향 화살표 · 송장.
    static func crate(_ size: Int) -> PixelCanvas {
        let (cw, ch) = cabinetSizes[max(0, min(3, size))]
        let w = cw + 2, h = ch + 2
        var c = PixelCanvas(w, h)
        let wood = PixelColor(0xC8975A), dark = PixelColor(0x8E6232), light = PixelColor(0xE2B97C)
        c.rect(0, 0, w, h, wood)
        for y in stride(from: 4, to: h - 2, by: 4) { c.hline(2, y, w - 4, dark.lighter(0.3)) }
        c.rect(0, 0, w, 2, dark); c.rect(0, h - 2, w, 2, dark); c.rect(0, 0, 2, h, dark); c.rect(w - 2, 0, 2, h, dark)
        for i in 0..<(min(w, h) - 4) { c.dot(2 + i * (w - 4) / max(1, min(w, h) - 4), h - 3 - i, light) }   // 버팀목
        for ax in [w - 9, w - 5] where ax > 2 { c.dot(ax + 1, 3, Pal.outline); c.hline(ax, 4, 3, Pal.outline); c.vline(ax + 1, 5, 2, Pal.outline) }
        c.box(3, h - 8, 5, 4, fill: Pal.paper, outline: PixelColor(0xC9C2B2), rounded: false)
        return c
    }

    /// 상자를 뜯을 때 튀는 판자 조각.
    static func plank(width: Int, height: Int) -> PixelCanvas {
        var c = PixelCanvas(max(1, width), max(1, height))
        c.rect(0, 0, width, height, PixelColor(0xC8975A))
        if width >= height { c.hline(0, height - 1, width, PixelColor(0x8E6232)) } else { c.vline(width - 1, 0, height, PixelColor(0x8E6232)) }
        return c
    }

    /// 리프트 수레 바탕(38×16, 원점 왼쪽 위): 왼쪽 손잡이(기사는 늘 수레 왼쪽에 선다) · 파란 받침 · 바퀴 두 개. 가위 다리 · 짐판은 노드가 올린다.
    static func liftBase() -> PixelCanvas {
        var c = PixelCanvas(38, 16)
        c.hline(0, 0, 4, steelDark); c.vline(1, 1, 10, steelLight); c.vline(2, 1, 10, steelDark)   // 손잡이
        c.box(0, 10, 38, 4, fill: PixelColor(0x2F6FB0), outline: PixelColor(0x1F4E80), rounded: false)
        c.hline(1, 11, 36, PixelColor(0x5B93CF))
        for x in [5, 28] { c.box(x, 12, 5, 4, fill: PixelColor(0x1C2128)); c.dot(x + 2, 13, steelLight) }
        return c
    }

    /// 가위 다리(가로 30, 세로 = 올린 높이, 1 이상). 낮으면 겹친 막대, 높으면 X자.
    static func liftArms(height: Int) -> PixelCanvas {
        let h = max(1, height), w = 30
        var c = PixelCanvas(w, h)
        if h <= 2 {
            c.hline(0, 0, w, steel); if h > 1 { c.hline(0, 1, w, steelDark) }
            return c
        }
        for x in 0..<w {
            let y = Int((Double(x) / Double(w - 1) * Double(h - 1)).rounded())
            c.dot(x, y, steelLight); c.dot(x, h - 1 - y, steel)
        }
        c.dot(w / 2, h / 2, brass)
        return c
    }

    /// 짐판(34×3): 철판 + 앞 모서리 노랑·검정 위험 띠.
    static func liftDeck() -> PixelCanvas {
        var c = PixelCanvas(34, 3)
        c.hline(0, 0, 34, steelLight); c.hline(0, 1, 34, steel)
        for x in 0..<34 { c.dot(x, 2, (x / 2) % 2 == 0 ? Pal.mustard : Pal.black) }
        return c
    }

    /// 반입구 셔터(28×38): 열린 만큼(0~1) 위 하우징으로 말려 올라간다. 말려 들어간 부분은 비운다(뒤의 트럭 짐칸이 보인다).
    static func dockShutter(open: Double) -> PixelCanvas {
        let w = 28, h = 38
        var c = PixelCanvas(w, h)
        let shown = Int((Double(h) * (1 - max(0, min(1, open)))).rounded())
        guard shown > 0 else { return c }
        for y in 0..<shown {
            let rib = y % 3
            c.hline(0, y, w, rib == 0 ? PixelColor(0x8E99A6) : rib == 1 ? PixelColor(0xC3CBD4) : PixelColor(0xADB6C1))
        }
        c.rect(0, shown - 2, w, 2, PixelColor(0x4B5563))   // 아래 막대
        c.rect(w / 2 - 3, shown - 4, 6, 1, PixelColor(0x2F3742))   // 손잡이
        return c
    }

    /// 물청소 자국(가로 width, 2px): 젖어 반짝이는 바닥.
    static func wetStreak(_ width: Int) -> PixelCanvas {
        var c = PixelCanvas(max(2, width), 2)
        for x in 0..<max(2, width) {
            c.dot(x, 0, PixelColor(0xBFE9FF, alpha: x % 3 == 0 ? 210 : 140))
            c.dot(x, 1, PixelColor(0x8FD3F5, alpha: x % 4 == 1 ? 200 : 110))
        }
        return c
    }

    /// '미끄럼 주의' 입간판(7×9): 노란 A자 판 + 검은 느낌표.
    static func wetFloorSign() -> PixelCanvas {
        var c = PixelCanvas(7, 9)
        for y in 0..<8 { let half = 1 + y / 3; c.hline(3 - half, y, half * 2 + 1, Pal.mustard) }
        c.dot(3, 0, Pal.mustardShade)
        c.vline(3, 2, 3, Pal.black); c.dot(3, 6, Pal.black)
        c.dot(0, 8, Pal.mustardShade); c.dot(6, 8, Pal.mustardShade)
        return c
    }

    /// 물청소 양동이(8×7): 파란 통 · 손잡이 · 물.
    static func bucket() -> PixelCanvas {
        var c = PixelCanvas(8, 7)
        c.hline(1, 0, 6, steelDark); c.dot(0, 1, steelDark); c.dot(7, 1, steelDark)   // 손잡이
        c.box(0, 2, 8, 5, fill: PixelColor(0x3B82C4), outline: PixelColor(0x245E92), rounded: false)
        c.hline(1, 2, 6, PixelColor(0x9BE7F3))   // 물
        return c
    }

    /// 짐꾼 수레(22×14, 원점 왼쪽 위): 왼쪽 손잡이(짐꾼은 늘 수레 왼쪽에 선다) · 철판 짐칸 · 바퀴 두 개. 상자는 장면이 짐칸 위(바닥에서 7px)에 얹는다.
    static func cart() -> PixelCanvas {
        var c = PixelCanvas(22, 14)
        c.hline(0, 0, 5, steelDark)                                 // 손잡이 가로대
        c.vline(0, 1, 7, steelLight); c.vline(1, 1, 7, steelDark)   // 손잡이 기둥
        c.box(0, 7, 22, 4, fill: steel, rounded: false)             // 짐칸 철판
        c.hline(1, 8, 20, steelLight)
        for x in [3, 14] {                                          // 바퀴
            c.box(x, 10, 5, 4, fill: PixelColor(0x1C2128))
            c.dot(x + 2, 11, steelLight)
        }
        return c
    }
}

/// 기계실 노드: 수치(SystemSnapshot)를 받아 팬 속도 · 실린더 · 열기 · 탱크 수위 · 경고등 · 랙 LED를 바꾼다.
final class MachineRoomNode: SKNode {
    private let engine = SKSpriteNode()
    private let fan = SKSpriteNode()
    private let heat = SKSpriteNode(color: NSColor(srgbRed: 1, green: 0.35, blue: 0.1, alpha: 1), size: CGSize(width: 82, height: 28))
    private var cylinders: [SKSpriteNode] = []
    private let tank = SKSpriteNode()
    private var liquids: [SKSpriteNode] = []
    private let lamp = SKSpriteNode(color: NSColor(srgbRed: 0.95, green: 0.2, blue: 0.2, alpha: 1), size: CGSize(width: 4, height: 3))
    private var racks: [SKSpriteNode] = []
    private var leds: [SKSpriteNode] = []
    private var fanSpeed: CGFloat = -1
    private var hot = false
    private var steamTimer = 0
    private(set) var floorLine: CGFloat = 0

    override init() {
        super.init()
        engine.anchorPoint = .zero
        engine.texture = TextureCache.shared.texture("machine-engine") { MachineArt.engine() }
        engine.size = CGSize(width: 86, height: 42)
        addChild(engine)
        let frames = (0..<4).map { index in TextureCache.shared.texture("machine-fan\(index)") { MachineArt.fan(index) } }
        fan.texture = frames[0]
        fan.size = CGSize(width: 22, height: 22)
        fan.anchorPoint = .zero
        fan.run(.repeatForever(.animate(with: frames, timePerFrame: 0.08)), withKey: "spin")
        addChild(fan)
        heat.anchorPoint = .zero
        heat.size = CGSize(width: 82, height: 26)
        heat.blendMode = .add
        heat.alpha = 0
        addChild(heat)
        for _ in 0..<10 {
            let bar = SKSpriteNode(color: NSColor(srgbRed: 0.35, green: 0.62, blue: 0.95, alpha: 1), size: CGSize(width: 4, height: 1))
            bar.anchorPoint = .zero
            addChild(bar)
            cylinders.append(bar)
        }
        tank.anchorPoint = .zero
        tank.texture = TextureCache.shared.texture("machine-tank") { MachineArt.tank() }
        tank.size = CGSize(width: 34, height: 54)
        tank.zPosition = 1
        addChild(tank)
        let colors = [NSColor(srgbRed: 0.95, green: 0.5, blue: 0.55, alpha: 0.95), NSColor(srgbRed: 0.3, green: 0.55, blue: 0.95, alpha: 0.95), NSColor(srgbRed: 0.3, green: 0.78, blue: 0.68, alpha: 0.95)]
        for color in colors {
            let liquid = SKSpriteNode(color: color, size: CGSize(width: 26, height: 0))
            liquid.anchorPoint = .zero
            addChild(liquid)
            liquids.append(liquid)
        }
        lamp.anchorPoint = .zero
        lamp.zPosition = 2
        lamp.alpha = 0.25
        addChild(lamp)
        for _ in MachineLayout.rackXs {
            let rack = SKSpriteNode(texture: TextureCache.shared.texture("machine-rack") { MachineArt.rack() })
            rack.anchorPoint = .zero
            rack.size = CGSize(width: 28, height: 46)
            addChild(rack)
            racks.append(rack)
            for slot in 0..<3 {
                let led = SKSpriteNode(color: slot == 0 ? NSColor.systemGreen : slot == 1 ? NSColor.systemBlue : NSColor.systemOrange, size: CGSize(width: 2, height: 1))
                led.anchorPoint = .zero
                led.zPosition = 1
                led.run(.repeatForever(.sequence([.wait(forDuration: Double.random(in: 0.2...1.4)), .fadeAlpha(to: 0.2, duration: 0.05), .wait(forDuration: Double.random(in: 0.05...0.4)), .fadeAlpha(to: 1, duration: 0.05)])))
                addChild(led)
                leds.append(led)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 층이 바뀌면(지하 바닥선) 위치를 다시 잡는다.
    func place(floorLine: CGFloat) {
        self.floorLine = floorLine
        engine.position = CGPoint(x: MachineLayout.cpuX, y: floorLine)
        fan.position = CGPoint(x: MachineLayout.cpuX + 6, y: floorLine + 8)
        heat.position = CGPoint(x: MachineLayout.cpuX + 2, y: floorLine + 6)
        for (index, bar) in cylinders.enumerated() { bar.position = CGPoint(x: MachineLayout.cpuX + 34 + CGFloat(index * 5), y: floorLine + 10) }
        tank.position = CGPoint(x: MachineLayout.tankX, y: floorLine)
        lamp.position = CGPoint(x: MachineLayout.tankX + 15, y: floorLine + 54)
        for (index, rack) in racks.enumerated() {
            let x = MachineLayout.rackXs[index]
            rack.position = CGPoint(x: x, y: floorLine)
            for slot in 0..<3 { leds[index * 3 + slot].position = CGPoint(x: x + 20, y: floorLine + 10 + CGFloat(slot) * 14) }
        }
        layoutLiquids(lastFractions)
    }

    private var lastFractions: [Double] = [0, 0, 0]

    func update(system: SystemSnapshot) {
        // 팬: 실제 팬 RPM(SMC)에 비례해 돈다(최소 0.4배 ~ 최대 7배). 못 읽으면 CPU 사용률로 대신한다.
        let cpu = system.cpuPercent
        let thermal = system.thermal
        let speed: CGFloat = thermal.available && thermal.fanCount > 0 ? CGFloat(0.4 + thermal.fanFraction * 6.6) : CGFloat(max(0.4, min(6, cpu / 15)))
        if abs(speed - fanSpeed) > 0.2 { fanSpeed = speed; fan.action(forKey: "spin")?.speed = speed }
        // 열기: 다이 온도 70°C부터 붉어지고 95°C면 과열(증기). 온도를 못 읽으면 CPU 50%·85%.
        if thermal.available && thermal.cpuTemperature > 0 {
            heat.alpha = CGFloat(max(0, min(0.5, (thermal.cpuTemperature - 70) / 50)))
            hot = thermal.cpuTemperature >= 95 || cpu >= 90
        } else {
            heat.alpha = CGFloat(max(0, min(0.45, (cpu - 50) / 110)))
            hot = cpu >= 85
        }
        let loads = system.coreLoads
        for (index, bar) in cylinders.enumerated() {
            let load = index < loads.count ? loads[index] : cpu
            bar.size = CGSize(width: 4, height: max(1, CGFloat(load / 100 * 19).rounded()))
            bar.color = load >= 85 ? .systemRed : load >= 60 ? .systemOrange : NSColor(srgbRed: 0.35, green: 0.62, blue: 0.95, alpha: 1)
            bar.isHidden = index >= max(1, loads.count) && !loads.isEmpty
        }
        // RAM: 와이어드 · 앱 · 압축 순으로 아래부터 차오른다
        let total = max(1, Double(system.memory.physical))
        lastFractions = [Double(system.memory.wired) / total, Double(system.memory.appMemory) / total, Double(system.memory.compressed) / total]
        layoutLiquids(lastFractions)
        lamp.removeAllActions()
        switch system.pressure {
        case .normal: lamp.alpha = 0.2
        case .warning: lamp.run(.repeatForever(.sequence([.fadeAlpha(to: 1, duration: 0.4), .fadeAlpha(to: 0.3, duration: 0.4)])))
        case .critical: lamp.run(.repeatForever(.sequence([.fadeAlpha(to: 1, duration: 0.15), .fadeAlpha(to: 0.2, duration: 0.15)])))
        }
    }

    private func layoutLiquids(_ fractions: [Double]) {
        var y = floorLine + 6
        let height: CGFloat = 41
        for (index, liquid) in liquids.enumerated() {
            let h = (CGFloat(min(1, max(0, fractions[index]))) * height).rounded()
            liquid.position = CGPoint(x: MachineLayout.tankX + 4, y: y)
            liquid.size = CGSize(width: 26, height: h)
            y += h
        }
    }

    /// 장면의 주기 갱신에서 불러 과열 증기를 뿜는다.
    func tick(in world: SKNode) {
        guard hot else { return }
        steamTimer += 1
        guard steamTimer % 2 == 0 else { return }
        Effects.burst(in: world, at: CGPoint(x: MachineLayout.cpuX + 75, y: floorLine + 42), color: PixelColor(0xE5E7EB), count: 3, spread: 4, rise: 14, duration: 0.9)
    }
}

/// 스왑 창고(상자 더미, 1GB = 1상자)와 디스크 저장고(선반 4개 × 12칸, 1칸 = 디스크의 1/48 — 칸은 꼬리표별 색, DiskShelves), 그리고 상자를 나르는 짐꾼(직원 — 에이전트 아님).
/// 값이 상자 하나 이상 바뀌어 두 스냅샷 연속 그대로면 짐꾼이 지하 엘리베이터로 들어와 상자를 쌓고(늘 때), 들고 나간다(줄 때).
/// 보이는 상자 수는 짐꾼이 놓고 집을 때만 한 개씩 바뀐다. 연출을 못 보는 동안(창 닫힘·멈춤)이 지나면 snapToTruth로 실제 값에 바로 맞춘다.
/// 메모리 최적화 뒤 앱이 실측한 '줄어든 스왑'이 오면(unload) 짐꾼이 내려와 상자를 내간다(3개 넘으면 수레로 8개씩, 여러 번).
/// 상자는 실제 값(스냅샷)만 따른다: 줄일 때는 마지막 스냅샷의 실제 값 아래로 내려가지 않고, 실제로 줄지 않은 상자를 들고 나가지도 않는다.
/// 스왑은 그 페이지를 쓰던 앱이 끝나야 줄고 ReMON이 직접 줄일 수 없기 때문이다(10-25 대표 원칙 '은유가 사실을 앞서면 안 된다' —
/// 예전엔 비운 양만큼 나르기를 채우려고 실제로 줄지 않은 상자도 '맨 위에서 덜어 낸 짐'으로 들고 나갔다).
final class WarehouseNode: SKNode {
    enum Stock: CaseIterable { case swap, disk }

    static let capacity = 48
    static let stackX: CGFloat = 206
    static let shelfXs: [CGFloat] = [332, 364, 396, 428]
    /// 한 번에 드는 상자 수 · 연출로 보여 줄 최대 차이(넘으면 나머지는 바로 맞춰 늘 실제 값에 빨리 닿게) · 걷는 속도(px/초).
    static let perTrip = 3
    static let maxAnimated = 6
    static let speed: CGFloat = 55
    /// 수레: 한 번에 8상자(2줄 × 4단) · 짐꾼 오른쪽 16px. 내가기 연출은 수레 3번(24상자)까지, 넘는 만큼은 실제 값 쪽으로 바로 맞춘다.
    static let cartCapacity = 8
    static let cartOffset: CGFloat = 16
    static let maxUnloadAnimated = 24
    /// 트레이너(메모리 정리)가 다녀간 뒤 스왑 감소를 자동 운반이 미루는 시간 — 그사이 들어오는 내가기(실측 비운 양)가 맡는다.
    static let swapHoldSeconds: TimeInterval = 25

    var openElevator: (() -> Void)?
    /// 일거리(연속 운반)를 시작할 때 한 번: 종류 · 바뀐 칸 수(+ 늘어남, − 줄어듦). 자동 줌·말풍선용.
    var onJob: ((Stock, Int) -> Void)?
    /// 스왑 내가기: 짐꾼이 더미 앞에 닿았을 때(이번에 나를 상자 수 · 수레인지 — 0이면 둘러보기) · 내가기 일거리가 끝났을 때.
    enum UnloadEvent { case atStack(boxes: Int, cart: Bool), done }
    var onUnload: ((UnloadEvent) -> Void)?
    let porter = SKSpriteNode()
    /// 수레: 늘 짐꾼 오른쪽에 붙어 다닌다 — 들어올 때는 앞으로 밀고, 나갈 때는 뒤로 끈다(손잡이는 수레 왼쪽).
    let cart = SKSpriteNode()
    /// 지금 보이는 칸 수 · 마지막 스냅샷의 실제 칸 수 · 짐꾼이 맞추는 목표(두 번 연속 같은 값).
    private(set) var shown: [Stock: Int] = [:]
    private(set) var truth: [Stock: Int] = [:]
    private var target: [Stock: Int] = [:]
    private var swapBoxes: [SKSpriteNode] = []
    private var cartBoxes: [SKSpriteNode] = []
    /// 디스크 저장고 선반 넷과 칸마다 상자(꼬리표 색 — DiskStock.swift). 칸 수는 아래 shown[.disk]가 정한다.
    let diskShelves = DiskShelves()
    /// 지금 디스크 사용량(바이트) — 칸을 꼬리표별로 나눌 때 '기타' 몫을 정한다(장면이 스냅샷마다 넣는다).
    var diskUsedBytes: UInt64 = 0
    /// 재고 조사 중(Inventory.swift): 디스크 칸 운반을 미룬다 — 끝나면 실측(snapDisk)으로 실제 값에 맞추거나(마침), 짐꾼이 평소대로 나른다(취소).
    var holdDisk = false {
        didSet { if oldValue && !holdDisk { startTripIfNeeded() } }
    }
    private(set) var floorLine: CGFloat = 0
    private(set) var busy = false
    private var inJob = false
    private var tripStarted: TimeInterval = 0
    private var clock: TimeInterval = 0
    /// 내가기 일거리: 남은 나르기 수 · 비운 양이 0이거나 실제로 뺄 상자가 없어 둘러보기만 · 이번 일거리에서 나른 수(검수용) ·
    /// 이번 일거리에서 짐꾼이 더미에서 직접 뺄 상자 수(실제 값이 허락하는 만큼 — 장면 말풍선용) · 일거리 중.
    private(set) var unloadLeft = 0
    private var unloadInspect = false
    private(set) var unloadCarried = 0
    private(set) var unloadPlanned = 0
    private(set) var unloading = false
    /// 검수용: 지금까지 스왑 더미에서 빠진 상자 수(짐꾼이 들고 나간 것 + 큰 변화를 바로 맞춘 것). 실제 값이 허락할 때만 는다.
    private(set) var swapRemoved = 0
    /// 지금 내가기 한 번에서 실제로 집은 상자 수(손으로 나를 때 들고 나가는 자세를 정한다).
    private var tripTaken = 0
    private var swapHoldUntil: TimeInterval = 0
    /// 자동 운반이 최근 스왑 상자를 뺀 시각들. 내가기가 늦게 오면 이미 뺀 상자는 나른 것으로 친다(같은 상자를 두 번 빼지 않게).
    private var autoRemovals: [TimeInterval] = []

    override init() {
        super.init()
        addChild(diskShelves)
        porter.anchorPoint = CGPoint(x: 0.5, y: 0)
        porter.zPosition = 4
        porter.isHidden = true
        addChild(porter)
        cart.texture = TextureCache.shared.texture("porter-cart") { MachineArt.cart() }
        cart.size = CGSize(width: 22, height: 14)
        cart.anchorPoint = CGPoint(x: 0.5, y: 0)
        cart.zPosition = 4.5
        cart.isHidden = true
        addChild(cart)
        refresh(.disk)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func texture(_ pose: WorkerPose) -> SKTexture { TextureCache.shared.texture("porter-\(pose)") { CharacterArt.porterSprite(pose) } }

    /// 층이 바뀌면(지하 바닥선) 위치를 다시 잡는다.
    func place(floorLine: CGFloat) {
        self.floorLine = floorLine
        diskShelves.place(floorLine: floorLine)
        for (index, box) in swapBoxes.enumerated() { box.position = boxPoint(index) }
        if porter.action(forKey: "trip") == nil { porter.position.y = floorLine; cart.position.y = floorLine }
    }

    /// 스냅샷마다: 실제 칸 수. 처음 값은 연출 없이 그대로 보인다.
    func update(swapBoxes swap: Int, diskSlots disk: Int) {
        for (stock, raw) in [(Stock.swap, swap), (.disk, disk)] {
            let value = min(Self.capacity, max(0, raw))
            let previous = truth[stock]
            truth[stock] = value
            if shown[stock] == nil {
                shown[stock] = value
                target[stock] = value
                refresh(stock)
            } else if previous == value || (stock == .swap && unloading) {
                // 반올림 경계에서 오락가락하는 값(4.49 ↔ 4.51GB)에 짐꾼이 왔다 갔다 하지 않게, 두 번 연속 같은 값만 따른다.
                // 내가기 중에는 대표가 실제로 비운 직후라 새 스왑 값을 바로 목표로 삼는다(더미가 실제 값보다 아래로 내려가지 않게).
                target[stock] = value
            }
        }
        startTripIfNeeded()
    }

    /// 트레이너(메모리 정리)가 들어올 때: 곧 실측한 비운 양(unload)이 올 수 있으니, 스왑 감소의 자동 운반을 잠시 미룬다.
    /// 내가기가 오면 그쪽이 맡고, 안 오면(값이 그대로·호출 없음) 시한이 지나 평소대로 자동 운반한다. 늘어난 상자는 미루지 않는다.
    func holdSwapDecrease() {
        swapHoldUntil = clock + Self.swapHoldSeconds
    }

    /// 메모리 최적화 뒤 실측한 비운 스왑(상자 수 = GB 반올림, 최소 1 — 장면이 계산한다)이 오면 짐꾼이 내려온다. 0이면 둘러보고 나간다.
    /// 더미에서 빠지는 상자는 실제 값이 허락하는 만큼(보이는 더미 − 스냅샷의 실제 칸 수)뿐이다 — 비운 양이 더 커도(반올림 · 창고 한도) 그 이상은
    /// 빼지 않는다. 자동 운반이 방금(30초 안) 뺀 상자는 이미 나른 것으로 친다. 뺄 상자가 없으면 둘러보러만 온다(무슨 일인지는 장면이 말풍선으로).
    func unload(boxes: Int) {
        swapHoldUntil = 0
        if let value = truth[.swap] { target[.swap] = value }   // 실측이 왔다 — 두 번 연속 확인을 기다리지 않는다
        inJob = true   // 이어지는 자동 맞춤이 '일거리 시작' 알림(카메라·말풍선)을 또 띄우지 않게
        unloading = true
        unloadCarried = 0
        unloadPlanned = 0
        let recent = autoRemovals.filter { clock - $0 <= 30 }.count
        autoRemovals.removeAll()
        if boxes <= 0 {
            unloadLeft = 0
            unloadInspect = true
        } else {
            let real = max(0, (shown[.swap] ?? 0) - (goal(.swap) ?? shown[.swap] ?? 0))
            unloadCarried = min(boxes, recent)
            unloadLeft = min(boxes - unloadCarried, real)
            if unloadLeft > Self.maxUnloadAnimated {
                // 수레 3번을 넘는 양: 넘는 만큼은 더미에서 바로 덜어 낸다(real ≥ 남은 나르기라 실제 값 아래로는 내려가지 않는다).
                let extra = unloadLeft - Self.maxUnloadAnimated
                if let now = shown[.swap], let goal = goal(.swap) {
                    let snap = min(extra, max(0, now - goal))
                    shown[.swap] = now - snap
                    swapRemoved += snap
                    refresh(.swap)
                }
                unloadCarried += extra
                unloadLeft = Self.maxUnloadAnimated
            }
            unloadPlanned = unloadLeft
            // 자동 운반이 이미 다 뺐거나 실제 값 기준으로 뺄 상자가 없으면 둘러보러만 온다.
            if unloadLeft == 0 { unloadInspect = true }
        }
        startTripIfNeeded()
    }

    /// 짐꾼이 맞출 칸 수. 늘 때는 목표(두 번 연속 같은 실제 값), 줄 때는 목표와 마지막 실제 값 중 큰 쪽 —
    /// 목표가 아직 옛 값이어도 더미는 마지막 스냅샷의 실제 값 아래로 내려가지 않는다(실제 값이 다시 늘었으면 그 자리에서 멈춘다).
    private func goal(_ stock: Stock) -> Int? {
        guard let goal = target[stock] else { return nil }
        guard let now = shown[stock], goal < now else { return goal }
        return min(now, max(goal, truth[stock] ?? goal))
    }

    /// 재고 조사를 마친 실측: 디스크 칸만 실제 값(마지막 스냅샷)에 바로 맞춘다 — 짐꾼은 오지 않는다.
    func snapDisk() {
        guard let value = truth[.disk] else { return }
        shown[.disk] = value
        target[.disk] = value
        refresh(.disk)
    }

    /// 연출을 건너뛰고 실제 값에 바로 맞춘다(창을 다시 열 때 · 연출이 너무 오래 걸릴 때).
    func snapToTruth() {
        porter.removeAllActions()
        porter.isHidden = true
        cart.removeAllActions()
        cart.isHidden = true
        cartBoxes.forEach { $0.removeFromParent() }
        cartBoxes = []
        busy = false
        inJob = false
        unloadLeft = 0
        unloadInspect = false
        unloading = false
        swapHoldUntil = 0
        autoRemovals = []
        for stock in Stock.allCases {
            guard let value = truth[stock] else { continue }
            if stock == .swap, let now = shown[stock], now > value { swapRemoved += now - value }
            shown[stock] = value
            target[stock] = value
            refresh(stock)
        }
    }

    /// 장면의 1초 주기(장면이 실제로 돈 시간): 한 번 운반이 40초 넘게 끝나지 않으면 끊고 실제 값에 맞춘다. 미뤄 둔 스왑 감소는 시한이 지나면 나른다.
    func tick(activeTime: TimeInterval) {
        clock = activeTime
        if busy, activeTime - tripStarted > 40 { snapToTruth() }
        if swapHoldUntil > 0, activeTime >= swapHoldUntil {
            swapHoldUntil = 0
            startTripIfNeeded()
        }
    }

    private func startTripIfNeeded() {
        guard !busy, parent != nil else { return }
        if unloadInspect { unloadInspect = false; inspectTrip(); return }
        if unloadLeft > 0 { unloadTrip(); return }
        if unloading {
            // 내가기 끝. 실제 값과 남은 차이가 있으면 아래 자동 운반이 같은 일거리로 이어 맞춘다.
            unloading = false
            onUnload?(.done)
        }
        let holding = clock < swapHoldUntil
        guard let stock = Stock.allCases.first(where: { stock in
            guard let goal = goal(stock), let now = shown[stock], goal != now else { return false }
            return !(stock == .swap && holding && goal < now) && !(stock == .disk && holdDisk)
        }), let goal = goal(stock), var now = shown[stock] else {
            inJob = false
            porter.isHidden = true
            return
        }
        if !inJob {
            inJob = true
            onJob?(stock, goal - now)
        }
        if abs(goal - now) > Self.maxAnimated {
            let jumped = goal - (goal > now ? Self.maxAnimated : -Self.maxAnimated)
            if stock == .swap, jumped < now { swapRemoved += now - jumped }
            now = jumped
            shown[stock] = now
            refresh(stock)
        }
        trip(stock, adding: goal > now, count: min(Self.perTrip, abs(goal - now)))
    }

    /// 짐꾼을 엘리베이터 칸에 세운다(나타나기 전).
    private func enterFromShaft(carrying: Bool) {
        porter.removeAction(forKey: "trip")
        porter.removeAction(forKey: "anim")
        porter.position = CGPoint(x: CGFloat(BuildingLayout.elevatorX), y: floorLine)
        porter.alpha = 0
        porter.isHidden = false
        stand(carrying: carrying, right: true)
        openElevator?()
    }

    /// 엘리베이터로 나가 사라진 뒤: 다음 일거리.
    private func exitSteps(cart withCart: Bool) -> [SKAction] {
        [
            .run { [weak self] in self?.openElevator?() },
            .wait(forDuration: 0.15),
            .group([.fadeOut(withDuration: 0.2), .run { [weak self] in if withCart { self?.cart.run(.fadeOut(withDuration: 0.2), withKey: "fade") } }]),
            .run { [weak self] in
                guard let self else { return }
                self.busy = false
                self.porter.isHidden = true
                if withCart {
                    self.cart.isHidden = true
                    self.cartBoxes.forEach { $0.removeFromParent() }
                    self.cartBoxes = []
                }
                self.startTripIfNeeded()
            }
        ]
    }

    /// 한 번 운반: 엘리베이터 → 일할 자리 → 상자 count개 놓기(또는 집기) → 엘리베이터.
    private func trip(_ stock: Stock, adding: Bool, count: Int) {
        busy = true
        tripStarted = clock
        let shaft = CGFloat(BuildingLayout.elevatorX)
        let slot = adding ? (shown[stock] ?? 0) : max(0, (shown[stock] ?? 1) - 1)
        let work = workX(stock, slot: slot)
        enterFromShaft(carrying: adding)
        var steps: [SKAction] = [.wait(forDuration: 0.2), .fadeIn(withDuration: 0.2), walk(from: shaft, to: work, carrying: adding)]
        for _ in 0..<count {
            steps.append(.run { [weak self] in self?.move(stock, adding: adding) })
            steps.append(.wait(forDuration: 0.4))
        }
        steps.append(.run { [weak self] in self?.stand(carrying: !adding, right: true) })
        steps.append(walk(from: work, to: shaft, carrying: !adding))
        steps += exitSteps(cart: false)
        porter.run(.sequence(steps), withKey: "trip")
    }

    /// 내가기 한 번: 3상자까지는 손으로(하나씩 집어 들고), 넘으면 수레를 밀고 들어와 8상자까지 싣고 끌고 나간다.
    private func unloadTrip() {
        let withCart = unloadLeft > Self.perTrip
        let count = min(unloadLeft, withCart ? Self.cartCapacity : Self.perTrip)
        busy = true
        tripStarted = clock
        tripTaken = 0
        let shaft = CGFloat(BuildingLayout.elevatorX)
        // 수레는 더미 바로 왼쪽(오른쪽 끝 205)에 세우고, 짐꾼은 그 왼쪽 손잡이 자리에 선다.
        let work = withCart ? Self.stackX - 12 - Self.cartOffset : workX(.swap, slot: 0)
        enterFromShaft(carrying: false)
        if withCart {
            cartBoxes.forEach { $0.removeFromParent() }
            cartBoxes = []
            cart.removeAllActions()
            cart.position = CGPoint(x: shaft + Self.cartOffset, y: floorLine)
            cart.alpha = 0
            cart.isHidden = false
        }
        var steps: [SKAction] = [
            .wait(forDuration: 0.2),
            .group([.fadeIn(withDuration: 0.2), .run { [weak self] in if withCart { self?.cart.run(.fadeIn(withDuration: 0.2), withKey: "fade") } }]),
            withCart ? cartWalk(from: shaft, to: work) : walk(from: shaft, to: work, carrying: false),
            .run { [weak self] in
                guard let self else { return }
                // 걸어오는 사이 실제 값이 다시 늘었으면 남은 나르기를 실제 값이 허락하는 만큼으로 줄인다(말풍선도 그 수만 말한다).
                let surplus = max(0, (self.shown[.swap] ?? 0) - (self.goal(.swap) ?? self.shown[.swap] ?? 0))
                self.unloadLeft = min(self.unloadLeft, surplus)
                self.onUnload?(.atStack(boxes: min(count, surplus), cart: withCart))
            }
        ]
        for _ in 0..<count {
            steps.append(.run { [weak self] in self?.unloadOne(cart: withCart) })
            steps.append(.wait(forDuration: withCart ? 0.3 : 0.4))
        }
        if withCart {
            steps.append(.wait(forDuration: 0.25))
            steps.append(cartWalk(from: work, to: shaft))
        } else {
            // 실제로 집은 상자가 있을 때만 들고 나간다(계획한 뒤 실제 값이 다시 늘어 하나도 못 집었으면 빈손으로).
            steps.append(.run { [weak self] in
                guard let self else { return }
                let carrying = self.tripTaken > 0
                self.stand(carrying: carrying, right: false)
                self.porter.run(self.walk(from: work, to: shaft, carrying: carrying), withKey: "walkOut")
            })
            steps.append(.wait(forDuration: TimeInterval(max(0.05, abs(work - shaft) / Self.speed))))
        }
        steps += exitSteps(cart: withCart)
        porter.run(.sequence(steps), withKey: "trip")
    }

    /// 둘러보기(비운 양 0 · 이미 다 뺐음): 엘리베이터 → 더미 앞에서 살피고(말풍선은 장면) → 엘리베이터. 상자는 그대로.
    private func inspectTrip() {
        busy = true
        tripStarted = clock
        let shaft = CGFloat(BuildingLayout.elevatorX)
        let work = workX(.swap, slot: 0)
        enterFromShaft(carrying: false)
        var steps: [SKAction] = [.wait(forDuration: 0.2), .fadeIn(withDuration: 0.2), walk(from: shaft, to: work, carrying: false),
                                 .run { [weak self] in self?.onUnload?(.atStack(boxes: 0, cart: false)) },
                                 .wait(forDuration: 2.0),
                                 .run { [weak self] in self?.stand(carrying: false, right: false) },
                                 walk(from: work, to: shaft, carrying: false)]
        steps += exitSteps(cart: false)
        porter.run(.sequence(steps), withKey: "trip")
    }

    /// 내가기 나르기 하나: 더미가 실제 값보다 많을 때만 맨 위 상자를 집는다(더미 −1). 계획한 뒤 실제 값이 다시 늘어 남는 상자가 없으면
    /// 빈손으로 둔다 — 줄지 않은 상자를 지어내 들고 나가지 않는다.
    private func unloadOne(cart withCart: Bool) {
        guard unloadLeft > 0 else { return }
        unloadLeft -= 1
        guard let now = shown[.swap], let goal = goal(.swap), now > goal, let box = swapBoxes.popLast() else { return }
        shown[.swap] = now - 1
        swapRemoved += 1
        unloadCarried += 1
        tripTaken += 1
        guard withCart else {
            box.run(.sequence([.group([.fadeOut(withDuration: 0.2), .moveBy(x: -6, y: 5, duration: 0.2)]), .removeFromParent()]))
            return
        }
        // 수레에 싣기: 더미 → 짐칸(2줄 × 4단)으로 살짝 뛰어오르며 옮긴다
        let slot = cartBoxes.count
        let from = CGPoint(x: box.position.x - cart.position.x, y: box.position.y - cart.position.y)
        let to = CGPoint(x: slot % 2 == 0 ? -8 : 1, y: 7 + CGFloat(slot / 2) * 8)
        box.removeAllActions()
        box.removeFromParent()
        box.alpha = 1
        box.position = from
        box.zPosition = 0.1
        cart.addChild(box)
        cartBoxes.append(box)
        box.run(.group([.moveTo(x: to.x, duration: 0.24),
                        .sequence([.moveTo(y: max(from.y, to.y) + 8, duration: 0.12), .moveTo(y: to.y, duration: 0.12)])]))
    }

    /// 상자 하나를 놓거나 집는다(보이는 칸 수가 여기서만 한 개씩 바뀐다).
    private func move(_ stock: Stock, adding: Bool) {
        guard let now = shown[stock], let goal = goal(stock) else { return }
        // 운반 도중에 목표·실제 값이 바뀌어(다시 늘거나 줄어) 이미 맞았으면 더 옮기지 않는다 — 줄일 때는 마지막 실제 값 아래로 내려가지 않는다.
        guard adding ? now < goal : now > goal else { return }
        shown[stock] = now + (adding ? 1 : -1)
        switch stock {
        case .swap:
            if adding {
                let box = makeBox(now)
                let point = boxPoint(now)
                box.position = CGPoint(x: point.x, y: point.y + 5)
                box.alpha = 0
                box.run(.group([.fadeIn(withDuration: 0.12), .moveTo(y: point.y, duration: 0.18)]))
                swapBoxes.append(box)
            } else {
                swapRemoved += 1
                // 내가기 일거리가 시작된 뒤 자동 운반이 뺀 상자는 그 일거리의 나르기로 친다.
                if unloadLeft > 0 { unloadLeft -= 1; unloadCarried += 1 } else { autoRemovals.append(clock) }
                if let box = swapBoxes.popLast() {
                    box.run(.sequence([.group([.fadeOut(withDuration: 0.2), .moveBy(x: -6, y: 5, duration: 0.2)]), .removeFromParent()]))
                }
            }
        case .disk:
            refresh(.disk)
            let index = adding ? now : now - 1
            let shelf = min(Self.shelfXs.count - 1, index / 12)
            Effects.burst(in: self, at: CGPoint(x: Self.shelfXs[shelf] + 15, y: floorLine + 8), color: PixelColor(0xD9D2C2), count: 3, spread: 5, rise: 5, duration: 0.4)
        }
    }

    private func walk(from start: CGFloat, to x: CGFloat, carrying: Bool) -> SKAction {
        let right = x >= start
        let frames = (0..<4).map { texture(carrying ? .carry($0) : .walk($0)) }
        return .sequence([
            .run { [weak self] in
                guard let self else { return }
                self.porter.xScale = right ? 1 : -1
                self.porter.run(.repeatForever(.animate(with: frames, timePerFrame: 0.12, resize: true, restore: false)), withKey: "anim")
            },
            .moveTo(x: x, duration: TimeInterval(max(0.05, abs(x - start) / Self.speed))),
            .run { [weak self] in self?.stand(carrying: carrying, right: right) }
        ])
    }

    /// 수레와 함께 걷기: 수레는 늘 짐꾼 오른쪽 16px. 오른쪽(더미 쪽)으로는 밀고, 왼쪽(엘리베이터 쪽)으로는 끈다.
    private func cartWalk(from start: CGFloat, to x: CGFloat) -> SKAction {
        let right = x >= start
        let frames = (0..<4).map { texture(right ? .push($0) : .walk($0)) }
        let duration = TimeInterval(max(0.05, abs(x - start) / Self.speed))
        return .sequence([
            .run { [weak self] in
                guard let self else { return }
                self.porter.xScale = right ? 1 : -1
                self.porter.run(.repeatForever(.animate(with: frames, timePerFrame: 0.12, resize: true, restore: false)), withKey: "anim")
                self.cart.run(.moveTo(x: x + Self.cartOffset, duration: duration), withKey: "roll")
            },
            .moveTo(x: x, duration: duration),
            .run { [weak self] in self?.stand(carrying: false, right: right) }
        ])
    }

    private func stand(carrying: Bool, right: Bool) {
        porter.removeAction(forKey: "anim")
        let texture = texture(carrying ? .carry(1) : .stand(blink: false))
        porter.texture = texture
        porter.size = texture.size()
        porter.xScale = right ? 1 : -1
    }

    /// 일할 자리: 스왑은 상자 더미 왼쪽, 디스크는 그 칸이 있는 선반 왼쪽.
    private func workX(_ stock: Stock, slot: Int) -> CGFloat {
        switch stock {
        case .swap: return Self.stackX - 9
        case .disk: return Self.shelfXs[min(Self.shelfXs.count - 1, max(0, slot) / 12)] - 9
        }
    }

    private func boxPoint(_ index: Int) -> CGPoint {
        CGPoint(x: Self.stackX + CGFloat(index % 8) * 10, y: floorLine + CGFloat(index / 8) * 8)
    }

    private func makeBox(_ index: Int) -> SKSpriteNode {
        let node = SKSpriteNode(texture: TextureCache.shared.texture("box\(index % 2)") { Furniture.box(index % 2) })
        node.anchorPoint = .zero
        node.position = boxPoint(index)
        addChild(node)
        return node
    }

    /// 보이는 칸 수에 맞춰 그림을 맞춘다(연출 없이).
    private func refresh(_ stock: Stock) {
        let count = shown[stock] ?? 0
        switch stock {
        case .swap:
            while swapBoxes.count > count { swapBoxes.removeLast().removeFromParent() }
            while swapBoxes.count < count { swapBoxes.append(makeBox(swapBoxes.count)) }
            for (index, box) in swapBoxes.enumerated() {
                box.removeAllActions()
                box.alpha = 1
                box.position = boxPoint(index)
            }
        case .disk:
            // 선반 상자: 칸 수만큼, 꼬리표별 색으로(DiskShelves가 나눈다).
            diskShelves.show(count: count, used: diskUsedBytes)
        }
    }

    /// 검수용: 짐꾼이 보이는지 · 수레에 실린 상자 수.
    var porterVisible: Bool { !porter.isHidden && porter.alpha > 0.01 }
    var cartLoad: Int { cart.isHidden ? 0 : cartBoxes.count }
}

extension Lines {
    /// 메모리 최적화 뒤 실측한 비운 스왑이 0일 때 짐꾼이 창고를 둘러보고 하는 말: 스왑은 그 페이지를 쓰던 앱이 끝나야 줄어든다(ReMON이 직접 줄일 수 없다).
    static let swapOwnerEnds = ["스왑은 쓰던 앱이 끝나야 줄어요", "주인 앱이 끝나야 상자가 나가요", "제가 뺄 순 없어요 · 앱이 끝나야 줄어요"]
}

/// 도구(앱) 기계. 크기 네 단(메모리 순위 · 커짐), 화면에 앱 아이콘, 앞면 팬, 위 경광등, 표시등(CPU), 칸 콘센트에 꽂힌 전원선.
/// 폭주(CPU 80% 이상): 몸체가 떨리고 팬이 미친 듯이 돌고 경광등이 돌며 김이 난다 — CPU가 20% 밑으로 내려올 때까지(그 사이는 그대로).
/// 전원을 내리면(앱 종료) 화면 · 표시등 · 팬이 꺼지고, 설치 기사가 전원선을 뽑아 반입구로 내간다.
/// 노드 전체가 사람(z 4~6)보다 뒤(3)라 화면 · 경광등 · 표시등도 몸통 바로 위(+0.3 안쪽)에만 둔다
/// (예전: 화면이 몸통 + 1이라 사람과 같은 높이가 되어 아이콘이 사람 앞에 떴다 — 10-25 대표 지적).
final class ToolMachineNode: SKNode {
    let id: String
    /// 떨림을 받는 몸체 묶음(몸통 · 화면 · 팬 · 경광등 · 표시등). 전원선은 콘센트에 꽂혀 있어 함께 떨지 않는다.
    private let chassis = SKNode()
    private let body = SKSpriteNode()
    private let screen = SKSpriteNode()
    private let fan = SKSpriteNode()
    private let beacon = SKSpriteNode()
    private let glow = SKSpriteNode()
    private let led = SKSpriteNode(color: .systemGreen, size: CGSize(width: 2, height: 2))
    private let cable = SKSpriteNode()
    private(set) var size = 1
    /// 폭주 중(CPU 80% 이상에서 시작, 20% 밑으로 내려올 때까지).
    private(set) var bursting = false
    private(set) var powered = true
    private(set) var plugged = true
    /// 반입구로 들어와 볼트를 조여야(설치 끝) true. 배송 중에는 상자 속이라 숨겨 둔다(누르기 · 이름표 · 폭주 줌 없음).
    var installed = true
    /// 앱 짧은 이름(기사 말풍선 · 검수 기록용).
    var title = ""
    private var iconImage: NSImage?
    private var iconKey = ""
    private(set) var cpu: Double = 0

    init(id: String) {
        self.id = id
        super.init()
        addChild(chassis)
        body.anchorPoint = CGPoint(x: 0.5, y: 0)
        chassis.addChild(body)
        for part in [screen, fan, beacon] {
            part.anchorPoint = CGPoint(x: 0.5, y: 0)
            part.zPosition = 0.2
            chassis.addChild(part)
        }
        glow.texture = TextureCache.shared.texture("tool-beacon-glow") { MachineArt.beaconGlow() }
        glow.size = CGSize(width: 22, height: 9)
        glow.anchorPoint = CGPoint(x: 0, y: 0.5)
        glow.zPosition = 0.3
        glow.isHidden = true
        chassis.addChild(glow)
        led.anchorPoint = .zero
        led.zPosition = 0.3
        chassis.addChild(led)
        cable.anchorPoint = .zero
        cable.zPosition = -0.1
        addChild(cable)
        beacon.texture = Self.beaconFrame(0)
        beacon.size = CGSize(width: 5, height: 4)
        setSize(1)
    }

    required init?(coder: NSCoder) { fatalError() }

    var width: CGFloat { CGFloat(MachineArt.cabinetSizes[size].w) }
    var height: CGFloat { CGFloat(MachineArt.cabinetSizes[size].h) }
    /// 검수용: 팬 회전 속도(0 = 멈춤) · 경광등이 도는 중인가 · 몸체가 떨리는 중인가.
    var fanSpeed: CGFloat { fan.action(forKey: "spin")?.speed ?? 0 }
    var beaconSpinning: Bool { beacon.action(forKey: "spin") != nil }
    var shaking: Bool { chassis.action(forKey: "shake") != nil }

    private static func beaconFrame(_ frame: Int) -> SKTexture { TextureCache.shared.texture("tool-beacon\(frame)") { MachineArt.beacon(frame) } }

    /// 크기를 바꾼다(아래 가운데가 바닥에 붙은 채로 위 · 옆으로 커진다).
    func setSize(_ value: Int) {
        size = max(0, min(3, value))
        let size = self.size
        let (w, h) = MachineArt.cabinetSizes[size]
        body.texture = TextureCache.shared.texture("cabinet\(size)") { MachineArt.cabinet(size) }
        body.size = CGSize(width: w, height: h)
        let s = MachineArt.screenRect(size)
        screen.size = CGSize(width: s.w, height: s.h)
        screen.position = CGPoint(x: CGFloat(s.x) + CGFloat(s.w) / 2 - CGFloat(w) / 2, y: CGFloat(h - s.y - s.h))
        let f = MachineArt.fanRect(size)
        let frames = (0..<4).map { frame in TextureCache.shared.texture("tool-fan\(f.s)-\(frame)") { MachineArt.cabinetFan(f.s, frame: frame) } }
        let speed = fan.action(forKey: "spin")?.speed ?? 0
        fan.removeAction(forKey: "spin")
        fan.texture = frames[0]
        fan.size = CGSize(width: f.s, height: f.s)
        fan.position = CGPoint(x: CGFloat(f.x) + CGFloat(f.s) / 2 - CGFloat(w) / 2, y: CGFloat(h - f.y - f.s))
        fan.run(.repeatForever(.animate(with: frames, timePerFrame: 0.08)), withKey: "spin")
        fan.action(forKey: "spin")?.speed = speed
        beacon.position = CGPoint(x: 0, y: CGFloat(h))
        glow.position = CGPoint(x: 1, y: CGFloat(h) + 2)
        led.position = CGPoint(x: CGFloat(w) / 2 - 4, y: CGFloat(h) - 3)
        // 전원선: 기계 오른쪽 옆에서 칸 오른쪽 기둥의 콘센트(칸 가운데에서 +socketDX, 바닥 위 +8)까지.
        let gap = Int(ToolRoom.socketDX) - w / 2
        cable.texture = TextureCache.shared.texture("tool-cable\(gap)") { MachineArt.cable(gap: gap) }
        cable.size = CGSize(width: max(3, gap), height: 8)
        cable.position = CGPoint(x: CGFloat(w / 2), y: 1)
        refreshScreen()
    }

    /// 앱 아이콘(없으면 파란 빈 화면). 크기마다 화면 크기에 맞춘 픽셀 아이콘을 만든다.
    func setIcon(_ image: NSImage?, key: String) {
        guard image !== iconImage || key != iconKey else { return }
        iconImage = image
        iconKey = key
        refreshScreen()
    }

    private func refreshScreen() {
        guard powered else {
            screen.texture = nil
            screen.color = NSColor(srgbRed: 0.07, green: 0.09, blue: 0.13, alpha: 1)
            screen.colorBlendFactor = 1
            return
        }
        let texture = Self.iconTexture(iconImage, key: iconKey, size: size)
        screen.texture = texture
        screen.color = texture == nil ? NSColor(srgbRed: 0.2, green: 0.3, blue: 0.45, alpha: 1) : .white
        screen.colorBlendFactor = texture == nil ? 1 : 0
    }

    /// CPU → 표시등 색 · 팬 속도 · 폭주. 돌려주는 값: 이번에 폭주가 시작됐는가(장면이 카메라를 부른다).
    @discardableResult
    func setActivity(cpu: Double) -> Bool {
        self.cpu = cpu
        guard powered else { return false }
        led.removeAllActions()
        led.alpha = 1
        led.color = cpu >= 80 ? .systemRed : cpu >= 20 ? .systemOrange : .systemGreen
        if cpu >= 20 { led.run(.repeatForever(.sequence([.fadeAlpha(to: 0.2, duration: 0.15), .fadeAlpha(to: 1, duration: 0.15)]))) }
        var started = false
        if !bursting, cpu >= 80 { startBurst(); started = true } else if bursting, cpu < 20 { stopBurst() }
        fan.action(forKey: "spin")?.speed = bursting ? 6 : cpu < 3 ? 0 : CGFloat(0.6 + cpu / 50)
        return started
    }

    private func startBurst() {
        bursting = true
        chassis.run(.repeatForever(.sequence([.moveBy(x: 1, y: 0, duration: 0.04), .moveBy(x: -2, y: 0, duration: 0.05), .moveBy(x: 1, y: 0, duration: 0.04)])), withKey: "shake")
        beacon.run(.repeatForever(.animate(with: (1...4).map { Self.beaconFrame($0) }, timePerFrame: 0.09)), withKey: "spin")
        glow.isHidden = false
        glow.run(.repeatForever(.sequence([.run { [weak glow] in glow?.xScale *= -1 }, .fadeAlpha(to: 0.9, duration: 0.18), .fadeAlpha(to: 0.2, duration: 0.18)])), withKey: "sweep")
        body.run(.repeatForever(.sequence([.colorize(with: .systemRed, colorBlendFactor: 0.45, duration: 0.3), .colorize(withColorBlendFactor: 0.12, duration: 0.3)])), withKey: "heat")
        run(.repeatForever(.sequence([.wait(forDuration: 0.3), .run { [weak self] in self?.puffSteam() }])), withKey: "steam")
    }

    private func stopBurst() {
        bursting = false
        chassis.removeAction(forKey: "shake")
        chassis.position = .zero
        beacon.removeAction(forKey: "spin")
        beacon.texture = Self.beaconFrame(0)
        glow.removeAllActions()
        glow.isHidden = true
        body.removeAction(forKey: "heat")
        body.colorBlendFactor = 0
        removeAction(forKey: "steam")
    }

    /// 김: 기계 위로 흰 김 세 덩이(기계가 떨려도 김은 제자리에서 오른다 — 부모 좌표에 올린다).
    private func puffSteam() {
        guard let parent, !isHidden else { return }
        let side = CGFloat(Variety.shared.integer(-3...3))
        Effects.burst(in: parent, at: CGPoint(x: position.x + side, y: position.y + height + 3), color: PixelColor(0xF4F4F4, alpha: 230), count: 3, spread: 3, rise: 11, duration: 0.8)
    }

    /// 앱 종료: 화면이 가로줄로 접히며 꺼지고 표시등 · 팬 · 경광등이 멈춘다.
    func powerDown() {
        guard powered else { return }
        stopBurst()
        powered = false
        led.removeAllActions()
        led.alpha = 0
        fan.action(forKey: "spin")?.speed = 0
        screen.run(.sequence([.scaleY(to: 0.15, duration: 0.12), .run { [weak self] in self?.refreshScreen() }, .scaleY(to: 1, duration: 0)]), withKey: "off")
    }

    /// 설치 직후: 화면이 깜박이며 켜진다.
    func powerOn() {
        powered = true
        refreshScreen()
        screen.run(.sequence([.fadeAlpha(to: 0.2, duration: 0.06), .fadeAlpha(to: 1, duration: 0.06), .fadeAlpha(to: 0.3, duration: 0.06), .fadeAlpha(to: 1, duration: 0.1)]), withKey: "on")
        setActivity(cpu: cpu)
    }

    /// 전원선을 뽑는다: 플러그 쪽이 떨어지며 사라진다.
    func unplug() {
        guard plugged else { return }
        plugged = false
        cable.run(.sequence([.group([.moveBy(x: 0, y: -3, duration: 0.25), .rotate(byAngle: -0.5, duration: 0.25), .fadeOut(withDuration: 0.35)]), .hide()]), withKey: "unplug")
    }

    /// 콘센트 자리(부모 좌표): 칸 오른쪽 기둥, 바닥 위 8px.
    var socketPoint: CGPoint { CGPoint(x: position.x + ToolRoom.socketDX, y: position.y + 8) }

    /// 이미 가장 큰데 또 커졌을 때: 잠깐 부풀었다 돌아온다(커짐이 보이게).
    func bulge() {
        chassis.run(.sequence([.scale(to: 1.12, duration: 0.12), .scale(to: 1, duration: 0.18)]), withKey: "bulge")
    }

    /// 앱 아이콘을 화면 크기에 맞춘 픽셀 텍스처로(가운데 정사각 아이콘 + 어두운 바탕, nearest).
    static func iconTexture(_ image: NSImage?, key: String, size: Int) -> SKTexture? {
        guard let image else { return nil }
        let s = MachineArt.screenRect(size)
        return TextureCache.shared.texture("tool-icon-\(key)-\(size)") {
            var canvas = PixelCanvas(s.w, s.h)
            canvas.rect(0, 0, s.w, s.h, PixelColor(0x111827))
            let side = min(s.w, s.h)
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return canvas }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
            let left = (s.w - side) / 2, top = (s.h - side) / 2
            for y in 0..<side { for x in 0..<side {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.3 else { continue }
                canvas.dot(left + x, top + y, PixelColor(r: UInt8(color.redComponent * 255), g: UInt8(color.greenComponent * 255), b: UInt8(color.blueComponent * 255)))
            } }
            return canvas
        }
    }
}
