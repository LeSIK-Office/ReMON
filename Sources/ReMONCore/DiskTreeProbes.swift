import Darwin
import Foundation

// 디스크 지도가 파일 크기 밖에서 읽는 사실들 — 휴지통의 원래 이름·위치(.DS_Store), Docker·Homebrew 정리 미리보기 해석,
// 시뮬레이터 기기(device.plist)·기기 백업(Info.plist)·큰 파일 종류. 모두 읽기 전용이고, 해석기는 시험에서 만든 글·바이트로 따로 검사한다.

// MARK: - 휴지통 '되돌려 놓기' 기록

/// Finder가 휴지통의 .DS_Store에 적어 두는 원래 이름(ptbN)·원래 폴더(ptbL). 휴지통 안 이름 → 원래 자리.
public enum TrashPutBack {
    public struct Origin: Sendable, Equatable {
        /// 원래 이름(휴지통에서 이름이 바뀌었으면 바뀌기 전)
        public var name: String
        /// 원래 폴더(정식 경로 — /System/Volumes/Data 접두는 뗀다). 모르면 nil.
        public var folder: String?

        public init(name: String, folder: String?) {
            self.name = name
            self.folder = folder
        }
    }

    /// 휴지통 폴더의 .DS_Store를 읽는다(없거나 못 읽으면 빈 목록 — 권한이 없으면 휴지통 자체를 못 본다).
    public static func read(_ trashFolder: String) -> [String: Origin] {
        let path = trashFolder + "/.DS_Store"
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size < 32 << 20, let data = FileManager.default.contents(atPath: path) else { return [:] }
        return parse(data)
    }

    /// .DS_Store(Bud1 버디 할당 + B-트리) 해석. 형식이 어긋나면 그때까지 읽은 것만 돌려준다(경계 밖을 읽지 않는다).
    public static func parse(_ data: Data) -> [String: Origin] {
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        }
        guard bytes.count >= 36, u32(0) == 1, bytes[4..<8].elementsEqual("Bud1".utf8), let rootOffset = u32(8) else { return [:] }
        let root = rootOffset + 4
        guard let count = u32(root), count > 0, count < 1 << 20 else { return [:] }
        var addresses: [Int] = []
        for index in 0..<count {
            guard let address = u32(root + 8 + 4 * index) else { return [:] }
            addresses.append(address)
        }
        // 목차: 이름 길이(1바이트) · 이름 · 블록 번호. 'DSDB'가 B-트리 머리 블록이다.
        var cursor = root + 8 + 4 * ((count + 255) / 256 * 256)
        guard let tocCount = u32(cursor), tocCount < 4096 else { return [:] }
        cursor += 4
        var dsdb: Int?
        for _ in 0..<tocCount {
            guard cursor < bytes.count else { return [:] }
            let length = Int(bytes[cursor])
            guard cursor + 1 + length + 4 <= bytes.count else { return [:] }
            let name = String(decoding: bytes[(cursor + 1)..<(cursor + 1 + length)], as: UTF8.self)
            let value = u32(cursor + 1 + length)
            if name == "DSDB" { dsdb = value }
            cursor += 1 + length + 4
        }
        func block(_ number: Int) -> (start: Int, end: Int)? {
            guard number >= 0, number < addresses.count else { return nil }
            let address = addresses[number]
            let start = (address & ~0x1f) + 4
            let size = 1 << (address & 0x1f)
            guard size >= 32, start >= 0, start < bytes.count else { return nil }
            return (start, min(bytes.count, start + size))
        }
        guard let header = dsdb.flatMap(block), let rootNode = u32(header.start) else { return [:] }

        var names: [String: String] = [:], folders: [String: String] = [:]
        var visited = Set<Int>()
        /// 기록 하나: 파일 이름(UTF-16) · 구조 코드 · 자료형 · 값. 다음 위치를 돌려준다(모르는 자료형이면 nil).
        func record(at start: Int, limit: Int) -> Int? {
            guard let length = u32(start), length < 1 << 16 else { return nil }
            var position = start + 4
            guard position + 2 * length + 8 <= limit else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(length)
            for index in 0..<length { units.append(UInt16(bytes[position + 2 * index]) << 8 | UInt16(bytes[position + 2 * index + 1])) }
            let file = String(decoding: units, as: UTF16.self)
            position += 2 * length
            let code = String(decoding: bytes[position..<(position + 4)], as: UTF8.self)
            let type = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
            position += 8
            switch type {
            case "long", "shor", "type":
                position += 4
            case "bool":
                position += 1
            case "comp", "dutc":
                position += 8
            case "blob":
                guard let size = u32(position) else { return nil }
                position += 4 + size
            case "ustr":
                guard let size = u32(position), position + 4 + 2 * size <= limit else { return nil }
                if code == "ptbN" || code == "ptbL" {
                    var text: [UInt16] = []
                    for index in 0..<size { text.append(UInt16(bytes[position + 4 + 2 * index]) << 8 | UInt16(bytes[position + 4 + 2 * index + 1])) }
                    let value = String(decoding: text, as: UTF16.self)
                    if code == "ptbN" { names[file] = value } else { folders[file] = value }
                }
                position += 4 + 2 * size
            default:
                return nil
            }
            return position <= limit ? position : nil
        }
        func walk(_ number: Int, depth: Int) {
            guard depth < 32, visited.insert(number).inserted, let node = block(number), let next = u32(node.start), let records = u32(node.start + 4), records < 1 << 16 else { return }
            var position = node.start + 8
            for _ in 0..<records {
                if next != 0 {
                    guard let child = u32(position) else { return }
                    walk(child, depth: depth + 1)
                    position += 4
                }
                guard let after = record(at: position, limit: node.end) else { return }
                position = after
            }
            if next != 0 { walk(next, depth: depth + 1) }
        }
        walk(rootNode, depth: 0)

        var result: [String: Origin] = [:]
        for file in Set(names.keys).union(folders.keys) {
            let folder = folders[file].map { raw -> String in
                var path = "/" + raw
                if path.hasPrefix("/System/Volumes/Data/") { path = String(path.dropFirst("/System/Volumes/Data".count)) }
                return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            }
            result[file] = Origin(name: names[file] ?? file, folder: folder)
        }
        return result
    }
}

// MARK: - Docker

/// docker system df · prune 출력 해석. 도커는 크기를 1000 단위(kB·MB·GB)로 쓴다.
public enum DockerDiskUsage {
    /// "1.21GB" · "812.4MB (66%)" · "0B" → 바이트.
    public static func bytes(_ text: String) -> UInt64? {
        let token = text.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
        guard let range = token.range(of: #"^[0-9]+(\.[0-9]+)?"#, options: .regularExpression), let value = Double(token[range]) else { return nil }
        let unit = token[range.upperBound...].uppercased()
        let scale: Double
        switch unit {
        case "B", "": scale = 1
        case "KB": scale = 1_000
        case "MB": scale = 1_000_000
        case "GB": scale = 1_000_000_000
        case "TB": scale = 1_000_000_000_000
        default: return nil
        }
        return UInt64(value * scale)
    }

    /// prune 출력의 마지막 "Total reclaimed space: 1.2GB".
    public static func reclaimed(_ output: String) -> UInt64? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "Total reclaimed space:") { return bytes(String(trimmed[range.upperBound...])) }
        }
        return nil
    }

    /// df 한 줄의 정리 명령(이미지 = 이름 없는 것만 · 빌드 캐시). 컨테이너·볼륨은 정리하지 않는다(볼륨은 데이터).
    public static func command(forType type: String) -> ToolCommand? {
        switch type.lowercased() {
        case "images": ToolCommands.dockerImagePrune
        case "build cache": ToolCommands.dockerBuilderPrune
        default: nil
        }
    }
}

// MARK: - Homebrew

/// `brew cleanup -n --prune=all` 미리보기. Homebrew는 크기를 1024 단위(KB·MB·GB)로 쓴다.
public struct HomebrewPreview: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var path: String
        public var files: Int?
        public var bytes: UInt64

        public init(path: String, files: Int?, bytes: UInt64) {
            self.path = path
            self.files = files
            self.bytes = bytes
        }
    }

    public var items: [Item]
    /// "This operation would free approximately …"의 값
    public var total: UInt64?
    /// 미리보기를 못 돌린 이유
    public var error: String?

    public init(items: [Item] = [], total: UInt64? = nil, error: String? = nil) {
        self.items = items
        self.total = total
        self.error = error
    }

    public var bytes: UInt64 { total ?? items.reduce(0) { $0 + $1.bytes } }

    public static func parse(_ text: String) -> HomebrewPreview {
        var preview = HomebrewPreview()
        let pattern = try? NSRegularExpression(pattern: #"^Would remove: (.+?) \((?:([0-9,]+) files?, )?([0-9.]+)\s?(B|KB|MB|GB|TB)\)$"#)
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let pattern, let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let pathRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 3), in: line), let unitRange = Range(match.range(at: 4), in: line) {
                let files = Range(match.range(at: 2), in: line).flatMap { Int(line[$0].replacingOccurrences(of: ",", with: "")) }
                let bytes = size(String(line[valueRange]), String(line[unitRange]))
                preview.items.append(Item(path: String(line[pathRange]), files: files, bytes: bytes))
            } else if let range = line.range(of: "free approximately ") ?? line.range(of: "freed approximately ") {
                let rest = line[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
                if let unit = rest.range(of: #"(B|KB|MB|GB|TB)$"#, options: .regularExpression) {
                    preview.total = size(String(rest[..<unit.lowerBound]), String(rest[unit]))
                }
            }
        }
        return preview
    }

    static func size(_ value: String, _ unit: String) -> UInt64 {
        let number = Double(value) ?? 0
        let scale: Double = ["B": 1, "KB": 1024, "MB": 1_048_576, "GB": 1_073_741_824, "TB": 1_099_511_627_776][unit] ?? 1
        return UInt64(number * scale)
    }
}

// MARK: - 시뮬레이터 기기 · 기기 백업

/// ~/Library/Developer/CoreSimulator/Devices/<UDID>/device.plist
public struct SimulatorDevice: Sendable, Equatable {
    public var name: String
    /// "iOS 26.5"
    public var runtime: String
    /// 3 = 실행 중(Booted)
    public var state: Int
    public var lastBooted: Date?
    /// device.plist 수정 시각(부팅 기록이 없을 때 기준)
    public var created: Date?

    public var booted: Bool { state == 3 }

    public static func read(_ folder: String) -> SimulatorDevice? {
        let plist = folder + "/device.plist"
        guard let dictionary = NSDictionary(contentsOfFile: plist) as? [String: Any], let name = dictionary["name"] as? String else { return nil }
        let runtime = (dictionary["runtime"] as? String).map(runtimeLabel) ?? ""
        return SimulatorDevice(name: name, runtime: runtime, state: (dictionary["state"] as? NSNumber)?.intValue ?? 0, lastBooted: dictionary["lastBootedAt"] as? Date,
                               created: DiskScanner.modified(plist))
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-5" → "iOS 26.5"
    public static func runtimeLabel(_ identifier: String) -> String {
        let last = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let parts = last.split(separator: "-").map(String.init)
        guard let platform = parts.first, parts.count > 1 else { return last }
        return platform + " " + parts.dropFirst().joined(separator: ".")
    }
}

/// ~/Library/Application Support/MobileSync/Backup/<id>/Info.plist
public struct DeviceBackup: Sendable, Equatable {
    public var deviceName: String
    public var product: String?
    public var lastBackup: Date?

    public static func read(_ folder: String) -> DeviceBackup? {
        guard let dictionary = NSDictionary(contentsOfFile: folder + "/Info.plist") as? [String: Any] else { return nil }
        let name = (dictionary["Device Name"] as? String) ?? (dictionary["Display Name"] as? String) ?? (folder as NSString).lastPathComponent
        let product = (dictionary["Product Name"] as? String) ?? (dictionary["Product Type"] as? String)
        return DeviceBackup(deviceName: name, product: product, lastBackup: dictionary["Last Backup Date"] as? Date)
    }
}

// MARK: - 큰 파일 종류

public enum LargeFileKind: String, Sendable, CaseIterable {
    case diskImage, video, archive, log, database, modelWeights

    public var label: String {
        switch self {
        case .diskImage: "디스크 이미지"
        case .video: "동영상"
        case .archive: "압축 파일"
        case .log: "로그"
        case .database: "데이터베이스"
        case .modelWeights: "모델 가중치"
        }
    }

    static let extensions: [String: LargeFileKind] = {
        var table: [String: LargeFileKind] = [:]
        for name in ["dmg", "iso", "img", "raw", "qcow2", "vdi", "vmdk", "vhd", "vhdx", "sparseimage", "sparsebundle", "toast", "ipsw", "asif"] { table[name] = .diskImage }
        for name in ["mov", "mp4", "m4v", "mkv", "avi", "webm", "wmv", "flv", "mpg", "mpeg", "mts", "m2ts", "hevc"] { table[name] = .video }
        for name in ["zip", "tar", "gz", "tgz", "bz2", "tbz", "xz", "txz", "zst", "7z", "rar", "xip", "lz4", "pkg", "bundle"] { table[name] = .archive }
        for name in ["log", "logarchive", "trace", "ips"] { table[name] = .log }
        for name in ["sqlite", "sqlite3", "db", "realm", "mdb", "ldb", "duckdb", "parquet"] { table[name] = .database }
        for name in ["gguf", "safetensors", "ckpt", "pt", "pth", "onnx", "mlmodel", "mlpackage", "h5", "tflite", "npz"] { table[name] = .modelWeights }
        return table
    }()

    /// 이름(확장자)으로 본 종류. .tar.gz 같은 겹친 확장자는 마지막 것으로 본다.
    public static func kind(for name: String) -> LargeFileKind? {
        extensions[DiskTreeWalker.pathExtension(name)]
    }
}
