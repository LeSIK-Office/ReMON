import AppKit
import ReMONCore
import SpriteKit
import SwiftUI

/// 'AI 사무실' 창. Aside처럼 창 전체가 반투명(behindWindow)이고 가운데 카드만 불투명하다.
/// 메뉴 막대 위치에서 커지며 열린다(펼치기). 닫으면 장면을 멈추고 메뉴 막대 상주로 돌아간다.
@MainActor
final class OfficeWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private(set) var window: NSWindow?
    private var retainedScene: OfficeScene?
    var scene: OfficeScene {
        if let retainedScene { return retainedScene }
        let scene = OfficeScene(size: CGSize(width: 1400, height: 900))
        configure(scene)
        retainedScene = scene
        return scene
    }
    private var skView: OfficeView?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    private func configure(_ scene: OfficeScene) {
        scene.onSelect = { [weak self] key in
            guard let self else { return }
            self.model.selectedSession = key
            if key != nil { self.model.selectedApp = nil; self.model.selectedMachine = nil; self.model.selectedBoss = false }
        }
        scene.onSelectApp = { [weak self] id in
            guard let self, let id else { return }
            self.model.selectedSession = nil
            self.model.selectedMachine = nil
            self.model.selectedApp = id
        }
        scene.onSelectMachine = { [weak self] machine in self?.model.selectMachine(machine) }
        scene.onSelectBoss = { [weak self] in self?.model.selectBoss() }
        scene.onSelectVault = { [weak self] in self?.model.openVault() }
        scene.onSelectSubagent = { [weak self] key, info in self?.model.selectSubagent(key, info) }
        scene.onFocusChanged = { [weak self] focus in self?.model.focus = focus }
        scene.onCaption = { [weak self] caption in self?.model.caption = caption }
        scene.onFloorsChanged = { [weak self] floors in self?.model.floors = floors }
        scene.onViewportFloor = { [weak self] index in self?.model.viewportFloor = index }
        scene.autoZoomEnabled = { [weak self] in self?.model.settings.autoZoom ?? true }
    }

    func show(from rect: NSRect?) {
        if window == nil { build() }
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        skView?.isPaused = false
        model.attachScene(scene)
        scene.updateWeather()   // 시간대·계절 하늘과 날씨 입자(Weather.swift). 이후엔 장면이 2초마다 스스로 맞춘다.
        model.monitor.foreground = true
        model.monitor.refreshNow()
        if let office = model.office { scene.update(snapshot: office, events: []) }
        scene.focus(model.focus, animated: false)
        scene.select(model.selectedSession)
        let target = window.frame
        if let rect, !window.isVisible {
            // 애니메이션 중에는 자동 저장을 끄고, 끝나면 다시 켠다(작은 시작 크기가 저장되지 않게).
            window.setFrameAutosaveName("")
            window.setFrame(NSRect(x: rect.midX - 60, y: rect.minY - 40, width: 120, height: 40), display: false)
            window.alphaValue = 0
            window.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.32
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(target, display: true)
                window.animator().alphaValue = 1
            }, completionHandler: {
                window.setFrame(target, display: true)
                window.setFrameAutosaveName("AIOfficeWindow")
            })
        } else {
            window.makeKeyAndOrderFront(nil)
        }
        // 사용자 요청으로 연 창은 실제로 활성화한다. activate()는 거절돼도 반환한다.
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1560, screen.width - 80), height = min(960, screen.height - 60)
        let window = NSWindow(contentRect: NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "AI 사무실"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // 창 상태 복원이 크기 검사 뒤에 작은 크기로 덮어써(565×453) 끈다. 크기·위치는 자동 저장 이름으로 따로 기억한다.
        window.isRestorable = false
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 1100, height: 680)
        window.delegate = self
        window.setFrameAutosaveName("AIOfficeWindow")
        // 펼치기 애니메이션 도중 닫히면 작은 시작 크기가 저장된다 → 복원된 크기가 최소보다 작으면 기본 크기로.
        if window.frame.width < window.minSize.width || window.frame.height < window.minSize.height {
            window.setFrame(NSRect(x: screen.midX - width / 2, y: screen.midY - height / 2, width: width, height: height), display: false)
        }
        // Aside식 반투명: 창 뒤 바탕화면이 비치는 재질을 창 전체에 깐다. 가운데 카드는 SwiftUI가 불투명하게 덮는다.
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.isEmphasized = true
        let skView = OfficeView(frame: .zero)
        skView.preferredFramesPerSecond = 60
        skView.ignoresSiblingOrder = true
        skView.allowsTransparency = false
        skView.presentScene(scene)
        self.skView = skView
        let hosting = NSHostingView(rootView: OfficeShellView(model: model, skView: skView))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        window.contentView = effect
        self.window = window
    }

    func snapshot(to folder: URL, tag: String) {
        SnapshotTool.capture(scene: scene, view: skView, window: window, model: model, to: folder, tag: tag)
    }

    func windowWillClose(_ notification: Notification) {
        // 창이 없을 때는 렌더링·SwiftUI 갱신을 모두 멈추고 내용을 해제한다(상주 부하 목표: CPU 1%·메모리 150MB 미만).
        skView?.isPaused = true
        model.scene = nil
        model.monitor.foreground = false
        WindowActivation.closing(window)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible != true else { return }
            self.window?.contentView = nil
            self.skView?.presentScene(nil)
            self.skView = nil
            self.window = nil
            self.retainedScene = nil
            TextureCache.shared.trim()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) { skView?.isPaused = true }
    func windowDidDeminiaturize(_ notification: Notification) { skView?.isPaused = false }
}

@MainActor
enum WindowActivation {
    static func closing(_ window: NSWindow?) {
        guard let remaining = NSApp.orderedWindows.first(where: { $0 !== window && $0.isVisible && $0.level == .normal }) else {
            NSApp.setActivationPolicy(.accessory)
            return
        }
        // 키 창을 닫은 처리가 끝난 뒤 남은 창에 입력을 돌려준다.
        DispatchQueue.main.async {
            guard remaining.isVisible else { return }
            remaining.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// 장면에 마우스 이동(구역 강조)·핀치(확대)·Esc(전체 보기)를 전달하는 SKView.
final class OfficeView: SKView {
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    private var office: OfficeScene? { scene as? OfficeScene }

    override func mouseMoved(with event: NSEvent) { office?.hover(event) }
    override func mouseExited(with event: NSEvent) { office?.hoverEnded() }
    override func magnify(with event: NSEvent) { office?.magnify(event) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: office?.escape()                 // Esc
        case 24, 69: office?.zoomStep(1)          // = / +
        case 27, 78: office?.zoomStep(-1)         // - / −
        default: super.keyDown(with: event)
        }
    }
}

struct SpriteHost: NSViewRepresentable {
    let view: SKView
    func makeNSView(context: Context) -> SKView { view }
    func updateNSView(_ nsView: SKView, context: Context) {}
}
