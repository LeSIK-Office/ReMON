import Foundation
import ReMONCore

/// 건물 단면 배치(가상 픽셀, 원점 = 건물 왼쪽 아래, y 위로).
/// 아래부터: 지하(창고·디스크·시설) → 1층(로비·중정) → 팀 층들(프로젝트별 방) → 옥상(루프톱·웰니스 풀).
struct BuildingLayout: Equatable {
    enum FloorKind: Equatable { case basement, lobby, hall, team(Int), roof }

    struct Floor: Equatable {
        var kind: FloorKind
        var y: Int
        var height: Int
        var floorLine: Int { y + BuildingLayout.slab }
    }

    struct Room: Equatable {
        var name: String
        var floor: Int
        var x0: Int
        var x1: Int
        var deskCount: Int
        var variant: Int
    }

    struct DeskSlot: Equatable {
        var floor: Int
        var deskX: Int
        var room: Int
        /// 앉은 직원의 기준 x(스프라이트 아래 가운데).
        var seatX: Int { deskX + 6 }
    }

    struct Spot: Equatable {
        enum Kind: Equatable { case hammock, reading, lounger, beanbag, desk, sofa, lounge, standing, swim, hallSeat, classSeat }
        var kind: Kind
        var floor: Int
        var x: Int
        var yOffset: Int = 0
        /// 강당·교육실처럼 뒷줄이 있으면 뒷줄은 살짝 위에, 뒤에 그린다.
        var row: Int = 0
    }

    static let width = 640
    static let slab = 4
    static let basementHeight = 72
    static let lobbyHeight = 88
    static let hallHeight = 84
    static let teamHeight = 80
    static let roofHeight = 66
    static let skyHeight = 56
    static let elevatorX0 = 8, elevatorX1 = 32
    static let mainX0 = 36, mainX1 = 468
    static let wingX0 = 472, wingX1 = 632
    static let deskPitch = 50
    static let roomPadding = 10
    static let maxDesksPerFloor = 8

    var floors: [Floor] = []
    var rooms: [Room] = []
    var desks: [ProcessKey: DeskSlot] = [:]
    var deskOrder: [ProcessKey] = []
    var spareDesks: [DeskSlot] = []

    var height: Int { (floors.last.map { $0.y + $0.height } ?? 0) }
    var teamFloorIndexes: [Int] { floors.indices.filter { if case .team = floors[$0].kind { return true } else { return false } } }
    var lobbyIndex: Int { 1 }
    var basementIndex: Int { 0 }
    /// 강당(대기실) + 별관 정신교육실. 오래 쉰 세션이 모이고, 감사가 여기로 들이닥친다.
    var hallIndex: Int { 2 }
    var roofIndex: Int { floors.count - 1 }
    var topTeamIndex: Int { floors.count - 2 }
    /// 팀 층 번호(0부터) → 건물 층 번호.
    static let firstTeamFloor = 3

    static func make(sessions: [AgentSession]) -> BuildingLayout {
        // 프로젝트별 책상 수(모든 세션이 자기 책상을 가진다. 쉬는 직원은 자리를 비운다).
        var byProject: [String: [AgentSession]] = [:]
        for session in sessions { byProject[session.project, default: []].append(session) }
        let projects = byProject.keys.sorted()
        var chunks: [(name: String, members: [AgentSession])] = []
        for project in projects {
            let members = byProject[project]!.sorted { $0.startTime < $1.startTime }
            var index = 0
            var part = 1
            while index < members.count {
                let slice = Array(members[index..<min(members.count, index + maxDesksPerFloor)])
                chunks.append((part == 1 ? project : "\(project) \(part)", slice))
                index += maxDesksPerFloor
                part += 1
            }
        }
        // 큰 방부터 들어갈 수 있는 가장 아래층에 넣는다(first-fit decreasing). 같은 층 안에서는 이름순.
        var placements: [[(name: String, members: [AgentSession])]] = []
        var used: [Int] = []
        let available = mainX1 - mainX0
        for chunk in chunks.sorted(by: { $0.members.count != $1.members.count ? $0.members.count > $1.members.count : $0.name < $1.name }) {
            let width = roomPadding * 2 + chunk.members.count * deskPitch
            if let floor = used.firstIndex(where: { $0 + width <= available }) {
                placements[floor].append(chunk)
                used[floor] += width
            } else {
                placements.append([chunk])
                used.append(width)
            }
        }
        placements = placements.map { $0.sorted { $0.name < $1.name } }
        while placements.count < 2 { placements.append([]) }

        var layout = BuildingLayout()
        var y = 0
        layout.floors.append(Floor(kind: .basement, y: y, height: basementHeight)); y += basementHeight
        layout.floors.append(Floor(kind: .lobby, y: y, height: lobbyHeight)); y += lobbyHeight
        layout.floors.append(Floor(kind: .hall, y: y, height: hallHeight)); y += hallHeight
        for (teamIndex, floorRooms) in placements.enumerated() {
            let floorIndex = layout.floors.count
            layout.floors.append(Floor(kind: .team(teamIndex), y: y, height: teamHeight)); y += teamHeight
            var x = mainX0
            for (roomIndex, chunk) in floorRooms.enumerated() {
                let width = roomPadding * 2 + chunk.members.count * deskPitch
                let room = Room(name: chunk.name, floor: floorIndex, x0: x, x1: x + width, deskCount: chunk.members.count, variant: (teamIndex + roomIndex) % 2)
                let roomNumber = layout.rooms.count
                layout.rooms.append(room)
                for (i, member) in chunk.members.enumerated() {
                    layout.desks[member.id] = DeskSlot(floor: floorIndex, deskX: x + roomPadding + i * deskPitch, room: roomNumber)
                    layout.deskOrder.append(member.id)
                }
                x += width
            }
        }
        layout.floors.append(Floor(kind: .roof, y: y, height: roofHeight))
        return layout
    }

    /// 쉬는 직원의 놀이 자리(쉼): 옥상 수영장·선베드·빈백, 별관 해먹·독서 의자, 로비 안락의자. 행동 엔진이 돌아가며 고른다.
    var playSpots: [Spot] {
        var spots: [Spot] = []
        spots += Self.swimLanes.map { Spot(kind: .swim, floor: roofIndex, x: $0, yOffset: 1) }
        spots += [44, 92, 140, 188, 236].map { Spot(kind: .lounger, floor: roofIndex, x: $0 + 12, yOffset: 5) }
        spots += [276, 296].map { Spot(kind: .beanbag, floor: roofIndex, x: $0) }
        spots.append(Spot(kind: .hammock, floor: 1, x: 548, yOffset: 40))
        spots += [482, 500, 600, 616, 518, 572].map { Spot(kind: .reading, floor: 1, x: $0) }
        spots += Self.lobbyArmchairs.map { Spot(kind: .sofa, floor: 1, x: $0 + 8) }
        return spots
    }

    /// 강당(대기실) 좌석: 두 줄 × 26. 오래 쉰 세션·고아 세션이 모여 앉는다.
    var hallSeats: [Spot] {
        (0..<Self.hallSeatsPerRow).map { Spot(kind: .hallSeat, floor: hallIndex, x: Self.hallSeatX0 + $0 * Self.hallSeatPitch, yOffset: 0, row: 0) } +
        (0..<Self.hallSeatsPerRow).map { Spot(kind: .hallSeat, floor: hallIndex, x: Self.hallSeatX0 + 7 + $0 * Self.hallSeatPitch, yOffset: 12, row: 1) }
    }

    /// 별관 정신교육실 좌석 4개(칠판을 보고 앉는다).
    var classSeats: [Spot] {
        Self.classSeatXs.map { Spot(kind: .classSeat, floor: hallIndex, x: $0) }
    }

    /// 상태별 기본 자리(행동 엔진이 없을 때의 정적 배치).
    func restSpots(for state: SessionState) -> [Spot] {
        switch state {
        case .idle: return playSpots
        case .longIdle, .orphan: return hallSeats
        default: return []
        }
    }

    static let swimLanes: [Int] = [364, 404, 444, 484, 524, 564]
    static let hallSeatX0 = 74
    static let hallSeatPitch = 14
    static let hallSeatsPerRow = 26
    static let hallDoorX = 50
    static let hallStageX = 432
    static let classSeatXs: [Int] = [500, 534, 568, 602]
    static let classBoardX = 486
    /// 로비(36~226): 소파(162~198) 위 대기 인력 세 자리 · 양옆 안락의자(놀이 자리). 로비 오른쪽은 도구실(ToolRoom, 228~468).
    static let lobbySofaX = 162
    static let lobbyArmchairs: [Int] = [146, 199]
    static let sofaSpots: [Int] = [168, 182, 196]
    static let guardPostX = 118
    static let doorX = 60
    static let elevatorX = 20
    static let chuteX = 304
}

/// 점진 배치: 한 번 정한 방(층·위치)과 책상은 그대로 두고, 새 프로젝트만 빈 칸에 넣는다.
/// 세션이 하나 늘거나 줄 때 다른 직원들이 우르르 자리를 옮기는 일(의자 뺏기)을 막는다.
final class LayoutPlanner {
    private struct RoomState {
        var name: String
        var project: String
        var part: Int
        var floor: Int      // 팀 층 번호(0 = 첫 팀 층)
        var x0: Int
        var capacity: Int
    }

    private var rooms: [String: RoomState] = [:]
    private var seats: [ProcessKey: (room: String, index: Int)] = [:]

    func plan(sessions: [AgentSession]) -> BuildingLayout {
        let pitch = BuildingLayout.deskPitch, padding = BuildingLayout.roomPadding, maxDesks = BuildingLayout.maxDesksPerFloor
        let available = BuildingLayout.mainX1 - BuildingLayout.mainX0
        func width(_ capacity: Int) -> Int { padding * 2 + capacity * pitch }

        // 프로젝트별 구성원(시작 순). 8명을 넘으면 '프로젝트 2' 방으로 나눈다.
        var chunks: [String: (project: String, part: Int, members: [AgentSession])] = [:]
        for (project, members) in Dictionary(grouping: sessions, by: \.project) {
            let ordered = members.sorted { $0.startTime < $1.startTime }
            for part in 0..<Int((Double(ordered.count) / Double(maxDesks)).rounded(.up)) {
                let slice = Array(ordered[(part * maxDesks)..<min(ordered.count, (part + 1) * maxDesks)])
                let name = part == 0 ? project : "\(project) \(part + 1)"
                chunks[name] = (project, part, slice)
            }
        }
        rooms = rooms.filter { chunks[$0.key] != nil }

        func occupied(floor: Int, except name: String? = nil) -> [(Int, Int)] {
            rooms.values.filter { $0.floor == floor && $0.name != name }.map { ($0.x0, $0.x0 + width($0.capacity)) }.sorted { $0.0 < $1.0 }
        }
        func findGap(width w: Int, except name: String? = nil) -> (floor: Int, x0: Int) {
            let floors = (rooms.values.map(\.floor).max() ?? -1) + 1
            for floor in 0..<max(1, floors) {
                var cursor = BuildingLayout.mainX0
                for (start, end) in occupied(floor: floor, except: name) {
                    if start - cursor >= w { return (floor, cursor) }
                    cursor = max(cursor, end)
                }
                if BuildingLayout.mainX1 - cursor >= w { return (floor, cursor) }
            }
            return (floors, BuildingLayout.mainX0)
        }

        // 기존 방: 제자리에서 늘리거나(옆이 비면) 안 되면 그 방만 옮긴다. 줄일 때는 앉은 사람을 남긴다.
        for name in chunks.keys.sorted() {
            let chunk = chunks[name]!
            let needed = chunk.members.count
            if var room = rooms[name] {
                if needed > room.capacity {
                    let limit = occupied(floor: room.floor, except: name).first { $0.0 >= room.x0 }?.0 ?? BuildingLayout.mainX1
                    let grown = min(maxDesks, needed + 1)
                    if room.x0 + width(grown) <= limit {
                        room.capacity = grown
                    } else {
                        let spot = findGap(width: width(grown), except: name)
                        room.floor = spot.floor
                        room.x0 = spot.x0
                        room.capacity = grown
                    }
                } else {
                    let highest = chunk.members.compactMap { seats[$0.id]?.room == name ? seats[$0.id]?.index : nil }.max() ?? -1
                    room.capacity = max(1, min(room.capacity, max(needed + 1, highest + 1)))
                }
                rooms[name] = room
            }
        }
        // 새 방: 예비 책상 1개를 더해 빈 칸에 넣는다(아래층부터). 큰 방부터 넣어(FFD) 첫 배치도 촘촘하게.
        let newRooms = chunks.keys.filter { rooms[$0] == nil }.sorted { lhs, rhs in
            let l = chunks[lhs]!.members.count, r = chunks[rhs]!.members.count
            return l != r ? l > r : lhs < rhs
        }
        for name in newRooms {
            let chunk = chunks[name]!
            let capacity = min(maxDesks, chunk.members.count + 1)
            let fitCapacity = width(capacity) <= available ? capacity : chunk.members.count
            let spot = findGap(width: width(fitCapacity))
            rooms[name] = RoomState(name: name, project: chunk.project, part: chunk.part, floor: spot.floor, x0: spot.x0, capacity: fitCapacity)
        }
        // 위쪽 빈 층 정리(방 번호는 유지)
        let usedFloors = Set(rooms.values.map(\.floor))
        if let maxFloor = usedFloors.max(), maxFloor > 0 {
            for floor in stride(from: maxFloor, to: 0, by: -1) where !usedFloors.contains(floor - 1) {
                for key in rooms.keys where rooms[key]!.floor >= floor { rooms[key]!.floor -= 1 }
            }
        }

        // 책상: 이전 자리 유지, 새 사람은 가장 앞의 빈 책상.
        var newSeats: [ProcessKey: (room: String, index: Int)] = [:]
        for (name, chunk) in chunks {
            let capacity = rooms[name]!.capacity
            var taken = Set<Int>()
            for member in chunk.members {
                if let seat = seats[member.id], seat.room == name, seat.index < capacity, !taken.contains(seat.index) {
                    newSeats[member.id] = seat
                    taken.insert(seat.index)
                }
            }
            for member in chunk.members where newSeats[member.id] == nil {
                let index = (0..<capacity).first { !taken.contains($0) } ?? 0
                newSeats[member.id] = (name, index)
                taken.insert(index)
            }
        }
        seats = newSeats

        // BuildingLayout으로 변환
        let teamFloors = max(2, (rooms.values.map(\.floor).max() ?? 0) + 1)
        var layout = BuildingLayout()
        var y = 0
        layout.floors.append(.init(kind: .basement, y: y, height: BuildingLayout.basementHeight)); y += BuildingLayout.basementHeight
        layout.floors.append(.init(kind: .lobby, y: y, height: BuildingLayout.lobbyHeight)); y += BuildingLayout.lobbyHeight
        layout.floors.append(.init(kind: .hall, y: y, height: BuildingLayout.hallHeight)); y += BuildingLayout.hallHeight
        for index in 0..<teamFloors {
            layout.floors.append(.init(kind: .team(index), y: y, height: BuildingLayout.teamHeight)); y += BuildingLayout.teamHeight
        }
        layout.floors.append(.init(kind: .roof, y: y, height: BuildingLayout.roofHeight))
        var roomIndex: [String: Int] = [:]
        for room in rooms.values.sorted(by: { ($0.floor, $0.x0) < ($1.floor, $1.x0) }) {
            roomIndex[room.name] = layout.rooms.count
            let variant = abs(room.project.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) }) % 2
            layout.rooms.append(.init(name: room.name, floor: room.floor + BuildingLayout.firstTeamFloor, x0: room.x0, x1: room.x0 + width(room.capacity), deskCount: room.capacity, variant: variant))
        }
        for (key, seat) in seats {
            guard let room = rooms[seat.room], let index = roomIndex[seat.room] else { continue }
            layout.desks[key] = .init(floor: room.floor + BuildingLayout.firstTeamFloor, deskX: room.x0 + padding + seat.index * pitch, room: index)
            layout.deskOrder.append(key)
        }
        // 빈 예비 책상도 가구로 그린다(키 없는 자리).
        layout.spareDesks = rooms.values.flatMap { room in
            (0..<room.capacity).filter { index in !seats.values.contains { $0.room == room.name && $0.index == index } }
                .map { BuildingLayout.DeskSlot(floor: room.floor + BuildingLayout.firstTeamFloor, deskX: room.x0 + padding + $0 * pitch, room: roomIndex[room.name] ?? 0) }
        }
        return layout
    }
}
