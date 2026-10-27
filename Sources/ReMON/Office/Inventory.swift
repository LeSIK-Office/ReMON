import AppKit
import ReMONCore
import SpriteKit

// 디스크 정비 · 재고 조사(10-25 대표 지시: "여러 명 투입돼서 디스크 박스 내려놓고 분리하고, 내용 보여 주고, 삭제할 거 선택하면
// 다른 건 다시 올려놓고 삭제하는 것만 박스 까서 버려"). 디스크 지도 화면이 부르는 대로 기계실에서 연출한다.
// 시작: 인력 2~3명이 지하 엘리베이터로 내려와 저장고 앞에 분류 탁자를 펴고, 꼬리표 묶음 상자를 선반에서 탁자로 내린다(선반은 빈칸).
// 열기: 고른 묶음만 열어 작은 상자로 펼친다(최대 12개 + '+N' 판). 표시: 폐기 = 빨간 스티커 · 보관 = 초록.
// 실행: 보관할 상자는 선반으로 · 휴지통 상자는 '되돌릴 수 있음' 꼬리표를 달고 손수레로 엘리베이터 → 1층 기록 보관소(기록관이 받는다) ·
//       삭제 상자는 까서 압축기에 넣고 레버 → 꾹 · 정리 명령(prune)은 기술자가 단말기 수레를 밀고 와 치면 그 묶음 상자가 작아진다.
// 마침: 선반이 실제 값으로 다시 재어지고(실측) 한 명이 "실측 +X"(0이면 "줄어든 게 없어요")를 외친 뒤 엘리베이터로 나간다.
// 어떤 순서로 불러도 안전하다(필요하면 앞 단계를 그 자리에서 마친다). 마지막 호출 뒤 180초 넘게 마침 · 취소가 없으면 안전망이 끝낸다.
// 사람은 늘 바닥선 위에만 선다(상자 · 손수레 짐은 탁자 · 짐판 위) — 검수 '뜬 것 없음 · 엘리베이터 끼임 없음'.

extension Lines {
    static let stockEnter = ["재고 조사 나왔습니다", "선반부터 내릴게요", "분류 들어갑니다", "상자 좀 내려 볼게요"]
    static let stockOpen = ["열어 볼게요", "안에 뭐가 들었나", "하나씩 펼칩니다"]
    static let stockReturn = ["보관할 건 다시 올려요", "제자리로!", "이건 남겨 둡니다"]
    static let stockTruck = ["되돌릴 수 있게 금고로", "휴지통 금고로 갑니다", "기록 보관소로 모십니다"]
    static let stockCrush = ["까서 버립니다", "압축 들어갑니다", "꾹!"]
    static let stockPrune = ["정리 명령 입력 중", "prune 돌립니다", "명령 치는 중"]
    static let stockCount = ["재고 세는 중", "하나, 둘, 셋…", "선반 점검합니다", "숫자 맞나 볼게요"]
    static let archivistReceive = ["받았습니다 · 되돌릴 수 있어요", "휴지통 기록 보관할게요", "원래 자리 적어 둘게요"]
}

/// 재고 조사 인력 한 명(직원 — 에이전트 아님): 몸(좌우로 뒤집힘) · 오른쪽 손수레(뒤집히지 않음) · 짐판 위 상자 · 손에 든 상자.
/// 정리 명령 기술자도 같은 틀이다(손수레 자리에 단말기 수레).
final class StockHand: SKNode {
    enum Role: Equatable { case clerk(Int), technician }

    let role: Role
    let body = SKSpriteNode()
    let truck = SKSpriteNode()
    private(set) var cargo: [SKSpriteNode] = []
    private(set) var held: SKSpriteNode?
    /// 금고 심부름(1층 기록 보관소) 중 — 지하 인력이 나갈 때 따로 움직이고, 일을 마치면 스스로 사라진다.
    var errand = false
    /// 이 사람이 금고에 건넬 휴지통 항목 수(손수레에 실은 몫 — 건넬 때 기록관에게 알린다).
    var archiveCount = 0
    /// 손수레 왼쪽 끝(몸 가운데 기준).
    static let truckOffset: CGFloat = 6

    init(role: Role) {
        self.role = role
        super.init()
        body.anchorPoint = CGPoint(x: 0.5, y: 0)
        body.zPosition = 0.2
        addChild(body)
        truck.anchorPoint = .zero
        truck.position = CGPoint(x: Self.truckOffset, y: 0)
        truck.zPosition = 0.1
        truck.isHidden = true
        addChild(truck)
        if role == .technician {
            truck.texture = TextureCache.shared.texture("terminal-cart0") { DiskStockArt.terminalCart(0) }
            truck.size = CGSize(width: 18, height: 20)
        } else {
            truck.texture = TextureCache.shared.texture("hand-truck") { DiskStockArt.handTruck() }
            truck.size = CGSize(width: 10, height: 14)
        }
        stand()
    }

    required init?(coder: NSCoder) { fatalError() }

    func texture(_ pose: WorkerPose) -> SKTexture {
        switch role {
        case .clerk(let index): TextureCache.shared.texture("stock\(index)-\(pose)") { CharacterArt.stockSprite(index, pose) }
        case .technician: TextureCache.shared.texture("tech-\(pose)") { CharacterArt.technicianSprite(pose) }
        }
    }

    var facingRight: Bool { body.xScale > 0 }

    func face(right: Bool) { body.xScale = right ? 1 : -1 }

    /// 서 있기(상자를 들었으면 두 팔을 앞으로 — push 자세).
    func stand(right: Bool? = nil) {
        body.removeAction(forKey: "anim")
        let pose: WorkerPose = held == nil ? .stand(blink: false) : .push(1)
        let texture = texture(pose)
        body.texture = texture
        body.size = texture.size()
        if let right { face(right: right) }
        held?.position = CGPoint(x: 8, y: 7)
    }

    func loop(_ poses: [WorkerPose], fps: Double) {
        let textures = poses.map(texture)
        body.removeAction(forKey: "anim")
        body.texture = textures.first
        body.size = textures.first?.size() ?? .zero
        if textures.count > 1 { body.run(.repeatForever(.animate(with: textures, timePerFrame: 1 / fps, resize: true, restore: false)), withKey: "anim") }
    }

    /// 손수레 짐판 위에 상자를 얹는다(보이는 것은 3단까지 — 넘는 상자는 짐 속으로).
    func load(_ box: SKSpriteNode) {
        box.removeAllActions()
        box.removeFromParent()
        box.alpha = 1
        box.setScale(1)
        box.anchorPoint = CGPoint(x: 0.5, y: 0)
        box.zPosition = 0.15
        let level = min(2, cargo.count)
        box.position = CGPoint(x: Self.truckOffset + 6.5, y: 2 + CGFloat(level) * 6)
        if cargo.count >= 3 { box.isHidden = true }
        addChild(box)
        cargo.append(box)
    }

    /// 짐을 모두 내린다(장면이 받아 처리) — 건물 좌표로 바꿔 돌려준다.
    func unloadAll(into parent: SKNode) -> [SKSpriteNode] {
        let list = cargo
        cargo = []
        for box in list {
            let point = convert(box.position, to: parent)
            box.removeFromParent()
            box.position = point
            parent.addChild(box)
        }
        return list
    }

    func clearCargo() {
        cargo.forEach { $0.removeFromParent() }
        cargo = []
    }

    var cargoCount: Int { cargo.count }

    /// 상자를 손에 든다(몸의 자식 — 몸과 함께 좌우가 바뀐다). nil = 내려놓음.
    func hold(_ box: SKSpriteNode?) {
        held?.removeFromParent()
        held = box
        guard let box else { return }
        box.removeAllActions()
        box.removeFromParent()
        box.alpha = 1
        box.anchorPoint = CGPoint(x: 0.5, y: 0)
        box.position = CGPoint(x: 8, y: 7)
        box.zPosition = 0.3
        body.addChild(box)
    }

    /// 손에 든 상자를 놓아 건물 좌표로 돌려준다.
    func release(into parent: SKNode) -> SKSpriteNode? {
        guard let box = held else { return nil }
        held = nil
        let point = body.convert(box.position, to: parent)
        box.removeFromParent()
        box.position = point
        parent.addChild(box)
        return box
    }
}

/// 탁자 위 한 묶음(꼬리표): 선반 상자를 최대 3단까지 쌓는다.
final class TableStack: SKNode {
    let tag: DiskTag
    var bytes: UInt64
    private(set) var boxes: [SKSpriteNode] = []

    init(tag: DiskTag, bytes: UInt64, height: Int) {
        self.tag = tag
        self.bytes = bytes
        super.init()
        setHeight(height)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setHeight(_ value: Int) {
        let height = max(1, min(3, value))
        while boxes.count > height { boxes.removeLast().removeFromParent() }
        while boxes.count < height {
            let index = boxes.count
            let box = SKSpriteNode(texture: DiskShelves.texture(tag, dashed: false, variant: index))
            box.anchorPoint = CGPoint(x: 0.5, y: 0)
            box.size = DiskShelves.boxSize
            box.position = CGPoint(x: index % 2 == 0 ? 0 : 1, y: CGFloat(index) * 8)
            box.zPosition = CGFloat(index) * 0.01
            addChild(box)
            boxes.append(box)
        }
    }

    var height: CGFloat { CGFloat(boxes.count) * 8 }
}

/// 탁자 위 항목 상자(작게) + 스티커(폐기 빨강 · 보관 초록).
final class ItemBox: SKSpriteNode {
    private(set) var item: DiskStockItem
    let sticker = SKSpriteNode()

    init(item: DiskStockItem) {
        self.item = item
        let texture = TextureCache.shared.texture("item-box-\(item.tag.rawValue)") { DiskStockArt.itemBox(item.tag) }
        super.init(texture: texture, color: .clear, size: CGSize(width: 7, height: 6))
        anchorPoint = CGPoint(x: 0.5, y: 0)
        sticker.anchorPoint = CGPoint(x: 0.5, y: 0)
        sticker.size = CGSize(width: 3, height: 2)
        sticker.position = CGPoint(x: 1.5, y: 1)
        sticker.zPosition = 0.01
        addChild(sticker)
        setMarked(item.marked, pop: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    var path: String { item.path }

    func setMarked(_ marked: Bool, pop: Bool) {
        item.marked = marked
        sticker.texture = TextureCache.shared.texture("sticker-\(marked ? 1 : 0)") { DiskStockArt.sticker(marked: marked) }
        if pop { sticker.run(.sequence([.scale(to: 1.8, duration: 0.08), .scale(to: 1, duration: 0.12)]), withKey: "pop") }
    }
}

/// 압축기(기계실 디스크 저장고 왼쪽 · 1층에서 내려오는 슈트 끝 아래): 투입구 · 누름판 · 오른쪽 레버 · 위 경고등.
/// 까서 넣은 상자 속을 레버로 누름판을 내려 꾹 누른다(먼지 · 몸체 떨림 · 경고등).
final class CompactorNode: SKNode {
    static let size = CGSize(width: 20, height: 24)
    /// 누름판 높이(몸통 아래 기준): 올림 · 내림.
    static let pressUp: CGFloat = 16
    static let pressDown: CGFloat = 10
    /// 투입구 가운데(몸통 왼쪽 기준 x) · 투입구 윗면(바닥 기준 y).
    static let mouthX: CGFloat = 9
    static let mouthTop: CGFloat = 22

    let body = SKSpriteNode()
    let press = SKSpriteNode()
    let lever = SKSpriteNode()
    let lamp = SKSpriteNode()
    private(set) var crushes = 0
    private(set) var leverDown = false

    override init() {
        super.init()
        body.texture = TextureCache.shared.texture("compactor") { DiskStockArt.compactor() }
        body.size = Self.size
        body.anchorPoint = .zero
        addChild(body)
        press.texture = TextureCache.shared.texture("compactor-press") { DiskStockArt.compactorPress() }
        press.size = CGSize(width: 12, height: 4)
        press.anchorPoint = .zero
        press.position = CGPoint(x: 3, y: Self.pressUp)
        press.zPosition = 0.05
        addChild(press)
        lever.size = CGSize(width: 5, height: 17)
        lever.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        lever.position = CGPoint(x: 18.5, y: 13.5)
        lever.zPosition = 0.1
        addChild(lever)
        lamp.texture = TextureCache.shared.texture("compactor-lamp") { DiskStockArt.compactorLamp() }
        lamp.size = CGSize(width: 4, height: 2)
        lamp.anchorPoint = .zero
        lamp.position = CGPoint(x: 7, y: 22)
        lamp.zPosition = 0.1
        lamp.isHidden = true
        addChild(lamp)
        setLever(down: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setLever(down: Bool) {
        leverDown = down
        lever.texture = TextureCache.shared.texture("compactor-lever\(down ? 1 : 0)") { DiskStockArt.compactorLever(down: down) }
    }

    /// 레버를 당겨 한 번 누른다: 레버 내림 → 경고등 → 누름판이 내려와 꾹(먼지 · 떨림) → 올라감 → 레버 올림.
    func crush(completion: @escaping () -> Void) {
        setLever(down: true)
        lamp.isHidden = false
        lamp.run(.repeatForever(.sequence([.fadeAlpha(to: 0.3, duration: 0.1), .fadeAlpha(to: 1, duration: 0.1)])), withKey: "blink")
        press.removeAllActions()
        press.run(.sequence([
            .moveTo(y: Self.pressDown, duration: 0.18),
            .run { [weak self] in
                guard let self else { return }
                self.crushes += 1
                Effects.burst(in: self, at: CGPoint(x: Self.mouthX + 1, y: Self.pressDown + 2), color: PixelColor(0xCFC8B8), count: 7, spread: 9, rise: 7, duration: 0.5)
                self.body.run(.sequence([.moveBy(x: 1, y: 0, duration: 0.04), .moveBy(x: -2, y: 0, duration: 0.05), .moveBy(x: 1, y: 0, duration: 0.04)]), withKey: "shake")
            },
            .wait(forDuration: 0.28),
            .moveTo(y: Self.pressUp, duration: 0.3),
            .run { [weak self] in
                self?.reset()
                completion()
            }
        ]), withKey: "crush")
    }

    /// 연출 없이 제자리(누름판 올림 · 레버 올림 · 경고등 끔).
    func reset() {
        press.removeAction(forKey: "crush")
        press.position = CGPoint(x: 3, y: Self.pressUp)
        body.removeAction(forKey: "shake")
        body.position = .zero
        lamp.removeAction(forKey: "blink")
        lamp.isHidden = true
        lamp.alpha = 1
        setLever(down: false)
    }
}

/// 재고 조사 무대(건물 좌표 그대로 — 원점 0, 0): 압축기(늘 있음) · 분류 탁자 · 인력 · 탁자 위 묶음과 항목 · 손수레 · 기술자.
final class InventoryNode: SKNode {
    enum Phase: String { case idle, arriving, table, executing, executed, finishing, leaving }

    /// 분류 탁자: 디스크 저장고 선반(332~458) 앞. 윗면 = 바닥선 + 11.
    static let tableX0: CGFloat = 336
    static let tableWidth = 120
    static var tableX1: CGFloat { tableX0 + CGFloat(tableWidth) }
    static let tableHeight: CGFloat = 11
    /// 압축기: 스왑 창고와 디스크 저장고 사이(슈트 끝 아래) · 상자를 넣는 직원 자리(압축기 오른쪽에서 왼쪽을 본다).
    static let compactorX: CGFloat = 302
    static let feedX: CGFloat = 333
    /// 반장 자리(탁자 왼쪽 끝) · 실측을 외치는 자리(저장고 가운데 — 다시 잰 선반 앞).
    /// 인력은 탁자 뒤(선반과 탁자 사이)에 선다: 상반신만 탁자 위로 보이고, 탁자 위 상자를 가리지 않는다(손수레 일만 탁자 앞).
    static let leadX: CGFloat = 344
    static let shoutX: CGFloat = 396
    static let behindTableZ: CGFloat = 4.05
    static let frontZ: CGFloat = 7.2
    /// 손수레가 상자를 건네는 곳: 1층 도구실 오른쪽 끝(별관 기록 보관소 벽 바로 앞).
    static var vaultHandoffX: CGFloat { CGFloat(BuildingLayout.wingX0) - 18 }
    static let maxItems = 12
    static let safetySeconds: TimeInterval = 180
    static let speed: CGFloat = 75
    /// 드문 순찰(재고 세기): 매초 이 확률 — 장면 시간으로 평균 10분에 한 번.
    static let idleChance = 1.0 / 600

    let compactor = CompactorNode()
    let table = SKSpriteNode()
    private(set) var phase: Phase = .idle
    /// 지하 인력(반장 = 첫째). 금고 심부름을 떠난 사람은 couriers로 옮긴다 — 새로 출동해도 심부름꾼을 잃지 않게.
    private(set) var hands: [StockHand] = []
    private(set) var couriers: [StockHand] = []
    private(set) var technician: StockHand?
    private(set) var counter: StockHand?
    private(set) var stacks: [TableStack] = []
    private(set) var openTag: DiskTag?
    private(set) var openItems: [DiskStockItem] = []
    private(set) var itemBoxes: [ItemBox] = []
    private(set) var marks: [String: Bool] = [:]
    private var known: [String: DiskStockItem] = [:]
    private(set) var groups: [DiskStockGroup] = []
    private var pendingOpen: (tag: DiskTag, items: [DiskStockItem])?
    private var pendingExecute: (trash: [String], delete: [String], prune: [DiskTag])?
    private var pendingFinish: UInt64?
    private var pullsLeft = 0
    private var leadReady = false
    private var tasksLeft = 0
    /// 실행 계획: 꼬리표별 실측 전까지 비워 둘 칸 · 정리 명령 꼬리표 · 금고에 건넬 수(안전망 · 바로 끝내기용).
    private var plannedOut: [DiskTag?: Int] = [:]
    private var plannedPrune: [DiskTag] = []
    private var pruneApplied = false
    private var archivePending = 0
    private var ghosts: [SKSpriteNode] = []
    /// 취소 · 안전망으로 상자를 되돌리는 중(끝나면 퇴장): 두 번째 취소는 무시하고, 그사이 새 호출이 오면 되돌리기를 바로 마친다.
    private var closing = false
    private var returning: Set<DiskTag> = []
    /// 장부 맞추기 예약(선반 빈칸 · 내리기 끝 · 퇴장) — 연출을 바로 끝낼 때 한꺼번에 지운다(지운 뒤 옛 예약이 선반을 덮어쓰지 않게).
    private let timers = SKNode()
    private var clock: TimeInterval = 0
    private var lastCall: TimeInterval = 0
    private var phaseSince: TimeInterval = 0
    private var counterSince: TimeInterval = 0
    private var errandSince: [ObjectIdentifier: TimeInterval] = [:]
    private(set) var floorLine: CGFloat = 0
    /// 검수용: 손수레 꼬리표 · 짐 · 마지막 외침 · 기록.
    private(set) var truckTag: String?
    private(set) var truckHand: StockHand?
    private(set) var lastShout: String?
    private(set) var log: [String] = []

    weak var shelves: DiskShelves?
    var lineOf: ((Int) -> CGFloat)?
    var openElevator: ((Int) -> Void)?
    var onSay: ((SKSpriteNode, String, TextBadge.Style, TimeInterval) -> Void)?
    var setHold: ((Bool) -> Void)?
    var remeasure: (() -> Void)?
    var onArchive: ((Int) -> Void)?
    var onChange: (() -> Void)?

    override init() {
        super.init()
        compactor.zPosition = 3.5
        addChild(compactor)
        table.texture = TextureCache.shared.texture("sorting-table") { DiskStockArt.sortingTable(width: InventoryNode.tableWidth) }
        table.size = CGSize(width: CGFloat(Self.tableWidth), height: Self.tableHeight)
        table.anchorPoint = .zero
        table.zPosition = 4.2
        table.isHidden = true
        addChild(table)
        addChild(timers)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var shaft: CGFloat { CGFloat(BuildingLayout.elevatorX) }
    private var tableTop: CGFloat { floorLine + Self.tableHeight }
    var active: Bool { phase != .idle }
    /// 지하 · 1층 어딘가에 재고 조사 사람이 있는가(순찰 · 심부름 포함).
    var anyoneHere: Bool { !hands.isEmpty || !couriers.isEmpty || technician != nil || counter != nil }

    func place(floorLine: CGFloat) {
        self.floorLine = floorLine
        compactor.position = CGPoint(x: Self.compactorX, y: floorLine)
        table.position = CGPoint(x: Self.tableX0, y: floorLine)
        layoutTable(animated: false)
    }

    private func touch() { lastCall = clock }

    private func note(_ text: String) {
        log.append(text)
        if log.count > 120 { log.removeFirst(log.count - 120) }
    }

    private func setPhase(_ value: Phase) {
        phase = value
        phaseSince = clock
        note("단계 · \(value.rawValue)")
    }

    // MARK: 손잡이(장면이 부른다)

    /// 시작: 비었으면 인력이 내려와 묶음을 탁자로, 이미 탁자 앞이면 묶음만 맞춘다.
    func begin(groups list: [DiskStockGroup]) {
        touch()
        snapReturn()
        let normalized = Self.normalize(list)
        switch phase {
        case .idle:
            arrive(normalized)
        case .leaving:
            removeCrewNow()
            arrive(normalized)
        case .arriving, .table:
            setGroups(normalized)
        case .executing, .executed, .finishing:
            snapExecution()
            resumeTable(normalized)
        }
        onChange?()
    }

    /// 묶음 하나를 연다(이미 연 묶음이 있으면 닫고). 비었으면 먼저 시작한다.
    func open(tag: DiskTag, items: [DiskStockItem]) {
        touch()
        snapReturn()
        for item in items {
            known[item.path] = item
            marks[item.path] = item.marked
        }
        switch phase {
        case .idle, .leaving:
            pendingOpen = (tag, items)
            begin(groups: stockGroups(including: tag, items: items))
            pendingOpen = (tag, items)
        case .arriving:
            pendingOpen = (tag, items)
            if stack(for: tag) == nil { setGroups(groups + [DiskStockGroup(tag: tag, bytes: items.reduce(0) { $0 + $1.bytes }, reclaimable: 0)]) }
        case .table:
            doOpen(tag, items)
        case .executing, .executed, .finishing:
            snapExecution()
            resumeTable(groups.isEmpty ? stockGroups(including: tag, items: items) : groups)
            doOpen(tag, items)
        }
        onChange?()
    }

    func mark(path: String, marked: Bool) {
        touch()
        marks[path] = marked
        known[path]?.marked = marked
        if let index = openItems.firstIndex(where: { $0.path == path }) { openItems[index].marked = marked }
        itemBoxes.first { $0.path == path }?.setMarked(marked, pop: true)
        onChange?()
    }

    func execute(trash: [String], delete: [String], prune: [DiskTag]) {
        touch()
        snapReturn()
        switch phase {
        case .idle, .leaving:
            begin(groups: stockGroups(including: nil, items: []))
            pendingExecute = (trash, delete, prune)
        case .arriving:
            pendingExecute = (trash, delete, prune)
        case .table:
            doExecute(trash: trash, delete: delete, prune: prune)
        case .executing, .executed, .finishing:
            snapExecution()
            hands.forEach { $0.removeAction(forKey: "task") }
            setPhase(.table)
            doExecute(trash: trash, delete: delete, prune: prune)
        }
        onChange?()
    }

    func finish(measured: UInt64) {
        touch()
        snapReturn()
        switch phase {
        case .idle:
            announceTrip(measured)
        case .leaving:
            removeCrewNow()
            announceTrip(measured)
        case .arriving:
            pendingFinish = measured
            pendingExecute = pendingExecute ?? ([], [], [])
        case .table:
            pendingFinish = measured
            doExecute(trash: [], delete: [], prune: [])
        case .executing:
            pendingFinish = measured
        case .executed, .finishing:
            doFinish(measured)
        }
        onChange?()
    }

    /// 취소: 탁자 위 상자를 모두 선반으로 · 인력 퇴장. 이미 실행했으면(실제로 치운 뒤) 선반을 실제 값으로 다시 재고 나간다.
    func cancel() {
        touch()
        switch phase {
        case .idle, .leaving, .finishing:
            break
        case .arriving, .table:
            guard !closing else { break }   // 이미 되돌리는 중 — 두 번째 취소는 한 번처럼
            pendingOpen = nil
            pendingExecute = nil
            pendingFinish = nil
            note("취소")
            returnEverything { [weak self] in self?.leaveAll() }
        case .executing, .executed:
            note("취소 · 실행 뒤")
            snapExecution()
            remeasure?()
            leaveAll()
        }
        onChange?()
    }

    /// 장면의 1초 주기: 안전망(마지막 호출 뒤 180초) · 끊긴 연출 감시.
    func tick(activeTime: TimeInterval) {
        clock = activeTime
        switch phase {
        case .idle:
            break
        case .leaving:
            if clock - phaseSince > 30 { removeCrewNow(); finishLeaving() }
        default:
            if clock - lastCall > Self.safetySeconds {
                note("안전망 · \(Int(Self.safetySeconds))초")
                safetyEnd()
            } else if phase == .arriving, clock - phaseSince > 40 {
                note("안전망 · 내리기 바로")
                snapArrival()
            } else if phase == .executing, clock - phaseSince > 60 {
                note("안전망 · 실행 바로")
                snapExecution()
                afterExecution()
            } else if phase == .finishing, clock - phaseSince > 25 {
                leaveAll()
            }
        }
        if let counter, clock - counterSince > 70 { counter.removeFromParent(); self.counter = nil; note("순찰 · 안전망") }
        for hand in couriers {
            let since = errandSince[ObjectIdentifier(hand)] ?? clock
            errandSince[ObjectIdentifier(hand)] = since
            if clock - since > 60 { removeHand(hand); note("심부름 · 안전망") }
        }
    }

    // MARK: 시작 — 내려와서 탁자 펴고 묶음 내리기

    /// 묶음 정리: 같은 꼬리표는 합치고 0바이트는 빼고, 큰 것부터(탁자는 지도 목록처럼 큰 순서).
    static func normalize(_ list: [DiskStockGroup]) -> [DiskStockGroup] {
        var merged: [DiskTag: DiskStockGroup] = [:]
        for group in list where group.bytes > 0 {
            if var existing = merged[group.tag] {
                existing.bytes += group.bytes
                existing.reclaimable += group.reclaimable
                merged[group.tag] = existing
            } else {
                merged[group.tag] = group
            }
        }
        let order = Dictionary(uniqueKeysWithValues: DiskTag.allCases.enumerated().map { ($1, $0) })
        return merged.values.sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : (order[$0.tag] ?? 0) < (order[$1.tag] ?? 0) }
    }

    /// 선반 진열(장면의 setDiskStock) 기준 묶음 — 시작 없이 열기 · 실행이 오면 이것으로 시작한다.
    private func stockGroups(including tag: DiskTag?, items: [DiskStockItem]) -> [DiskStockGroup] {
        var list = Self.normalize(shelves?.groups ?? [])
        if let tag, !list.contains(where: { $0.tag == tag }) {
            list.append(DiskStockGroup(tag: tag, bytes: max(1, items.reduce(0) { $0 + $1.bytes }), reclaimable: 0))
        }
        return list
    }

    private func makeClerk(_ index: Int) -> StockHand {
        let hand = StockHand(role: .clerk(index))
        hand.zPosition = Self.behindTableZ + CGFloat(index) * 0.01
        addChild(hand)
        return hand
    }

    private func arrive(_ list: [DiskStockGroup]) {
        cancelCounter()
        timers.removeAllActions()
        closing = false
        clearTable()
        groups = list
        setPhase(.arriving)
        setHold?(true)
        leadReady = false
        let size = list.count >= 4 ? 3 : 2
        hands = (0..<size).map { makeClerk($0) }
        for (index, hand) in hands.enumerated() where index > 0 { hand.truck.isHidden = false }
        note("출동 · \(size)명 · 묶음 \(list.count)")
        // 묶음은 돌아가며 나눈다(반장 빼고). 끝나면 탁자 앞 단계.
        let movers = Array(hands.dropFirst())
        var assignments = [[DiskStockGroup]](repeating: [], count: movers.count)
        for (index, group) in list.enumerated() { assignments[index % movers.count].append(group) }
        pullsLeft = list.count
        // 탁자 위 자리는 미리 정해 둔다(아직 보이지 않음).
        for group in list { addStack(group, hidden: true) }
        layoutTable(animated: false)
        for (index, hand) in hands.enumerated() {
            enter(hand, delay: 0.15 + 0.35 * Double(index)) { [weak self] in
                guard let self else { return }
                if index == 0 {
                    self.walk(hand, to: Self.leadX) { [weak self] in
                        guard let self else { return }
                        hand.stand(right: true)
                        self.setUpTable()
                        self.say(hand, Variety.shared.line("stockEnter", Lines.stockEnter), seconds: 2.4)
                        self.leadReady = true
                        self.checkReady()
                    }
                } else {
                    self.pullQueue(hand, assignments[index - 1])
                }
            }
        }
    }

    /// 엘리베이터 칸에서 나타난다(지하).
    private func enter(_ hand: StockHand, delay: TimeInterval, then: @escaping () -> Void) {
        hand.position = CGPoint(x: shaft, y: floorLine)
        hand.alpha = 0
        hand.stand(right: true)
        hand.run(.sequence([.wait(forDuration: delay), .run { [weak self] in self?.openElevator?(0) }, .wait(forDuration: 0.15), .fadeIn(withDuration: 0.2), .run(then)]), withKey: "task")
    }

    private func setUpTable() {
        guard table.isHidden || table.alpha < 1 else { return }
        table.removeAllActions()
        table.alpha = 0
        table.isHidden = false
        table.run(.fadeIn(withDuration: 0.25))
        Effects.burst(in: self, at: CGPoint(x: Self.tableX0 + 60, y: floorLine + 6), color: PixelColor(0xD9D2C2), count: 6, spread: 30, rise: 5, duration: 0.5)
    }

    /// 묶음을 차례로: 그 꼬리표 선반 상자 앞으로 가서 상자를 탁자 자리로 내린다.
    private func pullQueue(_ hand: StockHand, _ list: [DiskStockGroup]) {
        guard let group = list.first else {
            hand.stand(right: true)
            return
        }
        let points = shelves?.points(group.tag) ?? []
        let station = points.isEmpty ? (stack(for: group.tag)?.position.x ?? 396) : (points.map(\.x).reduce(0, +) / CGFloat(points.count))
        walk(hand, to: min(Self.tableX1 - 6, max(Self.tableX0 + 4, station - 10))) { [weak self] in
            guard let self else { return }
            self.setUpTable()
            hand.loop([.push(0), .push(2)], fps: 4)
            self.pull(group.tag)
            hand.run(.sequence([.wait(forDuration: 0.55), .run { [weak self] in self?.pullQueue(hand, Array(list.dropFirst())) }]), withKey: "task")
        }
    }

    /// 선반의 그 꼬리표 상자 → 탁자 묶음 자리(포물선). 선반은 빈칸이 되고, 첫 상자가 닿으면 묶음이 보인다.
    private func pull(_ tag: DiskTag) {
        guard let stack = stack(for: tag) else { finishPull(); return }
        let shelf = shelves
        let points = shelf.map { s in Array(s.points(tag).prefix(s.visible(tag))) } ?? []
        shelf?.setOut(tag, shelf?.allocated(tag) ?? 0)
        stack.setHeight(max(1, min(3, points.count)))
        guard !points.isEmpty else {
            stack.isHidden = false
            Effects.burst(in: self, at: CGPoint(x: stack.position.x, y: stack.position.y + 4), color: PixelColor(0xD9D2C2), count: 4, spread: 6, rise: 5, duration: 0.4)
            finishPull()
            return
        }
        var landed = false
        for (index, point) in points.enumerated() {
            let target = CGPoint(x: stack.position.x, y: stack.position.y + CGFloat(min(index, 2)) * 8)
            fly(DiskShelves.texture(tag, dashed: false, variant: index), size: DiskShelves.boxSize, from: point, to: target, delay: Double(index) * 0.04, duration: 0.32) { [weak self, weak stack] in
                guard let self, let stack, !landed else { return }
                landed = true
                stack.isHidden = self.openTag == tag
                self.onChange?()
            }
        }
        timers.run(.sequence([.wait(forDuration: Double(points.count) * 0.04 + 0.34), .run { [weak self] in self?.finishPull() }]))
    }

    private func finishPull() {
        pullsLeft = max(0, pullsLeft - 1)
        checkReady()
    }

    private func checkReady() {
        guard phase == .arriving, leadReady, pullsLeft == 0 else { return }
        setPhase(.table)
        for stack in stacks where stack.tag != openTag { stack.isHidden = false }
        for hand in hands.dropFirst() { stepAside(hand) }
        if let open = pendingOpen {
            pendingOpen = nil
            doOpen(open.tag, open.items)
        }
        if let order = pendingExecute {
            pendingExecute = nil
            doExecute(trash: order.trash, delete: order.delete, prune: order.prune)
        }
        onChange?()
    }

    /// 내리기 연출이 끊겼을 때: 남은 묶음을 바로 탁자에.
    private func snapArrival() {
        removeGhosts()
        timers.removeAllActions()
        for hand in hands {
            hand.removeAction(forKey: "task")
            hand.removeAllActions()
            hand.alpha = 1
            hand.position.y = floorLine
            hand.stand()
        }
        for stack in stacks {
            shelves?.setOut(stack.tag, shelves?.allocated(stack.tag) ?? 0)
            stack.setHeight(max(1, min(3, shelves?.allocated(stack.tag) ?? 1)))
        }
        if hands.first.map({ abs($0.position.x - shaft) < 8 }) ?? false { hands.first?.position.x = Self.leadX }
        setUpTable()
        table.alpha = 1
        pullsLeft = 0
        leadReady = true
        checkReady()
    }

    /// 탁자 앞 단계로 바로(실행 · 마침 도중 새 열기 · 시작이 왔을 때): 묶음을 다시 탁자에 올린다(선반 빈칸).
    private func resumeTable(_ list: [DiskStockGroup]) {
        removeGhosts()
        timers.removeAllActions()
        closing = false
        hands.forEach { $0.removeAction(forKey: "task"); $0.removeAction(forKey: "announce") }
        if hands.isEmpty {
            hands.append(makeClerk(0))
            hands.last?.position = CGPoint(x: Self.leadX, y: floorLine)
        }
        clearTable()
        groups = list
        for group in list {
            addStack(group, hidden: false)
            shelves?.setOut(group.tag, shelves?.allocated(group.tag) ?? 0)
        }
        setUpTable()
        table.alpha = 1
        layoutTable(animated: false)
        setPhase(.table)
        setHold?(true)
        Effects.burst(in: self, at: CGPoint(x: Self.tableX0 + 60, y: tableTop + 6), color: PixelColor(0xD9D2C2), count: 6, spread: 30, rise: 6, duration: 0.5)
    }

    /// 묶음 하나를 선반으로 되돌린다(묶음 목록에서 빠졌을 때): 상자가 제자리로 날아가고 빈칸이 채워진다.
    private func returnStack(_ stack: TableStack) {
        let tag = stack.tag
        let targets = Array((shelves?.points(tag) ?? []).prefix(shelves?.allocated(tag) ?? 0))
        if stack.isHidden {
            shelves?.setOut(tag, 0)
            stack.removeFromParent()
            return
        }
        for (index, target) in targets.enumerated() {
            fly(DiskShelves.texture(tag, dashed: false, variant: index), size: DiskShelves.boxSize, from: stack.position, to: target, delay: Double(index) * 0.03, duration: 0.3, completion: nil)
        }
        stack.run(.sequence([.fadeOut(withDuration: 0.12), .removeFromParent()]))
        timers.run(.sequence([.wait(forDuration: Double(targets.count) * 0.03 + 0.32), .run { [weak self] in
            self?.shelves?.setOut(tag, 0)
            self?.onChange?()
        }]))
    }

    /// 탁자 앞에서 묶음 목록이 바뀜: 새 꼬리표는 내려 오고, 빠진 꼬리표는 선반으로 돌아간다.
    private func setGroups(_ list: [DiskStockGroup]) {
        let wanted = Set(list.map(\.tag))
        for stack in stacks where !wanted.contains(stack.tag) {
            if stack.tag == openTag { closeOpen() }
            returnStack(stack)
        }
        stacks.removeAll { !wanted.contains($0.tag) }
        var fresh: [DiskTag] = []
        for group in list {
            if let stack = stack(for: group.tag) {
                stack.bytes = group.bytes
            } else {
                addStack(group, hidden: true)
                fresh.append(group.tag)
            }
        }
        groups = list
        stacks.sort { a, b in (list.firstIndex { $0.tag == a.tag } ?? 0) < (list.firstIndex { $0.tag == b.tag } ?? 0) }
        layoutTable(animated: true)
        // 새 꼬리표는 자리를 정한 뒤 바로 내린다(사람이 걸어가지 않는다 — 이미 탁자 앞에 있다).
        for tag in fresh {
            if phase == .arriving { pullsLeft += 1 }
            pull(tag)
        }
    }

    // MARK: 탁자 배치

    private func stack(for tag: DiskTag) -> TableStack? { stacks.first { $0.tag == tag } }

    @discardableResult
    private func addStack(_ group: DiskStockGroup, hidden: Bool) -> TableStack {
        let height = max(1, min(3, shelves?.allocated(group.tag) ?? 1))
        let stack = TableStack(tag: group.tag, bytes: group.bytes, height: height)
        stack.zPosition = 4.4
        stack.isHidden = hidden
        stack.position = CGPoint(x: Self.tableX0 + 60, y: tableTop)
        addChild(stack)
        stacks.append(stack)
        return stack
    }

    /// 묶음 자리: 펼친 묶음이 없으면 탁자에 고르게, 있으면 나머지는 오른쪽 끝에 겹쳐 꽂은 책처럼 촘촘히. 펼친 묶음 자리는 비운다.
    private func stackPoints() -> [CGPoint] {
        let x0 = Self.tableX0 + 3, x1 = Self.tableX1 - 3
        if openTag == nil {
            let count = max(1, stacks.count)
            let pitch = min(13, (x1 - x0) / CGFloat(count))
            let start = x0 + ((x1 - x0) - pitch * CGFloat(count)) / 2
            return stacks.indices.map { CGPoint(x: (start + pitch * (CGFloat($0) + 0.5)).rounded(), y: tableTop) }
        }
        let others = stacks.filter { $0.tag != openTag }
        var points: [CGPoint] = []
        var slot = 0
        for stack in stacks {
            if stack.tag == openTag { points.append(CGPoint(x: itemsRange.lowerBound + 6, y: tableTop)); continue }
            points.append(CGPoint(x: x1 - 4.5 - 5 * CGFloat(others.count - 1 - slot), y: tableTop))
            slot += 1
        }
        return points
    }

    /// 펼친 항목이 놓이는 가로 범위(묶음이 오른쪽 끝에 촘촘히 선 뒤 남는 왼쪽).
    var itemsRange: ClosedRange<CGFloat> {
        let x0 = Self.tableX0 + 3, x1 = Self.tableX1 - 3
        let others = stacks.filter { $0.tag != openTag }.count
        let right = others > 0 ? x1 - 9 - 5 * CGFloat(others - 1) - 4 : x1
        return x0...max(x0 + 40, right)
    }

    /// 항목 자리(앞줄 6 · 뒷줄 6 — 뒷줄은 반 칸 어긋나고 5px 높게, 탁자 안쪽에 놓인 것처럼).
    func itemPoint(_ index: Int) -> (point: CGPoint, back: Bool) {
        let range = itemsRange
        let pitch = (range.upperBound - range.lowerBound) / 6
        let back = index >= 6
        let column = CGFloat(index % 6)
        let x = range.lowerBound + pitch * (column + (back ? 1 : 0.5))
        return (CGPoint(x: min(range.upperBound - 3.5, x).rounded(), y: tableTop + (back ? 5 : 0)), back)
    }

    private func layoutTable(animated: Bool) {
        let points = stackPoints()
        for (stack, point) in zip(stacks, points) {
            stack.zPosition = 4.4 + (stack.tag == openTag ? 0 : CGFloat(stacks.firstIndex { $0 === stack } ?? 0) * 0.001)
            if animated, stack.position != point, !stack.isHidden {
                stack.run(.move(to: point, duration: 0.25), withKey: "slide")
            } else {
                stack.removeAction(forKey: "slide")
                stack.position = point
            }
        }
        for (index, box) in itemBoxes.enumerated() {
            let spot = itemPoint(index)
            box.zPosition = spot.back ? 4.5 : 4.6
            if box.action(forKey: "jump") == nil { box.position = spot.point }
        }
    }

    // MARK: 열기 · 닫기

    private func doOpen(_ tag: DiskTag, _ items: [DiskStockItem]) {
        if openTag == tag {
            // 같은 묶음을 다시 열면 항목만 새로(자리 그대로).
            openItems = items
            clearItems()
            spread(from: stack(for: tag)?.position ?? CGPoint(x: itemsRange.lowerBound + 6, y: tableTop), animated: false)
            onChange?()
            return
        }
        if openTag != nil { closeOpen() }
        let stack = self.stack(for: tag) ?? {
            let made = addStack(DiskStockGroup(tag: tag, bytes: max(1, items.reduce(0) { $0 + $1.bytes }), reclaimable: 0), hidden: false)
            groups.append(DiskStockGroup(tag: tag, bytes: made.bytes, reclaimable: 0))
            shelves?.setOut(tag, shelves?.allocated(tag) ?? 0)
            return made
        }()
        let from = stack.position
        openTag = tag
        openItems = items
        note("열기 · \(tag.rawValue) · \(items.count)개")
        layoutTable(animated: true)
        stack.isHidden = true
        guard let lead = hands.first else { spread(from: from, animated: false); return }
        // 반장은 탁자 왼쪽 끝 바깥에서 펼친 상자를 가리킨다(상자 사이에 서서 가리지 않게).
        walk(lead, to: Self.tableX0 - 5) { [weak self] in
            guard let self, self.openTag == tag else { return }
            lead.face(right: true)
            lead.loop([.wave(0), .wave(1)], fps: 3)
            self.say(lead, Variety.shared.line("stockOpen", Lines.stockOpen), seconds: 2.0)
        }
        // 묶음 뚜껑이 열리며 작은 상자가 펼쳐진다.
        Effects.burst(in: self, at: CGPoint(x: from.x, y: from.y + 10), color: PixelColor(0xE9CF97), count: 5, spread: 6, rise: 6, duration: 0.45)
        spread(from: CGPoint(x: from.x, y: from.y + 8), animated: true)
        onChange?()
    }

    /// 펼친 묶음의 앞 12개를 항목 상자로(나머지는 '+N' 판 — 장면이 그린다).
    private func spread(from origin: CGPoint, animated: Bool) {
        for (index, item) in openItems.prefix(Self.maxItems).enumerated() {
            var shown = item
            shown.marked = marks[item.path] ?? item.marked
            let box = ItemBox(item: shown)
            let spot = itemPoint(index)
            box.zPosition = spot.back ? 4.5 : 4.6
            addChild(box)
            itemBoxes.append(box)
            if animated {
                box.position = origin
                box.setScale(0.4)
                let duration = 0.3
                let peak = max(origin.y, spot.point.y) + 9
                box.run(.sequence([
                    .wait(forDuration: Double(index) * 0.05),
                    .group([.moveTo(x: spot.point.x, duration: duration), .scale(to: 1, duration: duration * 0.6),
                            .sequence([.moveTo(y: peak, duration: duration / 2), .moveTo(y: spot.point.y, duration: duration / 2)])])
                ]), withKey: "jump")
            } else {
                box.position = spot.point
            }
        }
    }

    /// 펼친 묶음을 닫는다: 항목 상자가 묶음 자리로 모여 사라지고 묶음이 다시 보인다.
    private func closeOpen() {
        guard let tag = openTag else { return }
        openTag = nil
        let stack = self.stack(for: tag)
        let target = stack?.position ?? CGPoint(x: itemsRange.lowerBound + 6, y: tableTop)
        for box in itemBoxes {
            box.removeAllActions()
            box.run(.sequence([.group([.move(to: target, duration: 0.22), .scale(to: 0.4, duration: 0.22)]), .removeFromParent()]))
        }
        itemBoxes = []
        openItems = []
        stack?.isHidden = false
        layoutTable(animated: true)
        note("닫기 · \(tag.rawValue)")
    }

    private func clearItems() {
        itemBoxes.forEach { $0.removeFromParent() }
        itemBoxes = []
    }

    private func clearTable() {
        clearItems()
        stacks.forEach { $0.removeFromParent() }
        stacks = []
        openTag = nil
        openItems = []
    }

    // MARK: 실행 — 보관 · 휴지통 손수레 · 압축기 · 정리 명령

    private func doExecute(trash: [String], delete: [String], prune: [DiskTag]) {
        setPhase(.executing)
        let trashSet = Set(trash), deleteSet = Set(delete).subtracting(trashSet)
        let pruneTags = DiskTag.allCases.filter { Set(prune).contains($0) }
        note("실행 · 휴지통 \(trashSet.count) · 삭제 \(deleteSet.count) · 정리 \(pruneTags.count)")
        let trashBoxes = itemBoxes.filter { trashSet.contains($0.path) }
        let deleteBoxes = itemBoxes.filter { deleteSet.contains($0.path) }
        let keptBoxes = itemBoxes.filter { !trashSet.contains($0.path) && !deleteSet.contains($0.path) }
        itemBoxes = []
        // 꼬리표별 실측 전까지 비워 둘 칸: 치운 항목(알려진 것)의 바이트 비율만큼. 나머지 칸은 상자가 선반으로 돌아간다.
        var removed: [DiskTag: UInt64] = [:]
        for path in trashSet.union(deleteSet) { if let item = known[path] { removed[item.tag, default: 0] += item.bytes } }
        plannedOut = [:]
        for stack in stacks {
            let allocated = shelves?.allocated(stack.tag) ?? 0
            let total = max(stack.bytes, groups.first { $0.tag == stack.tag }?.bytes ?? 0)
            let keep = total > 0 ? max(0, 1 - Double(removed[stack.tag] ?? 0) / Double(total)) : 1
            plannedOut[stack.tag] = allocated - Int((keep * Double(allocated)).rounded())
        }
        plannedPrune = pruneTags
        pruneApplied = pruneTags.isEmpty
        archivePending = trashSet.count
        tasksLeft = 0
        // 일 나누기: 반장 = 되돌리기, 손수레 · 압축기는 나머지 인력이(모자라면 반장이 이어서).
        let crew = hands
        guard let lead = crew.first else { snapExecution(); afterExecution(); return }
        var movers = Array(crew.dropFirst())
        var leadQueue: [(StockHand, @escaping () -> Void) -> Void] = []
        let stacksNow = stacks
        let openNow = openTag
        tasksLeft += 1
        leadQueue.append { [weak self] hand, done in self?.returnKept(hand, stacks: stacksNow, open: openNow, kept: keptBoxes, done: done) }
        if !trashSet.isEmpty {
            tasksLeft += 1
            let task: (StockHand, @escaping () -> Void) -> Void = { [weak self] hand, done in self?.truckRun(hand, boxes: trashBoxes, total: trashSet.count, done: done) }
            if let mover = movers.first { movers.removeFirst(); runQueue(mover, [task]) } else { leadQueue.append(task) }
        }
        if !deleteSet.isEmpty {
            tasksLeft += 1
            let task: (StockHand, @escaping () -> Void) -> Void = { [weak self] hand, done in self?.crushRun(hand, boxes: deleteBoxes, extra: deleteSet.count - deleteBoxes.count, done: done) }
            if let mover = movers.first { movers.removeFirst(); runQueue(mover, [task]) } else { leadQueue.append(task) }
        }
        runQueue(lead, leadQueue)
        if !pruneTags.isEmpty {
            tasksLeft += 1
            pruneRun(pruneTags)
        }
        for idle in movers { stepAside(idle) }
        openTag = nil
        openItems = []
    }

    /// 한 사람이 일을 차례로(각 일이 끝나면 다음).
    private func runQueue(_ hand: StockHand, _ queue: [(StockHand, @escaping () -> Void) -> Void]) {
        guard let first = queue.first else { return }
        first(hand) { [weak self, weak hand] in
            guard let self else { return }
            self.taskDone()
            if let hand, hand.parent != nil, !hand.errand { self.runQueue(hand, Array(queue.dropFirst())) }
        }
    }

    private func taskDone() {
        tasksLeft = max(0, tasksLeft - 1)
        if tasksLeft == 0, phase == .executing { executionDone() }
    }

    private func executionDone() {
        guard phase == .executing else { return }
        setPhase(.executed)
        for hand in hands where hand.action(forKey: "task") == nil { hand.stand() }
        afterExecution()
    }

    /// 실행을 마친 뒤(제대로 · 바로 끝내기 모두): 미뤄 둔 마침(실측)이 있으면 이어서.
    private func afterExecution() {
        guard phase == .executed else { return }
        if let measured = pendingFinish {
            pendingFinish = nil
            doFinish(measured)
        }
        onChange?()
    }

    /// 보관할 상자를 선반으로: 탁자 가운데로 가서 묶음마다(펼친 묶음은 남긴 항목) 상자를 제자리로 던져 올린다.
    private func returnKept(_ hand: StockHand, stacks list: [TableStack], open: DiskTag?, kept: [ItemBox], done: @escaping () -> Void) {
        walk(hand, to: Self.tableX0 + 58) { [weak self] in
            guard let self else { done(); return }
            hand.loop([.push(0), .push(2)], fps: 4)
            if !list.isEmpty { self.say(hand, Variety.shared.line("stockReturn", Lines.stockReturn), seconds: 2.0) }
            var delay = 0.0
            for stack in list {
                let tag = stack.tag
                let out = self.plannedOut[tag] ?? 0
                let allocated = self.shelves?.allocated(tag) ?? 0
                let returning = max(0, allocated - out)
                let targets = Array((self.shelves?.points(tag) ?? []).prefix(returning))
                let from = tag == open ? (kept.first?.position ?? stack.position) : stack.position
                stack.run(.sequence([.wait(forDuration: delay), .fadeOut(withDuration: 0.12), .removeFromParent()]))
                if tag == open {
                    for (index, box) in kept.enumerated() {
                        let target = targets.isEmpty ? CGPoint(x: box.position.x, y: box.position.y + 20) : targets[index % targets.count]
                        box.removeAllActions()
                        box.run(.sequence([.wait(forDuration: delay + Double(index) * 0.03), self.arc(to: target, duration: 0.3), .removeFromParent()]))
                    }
                }
                for (index, target) in targets.enumerated() {
                    self.fly(DiskShelves.texture(tag, dashed: false, variant: index), size: DiskShelves.boxSize, from: from, to: target, delay: delay + Double(index) * 0.03, duration: 0.34, completion: nil)
                }
                self.timers.run(.sequence([.wait(forDuration: delay + Double(targets.count) * 0.03 + 0.36), .run { [weak self] in
                    self?.shelves?.setOut(tag, out)
                    self?.onChange?()
                }]))
                delay += 0.2
            }
            if open == nil { kept.forEach { $0.removeFromParent() } }
            self.stacks.removeAll { stack in list.contains { $0 === stack } }
            hand.run(.sequence([.wait(forDuration: delay + 0.5), .run { hand.stand(); done() }]), withKey: "task")
        }
    }

    /// 휴지통: 상자에 '되돌릴 수 있음' 꼬리표를 달아 손수레에 싣고 엘리베이터로 → 1층 기록 보관소 앞에서 기록관에게 건넨다.
    private func truckRun(_ hand: StockHand, boxes: [ItemBox], total: Int, done: @escaping () -> Void) {
        hand.truck.isHidden = false
        hand.zPosition = Self.frontZ   // 손수레 일은 탁자 앞에서(실린 상자가 보이게)
        hand.archiveCount += archivePending
        archivePending = 0
        let x = boxes.isEmpty ? itemsRange.lowerBound + 10 : boxes.map(\.position.x).reduce(0, +) / CGFloat(boxes.count)
        walk(hand, to: max(Self.tableX0, x - 14)) { [weak self] in
            guard let self else { done(); return }
            hand.stand(right: true)
            var delay = 0.0
            for box in boxes {
                box.run(.sequence([.wait(forDuration: delay), .run { [weak self, weak hand, weak box] in
                    guard let self, let hand, let box else { return }
                    let target = hand.convert(CGPoint(x: StockHand.truckOffset + 6.5, y: 2 + CGFloat(min(2, hand.cargoCount)) * 6), to: self)
                    box.run(.sequence([self.arc(to: target, duration: 0.22), .run { [weak hand, weak box] in if let box { hand?.load(box) } }]), withKey: "jump")
                }]))
                delay += 0.18
            }
            if boxes.count < total {
                // 펼치지 않은 휴지통 항목(목록 밖 '+N')은 회색 상자 하나로 함께 싣는다.
                hand.run(.sequence([.wait(forDuration: delay + 0.25), .run { [weak hand] in
                    let extra = SKSpriteNode(texture: TextureCache.shared.texture("item-box-trash") { DiskStockArt.itemBox(.trash) }, size: CGSize(width: 7, height: 6))
                    hand?.load(extra)
                }]), withKey: "load")
                delay += 0.2
            }
            hand.run(.sequence([.wait(forDuration: delay + 0.4), .run { [weak self] in
                guard let self else { return }
                self.truckTag = "되돌릴 수 있음 · \(total)개"
                self.truckHand = hand
                self.note("손수레 · \(total)개")
                self.say(hand, Variety.shared.line("stockTruck", Lines.stockTruck), seconds: 2.2)
                self.onChange?()
                // 엘리베이터로(손수레는 늘 오른쪽 — 끌고 간다) → 1층
                self.walk(hand, to: self.shaft, speed: 65) { [weak self] in
                    guard let self else { return }
                    hand.errand = true
                    self.hands.removeAll { $0 === hand }
                    self.couriers.append(hand)
                    self.errandSince[ObjectIdentifier(hand)] = self.clock
                    done()   // 지하 일은 끝(1층 심부름은 따로)
                    self.ride(hand, toFloor: 1, x: Self.vaultHandoffX, speed: 65) { [weak self] in self?.handOff(hand) }
                }
            }]), withKey: "task")
        }
    }

    /// 1층 기록 보관소 벽 앞: 짐을 별관 쪽으로 밀어 넣는다(반짝) · 기록관이 받는다 → 엘리베이터로 돌아가 사라진다.
    private func handOff(_ hand: StockHand) {
        hand.stand(right: true)
        let count = hand.archiveCount
        hand.archiveCount = 0
        let boxes = hand.unloadAll(into: self)
        for (index, box) in boxes.enumerated() {
            box.isHidden = false
            box.zPosition = 7.3
            box.run(.sequence([.wait(forDuration: Double(index) * 0.12), .group([.moveBy(x: 16, y: 0, duration: 0.3), .fadeOut(withDuration: 0.3)]), .removeFromParent()]))
        }
        let line = lineOf?(1) ?? 0
        Effects.sparkle(in: self, at: CGPoint(x: CGFloat(BuildingLayout.wingX0) + 4, y: line + 8))
        truckTag = nil
        truckHand = nil
        note("금고 전달 · \(count)개")
        if count > 0 { onArchive?(count) }
        onChange?()
        hand.run(.sequence([.wait(forDuration: 0.8), .run { [weak self] in
            guard let self else { return }
            self.walk(hand, to: self.shaft, speed: 80) { [weak self] in
                self?.exit(hand, floor: 1)
            }
        }]), withKey: "task")
    }

    /// 삭제: 상자를 하나씩 압축기로 — 까서(날개가 튀고 속이 투입구로) 레버를 당겨 꾹. 많으면 넷째 번에 남은 것을 한꺼번에.
    private func crushRun(_ hand: StockHand, boxes: [ItemBox], extra: Int, done: @escaping () -> Void) {
        var loads: [[SKSpriteNode]] = boxes.map { [$0] }
        if extra > 0 {
            let generic = SKSpriteNode(texture: TextureCache.shared.texture("item-box-\(openTagFallback(boxes).rawValue)") { DiskStockArt.itemBox(openTagFallback(boxes)) }, size: CGSize(width: 7, height: 6))
            generic.anchorPoint = CGPoint(x: 0.5, y: 0)
            generic.position = CGPoint(x: itemsRange.lowerBound + 4, y: tableTop)
            generic.zPosition = 4.6
            addChild(generic)
            loads.append([generic])
        }
        if loads.count > 4 { loads = Array(loads.prefix(3)) + [loads.dropFirst(3).flatMap { $0 }] }
        note("압축 · \(boxes.count + (extra > 0 ? 1 : 0))상자 · \(loads.count)번")
        crushNext(hand, loads: loads, first: true, done: done)
    }

    private func openTagFallback(_ boxes: [ItemBox]) -> DiskTag { boxes.first?.item.tag ?? .cache }

    private func crushNext(_ hand: StockHand, loads: [[SKSpriteNode]], first: Bool, done: @escaping () -> Void) {
        guard let load = loads.first, let lead = load.first else {
            hand.stand()
            done()
            return
        }
        walk(hand, to: max(Self.feedX, lead.position.x - 9)) { [weak self] in
            guard let self else { done(); return }
            hand.stand(right: true)
            // 집기: 첫 상자는 손에, 나머지(한꺼번에 넣는 몫)는 사라지며 손 상자에 합친다.
            for extra in load.dropFirst() { extra.run(.sequence([.group([.move(to: lead.position, duration: 0.2), .fadeOut(withDuration: 0.2)]), .removeFromParent()])) }
            hand.hold(lead)
            hand.stand()
            self.walk(hand, to: Self.feedX, speed: 70) { [weak self] in
                guard let self else { done(); return }
                hand.stand(right: false)
                if first { self.say(hand, Variety.shared.line("stockCrush", Lines.stockCrush), seconds: 1.8) }
                self.unbox(hand) { [weak self] in
                    guard let self else { done(); return }
                    hand.loop([.push(0), .push(2)], fps: 6)
                    self.compactor.crush { [weak self] in
                        guard let self else { done(); return }
                        hand.stand(right: false)
                        self.crushNext(hand, loads: Array(loads.dropFirst()), first: false, done: done)
                    }
                }
            }
        }
    }

    /// 상자 까기: 손 상자가 투입구 위로 → 날개 둘이 튀고 속(서류 묶음)이 투입구로 떨어진다.
    /// 순서는 사람(일 키 "task")이 들고 간다 — 상자는 도중에 장면에서 빠지므로(빠진 노드의 동작은 멈춘다) 상자에 순서를 걸지 않는다.
    private func unbox(_ hand: StockHand, then: @escaping () -> Void) {
        guard let box = hand.release(into: self) else { then(); return }
        let mouth = CGPoint(x: Self.compactorX + CompactorNode.mouthX, y: floorLine + CompactorNode.mouthTop + 1)
        box.zPosition = 7.25
        box.run(.move(to: mouth, duration: 0.25), withKey: "jump")
        hand.run(.sequence([
            .wait(forDuration: 0.26),
            .run { [weak self, weak box] in
                guard let self, let box else { return }
                let tag = (box as? ItemBox)?.item.tag
                for side in [-1.0, 1.0] {
                    let flap = SKSpriteNode(texture: TextureCache.shared.texture("flap-\(tag?.rawValue ?? "rest")") { DiskStockArt.flap(tag) }, size: CGSize(width: 4, height: 2))
                    flap.position = CGPoint(x: mouth.x + CGFloat(side) * 2, y: mouth.y + 5)
                    flap.zPosition = 7.3
                    self.addChild(flap)
                    flap.run(.sequence([.group([.moveBy(x: CGFloat(side) * 7, y: 6, duration: 0.25), .rotate(byAngle: CGFloat(side) * -1.2, duration: 0.25), .fadeOut(withDuration: 0.3)]), .removeFromParent()]))
                }
                let paper = SKSpriteNode(texture: TextureCache.shared.texture("stock-contents") { DiskStockArt.contents() }, size: CGSize(width: 4, height: 3))
                paper.anchorPoint = CGPoint(x: 0.5, y: 0)
                paper.position = mouth
                paper.zPosition = 3.52
                self.addChild(paper)
                paper.run(.sequence([.moveTo(y: self.floorLine + CompactorNode.pressDown + 1, duration: 0.22), .wait(forDuration: 0.25), .fadeOut(withDuration: 0.12), .removeFromParent()]))
                box.removeAllActions()
                box.removeFromParent()
            },
            .wait(forDuration: 0.25),
            .run(then)
        ]), withKey: "task")
    }

    /// 정리 명령: 기술자가 단말기 수레를 밀고 와서 치면 그 묶음 선반 상자가 작아진다 → 엘리베이터로 돌아간다.
    private func pruneRun(_ tags: [DiskTag]) {
        let tech = technician ?? {
            let made = StockHand(role: .technician)
            made.zPosition = Self.behindTableZ - 0.02
            made.truck.isHidden = false
            addChild(made)
            technician = made
            return made
        }()
        let points = tags.flatMap { shelves?.points($0) ?? [] }
        let center = points.isEmpty ? 396 : points.map(\.x).reduce(0, +) / CGFloat(points.count)
        let station = min(Self.tableX1 - 24, max(Self.tableX0, center - 12))
        tech.position = CGPoint(x: shaft, y: floorLine)
        tech.alpha = 0
        tech.stand(right: true)
        tech.run(.sequence([.wait(forDuration: 0.5), .run { [weak self] in self?.openElevator?(0) }, .wait(forDuration: 0.15), .fadeIn(withDuration: 0.2), .run { [weak self] in
            guard let self else { return }
            self.walk(tech, to: station, speed: 70, push: true) { [weak self] in
                guard let self else { return }
                tech.loop([.push(0), .push(2)], fps: 6)
                tech.truck.run(.repeatForever(.animate(with: (0..<2).map { f in TextureCache.shared.texture("terminal-cart\(f)") { DiskStockArt.terminalCart(f) } }, timePerFrame: 0.25)), withKey: "screen")
                self.say(tech, Variety.shared.line("stockPrune", Lines.stockPrune), seconds: 2.2)
                tech.run(.sequence([.wait(forDuration: 2.4), .run { [weak self] in
                    guard let self else { return }
                    tech.truck.removeAction(forKey: "screen")
                    self.applyPrune()
                    self.taskDone()
                    tech.stand()
                    self.walk(tech, to: self.shaft, speed: 70) { [weak self] in
                        guard let self else { return }
                        self.exit(tech, floor: 0)
                    }
                }]), withKey: "task")
            }
        }]), withKey: "task")
    }

    private func applyPrune() {
        guard !pruneApplied else { return }
        pruneApplied = true
        shelves?.shrink(plannedPrune)
        for tag in plannedPrune {
            for point in (shelves?.points(tag) ?? []).prefix(6) {
                Effects.burst(in: self, at: CGPoint(x: point.x, y: point.y + 6), color: PixelColor(0xBFE9FF), count: 3, spread: 4, rise: 5, duration: 0.4)
            }
        }
        note("정리 명령 · \(plannedPrune.map(\.rawValue).joined(separator: ","))")
        onChange?()
    }

    /// 실행 연출을 그 자리에서 끝낸다: 손수레 짐은 금고로 건넨 것으로 · 삭제 상자는 사라짐 · 남길 칸은 선반으로 · 정리 명령은 축소 · 기술자 퇴장.
    private func snapExecution() {
        guard phase == .executing || phase == .executed || phase == .finishing else { return }
        removeGhosts()
        timers.removeAllActions()
        compactor.reset()
        for hand in hands {
            hand.removeAction(forKey: "task")
            hand.removeAction(forKey: "load")
            hand.removeAction(forKey: "announce")
            hand.removeAllActions()
            hand.alpha = 1
            hand.position.y = floorLine
            if hand.held != nil { hand.hold(nil) }
            hand.clearCargo()   // 싣던 중이었어도 짐은 금고 몫으로(아래에서 기록관에게 알린다)
            if case .clerk(let index) = hand.role { hand.zPosition = Self.behindTableZ + CGFloat(index) * 0.01 }
            hand.stand()
        }
        // 아직 지하에 있던 휴지통 몫(손수레가 떠나기 전): 금고로 건넨 것으로 친다. 이미 1층으로 떠난 심부름꾼은 제 몫을 직접 건넨다.
        var flushed = archivePending
        archivePending = 0
        for hand in hands {
            flushed += hand.archiveCount
            hand.archiveCount = 0
        }
        if let truck = truckHand, !truck.errand { removeHand(truck) }
        if flushed > 0 {
            onArchive?(flushed)
            note("금고 전달 · 바로 · \(flushed)개")
        }
        truckTag = nil
        truckHand = nil
        if !pruneApplied { applyPrune() }
        if let tech = technician { tech.removeFromParent(); technician = nil }
        for (tag, value) in plannedOut { shelves?.setOut(tag, value) }
        children.compactMap { $0 as? ItemBox }.forEach { $0.removeFromParent() }
        clearTable()
        tasksLeft = 0
        if phase == .executing { setPhase(.executed) }
    }

    // MARK: 마침 — 실측 · 외침 · 퇴장

    private func doFinish(_ measured: UInt64) {
        setPhase(.finishing)
        remeasure?()
        scanShelves()
        let text = measured > 0 ? "실측 +\(Fmt.size(measured))" : "줄어든 게 없어요"
        lastShout = text
        note("실측 · \(text)")
        guard let lead = hands.first else { leaveAll(); return }
        lead.removeAction(forKey: "announce")
        walk(lead, to: Self.shoutX) { [weak self] in
            guard let self else { return }
            lead.face(right: false)
            lead.loop([.shout(0), .shout(1)], fps: 5)
            self.say(lead, text, style: .shout, seconds: 4.4)
            lead.run(.sequence([.wait(forDuration: 4.6), .run { [weak self] in self?.leaveAll() }]), withKey: "announce")
        }
        onChange?()
    }

    /// 실측 표시: 선반을 왼쪽부터 훑는 반짝임.
    private func scanShelves() {
        for (index, x) in WarehouseNode.shelfXs.enumerated() {
            run(.sequence([.wait(forDuration: Double(index) * 0.12), .run { [weak self] in
                guard let self else { return }
                Effects.sparkle(in: self, at: CGPoint(x: x + 15, y: self.floorLine + 20))
            }]))
        }
    }

    /// 비어 있을 때 마침(실측)이 오면: 한 명이 내려와 선반을 다시 재고 외친 뒤 나간다.
    private func announceTrip(_ measured: UInt64) {
        cancelCounter()
        clearTable()
        let hand = makeClerk(0)
        hands = [hand]
        setPhase(.finishing)
        enter(hand, delay: 0.1) { [weak self] in
            guard let self else { return }
            self.walk(hand, to: Self.shoutX) { [weak self] in
                guard let self else { return }
                self.phaseSince = self.clock
                self.doFinish(measured)
            }
        }
    }

    /// 모두 퇴장: 탁자를 접고 엘리베이터로(1층 심부름 중인 사람은 제 일을 마치고 스스로 사라진다).
    private func leaveAll() {
        guard phase != .leaving else { return }
        removeGhosts()
        closing = false
        returning = []
        pendingOpen = nil
        pendingExecute = nil
        pendingFinish = nil
        setPhase(.leaving)
        setHold?(false)
        clearTable()
        table.run(.sequence([.wait(forDuration: 0.4), .fadeOut(withDuration: 0.3), .hide()]), withKey: "fold")
        let crew = hands
        if crew.isEmpty && technician == nil { finishLeaving(); return }
        for (index, hand) in crew.enumerated() {
            hand.removeAction(forKey: "announce")
            hand.run(.sequence([.wait(forDuration: Double(index) * 0.3), .run { [weak self] in
                guard let self else { return }
                self.walk(hand, to: self.shaft) { [weak self] in self?.exit(hand, floor: 0) }
            }]), withKey: "task")
        }
        onChange?()
    }

    /// 엘리베이터로 사라진다.
    private func exit(_ hand: StockHand, floor: Int) {
        openElevator?(floor)
        hand.run(.sequence([.wait(forDuration: 0.15), .fadeOut(withDuration: 0.2), .run { [weak self] in self?.removeHand(hand) }]), withKey: "task")
    }

    private func removeHand(_ hand: StockHand) {
        if hand.archiveCount > 0 {
            // 건네기 전에 사라짐(안전망 · 바로 끝내기): 휴지통으로 보낸 것은 사실이니 기록관에게는 알린다.
            onArchive?(hand.archiveCount)
            note("금고 전달 · 바로 · \(hand.archiveCount)개")
            hand.archiveCount = 0
        }
        hand.removeAllActions()
        hand.removeFromParent()
        hands.removeAll { $0 === hand }
        couriers.removeAll { $0 === hand }
        errandSince[ObjectIdentifier(hand)] = nil
        if technician === hand { technician = nil }
        if truckHand === hand { truckHand = nil; truckTag = nil }
        if phase == .leaving, hands.isEmpty, technician == nil { finishLeaving() }
        onChange?()
    }

    private func finishLeaving() {
        guard phase == .leaving else { return }
        table.removeAction(forKey: "fold")
        table.isHidden = true
        clearTable()
        known = [:]
        marks = [:]
        groups = []
        setPhase(.idle)
        onChange?()
    }

    /// 지금 사람 · 연출을 모두 바로 치운다(새로 시작할 때 · 퇴장이 끝나지 않을 때).
    private func removeCrewNow() {
        removeGhosts()
        timers.removeAllActions()
        closing = false
        returning = []
        for hand in hands { hand.removeAllActions(); hand.removeFromParent() }
        hands = []
        if let tech = technician { tech.removeFromParent(); technician = nil }
        if let truck = truckHand, !truck.errand { truckHand = nil; truckTag = nil }
        table.removeAllActions()
        table.isHidden = true
        clearTable()
        compactor.reset()
    }

    /// 안전망: 앱이 마침 · 취소를 잊었다 — 취소처럼 끝낸다(실행 뒤면 실측으로).
    private func safetyEnd() {
        switch phase {
        case .finishing: leaveAll()
        case .executing, .executed: snapExecution(); remeasure?(); leaveAll()
        case .arriving, .table:
            guard !closing else { break }
            pendingOpen = nil
            pendingExecute = nil
            pendingFinish = nil
            returnEverything { [weak self] in self?.leaveAll() }
        case .idle, .leaving: break
        }
        onChange?()
    }

    /// 되돌리는 중에 새 호출(시작 · 열기 · 실행 · 마침)이 왔다: 되돌리기를 바로 마치고(선반 제자리) 인력은 남아 빈 탁자 앞에서 이어 간다.
    private func snapReturn() {
        guard closing else { return }
        closing = false
        timers.removeAllActions()
        removeGhosts()
        for tag in returning { shelves?.setOut(tag, 0) }
        returning = []
        clearTable()
        pullsLeft = 0
        leadReady = true
        if phase == .arriving { setPhase(.table) }
        setUpTable()
        note("되돌리기 바로 · 다시 탁자")
    }

    /// 탁자 위 묶음 · 항목을 모두 선반으로(취소 · 안전망). 내리던 상자는 바로 제자리.
    private func returnEverything(completion: @escaping () -> Void) {
        removeGhosts()
        timers.removeAllActions()
        closing = true
        for hand in hands { hand.removeAction(forKey: "task"); hand.stand() }
        var delay = 0.0
        let list = stacks
        let open = openTag
        let items = itemBoxes
        itemBoxes = []
        returning = Set(list.map(\.tag))
        for stack in list {
            let tag = stack.tag
            let targets = Array((shelves?.points(tag) ?? []).prefix(shelves?.allocated(tag) ?? 0))
            let from = tag == open ? (items.first?.position ?? stack.position) : stack.position
            if stack.isHidden && tag != open {
                shelves?.setOut(tag, 0)   // 아직 내리기 전 · 내리는 중 — 바로 제자리
                stack.removeFromParent()
                continue
            }
            stack.run(.sequence([.wait(forDuration: delay), .fadeOut(withDuration: 0.12), .removeFromParent()]))
            for (index, target) in targets.enumerated() {
                fly(DiskShelves.texture(tag, dashed: false, variant: index), size: DiskShelves.boxSize, from: from, to: target, delay: delay + Double(index) * 0.03, duration: 0.3, completion: nil)
            }
            timers.run(.sequence([.wait(forDuration: delay + Double(targets.count) * 0.03 + 0.32), .run { [weak self] in
                self?.shelves?.setOut(tag, 0)
                self?.returning.remove(tag)
                self?.onChange?()
            }]))
            delay += 0.15
        }
        for box in items { box.run(.sequence([.group([.moveBy(x: 0, y: 14, duration: 0.25), .fadeOut(withDuration: 0.25)]), .removeFromParent()])) }
        stacks = []
        openTag = nil
        openItems = []
        // 탁자에 없던 꼬리표 중 아직 빠진 것(내리던 중 끊김)도 제자리로.
        for tag in shelves?.stockedTags ?? [] where (shelves?.outCount(tag) ?? 0) > 0 && !list.contains(where: { $0.tag == tag }) { shelves?.setOut(tag, 0) }
        timers.run(.sequence([.wait(forDuration: delay + 0.5), .run { [weak self] in
            guard let self, self.closing else { return }
            completion()
        }]))
    }

    // MARK: 순찰(드물게): 한 명이 내려와 선반을 따라 걸으며 센다 — 상자는 그대로

    @discardableResult
    func idleCount() -> Bool {
        guard phase == .idle, counter == nil else { return false }
        let hand = makeClerk(3)
        counter = hand
        counterSince = clock
        note("순찰 · 재고 세기")
        hand.position = CGPoint(x: shaft, y: floorLine)
        hand.alpha = 0
        hand.run(.sequence([.run { [weak self] in self?.openElevator?(0) }, .wait(forDuration: 0.15), .fadeIn(withDuration: 0.2), .run { [weak self] in
            self?.countShelf(hand, index: 0)
        }]), withKey: "task")
        return true
    }

    private func countShelf(_ hand: StockHand, index: Int) {
        guard counter === hand else { return }
        guard index < WarehouseNode.shelfXs.count else {
            walk(hand, to: shaft) { [weak self] in
                guard let self else { return }
                self.openElevator?(0)
                hand.run(.sequence([.wait(forDuration: 0.15), .fadeOut(withDuration: 0.2), .run { [weak self] in
                    hand.removeFromParent()
                    if self?.counter === hand { self?.counter = nil }
                }]), withKey: "task")
            }
            return
        }
        walk(hand, to: WarehouseNode.shelfXs[index] + 15) { [weak self] in
            guard let self else { return }
            hand.face(right: true)
            hand.loop([.wave(0), .wave(1)], fps: 2.5)
            // 순찰 대사도 드문 연출 난수로(순찰이 끼어도 다른 연출의 씨앗 순서가 밀리지 않게).
            if index == 0 { self.say(hand, Variety.shared.rareElement(Lines.stockCount) ?? Lines.stockCount[0], seconds: 2.2) }
            hand.run(.sequence([.wait(forDuration: 1.3), .run { [weak self] in self?.countShelf(hand, index: index + 1) }]), withKey: "task")
        }
    }

    private func cancelCounter() {
        guard let hand = counter else { return }
        counter = nil
        hand.removeAllActions()
        hand.run(.sequence([.fadeOut(withDuration: 0.2), .removeFromParent()]))
    }

    // MARK: 움직임

    /// 같은 층 걷기(손수레를 몰면 밀고 · 끌고). 거리는 출발하는 순간의 위치로 잰다.
    private func walk(_ hand: StockHand, to x: CGFloat, speed: CGFloat = InventoryNode.speed, push: Bool? = nil, then: @escaping () -> Void) {
        let start = hand.position.x
        let distance = abs(x - start)
        guard distance > 0.5 else { hand.position.x = x; then(); return }
        let right = x > start
        let pushing = push ?? (!hand.truck.isHidden && right)
        hand.face(right: right)
        hand.loop((0..<4).map { pushing || hand.held != nil ? WorkerPose.push($0) : .walk($0) }, fps: 8)
        hand.held?.position = CGPoint(x: 8, y: 7)
        hand.run(.sequence([.moveTo(x: x, duration: TimeInterval(distance / speed)), .run { hand.stand() }, .run(then)]), withKey: "task")
    }

    /// 다른 층으로: 엘리베이터까지 걸어 문 열림 → 사라짐 → 이동 시간 → 그 층 칸에서 나타나 걷는다.
    private func ride(_ hand: StockHand, toFloor floor: Int, x: CGFloat, speed: CGFloat, then: @escaping () -> Void) {
        let from = 0
        walk(hand, to: shaft, speed: speed) { [weak self] in
            guard let self else { return }
            self.openElevator?(from)
            hand.run(.sequence([
                .wait(forDuration: 0.15), .fadeOut(withDuration: 0.15), .wait(forDuration: 0.3 * Double(abs(floor - from)) + 0.15),
                .run { [weak self] in
                    guard let self else { return }
                    hand.position = CGPoint(x: self.shaft, y: self.lineOf?(floor) ?? hand.position.y)
                    self.openElevator?(floor)
                },
                .fadeIn(withDuration: 0.15),
                .run { [weak self] in self?.walk(hand, to: x, speed: speed, then: then) }
            ]), withKey: "task")
        }
    }

    /// 다른 일꾼과 겹치지 않게 탁자 오른쪽 끝 바깥으로 비켜 선다(탁자 위 묶음을 가리지 않게).
    private func stepAside(_ hand: StockHand) {
        guard let index = hands.firstIndex(where: { $0 === hand }) else { return }
        walk(hand, to: Self.tableX1 + 6 + CGFloat(max(0, index - 1)) * 11) { hand.stand(right: false) }
    }

    private func say(_ hand: StockHand, _ text: String, style: TextBadge.Style = .bubble, seconds: TimeInterval) {
        onSay?(hand.body, text, style, seconds)
    }

    /// 포물선 이동(상자 던지기).
    private func arc(to target: CGPoint, duration: TimeInterval) -> SKAction {
        .customAction(withDuration: duration) { node, elapsed in
            if node.userData?["arcFrom"] == nil { node.userData = ["arcFrom": NSValue(point: node.position)] }
            guard let start = (node.userData?["arcFrom"] as? NSValue)?.pointValue else { return }
            let t = min(1, max(0, elapsed / CGFloat(duration)))
            let peak = max(start.y, target.y) + 9
            let x = start.x + (target.x - start.x) * t
            let a = start.y + (peak - start.y) * min(1, t * 2)
            let y = t < 0.5 ? a : peak + (target.y - peak) * (t - 0.5) * 2
            node.position = CGPoint(x: x, y: y)
            if t >= 1 { node.userData?["arcFrom"] = nil }
        }
    }

    /// 선반 ↔ 탁자 사이를 나는 상자(연출용 사본).
    private func fly(_ texture: SKTexture, size: CGSize, from: CGPoint, to target: CGPoint, delay: TimeInterval, duration: TimeInterval, completion: (() -> Void)?) {
        let ghost = SKSpriteNode(texture: texture, size: size)
        ghost.anchorPoint = CGPoint(x: 0.5, y: 0)
        ghost.position = from
        ghost.zPosition = 4.8
        ghost.isHidden = delay > 0
        addChild(ghost)
        ghosts.append(ghost)
        ghost.run(.sequence([.wait(forDuration: delay), .unhide(), arc(to: target, duration: duration), .run { [weak self, weak ghost] in
            ghost?.removeFromParent()
            if let ghost { self?.ghosts.removeAll { $0 === ghost } }
            completion?()
        }]))
    }

    private func removeGhosts() {
        ghosts.forEach { $0.removeFromParent() }
        ghosts = []
    }

    /// 선반 배치가 바뀜(장면의 setDiskStock · 짐꾼): 묶음 높이를 맞춘다.
    func stockChanged() {
        for stack in stacks { stack.setHeight(max(1, min(3, shelves?.allocated(stack.tag) ?? 1))) }
    }

    // MARK: 검수용

    /// 사람마다 이름(역할 번호 — 같은 사람은 같은 이름: 반장 재고0 · 손수레 · 압축 재고1~2 · 순찰 재고3 · 기술자).
    var crewProbes: [(name: String, node: StockHand)] {
        func name(_ hand: StockHand) -> String {
            if case .clerk(let index) = hand.role { return "재고\(index)" + (hand.errand ? "(심부름)" : "") }
            return "기술자"
        }
        return (hands + couriers + [technician, counter].compactMap { $0 }).map { (name($0), $0) }
    }
    var stackTags: [DiskTag] { stacks.filter { !$0.isHidden && $0.parent != nil }.map(\.tag) }
    var visibleStackCount: Int { stacks.filter { !$0.isHidden && $0.parent != nil }.count }
    var itemCount: Int { itemBoxes.count }
    var overflow: Int { max(0, openItems.count - Self.maxItems) }
    var tableVisible: Bool { !table.isHidden && table.alpha > 0.5 }
    func sticker(_ path: String) -> Bool? { itemBoxes.first { $0.path == path }?.item.marked }
    var truckLoad: Int { truckHand?.cargoCount ?? 0 }
    var pending: (open: Bool, execute: Bool, finish: Bool) { (pendingOpen != nil, pendingExecute != nil, pendingFinish != nil) }
    /// 탁자 위 상자가 모두 탁자 윗면 위에 앉았는가(날거나 뛰는 중인 것 빼고).
    var tableSeated: Bool {
        let stacksOK = stacks.filter { !$0.isHidden && $0.action(forKey: "slide") == nil }.allSatisfy { abs($0.position.y - tableTop) < 0.5 }
        let itemsOK = itemBoxes.filter { $0.action(forKey: "jump") == nil }.enumerated().allSatisfy { abs($0.element.position.y - itemPoint($0.offset).point.y) < 0.5 }
        return stacksOK && itemsOK
    }
    /// 항목 상자(경로 · 건물 좌표 아래 가운데 · 뒷줄인가).
    var itemProbes: [(item: DiskStockItem, point: CGPoint)] { itemBoxes.map { ($0.item, $0.position) } }
    /// 묶음(꼬리표 · 아래 가운데 · 높이) — 이름표 자리.
    var stackProbes: [(tag: DiskTag, point: CGPoint, height: CGFloat, compact: Bool)] {
        stacks.filter { !$0.isHidden && $0.parent != nil }.map { ($0.tag, $0.position, $0.height, openTag != nil) }
    }
}

// MARK: - 장면: 손잡이 · 이름표 · 자동 줌 · 검수

/// 디스크 저장고 · 재고 조사 글자(장면이 놓는다): 선반 꼬리표 · 탁자 묶음 · 항목 이름표 · 스티커 글자 · '+N' · 손수레 꼬리표.
final class DiskLabelBoard {
    /// 글자 색(폐기 빨강 · 보관 초록 · 되돌릴 수 있음 초록) — 같은 색 객체를 써야 꼬리표를 다시 그리지 않는다(TextBadge.tint는 바뀔 때만 다시 그린다).
    static let markTint = DiskStockArt.markRed.darker(0.1).nsColor
    static let keepTint = DiskStockArt.keepGreen.darker(0.25).nsColor
    static let truckTint = DiskStockArt.keepGreen.darker(0.3).nsColor
    var shelf: [String: TextBadge] = [:]
    var stack: [String: TextBadge] = [:]
    var item: [String: TextBadge] = [:]
    var sticker: [String: TextBadge] = [:]
    var overflow: TextBadge?
    var truck: TextBadge?
    /// 지난번 자리 잡기의 입력 지문(배율 · 가까이 · 상자 · 손수레 자리 · 글자 세대) — 같으면 매 프레임 겹침 정리를 건너뛴다.
    var signature: Int?
    var generation = 0
    /// 지난 자리 잡기에서 보인 글자들의 사각형(글자 층) — 말풍선 겹침 정리가 장애물로 다시 쓴다(매 프레임 새로 모으지 않게).
    var frames: [CGRect] = []
}

extension OfficeScene {
    /// 디스크 저장고 진열(늘): 디스크 지도의 꼬리표 합계. 선반 칸 수는 그대로 실제 사용량(짐꾼)이고, 그 칸을 이 비율로 꼬리표별 색칠한다.
    func setDiskStock(_ groups: [DiskStockGroup]) {
        diskStock = groups
        warehouseNode.diskShelves.setStock(groups, used: diskUsedNow)
        inventory.stockChanged()
        refreshDiskLabels()
    }

    /// 재고 조사 시작(지도 화면이 열릴 때): 인력이 내려와 묶음을 탁자로 내린다. 카메라가 기계실로.
    func inventoryBegin(groups: [DiskStockGroup]) {
        let fresh = inventory.phase == .idle || inventory.phase == .leaving
        inventory.begin(groups: groups)
        if fresh { requestEventShot(Shot(target: .rect(inventoryStageRect), caption: "디스크 정비 · 재고 조사", duration: 12, priority: 2)) }
        refreshDiskLabels()
    }

    /// 묶음 하나를 열어 항목을 펼친다(최대 12개 + '+N').
    func inventoryOpen(group: DiskTag, items: [DiskStockItem]) {
        let fresh = inventory.phase == .idle || inventory.phase == .leaving
        inventory.open(tag: group, items: items)
        if fresh { requestEventShot(Shot(target: .rect(inventoryStageRect), caption: "디스크 정비 · 재고 조사", duration: 12, priority: 2)) }
        refreshDiskLabels()
    }

    /// 표시: 폐기(빨간 스티커) · 보관(초록).
    func inventoryMark(path: String, marked: Bool) {
        inventory.mark(path: path, marked: marked)
        refreshDiskLabels()
    }

    /// 실행(앱이 실제로 처리한 뒤): 보관 → 선반 · 휴지통 → 손수레로 금고 · 삭제 → 압축기 · 정리 명령 → 기술자.
    func inventoryExecute(trash: [String], delete: [String], prune: [DiskTag]) {
        var parts: [String] = []
        if !trash.isEmpty { parts.append("휴지통 \(trash.count)") }
        let deleting = Set(delete).subtracting(trash).count
        if deleting > 0 { parts.append("삭제 \(deleting)") }
        if !prune.isEmpty { parts.append("정리 명령 \(Set(prune).count)") }
        requestEventShot(Shot(target: .rect(inventoryStageRect), caption: "디스크 정비 · " + (parts.isEmpty ? "모두 보관" : parts.joined(separator: " · ")), duration: 12, priority: 2))
        inventory.execute(trash: trash, delete: delete, prune: prune)
        refreshDiskLabels()
    }

    /// 마침(앱이 다시 잰 뒤): 선반이 실제 값으로 다시 재어지고 한 명이 "실측 +X"(0이면 "줄어든 게 없어요")를 외친 뒤 나간다.
    func inventoryFinish(measuredFreed: UInt64) {
        requestEventShot(Shot(target: .rect(inventoryStageRect), caption: measuredFreed > 0 ? "디스크 정비 · 실측 +\(Fmt.size(measuredFreed))" : "디스크 정비 · 줄어든 게 없습니다", duration: 9, priority: 2))
        inventory.finish(measured: measuredFreed)
        refreshDiskLabels()
    }

    /// 취소: 탁자 위 상자를 모두 선반으로 · 인력 퇴장.
    func inventoryCancel() {
        inventory.cancel()
        refreshDiskLabels()
    }

    /// 드문 순찰(재고 세기)을 지금 — 장면의 1초 주기가 확률로 부른다. 검수 · 미리보기용으로도 연다.
    @discardableResult
    func inventoryIdleCount() -> Bool { inventory.idleCount() }

    /// 1초 주기(ambientTick)에서: 안전망 · 드문 순찰(평균 10분에 한 번, 본 난수 순서와 따로 굴린다).
    func inventoryTick() {
        inventory.tick(activeTime: activeTime)
        if !inventory.active, inventory.counter == nil, Variety.shared.rareChance(InventoryNode.idleChance) { inventory.idleCount() }
    }

    /// 실측(마침 · 실행 뒤 취소 · 안전망): 선반 칸을 실제 값에 바로 맞추고 빈칸 · 작아진 상자를 푼다.
    func remeasureDisk() {
        warehouseNode.snapDisk()
        warehouseNode.diskShelves.clearOut()
        refreshDiskLabels()
    }

    /// 지금 디스크 사용량(바이트, 마지막 스냅샷).
    var diskUsedNow: UInt64 {
        guard let disk = snapshot?.system.disk, disk.total > 0 else { return 0 }
        return disk.total > disk.available ? disk.total - disk.available : 0
    }

    /// 재고 조사 무대(압축기 ~ 선반 오른쪽): 자동 줌이 이 사각형을 화면에 채운다.
    var inventoryStageRect: CGRect {
        let floor = currentLayout.floors[currentLayout.basementIndex]
        return CGRect(x: InventoryNode.compactorX - 14, y: CGFloat(floor.y) - 4, width: 196, height: CGFloat(floor.height) + 10)
    }

    // MARK: 이름표

    /// 글자 상자를 지금 상태에 맞춰 만들고 지운다(문구도). 자리 · 보이기는 repositionDiskLabels.
    func refreshDiskLabels() {
        let board = diskLabels
        let shelves = warehouseNode.diskShelves
        // 선반 꼬리표(진열 묶음을 받기 전에는 모두 '기타'라 붙이지 않는다)
        var shelfKeys = Set<String>()
        for anchor in diskStock.isEmpty ? [] : shelves.labelAnchors(avoidBottom: inventory.tableVisible) {
            let key = anchor.tag?.rawValue ?? "rest"
            shelfKeys.insert(key)
            let badge = board.shelf[key] ?? makeDiskBadge(.tiny)
            board.shelf[key] = badge
            badge.set(anchor.tag?.shelfLabel ?? "기타")
        }
        for (key, badge) in board.shelf where !shelfKeys.contains(key) { badge.removeFromParent(); board.shelf[key] = nil }
        // 탁자 묶음
        var stackKeys = Set<String>()
        for probe in inventory.stackProbes {
            stackKeys.insert(probe.tag.rawValue)
            let badge = board.stack[probe.tag.rawValue] ?? makeDiskBadge(.tiny)
            board.stack[probe.tag.rawValue] = badge
            badge.set(probe.tag.shelfLabel)
        }
        for (key, badge) in board.stack where !stackKeys.contains(key) { badge.removeFromParent(); board.stack[key] = nil }
        // 항목 이름표 · 스티커 글자
        var itemKeys = Set<String>()
        for probe in inventory.itemProbes {
            let item = probe.item
            itemKeys.insert(item.path)
            let label = board.item[item.path] ?? makeDiskBadge(.tiny)
            board.item[item.path] = label
            let name = item.name.count > 9 ? String(item.name.prefix(9)) + "…" : item.name
            label.set("\(name) · \(Fmt.size(item.bytes)) · \(item.tag.shelfLabel)")
            let sticker = board.sticker[item.path] ?? makeDiskBadge(.tiny)
            board.sticker[item.path] = sticker
            let marked = inventory.sticker(item.path) ?? item.marked
            sticker.tint = marked ? DiskLabelBoard.markTint : DiskLabelBoard.keepTint
            sticker.set(marked ? "폐기" : "보관")
        }
        for (key, badge) in board.item where !itemKeys.contains(key) { badge.removeFromParent(); board.item[key] = nil }
        for (key, badge) in board.sticker where !itemKeys.contains(key) { badge.removeFromParent(); board.sticker[key] = nil }
        // '+N' 판
        if inventory.overflow > 0 {
            let badge = board.overflow ?? makeDiskBadge(.plate)
            board.overflow = badge
            badge.set("+\(inventory.overflow)")
        } else {
            board.overflow?.removeFromParent()
            board.overflow = nil
        }
        // 손수레 꼬리표
        if let text = inventory.truckTag {
            let badge = board.truck ?? makeDiskBadge(.tiny)
            board.truck = badge
            badge.tint = DiskLabelBoard.truckTint
            badge.set(text)
        } else {
            board.truck?.removeFromParent()
            board.truck = nil
        }
        board.generation += 1
        repositionDiskLabels()
    }

    private func makeDiskBadge(_ style: TextBadge.Style) -> TextBadge {
        let badge = TextBadge("", style: style)
        overlay.addChild(badge)
        return badge
    }

    /// 매 프레임(재고 조사 중) · 카메라가 바뀔 때: 글자 자리 · 보이기. 가까이 다가가 있을 때만 꼬리표 · 이름표 · 스티커를 보이고,
    /// 겹치면 이름표는 위로 몇 칸 올리고(그래도 겹치면 숨김), 선반 꼬리표는 겹치면 숨긴다. '+N' 판과 손수레 꼬리표는 늘 보인다.
    func repositionDiskLabels() {
        let board = diskLabels
        let ppp = pointsPerPixel
        let zoomed = lodZoomed ?? false
        let items = inventory.itemProbes
        let stackList = inventory.stackProbes
        // 입력이 그대로면(아무것도 안 움직임) 건너뛴다 — 재고 조사 내내 매 프레임 부르므로.
        var hasher = Hasher()
        hasher.combine(ppp)
        hasher.combine(zoomed)
        hasher.combine(board.generation)
        hasher.combine(inventory.tableVisible)
        for probe in items { hasher.combine(probe.point.x); hasher.combine(probe.point.y) }
        for probe in stackList { hasher.combine(probe.point.x); hasher.combine(probe.point.y); hasher.combine(probe.height); hasher.combine(probe.compact) }
        if let hand = inventory.truckHand { hasher.combine(hand.position.x); hasher.combine(hand.position.y); hasher.combine(hand.alpha) }
        let signature = hasher.finalize()
        guard signature != board.signature else { return }
        board.signature = signature
        var placed: [CGRect] = []
        // 천장: 기계실 '디스크 저장고' 배지(바닥선 + 56) 아래까지만 — 넘치는 이름표는 숨긴다(배지와 겹치지 않게).
        let ceiling = (inventory.floorLine + 56) * ppp - 12
        func rect(_ badge: TextBadge, _ point: CGPoint) -> CGRect {
            let size = badge.badgeSize
            return CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
        }
        func put(_ badge: TextBadge, at point: CGPoint, lifts: Int, show: Bool) {
            guard show, badge.badgeSize.width > 0 else { badge.isHidden = true; return }
            var frame = rect(badge, point)
            for _ in 0...lifts {
                if frame.maxY > ceiling { break }
                if !placed.contains(where: { $0.insetBy(dx: -1, dy: -1).intersects(frame) }) {
                    placed.append(frame)
                    badge.position = CGPoint(x: frame.midX, y: frame.midY)
                    badge.isHidden = false
                    return
                }
                frame.origin.y += frame.height + 2
            }
            badge.isHidden = true
        }
        // 늘 보이는 것: '+N' 판 · 손수레 꼬리표
        if let badge = board.overflow {
            let range = inventory.itemsRange
            let point = CGPoint(x: (range.upperBound - 2) * ppp, y: (inventory.floorLine + InventoryNode.tableHeight + 16) * ppp)
            put(badge, at: point, lifts: 2, show: true)
        }
        if let badge = board.truck, let hand = inventory.truckHand, hand.parent != nil {
            let base = hand.convert(CGPoint(x: StockHand.truckOffset + 6, y: 22), to: world)
            badge.position = CGPoint(x: base.x * ppp, y: base.y * ppp)
            badge.isHidden = hand.alpha < 0.3
            if !badge.isHidden { placed.append(rect(badge, badge.position)) }
        } else {
            board.truck?.isHidden = true
        }
        // 스티커 글자(상자 위) → 항목 이름표(상자 위쪽, 겹치면 올림)
        for probe in items {
            guard let badge = board.sticker[probe.item.path] else { continue }
            // 상자 아래쪽 절반에(윗면 · 테이프는 보이게) — 스티커 픽셀이 붙은 자리.
            put(badge, at: CGPoint(x: probe.point.x * ppp, y: (probe.point.y + 1.8) * ppp), lifts: 0, show: zoomed)
        }
        for probe in items.sorted(by: { ($0.point.y, $0.point.x) < ($1.point.y, $1.point.x) }) {
            guard let badge = board.item[probe.item.path] else { continue }
            let base = CGPoint(x: probe.point.x * ppp, y: (probe.point.y + 6) * ppp + badge.badgeSize.height / 2 + 7)
            put(badge, at: base, lifts: 7, show: zoomed)
        }
        // 탁자 묶음(펼친 묶음이 있으면 촘촘히 선 묶음은 글자를 숨긴다)
        for probe in stackList {
            guard let badge = board.stack[probe.tag.rawValue] else { continue }
            let base = CGPoint(x: probe.point.x * ppp, y: (probe.point.y + probe.height) * ppp + badge.badgeSize.height / 2 + 3)
            put(badge, at: base, lifts: 2, show: zoomed && !probe.compact)
        }
        // 선반 꼬리표(그 단 상자 바로 위) — 겹치면 숨김. 탁자 위에 묶음 · 항목이 놓인 동안은 탁자가 주인공이라 숨긴다.
        let tableBusy = inventory.visibleStackCount > 0 || inventory.itemCount > 0
        let anchors = board.shelf.isEmpty ? [] : warehouseNode.diskShelves.labelAnchors(avoidBottom: inventory.tableVisible)
        for anchor in anchors.sorted(by: { $0.total > $1.total }) {
            guard let badge = board.shelf[anchor.tag?.rawValue ?? "rest"] else { continue }
            put(badge, at: CGPoint(x: anchor.point.x * ppp, y: (anchor.point.y + 1.5) * ppp), lifts: 0, show: zoomed && !tableBusy)
        }
        for (key, badge) in board.shelf where !anchors.contains(where: { ($0.tag?.rawValue ?? "rest") == key }) { badge.isHidden = true }
        board.frames = placed
    }

    /// 이름표를 매 프레임 따라 움직여야 하는가(재고 조사 중 · 순찰 · 심부름).
    var diskLabelsLive: Bool { inventory.active || inventory.anyoneHere || diskLabels.truck != nil }

    // MARK: 검수용

    var inventoryNode: InventoryNode { inventory }
    var diskShelvesNode: DiskShelves { warehouseNode.diskShelves }
    /// 재고 조사 인력이 지금 하는 말(반장 · 손수레 · 압축 · 기술자 · 순찰 중 가장 최근).
    var inventorySaying: [String] {
        inventory.crewProbes.compactMap { probe in staffBubbles[ObjectIdentifier(probe.node.body)].flatMap { $0.parent == nil || $0.isHidden ? nil : $0.currentText } }
    }
    var inventoryProbes: [(name: String, probe: StaffProbe)] {
        inventory.crewProbes.map { item in
            let node = item.node
            return (item.name, StaffProbe(floor: currentLayout.floors.firstIndex { abs(CGFloat($0.floorLine) - node.position.y) < 0.5 } ?? -1,
                                         x: node.position.x, y: node.position.y, alpha: node.alpha, present: node.parent != nil))
        }
    }
    /// 보이는 디스크 글자(문구 · 글자 층 사각형).
    var diskLabelFrames: [(text: String, frame: CGRect)] {
        let board = diskLabels
        let all = Array(board.shelf.values) + Array(board.stack.values) + Array(board.item.values) + Array(board.sticker.values) + [board.overflow, board.truck].compactMap { $0 }
        return all.filter { !$0.isHidden && $0.parent != nil }.map { badge in
            (badge.currentText, CGRect(x: badge.position.x - badge.badgeSize.width / 2, y: badge.position.y - badge.badgeSize.height / 2, width: badge.badgeSize.width, height: badge.badgeSize.height))
        }
    }
    /// 재고 조사 인력의 말풍선(글자 층 사각형).
    var inventoryBubbleFrames: [CGRect] {
        inventory.crewProbes.compactMap { probe in
            guard let bubble = staffBubbles[ObjectIdentifier(probe.node.body)], bubble.parent != nil, !bubble.isHidden else { return nil }
            return CGRect(x: bubble.position.x - bubble.badgeSize.width / 2, y: bubble.position.y - bubble.badgeSize.height / 2, width: bubble.badgeSize.width, height: bubble.badgeSize.height)
        }
    }
    var diskOverflowText: String? { diskLabels.overflow?.currentText }
    var diskTruckTagText: String? { diskLabels.truck?.currentText }
}
