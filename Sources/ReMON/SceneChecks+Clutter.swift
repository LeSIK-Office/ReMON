import AppKit
import ReMONCore
import SpriteKit

// 방 안 짐(Clutter.swift) — 10-25 대표 요청 '워크트리 · 브랜치가 많을수록 책상 위 서류 → 짐 상자 → 벽에 쌓이고, 프로젝트 청소로 치운다'.
// 단계 0~5: 갈수록 짐이 많고(같은 단계 안에서도 무게가 늘면 더) · 앞 통로(바닥선 위 2px) · 의자 자리 · 책상을 비우고 · 사람보다 뒤 ·
// 창은 5단계만 가리고 · 뜬 것 없음 · 치울 몫은 노란 띠 그림 · 명판 글자 = 장부 숫자. 청소 특공대는 치울 몫만 정확히 치우고 남은 짐은 제자리.
// 서류 장부는 하나(setPapers = RoomClutter.papers) · 넘친 서류는 상자로 · 예전 setClutter(개수)는 새 API 뒤에는 무시 · 방 없는 프로젝트는 기계실 한 줄.

extension SceneChecks {
    /// 단계별 대표 짐(치울 수 있음 절반쯤). 5단계는 쿡썹처럼 워크트리 · 브랜치 스무 개 남짓 + 서류.
    static let clutterSamples: [RoomClutter] = [
        RoomClutter(),
        RoomClutter(branches: 2, cleanableBranches: 1),
        RoomClutter(worktrees: 1, branches: 2, cleanableBranches: 1, bytes: 300 << 20),
        RoomClutter(worktrees: 2, branches: 5, cleanableWorktrees: 1, cleanableBranches: 2, bytes: UInt64(1.2 * Fmt.gib)),
        RoomClutter(worktrees: 5, branches: 8, cleanableWorktrees: 2, cleanableBranches: 4, bytes: UInt64(4.8 * Fmt.gib)),
        RoomClutter(worktrees: 10, branches: 12, cleanableWorktrees: 4, cleanableBranches: 6, bytes: UInt64(9.6 * Fmt.gib), papers: 6),
    ]

    /// 그 층의 의자 자리(앉은 직원 16px + 의자) · 책상(바닥 짐이 들어가면 안 되는 곳).
    static func clutterObstacles(_ scene: OfficeScene, floor: Int) -> (chairs: [CGRect], desks: [CGRect]) {
        let layout = scene.currentLayout
        let line = scene.line(floor)
        let xs = (Array(layout.desks.values) + layout.spareDesks).filter { $0.floor == floor }.map { CGFloat($0.deskX) }
        return (xs.map { CGRect(x: $0 - 2, y: line, width: 16, height: 24) }, xs.map { CGRect(x: $0 + 10, y: line, width: 24, height: 11) })
    }

    /// 짐 하나하나: 앞 통로 · 의자 자리 · 책상(바닥 짐) · 사람보다 뒤(z) · 창(4단계까지) · 배치 자리 · 치울 몫 그림 ·
    /// 받침(바닥 · 책상 위 · 같은 칸 아래 상자 — 기운 더미는 돌리기 전 모양으로 · 표지는 탑 앞면이나 바닥).
    static func clutterProblems(_ scene: OfficeScene, project: String, level: Int) -> [String] {
        guard let index = scene.clutterRoomIndex(project) else { return ["방 없음"] }
        let site = scene.clutterSite(index)
        let probes = scene.clutterProbes(project)
        let (chairs, desks) = clutterObstacles(scene, floor: scene.currentLayout.rooms[index].floor)
        let line = site.line
        var problems: [String] = []
        func note(_ text: String) { if problems.count < 6 { problems.append(text) } }
        for p in probes {
            let onDesk = p.kind == .deskSheet || p.kind == .deskStack || p.kind == .binders
            if p.bounds.minY < line + 2 - 0.01 { note(String(format: "%@ 통로(y %.1f)", p.id, p.bounds.minY - line)) }
            if chairs.contains(where: { $0.intersects(p.bounds) }) { note("\(p.id) 의자 자리") }
            if !onDesk, desks.contains(where: { $0.intersects(p.bounds) }) { note("\(p.id) 책상") }
            if !(p.z > 2 && p.z < 5) { note("\(p.id) z \(p.z)") }
            if level <= 4, site.windows.contains(where: { $0.intersects(p.bounds) }) { note("\(p.id) 창") }
            if !p.placed { note("\(p.id) 자리 어긋남") }
            if p.kind != .sign, p.cleanLook != p.cleanable { note("\(p.id) 그림(치울 수 있음 \(p.cleanable) · 그림 \(p.cleanLook))") }
            let supported: Bool
            let withinDesk = desks.contains { $0.minX <= p.frame.minX + 0.01 && p.frame.maxX <= $0.maxX + 0.01 }
            switch p.kind {
            case .deskSheet:
                // 위 두 줄이 책상 위(상판 윗면 = 바닥선 + 11)에 눕고, 나머지는 상판 앞면(3px)으로만 늘어진다.
                supported = withinDesk && abs(p.frame.maxY - (line + 13)) < 0.01 && p.frame.minY >= line + 8 - 0.01
            case .deskStack:
                supported = withinDesk && abs(p.frame.minY - (line + 11)) < 0.01
            case .binders:
                supported = withinDesk && probes.contains { $0.kind == .deskStack && abs($0.frame.minX - p.frame.minX) < 0.01 && abs($0.frame.maxY - p.frame.minY) < 0.01 }
            case .box, .spill:
                let floorRow = [line + ClutterPlan.frontRow, line + ClutterPlan.backRow].contains { abs($0 - p.frame.minY) < 0.01 }
                let onBox = probes.contains { other in
                    other.kind == .box && other.id != p.id && other.column == p.column && !other.front && abs(other.frame.maxY - p.frame.minY) < 0.01 &&
                        min(other.frame.maxX, p.frame.maxX) - max(other.frame.minX, p.frame.minX) >= p.frame.width / 2
                }
                supported = floorRow || onBox
            case .sign:
                supported = abs(p.frame.minY - (line + ClutterPlan.frontRow)) < 0.01 || probes.contains { $0.kind == .box && !$0.front && $0.frame.intersects(p.frame) && $0.frame.minY <= p.frame.minY }
            }
            if !supported { note(String(format: "%@ 뜸(y %.1f)", p.id, p.frame.minY - line)) }
        }
        return problems
    }

    /// 창 가린 수(그 방 창 중 짐과 겹친 것).
    static func clutterHiddenWindows(_ scene: OfficeScene, project: String) -> Int {
        guard let index = scene.clutterRoomIndex(project) else { return 0 }
        let probes = scene.clutterProbes(project)
        return scene.clutterSite(index).windows.filter { window in probes.contains { window.intersects($0.bounds) } }.count
    }

    // MARK: 단계 0~5

    static func clutterLevels() {
        print("— clutter-levels: 짐 단계 0~5 — 갈수록 많아지고 · 통로 · 의자 자리 · 책상을 비우고 · 창은 5단계만 · 뜬 것 없음 · 치울 몫 노란 띠 · 명판 = 장부")
        Variety.shared.seed(91)
        let harness = SceneHarness()
        let scene = harness.scene
        let alpha = (0..<4).map { session(Int32(31_001 + $0), "알파", .working, order: Double($0)) }
        let beta = (0..<2).map { session(Int32(31_101 + $0), "베타", .working, order: Double(10 + $0)) }
        harness.sessions = alpha + beta
        harness.feed()
        harness.run(3)
        guard let index = scene.clutterRoomIndex("알파") else { check(false, "알파 방 없음"); return }
        let room = scene.currentLayout.rooms[index]
        let site = scene.clutterSite(index)
        print("  알파 방: 책상 \(site.deskXs.count)개 · 창 \(site.windows.count)개 · 바닥선 \(Int(site.line))")
        var counts: [Int] = []
        for (level, sample) in clutterSamples.enumerated() {
            scene.focus(.room("알파"), animated: false)
            scene.setClutter(["알파": sample])
            harness.run(0.8)
            _ = runUntil(harness, timeout: 3) { scene.papersSettled("알파") }   // 서류 낱장이 팔랑이며 다 내려앉을 때까지
            let probes = scene.clutterProbes("알파")
            counts.append(probes.count)
            let problems = clutterProblems(scene, project: "알파", level: sample.level)
            let boxes = probes.filter { $0.kind == .box }.count, cleanable = probes.filter(\.cleanable).count
            let hidden = clutterHiddenWindows(scene, project: "알파")
            check(sample.level == level && problems.isEmpty,
                  "단계 \(level)(무게 \(sample.load)): 짐 \(probes.count)개(상자 \(boxes) · 치울 수 있음 \(cleanable)) · 통로 · 의자 · 책상 · 받침 · 그림 이상 없음" + (problems.isEmpty ? "" : " · " + problems.joined(separator: " / ")))
            let keepUnits = (sample.worktrees - sample.cleanableWorktrees) * 3 + sample.branches - sample.cleanableBranches
            check((cleanable > 0) == (keepUnits < sample.load - sample.papers) && (probes.count - cleanable > 0) == (keepUnits > 0 || sample.level >= 5),
                  "단계 \(level): 치울 수 있음 \(cleanable)개 · 남길 짐 \(probes.count - cleanable)개(장부: 치울 무게 \(sample.load - sample.papers - keepUnits) · 남길 무게 \(keepUnits))")
            check(level == 5 ? hidden >= 1 : hidden == 0, "단계 \(level): 창 가림 \(hidden)개(5단계만 가린다)")
            if level > 0 {
                let plate = scene.clutterLabel("plate", "알파")
                let expected = "워크트리 \(sample.worktrees) · 브랜치 \(sample.branches) · 서류 \(sample.papers)" + (sample.bytes > 0 ? " · \(Fmt.size(sample.bytes))" : "")
                let work = scene.clutterLabel("work", "알파"), clean = scene.clutterLabel("clean", "알파")
                check(plate?.text == expected && plate?.hidden == false && (work?.hidden == false) == (probes.count - cleanable > 0) && (clean?.hidden == false) == (cleanable > 0),
                      "단계 \(level) 가까이: 명판 '\(plate?.text ?? "없음")' · '작업 중' \(work?.hidden == false ? "보임" : "없음") · '치울 수 있음' \(clean?.hidden == false ? "보임" : "없음")")
            }
            if [1, 3, 5].contains(level) { shot(harness, "clutter-level\(level)", rect: scene.roomRect(room).insetBy(dx: -24, dy: -6)) }
        }
        check(zip(counts, counts.dropFirst()).allSatisfy { $0 < $1 } && counts.first == 0, "단계 0~5 짐 수가 늘기만: \(counts)")

        // 같은 단계 안에서도 무게가 늘면 더(칸 한도까지).
        var within: [String] = []
        var grows = true
        for (low, high) in [(7, 14), (15, 30), (31, 60)] {
            scene.setClutter(["알파": RoomClutter(branches: low)])
            harness.run(0.4)
            let a = scene.clutterProbes("알파").count
            scene.setClutter(["알파": RoomClutter(branches: high)])
            harness.run(0.4)
            let b = scene.clutterProbes("알파").count
            within.append("무게 \(low)→\(high): \(a)→\(b)")
            if b <= a || RoomClutter(branches: low).level != RoomClutter(branches: high).level { grows = false }
        }
        check(grows, "같은 단계 안에서도 무게가 늘면 짐이 더: " + within.joined(separator: " · "))

        // 5단계: '복잡' 표지 · 천장 가까이 탑 · 가끔 먼지 · 멀리서는 글자 숨김.
        let busy = clutterSamples[5]
        scene.setClutter(["알파": busy])
        harness.run(0.4)
        let probes = scene.clutterProbes("알파")
        let tallest = probes.filter { $0.kind == .box }.map(\.bounds.maxY).max() ?? 0
        let dustBefore = scene.clutterStats.dust
        harness.run(12)
        let dust = scene.clutterStats.dust - dustBefore
        let sign = scene.clutterLabel("sign", "알파")
        check(probes.contains { $0.kind == .sign } && sign?.text == "복잡" && sign?.hidden == false && tallest >= site.line + 50 && dust >= 1,
              String(format: "5단계: '복잡' 표지 · 탑 꼭대기 바닥선 위 %.0fpx(천장 %.0f) · 12초 동안 먼지 %d번", tallest - site.line, site.top - site.line, dust))
        scene.focus(.all, animated: false)
        harness.run(0.2)
        check(scene.clutterLabel("plate", "알파")?.hidden == true && scene.clutterLabel("sign", "알파")?.hidden == true, "멀리서(전체 보기)는 명판 · '복잡' 글자 숨김")
        // 직원은 짐 앞(z)에서 그대로 앉아 일한다.
        let seated = alpha.filter { atDesk(scene.worker(for: $0.id), scene.currentLayout, $0.id) && (scene.worker(for: $0.id)?.zPosition ?? 0) > (probes.map(\.z).max() ?? 0) }
        check(seated.count == alpha.count, "5단계 방에서도 직원 \(seated.count)/\(alpha.count)명이 책상에서 짐보다 앞(z)에 앉아 있음")
        noSafetyNet(harness)
    }

    // MARK: 방 모양 전부 — 창 8가지 · 책상 1~8개

    static func clutterRooms() {
        print("— clutter-rooms: 창 모양 8가지 · 책상 2~8개 방 모두 — 4단계는 창을 가리지 않고 5단계는 가림 · 통로 · 의자 · 책상 · 받침")
        Variety.shared.seed(94)
        // 창 모양이 다 나오게 방 이름을 고른다(방 테마는 이름 해시라 이름이 곧 창 모양이다).
        var names: [String] = []
        var styles = Set<RoomTheme.Window>()
        for i in 1...400 where styles.count < RoomTheme.Window.allCases.count {
            let name = "방\(i)"
            if styles.insert(RoomTheme.of(name).window).inserted { names.append(name) }
        }
        let crews = [1, 2, 3, 7, 1, 2, 4, 3]   // 책상 = 직원 + 예비 1(최대 8)
        let harness = SceneHarness()
        let scene = harness.scene
        var crew: [AgentSession] = []
        for (k, name) in names.enumerated() {
            for j in 0..<crews[k % crews.count] {
                let index = k * 20 + j
                crew.append(session(Int32(34_000 + index), name, .working, order: Double(index)))
            }
        }
        harness.sessions = crew
        harness.feed()
        harness.run(3)
        let desks = names.compactMap { scene.clutterRoomIndex($0).map { scene.clutterSite($0).deskXs.count } }
        for sample in [clutterSamples[4], clutterSamples[5]] {
            scene.setClutter(Dictionary(uniqueKeysWithValues: names.map { ($0, sample) }))
            harness.run(0.8)
            _ = runUntil(harness, timeout: 3) { names.allSatisfy { scene.papersSettled($0) } }
            var bad: [String] = []
            var hiddenRooms = 0, props = 0
            for name in names {
                let problems = clutterProblems(scene, project: name, level: sample.level)
                if !problems.isEmpty { bad.append("\(name)(\(RoomTheme.of(name).window)) " + problems.joined(separator: " / ")) }
                if clutterHiddenWindows(scene, project: name) > 0 { hiddenRooms += 1 }
                props += scene.clutterProbes(name).count
            }
            check(bad.isEmpty && hiddenRooms == (sample.level == 5 ? names.count : 0),
                  "\(sample.level)단계: 방 \(names.count)개(창 \(styles.count)가지 · 책상 \(desks)) · 짐 \(props)개 · 통로 · 의자 · 책상 · 받침 이상 없음 · 창 가린 방 \(hiddenRooms)/\(names.count)" +
                    (bad.isEmpty ? "" : " · " + bad.prefix(3).joined(separator: " | ")))
            if sample.level == 5, let first = names.first, let index = scene.clutterRoomIndex(first) {
                shot(harness, "clutter-rooms", focus: .floor(scene.currentLayout.rooms[index].floor))
            }
        }
        noSafetyNet(harness)
    }

    // MARK: 청소 특공대 — 치울 몫만

    static func clutterJanitor() {
        print("— clutter-janitor: 5단계 방 청소 — 치울 몫만 정확히(상자는 품에 받아 엘리베이터로 · 더미는 쓸어 담음) · '정리 중' 테이프 · 물청소 · 남은 짐은 제자리 · 정리 뒤 장부로 다시 그려도 그대로")
        Variety.shared.seed(92)
        let harness = SceneHarness()
        let scene = harness.scene
        let alpha = (0..<4).map { session(Int32(32_001 + $0), "알파", .working, order: Double($0)) }
        harness.sessions = alpha + [session(32_101, "베타", .working, order: 10)]
        harness.feed()
        harness.run(3)
        guard let index = scene.clutterRoomIndex("알파") else { check(false, "알파 방 없음"); return }
        let room = scene.currentLayout.rooms[index]
        let before = clutterSamples[5]
        // 앱 순서 그대로: 서류 장부(setPapers) → 짐 장부(setClutter, 같은 서류 수).
        scene.setPapers(["알파": before.papers])
        scene.setClutter(["알파": before])
        harness.run(1)
        let probes = scene.clutterProbes("알파")
        let share = probes.filter(\.cleanable)
        let left = ClutterPlan.remaining(before)
        let kept = probes.filter { !$0.cleanable && ($0.kind != .sign || left.level >= 5) }
        let shareBoxes = share.filter { $0.kind == .box }.count
        let signTaken = left.level < 5 && probes.contains { $0.kind == .sign }
        print("  청소 전: 짐 \(probes.count)개 · 치울 몫 \(share.count)개(상자 \(shareBoxes)) · 남길 짐 \(kept.count)개 · 서류 \(scene.paperCount("알파"))장")
        let watch = StaffWatch()
        var sawTape = false, tapeText = "", maxHeld = 0, cleaningShot = false
        let stats0 = scene.clutterStats
        scene.janitorVisit(project: "알파", items: 10, reclaimed: UInt64(3.1 * Fmt.gib))
        let gone = runUntil(harness, timeout: 50, probe: { now in
            for (name, probe) in scene.janitorProbes { watch.observe(probe, name, layout: scene.currentLayout, now: now) }
            if scene.clutterTapeVisible { sawTape = true; tapeText = scene.clutterTapeText ?? "" }
            maxHeld = max(maxHeld, scene.clutterStats.held)
            if !cleaningShot, scene.clutterStats.held >= 3 {
                cleaningShot = true
                shot(harness, "clutter-cleaning", rect: scene.roomRect(room).insetBy(dx: -24, dy: -6))
            }
        }) { scene.janitorsGone }
        let after = scene.clutterProbes("알파")
        let stats = scene.clutterStats
        let moved = after.filter { probe in kept.first { $0.id == probe.id }.map { $0.bounds != probe.bounds } ?? true }
        check(gone != nil && after.count == kept.count && after.allSatisfy { !$0.cleanable } && moved.isEmpty,
              "청소 뒤 짐 \(probes.count) → \(after.count)개(치울 몫 \(share.count)개만 · 남길 짐 \(kept.count)개는 제자리, 움직인 칸 \(moved.count))")
        check(stats.carried - stats0.carried == shareBoxes && stats.swept - stats0.swept == share.count - shareBoxes + (signTaken ? 1 : 0) && maxHeld >= min(3, shareBoxes) && stats.held == 0,
              "상자 \(stats.carried - stats0.carried)/\(shareBoxes)개를 품에 받아(가장 많이 쌓은 것 \(maxHeld)) 엘리베이터로 · 더미 · 바인더 · 낱장 \(stats.swept - stats0.swept)개 쓸어 담음" + (signTaken ? "('복잡' 표지 포함)" : ""))
        check(sawTape && tapeText == "정리 중" && !scene.clutterTapeVisible && scene.clutterCleaning == nil, "청소하는 동안 '\(tapeText)' 테이프 · 끝나면 걷음")
        check(scene.paperCount("알파") == 0 && scene.mopLog.contains("반짝"), "서류 \(scene.paperCount("알파"))장 · 물청소(젖은 자국 \(scene.mopStrokes)개 · 반짝)")
        let problems = clutterProblems(scene, project: "알파", level: left.level)
        check(problems.isEmpty, "청소 뒤 남은 짐: 뜬 것 · 통로 · 창(\(left.level)단계) 이상 없음" + (problems.isEmpty ? "" : " · " + problems.joined(separator: " / ")))
        watch.report("청소 특공대", particle: "가")

        // 앱이 정리 뒤 다시 계산한 장부: 치울 몫 0 → 같은 칸이 그대로(서류 더미 높이만 무게에 맞춰 바뀔 수 있음 — 자리 · 받침은 그대로).
        scene.setPapers([:] as [String: Int])
        scene.setClutter(["알파": left])
        harness.run(1)
        let redrawn = scene.clutterProbes("알파")
        // 바닥 짐(상자 · 쏟아진 서류)은 자리 · 크기가 그대로, 책상 짐은 가로 자리가 그대로(서류 더미 높이는 무게를 따라 줄고 그 위 바인더도 같이 내려앉는다).
        let jumped = redrawn.filter { probe in
            kept.first { $0.id == probe.id }.map { old in
                probe.kind == .box || probe.kind == .spill ? old.bounds != probe.bounds : old.frame.minX != probe.frame.minX || old.frame.width != probe.frame.width
            } ?? true
        }
        check(redrawn.count == kept.count && jumped.isEmpty && redrawn.allSatisfy { !$0.cleanable } && clutterProblems(scene, project: "알파", level: left.level).isEmpty,
              "정리 뒤 장부(워크트리 \(left.worktrees) · 브랜치 \(left.branches))로 다시 그림: \(redrawn.count)개 · 튄 칸 \(jumped.count)개")
        shot(harness, "clutter-cleaned", rect: scene.roomRect(room).insetBy(dx: -24, dy: -6))
        noSafetyNet(harness)
    }

    // MARK: 장부 하나 · 예전 API · 방 없는 짐

    static func clutterLedger() {
        print("— clutter-ledger: 서류 장부 하나(setPapers = RoomClutter.papers) · 넘친 서류는 상자로 · 예전 setClutter(개수)는 새 API 뒤에 무시 · 방 없는 프로젝트는 기계실 한 줄")
        Variety.shared.seed(93)
        let harness = SceneHarness()
        let scene = harness.scene
        let alpha = (0..<4).map { session(Int32(33_001 + $0), "알파", .working, order: Double($0)) }
        harness.sessions = alpha
        harness.feed()
        harness.run(3)
        scene.focus(.room("알파"), animated: false)
        harness.run(0.2)
        func plate() -> String { scene.clutterLabel("plate", "알파")?.text ?? "없음" }

        // ① 예전 API(새 API 전): 개수 = 치울 수 있는 브랜치.
        scene.setClutter(["알파": 3])
        harness.run(0.6)
        let legacy = scene.clutterProbes("알파")
        check(!legacy.isEmpty && legacy.allSatisfy(\.cleanable) && plate() == "워크트리 0 · 브랜치 3 · 서류 0", "① 예전 setClutter(알파 3): 짐 \(legacy.count)개 모두 치울 수 있음 · 명판 '\(plate())'")
        // ② 서류 장부: setPapers가 같은 짐 장부의 서류 수를 바꾼다(낱장 자리 안이면 상자는 그대로).
        scene.setPapers(["알파": 4])
        harness.run(1.2)
        check(scene.paperCount("알파") == 4 && plate() == "워크트리 0 · 브랜치 3 · 서류 4" && scene.clutterProbes("알파").count == legacy.count,
              "② setPapers(4): 낱장 \(scene.paperCount("알파"))장 · 명판 '\(plate())' · 짐 \(scene.clutterProbes("알파").count)개 그대로")
        // ③ 새 API: RoomClutter.papers가 같은 낱장을 움직인다.
        let rich = RoomClutter(worktrees: 1, branches: 2, bytes: 512 << 20, papers: 7)
        scene.setClutter(["알파": rich])
        harness.run(1.5)
        check(scene.paperCount("알파") == 7 && scene.papersSettled("알파") && plate() == "워크트리 1 · 브랜치 2 · 서류 7 · 512MB", "③ setClutter(서류 7): 낱장 \(scene.paperCount("알파"))장 · 명판 '\(plate())'")
        // ④ 새 API를 받은 뒤 예전 API는 무시.
        let richCount = scene.clutterProbes("알파").count
        scene.setClutter(["알파": 9])
        harness.run(0.6)
        check(scene.clutterProbes("알파").count == richCount && plate() == "워크트리 1 · 브랜치 2 · 서류 7 · 512MB", "④ 새 API 뒤 예전 setClutter(알파 9)는 무시: 짐 \(scene.clutterProbes("알파").count)개 · 명판 그대로")
        // ⑤ 나중에 온 서류 수를 따른다.
        scene.setPapers(["알파": 2])
        harness.run(3)
        check(scene.paperCount("알파") == 2 && plate() == "워크트리 1 · 브랜치 2 · 서류 2 · 512MB", "⑤ setPapers(2) 뒤: 낱장 \(scene.paperCount("알파"))장 · 명판 '\(plate())'")
        // ⑥ 넘친 서류는 상자로(낱장 자리 × 5장을 넘는 만큼, 모두 치울 수 있음).
        let capacity = scene.paperSpots("알파").count * 5
        let calm = scene.clutterProbes("알파")
        scene.setPapers(["알파": 80])
        harness.run(4)
        let flooded = scene.clutterProbes("알파")
        let extra = flooded.filter { probe in probe.kind != .sign && !calm.contains { $0.id == probe.id } }
        check(scene.paperCount("알파") == capacity && extra.count > 0 && extra.allSatisfy(\.cleanable) && clutterProblems(scene, project: "알파", level: RoomClutter(worktrees: 1, branches: 2 + 80 - capacity).level).isEmpty,
              "⑥ 서류 80건: 낱장 \(scene.paperCount("알파"))장(자리 한도 \(capacity)) · 넘친 \(80 - capacity)건 → 짐 \(calm.count) → \(flooded.count)개(더해진 \(extra.count)개 모두 치울 수 있음)")
        shot(harness, "clutter-papers-overflow", rect: scene.roomRect(scene.currentLayout.rooms[scene.clutterRoomIndex("알파") ?? 0]).insetBy(dx: -24, dy: -6))

        // ⑦ 방 없는 프로젝트(세션 없음): 기계실 디스크 저장고 오른쪽에 한 줄 — 남길 것이 아래 · 치울 것이 위. 청소하면 치울 상자만 들고 나간다.
        let roomless = RoomClutter(worktrees: 2, branches: 1, cleanableBranches: 1, bytes: 700 << 20)
        scene.setClutter(["알파": rich, "감마": roomless])
        harness.run(0.6)
        let floor0 = scene.line(scene.currentLayout.basementIndex)
        func storageOK(_ probes: [OfficeScene.ClutterProbe]) -> Bool {
            var y = floor0 + ClutterPlan.backRow
            for probe in probes.sorted(by: { $0.frame.minY < $1.frame.minY }) {
                guard abs(probe.frame.minY - y) < 0.01, probe.frame.minX >= OfficeScene.storageX - 0.01, probe.frame.maxX <= OfficeScene.storageX + 10.01, probe.placed, probe.cleanLook == probe.cleanable else { return false }
                y = probe.frame.maxY
            }
            return true
        }
        let stored = scene.clutterProbes("감마")
        scene.frameCamera(on: CGRect(x: 380, y: floor0 - 10, width: 180, height: 80))
        harness.run(0.2)
        let storagePlate = scene.clutterLabel("plate", "")
        check(stored.count == 2 && stored.filter(\.cleanable).count == 1 && storageOK(stored) && storagePlate?.text == "방 없는 짐 · 워크트리 2 · 브랜치 1 · 서류 0 · 700MB" && storagePlate?.hidden == false,
              "⑦ 방 없는 감마: 기계실 한 줄 \(stored.count)상자(치울 수 있음 \(stored.filter(\.cleanable).count) · 위) · 명판 '\(storagePlate?.text ?? "없음")'")
        shot(harness, "clutter-storage", rect: CGRect(x: 380, y: floor0 - 10, width: 180, height: 80))
        scene.janitorVisit(project: "감마", items: 1, reclaimed: 0)
        let watch = StaffWatch()
        let gone = runUntil(harness, timeout: 40, probe: { now in for (name, probe) in scene.janitorProbes { watch.observe(probe, name, layout: scene.currentLayout, now: now) } }) { scene.janitorsGone }
        let rest = scene.clutterProbes("감마")
        check(gone != nil && rest.count == 1 && !rest[0].cleanable && storageOK(rest), "⑦ 감마 청소: 치울 상자만 들고 나가고 남은 \(rest.count)상자는 바닥에(뜬 것 없음)")
        watch.report("청소 특공대", particle: "가")
        noSafetyNet(harness)
    }
}
