import AppKit
import Combine
import ReMONCore
import SwiftUI

/// 메뉴 막대: RunCat 방식으로 CPU가 높을수록 빨리 달리는 직원 + 고른 수치. 클릭하면 요약 패널.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let model: AppModel
    private let runLayer = CALayer()
    private var framesKey = ""
    private var lastTitle = ""
    private var lastTitleAt = Date.distantPast
    private var cancellables: Set<AnyCancellable> = []
    var onOpenOffice: ((NSRect?) -> Void)?
    var onSettings: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        super.init()
        if let button = item.button {
            // 그림 자리는 투명 이미지로 비워 두고, 그 위 CALayer가 키프레임 애니메이션으로 달린다.
            // 프레임마다 이미지를 바꾸면 macOS 26 메뉴 막대가 매번 스냅샷을 다시 그려 CPU를 크게 쓴다(실측 11%).
            button.image = NSImage(size: NSSize(width: 18, height: 16))
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.wantsLayer = true
            runLayer.frame = CGRect(x: 2, y: max(0, (button.bounds.height - 16) / 2), width: 16, height: 16)
            runLayer.magnificationFilter = .nearest
            runLayer.contentsGravity = .resize
            runLayer.contentsScale = 2
            button.layer?.addSublayer(runLayer)
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        model.$system.receive(on: RunLoop.main).sink { [weak self] system in self?.refresh(system) }.store(in: &cancellables)
        model.settings.$menuMetrics.sink { [weak self] _ in self?.lastTitleAt = .distantPast; self?.refresh(self?.model.system ?? SystemSnapshot()) }.store(in: &cancellables)
        applyFrames()
    }

    /// 압박 3단계 × 디스크 배지 조합이 바뀔 때만 키프레임을 다시 만든다.
    private func applyFrames() {
        let pressure = model.system.pressure
        let diskLow = model.system.disk.available > 0 && model.system.disk.available < UInt64(model.settings.diskThresholdGB * Fmt.gib)
        let key = "\(pressure.rawValue)-\(diskLow)"
        guard key != framesKey else { return }
        framesKey = key
        let hoodie: PixelColor = pressure == .critical ? Pal.alarm : pressure == .warning ? PixelColor(0xF2C14E) : PixelColor(0xE8735A)
        let frames: [CGImage] = (0..<4).compactMap { index in
            var canvas = CharacterArt.runner(index, hoodie: hoodie, sweat: pressure != .normal, alert: pressure == .critical)
            if diskLow { canvas.rect(0, 0, 3, 3, Pal.alarm); canvas.dot(1, 1, Pal.white) }
            return canvas.cgImage(scale: 2)
        }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.calculationMode = .discrete
        animation.duration = Double(frames.count) / 2   // 1배속 = 초당 2프레임
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        runLayer.contents = frames.first
        runLayer.add(animation, forKey: "run")
    }

    /// CPU 5%마다 1배속(1~20배). 레이어 시간을 이어 붙여 속도가 바뀌어도 튀지 않게 한다.
    private func setSpeed(_ cpu: Double) {
        let speed = Float(max(1, min(20, (cpu / 5).rounded())))
        guard speed != runLayer.speed else { return }
        let now = CACurrentMediaTime()
        let local = runLayer.convertTime(now, from: nil)
        runLayer.timeOffset = local
        runLayer.beginTime = now
        runLayer.speed = speed
    }

    private func refresh(_ system: SystemSnapshot) {
        applyFrames()
        setSpeed(system.cpuPercent)
        guard let button = item.button else { return }
        // 상주 표시는 4초 간격, 글자가 바뀔 때만. 패널을 열면 매 표본을 반영한다(측정은 1초).
        guard Date().timeIntervalSince(lastTitleAt) >= 4 || popover.isShown else { return }
        // 항목마다 아이콘 + 값(글자만 이어 붙이면 구분이 안 된다는 피드백, 10-24).
        var parts: [(icon: String, value: String)] = []
        for metric in model.settings.menuMetrics {
            switch metric {
            case .cpu: parts.append(("cpu", Fmt.percent(system.cpuPercent)))
            case .memory: parts.append(("memorychip", Fmt.gb(system.memory.available)))
            case .swap: parts.append(("shippingbox", Fmt.gb(system.swap.used)))
            case .disk: parts.append(("internaldrive", Fmt.gb(system.disk.available)))
            case .sessions: parts.append(("person.2.fill", "\(model.office?.workingCount ?? 0)"))
            }
        }
        let key = parts.map { $0.icon + $0.value }.joined(separator: "|")
        lastTitleAt = Date()
        guard key != lastTitle else { return }
        lastTitle = key
        button.attributedTitle = Self.menuTitle(parts)
    }

    /// 메뉴 막대 제목: [아이콘] 값 ␣␣ [아이콘] 값 … 아이콘은 템플릿이라 메뉴 막대 색(밝음·어두움)을 따른다.
    static func menuTitle(_ parts: [(icon: String, value: String)]) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let result = NSMutableAttributedString()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
        for (index, part) in parts.enumerated() {
            result.append(NSAttributedString(string: index == 0 ? " " : "   ", attributes: [.font: font]))
            if let symbol = NSImage(systemSymbolName: part.icon, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                symbol.isTemplate = true
                let attachment = NSTextAttachment()
                attachment.image = symbol
                attachment.bounds = CGRect(x: 0, y: -1.5, width: symbol.size.width, height: symbol.size.height)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: "\u{2009}", attributes: [.font: font]))
            }
            result.append(NSAttributedString(string: part.value, attributes: [.font: font]))
        }
        return result
    }

    @objc private func toggle() { togglePanel() }

    func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            // 닫혀 있을 때 SwiftUI가 매초 다시 그리지 않도록 열 때 만들고 닫으면 버린다.
            let hosting = NSHostingController(rootView: MenuPanelView(model: model, openOffice: { [weak self] in self?.openOffice() },
                                                                      openSettings: { [weak self] in self?.popover.performClose(nil); self?.onSettings?() },
                                                                      quit: { (NSApp.delegate as? AppDelegate)?.quitForReal() }))
            // 내용 높이가 열린 뒤 바뀌면 창이 위로 자라 메뉴 막대 위로 잘렸다(0.1.1 실제 화면).
            // 크기를 먼저 확정하고, 이후 변화는 preferredContentSize로 팝오버가 기준점(아래쪽)에 맞춰 조정하게 한다.
            hosting.sizingOptions = [.preferredContentSize]
            hosting.view.layoutSubtreeIfNeeded()
            popover.contentViewController = hosting
            popover.contentSize = hosting.view.fittingSize
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            model.monitor.refreshNow()   // 백그라운드 주기(15초)와 상관없이 패널을 열 때 바로 갱신
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }

    private func openOffice() {
        let rect = item.button?.window.map { $0.convertToScreen(item.button!.convert(item.button!.bounds, to: nil)) }
        popover.performClose(nil)
        onOpenOffice?(rect)
    }
}

/// 컨셉샷 c1의 클릭 패널.
struct MenuPanelView: View {
    @ObservedObject var model: AppModel
    var openOffice: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void

    var body: some View {
        let system = model.system
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: CharacterArt.worker(.seeded(3, hoodie: PixelColor(0xE8735A)), .wave(0)).nsImage())
                    .interpolation(.none).resizable().frame(width: 36, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ReMON").font(.system(size: 17, weight: .bold))
                    Text("메모리 압박 \(system.pressure.label)").font(.system(size: 12)).foregroundStyle(pressureColor(system.pressure))
                }
                Spacer()
                Text(Fmt.percent(system.cpuPercent)).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("메모리 여유").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(Fmt.gb(system.memory.available)) / \(Fmt.gb(system.memory.physical))").font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(system.pressure == .critical ? .red : system.pressure == .warning ? .orange : .primary)
                }
                MemoryBar(memory: system.memory).frame(height: 8)
                Text("압축 \(Fmt.gb(system.memory.compressed)) · 스왑 \(Fmt.gb(system.swap.used))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("디스크 여유").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(Fmt.gb(system.disk.available)).font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(system.disk.available < UInt64(model.settings.diskThresholdGB * Fmt.gib) ? .red : .primary)
                }
                Sparkline(values: model.history.suffix(60).map { Double($0.diskAvailable) / Fmt.gib }).frame(height: 30)
            }
            Divider()
            HStack {
                Text("세션").font(.system(size: 13, weight: .semibold))
                Spacer()
                ForEach(AgentKind.allCases + AgentCatalog.shared.current.custom.map(\.kind), id: \.self) { kind in   // 직접 추가한 종류도 점으로
                    if model.office?.sessions.contains(where: { $0.kind == kind }) == true {
                        Circle().fill(Color(nsColor: TeamColor.ns(kind))).frame(width: 8, height: 8)
                    }
                }
                Text("일하는 중 \(model.office?.workingCount ?? 0) · 쉬는 중 \(model.office?.restingCount ?? 0)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("정리 제안").font(.system(size: 13, weight: .semibold))
                // 제안 수(0~3)에 따라 높이가 바뀌지 않게 세 줄 자리를 늘 비워 둔다.
                VStack(alignment: .leading, spacing: 4) {
                    if model.suggestions.isEmpty {
                        Text(model.diskScanning ? "디스크를 살펴보는 중…" : "지금은 정리할 것이 거의 없습니다").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(model.suggestions.prefix(3)) { suggestion in
                        HStack {
                            Text(suggestion.title).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text(Fmt.gb(suggestion.reclaimBytes)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                        }
                    }
                }
                .frame(height: 62, alignment: .top)
            }
            Button(action: openOffice) {
                Text("AI 사무실 열기").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            HStack {
                Button("설정…", action: openSettings).buttonStyle(.link)
                Spacer()
                Button("완전히 종료…", action: quit).buttonStyle(.link).foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        }
        .padding(16)
        .frame(width: 360)
    }

    private func pressureColor(_ level: PressureLevel) -> Color {
        switch level {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// 앱 메모리 · 와이어드 · 압축 비율 막대.
struct MemoryBar: View {
    let memory: MemoryStats

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, Double(memory.physical))
            let segments: [(Double, Color)] = [(Double(memory.appMemory), .blue), (Double(memory.wired), Color(red: 0.95, green: 0.55, blue: 0.5)), (Double(memory.compressed), Color(red: 0.4, green: 0.82, blue: 0.68))]
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: 3).fill(segment.1).frame(width: max(2, proxy.size.width * segment.0 / total))
                }
                Spacer(minLength: 0)
            }
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
        }
    }
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            if values.count > 1, let low = values.min(), let high = values.max() {
                let range = max(0.1, high - low)
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                        let y = proxy.size.height * (1 - CGFloat((value - low) / range))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            } else {
                Text("기록이 쌓이는 중(1분 간격)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}
