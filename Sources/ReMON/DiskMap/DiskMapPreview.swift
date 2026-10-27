import AppKit
import ReMONCore
import SwiftUI

/// 검수용: 디스크 지도 화면을 가짜 조사기(MockDiskTreeSource)로 그려 PNG로 남기고, 배치·나무 규칙을 스스로 점검한다.
/// 앱 실행 경로(main.swift)와 무관 — 바깥 하네스가 `@testable import ReMON`으로 부른다. 실제 파일은 읽지도 바꾸지도 않는다.
@MainActor
enum DiskMapPreview {
    struct Shot {
        let name: String
        let width: CGFloat
        let height: CGFloat
        let dark: Bool
        /// 조사가 끝나기 전(첫 조사 중) 화면을 찍는다.
        var midScan = false
        let setup: (DiskMapStore) -> Void
    }

    /// 상태별 화면을 그린다. 돌려주는 값 = 쓴 PNG 경로들.
    static func render(to folder: String) -> [String] {
        let url = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let home = NSHomeDirectory()
        let project = home + "/DEV/shop-web"
        let drill: (DiskMapStore) -> Void = { store in
            open(store, home + "/DEV")
            open(store, project)
            store.select(store.node(at: project + "/node_modules"))
            store.hovered = project + "/.next"
        }
        let shots: [Shot] = [
            Shot(name: "00-scanning-light", width: 1000, height: 1000, dark: false, midScan: true) { _ in },
            Shot(name: "01-top-light", width: 1000, height: 1640, dark: false) { _ in },
            Shot(name: "02-top-dark", width: 1000, height: 1640, dark: true) { _ in },
            Shot(name: "03-drill-light", width: 1000, height: 1640, dark: false, setup: drill),
            Shot(name: "04-drill-dark", width: 1000, height: 1640, dark: true, setup: drill),
            Shot(name: "05-filter-wide-light", width: 1290, height: 1500, dark: false) { store in
                store.filter = [.regenerable, .cache]
                store.select(store.displayed.first?.node)
                store.checked = Set(store.displayed.dropFirst().prefix(3).map(\.node.path))
            },
            Shot(name: "06-docker-dark", width: 1000, height: 1640, dark: true) { store in
                if let docker = store.glances.first(where: { $0.tag == .docker }) { store.focus(docker) }
            },
            Shot(name: "07-xcode-permanent-light", width: 1000, height: 1640, dark: false) { store in
                store.locate(home + "/Library/Developer/Xcode/DerivedData")
                store.waitUntilIdle()
            },
            Shot(name: "08-narrow-light", width: 560, height: 2700, dark: false, setup: drill),
            Shot(name: "09-narrow-dark", width: 560, height: 2700, dark: true) { store in
                store.filter = [.trash, .temp]
            },
            Shot(name: "10-medium-swap-light", width: 760, height: 2000, dark: false) { store in
                store.select(store.node(at: "/private/var/vm"))
            },
        ]
        var written: [String] = []
        for shot in shots {
            let store = makeStore(latency: shot.midScan ? 20 : 0)
            store.rescan()
            if shot.midScan {
                let until = Date().addingTimeInterval(1.2)
                while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            } else {
                store.waitUntilIdle()
            }
            shot.setup(store)
            if !shot.midScan { store.waitUntilIdle() }
            let target = url.appendingPathComponent(shot.name + ".png")
            if capture(DiskMapPage(store: store), width: shot.width, height: shot.height, dark: shot.dark, to: target) { written.append(target.path) }
        }
        return written
    }

    /// 가짜 조사기·가짜 실행기·확인 창 없음(미리보기는 묻지 않는다).
    static func makeStore(latency: TimeInterval = 0) -> DiskMapStore {
        let store = DiskMapStore(source: MockDiskTreeSource(latency: latency), actionRunner: MockDiskActions.run, rootPaths: [])
        store.confirm = { _, _, _, _ in true }
        store.inform = { title, text in print("inform: \(title) · \(text)") }
        store.dryRun = { false }
        return store
    }

    private static func open(_ store: DiskMapStore, _ path: String) {
        guard let node = store.node(at: path) else { print("preview: 칸 없음 \(path)"); return }
        store.drillDown(node)
        store.waitUntilIdle()
    }

    /// 화면 밖 창의 NSHostingView에 그려 PNG로 쓴다(화면 기록 권한 없이).
    static func capture<V: View>(_ view: V, width: CGFloat, height: CGFloat, dark: Bool, to url: URL) -> Bool {
        let root = view
            .frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let settle = Date().addingTimeInterval(0.8)
        while Date() < settle { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        hosting.layoutSubtreeIfNeeded()
        defer { window.close() }
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { print("preview: 그리기 실패 \(url.lastPathComponent)"); return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let image = rep.cgImage else { return false }
        SnapshotTool.write(image, to: url)
        return true
    }

    // MARK: 자기 점검(배치·나무 규칙)

    /// 실패한 점검 문장들(비면 전부 통과).
    static func selfCheck() -> [String] {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }

        // 1) squarified: 면적 보존 · 겹침 없음 · 안에 들어감 · 순서대로
        var random = SeededRandom(seed: 42)
        for trial in 0..<200 {
            let count = 1 + random.next(60)
            let values = (0..<count).map { _ in pow(Double(1 + random.next(10_000)), 1.6) }.sorted(by: >)
            let rect = CGRect(x: 0, y: 0, width: CGFloat(80 + random.next(900)), height: CGFloat(60 + random.next(600)))
            let rects = DiskMapSquarify.layout(values, in: rect)
            let area = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
            expect(abs(area - Double(rect.width * rect.height)) < Double(rect.width * rect.height) * 1e-6, "squarify[\(trial)] 면적 보존 실패")
            let total = values.reduce(0, +)
            for (index, value) in values.enumerated() {
                let expected = value / total * Double(rect.width * rect.height)
                let actual = Double(rects[index].width * rects[index].height)
                expect(abs(expected - actual) <= max(1e-6 * expected, 0.5), "squarify[\(trial)] 칸 \(index) 비율 어긋남")
                expect(rect.insetBy(dx: -0.01, dy: -0.01).contains(rects[index]), "squarify[\(trial)] 칸 \(index)이 밖으로 나감")
            }
            for a in 0..<rects.count { for b in (a + 1)..<max(a + 1, rects.count) where rects[a].insetBy(dx: 0.01, dy: 0.01).intersects(rects[b].insetBy(dx: 0.01, dy: 0.01)) {
                failures.append("squarify[\(trial)] 칸 \(a)·\(b) 겹침")
            } }
        }
        let zeros = DiskMapSquarify.layout([0, 5, 0, 3], in: CGRect(x: 0, y: 0, width: 100, height: 50))
        expect(zeros[0].width * zeros[0].height == 0 && zeros[2].width * zeros[2].height == 0, "squarify 0 값은 크기 0")
        expect(DiskMapSquarify.layout([], in: CGRect(x: 0, y: 0, width: 10, height: 10)).isEmpty, "squarify 빈 입력")

        // 2) 나무: 합치기는 펼친 단계를 남기고, 지우기는 조상 크기에서 덜어낸다
        let leaf = DiskNode(path: "/r/a/x", bytes: 30, fileCount: 3, isDirectory: false, tags: [.cache], actions: [.trash, .deletePermanently])
        let a = DiskNode(path: "/r/a", bytes: 100, fileCount: 10, children: [leaf, DiskNode(path: "/r/a/y", bytes: 70, fileCount: 7, isDirectory: false, tags: [.userFile])])
        let root = DiskNode(path: "/r", bytes: 150, fileCount: 15, children: [a, DiskNode(path: "/r/b", bytes: 50, fileCount: 5, children: nil, tags: [.trash])])
        var shallow = root
        shallow.children = [DiskNode(path: "/r/a", bytes: 120, fileCount: 12, children: nil), DiskNode(path: "/r/b", bytes: 50, fileCount: 5, children: nil, tags: [.trash])]
        let merged = DiskMapTree.merge(old: root, new: shallow)
        expect(DiskMapTree.find("/r/a/x", in: [merged]) != nil, "merge가 펼친 자식을 잃음")
        expect(DiskMapTree.find("/r/a", in: [merged])?.bytes == 120, "merge가 새 값을 쓰지 않음")
        var tree = [root]
        let removed = DiskMapTree.remove("/r/a/x", in: &tree)
        expect(removed?.bytes == 30, "remove가 칸을 돌려주지 않음")
        expect(tree[0].bytes == 120 && DiskMapTree.find("/r/a", in: tree)?.bytes == 70, "remove가 조상 크기를 덜지 않음")
        expect(tree[0].fileCount == 12, "remove가 조상 파일 수를 덜지 않음")
        var replaced = [root]
        DiskMapTree.replace("/r/a/y", in: &replaced) { $0.bytes = 20 }
        expect(replaced[0].bytes == 100 && DiskMapTree.find("/r/a", in: replaced)?.bytes == 50, "replace가 조상에 차이를 반영하지 않음")
        expect(DiskMapTree.chain(to: "/r/a/x", in: [root]) == ["/r", "/r/a", "/r/a/x"], "chain 경로")
        let matches = DiskMapTree.maximalMatches(in: [root], tags: [.cache, .trash])
        expect(Set(matches.map(\.node.path)) == ["/r/a/x", "/r/b"], "maximalMatches")
        let big = DiskNode(path: "/r/b/huge.raw", bytes: 40, fileCount: 1, isDirectory: false, tags: [.trash, .large])
        let other = DiskNode(path: "/r/c/huge.iso", bytes: 40, fileCount: 1, isDirectory: false, tags: [.cache, .large])
        let combined = DiskMapTree.matches(in: [root], under: nil, largeFiles: [big, other], tags: [.cache, .trash])
        expect(Set(combined.map(\.node.path)) == ["/r/a/x", "/r/b", "/r/c/huge.iso"], "matches: 이미 센 칸 아래 큰 파일은 빼고, 밖의 큰 파일은 더한다")
        expect(DiskMapTree.outermost([a, leaf]).map(\.path) == ["/r/a"], "outermost")
        expect(leaf.isSafeToDeletePermanently, "캐시 칸은 영구 삭제 가능")

        // 3) 가게: 조사 → 들어가기 → 다시 조사해도 경로 유지 → 휴지통 뒤 나무·조상 크기 반영 → 묶음은 휴지통만
        let store = makeStore()
        var asked: [(String, String, String, Bool)] = []
        store.confirm = { asked.append(($0, $1, $2, $3)); return true }
        store.rescan()
        store.waitUntilIdle()
        expect(!store.roots.isEmpty && !store.largeFiles.isEmpty && store.lastScan != nil, "가게: 조사 결과 없음")
        let home = NSHomeDirectory()
        let project = home + "/DEV/shop-web"
        open(store, home + "/DEV")
        open(store, project)
        expect(store.path == [home + "/DEV", project], "가게: 들어간 경로 \(store.path)")
        expect(store.displayed.contains { $0.node.name == "node_modules" }, "가게: 프로젝트 안 칸이 안 보임")
        store.rescan()
        store.waitUntilIdle()
        expect(store.path == [home + "/DEV", project], "가게: 다시 조사 뒤 경로가 풀림 \(store.path)")
        let beforeDev = store.node(at: home + "/DEV")?.bytes ?? 0
        if let modules = store.node(at: project + "/node_modules") {
            store.perform(.trash, on: modules)
            store.waitUntilIdle()
            expect(store.node(at: project + "/node_modules") == nil, "가게: 휴지통 뒤 칸이 남음")
            expect((store.node(at: home + "/DEV")?.bytes ?? 0) == beforeDev - modules.bytes, "가게: 조상 크기에서 덜지 않음")
            expect(asked.last?.1.contains("복구 금고에 기록합니다") == true && asked.last?.3 == false, "가게: 휴지통 확인 문장/스타일")
        } else {
            failures.append("가게: node_modules 없음")
        }
        if let next = store.node(at: project + "/.next") {
            store.perform(.deletePermanently, on: next)
            store.waitUntilIdle()
            expect(asked.last?.3 == true && asked.last?.1.contains("되돌릴 수 없습니다") == true, "가게: 영구 삭제는 파괴적 확인 + 되돌릴 수 없음 문장")
            expect(asked.last?.1.contains("복구 금고에 기록합니다") == true, "가게: 영구 삭제 확인에 금고 문장")
            expect(store.node(at: project + "/.next") == nil, "가게: 영구 삭제 뒤 칸이 남음")
        }
        // 영구 삭제가 허용되지 않은 칸(사용자 파일)은 묻지도 않고 막는다.
        var informed = false
        store.inform = { _, _ in informed = true }
        let askedBefore = asked.count
        if let apps = store.node(at: project + "/apps") {
            store.perform(.deletePermanently, on: apps)
            expect(informed && asked.count == askedBefore, "가게: 사용자 파일 영구 삭제를 막지 않음")
        }
        store.go(toDepth: 0)
        store.filter = [.gitByproduct]
        store.checked = Set(store.displayed.map(\.node.path))
        let bulk = store.checkedNodes
        expect(bulk.allSatisfy { $0.actions.contains(.trash) }, "가게: 묶음에 휴지통 불가 칸이 섞임")
        store.trashChecked()
        store.waitUntilIdle()
        expect(asked.last?.2 == "휴지통으로" && asked.last?.1.contains("영구 삭제하지는 않습니다") == true, "가게: 묶음 확인 문장")
        expect(asked.last?.1.contains("복구 금고에 기록합니다") == true, "가게: 묶음 확인에 금고 문장")
        expect(store.displayed.allSatisfy { !$0.node.actions.contains(.trash) }, "가게: 묶음 휴지통 뒤에도 옮길 수 있는 칸이 남음 \(store.displayed.map(\.node.name))")
        expect(store.note?.hasPrefix("휴지통으로") == true || bulk.count <= 1, "가게: 묶음 결과 한 줄 \(store.note ?? "")")
        // 정리 명령은 미리보기 문장을 확인 창에 먼저 보여 준다.
        store.filter = []
        if let docker = store.largeFiles.first(where: { $0.tags.contains(.docker) }) {
            store.perform(.prune, on: docker)
            store.waitUntilIdle()
            store.waitUntilIdle()
            expect(asked.last?.1.hasPrefix("미리보기") == true, "가게: 정리 명령 미리보기")
            expect(asked.last?.1.contains("복구 금고에 기록합니다") == true, "가게: 정리 명령 확인에 금고 문장")
        }
        return failures
    }
}
