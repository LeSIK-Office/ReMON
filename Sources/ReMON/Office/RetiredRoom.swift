import ReMONCore
import SpriteKit

// 정신교육실: 정리됐지만 복구 키로 같은 대화를 이어 열 수 있는 에이전트(복구 금고 '보관 중').
// 출근 때와 같은 사람(같은 생김새 씨앗)이 책을 펴고 앉아 있고, 누르면 복구 카드가 열린다. 복귀시키면 일어나 문으로 나간다.

/// 정신교육실 인물. 장면의 클릭 처리와 별개로 스스로 눌림을 받는다.
final class RetiredFigure: SKSpriteNode {
    let entryID: String
    var onClick: ((String) -> Void)?
    var leaving = false
    private let look: WorkerLook
    private var status: RecoveryEntry.Status?
    private let tag = TextBadge("복귀 대기", style: .tiny)

    init(entry: RecoveryEntry) {
        entryID = entry.id
        look = Self.look(for: entry)
        super.init(texture: nil, color: .clear, size: CGSize(width: 16, height: 24))
        anchorPoint = CGPoint(x: 0.5, y: 0)
        isUserInteractionEnabled = true
        name = "retired-" + entry.id
        let frames = (0..<2).map { TextureCache.shared.worker(look, .read($0)) }
        texture = frames[0]
        size = frames[0].size()
        run(.repeatForever(.animate(with: frames, timePerFrame: 0.9 + Double(abs(entry.id.hashValue) % 5) * 0.1)), withKey: "study")
        alpha = 0.9
        tag.position = CGPoint(x: 0, y: size.height + 5)
        tag.setScale(0.8)
        addChild(tag)
    }

    required init?(coder aDecoder: NSCoder) { nil }

    /// 일할 때와 같은 생김새: 씨앗은 장면의 look(for:)과 같은 식(pid + 시작 시각), 정리 시점까지의 나이만큼 덥수룩하게.
    static func look(for entry: RecoveryEntry) -> WorkerLook {
        let pid = Int(entry.pid ?? 0), start = entry.processStart ?? 0
        let base = WorkerLook.seeded(pid &+ Int(start % 9973), hoodie: TeamColor.hoodie(entry.agent.flatMap(AgentKind.init(rawValue:))))
        let started = Date(timeIntervalSince1970: TimeInterval(start) / 1_000_000)
        return start > 0 ? base.aged(max(0, entry.createdAt.timeIntervalSince(started))) : base
    }

    private var tagScale: CGFloat = 0.8

    /// 이름표("복귀 대기")를 화면에서 늘 같은 크기로(직원 이름표처럼): 건물은 카메라 배율만큼 커지므로 그만큼 줄인다.
    /// (예전: 정신교육실로 다가가면 이름표가 몇 배로 커져 교실을 덮었다.)
    func fitTag(cameraScale: CGFloat) {
        tagScale = 1 / max(0.25, cameraScale)
        applyTagScale()
    }

    /// 걸어 나가며 좌우가 뒤집혀도(xScale < 0) 글자는 바로 보이게 되돌린다.
    private func applyTagScale() {
        tag.yScale = tagScale
        tag.xScale = xScale < 0 ? -tagScale : tagScale
    }

    func apply(_ entry: RecoveryEntry) {
        guard entry.status != status else { return }
        status = entry.status
        tag.set(entry.status == .restoring ? "복귀 중…" : "복귀 대기")
    }

    /// 일어나 왼쪽(교육실 문)으로 걸어 나간다.
    func walkOut(to x: CGFloat) {
        removeAction(forKey: "study")
        status = .restoring
        tag.set("복귀 중…")
        xScale = x < position.x ? -abs(xScale) : abs(xScale)
        applyTagScale()
        let frames = (0..<4).map { TextureCache.shared.worker(look, .walk($0)) }
        run(.repeatForever(.animate(with: frames, timePerFrame: 0.12)), withKey: "steps")
        run(.sequence([.moveTo(x: x, duration: TimeInterval(abs(position.x - x) / 40)), .run { [weak self] in self?.removeAction(forKey: "steps") },
                       .fadeAlpha(to: 0.35, duration: 0.4)]), withKey: "walk")
    }

    override func mouseDown(with event: NSEvent) { onClick?(entryID) }
}

extension OfficeScene {
    /// 정신교육실 자리: 교육 책상 왼편 4자리 + 뒷줄 4자리(재교육 중인 직원 자리 layout.classSeats와 겹치지 않게).
    private func retiredSpots() -> [CGPoint] {
        let floor = layout.floors[min(layout.hallIndex, layout.floors.count - 1)]
        let y = CGFloat(floor.floorLine)
        let xs = BuildingLayout.classSeatXs.map(CGFloat.init)
        return xs.map { CGPoint(x: $0 - 13, y: y) } + xs.map { CGPoint(x: $0 + 3, y: y + 6) }
    }

    private var retiredLayer: SKNode {
        if let layer = world.childNode(withName: "retired-room") { return layer }
        let layer = SKNode()
        layer.name = "retired-room"
        world.addChild(layer)
        return layer
    }

    /// 금고의 '보관 중·복귀 중' 세션을 정신교육실에 앉힌다(최대 8명, 넘치면 칠판 아래 '+N').
    func setRetired(_ entries: [RecoveryEntry], onSelect: @escaping (String) -> Void) {
        let layer = retiredLayer
        let shown = Array(entries.prefix(8))
        let wanted = Set(shown.map(\.id))
        for case let figure as RetiredFigure in layer.children where !wanted.contains(figure.entryID) && !figure.leaving {
            figure.run(.sequence([.fadeOut(withDuration: 0.4), .removeFromParent()]))
            figure.leaving = true
        }
        let spots = retiredSpots()
        for (index, entry) in shown.enumerated() {
            let figure = layer.children.compactMap { $0 as? RetiredFigure }.first { $0.entryID == entry.id && !$0.leaving } ?? {
                // 처음부터 보이게 둔다(장면 액션이 멈춘 동안 — 화면 잠금·캡처 — 에도 사라지지 않게).
                let made = RetiredFigure(entry: entry)
                layer.addChild(made)
                return made
            }()
            figure.onClick = onSelect
            let spot = spots[index]
            if figure.action(forKey: "walk") == nil { figure.position = spot }
            figure.zPosition = index < 4 ? 5 : 4
            figure.apply(entry)
            figure.fitTag(cameraScale: pointsPerPixel)
        }
        let overflow = entries.count - shown.count
        let sign = layer.childNode(withName: "retired-overflow") as? TextBadge
        if overflow > 0 {
            let badge = sign ?? {
                let made = TextBadge("", style: .plate)
                made.name = "retired-overflow"
                made.zPosition = 6
                layer.addChild(made)
                return made
            }()
            badge.set("+\(overflow)명 더 대기")
            badge.position = CGPoint(x: CGFloat(BuildingLayout.wingX1) - 30, y: spots[0].y + 44)
        } else {
            sign?.removeFromParent()
        }
    }

    /// 복귀시키면: 일어나 교육실 문(왼쪽)으로 걸어 나간다. 새 세션이 보이면 평소처럼 출근해 자리로 간다.
    func retiredStand(_ id: String) {
        guard let figure = retiredLayer.children.compactMap({ $0 as? RetiredFigure }).first(where: { $0.entryID == id }) else { return }
        figure.walkOut(to: CGFloat(BuildingLayout.wingX0) + 4)
    }
}
