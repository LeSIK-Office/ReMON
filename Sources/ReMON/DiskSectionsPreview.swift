import AppKit
import ReMONCore
import SwiftUI

/// 검수용: `--render-disk-sections <폴더>` → 개발 캐시 · 시스템 데이터 · 큰 파일 구역을 실제 홈 조사(읽기 전용) 결과로 그려 PNG로 남긴다.
/// 정리 화면에 붙이기 전에 구역이 제대로 그려지는지 보는 개발 도구다. 아무것도 지우거나 옮기지 않는다.
@MainActor
enum DiskSectionsPreview {
    static func render(to path: String) {
        let folder = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let model = AppModel()
        let store = DiskToolsStore.shared
        model.diskItems = DiskScanner().scan(activeDirectories: [])
        model.diskScannedAt = Date()
        model.syncCatalogSelection()
        var availability: [String: String] = [:]
        for command in ToolCommands.catalogCommands + [ToolCommands.pnpmPrune, ToolCommands.goModClean, ToolCommands.dockerPrune] {
            availability[command.id] = ToolCommands.availability(command).reason ?? ""
        }
        store.commandAvailability = availability
        store.collapsed = [.excluded]
        store.systemData = SystemData.report()
        store.largeReport = LargeFileFinder().scan()
        let sections: [(String, AnyView)] = [
            ("dev-cache", AnyView(DevCacheSection(model: model))),
            ("system-data", AnyView(SystemDataSection(model: model))),
            ("large-files", AnyView(LargeFilesSection(model: model))),
        ]
        for (name, view) in sections {
            let renderer = ImageRenderer(content: view.frame(width: 960).padding(16).background(Color(nsColor: .windowBackgroundColor)))
            renderer.scale = 2
            if let image = renderer.cgImage {
                SnapshotTool.write(image, to: folder.appendingPathComponent("\(name).png"))
            } else {
                print("render failed: \(name)")
            }
        }
    }
}
