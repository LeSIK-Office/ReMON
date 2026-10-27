import AppKit
import ReMONCore
import SpriteKit
import SwiftUI

// 방마다 의미(10-25 대표 지시 '모든 방이 뭔가를 의미하게 · 구체적이고 재미있게').
// 도구실: 반입구로 들어오고 나가는 앱 기계 · 폭주(CPU) · 커짐(메모리) · 10대 배치와 +N.
// 사람 · 수레 · 상자 · 기계는 늘 바닥 · 선반 · 짐판 위에 있어야 한다(뜬 것 없음).

extension SceneChecks {
    static func fakeApp(_ index: Int, gb: Double, cpu: Double = 0) -> AppGroup {
        AppGroup(id: "/Applications/Fake\(index).app", name: "앱\(index)", category: .app, agentKind: nil, pids: [], footprint: UInt64(gb * Fmt.gib), cpuPercent: cpu)
    }

    static func appID(_ index: Int) -> String { "/Applications/Fake\(index).app" }

    /// 도구실의 사람 · 수레 · 짐 · 기계가 바닥 · 위 단 선반 · 짐판 위에만 있는지 0.25초마다 본다.
    @MainActor
    final class ToolFloatWatch {
        var problems: [String] = []
        var sawRiding = false
        var sawDoorOpen = false
        var sawAtDock = false

        func observe(_ scene: OfficeScene) {
            let floor = scene.line(scene.lobbyFloor)
            let upper = floor + ToolRoom.upperY
            let p = scene.toolDockProbe
            if p.door > 0.9 { sawDoorOpen = true }
            if p.visible {
                if abs(p.cartX - ToolRoom.dockX) < 2 { sawAtDock = true }
                if p.riding, abs(p.deckTop - upper) < 0.5 { sawRiding = true }
                if abs(p.cartY - floor) > 0.5 { note(String(format: "수레 y=%.1f", p.cartY)) }
                let onFloor = abs(p.courierY - floor) < 0.5, onDeck = p.riding && abs(p.courierY - p.deckTop) < 0.5
                if !onFloor && !onDeck { note(String(format: "기사 y=%.1f(짐판 %.1f)", p.courierY, p.deckTop)) }
                if let cargo = p.cargoY, abs(cargo - p.deckTop) > 0.5 { note(String(format: "짐 y=%.1f(짐판 %.1f)", cargo, p.deckTop)) }
            }
            if let crate = p.crateOnBayY, abs(crate - floor) > 0.5 && abs(crate - upper) > 0.5 { note(String(format: "칸의 상자 y=%.1f", crate)) }
            for id in scene.toolIDs {
                guard let info = scene.toolInfo(id), info.installed, info.node.parent === scene.world else { continue }
                if abs(info.frame.minY - floor) > 0.5 && abs(info.frame.minY - upper) > 0.5 { note(String(format: "기계 %@ y=%.1f", id, info.frame.minY)) }
            }
        }

        private func note(_ text: String) { if problems.count < 5 { problems.append(text) } }
    }

    // MARK: 한 장면에 모두(전체 보기 · 로비 층)

    /// 도구실(앱 12개 · 폭주 1) · 금고 · 워크플로실(멈춤? 1) · 서류 더미가 한꺼번에 있는 건물. 방끼리 겹치지 않고 각자 보이는지 · 전체 화면 검수용 사진.
    static func roomsOverview() {
        print("— rooms-overview: 도구실 · 금고 · 워크플로실 · 서류가 한 건물에 함께 — 구역이 겹치지 않음")
        Variety.shared.seed(78)
        let harness = SceneHarness()
        let scene = harness.scene
        var alpha = (0..<6).map { session(Int32(27_001 + $0), "알파", .working, order: Double($0)) }
        let beta = (0..<3).map { session(Int32(27_101 + $0), "베타", .working, order: Double(10 + $0)) }
        let gamma = (0..<5).map { session(Int32(27_201 + $0), "감마", .working, order: Double(20 + $0)) }
        alpha[1].subagents = (1...3).map { SubagentInfo(id: "o\($0)", label: "수집 o\($0)", model: "sonnet", kind: .workflow, workflow: "wf_collect", phase: "수집",
                                                        lastActivity: harness.clock.addingTimeInterval($0 == 3 ? -30 * 60 : -60), active: true) }
        harness.sessions = alpha + beta + gamma
        harness.apps = (0..<12).map { fakeApp($0, gb: 5 - Double($0) * 0.35, cpu: $0 == 2 ? 95 : 3) }
        harness.feed()
        scene.setVault(OfficeScene.VaultSummary(sessions: 5, files: 9, git: 4, processes: 2, expired: 6, bytes: UInt64(7.4 * Fmt.gib)))
        scene.setPapers(["알파": 9, "감마": 4])
        harness.run(3)
        let lobby = scene.currentLayout.floors[scene.currentLayout.lobbyIndex]
        let regions = [scene.regionRect(.lobby), scene.regionRect(.toolRoom), scene.vaultRect]
        let disjoint = !regions[0].intersects(regions[1]) && !regions[1].intersects(regions[2]) && !regions[0].intersects(regions[2])
        check(disjoint && regions.allSatisfy { $0.minY < CGFloat(lobby.floorLine) && $0.maxY > CGFloat(lobby.floorLine + 40) }, "로비 · 도구실 · 금고 구역이 1층에서 겹치지 않음")
        check(scene.toolIDs.count == 10 && scene.toolOverflowText == "+2" && scene.toolInfo(appID(2))?.bursting == true && scene.vaultNode.boxCount == 26 && scene.paperCount("알파") == 9,
              "기계 \(scene.toolIDs.count)대 · +2 · 폭주 1 · 금고 상자 \(scene.vaultNode.boxCount) · 알파 서류 \(scene.paperCount("알파"))")
        shot(harness, "rooms-overview", focus: .all)
        shot(harness, "rooms-lobby", focus: .floor(scene.currentLayout.lobbyIndex))
    }

    // MARK: 깃 사건 축하 · 서류 더미 · 물청소

    static func celebratePapers() {
        print("— celebrate-papers: 배포 = 그 방 직원이 일어나 뛰며 외침(매번 다른 대사) · 꽃가루 · 서류 더미(setPapers) · 청소 특공대가 서류를 걷고 물청소 → 서류 0")
        Variety.shared.seed(77)
        let harness = SceneHarness()
        let scene = harness.scene
        let alpha = (0..<4).map { session(Int32(26_001 + $0), "알파", .working, order: Double($0)) }
        let beta = (0..<2).map { session(Int32(26_101 + $0), "베타", .working, order: Double(10 + $0)) }
        harness.sessions = alpha + beta
        harness.feed()
        harness.run(3)
        guard let room = scene.currentLayout.rooms.first(where: { $0.name == "알파" }), let floor = scene.currentLayout.desks[alpha[0].id]?.floor else { check(false, "알파 방 없음"); return }
        // ① 서류: 처음 값은 연출 없이 그 방 바닥(책상 사이)에
        scene.setPapers(["알파": 4, "베타": 2])
        check(scene.paperCount("알파") == 4 && scene.paperCount("베타") == 2 && scene.papersSettled("알파"), "처음 서류: 알파 \(scene.paperCount("알파"))장 · 베타 \(scene.paperCount("베타"))장(바닥 더미 자리)")
        // ② 배포 축하: 책상에서 일어나 세 번 뛰며 외침 · 천장에서 꽃가루 · 말풍선은 글자판보다 앞 · 머리 위에 붙어 있음 · 보드와 겹치지 않음
        scene.focus(.room("알파"), animated: false)
        harness.run(0.6)
        var jumped = Set<ProcessKey>(), texts: [String] = [], maxConfetti = 0
        var zOK = true, attached = true, overBoard = false, floating = 0
        var shotTaken = false
        scene.celebrate(project: "알파", keys: alpha.map(\.id), kind: .deploy, label: "v1.2.0")
        harness.run(4.5) { _ in
            let ppp = scene.pointsPerPixel
            for member in alpha {
                guard let worker = scene.worker(for: member.id) else { continue }
                let base = scene.line(floor)
                if worker.position.y > base + 2 { jumped.insert(member.id) }
                if worker.position.y < base - 0.5 || worker.position.y > base + 7 { floating += 1 }
                guard let bubble = scene.bubbleProbe(member.id), bubble.style == .shout else { continue }
                if !texts.contains(bubble.text) { texts.append(bubble.text) }
                if bubble.z <= scene.signLayerTopZ { zOK = false }
                if abs(bubble.frame.midX / ppp - (worker.position.x + 6)) > 2 || bubble.frame.minY / ppp < worker.position.y + worker.spriteHeight { attached = false }
                if scene.boardFrames.contains(where: { $0.intersects(bubble.frame) }) { overBoard = true }
            }
            maxConfetti = max(maxConfetti, scene.confettiCount)
            if !shotTaken, jumped.count >= 3, maxConfetti > 10 {
                shotTaken = true
                shot(harness, "deploy-celebration", rect: scene.roomRect(room).insetBy(dx: -30, dy: -6))
            }
        }
        check(jumped.count == 4 && texts.count >= 2 && texts.allSatisfy(Lines.cheerDeploy.contains), "배포: 알파 4명 모두 뛰며 외침 · 대사 \(texts)(매번 다르게)")
        check(maxConfetti > 10 && scene.celebrationLog.last == "deploy · 알파 · v1.2.0", "배포 꽃가루(천장에서 \(maxConfetti)조각) · 기록")
        check(zOK && attached && !overBoard && floating == 0, "외침 말풍선: 글자판보다 앞 \(zOK) · 머리 위에 붙어 있음 \(attached) · 보드와 안 겹침 \(!overBoard) · 직원은 바닥 위(뛰기 6px 안)")
        harness.run(2)
        let seated = alpha.filter { atDesk(scene.worker(for: $0.id), scene.currentLayout, $0.id) && scene.worker(for: $0.id)?.busy == false && scene.bubbleProbe($0.id) == nil }
        check(seated.count == 4, "축하가 끝나면 모두 다시 책상에서 일함(말풍선 없음) \(seated.count)/4")
        // ③ 서류가 늘어남: 위에서 팔랑이며 내려앉아 7장 · 아주 많으면 방 한도(더미 자리 × 5)까지만
        scene.setPapers(["알파": 7, "베타": 2])
        harness.run(1.8)
        check(scene.paperCount("알파") == 7 && scene.papersSettled("알파"), "서류 +3: 팔랑이며 내려앉아 \(scene.paperCount("알파"))장")
        scene.setPapers(["알파": 80, "베타": 2])
        harness.run(4)
        let capacity = scene.paperSpots("알파").count * 5
        check(scene.paperCount("알파") == capacity && scene.papersSettled("알파"), "서류 80건: 그리는 건 방 한도 \(capacity)장(더미 \(scene.paperSpots("알파").count)곳 × 5)")
        // ④ 청소 특공대: 한 명은 서류를 걷으며 비질, 한 명은 양동이를 놓고 물걸레질(젖은 자국 → 반짝) → 알파 서류 0 · 베타 그대로
        let watch = StaffWatch()
        var mopShot = false
        scene.janitorVisit(project: "알파", items: 2, reclaimed: 0)
        let cleaned = runUntil(harness, timeout: 40, probe: { now in
            for (name, probe) in scene.janitorProbes { watch.observe(probe, name, layout: scene.currentLayout, now: now) }
            if !mopShot, scene.mopStrokes >= 8 {
                mopShot = true
                shot(harness, "wet-mop", rect: scene.roomRect(room).insetBy(dx: -30, dy: -6))
            }
        }) { scene.janitorsGone }
        check(cleaned != nil && scene.paperCount("알파") == 0 && scene.paperCount("베타") == 2, "청소 뒤 알파 서류 \(scene.paperCount("알파"))장 · 베타 \(scene.paperCount("베타"))장 그대로")
        check(scene.mopLog.contains("양동이") && scene.mopLog.contains("반짝") && scene.mopStrokes >= 8, "물청소: 양동이 · 젖은 자국 \(scene.mopStrokes)개 · 반짝")
        watch.report("청소 특공대", particle: "가")
        // ⑤ 장부가 0을 알려 오면 그대로 0, 서류 없는 방 청소는 예전처럼 비질만
        scene.setPapers(["베타": 2])
        harness.run(3)
        let strokes = scene.mopStrokes
        scene.janitorVisit(project: "알파", items: 1, reclaimed: 0)
        runUntil(harness, timeout: 40) { scene.janitorsGone }
        check(scene.paperCount("알파") == 0 && scene.paperCount("베타") == 2 && scene.mopStrokes == strokes, "서류 없는 방 청소: 물청소 없이 비질만(젖은 자국 그대로 \(scene.mopStrokes - strokes)개 추가)")
        noSafetyNet(harness)
    }

    // MARK: 워크플로실 = 하위 에이전트 자원 관리실

    static func workflowSubagent() {
        print("— workflow-subagent: 로봇을 누르면 하위 에이전트 카드 · 일하는 중인데 20분 넘게 기록 없음 = 빨간 등 · '멈춤?' · 보드 · 주인 세션이 사라지면 '잔재' → 다음 갱신에 치움")
        Variety.shared.seed(76)
        let harness = SceneHarness()
        let scene = harness.scene
        func agent(_ id: String, phase: String, minutesAgo: Double, kind: SubagentInfo.Kind = .workflow) -> SubagentInfo {
            SubagentInfo(id: id, label: kind == .workflow ? "빌드 \(id)" : "조사 \(id)", model: "sonnet", kind: kind, workflow: kind == .workflow ? "wf_build" : nil, phase: phase,
                         lastActivity: harness.clock.addingTimeInterval(-minutesAgo * 60), active: true)
        }
        var alpha = (0..<8).map { session(Int32(25_001 + $0), "알파", .working, order: Double($0)) }
        let delta = (0..<8).map { session(Int32(25_101 + $0), "델타", .working, order: Double(10 + $0)) }
        let beta = session(25_201, "베타", .working, order: 30)
        alpha[1].subagents = [agent("w1", phase: "구현", minutesAgo: 5), agent("w2", phase: "구현", minutesAgo: 25)]
        alpha[4].subagents = [agent("w3", phase: "검토", minutesAgo: 1)]
        alpha[6].subagents = [agent("s1", phase: "", minutesAgo: 1, kind: .subagent)]
        harness.sessions = alpha + delta + [beta]
        harness.feed()
        harness.run(3)
        guard let floor = scene.currentLayout.desks[alpha[0].id]?.floor, scene.workflowState(floor) != nil else { check(false, "알파 층 워크플로실 없음"); return }
        func robot(_ id: String) -> (robot: WorkflowRobot, point: CGPoint, tag: String?, light: Bool)? { scene.workflowRobots(floor).first { $0.robot.info.id == id } }
        // ① 멈춤?: w2(25분 전)는 빨간 등 · '멈춤?' · 보드에 이름, w1(5분 전) · w3(1분 전)은 그대로
        let w2 = robot("w2"), w1 = robot("w1")
        check(w2?.robot.stale == true && w2?.tag == "멈춤?" && w2?.light == true && w1?.robot.stale == false && w1?.tag == nil && w1?.light == false,
              "25분 전 기록 = 빨간 등 + '멈춤?' 꼬리표 · 5분 전 기록은 그대로")
        let board = scene.workflowState(floor)?.board ?? []
        check(board.first == "로봇 3대 가동 · 멈춤? 1" && board.contains("멈춤? · 빌드 w2"), "보드: \(board)")
        // ② 로봇을 누르면 (주인 세션 · 하위 에이전트) 손잡이
        var picked: (ProcessKey, SubagentInfo)?
        scene.onSelectSubagent = { picked = ($0, $1) }
        scene.focus(.all, animated: false)
        harness.run(0.1)
        if let w1 { scene.simulateClick(at: CGPoint(x: w1.point.x, y: w1.point.y + 6)) }
        check(picked?.0 == alpha[1].id && picked?.1.id == "w1" && SubagentSightings.shared.firstSeen("w1") != nil,
              "워크플로실 로봇을 누르면 onSelectSubagent(주인 pid \(picked?.0.pid ?? 0) · \(picked?.1.id ?? "없음")) · 처음 본 시각 기록됨")
        // ②-2 책상 옆 일반 하위 에이전트 로봇도(방에 다가가 있을 때)
        picked = nil
        scene.focus(.room("알파"), animated: false)
        harness.run(0.8)
        if let worker = scene.worker(for: alpha[6].id), let helper = worker.helperPoints.first {
            scene.simulateClick(at: CGPoint(x: worker.position.x + helper.point.x, y: worker.position.y + helper.point.y + 6))
        }
        check(picked?.0 == alpha[6].id && picked?.1.id == "s1", "책상 옆 하위 에이전트 로봇을 누르면 그 로봇(\(picked?.1.id ?? "없음"))")
        // ③ 가짜 시계 16분 뒤: w1(5분 전 → 21분 전)도 멈춤?
        harness.advanceClock(16 * 60)
        harness.feed()
        harness.run(0.5)
        check(robot("w1")?.robot.stale == true && robot("w1")?.tag == "멈춤?" && robot("w3")?.robot.stale == false,
              "가짜 시계 +16분: 21분 전 기록이 된 w1도 '멈춤?' · w3(17분 전)는 아직 아님")
        if let w1 = robot("w1") { shot(harness, "workflow-stale", rect: CGRect(x: w1.point.x - 80, y: w1.point.y - 12, width: 190, height: 70)) }
        // ④ 잔재: w3의 주인 세션이 사라짐(같은 층 다른 세션은 남음) → 전원이 꺼진 로봇 + '잔재' → 다음 갱신에 치움
        harness.sessions = alpha.filter { $0.id != alpha[4].id } + delta + [beta]
        harness.feed()
        harness.run(0.4)
        let residue = robot("w3")
        check(residue?.robot.residue == true && residue?.tag == "잔재" && scene.subagentOwner(alpha[4].id)?.project == "알파",
              "주인 세션이 사라진 로봇: 전원이 꺼지고 '잔재'(\(residue?.tag ?? "없음")) · 카드용 주인 세션은 마지막 모습으로")
        if let point = residue?.point { shot(harness, "workflow-residue", rect: CGRect(x: point.x - 100, y: point.y - 12, width: 190, height: 70)) }
        harness.feed()
        harness.run(0.6)
        check(robot("w3") == nil && scene.workflowState(floor)?.robots == 2, "다음 갱신: 잔재 로봇 치움(남은 로봇 \(scene.workflowState(floor)?.robots ?? -1)대)")
        // ⑤ 하위 에이전트 카드(SwiftUI)를 그려 본다: 토큰은 '토큰 정보 없음', 실행 시간은 처음 본 뒤(추정)
        if let owner = scene.subagentOwner(alpha[1].id), let info = owner.subagents.first(where: { $0.id == "w1" }) {
            let renderer = ImageRenderer(content: SubagentCard(session: owner, subagent: info).frame(width: 330).padding(14).background(Color.white))
            renderer.scale = 2
            let image = renderer.cgImage
            check(image.map { $0.width > 300 && $0.height > 200 } == true, "하위 에이전트 카드 그리기 \(image.map { "\($0.width)×\($0.height)" } ?? "실패")")
            if let image, let out { SnapshotTool.write(image, to: out.appendingPathComponent("subagent-card.png")) }
        } else {
            check(false, "카드용 세션 없음")
        }
        noSafetyNet(harness)
    }

    // MARK: 금고 방(기록 보관소)

    static func vaultRoom() {
        print("— vault-room: 금고 요약 → 서가 상자(칸마다 한 건) · 명판 · 기록관이 꽂고(늘 때) 꺼내 나감(줄 때) · 만료는 다락 · 누르면 복구함")
        Variety.shared.seed(75)
        let harness = SceneHarness()
        let scene = harness.scene
        harness.sessions = [session(24_001, "알파", .working, order: 0)]
        harness.feed()
        harness.run(1)
        let vault = scene.vaultNode
        var summary = OfficeScene.VaultSummary(sessions: 3, files: 5, git: 2, processes: 1, expired: 4, bytes: UInt64(2.5 * Fmt.gib))
        scene.setVault(summary)
        let shelves: [(VaultLayout.Shelf, Int)] = [(.sessions, 3), (.files, 5), (.git, 2), (.processes, 1), (.expired, 4)]
        check(vault.boxCount == 15 && vault.pending == 0 && shelves.allSatisfy { vault.boxCount($0.0) == $0.1 },
              "처음 요약(세션 3 · 파일 5 · git 2 · 프로세스 1 · 만료 4) → 연출 없이 상자 \(vault.boxCount)개, 칸마다 그 수")
        check(scene.vaultPlaqueText == "금고 · 15건 · 2.5GB" && scene.vaultShelfText(.files) == "파일 5", "명판 '\(scene.vaultPlaqueText ?? "없음")' · 칸 이름표 '\(scene.vaultShelfText(.files) ?? "없음")'")
        var floating = 0
        var climbed = false
        var fileShot = false
        let floor = vault.floorLine
        let observe: (TimeInterval) -> Void = { _ in
            if !vault.archivistGrounded { floating += 1 }
            if vault.archivist.position.y > floor + 1 { climbed = true }
        }
        // ① 세션 하나 정리됨(+1) → 기록관이 들고 와 사다리로 올라가 세션 칸에 꽂는다
        summary.sessions = 4
        summary.bytes = UInt64(2.9 * Fmt.gib)
        scene.setVault(summary)
        let filed = runUntil(harness, timeout: 30, probe: { now in
            observe(now)
            if !fileShot, vault.log.contains(where: { $0.hasPrefix("받음") }), vault.archivist.position.y > floor + 10 {
                fileShot = true
                shot(harness, "vault-room", rect: scene.vaultRect.insetBy(dx: -40, dy: 0))
            }
        }) { vault.boxCount(.sessions) == 4 && !vault.busy }
        check(filed != nil && climbed && ["받음 · sessions", "꽂음 · sessions"].allSatisfy(vault.log.contains) && scene.vaultPlaqueText == "금고 · 16건 · 2.9GB",
              "세션 +1: 기록관이 받아 들고 사다리로 올라가 꽂음 · 상자 4 · 명판 '\(scene.vaultPlaqueText ?? "")' · " + (filed.map { String(format: "%.1f초", $0) } ?? "30초 안에 못 끝남"))
        // ② 세션 하나 복구(−1) → 꺼내 들고 별관 왼쪽 끝으로 내보낸다
        summary.sessions = 3
        scene.setVault(summary)
        let restored = runUntil(harness, timeout: 30, probe: observe) { vault.boxCount(.sessions) == 3 && !vault.busy && vault.log.contains("내보냄 · sessions") }
        check(restored != nil && vault.log.contains("꺼냄 · sessions"), "세션 −1(복구): 꺼내 들고 나가 내보냄 · 상자 \(vault.boxCount(.sessions))")
        // ③ 만료: 파일 칸이 줄고 다락이 늘면 그 상자를 다락으로 옮긴다(복구가 아니다)
        summary.files = 4
        summary.expired = 5
        scene.setVault(summary)
        let expired = runUntil(harness, timeout: 30, probe: observe) { vault.boxCount(.expired) == 5 && vault.boxCount(.files) == 4 && !vault.busy }
        check(expired != nil && vault.log.contains("꺼냄 · files") && vault.log.last(where: { $0.hasPrefix("꽂음") }) == "꽂음 · expired" && !vault.log.contains("내보냄 · files"),
              "만료(파일 −1 · 만료 +1): 파일 칸에서 꺼내 다락에 꽂음(내보내지 않음)")
        // ④ 많이 늘어도 칸마다 12개까지만(넘는 수는 명판 · 칸 이름표가 말한다), 밀린 일은 셋까지만 연출
        summary.files = 40
        scene.setVault(summary)
        let capped = runUntil(harness, timeout: 60, probe: observe) { !vault.busy && vault.pending == 0 }
        check(capped != nil && vault.boxCount(.files) == VaultLayout.capacity && scene.vaultShelfText(.files) == "파일 40" && scene.vaultPlaqueText?.hasPrefix("금고 · 51건") == true,
              "파일 40건: 상자는 칸 한도 \(vault.boxCount(.files))개 · 칸 이름표 '\(scene.vaultShelfText(.files) ?? "")' · 명판 '\(scene.vaultPlaqueText ?? "")'")
        check(floating == 0 && vault.boxesSeated, "기록관은 늘 바닥이나 사다리 위(벗어난 순간 \(floating)회) · 상자는 모두 제자리")
        shot(harness, "vault-room-full", rect: scene.vaultRect.insetBy(dx: -40, dy: 0))
        // ⑤ 누르면 복구함(메인 연결) — 멀리서 누르면 그 방으로 다가간다
        var opened = 0
        scene.onSelectVault = { opened += 1 }
        scene.focus(.all, animated: false)
        harness.run(0.1)
        let rect = scene.vaultRect
        scene.simulateClick(at: CGPoint(x: rect.midX + 6, y: rect.minY + 50))
        harness.run(0.8)
        check(opened == 1 && scene.vaultLog.contains("누름"), "금고 방을 누르면 복구함 열기 \(opened)회")
        noSafetyNet(harness)
    }

    // MARK: 도구실 — 반입구 배송 · 회수

    static func toolDock() {
        print("— tool-dock: 새 앱 = 반입구 배송(상자 → 뜯기 → 볼트) · 끝난 앱 = 전원선 뽑고 반입구로 회수 · 위 단은 리프트로 · 뜬 것 없음")
        Variety.shared.seed(71)
        let harness = SceneHarness()
        let scene = harness.scene
        harness.apps = (0..<5).map { fakeApp($0, gb: Double(5 - $0)) }
        harness.sessions = [session(20_001, "알파", .working, order: 0)]
        harness.feed()
        harness.run(2)
        let room = scene.regionRect(.toolRoom)
        let first = (0..<5).compactMap { scene.toolInfo(appID($0)) }
        check(first.count == 5 && first.allSatisfy(\.installed) && Set(first.map(\.slot)) == Set(0..<5) && !scene.toolDockBusy,
              "처음 5대는 연출 없이 아래 단 0~4번 칸(큰 순서) · 기사 없음")
        let watch = ToolFloatWatch()
        let observe: (TimeInterval) -> Void = { _ in watch.observe(scene) }

        // ① 새 앱 → 위 단(5번 칸)으로 배송: 셔터 → 수레를 끌고 들어옴 → 리프트 → 상자 내려놓기 → 뜯기 → 볼트 → 화면 켜짐 → 나감
        let fresh = appID(5)
        harness.apps.append(fakeApp(5, gb: 0.6))
        harness.feed()
        var hiddenWhileCarried = true
        var arriveShot = false
        let arrived = runUntil(harness, timeout: 40, probe: { now in
            observe(now)
            if let info = scene.toolInfo(fresh), !scene.toolDockLog.contains(where: { $0.hasPrefix("상자 뜯음") }), !info.node.isHidden { hiddenWhileCarried = false }
            if !arriveShot, scene.toolDockLog.contains(where: { $0.hasPrefix("상자 뜯음") }) {
                arriveShot = true
                shot(harness, "tool-dock-arrive", rect: room.insetBy(dx: -6, dy: 0))
            }
        }) { scene.toolInfo(fresh)?.installed == true && !scene.toolDockBusy }
        let info = scene.toolInfo(fresh)
        let target = ToolRoom.point(5, floorLine: scene.line(scene.lobbyFloor))
        print("  기사 기록: \(scene.toolDockLog.joined(separator: " → "))")
        check(arrived != nil && watch.sawDoorOpen && watch.sawAtDock && hiddenWhileCarried,
              "새 앱: 셔터가 열리고 기사가 반입구에서 나타나 상자로 들여옴(뜯기 전엔 기계가 안 보임) · " + (arrived.map { String(format: "%.1f초", $0) } ?? "40초 안에 못 끝남"))
        check(info?.slot == 5 && info.map { abs($0.frame.midX - target.x) < 0.5 && abs($0.frame.minY - target.y) < 0.5 } == true && info?.powered == true,
              "설치 자리: 위 단 5번 칸(x \(Int(target.x)) · 선반 위) · 화면 켜짐")
        check(watch.sawRiding && ["상자 내려놓음", "상자 뜯음", "설치 끝", "반입구로 나감"].allSatisfy { step in scene.toolDockLog.contains { $0.hasPrefix(step) } },
              "위 단은 리프트를 올려 기사와 상자가 함께 선반 높이로 · 내려놓기 → 뜯기 → 볼트 → 나감")
        harness.run(0.6, probe: observe)   // 셔터가 내려오는 0.4초
        check(scene.toolDockProbe.door < 0.01 && !scene.toolDockProbe.visible, "끝나면 셔터 닫힘 · 기사 · 수레 퇴장")

        // ② 끝난 앱(위 단 5번) → 회수: 화면이 바로 꺼지고, 기사가 올라가 전원선을 뽑고 싣고 내려와 반입구로
        harness.apps.removeAll { $0.id == fresh }
        harness.feed()
        let poweredOff = info?.node.powered == false
        var departShot = false
        let departed = runUntil(harness, timeout: 40, probe: { now in
            observe(now)
            if !departShot, scene.toolDockLog.contains(where: { $0.hasPrefix("기계 실음") }), scene.toolDockProbe.visible, !scene.toolDockProbe.riding, scene.toolDockProbe.cargoY != nil {
                departShot = true
                harness.run(0.4)
                shot(harness, "tool-dock-depart", rect: room.insetBy(dx: -6, dy: 0))
            }
        }) { scene.leavingToolIDs.isEmpty && !scene.toolDockBusy }
        check(poweredOff && scene.toolInfo(fresh) == nil, "앱 종료 즉시: 화면 · 표시등 꺼짐 · 누를 수 없음")
        check(departed != nil && ["전원선 뽑음", "기계 실음"].allSatisfy { step in scene.toolDockLog.contains { $0.hasPrefix(step) } } && info?.node.parent == nil,
              "회수: 전원선 뽑기 → 싣기 → 반입구로 내감(장면에서 사라짐) · " + (departed.map { String(format: "%.1f초", $0) } ?? "40초 안에 못 끝남"))

        // ③ 아래 단 앱(1번 칸) 종료 → 회수, 그 자리에 새 앱 → 아래 단으로 배송(리프트 없이)
        harness.apps.removeAll { $0.id == appID(1) }
        harness.feed()
        runUntil(harness, timeout: 40, probe: observe) { scene.leavingToolIDs.isEmpty && !scene.toolDockBusy }
        harness.apps.append(fakeApp(6, gb: 0.8))
        harness.feed()
        let lower = runUntil(harness, timeout: 40, probe: observe) { scene.toolInfo(appID(6))?.installed == true && !scene.toolDockBusy }
        check(lower != nil && scene.toolInfo(appID(6))?.slot == 1, "아래 단 앱이 빠진 1번 칸에 새 앱이 배송됨(첫 빈 칸 · 아래 단 먼저)")

        // ④ 배송 도중(상자를 뜯기 전) 앱이 끝남 → 상자째 도로 싣고 나감, 자리는 비워 둔다
        harness.apps.append(fakeApp(7, gb: 0.4))
        harness.feed()
        harness.run(2)
        harness.apps.removeAll { $0.id == appID(7) }
        harness.feed()
        let aborted = runUntil(harness, timeout: 40, probe: observe) { !scene.toolDockBusy && scene.leavingToolIDs.isEmpty }
        check(aborted != nil && scene.toolInfo(appID(7)) == nil && scene.toolDockLog.contains { $0.hasPrefix("배송 취소") },
              "뜯기 전에 끝난 앱: 상자째 도로 나감(설치 안 함) · 기록 \(scene.toolDockLog.suffix(3))")

        // ⑤ 강제 종료: 경비원이 그 칸 콘센트로 가서 전원선을 뽑고 → 설치 기사가 반입구로 내감
        let victim = appID(2)
        scene.evictStaff(victim, shout: "저장 안 했어요!")
        harness.apps.removeAll { $0.id == victim }
        var guardReached = false
        let evicted = runUntil(harness, timeout: 50, probe: { now in
            observe(now)
            let socket = (ToolRoom.bayX(2) + ToolRoom.socketDX + 9)
            if abs(scene.guardProbe.x - socket) < 2, scene.guardProbe.floor == scene.lobbyFloor { guardReached = true }
        }) { scene.leavingToolIDs.isEmpty && !scene.toolDockBusy && scene.guardIdle }
        check(evicted != nil && guardReached && scene.toolInfo(victim) == nil, "강제 종료: 경비원이 콘센트에서 전원선을 뽑고 기사가 내감 · 경비원 초소 복귀")
        check(watch.problems.isEmpty, "뜬 것 없음(수레 · 기사 · 짐 · 칸의 상자 · 기계)" + (watch.problems.isEmpty ? "" : " · " + watch.problems.joined(separator: " / ")))
        noSafetyNet(harness)
    }

    // MARK: 도구실 — 폭주

    static func toolBurst() {
        print("— tool-burst: CPU 80% 이상 = 폭주(떨림 · 팬 최대 · 경광등 회전 · 김), 20% 밑으로 내려올 때까지 유지")
        Variety.shared.seed(72)
        let harness = SceneHarness()
        let scene = harness.scene
        harness.apps = [fakeApp(0, gb: 3), fakeApp(1, gb: 2), fakeApp(2, gb: 1)]
        harness.sessions = [session(21_001, "알파", .working, order: 0)]
        harness.feed()
        harness.run(2)
        let id = appID(1)
        func state() -> (burst: Bool, shake: Bool, beacon: Bool, fan: CGFloat) {
            let node = scene.toolInfo(id)!.node
            return (node.bursting, node.shaking, node.beaconSpinning, node.fanSpeed)
        }
        let calm = state()
        harness.apps[1].cpuPercent = 92
        harness.feed()
        harness.run(1.2)
        let hot = state()
        shot(harness, "tool-burst", rect: scene.regionRect(.toolRoom).insetBy(dx: 40, dy: 0))
        harness.apps[1].cpuPercent = 50
        harness.feed()
        harness.run(1)
        let warm = state()
        harness.apps[1].cpuPercent = 12
        harness.feed()
        harness.run(1)
        let cooled = state()
        check(!calm.burst && !calm.shake && calm.fan == 0, "CPU 0%: 폭주 아님 · 팬 멈춤")
        check(hot.burst && hot.shake && hot.beacon && hot.fan >= 5 && scene.toolLog.contains { $0.hasPrefix("폭주") },
              String(format: "CPU 92%% → 폭주: 떨림 %@ · 경광등 %@ · 팬 속도 %.1f", hot.shake ? "예" : "아니오", hot.beacon ? "회전" : "멈춤", hot.fan))
        check(warm.burst && warm.shake, "CPU 50%: 아직 폭주 유지(20% 밑으로 내려와야 멈춘다)")
        check(!cooled.burst && !cooled.shake && !cooled.beacon && cooled.fan > 0 && cooled.fan < 5, String(format: "CPU 12%% → 폭주 끝 · 팬은 천천히(%.1f)", cooled.fan))
    }

    // MARK: 도구실 — 커짐

    static func toolGrowth() {
        print("— tool-growth: 메모리 순위가 오르면 한 단씩 커짐('커짐') · 순위 그대로여도 25% 넘게 늘면 커짐 · 줄면 줄어듦")
        Variety.shared.seed(73)
        let harness = SceneHarness()
        let scene = harness.scene
        harness.apps = [fakeApp(0, gb: 4), fakeApp(1, gb: 3), fakeApp(2, gb: 2), fakeApp(3, gb: 1), fakeApp(4, gb: 0.5)]
        harness.sessions = [session(22_001, "알파", .working, order: 0)]
        harness.feed()
        harness.run(2)
        let size = { (index: Int) in scene.toolInfo(appID(index))?.size ?? -1 }
        let start = (0..<5).map(size)
        check(start == [3, 2, 2, 1, 1], "처음 크기(순위대로): \(start) = [3, 2, 2, 1, 1]")
        // ① 4번 앱이 6GB로 → 순위 0 → 두 스냅샷 뒤부터 한 단씩 1 → 2 → 3, 바뀔 때마다 '커짐'
        harness.apps[4].footprint = UInt64(6 * Fmt.gib)
        var sizes: [Int] = [size(4)]
        var puffs = 0
        var shotTaken = false
        for _ in 0..<5 {
            harness.run(2) { _ in
                if scene.floatingTexts.contains("커짐") { puffs += 1 }
            }
            if sizes.last != size(4) {
                sizes.append(size(4))
                if !shotTaken, size(4) == 2 { shotTaken = true; harness.run(0.3); shot(harness, "tool-growth", rect: scene.regionRect(.toolRoom).insetBy(dx: 40, dy: 0)) }
            }
        }
        check(sizes == [1, 2, 3] && puffs > 0, "순위가 오른 앱: 한 단씩 \(sizes.map(String.init).joined(separator: " → ")) · '커짐' 표지 보임")
        check(size(0) == 2 && scene.toolLog.contains { $0.hasPrefix("줄어듦 · 앱0") }, "순위가 내려간 앱(4GB, 0위 → 1위): 3 → \(size(0)) '줄어듦'")
        // ② 순위는 그대로(3위)인데 메모리가 30% 늘면 커짐, 다시 줄면 줄어듦
        let before = size(3)
        harness.apps[3].footprint = UInt64(1.3 * Fmt.gib)
        harness.run(4.2)
        let grown = size(3)
        harness.apps[3].footprint = UInt64(1.0 * Fmt.gib)
        harness.run(4.2)
        let shrunk = size(3)
        check(grown == before + 1 && shrunk == before, "순위 그대로 메모리 +30%: \(before) → \(grown) · 다시 줄면 \(shrunk)")
        // ③ 이미 가장 큰데 또 33% 늘면 부풀기('커짐')
        harness.apps[4].footprint = UInt64(8 * Fmt.gib)
        var bulged = false
        harness.run(4.2) { _ in if scene.floatingTexts.contains("커짐") { bulged = true } }
        check(size(4) == 3 && bulged && scene.toolLog.contains { $0.hasPrefix("커짐(최대)") }, "가장 큰 기계가 또 커지면 부풀며 '커짐'(크기 3 유지)")
    }

    // MARK: 도구실 — 10대 · +N

    static func toolTen() {
        print("— tool-ten: 앱 13개 → 10대(2단 × 5칸)가 겹치지 않게 · 나머지는 '+3' · 누르면 그 앱")
        Variety.shared.seed(74)
        let harness = SceneHarness()
        let scene = harness.scene
        harness.apps = (0..<13).map { fakeApp($0, gb: 6 - Double($0) * 0.4) }
        harness.sessions = [session(23_001, "알파", .working, order: 0)]
        harness.feed()
        harness.run(2)
        let floor = scene.line(scene.lobbyFloor)
        let infos = scene.toolIDs.compactMap(scene.toolInfo)
        var overlaps: [String] = []
        for (i, a) in infos.enumerated() { for b in infos.dropFirst(i + 1) where a.frame.insetBy(dx: -1, dy: 0).intersects(b.frame) { overlaps.append("\(a.slot)·\(b.slot)") } }
        let inside = infos.allSatisfy { $0.frame.minX >= CGFloat(ToolRoom.x0) && $0.frame.maxX <= ToolRoom.dockLeft - 2 }
        let tiers = infos.allSatisfy { info in
            ToolRoom.isUpper(info.slot) ? abs(info.frame.minY - floor - ToolRoom.upperY) < 0.5 && info.frame.maxY <= floor + 70
                : abs(info.frame.minY - floor) < 0.5 && info.frame.maxY <= floor + ToolRoom.upperY - 3
        }
        check(infos.count == 10 && Set(infos.map(\.slot)).count == 10, "보이는 기계 \(infos.count)대 · 자리 \(Set(infos.map(\.slot)).count)곳")
        check(overlaps.isEmpty && inside && tiers, "겹침 \(overlaps.count)쌍 · 도구실 안(반입구 앞은 비움) \(inside) · 아래 단은 위 단 보 밑, 위 단은 꼭대기 보 밑 \(tiers)")
        check(scene.toolOverflowText == "+3", "넘친 앱 표지: \(scene.toolOverflowText ?? "없음") = +3")
        check(scene.toolInfo(appID(0))?.slot == 0 && scene.toolInfo(appID(5))?.slot == 5, "큰 앱부터: 가장 큰 앱 = 아래 단 0번, 6번째 = 위 단 5번")
        var picked: String?
        scene.onSelectApp = { picked = $0 }
        scene.focus(.all, animated: false)   // 층 초점 밖을 누르면 전체 보기로 돌아가므로 먼저 전체 보기에서 누른다
        harness.run(0.1)
        if let target = scene.toolInfo(appID(7)) {
            scene.simulateClick(at: CGPoint(x: target.frame.midX, y: target.frame.midY))
        }
        check(picked == appID(7), "위 단 기계를 누르면 그 앱(\(picked ?? "없음"))")
        shot(harness, "tool-ten", rect: scene.regionRect(.toolRoom).insetBy(dx: -6, dy: 0))
        // 보이는 앱 둘이 끝나면: 반입구로 회수 → 빈 칸에 넘쳤던 앱이 조용히(실행 중이던 앱 — 배송 연출 없음) 들어오고 +1
        harness.apps.removeAll { $0.id == appID(2) || $0.id == appID(8) }
        harness.feed()
        runUntil(harness, timeout: 60) { scene.leavingToolIDs.isEmpty && !scene.toolDockBusy }
        harness.run(2.5)
        check(scene.toolIDs.count == 10 && scene.toolOverflowText == "+1" && scene.toolLog.filter { $0.hasPrefix("조용히 들임") }.count == 2,
              "끝난 두 앱은 회수 · 넘쳤던 두 앱이 조용히 빈 칸으로 · 남은 표지 \(scene.toolOverflowText ?? "없음")")
    }
}
