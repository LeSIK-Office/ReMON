import AppKit
import ReMONCore
import SpriteKit
import SwiftUI

/// 검수용: `--snapshot <폴더>` → 사무실 장면(SpriteKit 텍스처), 창 전체(뷰 렌더), 메뉴 패널을 PNG로 남긴다.
/// 화면 기록 권한 없이도 화면 증거를 남기기 위한 개발 도구다. `--demo <연출>`로 연출을 강제로 재생할 수 있다.
@MainActor
enum SnapshotTool {
    static func folder() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func capture(scene: OfficeScene, view: SKView?, window: NSWindow?, model: AppModel, to folder: URL, tag: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let view, let texture = view.texture(from: scene) {
            write(texture.cgImage(), to: folder.appendingPathComponent("office-\(tag).png"))
        }
        if let content = window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: rep)
            if let image = rep.cgImage { write(image, to: folder.appendingPathComponent("window-\(tag).png")) }
        }
        // 창 합성본: 사무실 텍스처 위에 사이드바(유리 대신 반투명 흰 판)를 겹친다. 실제 Liquid Glass 굴절은 렌더러가 재현하지 못한다.
        if let view, let texture = view.texture(from: scene) {
            let office = texture.cgImage()
            let sidebar = ImageRenderer(content: RightSidebar(model: model).frame(width: 300, height: max(600, CGFloat(office.height) / 2 - 48)))
            sidebar.scale = 2
            if let panel = sidebar.cgImage, let context = CGContext(data: nil, width: office.width, height: office.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(office, in: CGRect(x: 0, y: 0, width: office.width, height: office.height))
                let rect = CGRect(x: office.width - panel.width - 28, y: 28, width: panel.width, height: panel.height)
                let path = CGPath(roundedRect: rect, cornerWidth: 52, cornerHeight: 52, transform: nil)
                context.saveGState()
                context.addPath(path); context.clip()
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.62)); context.fill(rect)
                context.draw(panel, in: rect)
                context.restoreGState()
                context.addPath(path); context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9)); context.setLineWidth(3); context.strokePath()
                if let composite = context.makeImage() { write(composite, to: folder.appendingPathComponent("composite-\(tag).png")) }
            }
        }
        let renderer = ImageRenderer(content: MenuPanelView(model: model, openOffice: {}, openSettings: {}, quit: {}).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        if let image = renderer.cgImage { write(image, to: folder.appendingPathComponent("menu-panel-\(tag).png")) }
        let runner = (0..<4).map { CharacterArt.runner($0, hoodie: PixelColor(0xE8735A), sweat: false, alert: false) }
        var strip = PixelCanvas(16 * 4 + 6, 16, fill: PixelColor(0xEDEDED))
        for (index, frame) in runner.enumerated() { strip.stamp(frame, index * 18, 0) }
        if let image = strip.cgImage(scale: 8) { write(image, to: folder.appendingPathComponent("menubar-runner.png")) }
    }

    /// 검수용 `--capture-ui <폴더>`: 설정 탭 · 첫 실행 시트 · 대시보드 캡처(AppDelegate.captureUI).
    static func uiFolder() -> URL? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--capture-ui"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// 창 하나를 PNG로 남긴다(화면 기록 권한 없이 뷰를 그린다). 제목 막대·도구 막대까지 담으려고 내용 뷰의 부모(창 프레임)를 그린다.
    static func captureWindow(_ window: NSWindow?, to folder: URL, name: String) {
        guard let window, let content = window.contentView else { print("snapshot: \(name) 창 없음"); return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let view = content.superview ?? content
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let image = rep.cgImage { write(image, to: folder.appendingPathComponent(name + ".png")) }
    }

    static func write(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("snapshot: \(url.path) \(image.width)x\(image.height)")
    }
}
