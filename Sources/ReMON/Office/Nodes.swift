import AppKit
import ReMONCore
import SpriteKit

/// 픽셀 캔버스 → nearest 필터 텍스처(같은 그림은 한 번만 만든다).
final class TextureCache {
    static let shared = TextureCache()
    private var cache: [String: SKTexture] = [:]

    func texture(_ key: String, _ make: () -> PixelCanvas) -> SKTexture {
        if let texture = cache[key] { return texture }
        let canvas = make()
        let texture = canvas.cgImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
        texture.filteringMode = .nearest
        cache[key] = texture
        return texture
    }

    func worker(_ look: WorkerLook, _ pose: WorkerPose) -> SKTexture {
        texture("w\(look.hashValue)\(pose)") { CharacterArt.worker(look, pose) }
    }

    func clear() { cache.removeAll() }

    /// 창을 닫을 때 큰 텍스처(하늘·땅·층 배경)를 버린다. 작은 캐릭터 프레임은 남긴다.
    func trim() {
        cache = cache.filter { key, texture in
            !(key.hasPrefix("sky") || key.hasPrefix("ground") || key.hasPrefix("library")) && texture.size().width * texture.size().height < 20_000
        }
    }
}

enum TeamColor {
    /// 팀 후드 색은 종류가 들고 다닌다(기본 6종은 예전 색 그대로, 표·직접 추가 에이전트는 표의 색). 종류 없음 = 회색.
    static func hoodie(_ kind: AgentKind?) -> PixelColor {
        kind.map { PixelColor($0.color) } ?? PixelColor(0xB8BCC4)
    }

    static func ns(_ kind: AgentKind?) -> NSColor { hoodie(kind).nsColor }
}

/// 사무실 직원 한 명(세션 하나). 위치는 (층, x) 가상 좌표로 관리한다.
final class WorkerNode: SKNode {
    enum Place: Equatable { case desk, rest(BuildingLayout.Spot), lobby, lounge, away }

    let key: ProcessKey
    var look: WorkerLook
    let sprite = SKSpriteNode()
    var robots: [SKSpriteNode] = []
    var floorIndex = 1
    var vx: CGFloat = 0
    var place: Place = .away
    var busy = false          // 연출 중이면 상태 갱신으로 자리를 옮기지 않는다
    var leaving = false
    /// 가는 중인 곳(층 종류 · x · 도착하면 앉을 자리). 같은 곳으로 가는 중이면 스냅샷마다 다시 출발시키지 않는다.
    struct Route: Equatable {
        var floor: BuildingLayout.FloorKind
        var x: CGFloat
        var place: Place?
    }
    var route: Route?
    /// 안전망용(장면이 실제로 돈 시간 기준): 엘리베이터 칸에 들어선 때 · 퇴근을 시작한 때.
    var shaftSince: TimeInterval?
    var leavingSince: TimeInterval?
    var spriteHeight: CGFloat = 24
    var labelText = ""
    var bubbleText: String?
    var ghost = false

    init(key: ProcessKey, look: WorkerLook) {
        self.key = key
        self.look = look
        super.init()
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        addChild(sprite)
        show(.stand(blink: false))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ pose: WorkerPose) {
        sprite.removeAction(forKey: "anim")
        looping = nil
        let texture = TextureCache.shared.worker(look, pose)
        sprite.texture = texture
        sprite.size = texture.size()
        spriteHeight = texture.size().height
    }

    func loop(_ poses: [WorkerPose], fps: Double) {
        let textures = poses.map { TextureCache.shared.worker(look, $0) }
        sprite.texture = textures.first
        sprite.size = textures.first?.size() ?? .zero
        spriteHeight = sprite.size.height
        sprite.removeAction(forKey: "anim")
        sprite.run(.repeatForever(.animate(with: textures, timePerFrame: 1 / fps, resize: true, restore: false)), withKey: "anim")
        looping = (look, poses, fps)
    }

    /// 지금 도는 반복 자세(loop로 건 외형 · 자세 · 속도). show · 유령이 지운다.
    private var looping: (look: WorkerLook, poses: [WorkerPose], fps: Double)?

    /// 같은 반복이 이미 돌고 있으면 그대로 둔다(파티 춤이 스냅샷마다 처음부터 다시 시작해 끊기지 않게). 아니면 loop.
    func keepLooping(_ poses: [WorkerPose], fps: Double) {
        if let current = looping, current.look == look, current.poses == poses, current.fps == fps, sprite.action(forKey: "anim") != nil { return }
        loop(poses, fps: fps)
    }

    func showGhost() {
        ghost = true
        looping = nil
        sprite.removeAction(forKey: "anim")
        let frames = (0..<2).map { i in TextureCache.shared.texture("ghost\(i)") { CharacterArt.ghost(i) } }
        sprite.texture = frames[0]
        sprite.size = frames[0].size()
        spriteHeight = 16
        sprite.alpha = 0.85
        sprite.run(.repeatForever(.animate(with: frames, timePerFrame: 0.5)), withKey: "anim")
        sprite.run(.repeatForever(.sequence([.moveBy(x: 0, y: 3, duration: 1.2), .moveBy(x: 0, y: -3, duration: 1.2)])), withKey: "float")
    }

    func clearGhost() {
        guard ghost else { return }
        ghost = false
        sprite.removeAction(forKey: "float")
        sprite.position = .zero
        sprite.alpha = 1
    }

    func face(right: Bool) { sprite.xScale = right ? 1 : -1 }

    /// (예전) 하위 프로세스 로봇. 하위 프로세스는 도구라 사무실에 그리지 않는다 — 로봇은 하위 에이전트 전용(setHelpers).
    func setRobots(_ count: Int) {
        robots.forEach { $0.removeFromParent() }
        robots = []
    }

    func setRobotsVisible(_ visible: Bool) { robots.forEach { $0.isHidden = !visible } }

    // MARK: 하위 에이전트(사람) — 주 에이전트 책상에 모인 작은 조수들

    private var helpers: [SKSpriteNode] = []
    private var helperKey = ""

    /// 일하는 하위 에이전트를 책상 둘레에 작은 로봇으로(최대 6대). 워크플로 에이전트는 노란 명판.
    /// skipWorkflow: 그 층에 워크플로실이 있으면 워크플로 에이전트는 워크플로실에서 일하므로 책상 옆에는 그리지 않는다(두 번 그리지 않게).
    func setHelpers(_ subagents: [SubagentInfo], team: PixelColor, visible: Bool, skipWorkflow: Bool = false) {
        let active = subagents.filter { $0.active && !(skipWorkflow && $0.kind == .workflow) }
        let key = active.prefix(6).map(\.id).joined(separator: ",") + "|\(visible)"
        guard key != helperKey else { return }
        helperKey = key
        helpers.forEach { $0.removeFromParent() }
        helpers = []
        guard visible else { return }
        // 로봇 자리: 책상 왼쪽 바닥에 줄지어, 두 번째 줄은 뒤에(작게). 하위 에이전트마다 모양·색이 무작위(id로 고정).
        let offsets: [(CGFloat, CGFloat)] = [(-13, 0), (-23, 0), (-33, 0), (-18, 6), (-28, 6), (-38, 6)]
        for (index, agent) in active.prefix(6).enumerated() {
            let frames = Self.robotFrames(agent)
            let node = SKSpriteNode(texture: frames[0])
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            node.position = CGPoint(x: offsets[index].0, y: offsets[index].1)
            node.zPosition = offsets[index].1 > 3 ? -0.6 : -0.3
            node.name = agent.id
            node.run(.repeatForever(.animate(with: frames, timePerFrame: 0.22 + Double(index % 3) * 0.06)))
            addChild(node)
            helpers.append(node)
        }
    }

    var helperCount: Int { helpers.count }

    /// 책상 옆 로봇 중 그 점(이 직원 기준 좌표)에 선 하위 에이전트 id(누르면 하위 에이전트 카드).
    func helperID(at point: CGPoint) -> String? {
        helpers.first { !$0.isHidden && CGRect(x: $0.position.x - 6, y: $0.position.y - 1, width: 12, height: 15).contains(point) }?.name
    }

    /// 검수용: 책상 옆 로봇 자리(이 직원 기준).
    var helperPoints: [(id: String, point: CGPoint)] { helpers.map { ($0.name ?? "", $0.position) } }

    /// 하위 에이전트 로봇의 2프레임(id로 모양·색 고정 — 책상 옆이든 워크플로실이든 같은 로봇).
    static func robotFrames(_ agent: SubagentInfo) -> [SKTexture] {
        let design = robotDesign(agent)
        return (0..<2).map { frame in TextureCache.shared.texture("bot-\(design.key)-\(frame)") { CharacterArt.robot(design, frame: frame) } }
    }

    /// 하위 에이전트 → 로봇 생김새(id 해시 씨앗). 카드(SubagentCard)의 그림도 같은 로봇이다.
    static func robotDesign(_ agent: SubagentInfo) -> RobotDesign {
        let seed = abs(agent.id.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) })
        return RobotDesign(seed: seed, workflow: agent.kind == .workflow)
    }
}

/// 픽셀 효과(먼지·땀·반짝이·김). 파티클 시스템 대신 작은 스프라이트로 픽셀 느낌을 유지한다.
enum Effects {
    static func puff(color: PixelColor, size: Int = 3) -> SKSpriteNode {
        let texture = TextureCache.shared.texture("puff\(color.hashValue)-\(size)") {
            var c = PixelCanvas(size, size)
            c.rect(0, 0, size, size, color)
            return c
        }
        let node = SKSpriteNode(texture: texture)
        node.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        return node
    }

    static func burst(in parent: SKNode, at point: CGPoint, color: PixelColor, count: Int, spread: CGFloat, rise: CGFloat, duration: TimeInterval) {
        for i in 0..<count {
            let node = puff(color: color, size: i % 3 == 0 ? 3 : 2)
            node.position = point
            node.zPosition = 50
            parent.addChild(node)
            let angle = CGFloat(i) / CGFloat(max(1, count)) * .pi * 2
            let dx = cos(angle) * spread * CGFloat.random(in: 0.5...1)
            let dy = abs(sin(angle)) * rise * CGFloat.random(in: 0.4...1)
            node.run(.sequence([.group([.moveBy(x: dx, y: dy, duration: duration), .fadeOut(withDuration: duration)]), .removeFromParent()]))
        }
    }

    static func sparkle(in parent: SKNode, at point: CGPoint) {
        let texture = TextureCache.shared.texture("sparkle") {
            var c = PixelCanvas(5, 5)
            c.vline(2, 0, 5, PixelColor(0xFFE27A)); c.hline(0, 2, 5, PixelColor(0xFFE27A)); c.dot(2, 2, Pal.white)
            return c
        }
        for i in 0..<4 {
            let node = SKSpriteNode(texture: texture)
            node.position = CGPoint(x: point.x + CGFloat(i * 5 - 8), y: point.y + CGFloat((i % 2) * 6))
            node.zPosition = 60
            node.setScale(0.2)
            parent.addChild(node)
            node.run(.sequence([.wait(forDuration: Double(i) * 0.08), .scale(to: 1, duration: 0.15), .wait(forDuration: 0.25), .fadeOut(withDuration: 0.3), .removeFromParent()]))
        }
    }

    static func sweat(on node: SKNode, height: CGFloat) {
        let drop = puff(color: PixelColor(0x6EC6FF), size: 2)
        drop.position = CGPoint(x: 6, y: height)
        drop.zPosition = 55
        node.addChild(drop)
        drop.run(.sequence([.group([.moveBy(x: 4, y: -6, duration: 0.5), .fadeOut(withDuration: 0.5)]), .removeFromParent()]))
    }
}

/// 글자 오버레이(배율을 적용하지 않는 층에 올려 또렷하게 그린다).
final class TextBadge: SKNode {
    enum Style { case plate, bubble, shout, sign, tiny }
    /// overlay 안 앞뒤 층: 글자판 < 이름표 < 제목 풍선 < 말풍선(새로 말할수록 앞) < 안내 칩.
    /// SpriteKit은 z를 조상까지 더한 값 하나로 줄 세워 그리고, 같은 z끼리는 순서를 보장하지 않는다. 상자마다 z가 같으면
    /// 뒤 상자의 글자(바탕보다 위)가 앞 상자의 바탕보다 늦게 그려져 말풍선이 투명해 보였다(10-25 대표 지적 두 번).
    /// 그래서 상자마다 층 안에서 다른 z를 주고, 글자는 자기 바탕 바로 위(다음 상자보다 아래)에 둔다.
    enum Layer: Int { case sign, plate, title, speech, chip }
    private let label = SKLabelNode()
    private var background: SKShapeNode?
    private var signColor: NSColor
    let style: Style
    let layer: Layer
    var currentText: String { label.text ?? "" }
    /// 작은 이름표(.tiny · .plate)의 글자 · 테두리 색 — 경고 꼬리표('멈춤?' 빨강 · '잔재' 주황)용. nil이면 기본. 그리기만 바꾼다(앞뒤 층은 그대로).
    var tint: NSColor? {
        didSet {
            guard oldValue != tint, style == .tiny || style == .plate else { return }
            let text = currentText
            background?.removeFromParent()
            background = nil
            label.text = nil
            set(text)
        }
    }
    /// 배경 상자 크기(겹침 정리용, set에서 갱신).
    private(set) var badgeSize: CGSize = .zero

    private static let step: CGFloat = 0.0001
    private static let bases: [CGFloat] = [0, 1, 2, 3, 9, 10]   // 층별 시작 z(마지막 값은 끝)
    private static var counters = [Int](repeating: 0, count: 5)
    private static let live = NSHashTable<TextBadge>.weakObjects()

    init(_ text: String, style: Style, color: NSColor = .white, layer: Layer? = nil) {
        self.style = style
        self.signColor = color
        self.layer = layer ?? {
            switch style {
            case .sign: return .sign
            case .plate, .tiny: return .plate
            case .bubble, .shout: return .speech
            }
        }()
        super.init()
        label.fontName = "AppleSDGothicNeo-Bold"
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.zPosition = Self.step / 2
        addChild(label)
        Self.live.add(self)
        bringToFront()
        set(text, color: color)
    }

    /// 같은 층에서 맨 앞으로. 층의 자리가 다 차면 살아 있는 상자들을 지금 앞뒤 순서 그대로 앞쪽부터 다시 채운다.
    func bringToFront() {
        let index = layer.rawValue
        let capacity = Int(((Self.bases[index + 1] - Self.bases[index]) / Self.step).rounded()) - 1
        if Self.counters[index] >= capacity {
            let members = Self.live.allObjects.filter { $0.layer == layer && $0 !== self }.sorted { $0.zPosition < $1.zPosition }
            for (i, badge) in members.enumerated() { badge.zPosition = Self.bases[index] + CGFloat(i + 1) * Self.step }
            Self.counters[index] = members.count
        }
        Self.counters[index] += 1
        zPosition = Self.bases[index] + CGFloat(Self.counters[index]) * Self.step
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 색을 주지 않으면 처음 정한 색을 유지한다(현황판 글자가 흰색으로 바뀌던 문제).
    func set(_ text: String, color: NSColor? = nil) {
        if let color { signColor = color }
        let color = signColor
        guard label.text != text || background == nil && style != .sign else { return }
        // 새로 한 말은 겹친 다른 말풍선보다 앞에(처음 만들 때는 init에서 이미 앞).
        if layer == .speech, label.text != nil { bringToFront() }
        label.text = text
        switch style {
        case .plate:
            label.fontSize = 10; label.fontColor = tint ?? NSColor(white: 0.15, alpha: 1)
        case .bubble:
            label.fontSize = 11; label.fontColor = NSColor(white: 0.12, alpha: 1)
        case .shout:
            label.fontSize = 12; label.fontColor = NSColor(srgbRed: 0.75, green: 0.1, blue: 0.12, alpha: 1)
        case .sign:
            label.fontSize = 8; label.fontColor = color
        case .tiny:
            label.fontSize = 8.5; label.fontColor = tint ?? NSColor(white: 0.2, alpha: 1)
        }
        background?.removeFromParent()
        let width = label.frame.width + (style == .sign ? 8 : 12)
        let height = label.frame.height + (style == .tiny ? 4 : 7)
        badgeSize = CGSize(width: width, height: height + (style == .bubble || style == .shout ? 5 : 0))
        guard style != .sign else { return }
        let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
        let path = CGMutablePath()
        path.addRoundedRect(in: rect, cornerWidth: style == .plate || style == .tiny ? 4 : 7, cornerHeight: style == .plate || style == .tiny ? 4 : 7)
        if style == .bubble || style == .shout {
            path.move(to: CGPoint(x: -4, y: -height / 2))
            path.addLine(to: CGPoint(x: 0, y: -height / 2 - 5))
            path.addLine(to: CGPoint(x: 4, y: -height / 2))
        }
        let shape = SKShapeNode(path: path)
        switch style {
        case .plate, .tiny: shape.fillColor = NSColor(white: 1, alpha: 1); shape.strokeColor = tint ?? NSColor(white: 0, alpha: 0.18)
        case .bubble: shape.fillColor = .white; shape.strokeColor = NSColor(white: 0.15, alpha: 0.9)
        case .shout: shape.fillColor = NSColor(srgbRed: 1, green: 0.96, blue: 0.85, alpha: 1); shape.strokeColor = NSColor(srgbRed: 0.75, green: 0.1, blue: 0.12, alpha: 1)
        case .sign: break
        }
        shape.lineWidth = style == .shout ? 1.5 : 1
        shape.zPosition = 0
        insertChild(shape, at: 0)
        background = shape
    }
}


/// 사각형 구멍만 남기고 둘레를 어둡게 덮는다(위·아래·왼쪽·오른쪽 네 판).
/// SKShapeNode 채우기는 경로가 커지면(텍스처 한도 초과) 조용히 안 그려져, 단색 스프라이트로 만든다.
final class DimFrame: SKNode {
    private let panels = (0..<4).map { _ in SKSpriteNode(color: .black, size: .zero) }

    override init() {
        super.init()
        for panel in panels {
            panel.anchorPoint = .zero
            addChild(panel)
        }
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(hole: CGRect, within outer: CGRect, alpha: CGFloat) {
        let rects = [
            CGRect(x: outer.minX, y: hole.maxY, width: outer.width, height: max(0, outer.maxY - hole.maxY)),      // 위
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: max(0, hole.minY - outer.minY)),     // 아래
            CGRect(x: outer.minX, y: hole.minY, width: max(0, hole.minX - outer.minX), height: hole.height),      // 왼쪽
            CGRect(x: hole.maxX, y: hole.minY, width: max(0, outer.maxX - hole.maxX), height: hole.height),       // 오른쪽
        ]
        for (panel, rect) in zip(panels, rects) {
            panel.position = rect.origin
            panel.size = rect.size
            panel.alpha = alpha
        }
        isHidden = false
    }
}
