import AppKit
import ReMONCore
import SpriteKit

// 연출이 사실을 앞서지 않는가(10-25 대표 원칙 '은유가 사실을 앞서면 안 된다').
// 재기 전 숫자는 '예상'으로만 말하고, 앱이 다시 잰 값은 '실측'으로 — 인물이 실제 계기(기계실 RAM 탱크 · 디스크 저장고) 앞에서 말한다.
// 짐꾼의 스왑 상자는 실제 스왑 값만 따른다: 줄어든 게 없으면(0) 상자도 그대로이고, 스왑은 쓰던 앱이 끝나야 준다고 말한다.
// 발표하러 오가는 인물도 감사 인물과 같은 규칙으로 본다(보이는 동안 늘 어느 층 바닥 위 · 엘리베이터 칸에 2초 넘게 서 있지 않음).

extension SceneChecks {
    // MARK: 트레이너 — 예상 → 실측 발표

    static func trainerAnnounce() {
        print("— trainer-announce: 난입 자막·호루라기는 '예상'만 → 실측 발표는 기계실 RAM 탱크 앞 → 옥상 복귀 · 공중 부양·엘리베이터 끼임 없음")
        Variety.shared.seed(61)
        let harness = SceneHarness()
        let scene = harness.scene
        // 팀 셋(팀 층 셋): ④에서 발표하러 옥상을 걷는 도중 한 팀이 퇴근해 층이 줄어드는 경우까지 본다.
        let alpha = (0..<8).map { session(Int32(17_001 + $0), "알파", .working, order: Double($0)) }
        let delta = (0..<8).map { session(Int32(17_101 + $0), "델타", .working, order: Double(10 + $0)) }
        let gamma = (0..<8).map { session(Int32(17_201 + $0), "감마", .working, order: Double(20 + $0)) }
        harness.sessions = alpha + delta + gamma
        harness.feed()
        harness.run(4)
        let gib = Double(Fmt.gib)
        let watch = StaffWatch()
        var said: [String] = []
        let observe: (TimeInterval) -> Void = { now in
            watch.observe(scene.trainerProbe, "트레이너", layout: scene.currentLayout, now: now)
            if let text = scene.trainerSaying, said.last != text { said.append(text) }
        }

        // ① 난입(아직 재기 전): 자막·호루라기의 숫자는 '예상'뿐 — "X 회수"라고 단정하지 않는다.
        scene.trainerVisit(reclaimed: UInt64(3 * gib), text: "정리 운동!")
        let visitCaption = scene.eventCaptions.last ?? ""
        harness.run(13.5, probe: observe)
        let claims = said.filter { $0.contains("회수") && !$0.contains("예상") }
        check(visitCaption.contains("예상 3.0GB") && said.contains { $0.contains("예상 3.0GB") } && claims.isEmpty && scene.trainerResting,
              "① 재기 전: 자막 '\(visitCaption)' · 호루라기 \(said) — 숫자는 '예상'만(단정한 회수 \(claims.count)건)")

        // ② 실측 도착(옥상에서 대기 중): 엘리베이터로 기계실 RAM 탱크 앞까지 내려와 '실측 1.2GB 회수' → 설명 → 옥상 복귀.
        said = []
        scene.trainerAnnounce(measured: UInt64(1.2 * gib), text: "메모리 22.1GB → 20.9GB")
        let announceCaption = scene.eventCaptions.last ?? ""
        let reached = runUntil(harness, timeout: 30, probe: observe) {
            let p = scene.trainerProbe
            return p.floor == 0 && abs(p.x - OfficeScene.trainerTankX) < 1 && p.alpha > 0.99 && scene.trainerSaying == "실측 1.2GB 회수"
        }
        if reached != nil {
            harness.run(0.6, probe: observe)
            shot(harness, "trainer-announce", rect: MachineLayout.rect(.ram, floor: scene.currentLayout.floors[0]).insetBy(dx: -120, dy: -14))
        }
        let back = runUntil(harness, timeout: 30, probe: observe) { scene.trainerResting }
        let rest = scene.trainerProbe
        let roof = scene.currentLayout.floors[scene.currentLayout.roofIndex]
        check(reached != nil && announceCaption.contains("실측 1.2GB 회수") && said.contains("메모리 22.1GB → 20.9GB"),
              "② 실측 발표: 트레이너가 기계실 RAM 탱크 앞(층 0 · x \(Int(OfficeScene.trainerTankX)))에서 '실측 1.2GB 회수' · " +
              (reached.map { String(format: "%.1f초", $0) } ?? "30초 안에 못 감") + " · 자막 '\(announceCaption)' · 말 \(said)")
        check(back != nil && abs(rest.y - CGFloat(roof.floorLine)) < 0.5 && abs(rest.x - OfficeScene.trainerRoofX) < 1 && rest.alpha > 0.99,
              "② 발표 뒤 엘리베이터로 옥상에 돌아가 대기: " + (back.map { String(format: "%.1f초", $0) } ?? "30초 안에 못 감") + String(format: " · 층 %d x=%.0f", rest.floor, rest.x))

        // ③ 난입 도중에 실측(0)이 먼저 옴: 옥상에 들르지 않고 난입을 마친 층에서 곧장 RAM 탱크로 → '회수 없음 · 쓰던 앱이 끝나야 줄어듭니다'.
        said = []
        scene.trainerVisit(reclaimed: UInt64(2 * gib), text: "메모리 최적화!")
        harness.run(4, probe: observe)
        scene.trainerAnnounce(measured: 0, text: "")
        var visitedRoof = false
        let zero = runUntil(harness, timeout: 40, probe: { now in
            observe(now)
            let p = scene.trainerProbe
            if p.floor == scene.currentLayout.roofIndex, p.alpha > 0.5 { visitedRoof = true }
        }) { scene.trainerProbe.floor == 0 && scene.trainerSaying == "회수 없음 · 쓰던 앱이 끝나야 줄어듭니다" }
        let zeroBack = runUntil(harness, timeout: 30, probe: observe) { scene.trainerResting }
        check(zero != nil && !visitedRoof && zeroBack != nil,
              "③ 난입 도중 실측 0 → 난입을 마친 층에서 곧장(옥상 들름 \(visitedRoof)) 탱크로 '회수 없음 · 쓰던 앱이 끝나야 줄어듭니다' · " +
              (zero.map { String(format: "%.1f초", $0) } ?? "40초 안에 못 감") + " · 말 \(said)")

        // ④ 발표하러 옥상을 걷는 중 한 팀이 퇴근해 층이 줄어듦(옥상이 한 층 내려앉음) → 새 옥상 바닥 위에서 이어 간다(하늘에 뜨지 않음).
        said = []
        scene.trainerAnnounce(measured: UInt64(0.5 * gib), text: "")
        harness.run(1.0, probe: observe)
        let floorsBefore = scene.currentLayout.floors.count
        let onRoof = scene.trainerProbe.floor == scene.currentLayout.roofIndex && scene.trainerProbe.alpha > 0.99
        harness.sessions = alpha + delta
        harness.feed()
        harness.run(0.5, probe: observe)
        let floorsAfter = scene.currentLayout.floors.count
        let reachedAgain = runUntil(harness, timeout: 40, probe: observe) { scene.trainerProbe.floor == 0 && scene.trainerSaying == "실측 512MB 회수" }
        let restAgain = runUntil(harness, timeout: 40, probe: observe) { scene.trainerResting }
        check(onRoof && floorsAfter < floorsBefore && reachedAgain != nil && restAgain != nil,
              "④ 옥상을 걷는 중 층이 \(floorsBefore)→\(floorsAfter)개로 줄어도 새 옥상 바닥에서 이어 가 탱크에서 '실측 512MB 회수' → 옥상 복귀 " +
              (restAgain != nil ? "" : "(못 끝냄)"))
        watch.report("트레이너", particle: "가")
        noSafetyNet(harness)
    }

    // MARK: 청소 특공대 — 예상 → 디스크 실측

    static func janitorAnnounce() {
        print("— janitor-announce: 청소 자막은 '예상' → 실측은 쓸기를 마친 말풍선이 · 특공대가 돌아간 뒤 실측이 오면 한 명이 디스크 저장고 앞으로 와서 알림")
        Variety.shared.seed(62)
        let harness = SceneHarness()
        let scene = harness.scene
        let alpha: [AgentSession] = (0..<4).map { session(Int32(18_001 + $0), "알파", .working, order: Double($0)) }
        let beta: [AgentSession] = (0..<3).map { session(Int32(18_101 + $0), "베타", .working, order: Double(10 + $0)) }
        harness.sessions = alpha + beta
        harness.feed()
        scene.setClutter(["알파": 3])
        harness.run(3)
        let gib = Double(Fmt.gib)
        let watch = StaffWatch()
        var said: [String] = []
        let observe: (TimeInterval) -> Void = { now in
            for (name, probe) in scene.janitorProbes { watch.observe(probe, name, layout: scene.currentLayout, now: now) }
            if let text = scene.janitorSaying, said.last != text { said.append(text) }
        }

        // ① 청소 시작: 자막은 '예상' · 2초 뒤 디스크 실측이 오면 쓸기를 마친 말풍선이 마침 인사 대신 '실측 +4.6GB'(자막도 실측으로).
        scene.janitorVisit(project: "알파", items: 3, reclaimed: UInt64(4.8 * gib))
        let visitCaption = scene.eventCaptions.last ?? ""
        harness.run(2, probe: observe)
        scene.janitorAnnounce(measured: UInt64(4.6 * gib))
        let spoke = runUntil(harness, timeout: 30, probe: observe) { said.contains("실측 +4.6GB") }
        let gone = runUntil(harness, timeout: 30, probe: observe) { scene.janitorsGone }
        check(visitCaption.contains("예상 4.8GB") && !visitCaption.contains("실측"), "① 재기 전 청소 자막은 '예상': '\(visitCaption)'")
        check(spoke != nil && gone != nil && !said.contains { Lines.janitorDone.contains($0) } && scene.eventCaptions.contains { $0.contains("디스크 실측 +4.6GB") },
              "① 청소 중 실측 도착 → 쓸기를 마친 말풍선이 '실측 +4.6GB'(마침 인사 대신) · 자막도 실측으로 · 말 \(said)")

        // ② 특공대가 다 돌아간 뒤 실측이 옴: 한 명이 1층 문으로 들어와 기계실 디스크 저장고 앞에서 알리고 돌아간다.
        said = []
        scene.janitorAnnounce(measured: UInt64(2.1 * gib))
        let reportCaption = scene.eventCaptions.last ?? ""
        let atShelf = runUntil(harness, timeout: 30, probe: observe) {
            guard let reporter = scene.janitorProbes.first(where: { $0.name == "실측 알림" })?.probe else { return false }
            return reporter.floor == 0 && abs(reporter.x - OfficeScene.janitorShelfX) < 1 && reporter.alpha > 0.99 && scene.janitorSaying == "실측 +2.1GB"
        }
        if atShelf != nil {
            harness.run(0.6, probe: observe)
            shot(harness, "janitor-announce", rect: MachineLayout.rect(.disk, floor: scene.currentLayout.floors[0]).insetBy(dx: -70, dy: -14))
        }
        let left = runUntil(harness, timeout: 30, probe: observe) { scene.janitorsGone }
        check(atShelf != nil && left != nil && reportCaption.contains("실측 +2.1GB"),
              "② 특공대가 돌아간 뒤 실측 → 한 명이 기계실 디스크 저장고 앞(층 0 · x \(Int(OfficeScene.janitorShelfX)))에서 '실측 +2.1GB' 뒤 1층 문으로 퇴장 · " +
              (atShelf.map { String(format: "%.1f초", $0) } ?? "30초 안에 못 감") + " · 자막 '\(reportCaption)'")

        // ③ 실측 0: '실측 · 디스크 여유 그대로'(늘어난 게 없으면 없다고).
        said = []
        scene.janitorAnnounce(measured: 0)
        let zero = runUntil(harness, timeout: 30, probe: observe) { scene.janitorSaying == "실측 · 디스크 여유 그대로" }
        let zeroGone = runUntil(harness, timeout: 30, probe: observe) { scene.janitorsGone }
        check(zero != nil && zeroGone != nil, "③ 실측 0 → '실측 · 디스크 여유 그대로' · 말 \(said)")
        watch.report("청소 특공대", particle: "가")
        noSafetyNet(harness)
    }

    // MARK: 짐꾼 — 줄어든 스왑 0이면 상자 0개

    static func porterZero() {
        print("— porter-zero: 줄어든 스왑 0 → 짐꾼이 둘러보고 '쓰던 앱이 끝나야 줄어요' · 상자 0개 / 비운 양이 와도 실제 스왑이 그대로면 상자를 빼지 않음")
        Variety.shared.seed(63)
        let harness = SceneHarness()
        let scene = harness.scene
        let warehouse = scene.warehouseNode
        harness.sessions = [session(19_001, "알파", .working, order: 0)]
        harness.swapGB = 9
        harness.feed()
        harness.run(4)
        let gib = Double(Fmt.gib)
        /// 운반을 따라가며: 가장 낮았던 상자 수 · 짐꾼이 엘리베이터에서 나타났는가 · 수레 최대 적재 · 말풍선.
        final class Trace { var lowest = Int.max, fromShaft = false, maxCart = 0, said: [String] = [] }
        func tracer(_ trace: Trace) -> (TimeInterval) -> Void {
            { _ in
                trace.lowest = min(trace.lowest, warehouse.shown[.swap] ?? 0)
                if warehouse.porterVisible, abs(warehouse.porter.position.x - CGFloat(BuildingLayout.elevatorX)) <= 6 { trace.fromShaft = true }
                trace.maxCart = max(trace.maxCart, warehouse.cartLoad)
                if let text = scene.porterSaying, trace.said.last != text { trace.said.append(text) }
            }
        }
        let finished = { !warehouse.busy && !warehouse.unloading }

        // ① 메모리 최적화(트레이너 난입) 뒤 스왑이 그대로 → 실측 0: 짐꾼이 엘리베이터로 와서 둘러보고 앱이 끝나야 준다고 말함 · 상자 0개.
        scene.trainerVisit(reclaimed: UInt64(2 * gib), text: "메모리 최적화!")
        harness.run(13.5)
        let before = warehouse.shown[.swap] ?? -1
        var removed = warehouse.swapRemoved
        let a = Trace()
        scene.porterUnload(freedBytes: 0, caption: "스왑은 그대로입니다 · 쓰던 앱이 끝나야 줄어듭니다")
        let speaking = runUntil(harness, timeout: 20, probe: tracer(a)) { scene.porterSaying.map { Lines.swapOwnerEnds.contains($0) } ?? false }
        if speaking != nil {
            harness.run(0.5, probe: tracer(a))
            shot(harness, "porter-zero", rect: MachineLayout.rect(.swap, floor: scene.currentLayout.floors[0]).insetBy(dx: -150, dy: -10))
        }
        let doneA = runUntil(harness, timeout: 25, probe: tracer(a), finished)
        check(speaking != nil && doneA != nil && a.fromShaft && a.lowest == before && warehouse.shown[.swap] == before && warehouse.swapRemoved == removed,
              "① 실측 0 → 짐꾼이 엘리베이터로 와서 둘러보고 \(a.said) · 상자 \(before)→\(warehouse.shown[.swap] ?? -1)(가장 낮은 값 \(a.lowest)) · 뺀 상자 \(warehouse.swapRemoved - removed)개")

        // ② 비운 양 3GB가 왔지만 실제 스왑(스냅샷)은 그대로 9GB → 상자를 하나도 빼지 않는다(지어낸 상자 없음) · 그렇다고 말한다.
        removed = warehouse.swapRemoved
        let b = Trace()
        scene.porterUnload(freedBytes: UInt64(3 * gib), caption: "스왑 3.0GB 줄었습니다 · 짐꾼이 상자를 빼 갑니다")
        let captionB = scene.eventCaptions.last ?? ""
        let doneB = runUntil(harness, timeout: 25, probe: tracer(b), finished)
        check(doneB != nil && b.lowest == 9 && warehouse.shown[.swap] == 9 && warehouse.swapRemoved == removed && b.maxCart == 0 && warehouse.unloadCarried == 0
              && b.said.contains("3.0GB 줄었지만 상자는 그대로예요") && captionB.contains("상자는 그대로"),
              "② 비운 양 3GB · 실제 스왑 9GB 그대로 → 뺀 상자 \(warehouse.swapRemoved - removed)개 · 나른 수 \(warehouse.unloadCarried) · 말 \(b.said) · 자막 '\(captionB)'")

        // ③ 1상자에 못 미치는 감소(9.3 → 8.8GB, 반올림하면 둘 다 9상자)에 0.5GB 실측 → 상자 그대로.
        harness.swapGB = 9.3
        harness.run(4.5)
        harness.swapGB = 8.8
        harness.run(4.5)
        removed = warehouse.swapRemoved
        let c = Trace()
        scene.porterUnload(freedBytes: UInt64(0.5 * gib), caption: "스왑 0.5GB 줄었습니다 · 짐꾼이 상자를 빼 갑니다")
        let doneC = runUntil(harness, timeout: 25, probe: tracer(c), finished)
        check(doneC != nil && c.lowest == 9 && warehouse.shown[.swap] == 9 && warehouse.swapRemoved == removed,
              "③ 1GB 미만 감소(9.3→8.8GB) → 상자 9 그대로 · 뺀 상자 \(warehouse.swapRemoved - removed)개 · 말 \(c.said)")

        // ④ 대조군: 실제로 줄어든 만큼은 그대로 뺀다(9 → 7GB, 2GB 실측 → 2상자 · 가장 낮은 값 7).
        harness.swapGB = 7
        harness.feed()
        removed = warehouse.swapRemoved
        let d = Trace()
        scene.porterUnload(freedBytes: UInt64(2 * gib), caption: "스왑 2.0GB 줄었습니다 · 짐꾼이 상자를 빼 갑니다")
        let doneD = runUntil(harness, timeout: 30, probe: tracer(d)) { finished() && warehouse.shown[.swap] == 7 }
        check(doneD != nil && d.lowest == 7 && warehouse.swapRemoved - removed == 2 && warehouse.unloadCarried == 2,
              "④ 대조군: 실제 스왑 9→7GB · 2GB 실측 → 2상자 내감(가장 낮은 값 \(d.lowest)) · 말 \(d.said)")

        // ⑤ 내가기를 계획한 뒤 실제 스왑이 다시 늘면(12 → 6 → 10GB) 그 값에서 멈춘다 — 마지막 실제 값 아래로 빼지 않는다.
        harness.swapGB = 12
        _ = runUntil(harness, timeout: 40, probe: nil) { finished() && warehouse.shown[.swap] == 12 }
        harness.swapGB = 6
        harness.feed()
        removed = warehouse.swapRemoved
        let e = Trace()
        scene.porterUnload(freedBytes: UInt64(6 * gib), caption: "스왑 6.0GB 줄었습니다 · 짐꾼이 상자를 빼 갑니다")
        harness.swapGB = 10
        harness.feed()
        let doneE = runUntil(harness, timeout: 40, probe: tracer(e)) { finished() && warehouse.shown[.swap] == 10 }
        check(doneE != nil && e.lowest == 10 && warehouse.swapRemoved - removed == 2,
              "⑤ 계획 뒤 실제 스왑이 6→10GB로 다시 늘면 10상자에서 멈춤(가장 낮은 값 \(e.lowest) · 뺀 상자 \(warehouse.swapRemoved - removed)개) · 말 \(e.said)")
        check(harness.scene.workerKeys.count == 1, "짐꾼은 직원(에이전트)이 아님: 직원 \(harness.scene.workerKeys.count)명")
    }
}
