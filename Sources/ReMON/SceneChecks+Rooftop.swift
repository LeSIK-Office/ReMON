import AppKit
import ReMONCore
import SpriteKit

// 옥상 웰니스 풀 검사(10-25 대표 지시 '겨울되면 풀장에서 김 · 온수풀 · 저녁이면 조명 · 가끔 DJ 파티'):
// 겨울 밤 김 있음(새벽 · 밤이 낮보다 짙음) · 여름 없음 / 저녁 조명 있음 · 점심 없음(시간대가 바뀌면 다시 짓고 텍스처는 캐시) /
// 씨앗 + 저녁 시각으로 파티를 재현 — 디제이가 엘리베이터로 오가고, 쉬는 직원만 춤추고, 일하는 직원은 책상에, 끝나면 아무도 남지 않는다.
// 장면 시각은 하네스가 고정한다(SceneHarness(sceneTime:)) — 실제 시각 · 계절과 무관하게 같은 결과.
extension SceneChecks {
    /// 하네스 하나: 고른 시각 · 씨앗, 쉬는 직원 idle명(알파) + 일하는 직원 한 명(베타). 날씨 층(밤 색조 · 눈)도 앱처럼 켠다.
    /// party가 false면 이번 저녁 DJ 파티는 이미 연 것으로 둔다 — 김 · 조명만 보이게(파티는 pool-party가 따로 본다).
    private static func poolHarness(_ time: String, seed: UInt64, idle: Int, pid: Int32, party: Bool = false) -> (harness: SceneHarness, idle: [AgentSession]) {
        Variety.shared.seed(seed)
        let harness = SceneHarness(sceneTime: SceneHarness.sceneTime(time))
        if !party {
            harness.scene.party.evening = OfficeScene.eveningOf(SceneClock.now).key
            harness.scene.party.held = true
        }
        harness.scene.updateWeather()
        let members = (0..<idle).map { session(pid + Int32($0), "알파", .idle, order: Double($0)) }
        harness.sessions = members + [session(pid + 100, "베타", .working, order: 20)]
        harness.feed()
        return (harness, members)
    }

    /// 옥상 사각형(캡처용): 루프톱 선베드부터 풀 끝까지.
    private static func roofRect(_ scene: OfficeScene) -> CGRect {
        let roof = scene.currentLayout.floors[scene.currentLayout.roofIndex]
        return CGRect(x: 12, y: CGFloat(roof.y) - 6, width: 622, height: CGFloat(roof.height) + 22)
    }

    /// 옥상 가까이(캡처용): 선베드 오른쪽 절반 · DJ 부스 · 미러볼 · 풀 · 트레이너.
    private static func roofCloseRect(_ scene: OfficeScene) -> CGRect {
        let roof = scene.currentLayout.floors[scene.currentLayout.roofIndex]
        return CGRect(x: 180, y: CGFloat(roof.y) - 10, width: 440, height: CGFloat(roof.height) + 34)
    }

    /// seconds 동안 김 퍼프 수를 0.25초마다 세어 평균 · 최대(처음 3초는 피어오르는 중이라 뺀다).
    private static func steamStats(_ harness: SceneHarness, seconds: TimeInterval, probe: ((TimeInterval) -> Void)? = nil) -> (average: Double, peak: Int) {
        harness.run(3)
        var total = 0, samples = 0, peak = 0
        harness.run(seconds) { now in
            let count = harness.scene.poolSteamCount
            total += count; samples += 1; peak = max(peak, count)
            probe?(now)
        }
        return (Double(total) / Double(max(1, samples)), peak)
    }

    // MARK: 겨울 온수풀 김

    static func poolSteam() {
        print("— pool-steam: 겨울 = 온수풀 김(새벽 · 밤에 더 짙게) · 풀에서 헤엄치는 직원만 '따뜻해~' · 여름 = 김 없음")
        // ① 겨울 깊은 밤
        let night = poolHarness("2027-01-15T23:30", seed: 81, idle: 10, pid: 31_001)
        let scene = night.harness.scene
        scene.focus(.floor(scene.currentLayout.roofIndex), animated: false)   // 층 보기: 다른 층 말풍선은 숨으므로 옥상을 본다
        var shownWarm: [String] = [], wrongSpeaker: [String] = []
        var heard: [ProcessKey: TimeInterval] = [:], longest: TimeInterval = 0
        let deep = steamStats(night.harness, seconds: 30) { now in
            for member in night.idle {
                guard let bubble = scene.bubbleProbe(member.id), Lines.hotSpring.contains(bubble.text), let worker = scene.worker(for: member.id) else { heard[member.id] = nil; continue }
                if !shownWarm.contains(bubble.text) { shownWarm.append(bubble.text) }
                let since = heard[member.id] ?? now
                heard[member.id] = since
                longest = max(longest, now - since)
                if case .rest(let spot) = worker.place, spot.kind == .swim { continue }
                wrongSpeaker.append("pid \(member.id.pid) · \(describe(worker))")
            }
        }
        let swimmers = night.idle.filter { member in
            guard let worker = scene.worker(for: member.id), case .rest(let spot) = worker.place else { return false }
            return spot.kind == .swim
        }.count
        check(deep.average >= 6 && deep.peak >= 8, String(format: "겨울 깊은 밤: 수면에서 김 퍼프 평균 %.1f · 최대 %d개(≥ 6 · 8)", deep.average, deep.peak))
        check(!scene.hotSpringLines.isEmpty && scene.hotSpringLines.allSatisfy { Lines.hotSpring.contains($0.text) } && !shownWarm.isEmpty && wrongSpeaker.isEmpty,
              "겨울: 풀에서 헤엄치는 직원(\(swimmers)명)이 온천 대사 \(scene.hotSpringLines.count)번 · 보인 말 \(shownWarm.prefix(3))" + (wrongSpeaker.isEmpty ? "" : " · 풀 밖에서 말함 \(wrongSpeaker.prefix(2))"))
        check(longest >= 2.2, String(format: "온천 대사는 끝까지(2.6초) 보임 — 스냅샷 자세 맞추기가 지우지 않음: 가장 길게 %.2f초", longest))
        shot(night.harness, "pool-steam-winter-night", rect: CGRect(x: 300, y: roofRect(scene).minY, width: 336, height: roofRect(scene).height))
        // ② 겨울 새벽(아침 7시) · 점심: 낮에도 김은 쉬지 않지만, 새벽 · 밤이 더 짙다
        let dawn = poolHarness("2027-01-15T07:00", seed: 81, idle: 10, pid: 31_001)
        let early = steamStats(dawn.harness, seconds: 20)
        let noon = poolHarness("2027-01-15T13:00", seed: 81, idle: 10, pid: 31_001)
        let midday = steamStats(noon.harness, seconds: 20)
        check(midday.average > 0.5 && early.average > midday.average * 1.6 && deep.average > midday.average * 1.6,
              String(format: "짙기: 새벽 %.1f · 깊은 밤 %.1f > 점심 %.1f(점심에도 김은 남)", early.average, deep.average, midday.average))
        // ③ 여름 밤: 김 없음 · 온천 대사 없음
        let summer = poolHarness("2026-07-15T23:30", seed: 81, idle: 10, pid: 31_001)
        let warmNight = steamStats(summer.harness, seconds: 20)
        check(warmNight.peak == 0 && summer.harness.scene.hotSpringLines.isEmpty, "여름 밤: 김 퍼프 최대 \(warmNight.peak)개 · 온천 대사 \(summer.harness.scene.hotSpringLines.count)번(둘 다 0)")
        noSafetyNet(night.harness)
    }

    // MARK: 저녁 풀 조명

    static func poolLights() {
        print("— pool-lights: 노을 ~ 밤 = 수중등 · 줄전구 · 어두운 물빛 / 점심 = 없음 · 시간대가 바뀌면 조명 재구성이 다시 짓고 텍스처는 캐시 · 옥상을 따라간다")
        // ① 저녁(가을 20:30)
        let evening = poolHarness("2026-10-15T20:30", seed: 82, idle: 6, pid: 32_001)
        let scene = evening.harness.scene
        evening.harness.run(3)
        let deck = scene.poolDeckNode
        check(deck.lampCount == 5 && deck.strandLit && deck.waterTint > 0.3 && !deck.strandParty,
              String(format: "저녁: 수중등 %d개 · 줄전구 %@ · 물빛 어둡기 %.2f(> 0.3)", deck.lampCount, deck.strandLit ? "켜짐" : "꺼짐", deck.waterTint))
        shot(evening.harness, "pool-lights-evening", rect: roofRect(scene))
        shot(evening.harness, "pool-lights-evening-close", rect: roofCloseRect(scene))
        // 옥상을 따라간다: 새 팀(8명)이 들어와 층이 늘면 옥상이 올라가고 풀 데크(조명 · 김 · 무대)도 같이
        let before = scene.currentLayout.floors.count
        let delta: [AgentSession] = (0..<8).map { index in session(Int32(32_201 + index), "델타", .working, order: Double(40 + index)) }
        evening.harness.sessions += delta
        evening.harness.feed()
        evening.harness.run(2)
        let roofLine = scene.line(scene.currentLayout.roofIndex)
        check(scene.currentLayout.floors.count > before && abs(deck.position.y - roofLine) < 0.5 && deck.lampCount == 5,
              "층이 늘어도(\(before) → \(scene.currentLayout.floors.count)층) 풀 데크가 새 옥상 바닥선(\(Int(roofLine)))을 따라감 · 수중등 \(deck.lampCount)개")
        // ② 점심: 없음
        let noon = poolHarness("2026-10-15T13:00", seed: 82, idle: 6, pid: 32_001)
        noon.harness.run(3)
        let noonDeck = noon.harness.scene.poolDeckNode
        check(noonDeck.lampCount == 0 && !noonDeck.strandLit && noonDeck.waterTint == 0, "점심: 수중등 \(noonDeck.lampCount)개 · 줄전구 \(noonDeck.strandLit ? "켜짐" : "없음") · 물빛 그대로")
        // ③ 시간대 경계: 15:59(점심, 꺼짐) → 16:00이 지나면(노을) 조명 재구성이 다시 지어 켜진다
        let dusk = poolHarness("2026-10-15T15:59", seed: 82, idle: 6, pid: 32_001)
        dusk.harness.run(2)
        let duskDeck = dusk.harness.scene.poolDeckNode
        let off = duskDeck.lampCount
        dusk.harness.run(62)
        check(off == 0 && duskDeck.lampCount == 5 && duskDeck.strandLit && duskDeck.waterTint > 0.1 && duskDeck.waterTint < deck.waterTint,
              String(format: "15:59 → 16:00(노을): 수중등 %d → %d개 · 물빛 %.2f(저녁 %.2f보다 옅게)", off, duskDeck.lampCount, duskDeck.waterTint, deck.waterTint))
        // ④ 캐시: 같은 시간대 그림은 다시 그리지 않는다(하늘처럼 텍스처 캐시)
        var redrawn = false
        _ = TextureCache.shared.texture("pool-glow-0") { redrawn = true; return PixelCanvas(1, 1) }
        _ = TextureCache.shared.texture("string-lights-warm") { redrawn = true; return PixelCanvas(1, 1) }
        check(!redrawn, "수중등 · 줄전구 텍스처는 캐시에서 다시 씀(새로 그리지 않음)")
        noSafetyNet(evening.harness)
    }

    // MARK: DJ 파티

    /// 0.25초마다: 뜬 사람 · 엘리베이터에 멈춘 사람 · 책상을 떠난 일하는 직원 · 춤추는 일하는 직원 · 디제이가 보인 층(층 종류 — 층이 늘면 옥상 번호가 바뀐다)
    /// · 공연 중 디제이 · 무대가 옥상 바닥선에 있는지.
    @MainActor
    final class PartyWatch {
        var problems: [String] = []
        var djFloors: [String] = []
        var dancers = Set<ProcessKey>()
        var shaftSince: [String: TimeInterval] = [:]

        static func floorName(_ layout: BuildingLayout, _ index: Int) -> String {
            guard layout.floors.indices.contains(index) else { return "없는 층" }
            switch layout.floors[index].kind {
            case .lobby: return "1층"
            case .roof: return "옥상"
            default: return "\(index)층"
            }
        }

        func observe(_ scene: OfficeScene, desks: [AgentSession], now: TimeInterval) {
            let layout = scene.currentLayout
            let dancing = Set(scene.partyDancerKeys)
            dancers.formUnion(dancing)
            func note(_ text: String) { if problems.count < 40 { problems.append(String(format: "t=%.1f ", now) + text) } }
            for key in scene.workerKeys {
                guard let worker = scene.worker(for: key), !worker.leaving else { continue }
                let base = scene.line(worker.floorIndex)
                if worker.position.y > CGFloat(layout.height) || !layout.floors.indices.contains(worker.floorIndex) { note("건물 밖 pid \(key.pid) · \(SceneChecks.describe(worker))") }
                if dancing.contains(key) {
                    if scene.sessions[key]?.state != .idle { note("쉬지 않는 직원이 춤 pid \(key.pid)") }
                    if worker.position.y < base - 0.5 || worker.position.y > base + 1.5 { note("춤추며 뜸 pid \(key.pid) · y \(worker.position.y - base)") }
                } else if case .rest(let spot) = worker.place, worker.route == nil, worker.action(forKey: "move") == nil, !worker.busy,
                          abs(worker.position.y - (base + CGFloat(spot.yOffset))) > 0.5 {
                    note("자리에서 뜸 pid \(key.pid) · \(SceneChecks.describe(worker))")
                }
                track("pid \(key.pid)", visible: worker.alpha > 0.5 && abs(worker.position.x - CGFloat(BuildingLayout.elevatorX)) <= 6, now: now)
            }
            for member in desks {
                guard let worker = scene.worker(for: member.id), let desk = layout.desks[member.id] else { note("일하는 직원 없음 pid \(member.id.pid)"); continue }
                if worker.place != .desk || worker.floorIndex != desk.floor || abs(worker.position.x - CGFloat(desk.seatX)) > 1 { note("책상 떠남 pid \(member.id.pid) · \(SceneChecks.describe(worker))") }
                if dancing.contains(member.id) { note("일하는 직원이 춤 pid \(member.id.pid)") }
            }
            let dj = scene.djProbe
            if dj.present && dj.alpha > 0.5 {
                if !layout.floors.contains(where: { abs(CGFloat($0.floorLine) - dj.y) < 0.5 }) { note(String(format: "디제이가 뜸 y %.1f", dj.y)) }
                let name = Self.floorName(layout, dj.floor)
                if djFloors.last != name { djFloors.append(name) }
            }
            if scene.partyPhaseName == "playing" {
                let roofLine = scene.line(layout.roofIndex)
                if abs(dj.y - roofLine) > 0.5 { note(String(format: "공연 중 디제이가 옥상 바닥선 밖 y %.1f(옥상 %.0f)", dj.y, roofLine)) }
                if abs(scene.poolDeckNode.position.y - roofLine) > 0.5 { note(String(format: "무대가 옥상 바닥선 밖 y %.1f(옥상 %.0f)", scene.poolDeckNode.position.y, roofLine)) }
            }
            track("디제이", visible: dj.present && dj.alpha > 0.5 && abs(dj.x - CGFloat(BuildingLayout.elevatorX)) <= 6, now: now)
        }

        /// 엘리베이터 칸 앞에 보이게 3초 넘게 서 있으면 멈춘 것으로 본다.
        private func track(_ name: String, visible: Bool, now: TimeInterval) {
            guard visible else { shaftSince[name] = nil; return }
            let since = shaftSince[name] ?? now
            shaftSince[name] = since
            if now - since > 3, problems.count < 40, !problems.contains(where: { $0.hasSuffix("엘리베이터에 멈춤 \(name)") }) {
                problems.append(String(format: "t=%.1f ", now) + "엘리베이터에 멈춤 \(name)")
            }
        }
    }

    static func poolParty() {
        print("— pool-party: 저녁 + 씨앗 → 디제이가 1층 문 · 엘리베이터로 옥상에 와 부스 · 미러볼 · 박자 조명 → 쉬는 직원만 춤 · 외침(일하는 직원은 책상) → 약 90초 뒤 접고 엘리베이터로 떠남")
        Variety.shared.seed(84)
        let harness = SceneHarness(sceneTime: SceneHarness.sceneTime("2026-10-16T21:30"))
        harness.scene.updateWeather()
        let scene = harness.scene
        let idle: [AgentSession] = (0..<6).map { index in session(Int32(33_001 + index), "알파", .idle, order: Double(index)) }
        var desks: [AgentSession] = (0..<3).map { index in session(Int32(33_101 + index), "베타", .working, order: Double(10 + index)) }
        desks.append(session(33_201, "베타", .waiting, order: 20))
        let sleepy = session(33_301, "감마", .longIdle, order: 30)
        harness.sessions = idle + desks + [sleepy]
        harness.feed()
        let watch = PartyWatch()
        let probe: (TimeInterval) -> Void = { now in watch.observe(scene, desks: desks, now: now) }
        // ① 시작: 씨앗이 정한 때에 디제이가 1층 문으로 들어와 엘리베이터로 옥상 부스 자리까지 → 무대 설치 → 음악
        let started = runUntil(harness, timeout: 150, probe: probe) { scene.partyPhaseName == "playing" }
        check(started != nil, "저녁 21:30 · 씨앗 84 → 파티 시작까지 " + (started.map { String(format: "%.1f초", $0) } ?? "150초 안에 안 열림") + " · 단계 \(scene.partyLog)")
        guard started != nil else { return }
        let dj = scene.djProbe
        check(watch.djFloors == ["1층", "옥상"] && dj.floor == scene.currentLayout.roofIndex && abs(dj.x - PoolDeck.djX) <= 1,
              "디제이: 1층 문 → 엘리베이터 → 옥상 부스 뒤(x \(Int(dj.x))) · 보인 층 \(watch.djFloors)")
        // ② 공연(약 90초): 부스 · 미러볼 · 박자 조명 · 쉬는 직원만 춤 · 외침 · 일하는 직원은 책상.
        //    45초쯤 새 팀(8명)이 출근해 층이 하나 늘면 옥상이 80px 올라간다 — 디제이 · 무대 · 춤추는 직원이 새 바닥선을 따라가야 한다(감시가 0.25초마다 본다).
        var stage = false, ball = false, party = false, captured = false, grew = false
        let floorsBefore = scene.currentLayout.floors.count, roofBefore = scene.line(scene.currentLayout.roofIndex)
        let delta: [AgentSession] = (0..<8).map { index in session(Int32(33_401 + index), "델타", .working, order: Double(40 + index)) }
        let playStart = harness.elapsed
        let played = runUntil(harness, timeout: 140, probe: { now in
            probe(now)
            guard scene.partyPhaseName == "playing" else { return }
            let deck = scene.poolDeckNode
            stage = stage || deck.stageVisible
            ball = ball || deck.ballHanging
            party = party || deck.strandParty
            // 캡처: 20초 넘게 지나 둘 넘게 춤추고, 누군가 외치는 중일 때(말풍선까지 보이게)
            if !captured, now - playStart >= 20, scene.partyDancerKeys.count >= 2, scene.partyDancerKeys.contains(where: { scene.bubbles[$0] != nil }) {
                captured = true
                shot(harness, "pool-party", rect: roofRect(scene))
                shot(harness, "pool-party-close", rect: roofCloseRect(scene))
            }
            if !grew, now - playStart >= 45 {
                grew = true
                harness.sessions += delta
                harness.feed()
            }
        }) { scene.partyPhaseName != "playing" }
        let seconds = harness.elapsed - playStart
        check(played != nil && abs(seconds - PartyTiming.playSeconds) <= 2.5, String(format: "공연 %.1f초(약 %.0f초)", seconds, PartyTiming.playSeconds))
        check(stage && ball && party && scene.poolDeckNode.beats >= Int(PartyTiming.playSeconds / PartyTiming.beat) - 4,
              "부스 \(stage) · 미러볼 \(ball) · 줄전구 파티 색 \(party) · 박자 \(scene.poolDeckNode.beats)번")
        let roofAfter = scene.line(scene.currentLayout.roofIndex)
        check(grew && scene.currentLayout.floors.count == floorsBefore + 1 && roofAfter == roofBefore + CGFloat(BuildingLayout.teamHeight) && abs(scene.poolDeckNode.position.y - roofAfter) < 0.5,
              "공연 중 새 팀 8명 출근 → 층 \(floorsBefore) → \(scene.currentLayout.floors.count)개 · 옥상 바닥선 \(Int(roofBefore)) → \(Int(roofAfter)) · 무대가 따라감")
        let idleKeys = Set(idle.map(\.id))
        let cheers = scene.partyCheers
        check(watch.dancers.count >= 2 && watch.dancers.isSubset(of: idleKeys) && scene.partyMaxDancers >= 2,
              "춤: 쉬는 직원만 \(watch.dancers.count)명(동시 최대 \(scene.partyMaxDancers)명) · 일하는 · 기다리는 · 오래 쉰 직원 0명")
        check(!cheers.isEmpty && Set(cheers).isSubset(of: watch.dancers), "춤추는 직원이 돌아가며 외침 \(cheers.count)번 · 디제이 자막 \(scene.eventCaptions.filter { $0.contains("DJ 파티") }.count)개")
        // ③ 정리 → 엘리베이터로 내려가 문으로 나감 · 무대 치움 · 다들 원래 자세
        let gone = runUntil(harness, timeout: 60, probe: probe) { scene.partyPhaseName == "idle" }
        check(gone != nil && !scene.djProbe.present && !scene.poolDeckNode.stageVisible && !scene.poolDeckNode.ballHanging && !scene.poolDeckNode.strandParty,
              "끝: 장비를 접고 떠남 " + (gone.map { String(format: "%.1f초", $0) } ?? "60초 안에 못 끝남") + " · 디제이 \(scene.djProbe.present ? "남음" : "없음") · 무대 \(scene.poolDeckNode.stageVisible ? "남음" : "치움")")
        check(watch.djFloors == ["1층", "옥상", "1층"], "디제이: 옥상 → 엘리베이터 → 1층 문 · 보인 층 \(watch.djFloors)")
        harness.run(2, probe: probe)
        let lying = idle.compactMap { scene.worker(for: $0.id) }.filter { worker in
            guard case .rest(let spot) = worker.place, spot.kind == .lounger || spot.kind == .beanbag, worker.route == nil else { return false }
            return abs(worker.position.y - (scene.line(worker.floorIndex) + CGFloat(spot.yOffset))) <= 0.5
        }.count
        check(scene.partyDancerKeys.isEmpty && idle.allSatisfy { scene.worker(for: $0.id)?.busy == false }, "파티 뒤: 춤 0명 · 붙잡힌 직원 0명 · 선베드 · 빈백 직원 \(lying)명은 다시 누움")
        check(watch.problems.isEmpty, "뜬 사람 · 엘리베이터에 멈춘 사람 · 책상을 떠난 일하는 직원 없음" + (watch.problems.isEmpty ? "" : " · \(watch.problems.prefix(3))"))
        noSafetyNet(harness)
        // ④ 한 저녁에 한 번: 끝난 뒤 60초 더 돌아도 다시 열리지 않는다
        harness.run(60, probe: probe)
        check(scene.partyPhaseName == "idle" && scene.partyLog.filter { $0 == "arriving" }.count == 1, "한 저녁에 한 번: 끝난 뒤 60초 동안 다시 안 열림(시작 \(scene.partyLog.filter { $0 == "arriving" }.count)번)")
        // ⑤ 감사가 시작되면 일찍 접는다: 파티를 바로 한 번 더 열고(일정과 무관하게) 공연 중 감사관이 들어오면 → 접고 떠남 · 아무도 남지 않음
        scene.startParty()
        let replay = runUntil(harness, timeout: 40, probe: probe) { scene.partyPhaseName == "playing" }
        scene.auditorEnter()
        var heardBye = false
        let wrapped = runUntil(harness, timeout: 3, probe: { _ in heardBye = heardBye || scene.djSaying == "감사 떴다! 파티 끝!" }) { scene.partyPhaseName != "playing" }
        let left = runUntil(harness, timeout: 40, probe: { now in probe(now); heardBye = heardBye || scene.djSaying == "감사 떴다! 파티 끝!" }) { scene.partyPhaseName == "idle" }
        check(replay != nil && wrapped != nil && heardBye && left != nil && !scene.djProbe.present && !scene.poolDeckNode.stageVisible && scene.partyDancerKeys.isEmpty,
              "감사 시작 → 파티를 " + (wrapped.map { String(format: "%.1f초", $0) } ?? "3초 안에 못") + " 만에 접고 디제이가 떠남(\"감사 떴다! 파티 끝!\" \(heardBye)) · " + (left.map { String(format: "%.1f초", $0) } ?? "40초 안에 못 떠남"))
        check(watch.problems.isEmpty, "감사로 일찍 끝나도 뜬 사람 · 멈춘 사람 없음" + (watch.problems.isEmpty ? "" : " · \(watch.problems.prefix(3))"))
        // ⑥ 점심(같은 씨앗 · 13시)엔 열리지 않는다
        Variety.shared.seed(84)
        let noon = SceneHarness(sceneTime: SceneHarness.sceneTime("2026-10-16T13:00"))
        noon.sessions = idle + desks
        noon.feed()
        noon.run(60)
        check(noon.scene.partyPhaseName == "idle" && noon.scene.partyLog.isEmpty && !noon.scene.djProbe.present, "점심 13시: 파티 없음(단계 기록 \(noon.scene.partyLog.count)개)")
    }
}
