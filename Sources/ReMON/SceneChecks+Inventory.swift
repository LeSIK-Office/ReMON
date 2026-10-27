import AppKit
import ReMONCore
import SpriteKit

// 디스크 저장고 꼬리표 진열 · 재고 조사(10-25 대표 지시 "여러 명 투입돼서 디스크 박스 내려놓고 분리하고, 내용 보여 주고,
// 삭제할 거 선택하면 다른 건 다시 올려놓고 삭제하는 것만 박스 까서 버려").
// 선반 칸 수는 그대로 실제 사용량(짐꾼)이고 꼬리표 색은 바이트 비율 · 최소 1칸. 재고 조사는 어떤 순서로 불러도 깨지지 않고,
// 사람은 늘 바닥선 위 · 엘리베이터 칸에 2초 넘게 서 있지 않음 · 상자는 선반 · 탁자 · 짐판 위.

extension SceneChecks {
    static let stockGiB = UInt64(Fmt.gib)

    /// 1000GB 디스크 절반(500GB) 사용 · 꼬리표 넷(캐시 300 · 재생성 100 · Docker 50 · 휴지통 10, 나머지 40GB는 '기타').
    static func stockGroups() -> [DiskStockGroup] {
        [DiskStockGroup(tag: .cache, bytes: 300 * stockGiB, reclaimable: 120 * stockGiB),
         DiskStockGroup(tag: .regenerable, bytes: 100 * stockGiB, reclaimable: 0),
         DiskStockGroup(tag: .docker, bytes: 50 * stockGiB, reclaimable: 50 * stockGiB),
         DiskStockGroup(tag: .trash, bytes: 10 * stockGiB, reclaimable: 10 * stockGiB)]
    }

    /// 캐시 묶음 항목 15개(큰 순서).
    static func cacheItems() -> [DiskStockItem] {
        let names = ["com.apple.Safari", "node-gyp", "pip", "Homebrew", "JetBrains", "Yarn", "go-build", "ms-playwright", "Google", "CocoaPods", "typescript", "huggingface", "electron", "Spotify", "Slack"]
        let sizes: [Double] = [40, 32, 28, 24, 20, 18, 16, 14, 12, 10, 8, 6, 0.8, 0.5, 0.3]
        return zip(names, sizes).map { name, gb in
            DiskStockItem(path: "/Users/me/Library/Caches/\(name)", name: name, bytes: UInt64(gb * Fmt.gib), tag: .cache, marked: false)
        }
    }

    static func stockHarness(seed: UInt64) -> SceneHarness {
        Variety.shared.seed(seed)
        let harness = SceneHarness()
        harness.sessions = [session(31_001, "알파", .working, order: 0), session(31_002, "베타", .working, order: 1)]
        harness.feed()
        harness.scene.setDiskStock(stockGroups())
        harness.run(2)
        return harness
    }

    /// 재고 조사 인력 관찰(공중 부양 · 엘리베이터 끼임) + 엘리베이터에서 나타났는가 · 1층에 올라간 적이 있는가.
    @MainActor
    final class CrewWatch {
        let staff = StaffWatch()
        var fromShaft = false
        var sawLobby = false
        var said: [String] = []

        func observe(_ scene: OfficeScene, now: TimeInterval) {
            for (name, probe) in scene.inventoryProbes {
                staff.observe(probe, name, layout: scene.currentLayout, now: now)
                if probe.present, probe.alpha > 0.1, abs(probe.x - CGFloat(BuildingLayout.elevatorX)) <= 6 { fromShaft = true }
                if probe.present, probe.alpha > 0.5, probe.floor == scene.currentLayout.lobbyIndex { sawLobby = true }
            }
            for text in scene.inventorySaying where said.last != text && !said.contains(text) { said.append(text) }
        }
    }

    /// 선반 상자가 모두 제 칸 자리(선반 단 위)에 있는가.
    static func shelfSeated(_ scene: OfficeScene) -> Bool {
        let shelves = scene.diskShelvesNode
        return shelves.slotProbes.enumerated().allSatisfy { index, slot in slot.point == DiskShelves.slotPoint(index, floorLine: shelves.floorLine) }
    }

    /// 보이는 디스크 글자끼리 · 기계실 '디스크 저장고' 배지 · 재고 인력 말풍선과 겹치지 않는가(겹치면 그 글자 쌍).
    static func labelOverlaps(_ scene: OfficeScene) -> [String] {
        let frames = scene.diskLabelFrames
        var hits: [String] = []
        for i in frames.indices { for j in frames.indices where j > i && frames[i].frame.insetBy(dx: 1, dy: 1).intersects(frames[j].frame.insetBy(dx: 1, dy: 1)) {
            hits.append("\(frames[i].text)↔\(frames[j].text)")
        } }
        let obstacles = (scene.machineBadgeFrame(.disk).map { [("배지", $0)] } ?? []) + scene.inventoryBubbleFrames.map { ("말풍선", $0) }
        for label in frames { for obstacle in obstacles where label.frame.insetBy(dx: 1, dy: 1).intersects(obstacle.1.insetBy(dx: 1, dy: 1)) {
            hits.append("\(label.text)↔\(obstacle.0)")
        } }
        return hits
    }

    // MARK: 꼬리표별 진열

    static func diskStock() {
        print("— disk-stock: 선반 칸 = 실제 사용량 × 48 그대로 · 꼬리표별 색 비율(가장 큰 나머지 · 최소 1칸) · 치울 수 있는 몫은 점선 · 가까이서만 꼬리표")
        let harness = stockHarness(seed: 81)
        let scene = harness.scene
        let shelves = scene.diskShelvesNode
        let warehouse = scene.warehouseNode
        // 500GB 사용 · 24칸: 캐시 14.4 · 재생성 4.8 · Docker 2.4 · 휴지통 0.48→1(최소) · 기타 1.92 → 14 · 5 · 2 · 1 · 2
        let expected: [(DiskTag?, Int, Int)] = [(.cache, 14, 6), (.regenerable, 5, 0), (.docker, 2, 2), (.trash, 1, 1), (nil, 2, 0)]
        let got = expected.map { "\($0.0?.shelfLabel ?? "기타") \(shelves.allocated($0.0))(점선 \(shelves.dashedCount($0.0)))" }
        check(expected.allSatisfy { shelves.allocated($0.0) == $0.1 && shelves.dashedCount($0.0) == $0.2 } && shelves.visibleTotal == 24 && warehouse.shown[.disk] == 24,
              "500GB/1000GB(24칸) → \(got.joined(separator: " · ")) · 보이는 상자 \(shelves.visibleTotal) = 짐꾼 칸 \(warehouse.shown[.disk] ?? -1)")
        // 바이트 비율에서 1칸 넘게 벗어난 묶음 없음(최소 1칸 묶음 빼고)
        let used = 500.0
        let off = stockGroups().filter { abs(Double(shelves.allocated($0.tag)) - Double($0.bytes) / Fmt.gib / used * 24) >= 1 && shelves.allocated($0.tag) > 1 }
        check(off.isEmpty, "꼬리표 칸 수가 바이트 비율(× 24)에서 1칸 안: 벗어난 묶음 \(off.map(\.tag.shelfLabel))")
        // 칸 순서: 꼬리표 고정 순서대로 한 덩어리씩(색이 섞이지 않음) · 상자는 제 칸에
        let tags = shelves.slotProbes.map(\.tag)
        var runs: [DiskTag?] = []
        for tag in tags where runs.last != tag { runs.append(tag) }
        check(runs == [.cache, .regenerable, .docker, .trash, nil] && shelfSeated(scene), "칸 순서 = 꼬리표 덩어리 \(runs.map { $0?.shelfLabel ?? "기타" }) · 상자 모두 선반 단 위")
        // 꼬리표 글자: 가까이 다가가면 보이고(겹침 없음), 전체 보기에서는 숨김
        scene.focus(.all, animated: false)
        harness.run(0.2)
        let farLabels = scene.diskLabelFrames.count
        let stage = MachineLayout.rect(.disk, floor: scene.currentLayout.floors[0]).insetBy(dx: -20, dy: -6)
        scene.frameCamera(on: stage)
        harness.run(0.2)
        let near = scene.diskLabelFrames.map(\.text)
        let overlaps = labelOverlaps(scene)
        check(farLabels == 0 && near.contains("캐시") && near.contains("재생성") && overlaps.isEmpty,
              "꼬리표 글자: 전체 보기 \(farLabels)개 · 가까이 \(near) · 겹침 \(overlaps)")
        shot(harness, "disk-stock-shelves", rect: stage)
        // 사용량이 늘면(50 → 60%) 짐꾼이 한 칸씩 늘리고, 색 비율은 새 칸 수(29)로 다시 나눈다.
        harness.diskUsed = 0.6
        let grown = runUntil(harness, timeout: 60) { warehouse.shown[.disk] == 29 && !warehouse.busy }
        let sum = shelves.plan.reduce(0) { $0 + $1.count }
        check(grown != nil && sum == 29 && shelves.visibleTotal == 29 && shelves.allocated(.trash) >= 1 && shelfSeated(scene),
              "사용량 60%: 짐꾼이 29칸으로(\(grown.map { String(format: "%.1f초", $0) } ?? "60초 안에 못 맞춤")) · 묶음 칸 합 \(sum) · 보이는 상자 \(shelves.visibleTotal) · 휴지통 \(shelves.allocated(.trash))칸")
        // 꼬리표가 많아 칸이 모자라면(4%: 2칸 · 꼬리표 넷) 큰 꼬리표부터 1칸씩 — 칸 합은 실제 사용량 그대로.
        let tight = DiskStockPlan.allocate(total: 2, groups: stockGroups(), used: 500 * stockGiB)
        check(tight.reduce(0) { $0 + $1.count } == 2 && tight.first { $0.tag == .cache }?.count == 1 && tight.first { $0.tag == .regenerable }?.count == 1,
              "칸 2개 · 꼬리표 넷 → 큰 꼬리표 둘만 1칸씩: \(tight.filter { $0.count > 0 }.map { "\($0.tag?.shelfLabel ?? "기타") \($0.count)" })")
        noSafetyNet(harness)
    }

    // MARK: 재고 조사 — 시작 · 열기 · 표시 · 실행 · 마침

    static func inventoryFlow() {
        print("— inventory-flow: 시작(인력 3명 · 묶음 → 탁자) → 열기(12개 + '+N') → 표시(스티커) → 실행(보관 → 선반 · 휴지통 손수레 → 1층 금고 · 삭제 → 압축기 · 정리 명령 → 축소) → 마침(실측 외침 · 퇴장)")
        let harness = stockHarness(seed: 82)
        let scene = harness.scene
        let inventory = scene.inventoryNode
        let shelves = scene.diskShelvesNode
        let warehouse = scene.warehouseNode
        let watch = CrewWatch()
        let observe: (TimeInterval) -> Void = { now in watch.observe(scene, now: now) }
        let stage = scene.inventoryStageRect

        scene.frameCamera(on: stage)
        let idleCost = harness.measureUpdateCost(seconds: 3)
        // ① 시작: 엘리베이터로 3명 · 탁자 · 묶음 넷이 탁자로(선반은 빈칸) · 자막
        scene.inventoryBegin(groups: stockGroups())
        let caption = scene.eventCaptions.last ?? ""
        let ready = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .table }
        harness.run(0.6, probe: observe)
        let pulled = [DiskTag.cache, .regenerable, .docker, .trash].map { shelves.visible($0) }
        check(caption == "디스크 정비 · 재고 조사" && ready != nil && watch.fromShaft && inventory.hands.count == 3 && inventory.tableVisible,
              "시작: 자막 '\(caption)' · 인력 \(inventory.hands.count)명이 지하 엘리베이터에서 나타남(\(watch.fromShaft)) · 탁자 펼침 · " + (ready.map { String(format: "%.1f초", $0) } ?? "30초 안에 탁자 단계 아님"))
        check(inventory.visibleStackCount == 4 && Set(inventory.stackTags) == [.cache, .regenerable, .docker, .trash] && pulled.allSatisfy { $0 == 0 }
              && shelves.visible(nil) == 2 && inventory.tableSeated && warehouse.holdDisk,
              "묶음 넷이 탁자 위(\(inventory.stackTags.map(\.shelfLabel))) · 선반의 그 꼬리표 상자는 빈칸 \(pulled) · '기타' 2칸은 그대로 · 상자는 탁자 윗면에 · 짐꾼 디스크 운반 보류")

        // ② 열기: 캐시 15개 → 작은 상자 12개 + '+3' 판 · 나머지 묶음 셋은 쌓인 채(오른쪽 끝에 촘촘히)
        let items = cacheItems()
        scene.inventoryOpen(group: .cache, items: items)
        let opened = runUntil(harness, timeout: 15, probe: observe) { inventory.itemCount == 12 && inventory.tableSeated }
        harness.run(1.0, probe: observe)
        check(opened != nil && inventory.overflow == 3 && scene.diskOverflowText == "+3" && inventory.visibleStackCount == 3 && inventory.openTag == .cache,
              "열기: 항목 상자 \(inventory.itemCount)개 + 판 '\(scene.diskOverflowText ?? "없음")' · 쌓인 채인 묶음 \(inventory.visibleStackCount)개")
        scene.frameCamera(on: stage)
        harness.run(0.3, probe: observe)
        let names = scene.diskLabelFrames.map(\.text)
        let overlapsOpen = labelOverlaps(scene)
        check(names.contains("com.apple… · 40.0GB · 캐시") && names.filter { $0 == "보관" }.count >= 8 && overlapsOpen.isEmpty,
              "가까이: 항목 이름표(이름 · 크기 · 꼬리표) · 스티커 글자 '보관' \(names.filter { $0 == "보관" }.count)개 · 겹침 \(overlapsOpen)")
        shot(harness, "inventory-open", rect: stage)
        // 덜 다가갔을 때(가까이 보기 문턱 바로 위 · 배율 약 3 — 그보다 멀면 장면 규칙대로 글자를 숨긴다): 자리가 모자란 이름표는 숨겨도 겹치지는 않는다.
        let wide = CGRect(x: stage.midX - 200, y: stage.minY, width: 400, height: stage.height)
        scene.frameCamera(on: wide)
        harness.run(0.2, probe: observe)
        let wideOverlaps = labelOverlaps(scene)
        let wideCount = scene.diskLabelFrames.count
        check(wideOverlaps.isEmpty && scene.isZoomedIn && wideCount >= 12, "덜 다가감(배율 \(String(format: "%.1f", scene.pointsPerPixel))): 글자 \(wideCount)개 보임 · 겹침 \(wideOverlaps)")
        shot(harness, "inventory-open-wide", rect: wide)
        scene.frameCamera(on: stage)
        harness.run(0.2, probe: observe)
        let openCost = harness.measureUpdateCost(seconds: 3)
        print(String(format: "  장면 갱신 비용(SKRenderer.update 한 프레임, 그리기 제외) 중앙값: 재고 조사 전 %.1fµs · 탁자 펼침(항목 12 · 이름표 · 스티커, 가까이) %.1fµs",
                     idleCost.median * 1e6, openCost.median * 1e6))

        // ③ 표시: 셋은 폐기(빨강), 하나는 표시했다가 되돌림(초록)
        for item in items.prefix(4) { scene.inventoryMark(path: item.path, marked: true) }
        scene.inventoryMark(path: items[3].path, marked: false)
        harness.run(0.4, probe: observe)
        let stickers = items.prefix(5).map { inventory.sticker($0.path) == true }
        let stickerWords = scene.diskLabelFrames.map(\.text)
        check(stickers == [true, true, true, false, false] && stickerWords.filter { $0 == "폐기" }.count == 3,
              "표시: 폐기 스티커 \(stickers) · 글자 '폐기' \(stickerWords.filter { $0 == "폐기" }.count)개")
        shot(harness, "inventory-stickers", rect: stage)

        // ④ 실행: 휴지통 2(펼친 것) · 삭제 2 + 목록 밖 1 · Docker 정리 명령
        let crushesBefore = inventory.compactor.crushes
        let vaultBefore = scene.vaultNode.log.count
        scene.inventoryExecute(trash: [items[0].path, items[1].path], delete: [items[2].path, items[3].path, "/Users/me/.cache/unseen"], prune: [.docker])
        let execCaption = scene.eventCaptions.last ?? ""
        var maxLoad = 0, tagText: String?, executeShot = false
        var compactorWhileTruck = false
        let executed = runUntil(harness, timeout: 40, probe: { now in
            observe(now)
            maxLoad = max(maxLoad, inventory.truckLoad)
            if let text = scene.diskTruckTagText { tagText = text }
            if inventory.compactor.leverDown, inventory.truckHand.map({ !$0.errand }) ?? false { compactorWhileTruck = true }
            if !executeShot, inventory.compactor.leverDown, inventory.truckHand != nil {
                executeShot = true
                shot(harness, "inventory-execute", rect: stage.insetBy(dx: -50, dy: 0))
            }
        }) { inventory.phase == .executed }
        check(execCaption == "디스크 정비 · 휴지통 2 · 삭제 3 · 정리 명령 1" && executed != nil,
              "실행: 자막 '\(execCaption)' · 지하 일 끝 " + (executed.map { String(format: "%.1f초", $0) } ?? "40초 안에 못 끝남"))
        check(maxLoad >= 2 && tagText == "되돌릴 수 있음 · 2개", "휴지통: 손수레 짐 \(maxLoad)상자 · 꼬리표 '\(tagText ?? "없음")'")
        check(inventory.compactor.crushes - crushesBefore == 3 && compactorWhileTruck, "삭제: 압축기 \(inventory.compactor.crushes - crushesBefore)번(펼친 2 + 목록 밖 1) · 손수레가 지하에 있는 동안 압축(한 장면) \(compactorWhileTruck)")
        // 보관은 선반으로: 나머지 묶음은 모두 · 캐시는 치운 바이트(124GB / 300GB)만큼 빈칸(14칸 중 6칸)
        let kept = [(DiskTag.regenerable, 5), (.docker, 2), (.trash, 1), (.cache, 8)].map { (tag: $0.0, want: $0.1, got: shelves.visible($0.0)) }
        check(kept.allSatisfy { $0.want == $0.got } && inventory.visibleStackCount == 0 && inventory.itemCount == 0,
              "보관 → 선반: \(kept.map { "\($0.tag.shelfLabel) \($0.got)/\($0.want)" }) · 탁자 비움")
        let pruned = runUntil(harness, timeout: 20, probe: observe) { shelves.isShrunk(.docker) && inventory.technician == nil }
        check(pruned != nil && !shelves.isShrunk(.cache), "정리 명령: 기술자가 단말기 수레로 와서 친 뒤 Docker 상자 축소 · 기술자 퇴장")
        let delivered = runUntil(harness, timeout: 30, probe: observe) { scene.vaultNode.log.dropFirst(vaultBefore).contains("건네받음 · 2") && inventory.truckHand == nil && inventory.couriers.isEmpty }
        check(delivered != nil && watch.sawLobby, "손수레: 엘리베이터 → 1층 기록 보관소 앞 → 기록관 '건네받음 · 2' → 엘리베이터로 퇴장(1층에 보임 \(watch.sawLobby))")

        // ⑤ 마침: 앱이 다시 잰 값(사용량 50 → 45% · 꼬리표 새로) → 선반 실측 · "실측 +4.6GB" · 엘리베이터로 퇴장
        harness.diskUsed = 0.45
        harness.feed()
        scene.setDiskStock([DiskStockGroup(tag: .cache, bytes: 176 * stockGiB, reclaimable: 40 * stockGiB),
                            DiskStockGroup(tag: .regenerable, bytes: 100 * stockGiB, reclaimable: 0),
                            DiskStockGroup(tag: .docker, bytes: 20 * stockGiB, reclaimable: 0),
                            DiskStockGroup(tag: .trash, bytes: 82 * stockGiB, reclaimable: 82 * stockGiB)])
        let heldBefore = warehouse.shown[.disk] ?? -1
        scene.inventoryFinish(measuredFreed: UInt64(4.6 * Fmt.gib))
        let finishCaption = scene.eventCaptions.last ?? ""
        let shouted = runUntil(harness, timeout: 20, probe: observe) { watch.said.contains("실측 +4.6GB") }
        if shouted != nil {
            harness.run(0.5, probe: observe)
            shot(harness, "inventory-finish", rect: stage.insetBy(dx: -30, dy: 0))
        }
        let remeasured = DiskTag.allCases.allSatisfy { shelves.outCount($0) == 0 } && shelves.shrunk.isEmpty && shelves.visibleTotal == 22 && warehouse.shown[.disk] == 22
        check(heldBefore == 24 && shouted != nil && remeasured && finishCaption == "디스크 정비 · 실측 +4.6GB",
              "마침: 실행 동안 칸 보류(\(heldBefore)) → 실측으로 \(warehouse.shown[.disk] ?? -1)칸(실제 45% = 22) · 빈칸 · 축소 풀림 · 외침 \(watch.said.filter { $0.hasPrefix("실측") }) · 자막 '\(finishCaption)'")
        let gone = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .idle && !inventory.anyoneHere }
        check(gone != nil && !inventory.tableVisible && !warehouse.holdDisk && shelfSeated(scene),
              "퇴장: 모두 엘리베이터로 · 탁자 접음 · 짐꾼 운반 다시 · 상자 제 칸 " + (gone.map { String(format: "%.1f초", $0) } ?? "30초 안에 못 나감"))
        print("  기록: \(inventory.log.suffix(14).joined(separator: " → "))")
        print("  말: \(watch.said)")
        watch.staff.report("재고 조사 인력", particle: "이")
        noSafetyNet(harness)
    }

    // MARK: 취소 · 0 실측

    static func inventoryCancel() {
        print("— inventory-cancel: 연 채로 취소 → 모두 선반으로 · 퇴장 / 아무것도 안 치우고 마침 0 → '줄어든 게 없어요'")
        let harness = stockHarness(seed: 83)
        let scene = harness.scene
        let inventory = scene.inventoryNode
        let shelves = scene.diskShelvesNode
        let watch = CrewWatch()
        let observe: (TimeInterval) -> Void = { now in watch.observe(scene, now: now) }
        scene.inventoryBegin(groups: stockGroups())
        _ = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .table }
        scene.inventoryOpen(group: .cache, items: cacheItems())
        harness.run(2, probe: observe)
        scene.inventoryMark(path: cacheItems()[0].path, marked: true)
        harness.run(0.5, probe: observe)
        scene.inventoryCancel()
        let restored = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .idle && !inventory.anyoneHere }
        let all = [DiskTag.cache, .regenerable, .docker, .trash].map { (shelves.visible($0), shelves.allocated($0)) }
        check(restored != nil && all.allSatisfy { $0.0 == $0.1 } && shelves.visibleTotal == 24 && inventory.visibleStackCount == 0 && inventory.itemCount == 0 && !scene.warehouseNode.holdDisk,
              "취소: 모든 상자 선반으로 \(all.map { "\($0.0)/\($0.1)" }) · 보이는 상자 \(shelves.visibleTotal) · 탁자 비움 · 인력 퇴장 " + (restored.map { String(format: "%.1f초", $0) } ?? "30초 안에 못 끝남"))
        check(DiskTag.allCases.allSatisfy { shelves.outCount($0) == 0 } && shelfSeated(scene), "취소 뒤 빈칸 없음 · 상자 제 칸")
        // 아무것도 안 치움 → 실행(빈 목록) → 마침 0
        watch.said = []
        scene.inventoryBegin(groups: stockGroups())
        _ = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .table }
        scene.inventoryExecute(trash: [], delete: [], prune: [])
        _ = runUntil(harness, timeout: 20, probe: observe) { inventory.phase == .executed }
        scene.inventoryFinish(measuredFreed: 0)
        let zero = runUntil(harness, timeout: 20, probe: observe) { watch.said.contains("줄어든 게 없어요") }
        let left = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .idle && !inventory.anyoneHere }
        check(zero != nil && left != nil && shelves.visibleTotal == 24 && (scene.eventCaptions.last ?? "") == "디스크 정비 · 줄어든 게 없습니다",
              "마침 0: '줄어든 게 없어요' · 선반 그대로 \(shelves.visibleTotal)칸 · 자막 '\(scene.eventCaptions.last ?? "")' · 퇴장")
        watch.staff.report("재고 조사 인력", particle: "이")
        noSafetyNet(harness)
    }

    // MARK: 안전망

    static func inventorySafety() {
        print("— inventory-safety: 시작만 하고 앱이 잊음 → 마지막 호출 180초 뒤 안전망이 끝냄 / 실행 뒤 마침을 잊음 → 실측하고 퇴장")
        let harness = stockHarness(seed: 84)
        let scene = harness.scene
        let inventory = scene.inventoryNode
        let shelves = scene.diskShelvesNode
        let watch = CrewWatch()
        let observe: (TimeInterval) -> Void = { now in watch.observe(scene, now: now) }
        scene.inventoryBegin(groups: stockGroups())
        _ = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .table }
        scene.inventoryOpen(group: .cache, items: cacheItems())
        let lastCall = harness.elapsed
        var endedAt: TimeInterval?
        harness.run(200) { now in
            observe(now)
            if endedAt == nil, inventory.log.contains(where: { $0.hasPrefix("안전망 · 180") }) { endedAt = now - lastCall }
        }
        check(endedAt.map { $0 >= 179 && $0 <= 183 } ?? false && inventory.phase == .idle && !inventory.anyoneHere && shelves.visibleTotal == 24 && !scene.warehouseNode.holdDisk,
              "시작 · 열기만 하고 잊음: 마지막 호출 " + (endedAt.map { String(format: "%.0f초", $0) } ?? "200초 안에 안 끝남") + " 뒤 안전망 → 모두 선반으로 · 퇴장(보이는 상자 \(shelves.visibleTotal))")
        // 실행 뒤 마침을 잊음: 사용량이 줄었다(50 → 40%) — 안전망이 실측(20칸)으로 맞추고 퇴장
        scene.inventoryBegin(groups: stockGroups())
        _ = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .table }
        scene.inventoryOpen(group: .cache, items: cacheItems())
        harness.run(2, probe: observe)
        scene.inventoryExecute(trash: [], delete: [cacheItems()[0].path], prune: [])
        harness.diskUsed = 0.4
        harness.run(190, probe: observe)
        check(inventory.phase == .idle && !inventory.anyoneHere && scene.warehouseNode.shown[.disk] == 19 && DiskTag.allCases.allSatisfy { shelves.outCount($0) == 0 },
              "실행 뒤 마침을 잊음: 안전망이 실측으로 \(scene.warehouseNode.shown[.disk] ?? -1)칸(실제 40% = 19) · 빈칸 풀림 · 퇴장")
        watch.staff.report("재고 조사 인력", particle: "이")
        noSafetyNet(harness)
    }

    // MARK: 순서가 엉켜도

    static func inventoryOrder() {
        print("— inventory-order: 시작 전 표시 · 비었을 때 마침/실행/열기 · 시작 두 번 · 취소 두 번 · 마침 도중 시작 — 깨지지 않고 늘 비워진다")
        let harness = stockHarness(seed: 85)
        let scene = harness.scene
        let inventory = scene.inventoryNode
        let shelves = scene.diskShelvesNode
        let watch = CrewWatch()
        let observe: (TimeInterval) -> Void = { now in watch.observe(scene, now: now) }
        let items = cacheItems()
        func settle(_ timeout: TimeInterval = 40) -> Bool { runUntil(harness, timeout: timeout, probe: observe) { inventory.phase == .idle && !inventory.anyoneHere } != nil }

        // ① 시작 전 표시: 아무도 오지 않는다
        scene.inventoryMark(path: items[0].path, marked: true)
        harness.run(2, probe: observe)
        check(inventory.phase == .idle && !inventory.anyoneHere, "시작 전 표시 → 아무도 안 옴")
        // ② 비었을 때 마침: 한 명이 내려와 외치고 나간다
        watch.said = []
        scene.inventoryFinish(measuredFreed: stockGiB)
        let solo = runUntil(harness, timeout: 25, probe: observe) { watch.said.contains("실측 +1.0GB") }
        check(solo != nil && settle(), "비었을 때 마침 → 한 명이 지하로 내려와 '실측 +1.0GB' → 퇴장")
        // ③ 비었을 때 실행: 인력이 내려와 묶음을 내린 뒤 실행(압축) → 실행 뒤 취소 = 실측하고 퇴장
        let crushes = inventory.compactor.crushes
        scene.inventoryExecute(trash: [], delete: [items[5].path], prune: [])
        let run = runUntil(harness, timeout: 50, probe: observe) { inventory.phase == .executed }
        scene.inventoryCancel()
        check(run != nil && inventory.compactor.crushes == crushes + 1 && settle() && shelves.visibleTotal == 24,
              "비었을 때 실행 → 내려와서 압축 \(inventory.compactor.crushes - crushes)번 → 취소(실행 뒤) = 실측 · 퇴장(상자 \(shelves.visibleTotal))")
        // ④ 비었을 때 열기 · 시작 두 번 · 다른 묶음 열기 · 취소 두 번
        scene.inventoryOpen(group: .cache, items: items)
        scene.inventoryBegin(groups: stockGroups())
        scene.inventoryBegin(groups: stockGroups())
        let openReady = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .table && inventory.itemCount == 12 }
        check(openReady != nil && inventory.hands.count == 3, "비었을 때 열기 + 시작 두 번 → 인력 \(inventory.hands.count)명(겹친 출동 없음) · 도착하면 캐시를 펼침")
        scene.inventoryOpen(group: .docker, items: [DiskStockItem(path: "/var/lib/docker/overlay2", name: "overlay2", bytes: 40 * stockGiB, tag: .docker, marked: true)])
        harness.run(2.5, probe: observe)
        check(inventory.openTag == .docker && inventory.itemCount == 1 && inventory.sticker("/var/lib/docker/overlay2") == true && inventory.visibleStackCount == 3,
              "다른 묶음 열기 → 캐시는 닫혀 다시 쌓이고 Docker 1개(폐기 스티커) · 쌓인 묶음 \(inventory.visibleStackCount)")
        scene.inventoryCancel()
        scene.inventoryCancel()
        check(settle() && shelves.visibleTotal == 24 && DiskTag.allCases.allSatisfy { shelves.outCount($0) == 0 }, "취소 두 번 → 한 번처럼 · 모두 선반으로")
        // ⑤ 마침 외침 도중 새 시작 → 탁자로 되돌아감 → 취소
        scene.inventoryBegin(groups: stockGroups())
        _ = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .table }
        scene.inventoryFinish(measuredFreed: 0)
        _ = runUntil(harness, timeout: 20, probe: observe) { inventory.phase == .finishing }
        harness.run(1.0, probe: observe)
        scene.inventoryBegin(groups: stockGroups())
        harness.run(1.0, probe: observe)
        let resumedStacks = inventory.visibleStackCount
        let resumed = inventory.phase == .table && resumedStacks == 4
        scene.inventoryCancel()
        check(resumed && settle(), "마침 외침 도중 시작 → 탁자 단계로(묶음 \(resumedStacks)) → 취소 → 퇴장")
        // ⑥ 취소하자마자 다시 시작: 되돌리기를 바로 마치고 남은 인력이 묶음을 다시 내린다 — 예약해 둔 퇴장이 나중에 끼어들지 않는다.
        scene.inventoryBegin(groups: stockGroups())
        _ = runUntil(harness, timeout: 30, probe: observe) { inventory.phase == .table }
        scene.inventoryCancel()
        harness.run(0.2, probe: observe)
        scene.inventoryBegin(groups: stockGroups())
        harness.run(6, probe: observe)
        let stayed = inventory.phase == .table && inventory.visibleStackCount == 4 && inventory.hands.count == 3
            && [DiskTag.cache, .regenerable, .docker, .trash].allSatisfy { shelves.visible($0) == 0 }
        check(stayed, "취소 직후 시작 → 그대로 탁자 단계(\(inventory.phase.rawValue)) · 묶음 \(inventory.visibleStackCount) · 인력 \(inventory.hands.count)명 · 6초 뒤에도 퇴장 안 함")
        // ⑦ 손수레가 1층으로 올라간 사이 새로 시작(취소 뒤 다시): 심부름꾼은 제 일(금고 전달)을 마치고 사라지고, 새 인력과 섞이지 않는다.
        scene.inventoryOpen(group: .cache, items: items)
        harness.run(2, probe: observe)
        scene.inventoryExecute(trash: [items[6].path], delete: [], prune: [])
        _ = runUntil(harness, timeout: 30, probe: observe) { !inventory.couriers.isEmpty }
        scene.inventoryCancel()
        harness.run(0.5, probe: observe)
        scene.inventoryBegin(groups: stockGroups())
        let courierDone = runUntil(harness, timeout: 40, probe: observe) { inventory.couriers.isEmpty && inventory.phase == .table }
        check(courierDone != nil && scene.vaultNode.log.contains("건네받음 · 1") && inventory.hands.count == 3,
              "심부름 중 새 출동 → 심부름꾼은 금고에 건네고 퇴장 · 새 인력 \(inventory.hands.count)명은 탁자에")
        scene.inventoryCancel()
        check(settle(), "마지막 취소 → 모두 퇴장")
        watch.staff.report("재고 조사 인력", particle: "이")
        noSafetyNet(harness)
    }

    // MARK: 드문 순찰(재고 세기)

    static func inventoryIdle() {
        print("— inventory-idle: 가끔 한 명이 내려와 선반을 따라 걸으며 세고 나간다(상자는 그대로) · 장면 시간 20분에 몇 번(평균 10분에 한 번)")
        let harness = stockHarness(seed: 86)
        let scene = harness.scene
        let inventory = scene.inventoryNode
        let shelves = scene.diskShelvesNode
        let watch = CrewWatch()
        let before = shelves.slotProbes.map { "\($0.tag?.rawValue ?? "-")\($0.visible)" }
        let shownBefore = scene.warehouseNode.shown[.disk]
        var visits = 0, reachedLast = false, counting = false, wasHere = false, countShot = false
        harness.run(1200) { now in
            watch.observe(scene, now: now)
            let here = inventory.counter != nil
            if here && !wasHere { visits += 1 }
            wasHere = here
            if let counter = inventory.counter {
                if abs(counter.position.x - (WarehouseNode.shelfXs[3] + 15)) < 1 { reachedLast = true }
                if counter.body.action(forKey: "anim") != nil, abs(counter.position.x - (WarehouseNode.shelfXs[0] + 15)) < 1 { counting = true }
                if !countShot, counting {
                    countShot = true
                    shot(harness, "inventory-idle-count", rect: scene.inventoryStageRect)
                }
            }
        }
        let after = shelves.slotProbes.map { "\($0.tag?.rawValue ?? "-")\($0.visible)" }
        check(visits >= 1 && visits <= 5 && reachedLast && counting && watch.said.contains { Lines.stockCount.contains($0) },
              "20분 동안 순찰 \(visits)번 · 선반 넷을 따라 걸으며 셈(마지막 선반까지 \(reachedLast)) · 말 \(watch.said.filter { Lines.stockCount.contains($0) })")
        check(before == after && scene.warehouseNode.shown[.disk] == shownBefore && inventory.phase == .idle, "순찰은 상자를 옮기지 않음(선반 칸 그대로 · 재고 조사 단계 아님)")
        watch.staff.report("순찰 인력", particle: "이")
        noSafetyNet(harness)
    }
}
