import AppKit
import ReMONCore
import SpriteKit

// 옥상 웰니스 풀(10-25 대표 지시 '겨울되면 풀장에서 김 나야 한다 · 온수풀 · 저녁이면 조명도 들어오고 · 가끔 DJ 파티도 하고').
// · 겨울: 온수풀 수면에서 김이 쉬지 않고 피어오른다(새벽 · 깊은 밤에 더 짙게). 풀에서 쉬는 직원은 가끔 '따뜻해~'.
// · 노을 ~ 깊은 밤: 수중등(청록 · 호박색, 천천히 숨 쉬듯) · 루프톱 선베드 위 줄전구 · 어두워진 물빛과 조명이 비친 물결.
//   장면의 조명 재구성(rebuildLights — 시간대가 바뀔 때 · 건물을 다시 지을 때)에서 맞추고, 텍스처는 하늘처럼 캐시한다.
// · DJ 파티: 저녁(19시 ~ 다음 날 5시를 한 저녁으로 친다)마다 한 번쯤. 디제이가 1층 문으로 들어와 엘리베이터로 옥상에 올라
//   풀 가장자리에 부스를 차리고 약 90초 동안 튼다 — 미러볼 · 박자 맞춘 조명 · 음표. 옥상(풀 · 선베드 · 빈백)에서 쉬던 직원만 춤추며 외친다.
//   일하는 직원은 책상을 떠나지 않는다. 끝나면 장비를 접고 엘리베이터로 내려가 문으로 나간다. 일정은 공용 난수(Variety)라 장면 시험에서 재현된다.

/// 풀 조명 · 김 · 파티 무대 픽셀.
enum PoolArt {
    static let cyan = PixelColor(0x5CF2FF)
    static let warm = PixelColor(0xFFC46B)
    /// 무대 조명 색(박자마다 돌아가며).
    static let partyColors: [PixelColor] = [PixelColor(0xFF4FD8), PixelColor(0x4FF0FF), PixelColor(0xFFE45C), PixelColor(0x6BFF7A), PixelColor(0x8F7BFF)]

    /// 김 한 덩이(0 = 막 피어난 짙은 김 → 3 = 흩어지는 끝자락): 피어오르며 큰 그림으로 바꿔 단다. 큰 그림일수록 체크무늬 구멍이 많아
    /// 저절로 성글어진다 — 전체를 반투명하게 흐리면 밤하늘 위에서 회색 먼지처럼 보여서(장면 시험 캡처로 확인), 흰색은 그대로 두고 구멍으로 옅게 한다.
    static func steamPuff(_ stage: Int) -> PixelCanvas {
        let stage = min(3, max(0, stage))
        let (w, h) = [(5, 4), (7, 5), (9, 7), (11, 8)][stage]
        var c = PixelCanvas(w, h)
        for y in 0..<h { for x in 0..<w {
            let dx = (Double(x) + 0.5 - Double(w) / 2) / (Double(w) / 2), dy = (Double(y) + 0.5 - Double(h) / 2) / (Double(h) / 2)
            let d = dx * dx + dy * dy
            guard d <= 1 else { continue }
            let hole: Bool
            switch stage {
            case 0: hole = false
            case 1: hole = d > 0.55 && (x + y) % 2 == 1
            case 2: hole = (d > 0.4 && (x + y) % 2 == 1) || (d <= 0.4 && (x * 3 + y) % 5 == 0)
            default: hole = (x + y) % 2 == 1 || (d > 0.6 && (x + 2 * y) % 3 == 0)
            }
            guard !hole else { continue }
            c.dot(x, y, PixelColor(0xFFFFFF, alpha: UInt8(max(60, [240, 220, 195, 160][stage] - Int(d * 50)))))
        } }
        return c
    }

    /// 수면 위에 깔린 얇은 김 띠(256×4, 2프레임): 자리마다 1~3줄 높이로 들쭉날쭉, 위로 갈수록 성기다. 프레임을 번갈아 일렁인다.
    static func steamHaze(_ frame: Int) -> PixelCanvas {
        var c = PixelCanvas(256, 4)
        for x in 0..<256 {
            let height = 1 + FloorPainter.hash(x / 5 + frame * 7, 3, 113) % 3
            for k in 0..<height where k == 0 || (x + k + frame) % 2 == 0 {
                c.dot(x, 3 - k, PixelColor(0xFFFFFF, alpha: UInt8([170, 120, 80][k])))
            }
        }
        return c
    }

    /// 수중등 빛(32×12, 아래 가운데가 등 — 위로 퍼지며 흐려진다. 더하기 혼합으로 물 · 수면 위를 밝힌다).
    static func underwaterGlow(_ color: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(32, 12)
        for y in 0..<12 { for x in 0..<32 {
            let dx = (Double(x) - 15.5) / 16, dy = Double(11 - y) / 12
            let d = dx * dx + dy * dy
            guard d < 1 else { continue }
            if d > 0.42 && (x + y) % 2 == 1 { continue }
            c.dot(x, y, color.with(alpha: UInt8(max(0, (1 - d) * (y >= 7 ? 170 : 120)))))
        } }
        return c
    }

    /// 수중등 몸체(풀 벽에 박힌 3×2): 가운데 흰 심 + 색.
    static func underwaterLamp(_ color: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(3, 2)
        c.dot(0, 0, color); c.dot(1, 0, Pal.white); c.dot(2, 0, color)
        c.hline(0, 1, 3, color.darker(0.25))
        return c
    }

    /// 조명이 비친 물결(256×3, 2프레임): 낮 물결과 같은 자리 · 무늬에 청록 · 가끔 호박색.
    static func litShimmer(_ frame: Int) -> PixelCanvas {
        var c = PixelCanvas(256, 3)
        for x in stride(from: (frame * 4) % 7, to: 256, by: 7) {
            let warmth = ((x / 7) + frame) % 5 == 0
            c.hline(x, frame % 2, 3, (warmth ? warm : cyan).with(alpha: 205))
            c.dot(x + 1, 2 - frame % 2, Pal.white.with(alpha: 150))
        }
        return c
    }

    /// 줄전구: 캐노피 기둥(pitch 간격) 사이로 처지는 전선과 8px마다 전구. 평소엔 호박색 · 크림, 파티 중엔 다섯 색.
    static func stringLights(spans: Int, pitch: Int, party: Bool) -> PixelCanvas {
        let width = spans * pitch + 1
        var c = PixelCanvas(width, 9)
        let wire = PixelColor(0x2A2A30)
        func sag(_ x: Int) -> Int { Int((4 * sin(Double(x % pitch) / Double(pitch) * .pi)).rounded()) }
        for x in 0..<width { c.dot(x, 1 + sag(x), wire) }
        for x in stride(from: 4, to: width - 1, by: 8) {
            let s = sag(x), index = x / 8
            let color = party ? partyColors[index % partyColors.count] : (index % 2 == 0 ? PixelColor(0xFFC861) : PixelColor(0xFFF1C9))
            c.dot(x, 2 + s, wire)                                 // 소켓
            c.rect(x, 3 + s, 2, 2, color)
            c.dot(x, 3 + s, color.lighter(0.45))                  // 반사광
        }
        return c
    }

    /// 줄전구 둘레 빛(전구마다 작은 원, 더하기 혼합). 줄전구 그림보다 사방 2px 크다.
    static func stringHalo(spans: Int, pitch: Int) -> PixelCanvas {
        let width = spans * pitch + 1
        var c = PixelCanvas(width + 4, 13)
        func sag(_ x: Int) -> Int { Int((4 * sin(Double(x % pitch) / Double(pitch) * .pi)).rounded()) }
        for x in stride(from: 4, to: width - 1, by: 8) {
            let cx = Double(x + 2) + 1, cy = Double(3 + sag(x) + 2) + 1
            for y in 0..<13 { for xx in max(0, x - 2)..<min(width + 4, x + 7) {
                let dx = Double(xx) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let d = (dx * dx + dy * dy).squareRoot()
                guard d <= 3.6, (xx + y) % 2 == 0 || d < 2 else { continue }
                c.dot(xx, y, PixelColor(0xFFD98A, alpha: UInt8(max(0, 110 - d * 26))))
            } }
        }
        return c
    }

    /// DJ 부스(28×12, 3프레임): 노트북 화면 · 턴테이블 두 대 · 믹서 → 데크 윗면(바닥에서 7px) → 앞판(네온 띠 · 박자에 울렁이는 스피커 두 개 · 가운데 이퀄라이저).
    static func booth(_ frame: Int) -> PixelCanvas {
        var c = PixelCanvas(28, 12)
        let o = Pal.outline, f = frame % 3
        c.box(12, 0, 5, 3, fill: [PixelColor(0x9FE3FF), PixelColor(0xF7A8FF), PixelColor(0xB8FFC8)][f], outline: Pal.metal, rounded: false)   // 노트북 화면
        for x0 in [2, 19] {
            c.rect(x0, 2, 7, 2, PixelColor(0x1C1A1E)); c.hline(x0 + 1, 2, 5, PixelColor(0x3A3A44))
            c.dot(x0 + 2 + f, 2, [Pal.alarm, Pal.badge, PixelColor(0x6BCB77)][f])                     // 도는 판 라벨
        }
        c.rect(11, 3, 7, 1, Pal.metal); c.hline(12, 3, 5, Pal.metalLight)                             // 믹서 · 노트북 받침
        c.hline(0, 4, 28, PixelColor(0xB8BCC6))                                                        // 데크 윗면
        c.box(0, 5, 28, 7, fill: PixelColor(0x22232B), outline: o, rounded: false)
        c.hline(1, 6, 26, partyColors[f])                                                              // 네온 띠
        for x0 in [3, 21] {
            c.rect(x0, 7, 4, 4, PixelColor(0x30323F))
            if f == 1 { c.rect(x0, 7, 4, 4, PixelColor(0x4A4E62)); c.rect(x0 + 1, 8, 2, 2, PixelColor(0x7A7E96)) } else { c.rect(x0 + 1, 8, 2, 2, PixelColor(0x4A4E62)) }
        }
        let heights = [[2, 4, 3, 1, 3], [4, 2, 4, 3, 1], [1, 3, 2, 4, 2]][f]
        for (i, height) in heights.enumerated() {
            for k in 0..<height { c.dot(9 + i * 2, 10 - k, k >= 3 ? Pal.alarm : k >= 2 ? Pal.badge : PixelColor(0x6BCB77)) }
        }
        return c
    }

    /// 미러볼(7×8, 3프레임): 위 고리 + 면이 돌며 반짝인다.
    static func discoBall(_ frame: Int) -> PixelCanvas {
        var c = PixelCanvas(7, 8)
        c.dot(3, 0, Pal.metal)
        let tones = [PixelColor(0xDDE3EA), PixelColor(0x9AA3AF), PixelColor(0xF7FAFF)]
        for y in 0..<7 { for x in 0..<7 {
            let dx = Double(x) - 3, dy = Double(y) - 3
            guard dx * dx + dy * dy <= 10.5 else { continue }
            c.dot(x, y + 1, tones[(x + y * 2 + frame) % 3])
        } }
        let spark = [(1, 2), (4, 3), (2, 5)][frame % 3]
        c.dot(spark.0, spark.1 + 1, Pal.white)
        return c
    }

    /// 바닥에 비친 무대 조명(26×5 타원, 더하기 혼합).
    static func spot(_ color: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(26, 5)
        for y in 0..<5 { for x in 0..<26 {
            let dx = (Double(x) - 12.5) / 13, dy = (Double(y) - 2) / 2.5
            let d = dx * dx + dy * dy
            guard d <= 1, d < 0.5 || (x + y) % 2 == 0 else { continue }
            c.dot(x, y, color.with(alpha: UInt8(60 + (1 - d) * 120)))
        } }
        return c
    }

    /// 미러볼 반사 점(3×3 십자).
    static func glint(_ color: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(3, 3)
        c.dot(1, 0, color.with(alpha: 170)); c.dot(0, 1, color.with(alpha: 170)); c.dot(2, 1, color.with(alpha: 170)); c.dot(1, 2, color.with(alpha: 170))
        c.dot(1, 1, Pal.white)
        return c
    }

    /// 음표(0 = ♪ 5×6 · 1 = ♫ 7×6).
    static func note(_ variant: Int, _ color: PixelColor) -> PixelCanvas {
        if variant % 2 == 0 {
            var c = PixelCanvas(5, 6)
            c.rect(0, 4, 3, 2, color); c.vline(2, 0, 5, color); c.dot(3, 1, color); c.dot(4, 2, color)
            return c
        }
        var c = PixelCanvas(7, 6)
        c.rect(0, 4, 2, 2, color); c.rect(4, 4, 2, 2, color)
        c.vline(1, 0, 4, color); c.vline(5, 0, 4, color); c.hline(1, 0, 5, color)
        return c
    }
}

/// 김 발생기(겨울 온수풀): 수면에 얇은 김 띠를 깔고, 미리 만든 퍼프 몇 개를 돌려 쓰며 피워 올린다 — 수면에서 짙게 피어나
/// 흔들리며 올라가고, 큰 그림(구멍 많은 그림)으로 바뀌며 성글어진 뒤 사라진다. 파티클 파일(SKEmitterNode) 없이 작은 스프라이트만 쓴다.
/// 짙기(0~1)가 피우는 간격을 정한다(1 = 0.17초마다, 0 = 그친다 — 떠 있던 김은 마저 사라지고 띠도 걷힌다).
/// 자리 · 크기는 자기 난수(씨앗 고정)로 고른다 — 장면 시험의 공용 난수(Variety)를 흐트러뜨리지 않는다.
final class SteamEmitter: SKNode {
    let width: CGFloat
    private var puffs: [SKSpriteNode] = []
    private let haze = SKSpriteNode()
    private var cursor = 0
    private var random = Variety.Generator(state: 0x51EA_7E57)
    private(set) var density: Double = 0
    /// 김 색조(깊은 밤엔 수중등 빛이 비친 옅은 청록).
    var tint: (color: NSColor, factor: CGFloat) = (.white, 0) {
        didSet { haze.color = tint.color; haze.colorBlendFactor = tint.factor }
    }

    /// width = 김이 피는 폭(풀 물 폭에서 양끝 4px씩 뺀 값). 띠는 물 폭 전체에 깐다.
    init(width: CGFloat, capacity: Int = 20) {
        self.width = width
        super.init()
        let hazeFrames = (0..<2).map { frame in TextureCache.shared.texture("steam-haze\(frame)") { PoolArt.steamHaze(frame) } }
        haze.texture = hazeFrames[0]
        haze.size = hazeFrames[0].size()
        haze.anchorPoint = .zero
        haze.position = CGPoint(x: -4, y: 0)
        haze.alpha = 0
        haze.run(.repeatForever(.animate(with: hazeFrames, timePerFrame: 0.9)))
        addChild(haze)
        puffs = (0..<capacity).map { _ in
            let node = SKSpriteNode(texture: Self.frames[0])
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            node.alpha = 0
            node.isHidden = true
            addChild(node)
            return node
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private static var frames: [SKTexture] { (0..<4).map { stage in TextureCache.shared.texture("steam-puff\(stage)") { PoolArt.steamPuff(stage) } } }

    func setDensity(_ value: Double) {
        let value = max(0, min(1, value))
        guard abs(value - density) > 0.001 else { return }
        density = value
        removeAction(forKey: "emit")
        haze.removeAction(forKey: "breathe")
        guard value > 0 else { haze.run(.fadeOut(withDuration: 1.5), withKey: "breathe"); return }
        // 띠: 짙기만큼 깔리고 천천히 숨 쉬듯 짙어졌다 옅어진다
        let full = CGFloat(0.45 + 0.55 * value)
        let thick = SKAction.fadeAlpha(to: full, duration: 1.8), thin = SKAction.fadeAlpha(to: full * 0.6, duration: 1.8)
        thick.timingMode = .easeInEaseOut; thin.timingMode = .easeInEaseOut
        haze.run(.sequence([.fadeAlpha(to: full, duration: 1.0), .repeatForever(.sequence([thin, thick]))]), withKey: "breathe")
        run(.repeatForever(.sequence([.run { [weak self] in self?.emit() }, .wait(forDuration: 0.17 / value)])), withKey: "emit")
    }

    private func roll(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &random) }

    private func emit() {
        let puff = puffs[cursor]
        cursor = (cursor + 1) % puffs.count
        puff.removeAllActions()
        let life = roll(2.3...3.1), rise = CGFloat(roll(10...18)), drift = CGFloat(roll(-5...5))
        let frames = Self.frames
        puff.texture = frames[0]
        puff.size = frames[0].size()
        puff.position = CGPoint(x: CGFloat(roll(2...Double(max(3, width - 2)))), y: CGFloat(roll(0...1)))
        puff.alpha = 0
        puff.isHidden = false
        puff.color = tint.color
        puff.colorBlendFactor = tint.factor
        let rising = SKAction.moveBy(x: 0, y: rise, duration: life)
        rising.timingMode = .easeOut
        puff.run(.sequence([
            .group([
                rising,
                .sequence([.moveBy(x: drift, y: 0, duration: life * 0.55), .moveBy(x: -drift * 0.6, y: 0, duration: life * 0.45)]),   // 흔들흔들
                .animate(with: frames, timePerFrame: life / 4, resize: true, restore: false),
                .sequence([.fadeAlpha(to: CGFloat(roll(0.85...1)), duration: life * 0.12), .wait(forDuration: life * 0.2), .fadeOut(withDuration: life * 0.68)])
            ]),
            .hide()
        ]))
    }

    /// 지금 보이는 퍼프 수(검수용).
    var visibleCount: Int { puffs.filter { !$0.isHidden && $0.alpha > 0.02 }.count }
}

/// DJ 파티 시간 · 확률.
enum PartyTiming {
    /// 일정 확인 간격(장면이 실제로 돈 시간).
    static let checkEvery: TimeInterval = 10
    /// 그 저녁에 파티가 있을 확률 · 저녁 시작(19시) 뒤 열 수 있게 되는 때의 범위 · 열 수 있게 된 뒤 확인마다 시작할 확률.
    static let eveningChance = 0.9
    static let window: TimeInterval = 2 * 3600
    static let startChance = 0.3
    static let setupSeconds: TimeInterval = 2.6
    static let playSeconds: TimeInterval = 90
    static let packSeconds: TimeInterval = 2.0
    /// 한 박자(120BPM).
    static let beat: TimeInterval = 0.5
}

/// 옥상 풀 데크(장면 노드, 옥상 바닥선에 붙는다 — 자식 좌표 x = 건물 x, y = 옥상 바닥선에서 위로 잰 높이):
/// 조명(어두운 물빛 · 수중등 · 줄전구) · 김 · DJ 파티 무대(부스 · 미러볼 · 바닥 조명 · 반사 점 · 음표). 층이 늘거나 줄면 place로 따라간다.
/// 자리(가상 px, FloorPainter.roof와 같다): 물 340~596(바닥선 위 5px) · 루프톱 캐노피 기둥 30~310(40px 간격) · 돛 캐노피 아랫단(404에서 바닥선 위 54).
final class PoolDeck: SKNode {
    static let poolX0: CGFloat = 340
    static let poolWidth: CGFloat = 256
    static let water: CGFloat = 5
    static let lampXs: [CGFloat] = [366, 417, 468, 519, 570]
    /// 부스: 빈백(272~300)과 물(340) 사이 · 디제이는 부스 뒤 가운데에 선다.
    static let boothX: CGFloat = 305
    static let boothWidth: CGFloat = 28
    static var djX: CGFloat { boothX + boothWidth / 2 }
    /// 미러볼: 기둥(376 · 426) 사이, 돛 캐노피에 매단다('웰니스 풀' 이름표 자리 470은 비운다).
    static let discoX: CGFloat = 404
    static let sailBottom: CGFloat = 54
    static let discoDrop: CGFloat = 13
    static let strandX0: CGFloat = 30
    static let strandSpans = 7
    static let strandPitch = 40
    static let strandTop: CGFloat = 50
    /// 바닥 조명이 서는 자리(박자마다 정해진 무늬로 돈다) · 미러볼 반사 점 자리.
    static let spotXs: [CGFloat] = [352, 384, 416, 448, 480, 512, 544, 576, 286, 246, 206, 166]
    static let glintPoints: [CGPoint] = [CGPoint(x: 352, y: 30), CGPoint(x: 372, y: 18), CGPoint(x: 390, y: 34), CGPoint(x: 418, y: 24), CGPoint(x: 436, y: 37),
                                         CGPoint(x: 452, y: 14), CGPoint(x: 490, y: 30), CGPoint(x: 512, y: 20), CGPoint(x: 534, y: 35), CGPoint(x: 556, y: 16),
                                         CGPoint(x: 300, y: 28), CGPoint(x: 336, y: 40), CGPoint(x: 268, y: 36), CGPoint(x: 230, y: 22)]

    let steam: SteamEmitter
    private let lights = SKNode()
    private var lamps = 0
    private var strand: SKSpriteNode?
    private var signature = ""
    private(set) var part: Daypart = .noon
    private(set) var season: Season = .autumn
    private var partyColors = false
    // 무대
    private let stage = SKNode()
    private let booth = SKSpriteNode()
    private let cord = SKSpriteNode(color: PixelColor(0x9AA3AF).nsColor, size: CGSize(width: 1, height: 0))
    private let ball = SKSpriteNode()
    private var spots: [SKSpriteNode] = []
    private var glints: [SKSpriteNode] = []
    private(set) var beats = 0
    private(set) var musicOn = false

    override init() {
        steam = SteamEmitter(width: Self.poolWidth - 8)
        super.init()
        steam.position = CGPoint(x: Self.poolX0 + 4, y: Self.water - 1)
        steam.zPosition = 5.5   // 헤엄치는 직원(5) 앞 · 스태프(7) 뒤
        addChild(steam)
        addChild(lights)
        stage.isHidden = true
        addChild(stage)
        booth.anchorPoint = .zero
        booth.position = CGPoint(x: Self.boothX, y: 0)
        booth.zPosition = 7.5   // 디제이(7) 앞 — 디제이는 부스 뒤에서 상반신만 보인다
        stage.addChild(booth)
        cord.anchorPoint = CGPoint(x: 0.5, y: 1)
        cord.position = CGPoint(x: Self.discoX, y: Self.sailBottom)
        cord.zPosition = 5.9
        stage.addChild(cord)
        ball.anchorPoint = CGPoint(x: 0.5, y: 1)
        ball.zPosition = 6
        stage.addChild(ball)
        spots = (0..<3).map { _ in
            let node = SKSpriteNode()
            node.blendMode = .add
            node.zPosition = 1.3
            node.isHidden = true
            stage.addChild(node)
            return node
        }
        glints = (0..<8).map { index in
            let node = SKSpriteNode(texture: TextureCache.shared.texture("party-glint-\(index % 3)") { PoolArt.glint([Pal.white, PixelColor(0xFFB8F0), PixelColor(0xB8F6FF)][index % 3]) })
            node.blendMode = .add
            node.zPosition = 6.2
            node.isHidden = true
            stage.addChild(node)
            return node
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func place(floorLine: CGFloat) { position = CGPoint(x: 0, y: floorLine) }

    // MARK: 조명 · 김

    /// 시간대 · 계절이 바뀌었을 때만 고친다: 조명은 시간대가 바뀌면 다시 짓고(텍스처는 캐시), 김은 계절 · 시간대로 짙기를 정한다.
    func setAmbience(part: Daypart, season: Season) {
        let key = "\(part.rawValue)-\(season.rawValue)"
        guard key != signature else { return }
        let partChanged = signature.isEmpty || part != self.part
        signature = key
        self.part = part
        self.season = season
        if partChanged { rebuildLights() }
        steam.tint = part.isDark ? (PixelColor(0xD8F7FF).nsColor, 0.35) : (NSColor.white, 0)
        steam.setDensity(season == .winter ? part.steam : 0)
    }

    private func rebuildLights() {
        lights.removeAllChildren()
        strand = nil
        lamps = 0
        let level = CGFloat(part.poolLight)
        guard level > 0 else { return }
        // ① 어두워진 물빛(밤일수록 짙은 남청)
        let tint = SKSpriteNode(color: PixelColor(0x0A2B47).nsColor, size: CGSize(width: Self.poolWidth, height: Self.water))
        tint.anchorPoint = .zero
        tint.position = CGPoint(x: Self.poolX0, y: 0)
        tint.zPosition = 1.0
        tint.alpha = CGFloat([0, 0, 0.2, 0.34, 0.42][part.rawValue])
        tint.name = "water-tint"
        lights.addChild(tint)
        // ② 수중등: 청록 · 호박색 번갈아, 천천히 숨 쉬듯(등마다 박자를 어긋나게)
        for (index, x) in Self.lampXs.enumerated() {
            let color = index % 2 == 0 ? PoolArt.cyan : PoolArt.warm
            let glow = SKSpriteNode(texture: TextureCache.shared.texture("pool-glow-\(index % 2)") { PoolArt.underwaterGlow(color) })
            glow.anchorPoint = CGPoint(x: 0.5, y: 0)
            glow.position = CGPoint(x: x, y: 0)
            glow.zPosition = 1.2
            glow.blendMode = .add
            let low = 0.45 * level, high = level
            glow.alpha = low
            let up = SKAction.fadeAlpha(to: high, duration: 1.7), down = SKAction.fadeAlpha(to: low, duration: 1.7)
            up.timingMode = .easeInEaseOut; down.timingMode = .easeInEaseOut
            glow.run(.sequence([.wait(forDuration: Double(index) * 0.6), .repeatForever(.sequence([up, down]))]))
            lights.addChild(glow)
            let lamp = SKSpriteNode(texture: TextureCache.shared.texture("pool-lamp-\(index % 2)") { PoolArt.underwaterLamp(color) })
            lamp.anchorPoint = CGPoint(x: 0.5, y: 0)
            lamp.position = CGPoint(x: x, y: 0)
            lamp.zPosition = 1.25
            lights.addChild(lamp)
            lamps += 1
        }
        // ③ 루프톱 선베드 위 줄전구(캐노피 기둥 사이로 처진다) + 둘레 빛(느리게 반짝)
        let line = SKSpriteNode(texture: strandTexture(party: partyColors))
        line.anchorPoint = CGPoint(x: 0, y: 1)
        line.position = CGPoint(x: Self.strandX0, y: Self.strandTop)
        line.zPosition = 1.5
        line.alpha = 0.55 + 0.45 * level
        lights.addChild(line)
        strand = line
        let halo = SKSpriteNode(texture: TextureCache.shared.texture("string-halo") { PoolArt.stringHalo(spans: Self.strandSpans, pitch: Self.strandPitch) })
        halo.anchorPoint = CGPoint(x: 0, y: 1)
        halo.position = CGPoint(x: Self.strandX0 - 2, y: Self.strandTop + 2)
        halo.zPosition = 1.45
        halo.blendMode = .add
        halo.alpha = 0.7 * level
        let bright = SKAction.fadeAlpha(to: level, duration: 1.2), dim = SKAction.fadeAlpha(to: 0.55 * level, duration: 1.2)
        bright.timingMode = .easeInEaseOut; dim.timingMode = .easeInEaseOut
        halo.run(.repeatForever(.sequence([bright, dim])))
        lights.addChild(halo)
    }

    private func strandTexture(party: Bool) -> SKTexture {
        TextureCache.shared.texture("string-lights-\(party ? "party" : "warm")") { PoolArt.stringLights(spans: Self.strandSpans, pitch: Self.strandPitch, party: party) }
    }

    // MARK: 무대

    /// 디제이가 부스 자리에 닿았을 때: 부스가 먼지와 함께 서고, 미러볼이 돛 캐노피에서 내려온다.
    func setUpStage() {
        stage.removeAllActions()
        stage.children.filter { $0.name == "note" }.forEach { $0.removeFromParent() }
        stage.isHidden = false
        stage.alpha = 1
        booth.texture = TextureCache.shared.texture("dj-booth-0") { PoolArt.booth(0) }
        booth.size = CGSize(width: Self.boothWidth, height: 12)
        booth.alpha = 0
        booth.run(.fadeIn(withDuration: 0.3))
        Effects.burst(in: self, at: CGPoint(x: Self.djX, y: 3), color: PixelColor(0xE9DFCF), count: 10, spread: 16, rise: 8, duration: 0.6)
        ball.texture = discoTexture(0)
        ball.size = CGSize(width: 7, height: 8)
        ball.alpha = 1
        let drop = Self.discoDrop
        cord.size = CGSize(width: 1, height: 0)
        ball.position = CGPoint(x: Self.discoX, y: Self.sailBottom)
        let lower = SKAction.customAction(withDuration: 1.4) { [weak self] _, elapsed in
            guard let self else { return }
            let length = (drop * CGFloat(elapsed / 1.4)).rounded()
            self.cord.size = CGSize(width: 1, height: length)
            self.ball.position.y = Self.sailBottom - length
        }
        stage.run(lower, withKey: "ball")
    }

    /// 음악 시작: 박자(0.5초)마다 부스 화면 · 판 · 스피커 · 미러볼이 돌고, 바닥 조명 세 개가 자리 · 색을 바꾸고, 반사 점이 반짝이고, 두 박자마다 음표가 오른다.
    /// 무늬는 박자 번호로 정한다(난수 없이 — 장면 시험에서 같은 모습).
    func startMusic() {
        musicOn = true
        beats = 0
        setStrandParty(true)
        stage.run(.repeatForever(.sequence([.run { [weak self] in self?.beat() }, .wait(forDuration: PartyTiming.beat)])), withKey: "beat")
    }

    private func beat() {
        beats += 1
        let b = beats
        booth.texture = TextureCache.shared.texture("dj-booth-\(b % 3)") { PoolArt.booth(b % 3) }
        ball.texture = discoTexture(b % 3)
        for (i, spot) in spots.enumerated() {
            let colorIndex = (b + i * 2) % PoolArt.partyColors.count
            spot.texture = TextureCache.shared.texture("party-spot-\(colorIndex)") { PoolArt.spot(PoolArt.partyColors[colorIndex]) }
            spot.size = CGSize(width: 26, height: 5)
            spot.position = CGPoint(x: Self.spotXs[(b * 3 + i * 5) % Self.spotXs.count], y: 3)
            spot.isHidden = false
            spot.alpha = 0.95
            spot.run(.fadeAlpha(to: 0.3, duration: PartyTiming.beat * 0.9), withKey: "fade")
        }
        for (i, glint) in glints.enumerated() {
            let on = FloorPainter.hash(i, b, 97) % 2 == 0
            glint.isHidden = !on
            guard on else { continue }
            glint.position = Self.glintPoints[(i * 5 + b * 3) % Self.glintPoints.count]
            glint.alpha = 1
            glint.run(.fadeAlpha(to: 0.2, duration: PartyTiming.beat * 0.8), withKey: "fade")
        }
        if b % 2 == 0 { spawnNote(b) }
    }

    private func spawnNote(_ beat: Int) {
        let variant = (beat / 2) % 2
        let colors = [Pal.white, PixelColor(0xFFE45C), PixelColor(0xFF9BE8), PixelColor(0x9BF6FF)]
        let colorIndex = (beat / 2) % colors.count
        let note = SKSpriteNode(texture: TextureCache.shared.texture("party-note-\(variant)-\(colorIndex)") { PoolArt.note(variant, colors[colorIndex]) })
        note.name = "note"
        note.anchorPoint = CGPoint(x: 0.5, y: 0)
        note.position = CGPoint(x: Self.djX + CGFloat([-8, 6, -2, 10][(beat / 2) % 4]), y: 14)
        note.zPosition = 8
        stage.addChild(note)
        let sway = CGFloat([4, -4, 3, -3][(beat / 2) % 4])
        note.run(.sequence([.group([.moveBy(x: sway, y: 16, duration: 1.5), .sequence([.wait(forDuration: 0.7), .fadeOut(withDuration: 0.8)])]), .removeFromParent()]))
    }

    func stopMusic() {
        musicOn = false
        stage.removeAction(forKey: "beat")
        (spots + glints).forEach { $0.removeAllActions(); $0.isHidden = true }
        setStrandParty(false)
    }

    /// 장비 접기: 부스가 흐려지고 미러볼이 돛 캐노피로 올라간다. 끝나면 무대를 숨긴다.
    func packUp() {
        stage.removeAction(forKey: "ball")
        booth.run(.fadeOut(withDuration: 0.6))
        let start = cord.size.height
        let raise = SKAction.customAction(withDuration: 1.2) { [weak self] _, elapsed in
            guard let self else { return }
            let length = (start * (1 - CGFloat(elapsed / 1.2))).rounded()
            self.cord.size = CGSize(width: 1, height: max(0, length))
            self.ball.position.y = Self.sailBottom - max(0, length)
        }
        stage.run(.sequence([raise, .run { [weak self] in self?.ball.alpha = 0 }, .wait(forDuration: 0.2), .run { [weak self] in self?.stage.isHidden = true }]), withKey: "ball")
    }

    /// 연출 없이 바로 치운다(파티 끝 · 안전망).
    func clearStage() {
        stopMusic()
        stage.removeAllActions()
        stage.children.filter { $0.name == "note" }.forEach { $0.removeFromParent() }
        booth.removeAllActions()
        booth.alpha = 0
        cord.size = CGSize(width: 1, height: 0)
        ball.alpha = 0
        stage.isHidden = true
    }

    private func setStrandParty(_ on: Bool) {
        partyColors = on
        strand?.texture = strandTexture(party: on)
    }

    private func discoTexture(_ frame: Int) -> SKTexture { TextureCache.shared.texture("disco-ball-\(frame)") { PoolArt.discoBall(frame) } }

    // MARK: 검수용

    /// 무대(부스)가 보이는가.
    var stageVisible: Bool { !stage.isHidden && booth.alpha > 0.05 }
    /// 미러볼이 매달려 있는가(줄 길이 > 0).
    var ballHanging: Bool { !stage.isHidden && ball.alpha > 0.5 && cord.size.height > 0 }
    /// 켜진 수중등 수 · 줄전구가 켜졌나 · 물빛 어둡기.
    var lampCount: Int { lamps }
    var strandLit: Bool { strand != nil }
    var waterTint: CGFloat { lights.childNode(withName: "water-tint")?.alpha ?? 0 }
    /// 지금 줄전구가 파티 색인가.
    var strandParty: Bool { partyColors && strand != nil }
}

/// DJ 파티 진행 상태(장면이 들고 있다). 단계: 없음 → 올라오는 중 → 무대 설치 → 공연(약 90초) → 정리 → 내려가는 중 → 없음.
struct PartyState {
    enum Phase: String { case idle, arriving, setup, playing, packing, leaving }
    var phase: Phase = .idle
    var phaseSince: TimeInterval = 0
    /// 이번 저녁 계획: 저녁 열쇠 · 이 시각 뒤부터 열 수 있음 · 이 저녁은 쉼 · 이미 열었음.
    var evening = ""
    var earliest = Date.distantFuture
    var skip = false
    var held = false
    var nextCheck: TimeInterval = 0
    var endsAt: TimeInterval = 0
    var nextShout: TimeInterval = 0
    var nextHype: TimeInterval = 0
    var nextWarm: TimeInterval = 0
    /// 검수용: 단계 기록 · 외친 직원 · 온천 대사(직원 · 글자) · 가장 많이 춤춘 수. 상주 앱이라 기록은 최근 것만 남긴다(note).
    var log: [String] = []
    var cheers: [ProcessKey] = []
    var warmLines: [(key: ProcessKey, text: String)] = []
    var maxDancers = 0

    /// 기록 하나 더하기: 최근 limit개만 남긴다(겨울 온천 대사는 창이 열린 내내 몇 초마다 쌓인다).
    static func note<T>(_ item: T, to list: inout [T], limit: Int = 60) {
        list.append(item)
        if list.count > limit { list.removeFirst(list.count - limit) }
    }
}

extension OfficeScene {
    // MARK: 풀 조명 · 김

    /// 조명 재구성(rebuildLights)에서 부른다: 옥상 바닥선을 따라가고 시간대 · 계절에 맞춘다(바뀌었을 때만 실제로 고친다).
    func updatePoolAmbience() {
        poolDeck.place(floorLine: line(layout.roofIndex))
        poolDeck.setAmbience(part: Daypart.of(hour: SceneClock.hour), season: Season.current)
    }

    /// 1초마다(ambientTick): 겨울 온천 대사 · DJ 파티 일정과 진행.
    func poolTick() {
        hotSpringTick()
        switch party.phase {
        case .idle: considerParty()
        case .playing: tendParty()
        default: watchParty()
        }
    }

    /// 겨울: 5~9초마다 풀에서 헤엄치는 직원 한 명이 '따뜻해~'(말풍선이 없는 사람 중에서).
    private func hotSpringTick() {
        guard activeTime >= party.nextWarm, Season.current == .winter else { return }
        party.nextWarm = activeTime + Variety.shared.seconds(5...9)
        let swimmers = workers.values.filter { worker in
            guard !worker.busy, !worker.leaving, worker.route == nil, bubbles[worker.key] == nil, case .rest(let spot) = worker.place else { return false }
            return spot.kind == .swim && spot.floor == layout.roofIndex
        }.sorted { $0.key.pid < $1.key.pid }
        guard let worker = Variety.shared.element(swimmers) else { return }
        let text = Variety.shared.line("hotSpring", Lines.hotSpring)
        say(worker.key, text, seconds: 2.6)
        PartyState.note((worker.key, text), to: &party.warmLines, limit: 40)
    }

    // MARK: DJ 파티 — 일정

    /// 10초마다: 저녁 · 깊은 밤이고, 이번 저녁에 아직 안 열었고, 계획한 때가 지났고, 감사 중이 아니고, 쉬는 직원이 있으면 확률로 시작.
    private func considerParty() {
        guard activeTime >= party.nextCheck else { return }
        party.nextCheck = activeTime + PartyTiming.checkEvery
        let now = SceneClock.now
        guard Daypart.of(hour: Calendar.current.component(.hour, from: now)).isDark else { return }
        let evening = Self.eveningOf(now)
        if party.evening != evening.key {
            party.evening = evening.key
            party.held = false
            party.skip = !Variety.shared.chance(PartyTiming.eveningChance)
            party.earliest = evening.start.addingTimeInterval(Variety.shared.seconds(0...PartyTiming.window))
            PartyState.note("계획 \(evening.key)" + (party.skip ? " · 쉼" : ""), to: &party.log)
        }
        guard !party.held, !party.skip, now >= party.earliest, !auditInProgress,
              sessions.values.contains(where: { $0.state == .idle }),
              Variety.shared.chance(PartyTiming.startChance) else { return }
        startParty()
    }

    /// 저녁 하나 = 19시 ~ 다음 날 5시(새벽은 전날 저녁에 속한다): 열쇠(날짜) · 시작 시각.
    static func eveningOf(_ date: Date) -> (key: String, start: Date) {
        let calendar = Calendar.current
        let day = calendar.component(.hour, from: date) < 5 ? (calendar.date(byAdding: .day, value: -1, to: date) ?? date) : date
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let start = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: day) ?? day
        return ("\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)", start)
    }

    // MARK: DJ 파티 — 진행

    var partyPlaying: Bool { party.phase == .playing }

    func djTexture(_ pose: WorkerPose) -> SKTexture { TextureCache.shared.texture("dj-\(pose)") { CharacterArt.djSprite(pose) } }
    private var djCarry: [SKTexture] { (0..<4).map { djTexture(.carry($0)) } }

    private func setPartyPhase(_ phase: PartyState.Phase) {
        party.phase = phase
        party.phaseSince = activeTime
        PartyState.note(phase.rawValue, to: &party.log)
    }

    /// 파티 시작: 디제이가 장비 가방을 들고 1층 문으로 들어와 엘리베이터로 옥상 부스 자리까지(카메라가 따라간다).
    func startParty() {
        guard party.phase == .idle else { return }
        party.held = true
        party.maxDancers = 0
        setPartyPhase(.arriving)
        djNode.removeAllActions()
        if djNode.parent == nil { world.addChild(djNode) }
        djNode.anchorPoint = CGPoint(x: 0.5, y: 0)
        djNode.zPosition = 7
        let texture = djTexture(.carry(0))
        djNode.texture = texture
        djNode.size = texture.size()
        djNode.xScale = 1
        djNode.alpha = 0
        djNode.position = CGPoint(x: CGFloat(BuildingLayout.doorX), y: line(layout.lobbyIndex))
        doorNode.texture = door(1)
        requestEventShot(Shot(target: .follow(djNode, zoom: 2.4), caption: "옥상 · DJ 파티 · 디제이가 장비를 들고 올라갑니다", duration: 10, priority: 1))
        djNode.run(.sequence([.fadeIn(withDuration: 0.2), .run { [weak self] in
            guard let self, self.party.phase == .arriving else { return }
            self.doorNode.run(.sequence([.wait(forDuration: 0.6), .setTexture(self.door(0))]))
            self.staffTravel(self.djNode, walk: self.djCarry, stand: self.djTexture(.carry(0)), toFloor: self.layout.roofIndex, x: PoolDeck.djX, speed: 60) { [weak self] in
                self?.setUpBooth()
            }
        }]), withKey: "enter")
    }

    /// 부스 자리: 풀 쪽(오른쪽)을 보고 장비를 편다 — 부스가 서고 미러볼이 내려온다. 잠시 뒤 음악.
    private func setUpBooth() {
        guard party.phase == .arriving else { return }
        setPartyPhase(.setup)
        djNode.xScale = 1
        staffPose(djNode, [djTexture(.stand(blink: false))])
        staffSay(djNode, Variety.shared.line("djSetup", Lines.djSetup), style: .bubble, seconds: 2.2)
        poolDeck.setUpStage()
        poolDeck.run(.sequence([.wait(forDuration: PartyTiming.setupSeconds), .run { [weak self] in self?.startMusic() }]), withKey: "party-step")
    }

    private func startMusic() {
        guard party.phase == .setup else { return }
        setPartyPhase(.playing)
        party.endsAt = activeTime + PartyTiming.playSeconds
        party.nextShout = activeTime + 2
        party.nextHype = activeTime + Variety.shared.seconds(8...12)
        poolDeck.startMusic()
        staffPose(djNode, [djTexture(.scratch(0)), djTexture(.scratch(1))], timePerFrame: PartyTiming.beat / 2)
        staffSay(djNode, Variety.shared.line("djHype", Lines.djHype), style: .shout, seconds: 2.4)
        regroovePool()
        trainerParty(true)
        requestEventShot(Shot(target: .rect(regionRect(.rooftop)), caption: "옥상 · DJ 파티 · 쉬는 직원 \(partyDancerKeys.count)명이 춤춥니다", duration: 8, priority: 1))
    }

    /// 공연 중(1초마다): 끝날 때(약 90초 · 시간대가 낮으로 바뀜 · 감사 시작)면 정리, 아니면 춤추는 직원이 돌아가며 외치고 디제이가 분위기를 띄운다.
    private func tendParty() {
        if auditInProgress { endParty("감사 떴다! 파티 끝!"); return }
        if !Daypart.current.isDark { endParty("벌써 아침이네요, 파티 끝!"); return }
        if djNode.parent == nil { watchParty(); return }
        if activeTime >= party.endsAt { endParty(); return }
        let dancers = partyDancerKeys
        party.maxDancers = max(party.maxDancers, dancers.count)
        if activeTime >= party.nextShout {
            party.nextShout = activeTime + Variety.shared.seconds(2.5...4.5)
            if let key = Variety.shared.element(dancers.filter { bubbles[$0] == nil }) {
                say(key, Variety.shared.line("partyCheer", Lines.partyCheer), seconds: 2.4, style: .shout)
                PartyState.note(key, to: &party.cheers)
            }
        }
        if activeTime >= party.nextHype {
            party.nextHype = activeTime + Variety.shared.seconds(9...14)
            staffSay(djNode, Variety.shared.line("djHype", Lines.djHype), style: .shout, seconds: 2.4)
        }
    }

    /// 파티 끝: 음악을 끄고 장비를 접고(부스 흐려짐 · 미러볼 올라감) 인사한 뒤 엘리베이터로 내려가 문으로 나간다.
    /// 올라오던 중이면 무대 없이 바로 돌아간다. 춤추던 직원은 원래 자세로, 트레이너는 대기 동작으로 돌아간다.
    func endParty(_ text: String? = nil) {
        switch party.phase {
        case .arriving:
            djLeave()
        case .setup, .playing:
            setPartyPhase(.packing)
            poolDeck.stopMusic()
            poolDeck.packUp()
            staffPose(djNode, [djTexture(.wave(0)), djTexture(.wave(1))], timePerFrame: 0.3)
            staffSay(djNode, text ?? Variety.shared.line("djBye", Lines.djBye), style: .bubble, seconds: 2.4)
            regroovePool()
            trainerParty(false)
            staggerRoofSeats()
            poolDeck.run(.sequence([.wait(forDuration: PartyTiming.packSeconds), .run { [weak self] in self?.djLeave() }]), withKey: "party-step")
        default:
            break
        }
    }

    private func djLeave() {
        setPartyPhase(.leaving)
        poolDeck.removeAction(forKey: "party-step")
        poolDeck.clearStage()
        staffTravel(djNode, walk: djCarry, stand: djTexture(.carry(0)), toFloor: layout.lobbyIndex, x: CGFloat(BuildingLayout.doorX), speed: 60) { [weak self] in
            guard let self, self.party.phase == .leaving else { return }
            self.doorNode.texture = self.door(1)
            self.djNode.run(.sequence([.fadeOut(withDuration: 0.3), .run { [weak self] in
                guard let self else { return }
                self.doorNode.texture = self.door(0)
                self.finishParty()
            }]), withKey: "leave")
        }
    }

    private func finishParty() {
        djNode.removeAllActions()
        djNode.removeFromParent()
        poolDeck.removeAction(forKey: "party-step")
        poolDeck.clearStage()
        setPartyPhase(.idle)
    }

    /// 안전망(1초마다): 올라오기 · 설치 · 정리 · 내려가기가 시한을 넘기거나 디제이가 장면에서 빠졌으면 연출 없이 치운다(끊긴 연출 — 아무도 남지 않게).
    private func watchParty() {
        let limits: [PartyState.Phase: TimeInterval] = [.arriving: 60, .setup: 12, .playing: PartyTiming.playSeconds + 30, .packing: 12, .leaving: 60]
        guard let limit = limits[party.phase], djNode.parent == nil || activeTime - party.phaseSince > limit else { return }
        PartyState.note("안전망 \(party.phase.rawValue)", to: &party.log)
        finishParty()
        trainerParty(false)
        regroovePool()
    }

    /// 옥상 놀이 자리(풀 · 선베드 · 빈백)에 앉은 직원을 다시 앉힌다 — 파티가 시작되면 춤, 끝나면 원래 자세(settle이 파티 여부를 본다).
    private func regroovePool() {
        for worker in workers.values where !worker.busy && !worker.leaving && worker.route == nil {
            guard case .rest(let spot) = worker.place, Self.isPartySpot(spot, roof: layout.roofIndex) else { continue }
            settle(worker)
        }
    }

    // MARK: DJ 파티 — 춤(settle이 부른다)

    /// 파티가 열리는 놀이 자리: 옥상의 풀 · 선베드 · 빈백.
    static func isPartySpot(_ spot: BuildingLayout.Spot, roof: Int) -> Bool {
        spot.floor == roof && (spot.kind == .swim || spot.kind == .lounger || spot.kind == .beanbag)
    }

    /// 공연 중이고 옥상 놀이 자리면 춤 자세로 두고 true: 풀에서는 물속 춤, 선베드 · 빈백에서는 일어나 데크에서 뛰며 박수. 다들 부스 쪽을 본다.
    /// 같은 춤이 이미 돌고 있으면 처음부터 다시 걸지 않는다(스냅샷마다 끊기지 않게).
    func partyDance(_ worker: WorkerNode, spot: BuildingLayout.Spot) -> Bool {
        guard party.phase == .playing, Self.isPartySpot(spot, roof: layout.roofIndex) else { return false }
        worker.face(right: CGFloat(spot.x) < PoolDeck.djX)
        if spot.kind == .swim {
            worker.keepLooping([.splash(0), .splash(1)], fps: 4)
        } else {
            worker.position.y = line(worker.floorIndex)   // 선베드에서 일어나 데크 위에 선다
            worker.keepLooping([.jumpingJack(0), .clap(0), .jumpingJack(1), .clap(1)], fps: 4)
        }
        return true
    }

    /// 아직 말하는 중인 말풍선(say — 상태 말풍선 아님)이 있으면 그 글자 · 모양. settle이 스냅샷마다 지우지 않게 넘긴다.
    func keptSay(_ worker: WorkerNode) -> (String?, TextBadge.Style?) {
        guard worker.action(forKey: "say") != nil, let bubble = bubbles[worker.key], bubble.style == .bubble || bubble.style == .shout else { return (nil, nil) }
        return (bubble.currentText, bubble.style)
    }

    // MARK: 검수용

    /// 지금 춤추는 직원: 공연 중 옥상 놀이 자리에 앉아 있고 걷거나 연출에 붙잡히지 않은 직원(pid 순).
    var partyDancerKeys: [ProcessKey] {
        guard party.phase == .playing else { return [] }
        return workers.filter { _, worker in
            guard !worker.busy, !worker.leaving, worker.route == nil, worker.action(forKey: "move") == nil, case .rest(let spot) = worker.place else { return false }
            return Self.isPartySpot(spot, roof: layout.roofIndex)
        }.map(\.key).sorted { $0.pid < $1.pid }
    }
    var partyPhaseName: String { party.phase.rawValue }
    var partyLog: [String] { party.log }
    var partyCheers: [ProcessKey] { party.cheers }
    var partyMaxDancers: Int { party.maxDancers }
    var hotSpringLines: [(key: ProcessKey, text: String)] { party.warmLines }
    var djProbe: StaffProbe { probe(djNode) }
    var poolSteamCount: Int { poolDeck.steam.visibleCount }
    var djSaying: String? { staffBubbles[ObjectIdentifier(djNode)].flatMap { $0.parent == nil ? nil : $0.currentText } }
    var poolDeckNode: PoolDeck { poolDeck }
}
