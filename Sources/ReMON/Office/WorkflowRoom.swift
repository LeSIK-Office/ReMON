import AppKit
import ReMONCore
import SpriteKit

/// 워크플로실: 팀 층(맨 위 상황실 층 제외) 별관 방. 그 층 세션의 워크플로 에이전트(로봇)가 여기 모여 일한다.
/// 층 배경(FloorPainter) 위에 별관 크기 그림을 한 장 덮어 그린다 — 층 배경을 다시 그리지 않고 이 방만 바꾼다.
enum WorkflowRoomArt {
    static let width = BuildingLayout.wingX1 - BuildingLayout.wingX0
    /// 작업대(콘솔) 3개의 왼쪽 x(방 기준). 로봇은 콘솔마다 둘씩 그 앞에 선다.
    static let consoleXs = [72, 102, 132]
    static let robotXs: [CGFloat] = [78, 90, 108, 120, 138, 150]

    /// 방 그림(가로 160, 세로 = 층 높이 − 바닥판). lit = 워크플로가 도는 중(불 켜짐·화면 켜짐), 아니면 어둡게 대기.
    static func room(lit: Bool, height: Int) -> PixelCanvas {
        var c = PixelCanvas(width, height)
        let floorTop = height - 6
        let wall = lit ? PixelColor(0x4A5872) : PixelColor(0x2F3746)
        c.rect(0, 0, width, floorTop, wall)
        for x in stride(from: 20, to: width, by: 20) { c.vline(x, 4, floorTop - 4, wall.darker(0.14)) }   // 패널 이음
        c.hline(0, 0, width, wall.lighter(0.22))
        // 천장 레일 등
        c.rect(4, 2, width - 8, 2, lit ? PixelColor(0xFFF2B8) : PixelColor(0x4B5563))
        // 화이트보드(글자는 장면이 올린다) + 펜 받침
        c.box(6, 8, 62, 26, fill: lit ? Pal.paper : PixelColor(0x9AA3AF), outline: Pal.metal, rounded: false)
        c.rect(6, 34, 62, 2, Pal.metalLight)
        if lit { c.rect(58, 33, 4, 1, Pal.alarm); c.rect(52, 33, 4, 1, Pal.screenLine) }
        // 상태등 줄(콘솔 위, 방 이름표 아래)
        for (index, x) in consoleXs.enumerated() {
            c.box(x + 8, 20, 8, 5, fill: PixelColor(0x1F252E), outline: PixelColor(0x161B22), rounded: false)
            c.rect(x + 10, 22, 4, 1, lit ? [Pal.leaf, Pal.mustard, Pal.leaf][index] : PixelColor(0x3B4250))
        }
        // 작업대: 화면 + 몸통
        for x in consoleXs {
            c.box(x + 4, floorTop - 22, 16, 10, fill: lit ? Pal.monitorOn : Pal.monitorOff, outline: Pal.outline, rounded: false)
            if lit { c.hline(x + 6, floorTop - 19, 10, Pal.screenLine); c.hline(x + 6, floorTop - 16, 7, Pal.screenLine) }
            c.box(x, floorTop - 12, 24, 12, fill: PixelColor(0x5B6573), outline: PixelColor(0x2F3742), rounded: false)
            c.hline(x + 1, floorTop - 11, 22, PixelColor(0x7C8592))
            c.rect(x + 3, floorTop - 8, 4, 2, lit ? Pal.robotEye : PixelColor(0x3B4250))
        }
        // 보드 밑 화분
        c.stamp(Furniture.smallPlant(), 30, floorTop - 11)
        // 바닥: 회색 고무 타일
        for y in floorTop..<height { for x in 0..<width { c.dot(x, y, (x / 4 + y / 3) % 2 == 0 ? PixelColor(0x6B7280) : PixelColor(0x5F6675)) } }
        c.hline(0, floorTop, width, PixelColor(0x8A96A6))
        if !lit { c.rect(0, 0, width, floorTop, PixelColor(0x0B0F17, alpha: 70)) }
        return c
    }
}

/// 워크플로실 로봇 하나 = 하위 에이전트 하나(주인 세션 · 정보). 하위 에이전트 자원 관리실의 세 상태:
/// 일함 · 멈춤?(일하는 중으로 보이는데 20분 넘게 기록이 없음 — 빨간 등이 깜박) · 잔재(주인 세션이 사라졌는데 로봇이 남음 — 전원이 꺼진다).
struct WorkflowRobot: Equatable {
    var owner: ProcessKey
    var info: SubagentInfo
    var stale = false
    var residue = false
}

/// 워크플로실 한 칸(층 하나). 방 그림 + 로봇(최대 6대). 보드 글자·대기 표지는 장면의 글자 층(overlay)이 그린다.
/// 로봇 꼬리표('멈춤?' · '잔재')는 로봇에 붙여 건물과 함께 움직이고, 카메라 배율만큼 줄여 화면에서 늘 같은 크기로 보인다.
final class WorkflowRoomNode: SKNode {
    let floorIndex: Int
    private let background = SKSpriteNode()
    private var robots: [String: SKSpriteNode] = [:]
    private var robotInfo: [String: WorkflowRobot] = [:]
    private var tags: [String: TextBadge] = [:]
    private var tagScale: CGFloat = 0.5
    private(set) var lit = false
    private var floorHeight = BuildingLayout.teamHeight

    init(floorIndex: Int, floor: BuildingLayout.Floor) {
        self.floorIndex = floorIndex
        super.init()
        background.anchorPoint = .zero
        background.zPosition = 0
        addChild(background)
        place(floor)
        setLit(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func place(_ floor: BuildingLayout.Floor) {
        floorHeight = floor.height
        position = CGPoint(x: CGFloat(BuildingLayout.wingX0), y: CGFloat(floor.floorLine))
        background.size = CGSize(width: WorkflowRoomArt.width, height: floor.height - BuildingLayout.slab)
    }

    private func setLit(_ on: Bool) {
        lit = on
        let height = floorHeight - BuildingLayout.slab
        background.texture = TextureCache.shared.texture("workflow-room-\(on)-\(height)") { WorkflowRoomArt.room(lit: on, height: height) }
    }

    /// 일하는 로봇 수(잔재는 빼고 — 층 안내판 '워크플로 N'과 같은 뜻).
    var robotCount: Int { robotInfo.values.filter { !$0.residue }.count }
    var staleCount: Int { robotInfo.values.filter(\.stale).count }
    var residueCount: Int { robotInfo.values.filter(\.residue).count }

    /// 이 층의 로봇으로 방을 맞춘다: 일하는 로봇이 있으면 불을 켜고 콘솔 앞에 세운다(id로 같은 자리 · 같은 모양).
    /// 멈춤? = 그 자리에서 굳고 머리 위 빨간 등이 깜박 + '멈춤?' 꼬리표. 잔재 = 전원이 꺼져 회색으로 주저앉고 '잔재' 꼬리표.
    func show(_ list: [WorkflowRobot]) {
        let shown = Array(list.prefix(WorkflowRoomArt.robotXs.count))
        let working = shown.contains { !$0.residue }
        if lit != working { setLit(working) }
        let keep = Set(shown.map(\.info.id))
        for (id, node) in robots where !keep.contains(id) {
            robots[id] = nil
            robotInfo[id] = nil
            tags[id] = nil
            node.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
        }
        for (index, robot) in shown.enumerated() {
            let id = robot.info.id
            let x = WorkflowRoomArt.robotXs[index]
            let node: SKSpriteNode
            if let existing = robots[id] {
                node = existing
                if abs(node.position.x - x) > 0.5 { node.run(.moveTo(x: x, duration: 0.4), withKey: "slide") }
            } else {
                node = SKSpriteNode(texture: WorkerNode.robotFrames(robot.info)[0])
                node.anchorPoint = CGPoint(x: 0.5, y: 0)
                node.position = CGPoint(x: x, y: 0)
                node.zPosition = 4
                node.alpha = 0
                node.run(.fadeIn(withDuration: 0.3), withKey: "fade")
                addChild(node)
                robots[id] = node
            }
            let before = robotInfo[id]
            robotInfo[id] = robot
            if before == nil || before?.stale != robot.stale || before?.residue != robot.residue { style(node, robot, index: index) }
        }
    }

    /// 상태별 모양: 일함 = 두 프레임 반복 · 멈춤? = 굳음 + 빨간 등 깜박 · 잔재 = 회색 · 한 칸 주저앉음 · 눈 꺼짐.
    private func style(_ node: SKSpriteNode, _ robot: WorkflowRobot, index: Int) {
        let frames = WorkerNode.robotFrames(robot.info)
        node.removeAction(forKey: "work")
        node.childNode(withName: "stale-light")?.removeFromParent()
        node.colorBlendFactor = 0
        node.position.y = 0
        tags[robot.info.id]?.removeFromParent()
        tags[robot.info.id] = nil
        if robot.residue {
            node.texture = frames[1]
            node.color = NSColor(white: 0.18, alpha: 1)
            node.colorBlendFactor = 0.82
            node.position.y = -1
            addTag(node, robot.info.id, "잔재", tint: NSColor(srgbRed: 0.85, green: 0.45, blue: 0.1, alpha: 1))
        } else if robot.stale {
            node.texture = frames[0]
            // 머리 위 빨간 경고등(3×3, 가운데 흰 점) — 켜진 시간이 길게 깜박인다.
            let light = SKSpriteNode(texture: TextureCache.shared.texture("stale-light") {
                var c = PixelCanvas(3, 3)
                c.rect(0, 0, 3, 3, Pal.alarm); c.dot(1, 1, Pal.white)
                return c
            })
            light.size = CGSize(width: 3, height: 3)
            light.name = "stale-light"
            light.anchorPoint = CGPoint(x: 0.5, y: 0)
            light.position = CGPoint(x: 0, y: 15)
            light.zPosition = 0.2
            light.run(.repeatForever(.sequence([.fadeAlpha(to: 1, duration: 0.05), .wait(forDuration: 0.35), .fadeAlpha(to: 0.55, duration: 0.05), .wait(forDuration: 0.2)])))
            node.addChild(light)
            addTag(node, robot.info.id, "멈춤?", tint: NSColor(srgbRed: 0.82, green: 0.1, blue: 0.12, alpha: 1))
        } else {
            node.run(.repeatForever(.animate(with: frames, timePerFrame: 0.22 + Double(index % 3) * 0.06)), withKey: "work")
        }
    }

    private func addTag(_ node: SKSpriteNode, _ id: String, _ text: String, tint: NSColor) {
        let tag = TextBadge("", style: .tiny)
        tag.tint = tint
        tag.set(text)
        // 이웃 로봇 꼬리표와 겹치지 않게 칸마다 높이를 엇갈린다.
        let slot = WorkflowRoomArt.robotXs.firstIndex { abs($0 - node.position.x) < 1 } ?? 0
        tag.position = CGPoint(x: 0, y: 19 + CGFloat(slot % 2) * 7)
        tag.setScale(tagScale)
        node.addChild(tag)
        tags[id] = tag
    }

    /// 꼬리표를 화면에서 늘 같은 크기로(건물은 카메라 배율만큼 커지므로 그만큼 줄인다).
    func fitTags(cameraScale: CGFloat) {
        tagScale = 1 / max(0.25, cameraScale)
        tags.values.forEach { $0.setScale(tagScale) }
    }

    /// 누른 점(건물 좌표)의 로봇.
    func robot(at point: CGPoint) -> WorkflowRobot? {
        let local = CGPoint(x: point.x - position.x, y: point.y - position.y)
        guard let (id, _) = robots.first(where: { CGRect(x: $0.value.position.x - 6, y: $0.value.position.y - 1, width: 12, height: 16).contains(local) }) else { return nil }
        return robotInfo[id]
    }

    /// 검수용: 로봇 자리(건물 좌표) · 상태 · 꼬리표 글자.
    var robotProbes: [(robot: WorkflowRobot, point: CGPoint, tag: String?, light: Bool)] {
        robots.compactMap { id, node in
            guard let robot = robotInfo[id] else { return nil }
            return (robot, CGPoint(x: position.x + node.position.x, y: position.y + node.position.y), tags[id]?.currentText, node.childNode(withName: "stale-light") != nil)
        }
    }

    /// 보드 세 줄: 가동 대수(멈춤?이 있으면 함께) · 워크플로별 단계(없으면 이름)와 대수 · 셋째 줄 = 멈춤? 로봇 이름(없으면 잔재 수, 없으면 둘째 워크플로).
    static func board(_ list: [WorkflowRobot]) -> [String] {
        let working = list.filter { !$0.residue }
        let stale = working.filter(\.stale)
        let residue = list.count - working.count
        guard !working.isEmpty else { return residue > 0 ? ["로봇 0대 가동", "잔재 \(residue)대 · 주인 세션 없음"] : [] }
        let agents = working.map(\.info)
        let groups = Dictionary(grouping: agents) { $0.workflow ?? $0.label }.values.sorted { $0.count != $1.count ? $0.count > $1.count : ($0.first?.id ?? "") < ($1.first?.id ?? "") }
        func title(_ group: [SubagentInfo]) -> String {
            let phases = Dictionary(grouping: group.compactMap(\.phase), by: { $0 }).max { $0.value.count < $1.value.count }?.key
            let text = phases ?? group.first?.label ?? "워크플로"
            return text.count > 9 ? String(text.prefix(9)) + "…" : text
        }
        var lines = ["로봇 \(agents.count)대 가동" + (stale.isEmpty ? "" : " · 멈춤? \(stale.count)")]
        for group in groups.prefix(2) { lines.append("\(title(group)) · \(group.count)") }
        if groups.count > 2, lines.count > 2 { lines[2] += " 외 \(groups.count - 2)" }
        if let first = stale.first {
            let name = first.info.label.count > 8 ? String(first.info.label.prefix(8)) + "…" : first.info.label
            let line = "멈춤? · \(name)" + (stale.count > 1 ? " 외 \(stale.count - 1)" : "")
            if lines.count > 2 { lines[2] = line } else { lines.append(line) }
        } else if residue > 0 {
            let line = "잔재 \(residue)대 · 주인 없음"
            if lines.count > 2 { lines[2] = line } else { lines.append(line) }
        }
        return lines
    }
}
