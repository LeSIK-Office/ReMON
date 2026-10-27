import Darwin
import Foundation

/// 외장 이전(사양 5장): 파일 시스템 확인 → ExFAT·FAT이면 APFS sparsebundle 안에 담음 → 복사 → 파일 수·크기 대조 →
/// 일치할 때만 원본 삭제 → 원래 자리에 링크 → 이전 기록(MANIFEST)·되돌리기.
public final class ExternalMigrator: @unchecked Sendable {
    public struct Record: Codable, Sendable, Identifiable, Equatable {
        public var id: String
        public var source: String
        public var destination: String
        public var imagePath: String?
        public var files: Int
        public var bytes: UInt64
        public var time: Date
        public var undone: Bool
    }

    public enum LinkStatus: Equatable, Sendable { case ok, broken(imagePath: String?), notALink, undone }

    public enum Failure: Error, CustomStringConvertible {
        case unsupportedVolume(String), destinationExists(String), copyFailed(String), mismatch(source: (Int, UInt64), copy: (Int, UInt64)), attachFailed(String), invalid(String)
        public var description: String {
            switch self {
            case .unsupportedVolume(let v): "이전할 수 없는 볼륨입니다: \(v)"
            case .destinationExists(let d): "대상에 이미 같은 경로가 있습니다: \(d)"
            case .copyFailed(let m): "복사 실패: \(m)"
            case .mismatch(let s, let c): "파일 수·크기 불일치 — 원본 \(s.0)개 \(s.1)바이트 / 사본 \(c.0)개 \(c.1)바이트. 원본은 그대로 둡니다."
            case .attachFailed(let m): "이미지를 연결하지 못했습니다: \(m)"
            case .invalid(let m): m
            }
        }
    }

    public static let imageName = "ReMON-Archive.sparsebundle"
    public let manifestURL: URL
    public var audit = AuditLog.shared
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    public init(manifestURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReMON/migrations.json")) {
        self.manifestURL = manifestURL
    }

    public func records() -> [Record] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Record].self, from: data)) ?? []
    }

    private func save(_ records: [Record]) throws {
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: manifestURL, options: .atomic)
    }

    public static func filesystemType(_ path: String) -> String {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return "" }
        return withUnsafeBytes(of: info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }

    /// 연결된 외장 볼륨(내장 시스템 볼륨 제외)과 그 위의 sparsebundle(기존 StoreArc-archive 포함).
    public static func externalVolumes() -> [(path: String, fsType: String, images: [String])] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return names.compactMap { name in
            let path = "/Volumes/" + name
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
            let type = filesystemType(path)
            if path == "/Volumes/Macintosh HD" || type.isEmpty { return nil }
            let images = ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { $0.hasSuffix(".sparsebundle") || $0.hasSuffix(".sparseimage") }.map { path + "/" + $0 }
            return (path, type, images)
        }
    }

    // MARK: - 이전

    public func migrate(source rawSource: String, toVolume volume: String, userPIDs: [Int32], dryRun: Bool) throws -> Record {
        let sourceURL = try SafeFileOps.validate(rawSource)
        let source = sourceURL.path
        let users = SafeFileOps.openFileUsers(under: source, pids: userPIDs)
        guard users.isEmpty else { throw SafeFileOps.Failure.inUse(source, users) }
        let fsType = Self.filesystemType(volume)
        guard !fsType.isEmpty, volume.hasPrefix("/Volumes/") else { throw Failure.unsupportedVolume(volume) }
        let needsImage = ["exfat", "msdos", "vfat"].contains(fsType.lowercased())
        let tally = Self.tally(source)
        let relative = source.hasPrefix(home + "/") ? String(source.dropFirst(home.count + 1)) : String(source.dropFirst())
        if dryRun {
            let plannedRoot = needsImage ? "<\(volume)/\(Self.imageName)>" : volume + "/ReMON-Archive"
            audit.write(action: "file.migrate", target: source, bytes: tally.bytes, result: "dry-run", dryRun: true, detail: ["destination": plannedRoot + "/" + relative, "files": tally.files])
            return Record(id: UUID().uuidString, source: source, destination: plannedRoot + "/" + relative, imagePath: needsImage ? volume + "/" + Self.imageName : nil, files: tally.files, bytes: tally.bytes, time: Date(), undone: false)
        }
        var imagePath: String?
        let root: String
        if needsImage {
            let image = volume + "/" + Self.imageName
            if !FileManager.default.fileExists(atPath: image) {
                guard Shell.run("/usr/bin/hdiutil", ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-size", "1t", "-volname", "ReMON Archive", image], timeout: 120) != nil,
                      FileManager.default.fileExists(atPath: image) else { throw Failure.attachFailed("sparsebundle 생성 실패") }
            }
            root = try attach(image)
            imagePath = image
        } else {
            root = volume + "/ReMON-Archive"
        }
        let destination = root + "/" + relative
        if FileManager.default.fileExists(atPath: destination) { throw Failure.destinationExists(destination) }
        try FileManager.default.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let copyOK = Shell.runStatus("/usr/bin/ditto", [source, destination], timeout: 6 * 3600)
        guard copyOK == 0 else { throw Failure.copyFailed("ditto 종료 코드 \(copyOK)") }
        let copy = Self.tally(destination)
        guard copy.files == tally.files, copy.bytes == tally.bytes else {
            audit.write(action: "file.migrate", target: source, bytes: tally.bytes, result: "mismatch", dryRun: false, detail: ["copy_files": copy.files, "copy_bytes": copy.bytes])
            throw Failure.mismatch(source: (tally.files, tally.bytes), copy: (copy.files, copy.bytes))
        }
        try FileManager.default.removeItem(atPath: source)
        try FileManager.default.createSymbolicLink(atPath: source, withDestinationPath: destination)
        let record = Record(id: UUID().uuidString, source: source, destination: destination, imagePath: imagePath, files: tally.files, bytes: tally.bytes, time: Date(), undone: false)
        try save(records() + [record])
        audit.write(action: "file.migrate", target: source, bytes: tally.bytes, result: "ok", dryRun: false, detail: ["destination": destination, "files": tally.files, "image": imagePath ?? ""])
        return record
    }

    public func undo(_ record: Record, dryRun: Bool) throws {
        guard !record.undone else { throw Failure.invalid("이미 되돌렸습니다") }
        var info = stat()
        guard lstat(record.source, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { throw Failure.invalid("원래 자리에 이전 링크가 없습니다: \(record.source)") }
        if let image = record.imagePath, !FileManager.default.fileExists(atPath: record.destination) { _ = try attach(image) }
        guard FileManager.default.fileExists(atPath: record.destination) else { throw Failure.invalid("이전된 사본을 찾을 수 없습니다: \(record.destination)") }
        let expected = Self.tally(record.destination)
        if dryRun {
            audit.write(action: "file.migrate.undo", target: record.source, bytes: expected.bytes, result: "dry-run", dryRun: true)
            return
        }
        try FileManager.default.removeItem(atPath: record.source)
        let status = Shell.runStatus("/usr/bin/ditto", [record.destination, record.source], timeout: 6 * 3600)
        let restored = Self.tally(record.source)
        guard status == 0, restored.files == expected.files, restored.bytes == expected.bytes else {
            // 되돌리기 실패 시 링크를 복구해 데이터 접근을 유지한다.
            try? FileManager.default.removeItem(atPath: record.source)
            try? FileManager.default.createSymbolicLink(atPath: record.source, withDestinationPath: record.destination)
            audit.write(action: "file.migrate.undo", target: record.source, bytes: expected.bytes, result: "mismatch", dryRun: false)
            throw Failure.mismatch(source: (expected.files, expected.bytes), copy: (restored.files, restored.bytes))
        }
        try FileManager.default.removeItem(atPath: record.destination)
        var all = records()
        if let index = all.firstIndex(where: { $0.id == record.id }) { all[index].undone = true }
        try save(all)
        audit.write(action: "file.migrate.undo", target: record.source, bytes: expected.bytes, result: "ok", dryRun: false)
    }

    public func status(_ record: Record) -> LinkStatus {
        if record.undone { return .undone }
        var info = stat()
        guard lstat(record.source, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { return .notALink }
        return FileManager.default.fileExists(atPath: record.destination) ? .ok : .broken(imagePath: record.imagePath)
    }

    /// 이미 붙어 있으면 그 마운트 지점을, 아니면 hdiutil attach 결과의 마운트 지점을 돌려준다.
    public func attach(_ image: String) throws -> String {
        if let info = Shell.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 20), let mount = Self.mountPoint(forImage: image, inInfoPlist: info) { return mount }
        guard let output = Shell.run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-plist", image], timeout: 120),
              let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first else { throw Failure.attachFailed(image) }
        return mount
    }

    static func mountPoint(forImage image: String, inInfoPlist text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let target = URL(fileURLWithPath: image).standardizedFileURL.path
        for entry in images where (entry["image-path"] as? String).map({ URL(fileURLWithPath: $0).standardizedFileURL.path }) == target {
            let entities = entry["system-entities"] as? [[String: Any]] ?? []
            if let mount = entities.compactMap({ $0["mount-point"] as? String }).first { return mount }
        }
        return nil
    }

    /// 일반 파일 수와 논리 크기 합(링크는 링크 자체로 센다).
    public static func tally(_ path: String) -> (files: Int, bytes: UInt64) {
        var files = 0
        var bytes: UInt64 = 0
        var info = stat()
        guard lstat(path, &info) == 0 else { return (0, 0) }
        if (info.st_mode & S_IFMT) == S_IFREG { return (1, UInt64(info.st_size)) }
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return (0, 0) }
        while let relative = enumerator.nextObject() as? String {
            guard lstat(path + "/" + relative, &info) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFREG || type == S_IFLNK {
                files += 1
                bytes += UInt64(info.st_size)
            }
        }
        return (files, bytes)
    }
}

extension Shell {
    /// 종료 코드만 필요한 명령(복사 등). 출력은 버린다.
    public static func runStatus(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning { process.terminate(); return -2 }
        return process.terminationStatus
    }
}
