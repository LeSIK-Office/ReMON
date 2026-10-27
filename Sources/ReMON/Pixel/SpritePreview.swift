import AppKit
import ReMONCore

/// 개발용: `ReMON --render-sprites out.png` → 스프라이트 시트를 PNG로 저장(시각 검수용).
enum SpritePreview {
    static func render(to path: String, scale: Int = 6) {
        let teams = [PixelColor(0xE8735A), PixelColor(0x2BA59B), PixelColor(0x3FA34D), PixelColor(0x5B7BD5), PixelColor(0xB8BCC4)]
        let poses: [WorkerPose] = [.stand(blink: false), .stand(blink: true), .walk(0), .walk(1), .walk(2), .walk(3), .sitType(0), .sitType(1), .sitWait, .sleepDesk(0),
                                   .kick(0), .kick(1), .dragged(0), .dragged(1), .pushup(0), .pushup(1), .jumpingJack(0), .wave(0), .carry(0), .shout(0), .lie]
        var rows: [[PixelCanvas]] = []
        for (index, team) in teams.enumerated() {
            let look = WorkerLook.seeded(index * 31 + 7, hoodie: team)
            rows.append(poses.map { CharacterArt.worker(look, $0) })
        }
        rows.append([CharacterArt.guardSprite(.stand(blink: false)), CharacterArt.guardSprite(.walk(0)), CharacterArt.guardSprite(.dragged(0)),
                     CharacterArt.trainerSprite(.stand(blink: false)), CharacterArt.trainerSprite(.walk(1)), CharacterArt.trainerSprite(.shout(0)),
                     CharacterArt.robot(0), CharacterArt.robot(1), CharacterArt.ghost(0), CharacterArt.ghost(1),
                     CharacterArt.runner(0, hoodie: teams[0], sweat: false, alert: false), CharacterArt.runner(1, hoodie: teams[0], sweat: false, alert: false),
                     CharacterArt.runner(2, hoodie: PixelColor(0xF2C14E), sweat: true, alert: false), CharacterArt.runner(3, hoodie: Pal.alarm, sweat: true, alert: true)])
        // 감사 연출 인물: 감사관 · 비서 · 정신교육실 강사(훈계·어르기·달래기·지시) · 짐꾼(걷기·상자·수레 밀기) · 수레
        rows.append([CharacterArt.auditorSprite(.stand(blink: false)), CharacterArt.auditorSprite(.scold(0)), CharacterArt.secretarySprite(.stand(blink: false)),
                     CharacterArt.instructorSprite(.stand(blink: false)), CharacterArt.instructorSprite(.walk(1)), CharacterArt.instructorSprite(.scold(0)),
                     CharacterArt.instructorSprite(.wave(0)), CharacterArt.instructorSprite(.clap(1)), CharacterArt.instructorSprite(.shout(0)),
                     CharacterArt.porterSprite(.walk(0)), CharacterArt.porterSprite(.carry(1)), CharacterArt.porterSprite(.push(0)), CharacterArt.porterSprite(.push(1)),
                     MachineArt.cart()])
        // 도구실 배송·설치 기사(걷기 · 수레 밀기 · 뜯기 · 볼트) · 기록관(걷기 · 들고 걷기 · 사다리) · 물걸레 청소 · 상자 · 리프트 · 경광등
        rows.append([CharacterArt.courierSprite(.stand(blink: false)), CharacterArt.courierSprite(.walk(1)), CharacterArt.courierSprite(.push(0)),
                     CharacterArt.courierSprite(.pry(0)), CharacterArt.courierSprite(.pry(1)), CharacterArt.courierSprite(.kneel(0)), CharacterArt.courierSprite(.kneel(1)),
                     CharacterArt.archivistSprite(.stand(blink: false)), CharacterArt.archivistSprite(.walk(1)), CharacterArt.archivistSprite(.push(0)),
                     CharacterArt.archivistSprite(.climb(0)), CharacterArt.archivistSprite(.climb(1)),
                     CharacterArt.janitorSprite(1, .mop(0)), CharacterArt.janitorSprite(1, .mop(1)),
                     MachineArt.crate(1), MachineArt.crate(3), MachineArt.liftBase(), MachineArt.liftArms(height: 20), MachineArt.liftDeck(),
                     MachineArt.beacon(0), MachineArt.beacon(2), MachineArt.cabinet(0), MachineArt.cabinet(3), MachineArt.bucket()])
        // 옥상 웰니스 풀(Rooftop.swift): 디제이(서기 · 걷기 · 장비 가방 · 디제잉 · 손 머리 위로 · 인사) · 물속 춤 · 부스 · 미러볼 · 김 · 수중등 · 음표
        let swimmer = WorkerLook.seeded(5 * 31 + 7, hoodie: teams[0])
        rows.append([CharacterArt.djSprite(.stand(blink: false)), CharacterArt.djSprite(.walk(1)), CharacterArt.djSprite(.carry(0)), CharacterArt.djSprite(.scratch(0)),
                     CharacterArt.djSprite(.scratch(1)), CharacterArt.djSprite(.shout(0)), CharacterArt.djSprite(.wave(0)),
                     CharacterArt.worker(swimmer, .splash(0)), CharacterArt.worker(swimmer, .splash(1)), CharacterArt.worker(swimmer, .swim(0)),
                     PoolArt.booth(0), PoolArt.booth(1), PoolArt.discoBall(0), PoolArt.discoBall(1),
                     PoolArt.steamPuff(0), PoolArt.steamPuff(1), PoolArt.steamPuff(2), PoolArt.underwaterGlow(PoolArt.cyan), PoolArt.underwaterLamp(PoolArt.warm),
                     PoolArt.note(0, Pal.white), PoolArt.note(1, Pal.badge)])
        // 디스크 정비 · 재고 조사(Inventory.swift · DiskStock.swift): 재고 인력(서기 · 걷기 · 손수레 · 세기 · 외침) · 기술자 · 손수레 · 단말기 수레 ·
        // 압축기(몸통 · 누름판 · 레버 올림/내림 · 경고등) · 꼬리표 상자(점선 = 치울 수 있음) · 항목 상자 · 스티커 · 날개 · 속 · 탁자
        rows.append([CharacterArt.stockSprite(0, .stand(blink: false)), CharacterArt.stockSprite(1, .walk(1)), CharacterArt.stockSprite(2, .push(0)),
                     CharacterArt.stockSprite(0, .wave(0)), CharacterArt.stockSprite(3, .wave(1)), CharacterArt.stockSprite(0, .shout(0)),
                     CharacterArt.technicianSprite(.stand(blink: false)), CharacterArt.technicianSprite(.walk(1)), CharacterArt.technicianSprite(.push(0)),
                     DiskStockArt.handTruck(), DiskStockArt.terminalCart(0), DiskStockArt.terminalCart(1),
                     DiskStockArt.compactor(), DiskStockArt.compactorPress(), DiskStockArt.compactorLever(down: false), DiskStockArt.compactorLever(down: true), DiskStockArt.compactorLamp()])
        let stockTags: [DiskTag] = [.cache, .regenerable, .aiTranscript, .gitByproduct, .docker, .xcode, .homebrew, .temp, .trash, .large, .userFile, .system]
        var stockRow: [PixelCanvas] = []
        for tag in stockTags {
            stockRow.append(DiskStockArt.shelfBox(tag, dashed: false, variant: 0))
            stockRow.append(DiskStockArt.shelfBox(tag, dashed: true, variant: 1))
        }
        stockRow += [DiskStockArt.shelfBox(nil, dashed: false, variant: 0), DiskStockArt.itemBox(.cache), DiskStockArt.itemBox(.docker),
                     DiskStockArt.sticker(marked: true), DiskStockArt.sticker(marked: false), DiskStockArt.flap(.cache), DiskStockArt.contents(),
                     DiskStockArt.sortingTable(width: 40)]
        rows.append(stockRow)
        // 방 안 짐(Clutter.swift): 상자 세 크기 × 변형(갈색 테이프 = 남길 것 · 노란 테이프 = 치울 수 있음) · 책상 낱장 · 서류 더미 · 바인더 · 쏟아진 서류 · '복잡' · '정리 중' 테이프
        var clutterRow: [PixelCanvas] = []
        for size in ClutterArt.BoxSize.allCases {
            for variant in [0, 5, 10] { clutterRow += [ClutterArt.box(size, variant: variant, cleanable: false), ClutterArt.box(size, variant: variant, cleanable: true)] }
        }
        clutterRow += [ClutterArt.deskSheets(variant: 0, cleanable: false), ClutterArt.deskSheets(variant: 1, cleanable: true),
                       ClutterArt.deskStack(height: 16, variant: 0, cleanable: false), ClutterArt.deskStack(height: 19, variant: 1, cleanable: true),
                       ClutterArt.binders(variant: 0, cleanable: false), ClutterArt.binders(variant: 3, cleanable: true),
                       ClutterArt.spill(width: 10, variant: 0, cleanable: false), ClutterArt.spill(width: 10, variant: 1, cleanable: true),
                       ClutterArt.complexSign(), ClutterArt.cleaningTape(width: 24)]
        rows.append(clutterRow)
        rows.append(Furniture.previewItems())
        let heights = rows.map { ($0.map(\.height).max() ?? 0) + 6 }
        let widths = rows.map { row in row.reduce(0) { $0 + $1.width + 6 } }
        var sheet = PixelCanvas(widths.max() ?? 1, heights.reduce(0, +), fill: Pal.cream)
        var y = 0
        for (r, row) in rows.enumerated() {
            var x = 3
            for sprite in row {
                sheet.stamp(sprite, x, y + heights[r] - 3 - sprite.height)
                x += sprite.width + 6
            }
            y += heights[r]
        }
        guard let image = sheet.cgImage(scale: scale) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("sprites: \(path) \(sheet.width)x\(sheet.height) x\(scale)")
    }

    /// 개발용: `ReMON --render-floors <폴더>` → 층 배경(FloorPainter)을 PNG로 저장(방 테마·기록 보관소 검수용).
    /// 앱을 띄우지 않고 그림만 그린다. 책상에는 장면처럼 앉은 직원과 모니터를 얹는다.
    static func renderFloors(to folder: String) {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let teams = [PixelColor(0xE8735A), PixelColor(0x2BA59B), PixelColor(0x3FA34D), PixelColor(0x5B7BD5), PixelColor(0x9C7AD8)]
        var seed = 0
        /// 방 목록(이름 · 책상 수 · 앉은 수)으로 팀 층 하나를 그린다.
        func teamFloor(_ specs: [(String, Int, Int)]) -> PixelCanvas {
            let floorIndex = BuildingLayout.firstTeamFloor
            var rooms: [BuildingLayout.Room] = []
            var desks: [BuildingLayout.DeskSlot] = []
            var seated: [Int] = []
            var x = BuildingLayout.mainX0
            for (index, spec) in specs.enumerated() {
                let width = BuildingLayout.roomPadding * 2 + spec.1 * BuildingLayout.deskPitch
                rooms.append(.init(name: spec.0, floor: floorIndex, x0: x, x1: x + width, deskCount: spec.1, variant: index % 2))
                for i in 0..<spec.1 {
                    let deskX = x + BuildingLayout.roomPadding + i * BuildingLayout.deskPitch
                    desks.append(.init(floor: floorIndex, deskX: deskX, room: index))
                    if i < spec.2 { seated.append(deskX) }
                }
                x += width
            }
            var c = FloorPainter.team(height: BuildingLayout.teamHeight, floorIndex: floorIndex, rooms: rooms, desks: desks, isTop: false, isLibraryUpper: false)
            let line = BuildingLayout.teamHeight - BuildingLayout.slab
            for desk in desks {
                let on = seated.contains(desk.deskX)
                c.stamp(Furniture.monitor(on: on), desk.deskX + 21, line - 22)
                guard on else { continue }
                seed += 1
                let look = WorkerLook.seeded(seed * 7919, hoodie: teams[seed % teams.count])
                c.stamp(CharacterArt.worker(look, .sitType(0)), desk.deskX - 2, line - 24)
            }
            return c
        }
        func crop(_ c: PixelCanvas, _ x0: Int, _ x1: Int) -> PixelCanvas {
            var out = PixelCanvas(x1 - x0, c.height)
            out.stamp(c, -x0, 0)
            return out
        }
        func stack(_ items: [PixelCanvas], gap: Int = 0) -> PixelCanvas {
            var out = PixelCanvas(items.map(\.width).max() ?? 1, items.reduce(0) { $0 + $1.height } + gap * max(0, items.count - 1), fill: Pal.black)
            var y = 0
            for item in items { out.stamp(item, 0, y); y += item.height + gap }
            return out
        }
        func write(_ c: PixelCanvas, _ name: String, scale: Int) {
            guard let image = c.cgImage(scale: scale) else { return }
            let path = (folder as NSString).appendingPathComponent(name)
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("floors: \(path) \(c.width)x\(c.height) x\(scale)")
        }

        // 1) 실제 같은 팀 층 세 개(방 크기 섞어서)
        let floors = [
            teamFloor([("AI_OFFICE", 3, 3), ("COOKSUP_SYSTEM", 2, 2), ("FORMEA", 2, 1)]),
            teamFloor([("LeCIE", 1, 1), ("ReMON", 4, 3), ("blog", 1, 1)]),
            teamFloor([("Folder Backup", 2, 2), ("dotfiles", 1, 1), ("kds-web", 2, 2), ("notes", 1, 0)]),
        ]
        write(stack(floors.reversed().map { crop($0, 0, BuildingLayout.wingX0) }), "team-floors.png", scale: 3)
        // 2) 방 24개 갤러리(2인실 × 3개 × 8층): 이름만 다른 방들이 얼마나 달라 보이는지
        let names = ["ReMON", "COOKSUP_SYSTEM", "FORMEA", "LeCIE", "AI_OFFICE", "Folder Backup", "dotfiles", "blog", "kds-web", "notes", "infra", "design-system",
                     "orca-tools", "landing", "api-server", "mobile-app", "data-pipeline", "docs", "playground", "scraper", "billing", "analytics", "chatbot", "game-jam"]
        let gallery = stride(from: 0, to: names.count, by: 3).map { start in
            crop(teamFloor(names[start..<min(names.count, start + 3)].map { ($0, 2, 1) }), BuildingLayout.mainX0, BuildingLayout.mainX0 + 360)
        }
        write(stack(gallery, gap: 2), "room-gallery.png", scale: 3)
        // 이름 → 테마 축 목록(결정성 확인용: 두 번 돌려 같은지 비교한다)
        let summary = names.map { name -> String in
            let t = RoomTheme.of(name)
            let palette = RoomPalette.all.firstIndex(of: t.palette) ?? -1
            return "\(name)\tpalette=\(palette) wall=\(t.wall) dado=\(t.dado) floor=\(t.floor) window=\(t.window) lamp=\(t.lamp) accent=\(t.accent) decor=\(t.decor) corner=\(t.corner) desk=\(t.deskFinish)"
        }.joined(separator: "\n")
        try? (summary + "\n").write(toFile: (folder as NSString).appendingPathComponent("themes.txt"), atomically: true, encoding: .utf8)
        // 3) 1층 로비 + 기록 보관소(별관 노드를 같은 자리에 겹친다)
        var lobby = FloorPainter.lobby(height: BuildingLayout.lobbyHeight)
        let archive = FloorPainter.library(height: BuildingLayout.lobbyHeight)
        lobby.stamp(archive, BuildingLayout.wingX0, 0)
        write(lobby, "lobby.png", scale: 3)
        write(archive, "archive.png", scale: 6)
        // 쉬는 직원을 장면과 같은 자리에 앉혀 본 기록 보관소(독서 6 · 낮잠 1)
        var occupied = archive
        let line = BuildingLayout.lobbyHeight - BuildingLayout.slab
        for (index, spot) in [482, 500, 518, 572, 600, 616].enumerated() {
            let look = WorkerLook.seeded(index * 977 + 13, hoodie: teams[index % teams.count])
            let sprite = CharacterArt.worker(look, .read(0))
            occupied.stamp(spot < 560 ? sprite : sprite.flippedHorizontally(), spot - BuildingLayout.wingX0 - sprite.width / 2, line - sprite.height)
        }
        let napper = CharacterArt.worker(WorkerLook.seeded(4242, hoodie: teams[1]), .lie)
        occupied.stamp(napper, 548 - BuildingLayout.wingX0 - napper.width / 2, line - 40 - napper.height)
        write(occupied, "archive-occupied.png", scale: 6)
        // 4) 테마 소품 낱장(창·등 / 소품·책상 마감)
        let items = Furniture.themePreviewItems()
        for (index, part) in [Array(items.prefix(17)), Array(items.dropFirst(17))].enumerated() {
            var strip = PixelCanvas(part.reduce(0) { $0 + $1.width + 4 } + 4, (part.map(\.height).max() ?? 0) + 8, fill: PixelColor(0xD9DEE6))
            var x = 4
            for item in part { strip.stamp(item, x, strip.height - 4 - item.height); x += item.width + 4 }
            write(strip, "theme-items-\(index + 1).png", scale: 5)
        }
    }
}
