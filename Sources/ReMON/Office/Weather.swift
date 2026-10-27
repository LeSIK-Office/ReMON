import AppKit
import SpriteKit

// MARK: 장면 시계 · 시간대 · 계절

/// 장면 시계: 실제 현지 시각. 디버그로 REMON_FAKE_TIME="2026-01-15T21:30"(현지 시각)을 주면 그 시각에서 시작해 흐른다.
enum SceneClock {
    static let fakeStart: Date? = {
        guard let text = ProcessInfo.processInfo.environment["REMON_FAKE_TIME"], !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }()
    /// 검수용(장면 시험): 있으면 장면 시각을 여기서 읽는다. 하네스가 고른 날짜 · 시각에서 가짜 시계와 함께 흘러,
    /// 시간대 · 계절 · DJ 파티 일정이 실제 시각과 무관하게 재현된다. 평소에는 nil.
    nonisolated(unsafe) static var checkClock: (() -> Date)?
    private static let launch = Date()
    static var isFaked: Bool { fakeStart != nil }
    static var now: Date {
        if let checkClock { return checkClock() }
        return fakeStart.map { $0.addingTimeInterval(Date().timeIntervalSince(launch)) } ?? Date()
    }
    static var hour: Int { Calendar.current.component(.hour, from: now) }
}

/// 하루 다섯 때(현지 시각): 아침 05–10 · 점심 10–16 · 노을 16–19 · 저녁 19–23 · 깊은 밤 23–05.
enum Daypart: Int, CaseIterable {
    case morning, noon, sunset, evening, night

    static func of(hour: Int) -> Daypart {
        switch hour {
        case 5..<10: return .morning
        case 10..<16: return .noon
        case 16..<19: return .sunset
        case 19..<23: return .evening
        default: return .night
        }
    }

    static var current: Daypart { of(hour: SceneClock.hour) }
    var label: String { ["아침", "점심", "노을", "저녁", "깊은 밤"][rawValue] }

    /// 하늘 위 · 아래(아래 = 지평선. 건물 옆 아랫하늘도 이 색으로 채운다).
    var sky: (top: PixelColor, bottom: PixelColor) {
        switch self {
        case .morning: return (PixelColor(0x8EC5EA), PixelColor(0xFCE1C0))   // 맑은 하늘 → 복숭앗빛 지평선
        case .noon: return (Pal.skyTop, Pal.skyBottom)
        case .sunset: return (PixelColor(0x5E5294), PixelColor(0xFFAE72))    // 보랏빛 → 주황
        case .evening: return (PixelColor(0x1C2250), PixelColor(0x46457F))
        case .night: return (PixelColor(0x0A0F26), PixelColor(0x1A2346))
        }
    }

    /// 건너편 도시 창에 불이 켜진 비율(%).
    var cityLights: Int { [6, 0, 18, 46, 14][rawValue] }
    /// 바깥(땅 · 가로수 · 외벽 · 옥상)에 덮는 색조와 세기. 실내는 등이 켜져 있어 덮지 않는다.
    var tint: (color: PixelColor, amount: Double) {
        switch self {
        case .morning: return (PixelColor(0xFFD9A0), 0.10)
        case .noon: return (Pal.white, 0)
        case .sunset: return (PixelColor(0xF2875A), 0.22)
        case .evening: return (PixelColor(0x2E2F6B), 0.38)
        case .night: return (PixelColor(0x121A38), 0.52)
        }
    }
    var isDark: Bool { self == .evening || self == .night }
    /// 웰니스 풀 조명 세기(Rooftop.swift): 노을부터 은은하게 켜고 저녁 · 깊은 밤에 다 켠다. 아침 · 점심은 끈다.
    var poolLight: Double { [0, 0, 0.6, 1, 1][rawValue] }
    /// 겨울 온수풀 김의 짙기: 새벽(아침) · 깊은 밤이 가장 짙고, 해가 높은 점심이 가장 옅다.
    var steam: Double { [0.9, 0.35, 0.55, 0.8, 1][rawValue] }
}

/// 계절(한국 기준): 봄 3–5월 · 여름 6–8월 · 가을 9–11월 · 겨울 12–2월.
enum Season: Int, CaseIterable {
    case spring, summer, autumn, winter

    static func of(month: Int) -> Season {
        switch month {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .autumn
        default: return .winter
        }
    }

    static var current: Season { of(month: Calendar.current.component(.month, from: SceneClock.now)) }
    var label: String { ["봄", "여름", "가을", "겨울"][rawValue] }
    /// 잎 색(밝음 · 기본 · 어두움). 겨울은 잎 대신 눈 얹은 가지.
    var foliage: [PixelColor] {
        switch self {
        case .spring: return [PixelColor(0xFCD9E3), PixelColor(0xF5A9C0), PixelColor(0xE07F9E)]   // 벚꽃
        case .summer: return [Pal.leafLight, Pal.leaf, Pal.leafDark]
        case .autumn: return [PixelColor(0xF2C14E), PixelColor(0xE8873A), PixelColor(0xC0503A)]   // 단풍
        case .winter: return [PixelColor(0xF4F7FB), PixelColor(0xD8E2EE), PixelColor(0x8A7A6A)]
        }
    }
}

extension PixelColor {
    /// 두 색 사이(t 0 = 자기, 1 = other).
    func mixed(_ other: PixelColor, _ t: Double) -> PixelColor {
        let k = min(1, max(0, t))
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 { UInt8((Double(a) + (Double(b) - Double(a)) * k).rounded()) }
        return PixelColor(r: mix(r, other.r), g: mix(g, other.g), b: mix(b, other.b), a: mix(a, other.a))
    }
}

// MARK: 날씨 그림(입자 · 가로수 · 덤불)

enum WeatherArt {
    static func petal() -> PixelCanvas {
        var c = PixelCanvas(3, 2)
        c.dot(1, 0, PixelColor(0xFCD9E3)); c.dot(2, 0, PixelColor(0xF5A9C0)); c.dot(0, 1, PixelColor(0xF5A9C0)); c.dot(1, 1, PixelColor(0xE89AB2))
        return c
    }

    static func leaf(_ color: PixelColor) -> PixelCanvas {
        var c = PixelCanvas(3, 3)
        c.dot(2, 0, color.lighter(0.2)); c.dot(1, 0, color); c.dot(0, 1, color); c.dot(1, 1, color.darker(0.2)); c.dot(2, 1, color); c.dot(1, 2, color.darker(0.1))
        return c
    }

    static func snowflake(big: Bool) -> PixelCanvas {
        guard big else { var c = PixelCanvas(1, 1); c.dot(0, 0, PixelColor(0xF4F8FF)); return c }
        var c = PixelCanvas(2, 2)
        c.rect(0, 0, 2, 2, PixelColor(0xFFFFFF)); c.dot(1, 1, PixelColor(0xD8E4F2))
        return c
    }

    static func firefly() -> PixelCanvas {
        var c = PixelCanvas(5, 5)
        for (x, y) in [(2, 0), (0, 2), (4, 2), (2, 4), (1, 1), (3, 1), (1, 3), (3, 3)] { c.dot(x, y, PixelColor(0xE9FF7A, alpha: 70)) }
        for (x, y) in [(2, 1), (1, 2), (3, 2), (2, 3)] { c.dot(x, y, PixelColor(0xE9FF7A, alpha: 170)) }
        c.dot(2, 2, PixelColor(0xFFFFD0))
        return c
    }

    /// 가로수(22×34): 줄기 + 둥근 잎(계절 색). 겨울은 맨가지에 눈.
    static func tree(_ season: Season, variant: Int) -> PixelCanvas {
        var c = PixelCanvas(22, 34)
        let bark = Pal.walnut, barkLight = Pal.walnutLight
        c.rect(10, 18, 3, 16, bark); c.vline(10, 18, 16, barkLight)
        c.hline(8, 33, 7, bark.darker(0.2))
        let tones = season.foliage
        if season == .winter {
            for (x0, y0, dx) in [(11, 20, -1), (11, 16, 1), (11, 12, -1), (12, 9, 1)] {
                for i in 0..<6 { c.dot(x0 + dx * i, y0 - i / 2, bark) }
                for i in stride(from: 1, to: 6, by: 2) { c.dot(x0 + dx * i, y0 - i / 2 - 1, tones[0]) }   // 가지 위 눈
            }
            c.vline(11, 6, 12, bark); c.dot(11, 5, tones[0]); c.dot(12, 5, tones[0])
            return c
        }
        let cx = 11.0, cy = 11.0, radius = 10.5 - Double(variant % 2)
        for y in 0..<22 { for x in 0..<22 {
            let dx = Double(x) - cx, dy = (Double(y) - cy) * 1.1, d = (dx * dx + dy * dy).squareRoot()
            guard d <= radius else { continue }
            if season == .autumn && FloorPainter.hash(x, y, 71 + variant) % 9 == 0 { continue }   // 듬성듬성 빠진 잎
            let shade = d > radius - 1.2 ? tones[2] : (dx + dy < -4 ? tones[0] : FloorPainter.hash(x, y, 67 + variant) % 5 == 0 ? tones[2] : tones[1])
            c.dot(x, y, shade)
        } }
        if season == .spring { for (x, y) in [(6, 8), (14, 13), (9, 15)] { c.dot(x, y, Pal.leaf) } }   // 벚꽃 사이 새잎
        return c
    }

    /// 건물 밑 덤불(14×9).
    static func shrub(_ season: Season) -> PixelCanvas {
        var c = PixelCanvas(14, 9)
        let tones = season == .spring ? [Pal.leafLight, Pal.leaf, Pal.leafDark] : season == .winter ? [Pal.leaf, Pal.leafDark, Pal.leafDark.darker(0.2)] : season.foliage
        for y in 0..<9 { for x in 0..<14 {
            let dx = (Double(x) - 6.5) / 7, dy = (Double(y) - 8) / 8.5
            guard dx * dx + dy * dy <= 1 else { continue }
            c.dot(x, y, y < 3 ? tones[0] : FloorPainter.hash(x, y, 79) % 4 == 0 ? tones[2] : tones[1])
        } }
        switch season {
        case .spring: for (x, y) in [(3, 3), (7, 2), (10, 4), (5, 6)] { c.dot(x, y, PixelColor(0xF29BB0)) }    // 꽃
        case .winter: for x in 2..<12 { c.dot(x, x % 3 == 0 ? 1 : 2, PixelColor(0xF4F7FB)) }; c.hline(4, 0, 6, PixelColor(0xF4F7FB))  // 눈 얹힘
        default: break
        }
        return c
    }
}

// MARK: 날씨 층(장면 확장)

extension OfficeScene {
    /// 날씨·시간대 층: 건물 옆 아랫하늘 · 계절 가로수와 덤불 · 바깥 색조(땅 · 외벽 · 옥상) · 계절 입자(봄 꽃잎 · 여름 밤 반딧불 · 가을 낙엽 · 겨울 눈).
    /// 한 번 부르면 자기 노드가 2초마다 스스로 다시 맞춘다(층이 늘거나 시간대·계절이 바뀔 때만 실제로 고친다).
    /// 하늘 텍스처(해·달·별·도시 불빛)와 땅 텍스처(잔디·낙엽·눈)는 FloorPainter.sky/ground가 같은 시계로 그린다.
    /// 입자는 SKEmitterNode 몇 개로 합쳐 수십 개 이하. 창이 닫혀 장면이 멈추면 같이 멈춘다.
    func updateWeather(now: Date = SceneClock.now) {
        let floors = world.children.compactMap { $0 as? SKSpriteNode }.filter { $0.zPosition == 0 && $0.anchorPoint == .zero && $0.position.x == 0 && $0.size.width == CGFloat(BuildingLayout.width) }
        guard let roof = floors.max(by: { $0.position.y < $1.position.y }) else { return }
        let root: SKNode = world.childNode(withName: "weather") ?? {
            let node = SKNode()
            node.name = "weather"
            node.userData = NSMutableDictionary()
            world.addChild(node)
            node.run(.repeatForever(.sequence([.wait(forDuration: 2), .run { [weak self] in self?.updateWeather() }])), withKey: "tick")
            return node
        }()
        let part = Daypart.of(hour: Calendar.current.component(.hour, from: now))
        let season = Season.of(month: Calendar.current.component(.month, from: now))
        let signature = "\(part.rawValue)-\(season.rawValue)-\(ObjectIdentifier(roof).hashValue)-\(Int(roof.position.y))"
        guard root.userData?["signature"] as? String != signature else { return }
        root.userData?["signature"] = signature
        if SceneClock.isFaked && root.userData?["focused"] == nil {   // 디버그 시각: 하늘이 보이게 처음 한 번 전체 보기
            root.userData?["focused"] = true
            focus(.all, animated: false)
        }
        root.removeAllChildren()

        let groundY = CGFloat(BuildingLayout.basementHeight + BuildingLayout.slab)
        let skyBase = roof.position.y, top = roof.position.y + roof.size.height
        let tint = part.tint
        // 1) 건물 옆 아랫하늘(하늘 텍스처 아래 끝 ~ 땅): 지평선 색. 장면 배경색(낮/밤 둘뿐)을 가린다.
        let horizon = SKSpriteNode(color: part.sky.bottom.nsColor, size: CGSize(width: 2400, height: skyBase + 401))
        horizon.anchorPoint = .zero; horizon.position = CGPoint(x: -880, y: -400); horizon.zPosition = -20.5
        root.addChild(horizon)
        // 2) 땅 색조 + 가로수·덤불(계절 그림, 시간대 색조)
        func outdoor(_ node: SKSpriteNode) {
            node.color = tint.color.nsColor
            node.colorBlendFactor = CGFloat(tint.amount)
        }
        if tint.amount > 0 {
            let shade = SKSpriteNode(color: tint.color.nsColor, size: CGSize(width: 2400, height: 400))
            shade.anchorPoint = .zero; shade.position = CGPoint(x: -880, y: groundY - 400); shade.zPosition = -18.8; shade.alpha = CGFloat(tint.amount)
            root.addChild(shade)
        }
        for (index, x) in [-18, -54, 658, 694].enumerated() {   // 건물 바로 옆(전체 보기에서 반쯤 보임) + 넓은 창에서 보이는 바깥쪽
            let tree = SKSpriteNode(texture: TextureCache.shared.texture("wx-tree-\(season.rawValue)-\(index % 2)") { WeatherArt.tree(season, variant: index % 2) })
            tree.anchorPoint = CGPoint(x: 0.5, y: 0); tree.position = CGPoint(x: CGFloat(x), y: groundY - 1); tree.zPosition = -18
            outdoor(tree); root.addChild(tree)
        }
        for x in [-5, 645] {
            let shrub = SKSpriteNode(texture: TextureCache.shared.texture("wx-shrub-\(season.rawValue)") { WeatherArt.shrub(season) })
            shrub.anchorPoint = CGPoint(x: 0.5, y: 0); shrub.position = CGPoint(x: CGFloat(x), y: groundY - 1); shrub.zPosition = -17.5
            outdoor(shrub); root.addChild(shrub)
        }
        // 3) 외벽 기둥 · 옥상 색조(옥상은 텍스처 모양대로만 덮어 하늘엔 겹치지 않게)
        if tint.amount > 0 {
            for x in [0, BuildingLayout.width - 6] {
                let strip = SKSpriteNode(color: tint.color.nsColor, size: CGSize(width: 6, height: max(0, skyBase - groundY)))
                strip.anchorPoint = .zero; strip.position = CGPoint(x: CGFloat(x), y: groundY); strip.zPosition = 0.5; strip.alpha = CGFloat(tint.amount)
                root.addChild(strip)
            }
            if let texture = roof.texture {
                let veil = SKSpriteNode(texture: texture, size: roof.size)
                veil.anchorPoint = .zero; veil.position = roof.position; veil.zPosition = 0.5
                veil.color = tint.color.nsColor; veil.colorBlendFactor = 1; veil.alpha = CGFloat(tint.amount)
                root.addChild(veil)
            }
        }
        // 4) 계절 입자: 바깥에서만 보이게 건물 실내(옥상 아래 층들)와 땅속을 가린 크롭 층에 넣는다 — 옥상 테라스·건물 옆·하늘에만 내리고 실내엔 안 내린다.
        // 입자는 targetNode 기준으로 그려지므로 크롭 안의 층 노드를 target으로 쓴다(그래야 가림막이 입자에도 먹는다).
        let crop = SKCropNode(), layer = SKNode()
        crop.zPosition = 0.6
        let mask = SKNode(), ceiling = top + 400
        for rect in [CGRect(x: -880, y: groundY, width: 880, height: ceiling - groundY), CGRect(x: CGFloat(BuildingLayout.width), y: groundY, width: 880, height: ceiling - groundY),
                     CGRect(x: 0, y: skyBase, width: CGFloat(BuildingLayout.width), height: ceiling - skyBase)] {
            let piece = SKSpriteNode(color: .white, size: rect.size)
            piece.anchorPoint = .zero; piece.position = rect.origin
            mask.addChild(piece)
        }
        crop.maskNode = mask
        crop.addChild(layer)
        root.addChild(crop)
        // 보이는 곳에만 뿌린다: 옥상 위 띠(옥상 데크에서 사라짐) 70% + 건물 양옆 좁은 띠(땅까지) 15%씩. 실내 뒤로 떨어지는 낭비가 없다.
        let fallTop = top + 30, deck = skyBase + 10
        let zones: [(x: CGFloat, width: CGFloat, bottom: CGFloat, share: CGFloat)] = [
            (CGFloat(BuildingLayout.width) / 2, CGFloat(BuildingLayout.width) + 80, deck, 0.7),
            (-34, 68, groundY, 0.15),
            (CGFloat(BuildingLayout.width) + 34, 68, groundY, 0.15),
        ]
        /// count = 동시에 떠 있는 입자 수(띠마다 발생률 = 몫 ÷ 수명이라 건물이 높아져도 늘지 않는다). 바닥에 닿기 전에 흐려진다.
        func fall(_ key: String, _ art: @autoclosure () -> PixelCanvas, count: CGFloat, speed: CGFloat, alpha: CGFloat = 1, spin: CGFloat = 0) {
            let texture = TextureCache.shared.texture(key, art)
            for zone in zones {
                let emitter = SKEmitterNode()
                let life = (fallTop - zone.bottom) / speed
                emitter.particleTexture = texture
                emitter.particleBirthRate = count * zone.share / life
                emitter.particleLifetime = life
                emitter.particlePositionRange = CGVector(dx: zone.width, dy: 0)
                emitter.emissionAngle = -.pi / 2
                emitter.emissionAngleRange = 0.5
                emitter.particleSpeed = speed
                emitter.particleSpeedRange = speed * 0.3
                emitter.particleAlphaSequence = SKKeyframeSequence(keyframeValues: [alpha, alpha, 0] as [NSNumber], times: [0, 0.82, 1] as [NSNumber])
                emitter.particleRotationRange = spin > 0 ? .pi : 0
                emitter.particleRotationSpeed = spin
                emitter.position = CGPoint(x: zone.x, y: fallTop)
                emitter.targetNode = layer
                // 바람: 8초 주기로 좌우로 살랑(입자 하나하나가 아니라 발생기 하나의 가속만 바꾼다)
                emitter.run(.repeatForever(.customAction(withDuration: 8) { node, elapsed in
                    (node as? SKEmitterNode)?.xAcceleration = 3 * sin(elapsed / 8 * 2 * .pi)
                }))
                layer.addChild(emitter)
                emitter.advanceSimulationTime(TimeInterval(life))
            }
        }
        switch season {
        case .spring:
            fall("wx-petal", WeatherArt.petal(), count: 36, speed: 11, spin: 1.2)
        case .summer:
            if part.isDark {   // 여름 밤 반딧불: 옥상 정원 위와 건물 옆 풀숲
                for (center, range) in [(CGPoint(x: 320, y: skyBase + 24), CGVector(dx: 600, dy: 30)), (CGPoint(x: 320, y: groundY + 16), CGVector(dx: 760, dy: 24))] {
                    let flies = SKEmitterNode()
                    flies.particleTexture = TextureCache.shared.texture("wx-firefly") { WeatherArt.firefly() }
                    flies.particleBirthRate = 1.6
                    flies.particleLifetime = 5; flies.particleLifetimeRange = 2
                    flies.particlePositionRange = range
                    flies.emissionAngleRange = 2 * .pi
                    flies.particleSpeed = 3; flies.particleSpeedRange = 3
                    flies.particleAlphaSequence = SKKeyframeSequence(keyframeValues: [0, 1, 0.25, 1, 0] as [NSNumber], times: [0, 0.25, 0.5, 0.75, 1] as [NSNumber])
                    flies.particleBlendMode = .add
                    flies.position = center
                    flies.targetNode = layer
                    layer.addChild(flies)
                    flies.advanceSimulationTime(5)
                }
            }
        case .autumn:
            for (index, color) in [PixelColor(0xE8873A), PixelColor(0xC0503A), PixelColor(0xF2C14E)].enumerated() {
                fall("wx-leaf\(index)", WeatherArt.leaf(color), count: 10, speed: 13, spin: 1.6)
            }
        case .winter:
            fall("wx-snow1", WeatherArt.snowflake(big: true), count: 36, speed: 15)
            fall("wx-snow0", WeatherArt.snowflake(big: false), count: 18, speed: 9, alpha: 0.75)   // 먼 눈(작고 느리게)
        }
    }
}
