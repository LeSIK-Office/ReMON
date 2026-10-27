import AppKit
import ReMONCore

extension SceneChecks {
    static func projectCleanupFlow() {
        let harness = SceneHarness()
        harness.sessions = [session(93_001, "알파", .working, order: 0), session(93_002, "베타", .working, order: 1)]
        harness.feed()
        harness.run(3)
        let scene = harness.scene
        scene.setClutter(["알파": RoomClutter(papers: 3), "베타": RoomClutter(papers: 4)])
        harness.run(2)
        scene.janitorVisit(project: "알파", items: 0, reclaimed: 0)
        scene.janitorVisit(project: "베타", items: 0, reclaimed: 0)
        scene.setClutter([:] as [String: RoomClutter])
        check(scene.paperCount("알파") == 3 && scene.paperCount("베타") == 4,
              "청소 중·대기 중인 방의 서류는 새 장부가 와도 청소부가 걷을 때까지 유지")
        var visited = Set<String>()
        let end = runUntil(harness, timeout: 120, probe: { _ in
            if let project = scene.clutterCleaning { visited.insert(project) }
        }) { scene.janitorsGone }
        check(end != nil && visited == ["알파", "베타"] && scene.paperCount("알파") == 0 && scene.paperCount("베타") == 0,
              "연속 청소: 두 방 모두 방문하고 서류를 치움 · 방문 \(visited.sorted())")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remon-project-check-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(vault: RecoveryVault(folder: folder))
        model.office = harness.snapshot()
        model.attachScene(scene)
        model.projectGarbage = ["알파": ProjectGarbage(papers: 3)]
        model.refreshProjectGarbage()
        let dryRun = model.settings.dryRun
        defer { model.settings.dryRun = dryRun }
        model.settings.dryRun = true
        model.cleanProject("알파")
        check(model.projectGarbage["알파"]?.papers == 3 && scene.janitorsGone,
              "서류만 있는 방도 드라이런에서는 장부·청소 장면을 바꾸지 않음")
        model.settings.dryRun = false
        model.page = .dashboard
        model.cleanProject("알파")
        check(model.page == .office && scene.janitorBusy && model.roomClutter["알파"] == nil,
              "서류 청소: 즉시 사무실로 이동해 청소 시작 · 방 장부도 갱신")
    }
}
