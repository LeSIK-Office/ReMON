import AppKit
import ReMONCore
import SwiftUI

extension SceneChecks {
    static func dashboardLayout() {
        let cache = DiskNode(path: "/fixture/cache", bytes: 30, tags: [.cache, .regenerable, .large], actions: [.trash])
        let user = DiskNode(path: "/fixture/user", bytes: 50, tags: [.userFile, .large])
        let root = DiskNode(path: "/fixture", bytes: 100, children: [cache, user], tags: [.userFile])
        let virtual = DiskNode(path: "remon://category/cache", bytes: 30, children: [cache], tags: [.cache])
        let rows = DiskCompositionRow.summarize([root, cache, virtual, root])
        check(rows.reduce(0) { $0 + $1.total } == 100 && rows.first { $0.tag == .cache }?.total == 30,
              "디스크 구성: 다중 태그·중복 뿌리·가상 분류를 중복 합산하지 않음")
        check(rows.first { $0.tag == .userFile }?.total == 70 && rows.reduce(0) { $0 + $1.reclaimable } == 30,
              "디스크 구성: 부모의 나머지 20 포함 · 실제 조치 후보 30만 표시")
        var stale = root
        stale.bytes = 40
        check(DiskCompositionRow.summarize([stale]).reduce(0) { $0 + $1.total } == 40,
              "디스크 구성: 오래된 자식 합계가 새 부모 조사량을 초과하지 않음")

        guard let out else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remon-dashboard-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vault = RecoveryVault(folder: folder)
        vault.audit = AuditLog(url: folder.appendingPathComponent("actions.jsonl"))
        let model = AppModel(vault: vault)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let harness = SceneHarness()
        harness.sessions = (0..<3).map { index in
            var value = session(Int32(89001 + index), "긴 프로젝트 이름 \(index + 1)", .working, order: Double(index))
            value.title = "컨텍스트와 메모리가 큰 세션의 긴 작업 제목을 표시합니다"
            value.contextTokens = 230_000 - index * 35_000
            value.contextWindow = 258_000
            value.totalTokens = 4_900_000_000
            value.transcriptBytes = 2_100_000_000
            return value
        }
        model.office = harness.snapshot()
        model.system = harness.snapshot().system
        model.diskMapComposition = DiskTag.allCases.enumerated().map { index, tag in
            DiskCompositionRow(tag: tag, total: UInt64(index == 0 ? 170_000_000_000 : 100_000_000 / (index + 1)), reclaimable: 0)
        }
        for width in [560.0, 880.0, 1360.0] {
            for dark in [false, true] {
                let target = out.appendingPathComponent("dashboard-\(Int(width))-\(dark ? "dark" : "light").png")
                check(DiskMapPreview.capture(DashboardPageView(model: model), width: width, height: 1100, dark: dark, to: target),
                      "대시보드 \(Int(width))pt \(dark ? "어두운" : "밝은") 화면 렌더")
            }
        }
    }

    static func diskMapChecks() {
        let failures = DiskMapPreview.selfCheck()
        check(failures.isEmpty, "디스크 지도 배치·이동·더미 조치 검사" + (failures.isEmpty ? "" : " · " + failures.joined(separator: " / ")))
        let source = VirtualLocationSource()
        let store = DiskMapStore(source: source, actionRunner: MockDiskActions.run, rootPaths: [])
        store.prefetchLimit = 0
        store.rescan(); store.waitUntilIdle()
        store.filter = [.cache]
        store.locate(source.child.path); store.waitUntilIdle()
        check(store.path == [source.root.path] && store.selection == source.child.path && store.filter.isEmpty,
              "가상 칸 위치 보기: 문자열 경로 조립 없이 실제 트리의 부모로 이동")
    }

    static func windowLifecycle() {
        var reads = 0
        let sampler = SystemSampler(thermalReader: {
            reads += 1
            var value = SMCReader.Reading()
            value.cpuTemperature = Double(reads)
            return value
        })
        let sampledAt = Date()
        let first = sampler.sample(now: sampledAt)
        let cached = sampler.sample(now: sampledAt.addingTimeInterval(4))
        check(reads == 1 && first.thermal == cached.thermal && first.time != cached.time,
              "센서: 5초 안에는 온도·팬만 재사용하고 시스템 표본 시각은 갱신")
        let refreshed = sampler.sample(now: sampledAt.addingTimeInterval(5))
        check(reads == 2 && refreshed.thermal.cpuTemperature == 2, "센서: 5초가 되면 실제 읽기를 다시 수행")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remon-window-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = AppModel(vault: RecoveryVault(folder: folder))
        check(model.monitor.officeInterval == 30, "세션 목록: 상주 시작 시 30초 주기")
        model.office = SceneHarness().snapshot()
        model.refreshVisibleInventories()
        check(!model.diskScanning && !model.leftoversScanning, "상주 상태: 조사 기록이 없어도 전체 폴더 조사를 시작하지 않음")
        let now = Date()
        model.diskScannedAt = now
        model.leftoversScannedAt = now
        model.monitor.foreground = true
        model.refreshVisibleInventories(now: now.addingTimeInterval(6 * 3600 - 1))
        check(!model.diskScanning && !model.leftoversScanning && model.monitor.officeInterval == 2,
              "열린 창: 6시간 미만의 조사 결과를 재사용 · 세션 목록은 2초")
        let controller = OfficeWindowController(model: model)
        weak var previous = controller.scene
        model.attachScene(controller.scene)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(previous == nil && model.scene == nil && model.monitor.officeInterval == 30,
              "창 닫기: 사무실 장면 참조 해제 · 세션 목록은 30초")
        check(controller.scene.onSelect != nil, "다시 열기: 새 장면의 선택 콜백 복원")
    }
}

private struct VirtualLocationSource: DiskTreeSource {
    let child = DiskNode(path: "remon://snapshot/2026-10-25", name: "스냅샷", bytes: 0, isDirectory: false, tags: [.snapshot])
    var root: DiskNode { DiskNode(path: "/fixture", bytes: 0, children: [child]) }
    func scan(roots: [String], budget: TimeInterval) -> [DiskNode] { [root] }
    func expand(_ node: DiskNode, budget: TimeInterval) -> DiskNode { node }
    func largeFiles(under roots: [String], minimumBytes: UInt64, budget: TimeInterval) -> [DiskNode] { [] }
}
