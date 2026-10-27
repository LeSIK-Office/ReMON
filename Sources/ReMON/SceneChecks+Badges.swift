import AppKit
import Metal
import ReMONCore
import SpriteKit

// 말풍선 앞뒤 순서(10-25 대표 지적: 겹치면 뒤 글자가 비쳐 투명해 보임 · 가장 최근 말이 맨 앞이어야 함).
// 작은 장면에 같은 자리 말풍선 두 개를 그려 픽셀로 확인한다: 앞 상자 안에 뒤 상자의 짙은 회색 글자가 한 점도 보이면 안 된다.

extension SceneChecks {
    static func bubbleOrder() {
        print("— bubble-order: 같은 자리 말풍선 두 개 · 뒤 글자가 앞 바탕을 뚫는지 픽셀로 확인")
        let size = CGSize(width: 320, height: 120)
        let scene = SKScene(size: size)
        scene.backgroundColor = NSColor(white: 0.5, alpha: 1)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let back = TextBadge("가나다", style: .bubble)
        back.position = center
        scene.addChild(back)
        let front = TextBadge("앞에 선 큰 말풍선입니다", style: .shout)
        front.position = center
        scene.addChild(front)
        check(front.zPosition > back.zPosition, "새로 만든 말풍선이 앞(z \(front.zPosition) > \(back.zPosition))")
        // 뒤 상자의 글자 영역(가운데 작은 사각형)에 짙은 회색 글자 점이 있는지.
        let probe = CGRect(x: center.x - back.badgeSize.width / 2 + 4, y: center.y - 5, width: back.badgeSize.width - 8, height: 10)
        let covered = darkGrayPixels(scene, size: size, in: probe)
        check(covered == 0, "앞 말풍선이 뒤 말풍선 글자를 완전히 가림(비친 점 \(covered)개)")
        back.set("가나다라")
        check(back.zPosition > front.zPosition, "새로 말하면 맨 앞으로(z \(back.zPosition) > \(front.zPosition))")
        let shown = darkGrayPixels(scene, size: size, in: probe)
        check(shown > 20, "앞으로 나온 말풍선 글자가 보임(점 \(shown)개)")
        let sign = TextBadge("칠판", style: .sign), plate = TextBadge("이름표", style: .plate)
        let title = TextBadge("제목", style: .bubble, layer: .title), chip = TextBadge("안내", style: .plate, layer: .chip)
        check(sign.zPosition < plate.zPosition && plate.zPosition < title.zPosition && title.zPosition < back.zPosition && back.zPosition < chip.zPosition,
              "층 순서: 글자판 < 이름표 < 제목 풍선 < 말풍선 < 안내 칩")
        // 층 자리가 다 차도(오래 켜 둔 앱) 순서가 유지되는지: 말풍선을 6만 번 넘게 올린 뒤에도 마지막에 말한 것이 앞.
        for _ in 0..<60_010 { front.bringToFront() }
        check(front.zPosition > back.zPosition && front.zPosition < 9, "층 자리를 다시 채운 뒤에도 순서 유지(z \(front.zPosition))")
    }

    /// 장면을 화면 없이 그려, 사각형 안의 짙은 회색(말풍선 글자색 근처) 점 수를 센다.
    private static func darkGrayPixels(_ scene: SKScene, size: CGSize, in rect: CGRect) -> Int {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(), let buffer = queue.makeCommandBuffer() else { return -1 }
        let renderer = SKRenderer(device: device)
        renderer.ignoresSiblingOrder = true
        renderer.scene = scene
        renderer.update(atTime: 0)
        let width = Int(size.width), height = Int(size.height)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return -1 }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        renderer.render(withViewport: CGRect(origin: .zero, size: size), commandBuffer: buffer, renderPassDescriptor: pass)
        buffer.commit()
        buffer.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        var count = 0
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let row = height - 1 - y   // 텍스처는 위에서부터, 장면 좌표는 아래에서부터
                let i = (row * width + x) * 4
                let b = Int(bytes[i]), g = Int(bytes[i + 1]), r = Int(bytes[i + 2])
                if r < 90, g < 90, b < 90, abs(r - g) < 20, abs(g - b) < 20 { count += 1 }
            }
        }
        return count
    }

    /// 전체 보기: 화면 크기가 어떻든 건물이 화면을 거의 채운다(10-25 대표 지적: 건물이 작고 하늘·땅이 많음 — 배율 0.99가 0.5로 내려가던 문제).
    static func overviewFit() {
        print("— overview-fit: 여러 화면 크기에서 전체 보기 건물이 차지하는 비율")
        for size in [CGSize(width: 657, height: 688), CGSize(width: 600, height: 900), CGSize(width: 900, height: 560), CGSize(width: 1315, height: 1377), CGSize(width: 1400, height: 900)] {
            let harness = SceneHarness(size: size)
            harness.sessions = [session(101, "알파", .working, order: 0), session(102, "베타", .idle, order: 1)]
            harness.feed()
            harness.run(0.2)
            harness.scene.focus(.all, animated: false)
            harness.run(0.1)
            let scale = harness.scene.pointsPerPixel
            let width = CGFloat(BuildingLayout.width) * scale / size.width
            let height = CGFloat(harness.scene.layout.height) * scale / size.height
            let fill = max(width, height)
            check(fill >= 0.88 && width <= 1 && height <= 1, String(format: "화면 %.0f×%.0f → 배율 %.3f · 건물이 가로 %.0f%% · 세로 %.0f%%", size.width, size.height, scale, width * 100, height * 100))
            shot(harness, String(format: "overview-%.0fx%.0f", size.width, size.height), focus: .all)
        }
    }

    /// 방에 다가간 뒤 어둡게 가린 바깥을 누르면 전체 보기로, 밝은 안쪽을 누르면 그대로.
    static func clickOutside() {
        print("— click-outside: 방 초점 → 바깥 클릭이면 전체 보기")
        let harness = SceneHarness()
        harness.sessions = [session(201, "알파", .working, order: 0), session(202, "베타", .idle, order: 1)]
        harness.feed()
        harness.run(1)
        harness.scene.focus(.room("알파"), animated: false)
        harness.run(0.8)
        let room = harness.scene.focusRect(.room("알파"))
        harness.scene.simulateClick(at: CGPoint(x: room.midX, y: room.minY + 4))
        harness.run(0.8)
        check(harness.scene.focusTarget == .room("알파"), "밝은 방 안(바닥)을 누르면 초점 유지")
        let machine = harness.scene.regionRect(.machineRoom)
        harness.scene.simulateClick(at: CGPoint(x: machine.midX, y: machine.midY))
        harness.run(0.8)
        check(harness.scene.focusTarget == .all, "어둡게 가린 바깥(기계실)을 누르면 전체 보기로(\(harness.scene.focusTarget))")
    }

    /// 도구실: 기계(몸통·아이콘 화면·표시등)가 모두 사람보다 뒤에 그려진다(10-25 대표 지적: 기계는 뒤인데 아이콘만 사람 앞에 뜸).
    static func toolDepth() {
        print("— tool-depth: 도구실 기계와 아이콘이 사람보다 뒤")
        let harness = SceneHarness()
        var apps: [AppGroup] = []
        for index in 0..<3 {
            let bytes = UInt64(2 + index) << 30
            apps.append(AppGroup(id: "/Applications/Fake\(index).app", name: "Fake\(index)", category: .app, agentKind: nil, pids: [], footprint: bytes, cpuPercent: 0))
        }
        harness.apps = apps
        harness.sessions = [session(301, "알파", .working, order: 0)]
        harness.feed()
        harness.run(2)
        let tools = harness.scene.world.children.compactMap { $0 as? ToolMachineNode }
        let highest = tools.map { node in node.zPosition + (node.children.map(\.zPosition).max() ?? 0) }.max() ?? 99
        let lowestPerson = harness.scene.world.children.compactMap { $0 as? WorkerNode }.map(\.zPosition).min() ?? 4
        check(tools.count == 3 && highest < lowestPerson, "기계 \(tools.count)대 · 가장 높은 부품 z \(highest) < 사람 z \(lowestPerson)")
        if let first = tools.first { shot(harness, "tool-depth", rect: CGRect(x: first.position.x - 60, y: first.position.y - 10, width: 160, height: 70)) }
    }
}
