import Foundation

/// 직원 외형. 후드 색 = 팀, 머리 모양·색은 세션마다 고정(pid 기반 결정적 선택).
struct WorkerLook: Hashable {
    var hoodie: PixelColor
    var hair: PixelColor
    /// 0 짧은 머리, 1 올림머리, 2 삐죽 머리, 3 단발, 4 대머리, 5 덥수룩, 6 긴 머리, 7 포니테일, 8 짧게 민 머리
    var hairStyle: Int
    var skin: PixelColor = Pal.skin
    /// 퇴근 못 한 날수에 따른 몰골: 0 말끔, 1 까칠(수염 자국·헝클어진 머리), 2 덥수룩(수염·때·꼬질)
    var scruff: Int = 0
    var glasses = false
    var tie = false
    /// 옷: 0 후드, 1 셔츠, 2 니트, 3 재킷, 4 줄무늬 티
    var outfit: Int = 0
    /// 팀(에이전트 종류) 색 명찰 — 옷이 무작위여도 Claude·Codex를 구분하게 한다. clear면 없음.
    var accent: PixelColor = .clear
    var feminine = false
    var freckles = false

    static let skins: [PixelColor] = [PixelColor(0xFBE3CF), PixelColor(0xF4CDA5), PixelColor(0xE7B48C), PixelColor(0xC98E63), PixelColor(0x9C6844), PixelColor(0x6B4430)]
    static let hairColors: [PixelColor] = Pal.hairs + [PixelColor(0xD9B26A), PixelColor(0xB5532E), PixelColor(0x9A9A9E), PixelColor(0x6A4FA0), PixelColor(0x3E7CB1)]
    static let fashion: [PixelColor] = [PixelColor(0x3A4256), PixelColor(0x6B7280), PixelColor(0xE9E4D8), PixelColor(0x2B2D42), PixelColor(0xC2A27A), PixelColor(0x4F6D5A), PixelColor(0x8E4A5E), PixelColor(0x2E5E8C)]

    /// 세션마다 고정된 무작위 외형(같은 세션이면 출근~퇴근 동안 같다). seed = pid + 시작 시각.
    static func seeded(_ seed: Int, hoodie team: PixelColor) -> WorkerLook {
        func roll(_ salt: Int, _ count: Int) -> Int {
            var value = UInt64(bitPattern: Int64(seed)) &+ UInt64(salt) &* 0x9E37_79B9_7F4A_7C15
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((value ^ (value >> 31)) % UInt64(max(1, count)))
        }
        let feminine = roll(1, 2) == 0
        let styles = feminine ? [1, 3, 6, 6, 7, 7, 0] : [0, 0, 2, 4, 5, 8, 3]
        let hair = hairColors[roll(3, hairColors.count)]
        let skin = skins[roll(4, skins.count)]
        let outfit = roll(5, 5)
        // 옷 색: 절반은 팀 색 계열(밝게·어둡게), 절반은 무난한 옷 색. 명찰은 늘 팀 색.
        let clothes: PixelColor
        switch roll(6, 4) {
        case 0: clothes = team
        case 1: clothes = team.darker(0.18)
        case 2: clothes = team.lighter(0.15)
        default: clothes = fashion[roll(7, fashion.count)]
        }
        return WorkerLook(hoodie: clothes, hair: hair, hairStyle: styles[roll(2, styles.count)], skin: skin, glasses: roll(8, 5) == 0,
                          outfit: outfit, accent: team, feminine: feminine, freckles: roll(9, 7) == 0)
    }

    /// 실행 시간(초) → 몰골 단계. 하루 넘으면 까칠, 사흘 넘으면 덥수룩.
    static func scruff(forAge seconds: TimeInterval) -> Int { seconds >= 3 * 86_400 ? 2 : seconds >= 86_400 ? 1 : 0 }

    func aged(_ seconds: TimeInterval) -> WorkerLook {
        var copy = self
        copy.scruff = Self.scruff(forAge: seconds)
        if copy.scruff == 2 { copy.skin = skin.darker(0.08) }
        return copy
    }
}

enum Eyes { case open, closed, wide, happy }
enum Mouth { case none, smile, open, shout }

enum WorkerPose: Equatable {
    case stand(blink: Bool)
    case walk(Int)
    case sitType(Int)
    case sitWait
    case sleepDesk(Int)
    case kick(Int)
    case dragged(Int)
    case pushup(Int)
    case jumpingJack(Int)
    case wave(Int)
    case carry(Int)
    case shout(Int)
    case lie
    /// 수영(물 위로 머리·팔만, 2프레임)
    case swim(Int)
    /// 강당에서 시무룩하게 앉음(어깨 처짐·고개 숙임)
    case sitSad
    /// 책 읽기(의자)
    case read(Int)
    /// 빗자루질(청소 인력, 2프레임)
    case sweep(Int)
    /// 손가락질하며 혼내기(감사관, 2프레임)
    case scold(Int)
    /// 박수(칭찬, 2프레임)
    case clap(Int)
    /// 엄지척(따봉) — 앱 아이콘의 직원 자세
    case thumbsUp
    /// 두 팔을 앞으로 뻗고 걷기(짐꾼이 수레를 민다, 4프레임)
    case push(Int)
    /// 무릎 꿇고 전동 드라이버질(설치 기사가 볼트를 조이고 전원선을 뽑는다, 2프레임)
    case kneel(Int)
    /// 지렛대로 나무 상자 비틀어 열기(2프레임)
    case pry(Int)
    /// 사다리 오르기(기록관, 2프레임) — 오른쪽(선반)을 보고 팔을 번갈아 든다
    case climb(Int)
    /// 물걸레질(청소 인력, 2프레임)
    case mop(Int)
    /// 디제잉(DJ, 2프레임): 앞팔은 턴테이블 위를 문지르고 뒤팔은 머리 위로 흔든다. 고개도 박자에 까딱.
    case scratch(Int)
    /// 물속 춤(파티 중 수영하던 직원, 2프레임): 수영처럼 아래는 물속 — 머리 · 등 위로 두 팔을 번갈아 흔든다.
    case splash(Int)
}

/// 옆에서 본 사무실의 직원 스프라이트(오른쪽을 봄). 기본 캔버스 16×24, 아래 가운데가 발 위치.
enum CharacterArt {
    // MARK: 부위

    static func head(_ c: inout PixelCanvas, _ ox: Int, _ oy: Int, look: WorkerLook, eyes: Eyes = .open, mouth: Mouth = .smile) {
        let o = Pal.outline, k = look.hair, s = look.skin
        // 윤곽(12×11, 모서리 둥글게)
        c.hline(ox + 2, oy, 8, o)
        c.dot(ox + 1, oy + 1, o); c.dot(ox + 10, oy + 1, o)
        c.vline(ox, oy + 2, 7, o); c.vline(ox + 11, oy + 2, 7, o)
        c.dot(ox + 1, oy + 9, o); c.dot(ox + 10, oy + 9, o)
        c.hline(ox + 2, oy + 10, 8, o)
        // 머리카락과 얼굴
        c.rect(ox + 2, oy + 1, 8, 1, k)
        c.rect(ox + 1, oy + 2, 10, 4, k)
        c.rect(ox + 1, oy + 6, 2, 3, k)        // 뒤통수(왼쪽)
        c.rect(ox + 3, oy + 5, 8, 5, s)
        c.rect(ox + 2, oy + 9, 8, 1, s)
        // 앞머리
        c.dot(ox + 3, oy + 5, k); c.dot(ox + 4, oy + 5, k); c.dot(ox + 6, oy + 5, k); c.dot(ox + 9, oy + 5, k)
        // 하이라이트
        c.dot(ox + 4, oy + 2, k.lighter(0.25)); c.dot(ox + 5, oy + 2, k.lighter(0.25))
        switch look.hairStyle {
        case 1: c.box(ox + 1, oy - 3, 5, 4, fill: k)                                   // 올림머리
        case 2: c.dot(ox + 3, oy - 1, k); c.dot(ox + 6, oy - 1, k); c.dot(ox + 9, oy - 1, k); c.dot(ox + 3, oy - 1, o) // 삐죽
        case 3: c.rect(ox + 1, oy + 6, 2, 4, k); c.dot(ox + 11, oy + 6, k)              // 단발
        case 4:                                                                          // 대머리: 머리카락 자리를 피부로, 옆머리만
            c.rect(ox + 2, oy + 1, 8, 1, s); c.rect(ox + 1, oy + 2, 10, 4, s)
            c.rect(ox + 1, oy + 5, 2, 3, k); c.dot(ox + 10, oy + 5, k)
            c.dot(ox + 4, oy + 2, s.lighter(0.3)); c.dot(ox + 5, oy + 2, s.lighter(0.3))
            c.dot(ox + 3, oy + 5, s); c.dot(ox + 4, oy + 5, s); c.dot(ox + 6, oy + 5, s); c.dot(ox + 9, oy + 5, s)
        case 5:                                                                          // 덥수룩: 삐죽삐죽 사방으로
            c.dot(ox + 2, oy - 1, k); c.dot(ox + 4, oy - 2, k); c.dot(ox + 5, oy - 1, k); c.dot(ox + 7, oy - 2, k); c.dot(ox + 8, oy - 1, k); c.dot(ox + 10, oy - 1, k)
            c.dot(ox, oy + 3, k); c.dot(ox + 12, oy + 4, k); c.rect(ox + 1, oy + 6, 2, 4, k); c.dot(ox + 11, oy + 6, k)
        case 6:                                                                          // 긴 머리: 어깨까지 양옆으로
            c.rect(ox, oy + 4, 2, 9, k); c.rect(ox + 1, oy + 6, 2, 8, k); c.rect(ox + 10, oy + 5, 2, 7, k)
            c.dot(ox + 11, oy + 12, k)
        case 7:                                                                          // 포니테일: 뒤로 묶은 꼬리
            c.rect(ox - 2, oy + 3, 3, 2, k); c.rect(ox - 3, oy + 5, 3, 5, k); c.dot(ox - 2, oy + 10, k)
            c.dot(ox, oy + 3, Pal.terracotta)                                          // 머리끈
        case 8:                                                                          // 짧게 민 머리: 머리카락이 얇게
            c.rect(ox + 2, oy + 1, 8, 1, k.lighter(0.25)); c.rect(ox + 1, oy + 2, 10, 2, k.lighter(0.3))
            c.rect(ox + 1, oy + 4, 10, 1, s)
        default: break
        }
        if look.feminine {
            c.dot(ox + 5, oy + 5, Pal.eye); c.dot(ox + 10, oy + 5, Pal.eye)              // 속눈썹
        }
        if look.freckles {
            c.dot(ox + 4, oy + 7, s.darker(0.25)); c.dot(ox + 9, oy + 8, s.darker(0.25))
        }
        // 몰골: 1 = 수염 자국 · 다크서클, 2 = 수염 · 헝클어진 앞머리 · 때
        if look.scruff >= 1 {
            let stubble = k.with(alpha: look.scruff == 1 ? 110 : 255)
            c.dot(ox + 5, oy + 10, stubble); c.dot(ox + 7, oy + 10, stubble); c.dot(ox + 9, oy + 10, stubble)
            c.hline(ox + 6, oy + 8, 1, Pal.eye.with(alpha: 70)); c.hline(ox + 9, oy + 8, 1, Pal.eye.with(alpha: 70))
        }
        if look.scruff >= 2 {
            c.rect(ox + 4, oy + 10, 6, 2, k); c.dot(ox + 3, oy + 10, k); c.dot(ox + 10, oy + 10, k); c.hline(ox + 5, oy + 12, 4, k)
            c.dot(ox + 5, oy - 1, k); c.dot(ox + 8, oy - 1, k); c.dot(ox + 11, oy + 3, k)
            c.dot(ox + 3, oy + 6, PixelColor(0x8B7B5E, alpha: 140)); c.dot(ox + 9, oy + 4, PixelColor(0x8B7B5E, alpha: 120))
        }
        if look.glasses {
            c.hline(ox + 5, oy + 6, 2, Pal.outline); c.hline(ox + 8, oy + 6, 2, Pal.outline); c.dot(ox + 7, oy + 6, Pal.outline)
            c.dot(ox + 5, oy + 7, Pal.outline); c.dot(ox + 9, oy + 7, Pal.outline)
        }
        // 눈·볼·입
        let e = Pal.eye
        switch eyes {
        case .open: c.vline(ox + 6, oy + 6, 2, e); c.vline(ox + 9, oy + 6, 2, e)
        case .wide: c.rect(ox + 5, oy + 6, 2, 2, e); c.rect(ox + 8, oy + 6, 2, 2, e); c.dot(ox + 5, oy + 6, Pal.white); c.dot(ox + 8, oy + 6, Pal.white)
        case .closed: c.hline(ox + 5, oy + 7, 2, e); c.hline(ox + 8, oy + 7, 2, e)
        case .happy: c.dot(ox + 5, oy + 7, e); c.dot(ox + 6, oy + 6, e); c.dot(ox + 7, oy + 7, e); c.dot(ox + 8, oy + 7, e); c.dot(ox + 9, oy + 6, e); c.dot(ox + 10, oy + 7, e)
        }
        c.dot(ox + 4, oy + 8, Pal.blush); c.dot(ox + 10, oy + 8, Pal.blush)
        switch mouth {
        case .smile: c.hline(ox + 7, oy + 9, 2, look.feminine ? PixelColor(0xC2526A) : look.skin.darker(0.35))
        case .open: c.rect(ox + 7, oy + 8, 2, 2, Pal.eye); c.dot(ox + 7, oy + 9, Pal.blush)
        case .shout: c.rect(ox + 6, oy + 8, 4, 2, Pal.eye); c.hline(ox + 7, oy + 9, 2, Pal.terracotta)
        case .none: break
        }
    }

    static func torso(_ c: inout PixelCanvas, _ bx: Int, _ by: Int, look: WorkerLook, height: Int = 7) {
        let h = look.hoodie
        c.box(bx, by, 8, height, fill: h, rounded: false)
        c.vline(bx + 1, by + 1, height - 2, h.darker(0.15))
        if look.tie {
            c.rect(bx + 3, by + 1, 2, 4, PixelColor(0xC0392B)); c.dot(bx + 3, by + 1, PixelColor(0xE74C3C))   // 넥타이
        } else {
            switch look.outfit {
            case 1:                                                                   // 셔츠: 흰 깃 + 단추
                c.dot(bx + 2, by + 1, Pal.white); c.dot(bx + 5, by + 1, Pal.white); c.dot(bx + 3, by + 2, Pal.white); c.dot(bx + 4, by + 2, Pal.white)
                for y in stride(from: by + 3, to: by + height - 1, by: 2) { c.dot(bx + 4, y, h.darker(0.3)) }
            case 2:                                                                   // 니트: 짜임 줄
                for y in stride(from: by + 2, to: by + height - 1, by: 2) { c.hline(bx + 2, y, 5, h.lighter(0.12)) }
                c.hline(bx + 1, by + height - 2, 6, h.darker(0.2))
            case 3:                                                                   // 재킷: 어두운 옷깃 + 안쪽 셔츠
                c.vline(bx + 2, by + 1, height - 2, h.darker(0.3)); c.vline(bx + 5, by + 1, height - 2, h.darker(0.3))
                c.rect(bx + 3, by + 1, 2, 3, Pal.white)
            case 4:                                                                   // 줄무늬 티
                for y in stride(from: by + 2, to: by + height - 1, by: 2) { c.hline(bx + 1, y, 6, h.lighter(0.3)) }
            default:                                                                  // 후드: 끈 + 주머니
                c.dot(bx + 3, by + 1, Pal.white); c.dot(bx + 5, by + 1, Pal.white)
                c.hline(bx + 2, by + height - 3, 4, h.darker(0.2))
            }
        }
        // 팀 색 명찰(목줄 + 카드)
        if look.accent.a > 0 {
            c.dot(bx + 2, by + 1, look.accent.darker(0.2))
            c.rect(bx + 5, by + 3, 2, 2, look.accent)
        }
        if look.scruff >= 2 { c.dot(bx + 6, by + 2, h.darker(0.35)); c.dot(bx + 2, by + height - 2, h.darker(0.35)) }   // 때
    }

    static func arm(_ c: inout PixelCanvas, _ x: Int, _ y: Int, length: Int, look: WorkerLook, horizontal: Bool = false, handFirst: Bool = false) {
        let h = look.hoodie.darker(0.08)
        if horizontal {
            c.rect(x, y, length, 2, h)
            c.hline(x, y - 1, length, Pal.outline); c.hline(x, y + 2, length, Pal.outline)
            c.rect(handFirst ? x - 2 : x + length, y, 2, 2, look.skin)
        } else {
            c.rect(x, y, 2, length, h)
            c.vline(x - 1, y, length, Pal.outline); c.vline(x + 2, y, length, Pal.outline)
            c.rect(x, handFirst ? y - 2 : y + length, 2, 2, look.skin)
        }
    }

    static func legs(_ c: inout PixelCanvas, _ bx: Int, _ by: Int, offsetBack: Int = 0, offsetFront: Int = 0, length: Int = 4) {
        let p = Pal.pants
        c.rect(bx + 1 + offsetBack, by, 2, length, p.darker(0.1))
        c.rect(bx + 5 + offsetFront, by, 2, length, p)
        // 신발(앞쪽으로 1px)
        c.rect(bx + offsetBack, by + length, 4, 1, Pal.shoe); c.dot(bx + offsetBack, by + length, Pal.shoeShade)
        c.rect(bx + 4 + offsetFront, by + length, 4, 1, Pal.shoe); c.dot(bx + 4 + offsetFront, by + length, Pal.shoeShade)
        c.hline(bx + offsetBack, by + length + 1, 4, Pal.outline)
        c.hline(bx + 4 + offsetFront, by + length + 1, 4, Pal.outline)
    }

    // MARK: 자세

    static func worker(_ look: WorkerLook, _ pose: WorkerPose) -> PixelCanvas {
        switch pose {
        case .stand(let blink):
            var c = PixelCanvas(16, 24)
            arm(&c, 3, 13, length: 3, look: look)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, length: 3)
            arm(&c, 11, 13, length: 3, look: look)
            head(&c, 2, 1, look: look, eyes: blink ? .closed : .open)
            return c
        case .walk(let frame):
            var c = PixelCanvas(16, 24)
            let bob = frame % 2 == 1 ? -1 : 0
            let stride = [(-1, 1), (0, 0), (1, -1), (0, 0)][frame % 4]
            arm(&c, 3, 13 + bob, length: 3 - (frame == 0 ? 1 : 0), look: look)
            torso(&c, 4, 12 + bob, look: look)
            legs(&c, 4, 19, offsetBack: stride.0, offsetFront: stride.1, length: 3)
            arm(&c, 11, 13 + bob, length: 3 - (frame == 2 ? 1 : 0), look: look)
            head(&c, 2, 1 + bob, look: look)
            return c
        case .sitType(let frame):
            var c = PixelCanvas(16, 24)
            seated(&c, look: look)
            arm(&c, 11, 16 + (frame % 2), length: 3, look: look, horizontal: true)
            head(&c, 2, 3, look: look, eyes: .open, mouth: .none)
            return c
        case .sitWait:
            var c = PixelCanvas(16, 24)
            seated(&c, look: look)
            arm(&c, 11, 15, length: 2, look: look)
            head(&c, 2, 3, look: look, eyes: .open, mouth: .smile)
            return c
        case .sleepDesk(let frame):
            var c = PixelCanvas(16, 24)
            seated(&c, look: look)
            arm(&c, 10, 16, length: 4, look: look, horizontal: true)
            head(&c, 4, 7 + (frame % 2), look: look, eyes: .closed, mouth: .none)
            return c
        case .kick(let frame):
            var c = PixelCanvas(22, 24)
            if frame == 0 {
                // 준비: 무릎을 들어 올림
                arm(&c, 3, 12, length: 3, look: look)
                torso(&c, 4, 11, look: look)
                c.rect(5, 18, 2, 4, Pal.pants.darker(0.1))
                c.rect(9, 17, 4, 2, Pal.pants); c.rect(12, 19, 2, 2, Pal.pants)
                c.rect(4, 22, 4, 1, Pal.shoe); c.hline(4, 23, 4, Pal.outline)
                c.rect(12, 21, 3, 1, Pal.shoe)
                arm(&c, 11, 12, length: 3, look: look)
                head(&c, 2, 0, look: look, eyes: .wide, mouth: .open)
            } else {
                // 발차기: 앞다리를 쭉 뻗음
                arm(&c, 1, 9, length: 3, look: look, handFirst: true)
                torso(&c, 3, 12, look: look)
                c.rect(4, 19, 2, 3, Pal.pants.darker(0.1))
                c.rect(3, 22, 4, 1, Pal.shoe); c.hline(3, 23, 4, Pal.outline)
                c.rect(10, 16, 8, 2, Pal.pants)
                c.hline(10, 15, 8, Pal.outline); c.hline(10, 18, 8, Pal.outline)
                c.rect(18, 14, 2, 5, Pal.shoe); c.vline(20, 14, 5, Pal.outline); c.vline(18, 14, 5, Pal.shoeShade)
                arm(&c, 11, 13, length: 3, look: look, horizontal: true)
                head(&c, 1, 1, look: look, eyes: .closed, mouth: .shout)
            }
            return c
        case .dragged(let frame):
            var c = PixelCanvas(20, 24)
            let up = frame % 2
            arm(&c, 2, 6 + up, length: 5, look: look, handFirst: true)
            torso(&c, 4, 13, look: look)
            c.rect(10, 19, 6, 2, Pal.pants); c.hline(10, 18, 6, Pal.outline); c.hline(10, 21, 6, Pal.outline)
            c.rect(16, 18, 2, 4, Pal.shoe); c.vline(18, 18, 4, Pal.outline)
            c.rect(8, 21, 6, 1, Pal.pants.darker(0.1)); c.rect(14, 21, 2, 2, Pal.shoe)
            arm(&c, 13, 7 - up, length: 5, look: look, handFirst: true)
            head(&c, 3, 2 + up, look: look, eyes: .closed, mouth: .shout)
            return c
        case .pushup(let frame):
            var c = PixelCanvas(26, 14)
            let low = frame % 2 == 1 ? 2 : 0
            c.rect(2, 7 + low, 10, 3, Pal.pants); c.hline(2, 6 + low, 10, Pal.outline); c.hline(2, 10 + low, 10, Pal.outline)
            c.rect(0, 9 + low, 2, 3, Pal.shoe)
            c.box(11, 5 + low, 8, 6, fill: look.hoodie, rounded: false)
            c.rect(16, 11 + low - low, 2, 3 - low + 0, look.hoodie.darker(0.08)); c.vline(15, 11, 3, Pal.outline); c.vline(18, 11, 3, Pal.outline)
            c.rect(16, 13, 3, 1, look.skin)
            var h = PixelCanvas(12, 11)
            head(&h, 0, 0, look: look, eyes: .closed, mouth: .open)
            c.stamp(h, 14, low)
            c.dot(24, 2 + low, PixelColor(0x6EC6FF)) // 땀
            return c
        case .jumpingJack(let frame):
            var c = PixelCanvas(20, 26)
            if frame % 2 == 0 {
                arm(&c, 3, 4, length: 5, look: look, handFirst: true)
                arm(&c, 15, 4, length: 5, look: look, handFirst: true)
                torso(&c, 6, 13, look: look)
                c.rect(5, 20, 2, 4, Pal.pants); c.rect(13, 20, 2, 4, Pal.pants)
                c.rect(3, 24, 4, 1, Pal.shoe); c.rect(13, 24, 4, 1, Pal.shoe)
                c.hline(3, 25, 4, Pal.outline); c.hline(13, 25, 4, Pal.outline)
                head(&c, 4, 2, look: look, eyes: .happy, mouth: .open)
            } else {
                var s = worker(look, .stand(blink: false))
                s = s.flippedHorizontally().flippedHorizontally()
                c.stamp(s, 2, 2)
            }
            return c
        case .wave(let frame):
            var c = PixelCanvas(18, 24)
            arm(&c, 3, 13, length: 3, look: look)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, length: 3)
            arm(&c, 12 + (frame % 2), 7, length: 5, look: look, handFirst: true)
            head(&c, 2, 1, look: look, eyes: .happy, mouth: .smile)
            return c
        case .carry(let frame):
            var c = PixelCanvas(22, 24)
            let walk = worker(look, .walk(frame))
            c.stamp(walk, 0, 0)
            c.box(11, 11, 9, 8, fill: Pal.cardboard)
            c.hline(12, 14, 7, Pal.tape)
            c.rect(10, 14, 2, 2, look.skin)
            return c
        case .shout(let frame):
            var c = PixelCanvas(18, 24)
            arm(&c, 2, 7 + frame % 2, length: 5, look: look, handFirst: true)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, length: 3)
            arm(&c, 12, 8 - frame % 2, length: 5, look: look, handFirst: true)
            head(&c, 2, 1, look: look, eyes: .wide, mouth: .shout)
            return c
        case .lie:
            var c = PixelCanvas(16, 24)
            arm(&c, 3, 13, length: 3, look: look)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, length: 3)
            arm(&c, 11, 13, length: 3, look: look)
            head(&c, 2, 1, look: look, eyes: .closed, mouth: .smile)
            return c.rotatedLeft()
        case .swim(let frame):
            // 물 위: 머리 + 한쪽 팔이 번갈아 앞으로(물보라는 장면이 올린다). 아래 6줄은 물속이라 비운다.
            var c = PixelCanvas(22, 16)
            let stroke = frame % 2
            arm(&c, stroke == 0 ? 15 : 2, 3, length: 5, look: look, handFirst: true)
            c.rect(5, 11, 10, 3, look.hoodie)                        // 물 위로 보이는 등
            c.hline(5, 10, 10, Pal.outline)
            head(&c, 4, 0, look: look, eyes: stroke == 0 ? .happy : .closed, mouth: .open)
            c.dot(18, 9 + stroke, PixelColor(0x9BE7F3)); c.dot(20, 8, Pal.white)   // 물방울
            return c
        case .sitSad:
            var c = PixelCanvas(16, 24)
            arm(&c, 3, 16, length: 3, look: look)
            torso(&c, 4, 15, look: look, height: 6)
            c.rect(5, 21, 8, 2, Pal.pants); c.hline(5, 23, 8, Pal.outline)
            c.rect(12, 22, 2, 2, Pal.pants.darker(0.1))
            arm(&c, 11, 17, length: 3, look: look)
            head(&c, 3, 6, look: look, eyes: .closed, mouth: .none)   // 고개 숙임(머리가 아래로)
            c.hline(7, 15, 2, look.skin.darker(0.35))                    // 처진 입
            c.dot(14, 7, PixelColor(0x6EC6FF))                             // 식은땀
            return c
        case .read(let frame):
            var c = PixelCanvas(16, 24)
            seated(&c, look: look)
            arm(&c, 11, 15, length: 2, look: look)
            c.box(10, 12 + (frame % 2), 6, 5, fill: Pal.paper, rounded: false)   // 책
            c.vline(13, 13 + (frame % 2), 3, Pal.outline.with(alpha: 90))
            head(&c, 2, 3, look: look, eyes: .open, mouth: .smile)
            return c
        case .sweep(let frame):
            var c = PixelCanvas(24, 24)
            let lean = frame % 2
            arm(&c, 3, 13, length: 3, look: look)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, offsetBack: -lean, offsetFront: lean, length: 3)
            arm(&c, 11, 14, length: 4 + lean, look: look, horizontal: true)
            // 빗자루: 자루 + 솔
            c.vline(17 + lean * 2, 8, 12, Pal.teak); c.vline(18 + lean * 2, 8, 12, Pal.teak.darker(0.2))
            c.rect(15 + lean * 2, 20, 6, 3, Pal.mustard); c.hline(15 + lean * 2, 23, 6, Pal.mustardShade)
            head(&c, 2, 1, look: look, eyes: .open, mouth: .smile)
            return c
        case .scold(let frame):
            var c = PixelCanvas(20, 24)
            arm(&c, 3, 13, length: 3, look: look)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, length: 3)
            arm(&c, 11, 11 - frame % 2, length: 6, look: look, horizontal: true)   // 손가락질
            c.dot(18, 11 - frame % 2, look.skin)
            head(&c, 2, 1, look: look, eyes: .wide, mouth: .shout)
            return c
        case .clap(let frame):
            var c = PixelCanvas(18, 24)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, length: 3)
            let gap = frame % 2 == 0 ? 2 : 0
            arm(&c, 8 - gap, 12, length: 3, look: look, horizontal: true, handFirst: true)
            arm(&c, 10 + gap, 12, length: 3, look: look, horizontal: true)
            head(&c, 2, 1, look: look, eyes: .happy, mouth: .open)
            if gap == 0 { c.dot(7, 10, Pal.badge); c.dot(12, 10, Pal.badge) }
            return c
        case .thumbsUp:
            return thumbsUp(look)
        case .push(let frame):
            var c = PixelCanvas(18, 24)
            let bob = frame % 2 == 1 ? -1 : 0
            let stride = [(-1, 1), (0, 0), (1, -1), (0, 0)][frame % 4]
            torso(&c, 4, 12 + bob, look: look)
            legs(&c, 4, 19, offsetBack: stride.0, offsetFront: stride.1, length: 3)
            arm(&c, 10, 14 + bob, length: 5, look: look, horizontal: true)   // 두 팔을 앞으로(수레 손잡이)
            head(&c, 2, 1 + bob, look: look)
            return c
        case .kneel(let frame):
            // 뒷무릎은 바닥에(정강이가 뒤로 눕는다), 앞무릎은 세운다. 앞손에 노란 전동 드라이버.
            var c = PixelCanvas(18, 24)
            let jig = frame % 2
            c.rect(2, 21, 6, 2, Pal.pants.darker(0.1)); c.hline(2, 23, 6, Pal.outline)
            c.rect(0, 21, 2, 2, Pal.shoe)
            c.rect(6, 18, 4, 2, Pal.pants); c.rect(9, 18, 2, 4, Pal.pants)
            c.rect(9, 22, 4, 1, Pal.shoe); c.hline(9, 23, 4, Pal.outline)
            arm(&c, 3, 15, length: 3, look: look)
            torso(&c, 4, 13, look: look, height: 6)
            arm(&c, 11, 15 + jig, length: 3, look: look, horizontal: true)
            c.rect(14, 14 + jig, 3, 3, Pal.mustard); c.dot(14, 16 + jig, Pal.mustardShade); c.dot(17, 15 + jig, Pal.metalLight)
            head(&c, 3, 3, look: look, eyes: .open, mouth: .none)
            return c
        case .pry(let frame):
            // 두 손으로 빨간 지렛대를 상자 틈(오른쪽 아래)에 넣고 누른다. 프레임마다 지렛대가 들썩인다.
            var c = PixelCanvas(20, 24)
            let up = frame % 2
            arm(&c, 3, 13, length: 3, look: look)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, offsetBack: -1, offsetFront: 1, length: 3)
            arm(&c, 11, 14 + up, length: 4, look: look, horizontal: true)
            let bar: [(Int, Int)] = up == 0 ? [(16, 15), (17, 16), (18, 17), (19, 18)] : [(16, 16), (17, 16), (18, 17), (19, 17)]
            for (x, y) in bar { c.dot(x, y, Pal.alarm); c.dot(x, y + 1, Pal.alarm.darker(0.3)) }
            head(&c, 2, 1, look: look, eyes: .closed, mouth: .none)
            return c
        case .climb(let frame):
            // 사다리에 매달려 오른쪽(선반)을 본다: 팔과 무릎을 번갈아 든다. 팔은 머리 앞으로 뻗으니 머리 다음에 그린다.
            var c = PixelCanvas(17, 24)
            let up = frame % 2
            torso(&c, 4, 12, look: look)
            let back = up == 0 ? 3 : 1, front = up == 0 ? 1 : 3
            c.rect(5, 19, 2, back, Pal.pants.darker(0.1)); c.rect(4, 19 + back, 4, 1, Pal.shoe); c.hline(4, 20 + back, 4, Pal.outline)
            c.rect(9, 19, 2, front, Pal.pants); c.rect(9, 19 + front, 4, 1, Pal.shoe); c.hline(9, 20 + front, 4, Pal.outline)
            head(&c, 2, 1, look: look, eyes: .open, mouth: .smile)
            arm(&c, 12, 4 + up * 3, length: 9 - up * 3, look: look, handFirst: true)    // 앞팔: 위 칸을 짚는다
            arm(&c, 14, 7 - up * 2, length: 6 + up * 2, look: look, handFirst: true)    // 뒤팔(번갈아)
            return c
        case .mop(let frame):
            // 대걸레: 자루를 비스듬히 쥐고 젖은 걸레 머리를 바닥에서 밀었다 당긴다.
            var c = PixelCanvas(24, 24)
            let reach = frame % 2
            arm(&c, 3, 13, length: 3, look: look)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, offsetBack: reach == 0 ? -1 : 0, offsetFront: reach == 0 ? 1 : 0, length: 3)
            arm(&c, 11, 14, length: 3 + reach, look: look, horizontal: true)
            let hand = 14 + reach
            for i in 0..<7 { c.dot(hand + 1 + i / 3, 14 + i, Pal.teak) }
            let head0 = hand + 1
            c.rect(head0, 21, 6, 2, PixelColor(0xD6E2EA)); c.hline(head0, 23, 6, PixelColor(0x8FA7B8))
            for x in stride(from: head0, to: head0 + 6, by: 2) { c.dot(x, 22, PixelColor(0xA9BFCE)) }
            head(&c, 2, 1, look: look, eyes: .open, mouth: .smile)
            return c
        case .scratch(let frame):
            // 앞팔은 허리 높이 앞(턴테이블 자리)에 뻗어 문지르고(1px 앞뒤), 뒤팔은 머리 뒤로 들어 흔든다. 머리는 박자마다 1px 까딱.
            var c = PixelCanvas(18, 24)
            let beat = frame % 2
            c.rect(2, 12, 2, 2, look.hoodie.darker(0.08))                                  // 뒤 어깨(든 팔과 몸통을 잇는다)
            arm(&c, 0, 6 + beat, length: 6 - beat, look: look, handFirst: true)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, length: 3)
            arm(&c, 11, 14, length: 4 + beat, look: look, horizontal: true)
            head(&c, 2, 1 + beat, look: look, eyes: .happy, mouth: .open)
            return c
        case .splash(let frame):
            // 수영(swim)과 같은 물 위 모습(아래 여섯 줄은 물속이라 비운다)에 두 팔을 머리 양옆으로 번갈아 든다 + 물보라.
            var c = PixelCanvas(22, 16)
            let up = frame % 2
            arm(&c, 1, 3 + up * 2, length: 7 - up * 2, look: look, handFirst: true)
            arm(&c, 18, 5 - up * 2, length: 5 + up * 2, look: look, handFirst: true)
            c.rect(3, 10, 2, 2, look.hoodie.darker(0.08)); c.rect(16, 10, 2, 2, look.hoodie.darker(0.08))   // 어깨
            c.rect(5, 11, 10, 3, look.hoodie)                        // 물 위로 보이는 등
            c.hline(5, 10, 10, Pal.outline)
            head(&c, 5, 0, look: look, eyes: .happy, mouth: .open)
            c.dot(0, 9 + up, Pal.waterLight); c.dot(21, 8 - up, Pal.white); c.dot(3, 13 - up, Pal.white)   // 물보라
            return c
        }
    }

    /// 엄지척: 뒤팔은 내리고, 앞팔은 팔꿈치를 굽혀 주먹을 얼굴 옆(겹치지 않게)에 세운 뒤 엄지를 위로(20×24).
    private static func thumbsUp(_ look: WorkerLook) -> PixelCanvas {
        var c = PixelCanvas(20, 24)
        let o = Pal.outline, sleeve = look.hoodie.darker(0.08), s = look.skin, fold = look.skin.darker(0.22)
        arm(&c, 3, 13, length: 3, look: look)
        torso(&c, 4, 12, look: look)
        legs(&c, 4, 19, length: 3)
        head(&c, 2, 1, look: look, eyes: .open, mouth: .smile)   // 아이콘 크기에서 반달눈은 선글라스처럼 뭉쳐 보여 뜬 눈
        // 위팔(어깨에서 앞으로) + 아래팔(팔꿈치에서 위로) + 소매 끝
        c.rect(11, 14, 6, 2, sleeve); c.hline(11, 13, 4, o); c.hline(11, 16, 7, o)
        c.rect(16, 9, 2, 6, sleeve); c.vline(15, 9, 5, o); c.vline(18, 9, 7, o)
        c.hline(16, 9, 2, sleeve.lighter(0.2))
        // 주먹(앞으로 말아 쥔 손가락 마디) + 위로 세운 엄지 — 얼굴과 1px 띄운다
        c.rect(15, 5, 4, 4, s)
        c.dot(18, 6, fold); c.dot(18, 8, fold); c.dot(17, 7, fold)
        c.vline(14, 5, 4, o); c.vline(19, 5, 4, o); c.hline(17, 4, 2, o); c.hline(15, 9, 1, o)
        c.rect(15, 1, 2, 4, s); c.dot(15, 2, s.lighter(0.3))
        c.vline(14, 1, 4, o); c.vline(17, 1, 3, o); c.hline(15, 0, 2, o)
        return c
    }

    private static func seated(_ c: inout PixelCanvas, look: WorkerLook) {
        arm(&c, 3, 15, length: 2, look: look)
        torso(&c, 4, 14, look: look, height: 6)
        // 허벅지(오른쪽으로)와 정강이
        c.rect(5, 20, 8, 2, Pal.pants); c.hline(5, 19, 1, Pal.outline); c.hline(5, 22, 8, Pal.outline)
        c.rect(12, 21, 2, 2, Pal.pants.darker(0.1))
        c.rect(12, 23, 4, 1, Pal.shoe)
    }

    // MARK: 경비원 · 트레이너 · 도우미 · 유령

    static func guardSprite(_ pose: WorkerPose) -> PixelCanvas {
        var look = WorkerLook(hoodie: Pal.navy, hair: Pal.hairs[1], hairStyle: 0)
        look.skin = PixelColor(0xEDBE95)
        var c: PixelCanvas
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame))
        case .dragged: // 끌고 가는 자세: 두 팔을 앞으로
            c = PixelCanvas(18, 24)
            torso(&c, 4, 12, look: look)
            legs(&c, 4, 19, offsetBack: -1, offsetFront: 1, length: 3)
            arm(&c, 11, 13, length: 4, look: look, horizontal: true)
            arm(&c, 11, 16, length: 4, look: look, horizontal: true)
            head(&c, 2, 1, look: look, eyes: .open, mouth: .none)
        case .wave(let frame): c = worker(look, .wave(frame))
        default: c = worker(look, .stand(blink: false))
        }
        // 모자(챙은 오른쪽) + 배지 + 콧수염 + 금단추
        let capY = 0
        c.rect(2, capY, 12, 3, Pal.navy); c.hline(2, capY, 12, Pal.outline); c.hline(11, capY + 3, 5, Pal.navyShade)
        c.dot(7, capY + 1, Pal.badge)
        c.hline(7, 9, 4, Pal.black)
        c.dot(8, 14, Pal.badge); c.dot(8, 16, Pal.badge); c.dot(6, 13, Pal.badge)
        return c
    }

    static func trainerSprite(_ pose: WorkerPose) -> PixelCanvas {
        let look = WorkerLook(hoodie: Pal.magenta, hair: Pal.hairs[1], hairStyle: 2, skin: PixelColor(0xE9B48A))
        var c: PixelCanvas
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame))
        case .shout(let frame): c = worker(look, .shout(frame))
        case .wave(let frame): c = worker(look, .wave(frame))
        default: c = worker(look, .stand(blink: false))
        }
        // 머리띠 + 흰 줄무늬 + 호루라기
        c.hline(3, 3, 10, Pal.white); c.hline(3, 4, 10, Pal.alarm)
        c.vline(5, 13, 5, Pal.white); c.vline(10, 13, 5, Pal.white)
        c.dot(9, 11, Pal.badge); c.dot(9, 12, Pal.badge)
        return c
    }

    /// 사장(대표): 빼짝 마른 너드 — 덥수룩한 머리·뿔테 안경·체크 셔츠·카키 바지. 머리가 몸보다 커 보인다.
    /// 자세: stand · walk(종종걸음) · shout(머리 쥐어뜯기 = 패닉) · clap(만세 = 신남) · sitSad(축 처짐) · read(휴대폰 보기).
    static func bossSprite(_ pose: WorkerPose) -> PixelCanvas {
        var look = WorkerLook(hoodie: PixelColor(0x5B7FA6), hair: PixelColor(0x2A2A34), hairStyle: 5, skin: PixelColor(0xF2D0B0))
        look.glasses = true
        var c = PixelCanvas(16, 24)
        let khaki = PixelColor(0xB9A27A)
        // 마른 몸통(6px 폭) + 체크 무늬
        func body(_ by: Int, height: Int = 7) {
            c.box(5, by, 6, height, fill: look.hoodie, rounded: false)
            for y in stride(from: by + 1, to: by + height - 1, by: 2) { c.hline(6, y, 4, look.hoodie.darker(0.22)) }
            for x in stride(from: 6, to: 10, by: 2) { c.vline(x, by + 1, height - 2, look.hoodie.lighter(0.12)) }
            c.dot(7, by + 1, Pal.white); c.dot(8, by + 1, Pal.white)                     // 깃
        }
        func thinLegs(_ by: Int, back: Int = 0, front: Int = 0) {
            c.rect(6 + back, by, 1, 4, khaki.darker(0.15)); c.rect(9 + front, by, 1, 4, khaki)
            c.rect(5 + back, by + 4, 3, 1, Pal.shoe); c.rect(8 + front, by + 4, 3, 1, Pal.shoe)
            c.hline(5 + back, by + 5, 3, Pal.outline); c.hline(8 + front, by + 5, 3, Pal.outline)
        }
        func thinArm(_ x: Int, _ y: Int, length: Int) {
            c.vline(x, y, length, look.hoodie.darker(0.08)); c.dot(x, y + length, look.skin)
        }
        switch pose {
        case .walk(let frame):
            let bob = frame % 2 == 1 ? -1 : 0
            let stride = [(-1, 1), (0, 0), (1, -1), (0, 0)][frame % 4]
            thinArm(4, 13 + bob, length: 3); body(12 + bob); thinArm(11, 13 + bob, length: 3)
            thinLegs(18, back: stride.0, front: stride.1)
            head(&c, 2, 1 + bob, look: look, eyes: .open, mouth: .none)
        case .shout(let frame):                                                        // 패닉: 두 손으로 머리 쥐어뜯기
            body(12); thinLegs(18, back: -1, front: 1)
            c.vline(3, 5 + frame % 2, 8, look.hoodie.darker(0.08)); c.rect(3, 4 + frame % 2, 2, 2, look.skin)
            c.vline(12, 6 - frame % 2, 7, look.hoodie.darker(0.08)); c.rect(11, 4 - frame % 2, 2, 2, look.skin)
            head(&c, 2, 1, look: look, eyes: .wide, mouth: .shout)
            c.dot(1, 0 + frame % 2, look.hair); c.dot(14, 1 - frame % 2, look.hair)          // 뽑힌 머리카락
            c.dot(14, 6, PixelColor(0x6EC6FF)); c.dot(15, 8, PixelColor(0x6EC6FF))          // 식은땀
        case .clap(let frame):                                                         // 신남: 만세
            body(12); thinLegs(18)
            c.vline(3, 4 + frame % 2, 9, look.hoodie.darker(0.08)); c.dot(3, 3 + frame % 2, look.skin)
            c.vline(12, 4 + frame % 2, 9, look.hoodie.darker(0.08)); c.dot(12, 3 + frame % 2, look.skin)
            head(&c, 2, 1 - frame % 2, look: look, eyes: .happy, mouth: .open)
        case .sitSad:                                                                  // 축 처짐: 고개 숙이고 팔 늘어뜨림
            body(13); thinLegs(19)
            thinArm(4, 14, length: 5); thinArm(11, 14, length: 5)
            head(&c, 3, 3, look: look, eyes: .closed, mouth: .none)
            c.hline(7, 12, 2, look.skin.darker(0.35))
        case .read(let frame):                                                         // 휴대폰 보기
            body(12); thinLegs(18)
            thinArm(4, 13, length: 3)
            c.hline(11, 14, 2, look.hoodie.darker(0.08)); c.rect(12, 12, 2, 3, Pal.black); c.dot(12, 12 + frame % 2, PixelColor(0x7FD3FF))
            head(&c, 2, 2, look: look, eyes: .open, mouth: .none)
        default:
            thinArm(4, 13, length: 3); body(12); thinArm(11, 13, length: 3); thinLegs(18)
            head(&c, 2, 1, look: look, eyes: pose == .stand(blink: true) ? .closed : .open, mouth: .smile)
        }
        return c
    }

    /// 감사관: 대머리 · 검은 양복 · 넥타이 · 안경. 걸리면 혼난다.
    static func auditorSprite(_ pose: WorkerPose) -> PixelCanvas {
        var look = WorkerLook(hoodie: PixelColor(0x2B2D42), hair: Pal.hairs[1], hairStyle: 4, skin: PixelColor(0xF0C9A3))
        look.glasses = true
        look.tie = true
        var c: PixelCanvas
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame))
        case .scold(let frame): c = worker(look, .scold(frame))
        case .clap(let frame): c = worker(look, .clap(frame))
        case .kick(let frame): c = worker(look, .kick(frame))
        case .shout(let frame): c = worker(look, .shout(frame))
        default: c = worker(look, .stand(blink: false))
        }
        c.dot(5, 2, PixelColor(0xFFFFFF, alpha: 150))   // 정수리 반사광
        return c
    }

    /// 비서: 올림머리 · 베이지 재킷 · 클립보드.
    static func secretarySprite(_ pose: WorkerPose) -> PixelCanvas {
        let look = WorkerLook(hoodie: PixelColor(0xD9B99B), hair: Pal.hairs[0], hairStyle: 1, skin: Pal.skin)
        var c: PixelCanvas
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame))
        case .wave(let frame): c = worker(look, .wave(frame))
        default: c = worker(look, .stand(blink: false))
        }
        c.box(11, 12, 5, 7, fill: Pal.paper, rounded: false)   // 클립보드
        c.hline(12, 14, 3, Pal.outline.with(alpha: 120)); c.hline(12, 16, 3, Pal.outline.with(alpha: 120))
        c.dot(13, 12, Pal.metal)
        return c
    }

    /// 정신교육실 강사: 은발 올림머리 · 안경 · 세이지색 니트 카디건 · 목걸이 명찰(흰 카드).
    /// 자세: stand · walk · scold(훈계: 손가락으로 짚기) · wave(어르기: 손짓) · clap(달래기) · shout(지시 시작) · thumbsUp.
    static func instructorSprite(_ pose: WorkerPose) -> PixelCanvas {
        var look = WorkerLook(hoodie: PixelColor(0x7FA88B), hair: PixelColor(0xC9C6C0), hairStyle: 1, skin: PixelColor(0xF1C9A5))
        look.glasses = true
        look.feminine = true
        look.outfit = 2
        var c: PixelCanvas
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame))
        case .scold(let frame): c = worker(look, .scold(frame))
        case .wave(let frame): c = worker(look, .wave(frame))
        case .clap(let frame): c = worker(look, .clap(frame))
        case .shout(let frame): c = worker(look, .shout(frame))
        case .thumbsUp: c = worker(look, .thumbsUp)
        default: c = worker(look, .stand(blink: pose == .stand(blink: true)))
        }
        // 목걸이 명찰: 목줄 두 점 + 흰 카드(몸통 가운데 아래)
        c.dot(6, 13, Pal.outline.with(alpha: 140)); c.dot(9, 13, Pal.outline.with(alpha: 140))
        c.rect(7, 15, 2, 2, Pal.white); c.dot(7, 15, PixelColor(0x5B7BD5))
        return c
    }

    /// 청소 인력: 하늘색 작업복 · 모자. index로 머리색만 다르게.
    static func janitorSprite(_ index: Int, _ pose: WorkerPose) -> PixelCanvas {
        let look = WorkerLook(hoodie: PixelColor(0x5DA9E9), hair: Pal.hairs[index % Pal.hairs.count], hairStyle: 0, skin: Pal.skin)
        var c: PixelCanvas
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame))
        case .sweep(let frame): c = worker(look, .sweep(frame))
        case .carry(let frame): c = worker(look, .carry(frame))
        case .wave(let frame): c = worker(look, .wave(frame))
        case .mop(let frame): c = worker(look, .mop(frame))
        default: c = worker(look, .stand(blink: false))
        }
        c.rect(2, 0, 12, 3, PixelColor(0x3B82C4)); c.hline(2, 0, 12, Pal.outline); c.hline(11, 3, 4, PixelColor(0x2B6AA0))   // 모자
        c.hline(4, 15, 2, Pal.white)   // 명찰
        return c
    }

    /// 도구실 배송·설치 기사(직원 — 에이전트 아님): 갈색 작업복 · 챙 모자(노란 마크) · 공구 벨트. 팀 명찰이 없다.
    /// 반입구로 앱(기계)을 들이고(상자를 뜯어 볼트를 조인다) 끝난 앱을 내간다(전원선을 뽑아 싣는다).
    /// 자세: stand · walk(4) · push(4, 수레 밀기) · pry(2, 상자 뜯기) · kneel(2, 볼트 · 전원선) · wave(2).
    static func courierSprite(_ pose: WorkerPose) -> PixelCanvas {
        let uniform = PixelColor(0x8A5A3B), cap = PixelColor(0x5E3A22)
        let look = WorkerLook(hoodie: uniform, hair: Pal.hairs[4], hairStyle: 0, skin: PixelColor(0xE7B48C))
        var c: PixelCanvas
        var bob = 0
        var kneeling = false
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame)); bob = frame % 2 == 1 ? -1 : 0
        case .push(let frame): c = worker(look, .push(frame)); bob = frame % 2 == 1 ? -1 : 0
        case .kneel(let frame): c = worker(look, .kneel(frame)); kneeling = true
        case .pry(let frame): c = worker(look, .pry(frame))
        case .wave(let frame): c = worker(look, .wave(frame))
        default: c = worker(look, .stand(blink: pose == .stand(blink: true)))
        }
        // 챙 모자(챙은 앞 = 오른쪽) — 머리 위치는 자세마다 다르다(무릎 꿇으면 두 줄 아래)
        let ox = kneeling ? 3 : 2, oy = (kneeling ? 3 : 1) + bob
        c.rect(ox + 1, oy - 1, 9, 3, cap); c.hline(ox + 1, oy - 1, 9, Pal.outline)
        c.hline(ox + 8, oy + 2, 5, cap.darker(0.25))
        c.dot(ox + 4, oy, PixelColor(0xF2C14E))
        // 공구 벨트(허리) + 줄자
        let belt = kneeling ? 17 : 17 + bob
        c.hline(4, belt, 8, PixelColor(0x3B2A1E)); c.dot(10, belt, Pal.mustard)
        return c
    }

    /// 기록관(금고 담당 직원 — 에이전트 아님): 단발 · 동그란 안경 · 버건디 니트 조끼 · 흰 면장갑(기록물을 맨손으로 만지지 않는다) · 목에 건 금고 열쇠.
    /// 자세: stand · walk(4) · push(4, 상자를 두 손으로 든 채 걷기 — 상자는 장면이 손 위에 얹는다) · climb(2, 사다리) · wave(2).
    static func archivistSprite(_ pose: WorkerPose) -> PixelCanvas {
        var look = WorkerLook(hoodie: PixelColor(0x7A2E3E), hair: Pal.hairs[3], hairStyle: 3, skin: PixelColor(0xF1C9A5))
        look.glasses = true
        look.outfit = 2
        look.feminine = true
        var c: PixelCanvas
        var bob = 0
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame)); bob = frame % 2 == 1 ? -1 : 0
        case .push(let frame): c = worker(look, .push(frame)); bob = frame % 2 == 1 ? -1 : 0
        case .climb(let frame): c = worker(look, .climb(frame))
        case .wave(let frame): c = worker(look, .wave(frame))
        default: c = worker(look, .stand(blink: pose == .stand(blink: true)))
        }
        // 흰 면장갑: 머리 아래(13줄부터)의 피부색 = 손
        for y in 13..<c.height { for x in 0..<c.width where c[x, y] == look.skin { c.dot(x, y, Pal.white) } }
        // 금고 열쇠(목줄 + 놋쇠 열쇠)
        c.dot(6, 13 + bob, Pal.outline.with(alpha: 150)); c.dot(7, 15 + bob, Pal.gold); c.dot(7, 16 + bob, Pal.gold.darker(0.2))
        return c
    }

    /// 기계실 짐꾼(창고 직원 — 에이전트 아님): 노란 안전모 · 주황 형광 조끼(반사띠) · 회색 작업복 · 목장갑 · 갈색 작업화.
    /// 팀 명찰이 없어 에이전트와, 하늘색 작업복의 청소 인력과 구분된다. 자세: stand · walk(4) · carry(상자 들고 걷기, 4).
    static func porterSprite(_ pose: WorkerPose) -> PixelCanvas {
        let look = WorkerLook(hoodie: PixelColor(0x5B6573), hair: Pal.hairs[2], hairStyle: 0, skin: PixelColor(0xE2B48A))
        let vest = PixelColor(0xF28C28), stripe = PixelColor(0xF4F1E8), hat = PixelColor(0xF2C230)
        let glove = PixelColor(0xC9A06A), boot = PixelColor(0x6B4A2E)
        var c: PixelCanvas
        var bob = 0
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame)); bob = frame % 2 == 1 ? -1 : 0
        case .carry(let frame): c = worker(look, .carry(frame)); bob = frame % 2 == 1 ? -1 : 0
        case .push(let frame): c = worker(look, .push(frame)); bob = frame % 2 == 1 ? -1 : 0
        default: c = worker(look, .stand(blink: false))
        }
        // 작업화(흰 운동화 → 갈색)와 목장갑(손 → 황토색). 얼굴 피부는 그대로 둔다(손은 12줄 아래에만 있다).
        for y in 0..<c.height { for x in 0..<c.width {
            let color = c[x, y]
            if y >= 20, color == Pal.shoe || color == Pal.shoeShade { c.dot(x, y, color == Pal.shoe ? boot : boot.darker(0.2)) }
            if y >= 12, color == look.skin { c.dot(x, y, glove) }
        } }
        // 형광 조끼 + 반사띠 + 지퍼
        c.rect(5, 13 + bob, 6, 5, vest)
        c.hline(5, 15 + bob, 6, stripe)
        c.vline(8, 13 + bob, 2, vest.darker(0.2))
        // 안전모(챙은 앞 = 오른쪽)
        c.rect(4, bob, 8, 1, hat)
        c.rect(3, 1 + bob, 10, 2, hat)
        c.dot(5, 1 + bob, hat.lighter(0.35))
        c.hline(2, 3 + bob, 13, hat.darker(0.18))
        return c
    }

    /// 재고 조사 인력(창고 직원 — 에이전트 아님): 청록 작업 점퍼 · 짙은 청록 챙 모자 · 흰 명찰 · 갈색 클립보드(흰 종이 · 쇠 집게). 팀 명찰이 없다.
    /// 디스크 지도의 재고 조사를 연출한다(선반 상자를 탁자로 내리고 · 열고 · 스티커 · 보관/폐기). index로 머리색 · 머리 모양 · 피부만 다르게.
    /// 자세: stand · walk(4, 클립보드를 앞손에) · push(4, 손수레 · 상자 들기 — 클립보드는 옆구리) · wave(2, 선반을 가리키며 세기) · shout(2, 실측 외침).
    static func stockSprite(_ index: Int, _ pose: WorkerPose) -> PixelCanvas {
        let jacket = PixelColor(0x2E9C8A), cap = PixelColor(0x1D6B5F)
        let styles = [0, 3, 2, 8]
        let look = WorkerLook(hoodie: jacket, hair: Pal.hairs[(index + 2) % Pal.hairs.count], hairStyle: styles[index % styles.count],
                              skin: WorkerLook.skins[(index * 2 + 1) % WorkerLook.skins.count])
        var c: PixelCanvas
        var bob = 0
        var board: (x: Int, y: Int)?
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame)); bob = frame % 2 == 1 ? -1 : 0; board = (11, 13 + bob)
        case .push(let frame): c = worker(look, .push(frame)); bob = frame % 2 == 1 ? -1 : 0
        case .wave(let frame): c = worker(look, .wave(frame)); board = (0, 14)
        case .shout(let frame): c = worker(look, .shout(frame))
        default: c = worker(look, .stand(blink: pose == .stand(blink: true))); board = (11, 13)
        }
        // 챙 모자(챙은 앞 = 오른쪽) + 흰 마크
        let oy = 1 + bob
        c.rect(2, oy - 1, 12, 3, cap); c.hline(2, oy - 1, 12, Pal.outline); c.hline(11, oy + 2, 4, cap.darker(0.25))
        c.dot(6, oy, PixelColor(0xF2F2E6))
        c.hline(5, 15 + bob, 2, Pal.white)   // 명찰
        if let board {
            c.box(board.x, board.y, 5, 6, fill: PixelColor(0x8E6232), outline: PixelColor(0x5E3F1F), rounded: false)
            c.rect(board.x + 1, board.y + 1, 3, 4, Pal.paper)
            c.hline(board.x + 1, board.y + 2, 2, PixelColor(0x9AA3AF)); c.hline(board.x + 1, board.y + 4, 3, PixelColor(0x9AA3AF))
            c.dot(board.x + 2, board.y, MachineArt.steelLight)
        }
        return c
    }

    /// 정리 명령 기술자(직원 — 에이전트 아님): 짙은 회색 셔츠 · 안경 · 헤드셋(회색 띠 · 귀 덮개 · 마이크) · 파란 목줄 카드.
    /// 단말기 수레를 밀고 와서 외부 도구의 정리 명령(prune)을 친다. 자세: stand · walk(4) · push(4, 수레 밀기 · 자판 치기).
    static func technicianSprite(_ pose: WorkerPose) -> PixelCanvas {
        var look = WorkerLook(hoodie: PixelColor(0x3E4452), hair: Pal.hairs[5], hairStyle: 8, skin: PixelColor(0xE7B48C))
        look.glasses = true
        look.outfit = 1
        var c: PixelCanvas
        var bob = 0
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame)); bob = frame % 2 == 1 ? -1 : 0
        case .push(let frame): c = worker(look, .push(frame)); bob = frame % 2 == 1 ? -1 : 0
        default: c = worker(look, .stand(blink: pose == .stand(blink: true)))
        }
        let oy = 1 + bob, band = PixelColor(0x6B7280)
        c.hline(3, oy - 1, 7, band); c.vline(3, oy, 5, band)            // 헤드셋 띠(정수리 → 뒤통수)
        c.rect(2, oy + 5, 2, 3, PixelColor(0x2B2D33))                   // 귀 덮개
        c.hline(4, oy + 9, 4, band); c.dot(8, oy + 9, Pal.alarm)        // 마이크 대
        c.dot(6, 13 + bob, PixelColor(0x5B7BD5)); c.rect(6, 15 + bob, 2, 2, Pal.white)   // 목줄 카드
        return c
    }

    /// DJ(옥상 파티 손님 — 에이전트 아님): 탈색한 삐죽 머리 · 보라 재킷 · 검은 선글라스 · 머리에 쓴 큰 헤드폰(네온 귀 덮개) · 금목걸이. 팀 명찰이 없다.
    /// 자세: stand · walk(4) · carry(4, 장비 가방 = 검은 하드 케이스) · scratch(2, 디제잉) · shout(2, 손 머리 위로) · wave(2, 인사).
    static func djSprite(_ pose: WorkerPose) -> PixelCanvas {
        var look = WorkerLook(hoodie: PixelColor(0x5B2C83), hair: PixelColor(0xF0C84A), hairStyle: 2, skin: PixelColor(0xC98E63))
        look.outfit = 3   // 재킷: 어두운 옷깃 + 안쪽 흰 셔츠
        var c: PixelCanvas
        var oy = 1        // 머리 위치(자세마다 위아래로 1px씩 다르다)
        switch pose {
        case .walk(let frame): c = worker(look, .walk(frame)); oy += frame % 2 == 1 ? -1 : 0
        case .carry(let frame):
            c = worker(look, .carry(frame)); oy += frame % 2 == 1 ? -1 : 0
            // 종이 상자 → 검은 하드 케이스(은색 띠)
            for y in 0..<c.height { for x in 0..<c.width {
                if c[x, y] == Pal.cardboard { c.dot(x, y, PixelColor(0x2B2D35)) } else if c[x, y] == Pal.tape { c.dot(x, y, Pal.metalLight) }
            } }
        case .scratch(let frame): c = worker(look, .scratch(frame)); oy += frame % 2
        case .shout(let frame): c = worker(look, .shout(frame))
        case .wave(let frame): c = worker(look, .wave(frame))
        default: c = worker(look, .stand(blink: pose == .stand(blink: true)))
        }
        let ox = 2, shade = PixelColor(0x15151C), cup = PixelColor(0x34343C), neon = PixelColor(0x3FF0C8)
        // 선글라스: 두 알 + 코걸이 + 귀로 가는 다리, 알 위 반사광
        c.rect(ox + 5, oy + 6, 2, 2, shade); c.rect(ox + 8, oy + 6, 3, 2, shade); c.dot(ox + 7, oy + 6, shade)
        c.hline(ox + 5, oy + 6, 1, shade); c.dot(ox + 9, oy + 6, PixelColor(0x8FD8FF))
        // 헤드폰: 정수리를 넘는 띠 + 귀 덮개(네온 테)
        c.hline(ox + 3, oy - 1, 4, cup); c.vline(ox + 3, oy, 5, cup)
        c.box(ox + 2, oy + 5, 4, 5, fill: cup, outline: Pal.outline, rounded: false)
        c.dot(ox + 3, oy + 6, neon); c.dot(ox + 4, oy + 7, neon); c.dot(ox + 3, oy + 8, neon)
        // 금목걸이(목 아래 셔츠 위)
        let chest = oy + 12
        c.dot(ox + 4, chest, Pal.gold); c.dot(ox + 5, chest + 1, Pal.gold); c.dot(ox + 6, chest + 1, Pal.gold.lighter(0.3)); c.dot(ox + 7, chest, Pal.gold)
        return c
    }

    /// 하위 에이전트 로봇: 몸통(네모·둥근·캡슐·바퀴·드론) × 머리(안테나·접시·램프·귀) × 색이 무작위. 워크플로 에이전트는 노란 명판.
    static func robot(_ design: RobotDesign, frame: Int) -> PixelCanvas {
        var c = PixelCanvas(12, 14)
        let body = design.color, shade = design.color.darker(0.25), eye = design.eye
        let bob = design.body == 4 ? (frame % 2) : 0   // 드론은 둥둥 뜬다
        let base = 13 - bob
        switch design.body {
        case 1:  // 둥근 몸
            c.box(2, base - 8, 8, 7, fill: body); c.dot(2, base - 8, .clear); c.dot(9, base - 8, .clear)
            c.rect(3, base - 1, 2, 1, shade); c.rect(7, base - 1, 2, 1, shade)
        case 2:  // 캡슐(가늘고 높음)
            c.box(3, base - 10, 6, 9, fill: body)
            c.rect(4, base - 1, 1, 1, shade); c.rect(7, base - 1, 1, 1, shade)
        case 3:  // 바퀴
            c.box(2, base - 8, 8, 6, fill: body)
            c.box(2, base - 2, 3, 3, fill: Pal.black); c.box(7, base - 2, 3, 3, fill: Pal.black)
            c.dot(3, base - 1, Pal.metalLight); c.dot(8, base - 1, Pal.metalLight)
        case 4:  // 드론(프로펠러)
            c.box(2, base - 6, 8, 5, fill: body)
            c.hline(0, base - 7, 5, frame % 2 == 0 ? Pal.metalLight : shade); c.hline(7, base - 7, 5, frame % 2 == 0 ? shade : Pal.metalLight)
        default: // 네모
            c.box(2, base - 8, 8, 7, fill: body)
            c.rect(3, base - 1, 2, 1, shade); c.rect(7, base - 1, 2, 1, shade)
        }
        // 얼굴 화면 + 눈(깜박)
        let faceTop = design.body == 2 ? base - 9 : base - 7
        c.rect(3, faceTop, 6, 3, Pal.eye)
        if frame % 2 == 0 || design.body != 0 { c.dot(4, faceTop + 1, eye); c.dot(7, faceTop + 1, eye) } else { c.hline(4, faceTop + 1, 4, eye.darker(0.4)) }
        // 머리 장식
        let top = design.body == 2 ? base - 11 : base - 9
        switch design.head {
        case 1: c.hline(4, top, 4, Pal.metalLight); c.dot(6, top - 1, Pal.metal)              // 접시
        case 2: c.dot(6, top, frame % 2 == 0 ? Pal.alarm : Pal.badge); c.dot(6, top + 1, Pal.metal) // 램프
        case 3: c.dot(2, top + 1, shade); c.dot(9, top + 1, shade)                               // 귀
        default: c.vline(6, top - 1, 2, Pal.outline); c.dot(6, top - 2, eye)                     // 안테나
        }
        if design.workflow { c.hline(4, base - 3, 4, Pal.badge) }
        return c
    }

    static func robot(_ frame: Int) -> PixelCanvas {
        var c = PixelCanvas(9, 10)
        let bob = frame % 2
        c.vline(4, 0 + bob, 2, Pal.outline); c.dot(4, bob, Pal.robotEye)
        c.box(0, 2 + bob, 9, 7, fill: Pal.robot)
        c.hline(1, 3 + bob, 7, Pal.robotShade.lighter(0.4))
        c.rect(2, 4 + bob, 5, 2, Pal.eye)
        c.dot(3, 4 + bob, Pal.robotEye); c.dot(5, 4 + bob, Pal.robotEye)
        c.hline(2, 7 + bob, 5, Pal.robotShade)
        return c
    }

    static func ghost(_ frame: Int) -> PixelCanvas {
        var c = PixelCanvas(14, 16)
        let g = Pal.ghost
        c.hline(4, 0, 6, Pal.outline.with(alpha: 150))
        c.rect(3, 1, 8, 1, g); c.rect(2, 2, 10, 10, g); c.rect(1, 4, 12, 9, g)
        c.vline(0, 4, 9, Pal.outline.with(alpha: 150)); c.vline(13, 4, 9, Pal.outline.with(alpha: 150))
        let wave = frame % 2
        for x in stride(from: 1, to: 13, by: 3) { c.rect(x + wave, 13, 2, 2, g) }
        c.rect(4, 6, 2, 3, Pal.eye.with(alpha: 220)); c.rect(8, 6, 2, 3, Pal.eye.with(alpha: 220))
        c.dot(3, 9, Pal.blush.with(alpha: 160)); c.dot(10, 9, Pal.blush.with(alpha: 160))
        c.vline(2, 5, 6, Pal.ghostShade)
        return c
    }

    /// 메뉴 막대용 달리는 직원(14×16). 압박 수준에 따라 후드 색과 땀이 바뀐다.
    static func runner(_ frame: Int, hoodie: PixelColor, sweat: Bool, alert: Bool) -> PixelCanvas {
        var c = PixelCanvas(16, 16)
        let look = WorkerLook(hoodie: hoodie, hair: Pal.hairs[0], hairStyle: 0)
        let bob = frame % 2 == 1 ? 1 : 0
        // 작은 머리(9×8)
        let o = Pal.outline
        c.hline(4, bob, 6, o); c.vline(3, 1 + bob, 6, o); c.vline(10, 1 + bob, 6, o); c.hline(4, 7 + bob, 6, o)
        c.rect(4, 1 + bob, 6, 2, look.hair); c.rect(4, 3 + bob, 6, 4, look.skin); c.rect(4, 3 + bob, 1, 2, look.hair)
        c.dot(7, 4 + bob, Pal.eye); c.dot(9, 4 + bob, Pal.eye); c.dot(6, 6 + bob, Pal.blush)
        // 몸통
        c.box(4, 8 + bob, 6, 4, fill: hoodie, rounded: false)
        // 팔·다리(달리기 4프레임)
        let legsFrames: [[(Int, Int)]] = [[(3, 12), (9, 13)], [(5, 12), (7, 12)], [(8, 12), (4, 13)], [(6, 12), (6, 12)]]
        for (x, y) in legsFrames[frame % 4] { c.rect(x, y, 2, 3, Pal.pants); c.hline(x - 1, y + 3, 3, o) }
        let armsFrames: [[(Int, Int)]] = [[(2, 8), (11, 10)], [(3, 9), (10, 9)], [(11, 8), (2, 10)], [(3, 9), (10, 9)]]
        for (x, y) in armsFrames[frame % 4] { c.rect(x, y + bob, 2, 2, hoodie.darker(0.1)) }
        if sweat { c.dot(12, 2, PixelColor(0x6EC6FF)); c.dot(13, 4, PixelColor(0x6EC6FF)) }
        if alert { c.rect(13, 0, 2, 4, Pal.alarm); c.rect(13, 5, 2, 1, Pal.alarm) }
        return c
    }
}


/// 하위 에이전트 로봇 생김새(씨앗으로 고정 — 같은 에이전트면 같은 로봇).
struct RobotDesign: Hashable {
    let body: Int     // 0 네모 · 1 둥근 · 2 캡슐 · 3 바퀴 · 4 드론
    let head: Int     // 0 안테나 · 1 접시 · 2 램프 · 3 귀
    let color: PixelColor
    let eye: PixelColor
    let workflow: Bool

    static let colors: [PixelColor] = [PixelColor(0xA9B2BC), PixelColor(0x7FB3D5), PixelColor(0xF5B041), PixelColor(0x82E0AA), PixelColor(0xF1948A), PixelColor(0xBB8FCE), PixelColor(0xE5E8E8), PixelColor(0x76D7C4)]
    static let eyes: [PixelColor] = [PixelColor(0x6EF0FF), PixelColor(0x9CFF6E), PixelColor(0xFFD34E), PixelColor(0xFF7A7A)]

    init(seed: Int, workflow: Bool) {
        body = seed % 5
        head = (seed / 5) % 4
        color = Self.colors[(seed / 20) % Self.colors.count]
        eye = Self.eyes[(seed / 160) % Self.eyes.count]
        self.workflow = workflow
    }

    var key: String { "\(body)\(head)-\(color.r)\(color.g)\(color.b)-\(eye.r)-\(workflow)" }
}
