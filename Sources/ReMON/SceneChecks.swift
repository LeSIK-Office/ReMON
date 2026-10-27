import AppKit
import Metal
import ReMONCore
import SpriteKit

/// 검수용 장면 시험(결정적 재현): `ReMON --scene-check <이름|all> [--out <폴더>]`.
/// 실제 OfficeScene에 가짜 스냅샷을 2초마다(수집 엔진과 같은 주기) 넣고, SKRenderer로 시간을 1/60초씩 직접 돌린다.
/// 창·화면 기록 권한·실제 세션이 필요 없고, 같은 씨앗이면 매번 같은 결과가 나온다. --out을 주면 장면을 PNG로 남긴다.
@MainActor
enum SceneChecks {
    private static var failures = 0
    static var out: URL?

    static func run(_ name: String, out: URL?) -> Int32 {
        self.out = out
        let checks: [(String, () -> Void)] = [
            ("elevator-hall", elevatorHall),
            ("elevator-lobby", elevatorLobby),
            ("roof-float", roofFloat),
            ("depart-race", departRace),
            ("safety-net", safetyNet),
            ("porter", porter),
            ("porter-snap", porterSnap),
            ("workflow-room", workflowRoom),
            ("bubble-order", bubbleOrder),
            ("audit-rules", auditRules),
            ("audit-report", auditReportFlow),
            ("audit-runner", auditRunner),
            ("overview-fit", overviewFit),
            ("long-waiting", longWaitingRule),
            ("click-outside", clickOutside),
            ("audit-tour", auditTour),
            ("audit-lesson", auditLesson),
            ("audit-evict", auditEvict),
            ("audit-full", auditFull),
            ("audit-abort", auditAbort),
            ("audit-ledger", auditLedger),
            ("porter-unload", porterUnload),
            ("tool-depth", toolDepth),
            ("speech", speech),
            ("trainer-announce", trainerAnnounce),
            ("janitor-announce", janitorAnnounce),
            ("porter-zero", porterZero),
            ("tool-dock", toolDock),
            ("tool-burst", toolBurst),
            ("tool-growth", toolGrowth),
            ("tool-ten", toolTen),
            ("vault-room", vaultRoom),
            ("workflow-subagent", workflowSubagent),
            ("celebrate-papers", celebratePapers),
            ("rooms-overview", roomsOverview),
            ("pool-steam", poolSteam),
            ("pool-lights", poolLights),
            ("pool-party", poolParty),
            ("disk-stock", diskStock),
            ("inventory-flow", inventoryFlow),
            ("inventory-cancel", inventoryCancel),
            ("inventory-safety", inventorySafety),
            ("inventory-order", inventoryOrder),
            ("inventory-idle", inventoryIdle),
            ("clutter-levels", clutterLevels),
            ("clutter-rooms", clutterRooms),
            ("clutter-janitor", clutterJanitor),
            ("clutter-ledger", clutterLedger),
            ("dashboard-layout", dashboardLayout),
            ("disk-map", diskMapChecks),
            ("window-lifecycle", windowLifecycle),
            ("project-cleanup-flow", projectCleanupFlow),
        ]
        // 비용이 드는 실제 모델 호출은 all에 넣지 않고 이름으로만 돈다.
        let explicit: [(String, () -> Void)] = [("audit-live", auditLive)]
        let selected = name == "all" ? checks : (checks + explicit).filter { $0.0 == name }
        if selected.isEmpty { print("unknown scene check: \(name) · \(checks.map(\.0).joined(separator: " "))"); return 2 }
        for (_, check) in selected { check() }
        print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
        return failures == 0 ? 0 : 1
    }

    static func check(_ condition: Bool, _ message: String) {
        print((condition ? "PASS " : "FAIL ") + message)
        if !condition { failures += 1 }
    }

    static func session(_ pid: Int32, _ project: String, _ state: SessionState, order: Double, subagents: [SubagentInfo] = []) -> AgentSession {
        var session = AgentSession(id: ProcessKey(pid: pid, start: 1_760_000_000 + Int64(pid)), kind: pid % 3 == 0 ? .codexCLI : .claudeCode, rootPID: pid, pids: [pid],
                                   footprint: 400 << 20, cpuPercent: state == .working ? 18 : 0, startTime: Date().addingTimeInterval(-5400 + order),
                                   cwd: "/tmp/\(project)", project: project, state: state)
        session.subagents = subagents
        return session
    }

    static func describe(_ worker: WorkerNode?) -> String {
        guard let worker else { return "없음(퇴장)" }
        let place: String
        switch worker.place {
        case .desk: place = "책상"
        case .rest(let spot): place = "\(spot.kind)@\(spot.x)"
        case .lobby: place = "로비"
        case .lounge: place = "라운지"
        case .away: place = "없음"
        }
        return String(format: "층 %d x=%.1f y=%.0f 자리=%@ 투명도=%.2f%@%@%@", worker.floorIndex, worker.position.x, worker.position.y, place, worker.alpha,
                      worker.busy ? " busy" : "", worker.leaving ? " leaving" : "", worker.action(forKey: "move") != nil ? " 이동중" : "")
    }

    static func shot(_ harness: SceneHarness, _ name: String, focus: OfficeFocus) {
        guard let out else { return }
        harness.scene.focus(focus, animated: false)
        harness.run(0.05)
        harness.screenshot(out.appendingPathComponent("\(name).png"))
    }

    static func shot(_ harness: SceneHarness, _ name: String, rect: CGRect) {
        guard let out else { return }
        harness.scene.frameCamera(on: rect)
        harness.run(0.05)
        harness.screenshot(out.appendingPathComponent("\(name).png"))
    }

    // MARK: 버그 1 — 엘리베이터 문 안에 멈춰 선 직원

    /// 강당(오래 쉼) → 일 시작 → 3층 오른쪽 책상. 강당 엘리베이터까지 3초 넘게 걷는 길.
    static func elevatorHall() {
        print("— elevator-hall: 강당 의자(오른쪽) → 팀 층 책상. 2초마다 스냅샷")
        Variety.shared.seed(11)
        let harness = SceneHarness()
        var team = (0..<8).map { session(Int32(3001 + $0), "알파", .longIdle, order: Double($0)) }
        harness.sessions = team
        harness.feed()
        harness.run(4)
        let key = team[7].id
        print("  시작: \(describe(harness.scene.worker(for: key)))")
        team[7].state = .working
        harness.sessions = team
        let started = harness.elapsed
        var shaftRun = 0.0, worstShaft = 0.0, last = harness.elapsed
        var arrived: TimeInterval?
        var stuckSample = ""
        harness.run(70) { now in
            guard let worker = harness.scene.worker(for: key) else { return }
            let inShaft = abs(worker.position.x - CGFloat(BuildingLayout.elevatorX)) <= 6 && worker.alpha > 0.5
            shaftRun = inShaft ? shaftRun + (now - last) : 0
            last = now
            if shaftRun > worstShaft { worstShaft = shaftRun; stuckSample = describe(worker) }
            if arrived == nil, let desk = harness.scene.currentLayout.desks[key], worker.place == .desk, worker.floorIndex == desk.floor,
               abs(worker.position.x - CGFloat(desk.seatX)) <= 1, worker.action(forKey: "move") == nil {
                arrived = now - started
            }
            if Int((now - started) * 4) % 40 == 0 { print(String(format: "  t+%4.0fs %@", now - started, describe(worker))) }
        }
        shot(harness, "elevator-hall", focus: .floor(2))
        check(arrived.map { $0 < 45 } ?? false, "일 시작 15초(안정화) 뒤 책상 도착: " + (arrived.map { String(format: "%.1f초", $0) } ?? "70초 안에 못 감"))
        check(worstShaft <= 2, String(format: "엘리베이터 칸에 보이게 서 있던 최장 시간 %.1f초 ≤ 2초", worstShaft) + (worstShaft > 2 ? " · \(stuckSample)" : ""))
        noSafetyNet(harness)
    }

    /// 원인을 고쳤다면 안전망(1초 점검)이 손댈 일이 없어야 한다 — 안전망이 버그를 가려 통과한 것이 아님을 확인.
    static func noSafetyNet(_ harness: SceneHarness) {
        let fixes = harness.scene.safetyFixes
        check(fixes.isEmpty, "안전망 개입 \(fixes.count)회" + (fixes.isEmpty ? "" : " · " + fixes.prefix(3).joined(separator: " / ")))
    }

    /// 로비 놀이 자리(오른쪽 별관) → 옥상 놀이 자리. 놀이 자리를 무작위로 고르므로 씨앗을 바꿔 가며 그 경로가 나오는 경우를 찾는다.
    static func elevatorLobby() {
        print("— elevator-lobby: 로비 별관 독서 의자 → 옥상(놀이 자리 교체). 2초마다 스냅샷")
        for seed in UInt64(1)...200 {
            Variety.shared.seed(seed)
            let harness = SceneHarness()
            let me = session(4001, "베타", .idle, order: 0)
            harness.sessions = [me, session(4002, "감마", .working, order: 1)]
            harness.feed()
            guard let worker = harness.scene.worker(for: me.id), worker.floorIndex == 1, worker.position.x >= 400 else { continue }
            let startSpot = describe(worker)
            var leftLobby: TimeInterval?
            var shaftRun = 0.0, worstShaft = 0.0, last = harness.elapsed
            var stuckSample = ""
            var sawRoofTrip = false
            harness.run(150) { now in
                guard let worker = harness.scene.worker(for: me.id) else { return }
                // 로비 놀이 자리는 모두 x 150 이상 → 로비에서 x 100 밑으로 가면 엘리베이터로 가는 길이다.
                if worker.floorIndex == 1, worker.position.x < 100 { sawRoofTrip = true }
                if leftLobby == nil, worker.floorIndex == harness.scene.currentLayout.roofIndex { leftLobby = now }
                let inShaft = abs(worker.position.x - CGFloat(BuildingLayout.elevatorX)) <= 6 && worker.alpha > 0.5
                shaftRun = inShaft ? shaftRun + (now - last) : 0
                last = now
                if shaftRun > worstShaft { worstShaft = shaftRun; stuckSample = describe(worker) }
            }
            // 다음 놀이 자리가 로비 안이면(엘리베이터를 안 탐) 다른 씨앗으로.
            guard sawRoofTrip else { continue }
            print("  씨앗 \(seed) · 시작 \(startSpot)")
            print("  150초 뒤: \(describe(harness.scene.worker(for: me.id)))")
            shot(harness, "elevator-lobby", focus: .floor(1))
            check(leftLobby != nil, "로비 → 옥상 이동 완료" + (leftLobby == nil ? " 실패" : ""))
            check(worstShaft <= 2, String(format: "엘리베이터 칸에 보이게 서 있던 최장 시간 %.1f초 ≤ 2초", worstShaft) + (worstShaft > 2 ? " · \(stuckSample)" : ""))
            noSafetyNet(harness)
            return
        }
        check(false, "로비 → 옥상 경로가 나오는 씨앗을 찾지 못함")
    }

    // MARK: 버그 2 — 옥상 위 밤하늘에 뜬 직원

    /// 옥상에서 쉬던 직원이 일을 시작해 엘리베이터로 걷는 중에, 다른 팀이 모두 퇴근해 층이 줄어든다(옥상이 한 층 내려앉음).
    static func roofFloat() {
        print("— roof-float: 옥상 → 책상으로 걷는 중 팀 층 하나가 사라짐(자동 층 정리)")
        for seed in UInt64(1)...300 {
            Variety.shared.seed(seed)
            let harness = SceneHarness()
            let alpha = (0..<8).map { session(Int32(5001 + $0), "알파", .working, order: Double($0)) }
            let delta = (0..<8).map { session(Int32(5101 + $0), "델타", .working, order: Double(10 + $0)) }
            var me = session(5201, "베타", .idle, order: 30)
            harness.sessions = alpha + delta + [me]
            harness.feed()
            let roof = harness.scene.currentLayout.roofIndex
            guard let worker = harness.scene.worker(for: me.id), worker.floorIndex == roof, worker.position.x >= 200 else { continue }
            print("  씨앗 \(seed) · 층 \(harness.scene.currentLayout.floors.count)개 · 시작 \(describe(worker))")
            harness.run(3)
            me.state = .working
            harness.sessions = alpha + delta + [me]
            // 안정화(15초) 직후 걷기 시작 → 3초 뒤 델타 팀 전원 퇴근
            harness.run(19)
            print("  층 줄기 직전: \(describe(harness.scene.worker(for: me.id)))")
            harness.sessions = alpha + [me]
            let shrinkAt = harness.elapsed
            var outside = 0.0, worstOutside = 0.0, last = harness.elapsed
            var outsideSample = ""
            var arrived: TimeInterval?
            var deltaGoneAt: TimeInterval?
            var alphaSeatedAt: TimeInterval?
            let floorsBefore = harness.scene.currentLayout.floors.count
            harness.run(60) { now in
                let layout = harness.scene.currentLayout
                if deltaGoneAt == nil, delta.allSatisfy({ harness.scene.worker(for: $0.id) == nil }) { deltaGoneAt = now - shrinkAt }
                // 델타 방이 비면 알파 방이 아래층으로 내려온다(층 정리) → 알파 8명도 엘리베이터로 옮겨 앉아야 한다.
                if alphaSeatedAt == nil, layout.floors.count < floorsBefore, alpha.allSatisfy({ member in
                    guard let worker = harness.scene.worker(for: member.id), let desk = layout.desks[member.id] else { return false }
                    return worker.place == .desk && worker.floorIndex == desk.floor && abs(worker.position.x - CGFloat(desk.seatX)) <= 1 && worker.action(forKey: "move") == nil
                }) { alphaSeatedAt = now - shrinkAt }
                guard let worker = harness.scene.worker(for: me.id) else { return }
                let top = CGFloat(layout.height)
                let floating = worker.position.y > top || !layout.floors.indices.contains(worker.floorIndex)
                outside = floating ? outside + (now - last) : 0
                last = now
                if outside > worstOutside { worstOutside = outside; outsideSample = describe(worker) + " · 건물 높이 \(layout.height)" }
                if arrived == nil, let desk = layout.desks[me.id], worker.place == .desk, worker.floorIndex == desk.floor,
                   abs(worker.position.x - CGFloat(desk.seatX)) <= 1, worker.action(forKey: "move") == nil {
                    arrived = now - shrinkAt
                }
                if Int((now - shrinkAt) * 4) % 40 == 0 { print(String(format: "  층 줄고 t+%4.0fs 층 %d개 %@", now - shrinkAt, layout.floors.count, describe(worker))) }
            }
            shot(harness, "roof-float", focus: .all)
            check(worstOutside <= 1, String(format: "건물 밖(옥상 위 하늘)·없는 층에 머문 최장 시간 %.1f초 ≤ 1초", worstOutside) + (worstOutside > 1 ? " · \(outsideSample)" : ""))
            check(arrived != nil, "층이 줄어든 뒤 새 책상 도착: " + (arrived.map { String(format: "%.1f초", $0) } ?? "60초 안에 못 감"))
            check(deltaGoneAt != nil, "퇴근한 델타 팀 8명 모두 퇴장: " + (deltaGoneAt.map { String(format: "%.1f초", $0) } ?? "60초 뒤에도 남음"))
            let strandedAlpha = alpha.filter { member in
                guard let worker = harness.scene.worker(for: member.id), let desk = harness.scene.currentLayout.desks[member.id] else { return true }
                return worker.floorIndex != desk.floor || abs(worker.position.x - CGFloat(desk.seatX)) > 1
            }
            check(alphaSeatedAt != nil, "아래층으로 옮긴 알파 팀 8명 모두 새 책상에: " + (alphaSeatedAt.map { String(format: "%.1f초", $0) } ?? "\(strandedAlpha.count)명이 못 감(엘리베이터 앞)"))
            noSafetyNet(harness)
            return
        }
        check(false, "옥상 놀이 자리가 나오는 씨앗을 찾지 못함")
    }

    // MARK: 퇴근 직원은 반드시 사라진다

    /// 회귀 방지: 출근 연출(문 발차기·살금살금) 도중에 세션이 끝나는 경우. 씨앗 40개로 연출 변형·대사를 바꿔 가며 남는 직원이 없는지.
    static func departRace() {
        print("— depart-race: 출근 연출 0.3초 뒤 퇴근(짧은 세션) · 씨앗 40개")
        var stuck: [String] = []
        var netFixes = 0
        for seed in UInt64(1)...40 {
            Variety.shared.seed(seed)
            let harness = SceneHarness()
            harness.feedInterval = .infinity
            let base = session(6001, "알파", .working, order: 0)
            harness.sessions = [base]
            harness.feed()
            harness.run(1)
            let short = session(6002, "알파", .working, order: 1)
            harness.sessions = [base, short]
            harness.feed()
            harness.run(0.3)
            harness.sessions = [base]
            harness.feed()
            harness.run(40)
            if let worker = harness.scene.worker(for: short.id) { stuck.append("씨앗 \(seed): \(describe(worker))") }
            netFixes += harness.scene.safetyFixes.count
        }
        stuck.prefix(3).forEach { print("  남음 · \($0)") }
        check(stuck.isEmpty, "짧은 세션 퇴근 40회 중 40초 뒤에도 남은 직원 \(stuck.count)명")
        check(netFixes == 0, "안전망 개입 \(netFixes)회(40회 합계)")
    }

    // MARK: 안전망 — 끊긴 연출을 바로잡는다

    static func safetyNet() {
        print("— safety-net: 연출이 끊긴 직원을 1초 점검이 바로잡는지(인위적으로 끊음)")
        Variety.shared.seed(5)
        let harness = SceneHarness()
        let members = (0..<4).map { session(Int32(7001 + $0), "알파", .working, order: Double($0)) }
        harness.sessions = members
        harness.feed()
        harness.run(3)
        // ① 퇴근 도중 이동이 끊김(연출 키가 지워짐)
        harness.sessions = Array(members.dropFirst())
        harness.feed()
        harness.run(2.5)
        harness.scene.worker(for: members[0].id)?.removeAllActions()
        // ② 연출 중(busy)인 직원이 건물 밖 하늘에 남음
        if let worker = harness.scene.worker(for: members[1].id) {
            worker.removeAllActions()
            worker.busy = true
            worker.position = CGPoint(x: 20, y: CGFloat(harness.scene.currentLayout.height + 40))
        }
        // ③ 없는 층 번호를 들고 엘리베이터 칸에 멈춤
        if let worker = harness.scene.worker(for: members[2].id) {
            worker.removeAllActions()
            worker.busy = true
            worker.floorIndex = 42
            worker.position.x = CGFloat(BuildingLayout.elevatorX)
        }
        var gone: TimeInterval?, skyFixed: TimeInterval?, floorFixed: TimeInterval?
        let start = harness.elapsed
        harness.run(75) { now in
            let layout = harness.scene.currentLayout
            if gone == nil, harness.scene.worker(for: members[0].id) == nil { gone = now - start }
            if skyFixed == nil, let worker = harness.scene.worker(for: members[1].id), worker.position.y <= CGFloat(layout.height), !worker.busy { skyFixed = now - start }
            if floorFixed == nil, let worker = harness.scene.worker(for: members[2].id), layout.floors.indices.contains(worker.floorIndex),
               abs(worker.position.x - CGFloat(BuildingLayout.elevatorX)) > 6 { floorFixed = now - start }
        }
        print("  끝: ① \(describe(harness.scene.worker(for: members[0].id))) ② \(describe(harness.scene.worker(for: members[1].id))) ③ \(describe(harness.scene.worker(for: members[2].id)))")
        check(gone.map { $0 <= 62 } ?? false, "① 이동이 끊긴 퇴근 직원 퇴장: " + (gone.map { String(format: "%.1f초", $0) } ?? "75초 뒤에도 남음"))
        check(skyFixed.map { $0 <= 3 } ?? false, "② 하늘에 남은 연출 중 직원 제자리로: " + (skyFixed.map { String(format: "%.1f초", $0) } ?? "그대로"))
        check(floorFixed.map { $0 <= 10 } ?? false, "③ 없는 층·엘리베이터 칸에 멈춘 직원 제자리로: " + (floorFixed.map { String(format: "%.1f초", $0) } ?? "그대로"))
    }
}

extension SceneChecks {
    // MARK: 기계실 짐꾼

    /// 스냅샷 값이 바뀐 뒤 보이는 상자 수가 어떻게 바뀌는지 기록한다: 한 번에 몇 개씩, 언제 실제 값에 닿는지, 짐꾼이 엘리베이터로 들어왔는지.
    private static func follow(_ harness: SceneHarness, _ stock: WarehouseNode.Stock, seconds: TimeInterval, until goal: Int) -> (reached: TimeInterval?, biggestStep: Int, changes: Int, enteredFromShaft: Bool) {
        let warehouse = harness.scene.warehouseNode
        var last = warehouse.shown[stock] ?? 0
        var biggest = 0, changes = 0
        var reached: TimeInterval?
        var fromShaft = false
        let start = harness.elapsed
        harness.run(seconds) { now in
            let value = warehouse.shown[stock] ?? 0
            if value != last { biggest = max(biggest, abs(value - last)); changes += 1; last = value }
            if warehouse.porterVisible, abs(warehouse.porter.position.x - CGFloat(BuildingLayout.elevatorX)) <= 6, abs(warehouse.porter.position.y - warehouse.floorLine) < 1 { fromShaft = true }
            if reached == nil, value == goal, !warehouse.busy { reached = now - start }
        }
        return (reached, biggest, changes, fromShaft)
    }

    /// 스왑이 늘면 짐꾼이 지하 엘리베이터로 들어와 상자를 하나씩 쌓고, 줄면 하나씩 들고 나간다. 디스크 선반도 같다.
    static func porter() {
        print("— porter: 스왑 2→7→3GB, 디스크 50→60% · 보이는 상자 수는 짐꾼이 한 개씩 바꾼다")
        Variety.shared.seed(21)
        let harness = SceneHarness()
        harness.sessions = [session(8001, "알파", .working, order: 0)]
        harness.feed()
        let warehouse = harness.scene.warehouseNode
        check(warehouse.shown[.swap] == 2 && warehouse.shown[.disk] == 24 && !warehouse.porterVisible,
              "처음 값은 연출 없이: 스왑 \(warehouse.shown[.swap] ?? -1)상자 · 디스크 \(warehouse.shown[.disk] ?? -1)칸 · 짐꾼 없음")
        harness.run(3)
        let idleCost = harness.measureUpdateCost(seconds: 4)

        harness.swapGB = 7
        harness.run(2.5)
        let activeCost = harness.measureUpdateCost(seconds: 4)
        shot(harness, "porter-carrying", focus: .region(.machineRoom))
        let up = follow(harness, .swap, seconds: 40, until: 7)
        check(up.enteredFromShaft, "스왑 +5GB: 짐꾼이 지하 엘리베이터에서 나타남")
        check(up.biggestStep <= 1 && up.reached != nil, "상자 2→7: 한 번에 최대 \(up.biggestStep)개씩 바뀜 · " + (up.reached.map { String(format: "%.1f초에 7상자 · 짐꾼 퇴장", $0 + 6.5) } ?? "40초 안에 못 맞춤"))
        shot(harness, "porter-stacked", focus: .region(.machineRoom))

        harness.swapGB = 3
        let down = follow(harness, .swap, seconds: 40, until: 3)
        check(down.biggestStep <= 1 && down.reached != nil, "스왑 −4GB: 상자 7→3, 한 번에 최대 \(down.biggestStep)개씩 · " + (down.reached.map { String(format: "%.1f초", $0) } ?? "40초 안에 못 맞춤"))

        harness.diskUsed = 0.6
        let disk = follow(harness, .disk, seconds: 50, until: 29)
        check(disk.biggestStep <= 1 && disk.reached != nil && disk.enteredFromShaft, "디스크 50→60%: 선반 24→29칸, 한 번에 최대 \(disk.biggestStep)칸씩 · " + (disk.reached.map { String(format: "%.1f초", $0) } ?? "50초 안에 못 맞춤"))
        shot(harness, "porter-disk", focus: .region(.machineRoom))

        // 반올림 경계에서 오락가락(4.45 ↔ 4.55GB)하면 짐꾼이 왔다 갔다 하지 않는다.
        harness.swapGB = 4
        _ = follow(harness, .swap, seconds: 30, until: 4)
        var trips = 0, wasBusy = false
        for index in 0..<12 {
            harness.swapGB = index % 2 == 0 ? 4.45 : 4.55
            harness.run(2) { _ in
                if warehouse.busy && !wasBusy { trips += 1 }
                wasBusy = warehouse.busy
            }
        }
        check(trips == 0, "4.45 ↔ 4.55GB를 2초마다 오가도 짐꾼 출동 \(trips)회")
        check(harness.scene.workerKeys.count == 1, "짐꾼은 직원(에이전트)이 아님: 장면의 직원 \(harness.scene.workerKeys.count)명 = 세션 1개")
        // 꾸준한 비용: 텍스처·말풍선을 한 번 만든 뒤(위 운반들), 운반 한 번 동안 다시 잰다.
        let steadyIdle = harness.measureUpdateCost(seconds: 4)
        harness.swapGB = 9
        harness.run(3)
        let steadyActive = harness.measureUpdateCost(seconds: 4)
        print(String(format: "  장면 갱신 비용(SKRenderer.update, 1/60초 한 프레임, 그리기 제외) 중앙값: 짐꾼 없음 %.1fµs · 운반 중 %.1fµs (첫 운반 평균 %.1fµs → %.1fµs: 텍스처·말풍선 처음 만들기 포함)",
                     steadyIdle.median * 1e6, steadyActive.median * 1e6, idleCost.mean * 1e6, activeCost.mean * 1e6))
    }

    /// 장면이 멈춘 동안(최소화·다른 화면: 스냅샷은 계속 옴 / 창 닫힘: 스냅샷도 없음) 값이 바뀌면, 다시 돌 때 첫 프레임에 실제 값으로 맞춘다.
    static func porterSnap() {
        print("— porter-snap: 멈춘 동안 바뀐 값은 다시 돌 때 바로 · 큰 변화는 6개만 나른다")
        Variety.shared.seed(22)
        let harness = SceneHarness()
        harness.sessions = [session(8101, "알파", .working, order: 0)]
        harness.feed()
        harness.run(3)
        let warehouse = harness.scene.warehouseNode
        // ① 최소화·다른 화면: 프레임은 멈추고 스냅샷은 2초마다 계속
        harness.paused = true
        harness.swapGB = 12
        harness.run(20)
        let frozen = warehouse.shown[.swap] ?? -1
        harness.paused = false
        harness.run(1.0 / 60)
        check(warehouse.shown[.swap] == 12 && !warehouse.porterVisible, "① 멈춘 동안 2→12GB(그동안 보인 값 \(frozen)) → 다시 돌자마자 \(warehouse.shown[.swap] ?? -1)상자 · 짐꾼 없음")
        // ② 창 닫힘: 스냅샷도 안 들어오다가, 다시 열 때 한 번(show()) 들어온다
        harness.run(3)
        harness.paused = true
        harness.feedInterval = .infinity
        harness.swapGB = 5
        harness.diskUsed = 0.3
        harness.run(30)
        harness.feed()
        harness.paused = false
        harness.run(1.0 / 60)
        check(warehouse.shown[.swap] == 5 && warehouse.shown[.disk] == 14, "② 창을 닫은 동안 12→5GB · 디스크 50→30% → 다시 열자마자 \(warehouse.shown[.swap] ?? -1)상자 · \(warehouse.shown[.disk] ?? -1)칸")
        // ③ 크게 늘면(+25GB) 6개만 나르고 나머지는 바로 맞춘다 → 늘 실제 값에 빨리 닿는다
        harness.feedInterval = 2
        harness.run(3)
        harness.swapGB = 30
        let big = follow(harness, .swap, seconds: 30, until: 30)
        check(big.reached.map { $0 < 25 } ?? false, "③ 5→30GB: " + (big.reached.map { String(format: "%.1f초에 30상자(짐꾼이 마지막 6개만 나름)", $0) } ?? "30초 안에 못 맞춤"))
        // ④ 운반 도중 연출이 끊겨도(액션 지움) 40초 감시로 실제 값에 맞춘다
        harness.swapGB = 20
        harness.run(5)
        warehouse.porter.removeAllActions()
        let stuck = follow(harness, .swap, seconds: 50, until: 20)
        check(stuck.reached != nil, "④ 운반이 끊긴 짐꾼 → 감시가 실제 값으로: " + (stuck.reached.map { String(format: "%.1f초", $0) } ?? "50초 뒤에도 못 맞춤"))
    }
}

extension SceneChecks {
    // MARK: 워크플로실

    /// 팀 층 별관(맨 위 상황실 층 제외)이 워크플로실이다. 그 층 세션의 워크플로 에이전트는 방의 콘솔 앞에서, 일반 하위 에이전트는 책상 옆에서 일한다.
    static func workflowRoom() {
        print("— workflow-room: 팀 층 별관 = 워크플로실 · 워크플로 로봇은 방에, 일반 하위 에이전트는 책상 옆에")
        Variety.shared.seed(31)
        let harness = SceneHarness()
        func agent(_ id: String, _ kind: SubagentInfo.Kind, workflow: String? = nil, phase: String? = nil, active: Bool = true) -> SubagentInfo {
            SubagentInfo(id: id, label: kind == .workflow ? "collect:\(id)" : "하위 에이전트 \(id)", model: "sonnet", kind: kind, workflow: workflow, phase: phase, lastActivity: Date(), active: active)
        }
        var alpha = (0..<8).map { session(Int32(9001 + $0), "알파", .working, order: Double($0)) }
        alpha[2].subagents = [agent("w1", .workflow, workflow: "wf_build", phase: "구현"), agent("w2", .workflow, workflow: "wf_build", phase: "구현"),
                              agent("w3", .workflow, workflow: "wf_build", phase: "검토"), agent("w4", .workflow, workflow: "wf_build", phase: "구현", active: false),
                              agent("s1", .subagent), agent("s2", .subagent)]
        alpha[5].subagents = [agent("w5", .workflow, workflow: "wf_docs", phase: "문서화")]
        let delta = (0..<8).map { session(Int32(9101 + $0), "델타", .working, order: Double(10 + $0)) }
        var beta = session(9201, "베타", .working, order: 30)
        beta.subagents = [agent("w9", .workflow, workflow: "wf_top", phase: "배포")]
        harness.sessions = alpha + delta + [beta]
        harness.feed()
        harness.run(4)
        let layout = harness.scene.currentLayout
        guard let alphaFloor = layout.desks[alpha[0].id]?.floor, let deltaFloor = layout.desks[delta[0].id]?.floor, let betaFloor = layout.desks[beta.id]?.floor else {
            check(false, "책상 배치 없음"); return
        }
        print("  층: 델타 \(deltaFloor) · 알파 \(alphaFloor) · 베타 \(betaFloor)(맨 위 = 상황실 \(layout.topTeamIndex))")
        let busy = harness.scene.workflowState(alphaFloor)
        let quiet = harness.scene.workflowState(deltaFloor)
        print("  알파 층 워크플로실: 로봇 \(busy?.robots ?? -1) · 보드 \(busy?.board ?? [])")
        check(busy?.robots == 4 && busy?.lit == true && busy?.idleSign == false, "알파 층 워크플로실: 일하는 워크플로 로봇 4대(끝난 1대 제외) · 불 켜짐")
        check(busy?.board == ["로봇 4대 가동", "구현 · 3", "문서화 · 1"], "보드: 가동 대수 · 워크플로별 단계와 대수")
        check(quiet?.robots == 0 && quiet?.lit == false && quiet?.idleSign == true, "델타 층 워크플로실: 비어 어둡고 '대기' 표지")
        check(harness.scene.workflowState(betaFloor) == nil && betaFloor == layout.topTeamIndex, "맨 위 층 별관은 상황실 그대로(워크플로실 없음)")
        let helpers = { (session: AgentSession) in harness.scene.worker(for: session.id)?.helperCount ?? -1 }
        check(helpers(alpha[2]) == 2 && helpers(alpha[5]) == 0, "책상 옆 로봇: 일반 하위 에이전트만(알파 3번 \(helpers(alpha[2]))대 · 6번 \(helpers(alpha[5]))대) — 워크플로 로봇을 두 번 그리지 않음")
        check(helpers(beta) == 1, "워크플로실이 없는 맨 위 층 세션의 워크플로 로봇은 책상 옆에(\(helpers(beta))대)")
        // 별관(오른쪽) 세 층: 델타 층 워크플로실(대기) · 알파 층 워크플로실(가동) · 맨 위 상황실
        let wing = CGRect(x: CGFloat(BuildingLayout.wingX0) - 70, y: CGFloat(layout.floors[deltaFloor].y) - 4, width: CGFloat(BuildingLayout.width - BuildingLayout.wingX0) + 74,
                          height: CGFloat(layout.floors[betaFloor].y + layout.floors[betaFloor].height - layout.floors[deltaFloor].y) + 8)
        shot(harness, "workflow-room-active", rect: wing)
        shot(harness, "workflow-room-building", focus: .all)
        // 워크플로가 끝나면 방은 다시 어두워지고 '대기'
        alpha[2].subagents = alpha[2].subagents.map { var copy = $0; if copy.kind == .workflow { copy.active = false }; return copy }
        alpha[5].subagents = []
        harness.sessions = alpha + delta + [beta]
        harness.run(3)
        let done = harness.scene.workflowState(alphaFloor)
        check(done?.robots == 0 && done?.lit == false && done?.idleSign == true && helpers(alpha[2]) == 2, "워크플로가 끝나면: 로봇 0 · 어두움 · '대기' · 책상 옆 일반 로봇 2대 그대로")
        shot(harness, "workflow-room-idle", rect: wing)
    }
}

extension SceneChecks {
    // MARK: 감사 — 순찰 · 정신교육 · 강당 퇴출 · 장부

    /// 감사 인물(감사관 · 비서 · 강사)이 보이는 동안 늘 어느 층 바닥선 위에 있는가(공중 부양 없음) · 엘리베이터 칸에 보이게 서 있던 최장 시간.
    @MainActor
    final class StaffWatch {
        var floating = 0.0
        var worstShaft = 0.0
        var sample = ""
        private var shaftRun: [String: Double] = [:]
        private var last: [String: TimeInterval] = [:]

        func observe(_ probe: OfficeScene.StaffProbe, _ name: String, layout: BuildingLayout, now: TimeInterval) {
            let step = now - (last[name] ?? now)
            last[name] = now
            guard probe.present, probe.alpha > 0.5 else { shaftRun[name] = 0; return }
            if !layout.floors.contains(where: { abs(CGFloat($0.floorLine) - probe.y) < 0.5 }) {
                floating += step
                if sample.isEmpty { sample = String(format: "%@ x=%.1f y=%.1f", name, probe.x, probe.y) }
            }
            let run = abs(probe.x - CGFloat(BuildingLayout.elevatorX)) <= 6 ? (shaftRun[name] ?? 0) + step : 0
            shaftRun[name] = run
            worstShaft = max(worstShaft, run)
        }

        func observeAll(_ scene: OfficeScene, now: TimeInterval) {
            let layout = scene.currentLayout
            observe(scene.auditorProbe, "감사관", layout: layout, now: now)
            observe(scene.secretaryProbe, "비서", layout: layout, now: now)
            observe(scene.instructorProbe, "강사", layout: layout, now: now)
        }

        /// particle: 주격 조사(받침 있으면 '이', 없으면 '가').
        func report(_ who: String = "감사 인물", particle: String = "이") {
            check(floating == 0, String(format: "%@ 공중 부양 %.1f초", who, floating) + (sample.isEmpty ? "" : " · \(sample)"))
            check(worstShaft <= 2, String(format: "%@%@ 엘리베이터 칸에 보이게 서 있던 최장 시간 %.1f초 ≤ 2초", who, particle, worstShaft))
        }
    }

    /// 실행 연출 손잡이 기록(장면 시험이 넘기는 가짜 실제 조치).
    final class AuditRecorder {
        var reeducate: [ProcessKey: Int] = [:]
        var evict: [ProcessKey: Int] = [:]
        var atCall: [ProcessKey: (floor: Int, x: CGFloat, alpha: CGFloat)] = [:]
        var climaxAt: TimeInterval?
        var firstEvictAt: TimeInterval?
        var finished = 0
        var finishedAt: TimeInterval?
        /// 세션이 끝나는 시각(퇴출 → SIGTERM 뒤 몇 초 만에 사라지는 것을 흉내).
        var removeAt: [ProcessKey: TimeInterval] = [:]
        var resumeAt: [ProcessKey: TimeInterval] = [:]
    }

    /// 조건이 맞을 때까지(또는 시한까지) 0.25초씩 돌린다. 맞으면 걸린 시간, 아니면 nil.
    @discardableResult
    static func runUntil(_ harness: SceneHarness, timeout: TimeInterval, probe: ((TimeInterval) -> Void)? = nil, _ condition: () -> Bool) -> TimeInterval? {
        let start = harness.elapsed
        while harness.elapsed - start < timeout {
            if condition() { return harness.elapsed - start }
            harness.run(0.25, probe: probe)
        }
        return condition() ? harness.elapsed - start : nil
    }

    /// 기록대로 세션을 끝내거나(퇴출) 일을 시작시킨다(재교육 지시를 받은 세션).
    static func applyScript(_ harness: SceneHarness, _ recorder: AuditRecorder, now: TimeInterval) {
        for (key, at) in recorder.removeAt where now >= at {
            harness.sessions.removeAll { $0.id == key }
            recorder.removeAt[key] = nil
        }
        for (key, at) in recorder.resumeAt where now >= at {
            if let index = harness.sessions.firstIndex(where: { $0.id == key }) {
                harness.sessions[index].state = .working
                harness.sessions[index].cpuPercent = 22
            }
            recorder.resumeAt[key] = nil
        }
    }

    static func inClass(_ worker: WorkerNode?, _ layout: BuildingLayout) -> Bool {
        guard let worker else { return false }
        return worker.floorIndex == layout.hallIndex && worker.position.x >= CGFloat(BuildingLayout.wingX0) && worker.position.x <= CGFloat(BuildingLayout.wingX1)
    }

    static func inHall(_ worker: WorkerNode?, _ layout: BuildingLayout) -> Bool {
        guard let worker else { return false }
        return worker.floorIndex == layout.hallIndex && worker.position.x >= CGFloat(BuildingLayout.mainX0) && worker.position.x <= CGFloat(BuildingLayout.mainX1)
    }

    static func atDesk(_ worker: WorkerNode?, _ layout: BuildingLayout, _ key: ProcessKey) -> Bool {
        guard let worker, let desk = layout.desks[key] else { return false }
        return worker.place == .desk && worker.floorIndex == desk.floor && abs(worker.position.x - CGFloat(desk.seatX)) <= 1 && worker.action(forKey: "move") == nil
    }

    static func floorRect(_ harness: SceneHarness, _ floor: Int, x: CGFloat = 0, width: CGFloat = CGFloat(BuildingLayout.width)) -> CGRect {
        let f = harness.scene.currentLayout.floors[floor]
        return CGRect(x: x, y: CGFloat(f.y) - 4, width: width, height: CGFloat(f.height) + 34)
    }

    // MARK: 순찰

    /// 판정을 기다리는 동안 감사관이 직원 있는 층을 돌며 책상 모니터를 들여다본다(비서가 따라감). 말풍선은 그 세션의 실제 값.
    /// 판정이 오면(강당 급습 · 취소) 걷는 중이든 엘리베이터 안이든 그 자리에서 멈추고 깔끔하게 이어 간다.
    static func auditTour() {
        print("— audit-tour: 판정 대기 중 순찰(층 이동 · 모니터 확인 · 실제 값 말풍선) · 엘리베이터 안에서 판정이 와도 깔끔하게")
        Variety.shared.seed(41)
        let harness = SceneHarness()
        let scene = harness.scene
        var alpha = (0..<8).map { session(Int32(10_001 + $0), "알파", .working, order: Double($0)) }
        alpha[1].pids = [10_002, 20_001, 20_002]
        alpha[1].childCount = 2
        alpha[2].cpuPercent = 2
        let beta = [session(10_101, "베타", .waiting, order: 20), session(10_102, "베타", .working, order: 21), session(10_103, "베타", .idle, order: 22)]
        harness.sessions = alpha + beta
        harness.feed()
        harness.run(3)
        let layout = scene.currentLayout
        let teamFloors = Set((alpha + beta).compactMap { layout.desks[$0.id]?.floor })
        print("  직원 있는 층: \(teamFloors.sorted())")
        let watch = StaffWatch()
        let observe: (TimeInterval) -> Void = { now in watch.observeAll(scene, now: now) }
        scene.auditorEnter()
        // 둘째 층에서 모니터를 들여다보는 순간을 찍는다
        if runUntil(harness, timeout: 70, probe: observe, { Set(scene.tourLog.map(\.floor)).count >= 2 }) != nil {
            harness.run(0.5, probe: observe)
            let probe = scene.auditorProbe
            shot(harness, "audit-tour", rect: floorRect(harness, probe.floor, x: max(0, probe.x - 130), width: 280))
        }
        harness.run(12, probe: observe)
        let visited = Set(scene.tourLog.map(\.floor))
        print("  들여다본 책상: " + scene.tourLog.map { "층\($0.floor) \"\($0.text)\"" }.joined(separator: " · "))
        check(visited.count >= 2 && visited.isSubset(of: teamFloors), "순찰: 직원 있는 층 \(visited.count)곳(\(visited.sorted())) · 책상 \(scene.tourLog.count)곳")
        let expected: [(ProcessKey, String)] = [(alpha[1].id, "CPU 18% · 하위 2개"), (alpha[2].id, "CPU 2% · 0.4GB"), (beta[0].id, "1시간째 입력 대기 · 0.4GB"), (beta[2].id, "빈자리 · 1시간째 쉼 · 0.4GB")]
        let mismatches = expected.compactMap { key, text -> String? in
            guard let seen = scene.tourLog.first(where: { $0.key == key }) else { return "\(key.pid) 안 봄" }
            return seen.text == text ? nil : "\(key.pid): \"\(seen.text)\" ≠ \"\(text)\""
        }
        check(mismatches.isEmpty, "말풍선 = 실제 값(CPU · 하위 수 · 입력 대기 시간 · 메모리 · 빈자리): " + (mismatches.isEmpty ? "4곳 일치" : mismatches.joined(separator: " / ")))
        // 판정 도착: 엘리베이터 안(사라진 채)에서 강당 급습을 부른다
        let riding = runUntil(harness, timeout: 40, probe: observe) { let p = scene.auditorProbe; return p.present && p.alpha < 0.99 }
        let stormed = AuditRecorder()
        scene.auditorStormHall { stormed.finished += 1 }
        let arrived = runUntil(harness, timeout: 25, probe: observe) { stormed.finished == 1 }
        let probe = scene.auditorProbe
        check(riding != nil && arrived != nil && probe.floor == layout.hallIndex && probe.alpha > 0.99 && abs(probe.x - CGFloat(BuildingLayout.hallDoorX + 34)) <= 1,
              "엘리베이터 안에서 판정 도착 → 강당 문 박차고 입장: " + (arrived.map { String(format: "%.1f초", $0) } ?? "25초 안에 못 감") + String(format: " · 층 %d x=%.0f", probe.floor, probe.x))
        scene.auditorLeave()
        let left = runUntil(harness, timeout: 30, probe: observe) { !scene.auditInProgress && !scene.auditorProbe.present && !scene.secretaryProbe.present }
        check(left != nil, "취소·끝: 감사관과 비서가 1층 문으로 퇴장 " + (left.map { String(format: "%.1f초", $0) } ?? "30초 안에 안 끝남"))
        // 다시 감사(앞 감사가 깨끗이 끝났는지) → 순찰 도중 엘리베이터 안에서 취소
        scene.auditorEnter()
        let toured = runUntil(harness, timeout: 30, probe: observe) { !scene.tourLog.isEmpty }
        let ridingAgain = runUntil(harness, timeout: 40, probe: observe) { let p = scene.auditorProbe; return p.present && p.alpha < 0.99 }
        scene.auditorLeave(line: "판정을 못 받았어요")
        let leftAgain = runUntil(harness, timeout: 30, probe: observe) { !scene.auditInProgress && !scene.auditorProbe.present }
        check(toured != nil && ridingAgain != nil && leftAgain != nil, "두 번째 감사도 순찰 → 엘리베이터 안에서 취소 → 퇴장: " + (leftAgain.map { String(format: "%.1f초", $0) } ?? "안 끝남"))
        watch.report()
        noSafetyNet(harness)
    }

    // MARK: 정신교육

    /// 재교육: 대상(강당 · 옥상 · 로비)을 정신교육실에 모아 강사가 훈계 → 상담 → 어르기 → 달래기, "지시 보냅니다!" 순간 실제 전송(대상마다 한 번).
    /// 그 뒤 자기 책상으로 돌아가고, 지시를 받아 일을 시작한 세션은 책상에서 일하고 나머지는 평소 흐름으로 돌아간다.
    static func auditLesson() {
        print("— audit-lesson: 정신교육실 수업(훈계·상담·어르기·달래기) → 지시 전송 순간 → 책상 복귀")
        Variety.shared.seed(42)
        let harness = SceneHarness()
        let scene = harness.scene
        let alpha = (0..<8).map { session(Int32(11_001 + $0), "알파", .working, order: Double($0)) }
        var students = [session(11_101, "베타", .longIdle, order: 20), session(11_102, "베타", .idle, order: 21), session(11_103, "감마", .longIdle, order: 22)]
        students[0].title = "로그인 버그 수정"
        students[1].title = "결제 화면 리팩터링"
        harness.sessions = alpha + students
        harness.feed()
        // 정신교육실에는 이미 정리된(복구 금고 '보관 중') 세션 5명이 책을 펴고 앉아 있다 — 실제 화면처럼 붐비는 교실에서 수업한다.
        scene.setRetired((0..<5).map { RecoveryEntry(kind: .session, status: .held, project: "보관\($0)", title: "보관 \($0)", reason: "시험") }) { _ in }
        harness.run(12)
        let layout = scene.currentLayout
        print("  시작: " + students.map { "\($0.project)(\($0.state.rawValue)) \(describe(scene.worker(for: $0.id)))" }.joined(separator: " / "))
        scene.auditorEnter()
        harness.run(8)
        let watch = StaffWatch()
        let recorder = AuditRecorder()
        var seenInClass = Set<ProcessKey>()
        var backAtDesk: [ProcessKey: TimeInterval] = [:]
        var instructorSeen = false
        let observe: (TimeInterval) -> Void = { now in
            watch.observeAll(scene, now: now)
            applyScript(harness, recorder, now: now)
            if scene.instructorProbe.present && scene.instructorProbe.alpha > 0.5 { instructorSeen = true }
            for student in students {
                let worker = scene.worker(for: student.id)
                if scene.auditHold(student.id)?.hasPrefix("student") == true, inClass(worker, layout) { seenInClass.insert(student.id) }
                if recorder.climaxAt != nil, backAtDesk[student.id] == nil, atDesk(worker, scene.currentLayout, student.id) { backAtDesk[student.id] = now }
            }
        }
        let started = harness.elapsed
        scene.auditorExecute(
            reeducate: students.map { OfficeScene.AuditCall(key: $0.id, reason: "9시간 쉼 · 0.4GB") }, evict: [], praise: [OfficeScene.AuditCall(key: alpha[3].id, reason: "CPU 18%")],
            onReeducate: { key in
                recorder.reeducate[key, default: 0] += 1
                if let worker = scene.worker(for: key) { recorder.atCall[key] = (worker.floorIndex, worker.position.x, worker.alpha) }
                if recorder.climaxAt == nil { recorder.climaxAt = harness.elapsed }
                if key == students[0].id { recorder.resumeAt[key] = harness.elapsed + 3 }   // 지시를 받고 3초 뒤 일을 시작한 세션
                return true
            },
            onEvict: { _ in false },
            onFinish: { recorder.finished += 1; recorder.finishedAt = harness.elapsed })
        // 상담 장면(강사가 첫 학생 책상 앞에서 묻고, 학생이 대답)을 찍는다
        let counselX = CGFloat(layout.classSeats[0].x + 14)
        if runUntil(harness, timeout: 70, probe: observe, { let p = scene.instructorProbe; return p.present && abs(p.x - counselX) < 1 && p.alpha > 0.99 }) != nil {
            harness.run(1.6, probe: observe)
            shot(harness, "audit-lesson", rect: floorRect(harness, layout.hallIndex, x: 380, width: 260))
        }
        runUntil(harness, timeout: 100, probe: observe) { recorder.finished > 0 && backAtDesk.count == students.count }
        harness.run(34, probe: observe)
        print("  지시 순간 위치: " + students.map { s in recorder.atCall[s.id].map { String(format: "%@ 층%d x=%.0f", s.project, $0.floor, $0.x) } ?? "\(s.project) 없음" }.joined(separator: " / "))
        print("  끝: " + students.map { "\($0.project) \(describe(scene.worker(for: $0.id)))" }.joined(separator: " / "))
        let once = students.allSatisfy { recorder.reeducate[$0.id] == 1 } && recorder.reeducate.count == students.count
        check(once, "실제 지시: 대상 \(students.count)명 각 한 번(\(recorder.reeducate.values.map(String.init).joined(separator: ",")))")
        let classed = students.filter { s in
            guard let at = recorder.atCall[s.id] else { return false }
            return at.floor == layout.hallIndex && at.x >= CGFloat(BuildingLayout.wingX0) && at.x <= CGFloat(BuildingLayout.wingX1)
        }
        check(classed.count == students.count && seenInClass.count == students.count, "수업 중 대상 \(classed.count)/\(students.count)명이 정신교육실 안(지시 순간 위치) · 교실에 앉은 적 \(seenInClass.count)명")
        check(instructorSeen && !scene.instructorProbe.present, "강사: 수업에 나왔다가 끝나고 교육실 문으로 퇴장")
        check(backAtDesk.count == students.count, "수업 뒤 자기 책상으로 복귀 \(backAtDesk.count)/\(students.count)명: " + students.map { s in backAtDesk[s.id].map { String(format: "%.0f초", $0 - (recorder.climaxAt ?? 0)) } ?? "못 감" }.joined(separator: " · "))
        let resumed = scene.worker(for: students[0].id)
        check(atDesk(resumed, scene.currentLayout, students[0].id) && resumed?.busy == false && scene.auditHold(students[0].id) == nil, "지시를 받아 일을 시작한 세션: 책상에서 평소 흐름(일함) · " + describe(resumed))
        let released = students.dropFirst().allSatisfy { scene.auditHold($0.id) == nil && scene.worker(for: $0.id)?.busy == false }
        check(released, "아직 일을 시작하지 않은 세션: 30초 뒤 평소 흐름으로 놓아줌(쉼 자리) · " + students.dropFirst().map { describe(scene.worker(for: $0.id)) }.joined(separator: " / "))
        check(recorder.finished == 1 && (recorder.finishedAt.map { $0 - started <= 90 } ?? false), "실행 연출 " + (recorder.finishedAt.map { String(format: "%.0f초", $0 - started) } ?? "안 끝남") + " ≤ 90초 · 마침 알림 \(recorder.finished)회")
        watch.report()
        noSafetyNet(harness)
    }

    // MARK: 강당 퇴출

    /// 퇴출: 강당 좌석의 대상은 일어나 단상 앞 줄로, 사무실 대상은 감사관이 끌고 내려온다. 이름을 부르는 순간 실제 정리(대상마다 한 번),
    /// 경비원이 차례로 끌고 나간다. 실제로 정리하지 않으면(드라이런 · 결정 뒤 상태 변화) 놓아준다.
    static func auditEvict() {
        print("— audit-evict: 강당 단상 앞에 모으기(사무실 대상은 끌고 내려옴) → 이름 부르는 순간 실제 정리 → 경비원이 차례로")
        Variety.shared.seed(43)
        let harness = SceneHarness()
        let scene = harness.scene
        let alpha = (0..<8).map { session(Int32(12_001 + $0), "알파", .working, order: Double($0)) }
        let hallers = [session(12_101, "베타", .longIdle, order: 20), session(12_102, "베타", .longIdle, order: 21), session(12_103, "감마", .orphan, order: 22)]
        let office = session(12_104, "델타", .waiting, order: 23)
        let keep = session(12_105, "베타", .longIdle, order: 24)
        harness.sessions = alpha + hallers + [office, keep]
        harness.feed()
        harness.run(12)
        let layout = scene.currentLayout
        let officeFloor = scene.worker(for: office.id)?.floorIndex ?? -1
        print("  시작: 강당 \(hallers.map { describe(scene.worker(for: $0.id)) }.joined(separator: " / ")) · 사무실 \(describe(scene.worker(for: office.id)))")
        scene.auditorEnter()
        harness.run(6)
        let targets = hallers + [office]
        let watch = StaffWatch()
        let recorder = AuditRecorder()
        var lineupShot = false
        var guardShot = false
        var gone: [ProcessKey: TimeInterval] = [:]
        let observe: (TimeInterval) -> Void = { now in
            watch.observeAll(scene, now: now)
            applyScript(harness, recorder, now: now)
            for target in targets where gone[target.id] == nil && recorder.evict[target.id] != nil && scene.worker(for: target.id) == nil { gone[target.id] = now }
        }
        let started = harness.elapsed
        scene.auditorExecute(
            reeducate: [], evict: targets.map { OfficeScene.AuditCall(key: $0.id, reason: "9시간 쉼 · 0.4GB") }, praise: [],
            onReeducate: { _ in false },
            onEvict: { key in
                recorder.evict[key, default: 0] += 1
                if let worker = scene.worker(for: key) { recorder.atCall[key] = (worker.floorIndex, worker.position.x, worker.alpha) }
                if recorder.firstEvictAt == nil { recorder.firstEvictAt = harness.elapsed }
                recorder.removeAt[key] = harness.elapsed + 3   // SIGTERM 뒤 3초 만에 세션이 사라진다
                return true
            },
            onFinish: { recorder.finished += 1; recorder.finishedAt = harness.elapsed })
        // 감사관이 사무실 대상을 끌고 강당으로 들어오는 장면 → 줄 선 장면(감사관 단상 · 대상 4명) → 경비원이 끌고 가는 장면을 찍는다
        var dragShot = false
        if runUntil(harness, timeout: 60, probe: observe, {
            guard let worker = scene.worker(for: office.id) else { return false }
            return worker.floorIndex == layout.hallIndex && worker.action(forKey: "move") != nil && worker.position.x > 140 && worker.alpha > 0.99
        }) != nil, let x = scene.worker(for: office.id)?.position.x {
            dragShot = true
            shot(harness, "audit-evict-drag", rect: floorRect(harness, layout.hallIndex, x: max(0, x - 150), width: 300))
        }
        let lined = runUntil(harness, timeout: 70, probe: observe) {
            targets.allSatisfy { scene.auditHold($0.id)?.hasPrefix("lineup") == true && inHall(scene.worker(for: $0.id), layout) && scene.worker(for: $0.id)?.action(forKey: "move") == nil }
                && abs(scene.auditorProbe.x - CGFloat(BuildingLayout.hallStageX - 8)) < 1
        }
        if lined != nil {
            harness.run(1.0, probe: observe)
            lineupShot = true
            shot(harness, "audit-evict-lineup", rect: floorRect(harness, layout.hallIndex, x: 150, width: 330))
        }
        // 경비원이 줄에서 한 명을 끌고 엘리베이터 쪽으로 가는 순간(경비원이 끌려가는 직원 바로 왼쪽 13px에서 앞장선다)
        func dragged() -> WorkerNode? {
            let guardProbe = scene.guardProbe
            guard guardProbe.floor == layout.hallIndex, guardProbe.alpha > 0.99 else { return nil }
            return targets.compactMap { scene.worker(for: $0.id) }.first { worker in
                worker.leaving && worker.floorIndex == layout.hallIndex && worker.position.x < 340 && worker.position.x > 60 && abs(guardProbe.x - (worker.position.x - 13)) < 4
            }
        }
        if runUntil(harness, timeout: 50, probe: observe, { dragged() != nil }) != nil, let worker = dragged() {
            guardShot = true
            shot(harness, "audit-evict-guard", rect: floorRect(harness, layout.hallIndex, x: max(0, worker.position.x - 150), width: 300))
        }
        runUntil(harness, timeout: 120, probe: observe) { gone.count == targets.count && scene.guardIdle }
        harness.run(2, probe: observe)
        print("  이름 부를 때 위치: " + targets.map { t in recorder.atCall[t.id].map { String(format: "%@ 층%d x=%.0f", t.project, $0.floor, $0.x) } ?? "\(t.project) 없음" }.joined(separator: " / "))
        check(targets.allSatisfy { recorder.evict[$0.id] == 1 } && recorder.evict.count == targets.count, "실제 정리: 대상 \(targets.count)명 각 한 번")
        let inside = targets.filter { t in
            guard let at = recorder.atCall[t.id] else { return false }
            return at.floor == layout.hallIndex && at.x >= CGFloat(BuildingLayout.mainX0) && at.x <= CGFloat(BuildingLayout.mainX1) && at.alpha > 0.99
        }
        check(inside.count == targets.count, "정리 순간 대상 \(inside.count)/\(targets.count)명이 강당 안(줄)")
        check(officeFloor != layout.hallIndex && recorder.atCall[office.id]?.floor == layout.hallIndex, "사무실(층 \(officeFloor)) 대상은 감사관이 강당으로 끌고 내려옴")
        check(dragShot && lineupShot && guardShot, "장면 확인: 사무실 대상 끌고 내려옴 \(dragShot) · 단상 앞 줄 \(lineupShot) · 경비원이 끌고 감 \(guardShot)")
        check(gone.count == targets.count && scene.guardIdle, "경비원이 차례로 끌고 나감(대상 \(gone.count)/\(targets.count)명 퇴장) · 경비원 초소 복귀 \(scene.guardIdle)")
        let stayed = scene.worker(for: keep.id)
        check(stayed != nil && stayed?.busy == false && stayed?.leaving == false, "퇴출 대상이 아닌 강당 직원은 그대로: " + describe(stayed))
        check(recorder.finished == 1 && (recorder.finishedAt.map { $0 - started <= 90 } ?? false), "실행 연출 " + (recorder.finishedAt.map { String(format: "%.0f초", $0 - started) } ?? "안 끝남") + " ≤ 90초")
        watch.report()
        noSafetyNet(harness)
        auditEvictSpared()
    }

    /// 드라이런(또는 결정 뒤 일을 시작함): 이름은 부르되 정리하지 않으니 끌려 나가지 않고 놓아준다.
    static func auditEvictSpared() {
        Variety.shared.seed(44)
        let harness = SceneHarness()
        let scene = harness.scene
        let alpha = (0..<4).map { session(Int32(12_501 + $0), "알파", .working, order: Double($0)) }
        let hallers = [session(12_601, "베타", .longIdle, order: 20), session(12_602, "베타", .longIdle, order: 21)]
        harness.sessions = alpha + hallers
        harness.feed()
        harness.run(10)
        scene.auditorEnter()
        harness.run(4)
        let recorder = AuditRecorder()
        scene.auditorExecute(reeducate: [], evict: hallers.map { OfficeScene.AuditCall(key: $0.id, reason: "드라이런") }, praise: [],
                             onReeducate: { _ in false },
                             onEvict: { key in recorder.evict[key, default: 0] += 1; return false },
                             onFinish: { recorder.finished += 1 })
        runUntil(harness, timeout: 90) { recorder.finished == 1 }
        harness.run(25)
        let seated = hallers.filter { h in
            guard let worker = scene.worker(for: h.id), case .rest(let spot) = worker.place else { return false }
            return spot.kind == .hallSeat && !worker.busy && worker.action(forKey: "move") == nil
        }
        check(hallers.allSatisfy { recorder.evict[$0.id] == 1 } && seated.count == hallers.count,
              "정리하지 않는 퇴출(드라이런): 이름은 한 번씩 부르고 끌려 나가지 않음 → 강당 좌석으로 돌아감 \(seated.count)/\(hallers.count)명")
        noSafetyNet(harness)
    }

    // MARK: 전체(보통 규모)

    /// 보통 규모(재교육 2 · 퇴출 3 · 칭찬 3): 모든 조치 한 번씩 · 실행 연출 90초 안 · 강당 층에 교실과 퇴출 줄이 함께 보이는 장면.
    static func auditFull() {
        print("— audit-full: 재교육 2 · 퇴출 3 · 칭찬 3 — 조치 한 번씩 · 90초 안")
        Variety.shared.seed(45)
        let harness = SceneHarness()
        let scene = harness.scene
        let alpha = (0..<8).map { session(Int32(13_001 + $0), "알파", .working, order: Double($0)) }
        var beta = [session(13_101, "베타", .working, order: 20), session(13_102, "베타", .idle, order: 21), session(13_103, "베타", .longIdle, order: 22)]
        beta[1].title = "검색 색인 다시 만들기"
        let gamma = [session(13_201, "감마", .longIdle, order: 30), session(13_202, "감마", .longIdle, order: 31), session(13_203, "감마", .orphan, order: 32)]
        harness.sessions = alpha + beta + gamma
        harness.feed()
        harness.run(12)
        let layout = scene.currentLayout
        scene.auditorEnter()
        harness.run(20)
        let reeducate = [beta[1], beta[2]]
        let evict = gamma
        let praise = [alpha[2], alpha[5], beta[0]]
        let watch = StaffWatch()
        let recorder = AuditRecorder()
        let observe: (TimeInterval) -> Void = { now in
            watch.observeAll(scene, now: now)
            applyScript(harness, recorder, now: now)
        }
        let started = harness.elapsed
        scene.auditorExecute(
            reeducate: reeducate.map { OfficeScene.AuditCall(key: $0.id, reason: "3시간 쉼 · 0.4GB") },
            evict: evict.map { OfficeScene.AuditCall(key: $0.id, reason: "9시간 쉼 · 0.4GB") },
            praise: praise.map { OfficeScene.AuditCall(key: $0.id, reason: "CPU 18%") },
            onReeducate: { key in recorder.reeducate[key, default: 0] += 1; if recorder.climaxAt == nil { recorder.climaxAt = harness.elapsed }; return true },
            onEvict: { key in
                recorder.evict[key, default: 0] += 1
                recorder.removeAt[key] = harness.elapsed + 3
                return true
            },
            onFinish: { recorder.finished += 1; recorder.finishedAt = harness.elapsed })
        // 강당 층 전체: 왼쪽 퇴출 줄 · 오른쪽 정신교육실 수업
        let classing = runUntil(harness, timeout: 70, probe: observe) { scene.instructorProbe.present && scene.instructorProbe.alpha > 0.99 && abs(scene.instructorProbe.x - 622) < 1
            && reeducate.allSatisfy { inClass(scene.worker(for: $0.id), layout) && scene.worker(for: $0.id)?.action(forKey: "move") == nil } }
        if classing != nil {
            harness.run(0.8, probe: observe)
            shot(harness, "audit-full-hall", rect: floorRect(harness, layout.hallIndex))
        }
        runUntil(harness, timeout: 120, probe: observe) { recorder.finished > 0 }
        runUntil(harness, timeout: 40, probe: observe) { !scene.auditInProgress }
        let duration = recorder.finishedAt.map { $0 - started }
        print(String(format: "  지시 순간 +%.0f초 · 실행 연출 끝 +%.0f초", (recorder.climaxAt ?? 0) - started, duration ?? -1))
        check(reeducate.allSatisfy { recorder.reeducate[$0.id] == 1 } && evict.allSatisfy { recorder.evict[$0.id] == 1 } && recorder.reeducate.count + recorder.evict.count == 5,
              "조치: 재교육 \(recorder.reeducate.count)건 · 퇴출 \(recorder.evict.count)건, 각 한 번")
        check(duration.map { $0 <= 90 } ?? false, "보통 규모 실행 연출 " + (duration.map { String(format: "%.0f초", $0) } ?? "안 끝남") + " ≤ 90초 · 감사관 퇴장 \(!scene.auditInProgress)")
        watch.report()
        noSafetyNet(harness)
    }

    // MARK: 끊긴 감사

    /// ① 창이 감사 도중에 열려 감사관이 없던 상태에서 판정 실행이 와도 1층 문에서 바로 시작해 끝까지 간다.
    /// ② 수업 도중 감사를 그만두면(auditorLeave): 마침 알림은 한 번, 교육생은 평소 흐름으로 놓아주고, 강사도 퇴장한다(남은 조치는 부르는 쪽 장부 몫).
    static func auditAbort() {
        print("— audit-abort: 감사관 없이 판정 실행이 옴 · 수업 도중 그만둠")
        Variety.shared.seed(47)
        let harness = SceneHarness()
        let scene = harness.scene
        let alpha = (0..<6).map { session(Int32(16_001 + $0), "알파", .working, order: Double($0)) }
        let idle = [session(16_101, "베타", .longIdle, order: 20), session(16_102, "베타", .longIdle, order: 21), session(16_103, "감마", .longIdle, order: 22)]
        harness.sessions = alpha + idle
        harness.feed()
        harness.run(10)
        let watch = StaffWatch()
        let late = AuditRecorder()
        let observe: (TimeInterval) -> Void = { now in
            watch.observeAll(scene, now: now)
            applyScript(harness, late, now: now)
        }
        // ① 감사관 없이(순찰 없이) 판정 실행
        let started = harness.elapsed
        scene.auditorExecute(reeducate: [OfficeScene.AuditCall(key: idle[0].id, reason: "3시간 쉼")], evict: [OfficeScene.AuditCall(key: idle[1].id, reason: "9시간 쉼")], praise: [OfficeScene.AuditCall(key: alpha[0].id, reason: "CPU 18%")],
                             onReeducate: { key in late.reeducate[key, default: 0] += 1; return false },
                             onEvict: { key in late.evict[key, default: 0] += 1; late.removeAt[key] = harness.elapsed + 3; return true },
                             onFinish: { late.finished += 1; late.finishedAt = harness.elapsed })
        runUntil(harness, timeout: 100, probe: observe) { late.finished > 0 }
        runUntil(harness, timeout: 30, probe: observe) { !scene.auditInProgress }
        check(late.finished == 1 && late.reeducate[idle[0].id] == 1 && late.evict[idle[1].id] == 1 && !scene.auditInProgress,
              "① 감사관 없이 판정 실행 → 문에서 바로 시작해 끝까지: 재교육 \(late.reeducate.count) · 퇴출 \(late.evict.count) · " + (late.finishedAt.map { String(format: "%.0f초", $0 - started) } ?? "안 끝남"))
        // ② 수업 도중 그만둠
        scene.auditorEnter()
        harness.run(4, probe: observe)
        let aborted = AuditRecorder()
        let students = [idle[2]]
        scene.auditorExecute(reeducate: students.map { OfficeScene.AuditCall(key: $0.id, reason: "5시간 쉼") }, evict: [], praise: [],
                             onReeducate: { key in aborted.reeducate[key, default: 0] += 1; return true },
                             onEvict: { _ in false },
                             onFinish: { aborted.finished += 1 })
        let inLesson = runUntil(harness, timeout: 70, probe: observe) {
            scene.instructorProbe.present && scene.instructorProbe.alpha > 0.99 && scene.auditHold(students[0].id)?.hasPrefix("student") == true
                && inClass(scene.worker(for: students[0].id), scene.currentLayout) && scene.worker(for: students[0].id)?.action(forKey: "move") == nil
        }
        scene.auditorLeave(line: "오늘은 여기까지")
        let released = runUntil(harness, timeout: 30, probe: observe) {
            scene.auditHold(students[0].id) == nil && scene.worker(for: students[0].id)?.busy == false && !scene.instructorProbe.present && !scene.auditInProgress
        }
        harness.run(2, probe: observe)
        check(inLesson != nil && released != nil && aborted.finished == 1 && aborted.reeducate.isEmpty,
              "② 수업 도중 그만둠 → 마침 알림 \(aborted.finished)회 · 교육생 놓아줌 · 강사 퇴장 · 연출이 부른 지시 \(aborted.reeducate.count)건(남은 조치는 장부가 처리) · " + (released.map { String(format: "%.1f초", $0) } ?? "안 끝남"))
        watch.report()
        noSafetyNet(harness)
    }

    // MARK: 장부(정확히 한 번)

    /// 실제 조치 장부: 연출이 두 번 불러도 한 번 · 창이 닫히면 남은 것을 바로 · 20초 넘게 멈추거나 시한이 넘으면 몰아서 하고 감사관 퇴장 · 마침은 한 번.
    static func auditLedger() {
        print("— audit-ledger: 판정마다 실제 조치 정확히 한 번(연출 · 감시가 겹쳐도)")
        let keys = (1...4).map { ProcessKey(pid: Int32(14_000 + $0), start: 1) }
        var sent: [ProcessKey] = [], terminated: [ProcessKey] = [], finished = 0, timeouts = 0
        func make() -> AuditLedger {
            AuditLedger(reeducate: [keys[0], keys[1]], evict: [keys[2], keys[3]], send: { sent.append($0) }, terminate: { terminated.append($0) }, finished: { finished += 1 })
        }
        // ① 연출이 같은 대상을 두 번 부름 → 한 번 · 마침 때 남은 것 처리 · 마침 두 번 → 한 번
        var ledger = make()
        ledger.reeducate(keys[0]); ledger.reeducate(keys[0]); ledger.evict(keys[2]); ledger.evict(keys[2]); ledger.reeducate(keys[3])
        ledger.finish(); ledger.finish(); ledger.evict(keys[3])
        check(sent == [keys[0], keys[1]] && terminated == [keys[2], keys[3]] && finished == 1,
              "① 중복 호출 · 대상 아닌 호출은 무시, 마침 때 남은 조치 처리: 지시 \(sent.count) · 정리 \(terminated.count) · 마침 \(finished)")
        // ② 창이 닫힘(장면 사라짐) → 바로 몰아서, 퇴장 손잡이는 부르지 않음(장면이 없다)
        sent = []; terminated = []; finished = 0
        ledger = make()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        ledger.startClock(at: t0, limit: 150)
        ledger.reeducate(keys[1])
        let goneDone = ledger.check(now: t0.addingTimeInterval(5), scene: .gone)
        check(goneDone && sent == [keys[1], keys[0]] && terminated == [keys[2], keys[3]] && finished == 1 && ledger.flushedByWatch,
              "② 창 닫힘 → 남은 조치를 연출 없이 바로(지시 \(sent.count) · 정리 \(terminated.count))")
        // ③ 멈춤 19초는 기다리고, 20초가 되면 몰아서 + 감사관 퇴장
        sent = []; terminated = []; finished = 0
        ledger = make()
        ledger.startClock(at: t0, limit: 150)
        let wait1 = ledger.check(now: t0.addingTimeInterval(10), scene: .paused)
        let wait2 = ledger.check(now: t0.addingTimeInterval(29), scene: .paused)
        let flushed = ledger.check(now: t0.addingTimeInterval(30.5), scene: .paused)
        if flushed { timeouts += 1 }
        check(!wait1 && !wait2 && flushed && sent.count == 2 && terminated.count == 2 && finished == 1, "③ 멈춤 19초는 기다림 → 20초에 몰아서 처리(지시 \(sent.count) · 정리 \(terminated.count))")
        // ④ 돌아가는 중이어도 시한(150초)이 넘으면 몰아서
        sent = []; terminated = []; finished = 0
        ledger = make()
        ledger.startClock(at: t0, limit: 150)
        ledger.evict(keys[2])
        let early = ledger.check(now: t0.addingTimeInterval(149), scene: .running)
        let late = ledger.check(now: t0.addingTimeInterval(151), scene: .running)
        let after = ledger.check(now: t0.addingTimeInterval(152), scene: .gone)
        check(!early && late && after && terminated == [keys[2], keys[3]] && sent.count == 2 && finished == 1, "④ 시한 초과 → 몰아서 한 번(끝난 뒤 감시는 아무것도 하지 않음)")
        _ = timeouts
    }

    // MARK: 스왑 내가기(메모리 최적화)

    /// 메모리 최적화로 실제로 비운 스왑만큼 짐꾼이 상자를 내간다: 3GB → 3상자, 20GB → 수레 3번, 0 → 둘러보고 "뺄 상자가 없네요".
    /// 더미는 스냅샷의 실제 값 아래로 내려가지 않고, 자동 운반과 겹쳐도 같은 상자를 두 번 빼지 않는다.
    static func porterUnload() {
        print("— porter-unload: 메모리 최적화로 비운 스왑만큼 상자 내가기(3GB · 트레이너 직후 · 늦은 호출 · 20GB 수레 · 0)")
        Variety.shared.seed(46)
        let harness = SceneHarness()
        let scene = harness.scene
        let warehouse = scene.warehouseNode
        harness.sessions = [session(15_001, "알파", .working, order: 0)]
        harness.swapGB = 9
        harness.feed()
        harness.run(4)
        let gib = UInt64(Fmt.gib)
        /// 운반을 따라가며: 가장 낮았던 상자 수 · 짐꾼이 엘리베이터에서 나타났는가 · 수레 최대 적재 · 말풍선.
        func follow(seconds: TimeInterval, until done: () -> Bool) -> (lowest: Int, fromShaft: Bool, maxCart: Int, said: [String], took: TimeInterval?) {
            var lowest = warehouse.shown[.swap] ?? 0, fromShaft = false, maxCart = 0, said: [String] = []
            let took = runUntil(harness, timeout: seconds, probe: { _ in
                lowest = min(lowest, warehouse.shown[.swap] ?? 0)
                if warehouse.porterVisible, abs(warehouse.porter.position.x - CGFloat(BuildingLayout.elevatorX)) <= 6 { fromShaft = true }
                maxCart = max(maxCart, warehouse.cartLoad)
                if let text = scene.porterSaying, said.last != text { said.append(text) }
            }, done)
            return (lowest, fromShaft, maxCart, said, took)
        }
        // ① 정리 직후 호출(스냅샷도 막 줄어듦): 9 → 6GB, 3GB 비움 → 3상자
        harness.swapGB = 6
        harness.feed()
        scene.porterUnload(freedBytes: 3 * gib, caption: "스왑 3.0GB 비움")
        let a = follow(seconds: 40) { !warehouse.busy && !warehouse.unloading && warehouse.shown[.swap] == 6 }
        check(a.took != nil && a.fromShaft && warehouse.unloadCarried == 3 && a.lowest == 6 && warehouse.shown[.swap] == warehouse.truth[.swap],
              "① 3GB 비움 → 짐꾼이 엘리베이터로 와서 3상자 내감: 9→\(warehouse.shown[.swap] ?? -1)상자(실제 \(warehouse.truth[.swap] ?? -1)) · 나른 수 \(warehouse.unloadCarried) · 가장 낮은 값 \(a.lowest) · " + (a.took.map { String(format: "%.1f초", $0) } ?? "40초 안에 못 맞춤") + " · 말 \(a.said)")
        // ② 트레이너(메모리 정리)가 다녀간 직후 스왑이 먼저 줄어도 자동 운반은 기다리고, 실측 호출이 오면 그만큼 내간다
        harness.swapGB = 12
        _ = follow(seconds: 40) { !warehouse.busy && warehouse.shown[.swap] == 12 }
        scene.trainerVisit(reclaimed: 0, text: "메모리 최적화!")
        harness.swapGB = 9
        var lowestDuringHold = 12
        harness.run(10) { _ in lowestDuringHold = min(lowestDuringHold, warehouse.shown[.swap] ?? 0) }
        scene.porterUnload(freedBytes: UInt64(3.2 * Double(gib)), caption: "스왑 3.2GB 비움")
        let b = follow(seconds: 40) { !warehouse.busy && !warehouse.unloading && warehouse.shown[.swap] == 9 }
        check(lowestDuringHold == 12 && b.took != nil && warehouse.unloadCarried == 3 && b.lowest == 9,
              "② 트레이너 직후: 실측 호출 전 10초간 상자 그대로(\(lowestDuringHold)) → 3.2GB 비움 → 3상자 내감(12→\(warehouse.shown[.swap] ?? -1)) · 나른 수 \(warehouse.unloadCarried)")
        // ③ 늦은 호출: 자동 운반이 이미 3상자를 뺀 뒤 3GB 호출 → 더 빼지 않고 둘러보며 "방금 3상자 다 뺐어요"
        harness.swapGB = 6
        _ = follow(seconds: 40) { !warehouse.busy && warehouse.shown[.swap] == 6 }
        scene.porterUnload(freedBytes: 3 * gib, caption: "스왑 3.0GB 비움")
        let c = follow(seconds: 30) { !warehouse.busy && !warehouse.unloading }
        check(c.lowest == 6 && warehouse.shown[.swap] == 6 && warehouse.unloadCarried == 3 && c.said.contains("방금 3상자 다 뺐어요"),
              "③ 자동 운반이 먼저 뺀 뒤 늦은 호출: 두 번 빼지 않음(가장 낮은 값 \(c.lowest), 끝 \(warehouse.shown[.swap] ?? -1)) · 말 \(c.said)")
        // ④ 많이 비움(30 → 10GB, 20GB): 수레로 8 · 8 · 4상자, 더미는 실제 값까지만
        harness.swapGB = 30
        harness.run(1)
        warehouse.snapToTruth()
        harness.run(3)
        harness.swapGB = 10
        harness.feed()
        scene.porterUnload(freedBytes: 20 * gib, caption: "스왑 20.0GB 비움")
        var cartShot = false
        let d = follow(seconds: 60) {
            if !cartShot, warehouse.cartLoad >= 6 {
                cartShot = true
                shot(harness, "porter-unload-cart", rect: MachineLayout.rect(.swap, floor: harness.scene.currentLayout.floors[0]).insetBy(dx: -150, dy: -10))
            }
            return !warehouse.busy && !warehouse.unloading && warehouse.shown[.swap] == 10
        }
        check(d.took != nil && d.maxCart == WarehouseNode.cartCapacity && warehouse.unloadCarried == 20 && d.lowest == 10 && warehouse.shown[.swap] == warehouse.truth[.swap],
              "④ 20GB 비움 → 수레(최대 \(d.maxCart)상자)로 여러 번: 30→\(warehouse.shown[.swap] ?? -1)상자 · 나른 수 \(warehouse.unloadCarried) · " + (d.took.map { String(format: "%.1f초", $0) } ?? "60초 안에 못 맞춤") + " · 말 \(d.said)")
        shot(harness, "porter-unload-after", rect: MachineLayout.rect(.swap, floor: harness.scene.currentLayout.floors[0]).insetBy(dx: -150, dy: -10))
        // ⑤ 줄어든 게 없음(0): 둘러보고 "스왑은 쓰던 앱이 끝나야 줄어요", 상자 그대로
        let before = warehouse.shown[.swap] ?? -1
        scene.porterUnload(freedBytes: 0, caption: "스왑 변화 없음")
        let e = follow(seconds: 20) { !warehouse.busy && !warehouse.unloading }
        check(e.fromShaft && warehouse.shown[.swap] == before && e.said.contains(where: { Lines.swapOwnerEnds.contains($0) }), "⑤ 0 → 짐꾼이 둘러보고 \(e.said) · 상자 \(before)→\(warehouse.shown[.swap] ?? -1)")
        // ⑥ 자동 운반(스스로 늘고 주는 스왑)은 그대로: 10 → 13 → 11
        harness.swapGB = 13
        let up = follow(seconds: 40) { !warehouse.busy && warehouse.shown[.swap] == 13 }
        harness.swapGB = 11
        let down = follow(seconds: 40) { !warehouse.busy && warehouse.shown[.swap] == 11 }
        check(up.took != nil && down.took != nil, "⑥ 자동 운반은 그대로: 10→13→11상자")
        check(harness.scene.workerKeys.count == 1, "짐꾼은 직원(에이전트)이 아님: 직원 \(harness.scene.workerKeys.count)명")
    }
}

/// 장면 하나 + 가짜 시계 + SKRenderer. run()이 1/60초씩 시간을 돌리고 feedInterval마다 스냅샷을 넣는다.
@MainActor
final class SceneHarness {
    let scene: OfficeScene
    private let device: MTLDevice
    private let renderer: SKRenderer
    private var time: TimeInterval = 50_000
    private(set) var elapsed: TimeInterval = 0
    private var sinceFeed: TimeInterval = 0
    private var previous: [ProcessKey: AgentSession]?
    var clock = Date()
    var feedInterval: TimeInterval = 2
    var sessions: [AgentSession] = []
    var swapGB: Double = 2
    var apps: [AppGroup] = []
    var diskUsed: Double = 0.5
    /// true면 장면이 멈춘 것처럼(창 닫힘·최소화) 프레임을 돌리지 않고 스냅샷만 넣는다.
    var paused = false
    /// 가짜 시계를 프레임 없이 앞당긴 양(초). 장면 시계(clock)만 건너뛰고 SpriteKit 시간은 그대로다.
    private var clockOffset: TimeInterval = 0

    /// 장면 시각(SceneClock — 시간대 · 계절)의 기본값: 가을 낮 13시. 풀 조명 · 김 · DJ 파티가 없는 때라, 실제 시각과 무관하게 매번 같은 결과가 나온다.
    nonisolated static let neutralTime = sceneTime("2026-10-15T13:00")

    /// 현지 시각 글자("2027-01-15T22:00") → 날짜.
    nonisolated static func sceneTime(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.date(from: text) ?? Date()
    }

    /// sceneTime: 장면 시각의 시작(이 하네스 시계와 함께 흐른다). 겨울 밤 · 저녁 같은 때를 고르는 시험만 준다.
    init(size viewSize: CGSize = CGSize(width: 1400, height: 900), sceneTime startTime: Date = SceneHarness.neutralTime) {
        scene = OfficeScene(size: viewSize)
        device = MTLCreateSystemDefaultDevice()!
        renderer = SKRenderer(device: device)
        renderer.ignoresSiblingOrder = true
        renderer.scene = scene
        let base = clock
        let start = time
        scene.clock = { [unowned self] in base.addingTimeInterval(self.time - start + self.clockOffset) }
        // 장면 시각: 고른 시각에서 이 하네스 시계와 함께 흐른다(다음 하네스가 바꿔 걸 때까지 · 하네스가 사라졌으면 시작 시각 그대로).
        SceneClock.checkClock = { [weak self] in startTime.addingTimeInterval(self.map { $0.time - start + $0.clockOffset } ?? 0) }
        let size = scene.size
        scene.didMove(to: SKView(frame: NSRect(origin: .zero, size: size)))
        // 화면에 붙이지 않았으므로 .resizeFill이 크기를 0으로 만든다 → 원래 크기로 되돌리고 카메라를 다시 맞춘다.
        scene.scaleMode = .fill
        scene.size = size
        renderer.update(atTime: time)
    }

    func feed(events extra: [OfficeEvent] = []) {
        var events = extra
        let current = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        if let previous {
            for session in sessions where previous[session.id] == nil {
                events.append(OfficeEvent(time: clock, kind: .arrived(session.id), text: "출근", sessionSnapshot: session))
            }
            for (key, old) in previous where current[key] == nil {
                events.append(OfficeEvent(time: clock, kind: .departed(key, .left), text: "퇴근", sessionSnapshot: old))
            }
        }
        previous = current
        scene.update(snapshot: snapshot(), events: events)
        sinceFeed = 0
    }

    func snapshot() -> OfficeSnapshot {
        let gib = 1_073_741_824.0
        var system = SystemSnapshot()
        system.time = clock
        system.memory.physical = UInt64(32 * gib)
        system.memory.internalPages = UInt64(14 * gib)
        system.memory.wired = UInt64(3 * gib)
        system.memory.compressed = UInt64(2 * gib)
        system.swap = SwapStats(total: UInt64(24 * gib), used: UInt64(swapGB * gib), available: UInt64(max(0, 24 - swapGB) * gib))
        system.disk.total = UInt64(1000 * gib)
        system.disk.available = UInt64((1 - diskUsed) * 1000 * gib)
        system.cpuPercent = 14
        system.coreCount = 10
        system.coreLoads = Array(repeating: 14, count: 10)
        return OfficeSnapshot(time: clock, system: system, sessions: sessions, apps: apps, processCount: 480, unaccountedMemory: 0, standbyClaudeSpares: 0)
    }

    /// 가짜 시계만 seconds만큼 건너뛴다(20분 같은 긴 시간 — 프레임을 돌리지 않아 걷던 연출은 그대로). 스냅샷 시각도 같이 간다.
    func advanceClock(_ seconds: TimeInterval) {
        clockOffset += seconds
        clock = clock.addingTimeInterval(seconds)
    }

    /// seconds 동안 시간을 돌린다. probe는 0.25초마다(경과 시간).
    func run(_ seconds: TimeInterval, probe: ((TimeInterval) -> Void)? = nil) {
        let step = 1.0 / 60
        var untilProbe = 0.0
        for _ in 0..<Int((seconds / step).rounded()) {
            time += step
            elapsed += step
            clock = clock.addingTimeInterval(step)
            sinceFeed += step
            if sinceFeed >= feedInterval - 1e-9 { feed() }
            if !paused { renderer.update(atTime: time) }
            untilProbe -= step
            if untilProbe <= 0 { probe?(elapsed); untilProbe = 0.25 }
        }
    }

    /// seconds 동안 돌리며 SKRenderer.update(액션·장면 갱신) 한 프레임의 시간(초): 평균 · 중앙값. 그리기(GPU)는 빼고 잰다.
    /// 평균에는 처음 한 번만 드는 비용(텍스처·말풍선 글자 만들기)이 섞이므로, 꾸준한 비용은 중앙값으로 본다.
    func measureUpdateCost(seconds: TimeInterval) -> (mean: Double, median: Double) {
        let step = 1.0 / 60
        var samples: [Double] = []
        for _ in 0..<Int((seconds / step).rounded()) {
            time += step
            elapsed += step
            clock = clock.addingTimeInterval(step)
            sinceFeed += step
            if sinceFeed >= feedInterval - 1e-9 { feed() }
            let start = DispatchTime.now().uptimeNanoseconds
            renderer.update(atTime: time)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        guard !samples.isEmpty else { return (0, 0) }
        return (samples.reduce(0, +) / Double(samples.count), samples.sorted()[samples.count / 2])
    }

    /// 지금 장면을 2배(기기 픽셀)로 그려 PNG로 남긴다.
    func screenshot(_ url: URL) {
        let scale: CGFloat = 2
        let width = Int(scene.size.width * scale), height = Int(scene.size.height * scale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: width, height: height), commandBuffer: buffer, renderPassDescriptor: pass)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        SnapshotTool.write(image, to: url)
    }
}
