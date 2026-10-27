import AppKit
import CoreGraphics

/// RGBA 8bit 색. 팔레트는 참고 사진(크림 벽·헤링본 오크·월넛·트래버틴·머스터드·포레스트 그린)에서 뽑았다.
struct PixelColor: Equatable, Hashable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255

    init(_ hex: UInt32, alpha: UInt8 = 255) {
        r = UInt8((hex >> 16) & 0xFF)
        g = UInt8((hex >> 8) & 0xFF)
        b = UInt8(hex & 0xFF)
        a = alpha
    }

    init(r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    static let clear = PixelColor(r: 0, g: 0, b: 0, a: 0)

    func darker(_ amount: Double = 0.18) -> PixelColor {
        PixelColor(r: UInt8(Double(r) * (1 - amount)), g: UInt8(Double(g) * (1 - amount)), b: UInt8(Double(b) * (1 - amount)), a: a)
    }

    func lighter(_ amount: Double = 0.18) -> PixelColor {
        func up(_ v: UInt8) -> UInt8 { UInt8(min(255, Double(v) + (255 - Double(v)) * amount)) }
        return PixelColor(r: up(r), g: up(g), b: up(b), a: a)
    }

    func with(alpha: UInt8) -> PixelColor { PixelColor(r: r, g: g, b: b, a: alpha) }

    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255) }
}

enum Pal {
    static let outline = PixelColor(0x2B2420)
    static let cream = PixelColor(0xF3E9D7)
    static let creamShade = PixelColor(0xE4D5BA)
    static let doorWhite = PixelColor(0xFBF7EF)
    static let doorShade = PixelColor(0xDCD2C0)
    static let gold = PixelColor(0xC9A24A)
    static let oak = PixelColor(0xC98F55)
    static let oakMid = PixelColor(0xB07642)
    static let oakDark = PixelColor(0x8E5A31)
    static let walnut = PixelColor(0x7A4A2A)
    static let walnutDark = PixelColor(0x5C351D)
    static let walnutLight = PixelColor(0x95603A)
    static let travertine = PixelColor(0xE8DCC4)
    static let travertineSpeck = PixelColor(0xD3C3A4)
    static let mustard = PixelColor(0xE3B23C)
    static let mustardShade = PixelColor(0xBF912A)
    static let forest = PixelColor(0x2F5D3A)
    static let forestShade = PixelColor(0x224529)
    static let teak = PixelColor(0x9C5B2E)
    static let terracotta = PixelColor(0xE07A5F)
    static let leaf = PixelColor(0x4C9A4A)
    static let leafDark = PixelColor(0x2F6B33)
    static let leafLight = PixelColor(0x79C26A)
    static let skyTop = PixelColor(0x8FD0F2)
    static let skyBottom = PixelColor(0xD3F0FF)
    static let cloud = PixelColor(0xFFFFFF)
    static let glass = PixelColor(0xBFE6F2, alpha: 200)
    static let concrete = PixelColor(0xC7C2B8)
    static let concreteDark = PixelColor(0xA39E95)
    static let cardboard = PixelColor(0xC89B61)
    static let cardboardShade = PixelColor(0xA47A45)
    static let tape = PixelColor(0xE9CF97)
    static let metal = PixelColor(0x7C858F)
    static let metalLight = PixelColor(0xA9B2BC)
    static let water = PixelColor(0x4FC3D9)
    static let waterLight = PixelColor(0x9BE7F3)
    static let skin = PixelColor(0xF4CDA5)
    static let skinShade = PixelColor(0xDDA57A)
    static let blush = PixelColor(0xF39A9A)
    static let eye = PixelColor(0x2A2230)
    static let pants = PixelColor(0x3A3F55)
    static let pantsShade = PixelColor(0x2C3042)
    static let shoe = PixelColor(0xF5F5F2)
    static let shoeShade = PixelColor(0xC9C9C4)
    static let navy = PixelColor(0x2C3E66)
    static let navyShade = PixelColor(0x1F2D4C)
    static let badge = PixelColor(0xE5C04B)
    static let magenta = PixelColor(0xE0408A)
    static let magentaShade = PixelColor(0xB52E6D)
    static let robot = PixelColor(0xF4F6F8)
    static let robotShade = PixelColor(0xC3CDD7)
    static let robotEye = PixelColor(0x39D5F0)
    static let ghost = PixelColor(0xF4F7FF, alpha: 190)
    static let ghostShade = PixelColor(0xC9D3EE, alpha: 190)
    static let alarm = PixelColor(0xE5484D)
    static let monitorOn = PixelColor(0x9FE3FF)
    static let monitorOff = PixelColor(0x3B4250)
    static let screenLine = PixelColor(0x4F86C6)
    static let white = PixelColor(0xFFFFFF)
    static let black = PixelColor(0x1C1A1E)
    static let paper = PixelColor(0xFFFDF6)
    static let hairs: [PixelColor] = [PixelColor(0x4A3022), PixelColor(0x2A2A34), PixelColor(0x7A4E2D), PixelColor(0x3B2A4A), PixelColor(0x8C5A3C), PixelColor(0x1E1E26)]
}

/// 왼쪽 위 원점(y 아래로)의 픽셀 캔버스. CGImage로 내보낼 때 정수 배율로 키운다.
struct PixelCanvas {
    let width: Int
    let height: Int
    private(set) var pixels: [PixelColor]

    init(_ width: Int, _ height: Int, fill: PixelColor = .clear) {
        self.width = width
        self.height = height
        pixels = Array(repeating: fill, count: width * height)
    }

    subscript(x: Int, y: Int) -> PixelColor {
        get { (x >= 0 && y >= 0 && x < width && y < height) ? pixels[y * width + x] : .clear }
        set {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            if newValue.a == 255 || pixels[y * width + x].a == 0 {
                pixels[y * width + x] = newValue
            } else if newValue.a > 0 {
                pixels[y * width + x] = Self.blend(newValue, over: pixels[y * width + x])
            }
        }
    }

    static func blend(_ top: PixelColor, over bottom: PixelColor) -> PixelColor {
        let a = Double(top.a) / 255
        func mix(_ t: UInt8, _ b: UInt8) -> UInt8 { UInt8(Double(t) * a + Double(b) * (1 - a)) }
        return PixelColor(r: mix(top.r, bottom.r), g: mix(top.g, bottom.g), b: mix(top.b, bottom.b), a: max(top.a, bottom.a))
    }

    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: PixelColor) {
        guard w > 0, h > 0 else { return }
        for yy in y..<(y + h) { for xx in x..<(x + w) { self[xx, yy] = color } }
    }

    mutating func hline(_ x: Int, _ y: Int, _ w: Int, _ color: PixelColor) { rect(x, y, w, 1, color) }
    mutating func vline(_ x: Int, _ y: Int, _ h: Int, _ color: PixelColor) { rect(x, y, 1, h, color) }

    /// 테두리 + 채우기(모서리 1px 깎음).
    mutating func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int, fill: PixelColor, outline: PixelColor = Pal.outline, rounded: Bool = true) {
        rect(x + 1, y + 1, w - 2, h - 2, fill)
        hline(x + (rounded ? 1 : 0), y, w - (rounded ? 2 : 0), outline)
        hline(x + (rounded ? 1 : 0), y + h - 1, w - (rounded ? 2 : 0), outline)
        vline(x, y + (rounded ? 1 : 0), h - (rounded ? 2 : 0), outline)
        vline(x + w - 1, y + (rounded ? 1 : 0), h - (rounded ? 2 : 0), outline)
    }

    mutating func dot(_ x: Int, _ y: Int, _ color: PixelColor) { self[x, y] = color }

    /// 다른 캔버스를 (x, y)에 겹친다.
    mutating func stamp(_ other: PixelCanvas, _ x: Int, _ y: Int) {
        for yy in 0..<other.height { for xx in 0..<other.width {
            let color = other[xx, yy]
            if color.a > 0 { self[x + xx, y + yy] = color }
        } }
    }

    func flippedHorizontally() -> PixelCanvas {
        var copy = PixelCanvas(width, height)
        for y in 0..<height { for x in 0..<width { copy.pixels[y * width + (width - 1 - x)] = pixels[y * width + x] } }
        return copy
    }

    /// 90° 반시계 회전(눕기 자세). 픽셀이 정확히 보존된다.
    func rotatedLeft() -> PixelCanvas {
        var copy = PixelCanvas(height, width)
        for y in 0..<height { for x in 0..<width { copy.pixels[(width - 1 - x) * height + y] = pixels[y * width + x] } }
        return copy
    }

    func cgImage(scale: Int = 1) -> CGImage? {
        let w = width * scale, h = height * scale
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let color = pixels[(y / scale) * width + (x / scale)]
            let index = (y * w + x) * 4
            let alpha = Double(color.a) / 255
            bytes[index] = UInt8(Double(color.r) * alpha)
            bytes[index + 1] = UInt8(Double(color.g) * alpha)
            bytes[index + 2] = UInt8(Double(color.b) * alpha)
            bytes[index + 3] = color.a
        } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 메뉴 막대용: 포인트 크기 = 픽셀 크기, 실제 비트맵은 2배(Retina에서 또렷하게).
    func nsImage() -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height))
        if let cg = cgImage(scale: 2) {
            let rep = NSBitmapImageRep(cgImage: cg)
            rep.size = NSSize(width: width, height: height)
            image.addRepresentation(rep)
        }
        return image
    }
}
