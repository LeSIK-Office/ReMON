import AppKit
import ReMONCore
import SpriteKit

/// 도구실 배치(가상 px). 로비(36~226) 오른쪽 228~468: 2단 팔레트 랙 5칸 × 2단 = 10자리 + 오른쪽 끝 반입구(뒷벽 셔터, 트럭이 대 있다).
/// 앱은 사람이 아니라 기계다: 새 앱은 배송·설치 기사가 반입구로 들여와 칸에 설치하고, 끝난 앱은 전원선을 뽑아 반입구로 내간다.
/// (10-25 대표 지적 '위치가 애매하다': 예전엔 로비와 기록 보관소 사이 중정의 벽난로 앞에 캐비닛 6대가 겹쳐 섰고 그 밖의 앱은 잘렸다.)
enum ToolRoom {
    static let x0 = 228
    /// 칸 가운데(왼쪽부터). 칸 너비 36 — 가장 큰 기계(26)도 양옆 5px씩 뜬다. 기둥은 칸 가운데 ±18.
    static let bayXs: [CGFloat] = [248, 284, 320, 356, 392]
    static let bayHalf: CGFloat = 18
    /// 위 단 선반 윗면(바닥선 위).
    static let upperY: CGFloat = 40
    static let capacity = 10
    /// 콘센트: 칸 가운데에서 오른쪽 기둥 쪽으로(바닥 위 8px).
    static let socketDX: CGFloat = 16
    /// 반입구(뒷벽 셔터) 가운데 · 열린 곳 왼쪽 끝 · 폭 · 높이.
    static let dockX: CGFloat = 444
    static let dockLeft: CGFloat = 430
    static let dockWidth: CGFloat = 28
    static let dockHeight: CGFloat = 38
    /// 랙 끝(410)과 반입구 사이 게시판(+N 표지).
    static let boardX: CGFloat = 420
    /// 천장 작업등(밤에는 불빛).
    static let lampXs = [284, 356]

    static func isUpper(_ slot: Int) -> Bool { slot >= 5 }
    static func bayX(_ slot: Int) -> CGFloat { bayXs[slot % 5] }
    /// 자리 → 기계 아래 가운데(위 단이면 선반 높이).
    static func point(_ slot: Int, floorLine: CGFloat) -> CGPoint { CGPoint(x: bayX(slot), y: floorLine + (isUpper(slot) ? upperY : 0)) }
    /// 메모리 순위(0 = 가장 큼) → 기계 크기.
    static func rankSize(_ rank: Int) -> Int { rank == 0 ? 3 : rank <= 2 ? 2 : rank <= 5 ? 1 : 0 }
}

/// 반입구와 배송·설치 기사. 한 번에 한 건(배송 또는 회수)씩, 밀린 일이 둘을 넘으면 넘는 건은 연출 없이 바로 처리한다.
/// 배송: 셔터가 말려 올라가고 기사가 나무 상자를 실은 리프트 수레를 끌고 들어와 칸 앞에 선다 → 위 단이면 수레에 올라 짐판을 올린다 →
///       상자를 칸에 내려놓고 지렛대로 뜯는다(판자가 튄다) → 무릎 꿇고 볼트를 조인다(불꽃) → 화면이 켜진다 → 내려와 빈 수레를 밀고 나간다.
/// 회수: 빈 수레를 끌고 들어와 칸 앞 → (위 단이면 올라가) 전원선을 뽑고(불꽃) 기계를 싣는다 → 내려와 반입구로 밀고 나간다.
/// 사람 · 상자 · 기계는 늘 바닥 · 선반 · 짐판 위에만 있다: 오르내림은 짐판과 함께, 싣고 내리는 것은 한 번에(검수 '뜬 것 없음').
final class ToolDock: SKNode {
    enum Kind { case deliver, remove }

    final class Job {
        let kind: Kind
        let node: ToolMachineNode
        let slot: Int
        let name: String
        /// 배송: 볼트를 다 조이고 화면이 켜진 순간.
        let installed: (() -> Void)?
        /// 기사가 반입구로 나간 뒤(회수 = 기계가 건물을 나감 · 취소된 배송 = 자리가 빔).
        let finished: () -> Void
        var cancelled = false
        var started: TimeInterval = 0

        init(kind: Kind, node: ToolMachineNode, slot: Int, name: String, installed: (() -> Void)? = nil, finished: @escaping () -> Void) {
            self.kind = kind
            self.node = node
            self.slot = slot
            self.name = name
            self.installed = installed
            self.finished = finished
        }
    }

    /// 짐판 높이: 접었을 때 바닥 위 10, 다 올리면 위 단 선반(40).
    static let deckRest: CGFloat = 10
    static let maxLift: CGFloat = ToolRoom.upperY - deckRest

    let door = SKSpriteNode()
    let crew = SKNode()
    let courier = SKSpriteNode()
    private let base = SKSpriteNode()
    private let arms = SKSpriteNode()
    private let deck = SKSpriteNode()
    private var crate: SKSpriteNode?
    private var carried: ToolMachineNode?
    private(set) var lift: CGFloat = 0
    private(set) var riding = false
    private(set) var queue: [Job] = []
    private(set) var current: Job?
    private(set) var floorLine: CGFloat = 0
    private(set) var openness: Double = 0
    private var clock: TimeInterval = 0
    var onSay: ((SKSpriteNode, String, TextBadge.Style) -> Void)?
    var onJobStart: ((Job) -> Void)?
    /// 검수용 기록(문 열림 · 상자 뜯음 · 볼트 · 전원선 · 싣기 · 나감).
    private(set) var log: [String] = []

    override init() {
        super.init()
        door.anchorPoint = .zero
        door.size = CGSize(width: ToolRoom.dockWidth, height: ToolRoom.dockHeight)
        door.zPosition = 2.6
        addChild(door)
        showDoor(0)
        crew.zPosition = 6
        crew.isHidden = true
        addChild(crew)
        base.texture = TextureCache.shared.texture("lift-base") { MachineArt.liftBase() }
        base.size = CGSize(width: 38, height: 16)
        base.anchorPoint = CGPoint(x: 0.5, y: 0)
        crew.addChild(base)
        arms.anchorPoint = CGPoint(x: 0.5, y: 0)
        arms.position = CGPoint(x: 2, y: 6)
        arms.zPosition = 0.1
        crew.addChild(arms)
        deck.texture = TextureCache.shared.texture("lift-deck") { MachineArt.liftDeck() }
        deck.size = CGSize(width: 34, height: 3)
        deck.anchorPoint = CGPoint(x: 0.5, y: 0)
        deck.zPosition = 0.2
        crew.addChild(deck)
        courier.anchorPoint = CGPoint(x: 0.5, y: 0)
        courier.zPosition = 1
        crew.addChild(courier)
        setLift(0)
        stand()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 짐판 윗면(수레 기준).
    var top: CGFloat { Self.deckRest + lift }
    var busy: Bool { current != nil }

    /// 층이 바뀌면(로비 바닥선) 셔터 · 수레 높이를 맞춘다.
    func place(floorLine: CGFloat) {
        self.floorLine = floorLine
        door.position = CGPoint(x: ToolRoom.dockLeft, y: floorLine)
        crew.position.y = floorLine
    }

    func tick(activeTime: TimeInterval) {
        clock = activeTime
        // 안전망: 한 건이 60초 넘게 끝나지 않으면(연출이 끊김) 연출 없이 끝낸다.
        if let job = current, activeTime - job.started > 60 { snap(job) }
    }

    // MARK: 일거리

    func enqueue(_ job: Job) {
        if queue.count >= 2 { finishInstantly(job); return }
        queue.append(job)
        startNext()
    }

    /// 앱이 배송 도중에 끝났을 때: 아직 줄에 있으면 빼고(자리 비움), 하는 중이면 취소 표시(상자를 뜯기 전이면 도로 싣고 나간다).
    /// 이미 뜯었으면 false — 장면이 평소처럼 회수를 맡긴다.
    func cancel(_ node: ToolMachineNode) -> Bool {
        if let index = queue.firstIndex(where: { $0.node === node && $0.kind == .deliver }) {
            let job = queue.remove(at: index)
            node.removeFromParent()
            job.finished()
            return true
        }
        if let job = current, job.node === node, job.kind == .deliver, !node.installed {
            job.cancelled = true
            return node.isHidden   // 뜯기 전 = 상자째 도로 나간다. 이미 뜯었으면(볼트 조이는 중) 장면이 회수를 맡긴다.
        }
        return false
    }

    private func startNext() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        current = job
        job.started = clock
        onJobStart?(job)
        switch job.kind {
        case .deliver: beginDelivery(job)
        case .remove: beginRemoval(job)
        }
    }

    /// 밀린 일: 연출 없이 바로(배송 = 먼지와 함께 설치 · 회수 = 전원선을 뽑고 사라짐).
    private func finishInstantly(_ job: Job) {
        switch job.kind {
        case .deliver:
            job.node.isHidden = false
            job.node.installed = true
            job.node.powerOn()
            if let parent = job.node.parent { Effects.burst(in: parent, at: CGPoint(x: job.node.position.x, y: job.node.position.y + 3), color: PixelColor(0xD9D2C2), count: 6, spread: 10, rise: 6, duration: 0.5) }
            job.installed?()
        case .remove:
            job.node.unplug()
            job.node.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
        }
        log.append("바로 처리 · \(job.name)")
        job.finished()
    }

    /// 안전망: 하던 일을 그 자리에서 끝낸다(사람 · 수레를 숨기고 셔터를 닫는다).
    private func snap(_ job: Job) {
        crew.removeAllActions()
        removeAction(forKey: "doorTimer")
        if let box = crate { box.removeFromParent(); crate = nil }
        if job.kind == .deliver, !job.cancelled, !job.node.installed {
            job.node.isHidden = false
            job.node.installed = true
            job.node.powerOn()
            job.installed?()
        }
        if job.kind == .deliver, job.cancelled, job.node.isHidden { job.node.removeFromParent() }
        log.append("안전망 · \(job.name)")
        end(job)
    }

    private func end(_ job: Job) {
        crew.isHidden = true
        crew.alpha = 1
        riding = false
        setLift(0)
        if let carried { carried.removeFromParent(); self.carried = nil }
        if let box = crate { box.removeFromParent(); crate = nil }
        setDoor(open: false)
        current = nil
        job.finished()
        startNext()
    }

    // MARK: 배송

    private func beginDelivery(_ job: Job) {
        enter()
        let box = SKSpriteNode(texture: TextureCache.shared.texture("crate\(job.node.size)") { MachineArt.crate(job.node.size) })
        box.anchorPoint = CGPoint(x: 0.5, y: 0)
        box.position = CGPoint(x: 3, y: top)
        box.zPosition = 0.5
        crew.addChild(box)
        crate = box
        log.append("배송 시작 · \(job.name)")
        let lines = ["배송 왔습니다!", "새 기계 들어갑니다", "설치 기사 출동!", "\(job.name) 왔어요"]
        crew.run(.sequence([
            .wait(forDuration: 0.4),
            .fadeIn(withDuration: 0.25),
            .run { [weak self] in guard let self else { return }; self.onSay?(self.courier, Variety.shared.line("courierIn", lines), .bubble) },
            walk(to: ToolRoom.bayX(job.slot) - 3, speed: 46, pushing: false),
            .run { [weak self] in self?.deliveryAtBay(job) }
        ]), withKey: "job")
        closeDoorSoon()
    }

    private func deliveryAtBay(_ job: Job) {
        guard !job.cancelled else { abortDelivery(job); return }
        guard ToolRoom.isUpper(job.slot) else { unloadCrate(job); return }
        board()
        crew.run(.sequence([raise(to: Self.maxLift, duration: 0.9), .run { [weak self] in self?.unloadCrate(job) }]), withKey: "job")
    }

    /// 상자를 칸에 내려놓는다(수레 앞 → 칸 뒤로, 한 번에 · 쿵 먼지). 아래 단이면 기사가 상자 왼쪽으로 붙어 선다.
    private func unloadCrate(_ job: Job) {
        guard !job.cancelled else { abortDelivery(job); return }
        guard let box = crate, let world = parent else { snap(job); return }
        let point = ToolRoom.point(job.slot, floorLine: floorLine)
        box.removeFromParent()
        box.position = point
        box.zPosition = 3.1
        world.addChild(box)
        Effects.burst(in: world, at: CGPoint(x: point.x, y: point.y + 2), color: PixelColor(0xD9D2C2), count: 6, spread: 12, rise: 5, duration: 0.45)
        if !riding { courier.position = CGPoint(x: -18, y: 0) }
        face(right: true)
        loop([.pry(0), .pry(1)], fps: 4)
        onSay?(courier, Variety.shared.line("courierPry", ["개봉 박두!", "뜯습니다~", "포장 엄청 많네", "조심조심…"]), .bubble)
        log.append("상자 내려놓음 · \(job.name)")
        crew.run(.sequence([.wait(forDuration: 1.1), .run { [weak self] in self?.openCrate(job) }]), withKey: "job")
    }

    /// 지렛대로 뜯기: 판자 세 조각이 튀고 기계가 드러난다 → 무릎 꿇고 볼트(불꽃 두 번) → 화면이 켜진다.
    private func openCrate(_ job: Job) {
        guard !job.cancelled else { abortDelivery(job); return }
        guard let box = crate, let world = parent else { snap(job); return }
        let point = box.position
        let size = box.size
        box.removeFromParent()
        crate = nil
        splinter(in: world, at: point, size: size)
        job.node.isHidden = false
        job.node.alpha = 1
        Effects.sparkle(in: world, at: CGPoint(x: point.x, y: point.y + size.height + 2))
        log.append("상자 뜯음 · \(job.name)")
        loop([.kneel(0), .kneel(1)], fps: 6)
        let node = job.node
        crew.run(.sequence([
            .wait(forDuration: 0.3),
            .run { [weak self] in self?.spark(at: CGPoint(x: node.position.x - node.width / 2 + 2, y: node.position.y + 1)) },
            .wait(forDuration: 0.45),
            .run { [weak self] in self?.spark(at: CGPoint(x: node.position.x + node.width / 2 - 2, y: node.position.y + 1)) },
            .wait(forDuration: 0.45),
            .run { [weak self] in self?.installDone(job) }
        ]), withKey: "job")
    }

    private func installDone(_ job: Job) {
        job.node.installed = true
        stand()
        if job.cancelled {
            // 볼트를 조이는 사이 앱이 끝났다: 화면을 켜지 않는다(이어지는 회수가 내간다).
            log.append("설치 직후 종료 · \(job.name)")
        } else {
            job.node.powerOn()
            log.append("설치 끝 · \(job.name)")
            job.installed?()
            onSay?(courier, "\(job.name) 설치 끝!", .bubble)
        }
        crew.run(.sequence([.wait(forDuration: 0.5), .run { [weak self] in self?.descendAndLeave(job) }]), withKey: "job")
    }

    /// 뜯기 전에 앱이 끝났다: 상자를 도로 싣고 나간다.
    private func abortDelivery(_ job: Job) {
        if let box = crate, box.parent !== crew {
            box.removeFromParent()
            box.position = CGPoint(x: 3, y: top)
            box.zPosition = 0.5
            crew.addChild(box)
        }
        log.append("배송 취소 · \(job.name)")
        onSay?(courier, Variety.shared.line("courierCancel", ["주문 취소래요", "어? 벌써 껐어요?", "도로 싣습니다"]), .bubble)
        descendAndLeave(job)
    }

    // MARK: 회수

    private func beginRemoval(_ job: Job) {
        enter()
        log.append("회수 시작 · \(job.name)")
        crew.run(.sequence([
            .wait(forDuration: 0.4),
            .fadeIn(withDuration: 0.25),
            .run { [weak self] in guard let self else { return }; self.onSay?(self.courier, Variety.shared.line("courierOut", ["회수하러 왔습니다", "이 기계 퇴근이요", "전원 내렸죠?", "\(job.name) 데려갑니다"]), .bubble) },
            walk(to: ToolRoom.bayX(job.slot) - 3, speed: 46, pushing: false),
            .run { [weak self] in self?.removalAtBay(job) }
        ]), withKey: "job")
        closeDoorSoon()
    }

    private func removalAtBay(_ job: Job) {
        guard ToolRoom.isUpper(job.slot) else { unplugMachine(job); return }
        board()
        crew.run(.sequence([raise(to: Self.maxLift, duration: 0.9), .run { [weak self] in self?.unplugMachine(job) }]), withKey: "job")
    }

    /// 무릎 꿇고 전원선을 뽑는다(콘센트에서 불꽃) → 기계를 짐판에 싣는다(한 번에).
    private func unplugMachine(_ job: Job) {
        if !riding { courier.position = CGPoint(x: -18, y: 0) }
        face(right: true)
        loop([.kneel(0), .kneel(1)], fps: 6)
        let node = job.node
        crew.run(.sequence([
            .wait(forDuration: 0.5),
            .run { [weak self] in
                guard let self else { return }
                node.unplug()
                self.spark(at: node.socketPoint)
                self.log.append("전원선 뽑음 · \(job.name)")
                self.onSay?(self.courier, Variety.shared.line("courierUnplug", ["뽑았어요", "플러그 OK", "전원 차단!"]), .bubble)
            },
            .wait(forDuration: 0.6),
            .run { [weak self] in self?.loadMachine(job) }
        ]), withKey: "job")
    }

    private func loadMachine(_ job: Job) {
        let node = job.node
        if let world = node.parent { Effects.burst(in: world, at: CGPoint(x: node.position.x, y: node.position.y + 2), color: PixelColor(0xD9D2C2), count: 5, spread: 10, rise: 5, duration: 0.4) }
        node.removeAllActions()
        node.removeFromParent()
        node.position = CGPoint(x: 3, y: top)
        node.zPosition = 0.5
        node.alpha = 1
        crew.addChild(node)
        carried = node
        stand()
        log.append("기계 실음 · \(job.name)")
        crew.run(.sequence([.wait(forDuration: 0.35), .run { [weak self] in self?.descendAndLeave(job) }]), withKey: "job")
    }

    // MARK: 움직임

    /// 반입구 앞에 수레를 세운다(아직 투명) · 셔터를 올린다. 기사는 수레 왼쪽에서 왼쪽을 보고 끌고 들어온다.
    private func enter() {
        crew.removeAllActions()
        crew.position = CGPoint(x: ToolRoom.dockX, y: floorLine)
        crew.alpha = 0
        crew.isHidden = false
        riding = false
        setLift(0)
        courier.position = CGPoint(x: -26, y: 0)
        face(right: false)
        stand()
        setDoor(open: true)
        log.append("셔터 열림")
    }

    /// 수레가 반입구를 벗어나면 셔터를 내린다.
    private func closeDoorSoon() {
        run(.sequence([.wait(forDuration: 1.6), .run { [weak self] in self?.setDoor(open: false) }]), withKey: "doorTimer")
    }

    /// (위였으면) 짐판을 내리고 바닥으로 내려선 뒤 반입구로 밀고 나간다 — 셔터는 닿기 조금 전에 올라간다.
    private func descendAndLeave(_ job: Job) {
        var steps: [SKAction] = []
        if lift > 0 { steps.append(raise(to: 0, duration: 0.9)) }
        steps.append(.run { [weak self] in
            guard let self else { return }
            self.riding = false
            self.courier.position = CGPoint(x: -26, y: 0)
            let travel = TimeInterval(abs(ToolRoom.dockX - self.crew.position.x) / 70)
            self.run(.sequence([.wait(forDuration: max(0, travel - 0.5)), .run { [weak self] in self?.setDoor(open: true) }]), withKey: "doorTimer")
            self.crew.run(.sequence([
                self.walk(to: ToolRoom.dockX, speed: 70, pushing: true),
                .fadeOut(withDuration: 0.25),
                .run { [weak self] in
                    guard let self else { return }
                    self.log.append("반입구로 나감 · \(job.name)")
                    if job.kind == .deliver, job.cancelled, job.node.isHidden { job.node.removeFromParent() }
                    self.end(job)
                }
            ]), withKey: "job")
        })
        crew.run(.sequence(steps), withKey: "job")
    }

    /// 걷기(수레와 함께). 거리는 만드는 순간의 위치로 잰다 — 단계마다 그 자리에서 만든다(가는 도중에는 만들지 않는다).
    private func walk(to x: CGFloat, speed: CGFloat, pushing: Bool) -> SKAction {
        let right = x > crew.position.x
        return .sequence([
            .run { [weak self] in
                self?.face(right: right)
                self?.loop((0..<4).map { pushing ? WorkerPose.push($0) : .walk($0) }, fps: 8)
            },
            .moveTo(x: x, duration: TimeInterval(max(0.05, abs(x - crew.position.x) / speed))),
            .run { [weak self] in self?.stand() }
        ])
    }

    /// 수레에 오른다: 짐판 왼쪽(상자 왼편)에 서서 오른쪽(칸)을 본다.
    private func board() {
        riding = true
        courier.position = CGPoint(x: -10, y: top)
        face(right: true)
        stand()
    }

    /// 짐판을 올리고 내린다(기사 · 짐이 함께).
    private func raise(to target: CGFloat, duration: TimeInterval) -> SKAction {
        let from = lift
        return .customAction(withDuration: duration) { [weak self] _, elapsed in
            let t = min(1, elapsed / CGFloat(duration))
            self?.setLift(from + (target - from) * t)
        }
    }

    private func setLift(_ value: CGFloat) {
        lift = max(0, min(Self.maxLift, value.rounded()))
        let h = Int(lift) + 1
        arms.texture = TextureCache.shared.texture("lift-arms\(h)") { MachineArt.liftArms(height: h) }
        arms.size = CGSize(width: 30, height: h)
        deck.position = CGPoint(x: 2, y: top - 3)
        if let crate, crate.parent === crew { crate.position.y = top }
        carried?.position.y = top
        if riding { courier.position.y = top }
    }

    // MARK: 셔터 · 효과 · 자세

    private func setDoor(open: Bool, duration: TimeInterval = 0.4) {
        let target: Double = open ? 1 : 0
        let from = openness
        guard abs(target - from) > 0.01 else { return }
        var steps: [SKAction] = []
        for i in 1...4 {
            let value = from + (target - from) * Double(i) / 4
            steps.append(.wait(forDuration: duration / 4))
            steps.append(.run { [weak self] in self?.showDoor(value) })
        }
        door.run(.sequence(steps), withKey: "door")
    }

    private func showDoor(_ value: Double) {
        openness = value
        let key = (value * 4).rounded() / 4
        door.texture = TextureCache.shared.texture("dock-shutter-\(key)") { MachineArt.dockShutter(open: key) }
    }

    private func splinter(in world: SKNode, at point: CGPoint, size: CGSize) {
        let w = Int(size.width), h = Int(size.height)
        let pieces: [(PixelCanvas, CGPoint, CGFloat, CGFloat)] = [
            (MachineArt.plank(width: 3, height: h), CGPoint(x: point.x - size.width / 2 + 1, y: point.y + size.height / 2), -14, 0.9),
            (MachineArt.plank(width: 3, height: h), CGPoint(x: point.x + size.width / 2 - 1, y: point.y + size.height / 2), 14, -0.9),
            (MachineArt.plank(width: w, height: 3), CGPoint(x: point.x, y: point.y + size.height - 1), 4, 0.5),
        ]
        for (index, piece) in pieces.enumerated() {
            let texture = TextureCache.shared.texture("plank-\(piece.0.width)x\(piece.0.height)") { piece.0 }
            let node = SKSpriteNode(texture: texture)
            node.position = piece.1
            node.zPosition = 6.5
            world.addChild(node)
            node.run(.sequence([.group([.moveBy(x: piece.2, y: index == 2 ? 8 : 4, duration: 0.35), .rotate(byAngle: piece.3, duration: 0.35)]),
                                .group([.moveBy(x: piece.2 * 0.3, y: -10, duration: 0.3), .fadeOut(withDuration: 0.3)]), .removeFromParent()]))
        }
        Effects.burst(in: world, at: CGPoint(x: point.x, y: point.y + size.height / 2), color: PixelColor(0xC8975A), count: 8, spread: 14, rise: 10, duration: 0.5)
    }

    private func spark(at point: CGPoint) {
        guard let world = parent else { return }
        Effects.burst(in: world, at: point, color: PixelColor(0xFFD34E), count: 7, spread: 6, rise: 7, duration: 0.35)
        Effects.burst(in: world, at: point, color: PixelColor(0xFFFFFF), count: 3, spread: 3, rise: 4, duration: 0.25)
    }

    private func texture(_ pose: WorkerPose) -> SKTexture { TextureCache.shared.texture("courier-\(pose)") { CharacterArt.courierSprite(pose) } }

    private func stand() {
        courier.removeAction(forKey: "pose")
        let texture = texture(.stand(blink: false))
        courier.texture = texture
        courier.size = texture.size()
    }

    private func loop(_ poses: [WorkerPose], fps: Double) {
        let textures = poses.map(texture)
        courier.removeAction(forKey: "pose")
        courier.texture = textures.first
        courier.size = textures.first?.size() ?? .zero
        courier.run(.repeatForever(.animate(with: textures, timePerFrame: 1 / fps, resize: true, restore: false)), withKey: "pose")
    }

    private func face(right: Bool) { courier.xScale = right ? 1 : -1 }

    // MARK: 검수용

    struct Probe {
        var visible: Bool
        /// 수레 가운데 x · 수레 바닥 y(부모 좌표)
        var cartX: CGFloat
        var cartY: CGFloat
        var courierX: CGFloat
        var courierY: CGFloat
        var riding: Bool
        /// 짐판 윗면(부모 좌표)
        var deckTop: CGFloat
        /// 수레 위 짐(상자 · 기계)의 바닥, 없으면 nil
        var cargoY: CGFloat?
        /// 칸에 내려놓은(아직 안 뜯은) 상자의 바닥, 없으면 nil
        var crateOnBayY: CGFloat?
        var door: Double
    }

    var probe: Probe {
        let onCart = crate?.parent === crew ? crate : nil
        let cargo: CGFloat? = carried.map { crew.position.y + $0.position.y } ?? onCart.map { crew.position.y + $0.position.y }
        let bay = crate.flatMap { $0.parent === crew ? nil : $0.position.y }
        return Probe(visible: !crew.isHidden && crew.alpha > 0.5, cartX: crew.position.x, cartY: crew.position.y,
                     courierX: crew.position.x + courier.position.x, courierY: crew.position.y + courier.position.y, riding: riding,
                     deckTop: crew.position.y + top, cargoY: cargo, crateOnBayY: bay, door: openness)
    }
}

// MARK: - 장면: 도구실(앱 기계 배치 · 반입구 · 폭주 · 커짐 · +N)

extension OfficeScene {
    /// 앱마다 크기 상태: 지금 크기 · 기준 메모리(마지막으로 크기가 바뀐 때) · 순위로 정한 크기(두 번 연속 같아야 따른다) · 후보.
    struct ToolGrowth {
        var size: Int
        var ref: UInt64
        var stable: Int
        var pending: Int?
    }

    private static func eligibleApps(_ snapshot: OfficeSnapshot) -> [AppGroup] {
        snapshot.apps.filter { $0.category != .system && $0.category != .other && $0.id != "claude-daemon" }
            .sorted { $0.footprint != $1.footprint ? $0.footprint > $1.footprint : $0.id < $1.id }
    }

    private static func shortName(_ app: AppGroup) -> String {
        app.name.replacingOccurrences(of: " · Codex Desktop", with: "").replacingOccurrences(of: "Google ", with: "")
    }

    /// 도구실: 앱(기계) 최대 10대를 2단 랙에 둔다. 새로 켠 앱 = 반입구 배송 · 끝난 앱 = 반입구 회수(처음 채울 때는 바로).
    /// 실행 중인데 10대 밖으로 밀린 앱은 반입구로 내가지 않는다(끝난 것처럼 보이면 안 된다) — 조용히 바꿔 달고 '+N'으로 센다.
    func updateTools(_ snapshot: OfficeSnapshot) {
        let ranked = Self.eligibleApps(snapshot)
        var present: [String: AppGroup] = [:]
        for app in ranked where present[app.id] == nil { present[app.id] = app }
        var rank: [String: Int] = [:]
        for (index, app) in ranked.enumerated() where rank[app.id] == nil { rank[app.id] = index }
        // ① 끝난 앱: 반입구로 내간다
        for id in Array(tools.keys) where present[id] == nil { removeTool(id, animated: toolsInitialized, reason: "종료") }
        // ② 빈 자리에 앱을 들인다(처음엔 큰 순서대로 아래 단부터, 그 뒤로는 새로 켠 앱 = 배송 · 밀렸던 앱 = 조용히)
        var used = Set(toolSlotOf.values).union(toolsLeaving.values)
        func freeSlot() -> Int? { (0..<ToolRoom.capacity).first { !used.contains($0) } }
        for app in ranked where tools[app.id] == nil && toolsLeaving[app.id] == nil {
            guard let slot = freeSlot() else { break }
            let fresh = toolsInitialized && !toolSeen.contains(app.id)
            installTool(app, slot: slot, rank: rank[app.id] ?? 9, mode: !toolsInitialized ? .instant : fresh ? .dock : .quiet)
            used.insert(slot)
        }
        // ③ 밀린 앱이 보이는 앱보다 훨씬 크면(2배 넘고 256MB 넘게 차이) 한 스냅샷에 한 대씩 조용히 바꿔 단다
        if toolsInitialized, let big = ranked.first(where: { tools[$0.id] == nil && toolsLeaving[$0.id] == nil }),
           let small = tools.filter({ $0.value.installed && present[$0.key] != nil }).min(by: { (present[$0.key]?.footprint ?? 0) < (present[$1.key]?.footprint ?? 0) }),
           let smallApp = present[small.key], big.footprint > smallApp.footprint * 2, big.footprint - smallApp.footprint > 256 << 20,
           let slot = toolSlotOf[small.key] {
            removeTool(small.key, animated: false, reason: "교체")
            installTool(big, slot: slot, rank: rank[big.id] ?? 9, mode: .quiet)
        }
        // ④ 크기 · 활동 · 아이콘 · 이름표
        for (id, node) in tools {
            guard let app = present[id] else { continue }
            updateGrowth(id, node: node, app: app, rank: rank[id] ?? 9)
            node.setIcon(app.pids.lazy.compactMap { NSRunningApplication(processIdentifier: $0)?.icon }.first, key: id)
            if node.setActivity(cpu: app.cpuPercent), node.installed, !node.isHidden, toolsInitialized {
                toolLog.append("폭주 · \(Self.shortName(app))")
                floatTag("폭주!", at: CGPoint(x: node.position.x, y: node.position.y + node.height + 8))
                requestShot(Shot(target: .rect(CGRect(x: node.position.x - 70, y: node.position.y - 16, width: 140, height: 76)),
                                 caption: "폭주 · \(Self.shortName(app)) · CPU \(Fmt.percent(app.cpuPercent))", duration: 4.5, priority: 1))
            }
            // 이름표: 이름 · 메모리(폭주 중이면 CPU도 — 무엇이 폭주인지 숫자로).
            toolLabels[id]?.set("\(String(Self.shortName(app).prefix(9))) \(Fmt.gb(app.footprint))" + (node.bursting ? " · CPU \(Fmt.percent(app.cpuPercent))" : ""))
        }
        // ⑤ 넘친 앱 수(+N)
        let overflow = ranked.filter { tools[$0.id] == nil && toolsLeaving[$0.id] == nil }.count
        setToolOverflow(overflow)
        toolSeen = Set(present.keys)
        toolsInitialized = true
        repositionToolLabels()
    }

    private enum ToolArrival { case instant, quiet, dock }

    private func installTool(_ app: AppGroup, slot: Int, rank: Int, mode: ToolArrival) {
        let node = ToolMachineNode(id: app.id)
        node.zPosition = 3   // 사람(4~6)보다 뒤 — 화면 · 경광등 · 표시등까지 포함해서(ToolMachineNode 주석)
        let size = ToolRoom.rankSize(rank)
        node.setSize(size)
        node.position = ToolRoom.point(slot, floorLine: line(lobbyFloor))
        world.addChild(node)
        tools[app.id] = node
        toolSlotOf[app.id] = slot
        toolGrowth[app.id] = ToolGrowth(size: size, ref: app.footprint, stable: size, pending: nil)
        let label = TextBadge("", style: .tiny)
        label.isHidden = true
        overlay.addChild(label)
        toolLabels[app.id] = label
        let name = Self.shortName(app)
        node.title = name
        switch mode {
        case .instant:
            break
        case .quiet:
            node.alpha = 0
            node.run(.fadeIn(withDuration: 0.4))
            toolLog.append("조용히 들임 · \(name)")
        case .dock:
            node.isHidden = true
            node.installed = false
            node.powerDown()
            toolLog.append("배송 · \(name) → \(slot)")
            toolDock.enqueue(ToolDock.Job(kind: .deliver, node: node, slot: slot, name: String(name.prefix(10)), installed: { [weak self] in
                self?.repositionToolLabels()
            }, finished: { [weak self, weak node] in
                // 상자째 도로 나갔으면(앱이 금방 끝남) 자리를 비운다. 설치까지 마쳤으면 그대로(회수는 따로 온다).
                guard let self, node?.parent == nil, self.tools[app.id] == nil else { return }
                self.toolsLeaving[app.id] = nil
            }))
        }
    }

    /// 앱이 끝났다(또는 바꿔 달림): 화면이 꺼지고, 설치 기사가 전원선을 뽑아 반입구로 내간다. animated가 false면 조용히 사라진다.
    func removeTool(_ id: String, animated: Bool, reason: String) {
        guard let node = tools[id], let slot = toolSlotOf[id] else { return }
        tools[id] = nil
        toolSlotOf[id] = nil
        toolGrowth[id] = nil
        toolLabels[id]?.removeFromParent()
        toolLabels[id] = nil
        let name = String(node.title.prefix(10))
        // 아직 배송 중(상자 속): 줄에서 빼거나 취소 — 뜯기 전이면 상자째 도로 나간다.
        if !node.installed {
            toolsLeaving[id] = slot
            if toolDock.cancel(node) {
                toolLog.append("배송 취소 · \(name)")
                if node.parent == nil { toolsLeaving[id] = nil }
                return
            }
        }
        node.powerDown()
        guard animated else {
            toolsLeaving[id] = nil
            toolLog.append("\(reason) · 조용히 · \(name)")
            node.run(.sequence([.fadeOut(withDuration: 0.35), .removeFromParent()]))
            return
        }
        toolsLeaving[id] = slot
        toolLog.append("회수 · \(name) ← \(slot)")
        toolDock.enqueue(ToolDock.Job(kind: .remove, node: node, slot: slot, name: String(name), finished: { [weak self] in
            self?.toolsLeaving[id] = nil
        }))
    }

    /// 크기: 순위로 정한 크기(두 번 연속 같아야)로 한 단씩 다가가고, 순위가 그대로여도 메모리가 기준보다 25% 넘게 늘면 한 단 커진다(이미 가장 크면 부풀기).
    /// 줄어드는 쪽: 순위로 정한 크기보다 크고, 메모리가 기준의 80% 밑으로 줄었거나 순위가 내려갔으면 한 단. 바뀔 때마다 '커짐' · '줄어듦' 표시.
    private func updateGrowth(_ id: String, node: ToolMachineNode, app: AppGroup, rank: Int) {
        guard var growth = toolGrowth[id] else { return }
        let target = ToolRoom.rankSize(rank)
        var droppedRank = false
        if target == growth.stable {
            growth.pending = nil
        } else if growth.pending == target {
            droppedRank = target < growth.stable
            growth.stable = target
            growth.pending = nil
        } else {
            growth.pending = target
        }
        let grew = Double(app.footprint) >= Double(growth.ref) * 1.25
        let shrank = Double(app.footprint) <= Double(growth.ref) * 0.8
        let name = Self.shortName(app)
        if growth.size < growth.stable {
            growth.size += 1
            growth.ref = app.footprint
            changeToolSize(node, to: growth.size, grew: true, name: name, why: "순위")
        } else if grew {
            growth.ref = app.footprint
            if growth.size < 3 {
                growth.size += 1
                changeToolSize(node, to: growth.size, grew: true, name: name, why: "메모리")
            } else {
                node.bulge()
                toolPuff(node, "커짐")
                toolLog.append("커짐(최대) · \(name)")
            }
        } else if growth.size > growth.stable, shrank || droppedRank {
            growth.size -= 1
            growth.ref = app.footprint
            changeToolSize(node, to: growth.size, grew: false, name: name, why: shrank ? "메모리" : "순위")
        } else if shrank {
            growth.ref = app.footprint
        }
        toolGrowth[id] = growth
    }

    private func changeToolSize(_ node: ToolMachineNode, to size: Int, grew: Bool, name: String, why: String) {
        node.setSize(size)
        toolLog.append("\(grew ? "커짐" : "줄어듦") · \(name) → \(size) · \(why)")
        guard node.installed, !node.isHidden, toolsInitialized else { return }
        node.bulge()
        toolPuff(node, grew ? "커짐" : "줄어듦")
    }

    /// 기계 위로 '커짐' · '줄어듦' 표지가 떠오르며 사라진다(김 같은 먼지와 함께).
    private func toolPuff(_ node: ToolMachineNode, _ text: String) {
        guard node.installed, !node.isHidden, node.parent === world else { return }
        Effects.burst(in: world, at: CGPoint(x: node.position.x, y: node.position.y + node.height + 2), color: text == "커짐" ? PixelColor(0xFFE29A) : PixelColor(0xC7D0DB), count: 8, spread: 10, rise: 8, duration: 0.6)
        floatTag(text, at: CGPoint(x: node.position.x, y: node.position.y + node.height + 6))
    }

    /// 앱 강제 종료: 경비원이 그 칸 콘센트로 가서 전원선을 잡아 뽑는다(불꽃 · 화면 꺼짐) → 설치 기사가 반입구로 내간다.
    /// 기계는 이때부터 경비원 몫이다(그사이 스냅샷에서 앱이 사라져도 기사가 먼저 오지 않게). 경비원 걸음이 끊겨도 10초 뒤엔 기사가 내간다.
    func evictStaff(_ id: String, shout: String?) {
        guard let node = tools[id], let slot = toolSlotOf[id], toolsLeaving[id] == nil else { return }
        guard node.installed else { removeTool(id, animated: true, reason: "강제 종료"); return }
        tools[id] = nil
        toolSlotOf[id] = nil
        toolGrowth[id] = nil
        toolLabels[id]?.removeFromParent()
        toolLabels[id] = nil
        toolsLeaving[id] = slot
        let socket = node.socketPoint
        var handed = false
        let hand: () -> Void = { [weak self, weak node] in
            guard let self, let node, !handed else { return }
            handed = true
            node.unplug()
            node.powerDown()
            Effects.burst(in: self.world, at: socket, color: PixelColor(0xFFD34E), count: 10, spread: 8, rise: 9, duration: 0.45)
            self.toolLog.append("강제 종료 · 전원선 뽑음 · \(node.title)")
            self.toolDock.enqueue(ToolDock.Job(kind: .remove, node: node, slot: slot, name: String(node.title.prefix(10)), finished: { [weak self] in
                self?.toolsLeaving[id] = nil
            }))
        }
        run(.sequence([.wait(forDuration: 10), .run(hand)]), withKey: "evict-\(id)")
        requestShot(Shot(target: .follow(guardNode, zoom: 2.6), caption: "강제 종료 · 경비원이 전원선을 뽑습니다" + (shout.map { " · \($0)" } ?? ""), duration: 9, priority: 3))
        let bubble = TextBadge(shout ?? Variety.shared.line("guard", Lines.guardLines), style: .shout)
        overlay.addChild(bubble)
        bubble.run(.repeatForever(.sequence([.wait(forDuration: 0.05), .run { [weak self] in
            guard let self else { return }
            bubble.position = CGPoint(x: (self.guardNode.position.x + 6) * self.pointsPerPixel, y: (self.guardNode.position.y + 42) * self.pointsPerPixel)
        }])))
        guardBusy = true
        guardNode.removeAction(forKey: "patrolWalk")
        moveGuard(toFloor: lobbyFloor, x: socket.x + 9) { [weak self] in
            guard let self else { return }
            self.setGuard(.dragged(0), faceRight: false)
            hand()
            self.removeAction(forKey: "evict-\(id)")
            self.guardNode.run(.sequence([.wait(forDuration: 0.9), .run { [weak self] in
                guard let self else { return }
                bubble.removeFromParent()
                self.moveGuard(toFloor: self.lobbyFloor, x: CGFloat(BuildingLayout.guardPostX)) { [weak self] in
                    self?.setGuard(.stand(blink: false))
                    self?.guardBusy = false
                }
            }]), withKey: "guardWait")
        }
    }

    // MARK: 이름표 · +N · 누르기

    func repositionToolLabels() {
        let zoomed = lodZoomed ?? false
        for (id, node) in tools {
            guard let label = toolLabels[id] else { continue }
            label.isHidden = !zoomed || !node.installed || node.isHidden || node.parent !== world
            label.position = CGPoint(x: node.position.x * pointsPerPixel, y: (node.position.y + node.height + 5) * pointsPerPixel)
        }
        if let badge = toolOverflowBadge {
            badge.position = CGPoint(x: ToolRoom.boardX * pointsPerPixel, y: (line(lobbyFloor) + 32) * pointsPerPixel)
        }
    }

    private func setToolOverflow(_ count: Int) {
        if count <= 0 {
            toolOverflowBadge?.isHidden = true
            return
        }
        let badge = toolOverflowBadge ?? {
            let made = TextBadge("", style: .plate)
            overlay.addChild(made)
            toolOverflowBadge = made
            return made
        }()
        badge.set("+\(count)")
        badge.isHidden = false
    }

    /// 누른 점의 앱(설치를 마친 기계만, 기계 크기 + 2px).
    func hitTool(_ point: CGPoint) -> String? {
        tools.first { id, node in
            node.installed && !node.isHidden && node.parent === world && toolsLeaving[id] == nil
                && CGRect(x: node.position.x - node.width / 2 - 2, y: node.position.y - 2, width: node.width + 4, height: node.height + 6).contains(point)
        }?.key
    }

    // MARK: 검수용

    /// 설치된 기계(자리 · 위치 · 크기 · 폭주 · 전원), 배송 · 회수 중인 기계는 installed가 false거나 목록에 없다.
    func toolInfo(_ id: String) -> (slot: Int, frame: CGRect, size: Int, installed: Bool, bursting: Bool, powered: Bool, node: ToolMachineNode)? {
        guard let node = tools[id], let slot = toolSlotOf[id] else { return nil }
        return (slot, CGRect(x: node.position.x - node.width / 2, y: node.position.y, width: node.width, height: node.height), node.size, node.installed, node.bursting, node.powered, node)
    }

    var toolIDs: [String] { Array(tools.keys) }
    var toolOverflowText: String? { toolOverflowBadge.flatMap { $0.isHidden ? nil : $0.currentText } }
    var toolDockProbe: ToolDock.Probe { toolDock.probe }
    var toolDockLog: [String] { toolDock.log }
    var toolDockBusy: Bool { toolDock.busy }
    var leavingToolIDs: [String] { Array(toolsLeaving.keys) }
    var lobbyFloor: Int { layout.lobbyIndex }
}
