import AppKit
import ReMONCore
import SpriteKit

/// 디스크 저장고 진열 한 묶음(메인이 디스크 지도의 꼬리표 합계로 채운다): 꼬리표 · 실제 할당량 · 그중 지금 치울 수 있는 양.
/// 선반 상자는 이 비율로 꼬리표별 색이 칠해지고, 치울 수 있는 몫만큼은 옅은 점선 테두리가 붙는다(DiskStock.swift).
struct DiskStockGroup: Equatable {
    var tag: DiskTag
    var bytes: UInt64
    var reclaimable: UInt64
}

/// 재고 조사 탁자에 펼칠 항목 하나(디스크 지도의 한 칸): 경로 · 이름 · 크기 · 꼬리표 · 대표가 '폐기'로 고른 것인지.
struct DiskStockItem: Equatable {
    var path: String
    var name: String
    var bytes: UInt64
    var tag: DiskTag
    var marked: Bool
}

/// 'AI 사무실' 장면. 가상 픽셀(640폭) 건물을 정수 배율(기기 픽셀 기준)로 키워 nearest로 그린다.
/// 상태 반영 순서: 사건(출근·퇴근·쫓겨남·트레이너·상자) → 스냅샷 조정(자리 이동·자세).
final class OfficeScene: SKScene {
    var onSelect: ((ProcessKey?) -> Void)?
    /// 성능 실측용: 출근 연출이 시작될 때.
    var onArrival: ((AgentSession) -> Void)?
    var onSelectApp: ((String?) -> Void)?
    private var fpsTimes: [TimeInterval] = []
    private var measuringFPS = false
    private(set) var pointsPerPixel: CGFloat = 1.5

    /// 건물 전체(카메라가 움직이는 층). 정신교육실 인물(RetiredRoom.swift)도 여기에 붙인다.
    let world = SKNode()
    /// 글자 층(배율을 적용하지 않는다). 방별 확장(도구실 · 금고 · 워크플로실 · 축하)도 여기에 이름표를 올린다.
    let overlay = SKNode()
    private let skyNode = SKSpriteNode()
    private let groundNode = SKSpriteNode()
    private var floorNodes: [SKSpriteNode] = []
    private let libraryNode = SKSpriteNode()
    private let planner = LayoutPlanner()
    private(set) var layout = BuildingLayout.make(sessions: [])
    var workers: [ProcessKey: WorkerNode] = [:]
    private var labels: [ProcessKey: TextBadge] = [:]
    var bubbles: [ProcessKey: TextBadge] = [:]
    private var monitors: [ProcessKey: SKSpriteNode] = [:]
    private var memoryBars: [ProcessKey: SKSpriteNode] = [:]
    private var staticLabels: [(badge: TextBadge, vx: CGFloat, vy: CGFloat)] = []
    let doorNode = SKSpriteNode()
    private var elevatorDoors: [Int: SKSpriteNode] = [:]
    private let alarmNode = SKSpriteNode()
    /// 스왑 창고 상자 · 디스크 저장고 선반 · 짐꾼.
    private let warehouse = WarehouseNode()
    /// 디스크 정비 · 재고 조사(Inventory.swift): 압축기 · 분류 탁자 · 인력 · 손수레 · 기술자. 진열 묶음(setDiskStock) · 글자(꼬리표 · 이름표 · 스티커).
    let inventory = InventoryNode()
    var diskStock: [DiskStockGroup] = []
    let diskLabels = DiskLabelBoard()
    /// 워크플로실(층 번호 → 방): 맨 위 팀 층(상황실)을 뺀 팀 층마다 별관에 하나. 보드 글자 세 줄과 '대기' 표지는 글자 층에.
    private var workflowRooms: [Int: WorkflowRoomNode] = [:]
    private var workflowBoards: [Int: [TextBadge]] = [:]
    private var workflowIdleSigns: [Int: TextBadge] = [:]
    private var workflowFloors: [Int] { layout.teamFloorIndexes.filter { $0 != layout.topTeamIndex } }
    let guardNode = SKSpriteNode()
    private let trainerNode = SKSpriteNode()
    var guardBusy = false
    private var trainerBusy = false
    private var spareNodes: [SKSpriteNode] = []
    private let machineRoom = MachineRoomNode()
    /// 도구실(ToolRoom.swift): 설치됐거나 배송 중인 기계 · 이름표 · 자리(0~9) · 내가는 중인 앱과 비우는 자리 · 처음 채웠나 ·
    /// 지난 스냅샷의 앱(새로 켠 앱 가리기) · 크기 상태 · '+N' 표지 · 반입구(배송·설치 기사).
    var tools: [String: ToolMachineNode] = [:]
    var toolLabels: [String: TextBadge] = [:]
    var toolSlotOf: [String: Int] = [:]
    var toolsLeaving: [String: Int] = [:]
    var toolsInitialized = false
    var toolSeen = Set<String>()
    var toolGrowth: [String: ToolGrowth] = [:]
    var toolOverflowBadge: TextBadge?
    let toolDock = ToolDock()
    /// 검수용: 도구실 사건(배송 · 회수 · 폭주 · 커짐 · 교체).
    var toolLog: [String] = []
    /// 떠오르며 사라지는 작은 표지('커짐' 등): 배지 · 가상 좌표 · 남은 시간.
    private var floatTags: [(badge: TextBadge, vx: CGFloat, vy: CGFloat, age: TimeInterval)] = []
    /// 기록 보관소 = 복구 금고의 방(Vault.swift): 서가 상자 · 사다리 · 기록관, 명판 · 칸 이름표, 마지막 요약.
    let vault = VaultNode()
    var vaultSummary = VaultSummary()
    var vaultPlaque: TextBadge?
    var vaultShelfLabels: [VaultLayout.Shelf: TextBadge] = [:]
    /// 금고 방을 누르면(메인이 복구함 페이지로 연결한다).
    var onSelectVault: (() -> Void)?
    /// 대사 맥락(앱이 채움): git 사건 · 금고 · 감사 · 정신교육실 인원. 세션·시스템은 스냅샷에서.
    private var speech = SpeechContext()

    func setSpeech(git: [GitEvent], vault: VaultCounts, audit: (summary: String, time: Date)?, retired: Int) {
        speech.recentGit = git
        speech.vault = vault
        speech.auditSummary = audit?.summary
        speech.auditTime = audit?.time
        speech.retired = retired
    }

    /// 지금 스냅샷을 얹은 대사 맥락.
    private var speechNow: SpeechContext {
        var context = speech
        context.sessions = snapshot?.sessions ?? []
        context.system = snapshot?.system ?? SystemSnapshot()
        context.now = clock()
        return context
    }
    /// 검수용: 금고 방 눌림 기록.
    var vaultLog: [String] = []
    /// 워크플로실 로봇을 누르면(주인 세션 · 하위 에이전트) — 메인이 하위 에이전트 카드(SubagentCard)를 띄운다.
    var onSelectSubagent: ((ProcessKey, SubagentInfo) -> Void)?
    /// 지난 갱신에 세운 워크플로 로봇(잔재 판정용) · 로봇 주인 세션(잔재가 된 뒤에도 카드에 넘기려고 마지막 모습을 남긴다).
    private var workflowSeen: [String: (robot: WorkflowRobot, floor: Int)] = [:]
    private var workflowOwners: [ProcessKey: AgentSession] = [:]
    /// 검수용: 누른 로봇(하위 에이전트 id).
    var subagentClicks: [String] = []
    /// 서류 더미(Celebrate.swift): 그려 둔 서류 · 처음 받았나. 축하 기록 · 물청소(양동이 · 젖은 자국 수 · 반짝).
    var paperNodes: [String: [SKSpriteNode]] = [:]
    var papersInitialized = false
    /// 방 안 짐 층(Clutter.swift): 워크트리 · 브랜치 · 넘친 서류의 무게만큼 책상 위 서류 → 바닥 상자 → 벽 2단 → 천장 탑.
    let clutter = ClutterLayer()
    var celebrationLog: [String] = []
    var mopBucket: SKSpriteNode?
    var mopStrokes = 0
    var mopLog: [String] = []
    /// 옥상 웰니스 풀(Rooftop.swift): 조명 · 김 · DJ 파티 무대(옥상 바닥선에 붙는 노드) · 디제이 · 파티 진행 상태.
    let poolDeck = PoolDeck()
    let djNode = SKSpriteNode()
    var party = PartyState()
    private let hallDoorNode = SKSpriteNode()
    /// 쉼: 놀이 자리와 다음 자리 바꿀 시각. 오래 쉼·고아: 강당 좌석 번호.
    private var playSeats: [ProcessKey: (spot: BuildingLayout.Spot, until: TimeInterval)] = [:]
    private var hallSeatOf: [ProcessKey: Int] = [:]
    private var lastAmbientTick: TimeInterval = 0
    private var lastFloorSummary: [FloorSummary] = []
    private var lastViewportFloor = -1
    var onFloorsChanged: (([FloorSummary]) -> Void)?
    var onViewportFloor: ((Int) -> Void)?
    private let selectionMarker = SKSpriteNode()
    private let lightsLayer = SKNode()
    private let shimmerNode = SKSpriteNode()
    private var whiteboardLines: [TextBadge] = []
    var sessions: [ProcessKey: AgentSession] = [:]
    var snapshot: OfficeSnapshot?
    private var selected: ProcessKey?
    private var skyHour = -1
    private var skySeason: Season?
    private var lightsHour = -1
    private var lightsSeason: Season?
    private var built = false
    private var diskLow = false
    /// 장면이 실제로 돈 시간(창이 닫혀 멈춘 동안은 흐르지 않는다). 안전망의 시한은 이 시계로 잰다.
    var activeTime: TimeInterval = 0
    /// 검수용: 안전망이 바로잡은 기록(사유). 원인을 고쳤다면 평소에는 비어 있어야 한다.
    private(set) var safetyFixes: [String] = []

    // MARK: 카메라 상태(전체 ↔ 방 줌, 핀치·스크롤, 끌어서 이동, 사건 따라가기)
    var onFocusChanged: ((OfficeFocus) -> Void)?
    var onCaption: ((String?) -> Void)?
    var onSelectMachine: ((MachineKind) -> Void)?
    var autoZoomEnabled: () -> Bool = { true }
    private(set) var focusTarget: OfficeFocus = .all
    /// 점/가상 픽셀(현재 배율)과 화면 가운데에 오는 가상 좌표.
    private var camScale: CGFloat = 1
    private var camCenter = CGPoint(x: 320, y: 300)
    private var camAnimation: CameraAnimation?
    private var followNode: SKNode?
    /// 사용자가 직접 확대·이동한 상태(방 탭 초점과 다를 수 있음).
    private var userCamera = false
    private var lastUserInput = Date.distantPast
    private var lastFrameTime: TimeInterval = 0
    private var pendingSnap: TimeInterval?
    private var dragStart: CGPoint?
    private var dragged = false
    private var hoverKey: String?
    private let dimNode = DimFrame()
    private let focusDimNode = DimFrame()
    private let hoverOutline = SKShapeNode()
    private let hoverChip = TextBadge("", style: .plate, layer: .chip)
    private var titleBubbles: [ProcessKey: TextBadge] = [:]
    var lodZoomed: Bool?
    private var lodFocusKey = ""
    private var shotQueue: [Shot] = []
    private var activeShot: (shot: Shot, endsAt: TimeInterval)?
    private var savedCamera: (scale: CGFloat, center: CGPoint, focus: OfficeFocus, user: Bool)?
    private var lastAutoShot = Date.distantPast

    struct CameraAnimation {
        var fromScale: CGFloat, toScale: CGFloat
        var fromCenter: CGPoint, toCenter: CGPoint
        var start: TimeInterval, duration: TimeInterval
    }

    /// 자동 줌 한 장면: 자리(사각형)로 다가가거나, 움직이는 인물을 따라간다(층을 옮겨도 카메라가 같이 간다).
    struct Shot {
        enum Target { case rect(CGRect), follow(SKNode, zoom: CGFloat) }
        var target: Target
        var caption: String
        var duration: TimeInterval
        /// 0~1: 잦은 사건(출근·스왑) — 20초에 한 번만. 2: 경보·트레이너·청소. 3: 퇴출·감사(항상).
        var priority: Int
    }

    static func look(for session: AgentSession) -> WorkerLook {
        .seeded(Int(session.rootPID) &+ Int(session.id.start % 9973), hoodie: TeamColor.hoodie(session.kind))
    }

    // MARK: 준비

    override func didMove(to view: SKView) {
        scaleMode = .resizeFill
        anchorPoint = .zero
        backgroundColor = Pal.skyBottom.nsColor
        guard !built else { relayout(); return }
        built = true
        focusTarget = .floor(BuildingLayout.firstTeamFloor)
        onFocusChanged?(focusTarget)
        addChild(world)
        addChild(overlay)
        overlay.zPosition = 100
        skyNode.anchorPoint = .zero; skyNode.zPosition = -20; world.addChild(skyNode)
        groundNode.anchorPoint = .zero; groundNode.zPosition = -19; world.addChild(groundNode)
        libraryNode.anchorPoint = .zero; libraryNode.zPosition = 1; world.addChild(libraryNode)
        for node in [doorNode, alarmNode] { node.anchorPoint = .zero; node.zPosition = 3; world.addChild(node) }
        world.addChild(toolDock)
        world.addChild(vault)
        world.addChild(poolDeck)
        vault.onSay = { [weak self] node, text in self?.staffSay(node, text, style: .bubble, seconds: 2.2) }
        vault.onTaskStart = { [weak self] task in
            guard let self else { return }
            let shelf = ["세션", "파일", "git", "프로세스", "만료"][task.shelf.rawValue]
            let what: String
            switch task.kind {
            case .file: what = "\(shelf) 기록 보관 · 기록관이 서가에 꽂습니다"
            case .restore: what = "\(shelf) 복구 · 기록관이 꺼내 내보냅니다"
            case .expire: what = "\(shelf) 보관 기간 끝 · 다락으로"
            }
            self.requestEventShot(Shot(target: .follow(self.vault.archivist, zoom: 2.6), caption: "금고 · " + what, duration: 7, priority: 1))
        }
        toolDock.onSay = { [weak self] node, text, style in self?.staffSay(node, text, style: style, seconds: 2.2) }
        toolDock.onJobStart = { [weak self] job in
            guard let self else { return }
            let what = job.kind == .deliver ? "새 앱 설치 · \(job.name) · 배송 기사가 반입구로" : "앱 종료 · \(job.name) · 설치 기사가 반입구로 내갑니다"
            self.requestEventShot(Shot(target: .follow(self.toolDock.courier, zoom: 2.4), caption: "도구실 · " + what, duration: 9, priority: 1))
        }
        guardNode.anchorPoint = CGPoint(x: 0.5, y: 0); guardNode.zPosition = 7; world.addChild(guardNode)
        trainerNode.anchorPoint = CGPoint(x: 0.5, y: 0); trainerNode.zPosition = 7; world.addChild(trainerNode)
        machineRoom.zPosition = 3; world.addChild(machineRoom)
        warehouse.zPosition = 3; world.addChild(warehouse)
        warehouse.openElevator = { [weak self] in self?.openElevator(0) }
        warehouse.onJob = { [weak self] stock, change in self?.porterJob(stock, change: change) }
        warehouse.onUnload = { [weak self] event in self?.porterUnloadEvent(event) }
        world.addChild(inventory)
        inventory.shelves = warehouse.diskShelves
        inventory.lineOf = { [weak self] index in self?.line(index) ?? 0 }
        inventory.openElevator = { [weak self] floor in self?.openElevator(floor) }
        inventory.onSay = { [weak self] node, text, style, seconds in self?.staffSay(node, text, style: style, seconds: seconds) }
        inventory.setHold = { [weak self] on in self?.warehouse.holdDisk = on }
        inventory.remeasure = { [weak self] in self?.remeasureDisk() }
        inventory.onArchive = { [weak self] count in self?.vault.receiveDelivery(count: count) }
        inventory.onChange = { [weak self] in self?.refreshDiskLabels() }
        warehouse.diskShelves.onLayout = { [weak self] in
            self?.inventory.stockChanged()
            self?.refreshDiskLabels()
        }
        hallDoorNode.anchorPoint = .zero; hallDoorNode.zPosition = 3; world.addChild(hallDoorNode)
        selectionMarker.texture = TextureCache.shared.texture("marker") {
            var c = PixelCanvas(7, 5)
            c.hline(0, 0, 7, Pal.outline); c.rect(1, 1, 5, 1, PixelColor(0xFFD34E)); c.rect(2, 2, 3, 1, PixelColor(0xFFD34E)); c.dot(3, 3, PixelColor(0xFFD34E)); c.dot(3, 4, Pal.outline)
            return c
        }
        selectionMarker.size = CGSize(width: 7, height: 5)
        selectionMarker.zPosition = 60
        selectionMarker.isHidden = true
        selectionMarker.run(.repeatForever(.sequence([.moveBy(x: 0, y: 3, duration: 0.35), .moveBy(x: 0, y: -3, duration: 0.35)])))
        world.addChild(selectionMarker)
        lightsLayer.zPosition = 2
        world.addChild(lightsLayer)
        dimNode.zPosition = 70
        world.addChild(dimNode)
        focusDimNode.zPosition = 69
        world.addChild(focusDimNode)
        hoverOutline.zPosition = 71
        hoverOutline.isHidden = true
        world.addChild(hoverOutline)
        hoverChip.isHidden = true
        overlay.addChild(hoverChip)
        shimmerNode.anchorPoint = .zero
        shimmerNode.zPosition = 2
        world.addChild(shimmerNode)
        rebuildBuilding()
        startAmbient()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        relayout()
    }

    private func relayout() {
        guard built, size.width > 10 else { return }
        rebuildBackdrop()
        if camAnimation == nil && followNode == nil && !userCamera && activeShot == nil {
            let frame = cameraFrame(for: focusTarget)
            camScale = frame.scale
            camCenter = frame.center
        } else {
            camScale = min(maxScale, max(fitScale * 0.85, camScale))
            camCenter = clampCenter(camCenter, scale: camScale)
        }
        applyCamera()
    }

    /// 하늘·땅은 넉넉한 고정 텍스처로 한 번만 만든다(카메라가 움직일 때마다 다시 그리지 않게).
    private func rebuildBackdrop() {
        let hour = SceneClock.hour
        let width = 2400, height = 1000
        let left: CGFloat = -880
        let base = CGFloat(layout.height - BuildingLayout.roofHeight)
        skyHour = hour
        skySeason = Season.current
        // 시간대·계절 단위로만 캐시한다(예전엔 매시간 2400×1000 텍스처가 하나씩 쌓였다 — 창이 열려 있는 동안 시간당 약 9.6MB).
        skyNode.texture = TextureCache.shared.texture("sky-\(Daypart.of(hour: hour).rawValue)-\(Season.current.rawValue)-\(width)x\(height)") { FloorPainter.sky(width: width, height: height, hour: hour) }
        skyNode.size = CGSize(width: width, height: height)
        skyNode.position = CGPoint(x: left, y: base)
        backgroundColor = (hour >= 19 || hour < 5) ? PixelColor(0x2D3E6E).nsColor : Pal.skyBottom.nsColor
        // 땅도 계절 그림이라 계절 단위로 캐시한다(예전 열쇠엔 계절이 없어, 창을 연 채 계절이 바뀌면 지난 계절 땅이 남았다).
        groundNode.texture = TextureCache.shared.texture("ground-\(Season.current.rawValue)-\(width)x400") { FloorPainter.ground(width: width, height: 400) }
        groundNode.size = CGSize(width: CGFloat(width), height: 400)
        groundNode.position = CGPoint(x: left, y: CGFloat(BuildingLayout.basementHeight + BuildingLayout.slab) - 400)
    }

    private func rebuildSky() { rebuildBackdrop() }

    // MARK: 카메라

    private var backing: CGFloat { view?.window?.backingScaleFactor ?? 2 }
    private var maxScale: CGFloat { 7 }
    private var fitScale: CGFloat { cameraFrame(for: .all).scale }
    var isZoomedIn: Bool { camScale >= fitScale * 1.5 }
    /// 건물 전체(가상 픽셀). 전체 보기는 이 사각형을 화면에 맞춘다.
    private var buildingBounds: CGRect { CGRect(x: -10, y: -8, width: CGFloat(BuildingLayout.width) + 20, height: CGFloat(layout.height) + 30) }

    private func snapScale(_ scale: CGFloat) -> CGFloat { max(1 / backing, (scale * backing).rounded() / backing) }

    private func frame(for rect: CGRect, fill: CGFloat) -> (scale: CGFloat, center: CGPoint) {
        let raw = min(size.width / max(1, rect.width), size.height / max(1, rect.height)) * fill
        let scale = fittedScale(raw)
        return (scale, clampCenter(CGPoint(x: rect.midX, y: rect.midY), scale: scale))
    }

    /// 화면에 맞춘 배율 고르기. 기기 픽셀 4배 이상이면 정수 배로 내려 픽셀을 또렷하게, 그보다 작으면 1/8 단위로만 내린다.
    /// 10-25: 화면 폭이 건물 폭보다 조금 좁으면(배율 0.99) 정수 배로 내리며 0.5가 되어, 전체 보기 건물이 절반 크기로 작아지고
    /// 둘레가 하늘·땅으로 남았다(대표 지적 '건물이 너무 작고 주변 배경이 많아').
    private func fittedScale(_ raw: CGFloat) -> CGFloat {
        let device = raw * backing
        let snapped = device >= 4 ? floor(device) : floor(device * 8) / 8
        return max(1 / backing, min(maxScale, snapped / backing))
    }

    private func cameraFrame(for focus: OfficeFocus) -> (scale: CGFloat, center: CGPoint) {
        if case .floor(let index) = focus, layout.floors.indices.contains(index) {
            // 한 층 크게: 층 높이를 화면에 크게 채우되, 층 가로의 40%는 보이게(나머지는 끌어서 본다).
            // 한 층 보기: 그 층 팀 전체(방들이 차지한 범위)가 다 보이는 가장 큰 배율. 층 높이보다 크게 키우지는 않는다.
            let floor = layout.floors[index]
            let rooms = layout.rooms.filter { $0.floor == index }
            let span: (CGFloat, CGFloat) = rooms.isEmpty ? (CGFloat(BuildingLayout.mainX0), CGFloat(BuildingLayout.wingX1))
                : (CGFloat(rooms.map(\.x0).min()!) - 14, CGFloat(rooms.map(\.x1).max()!) + 14)
            let heightFit = size.height / (CGFloat(floor.height) + 26) * 0.9
            let widthFit = size.width / max(120, span.1 - span.0)
            let scale = fittedScale(min(heightFit, widthFit))
            let centerX = (span.0 + span.1) / 2
            let centerY = CGFloat(floor.y) + CGFloat(floor.height) / 2 + (index == layout.roofIndex ? 10 : 0)
            return (scale, clampCenter(CGPoint(x: centerX, y: centerY), scale: scale))
        }
        return frame(for: focusRect(focus), fill: focus == .all ? 1 : 0.92)
    }

    func focusRect(_ focus: OfficeFocus) -> CGRect {
        switch focus {
        case .all:
            return buildingBounds
        case .room(let name):
            let rooms = layout.rooms.filter { $0.name == name || $0.name.hasPrefix(name + " ") }
            guard !rooms.isEmpty else { return buildingBounds }
            // 작은 방(책상 1~2개)이 화면을 가득 채우지 않게: 최소 책상 6개 폭은 보이게 넓힌다(옆방이 같이 보인다).
            var rect = rooms.map(roomRect).reduce(CGRect.null) { $0.union($1) }
            let minWidth = CGFloat(BuildingLayout.deskPitch * 6 + BuildingLayout.roomPadding * 2)
            if rect.width < minWidth { rect = rect.insetBy(dx: -(minWidth - rect.width) / 2, dy: 0) }
            return rect
        case .region(let region):
            return regionRect(region)
        case .floor(let index):
            // 한 층 보기: 본관(36~468)만 맞춘다 — 정수 배율에서 한 단계 더 크게 보이고, 별관은 옆으로 끌어서 본다. 옥상은 수영장 쪽.
            guard layout.floors.indices.contains(index) else { return buildingBounds }
            let floor = layout.floors[index]
            if index == layout.roofIndex { return CGRect(x: 200, y: CGFloat(floor.y) - 2, width: 436, height: CGFloat(floor.height) + 26) }
            return CGRect(x: CGFloat(BuildingLayout.mainX0) - 6, y: CGFloat(floor.y) - 2, width: CGFloat(BuildingLayout.mainX1 - BuildingLayout.mainX0) + 12, height: CGFloat(floor.height) + 10)
        }
    }

    func roomRect(_ room: BuildingLayout.Room) -> CGRect {
        let floor = layout.floors[room.floor]
        return CGRect(x: CGFloat(room.x0) - 6, y: CGFloat(floor.y) - 2, width: CGFloat(room.x1 - room.x0) + 12, height: CGFloat(floor.height) + 10)
    }

    func regionRect(_ region: OfficeRegion) -> CGRect {
        switch region {
        case .lobby:
            // 로비(36~226) | 도구실(228~468) | 기록 보관소 · 금고(별관 472~632) — 세 구역이 겹치지 않게 나눈다.
            let floor = layout.floors[1]
            return CGRect(x: 30, y: CGFloat(floor.y) - 2, width: CGFloat(ToolRoom.x0) - 32, height: CGFloat(floor.height) + 8)
        case .toolRoom:
            let floor = layout.floors[1]
            return CGRect(x: CGFloat(ToolRoom.x0) - 2, y: CGFloat(floor.y) - 2, width: CGFloat(BuildingLayout.wingX0 - ToolRoom.x0), height: CGFloat(floor.height) + 8)
        case .machineRoom:
            let floor = layout.floors[0]
            return CGRect(x: 30, y: CGFloat(floor.y) - 4, width: 444, height: CGFloat(floor.height) + 10)
        case .rooftop:
            let floor = layout.floors[layout.roofIndex]
            return CGRect(x: 30, y: CGFloat(floor.y) - 2, width: 606, height: CGFloat(floor.height) + 26)
        case .hall:
            let floor = layout.floors[layout.hallIndex]
            return CGRect(x: 30, y: CGFloat(floor.y) - 2, width: 606, height: CGFloat(floor.height) + 10)
        case .situationRoom:
            let floor = layout.floors[layout.topTeamIndex]
            return CGRect(x: CGFloat(BuildingLayout.wingX0) - 8, y: CGFloat(floor.y) - 2, width: CGFloat(BuildingLayout.wingX1 - BuildingLayout.wingX0) + 14, height: CGFloat(floor.height) + 10)
        }
    }

    private func clampCenter(_ center: CGPoint, scale: CGFloat) -> CGPoint {
        let bounds = buildingBounds.insetBy(dx: -40, dy: -30)
        let halfWidth = size.width / 2 / scale, halfHeight = size.height / 2 / scale
        let x = bounds.width <= halfWidth * 2 ? bounds.midX : min(max(center.x, bounds.minX + halfWidth), bounds.maxX - halfWidth)
        let y = bounds.height <= halfHeight * 2 ? bounds.midY : min(max(center.y, bounds.minY + halfHeight), bounds.maxY - halfHeight)
        return CGPoint(x: x, y: y)
    }

    private func applyCamera() {
        pointsPerPixel = camScale
        let snap: (CGFloat) -> CGFloat = { [backing] in ($0 * backing).rounded() / backing }
        let origin = CGPoint(x: snap(size.width / 2 - camCenter.x * camScale), y: snap(size.height / 2 - camCenter.y * camScale))
        world.position = origin
        world.setScale(camScale)
        overlay.position = origin
        hoverOutline.lineWidth = 2 / camScale
        repositionOverlay()
        updateLOD()
        if abs(camScale - lastBadgeScale) > 0.05 { lastBadgeScale = camScale; refreshMachineBadges() }
        publishViewportFloor()
        updateFocusDim()
    }

    private var lastBadgeScale: CGFloat = 0

    /// 한 층(방) 보기: 초점 밖을 어둡게 해 '한 층 단위'로 읽히게 한다. 사용자가 직접 움직이거나 자동 줌 중에는 끈다.
    private func updateFocusDim() {
        // 한 층·한 방 보기: 초점 밖(다른 층)을 어둡게 해 '한 층 단위'로 읽히게 한다. 직접 움직이거나 자동 줌 중에는 끈다.
        guard let hole = focusHole else { focusDimNode.isHidden = true; return }
        let outer = CGRect(x: -1200, y: -600, width: CGFloat(BuildingLayout.width) + 2400, height: CGFloat(layout.height) + 1600)
        focusDimNode.show(hole: hole, within: outer, alpha: 0.68)
    }

    /// 지금 밝게 남긴 초점 사각형(가상 좌표). 초점이 없거나 직접 움직이는 중이면 nil.
    private var focusHole: CGRect? {
        guard focusTarget != .all, !userCamera, activeShot == nil, camAnimation == nil else { return nil }
        return (focusTarget.isFloor ? floorBand(focusTarget) : focusRect(focusTarget)).insetBy(dx: -2, dy: -2)
    }

    /// 층 보기의 밝은 띠: 그 층 전체 폭.
    private func floorBand(_ focus: OfficeFocus) -> CGRect {
        guard case .floor(let index) = focus, layout.floors.indices.contains(index) else { return buildingBounds }
        let floor = layout.floors[index]
        let extra: CGFloat = index == layout.roofIndex ? 24 : 0
        return CGRect(x: 0, y: CGFloat(floor.y), width: CGFloat(BuildingLayout.width), height: CGFloat(floor.height) + extra)
    }

    private func animateCamera(to scale: CGFloat, center: CGPoint, duration: TimeInterval) {
        guard duration > 0, lastFrameTime > 0 else {
            camAnimation = nil
            camScale = scale
            camCenter = center
            applyCamera()
            return
        }
        camAnimation = CameraAnimation(fromScale: camScale, toScale: scale, fromCenter: camCenter, toCenter: center, start: lastFrameTime, duration: duration)
    }

    /// 방 탭·목록·장면 클릭이 부른다. 사용자 조작이므로 진행 중인 자동 줌은 끝낸다.
    func focus(_ focus: OfficeFocus, animated: Bool) {
        cancelShots()
        followNode = nil
        userCamera = false
        focusTarget = focus
        onFocusChanged?(focus)
        setHover(nil)
        let frame = cameraFrame(for: focus)
        animateCamera(to: frame.scale, center: frame.center, duration: animated ? 0.55 : 0)
    }

    /// 사람을 고르면: 책상에 있으면 그 방 전체로, 쉬는 중이면 그 사람 주변으로 다가간다.
    func focusWorker(_ key: ProcessKey) {
        guard let worker = workers[key] else { return }
        if case .desk = worker.place, let project = sessions[key]?.project {
            focus(.room(project), animated: true)
            return
        }
        cancelShots()
        userCamera = true
        let rect = CGRect(x: worker.position.x - 90, y: worker.position.y - 26, width: 180, height: 96)
        let target = frame(for: rect, fill: 0.9)
        animateCamera(to: target.scale, center: target.center, duration: 0.55)
    }

    /// 방이 아닌 곳(금고 방 · 워크플로실 로봇 등)을 눌렀을 때: 그 사각형으로 부드럽게 다가간다(사용자 조작 — 자동 줌은 끝낸다).
    func zoomCamera(to rect: CGRect) {
        cancelShots()
        followNode = nil
        userCamera = true
        setHover(nil)
        let target = frame(for: rect, fill: 0.92)
        animateCamera(to: target.scale, center: target.center, duration: 0.55)
    }

    /// 검수용(장면 시험): 가상 좌표 사각형이 화면에 차게 카메라를 바로 옮긴다.
    func frameCamera(on rect: CGRect) {
        cancelShots()
        followNode = nil
        userCamera = true
        let target = frame(for: rect, fill: 0.95)
        animateCamera(to: target.scale, center: target.center, duration: 0)
    }

    /// 머리글의 −/＋ 버튼: 기기 픽셀 배율 단위로 한 단계씩.
    func zoomStep(_ direction: Int) {
        noteUserInput(cancelShots: true)
        let level = (camScale * backing).rounded()
        let step = max(1, (level * 0.3).rounded())
        let target = min(maxScale, (level + CGFloat(direction) * step) / backing)
        if target <= fitScale + 0.001 { focus(.all, animated: true); return }
        userCamera = true
        animateCamera(to: target, center: clampCenter(camCenter, scale: target), duration: 0.3)
    }

    private func zoom(by factor: CGFloat, at viewPoint: CGPoint) {
        camAnimation = nil
        followNode = nil
        let newScale = min(maxScale, max(fitScale * 0.85, camScale * factor))
        let dx = viewPoint.x - size.width / 2, dy = viewPoint.y - size.height / 2
        let anchor = CGPoint(x: camCenter.x + dx / camScale, y: camCenter.y + dy / camScale)
        camScale = newScale
        camCenter = clampCenter(CGPoint(x: anchor.x - dx / newScale, y: anchor.y - dy / newScale), scale: newScale)
        userCamera = camScale > fitScale * 1.05
        if !userCamera && focusTarget != .all { focusTarget = .all; onFocusChanged?(.all) }
        pendingSnap = lastFrameTime + 0.3
        applyCamera()
    }

    private func pan(dx: CGFloat, dy: CGFloat) {
        camAnimation = nil
        followNode = nil
        userCamera = true
        camCenter = clampCenter(CGPoint(x: camCenter.x - dx / camScale, y: camCenter.y + dy / camScale), scale: camScale)
        applyCamera()
    }

    private func stepCamera(_ currentTime: TimeInterval) {
        let delta = lastFrameTime > 0 ? min(0.1, currentTime - lastFrameTime) : 0
        lastFrameTime = currentTime
        if let animation = camAnimation {
            let t = min(1, max(0, (currentTime - animation.start) / animation.duration))
            let e = t * t * (3 - 2 * t)
            // 배율은 로그 공간에서 보간해야 확대·축소 속도가 고르게 보인다.
            camScale = exp(Foundation.log(Double(animation.fromScale)) + (Foundation.log(Double(animation.toScale)) - Foundation.log(Double(animation.fromScale))) * e)
            var to = animation.toCenter
            if let node = followNode, node.parent != nil { to = clampCenter(followPoint(node), scale: animation.toScale) }
            camCenter = CGPoint(x: animation.fromCenter.x + (to.x - animation.fromCenter.x) * e, y: animation.fromCenter.y + (to.y - animation.fromCenter.y) * e)
            if t >= 1 { camAnimation = nil }
            applyCamera()
        } else if let node = followNode {
            if node.parent == nil {
                followNode = nil
            } else {
                let target = clampCenter(followPoint(node), scale: camScale)
                let k = min(1, 5 * delta)
                camCenter = CGPoint(x: camCenter.x + (target.x - camCenter.x) * k, y: camCenter.y + (target.y - camCenter.y) * k)
                applyCamera()
            }
        }
        if let snapAt = pendingSnap, currentTime >= snapAt, camAnimation == nil {
            pendingSnap = nil
            let target = snapScale(camScale)
            if abs(target - camScale) > 0.001 { animateCamera(to: target, center: clampCenter(camCenter, scale: target), duration: 0.12) }
        }
        if let active = activeShot, currentTime >= active.endsAt { startNextShot() }
    }

    /// 따라갈 때는 인물보다 조금 위(머리 위 말풍선까지)를 가운데에 둔다.
    private func followPoint(_ node: SKNode) -> CGPoint {
        let point = node.parent === world || node.parent == nil ? node.position : node.convert(.zero, to: world)
        return CGPoint(x: point.x, y: point.y + 16)
    }

    // MARK: 자동 줌(상황별 연출)

    func requestShot(_ shot: Shot) {
        guard autoZoomEnabled(), Date().timeIntervalSince(lastUserInput) > 6, view?.isPaused == false else { return }
        if shot.priority <= 1, Date().timeIntervalSince(lastAutoShot) < 20 { return }
        shotQueue.append(shot)
        shotQueue.sort { $0.priority > $1.priority }
        if shotQueue.count > 3 { shotQueue.removeLast(shotQueue.count - 3) }
        if activeShot == nil { startNextShot() }
    }

    private func startNextShot() {
        guard !shotQueue.isEmpty else { finishShots(); return }
        let shot = shotQueue.removeFirst()
        if savedCamera == nil { savedCamera = (camScale, camCenter, focusTarget, userCamera) }
        setHover(nil)
        switch shot.target {
        case .rect(let rect):
            followNode = nil
            let target = frame(for: rect, fill: 0.9)
            animateCamera(to: target.scale, center: target.center, duration: 0.6)
        case .follow(let node, let zoom):
            let scale = min(maxScale, snapScale(fitScale * zoom))
            followNode = node
            animateCamera(to: scale, center: clampCenter(followPoint(node), scale: scale), duration: 0.6)
        }
        onCaption?(shot.caption)
        activeShot = (shot, lastFrameTime + shot.duration)
        lastAutoShot = Date()
    }

    private func finishShots() {
        activeShot = nil
        followNode = nil
        onCaption?(nil)
        if let saved = savedCamera {
            savedCamera = nil
            focusTarget = saved.focus
            userCamera = saved.user
            animateCamera(to: saved.scale, center: clampCenter(saved.center, scale: saved.scale), duration: 0.6)
        }
    }

    private func cancelShots() {
        guard activeShot != nil || !shotQueue.isEmpty || savedCamera != nil else { return }
        shotQueue.removeAll()
        activeShot = nil
        followNode = nil
        savedCamera = nil
        onCaption?(nil)
    }

    private func noteUserInput(cancelShots shouldCancel: Bool) {
        lastUserInput = Date()
        if shouldCancel { cancelShots() }
    }

    private func rectAround(_ worker: WorkerNode, width: CGFloat = 170, height: CGFloat = 90) -> CGRect {
        CGRect(x: worker.position.x - width / 2, y: worker.position.y - 24, width: width, height: height)
    }

    // MARK: 확대 수준별 표시(LOD)

    /// 전체 보기에서는 이름표를 숨기고, 방으로 다가가면 이름표 · 작업 제목 말풍선 · 화이트보드를 보인다.
    /// 층 보기 중 다른 층 사람인가(이름표·말풍선을 숨긴다).
    private func offFocusFloor(_ worker: WorkerNode) -> Bool { offFocus(floor: worker.floorIndex) }

    /// 층 보기 중 그 층이 아닌가(그 층의 이름표 · 짐 글자를 숨긴다).
    func offFocus(floor: Int) -> Bool {
        guard case .floor(let index) = focusTarget, !userCamera, activeShot == nil else { return false }
        return floor != index
    }

    private func updateLOD(force: Bool = false) {
        let zoomed = isZoomedIn
        let focusKey = "\(focusTarget)-\(userCamera)-\(activeShot != nil)"
        guard force || zoomed != lodZoomed || focusKey != lodFocusKey else { return }
        lodZoomed = zoomed
        lodFocusKey = focusKey
        for (key, label) in labels {
            guard let worker = workers[key] else { continue }
            let away: Bool = { if case .rest = worker.place { return true } else { return false } }()
            label.isHidden = ((!zoomed || away) && selected != key) || offFocusFloor(worker)
        }
        for (key, bubble) in bubbles { if let worker = workers[key] { bubble.isHidden = offFocusFloor(worker) } }
        whiteboardLines.forEach { $0.isHidden = !zoomed }
        workflowBoards.values.joined().forEach { $0.isHidden = !zoomed }
        repositionToolLabels()
        repositionRoomExtras()
        valueLabels.forEach { $0.isHidden = !zoomed }
        refreshMachineBadges()
        refreshTitleBubbles()
    }

    private func refreshTitleBubbles() {
        let zoomed = lodZoomed ?? false
        for (key, worker) in workers {
            let atDesk: Bool = { if case .desk = worker.place { return true } else { return false } }()
            guard zoomed, atDesk, !worker.busy, !worker.leaving, !offFocusFloor(worker), let session = sessions[key], bubbles[key] == nil else {
                titleBubbles[key]?.isHidden = true
                continue
            }
            let badge: TextBadge
            if let existing = titleBubbles[key] {
                badge = existing
            } else {
                badge = TextBadge("", style: .bubble, layer: .title)
                overlay.addChild(badge)
                titleBubbles[key] = badge
            }
            // 책상 간격(50px × 배율)에 맞춰 글자 수를 줄인다. 너무 멀면 숨긴다.
            let pitch = CGFloat(BuildingLayout.deskPitch) * camScale
            guard camScale >= 2.2 else { badge.isHidden = true; continue }
            let limit = max(6, min(18, Int(pitch / 9)))
            let title = session.displayTitle
            badge.set(String(title.prefix(limit)) + (title.count > limit ? "…" : ""))
            badge.isHidden = false
            badge.position = titlePoint(worker)
        }
        for (key, badge) in titleBubbles where workers[key] == nil { badge.removeFromParent(); titleBubbles[key] = nil }
    }

    private func titlePoint(_ worker: WorkerNode) -> CGPoint {
        CGPoint(x: worker.position.x * pointsPerPixel, y: (worker.position.y + worker.spriteHeight + 6) * pointsPerPixel + 26)
    }

    // MARK: 건물

    private func rebuildBuilding() {
        floorNodes.forEach { $0.removeFromParent() }
        floorNodes = []
        for (index, floor) in layout.floors.enumerated() {
            let canvas: PixelCanvas
            switch floor.kind {
            case .basement: canvas = FloorPainter.basement(height: floor.height)
            case .lobby: canvas = FloorPainter.lobby(height: floor.height)
            case .hall: canvas = FloorPainter.hall(height: floor.height)
            case .team: canvas = FloorPainter.team(height: floor.height, floorIndex: index, rooms: layout.rooms, desks: Array(layout.desks.values) + layout.spareDesks, isTop: index == layout.topTeamIndex, isLibraryUpper: false)
            case .roof: canvas = FloorPainter.roof(height: floor.height)
            }
            let texture = canvas.cgImage().map { SKTexture(cgImage: $0) } ?? SKTexture()
            texture.filteringMode = .nearest
            let node = SKSpriteNode(texture: texture)
            node.anchorPoint = .zero
            node.position = CGPoint(x: 0, y: floor.y)
            node.zPosition = 0
            world.addChild(node)
            floorNodes.append(node)
        }
        workflowRooms.values.forEach { $0.removeFromParent() }
        workflowRooms = [:]
        for index in workflowFloors {
            let room = WorkflowRoomNode(floorIndex: index, floor: layout.floors[index])
            room.zPosition = 0.5
            world.addChild(room)
            workflowRooms[index] = room
        }
        let libraryHeight = BuildingLayout.lobbyHeight
        libraryNode.texture = TextureCache.shared.texture("library\(libraryHeight)") { FloorPainter.library(height: libraryHeight) }
        libraryNode.size = CGSize(width: BuildingLayout.wingX1 - BuildingLayout.wingX0, height: libraryHeight)
        libraryNode.position = CGPoint(x: BuildingLayout.wingX0, y: layout.floors[1].y)

        doorNode.texture = door(0)
        doorNode.size = CGSize(width: 30, height: 36)
        doorNode.position = CGPoint(x: 44, y: CGFloat(layout.floors[1].floorLine))
        hallDoorNode.texture = door(0)
        hallDoorNode.size = CGSize(width: 30, height: 36)
        hallDoorNode.position = CGPoint(x: CGFloat(BuildingLayout.hallDoorX) - 15, y: CGFloat(layout.floors[layout.hallIndex].floorLine))
        machineRoom.place(floorLine: CGFloat(layout.floors[0].floorLine))

        elevatorDoors.values.forEach { $0.removeFromParent() }
        elevatorDoors = [:]
        for index in layout.floors.indices.dropLast() {
            let node = SKSpriteNode(texture: elevatorTexture(0))
            node.anchorPoint = .zero
            node.size = CGSize(width: 20, height: 32)
            node.position = CGPoint(x: BuildingLayout.elevatorX0 + 2, y: layout.floors[index].floorLine)
            node.zPosition = 3
            world.addChild(node)
            elevatorDoors[index] = node
        }

        // 도구실: 반입구 높이 · 설치된 기계 자리(로비 바닥선은 층이 늘어도 그대로지만 다시 맞춘다). 금고 방도 같은 층.
        toolDock.place(floorLine: line(layout.lobbyIndex))
        placeVault()
        relayoutPapers()
        relayoutClutter()
        for (id, node) in tools where node.parent === world { if let slot = toolSlotOf[id] { node.position = ToolRoom.point(slot, floorLine: line(layout.lobbyIndex)) } }

        alarmNode.texture = TextureCache.shared.texture("alarm0") { Furniture.alarmLight(on: false) }
        alarmNode.size = CGSize(width: 6, height: 6)
        alarmNode.position = CGPoint(x: 458, y: CGFloat(layout.floors[0].floorLine + 44))

        warehouse.place(floorLine: CGFloat(layout.floors[0].floorLine))
        inventory.place(floorLine: CGFloat(layout.floors[0].floorLine))
        // 출동 중인 경비원은 그대로 둔다(층이 바뀔 때마다 초소로 순간 이동하던 문제).
        if !guardBusy {
            guardNode.position = CGPoint(x: BuildingLayout.guardPostX, y: layout.floors[1].floorLine)
            setGuard(.stand(blink: false))
        }
        if !trainerBusy {
            trainerNode.position = CGPoint(x: Self.trainerRoofX, y: CGFloat(layout.floors[layout.roofIndex].floorLine))
            if partyPlaying { trainerParty(true) } else { trainerIdle() }   // DJ 파티 중이면 계속 같이 논다(Rooftop.swift)
        } else {
            // 연출(난입 · 실측 발표) 중에 층이 늘거나 줄면 서 있던 층의 새 바닥으로 옮긴다 — 옥상이 내려앉아 하늘에 뜨지 않게.
            trainerNode.position.y = staffY(afterRebuild: trainerNode.position.y)
        }
        // 청소 특공대(방문 중인 두 명 · 실측을 알리러 온 한 명) · 옥상 파티 디제이(Rooftop.swift)도 같다.
        for node in janitorNodes + [janitorReporter, djNode].compactMap({ $0 }) where node.parent != nil {
            node.position.y = staffY(afterRebuild: node.position.y)
        }
        staffFloorsBeforeRebuild = layout.floors
        rebuildStaticLabels()
        rebuildLights()
        placeBoss()
        relayout()
    }

    /// 밤(19시~5시)에는 천장 등·로비 등에 따뜻한 불빛을 켠다. 수영장은 물결이 반짝인다(노을~밤엔 수중등이 비친 청록 · 호박색 물결).
    /// 옥상 풀 조명 · 김(Rooftop.swift)도 여기서 맞춘다 — 시간이 바뀔 때(update) · 건물을 다시 지을 때(옥상 높이) 불린다.
    private func rebuildLights() {
        lightsLayer.removeAllChildren()
        let hour = SceneClock.hour
        lightsHour = hour
        lightsSeason = Season.current
        let night = hour >= 19 || hour < 5
        let glow = TextureCache.shared.texture("glow") {
            var c = PixelCanvas(30, 22)
            for y in 0..<22 { for x in 0..<30 {
                let dx = Double(x - 15) / 15, dy = Double(y) / 22
                let d = dx * dx + dy * dy
                if d < 1, (x + y) % 2 == 0 || d < 0.45 { c.dot(x, y, PixelColor(0xFFE7A0, alpha: UInt8(max(0, 70 - d * 60)))) }
            } }
            return c
        }
        if night {
            var points: [(CGFloat, CGFloat)] = layout.desks.values.map { (CGFloat($0.deskX + 19), CGFloat(layout.floors[$0.floor].y + layout.floors[$0.floor].height) - 11) }
            points += layout.spareDesks.map { (CGFloat($0.deskX + 19), CGFloat(layout.floors[$0.floor].y + layout.floors[$0.floor].height) - 11) }
            points += [(103, CGFloat(layout.floors[1].y + layout.floors[1].height) - 11), (183, CGFloat(layout.floors[1].y + layout.floors[1].height) - 11)]
            points += ToolRoom.lampXs.map { (CGFloat($0), CGFloat(layout.floors[1].y + layout.floors[1].height) - 13) }
            for (x, top) in points {
                let node = SKSpriteNode(texture: glow)
                node.anchorPoint = CGPoint(x: 0.5, y: 1)
                node.position = CGPoint(x: x, y: top)
                node.blendMode = .add
                lightsLayer.addChild(node)
            }
        }
        let roof = layout.floors[layout.roofIndex]
        let lit = Daypart.of(hour: hour).poolLight > 0
        let frames = (0..<2).map { frame in TextureCache.shared.texture(lit ? "shimmer-lit\(frame)" : "shimmer\(frame)") {
            if lit { return PoolArt.litShimmer(frame) }
            var c = PixelCanvas(256, 3)
            for x in stride(from: (frame * 4) % 7, to: 256, by: 7) { c.hline(x, frame % 2, 3, Pal.waterLight.with(alpha: 230)); c.dot(x + 1, 2 - frame % 2, Pal.white.with(alpha: 180)) }
            return c
        } }
        shimmerNode.texture = frames[0]
        shimmerNode.size = CGSize(width: 256, height: 3)
        shimmerNode.position = CGPoint(x: 340, y: CGFloat(roof.floorLine + 1))
        shimmerNode.removeAllActions()
        shimmerNode.run(.repeatForever(.animate(with: frames, timePerFrame: 0.6)))
        updatePoolAmbience()
    }

    private func rebuildStaticLabels() {
        staticLabels.forEach { $0.badge.removeFromParent() }
        staticLabels = []
        whiteboardLines = []
        // 수치 라벨도 함께 지웠으니 다음 갱신에서 다시 만들게 한다.
        swapLabel = nil; diskLabel = nil; systemLabel = nil; processLabel = nil; cpuLabel = nil; ramLabel = nil; hallLabel = nil
        valueLabels = []
        func sign(_ text: String, _ vx: CGFloat, _ vy: CGFloat, style: TextBadge.Style = .plate, color: NSColor = .white) -> TextBadge {
            let badge = TextBadge(text, style: style, color: color)
            overlay.addChild(badge)
            staticLabels.append((badge, vx, vy))
            return badge
        }
        let b = layout.floors[0], l = layout.floors[1], hall = layout.floors[layout.hallIndex], roof = layout.floors[layout.roofIndex]
        // 기계실: 이름과 값을 한 배지로(이름 카드·상태 카드가 겹치던 문제). 줌아웃 = 이름, 줌인 = 이름 + 값.
        machineBadges = [:]
        for (kind, x) in [(MachineKind.cpu, 83.0), (.ram, 165.0), (.swap, 262.0), (.disk, 397.0), (.system, 552.0)] {
            let badge = TextBadge(kind.label, style: .plate)
            overlay.addChild(badge)
            staticLabels.append((badge, CGFloat(x), CGFloat(b.y + b.height - 12)))
            machineBadges[kind] = badge
        }
        _ = sign("로비", 131, CGFloat(l.y + l.height - 14))
        _ = sign("도구실 · 앱", ToolRoom.dockX, CGFloat(l.y + l.height - 14))
        _ = sign("기록 보관소 · 금고", 552, CGFloat(l.y + l.height - 14))
        _ = sign("대기실 · 강당", 250, CGFloat(hall.y + hall.height - 14))
        _ = sign("정신교육실", 552, CGFloat(hall.y + hall.height - 14))
        _ = sign("루프톱", 160, CGFloat(roof.y + roof.height - 20))
        _ = sign("웰니스 풀", 470, CGFloat(roof.y + roof.height - 20))
        for room in layout.rooms {
            let floor = layout.floors[room.floor]
            let plateWidth = min(60, room.x1 - room.x0 - 12)
            _ = sign(room.name, CGFloat(room.x0 + 6 + plateWidth / 2), CGFloat(floor.y + floor.height - 13), style: .sign, color: NSColor(srgbRed: 1, green: 0.93, blue: 0.75, alpha: 1))
        }
        for index in layout.teamFloorIndexes {
            let floor = layout.floors[index]
            let used = layout.rooms.filter { $0.floor == index }.map(\.x1).max() ?? BuildingLayout.mainX0
            if BuildingLayout.mainX1 - used > 40 {
                _ = sign("공실", CGFloat(used + (BuildingLayout.mainX1 - used) / 2), CGFloat(floor.floorLine + 36), style: .sign, color: NSColor(white: 0.35, alpha: 1))
            }
        }
        // 워크플로실: 이름표 · 보드 세 줄(가까이서만) · 비었을 때 '대기'
        workflowBoards = [:]
        workflowIdleSigns = [:]
        for index in workflowFloors {
            let floor = layout.floors[index]
            let wing = CGFloat(BuildingLayout.wingX0)
            _ = sign("워크플로실", wing + 114, CGFloat(floor.y + floor.height - 14))
            workflowBoards[index] = (0..<3).map { line in
                let badge = sign("", wing + 37, CGFloat(floor.floorLine + 62 - line * 8), style: .sign, color: NSColor(srgbRed: 0.2, green: 0.35, blue: 0.7, alpha: 1))
                badge.isHidden = !(lodZoomed ?? false)
                return badge
            }
            workflowIdleSigns[index] = sign("대기", wing + 114, CGFloat(floor.floorLine + 40), style: .sign, color: NSColor(white: 0.66, alpha: 1))
        }
        let top = layout.floors[layout.topTeamIndex]
        _ = sign("상황실 · 지금 하는 일", CGFloat(BuildingLayout.wingX0 + 78), CGFloat(top.y + top.height - 16), style: .sign, color: NSColor(white: 0.2, alpha: 1))
        for i in 0..<3 {
            whiteboardLines.append(sign("", CGFloat(BuildingLayout.wingX0 + 78), CGFloat(top.y + top.height - 26 - i * 8), style: .sign, color: NSColor(srgbRed: 0.2, green: 0.35, blue: 0.7, alpha: 1)))
        }
        repositionOverlay()
    }

    private func repositionOverlay() {
        for item in staticLabels { item.badge.position = CGPoint(x: item.vx * pointsPerPixel, y: item.vy * pointsPerPixel) }
        for (key, label) in labels { if let worker = workers[key] { label.position = labelPoint(worker) } }
        for (key, bubble) in bubbles { if let worker = workers[key] { bubble.position = bubblePoint(worker) } }
        for (key, bubble) in titleBubbles { if let worker = workers[key] { bubble.position = titlePoint(worker) } }
        repositionToolLabels()
        repositionRoomExtras()
    }

    private func labelPoint(_ worker: WorkerNode) -> CGPoint {
        CGPoint(x: worker.position.x * pointsPerPixel, y: (worker.position.y + worker.spriteHeight + 6) * pointsPerPixel)
    }

    private func bubblePoint(_ worker: WorkerNode) -> CGPoint {
        CGPoint(x: (worker.position.x + 6) * pointsPerPixel, y: (worker.position.y + worker.spriteHeight + 17) * pointsPerPixel)
    }

    func startFPSMeter() {
        fpsTimes = []
        measuringFPS = true
    }

    /// 평균 FPS와 하위 5% 구간 FPS(가장 긴 프레임 간격 기준).
    func stopFPSMeter() -> (average: Double, low: Double, frames: Int, seconds: Double) {
        measuringFPS = false
        guard fpsTimes.count > 2, let first = fpsTimes.first, let last = fpsTimes.last else { return (0, 0, fpsTimes.count, 0) }
        let seconds = last - first
        let intervals = zip(fpsTimes.dropFirst(), fpsTimes).map { $0 - $1 }.sorted()
        let p95 = intervals[min(intervals.count - 1, Int(Double(intervals.count) * 0.95))]
        return (Double(fpsTimes.count - 1) / seconds, p95 > 0 ? 1 / p95 : 0, fpsTimes.count, seconds)
    }

    override func update(_ currentTime: TimeInterval) {
        if measuringFPS { fpsTimes.append(currentTime) }
        // 안전망 시계: 창이 닫혀 멈춘 동안(프레임 사이가 긴 동안)은 흐르지 않게 한 프레임에 0.1초까지만 더한다.
        // 프레임 사이가 1초 넘게 비었다 = 창을 닫았거나 최소화·다른 화면에 있다가 돌아왔다.
        let gap = lastFrameTime > 0 ? currentTime - lastFrameTime : 0
        if gap > 1 { resumed() }
        activeTime += min(0.1, max(0, gap))
        stepCamera(currentTime)
        // 움직이는 직원의 이름표·말풍선이 따라가게 한다.
        for (key, worker) in workers {
            labels[key]?.position = labelPoint(worker)
            bubbles[key]?.position = bubblePoint(worker)
            titleBubbles[key]?.position = titlePoint(worker)
        }
        positionStaffBubbles()
        positionFloatTags(step: gap > 0 && gap < 1 ? gap : 0)
        // 디스크 저장고 글자(재고 조사 중에는 상자 · 손수레가 움직인다).
        if diskLabelsLive { repositionDiskLabels() }
        // 정신교육실 인물 이름표: 화면에서 늘 같은 크기(가까이 다가가도 커지지 않게) — 배율이 바뀔 때만 다시 맞춘다.
        if abs(camScale - retiredTagScale) > 0.001 {
            retiredTagScale = camScale
            world.childNode(withName: "retired-room")?.children.forEach { ($0 as? RetiredFigure)?.fitTag(cameraScale: camScale) }
            fitRoomTags(cameraScale: camScale)
        }
        resolveBubbleOverlaps()
        if let key = selected, let worker = workers[key] {
            selectionMarker.isHidden = false
            selectionMarker.position.x = worker.position.x
            if !selectionMarker.hasActions() { selectionMarker.position.y = worker.position.y + worker.spriteHeight + 22 }
        } else {
            selectionMarker.isHidden = true
        }
        // 시간 · 계절이 바뀌면 하늘 · 땅과 조명(풀 조명 · 김 포함)을 다시 맞춘다. 조명은 따로 잰다 — 창 크기 변경(relayout)이 하늘만 먼저 고쳐도 놓치지 않게.
        let clockHour = SceneClock.hour, season = Season.current
        if clockHour != skyHour || season != skySeason { rebuildSky() }
        if clockHour != lightsHour || season != lightsSeason { rebuildLights() }
        if currentTime - lastAmbientTick >= 1 {
            lastAmbientTick = currentTime
            ambientTick(currentTime)
        }
    }

    /// 정신교육실 인물 이름표를 마지막으로 맞춘 배율.
    private var retiredTagScale: CGFloat = 0

    /// 말풍선이 겹치지 않게: 이름표는 그대로 두고(장애물), 말풍선은 아래부터 놓으며 겹치면 위 빈자리로 올린다.
    private func resolveBubbleOverlaps() {
        var placed: [CGRect] = []
        for label in labels.values where !label.isHidden && label.badgeSize.width > 0 {
            placed.append(CGRect(x: label.position.x - label.badgeSize.width / 2, y: label.position.y - label.badgeSize.height / 2, width: label.badgeSize.width, height: label.badgeSize.height))
        }
        // 재고 조사 중: 탁자 이름표 · 스티커 · 손수레 꼬리표도 장애물(인력의 말풍선이 그 위를 덮지 않게).
        if diskLabelsLive { placed += diskLabels.frames }
        let items = (Array(bubbles.values) + Array(titleBubbles.values) + Array(staffBubbles.values))
            .filter { !$0.isHidden && $0.parent != nil && $0.badgeSize.width > 0 }
            .sorted { $0.position.y != $1.position.y ? $0.position.y < $1.position.y : $0.position.x < $1.position.x }
        for badge in items {
            let size = badge.badgeSize
            var rect = CGRect(x: badge.position.x - size.width / 2, y: badge.position.y - size.height / 2, width: size.width, height: size.height)
            var tries = 0
            while let hit = placed.first(where: { $0.insetBy(dx: -2, dy: -1).intersects(rect) }), tries < 8 {
                rect.origin.y = hit.maxY + 2
                tries += 1
            }
            badge.position.y = rect.midY
            placed.append(rect)
        }
    }

    /// 1초마다: 안전망, 놀이 자리 교체, 냄새·땀, 기계실 증기, 심심한 대사.
    private func ambientTick(_ now: TimeInterval) {
        auditWorkers()
        auditWatch()
        warehouse.tick(activeTime: activeTime)
        inventoryTick()   // 재고 조사 안전망 · 드문 재고 세기 순찰(Inventory.swift)
        toolDock.tick(activeTime: activeTime)
        vault.tick(activeTime: activeTime)
        machineRoom.tick(in: world)
        poolTick()   // 옥상: 겨울 온천 대사 · DJ 파티 일정과 진행(Rooftop.swift)
        clutterTick()   // 짐 5단계 방: 가끔 상자 탑 먼지(Clutter.swift)
        // 검수용: REMON_DEBUG_WORKERS=1이면 5초마다 직원 위치·상태를 표준 오류로.
        if ProcessInfo.processInfo.environment["REMON_DEBUG_WORKERS"] == "1", Int(now) % 5 == 0 {
            var lines: [String] = []
            for (key, worker) in workers.sorted(by: { $0.key.pid < $1.key.pid }) {
                let session = sessions[key]
                lines.append("pid \(key.pid) \(session?.project ?? "?") \(session?.state.rawValue ?? "?") floor=\(worker.floorIndex) place=\(worker.place) x=\(Int(worker.position.x)) busy=\(worker.busy) leaving=\(worker.leaving) desk=\(layout.desks[key].map { "f\($0.floor)x\($0.deskX)" } ?? "none") bubble=\(bubbles[key]?.currentText ?? "-")")
            }
            FileHandle.standardError.write(Data(("[workers] floors=\(layout.floors.count) rooms=\(layout.rooms.map { "\($0.name)@f\($0.floor)" })\n" + lines.joined(separator: "\n") + "\n").utf8))
        }
        for (key, worker) in workers where !worker.busy && !worker.leaving {
            guard let session = sessions[key] else { continue }
            // 쉬는 직원: 놀이 자리가 만료되면 다른 놀이로 옮긴다(실제 상태는 그대로 '쉼'). DJ 파티 중인 옥상 자리는 끝날 때까지 그대로.
            if session.state == .idle, let seat = playSeats[key], now >= seat.until, !(partyPlaying && Self.isPartySpot(seat.spot, roof: layout.roofIndex)) {
                playSeats[key] = nil
                let target = targetPlace(session)
                travel(worker, toFloor: target.floor, x: target.x, place: target.place) { [weak self, weak worker] in
                    guard let self, let worker else { return }
                    worker.place = target.place
                    self.settle(worker)
                }
                continue
            }
            // 사흘 넘게 퇴근 못 한 직원: 가끔 냄새가 난다.
            if worker.look.scruff >= 2, Variety.shared.chance(0.12) {
                Effects.burst(in: world, at: CGPoint(x: worker.position.x + 4, y: worker.position.y + worker.spriteHeight + 2), color: PixelColor(0x9BBF6A), count: 2, spread: 5, rise: 9, duration: 1.2)
            }
            // 심심한 대사(놀이 중·강당). 자리를 떠나 걷는 중에는 하지 않는다(엘리베이터 앞에서 '집에 가고 싶다'를 외치던 장면).
            if bubbles[key] == nil, worker.route == nil, Variety.shared.chance(0.02) {
                // 자기 세션의 실제 상태로 말한다(Speech): 하는 일 제목 · 기다린 시간 · 컨텍스트 % · 최근 커밋/푸시/배포.
                let options = Speech.worker(session, speechNow)
                switch worker.place {
                case .rest(let spot) where spot.kind == .hallSeat:
                    say(key, Variety.shared.line("hall", options), seconds: 3)
                case .rest:
                    say(key, Variety.shared.line("fun", options), seconds: 3)
                case .desk where session.state == .working || session.state == .waiting:
                    if Variety.shared.chance(session.state == .waiting ? 0.5 : 0.3) { say(key, Variety.shared.line("work", options), seconds: 2.8) }
                default: break
                }
            }
        }
    }

    /// 잠깐 말풍선을 띄운다(상태 말풍선 '입력 필요'·'zZ'는 건드리지 않는다).
    func say(_ key: ProcessKey, _ text: String, seconds: TimeInterval, style: TextBadge.Style = .bubble) {
        guard let worker = workers[key], bubbles[key] == nil else { return }
        setBubble(key, text, style: style)
        worker.run(.sequence([.wait(forDuration: seconds), .run { [weak self] in
            guard let self, self.bubbles[key]?.currentText == text else { return }
            self.setBubble(key, nil)
        }]), withKey: "say")
    }

    // MARK: 스냅샷 + 사건

    private var stableStates: [ProcessKey: (state: SessionState, candidate: SessionState?, since: Date)] = [:]
    /// 상태 안정화(15초)용 시계. 장면 시험은 가짜 시계를 넣어 시간을 빨리 돌린다.
    var clock: () -> Date = { Date() }
    /// 검수용(장면 시험): 지금 건물 배치 · 기계실 창고(짐꾼).
    var currentLayout: BuildingLayout { layout }
    var warehouseNode: WarehouseNode { warehouse }
    var workerKeys: [ProcessKey] { Array(workers.keys) }
    /// 검수용: 워크플로실(층별) — 로봇 수 · 불 켜짐 · 보드 글자 · '대기' 표지가 보이는지. 방이 없는 층이면 nil.
    func workflowState(_ floor: Int) -> (robots: Int, lit: Bool, board: [String], idleSign: Bool)? {
        guard let room = workflowRooms[floor] else { return nil }
        return (room.robotCount, room.lit, (workflowBoards[floor] ?? []).map(\.currentText), workflowIdleSigns[floor]?.isHidden == false)
    }

    /// 장면 안 자리 범주: 0 책상(일함·입력 필요), 1 놀이(쉼), 2 강당(오래 쉼·고아).
    private static func seatCategory(_ state: SessionState) -> Int {
        switch state {
        case .working, .waiting: 0
        case .idle: 1
        case .longIdle, .orphan: 2
        }
    }

    /// 자리를 옮기게 되는 상태 변화는 15초 동안 유지될 때만 따른다(경계에서 깜박이며 책상↔수영장을 오가지 않게).
    /// 같은 자리 안의 변화(일함 ↔ 입력 필요)는 바로 따른다. 목록·상세 카드는 원래 상태를 그대로 보여 준다.
    private func stabilized(_ list: [AgentSession]) -> [AgentSession] {
        let now = clock()
        var result: [AgentSession] = []
        for var session in list {
            if var entry = stableStates[session.id] {
                if Self.seatCategory(session.state) == Self.seatCategory(entry.state) {
                    entry.state = session.state; entry.candidate = nil
                } else if entry.candidate == session.state {
                    if now.timeIntervalSince(entry.since) >= 15 { entry.state = session.state; entry.candidate = nil }
                } else {
                    entry.candidate = session.state; entry.since = now
                }
                stableStates[session.id] = entry
                session.state = entry.state
            } else {
                stableStates[session.id] = (session.state, nil, now)
            }
            result.append(session)
        }
        let alive = Set(list.map(\.id))
        stableStates = stableStates.filter { alive.contains($0.key) }
        return result
    }

    /// 직전 스냅샷의 잠깐 세션(퇴근할 땐 세션이 이미 없어 여기서 기억한다).
    private var lastEphemeral = Set<ProcessKey>()

    func update(snapshot: OfficeSnapshot, events: [OfficeEvent]) {
        lastEphemeral.formUnion(snapshot.sessions.filter(\.isEphemeral).map(\.id))
        let alive = Set(snapshot.sessions.map(\.id))
        defer { lastEphemeral = lastEphemeral.intersection(alive.union(Set(workers.keys))) }
        let steady = stabilized(snapshot.sessions)
        var adjusted = snapshot
        adjusted.sessions = steady
        self.snapshot = adjusted
        sessions = Dictionary(uniqueKeysWithValues: steady.map { ($0.id, $0) })
        let newLayout = planner.plan(sessions: snapshot.sessions)
        let structureChanged = newLayout.floors != layout.floors || newLayout.rooms != layout.rooms || Set(newLayout.desks.values.map(\.deskX).map { "\($0)" } + newLayout.spareDesks.map { "s\($0.floor)-\($0.deskX)" }) != Set(layout.desks.values.map(\.deskX).map { "\($0)" } + layout.spareDesks.map { "s\($0.floor)-\($0.deskX)" })
        let oldLayout = layout
        layout = newLayout
        if structureChanged && built { rebuildBuilding() }
        if oldLayout.floors != layout.floors { remapFloors(from: oldLayout) }
        for event in events { handle(event) }
        reconcile()
        updateWorkflowRooms()
        updateProps(snapshot)
        publishFloors()
    }

    /// 멈춤? 기준: 일하는 중(active)으로 보이는데 마지막 기록이 이보다 오래됐다.
    static let workflowStaleAfter: TimeInterval = 20 * 60

    /// 워크플로실 = 하위 에이전트 자원 관리실: 층마다 그 층에 책상이 있는 세션들의 일하는 워크플로 에이전트를 모아 방에 세우고 보드를 쓴다.
    /// 멈춤?: 일하는 중인데 20분 넘게 기록이 없으면(장면 시계 기준) 빨간 등 · '멈춤?' · 보드에 이름.
    /// 잔재: 주인 세션이 스냅샷에서 사라졌는데 로봇이 남아 있던 것 → 이번 갱신에 전원을 내리고 '잔재', 다음 갱신에 치운다(실제 정리는 코어 몫).
    private func updateWorkflowRooms() {
        let now = clock()
        var robots: [Int: [WorkflowRobot]] = [:]
        var seen: [String: (robot: WorkflowRobot, floor: Int)] = [:]
        let alive = Set((snapshot?.sessions ?? []).map(\.id))
        for session in snapshot?.sessions ?? [] {
            SubagentSightings.shared.note(session.subagents, at: now)
            guard let floor = layout.desks[session.id]?.floor, workflowRooms[floor] != nil else { continue }
            for agent in session.subagents where (agent.active || agent.stale) && agent.kind == .workflow {
                // 멈춤? = 코어 판정(일지에 끝났다는 기록이 없는데 20분 넘게 조용함) 또는 장면 시계 기준 20분(시험용 가짜 시계).
                let stale = agent.stale || (agent.active && (agent.lastActivity.map { now.timeIntervalSince($0) > Self.workflowStaleAfter } ?? false))
                let robot = WorkflowRobot(owner: session.id, info: agent, stale: stale)
                robots[floor, default: []].append(robot)
                seen[agent.id] = (robot, floor)
                workflowOwners[session.id] = session
            }
        }
        for (id, last) in workflowSeen where !last.robot.residue && !alive.contains(last.robot.owner) && seen[id] == nil && workflowRooms[last.floor] != nil {
            var robot = last.robot
            robot.residue = true
            robot.stale = false
            robots[last.floor, default: []].append(robot)
            seen[id] = (robot, last.floor)
        }
        workflowSeen = seen
        let owned = Set(seen.values.map(\.robot.owner))
        workflowOwners = workflowOwners.filter { owned.contains($0.key) }
        for (index, room) in workflowRooms {
            let list = (robots[index] ?? []).sorted { ($0.residue ? 1 : 0, $0.info.id) < ($1.residue ? 1 : 0, $1.info.id) }
            room.show(list)
            room.fitTags(cameraScale: pointsPerPixel)
            let lines = WorkflowRoomNode.board(list)
            for (line, badge) in (workflowBoards[index] ?? []).enumerated() { badge.set(line < lines.count ? lines[line] : "") }
            workflowIdleSigns[index]?.isHidden = !list.isEmpty
        }
    }

    /// 로봇을 누른 점: 워크플로실 로봇(늘) · 책상 옆 하위 에이전트 로봇(가까이 다가가 있을 때만 — 멀리서는 직원을 누르기 쉽게).
    private func hitRobot(_ point: CGPoint) -> (robot: WorkflowRobot, floor: Int?)? {
        for (index, room) in workflowRooms {
            let floor = layout.floors[index]
            guard point.y >= CGFloat(floor.y), point.y <= CGFloat(floor.y + floor.height), let robot = room.robot(at: point) else { continue }
            return (robot, index)
        }
        guard isZoomedIn else { return nil }
        for (key, worker) in workers where !worker.leaving {
            // 책상 옆 로봇은 직원 노드 기준 자리(직원 그림만 좌우로 뒤집히고 노드는 뒤집히지 않는다).
            let local = CGPoint(x: point.x - worker.position.x, y: point.y - worker.position.y)
            guard let id = worker.helperID(at: local), let session = sessions[key], let info = session.subagents.first(where: { $0.id == id }) else { continue }
            let stale = info.active && info.lastActivity.map { clock().timeIntervalSince($0) > Self.workflowStaleAfter } == true
            return (WorkflowRobot(owner: key, info: info, stale: stale), nil)
        }
        return nil
    }

    /// 하위 에이전트 카드에 넘길 주인 세션: 지금 스냅샷의 세션, 없으면(잔재 로봇) 마지막으로 본 세션.
    func subagentOwner(_ key: ProcessKey) -> AgentSession? { sessions[key] ?? workflowOwners[key] }

    /// 이 층에 워크플로실이 있으면 워크플로 에이전트는 그 방에서 일한다(책상 옆에는 일반 하위 에이전트만).
    private func hasWorkflowRoom(_ floor: Int) -> Bool { workflowRooms[floor] != nil }

    // MARK: 층 안내판

    func publishFloors() {
        var result: [FloorSummary] = []
        let sessions = snapshot?.sessions ?? []
        for (index, floor) in layout.floors.enumerated().reversed() {
            switch floor.kind {
            case .roof:
                let playing = sessions.filter { $0.state == .idle }.count
                let partyNote = partyPlaying ? " · DJ 파티 중" : ""
                result.append(FloorSummary(id: index, kind: .roof, title: "옥상 · 휴식", subtitle: (playing > 0 ? "쉬는 중 \(playing)명" : "비어 있음") + partyNote, focus: .floor(index), people: playing))
            case .team:
                let rooms = layout.rooms.filter { $0.floor == index }
                let names = rooms.map { $0.name }
                let members = sessions.filter { session in names.contains { $0 == session.project || $0.hasPrefix(session.project + " ") } }
                let working = members.filter { $0.state == .working }.count
                let waiting = members.filter { $0.state == .waiting }.count
                let title = names.isEmpty ? "빈 층" : names.joined(separator: " · ")
                let robots = workflowRooms[index]?.robotCount ?? 0
                result.append(FloorSummary(id: index, kind: .team, title: title, subtitle: members.isEmpty ? "공실" : "\(members.count)명 · 일하는 중 \(working)" + (waiting > 0 ? " · 입력 필요 \(waiting)" : "") + (robots > 0 ? " · 워크플로 \(robots)" : ""), focus: .floor(index), people: members.count, working: working, waiting: waiting))
            case .hall:
                let waitingRoom = sessions.filter { $0.state == .longIdle || $0.state == .orphan }
                result.append(FloorSummary(id: index, kind: .hall, title: "대기실 · 강당", subtitle: waitingRoom.isEmpty ? "비어 있음" : "오래 쉼 \(waitingRoom.count)명 · \(Fmt.gb(waitingRoom.reduce(0) { $0 + $1.footprint }))", focus: .floor(index), people: waitingRoom.count, warn: waitingRoom.count >= 5))
            case .lobby:
                let apps = (snapshot?.apps ?? []).filter { $0.category != .system && $0.category != .other && $0.id != "claude-daemon" }.count
                result.append(FloorSummary(id: index, kind: .lobby, title: "로비 · 도구실 · 금고", subtitle: "앱 \(apps)개 · 금고 \(vaultSummary.total)건", focus: .floor(index)))
            case .basement:
                let system = snapshot?.system
                let hot = (system?.thermal.available == true && system!.thermal.cpuTemperature >= 95) || (system?.cpuPercent ?? 0) >= 85
                let sub = system.map { "CPU \(Fmt.percent($0.cpuPercent)) · RAM 여유 \(Fmt.gb($0.memory.available)) · 디스크 여유 \(Fmt.gb($0.disk.available))" } ?? ""
                result.append(FloorSummary(id: index, kind: .machines, title: "기계실", subtitle: sub, focus: .floor(index), warn: hot || diskLow || system?.pressure == .critical))
            }
        }
        if result != lastFloorSummary {
            lastFloorSummary = result
            onFloorsChanged?(result)
        }
    }

    private func publishViewportFloor() {
        let y = camCenter.y
        let index = layout.floors.firstIndex { CGFloat($0.y) <= y && y < CGFloat($0.y + $0.height) } ?? (y < 0 ? 0 : layout.roofIndex)
        if index != lastViewportFloor {
            lastViewportFloor = index
            onViewportFloor?(index)
        }
    }

    private func handle(_ event: OfficeEvent) {
        switch event.kind {
        case .arrived(let key):
            guard workers[key] == nil, let session = event.sessionSnapshot ?? sessions[key] else { return }
            arrive(session)
        case .departed(let key, let reason):
            guard let worker = workers[key], !worker.leaving else { return }
            if reason == .evictedByReMON { evict(worker, shout: nil) } else { depart(worker) }
        case .pressureChanged(_, let to):
            if to != .normal { trainerVisit(reclaimed: 0, text: to == .critical ? "메모리 압박 위험!" : "메모리 압박 주의") }
        case .cleanup(let reclaimed, _):
            trainerVisit(reclaimed: reclaimed, text: "정리 운동!")
        case .swapMoved:
            // 스왑 상자는 스냅샷 값을 따라 짐꾼이 나른다(updateProps → warehouse). 사건은 기록용.
            break
        case .diskLow:
            setAlarm(true)
        case .diskRecovered:
            setAlarm(false)
        case .cpuSpike(let key, _):
            if let worker = workers[key] { steam(worker) }
        case .tidy(let reclaimed, let project, let items):
            janitorVisit(project: project, items: items, reclaimed: reclaimed)
        case .stateChanged:
            break
        }
    }

    private func reconcile() {
        for session in snapshot?.sessions ?? [] {
            if let worker = workers[session.id] {
                worker.setRobots(session.childCount)
                if case .desk = worker.place, !worker.busy, !worker.leaving {
                    worker.setHelpers(session.subagents, team: TeamColor.hoodie(session.kind), visible: true, skipWorkflow: hasWorkflowRoom(worker.floorIndex))
                }
                updateLabel(worker, session: session)
                if classSeatOf[session.id] != nil, session.state == .working || session.state == .waiting { finishReeducation(worker); continue }
                // 감사 실행 연출이 붙잡은 직원(교육생 · 퇴출 줄 · 책상으로 돌아가는 중)은 연출이 놓아줄 때까지 그대로 둔다.
                guard !worker.busy, !worker.leaving, auditHeld[session.id] == nil else { continue }
                let target = targetPlace(session)
                if Self.sameSpot(target.place, worker.place), abs(target.x - worker.vx) <= 1, target.floor != worker.floorIndex, worker.route == nil {
                    // 층이 늘어 옥상 층 번호만 바뀐 경우: 직원은 그대로, 위치만 맞춘다.
                    place(worker, floor: target.floor, x: target.x)
                    worker.place = target.place
                    settle(worker)
                } else if target.place != worker.place || target.floor != worker.floorIndex || abs(target.x - worker.vx) > 1 {
                    // 이미 그곳으로 가는 중이면 그대로 둔다. 2초마다 처음부터 다시 출발시키면 남은 길을 처음 길이만큼의 시간에 걸어
                    // 다음 스냅샷 전에 끝나지 못하고(제논의 역설), 엘리베이터 문 앞에 영영 서 있게 된다.
                    if !isHeading(worker, to: target) {
                        travel(worker, toFloor: target.floor, x: target.x, place: target.place) { [weak self, weak worker] in
                            guard let self, let worker else { return }
                            worker.place = target.place
                            self.settle(worker)
                        }
                    }
                } else {
                    settle(worker)
                }
            } else {
                let worker = makeWorker(session)
                let target = targetPlace(session)
                place(worker, floor: target.floor, x: target.x)
                worker.place = target.place
                settle(worker)
            }
        }
        for (key, worker) in workers where sessions[key] == nil && !worker.leaving && !worker.busy {
            depart(worker)
        }
        updateMonitors()
        refreshTitleBubbles()
    }

    private func makeWorker(_ session: AgentSession) -> WorkerNode {
        let worker = WorkerNode(key: session.id, look: Self.look(for: session).aged(Date().timeIntervalSince(session.startTime)))
        worker.zPosition = 5
        world.addChild(worker)
        workers[session.id] = worker
        worker.setRobots(session.childCount)
        let label = TextBadge("", style: .tiny)
        overlay.addChild(label)
        labels[session.id] = label
        updateLabel(worker, session: session)
        return worker
    }

    private func updateLabel(_ worker: WorkerNode, session: AgentSession) {
        let kind = session.kind == .claudeCode ? "Claude" : session.kind == .codexCLI ? "Codex" : session.kind.label
        let age = Date().timeIntervalSince(session.startTime)
        let runtime = Self.shortAge(age)
        // 퇴근 못 한 날이 쌓이면 몰골이 바뀐다(하루: 까칠, 사흘: 덥수룩).
        let aged = Self.look(for: session).aged(age)
        if aged != worker.look { worker.look = aged; if !worker.busy && !worker.leaving { settle(worker) } }
        let away: Bool = { if case .rest = worker.place { return true } else { return false } }()
        // 쉬는 직원은 선베드·해먹이 붙어 있어 이름표가 겹친다 → 'zZ'만 보이고, 누르면 상세 카드에서 확인한다.
        // 전체 보기에서도 이름표는 숨긴다(방으로 다가가면 보인다).
        labels[session.id]?.isHidden = ((away || !(lodZoomed ?? false)) && selected != session.id) || offFocusFloor(worker)
        let helpers = session.activeSubagents > 0 ? " · 하위 \(session.activeSubagents)" : ""
        labels[session.id]?.set(away ? "\(String(session.project.prefix(9))) \(runtime)" : "\(kind) \(runtime)\(helpers)")
    }

    private struct Target { var place: WorkerNode.Place; var floor: Int; var x: CGFloat }

    /// 쉬는 자리는 종류·x로 같은지 본다(층 번호는 건물 높이에 따라 바뀔 수 있다).
    static func sameSpot(_ lhs: WorkerNode.Place, _ rhs: WorkerNode.Place) -> Bool {
        if case .rest(let a) = lhs, case .rest(let b) = rhs { return a.kind == b.kind && a.x == b.x }
        return false
    }

    /// 같은 목적지(층 종류 · x · 자리)로 지금 이동 중인가.
    private func isHeading(_ worker: WorkerNode, to target: Target) -> Bool {
        guard let route = worker.route, worker.action(forKey: "move") != nil, layout.floors.indices.contains(target.floor),
              route.floor == layout.floors[target.floor].kind, abs(route.x - target.x) <= 1, let place = route.place else { return false }
        return place == target.place || Self.sameSpot(place, target.place)
    }

    /// 이름표용 짧은 실행 시간: 21분 · 3시간 · 6일.
    static func shortAge(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<3600: return "\(Int(seconds / 60))분"
        case ..<86_400: return "\(Int(seconds / 3600))시간"
        default: return "\(Int(seconds / 86_400))일"
        }
    }

    /// 상태 → 자리: 일하는 중·기다림·고아 = 책상, 쉼 = 라이브러리, 오래 쉼 = 옥상(자리가 차면 책상에서 존다).
    private func targetPlace(_ session: AgentSession) -> Target {
        let desk = layout.desks[session.id]
        let deskTarget = desk.map { Target(place: .desk, floor: $0.floor, x: CGFloat($0.seatX)) } ?? Target(place: .lobby, floor: 1, x: 120)
        switch session.state {
        case .idle:
            hallSeatOf[session.id] = nil
            // 놀이 자리: 비어 있는 곳 중 무작위, 25~60초마다 바꾼다. 다 차면 책상에서 존다.
            if let seat = playSeats[session.id] { return Target(place: .rest(seat.spot), floor: seat.spot.floor, x: CGFloat(seat.spot.x)) }
            let taken = Set(playSeats.filter { sessions[$0.key] != nil && $0.key != session.id }.map { "\($0.value.spot.kind)-\($0.value.spot.x)" })
            let free = layout.playSpots.filter { !taken.contains("\($0.kind)-\($0.x)") }
            // DJ 파티 중이면 옥상(풀 · 선베드 · 빈백) 빈자리부터 — 다른 층에서 쉬던 직원도 자리를 옮길 때 파티로 올라온다.
            let roofFree = partyPlaying ? free.filter { Self.isPartySpot($0, roof: layout.roofIndex) } : []
            guard let spot = Variety.shared.element(roofFree.isEmpty ? free : roofFree) else { return deskTarget }
            playSeats[session.id] = (spot, lastFrameTime + Variety.shared.seconds(25...60))
            return Target(place: .rest(spot), floor: spot.floor, x: CGFloat(spot.x))
        case .longIdle, .orphan:
            playSeats[session.id] = nil
            let seats = layout.hallSeats
            var index = hallSeatOf[session.id]
            if index == nil {
                let taken = Set(hallSeatOf.filter { sessions[$0.key] != nil && $0.key != session.id }.map(\.value))
                index = (0..<seats.count).first { !taken.contains($0) }
            }
            guard let index, index < seats.count else { hallSeatOf[session.id] = nil; return deskTarget }
            hallSeatOf[session.id] = index
            let spot = seats[index]
            return Target(place: .rest(spot), floor: spot.floor, x: CGFloat(spot.x))
        default:
            playSeats[session.id] = nil
            hallSeatOf[session.id] = nil
            return deskTarget
        }
    }

    private func place(_ worker: WorkerNode, floor: Int, x: CGFloat, yOffset: CGFloat = 0) {
        worker.floorIndex = clampFloor(floor)
        worker.vx = x
        worker.position = CGPoint(x: x, y: line(floor) + yOffset)
    }

    /// 자리에 도착한 직원의 자세·말풍선. 걷는 중이면 건드리지 않는다(도착하면 이동이 직접 부른다).
    /// 자리 좌표(x = vx, y = 그 층 바닥)도 다시 맞춘다 — 끊긴 걸음 때문에 보이는 위치가 자리와 어긋난 채 남지 않게.
    func settle(_ worker: WorkerNode) {
        guard let session = sessions[worker.key], worker.route == nil || worker.action(forKey: "move") == nil else { return }
        worker.route = nil
        worker.clearGhost()
        worker.sprite.zRotation = 0
        var bubble: String?
        var bubbleStyle: TextBadge.Style?
        switch worker.place {
        case .desk:
            worker.face(right: true)
            worker.position = CGPoint(x: worker.vx, y: line(worker.floorIndex))
            arrangeRobotsAtDesk(worker)
            worker.setHelpers(session.subagents, team: TeamColor.hoodie(session.kind), visible: true, skipWorkflow: hasWorkflowRoom(worker.floorIndex))
            switch session.state {
            case .working: worker.loop([.sitType(0), .sitType(1)], fps: session.cpuPercent >= 50 ? 10 : 4)
            case .waiting: worker.show(.sitWait); bubble = "입력 필요"
            case .orphan: worker.showGhost(); bubble = nil
            case .idle, .longIdle: worker.loop([.sleepDesk(0), .sleepDesk(1)], fps: 1.2); bubble = "zZ"
            }
        case .rest(let spot):
            worker.setRobotsVisible(false)
            worker.setHelpers([], team: .clear, visible: false)
            worker.position = CGPoint(x: worker.vx, y: line(worker.floorIndex) + CGFloat(spot.yOffset))
            worker.zPosition = spot.row == 1 ? 4 : 5
            if partyDance(worker, spot: spot) {
                // DJ 파티 중인 옥상 놀이 자리(Rooftop.swift): 춤. 외치던 말은 스냅샷마다 지우지 않는다.
                (bubble, bubbleStyle) = keptSay(worker)
            } else {
                switch spot.kind {
                case .hammock, .lounger, .beanbag: worker.show(.lie); bubble = Variety.shared.chance(0.5) ? "zZ" : nil
                case .swim:
                    worker.face(right: Variety.shared.chance(0.5)); worker.loop([.swim(0), .swim(1)], fps: 2.5); bubble = nil
                    if Season.current == .winter { (bubble, bubbleStyle) = keptSay(worker) }   // 겨울 온수풀 '따뜻해~'는 끝까지 말한다
                case .reading: worker.face(right: spot.x < 560); worker.loop([.read(0), .read(1)], fps: 0.6); bubble = nil
                case .hallSeat:
                    worker.face(right: false)
                    if session.state == .orphan { worker.showGhost() } else { worker.show(.sitSad) }
                    bubble = nil
                case .classSeat: worker.face(right: true); worker.show(.sitWait); bubble = nil   // 교육실 의자는 책상(오른쪽) · 강사 쪽을 본다
                default: worker.face(right: spot.x < 560); worker.show(.sitWait)
                }
            }
        default:
            worker.show(.stand(blink: false))
        }
        setBubble(worker.key, bubble, style: bubbleStyle ?? (bubble == "입력 필요" ? .bubble : .tiny))
        updateLabel(worker, session: session)
    }

    private func arrangeRobotsAtDesk(_ worker: WorkerNode) {
        worker.setRobotsVisible(true)
        // 책상 간격(50px) 안에 두 대까지만 보인다. 나머지 수는 이름표·상세 카드에서.
        for (i, robot) in worker.robots.enumerated() {
            robot.position = CGPoint(x: 31 + CGFloat(i) * 7, y: 0)
            robot.isHidden = i >= 2
        }
    }

    func setBubble(_ key: ProcessKey, _ text: String?, style: TextBadge.Style = .bubble) {
        if let text {
            if let bubble = bubbles[key], bubble.style == style {
                bubble.set(text)
            } else {
                bubbles[key]?.removeFromParent()
                let bubble = TextBadge(text, style: style)
                overlay.addChild(bubble)
                bubbles[key] = bubble
            }
            if let worker = workers[key] {
                bubbles[key]?.position = bubblePoint(worker)
                bubbles[key]?.isHidden = offFocusFloor(worker)
            }
        } else {
            bubbles[key]?.removeFromParent()
            bubbles[key] = nil
        }
    }

    // MARK: 이동

    /// 진행 중인 연출이 옛 층 번호를 들고 있어도(퇴근으로 층이 줄어든 경우) 안전하게 현재 범위로 제한한다.
    private func clampFloor(_ index: Int) -> Int { min(max(0, index), layout.floors.count - 1) }
    func line(_ index: Int) -> CGFloat { CGFloat(layout.floors[clampFloor(index)].floorLine) }

    /// start → x 걷기. 시간은 실제 남은 거리로 잰다(끊긴 걸음의 옛 출발점 vx로 재면 같은 길을 처음 길이만큼 다시 걷는다).
    private func walkAction(_ worker: WorkerNode, from start: CGFloat, to x: CGFloat) -> SKAction {
        let distance = abs(x - start)
        guard distance > 0.5 else { return .sequence([.moveTo(x: x, duration: 0), .run { [weak worker] in worker?.vx = x }]) }
        let right = x > start
        return .sequence([
            .run { [weak worker] in
                guard let worker else { return }
                worker.face(right: right)
                worker.loop([.walk(0), .walk(1), .walk(2), .walk(3)], fps: 8)
                for (i, robot) in worker.robots.enumerated() { robot.position = CGPoint(x: (right ? -1 : 1) * (14 + CGFloat(i) * 9), y: 0) }
                worker.setRobotsVisible(true)
            },
            .moveTo(x: x, duration: TimeInterval(distance / 44)),
            .run { [weak worker] in worker?.vx = x }
        ])
    }

    /// 같은 층이면 걷고, 다른 층이면 엘리베이터(문 열림 → 사라짐 → 이동 시간 → 다른 층에서 나타남).
    /// 걷기·타기·내려서 걷기·도착이 한 묶음("move")이라, 다시 부르거나 멈추면 남는 동작 없이 함께 끊긴다.
    /// 도착 층은 층 종류로 기억했다가 내릴 때 다시 찾는다(타는 동안 층이 늘거나 줄어 옥상 번호가 바뀌어도 맞는 층에 내린다).
    private func travel(_ worker: WorkerNode, toFloor floor: Int, x: CGFloat, place: WorkerNode.Place? = nil, completion: @escaping () -> Void) {
        worker.removeAction(forKey: "move")
        setBubble(worker.key, nil)
        let destination = clampFloor(floor)
        let kind = layout.floors[destination].kind
        worker.route = WorkerNode.Route(floor: kind, x: x, place: place)
        let start = worker.position.x
        worker.vx = start
        var steps: [SKAction] = []
        // 타는 도중(사라진 채)에 끊겼다면 먼저 다시 보이게 한다.
        if worker.alpha < 1 { steps.append(.fadeIn(withDuration: 0.15)) }
        // 높이가 있는 자리(강당 뒷줄 +12 · 해먹 +40 · 선베드 +5)에서 일어나면 먼저 바닥으로 내려선다 — 공중을 걸어가지 않게.
        let floorY = line(worker.floorIndex)
        if abs(worker.position.y - floorY) > 0.5 { steps.append(.moveTo(y: floorY, duration: 0.15)) }
        if worker.floorIndex == destination {
            steps.append(walkAction(worker, from: start, to: x))
        } else {
            let from = worker.floorIndex
            let shaft = CGFloat(BuildingLayout.elevatorX)
            steps.append(walkAction(worker, from: start, to: shaft))
            steps.append(.run { [weak self] in self?.openElevator(from) })
            steps.append(.wait(forDuration: 0.25))
            steps.append(.fadeOut(withDuration: 0.2))
            steps.append(.wait(forDuration: 0.35 * Double(abs(destination - from)) + 0.2))
            steps.append(.run { [weak self, weak worker] in
                guard let self, let worker else { return }
                let arrival = self.layout.floors.firstIndex { $0.kind == kind } ?? self.clampFloor(destination)
                self.place(worker, floor: arrival, x: shaft)
                self.openElevator(arrival)
            })
            steps.append(.fadeIn(withDuration: 0.2))
            steps.append(walkAction(worker, from: shaft, to: x))
        }
        steps.append(.run { [weak worker] in worker?.route = nil })
        steps.append(.run(completion))
        worker.run(.sequence(steps), withKey: "move")
    }

    /// 가던 길을 그 자리에서 멈춘다(퇴근·쫓겨남·안전망). 사라진 채였다면 다시 보이게 한다.
    private func stopTravel(_ worker: WorkerNode) {
        worker.removeAction(forKey: "move")
        worker.route = nil
        worker.vx = worker.position.x
        worker.alpha = 1
    }

    // MARK: 층 변화 · 안전망

    /// 팀 층이 늘거나 줄면 옥상(과 맨 위층)의 번호·높이가 바뀐다. 층 종류로 새 번호를 찾아 사람의 층 번호·높이·쉬는 자리를 옮긴다.
    /// (예전: 옥상에서 걷던 직원이 옛 옥상 높이에 그대로 남아, 한 층 내려앉은 옥상 위 하늘에 떠 있었다.)
    private func remapFloors(from old: BuildingLayout) {
        func mapped(_ index: Int) -> Int? {
            guard old.floors.indices.contains(index) else { return nil }
            return layout.floors.firstIndex { $0.kind == old.floors[index].kind }
        }
        for worker in workers.values {
            let before = worker.floorIndex
            let after = mapped(before) ?? clampFloor(before)
            if old.floors.indices.contains(before) { worker.position.y += line(after) - CGFloat(old.floors[before].floorLine) }
            worker.floorIndex = after
            if case .rest(var spot) = worker.place, let index = mapped(spot.floor) {
                spot.floor = index
                worker.place = .rest(spot)
            }
        }
        for (key, seat) in playSeats {
            guard let index = mapped(seat.spot.floor) else { playSeats[key] = nil; continue }
            var spot = seat.spot
            spot.floor = index
            playSeats[key] = (spot, seat.until)
        }
    }

    /// 안전망(1초마다, 장면이 실제로 돈 시간 기준): 끊긴 연출 때문에 이상한 곳에 남은 직원을 바로잡는다.
    /// 없는 층 · 건물이나 자기 층 높이 밖 · 엘리베이터 칸에 8초 넘게 → 제자리로 다시 앉힌다. 퇴근이 60초 넘게 안 끝나면 내보낸다.
    private func auditWorkers() {
        let shaft = CGFloat(BuildingLayout.elevatorX)
        for worker in Array(workers.values) {
            if worker.leaving {
                let since = worker.leavingSince ?? activeTime
                worker.leavingSince = since
                if activeTime - since > 60 { fixed(worker, "퇴근이 끝나지 않음"); remove(worker) }
                continue
            }
            if abs(worker.position.x - shaft) <= 6 { worker.shaftSince = worker.shaftSince ?? activeTime } else { worker.shaftSince = nil }
            var problem: String?
            if !layout.floors.indices.contains(worker.floorIndex) {
                problem = "없는 층 \(worker.floorIndex)"
            } else {
                let floor = layout.floors[worker.floorIndex]
                let point = worker.position
                if point.x < 0 || point.x > CGFloat(BuildingLayout.width) || point.y < CGFloat(floor.y) - 1 || point.y > CGFloat(floor.y + floor.height) {
                    problem = "층 밖 (\(Int(point.x)), \(Int(point.y)))"
                } else if let since = worker.shaftSince, activeTime - since > 8 {
                    problem = "엘리베이터 칸 \(Int(activeTime - since))초"
                }
            }
            guard let problem else { continue }
            fixed(worker, problem)
            reseat(worker)
        }
    }

    /// 연출을 모두 끊고 지금 상태의 자리에 바로 앉힌다. 세션이 없으면 내보낸다.
    private func reseat(_ worker: WorkerNode) {
        worker.removeAllActions()
        stopTravel(worker)
        worker.shaftSince = nil
        worker.setScale(1)
        worker.zRotation = 0
        worker.busy = false
        classSeatOf[worker.key] = nil
        auditHeld[worker.key] = nil
        guard let session = sessions[worker.key] else { remove(worker); return }
        let target = targetPlace(session)
        place(worker, floor: target.floor, x: target.x)
        worker.place = target.place
        settle(worker)
    }

    private func fixed(_ worker: WorkerNode, _ reason: String) {
        let text = "pid \(worker.key.pid) · \(reason)"
        safetyFixes.append(text)
        if ProcessInfo.processInfo.environment["REMON_DEBUG_WORKERS"] == "1" { FileHandle.standardError.write(Data("[safety] \(text)\n".utf8)) }
    }

    private func openElevator(_ floor: Int) {
        guard let door = elevatorDoors[floor] else { return }
        let open = (0...2).map { elevatorTexture(Double($0) / 2) }
        door.removeAllActions()
        door.run(.sequence([.animate(with: open, timePerFrame: 0.08), .wait(forDuration: 0.7), .animate(with: open.reversed(), timePerFrame: 0.08)]))
    }

    private func elevatorTexture(_ open: Double) -> SKTexture {
        TextureCache.shared.texture("elev\(open)") { Furniture.elevatorDoor(open: open) }
    }

    func door(_ state: Int) -> SKTexture {
        TextureCache.shared.texture("door\(state)") { Furniture.entranceDoor(state) }
    }

    // MARK: 연출 — 출근

    private func arrive(_ session: AgentSession) {
        onArrival?(session)
        let worker = makeWorker(session)
        if session.isEphemeral {
            // 보조 호출: 문을 박차지 않고 자리에 살짝 나타난다(자동 줌·대사 없음).
            let target = targetPlace(session)
            place(worker, floor: target.floor, x: target.x)
            worker.place = target.place
            worker.alpha = 0
            settle(worker)
            worker.run(.fadeIn(withDuration: 0.4))
            return
        }
        requestShot(Shot(target: .follow(worker, zoom: 2.6), caption: "출근 · \(session.project) · \(session.kind.shortLabel)", duration: 8, priority: 1))
        worker.busy = true
        let doorCenter = CGFloat(BuildingLayout.doorX)
        place(worker, floor: 1, x: doorCenter)
        worker.alpha = 0
        worker.setRobotsVisible(false)
        worker.face(right: true)
        let doorPoint = CGPoint(x: doorCenter, y: CGFloat(layout.floors[1].floorLine + 18))
        // 매번 다르게: 0 문 발차기 · 1 살금살금 · 2 지각 전력질주
        let variant = Variety.shared.pick("arrive", 3)
        if variant == 1 {
            worker.show(.stand(blink: false))
            worker.run(.sequence([
                .run { [weak self] in self?.doorNode.texture = self?.door(1) },
                .wait(forDuration: 0.4),
                .fadeIn(withDuration: 0.3),
                .run { [weak self, weak worker] in
                    guard let self, let worker else { return }
                    self.setBubble(worker.key, Variety.shared.line("sneak", Lines.arriveSneak), style: .bubble)
                },
                .wait(forDuration: 0.9),
                .run { [weak self, weak worker] in
                    guard let self, let worker, !worker.leaving else { return }
                    self.setBubble(worker.key, nil)
                    self.doorNode.run(.sequence([.wait(forDuration: 1.0), .setTexture(self.door(0))]))
                    worker.setRobotsVisible(true)
                    let target = self.targetPlace(self.sessions[worker.key] ?? session)
                    self.travel(worker, toFloor: target.floor, x: target.x, place: target.place) { [weak self, weak worker] in
                        guard let self, let worker else { return }
                        worker.busy = false
                        worker.place = target.place
                        self.settle(worker)
                    }
                }
            ]))
            return
        }
        worker.show(.kick(0))
        worker.run(.sequence([
            .fadeIn(withDuration: 0.05),
            .wait(forDuration: variant == 2 ? 0.08 : 0.2),
            .run { [weak self, weak worker] in
                guard let self, let worker else { return }
                worker.show(.kick(1))
                self.doorNode.texture = self.door(2)
                self.doorNode.run(.sequence([.moveBy(x: -1, y: 0, duration: 0.04), .moveBy(x: 2, y: 0, duration: 0.04), .moveBy(x: -1, y: 0, duration: 0.04)]))
                Effects.burst(in: self.world, at: doorPoint, color: PixelColor(0xE9DFCF), count: variant == 2 ? 18 : 12, spread: 16, rise: 12, duration: 0.6)
                self.setBubble(worker.key, Variety.shared.line("arrive", variant == 2 ? Lines.arriveDash : Lines.arrive), style: .shout)
            },
            .wait(forDuration: variant == 2 ? 0.45 : 0.7),
            .run { [weak self, weak worker] in
                guard let self, let worker else { return }
                self.doorNode.texture = self.door(1)
                worker.setRobotsVisible(true)
                worker.show(.stand(blink: false))
            },
            .wait(forDuration: 0.35),
            .run { [weak self, weak worker] in
                // 출근 연출 도중에 이미 퇴근이 시작됐으면(짧은 세션) 자리로 보내지 않는다 — 퇴근 길을 덮어쓰지 않게.
                guard let self, let worker, !worker.leaving else { return }
                self.setBubble(worker.key, nil)
                self.doorNode.run(.sequence([.wait(forDuration: 1.2), .setTexture(self.door(0))]))
                let target = self.targetPlace(self.sessions[worker.key] ?? session)
                self.travel(worker, toFloor: target.floor, x: target.x, place: target.place) { [weak self, weak worker] in
                    guard let self, let worker else { return }
                    worker.busy = false
                    worker.place = target.place
                    self.settle(worker)
                }
            }
        ]))
    }

    // MARK: 연출 — 퇴근

    private func depart(_ worker: WorkerNode) {
        worker.leaving = true
        worker.busy = true
        worker.leavingSince = activeTime
        worker.clearGhost()
        // 걷던 중이면 그 자리에 멈춰 인사하고 나간다(가던 길이 퇴근 길과 겹쳐 돌지 않게).
        stopTravel(worker)
        if lastEphemeral.contains(worker.key) {
            worker.run(.sequence([.fadeOut(withDuration: 0.4), .run { [weak self, weak worker] in
                guard let self, let worker else { return }
                self.remove(worker)
            }]))
            return
        }
        worker.zPosition = 5
        playSeats[worker.key] = nil
        hallSeatOf[worker.key] = nil
        // 매번 다르게: 손 흔들기 · 칼퇴 춤
        let dance = Variety.shared.pick("depart", 2) == 1
        setBubble(worker.key, Variety.shared.line("depart", dance ? Lines.departDance : Lines.depart), style: .bubble)
        if dance { worker.loop([.jumpingJack(0), .jumpingJack(1)], fps: 5) } else { worker.loop([.wave(0), .wave(1)], fps: 4) }
        worker.run(.sequence([
            .wait(forDuration: dance ? 1.4 : 1.0),
            .run { [weak self, weak worker] in
                guard let self, let worker else { return }
                self.setBubble(worker.key, nil)
                self.travel(worker, toFloor: 1, x: CGFloat(BuildingLayout.doorX)) { [weak self, weak worker] in
                    guard let self, let worker else { return }
                    self.doorNode.texture = self.door(1)
                    worker.show(.stand(blink: false))
                    worker.run(.sequence([.group([.fadeOut(withDuration: 0.5), .moveBy(x: 0, y: 4, duration: 0.5), .scale(to: 0.85, duration: 0.5)]),
                                          .run { [weak self] in self?.doorNode.texture = self?.door(0); self?.remove(worker) }]))
                }
            }
        ]))
    }

    private func remove(_ worker: WorkerNode) {
        worker.removeFromParent()
        workers[worker.key] = nil
        playSeats[worker.key] = nil
        hallSeatOf[worker.key] = nil
        classSeatOf[worker.key] = nil
        auditHeld[worker.key] = nil
        evictQueue.removeAll { $0 == worker.key }
        titleBubbles[worker.key]?.removeFromParent(); titleBubbles[worker.key] = nil
        labels[worker.key]?.removeFromParent(); labels[worker.key] = nil
        bubbles[worker.key]?.removeFromParent(); bubbles[worker.key] = nil
        monitors[worker.key]?.removeFromParent(); monitors[worker.key] = nil
        memoryBars[worker.key]?.removeFromParent(); memoryBars[worker.key] = nil
        if selected == worker.key { selected = nil; onSelect?(nil) }
    }

    // MARK: 연출 — 종료 전 소리침 · 경비원 퇴출

    /// 확인 창이 떠 있는 동안: 직원이 일어나 종료하면 안 되는 이유를 외친다.
    func shout(_ key: ProcessKey, reason: String) {
        guard let worker = workers[key], !worker.leaving else { return }
        requestShot(Shot(target: .rect(rectAround(worker)), caption: "종료하면 안 돼요 · \(reason)", duration: 4, priority: 2))
        worker.busy = true
        worker.zPosition = 6
        worker.clearGhost()
        worker.loop([.shout(0), .shout(1)], fps: 5)
        setBubble(key, reason, style: .shout)
    }

    func calmDown(_ key: ProcessKey) {
        guard let worker = workers[key], !worker.leaving else { return }
        worker.busy = false
        setBubble(key, nil)
        settle(worker)
    }

    /// 경비원이 끌고 나갈 차례를 기다리는 직원(감사 퇴출처럼 여럿이 한꺼번에). 경비원은 한 명씩 끌고 나가고, 다음 사람에게 바로 간다.
    private var evictQueue: [ProcessKey] = []
    private var guardDragging = false

    /// 강제 종료(쫓아내기): 경비원이 와서 끌고 나가 문 밖으로 내보낸다. 경비원이 다른 직원을 끌고 가는 중이면 소리치며 차례를 기다린다.
    /// camera: 자동 줌을 요청할지(감사 퇴출처럼 이미 강당을 비추는 연출은 끈다).
    func evict(_ worker: WorkerNode, shout: String?, camera: Bool = true) {
        guard !worker.leaving else { return }
        let project = sessions[worker.key]?.project ?? "세션"
        if camera { requestShot(Shot(target: .follow(worker, zoom: 2.6), caption: "퇴출 · \(project) · 경비원 출동" + (shout.map { " · \"\($0)\"" } ?? ""), duration: 12, priority: 3)) }
        worker.leaving = true
        worker.busy = true
        worker.leavingSince = activeTime
        worker.clearGhost()
        stopTravel(worker)
        worker.loop([.shout(0), .shout(1)], fps: 6)
        setBubble(worker.key, shout ?? "으악! 잠깐만요!", style: .shout)
        if guardDragging {
            evictQueue.append(worker.key)
            return
        }
        guardDrag(worker)
    }

    private func guardDrag(_ worker: WorkerNode) {
        guardDragging = true
        guardNode.removeAction(forKey: "patrolWalk")
        guardNode.removeAction(forKey: "guardWait")
        guardBusy = true
        // 퇴근 시한(안전망 60초)은 끌려가기 시작할 때부터 잰다(차례를 기다린 시간은 빼고).
        worker.leavingSince = activeTime
        for key in evictQueue { workers[key]?.leavingSince = activeTime }
        let targetFloor = worker.floorIndex
        let targetX = worker.position.x - 12
        moveGuard(toFloor: targetFloor, x: targetX) { [weak self, weak worker] in
            guard let self else { return }
            guard let worker, worker.parent != nil else { self.guardNext(); return }
            // 끌고 가기: 경비원과 직원이 함께 이동
            self.setGuard(.dragged(0), faceRight: false)
            worker.loop([.dragged(0), .dragged(1)], fps: 6)
            worker.face(right: true)
            let path = self.dragPath(worker: worker, from: targetFloor)
            worker.run(path) { [weak self, weak worker] in
                guard let self, let worker else { return }
                self.doorNode.texture = self.door(2)
                Effects.burst(in: self.world, at: CGPoint(x: CGFloat(BuildingLayout.doorX), y: CGFloat(self.layout.floors[1].floorLine + 14)), color: PixelColor(0xE9DFCF), count: 14, spread: 18, rise: 14, duration: 0.7)
                self.setBubble(worker.key, nil)
                worker.run(.sequence([
                    .group([.moveBy(x: -6, y: 16, duration: 0.35), .rotate(byAngle: .pi * 1.5, duration: 0.35), .fadeOut(withDuration: 0.4), .scale(to: 0.6, duration: 0.35)]),
                    .run { [weak self] in
                        guard let self else { return }
                        self.doorNode.texture = self.door(0)
                        self.remove(worker)
                        self.guardNext()
                    }
                ]))
            }
        }
    }

    /// 한 명을 내보낸 뒤: 차례를 기다리는 직원이 있으면 바로 끌러 가고, 없으면 손을 흔들고 초소로 돌아간다.
    private func guardNext() {
        setGuard(.wave(0), faceRight: true)
        while let key = evictQueue.first {
            evictQueue.removeFirst()
            guard let next = workers[key], next.leaving, next.parent != nil else { continue }
            guardNode.run(.sequence([.wait(forDuration: 0.4), .run { [weak self] in self?.guardDrag(next) }]), withKey: "guardWait")
            return
        }
        guardDragging = false
        let post = CGFloat(BuildingLayout.guardPostX)
        guardNode.run(.sequence([.wait(forDuration: 0.6), .run { [weak self] in
            guard let self, !self.guardDragging else { return }
            self.moveGuard(toFloor: 1, x: post) { [weak self] in
                guard let self, !self.guardDragging else { return }
                self.guardBusy = false
                self.setGuard(.stand(blink: false))
            }
        }]), withKey: "guardWait")
    }

    /// 직원 이동 경로(엘리베이터 포함)를 경비원이 그대로 따라오게 한다.
    private func dragPath(worker: WorkerNode, from floor: Int) -> SKAction {
        let door = CGFloat(BuildingLayout.doorX) + 4
        let shaft = CGFloat(BuildingLayout.elevatorX)
        var steps: [SKAction] = []
        func follow(_ duration: TimeInterval, toX x: CGFloat) -> SKAction {
            .group([.moveTo(x: x, duration: duration), .run { [weak self] in self?.guardNode.run(.moveTo(x: x - 13, duration: duration)) }])
        }
        if floor != 1 {
            steps.append(follow(TimeInterval(abs(worker.position.x - shaft) / 34), toX: shaft))
            steps.append(.run { [weak self] in self?.openElevator(floor); self?.guardNode.run(.fadeOut(withDuration: 0.2)) })
            steps.append(.fadeOut(withDuration: 0.2))
            steps.append(.wait(forDuration: 0.35 * Double(abs(floor - 1)) + 0.2))
            steps.append(.run { [weak self, weak worker] in
                guard let self, let worker else { return }
                self.place(worker, floor: 1, x: shaft)
                self.guardNode.position = CGPoint(x: shaft - 13, y: self.line(1))
                self.openElevator(1)
                self.guardNode.run(.fadeIn(withDuration: 0.2))
            })
            steps.append(.fadeIn(withDuration: 0.2))
            steps.append(follow(TimeInterval(abs(door - shaft) / 34), toX: door))
        } else {
            steps.append(follow(TimeInterval(abs(worker.position.x - door) / 34), toX: door))
        }
        return .sequence(steps)
    }

    /// 지금 서 있는 층(바닥선 기준). 연출이 끊겨 바닥선에 딱 맞지 않으면 가장 가까운 층.
    private func staffFloor(_ node: SKNode) -> Int {
        let y = node.position.y
        if let exact = layout.floors.firstIndex(where: { abs(CGFloat($0.floorLine) - y) < 0.5 }) { return exact }
        return layout.floors.indices.min { abs(CGFloat(layout.floors[$0].floorLine) - y) < abs(CGFloat(layout.floors[$1].floorLine) - y) } ?? 1
    }

    /// 직원 노드(경비원 아님) 이동: 같은 층이면 걷고, 층이 다르면 엘리베이터. walk 프레임은 호출자가 준다.
    /// 출발 층은 노드의 실제 높이로 정한다(순찰·연출이 도중에 끊겨도 맞는 층에서 출발). 도착 층은 층 종류로 기억했다가 내릴 때 다시 찾는다.
    /// 엘리베이터 안(사라진 채)에서 끊겼으면 그대로 타고 가고, 다른 곳에서 사라진 채였으면 먼저 다시 보이게 한다.
    func staffTravel(_ node: SKSpriteNode, walk: [SKTexture], stand: SKTexture, toFloor floor: Int, x: CGFloat, speed: CGFloat = 50, completion: @escaping () -> Void) {
        let shaft = CGFloat(BuildingLayout.elevatorX)
        let fromFloor = staffFloor(node)
        let destination = clampFloor(floor)
        let kind = layout.floors[destination].kind
        node.removeAction(forKey: "pose")
        func walkStep(to target: CGFloat, from start: CGFloat) -> SKAction {
            let distance = abs(target - start)
            return .sequence([
                .run { node.xScale = target >= start ? 1 : -1 },
                .group([.moveTo(x: target, duration: TimeInterval(max(0.05, distance / speed))),
                        .repeat(.animate(with: walk, timePerFrame: 0.12, resize: true, restore: false), count: max(1, Int(distance / speed / 0.48)))]),
                .setTexture(stand, resize: true)
            ])
        }
        var steps: [SKAction] = []
        let hidden = node.alpha < 0.99
        if fromFloor != destination {
            if hidden && abs(node.position.x - shaft) < 2 {
                steps.append(.fadeAlpha(to: 0, duration: 0))
            } else {
                if hidden { steps.append(.fadeIn(withDuration: 0.15)) }
                steps.append(walkStep(to: shaft, from: node.position.x))
                steps.append(.run { [weak self] in self?.openElevator(fromFloor) })
                steps.append(.fadeOut(withDuration: 0.15))
            }
            steps.append(.wait(forDuration: 0.3 * Double(abs(destination - fromFloor)) + 0.15))
            steps.append(.run { [weak self] in
                guard let self else { return }
                let arrival = self.layout.floors.firstIndex { $0.kind == kind } ?? self.clampFloor(destination)
                node.position = CGPoint(x: shaft, y: self.line(arrival))
                self.openElevator(arrival)
            })
            steps.append(.fadeIn(withDuration: 0.15))
            steps.append(walkStep(to: x, from: shaft))
        } else {
            if hidden { steps.append(.fadeIn(withDuration: 0.15)) }
            steps.append(walkStep(to: x, from: node.position.x))
        }
        steps.append(.run { node.xScale = 1 })
        steps.append(.run(completion))
        node.run(.sequence(steps), withKey: "travel")
    }

    /// 경비원 이동(한 번에 하나: "guardMove" 키라 새 이동이 옛 이동을 대신한다 — 두 이동이 겹쳐 위치를 다투지 않게).
    func moveGuard(toFloor floor: Int, x: CGFloat, completion: @escaping () -> Void) {
        let currentFloor = layout.floors.firstIndex { CGFloat($0.floorLine) == guardNode.position.y } ?? 1
        let shaft = CGFloat(BuildingLayout.elevatorX)
        var steps: [SKAction] = []
        // 엘리베이터 안(사라진 채)에서 끊겼으면 먼저 다시 보이게 한다.
        if guardNode.alpha < 0.99 { steps.append(.fadeIn(withDuration: 0.15)) }
        func walk(to target: CGFloat, from start: CGFloat) -> SKAction {
            .sequence([.run { [weak self] in self?.guardWalk(right: target > start) },
                       .moveTo(x: target, duration: TimeInterval(max(0.05, abs(target - start) / 60)))])
        }
        if currentFloor != floor {
            steps.append(walk(to: shaft, from: guardNode.position.x))
            steps.append(.run { [weak self] in self?.openElevator(currentFloor) })
            steps.append(.fadeOut(withDuration: 0.15))
            steps.append(.wait(forDuration: 0.3 * Double(abs(floor - currentFloor)) + 0.15))
            steps.append(.run { [weak self] in
                guard let self else { return }
                self.guardNode.position = CGPoint(x: shaft, y: self.line(floor))
                self.openElevator(floor)
            })
            steps.append(.fadeIn(withDuration: 0.15))
            steps.append(walk(to: x, from: shaft))
        } else {
            steps.append(walk(to: x, from: guardNode.position.x))
        }
        steps.append(.run(completion))
        guardNode.run(.sequence(steps), withKey: "guardMove")
    }

    func setGuard(_ pose: WorkerPose, faceRight: Bool = true) {
        guardNode.removeAction(forKey: "anim")
        let texture = TextureCache.shared.texture("guard\(pose)") { CharacterArt.guardSprite(pose) }
        guardNode.texture = texture
        guardNode.size = texture.size()
        guardNode.xScale = faceRight ? 1 : -1
    }

    func guardWalk(right: Bool) {
        let frames = (0..<4).map { i in TextureCache.shared.texture("guard\(WorkerPose.walk(i))") { CharacterArt.guardSprite(.walk(i)) } }
        guardNode.xScale = right ? 1 : -1
        guardNode.removeAction(forKey: "anim")
        guardNode.run(.repeatForever(.animate(with: frames, timePerFrame: 0.11, resize: true, restore: false)), withKey: "anim")
    }

    // MARK: 연출 — 트레이너 난입 · 실측 발표

    /// 실측을 외칠 자리: 기계실 RAM 탱크(x 148~182) 왼쪽 — CPU 엔진(40~126)과 탱크 사이에서 탱크를 본다.
    static let trainerTankX: CGFloat = 138
    /// 옥상 대기 자리.
    static let trainerRoofX: CGFloat = 612

    /// idle 옥상 대기 · visiting 난입 중 · toTank 실측을 들고 RAM 탱크로 가는 중 · atTank 외치는 중 · returning 옥상으로 돌아가는 중.
    private enum TrainerPhase { case idle, visiting, toTank, atTank, returning }
    private var trainerPhase: TrainerPhase = .idle
    /// 난입 호루라기(검수용으로 지금 글자를 읽는다).
    private var trainerWhistle: TextBadge?
    /// 앱이 잰 실제 효과: 외칠 한 줄 · 덧붙일 설명 · 바이트. 탱크 앞에서 다 말하면 비운다.
    private var trainerAnnouncement: (shout: String, detail: String, measured: UInt64)?

    private func trainerTexture(_ pose: WorkerPose) -> SKTexture { TextureCache.shared.texture("trainer\(pose)") { CharacterArt.trainerSprite(pose) } }
    private var trainerRunFrames: [SKTexture] { (0..<4).map { trainerTexture(.walk($0)) } }

    private func trainerIdle() {
        trainerNode.removeAllActions()
        let frames = [WorkerPose.wave(0), .wave(1), .stand(blink: false), .stand(blink: true)].map { trainerTexture($0) }
        trainerNode.texture = frames[2]
        trainerNode.size = frames[2].size()
        trainerNode.xScale = -1
        trainerNode.run(.repeatForever(.sequence([.animate(with: [frames[2], frames[3], frames[2]], timePerFrame: 0.6, resize: true, restore: false), .animate(with: [frames[0], frames[1], frames[0], frames[1]], timePerFrame: 0.3, resize: true, restore: false)])))
    }

    /// 트레이너 난입(메모리·프로세스 정리를 시작할 때). reclaimed는 정리할 세션 크기의 합 — 재기 전의 **예상**이다.
    /// 실제로 얼마나 비었는지는 앱이 십몇 초 뒤 다시 재서 trainerAnnounce(measured:text:)로 알린다. 그래서 여기서는 '예상'만 말하고
    /// 회수한 것처럼 상자를 내가지 않는다(10-25 대표 원칙 '은유가 사실을 앞서면 안 된다' — 예전엔 재기 전에 "정리 완료 · X 회수"를 외치고 상자를 날랐다).
    func trainerVisit(reclaimed: UInt64, text: String) {
        // 메모리 정리가 시작됐다: 곧 실측한 비운 스왑(porterUnload)이 올 수 있으니 창고의 스왑 감소 자동 운반을 잠시 미룬다(상자를 두 번 빼지 않게).
        warehouse.holdSwapDecrease()
        guard !trainerBusy else { return }
        trainerBusy = true
        trainerPhase = .visiting
        let estimate = reclaimed > 0 ? "예상 \(Fmt.gb(reclaimed)) 회수" : nil
        requestEventShot(Shot(target: .follow(trainerNode, zoom: 2.4), caption: "트레이너 난입 · \(text)" + (estimate.map { " · " + $0 } ?? ""), duration: 13, priority: 2))
        // 가장 붐비는 팀 층
        let counts = layout.teamFloorIndexes.map { index in (index, workers.values.filter { $0.floorIndex == index && $0.place == .desk && !$0.leaving }.count) }
        let floor = counts.max { $0.1 < $1.1 }?.0 ?? 2
        let shaft = CGFloat(BuildingLayout.elevatorX)
        let whistle = TextBadge("삐익! \(text)", style: .shout)
        overlay.addChild(whistle)
        trainerWhistle = whistle
        trainerNode.removeAllActions()
        let runFrames = trainerRunFrames
        let shoutFrames = (0..<2).map { trainerTexture(.shout($0)) }
        func follow() { whistle.position = CGPoint(x: trainerNode.position.x * pointsPerPixel, y: (trainerNode.position.y + 42) * pointsPerPixel) }
        follow()
        let roofFloor = layout.roofIndex
        trainerNode.run(.sequence([
            .animate(with: shoutFrames + shoutFrames, timePerFrame: 0.15, resize: true, restore: false),
            .run { [weak self] in self?.trainerNode.xScale = -1; self?.trainerNode.run(.repeatForever(.animate(with: runFrames, timePerFrame: 0.07, resize: true, restore: false)), withKey: "run") },
            .moveTo(x: shaft, duration: 1.4),
            .run { [weak self] in self?.openElevator(min(roofFloor, self?.layout.topTeamIndex ?? 2)) },
            .fadeOut(withDuration: 0.15),
            .wait(forDuration: 0.5),
            .run { [weak self] in
                guard let self else { return }
                self.trainerNode.position = CGPoint(x: shaft, y: self.line(floor))
                self.openElevator(floor)
                self.trainerNode.xScale = 1
                follow()
            },
            .fadeIn(withDuration: 0.1),
            .moveTo(x: 120, duration: 0.8),
            .run { [weak self] in
                guard let self else { return }
                self.trainerNode.removeAction(forKey: "run")
                self.trainerNode.run(.repeatForever(.animate(with: shoutFrames, timePerFrame: 0.2, resize: true, restore: false)), withKey: "run")
                whistle.set("하나! 둘! 하나! 둘!")
                follow()
                self.exercise(floor: floor, duration: 4.2)
            },
            .wait(forDuration: 4.4),
            .run {
                // 아직 재지 않았다: 숫자는 '예상'만 — 실제 효과는 잠시 뒤 실측 발표(trainerAnnounce)가 말한다.
                whistle.set(estimate.map { "\($0) · 잠시 뒤 실측합니다" } ?? "잘했어요! 메모리 아껴 써요")
            },
            .wait(forDuration: 2.2),
            .run { [weak self] in
                guard let self else { return }
                whistle.removeFromParent()
                if self.trainerWhistle === whistle { self.trainerWhistle = nil }
                self.trainerNode.removeAction(forKey: "run")
                if self.trainerAnnouncement != nil {
                    // 실측이 이미 왔다: 옥상으로 돌아가지 않고 이 층에서 곧장 기계실 RAM 탱크로 간다.
                    self.trainerAnnounceTrip()
                } else {
                    self.trainerNode.position = CGPoint(x: Self.trainerRoofX, y: self.line(self.layout.roofIndex))
                    self.trainerPhase = .idle
                    self.trainerBusy = false
                    self.trainerIdle()
                }
            }
        ]))
        // 말풍선이 트레이너를 따라가도록
        whistle.run(.repeatForever(.sequence([.wait(forDuration: 0.05), .run { follow() }])))
    }

    /// 실측 발표: 앱이 정리 효과를 다시 잰 뒤(트레이너 난입 13초쯤 뒤) 부른다. measured = 실제로 줄어든 메모리(바이트, 0이면 회수 없음), text = 덧붙일 설명.
    /// 트레이너가 기계실 RAM 탱크 앞으로 내려와 잰 값을 외친다 — 탱크 수위가 실제 메모리 값이라 외치는 숫자와 보이는 탱크가 같은 사실을 가리킨다.
    /// 난입 중이면 끝나는 대로 그 층에서, 옥상에 돌아가 있으면 엘리베이터로 내려온다(늘 어느 층 바닥 위 — 순간 이동·공중 부양 없이).
    /// 이미 탱크 앞에 서 있으면 새 값으로 다시 외친다.
    func trainerAnnounce(measured: UInt64, text: String) {
        let shout = measured > 0 ? "실측 \(Fmt.size(measured)) 회수" : "회수 없음 · 쓰던 앱이 끝나야 줄어듭니다"
        trainerAnnouncement = (shout, text.trimmingCharacters(in: .whitespacesAndNewlines), measured)
        switch trainerPhase {
        case .visiting, .toTank: break            // 난입이 끝나면 · 탱크에 닿으면 이 값을 외친다
        case .atTank: trainerAtTank()              // 새 값으로 다시 외친다
        case .idle, .returning: trainerAnnounceTrip()
        }
    }

    /// 실측을 들고 RAM 탱크로: 지금 서 있는 층에서(엘리베이터 안이면 그대로 타고) 기계실까지. 카메라가 따라간다.
    private func trainerAnnounceTrip() {
        guard let announcement = trainerAnnouncement else { trainerReturnToRoof(); return }
        trainerBusy = true
        trainerPhase = .toTank
        trainerNode.removeAllActions()   // 옥상 대기 동작 · 돌아가던 걸음을 멈춘다
        requestEventShot(Shot(target: .follow(trainerNode, zoom: 2.4), caption: "트레이너 · \(announcement.shout)" + (announcement.detail.isEmpty ? "" : " · " + announcement.detail),
                              duration: 12, priority: 2))
        staffTravel(trainerNode, walk: trainerRunFrames, stand: trainerTexture(.stand(blink: false)), toFloor: layout.basementIndex, x: Self.trainerTankX, speed: 150) { [weak self] in
            self?.trainerAtTank()
        }
    }

    /// 탱크 앞: 탱크(오른쪽)를 보고 잰 값을 외친다. 회수가 있으면 탱크 위가 반짝인다(수위 = 실제 값). 설명은 이어서 말풍선으로.
    private func trainerAtTank() {
        guard let announcement = trainerAnnouncement else { trainerReturnToRoof(); return }
        trainerPhase = .atTank
        trainerNode.xScale = 1
        staffPose(trainerNode, (0..<2).map { trainerTexture(.shout($0)) }, timePerFrame: 0.2)
        let seconds: TimeInterval = announcement.detail.isEmpty ? 4.6 : 3.0
        staffSay(trainerNode, announcement.shout, style: .shout, seconds: seconds)
        if announcement.measured > 0 {
            Effects.sparkle(in: world, at: CGPoint(x: MachineLayout.tankX + 17, y: line(layout.basementIndex) + 50))
        }
        var steps: [SKAction] = [.wait(forDuration: seconds)]
        if !announcement.detail.isEmpty {
            let detail = announcement.detail
            steps += [.run { [weak self] in
                guard let self else { return }
                self.staffSay(self.trainerNode, detail, style: .bubble, seconds: 2.4)
            }, .wait(forDuration: 2.4)]
        }
        steps.append(.run { [weak self] in
            guard let self else { return }
            self.trainerAnnouncement = nil
            self.trainerReturnToRoof()
        })
        trainerNode.run(.sequence(steps), withKey: "announce")
    }

    /// 다 외쳤으면 엘리베이터로 옥상에 돌아가 대기한다.
    private func trainerReturnToRoof() {
        trainerPhase = .returning
        trainerNode.removeAction(forKey: "pose")
        trainerNode.removeAction(forKey: "announce")
        staffTravel(trainerNode, walk: trainerRunFrames, stand: trainerTexture(.stand(blink: false)), toFloor: layout.roofIndex, x: Self.trainerRoofX, speed: 150) { [weak self] in
            guard let self else { return }
            self.trainerPhase = .idle
            self.trainerBusy = false
            self.trainerIdle()
        }
    }

    /// DJ 파티(Rooftop.swift): 옥상에서 쉬던 트레이너도 무대(왼쪽)를 보고 손을 흔들며 같이 논다 · 끝나면 원래 대기 동작으로.
    /// 연출 중(난입 · 실측 발표 · 돌아가는 길)이면 손대지 않는다 — 그 연출이 끝나면 스스로 대기 동작으로 돌아온다.
    func trainerParty(_ on: Bool) {
        guard !trainerBusy, trainerPhase == .idle else { return }
        guard on else { trainerIdle(); return }
        trainerNode.removeAllActions()
        let frames = [WorkerPose.wave(0), .wave(1), .shout(0), .shout(1)].map { trainerTexture($0) }
        trainerNode.xScale = -1
        trainerNode.run(.repeatForever(.animate(with: frames, timePerFrame: PartyTiming.beat / 2, resize: true, restore: false)), withKey: "party")
    }

    /// DJ 파티가 끝날 때: 옥상 놀이 자리 직원이 한꺼번에 일어나 엘리베이터로 몰리지 않게 다음 자리 바꿀 시각을 8~30초 사이로 흩는다.
    func staggerRoofSeats() {
        for key in playSeats.keys.sorted(by: { $0.pid < $1.pid }) {
            guard let seat = playSeats[key], Self.isPartySpot(seat.spot, roof: layout.roofIndex) else { continue }
            playSeats[key] = (seat.spot, max(seat.until, lastFrameTime + Variety.shared.seconds(8...30)))
        }
    }

    /// 검수용: 트레이너가 지금 하는 말(호루라기 · 실측 발표), 없으면 nil · 위치 · 옥상에서 대기 중인가.
    var trainerSaying: String? {
        if let bubble = staffBubbles[ObjectIdentifier(trainerNode)], bubble.parent != nil { return bubble.currentText }
        if let whistle = trainerWhistle, whistle.parent != nil { return whistle.currentText }
        return nil
    }
    var trainerProbe: StaffProbe { probe(trainerNode) }
    var trainerResting: Bool { !trainerBusy }

    /// 검수용: 트레이너 · 청소 특공대 · 짐꾼 연출이 띄운 자동 줌 자막(최근 40개, 실측으로 바꾼 자막 포함).
    /// 장면 시험에는 화면이 없어 자동 줌 자체는 돌지 않으므로 자막은 여기서 확인한다.
    private(set) var eventCaptions: [String] = []

    private func noteCaption(_ caption: String) {
        eventCaptions.append(caption)
        if eventCaptions.count > 40 { eventCaptions.removeFirst(eventCaptions.count - 40) }
    }

    /// 트레이너 · 청소 특공대 · 짐꾼 · 도구실 · 금고의 자동 줌(자막을 검수용으로도 남긴다).
    func requestEventShot(_ shot: Shot) {
        noteCaption(shot.caption)
        requestShot(shot)
    }

    /// 실측이 도착했을 때: 지금 자동 줌이 그 인물을 따라가는 중이면 자막만 새 사실로 바꾼다(다른 장면이면 손대지 않는다).
    private func replaceCaption(following node: SKNode?, with caption: String) {
        noteCaption(caption)
        guard let node, activeShot != nil, followNode === node else { return }
        onCaption?(caption)
    }

    /// 층 구성이 바뀌기 직전의 층들(연출 중인 직원을 같은 층의 새 바닥으로 옮길 때 쓴다).
    private var staffFloorsBeforeRebuild: [BuildingLayout.Floor] = []

    /// 층 구성이 바뀐 직후: 옛 층 바닥에 서 있던 높이 → 같은 종류 층(팀 층은 같은 팀 번호)의 새 바닥. 그런 층이 없으면 가장 가까운 층 바닥.
    private func staffY(afterRebuild y: CGFloat) -> CGFloat {
        if let old = staffFloorsBeforeRebuild.first(where: { abs(CGFloat($0.floorLine) - y) < 0.5 }),
           let same = layout.floors.first(where: { $0.kind == old.kind }) {
            return CGFloat(same.floorLine)
        }
        return layout.floors.min { abs(CGFloat($0.floorLine) - y) < abs(CGFloat($1.floorLine) - y) }.map { CGFloat($0.floorLine) } ?? y
    }

    private func exercise(floor: Int, duration: TimeInterval) {
        let present = workers.values.filter { $0.floorIndex == floor && $0.place == .desk && !$0.leaving && !$0.busy && $0.route == nil }
        for (index, worker) in present.enumerated() {
            worker.busy = true
            worker.clearGhost()
            setBubble(worker.key, nil)
            let poses: [WorkerPose] = index % 2 == 0 ? [.pushup(0), .pushup(1)] : [.jumpingJack(0), .jumpingJack(1)]
            worker.loop(poses, fps: 3)
            worker.position.x = worker.vx - 4
            let sweat = SKAction.repeat(.sequence([.wait(forDuration: 0.6), .run { [weak worker] in if let worker { Effects.sweat(on: worker, height: worker.spriteHeight) } }]), count: Int(duration / 0.6))
            worker.run(.sequence([sweat, .run { [weak self, weak worker] in
                // 운동 중에 감사 연출이 데려갔으면(붙잡힘) 그대로 둔다.
                guard let self, let worker, self.auditHeld[worker.key] == nil, !worker.leaving else { return }
                worker.busy = false
                worker.position.x = worker.vx
                self.settle(worker)
            }]))
        }
    }

    // MARK: 연출 — 기계실 짐꾼 · 디스크 경보 · CPU 김

    /// 짐꾼이 일거리를 시작할 때: 카메라가 따라가고 한마디 한다(상자 수는 짐꾼이 직접 바꾼다).
    private func porterJob(_ stock: WarehouseNode.Stock, change: Int) {
        let adding = change > 0
        let amount: String
        switch stock {
        case .swap: amount = "스왑 창고 \(adding ? "+" : "−")\(abs(change))GB"
        case .disk: amount = "디스크 저장고 \(adding ? "+" : "−")\(Fmt.gb(UInt64(abs(change)) * (snapshot?.system.disk.total ?? 0) / UInt64(WarehouseNode.capacity)))"
        }
        requestShot(Shot(target: .follow(warehouse.porter, zoom: 2.4), caption: "\(amount) · 짐꾼이 상자를 \(adding ? "쌓습니다" : "꺼내 갑니다")", duration: 6, priority: 1))
        let lines: [String]
        switch stock {
        case .swap: lines = adding ? Lines.swapIn : Lines.swapOut
        case .disk: lines = adding ? Lines.diskIn : Lines.diskOut
        }
        warehouse.porter.run(.sequence([.wait(forDuration: 0.5), .run { [weak self] in
            guard let self else { return }
            self.staffSay(self.warehouse.porter, Variety.shared.line("porter", lines), style: .bubble, seconds: 2.4)
        }]), withKey: "say")
    }

    /// 메모리 최적화 뒤 앱이 실측한 '줄어든 스왑'(freedBytes — 정리 전후를 잰 값)이 오면 짐꾼이 스왑 창고로 내려온다.
    /// 더미에서 빠지는 상자는 늘 실제 스왑 값(스냅샷 · 1상자 ≈ 1GB)이 허락하는 만큼뿐이다(warehouse.unload): 스왑은 그 페이지를 쓰던 앱이
    /// 끝나야 줄고 ReMON이 직접 줄일 수 없으니, 실제로 줄지 않은 상자가 나가는 일이 없어야 한다. 3개 넘으면 수레(8개씩), 더 많으면 여러 번.
    /// 0이면 창고를 둘러보고 "스왑은 쓰던 앱이 끝나야 줄어요". 비운 양은 있는데 실제 값 기준으로 뺄 상자가 없으면(1GB 미만 · 반올림)
    /// 그렇다고 말하고 상자는 그대로 둔다. 자동 운반이 이미 뺀 상자는 이번 나르기로 친다(같은 상자를 두 번 빼지 않게).
    func porterUnload(freedBytes: UInt64, caption: String) {
        let boxes = freedBytes == 0 ? 0 : max(1, Int((Double(freedBytes) / Fmt.gib).rounded()))
        unloadFreed = freedBytes
        unloadTrips = 0
        warehouse.unload(boxes: boxes)
        // 이번에 더미에서 실제로 빠지는(또는 자동 운반이 방금 뺀) 상자가 하나도 없으면 자막도 그렇게 말한다.
        let moving = warehouse.unloadCarried + warehouse.unloadPlanned
        let shown = freedBytes > 0 && moving == 0 ? "스왑 \(Fmt.size(freedBytes)) 줄었습니다 · 상자는 그대로입니다(1상자 ≈ 1GB)" : caption
        requestEventShot(Shot(target: .follow(warehouse.porter, zoom: 2.4), caption: shown, duration: warehouse.unloadPlanned > WarehouseNode.perTrip ? 12 : 7, priority: 2))
    }

    /// 더미 앞에 닿은 횟수(수레 여러 번) · 앱이 실측한 줄어든 스왑(바이트).
    private var unloadTrips = 0
    private var unloadFreed: UInt64 = 0

    /// 짐꾼이 더미 앞에 닿았을 때 한마디(실제 값): 몇 상자를 내가는지 · 수레 몇 번째인지 · 이미 다 뺐는지 · 줄어든 게 없는지.
    /// 상자 수는 그 순간 창고가 실제 값으로 셈한 것(이미 뺀 것 + 남은 나르기)이다.
    private func porterUnloadEvent(_ event: WarehouseNode.UnloadEvent) {
        switch event {
        case .atStack(let carrying, let cart):
            unloadTrips += 1
            let total = warehouse.unloadCarried + warehouse.unloadLeft
            let text: String
            if unloadFreed == 0 {
                // 줄어든 스왑이 없다: 스왑은 그 페이지를 쓰던 앱이 끝나야 줄어든다(ReMON이 직접 줄일 수 없다).
                text = Variety.shared.line("swapOwnerEnds", Lines.swapOwnerEnds)
            } else if carrying == 0 {
                text = total > 0 ? "방금 \(total)상자 다 뺐어요" : "\(Fmt.size(unloadFreed)) 줄었지만 상자는 그대로예요"
            } else if unloadTrips == 1 {
                text = "\(total)상자 · " + (cart ? "수레로 내갑니다" : Variety.shared.line("swapUnload", Lines.swapUnload))
            } else {
                text = "수레 \(unloadTrips)번째 · \(min(total, warehouse.unloadCarried + carrying))/\(total)"
            }
            warehouse.porter.run(.sequence([.wait(forDuration: 0.2), .run { [weak self] in
                guard let self else { return }
                self.staffSay(self.warehouse.porter, text, style: .bubble, seconds: 2.4)
            }]), withKey: "say")
        case .done:
            unloadTrips = 0
            unloadFreed = 0
        }
    }

    /// 멈췄던 장면이 다시 돌기 시작할 때(창 열기 · 최소화 해제 · 사무실 화면으로 돌아옴): 밀린 운반은 건너뛰고 실제 값에 맞춘다.
    private func resumed() {
        warehouse.snapToTruth()
    }

    private func setAlarm(_ on: Bool) {
        if on && !diskLow { requestShot(Shot(target: .rect(MachineLayout.rect(.disk, floor: layout.floors[0])), caption: "디스크 저장고 여유 부족", duration: 5, priority: 2)) }
        diskLow = on
        alarmNode.removeAllActions()
        let off = TextureCache.shared.texture("alarm0") { Furniture.alarmLight(on: false) }
        let lit = TextureCache.shared.texture("alarm1") { Furniture.alarmLight(on: true) }
        if on { alarmNode.run(.repeatForever(.animate(with: [lit, off], timePerFrame: 0.4))) } else { alarmNode.texture = off }
    }

    private func steam(_ worker: WorkerNode) {
        requestShot(Shot(target: .rect(rectAround(worker)), caption: "과열 · \(sessions[worker.key]?.project ?? "세션") · CPU \(Fmt.percent(sessions[worker.key]?.cpuPercent ?? 0))", duration: 4.5, priority: 1))
        let point = CGPoint(x: worker.position.x + 22, y: worker.position.y + 24)
        let puffs = SKAction.repeat(.sequence([.run { [weak self] in
            guard let self else { return }
            Effects.burst(in: self.world, at: point, color: PixelColor(0xF4F4F4, alpha: 230), count: 3, spread: 3, rise: 10, duration: 0.8)
        }, .wait(forDuration: 0.35)]), count: 14)
        worker.run(puffs, withKey: "steam")
    }

    // MARK: 소품(모니터·메모리 막대·상자·선반·앱 직원·대기 인력·시설)

    private func updateMonitors() {
        for (key, slot) in layout.desks {
            let worker = workers[key]
            let atDesk = worker?.place == .desk && worker?.leaving == false
            let session = sessions[key]
            let on = atDesk && (session?.state == .working || session?.state == .waiting)
            let monitor = monitors[key] ?? {
                let node = SKSpriteNode()
                node.anchorPoint = .zero
                node.zPosition = 4
                world.addChild(node)
                monitors[key] = node
                return node
            }()
            monitor.position = CGPoint(x: CGFloat(slot.deskX + 21), y: line(slot.floor) + 11)
            monitor.size = CGSize(width: 12, height: 11)
            monitor.removeAction(forKey: "screen")
            if on && session?.state == .working {
                let frames = (0..<3).map { i in TextureCache.shared.texture("mon1-\(i)") { Furniture.monitor(on: true, frame: i) } }
                monitor.run(.repeatForever(.animate(with: frames, timePerFrame: 0.3)), withKey: "screen")
            } else {
                monitor.texture = TextureCache.shared.texture("mon\(on)") { Furniture.monitor(on: on) }
            }
            // 메모리 막대(하위 합계): 1GB당 3px, 최대 24px
            let bar = memoryBars[key] ?? {
                let node = SKSpriteNode(color: .clear, size: .zero)
                node.anchorPoint = .zero
                node.zPosition = 4
                world.addChild(node)
                memoryBars[key] = node
                return node
            }()
            let gb = Double(session?.footprint ?? 0) / Fmt.gib
            let height = max(2, min(24, Int((gb * 3).rounded())))
            bar.color = gb >= 3 ? Pal.alarm.nsColor : gb >= 1 ? Pal.mustard.nsColor : Pal.leaf.nsColor
            bar.size = CGSize(width: 3, height: height)
            bar.position = CGPoint(x: CGFloat(slot.deskX + 46), y: line(slot.floor))
        }
        for (key, monitor) in monitors where layout.desks[key] == nil {
            monitor.removeFromParent(); monitors[key] = nil
            memoryBars[key]?.removeFromParent(); memoryBars[key] = nil
        }
    }

    private func updateProps(_ snapshot: OfficeSnapshot) {
        machineRoom.update(system: snapshot.system)
        // 스왑 상자: 1GB = 1상자(최대 48, 스왑 창고에 8개씩). 디스크: 선반 4개 × 12칸, 1칸 = 디스크의 1/48.
        // 값이 바뀌면 상자를 바로 바꾸지 않고 짐꾼이 날라 바꾼다(warehouse).
        let disk = snapshot.system.disk
        let fill = disk.total > 0 ? 1 - Double(disk.available) / Double(disk.total) : 0
        warehouse.diskUsedBytes = disk.total > disk.available ? disk.total - disk.available : 0
        warehouse.update(swapBoxes: Int((Double(snapshot.system.swap.used) / Fmt.gib).rounded()),
                         diskSlots: Int((fill * Double(WarehouseNode.capacity)).rounded()))
        updateSignLabels(snapshot)
        updateTools(snapshot)
        updateSpares(snapshot)
    }

    private var swapLabel: TextBadge?
    private var diskLabel: TextBadge?
    private var systemLabel: TextBadge?
    private var processLabel: TextBadge?
    private var cpuLabel: TextBadge?
    private var ramLabel: TextBadge?
    private var hallLabel: TextBadge?

    private var valueLabels: [TextBadge] = []
    private var machineBadges: [MachineKind: TextBadge] = [:]
    private var machineValues: [MachineKind: String] = [:]

    /// 기계 배지 문구: 멀리서는 이름만, 다가가면 이름 · 값.
    private func refreshMachineBadges() {
        let zoomed = lodZoomed ?? false
        // 기계 사이 간격(가상 px)에 지금 배율을 곱한 만큼만 글자를 쓴다. 넘치면 이름만(이웃 배지와 겹치지 않게).
        let order: [(MachineKind, CGFloat)] = [(.cpu, 83), (.ram, 165), (.swap, 262), (.disk, 397), (.system, 552)]
        for (index, item) in order.enumerated() {
            guard let badge = machineBadges[item.0] else { continue }
            let left = index > 0 ? item.1 - order[index - 1].1 : 120
            let right = index < order.count - 1 ? order[index + 1].1 - item.1 : 120
            let room = min(left, right) * camScale - 10
            let value = machineValues[item.0] ?? ""
            let full = "\(item.0.label) · \(value)"
            badge.set(zoomed && !value.isEmpty ? full : item.0.label)
            if badge.calculateAccumulatedFrame().width > room { badge.set(item.0.label) }
        }
    }

    private func updateSignLabels(_ snapshot: OfficeSnapshot) {
        func badge(_ existing: inout TextBadge?, _ text: String, _ vx: CGFloat, _ vy: CGFloat) {
            if existing == nil {
                let created = TextBadge(text, style: .tiny)
                created.isHidden = !(lodZoomed ?? false)
                overlay.addChild(created)
                staticLabels.append((created, vx, vy))
                valueLabels.append(created)
                existing = created
            }
            existing?.set(text)
            existing?.position = CGPoint(x: vx * pointsPerPixel, y: vy * pointsPerPixel)
        }
        let basement = layout.floors[0]
        let system = snapshot.system
        let thermal = system.thermal
        let cpuText = thermal.available && thermal.cpuTemperature > 0
            ? "\(Fmt.percent(system.cpuPercent)) · \(Int(thermal.cpuTemperature.rounded()))°C"
            : Fmt.percent(system.cpuPercent)
        let systemApp = snapshot.apps.first { $0.id == "system" }
        machineValues = [
            .cpu: cpuText,
            .ram: "여유 \(Fmt.gb(system.memory.available))",
            .swap: Fmt.gb(system.swap.used),
            .disk: "여유 \(Fmt.gb(system.disk.available))",
            .system: "\(systemApp?.pids.count ?? 0)개 · \(Fmt.gb(systemApp?.footprint ?? 0))",
        ]
        refreshMachineBadges()
        _ = basement
        badge(&processLabel, "프로세스 \(snapshot.processCount)", 60, CGFloat(layout.floors[1].floorLine + 46))
        let waitingRoom = snapshot.sessions.filter { $0.state == .longIdle || $0.state == .orphan }
        badge(&hallLabel, waitingRoom.isEmpty ? "비어 있음" : "오래 쉼 \(waitingRoom.count)명 · \(Fmt.gb(waitingRoom.reduce(0) { $0 + $1.footprint }))", 250, CGFloat(layout.floors[layout.hallIndex].floorLine + 54))
        let working = snapshot.sessions.filter { $0.state == .working }.sorted { $0.cpuPercent > $1.cpuPercent }
        for (index, line) in whiteboardLines.enumerated() {
            let session = index < working.count ? working[index] : nil
            line.set(session.map { "\(String($0.project.prefix(7)))·\(String($0.displayTitle.prefix(6)))" } ?? "")
        }
    }

    /// 대기 인력(Claude bg-spare) — 로비 소파. 도구실(앱 기계)은 ToolRoom.swift.
    private func updateSpares(_ snapshot: OfficeSnapshot) {
        let spares = min(BuildingLayout.sofaSpots.count, snapshot.standbyClaudeSpares)
        while spareNodes.count > spares { spareNodes.removeLast().removeFromParent() }
        while spareNodes.count < spares {
            let look = WorkerLook.seeded(900 + spareNodes.count, hoodie: TeamColor.hoodie(.claudeCode))
            let node = SKSpriteNode(texture: TextureCache.shared.worker(look, .sitWait))
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            node.zPosition = 5
            node.position = CGPoint(x: BuildingLayout.sofaSpots[spareNodes.count], y: layout.floors[1].floorLine + 2)
            world.addChild(node)
            spareNodes.append(node)
        }
    }

    /// 떠오르며 사라지는 작은 표지(도구실 '커짐' 등): 1.2초 동안 10px 떠올라 사라진다. 위치는 매 프레임 건물 좌표에서 다시 잰다.
    func floatTag(_ text: String, at point: CGPoint) {
        let badge = TextBadge(text, style: .tiny)
        overlay.addChild(badge)
        floatTags.append((badge, point.x, point.y, 0))
        positionFloatTags(step: 0)
    }

    private func positionFloatTags(step: TimeInterval) {
        guard !floatTags.isEmpty else { return }
        floatTags = floatTags.compactMap { item in
            let age = item.age + step
            guard age < 1.2 else { item.badge.removeFromParent(); return nil }
            item.badge.position = CGPoint(x: item.vx * pointsPerPixel, y: (item.vy + CGFloat(age / 1.2) * 10) * pointsPerPixel)
            item.badge.alpha = age < 0.8 ? 1 : CGFloat((1.2 - age) / 0.4)
            return (item.badge, item.vx, item.vy, age)
        }
    }

    /// 검수용: 지금 떠 있는 표지 글자.
    var floatingTexts: [String] { floatTags.map(\.badge.currentText) }

    /// 방별 확장(금고 명판 · 워크플로실 꼬리표 등)의 글자 위치 · 보이기를 카메라에 맞춘다.
    func repositionRoomExtras() {
        repositionVaultLabels()
        repositionDiskLabels()
        repositionClutterLabels()
    }

    /// 건물 안에 붙은 꼬리표(워크플로 로봇의 '멈춤?' · '잔재')를 화면에서 늘 같은 크기로.
    func fitRoomTags(cameraScale: CGFloat) {
        workflowRooms.values.forEach { $0.fitTags(cameraScale: cameraScale) }
    }

    /// 검수용: 글자판(.sign — 칠판 · 워크플로 보드 · 방 이름) 가운데 가장 앞의 z.
    var signLayerTopZ: CGFloat { staticLabels.filter { $0.badge.style == .sign }.map(\.badge.zPosition).max() ?? 0 }
    /// 검수용: 보이는 보드 글자(상황실 칠판 · 워크플로실 보드)의 사각형(글자 층 좌표).
    var boardFrames: [CGRect] {
        (whiteboardLines + workflowBoards.values.joined()).filter { !$0.isHidden && !$0.currentText.isEmpty }
            .map { CGRect(x: $0.position.x - $0.badgeSize.width / 2, y: $0.position.y - $0.badgeSize.height / 2, width: $0.badgeSize.width, height: $0.badgeSize.height) }
    }
    /// 검수용: 직원 말풍선(글자 · 모양 · z · 글자 층 사각형), 없거나 숨었으면 nil.
    func bubbleProbe(_ key: ProcessKey) -> (text: String, style: TextBadge.Style, z: CGFloat, frame: CGRect)? {
        guard let bubble = bubbles[key], bubble.parent != nil, !bubble.isHidden else { return nil }
        let size = bubble.badgeSize
        return (bubble.currentText, bubble.style, bubble.zPosition, CGRect(x: bubble.position.x - size.width / 2, y: bubble.position.y - size.height / 2, width: size.width, height: size.height))
    }

    /// 검수용: 워크플로실 로봇(층별) — 상태 · 건물 좌표 · 꼬리표 글자 · 빨간 등.
    func workflowRobots(_ floor: Int) -> [(robot: WorkflowRobot, point: CGPoint, tag: String?, light: Bool)] { workflowRooms[floor]?.robotProbes ?? [] }

    // MARK: 부산물(짐)과 청소 인력 — 짐 층 자체는 Clutter.swift

    var janitorNodes: [SKSpriteNode] = []
    var janitorBusy = false
    private var pendingJanitorVisits: [(project: String?, items: Int, reclaimed: UInt64)] = []
    var cleaningProjects: Set<String> {
        Set(pendingJanitorVisits.compactMap(\.project) + [clutter.cleaning].compactMap { $0 })
    }
    /// 방문 중인 청소 특공대의 말풍선 · 쓸기를 마쳤는가 · 앱이 다시 잰 디스크 실측 한 줄(쓸기를 마치면 마침 인사 대신 이것을 말한다).
    private var janitorBubble: TextBadge?
    private var janitorSwept = false
    private var janitorMeasured: String?
    /// 특공대가 이미 돌아간 뒤 실측이 오면 한 명이 기계실 디스크 저장고 앞으로 다시 와서 알린다(그 사람 · 말할 한 줄 · 오는 중/저장고 앞/돌아가는 중).
    private enum ReporterPhase { case coming, atShelf, leaving }
    private var janitorReporter: SKSpriteNode?
    private var janitorReportLine: String?
    private var janitorReporterPhase: ReporterPhase = .coming
    /// 실측을 알릴 자리: 디스크 저장고 선반(332~458) 오른쪽 · 시스템 랙(488~) 왼쪽에서 선반을 본다.
    static let janitorShelfX: CGFloat = 474

    /// 청소 특공대가 일할 자리: 방의 오른쪽 벽 앞(짐 구석). 방이 없으면 기계실의 '방 없는 짐' 줄 앞(디스크 저장고 오른쪽).
    func clutterAnchor(_ project: String) -> CGPoint? {
        if let room = layout.rooms.first(where: { $0.name == project || $0.name.hasPrefix(project + " ") }) {
            return CGPoint(x: CGFloat(room.x1) - 4, y: line(room.floor))
        }
        return CGPoint(x: Self.storageX + 6, y: line(0))
    }

    /// 청소 인력 2명이 문으로 들어와 방으로 가서 쓸고, 짐 층의 치울 몫만 치운 뒤 돌아간다. 카메라가 따라간다.
    /// 짐(Clutter.swift): 치울 수 있음 칸만 — 상자는 한 명이 품에 받아 엘리베이터로 실어 내고, 서류 더미 · 바인더 · 낱장은 쓸어 담는다. 그동안 '정리 중' 테이프.
    /// 남길 짐은 그대로이고, 그 방은 앱이 정리 뒤 다시 계산해 부르는 setClutter로 다시 그린다(그사이 온 장부는 청소가 끝난 뒤 그린다).
    /// reclaimed는 치운 항목 크기의 합 — 디스크를 다시 재기 전의 **예상**이라 자막에 '예상'으로 적는다. 실제로 늘어난 여유는
    /// 앱이 다시 잰 뒤 janitorAnnounce(measured:)로 알린다(쓸기를 마친 말풍선이 그 값을 말한다).
    func janitorVisit(project: String?, items: Int, reclaimed: UInt64) {
        guard !janitorBusy else {
            pendingJanitorVisits.append((project, items, reclaimed))
            return
        }
        janitorBusy = true
        janitorSwept = false
        janitorMeasured = nil
        let roomName = project ?? "기계실"
        let floor = project.flatMap { name in layout.rooms.first { $0.name == name || $0.name.hasPrefix(name + " ") }?.floor } ?? 0
        let anchor = clutterAnchor(project ?? "") ?? CGPoint(x: 466, y: line(0))
        // 서류가 쌓인 방이면(커밋 · 푸시 · 배포 뒤) 한 명은 물걸레질(양동이 · 젖은 자국 · 반짝), 다른 한 명은 비질하며 서류를 걷는다.
        let room = project.flatMap { name in layout.rooms.first { $0.name == name || $0.name.hasPrefix(name + " ") } }
        let mop = room != nil && paperCount(project ?? "") > 0
        let mopFrom = CGFloat(room?.x0 ?? 0) + 22, mopTo = max(CGFloat(room?.x0 ?? 0) + 40, CGFloat(room?.x1 ?? 0) - 46)
        let mopDuration = TimeInterval(max(0.6, (mopTo - mopFrom) / 40))
        // 짐 층의 치울 몫(위에 있는 것부터). 상자가 있으면 첫 번째 사람이 잠깐 쓸고 상자를 품에 받는다.
        let share = clutterShare(project)
        let carrying = !share.boxes.isEmpty
        clutter.cleaning = project
        let crew = (0..<2).map { index -> SKSpriteNode in
            let node = SKSpriteNode(texture: TextureCache.shared.texture("janitor\(index)-stand") { CharacterArt.janitorSprite(index, .stand(blink: false)) })
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            node.zPosition = 7
            node.position = CGPoint(x: CGFloat(BuildingLayout.doorX) - CGFloat(index * 12), y: line(1))
            node.alpha = 0
            world.addChild(node)
            return node
        }
        janitorNodes = crew
        requestEventShot(Shot(target: .follow(crew[0], zoom: 2.4), caption: "청소 · \(roomName) · \(items)개" + (reclaimed > 0 ? " · 예상 \(Fmt.gb(reclaimed))" : ""), duration: 14, priority: 2))
        let bubble = TextBadge(Variety.shared.line("janitor", Lines.janitorEnter), style: .bubble)
        overlay.addChild(bubble)
        janitorBubble = bubble
        bubble.run(.repeatForever(.sequence([.wait(forDuration: 0.05), .run { [weak self] in
            guard let self else { return }
            bubble.position = CGPoint(x: (crew[0].position.x + 6) * self.pointsPerPixel, y: (crew[0].position.y + 42) * self.pointsPerPixel)
        }])))
        doorNode.texture = door(1)
        let targetX = anchor.x - 22
        func walkFrames(_ index: Int) -> [SKTexture] { (0..<4).map { f in TextureCache.shared.texture("janitor\(index)-walk\(f)") { CharacterArt.janitorSprite(index, .walk(f)) } } }
        func sweepFrames(_ index: Int) -> [SKTexture] { (0..<2).map { f in TextureCache.shared.texture("janitor\(index)-sweep\(f)") { CharacterArt.janitorSprite(index, .sweep(f)) } } }
        func mopFrames(_ index: Int) -> [SKTexture] { (0..<2).map { f in TextureCache.shared.texture("janitor\(index)-mop\(f)") { CharacterArt.janitorSprite(index, .mop(f)) } } }
        func carryFrames(_ index: Int) -> [SKTexture] { (0..<4).map { f in TextureCache.shared.texture("janitor\(index)-carry\(f)") { CharacterArt.janitorSprite(index, .carry(f)) } } }
        for (index, node) in crew.enumerated() {
            let walk = walkFrames(index)
            let shaft = CGFloat(BuildingLayout.elevatorX)
            var steps: [SKAction] = [.fadeIn(withDuration: 0.2), .wait(forDuration: Double(index) * 0.4)]
            if floor != 1 {
                steps.append(.group([.moveTo(x: shaft, duration: 1.0), .repeat(.animate(with: walk, timePerFrame: 0.12, resize: true, restore: false), count: 3)]))
                steps.append(.run { [weak self] in self?.openElevator(1) })
                steps.append(.fadeOut(withDuration: 0.2))
                steps.append(.wait(forDuration: 0.35 * Double(abs(floor - 1)) + 0.3))
                steps.append(.run { [weak self] in
                    guard let self else { return }
                    node.position = CGPoint(x: shaft, y: self.line(floor))
                    self.openElevator(floor)
                })
                steps.append(.fadeIn(withDuration: 0.2))
            }
            let mopper = mop && index == 1
            let destination = mopper ? mopFrom : targetX - CGFloat(index * 16)
            steps.append(.group([.moveTo(x: destination, duration: TimeInterval(abs(destination - shaft) / 50)), .repeat(.animate(with: walk, timePerFrame: 0.12, resize: true, restore: false), count: max(1, Int(abs(destination - shaft) / 50 / 0.48)))]))
            steps.append(.run { node.xScale = 1 })
            if mopper {
                // 물걸레질: 방 왼쪽에 양동이를 놓고 오른쪽 끝까지 밀며 지나간 자리에 젖은 자국을 남긴다 → 다 닦으면 바닥이 반짝인다.
                steps.append(.run { [weak self] in self?.startMopping(node, floor: floor, at: mopFrom) })
                steps.append(.group([
                    .moveTo(x: mopTo, duration: mopDuration),
                    .repeat(.animate(with: mopFrames(index), timePerFrame: 0.25, resize: true, restore: false), count: max(1, Int(mopDuration / 0.5))),
                    .repeat(.sequence([.wait(forDuration: 0.15), .run { [weak self] in self?.wetStreak(at: node.position.x - 7, floor: floor) }]), count: max(1, Int(mopDuration / 0.15)))
                ]))
                steps.append(.run { [weak self] in self?.floorShine(from: mopFrom, to: mopTo, floor: floor) })
            } else if carrying && index == 0 {
                // 짐 받기: 잠깐 쓸고 상자를 받는 자세(품에 한 상자)로 선다 — 나머지 상자는 날아와 그 위에 쌓인다.
                steps.append(.repeat(.animate(with: sweepFrames(index), timePerFrame: 0.3, resize: true, restore: false), count: 5))
                steps.append(.setTexture(carryFrames(index)[0], resize: true))
            } else {
                steps.append(.repeat(.animate(with: sweepFrames(index), timePerFrame: 0.3, resize: true, restore: false), count: 10))
            }
            if !(carrying && index == 0) {
                steps.append(.setTexture(TextureCache.shared.texture("janitor\(index)-stand") { CharacterArt.janitorSprite(index, .stand(blink: false)) }, resize: true))
            }
            node.run(.sequence(steps), withKey: "janitor")
        }
        // 방에 닿으면 '정리 중' 테이프 · 서류 더미 · 바인더 · 낱장은 쓸어 담고(먼지), 잠시 뒤 치울 상자가 위에서부터 품으로 날아와 쌓인다.
        let sweepStart = 2.6 + (floor != 1 ? 0.35 * Double(abs(floor - 1)) + 1.6 : 0) + TimeInterval(abs(targetX - CGFloat(BuildingLayout.elevatorX)) / 50)
        // 물걸레질하는 사람은 방 왼쪽에서 출발해 오른쪽 끝까지 닦는다: 다 닦고 반짝일 때까지 마침 인사를 미룬다.
        let mopStart = 0.6 + (floor != 1 ? 1.9 + 0.35 * Double(abs(floor - 1)) : 0) + TimeInterval(abs(mopFrom - CGFloat(BuildingLayout.elevatorX)) / 50)
        let pickDelay: TimeInterval = 1.5
        var doneDelay = mop ? max(3.2, mopStart + mopDuration + 0.8 - sweepStart) : 3.2
        if carrying { doneDelay = max(doneDelay, pickDelay + min(0.16, 1.4 / Double(share.boxes.count)) * Double(share.boxes.count) + 0.9) }
        run(.sequence([
            .wait(forDuration: sweepStart),
            .run { [weak self] in
                guard let self else { return }
                if mop {
                    self.collectPapers(project ?? "", toward: crew[0])
                    bubble.set(Variety.shared.line("paperCollect", Lines.paperCollect))
                }
                self.clutterSweep(project, share: share, toward: crew[0], floor: floor)
                for _ in 0..<6 {
                    Effects.burst(in: self.world, at: CGPoint(x: targetX + CGFloat.random(in: -10...14), y: self.line(floor) + 3), color: PixelColor(0xD9D2C2), count: 3, spread: 6, rise: 6, duration: 0.6)
                }
            },
            .wait(forDuration: pickDelay),
            .run { [weak self] in self?.clutterPickUp(share.boxes, carrier: crew[0]) },
            .wait(forDuration: doneDelay - pickDelay),
            .run { [weak self] in
                guard let self else { return }
                self.janitorSwept = true
                self.mopBucket?.run(.sequence([.fadeOut(withDuration: 0.4), .removeFromParent()]))
                self.mopBucket = nil
                if let measured = self.janitorMeasured {
                    // 디스크를 다시 잰 값이 이미 왔다: 마침 인사 대신 실측을 말한다.
                    bubble.set(measured)
                    self.replaceCaption(following: crew[0], with: "청소 · \(roomName) · 디스크 \(measured)")
                } else {
                    bubble.set(Variety.shared.line("janitorDone", Lines.janitorDone))
                }
                for (index, node) in crew.enumerated() {
                    // 상자를 받은 사람은 품에 쌓은 채 엘리베이터까지 걸어가 싣고(사라질 때 내린다), 1층부터는 빈손으로 나간다.
                    let carrier = carrying && index == 0
                    let walk = carrier ? carryFrames(index) : walkFrames(index)
                    node.xScale = -1
                    var steps: [SKAction] = []
                    let shaft = CGFloat(BuildingLayout.elevatorX)
                    if floor != 1 {
                        steps.append(.group([.moveTo(x: shaft, duration: TimeInterval(abs(node.position.x - shaft) / 50)), .repeat(.animate(with: walk, timePerFrame: 0.12, resize: true, restore: false), count: max(1, Int(abs(node.position.x - shaft) / 50 / 0.48)))]))
                        steps.append(.fadeOut(withDuration: 0.2))
                        if carrier { steps.append(.run { [weak self] in self?.clutterUnload() }) }
                        steps.append(.wait(forDuration: 0.35 * Double(abs(floor - 1)) + 0.3))
                        steps.append(.run { [weak self] in guard let self else { return }; node.position = CGPoint(x: shaft, y: self.line(1)) })
                        steps.append(.fadeIn(withDuration: 0.2))
                    }
                    let door = CGFloat(BuildingLayout.doorX)
                    let doorWalk = carrier && floor == 1 ? walk : walkFrames(index)
                    steps.append(.group([.moveTo(x: door, duration: TimeInterval(abs(node.position.x - door) / 50)), .repeat(.animate(with: doorWalk, timePerFrame: 0.12, resize: true, restore: false), count: 3)]))
                    steps.append(.fadeOut(withDuration: 0.3))
                    if carrier { steps.append(.run { [weak self] in self?.clutterUnload() }) }
                    steps.append(.removeFromParent())
                    node.run(.sequence(steps), withKey: "janitor")
                }
            },
            .wait(forDuration: 4.5),
            .run { [weak self] in
                guard let self else { return }
                bubble.removeFromParent()
                if self.janitorBubble === bubble { self.janitorBubble = nil }
                self.doorNode.texture = self.door(0)
                self.janitorNodes = []
                self.janitorBusy = false
                self.janitorSwept = false
                self.janitorMeasured = nil
                self.clutterCleaningDone()
                if !self.pendingJanitorVisits.isEmpty {
                    let next = self.pendingJanitorVisits.removeFirst()
                    self.janitorVisit(project: next.project, items: next.items, reclaimed: next.reclaimed)
                }
            }
        ]), withKey: "janitorVisit")
    }

    /// 물청소 시작: 방 왼쪽 바닥에 파란 양동이를 놓고 한마디.
    private func startMopping(_ node: SKSpriteNode, floor: Int, at x: CGFloat) {
        mopBucket?.removeFromParent()
        let bucket = SKSpriteNode(texture: TextureCache.shared.texture("mop-bucket") { MachineArt.bucket() })
        bucket.anchorPoint = CGPoint(x: 0.5, y: 0)
        bucket.size = CGSize(width: 8, height: 7)
        bucket.position = CGPoint(x: x - 12, y: line(floor))
        bucket.zPosition = 6.5
        world.addChild(bucket)
        mopBucket = bucket
        // 양동이 옆 '미끄럼 주의' 입간판(양동이와 함께 치운다)
        let sign = SKSpriteNode(texture: TextureCache.shared.texture("wet-floor-sign") { MachineArt.wetFloorSign() })
        sign.anchorPoint = CGPoint(x: 0.5, y: 0)
        sign.size = CGSize(width: 7, height: 9)
        sign.position = CGPoint(x: -7, y: 0)
        bucket.addChild(sign)
        Effects.burst(in: world, at: CGPoint(x: x - 12, y: line(floor) + 7), color: PixelColor(0x9BE7F3), count: 4, spread: 4, rise: 6, duration: 0.5)
        staffSay(node, Variety.shared.line("mopping", Lines.mopping), style: .bubble, seconds: 2.2)
        mopLog.append("양동이")
    }

    /// 걸레가 지나간 자리: 바닥 띠 위 젖은 자국(반짝이다 마르며 사라진다).
    private func wetStreak(at x: CGFloat, floor: Int) {
        let streak = SKSpriteNode(texture: TextureCache.shared.texture("wet-streak-8") { MachineArt.wetStreak(8) })
        streak.anchorPoint = CGPoint(x: 0.5, y: 0)
        streak.size = CGSize(width: 8, height: 2)
        streak.position = CGPoint(x: x, y: line(floor) + 1)
        streak.zPosition = 2.3
        streak.name = "wet"
        world.addChild(streak)
        streak.run(.sequence([.wait(forDuration: 1.6), .fadeAlpha(to: 0.55, duration: 0.8), .wait(forDuration: 1.4), .fadeOut(withDuration: 0.9), .removeFromParent()]))
        mopStrokes += 1
    }

    /// 다 닦은 바닥이 반짝인다.
    private func floorShine(from: CGFloat, to: CGFloat, floor: Int) {
        let y = line(floor) + 4
        for i in 0..<4 {
            let x = from + (to - from) * CGFloat(i) / 3
            world.run(.sequence([.wait(forDuration: Double(i) * 0.15), .run { [weak self] in
                guard let self else { return }
                Effects.sparkle(in: self.world, at: CGPoint(x: x, y: y))
            }]))
        }
        mopLog.append("반짝")
    }

    /// 디스크 실측 발표: 앱이 정리 뒤 디스크 여유를 다시 잰 값(늘어난 바이트, 0이면 그대로). 청소 중이면 쓸기를 마친 말풍선이 이 값을 말하고
    /// (이미 마쳤으면 바로), 특공대가 이미 돌아갔으면 한 명이 기계실 디스크 저장고 앞으로 다시 와서 알린다 — 저장고 선반이 실제 디스크 값이다.
    func janitorAnnounce(measured: UInt64) {
        let text = measured > 0 ? "실측 +\(Fmt.size(measured))" : "실측 · 디스크 여유 그대로"
        if janitorBusy {
            janitorMeasured = text
            if janitorSwept, let bubble = janitorBubble {
                bubble.set(text)
                replaceCaption(following: janitorNodes.first, with: "청소 · 디스크 \(text)")
            }
            return
        }
        janitorReport(text)
    }

    private func janitorWalkFrames(_ index: Int) -> [SKTexture] { (0..<4).map { f in TextureCache.shared.texture("janitor\(index)-walk\(f)") { CharacterArt.janitorSprite(index, .walk(f)) } } }
    private func janitorStand(_ index: Int) -> SKTexture { TextureCache.shared.texture("janitor\(index)-stand") { CharacterArt.janitorSprite(index, .stand(blink: false)) } }

    /// 특공대가 돌아간 뒤 온 실측: 한 명이 1층 문으로 들어와 엘리베이터로 기계실 디스크 저장고 앞까지 와서 알리고 돌아간다.
    /// 이미 오는 중이면 닿았을 때 새 값을 말하고, 저장고 앞이면 바로 다시 말한다. 돌아가는 중이면 새로 한 명이 온다.
    private func janitorReport(_ text: String) {
        janitorReportLine = text
        if let reporter = janitorReporter, reporter.parent != nil, janitorReporterPhase != .leaving {
            if janitorReporterPhase == .atShelf { janitorAtShelf(reporter) }
            return
        }
        let node = SKSpriteNode(texture: janitorStand(0))
        node.anchorPoint = CGPoint(x: 0.5, y: 0)
        node.zPosition = 7
        node.position = CGPoint(x: CGFloat(BuildingLayout.doorX), y: line(layout.lobbyIndex))
        node.alpha = 0
        world.addChild(node)
        janitorReporter = node
        janitorReporterPhase = .coming
        doorNode.texture = door(1)
        requestEventShot(Shot(target: .follow(node, zoom: 2.4), caption: "청소 특공대 · 디스크 \(text)", duration: 12, priority: 2))
        node.run(.sequence([
            .fadeIn(withDuration: 0.2),
            .run { [weak self, weak node] in
                guard let self, let node else { return }
                self.doorNode.run(.sequence([.wait(forDuration: 0.5), .setTexture(self.door(0))]))
                self.staffTravel(node, walk: self.janitorWalkFrames(0), stand: self.janitorStand(0), toFloor: self.layout.basementIndex, x: Self.janitorShelfX, speed: 90) { [weak self, weak node] in
                    guard let self, let node else { return }
                    self.janitorAtShelf(node)
                }
            }
        ]), withKey: "enter")
    }

    /// 저장고 앞: 선반(왼쪽)을 보고 손을 흔들며 실측을 말한 뒤 1층 문으로 돌아가 나간다.
    private func janitorAtShelf(_ node: SKSpriteNode) {
        guard let text = janitorReportLine else { return }
        janitorReporterPhase = .atShelf
        node.xScale = -1
        staffPose(node, (0..<2).map { f in TextureCache.shared.texture("janitor0-wave\(f)") { CharacterArt.janitorSprite(0, .wave(f)) } }, timePerFrame: 0.3)
        staffSay(node, text, style: .shout, seconds: 4.4)
        node.run(.sequence([.wait(forDuration: 4.6), .run { [weak self, weak node] in
            guard let self, let node else { return }
            if self.janitorReporter === node {
                self.janitorReporterPhase = .leaving
                self.janitorReportLine = nil
            }
            self.staffTravel(node, walk: self.janitorWalkFrames(0), stand: self.janitorStand(0), toFloor: self.layout.lobbyIndex, x: CGFloat(BuildingLayout.doorX), speed: 90) { [weak self, weak node] in
                guard let self, let node else { return }
                self.doorNode.texture = self.door(1)
                node.run(.sequence([.fadeOut(withDuration: 0.3), .run { [weak self, weak node] in
                    guard let self else { return }
                    self.doorNode.texture = self.door(0)
                    node?.removeFromParent()
                    if self.janitorReporter === node { self.janitorReporter = nil }
                }]), withKey: "leave")
            }
        }]), withKey: "report")
    }

    /// 검수용: 청소 특공대(방문 중인 두 명 · 실측을 알리러 다시 온 한 명)가 지금 하는 말 · 위치 · 모두 돌아갔는가.
    var janitorSaying: String? {
        if let reporter = janitorReporter, let bubble = staffBubbles[ObjectIdentifier(reporter)], bubble.parent != nil { return bubble.currentText }
        if let bubble = janitorBubble, bubble.parent != nil { return bubble.currentText }
        return nil
    }
    var janitorProbes: [(name: String, probe: StaffProbe)] {
        janitorNodes.enumerated().map { ("청소\($0.offset + 1)", probe($0.element)) } + (janitorReporter.map { [("실측 알림", probe($0))] } ?? [])
    }
    var janitorsGone: Bool { !janitorBusy && pendingJanitorVisits.isEmpty && janitorReporter == nil }

    // MARK: 사장(대표) — 상황실

    enum BossMood: String { case elated, calm, anxious, panic }

    private let bossNode = SKSpriteNode()
    private(set) var bossMood: BossMood = .calm
    private var bossMoodUntil: TimeInterval = 0
    var onSelectBoss: (() -> Void)?

    private var bossFloor: Int { layout.topTeamIndex }
    private var bossRange: ClosedRange<CGFloat> { CGFloat(BuildingLayout.wingX0 + 16)...CGFloat(BuildingLayout.wingX1 - 18) }
    private func bossTexture(_ pose: WorkerPose) -> SKTexture { TextureCache.shared.texture("boss-\(pose)") { CharacterArt.bossSprite(pose) } }

    /// 상황실(맨 위 팀 층 별관)에 사장을 세우고 서성이기 시작한다.
    private func placeBoss() {
        if bossNode.parent == nil {
            bossNode.anchorPoint = CGPoint(x: 0.5, y: 0)
            bossNode.zPosition = 6
            world.addChild(bossNode)
        }
        bossNode.removeAllActions()
        bossNode.texture = bossTexture(.stand(blink: false))
        bossNode.size = CGSize(width: 16, height: 24)
        bossNode.position = CGPoint(x: (bossRange.lowerBound + bossRange.upperBound) / 2, y: line(bossFloor))
        bossMoodUntil = 0
        bossNextMove()
    }

    /// 기분은 실제 수치에서: 나만 기다리는 세션(입력 필요)·메모리 압박·디스크 부족·과열은 불안,
    /// 일하는 세션이 많으면 신남. 여기에 들쭉날쭉한 기복(±)을 더해 감정 기복이 심해 보이게 한다.
    func bossComputeMood() -> BossMood {
        guard let snapshot else { return .calm }
        let waiting = snapshot.sessions.filter { $0.state == .waiting }.count
        let working = snapshot.sessions.filter { $0.state == .working }.count
        var anxiety = Double(waiting) * 0.16
        switch snapshot.system.pressure {
        case .critical: anxiety += 0.5
        case .warning: anxiety += 0.22
        case .normal: break
        }
        if diskLow { anxiety += 0.35 }
        if snapshot.system.thermal.cpuTemperature >= 95 || snapshot.system.cpuPercent >= 90 { anxiety += 0.2 }
        anxiety -= min(0.3, Double(working) * 0.06)
        anxiety += Variety.shared.number(-0.18...0.18)
        switch anxiety {
        case ..<0.12: return .elated
        case ..<0.35: return .calm
        case ..<0.62: return .anxious
        default: return .panic
        }
    }

    /// 다음 동작 하나: 기분에 따라 걸음 속도·멈춤 자세·대사가 다르다. 끝나면 다시 고른다(정신없이 왔다 갔다).
    private func bossNextMove() {
        if lastFrameTime >= bossMoodUntil {
            bossMood = bossComputeMood()
            bossMoodUntil = lastFrameTime + Variety.shared.seconds(5...12)
        }
        let speed: CGFloat
        switch bossMood {
        case .elated: speed = 34
        case .calm: speed = 24
        case .anxious: speed = 62
        case .panic: speed = 96
        }
        let target = CGFloat(Variety.shared.number(Double(bossRange.lowerBound)...Double(bossRange.upperBound)))
        let distance = abs(target - bossNode.position.x)
        let frame = bossMood == .panic ? 0.07 : 0.12
        let walk = (0..<4).map { bossTexture(.walk($0)) }
        bossNode.xScale = target >= bossNode.position.x ? 1 : -1
        let move = SKAction.group([
            .moveTo(x: target, duration: TimeInterval(max(0.2, distance / speed))),
            .repeat(.animate(with: walk, timePerFrame: frame, resize: false, restore: false), count: max(1, Int(distance / speed / (frame * 4))))
        ])
        let pause: SKAction
        switch bossMood {
        case .panic:
            pause = .repeat(.animate(with: [bossTexture(.shout(0)), bossTexture(.shout(1))], timePerFrame: 0.12, resize: false, restore: false), count: Variety.shared.integer(2...4))
        case .anxious:
            pause = Variety.shared.chance(0.5)
                ? .sequence([.setTexture(bossTexture(.read(0))), .wait(forDuration: 0.5), .setTexture(bossTexture(.read(1))), .wait(forDuration: 0.5)])
                : .wait(forDuration: 0.25)
        case .elated:
            pause = Variety.shared.chance(0.5)
                ? .repeat(.animate(with: [bossTexture(.clap(0)), bossTexture(.clap(1))], timePerFrame: 0.2, resize: false, restore: false), count: 3)
                : .wait(forDuration: 1.2)
        case .calm:
            pause = Variety.shared.chance(0.35)
                ? .sequence([.setTexture(bossTexture(.read(0))), .wait(forDuration: 1.6)])
                : Variety.shared.chance(0.2) ? .sequence([.setTexture(bossTexture(.sitSad)), .wait(forDuration: 1.4)]) : .wait(forDuration: Variety.shared.seconds(0.8...2.2))
        }
        bossNode.run(.sequence([move, .setTexture(bossTexture(.stand(blink: false))), pause,
                                .run { [weak self] in self?.bossSpeakMaybe() },
                                .run { [weak self] in self?.bossNextMove() }]), withKey: "boss")
    }

    /// 대사: 기분별 + 실제 수치(기다리는 세션 수·스왑 크기)를 넣는다.
    private func bossSpeakMaybe() {
        let probability: Double
        switch bossMood {
        case .panic: probability = 0.6
        case .anxious: probability = 0.4
        default: probability = 0.22
        }
        guard Variety.shared.chance(probability), snapshot != nil else { return }
        // 일·진행 상황(배포·푸시·기다리는 세션·하는 일·컨텍스트·감사 결과)과 메모리 기분 줄을 섞는다(Speech).
        var options = Speech.boss(speechNow, mood: bossMood.rawValue)
        if bossMood == .panic && diskLow { options.append("디스크 꽉 찼잖아!") }
        staffSay(bossNode, Variety.shared.line("boss-\(bossMood.rawValue)", options), style: bossMood == .panic ? .shout : .bubble, seconds: 2.8)
    }

    // MARK: 감사(자동 정리): 감사관 + 비서 + 정신교육실 강사

    private let auditorNode = SKSpriteNode()
    private let secretaryNode = SKSpriteNode()
    private let instructorNode = SKSpriteNode()
    private var auditBusy = false
    private var classSeatOf: [ProcessKey: Int] = [:]
    /// 감사 단계: 들어옴(문 박차기) → 순찰(판정 대기 — 일하는 층을 돌며 모니터를 들여다본다) → 실행(강당 · 정신교육실) → 퇴장.
    private enum AuditPhase { case idle, entering, touring, acting, leaving }
    private var auditPhase: AuditPhase = .idle
    /// 실행 연출의 기다림(모이기 등)을 돌리는 보이지 않는 노드. 그만둘 때는 이 노드의 동작만 지우면 된다.
    private let auditStage = SKNode()
    private var auditStageStarted: TimeInterval = 0
    private var auditTourStarted: TimeInterval = 0
    private var auditWaitSerial = 0
    /// 순찰: 이번 바퀴에 볼 순서(층 아래부터, 층마다 엘리베이터 쪽부터 3명) · 이번 감사에서 이미 본 사람.
    private var tourPlan: [ProcessKey] = []
    private var tourSeen = Set<ProcessKey>()
    /// 검수용: 순찰에서 모니터를 들여다본 기록(층 · 세션 · 말풍선 글자).
    private(set) var tourLog: [(floor: Int, key: ProcessKey, text: String)] = []
    /// 실행 연출이 붙잡고 있는 직원: 교육생(좌석) · 퇴출 줄(자리) · 교육 뒤 책상으로 돌아가는 중. busy로 붙잡아 스냅샷 조정이 자리를 옮기지 않게 한다.
    private enum AuditHold: Equatable { case student(Int), lineup(Int), returning }
    private var auditHeld: [ProcessKey: AuditHold] = [:]
    private var auditFetchQueue: [ProcessKey] = []
    private var auditorAtPost = false
    private var instructorAtFront = false
    private var guardDragsThisAudit = 0

    /// 판정 실행 대상 하나(세션 · 판정 사유).
    struct AuditCall {
        var key: ProcessKey
        var reason: String
    }

    /// 실행 연출 한 번: 대상과 실제 조치 손잡이. 손잡이는 판정마다 한 번만 부른다(reeducated · evicted로 기억).
    private final class AuditRun {
        let reeducate: [AuditCall]
        let evict: [AuditCall]
        let praise: [AuditCall]
        let onReeducate: (ProcessKey) -> Bool
        let onEvict: (ProcessKey) -> Bool
        let onFinish: () -> Void
        var reeducated = Set<ProcessKey>()
        var evicted = Set<ProcessKey>()
        /// 퇴출 외침 대사를 이번 감사 안에서 돌려 쓴다(줄 선 사람들이 같은 말을 외치지 않게).
        let lineOffset = Variety.shared.integer(0...(Lines.evicted.count - 1))

        init(reeducate: [AuditCall], evict: [AuditCall], praise: [AuditCall], onReeducate: @escaping (ProcessKey) -> Bool, onEvict: @escaping (ProcessKey) -> Bool, onFinish: @escaping () -> Void) {
            self.reeducate = reeducate
            self.evict = evict
            self.praise = praise
            self.onReeducate = onReeducate
            self.onEvict = onEvict
            self.onFinish = onFinish
        }

        /// 이번 감사에서 n번째로 이름이 불린 사람의 외침.
        func evictedLine(_ n: Int) -> String { Lines.evicted[(lineOffset + n) % Lines.evicted.count] }
    }
    private var auditRun: AuditRun?

    /// 연출 자리(가상 px, 강당 층): 강사는 교육실 오른쪽 끝에서 학생들(책상을 보고 앉음)을 본다 · 교육실 문(왼쪽, 정리 세션이 복귀할 때 나가는 그 문) ·
    /// 감사관 단상(무대 왼쪽 앞) · 퇴출 줄(단상 앞에서 왼쪽으로 14px 간격) · 교육실 좌석이 차면 책상 사이에 선다.
    private enum AuditSpot {
        static let instructorFront: CGFloat = 622
        static let classDoor = CGFloat(BuildingLayout.wingX0 + 4)
        static let podium = CGFloat(BuildingLayout.hallStageX - 8)
        static let watch = CGFloat(BuildingLayout.hallStageX + 12)
        static let secretaryHall: CGFloat = 458
        static let lineX0 = CGFloat(BuildingLayout.hallStageX - 24)
        static let linePitch: CGFloat = 14
        static let lineMax = 12
        static let standExtras: [CGFloat] = [517, 551, 585]
        static let studentsMax = 7
    }

    private func auditorTexture(_ pose: WorkerPose) -> SKTexture { TextureCache.shared.texture("auditor-\(pose)") { CharacterArt.auditorSprite(pose) } }
    private func secretaryTexture(_ pose: WorkerPose) -> SKTexture { TextureCache.shared.texture("secretary-\(pose)") { CharacterArt.secretarySprite(pose) } }
    private func instructorTexture(_ pose: WorkerPose) -> SKTexture { TextureCache.shared.texture("instructor-\(pose)") { CharacterArt.instructorSprite(pose) } }
    private var auditorWalk: [SKTexture] { (0..<4).map { auditorTexture(.walk($0)) } }
    private var secretaryWalk: [SKTexture] { (0..<4).map { secretaryTexture(.walk($0)) } }
    private var instructorWalk: [SKTexture] { (0..<4).map { instructorTexture(.walk($0)) } }
    private var auditorStand: SKTexture { auditorTexture(.stand(blink: false)) }
    private var secretaryStand: SKTexture { secretaryTexture(.stand(blink: false)) }
    private var instructorStand: SKTexture { instructorTexture(.stand(blink: false)) }

    var staffBubbles: [ObjectIdentifier: TextBadge] = [:]
    /// 말풍선 주인(사장 · 감사관 · 비서 · 강사 · 짐꾼). 위치는 매 프레임 update에서 맞춘 뒤 겹침 정리가 옮긴다
    /// (예전: 말풍선 자체 동작이 0.03초마다 자리를 되돌려 겹침 정리가 무효가 됐다 — 감사관 호명과 퇴출 대상의 외침이 겹쳐 보였다).
    private var staffSpeakers: [ObjectIdentifier: SKSpriteNode] = [:]

    func staffSay(_ node: SKSpriteNode, _ text: String, style: TextBadge.Style, seconds: TimeInterval) {
        let id = ObjectIdentifier(node)
        staffBubbles[id]?.removeFromParent()
        let bubble = TextBadge(text, style: style)
        overlay.addChild(bubble)
        staffBubbles[id] = bubble
        staffSpeakers[id] = node
        bubble.position = staffBubblePoint(node)
        bubble.run(.sequence([.wait(forDuration: seconds), .run { [weak self, weak bubble] in
            guard let self, let bubble else { return }
            bubble.removeFromParent()
            if self.staffBubbles[id] === bubble {
                self.staffBubbles[id] = nil
                self.staffSpeakers[id] = nil
            }
        }]))
    }

    private func staffBubblePoint(_ node: SKSpriteNode) -> CGPoint {
        // 수레 위 기사처럼 다른 노드 안에 든 인물은 건물 좌표로 바꿔 머리 위에 띄운다.
        let point = node.parent === world || node.parent == nil ? node.position : node.convert(.zero, to: world)
        return CGPoint(x: (point.x + 6) * pointsPerPixel, y: (point.y + node.size.height + 17) * pointsPerPixel)
    }

    /// 매 프레임(겹침 정리 전): 말풍선을 주인 머리 위로. 주인이 장면에서 빠졌으면(퇴장) 말풍선도 숨긴다.
    private func positionStaffBubbles() {
        for (id, bubble) in staffBubbles {
            guard let node = staffSpeakers[id] else { continue }
            bubble.isHidden = node.parent == nil
            bubble.position = staffBubblePoint(node)
        }
    }

    /// 감사 인물의 반복 자세("pose" 키 — 걷기가 시작되면 staffTravel이 지운다).
    func staffPose(_ node: SKSpriteNode, _ textures: [SKTexture], timePerFrame: TimeInterval = 0.25) {
        node.removeAction(forKey: "pose")
        guard let first = textures.first else { return }
        node.texture = first
        node.size = first.size()
        if textures.count > 1 { node.run(.repeatForever(.animate(with: textures, timePerFrame: timePerFrame, resize: true, restore: false)), withKey: "pose") }
    }

    private func prepareAuditNodes() {
        for node in [auditorNode, secretaryNode] where node.parent == nil {
            node.anchorPoint = CGPoint(x: 0.5, y: 0)
            node.zPosition = 8
            world.addChild(node)
        }
        if auditStage.parent == nil { world.addChild(auditStage) }
    }

    /// 감사 시작: 회사 문을 박차고 감사관(대머리)과 비서가 들어온다. 판정을 기다리는 동안(1~3분) 직원이 있는 층을 돌며 모니터를 들여다본다.
    func auditorEnter() {
        if auditPhase == .leaving { finishAuditNow() }   // 앞 감사가 아직 나가는 중이면 바로 정리하고 새로 시작
        guard !auditBusy else { return }
        auditBusy = true
        auditPhase = .entering
        prepareAuditNodes()
        tourPlan = []
        tourSeen = []
        tourLog = []
        auditTourStarted = activeTime
        for node in [auditorNode, secretaryNode] {
            node.removeAllActions()
            node.alpha = 0
            node.xScale = 1
        }
        auditorNode.texture = auditorTexture(.kick(0)); auditorNode.size = auditorNode.texture!.size()
        secretaryNode.texture = secretaryStand; secretaryNode.size = secretaryStand.size()
        auditorNode.position = CGPoint(x: CGFloat(BuildingLayout.doorX), y: line(1))
        secretaryNode.position = CGPoint(x: CGFloat(BuildingLayout.doorX) - 14, y: line(1))
        requestShot(Shot(target: .follow(auditorNode, zoom: 2.6), caption: "감사 · 감사관과 비서가 들어옵니다", duration: 40, priority: 3))
        let doorPoint = CGPoint(x: CGFloat(BuildingLayout.doorX), y: line(1) + 18)
        let headcount = sessions.count
        auditorNode.run(.sequence([
            .fadeIn(withDuration: 0.05), .wait(forDuration: 0.25),
            .run { [weak self] in
                guard let self else { return }
                self.auditorNode.texture = self.auditorTexture(.kick(1)); self.auditorNode.size = self.auditorNode.texture!.size()
                self.doorNode.texture = self.door(2)
                Effects.burst(in: self.world, at: doorPoint, color: PixelColor(0xE9DFCF), count: 16, spread: 18, rise: 14, duration: 0.7)
                self.staffSay(self.auditorNode, Variety.shared.line("auditorEnter", Lines.auditorEnter), style: .shout, seconds: 3)
            },
            .wait(forDuration: 0.8),
            .run { [weak self] in
                guard let self, self.auditPhase == .entering else { return }
                self.auditorNode.texture = self.auditorStand; self.auditorNode.size = self.auditorStand.size()
                self.doorNode.texture = self.door(1)
                self.secretaryNode.run(.sequence([.fadeIn(withDuration: 0.2), .run { [weak self] in
                    guard let self else { return }
                    self.staffSay(self.secretaryNode, "명단 \(headcount)명 가져왔습니다", style: .bubble, seconds: 2.5)
                }]), withKey: "fade")
                self.doorNode.run(.sequence([.wait(forDuration: 1.2), .setTexture(self.door(0))]))
                self.auditPhase = .touring
                self.auditTourNext()
            }
        ]), withKey: "enter")
    }

    /// 나가던 감사(또는 끊긴 감사)를 연출 없이 바로 정리한다(새 감사가 곧 시작될 때).
    private func finishAuditNow() {
        auditStage.removeAllActions()
        for node in [auditorNode, secretaryNode, instructorNode] {
            node.removeAllActions()
            node.removeFromParent()
            staffBubbles[ObjectIdentifier(node)]?.removeFromParent()
            staffBubbles[ObjectIdentifier(node)] = nil
            staffSpeakers[ObjectIdentifier(node)] = nil
        }
        if let run = auditRun { auditRun = nil; run.onFinish() }
        for (key, hold) in Array(auditHeld) where hold != .returning { auditRelease(key) }
        auditFetchQueue = []
        doorNode.texture = door(0)
        hallDoorNode.texture = door(0)
        auditBusy = false
        auditPhase = .idle
        auditorAtPost = false
        instructorAtFront = false
    }

    // MARK: 감사 — 순찰(판정 대기)

    /// 순찰 다음 걸음: 이번 바퀴 순서에서 아직 있는 사람의 책상으로 가서(층이 다르면 엘리베이터) 모니터를 들여다본다. 비서가 조금 뒤에 따라온다.
    private func auditTourNext() {
        guard auditPhase == .touring else { return }
        guard let key = nextTourKey(), let desk = layout.desks[key] else {
            // 볼 책상이 없다: 로비에서 판정을 기다리다가 다시 둘러본다
            staffTravel(auditorNode, walk: auditorWalk, stand: auditorStand, toFloor: 1, x: 150) {}
            staffTravel(secretaryNode, walk: secretaryWalk, stand: secretaryStand, toFloor: 1, x: 134) {}
            auditorNode.run(.sequence([.wait(forDuration: 6), .run { [weak self] in self?.auditTourNext() }]), withKey: "tour")
            return
        }
        let floor = desk.floor
        let x = CGFloat(desk.seatX) - 14
        let changed = staffFloor(auditorNode) != floor
        staffTravel(auditorNode, walk: auditorWalk, stand: auditorStand, toFloor: floor, x: x) { [weak self] in
            self?.auditorPeek(key)
        }
        // 비서는 감사관 왼쪽 15px. 엘리베이터 바로 옆 책상(층 첫 책상)은 설 자리가 없어 감사관과 겹치므로 따라가지 않고 다음 책상에서 합류한다.
        if x - 15 >= 40 {
            secretaryNode.run(.sequence([.wait(forDuration: 0.4), .run { [weak self] in
                guard let self, self.auditPhase == .touring else { return }
                self.staffTravel(self.secretaryNode, walk: self.secretaryWalk, stand: self.secretaryStand, toFloor: floor, x: x - 15) {}
            }]), withKey: "tour")
        }
        if changed, activeShot == nil, shotQueue.isEmpty {
            let rooms = layout.rooms.filter { $0.floor == floor }.map(\.name).prefix(3).joined(separator: " · ")
            requestShot(Shot(target: .follow(auditorNode, zoom: 2.4), caption: "감사 순찰 · " + (rooms.isEmpty ? "모니터 확인" : rooms), duration: 10, priority: 2))
        }
    }

    /// 이번 바퀴: 층 아래부터, 층마다 엘리베이터 쪽(왼쪽)부터 아직 안 본 사람 3명씩. 다 보면 처음부터 다시 돈다.
    private func nextTourKey() -> ProcessKey? {
        func present(_ key: ProcessKey) -> Bool {
            guard let worker = workers[key], !worker.leaving else { return false }
            return sessions[key] != nil && layout.desks[key] != nil
        }
        while !tourPlan.isEmpty {
            let key = tourPlan.removeFirst()
            if present(key) { return key }
        }
        let candidates = layout.desks.filter { present($0.key) }
        guard !candidates.isEmpty else { return nil }
        if candidates.keys.allSatisfy({ tourSeen.contains($0) }) { tourSeen.removeAll() }
        let fresh = candidates.filter { !tourSeen.contains($0.key) }
        let byFloor = Dictionary(grouping: fresh, by: { $0.value.floor })
        tourPlan = byFloor.keys.sorted().flatMap { floor in
            (byFloor[floor] ?? []).sorted { $0.value.deskX < $1.value.deskX }.prefix(3).map(\.key)
        }
        return tourPlan.isEmpty ? nil : tourPlan.removeFirst()
    }

    /// 모니터 들여다보기: 그 세션의 실제 값(상태 · 쉰 시간 · CPU · 메모리 · 하위 수)을 말풍선으로. 비서는 가끔 프로젝트를 적는다.
    private func auditorPeek(_ key: ProcessKey) {
        guard auditPhase == .touring else { return }
        tourSeen.insert(key)
        guard let session = sessions[key], let worker = workers[key] else { auditTourNext(); return }
        let atDesk = worker.place == .desk && !worker.busy && worker.route == nil
        let text = (atDesk ? "" : "빈자리 · ") + Self.peekLine(session, now: clock())
        tourLog.append((staffFloor(auditorNode), key, text))
        auditorNode.xScale = 1
        auditorNode.texture = auditorStand; auditorNode.size = auditorStand.size()
        staffSay(auditorNode, text, style: .bubble, seconds: 2.6)
        monitors[key]?.run(.sequence([.colorize(with: .white, colorBlendFactor: 0.45, duration: 0.12), .wait(forDuration: 0.6), .colorize(withColorBlendFactor: 0, duration: 0.25)]), withKey: "peek")
        if atDesk, session.state == .working, Variety.shared.chance(0.35) {
            worker.run(.sequence([.wait(forDuration: 1.2), .run { [weak self] in self?.say(key, Variety.shared.line("peeked", Lines.peeked), seconds: 2) }]), withKey: "peeked")
        }
        if tourLog.count % 3 == 1 {
            let note = "\(session.project) · \(session.kind.shortLabel) 확인"
            secretaryNode.run(.sequence([.wait(forDuration: 1.3), .run { [weak self] in
                guard let self, self.auditPhase == .touring else { return }
                self.staffSay(self.secretaryNode, note, style: .bubble, seconds: 1.8)
            }]), withKey: "note")
        }
        // 모니터 쪽으로 몸을 살짝 기울였다가 돌아와 다음 책상으로
        auditorNode.run(.sequence([.moveBy(x: 2, y: 0, duration: 0.15), .wait(forDuration: 2.3), .moveBy(x: -2, y: 0, duration: 0.15), .wait(forDuration: 0.3),
                                   .run { [weak self] in self?.auditTourNext() }]), withKey: "tour")
    }

    /// 순찰 말풍선(실제 값): "6일째 입력 대기 · 3.5GB" · "CPU 2% · 하위 2개" · "9시간째 쉼 · 5.3GB" · "터미널 없음 · 2.1GB".
    static func peekLine(_ session: AgentSession, now: Date) -> String {
        let quiet = max(0, now.timeIntervalSince(session.lastActivity ?? session.startTime))
        let since = shortAge(quiet) + "째"
        let memory = Fmt.gb(session.footprint)
        switch session.state {
        case .working:
            let cpu = "CPU \(Int(session.cpuPercent.rounded()))%"
            return session.childCount > 0 ? "\(cpu) · 하위 \(session.childCount)개" : "\(cpu) · \(memory)"
        case .waiting:
            return quiet < 60 ? "입력 대기 · \(memory)" : "\(since) 입력 대기 · \(memory)"
        case .idle, .longIdle:
            return quiet < 60 ? "쉬는 중 · \(memory)" : "\(since) 쉼 · \(memory)"
        case .orphan:
            return "터미널 없음 · \(memory)"
        }
    }

    /// 순찰을 그 자리에서 멈춘다(걷는 중 · 엘리베이터 안 · 들여다보는 중 어디서든). 다음 이동은 실제 높이에서 다시 출발한다.
    private func stopAuditTour() {
        for node in [auditorNode, secretaryNode] {
            node.removeAction(forKey: "tour")
            node.removeAction(forKey: "note")
            node.removeAction(forKey: "travel")
            node.removeAction(forKey: "enter")
            // 엘리베이터 문 앞에서 끊겼으면 칸 안에 있는 것으로 둔다(문 앞에 멈춰 서 있지 않게). 다음 이동이 거기서 타고 간다.
            if abs(node.position.x - CGFloat(BuildingLayout.elevatorX)) <= 6 { node.alpha = 0 }
        }
        tourPlan = []
    }

    /// 판정이 취소됐거나 끝났을 때(실행 연출이 끝났을 때도): 한마디 남기고 문으로 나간다. 순찰·실행 연출은 어디서든 멈추고,
    /// 붙잡고 있던 직원(교육생 · 퇴출 줄)은 평소 흐름으로 놓아준다. 실행 도중이었으면 남은 조치는 부르는 쪽(장부)이 마무리한다(onFinish).
    func auditorLeave(line: String? = nil) {
        guard auditBusy, auditPhase != .leaving else { return }
        if auditPhase == .entering { doorNode.run(.sequence([.wait(forDuration: 1.0), .setTexture(door(0))])) }
        stopAuditTour()
        auditStage.removeAllActions()
        auditorNode.removeAction(forKey: "after")
        if let run = auditRun { auditRun = nil; run.onFinish() }
        for (key, hold) in Array(auditHeld) where hold != .returning { auditRelease(key) }
        auditFetchQueue = []
        instructorLeave()
        auditPhase = .leaving
        auditorAtPost = false
        hallDoorNode.run(.sequence([.wait(forDuration: 1.5), .setTexture(door(0))]))
        let text = line ?? Variety.shared.line("auditorDone", Lines.auditorDone)
        staffSay(auditorNode, text, style: .bubble, seconds: 2.5)
        let door = CGFloat(BuildingLayout.doorX)
        staffTravel(auditorNode, walk: auditorWalk, stand: auditorStand, toFloor: 1, x: door) { [weak self] in
            guard let self else { return }
            self.doorNode.texture = self.door(1)
            self.auditorNode.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]), withKey: "fade")
        }
        secretaryNode.run(.sequence([.wait(forDuration: 0.5), .run { [weak self] in
            guard let self else { return }
            self.staffTravel(self.secretaryNode, walk: self.secretaryWalk, stand: self.secretaryStand, toFloor: 1, x: door) { [weak self] in
                guard let self else { return }
                // 끝 정리는 노드를 빼기 전에(빠진 노드의 동작은 더 돌지 않는다)
                self.secretaryNode.run(.sequence([.fadeOut(withDuration: 0.3), .run { [weak self] in
                    guard let self, self.auditPhase == .leaving else { return }
                    self.doorNode.texture = self.door(0)
                    self.auditBusy = false
                    self.auditPhase = .idle
                }, .removeFromParent()]), withKey: "fade")
            }
        }]), withKey: "tour")
    }

    /// 안전망(1초마다, 장면이 실제로 돈 시간): 실행 연출이 150초 넘게 끝나지 않거나 순찰이 6분 넘게 이어지면(판정 호출이 오지 않음) 마무리하고 나간다.
    private func auditWatch() {
        switch auditPhase {
        case .acting where auditRun != nil && activeTime - auditStageStarted > 150: auditorLeave(line: "오늘은 여기까지")
        case .touring where activeTime - auditTourStarted > 360: auditorLeave(line: "판정이 늦네요, 다음에 봅시다")
        default: break
        }
    }

    // MARK: 감사 — 판정 실행(강당 · 정신교육실)

    /// 판정 실행 연출. 실제 조치는 부르는 쪽이 넘긴 손잡이로 그 순간에 한다(판정마다 한 번):
    /// · 재교육: 정신교육실 수업 끝 "지시 보냅니다!" 순간에 onReeducate(교실에 못 온 대상 포함). 돌려주는 값 = 실제로 지시를 보냈는가.
    /// · 퇴출: 강당 단상에서 이름(사유)을 부르는 순간 onEvict. 돌려주는 값 = 끌려 나가는 연출을 할지(드라이런 · 결정 뒤 일을 시작함 → false, 놓아준다).
    /// 끝나면(도중에 그만둬도) onFinish. 흐름: 강당 급습 → 모으기(30초 안) → 정신교육(약 16초) → 퇴출 → 칭찬(짧게) → 퇴장, 보통 90초 안.
    func auditorExecute(reeducate: [AuditCall], evict: [AuditCall], praise: [AuditCall],
                        onReeducate: @escaping (ProcessKey) -> Bool, onEvict: @escaping (ProcessKey) -> Bool, onFinish: @escaping () -> Void) {
        if let previous = auditRun { auditRun = nil; previous.onFinish() }
        if !auditBusy || auditPhase == .leaving { auditorAppear() }
        let run = AuditRun(reeducate: reeducate, evict: evict, praise: praise, onReeducate: onReeducate, onEvict: onEvict, onFinish: onFinish)
        auditRun = run
        guardDragsThisAudit = 0
        auditorAtPost = false
        auditStageStarted = activeTime
        auditorStormHall { [weak self] in self?.auditGather(run) }
    }

    /// 감사관이 없을 때(창이 감사 도중에 열림 · 순찰이 시한으로 끝남): 실행 연출을 위해 1층 문 앞에 바로 세운다.
    private func auditorAppear() {
        if auditPhase == .leaving { finishAuditNow() }
        prepareAuditNodes()
        auditBusy = true
        auditPhase = .touring
        for (node, x) in [(auditorNode, CGFloat(BuildingLayout.doorX) + 12), (secretaryNode, CGFloat(BuildingLayout.doorX) - 2)] {
            node.removeAllActions()
            node.position = CGPoint(x: x, y: line(1))
            node.alpha = 1
            node.xScale = 1
        }
        auditorNode.texture = auditorStand; auditorNode.size = auditorStand.size()
        secretaryNode.texture = secretaryStand; secretaryNode.size = secretaryStand.size()
    }

    /// 감사관이 강당으로 가서(순찰 중이면 그 자리에서 멈추고) 문을 박차고 들어간다. 완료 시 호출자가 판정 연출을 이어 간다.
    func auditorStormHall(completion: @escaping () -> Void) {
        guard auditBusy, auditPhase != .leaving else { completion(); return }
        if auditPhase == .entering { doorNode.run(.sequence([.wait(forDuration: 1.0), .setTexture(door(0))])) }
        stopAuditTour()
        auditPhase = .acting
        let hall = layout.hallIndex
        requestShot(Shot(target: .follow(auditorNode, zoom: 2.6), caption: "감사 · 대기실 문을 박차고 들어갑니다", duration: 10, priority: 3))
        let doorX = CGFloat(BuildingLayout.hallDoorX)
        staffTravel(auditorNode, walk: auditorWalk, stand: auditorStand, toFloor: hall, x: doorX - 10) { [weak self] in
            guard let self, self.auditPhase == .acting else { return }
            self.auditorNode.texture = self.auditorTexture(.kick(1)); self.auditorNode.size = self.auditorNode.texture!.size()
            self.hallDoorNode.texture = self.door(2)
            self.hallDoorNode.run(.sequence([.moveBy(x: -1, y: 0, duration: 0.04), .moveBy(x: 2, y: 0, duration: 0.04), .moveBy(x: -1, y: 0, duration: 0.04)]))
            Effects.burst(in: self.world, at: CGPoint(x: doorX, y: self.line(hall) + 18), color: PixelColor(0xE9DFCF), count: 16, spread: 18, rise: 14, duration: 0.7)
            self.staffSay(self.auditorNode, Variety.shared.line("auditorHall", ["다들 일어나!", "여기 다 뭐야?", "쉬는 사람 집합!", "누가 자고 있어?"]), style: .shout, seconds: 3)
            // 강당의 사람들: 화들짝
            for (key, worker) in self.workers {
                if case .rest(let spot) = worker.place, spot.kind == .hallSeat, !worker.busy, !worker.leaving, worker.route == nil {
                    worker.show(.stand(blink: false))
                    worker.face(right: false)
                    if Variety.shared.chance(0.5) { self.say(key, Variety.shared.line("startled", ["헉!", "저 안 잤어요!", "깼어요 깼어!", "…네?"]), seconds: 2.5, style: .shout) }
                }
            }
            self.auditorNode.run(.sequence([.wait(forDuration: 0.8), .run { [weak self] in
                guard let self, self.auditPhase == .acting else { return }
                self.auditorNode.texture = self.auditorStand; self.auditorNode.size = self.auditorStand.size()
                self.hallDoorNode.texture = self.door(1)
                self.staffTravel(self.secretaryNode, walk: self.secretaryWalk, stand: self.secretaryStand, toFloor: hall, x: doorX + 16) {}
                self.staffTravel(self.auditorNode, walk: self.auditorWalk, stand: self.auditorStand, toFloor: hall, x: doorX + 34, completion: completion)
            }]), withKey: "after")
        }
    }

    /// 모으기: 재교육 대상은 정신교육실 좌석으로(강당 층이면 걸어서, 다른 층이면 비서가 데리러 간다 — 가까운 두 층까지, 나머지는 스스로 온다),
    /// 퇴출 대상은 강당 단상 앞 줄로(강당 층이면 걸어서, 사무실이면 감사관이 끌고 내려온다 — 두 명까지, 나머지는 스스로 온다). 다 모이거나 30초가 지나면 다음.
    private func auditGather(_ run: AuditRun) {
        guard auditRun === run else { return }
        let hall = layout.hallIndex
        requestShot(Shot(target: .rect(regionRect(.hall)), caption: "감사 · 재교육 \(run.reeducate.count)명 → 정신교육실 · 퇴출 \(run.evict.count)명 → 강당", duration: 30, priority: 3))
        var remote: [Int: [ProcessKey]] = [:]
        var seat = 0
        for call in run.reeducate where seat < AuditSpot.studentsMax {
            guard let worker = workers[call.key], !worker.leaving else { continue }
            hold(worker, .student(seat))
            if worker.floorIndex == hall { sendToClass(worker, seat: seat) } else { remote[worker.floorIndex, default: []].append(call.key) }
            seat += 1
        }
        if seat > 0 { instructorEnter() }
        let floors = remote.keys.sorted { abs($0 - hall) != abs($1 - hall) ? abs($0 - hall) < abs($1 - hall) : $0 < $1 }
        for floor in floors.dropFirst(2) { (remote[floor] ?? []).forEach(sendHeldToClass) }
        secretaryFetch(Array(floors.prefix(2)), remote: remote)
        var slot = 0
        var offices: [ProcessKey] = []
        for call in run.evict where slot < AuditSpot.lineMax {
            guard let worker = workers[call.key], !worker.leaving else { continue }
            hold(worker, .lineup(slot))
            if worker.floorIndex == hall { sendToLine(worker, slot: slot) } else { offices.append(call.key) }
            slot += 1
        }
        let ordered = offices.sorted { lhs, rhs in
            let l = workers[lhs]?.floorIndex ?? 0, r = workers[rhs]?.floorIndex ?? 0
            return l != r ? abs(l - hall) < abs(r - hall) : (workers[lhs]?.position.x ?? 0) < (workers[rhs]?.position.x ?? 0)
        }
        ordered.dropFirst(2).forEach(sendHeldToLine)
        auditFetchQueue = Array(ordered.prefix(2))
        auditorFetchNext()
        auditWhen({ [weak self] in self?.gathered(run) ?? true }, timeout: 30) { [weak self] in self?.auditLesson(run) }
    }

    /// 실행 연출이 직원을 붙잡는다(busy — 스냅샷 조정이 자리를 옮기지 않음). 쉬던 자리(놀이 · 강당 좌석)는 내놓는다.
    private func hold(_ worker: WorkerNode, _ role: AuditHold) {
        auditHeld[worker.key] = role
        worker.busy = true
        worker.clearGhost()
        playSeats[worker.key] = nil
        hallSeatOf[worker.key] = nil
        if case .student(let seat) = role { classSeatOf[worker.key] = seat }
    }

    /// 붙잡았던 직원을 놓아준다: 지금 상태의 자리로 보낸다(세션이 끝났으면 퇴근). 이후는 평소 흐름(스냅샷 조정).
    private func auditRelease(_ key: ProcessKey) {
        auditHeld[key] = nil
        classSeatOf[key] = nil
        guard let worker = workers[key], !worker.leaving else { return }
        worker.removeAction(forKey: "reeducation")
        worker.busy = false
        worker.zPosition = 5
        guard let session = sessions[key] else { depart(worker); return }
        let target = targetPlace(session)
        if (target.place == worker.place || Self.sameSpot(target.place, worker.place)), target.floor == worker.floorIndex, abs(target.x - worker.vx) <= 1 {
            settle(worker)
            return
        }
        travel(worker, toFloor: target.floor, x: target.x, place: target.place) { [weak self, weak worker] in
            guard let self, let worker else { return }
            worker.place = target.place
            self.settle(worker)
        }
    }

    /// 교육실 자리: 좌석 4개(layout.classSeats), 차면 책상 사이에 선다.
    private func classPoint(_ seat: Int) -> (spot: BuildingLayout.Spot, x: CGFloat, seated: Bool) {
        let seats = layout.classSeats
        if seat < seats.count { return (seats[seat], CGFloat(seats[seat].x), true) }
        let x = AuditSpot.standExtras[min(AuditSpot.standExtras.count - 1, seat - seats.count)]
        return (BuildingLayout.Spot(kind: .standing, floor: layout.hallIndex, x: Int(x)), x, false)
    }

    /// 강사가 학생에게 다가가 서는 자리: 그 학생 책상 앞(학생 바로 오른쪽, 책상을 사이에 두고 마주 본다). 옆 학생과 겹치지 않는 유일한 틈이다.
    private func counselX(_ seat: Int) -> CGFloat { min(CGFloat(BuildingLayout.wingX1) - 4, classPoint(seat).x + 14) }

    private func linePoint(_ slot: Int) -> CGFloat { AuditSpot.lineX0 - CGFloat(slot) * AuditSpot.linePitch }

    private func sendToClass(_ worker: WorkerNode, seat: Int) {
        let point = classPoint(seat)
        let hall = layout.hallIndex
        travel(worker, toFloor: hall, x: point.x, place: .rest(point.spot)) { [weak self, weak worker] in
            guard let self, let worker, case .student = self.auditHeld[worker.key] else { return }
            worker.place = .rest(point.spot)
            worker.position = CGPoint(x: point.x, y: self.line(hall))
            worker.vx = point.x
            worker.face(right: true)   // 책상 너머 강사(교육실 오른쪽 끝) 쪽
            worker.zPosition = 6
            if point.seated { worker.show(.sitWait) } else { worker.show(.stand(blink: false)) }
        }
    }

    private func sendHeldToClass(_ key: ProcessKey) {
        guard let worker = workers[key], !worker.leaving, case .student(let seat) = auditHeld[key] else { return }
        sendToClass(worker, seat: seat)
    }

    private func sendToLine(_ worker: WorkerNode, slot: Int) {
        let x = linePoint(slot)
        travel(worker, toFloor: layout.hallIndex, x: x, place: .rest(BuildingLayout.Spot(kind: .standing, floor: layout.hallIndex, x: Int(x)))) { [weak self, weak worker] in
            guard let self, let worker, case .lineup = self.auditHeld[worker.key] else { return }
            self.standInLine(worker, x: x)
        }
    }

    private func sendHeldToLine(_ key: ProcessKey) {
        guard let worker = workers[key], !worker.leaving, case .lineup(let slot) = auditHeld[key] else { return }
        sendToLine(worker, slot: slot)
    }

    /// 퇴출 줄에 선다: 단상(감사관) 쪽을 보고. 고아 세션은 유령 그대로.
    private func standInLine(_ worker: WorkerNode, x: CGFloat) {
        let hall = layout.hallIndex
        worker.place = .rest(BuildingLayout.Spot(kind: .standing, floor: hall, x: Int(x)))
        worker.floorIndex = hall
        worker.position = CGPoint(x: x, y: line(hall))
        worker.vx = x
        worker.face(right: true)
        worker.zPosition = 6
        if sessions[worker.key]?.state == .orphan { worker.showGhost() } else { worker.show(.stand(blink: false)) }
    }

    /// 비서가 다른 층의 재교육 대상을 데리러 간다(가까운 층부터): 그 층에서 부르면 대상이 교육실로 내려오고, 비서는 다음 층으로. 끝나면 교육실 옆에 선다.
    private func secretaryFetch(_ floors: [Int], remote: [Int: [ProcessKey]]) {
        guard auditPhase == .acting else { return }
        guard let floor = floors.first else {
            staffTravel(secretaryNode, walk: secretaryWalk, stand: secretaryStand, toFloor: layout.hallIndex, x: AuditSpot.secretaryHall) {}
            return
        }
        let keys = (remote[floor] ?? []).filter { workers[$0].map { !$0.leaving } ?? false }
        let firstX = keys.compactMap { workers[$0]?.position.x }.min() ?? 120
        staffTravel(secretaryNode, walk: secretaryWalk, stand: secretaryStand, toFloor: floor, x: max(40, firstX - 16)) { [weak self] in
            guard let self, self.auditPhase == .acting else { return }
            let name = keys.first.flatMap { self.sessions[$0]?.project } ?? ""
            self.staffSay(self.secretaryNode, (name.isEmpty ? "" : "\(name) · ") + Variety.shared.line("fetch", Lines.secretaryFetch), style: .bubble, seconds: 2.2)
            keys.forEach(self.sendHeldToClass)
            self.secretaryNode.run(.sequence([.wait(forDuration: 0.8), .run { [weak self] in self?.secretaryFetch(Array(floors.dropFirst()), remote: remote) }]), withKey: "fetch")
        }
    }

    /// 감사관: 사무실에 남은 퇴출 대상을 한 명씩 끌고 내려온다. 끝나면 단상(퇴출 대상이 있으면) 또는 교육실이 보이는 자리로.
    private func auditorFetchNext() {
        guard auditPhase == .acting, auditRun != nil else { return }
        guard !auditFetchQueue.isEmpty else { auditorToPost(); return }
        let key = auditFetchQueue.removeFirst()
        guard let worker = workers[key], !worker.leaving, case .lineup(let slot) = auditHeld[key] else { auditorFetchNext(); return }
        let hall = layout.hallIndex
        let project = sessions[key]?.project ?? "세션"
        requestShot(Shot(target: .follow(auditorNode, zoom: 2.4), caption: "감사 · \(project) 끌고 내려오기", duration: 14, priority: 3))
        staffTravel(auditorNode, walk: auditorWalk, stand: auditorStand, toFloor: worker.floorIndex, x: max(40, worker.position.x - 16), speed: 60) { [weak self] in
            guard let self, self.auditPhase == .acting else { return }
            guard let worker = self.workers[key], !worker.leaving, self.auditHeld[key] == .lineup(slot) else { self.auditorFetchNext(); return }
            self.auditorNode.xScale = 1
            self.staffPose(self.auditorNode, [self.auditorTexture(.scold(0)), self.auditorTexture(.scold(1))])
            self.staffSay(self.auditorNode, "\(project) · 강당으로!", style: .shout, seconds: 1.8)
            worker.face(right: false)
            worker.show(.stand(blink: false))
            self.auditorNode.run(.sequence([.wait(forDuration: 1.2), .run { [weak self] in
                guard let self else { return }
                guard let worker = self.workers[key], !worker.leaving, self.auditHeld[key] == .lineup(slot) else { self.auditorFetchNext(); return }
                self.auditorDrag(worker, toFloor: hall, x: self.linePoint(slot)) { [weak self] in
                    guard let self else { return }
                    if let worker = self.workers[key], self.auditHeld[key] == .lineup(slot) { self.standInLine(worker, x: self.linePoint(slot)) }
                    self.auditorFetchNext()
                }
            }]), withKey: "after")
        }
    }

    /// 감사관 자리: 퇴출 대상이 있으면 단상(줄을 본다), 없으면 교육실이 보이는 무대 오른쪽.
    private func auditorToPost() {
        guard let run = auditRun else { return }
        let lineup = !run.evict.isEmpty
        staffTravel(auditorNode, walk: auditorWalk, stand: auditorStand, toFloor: layout.hallIndex, x: lineup ? AuditSpot.podium : AuditSpot.watch) { [weak self] in
            guard let self else { return }
            self.auditorNode.xScale = lineup ? -1 : 1
            self.auditorAtPost = true
        }
    }

    /// 감사관이 직원을 끌고 간다: 직원이 끌려가는 길(엘리베이터 포함)을 감사관이 앞장서 같이 간다. 층 이동은 travel과 같은 순서(문 열림 → 사라짐 → 다른 층에서 나타남).
    private func auditorDrag(_ worker: WorkerNode, toFloor destination: Int, x target: CGFloat, completion: @escaping () -> Void) {
        let shaft = CGFloat(BuildingLayout.elevatorX)
        let speed: CGFloat = 40
        let from = worker.floorIndex
        let kind = layout.floors[clampFloor(destination)].kind
        stopTravel(worker)
        worker.clearGhost()
        setBubble(worker.key, nil)
        worker.route = WorkerNode.Route(floor: kind, x: target, place: nil)
        worker.loop([.dragged(0), .dragged(1)], fps: 6)
        auditorNode.removeAction(forKey: "pose")
        auditorNode.removeAction(forKey: "travel")
        let walk = auditorWalk
        func segment(to x: CGFloat, from start: CGFloat) -> SKAction {
            let right = x > start
            let duration = TimeInterval(max(0.05, abs(x - start) / speed))
            return .sequence([
                .run { [weak self, weak worker] in
                    guard let self, let worker else { return }
                    worker.face(right: !right)   // 끌려가는 쪽: 발이 뒤로 끌린다
                    let lead: CGFloat = right ? 13 : -13
                    self.auditorNode.xScale = right ? 1 : -1
                    self.auditorNode.position = CGPoint(x: worker.position.x + lead, y: worker.position.y)
                    self.auditorNode.run(.group([.moveTo(x: x + lead, duration: duration),
                                                 .repeat(.animate(with: walk, timePerFrame: 0.12, resize: true, restore: false), count: max(1, Int(duration / 0.48)))]), withKey: "travel")
                },
                .moveTo(x: x, duration: duration),
                .run { [weak worker] in worker?.vx = x }
            ])
        }
        var steps: [SKAction] = []
        if abs(worker.position.y - line(from)) > 0.5 { steps.append(.moveTo(y: line(from), duration: 0.15)) }
        if from != clampFloor(destination) {
            steps.append(segment(to: shaft, from: worker.position.x))
            steps.append(.run { [weak self] in
                guard let self else { return }
                self.openElevator(from)
                self.auditorNode.run(.fadeOut(withDuration: 0.2), withKey: "fade")
            })
            steps.append(.fadeOut(withDuration: 0.2))
            steps.append(.wait(forDuration: 0.35 * Double(abs(clampFloor(destination) - from)) + 0.2))
            steps.append(.run { [weak self, weak worker] in
                guard let self, let worker else { return }
                let arrival = self.layout.floors.firstIndex { $0.kind == kind } ?? self.clampFloor(destination)
                self.place(worker, floor: arrival, x: shaft)
                self.auditorNode.position = CGPoint(x: shaft + 13, y: self.line(arrival))
                self.openElevator(arrival)
                self.auditorNode.run(.fadeIn(withDuration: 0.2), withKey: "fade")
            })
            steps.append(.fadeIn(withDuration: 0.2))
            steps.append(segment(to: target, from: shaft))
        } else {
            steps.append(segment(to: target, from: worker.position.x))
        }
        steps.append(.run { [weak self, weak worker] in
            worker?.route = nil
            self?.auditorNode.texture = self?.auditorStand
        })
        steps.append(.run(completion))
        worker.run(.sequence(steps), withKey: "move")
    }

    /// 다 모였나: 교육생은 좌석에, 퇴출 대상은 줄에(끝난 세션은 빼고), 강사는 교실 앞에, 감사관은 자기 자리에.
    private func gathered(_ run: AuditRun) -> Bool {
        let hall = layout.hallIndex
        for (key, hold) in auditHeld {
            guard let worker = workers[key], !worker.leaving else { continue }
            let x: CGFloat
            switch hold {
            case .student(let seat): x = classPoint(seat).x
            case .lineup(let slot): x = linePoint(slot)
            case .returning: continue
            }
            if worker.floorIndex != hall || abs(worker.position.x - x) > 1 || worker.action(forKey: "move") != nil { return false }
        }
        let students = auditHeld.values.contains { if case .student = $0 { return true } else { return false } }
        return auditorAtPost && (!students || instructorAtFront)
    }

    /// 조건이 맞거나 시한이 지나면 한 번 이어 간다(장면 시계 — 창이 닫혀 멈추면 같이 멈춘다).
    private func auditWhen(_ condition: @escaping () -> Bool, timeout: TimeInterval, _ block: @escaping () -> Void) {
        auditWaitSerial += 1
        let key = "when-\(auditWaitSerial)"
        let deadline = activeTime + timeout
        auditStage.run(.repeatForever(.sequence([.wait(forDuration: 0.25), .run { [weak self] in
            guard let self, self.auditStage.action(forKey: key) != nil else { return }
            guard condition() || self.activeTime >= deadline else { return }
            self.auditStage.removeAction(forKey: key)
            block()
        }])), withKey: key)
    }

    // MARK: 감사 — 정신교육실 수업

    /// 강사: 교육실 문(왼쪽)으로 들어와 교실 앞(오른쪽 끝)에 선다. 수업이 있을 때만 나온다.
    private func instructorEnter() {
        if instructorNode.parent == nil {
            instructorNode.anchorPoint = CGPoint(x: 0.5, y: 0)
            instructorNode.zPosition = 8
            world.addChild(instructorNode)
        }
        instructorNode.removeAllActions()
        instructorAtFront = false
        instructorNode.texture = instructorStand; instructorNode.size = instructorStand.size()
        instructorNode.position = CGPoint(x: AuditSpot.classDoor, y: line(layout.hallIndex))
        instructorNode.alpha = 0
        instructorNode.xScale = 1
        staffTravel(instructorNode, walk: instructorWalk, stand: instructorStand, toFloor: layout.hallIndex, x: AuditSpot.instructorFront) { [weak self] in
            guard let self else { return }
            self.instructorNode.xScale = -1   // 학생들(왼쪽)을 본다
            self.instructorAtFront = true
        }
    }

    /// 수업이 끝나면(또는 감사를 그만두면) 강사는 교육실 문으로 나간다.
    private func instructorLeave() {
        guard instructorNode.parent != nil, instructorNode.action(forKey: "leave") == nil else { return }
        instructorAtFront = false
        instructorNode.removeAction(forKey: "lesson")
        instructorNode.removeAction(forKey: "reply")
        staffTravel(instructorNode, walk: instructorWalk, stand: instructorStand, toFloor: layout.hallIndex, x: AuditSpot.classDoor) { [weak self] in
            guard let self else { return }
            self.instructorNode.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]), withKey: "leave")
        }
    }

    /// 수업 한 박자: (필요하면 먼저 걸어가서) 자세 · 말풍선 · 학생 대답.
    private struct LessonBeat {
        var x: CGFloat
        var pose: [WorkerPose]
        var text: String
        var seconds: TimeInterval
        var reply: ProcessKey? = nil
    }

    private func playLesson(_ beats: [LessonBeat], run: AuditRun, then: @escaping () -> Void) {
        guard auditRun === run else { return }
        guard let beat = beats.first else { then(); return }
        let rest = Array(beats.dropFirst())
        let perform: () -> Void = { [weak self] in
            guard let self, self.auditRun === run else { return }
            self.instructorNode.xScale = -1
            self.staffPose(self.instructorNode, beat.pose.map(self.instructorTexture), timePerFrame: 0.3)
            self.staffSay(self.instructorNode, beat.text, style: .bubble, seconds: beat.seconds)
            if let student = beat.reply {
                self.instructorNode.run(.sequence([.wait(forDuration: 1.3), .run { [weak self] in
                    self?.say(student, Variety.shared.line("reply", Lines.studentReply), seconds: 2.0)
                }]), withKey: "reply")
            }
            self.instructorNode.run(.sequence([.wait(forDuration: beat.seconds + 0.2), .run { [weak self] in
                self?.playLesson(rest, run: run, then: then)
            }]), withKey: "lesson")
        }
        if abs(instructorNode.position.x - beat.x) > 1 || abs(instructorNode.position.y - line(layout.hallIndex)) > 0.5 {
            staffTravel(instructorNode, walk: instructorWalk, stand: instructorStand, toFloor: layout.hallIndex, x: beat.x, completion: perform)
        } else {
            perform()
        }
    }

    /// 정신교육(약 16초): 훈계(실제 값) → 상담(한 학생, 판정 사유 · 학생 대답) → 어르기(하던 일 제목) → 달래기 → "지시 보냅니다!" 순간 실제 전송 → 자리로.
    private func auditLesson(_ run: AuditRun) {
        guard auditRun === run else { return }
        guard !run.reeducate.isEmpty else { auditEvict(run); return }
        let hall = layout.hallIndex
        let students = auditHeld.compactMap { key, hold -> (key: ProcessKey, seat: Int)? in
            guard case .student(let seat) = hold, let worker = workers[key], !worker.leaving else { return nil }
            return (key, seat)
        }.sorted { $0.seat < $1.seat }
        let seated = students.filter { student in
            guard let worker = workers[student.key] else { return false }
            return worker.floorIndex == hall && abs(worker.position.x - classPoint(student.seat).x) <= 1 && worker.action(forKey: "move") == nil
        }
        guard let first = seated.first, instructorNode.parent != nil else {
            // 교실에 아무도 못 왔다(모두 퇴근 등): 연출 없이 지시만 보내고 넘어간다
            lessonClimax(run, students: students.map(\.key))
            auditStage.run(.sequence([.wait(forDuration: 1.0), .run { [weak self] in self?.auditEvict(run) }]))
            return
        }
        let second = seated.count > 1 ? seated[1] : first
        let classRect = CGRect(x: CGFloat(BuildingLayout.wingX0) - 60, y: CGFloat(layout.floors[hall].y) - 2, width: CGFloat(BuildingLayout.wingX1 - BuildingLayout.wingX0) + 66, height: CGFloat(layout.floors[hall].height) + 10)
        requestShot(Shot(target: .rect(classRect), caption: "정신교육 · \(students.count)명 · 강사가 훈계 · 상담 · 달래기", duration: 18, priority: 3))
        let inClass = students.compactMap { sessions[$0.key] }
        let memory = inClass.reduce(UInt64(0)) { $0 + $1.footprint }
        let longest = inClass.map { max(0, clock().timeIntervalSince($0.lastActivity ?? $0.startTime)) }.max() ?? 0
        let lecture = longest >= 60 && Variety.shared.chance(0.5) ? "제일 오래 쉰 분은 \(Self.shortAge(longest))째예요" : "\(inClass.count)명 합쳐 \(Fmt.gb(memory)) 들고 쉬었어요"
        let reason = run.reeducate.first { $0.key == first.key }?.reason ?? ""
        let title = sessions[second.key]?.title.map { String($0.prefix(10)) }
        let beats = [
            LessonBeat(x: AuditSpot.instructorFront, pose: [.scold(0), .scold(1)], text: lecture, seconds: 3.0),
            LessonBeat(x: counselX(first.seat), pose: [.stand(blink: false)], text: Variety.shared.line("counsel", Lines.lessonCounsel) + (reason.isEmpty ? "" : " · \(reason)"), seconds: 3.0, reply: first.key),
            LessonBeat(x: counselX(second.seat), pose: [.wave(0), .wave(1)], text: title.map { "'\($0)' 마무리만 하면 돼요" } ?? Variety.shared.line("coax", Lines.lessonCoax), seconds: 2.8),
            LessonBeat(x: AuditSpot.instructorFront, pose: [.clap(0), .clap(1)], text: Variety.shared.line("soothe", Lines.lessonSoothe), seconds: 2.6),
        ]
        playLesson(beats, run: run) { [weak self] in
            guard let self, self.auditRun === run else { return }
            self.lessonClimax(run, students: students.map(\.key))
            self.auditStage.run(.sequence([.wait(forDuration: 2.4), .run { [weak self] in self?.auditEvict(run) }]))
        }
    }

    /// 수업 끝 "지시 보냅니다!": 이 순간 재교육 판정마다 실제 지시를 한 번씩 보낸다(교실에 못 온 대상 포함). 학생들은 벌떡 일어나 자기 책상으로.
    private func lessonClimax(_ run: AuditRun, students: [ProcessKey]) {
        var delivered: [ProcessKey: Bool] = [:]
        for call in run.reeducate where !run.reeducated.contains(call.key) {
            run.reeducated.insert(call.key)
            delivered[call.key] = run.onReeducate(call.key)
        }
        if instructorNode.parent != nil {
            staffPose(instructorNode, [instructorTexture(.shout(0)), instructorTexture(.shout(1))], timePerFrame: 0.15)
            staffSay(instructorNode, delivered.values.contains(true) ? Variety.shared.line("climax", Lines.lessonClimax) : "오늘은 연습만 합니다", style: .shout, seconds: 2.0)
            instructorNode.run(.sequence([.wait(forDuration: 2.0), .run { [weak self] in self?.instructorLeave() }]), withKey: "lesson")
        }
        for (index, key) in students.enumerated() {
            guard let worker = workers[key], !worker.leaving, case .student = auditHeld[key] else { continue }
            let sent = delivered[key] ?? false
            Effects.sparkle(in: world, at: CGPoint(x: worker.position.x, y: worker.position.y + worker.spriteHeight + 4))
            if worker.action(forKey: "move") == nil { worker.show(.stand(blink: false)) }
            worker.run(.sequence([
                .wait(forDuration: 0.15 * Double(index)),
                .run { [weak self] in self?.say(key, Variety.shared.line("reeducated", Lines.reeducated), seconds: 1.5, style: .shout) },
                .wait(forDuration: 1.4),
                .run { [weak self, weak worker] in
                    guard let self, let worker else { return }
                    self.returnToDesk(worker, waitForWork: sent)
                }
            ]), withKey: "reeducation")
        }
    }

    /// 교육을 마친 직원: 자기 책상으로 돌아가 앉는다. 지시를 받은 세션이 일을 시작하면(상태가 일함 · 입력 대기) 그대로 평소 흐름으로,
    /// 30초 안에 시작하지 않으면(지시를 못 보냈으면 바로) 평소 흐름(지금 상태의 자리)으로 놓아준다.
    private func returnToDesk(_ worker: WorkerNode, waitForWork: Bool) {
        let key = worker.key
        classSeatOf[key] = nil
        guard let desk = layout.desks[key], sessions[key] != nil else { auditRelease(key); return }
        auditHeld[key] = .returning
        travel(worker, toFloor: desk.floor, x: CGFloat(desk.seatX), place: .desk) { [weak self, weak worker] in
            guard let self, let worker, self.auditHeld[key] == .returning else { return }
            worker.place = .desk
            worker.position = CGPoint(x: worker.vx, y: self.line(worker.floorIndex))
            worker.face(right: true)
            worker.zPosition = 5
            worker.show(.sitWait)
            guard waitForWork else { self.auditRelease(key); return }
            let deadline = self.activeTime + 30
            worker.run(.repeatForever(.sequence([.wait(forDuration: 1), .run { [weak self] in
                guard let self, self.auditHeld[key] == .returning else { return }
                let state = self.sessions[key]?.state
                if state == .working || state == .waiting || self.activeTime >= deadline { self.auditRelease(key) }
            }])), withKey: "reeducation")
        }
    }

    /// 수업 도중 세션이 스스로 일을 시작하면(상태 변화) 교실에서 바로 자기 자리로 돌아간다.
    private func finishReeducation(_ worker: WorkerNode) {
        guard classSeatOf[worker.key] != nil else { return }
        classSeatOf[worker.key] = nil
        auditHeld[worker.key] = nil
        worker.removeAction(forKey: "reeducation")
        guard let session = sessions[worker.key] else { worker.busy = false; return }
        let target = targetPlace(session)
        travel(worker, toFloor: target.floor, x: target.x, place: target.place) { [weak self, weak worker] in
            guard let self, let worker else { return }
            worker.busy = false
            worker.zPosition = 5
            worker.place = target.place
            self.settle(worker)
        }
        say(worker.key, Variety.shared.line("reeducated", Lines.reeducated), seconds: 2.5)
    }

    // MARK: 감사 — 강당 퇴출 · 칭찬 · 마무리

    /// 퇴출(강당): 단상에서 연설(인원 · 합계 메모리) → 한 명씩 이름(사유)을 부르는 순간 onEvict(실제 정리) → 경비원이 차례로 끌고 나간다(세 명까지,
    /// 나머지는 줄지어 스스로 나간다). 실제로 정리하지 않으면(드라이런 · 결정 뒤 상태 변화) 놓아준다. 여섯 명이 넘으면 나머지는 한 번에 부른다.
    private func auditEvict(_ run: AuditRun) {
        guard auditRun === run else { return }
        guard !run.evict.isEmpty else { auditPraise(run); return }
        let hall = layout.hallIndex
        let present = run.evict.map(\.key).filter { key in
            guard let worker = workers[key], !worker.leaving, case .lineup = auditHeld[key] else { return false }
            return worker.floorIndex == hall
        }
        let memory = present.compactMap { sessions[$0]?.footprint }.reduce(UInt64(0), +)
        staffTravel(auditorNode, walk: auditorWalk, stand: auditorStand, toFloor: hall, x: AuditSpot.podium) { [weak self] in
            guard let self, self.auditRun === run else { return }
            self.auditorAtPost = true
            self.auditorNode.xScale = -1
            let floor = self.layout.floors[hall]
            self.requestShot(Shot(target: .rect(CGRect(x: 30, y: CGFloat(floor.y) - 2, width: CGFloat(BuildingLayout.mainX1) - 24, height: CGFloat(floor.height) + 10)),
                                  caption: "퇴출 · \(run.evict.count)명" + (memory > 0 ? " · \(Fmt.gb(memory))" : ""), duration: 8 + 2.2 * Double(min(6, run.evict.count)), priority: 3))
            self.staffPose(self.auditorNode, [self.auditorTexture(.shout(0)), self.auditorTexture(.shout(1))], timePerFrame: 0.3)
            let speech = Variety.shared.line("speech", Lines.auditorSpeech)
            self.staffSay(self.auditorNode, present.isEmpty ? speech : "\(present.count)명 · \(Fmt.gb(memory)) · \(speech)", style: .shout, seconds: 3.0)
            for key in present {
                guard let worker = self.workers[key] else { continue }
                worker.face(right: true)
                if !worker.ghost { worker.show(.stand(blink: false)) }
            }
            self.auditorNode.run(.sequence([.wait(forDuration: 3.2), .run { [weak self] in self?.evictNext(run) }]), withKey: "after")
        }
    }

    private func evictNext(_ run: AuditRun) {
        guard auditRun === run else { return }
        let remaining = run.evict.filter { !run.evicted.contains($0.key) }
        guard let call = remaining.first else {
            auditorNode.run(.sequence([.wait(forDuration: 0.8), .run { [weak self] in self?.auditPraise(run) }]), withKey: "after")
            return
        }
        if run.evicted.count < 6 || remaining.count == 1 {
            let project = sessions[call.key]?.project ?? "세션"
            staffPose(auditorNode, [auditorTexture(.scold(0)), auditorTexture(.scold(1))])
            staffSay(auditorNode, "\(project) · \(call.reason)", style: .shout, seconds: 1.8)
            fireEvict(run, call.key)
            auditorNode.run(.sequence([.wait(forDuration: 2.0), .run { [weak self] in self?.evictNext(run) }]), withKey: "after")
        } else {
            staffPose(auditorNode, [auditorTexture(.scold(0)), auditorTexture(.scold(1))])
            staffSay(auditorNode, "나머지 \(remaining.count)명도 정리합니다", style: .shout, seconds: 2.0)
            remaining.forEach { fireEvict(run, $0.key) }
            auditorNode.run(.sequence([.wait(forDuration: 2.2), .run { [weak self] in self?.evictNext(run) }]), withKey: "after")
        }
    }

    /// 이름을 부르는 순간: 실제 조치(onEvict, 한 번). 정리 연출을 하면 경비원 차례(세 명까지) 또는 단체 퇴장, 아니면 놓아준다.
    private func fireEvict(_ run: AuditRun, _ key: ProcessKey) {
        guard !run.evicted.contains(key) else { return }
        run.evicted.insert(key)
        let animate = run.onEvict(key)
        guard let worker = workers[key], !worker.leaving else { auditHeld[key] = nil; return }
        guard animate else {
            auditRelease(key)
            say(key, Variety.shared.line("spared", Lines.evictSpared), seconds: 2.2)
            return
        }
        auditHeld[key] = nil
        classSeatOf[key] = nil
        let shout = run.evictedLine(run.evicted.count - 1)
        if guardDragsThisAudit < 3 {
            guardDragsThisAudit += 1
            evict(worker, shout: shout, camera: false)
        } else {
            marchOut(worker, shout: shout)
        }
    }

    /// 단체 퇴출: 경비원 차례를 기다리지 않고 외치며 1층 문으로 걸어 나간다. 문에서 먼지와 함께 밖으로.
    private func marchOut(_ worker: WorkerNode, shout: String) {
        worker.leaving = true
        worker.busy = true
        worker.leavingSince = activeTime
        worker.clearGhost()
        travel(worker, toFloor: 1, x: CGFloat(BuildingLayout.doorX) + 4) { [weak self, weak worker] in
            guard let self, let worker else { return }
            self.doorNode.texture = self.door(2)
            Effects.burst(in: self.world, at: CGPoint(x: CGFloat(BuildingLayout.doorX), y: self.line(1) + 14), color: PixelColor(0xE9DFCF), count: 10, spread: 14, rise: 12, duration: 0.6)
            self.setBubble(worker.key, nil)
            worker.run(.sequence([.group([.fadeOut(withDuration: 0.35), .moveBy(x: -6, y: 6, duration: 0.35)]), .run { [weak self] in
                guard let self else { return }
                self.doorNode.texture = self.door(0)
                self.remove(worker)
            }]))
        }
        setBubble(worker.key, shout, style: .shout)
    }

    /// 칭찬(짧게): 가까운 층부터 두 명까지 찾아가 박수, 나머지는 그 자리에서 반짝(멀리서 칭찬). 끝나면 마무리.
    private func auditPraise(_ run: AuditRun) {
        guard auditRun === run else { return }
        let here = staffFloor(auditorNode)
        let visits = run.praise.filter { workers[$0.key].map { !$0.leaving } ?? false }
            .sorted { abs((workers[$0.key]?.floorIndex ?? 0) - here) < abs((workers[$1.key]?.floorIndex ?? 0) - here) }
        for call in visits.dropFirst(2) {
            guard let worker = workers[call.key] else { continue }
            Effects.sparkle(in: world, at: CGPoint(x: worker.position.x, y: worker.position.y + worker.spriteHeight + 4))
            say(call.key, Variety.shared.line("praised", ["칭찬받았다!", "오예", "보너스는요?", "더 열심히!"]), seconds: 2)
        }
        praiseStep(run, Array(visits.prefix(2)), index: 0)
    }

    private func praiseStep(_ run: AuditRun, _ calls: [AuditCall], index: Int) {
        guard auditRun === run else { return }
        guard index < calls.count else { auditFinish(run); return }
        auditorPraise(calls[index].key, reason: calls[index].reason) { [weak self] in self?.praiseStep(run, calls, index: index + 1) }
    }

    /// 실행 연출 끝: 부르는 쪽에 알리고(남은 조치가 있으면 그쪽 장부가 마무리) 퇴장한다.
    private func auditFinish(_ run: AuditRun) {
        guard auditRun === run else { return }
        auditRun = nil
        run.onFinish()
        auditorLeave()
    }

    /// 감사관이 직원 앞으로 가서 손가락질하며 혼내고(사유), 완료를 알린다.
    func auditorScold(_ key: ProcessKey, reason: String, completion: @escaping () -> Void) {
        guard let worker = workers[key], auditBusy else { completion(); return }
        let floor = worker.floorIndex
        staffTravel(auditorNode, walk: auditorWalk, stand: auditorStand, toFloor: floor, x: worker.position.x - 16, speed: 60) { [weak self] in
            guard let self else { return }
            self.auditorNode.xScale = 1
            self.auditorNode.run(.repeat(.animate(with: [self.auditorTexture(.scold(0)), self.auditorTexture(.scold(1))], timePerFrame: 0.25, resize: true, restore: false), count: 6), withKey: "pose")
            self.staffSay(self.auditorNode, "\(Variety.shared.line("scold", Lines.auditorScold)) \(reason)", style: .shout, seconds: 3)
            worker.face(right: false)
            if !worker.leaving { worker.show(.stand(blink: false)) }
            self.auditorNode.run(.sequence([.wait(forDuration: 2.8), .setTexture(self.auditorStand, resize: true), .run(completion)]), withKey: "after")
        }
    }

    /// 감사관이 일하는 직원 옆에서 박수치며 칭찬한다.
    func auditorPraise(_ key: ProcessKey, reason: String, completion: @escaping () -> Void) {
        guard let worker = workers[key], auditBusy else { completion(); return }
        let floor = worker.floorIndex
        staffTravel(auditorNode, walk: auditorWalk, stand: auditorStand, toFloor: floor, x: worker.position.x - 18, speed: 60) { [weak self] in
            guard let self else { return }
            self.auditorNode.run(.repeat(.animate(with: [self.auditorTexture(.clap(0)), self.auditorTexture(.clap(1))], timePerFrame: 0.2, resize: true, restore: false), count: 8), withKey: "pose")
            self.staffSay(self.auditorNode, "\(Variety.shared.line("praise", Lines.auditorPraise)) · \(reason)", style: .bubble, seconds: 2.8)
            Effects.sparkle(in: self.world, at: CGPoint(x: worker.position.x, y: worker.position.y + worker.spriteHeight + 4))
            self.auditorNode.run(.sequence([.wait(forDuration: 2.4), .setTexture(self.auditorStand, resize: true), .run(completion)]), withKey: "after")
        }
    }

    // MARK: 검수용(장면 시험) — 감사 인물 위치 · 붙잡은 직원

    struct StaffProbe {
        var floor: Int
        var x: CGFloat
        var y: CGFloat
        var alpha: CGFloat
        var present: Bool
    }

    func probe(_ node: SKSpriteNode) -> StaffProbe {
        StaffProbe(floor: staffFloor(node), x: node.position.x, y: node.position.y, alpha: node.alpha, present: node.parent != nil)
    }

    var auditorProbe: StaffProbe { probe(auditorNode) }
    var secretaryProbe: StaffProbe { probe(secretaryNode) }
    var instructorProbe: StaffProbe { probe(instructorNode) }
    var guardProbe: StaffProbe { probe(guardNode) }
    var auditInProgress: Bool { auditBusy }
    /// 실행 연출이 붙잡은 직원의 역할("student(0)" · "lineup(2)" · "returning"), 없으면 nil.
    func auditHold(_ key: ProcessKey) -> String? { auditHeld[key].map { "\($0)" } }
    /// 경비원이 할 일을 마치고 초소로 돌아왔는가(끌고 갈 사람 · 대기 줄 없음).
    var guardIdle: Bool { !guardBusy && !guardDragging && evictQueue.isEmpty }
    /// 짐꾼이 지금 하는 말(말풍선 글자), 없으면 nil.
    var porterSaying: String? { staffBubbles[ObjectIdentifier(warehouse.porter)].flatMap { $0.parent == nil ? nil : $0.currentText } }
    /// 검수용: 기계 배지(이름 · 값)의 글자 층 사각형(숨었으면 nil).
    func machineBadgeFrame(_ kind: MachineKind) -> CGRect? {
        guard let badge = machineBadges[kind], !badge.isHidden, badge.parent != nil else { return nil }
        let size = badge.badgeSize
        return CGRect(x: badge.position.x - size.width / 2, y: badge.position.y - size.height / 2, width: size.width, height: size.height)
    }

    private func startAmbient() {
        // 경비원은 가끔 고개를 돌리고, 30초쯤마다 로비를 한 바퀴 순찰한다.
        guardNode.run(.repeatForever(.sequence([.wait(forDuration: 6), .run { [weak self] in
            guard let self, !self.guardBusy else { return }
            self.guardNode.xScale *= -1
        }])), withKey: "ambient")
        guardNode.run(.repeatForever(.sequence([.wait(forDuration: 32), .run { [weak self] in self?.patrol() }])), withKey: "patrol")
    }

    private func patrol() {
        guard !guardBusy, abs(guardNode.position.y - line(1)) < 1 else { return }
        guardBusy = true
        let post = CGFloat(BuildingLayout.guardPostX)
        guardWalk(right: true)
        guardNode.run(.sequence([
            .moveTo(x: 206, duration: 3.0),
            .run { [weak self] in self?.guardWalk(right: false) },
            .moveTo(x: post, duration: 3.0),
            .run { [weak self] in
                self?.setGuard(.stand(blink: false))
                self?.guardBusy = false
            }
        ]), withKey: "patrolWalk")
    }

    // MARK: 입력 — 누르기(고르기·방으로 다가가기) · 끌기(이동) · 스크롤·핀치(확대) · 두 번 누르기 · Esc

    /// 누를 수 있는 구역(방 · 로비 · 도구실 · 기계실 · 옥상).
    private struct HitRegion {
        var key: String
        var rect: CGRect
        var label: String
        var focus: OfficeFocus
    }

    private func regions() -> [HitRegion] {
        var result: [HitRegion] = []
        var seen = Set<String>()
        for room in layout.rooms {
            let project = room.name.split(separator: " ").count > 1 && Int(room.name.split(separator: " ").last ?? "") != nil ? room.name.split(separator: " ").dropLast().joined(separator: " ") : room.name
            let members = (snapshot?.sessions ?? []).filter { $0.project == project }
            let working = members.filter { $0.state == .working || $0.state == .waiting }.count
            result.append(HitRegion(key: "room:\(room.name)", rect: roomRect(room), label: "\(project) · \(members.count)명 · 일하는 중 \(working)", focus: .room(project)))
            seen.insert(project)
        }
        let tools = (snapshot?.apps ?? []).filter { $0.category != .system && $0.category != .other && $0.id != "claude-daemon" }.count
        let waitingCount = (snapshot?.sessions ?? []).filter { $0.state == .waiting }.count
        result.insert(HitRegion(key: "situation", rect: regionRect(.situationRoom), label: "상황실 · 대표 · 나를 기다리는 세션 \(waitingCount)개", focus: .region(.situationRoom)), at: 0)
        for (index, room) in workflowRooms.sorted(by: { $0.key < $1.key }) {
            let floor = layout.floors[index]
            let rect = CGRect(x: CGFloat(BuildingLayout.wingX0) - 8, y: CGFloat(floor.y) - 2, width: CGFloat(BuildingLayout.wingX1 - BuildingLayout.wingX0) + 14, height: CGFloat(floor.height) + 10)
            var label = room.robotCount > 0 ? "워크플로실 · 로봇 \(room.robotCount)대 가동" : "워크플로실 · 대기"
            if room.staleCount > 0 { label += " · 멈춤? \(room.staleCount)" }
            if room.residueCount > 0 { label += " · 잔재 \(room.residueCount)" }
            if room.robotCount + room.residueCount > 0 { label += " · 로봇을 누르면 카드" }
            result.insert(HitRegion(key: "workflow:\(index)", rect: rect, label: label, focus: .floor(index)), at: 1)
        }
        result.append(HitRegion(key: "lobby", rect: regionRect(.lobby), label: "로비 · 출근·퇴근 문", focus: .region(.lobby)))
        result.append(HitRegion(key: "tools", rect: regionRect(.toolRoom), label: "도구실 · 앱 \(tools)개 · 반입구", focus: .region(.toolRoom)))
        result.append(HitRegion(key: "vault", rect: vaultRect, label: "기록 보관소 · 금고 \(vaultSummary.total)건 · \(Fmt.gb(vaultSummary.bytes)) · 누르면 복구함", focus: .floor(layout.lobbyIndex)))
        result.append(HitRegion(key: "machines", rect: regionRect(.machineRoom), label: "기계실 · CPU · RAM · 디스크 · 스왑", focus: .region(.machineRoom)))
        result.append(HitRegion(key: "hall", rect: regionRect(.hall), label: "대기실 · 오래 쉼 \((snapshot?.sessions ?? []).filter { $0.state == .longIdle || $0.state == .orphan }.count)명", focus: .region(.hall)))
        result.append(HitRegion(key: "roof", rect: regionRect(.rooftop), label: "옥상 · 쉬는 중 \((snapshot?.sessions ?? []).filter { $0.state == .idle }.count)명" + (partyPlaying ? " · DJ 파티 중" : ""), focus: .region(.rooftop)))
        return result
    }

    private func hitRegion(_ point: CGPoint) -> HitRegion? {
        regions().first { $0.rect.contains(point) }
    }

    /// 확대가 작을수록 사람을 누르기 쉽게 판정 범위를 넓힌다.
    private func hitWorker(_ point: CGPoint) -> WorkerNode? {
        let pad = max(3, 10 / camScale)
        return workers.values
            .filter { !$0.leaving && CGRect(x: $0.position.x - 8 - pad, y: $0.position.y - 2 - pad, width: 16 + pad * 2, height: $0.spriteHeight + 6 + pad * 2).contains(point) }
            .min { hypot($0.position.x - point.x, $0.position.y + 10 - point.y) < hypot($1.position.x - point.x, $1.position.y + 10 - point.y) }
    }

    private func hitMachine(_ point: CGPoint) -> MachineKind? {
        let basement = layout.floors[0]
        guard point.y >= CGFloat(basement.y), point.y <= CGFloat(basement.y + basement.height) else { return nil }
        return MachineLayout.kind(atX: point.x)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = event.location(in: self)
        dragged = false
        noteUserInput(cancelShots: false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = event.location(in: self)
        if !dragged, hypot(point.x - start.x, point.y - start.y) < 4 { return }
        if !dragged { noteUserInput(cancelShots: true); setHover(nil) }
        dragged = true
        pan(dx: event.deltaX, dy: event.deltaY)
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        guard !dragged else { return }
        let point = event.location(in: world)
        if event.clickCount >= 2 {
            if focusTarget != .all || userCamera { focus(.all, animated: true) } else if let region = hitRegion(point) { focus(region.focus, animated: true) }
            return
        }
        click(at: point)
    }

    /// 검수용(장면 시험): 가상 좌표 한 점을 누른 것처럼.
    func simulateClick(at point: CGPoint) { click(at: point) }

    private func click(at point: CGPoint) {
        // 방·층에 다가가 있을 때 어둡게 가린 바깥을 누르면 전체 보기로 돌아간다(10-25 대표 요청).
        if let hole = focusHole, !hole.contains(point) {
            focus(.all, animated: true)
            return
        }
        noteUserInput(cancelShots: true)
        if bossNode.parent != nil, CGRect(x: bossNode.position.x - 10, y: bossNode.position.y - 2, width: 20, height: 30).contains(point) {
            onSelectBoss?()
            staffSay(bossNode, Variety.shared.line("boss-click", ["왜? 뭐 터졌어?", "나 바빠…", "할 일 목록 보여줄게", "또 뭐야"]), style: .bubble, seconds: 2)
            return
        }
        if let hit = hitRobot(point) {
            // 하위 에이전트(로봇) 카드: 주인 세션 · 이름 · 단계 · 실행 시간 · 마지막 활동 · 토큰(SubagentCard).
            onSelectSubagent?(hit.robot.owner, hit.robot.info)
            subagentClicks.append(hit.robot.info.id)
            if !isZoomedIn {
                if let floor = hit.floor { focus(.floor(floor), animated: true) } else { focusWorker(hit.robot.owner) }
            }
            return
        }
        if let worker = hitWorker(point) {
            selected = worker.key
            onSelect?(worker.key)
            updateLOD(force: true)
            if !isZoomedIn { focusWorker(worker.key) }
            return
        }
        if let machine = hitMachine(point) {
            onSelectMachine?(machine)
            if !isZoomedIn { focus(.region(.machineRoom), animated: true) }
            return
        }
        if let app = hitTool(point) {
            onSelectApp?(app)
            if !isZoomedIn { focus(.region(.toolRoom), animated: true) }
            return
        }
        if vaultRect.contains(point) {
            selectVault()
            return
        }
        if let region = hitRegion(point) {
            if region.focus != focusTarget || userCamera { focus(region.focus, animated: true) }
            return
        }
        selected = nil
        onSelect?(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        noteUserInput(cancelShots: true)
        setHover(nil)
        if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.command) {
            // 트랙패드 두 손가락: 이동(⌘를 누르면 확대)
            pan(dx: -event.scrollingDeltaX, dy: -event.scrollingDeltaY)
        } else {
            let amount = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 10)
            zoom(by: pow(1.004, amount), at: event.location(in: self))
        }
    }

    func magnify(_ event: NSEvent) {
        noteUserInput(cancelShots: true)
        setHover(nil)
        zoom(by: 1 + event.magnification, at: event.location(in: self))
    }

    func hover(_ event: NSEvent) {
        guard dragStart == nil, activeShot == nil else { return }
        setHover(isZoomedIn ? nil : hitRegion(event.location(in: world)))
    }

    func hoverEnded() { setHover(nil) }

    func escape() {
        noteUserInput(cancelShots: true)
        selected = nil
        onSelect?(nil)
        focus(.all, animated: true)
    }

    /// 전체 보기에서 마우스를 올린 구역만 밝게 두고 나머지를 어둡게 한다(ANOGRO의 팀 구역 강조).
    private func setHover(_ region: HitRegion?) {
        guard region?.key != hoverKey else { return }
        hoverKey = region?.key
        guard let region else {
            dimNode.isHidden = true
            hoverOutline.isHidden = true
            hoverChip.isHidden = true
            return
        }
        let outer = CGRect(x: 0, y: 0, width: CGFloat(BuildingLayout.width), height: CGFloat(layout.height))
        let inner = region.rect.intersection(outer.insetBy(dx: -4, dy: -4))
        dimNode.show(hole: inner, within: outer, alpha: 0.42)
        hoverOutline.path = CGPath(rect: inner, transform: nil)
        hoverOutline.strokeColor = NSColor(white: 1, alpha: 0.95)
        hoverOutline.fillColor = .clear
        hoverOutline.lineWidth = 2 / camScale
        hoverOutline.isHidden = false
        hoverChip.set(region.label)
        hoverChip.position = CGPoint(x: inner.midX * pointsPerPixel, y: inner.maxY * pointsPerPixel + 12)
        hoverChip.isHidden = false
    }

    func select(_ key: ProcessKey?) {
        selected = key
        updateLOD(force: true)
    }

    func worker(for key: ProcessKey) -> WorkerNode? { workers[key] }
}
