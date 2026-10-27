import ReMONCore
import SpriteKit

// 커밋 · 푸시 · 배포 축하(10-25 대표 요청 '배포~~! 환호 · 꽃가루 · 서류 더미 → 청소하기 → 청소부 투입 · 물청소').
// 그 방 직원들이 책상에서 벌떡 일어나 뛰며 외치고(매번 다른 대사), 배포면 천장에서 꽃가루가 쏟아진다.
// 서류 더미는 메인이 쓰레기 장부(ProjectGarbage.papers: 커밋 1 · 푸시 2 · 배포 3)로 setPapers를 불러 그 방 바닥(책상 사이)에 쌓는다.
// 청소 특공대가 그 방에 오면(janitorVisit) 서류를 걷고 물걸레질한다(양동이 · 젖은 자국 · 반짝) — OfficeScene.janitorVisit.

/// 서류 · 꽃가루 픽셀.
enum PaperArt {
    /// 서류 묶음 한 장(8×3, 더미에서 3px씩 쌓인다): 흰 종이 · 크림 종이 · 빨간 도장 찍힌 종이.
    static func sheet(_ variant: Int) -> PixelCanvas {
        var c = PixelCanvas(8, 3)
        let paper = [Pal.paper, PixelColor(0xF3EAD2), Pal.paper][variant % 3]
        c.rect(0, 0, 8, 2, paper)
        c.hline(0, 2, 8, PixelColor(0xB9B2A2))
        if variant % 3 == 1 { c.hline(1, 1, 3, PixelColor(0x8FA7B8)); c.hline(5, 1, 2, PixelColor(0x8FA7B8)) }   // 줄글
        if variant % 3 == 2 { c.rect(5, 0, 2, 2, Pal.alarm) }                                                    // 도장
        if variant % 3 == 0 { c.dot(1, 0, PixelColor(0xD8D2C4)) }                                                // 접힌 귀
        return c
    }

    static let confettiColors: [PixelColor] = [PixelColor(0xFF6B6B), PixelColor(0xFFD93D), PixelColor(0x6BCB77), PixelColor(0x4D96FF), PixelColor(0xF7A8FF), PixelColor(0xFFFFFF)]

    /// 꽃가루 조각: 2×2 사각 또는 1×3 띠.
    static func confetti(_ color: Int, strip: Bool) -> PixelCanvas {
        var c = PixelCanvas(strip ? 1 : 2, strip ? 3 : 2)
        c.rect(0, 0, c.width, c.height, confettiColors[color % confettiColors.count])
        return c
    }
}

extension OfficeScene {
    /// 깃 사건 축하: 그 방(없으면 첫 직원 주변)으로 카메라 · 책상에 앉은 직원들이 일어나 뛰며 외침 · 꽃가루(배포 = 천장에서 쏟아짐, 푸시 = 머리 위 두 번, 커밋 = 한 번).
    /// 서류 더미는 여기서 늘리지 않는다 — 메인이 쓰레기 장부로 setPapers를 부른다(사실 = 장부).
    func celebrate(project: String, keys: [ProcessKey], kind: GitEvent.Kind, label: String) {
        let caption: String
        switch kind {
        case .deploy: caption = "배포! · \(project) · \(label) · 다들 축하합니다"
        case .push: caption = "푸시 · \(project) · \(label)"
        case .commit: caption = "커밋 · \(project) · \(label)"
        }
        let room = layout.rooms.first { $0.name == project || $0.name.hasPrefix(project + " ") }
        let crew = keys.compactMap { workers[$0] }
        if let room {
            requestShot(Shot(target: .rect(roomRect(room)), caption: caption, duration: kind == .deploy ? 7 : 4, priority: kind == .deploy ? 2 : 1))
        } else if let first = crew.first {
            requestShot(Shot(target: .rect(CGRect(x: first.position.x - 90, y: first.position.y - 20, width: 180, height: 90)), caption: caption, duration: kind == .deploy ? 7 : 4, priority: kind == .deploy ? 2 : 1))
        }
        celebrationLog.append("\(kind.rawValue) · \(project) · \(label)")
        let lines = kind == .deploy ? Lines.cheerDeploy : kind == .push ? Lines.cheerPush : Lines.cheerCommit
        let jumps = kind == .deploy ? 3 : kind == .push ? 2 : 1
        // 책상에 앉아 있는 직원만(걷는 중 · 연출 중 · 쉬는 자리는 그대로).
        let cheering = crew.filter { !$0.busy && !$0.leaving && $0.route == nil && $0.place == .desk }
        // 한 번의 축하 안에서는 사람마다 다른 대사(시작 대사만 씨앗 난수로 고르고 차례로 돌린다).
        let offset = Variety.shared.integer(0...(lines.count - 1))
        for (index, worker) in cheering.enumerated() {
            cheer(worker, text: lines[(offset + index) % lines.count], delay: Double(index) * 0.15, jumps: jumps)
        }
        // 머리 위 폭죽
        let bursts = kind == .deploy ? 3 : kind == .push ? 2 : 1
        for (index, worker) in crew.enumerated() {
            for burst in 0..<bursts {
                world.run(.sequence([.wait(forDuration: Double(index) * 0.12 + Double(burst) * 0.35 + 0.2), .run { [weak self, weak worker] in
                    guard let self, let worker else { return }
                    Effects.burst(in: self.world, at: CGPoint(x: worker.position.x, y: worker.position.y + worker.spriteHeight + 8),
                                  color: PaperArt.confettiColors[(index + burst) % 5], count: kind == .deploy ? 14 : 8, spread: 18, rise: 16, duration: 0.9)
                }]))
            }
        }
        if kind == .deploy, let room { confettiRain(over: room) }
    }

    /// 직원 하나: 벌떡 일어나 제자리에서 뛰며(배포 3번 · 푸시 2번 · 커밋 1번) 외친다 → 끝나면 다시 앉아 하던 상태로(말풍선도 원래대로).
    private func cheer(_ worker: WorkerNode, text: String, delay: TimeInterval, jumps: Int) {
        let key = worker.key
        worker.busy = true
        worker.removeAction(forKey: "say")
        var steps: [SKAction] = [.wait(forDuration: delay), .run { [weak self, weak worker] in
            guard let self, let worker else { return }
            worker.position.y = self.line(worker.floorIndex)
            worker.loop([.jumpingJack(0), .clap(0), .jumpingJack(0), .clap(1)], fps: 6)
            self.setBubble(key, text, style: .shout)
        }]
        for _ in 0..<jumps {
            steps += [.moveBy(x: 0, y: 6, duration: 0.16), .moveBy(x: 0, y: -6, duration: 0.16), .wait(forDuration: 0.12)]
        }
        steps.append(.wait(forDuration: 1.3))
        steps.append(.run { [weak self, weak worker] in
            guard let self, let worker, !worker.leaving else { return }
            worker.busy = false
            self.setBubble(key, nil)
            self.settle(worker)
        })
        worker.run(.sequence(steps), withKey: "cheer")
    }

    /// 배포 꽃가루: 방 천장에서 색 조각이 흔들리며 바닥까지 떨어졌다가 잠시 뒤 사라진다(씨앗 난수 — 장면 시험에서 같은 모양).
    private func confettiRain(over room: BuildingLayout.Room) {
        let floor = layout.floors[room.floor]
        let top = CGFloat(floor.y + floor.height) - 6
        let bottom = line(room.floor)
        let count = min(48, 10 + (room.x1 - room.x0) / 6)
        for i in 0..<count {
            let x = CGFloat(Variety.shared.number(Double(room.x0 + 4)...Double(room.x1 - 6)))
            let strip = Variety.shared.chance(0.4)
            let color = Variety.shared.integer(0...(PaperArt.confettiColors.count - 1))
            let piece = SKSpriteNode(texture: TextureCache.shared.texture("confetti-\(color)-\(strip)") { PaperArt.confetti(color, strip: strip) })
            piece.position = CGPoint(x: x, y: top)
            piece.zPosition = 9
            piece.alpha = 0
            piece.name = "confetti"
            world.addChild(piece)
            let fall = Variety.shared.seconds(1.3...2.3)
            let sway = CGFloat(Variety.shared.number(-10...10))
            let land = bottom + CGFloat(Variety.shared.integer(0...3))
            piece.run(.sequence([
                .wait(forDuration: Double(i % 12) * 0.06),
                .fadeIn(withDuration: 0.05),
                .group([.moveTo(y: land, duration: fall),
                        .sequence([.moveBy(x: sway, y: 0, duration: fall / 2), .moveBy(x: -sway * 0.6, y: 0, duration: fall / 2)]),
                        .rotate(byAngle: CGFloat(Variety.shared.number(-6...6)), duration: fall)]),
                .wait(forDuration: 1.6),
                .fadeOut(withDuration: 0.5),
                .removeFromParent()
            ]))
        }
    }

    // MARK: 서류 더미

    /// 방(프로젝트)별 서류 수 → 그 방 바닥의 책상 사이(첫 책상 왼쪽 + 책상과 책상 사이)에 서류 더미로 쌓는다. 한 더미에 5장, 방마다 '책상 수 × 5'장까지.
    /// 늘면 새 서류가 위에서 팔랑이며 내려앉고, 줄면 잠시(2.5초) 기다렸다 사라진다 — 그사이 청소 특공대가 오면(janitorVisit) 걷어 가고 물청소한다.
    /// 짐 층(Clutter.swift)과 같은 장부다: 서류 수는 방 짐(RoomClutter.papers)에도 들어가고, 더미 자리를 넘친 서류는 상자로 묶여 짐 층에 쌓인다.
    /// setClutter(RoomClutter)도 같은 낱장을 움직인다 — 둘 다 오면 나중에 온 값을 따른다(앱은 같은 장부에서 두 값을 만든다).
    func setPapers(_ counts: [String: Int]) {
        syncPaperSheets(counts)
        clutterPapersChanged(counts)
    }

    /// 낱장 더미만 맞춘다(setPapers · setClutter가 함께 쓴다).
    func syncPaperSheets(_ counts: [String: Int]) {
        let first = !papersInitialized
        papersInitialized = true
        for project in Set(paperNodes.keys).union(counts.keys) {
            let want = min(paperCapacity(project), max(0, counts[project] ?? 0))
            let have = paperNodes[project]?.count ?? 0
            if want > have {
                addPapers(project, count: want - have, animated: !first)
            } else if want < have {
                if cleaningProjects.contains(project) {
                    removeAction(forKey: "papers-out-\(project)")
                    continue
                }
                schedulePaperRemoval(project, keep: want)
            } else {
                removeAction(forKey: "papers-out-\(project)")
            }
        }
    }

    /// 서류를 놓을 자리(건물 좌표, 더미 아래 가운데): 첫 책상 왼쪽 벽 앞 + 책상마다 오른쪽 틈(마지막 책상 오른쪽은 짐 구석이라 뺀다).
    /// 높이는 바닥선 위 2px — 바닥 앞 2px은 걷는 통로라 비운다(짐 층과 같은 규칙). 짐 상자는 그 뒤(뒷벽 쪽)에 쌓인다.
    func paperSpots(_ project: String) -> [CGPoint] {
        guard let index = layout.rooms.firstIndex(where: { $0.name == project || $0.name.hasPrefix(project + " ") }) else { return [] }
        let room = layout.rooms[index]
        let desks = (Array(layout.desks.values) + layout.spareDesks).filter { $0.room == index }
        let xs = Set(desks.map(\.deskX)).sorted()
        let y = line(room.floor) + ClutterPlan.frontRow
        return [CGPoint(x: CGFloat(room.x0 + 4), y: y)] + xs.dropLast().map { CGPoint(x: CGFloat($0 + 39), y: y) }
    }

    private func paperCapacity(_ project: String) -> Int { paperSpots(project).count * 5 }

    /// k번째 서류의 자리: 한 더미를 다섯 장까지 쌓고(3px씩) 다음 더미로 — 쌓일수록 더미가 높아 보이게. 장마다 1px씩 어긋나게(고정 무늬).
    private func paperPoint(_ project: String, _ k: Int) -> CGPoint? {
        let spots = paperSpots(project)
        guard !spots.isEmpty, k / 5 < spots.count else { return nil }
        let spot = spots[k / 5]
        let level = k % 5
        let jitter = CGFloat([0, 1, -1, 1, 0][level])
        return CGPoint(x: spot.x + jitter, y: spot.y + CGFloat(level) * 3)
    }

    private func addPapers(_ project: String, count: Int, animated: Bool) {
        removeAction(forKey: "papers-out-\(project)")
        var list = paperNodes[project] ?? []
        for i in 0..<count {
            let k = list.count
            guard let point = paperPoint(project, k) else { break }
            let sheet = SKSpriteNode(texture: TextureCache.shared.texture("paper-sheet-\(k % 3)") { PaperArt.sheet(k % 3) })
            sheet.anchorPoint = CGPoint(x: 0.5, y: 0)
            sheet.size = CGSize(width: 8, height: 3)
            sheet.zPosition = 2.5 + CGFloat(k % 5) * 0.01
            world.addChild(sheet)
            list.append(sheet)
            if animated {
                // 위에서 팔랑이며 내려앉는다(좌우로 흔들리다 제자리에 눕는다)
                sheet.position = CGPoint(x: point.x - 6, y: point.y + 26)
                sheet.zRotation = 0.5
                sheet.alpha = 0
                sheet.run(.sequence([.wait(forDuration: Double(i) * 0.12),
                                     .fadeIn(withDuration: 0.1),
                                     .group([.move(to: point, duration: 0.6),
                                             .sequence([.rotate(toAngle: -0.4, duration: 0.2), .rotate(toAngle: 0.3, duration: 0.2), .rotate(toAngle: 0, duration: 0.2)])])]),
                          withKey: "flutter")
            } else {
                sheet.position = point
            }
        }
        paperNodes[project] = list
    }

    /// 건물을 다시 지었을 때(방이 옮겨 가거나 책상 수가 바뀜): 서류를 새 자리로. 방이 없어졌거나 자리가 모자라면 넘치는 만큼 뺀다.
    func relayoutPapers() {
        for (project, list) in paperNodes {
            let capacity = paperCapacity(project)
            var kept: [SKSpriteNode] = []
            for (k, sheet) in list.enumerated() {
                guard k < capacity, let point = paperPoint(project, k) else { sheet.removeFromParent(); continue }
                sheet.removeAction(forKey: "flutter")
                sheet.zRotation = 0
                sheet.alpha = 1
                sheet.position = point
                kept.append(sheet)
            }
            paperNodes[project] = kept.isEmpty ? nil : kept
        }
    }

    /// 줄어든 만큼은 2.5초 뒤 사라진다(그사이 청소가 오면 청소가 걷는다).
    private func schedulePaperRemoval(_ project: String, keep: Int) {
        run(.sequence([.wait(forDuration: 2.5), .run { [weak self] in self?.dropPapers(project, keep: keep) }]), withKey: "papers-out-\(project)")
    }

    private func dropPapers(_ project: String, keep: Int) {
        guard var list = paperNodes[project], list.count > keep else { return }
        while list.count > keep {
            let sheet = list.removeLast()
            sheet.run(.sequence([.fadeOut(withDuration: 0.3), .removeFromParent()]))
        }
        paperNodes[project] = list.isEmpty ? nil : list
    }

    /// 청소 특공대가 서류를 걷는다: 한 장씩 비질하는 사람 쪽으로 날아가 사라진다(먼지). 장면의 서류 수는 0 — 장부가 0으로 다시 알려 온다.
    func collectPapers(_ project: String, toward collector: SKNode?) {
        removeAction(forKey: "papers-out-\(project)")
        guard let list = paperNodes[project], !list.isEmpty else { return }
        paperNodes[project] = nil
        for (index, sheet) in list.enumerated() {
            let target = collector.map { CGPoint(x: $0.position.x + 4, y: $0.position.y + 12) } ?? CGPoint(x: sheet.position.x, y: sheet.position.y + 10)
            sheet.run(.sequence([.wait(forDuration: Double(index) * 0.06),
                                 .group([.move(to: target, duration: 0.35), .rotate(byAngle: 1.2, duration: 0.35), .fadeOut(withDuration: 0.35)]),
                                 .removeFromParent()]))
        }
        Effects.burst(in: world, at: list[0].position, color: PixelColor(0xE9E4D8), count: 6, spread: 10, rise: 8, duration: 0.5)
    }

    // MARK: 검수용

    /// 그 방 바닥의 서류 장수(날아가는 중인 것 포함).
    func paperCount(_ project: String) -> Int { paperNodes[project]?.count ?? 0 }
    /// 서류가 모두 바닥(더미 자리)에 내려앉았는가.
    func papersSettled(_ project: String) -> Bool {
        (paperNodes[project] ?? []).enumerated().allSatisfy { index, sheet in sheet.action(forKey: "flutter") == nil && paperPoint(project, index) == sheet.position }
    }
    var confettiCount: Int { world.children.filter { $0.name == "confetti" }.count }
}
