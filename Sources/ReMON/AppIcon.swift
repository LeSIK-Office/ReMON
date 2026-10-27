import AppKit

/// 앱 아이콘: 엄지척(따봉) 하는 픽셀 직원(32×32 픽셀을 정수 배율로 키운다).
/// - 번들 아이콘(Resources/ReMON.icns): 기본 직원(코랄 후드 · 하늘 배경). `scripts/generate-icon.swift`가 `ReMON --render-icon`으로 만든다.
/// - 실행 중 아이콘(Dock · 알림창): 사용자마다 다른 무작위 직원. 첫 실행 때 씨앗을 만들어 UserDefaults("iconSeed")에 둔다.
/// 서명된 앱 번들은 건드리지 않는다 — NSApp.applicationIconImage만 바꾼다(번들 아이콘 파일을 고치면 서명 봉인이 깨진다).
enum AppIcon {
    static let seedKey = "iconSeed"
    static let pixels = 32

    /// 사용자 아이콘 씨앗: 저장된 값이 있으면 그대로, 없으면 한 번 만들어 저장한다.
    /// `-iconSeed 123` 실행 인자로 다른 씨앗을 볼 수 있다(인자 도메인이라 저장되지 않는다).
    @MainActor static var seed: Int {
        let defaults = UserDefaults.standard
        let stored = defaults.integer(forKey: seedKey)   // 없으면 0(씨앗은 1 이상만 만든다)
        if stored != 0 { return stored }
        let fresh = Int.random(in: 1...Int(Int32.max))
        defaults.set(fresh, forKey: seedKey)
        return fresh
    }

    /// 이 사용자의 아이콘(512px). 정보 탭 등 다른 화면에서도 그대로 쓴다.
    @MainActor static let userImage: NSImage = image(canvas(seed: seed))

    /// Dock · 알림창 아이콘을 사용자 아이콘으로. 메뉴 막대 상주(.accessory)일 때는 Dock에 보이지 않다가 사무실 창을 열면 보인다.
    /// .accessory → .regular로 바뀌며 Dock 타일이 새로 생길 때 번들 아이콘으로 돌아가는 경우가 있어, 전환을 처음 본 순간(활성화·창 키) 한 번 더 건다.
    @MainActor static func apply() {
        NSApp.applicationIconImage = userImage
        guard observers.isEmpty else { return }
        let reapply: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated {
                let regular = NSApp.activationPolicy() == .regular
                if regular && !shownInDock { NSApp.applicationIconImage = userImage }
                shownInDock = regular
            }
        }
        // 창을 닫으면 .accessory로 돌아가며 비활성화된다 → 그때 '안 보임'으로 되돌려 두면 다음에 열 때 다시 건다.
        observers = [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, NSWindow.didBecomeKeyNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main, using: reapply)
        }
    }

    @MainActor private static var observers: [NSObjectProtocol] = []
    @MainActor private static var shownInDock = false

    /// 번들 아이콘의 기본 직원(메뉴 막대 달리는 직원과 같은 코랄 후드).
    static let defaultLook = WorkerLook(hoodie: PixelColor(0xE8735A), hair: Pal.hairs[0], hairStyle: 0)

    static let outfits: [PixelColor] = [PixelColor(0xE8735A), PixelColor(0x2BA59B), PixelColor(0x5B7BD5), PixelColor(0x9C7AD8), PixelColor(0xD9A441),
                                         PixelColor(0xE0408A), PixelColor(0x2E5E8C), PixelColor(0x4FB6A8), PixelColor(0xF2C14E), PixelColor(0x3FA34D)]
    /// 배경(위 · 아래 · 테두리): 하늘 · 노을 · 민트 · 라벤더 · 레몬 · 밤.
    static let backgrounds: [(PixelColor, PixelColor, PixelColor)] = [
        (PixelColor(0x8FD0F2), PixelColor(0xD3F0FF), PixelColor(0x4E8FB8)),
        (PixelColor(0xF7A88A), PixelColor(0xFFE3C2), PixelColor(0xC2705A)),
        (PixelColor(0x8EDDC4), PixelColor(0xD9F7EC), PixelColor(0x4FA088)),
        (PixelColor(0xB9A8EC), PixelColor(0xE9E2FB), PixelColor(0x7A68B8)),
        (PixelColor(0xF7D86A), PixelColor(0xFFF5C8), PixelColor(0xC2A033)),
        (PixelColor(0x2D3E6E), PixelColor(0x4A5F9A), PixelColor(0x1C2747)),
    ]

    /// 씨앗 → 직원 외형(성별·피부·머리·옷·안경은 WorkerLook.seeded 규칙 그대로, 팀 명찰은 뺀다).
    static func look(seed: Int) -> WorkerLook {
        var look = WorkerLook.seeded(seed, hoodie: outfits[abs(seed / 3) % outfits.count])
        look.accent = .clear
        return look
    }

    static func canvas(seed: Int) -> PixelCanvas { canvas(look: look(seed: seed), background: abs(seed / 11) % backgrounds.count) }

    /// 32×32 아이콘: 둥근 사각(macOS 아이콘 격자처럼 가장자리 3px 여백) · 그러데이션 배경 · 마루 띠 · 엄지척 직원 · 반짝이.
    static func canvas(look: WorkerLook, background: Int) -> PixelCanvas {
        let (top, bottom, border) = backgrounds[background % backgrounds.count]
        let n = pixels, lo = 3, hi = n - 3, radius = 5.5
        func inside(_ x: Int, _ y: Int) -> Bool {
            let px = Double(x) + 0.5, py = Double(y) + 0.5
            let cx = min(max(px, Double(lo) + radius), Double(hi) - radius), cy = min(max(py, Double(lo) + radius), Double(hi) - radius)
            return (px - cx) * (px - cx) + (py - cy) * (py - cy) <= radius * radius
        }
        var art = PixelCanvas(n, n)
        // 배경: 6단 띠 그러데이션(픽셀 느낌)
        for y in 0..<n {
            let t = Double(Int(Double(y - lo) / Double(hi - lo) * 6)) / 5
            let mix = { (a: UInt8, b: UInt8) in UInt8(max(0, min(255, Double(a) + (Double(b) - Double(a)) * min(1, max(0, t))))) }
            art.hline(0, y, n, PixelColor(r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b)))
        }
        if background == 5 {   // 밤: 별 + 달
            for (x, y) in [(6, 7), (10, 5), (24, 9), (8, 12), (26, 15)] { art.dot(x, y, Pal.white.with(alpha: 220)) }
            art.rect(5, 5, 3, 3, PixelColor(0xF5F0D0)); art.dot(7, 5, top)
        } else {               // 낮: 구름
            art.rect(4, 7, 5, 2, Pal.white); art.rect(5, 6, 3, 1, Pal.white)
        }
        // 마루 띠(사무실 헤링본)
        for y in 24..<n { for x in 0..<n { art.dot(x, y, [Pal.oak, Pal.oakMid, Pal.oakDark.lighter(0.15)][((x + y) / 3 + (x - y + 64) / 3) % 3]) } }
        art.hline(0, 24, n, Pal.oak.lighter(0.3))
        // 엄지척 직원(무릎 아래는 아이콘 테두리에서 잘린다) + 반짝이
        art.stamp(CharacterArt.worker(look, .thumbsUp), 6, 6)
        for (x, y) in [(25, 4), (24, 5), (25, 5), (26, 5), (25, 6)] { art.dot(x, y, Pal.white) }
        art.dot(25, 5, PixelColor(0xFFE27A)); art.dot(27, 9, Pal.white); art.dot(19, 4, PixelColor(0xFFE27A))
        // 둥근 사각으로 자르고 테두리
        var c = PixelCanvas(n, n)
        for y in 0..<n { for x in 0..<n where inside(x, y) {
            let edge = !inside(x - 1, y) || !inside(x + 1, y) || !inside(x, y - 1) || !inside(x, y + 1)
            c.dot(x, y, edge ? border : art[x, y])
        } }
        return c
    }

    /// 정수 배율(×16 = 512px) NSImage.
    static func image(_ canvas: PixelCanvas, scale: Int = 16) -> NSImage {
        let side = canvas.width * scale
        let image = NSImage(size: NSSize(width: side, height: side))
        if let cg = canvas.cgImage(scale: scale) {
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: side, height: side)
            image.addRepresentation(rep)
        }
        return image
    }

    /// 개발용: `ReMON --render-icon <폴더.iconset> [--icon-seed N]` → iconset PNG 10장(기본 직원, 씨앗을 주면 그 사용자 아이콘).
    /// 16px만 32px 그림을 반으로 평균해 줄이고, 나머지는 정수 배율로 키운다.
    static func writeIconset(to folder: String, seed: Int?) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let art = seed.map { canvas(seed: $0) } ?? canvas(look: defaultLook, background: 0)
        for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                             ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
            guard var image = art.cgImage(scale: max(1, size / art.width)) else { continue }
            if image.width != size, let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
                if let scaled = context.makeImage() { image = scaled }
            }
            let path = (folder as NSString).appendingPathComponent("icon_\(name).png")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        print("iconset: \(folder) seed=\(seed.map(String.init) ?? "default")")
    }
}
