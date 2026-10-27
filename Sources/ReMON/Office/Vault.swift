import AppKit
import ReMONCore
import SpriteKit

// 기록 보관소 = 복구 금고(RecoveryVault)의 방(10-25 대표 지시 '기록 보관소 = 금고의 방, 서가 상자 = 금고 항목, 누르면 복구함').
// 서가: 왼쪽 위 두 단 = 정리한 세션(복귀 가능) · 왼쪽 아래 두 단 = 휴지통으로 보낸 파일 · 오른쪽 위 = 지운 워크트리 · 브랜치 · 오른쪽 아래 = 정리한 프로세스.
// 서가 꼭대기(다락) = 만료(보관 기간이 지나 되돌릴 수 없음) — 먼지 앉은 상자. 한 칸에 한 건, 칸이 차면 더 그리지 않는다(명판 · 칸 이름표가 실제 수를 말한다).
// 기록관이 새 항목을 받아 사다리를 굴려 꽂고(수가 늘 때), 복구하면 꺼내 들고 나간다(수가 줄 때).

/// 금고 방 배치(별관 왼쪽 끝 472 기준 x · 로비 층 천장에서 아래로 잰 캔버스 행). FloorPainter.library의 서가와 같은 자리다.
enum VaultLayout {
    enum Shelf: Int, CaseIterable { case sessions, files, git, processes, expired }

    static var wing: CGFloat { CGFloat(BuildingLayout.wingX0) }
    /// 서가 칸(왼쪽 서가 칸 폭 24 = 상자 8px 셋 붙여, 오른쪽 서가 칸 폭 29 = 9px 간격).
    static let leftColumns: [CGFloat] = [4, 30]
    static let rightColumns: [CGFloat] = [97, 128]
    /// 단마다 상자가 서는 판(천장에서 아래로 잰 행): 서가 윗면 19 + 11 · 22 · 33 · 44.
    static let rowPlanks: [CGFloat] = [30, 41, 52, 63]
    /// 다락: 서가 윗면(행 19) 위 두 겹, 왼쪽 서가 위 4개 · 오른쪽 서가 위 4개(가운데 방 이름표 자리는 비운다).
    static let atticPlank: CGFloat = 19
    static let atticXs: [CGFloat] = [4, 120]
    static let capacity = 12
    static let atticCapacity = 16
    /// 기록관이 서 있는 자리(문서 보관장 앞) · 항목이 들고 나는 곳(별관 왼쪽 끝) · 사다리가 처음 서 있는 곳(왼쪽 서가 오른편).
    static var idleX: CGFloat { wing + 88 }
    static var doorX: CGFloat { wing + 8 }
    /// 사다리 쉬는 자리: 왼쪽 서가 오른쪽 기둥 옆(상자를 가리지 않는다).
    static var ladderRestX: CGFloat { wing + 58 }

    static func capacity(_ shelf: Shelf) -> Int { shelf == .expired ? atticCapacity : capacity }

    /// 칸 하나의 상자 자리(아래 가운데, 건물 좌표) · 그 칸 앞 사다리 자리.
    static func slot(_ shelf: Shelf, _ index: Int, ceiling: CGFloat) -> (point: CGPoint, ladderX: CGFloat) {
        if shelf == .expired {
            let side = index / 8, layer = (index % 8) / 4, k = index % 4
            let x0 = wing + atticXs[side]
            return (CGPoint(x: x0 + CGFloat(k) * 8 + 4, y: ceiling - atticPlank + CGFloat(layer) * 7), x0 + 16)
        }
        let row = (shelf == .sessions || shelf == .git ? 0 : 2) + index / 6
        let column = (index % 6) / 3, k = index % 3
        let left = shelf == .sessions || shelf == .files
        let c0 = wing + (left ? leftColumns[column] : rightColumns[column])
        let x = left ? c0 + CGFloat(k) * 8 + 4 : c0 + 1 + CGFloat(k) * 9 + 4
        return (CGPoint(x: x, y: ceiling - rowPlanks[row]), left ? c0 + 12 : c0 + 14)
    }
}

/// 금고 상자 그림(8×7, 앞면).
enum VaultArt {
    static func box(_ shelf: VaultLayout.Shelf) -> PixelCanvas {
        var c = PixelCanvas(8, 7)
        switch shelf {
        case .sessions:   // 세션 기록철: 남색 상자 + 색 등 세 줄(대화 · 이어 열기 키)
            let fill = PixelColor(0x2E4A7A)
            c.box(0, 0, 8, 7, fill: fill, outline: fill.darker(0.4), rounded: false)
            for (i, color) in [PixelColor(0xE8735A), PixelColor(0x2BA59B), PixelColor(0xF2C14E)].enumerated() { c.vline(2 + i * 2, 1, 4, color) }
            c.hline(1, 5, 6, Pal.paper)
        case .files:      // 휴지통 파일: 골판지 + 테이프 + 흰 송장
            c.box(0, 0, 8, 7, fill: Pal.cardboard, outline: Pal.cardboardShade.darker(0.2), rounded: false)
            c.vline(3, 1, 5, Pal.tape); c.rect(5, 2, 2, 2, Pal.paper)
        case .git:        // 워크트리 · 브랜치: 흰 보존 상자 + 주황 갈래 표시
            let fill = PixelColor(0xE9E4D8)
            c.box(0, 0, 8, 7, fill: fill, outline: fill.darker(0.38), rounded: false)
            let mark = PixelColor(0xE8603C)
            c.vline(2, 1, 5, mark); c.dot(3, 3, mark); c.dot(4, 2, mark); c.dot(5, 1, mark); c.dot(2, 5, mark.darker(0.2)); c.dot(5, 2, mark.darker(0.2))
        case .processes:  // 프로세스: 회색 금속 카트리지 + 초록 표시등 + 꽂는 홈
            let fill = PixelColor(0x8D9AA8)
            c.box(0, 0, 8, 7, fill: fill, outline: fill.darker(0.45), rounded: false)
            c.hline(2, 2, 4, PixelColor(0x4A5260)); c.dot(6, 4, Pal.leafLight); c.hline(1, 5, 3, fill.lighter(0.25))
        case .expired:    // 만료: 빛바랜 상자 + 빨간 ✕ 도장 + 거미줄
            let fill = PixelColor(0xA89E8A)
            c.box(0, 0, 8, 7, fill: fill, outline: fill.darker(0.35), rounded: false)
            for i in 0..<3 { c.dot(3 + i, 2 + i, PixelColor(0xB5483F)); c.dot(5 - i, 2 + i, PixelColor(0xB5483F)) }
            c.dot(1, 1, PixelColor(0xE6E3DC)); c.dot(2, 1, PixelColor(0xD4D0C6)); c.dot(1, 2, PixelColor(0xD4D0C6))
        }
        return c
    }
}

/// 금고 방 노드(건물 좌표 그대로 — 원점 0,0): 서가 상자 · 이동식 사다리 · 기록관과 할 일 줄.
final class VaultNode: SKNode {
    typealias Shelf = VaultLayout.Shelf

    enum TaskKind { case file, restore, expire }
    struct Task {
        var kind: TaskKind
        var shelf: Shelf
    }

    let archivist = SKSpriteNode()
    let ladder = SKSpriteNode()
    private var boxes: [Shelf: [SKSpriteNode]] = [:]
    /// 서가에 보이는 상자 수 · 줄 선 일까지 반영한 수(새 값과의 차이를 셀 때).
    private(set) var shown: [Shelf: Int] = [:]
    private var planned: [Shelf: Int] = [:]
    private var tasks: [Task] = []
    private(set) var current: Task?
    private var held: SKSpriteNode?
    private(set) var floorLine: CGFloat = 0
    private(set) var ceiling: CGFloat = 0
    private(set) var initialized = false
    private var clock: TimeInterval = 0
    private var taskStarted: TimeInterval = 0
    var onSay: ((SKSpriteNode, String) -> Void)?
    var onTaskStart: ((Task) -> Void)?
    /// 검수용 기록(받음 · 꽂음 · 꺼냄 · 내보냄 · 다락).
    private(set) var log: [String] = []

    static let ladderHeight = 65

    override init() {
        super.init()
        ladder.texture = TextureCache.shared.texture("vault-ladder") { Furniture.rollingLadder(height: VaultNode.ladderHeight) }
        ladder.size = CGSize(width: 8, height: Self.ladderHeight)
        ladder.anchorPoint = CGPoint(x: 0.5, y: 0)
        ladder.zPosition = 1.7
        addChild(ladder)
        archivist.anchorPoint = CGPoint(x: 0.5, y: 0)
        archivist.zPosition = 5.5
        addChild(archivist)
        stand(right: false)
        for shelf in Shelf.allCases { shown[shelf] = 0; planned[shelf] = 0; boxes[shelf] = [] }
    }

    required init?(coder: NSCoder) { fatalError() }

    var busy: Bool { current != nil }
    /// 사다리 꼭대기(올라설 수 있는 높이 한도).
    var ladderTop: CGFloat { ladder.position.y + CGFloat(Self.ladderHeight) }

    /// 로비 층이 정해지면(또는 다시 지으면) 사다리 · 기록관 · 상자 자리를 맞춘다.
    func place(floorLine: CGFloat, ceiling: CGFloat) {
        self.floorLine = floorLine
        self.ceiling = ceiling
        // 사다리 아래 끝 = 바닥 띠 뒤쪽(바닥선 + 4), 위 고리 = 놋쇠 레일.
        ladder.position = CGPoint(x: ladder.position.x == 0 ? VaultLayout.ladderRestX : ladder.position.x, y: floorLine + 4)
        if current == nil {
            archivist.removeAllActions()
            archivist.position = CGPoint(x: VaultLayout.idleX, y: floorLine)
            stand(right: false)
        }
        for shelf in Shelf.allCases { for (index, box) in (boxes[shelf] ?? []).enumerated() { box.position = VaultLayout.slot(shelf, index, ceiling: ceiling).point } }
        // 장면에 붙기 전에(창을 열기 전) 들어온 일은 이제 시작한다.
        startNext()
    }

    func tick(activeTime: TimeInterval) {
        clock = activeTime
        if current != nil, activeTime - taskStarted > 40 { snapAll() }
    }

    // MARK: 수 맞추기

    /// 새 수(칸마다 한도까지). 처음이면 그대로 보이고, 그 뒤로는 기록관이 한 건씩 꽂고 · 꺼내고 · 다락으로 옮긴다(밀린 일이 셋을 넘으면 나머지는 바로).
    func setCounts(_ counts: [Shelf: Int]) {
        let want = Dictionary(uniqueKeysWithValues: Shelf.allCases.map { ($0, min(VaultLayout.capacity($0), max(0, counts[$0] ?? 0))) })
        guard initialized else {
            initialized = true
            for shelf in Shelf.allCases { setShown(shelf, want[shelf] ?? 0); planned[shelf] = want[shelf] ?? 0 }
            log.append("처음 채움")
            return
        }
        var delta = Dictionary(uniqueKeysWithValues: Shelf.allCases.map { ($0, (want[$0] ?? 0) - (planned[$0] ?? 0)) })
        var newTasks: [Task] = []
        // 만료: 보관 중이던 칸이 줄고 다락이 늘면 그 상자를 다락으로 옮긴다(복구가 아니다).
        var rise = max(0, delta[.expired] ?? 0)
        for shelf in Shelf.allCases where shelf != .expired {
            while rise > 0, (delta[shelf] ?? 0) < 0 {
                newTasks.append(Task(kind: .expire, shelf: shelf))
                delta[shelf, default: 0] += 1
                delta[.expired, default: 0] -= 1
                rise -= 1
            }
        }
        for shelf in Shelf.allCases {
            let d = delta[shelf] ?? 0
            for _ in 0..<abs(d) { newTasks.append(Task(kind: d > 0 ? .file : .restore, shelf: shelf)) }
        }
        for task in newTasks {
            switch task.kind {
            case .file: planned[task.shelf, default: 0] += 1
            case .restore: planned[task.shelf, default: 0] -= 1
            case .expire: planned[task.shelf, default: 0] -= 1; planned[.expired, default: 0] += 1
            }
            if tasks.count >= 3 { apply(task) } else { tasks.append(task) }
        }
        startNext()
    }

    /// 연출 없이 바로(밀린 일 · 안전망).
    private func apply(_ task: Task) {
        switch task.kind {
        case .file: setShown(task.shelf, (shown[task.shelf] ?? 0) + 1)
        case .restore: setShown(task.shelf, (shown[task.shelf] ?? 0) - 1)
        case .expire:
            setShown(task.shelf, (shown[task.shelf] ?? 0) - 1)
            setShown(.expired, (shown[.expired] ?? 0) + 1)
        }
        log.append("바로 · \(task.kind) · \(task.shelf)")
    }

    /// 보이는 상자 수를 맞춘다(연출 없이).
    private func setShown(_ shelf: Shelf, _ value: Int) {
        let count = max(0, min(VaultLayout.capacity(shelf), value))
        var list = boxes[shelf] ?? []
        while list.count > count { list.removeLast().removeFromParent() }
        while list.count < count { list.append(makeBox(shelf, index: list.count)) }
        boxes[shelf] = list
        shown[shelf] = count
    }

    private func makeBox(_ shelf: Shelf, index: Int) -> SKSpriteNode {
        let box = SKSpriteNode(texture: TextureCache.shared.texture("vault-box-\(shelf.rawValue)") { VaultArt.box(shelf) })
        box.anchorPoint = CGPoint(x: 0.5, y: 0)
        box.size = CGSize(width: 8, height: 7)
        box.position = VaultLayout.slot(shelf, index, ceiling: ceiling).point
        box.zPosition = 1.5
        addChild(box)
        return box
    }

    /// 안전망: 하던 일과 밀린 일을 모두 바로 끝내고 기록관을 제자리로.
    private func snapAll() {
        archivist.removeAllActions()
        ladder.removeAllActions()
        held?.removeFromParent()
        held = nil
        if let task = current { apply(task) }
        tasks.forEach(apply)
        tasks = []
        current = nil
        for shelf in Shelf.allCases { planned[shelf] = shown[shelf] }
        archivist.position = CGPoint(x: VaultLayout.idleX, y: floorLine)
        stand(right: false)
        log.append("안전망")
    }

    // MARK: 기록관 일

    private func startNext() {
        guard current == nil, !tasks.isEmpty, parent != nil else { return }
        let task = tasks.removeFirst()
        current = task
        taskStarted = clock
        onTaskStart?(task)
        switch task.kind {
        case .file: fileTask(task)
        case .restore, .expire: pullTask(task)
        }
    }

    /// 일 하나를 마쳤을 때: 밀린 일이 있으면 바로 다음, 없으면 사다리를 쉬는 자리로 밀어 두고(상자를 가리지 않게) 제자리로 돌아간다.
    private func finish() {
        current = nil
        if tasks.isEmpty {
            var steps: [SKAction] = []
            let rest = VaultLayout.ladderRestX
            if abs(ladder.position.x - rest) > 0.5 {
                steps.append(walk(to: ladder.position.x + (rest > ladder.position.x ? -7 : 7)))
                steps.append(.run { [weak self] in
                    guard let self else { return }
                    let duration = TimeInterval(max(0.05, abs(rest - self.ladder.position.x) / 40))
                    self.ladder.run(.moveTo(x: rest, duration: duration), withKey: "roll")
                    self.archivist.xScale = rest >= self.ladder.position.x ? 1 : -1
                    self.loop((0..<4).map { WorkerPose.walk($0) })
                    self.archivist.run(.sequence([.moveTo(x: rest + (rest > self.ladder.position.x ? -7 : 7), duration: duration),
                                                  .run { [weak self] in self?.goIdle() }]), withKey: "task")
                })
            } else {
                steps.append(.run { [weak self] in self?.goIdle() })
            }
            archivist.run(.sequence(steps), withKey: "task")
        }
        startNext()
    }

    private func goIdle() {
        archivist.run(.sequence([walk(to: VaultLayout.idleX), .run { [weak self] in self?.stand(right: false) }]), withKey: "task")
    }

    /// 새 항목: 별관 왼쪽 끝에서 상자를 받아 들고 → 사다리를 그 칸 앞으로 굴려 → 올라가 꽂는다 → 내려온다.
    private func fileTask(_ task: Task) {
        let index = shown[task.shelf] ?? 0
        guard index < VaultLayout.capacity(task.shelf) else { finish(); return }
        let target = VaultLayout.slot(task.shelf, index, ceiling: ceiling)
        let lines = task.shelf == .expired ? ["만료 기록 · 다락으로", "되돌릴 순 없지만 기록은 남겨요"] : ["보관합니다", "금고에 넣어 둘게요", "기록 하나 추가!", "잘 넣어 둘게요"]
        archivist.run(.sequence([
            walk(to: VaultLayout.doorX),
            .run { [weak self] in self?.receiveBox(task.shelf) },
            .wait(forDuration: 0.45),
            .run { [weak self] in guard let self else { return }; self.onSay?(self.archivist, Variety.shared.line("vaultFile", lines)) },
            .run { [weak self] in self?.climbAndPlace(task, target: target) }
        ]), withKey: "task")
    }

    /// 복구 · 만료: 사다리를 그 칸 앞으로 → 올라가 맨 끝 상자를 꺼낸다 → (복구) 들고 나가 별관 왼쪽 끝으로 내보낸다 / (만료) 다락으로 옮긴다.
    private func pullTask(_ task: Task) {
        let index = (shown[task.shelf] ?? 0) - 1
        guard index >= 0, let box = boxes[task.shelf]?.last else { finish(); return }
        let source = VaultLayout.slot(task.shelf, index, ceiling: ceiling)
        moveLadderAndClimb(to: source) { [weak self] in
            guard let self else { return }
            // 꺼내기: 서가 → 손
            self.boxes[task.shelf]?.removeLast()
            self.shown[task.shelf] = index
            self.hold(box)
            self.log.append("꺼냄 · \(task.shelf)")
            self.archivist.run(.sequence([.wait(forDuration: 0.35), self.climbDown(), .run { [weak self] in
                guard let self else { return }
                if task.kind == .expire { self.toAttic(task) } else { self.sendOut(task) }
            }]), withKey: "task")
        }
    }

    /// 재고 조사 손수레가 휴지통 상자를 별관 벽 앞에 건넸을 때(Inventory.swift): 쉬고 있으면 기록관이 왼쪽 끝으로 나와 받는 몸짓 · 한마디 → 제자리.
    /// 일하는 중이면 한마디만. 서가 수는 여기서 바꾸지 않는다 — 금고 기록이 실제로 늘면 setCounts가 꽂는다(사실 = 금고 장부).
    func receiveDelivery(count: Int) {
        log.append("건네받음 · \(count)")
        let line = Variety.shared.line("archivistReceive", Lines.archivistReceive)
        guard current == nil, tasks.isEmpty, parent != nil else { onSay?(archivist, line); return }
        archivist.run(.sequence([
            walk(to: VaultLayout.doorX),
            .run { [weak self] in
                guard let self else { return }
                self.archivist.xScale = -1   // 벽(손수레) 쪽을 본다
                self.loop([.wave(0), .wave(1)], fps: 4)
                self.onSay?(self.archivist, line)
            },
            .wait(forDuration: 1.4),
            .run { [weak self] in self?.goIdle() }
        ]), withKey: "task")
    }

    private func sendOut(_ task: Task) {
        let lines = ["복구 나갑니다!", "꺼내 드릴게요", "찾으시던 거 여기요", "원래 자리로!"]
        onSay?(archivist, Variety.shared.line("vaultRestore", lines))
        archivist.run(.sequence([walk(to: VaultLayout.doorX), .run { [weak self] in
            guard let self, let box = self.held else { return }
            self.held = nil
            let point = box.convert(.zero, to: self)
            box.removeFromParent()
            box.position = point
            self.addChild(box)
            Effects.sparkle(in: self, at: CGPoint(x: point.x - 4, y: point.y + 8))
            box.run(.sequence([.group([.moveBy(x: -10, y: 0, duration: 0.35), .fadeOut(withDuration: 0.35)]), .removeFromParent()]))
            self.log.append("내보냄 · \(task.shelf)")
        }, .wait(forDuration: 0.4), .run { [weak self] in self?.finish() }]), withKey: "task")
    }

    private func toAttic(_ task: Task) {
        let index = shown[.expired] ?? 0
        guard index < VaultLayout.atticCapacity else {
            held?.removeFromParent(); held = nil
            finish()
            return
        }
        onSay?(archivist, Variety.shared.line("vaultExpire", ["보관 기간 끝 · 다락으로", "만료 · 이제 못 돌려요", "먼지 쌓일 차례"]))
        held?.texture = TextureCache.shared.texture("vault-box-\(Shelf.expired.rawValue)") { VaultArt.box(.expired) }
        climbAndPlace(Task(kind: .file, shelf: .expired), target: VaultLayout.slot(.expired, index, ceiling: ceiling))
    }

    /// 들고 있는 상자를 그 칸에 꽂는다(사다리를 굴리고 올라가서). 꽂는 순간 보이는 수가 하나 는다.
    private func climbAndPlace(_ task: Task, target: (point: CGPoint, ladderX: CGFloat)) {
        moveLadderAndClimb(to: target) { [weak self] in
            guard let self else { return }
            if let box = self.held {
                self.held = nil
                let from = box.convert(.zero, to: self)
                box.removeFromParent()
                box.position = from
                box.zPosition = 1.5
                self.addChild(box)
                let shelf = task.shelf
                box.run(.sequence([.move(to: target.point, duration: 0.25), .run { [weak self] in
                    guard let self else { return }
                    var list = self.boxes[shelf] ?? []
                    list.append(box)
                    self.boxes[shelf] = list
                    self.shown[shelf] = list.count
                    Effects.sparkle(in: self, at: CGPoint(x: target.point.x, y: target.point.y + 8))
                    self.log.append("꽂음 · \(shelf)")
                }]))
            }
            self.archivist.run(.sequence([.wait(forDuration: 0.4), self.climbDown(), .run { [weak self] in self?.finish() }]), withKey: "task")
        }
    }

    // MARK: 움직임

    private func receiveBox(_ shelf: Shelf) {
        let box = SKSpriteNode(texture: TextureCache.shared.texture("vault-box-\(shelf.rawValue)") { VaultArt.box(shelf) })
        box.anchorPoint = CGPoint(x: 0.5, y: 0)
        box.size = CGSize(width: 8, height: 7)
        // 별관 왼쪽 벽 너머에서 손(몸 앞 = 지역 x +6)으로 미끄러져 온다. 좌우가 뒤집혀 있어도 건물 x로 맞춘다.
        box.alpha = 0
        box.zPosition = 0.2
        archivist.addChild(box)
        held = box
        holdPose()
        box.position = CGPoint(x: (VaultLayout.wing - 4 - archivist.position.x) * archivist.xScale, y: 9)
        box.run(.group([.fadeIn(withDuration: 0.2), .move(to: CGPoint(x: 6, y: 9), duration: 0.3)]))
        log.append("받음 · \(shelf)")
    }

    /// 상자를 손에 든다(서가 → 손).
    private func hold(_ box: SKSpriteNode) {
        let point = convert(box.position, to: archivist)
        box.removeFromParent()
        box.position = point
        box.zPosition = 0.2
        archivist.addChild(box)
        held = box
        box.run(.move(to: CGPoint(x: 6, y: 16), duration: 0.25))
    }

    /// 사다리를 그 칸 앞으로 굴린 뒤 올라선다(맨 아랫단은 사다리 없이 바닥에서). 다 올라가면 done.
    private func moveLadderAndClimb(to target: (point: CGPoint, ladderX: CGFloat), done: @escaping () -> Void) {
        let feet = max(floorLine, target.point.y - 17)
        let needLadder = feet > floorLine + 3
        let x = needLadder ? target.ladderX : target.point.x - 6
        var steps: [SKAction] = []
        if needLadder {
            let beside = ladder.position.x - 7
            steps.append(walk(to: beside))
            // 사다리와 함께 굴러간다(기록관은 사다리 왼편에서 민다)
            steps.append(.run { [weak self] in
                guard let self else { return }
                let distance = abs(x - self.ladder.position.x)
                let duration = TimeInterval(max(0.05, distance / 40))
                self.ladder.run(.moveTo(x: x, duration: duration), withKey: "roll")
                self.archivist.xScale = x >= self.ladder.position.x ? 1 : -1
                self.loop((0..<4).map { WorkerPose.walk($0) })
                self.archivist.run(.moveTo(x: x - 7, duration: duration), withKey: "push")
            })
            steps.append(.wait(forDuration: TimeInterval(max(0.05, abs(x - ladder.position.x) / 40)) + 0.05))
            // 올라서기: 사다리 위(가운데)로 → 오른쪽(서가)을 보고 올라간다
            steps.append(.run { [weak self] in
                guard let self else { return }
                self.archivist.removeAction(forKey: "push")
                self.ladder.removeAction(forKey: "roll")
                self.ladder.position.x = x
                self.archivist.position.x = x
                self.archivist.xScale = 1
                self.loop([.climb(0), .climb(1)], fps: 4)
                self.held?.position = CGPoint(x: 7, y: 20)
            })
            let climb = TimeInterval((feet - floorLine) / 24)
            steps.append(.moveTo(y: feet, duration: climb))
            steps.append(.run { [weak self] in self?.archivist.removeAction(forKey: "pose"); self?.archivist.texture = self?.texture(.climb(0)) })
        } else {
            steps.append(walk(to: x))
            steps.append(.run { [weak self] in self?.archivist.xScale = 1; self?.holdPose() })
        }
        steps.append(.run(done))
        archivist.run(.sequence(steps), withKey: "task")
    }

    /// 사다리에서 바닥으로 내려온다(이미 바닥이면 바로). 거리는 만드는 순간(사다리 위)의 높이로 잰다.
    private func climbDown() -> SKAction {
        let height = archivist.position.y - floorLine
        guard height > 0.5 else { return .run { [weak self] in self?.holdPose() } }
        return .sequence([
            .run { [weak self] in self?.loop([.climb(0), .climb(1)], fps: 4) },
            .moveTo(y: floorLine, duration: TimeInterval(height / 30)),
            .run { [weak self] in self?.holdPose() }
        ])
    }

    /// 걷기(상자를 들었으면 두 손으로 든 채). 거리는 만드는 순간의 위치로 잰다 — 단계마다 그 자리에서 만든다.
    private func walk(to x: CGFloat) -> SKAction {
        let right = x >= archivist.position.x
        return .sequence([
            .run { [weak self] in
                guard let self else { return }
                self.archivist.xScale = right ? 1 : -1
                self.loop((0..<4).map { self.held == nil ? WorkerPose.walk($0) : .push($0) })
                self.held?.position = CGPoint(x: 6, y: 9)
            },
            .moveTo(x: x, duration: TimeInterval(max(0.05, abs(x - archivist.position.x) / 40))),
            .run { [weak self] in self?.holdPose() }
        ])
    }

    private func texture(_ pose: WorkerPose) -> SKTexture { TextureCache.shared.texture("archivist-\(pose)") { CharacterArt.archivistSprite(pose) } }

    private func loop(_ poses: [WorkerPose], fps: Double = 8) {
        let textures = poses.map(texture)
        archivist.removeAction(forKey: "pose")
        archivist.texture = textures.first
        archivist.size = textures.first?.size() ?? .zero
        archivist.run(.repeatForever(.animate(with: textures, timePerFrame: 1 / fps, resize: true, restore: false)), withKey: "pose")
    }

    /// 서 있기(상자를 들었으면 두 손으로 든 자세).
    private func holdPose() {
        archivist.removeAction(forKey: "pose")
        let texture = texture(held == nil ? .stand(blink: false) : .push(1))
        archivist.texture = texture
        archivist.size = texture.size()
        held?.position = CGPoint(x: 6, y: 9)
    }

    private func stand(right: Bool) {
        archivist.xScale = right ? 1 : -1
        archivist.removeAction(forKey: "pose")
        let frames = [texture(.stand(blink: false)), texture(.stand(blink: true))]
        archivist.texture = frames[0]
        archivist.size = frames[0].size()
        archivist.run(.repeatForever(.sequence([.wait(forDuration: 2.6), .animate(with: [frames[1], frames[0]], timePerFrame: 0.15, resize: true, restore: false)])), withKey: "pose")
    }

    // MARK: 검수용

    var boxCount: Int { boxes.values.reduce(0) { $0 + $1.count } }
    func boxCount(_ shelf: Shelf) -> Int { boxes[shelf]?.count ?? 0 }
    var pending: Int { tasks.count + (current == nil ? 0 : 1) }
    /// 기록관이 서 있는 곳이 바닥이거나 사다리 위인가(뜬 것 없음).
    var archivistGrounded: Bool {
        let p = archivist.position
        if abs(p.y - floorLine) < 0.5 { return true }
        return abs(p.x - ladder.position.x) < 1 && p.y >= floorLine && p.y <= ladderTop - 10
    }
    /// 상자가 제자리(칸 · 다락)에 있는가 — 손에 든 상자는 빼고.
    var boxesSeated: Bool {
        Shelf.allCases.allSatisfy { shelf in
            (boxes[shelf] ?? []).enumerated().allSatisfy { index, box in box.hasActions() || box.position == VaultLayout.slot(shelf, index, ceiling: ceiling).point }
        }
    }
}

// MARK: - 장면: 금고 방(요약 · 명판 · 칸 이름표 · 누르기)

extension OfficeScene {
    /// 복구 금고 요약(메인이 RecoveryVault에서 채운다). 세션 = 복귀 가능한 정리 세션 · 파일 = 휴지통으로 보낸 파일 · git = 지운 워크트리 · 브랜치 ·
    /// 프로세스 = 정리한 프로세스 · 만료 = 보관 기간이 지나 되돌릴 수 없는 기록 · 바이트 = 금고가 들고 있는 크기.
    struct VaultSummary: Equatable {
        var sessions: Int = 0
        var files: Int = 0
        var git: Int = 0
        var processes: Int = 0
        var expired: Int = 0
        var bytes: UInt64 = 0

        /// 명판의 'N건' = 금고 기록 전부(만료 포함).
        var total: Int { sessions + files + git + processes + expired }
    }

    /// 금고 방을 맞춘다: 서가 상자(칸마다 한 건, 칸이 차면 그만) · 명판 '금고 · N건 · X GB' · 칸 이름표. 수가 늘면 기록관이 꽂고, 줄면 꺼내 나간다.
    func setVault(_ summary: VaultSummary) {
        vaultSummary = summary
        vault.setCounts([.sessions: summary.sessions, .files: summary.files, .git: summary.git, .processes: summary.processes, .expired: summary.expired])
        let plaque = vaultPlaque ?? {
            let made = TextBadge("", style: .plate)
            overlay.addChild(made)
            vaultPlaque = made
            return made
        }()
        plaque.set("금고 · \(summary.total)건 · \(Fmt.gb(summary.bytes))")
        let names: [(VaultLayout.Shelf, String, Int)] = [(.sessions, "세션", summary.sessions), (.files, "파일", summary.files), (.git, "git", summary.git),
                                                          (.processes, "프로세스", summary.processes), (.expired, "만료", summary.expired)]
        for (shelf, name, count) in names {
            let badge = vaultShelfLabels[shelf] ?? {
                let made = TextBadge("", style: .sign, color: NSColor(srgbRed: 1, green: 0.95, blue: 0.82, alpha: 1))
                overlay.addChild(made)
                vaultShelfLabels[shelf] = made
                return made
            }()
            badge.set("\(name) \(count)")
        }
        repositionVaultLabels()
        publishFloors()
    }

    func placeVault() {
        let lobby = layout.floors[layout.lobbyIndex]
        vault.place(floorLine: line(layout.lobbyIndex), ceiling: CGFloat(lobby.y + lobby.height))
        repositionVaultLabels()
    }

    /// 금고 방 사각형(누르면 복구함).
    var vaultRect: CGRect {
        let floor = layout.floors[layout.lobbyIndex]
        return CGRect(x: CGFloat(BuildingLayout.wingX0) - 2, y: CGFloat(floor.y) - 2, width: CGFloat(BuildingLayout.wingX1 - BuildingLayout.wingX0) + 6, height: CGFloat(floor.height) + 8)
    }

    func repositionVaultLabels() {
        let zoomed = lodZoomed ?? false
        let ceiling = vault.ceiling
        let wing = CGFloat(BuildingLayout.wingX0)
        if let plaque = vaultPlaque {
            plaque.isHidden = !zoomed
            plaque.position = CGPoint(x: (wing + 77) * pointsPerPixel, y: (ceiling - 26) * pointsPerPixel)
        }
        // 칸 이름표: 그 칸 아래 판 위(세션 · git = 위 두 단 아래 판, 파일 · 프로세스 = 아래 두 단 아래 판, 만료 = 다락 왼쪽).
        let places: [VaultLayout.Shelf: CGPoint] = [
            .sessions: CGPoint(x: wing + 29, y: ceiling - 42), .files: CGPoint(x: wing + 29, y: ceiling - 64),
            .git: CGPoint(x: wing + 126, y: ceiling - 42), .processes: CGPoint(x: wing + 126, y: ceiling - 64),
            .expired: CGPoint(x: wing + 46, y: ceiling - 15),
        ]
        for (shelf, badge) in vaultShelfLabels {
            badge.isHidden = !zoomed || pointsPerPixel < 3
            if let point = places[shelf] { badge.position = CGPoint(x: point.x * pointsPerPixel, y: point.y * pointsPerPixel) }
        }
    }

    /// 금고 방을 눌렀을 때: 복구함을 연다(메인 연결) · 멀리서 눌렀으면 그 방으로 다가간다.
    func selectVault() {
        onSelectVault?()
        vaultLog.append("누름")
        if !isZoomedIn { zoomCamera(to: vaultRect.insetBy(dx: -30, dy: 0)) }
    }

    // MARK: 검수용
    var vaultNode: VaultNode { vault }
    var vaultPlaqueText: String? { vaultPlaque?.currentText }
    func vaultShelfText(_ shelf: VaultLayout.Shelf) -> String? { vaultShelfLabels[shelf]?.currentText }
}
