import Darwin
import Foundation

// 큰 파일·폴더 찾기 — 홈 폴더를 getattrlistbulk(ATTR_FILE_ALLOCSIZE)로 한 번 훑어 실제 할당량이 큰 것을 고른다.
// ~/Library · 휴지통 · 클라우드 저장소 · 다른 볼륨은 들어가지 않는다. 동작은 Finder에서 보기와 휴지통(금고 기록)뿐이고,
// 홈 최상위 폴더와 앱이 관리하는 데이터(가상 머신·AI 기록·모델)는 옮기지 않는다. 언제든 취소할 수 있고 메인 스레드 밖에서 돈다.
// APFS 복제본(clone)은 블록을 함께 쓰므로 합계가 실제 사용량보다 클 수 있다(하드링크는 한 번만 센다).

public final class LargeFileFinder: @unchecked Sendable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String { path }
        public var path: String
        public var bytes: UInt64
        public var isDirectory: Bool
        public var modified: Date?
        /// 옮기지 않는 이유(홈 최상위 · 앱이 관리하는 데이터 …). nil이면 휴지통으로 옮길 수 있다.
        public var refusal: String?

        public init(path: String, bytes: UInt64, isDirectory: Bool, modified: Date?, refusal: String?) {
            self.path = path
            self.bytes = bytes
            self.isDirectory = isDirectory
            self.modified = modified
            self.refusal = refusal
        }
    }

    public struct Report: Sendable, Equatable {
        public var files: [Entry] = []
        public var folders: [Entry] = []
        public var scannedFiles = 0
        public var scannedFolders = 0
        /// 하드링크를 한 번만 센 실제 할당량 합계(APFS 복제본은 겹쳐 셀 수 있음)
        public var scannedBytes: UInt64 = 0
        public var elapsed: TimeInterval = 0
        public var cancelled = false
        /// 들어가지 않은 최상위 이름(제외 규칙)
        public var skipped: [String] = []
        /// 읽지 못한 폴더 수(권한 등)
        public var unreadable = 0

        public init() {}
    }

    public let home: String
    /// 상위 몇 개를 돌려줄지
    public var limit = 30
    /// 이보다 작은 파일·폴더는 후보에 넣지 않는다(정렬 비용 절약). 시험에서는 낮춘다.
    public var minimumFileBytes: UInt64 = 50 * 1_048_576
    public var minimumFolderBytes: UInt64 = 200 * 1_048_576
    /// 이 비율 이상을 한 하위 폴더가 차지하면 그 폴더 대신 하위 폴더를 보여 준다(같은 덩어리를 여러 줄로 보이지 않게).
    public var dominance = 0.9
    /// 진행 알림 간격(폴더 수). 시험에서는 1.
    public var progressEvery = 400
    private let lock = NSLock()
    private var _cancelled = false

    public init(home: String = NSHomeDirectory()) {
        self.home = Self.normalized(home)
    }

    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    /// 홈에서 들어가지 않는 최상위 이름: Library(앱 데이터·클라우드 저장소), 휴지통, 옛 클라우드 폴더.
    public static let skippedTopLevel: Set<String> = ["Library", ".Trash"]
    public static let cloudPrefixes = ["Dropbox", "Google Drive", "OneDrive", "Box", "iCloud Drive", "Creative Cloud Files", "pCloud Drive", "MEGA"]
    /// 앱이 관리하는 데이터(휴지통 대신 그 앱에서 정리): AI 도구 기록·기억 · 가상 머신·에뮬레이터 · 로컬 모델 · 컨테이너.
    public static let managedPrefixes = [".codex", ".claude", ".aside", ".cursor", ".gemini", ".continue", ".windsurf", ".codeium", ".local/share/opencode",
                                         ".ollama", ".lmstudio", ".cache/huggingface", ".cache/lm-studio",
                                         ".colima", ".lima", ".tart", ".orbstack", ".docker", "Parallels", "VirtualBox VMs", ".android/avd"]
    /// 앱 보관함 패키지(사진·음악·영상 편집): 통째로 한 덩어리로 보이고, 안으로도 통째로도 옮기지 않는다(그 앱에서 정리).
    public static let libraryExtensions: Set<String> = ["photoslibrary", "photolibrary", "aplibrary", "migratedphotolibrary", "musiclibrary", "tvlibrary", "imovielibrary",
                                                        "fcpbundle", "logicx", "band", "lrlibrary", "lrdata", "cocatalog"]
    /// 그 밖의 패키지(.app 등): 크기는 세지만 안쪽 항목은 후보로 올리지 않는다(앱 안 파일을 하나씩 지우면 앱이 깨진다).
    public static let packageExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "appex", "xcarchive", "pkg", "mpkg", "sparsebundle", "photosmigrator"]

    static func pathExtension(_ name: Substring) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// 옮기지 않는 이유. 홈 밖 · 홈 자체 · 홈 최상위 폴더 · ~/Library · 앱이 관리하는 데이터는 거부한다.
    public static func refusalReason(_ rawPath: String, home rawHome: String, isDirectory: Bool? = nil) -> String? {
        let home = normalized(rawHome)
        let path = normalized(rawPath)
        guard path.hasPrefix(home + "/") else { return path == home ? "홈 폴더 자체는 옮기지 않습니다" : "홈 폴더 밖은 다루지 않습니다" }
        let relative = String(path.dropFirst(home.count + 1))
        let components = relative.split(separator: "/").map(String.init)
        guard let first = components.first else { return "홈 폴더 자체는 옮기지 않습니다" }
        let directory: Bool = isDirectory ?? {
            var info = stat()
            return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }()
        if components.count == 1 && directory { return "홈 최상위 폴더는 옮기지 않습니다" }
        if skippedTopLevel.contains(first) { return first == "Library" ? "~/Library는 다루지 않습니다" : "휴지통 안의 항목입니다" }
        if cloudPrefixes.contains(where: { first.hasPrefix($0) }) { return "클라우드 저장소는 그 앱에서 정리합니다" }
        if managedPrefixes.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { return "앱이 관리하는 데이터입니다 — 그 앱에서 정리합니다" }
        if components.contains(".git") { return "git 저장소 내부입니다 — git gc로 줄입니다(파일을 옮기면 저장소가 깨집니다)" }
        let extensions = relative.split(separator: "/").map(pathExtension)
        if extensions.contains(where: libraryExtensions.contains) { return "사진·음악 같은 앱 보관함입니다 — 그 앱에서 정리합니다" }
        if extensions.dropLast().contains(where: packageExtensions.contains) { return "앱·패키지 안의 항목입니다 — 패키지째로만 다룹니다" }
        return nil
    }

    /// '.'·'..'·겹친 '/'만 글자 그대로 정리한다(standardizingPath·standardizedFileURL은 /private/tmp를 /tmp로 바꿔 금고·커널 경로와 어긋난다).
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// 홈을 훑는다. progress(파일 수, 바이트)는 폴더 몇백 개마다 이 스레드에서 불린다.
    public func scan(progress: ((Int, UInt64) -> Void)? = nil) -> Report {
        DiskScanner.withoutMaterializing { scanHome(progress: progress) }
    }

    private func scanHome(progress: ((Int, UInt64) -> Void)?) -> Report {
        lock.lock(); _cancelled = false; lock.unlock()
        let started = Date()
        var report = Report()
        var rootInfo = stat()
        guard stat(home, &rootInfo) == 0 else { return report }
        var walker = Walker(owner: self, device: rootInfo.st_dev, progress: progress)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: home)) ?? []).sorted()
        for name in names {
            if isCancelled { break }
            if Self.skippedTopLevel.contains(name) || Self.cloudPrefixes.contains(where: { name.hasPrefix($0) }) { report.skipped.append(name); continue }
            let path = home + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard info.st_dev == rootInfo.st_dev else { report.skipped.append(name); continue }
                _ = walker.walk(path, depth: 1, inPackage: false)
            case S_IFREG:
                walker.addFile(bytes: UInt64(info.st_blocks) * 512, links: UInt32(info.st_nlink), fileID: UInt64(info.st_ino), modified: TimeInterval(info.st_mtimespec.tv_sec)) { path }
            default:
                continue
            }
        }
        walker.finish()
        report.files = walker.files.map { entry in var entry = entry; entry.refusal = Self.refusalReason(entry.path, home: home, isDirectory: false); return entry }
        report.folders = walker.folders.map { entry in var entry = entry; entry.refusal = Self.refusalReason(entry.path, home: home, isDirectory: true); return entry }
        report.scannedFiles = walker.fileCount
        report.scannedFolders = walker.folderCount
        report.scannedBytes = walker.totalBytes
        report.unreadable = walker.unreadable
        report.cancelled = isCancelled
        report.elapsed = Date().timeIntervalSince(started)
        return report
    }

    /// 휴지통으로(금고 기록). 거부 대상이면 옮기지 않고 이유를 던진다.
    @discardableResult
    public static func trash(_ entry: Entry, home: String = NSHomeDirectory(), userPIDs: [Int32], dryRun: Bool, audit: AuditLog = .shared, vault: RecoveryVault?) throws -> URL? {
        if let reason = refusalReason(entry.path, home: home) {
            audit.write(action: "file.trash", target: entry.path, bytes: entry.bytes, result: "refused: " + reason, dryRun: dryRun)
            throw SafeFileOps.Failure.forbidden(entry.path + " · " + reason)
        }
        return try SafeFileOps.moveToTrash(entry.path, userPIDs: userPIDs, dryRun: dryRun, bytes: entry.bytes, audit: audit, vault: dryRun ? nil : vault,
                                           project: "큰 파일", reason: "큰 파일 정리")
    }

    // MARK: - 순회

    /// 상위 K개만 들고 다니는 목록(크기 내림차순).
    struct TopList {
        let capacity: Int
        var items: [Entry] = []
        func accepts(_ bytes: UInt64) -> Bool { items.count < capacity || (items.last?.bytes ?? 0) < bytes }
        mutating func offer(_ entry: Entry) {
            guard accepts(entry.bytes) else { return }
            let index = items.firstIndex { $0.bytes < entry.bytes } ?? items.count
            items.insert(entry, at: index)
            if items.count > capacity { items.removeLast() }
        }
    }

    struct Walker {
        unowned let owner: LargeFileFinder
        let device: dev_t
        let progress: ((Int, UInt64) -> Void)?
        var fileTop: TopList
        var folderTop: TopList
        var fileCount = 0
        var folderCount = 0
        var totalBytes: UInt64 = 0
        var unreadable = 0
        var seenLinks = Set<UInt64>()
        let buffer: UnsafeMutableRawPointer
        let bufferSize = 256 * 1024
        var files: [Entry] { fileTop.items }
        var folders: [Entry] { folderTop.items }

        init(owner: LargeFileFinder, device: dev_t, progress: ((Int, UInt64) -> Void)?) {
            self.owner = owner
            self.device = device
            self.progress = progress
            fileTop = TopList(capacity: owner.limit)
            folderTop = TopList(capacity: owner.limit)
            buffer = UnsafeMutableRawPointer.allocate(byteCount: 256 * 1024, alignment: 16)
        }

        func finish() { buffer.deallocate() }

        /// 파일 하나를 센다. 경로 문자열은 후보가 될 만큼 클 때만 만든다(수백만 개 파일에서 할당을 줄인다). 돌려주는 값 = 새로 센 바이트.
        @discardableResult
        mutating func addFile(bytes: UInt64, links: UInt32, fileID: UInt64, modified: TimeInterval, offer: Bool = true, path: () -> String) -> UInt64 {
            fileCount += 1
            if links > 1 { guard seenLinks.insert(fileID).inserted else { return 0 } }
            totalBytes += bytes
            if offer, bytes >= owner.minimumFileBytes, fileTop.accepts(bytes) {
                fileTop.offer(Entry(path: path(), bytes: bytes, isDirectory: false, modified: Date(timeIntervalSince1970: modified), refusal: nil))
            }
            return bytes
        }

        /// 폴더 하나를 읽고(항목을 모두 모은 뒤 닫고) 하위 폴더로 내려간다. 돌려주는 값 = 이 폴더의 합계.
        /// inPackage: 패키지(.app·사진 보관함 등) 안 — 크기만 세고 후보로 올리지 않는다.
        mutating func walk(_ path: String, depth: Int, inPackage: Bool) -> UInt64 {
            if owner.isCancelled { return 0 }
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { unreadable += 1; return 0 }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_dev == device else { close(fd); return 0 }
            folderCount += 1
            var subfolders: [String] = []
            var own: UInt64 = 0
            var newest: TimeInterval = 0
            let ok = Self.read(fd: fd, buffer: buffer, size: bufferSize) { name, type, alloc, links, fileID, modified in
                newest = max(newest, modified)
                switch type {
                case 2:                                               // VDIR
                    let text = String(cString: name)
                    if text != "." && text != ".." { subfolders.append(text) }
                case 1:                                               // VREG
                    own += addFile(bytes: alloc, links: links, fileID: fileID, modified: modified, offer: !inPackage) { path + "/" + String(cString: name) }
                default: break                                        // 링크·소켓 등은 따라가지 않는다
                }
            }
            close(fd)
            if !ok { unreadable += 1 }
            if folderCount % max(1, owner.progressEvery) == 0 { progress?(fileCount, totalBytes) }
            var total = own
            var largestChild: UInt64 = 0
            for name in subfolders {
                if owner.isCancelled { break }
                let ext = LargeFileFinder.pathExtension(Substring(name))
                let package = !inPackage && (LargeFileFinder.packageExtensions.contains(ext) || LargeFileFinder.libraryExtensions.contains(ext))
                let child = path + "/" + name
                let size = walk(child, depth: depth + 1, inPackage: inPackage || package)
                total += size
                largestChild = max(largestChild, size)
                // 패키지는 한 덩어리로 폴더 후보에 오른다(안쪽 폴더는 후보가 되지 않는다).
                if package, size >= owner.minimumFolderBytes { folderTop.offer(Entry(path: child, bytes: size, isDirectory: true, modified: nil, refusal: nil)) }
            }
            // 홈 최상위 폴더는 후보에서 뺀다(옮길 수 없고 너무 뻔하다). 한 하위 폴더가 거의 전부면 그 하위 폴더가 대신 보인다.
            if !inPackage, depth >= 2, total >= owner.minimumFolderBytes, Double(largestChild) < owner.dominance * Double(total) {
                folderTop.offer(Entry(path: path, bytes: total, isDirectory: true, modified: newest > 0 ? Date(timeIntervalSince1970: newest) : nil, refusal: nil))
            }
            return total
        }

        /// getattrlistbulk 한 폴더 분량. 속성 순서: 길이 · 돌려준 속성 · 오류 · 이름 · 종류 · 수정 시각 · 파일 id | 링크 수 · 할당량.
        static func read(fd: Int32, buffer: UnsafeMutableRawPointer, size: Int,
                         _ body: (_ name: UnsafePointer<CChar>, _ type: UInt32, _ alloc: UInt64, _ links: UInt32, _ fileID: UInt64, _ modified: TimeInterval) -> Void) -> Bool {
            var list = attrlist()
            list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE)
                | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FILEID)
            list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
            while true {
                let count = getattrlistbulk(fd, &list, buffer, size, 0)
                if count < 0 { return false }
                if count == 0 { return true }
                var cursor = UnsafeRawPointer(buffer)
                for _ in 0..<count {
                    let start = cursor
                    let length = Int(start.loadUnaligned(as: UInt32.self))
                    var field = start + MemoryLayout<UInt32>.size
                    let returned = field.loadUnaligned(as: attribute_set_t.self)
                    field += MemoryLayout<attribute_set_t>.size
                    var error: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 { error = field.loadUnaligned(as: UInt32.self); field += MemoryLayout<UInt32>.size }
                    var name: UnsafePointer<CChar>?
                    if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                        let reference = field.loadUnaligned(as: attrreference_t.self)
                        if reference.attr_length > 1 { name = (field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self) }
                        field += MemoryLayout<attrreference_t>.size
                    }
                    var type: UInt32 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 { type = field.loadUnaligned(as: UInt32.self); field += MemoryLayout<UInt32>.size }
                    var modified: TimeInterval = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                        let time = field.loadUnaligned(as: timespec.self)
                        modified = TimeInterval(time.tv_sec)
                        field += MemoryLayout<timespec>.size
                    }
                    var fileID: UInt64 = 0
                    if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 { fileID = field.loadUnaligned(as: UInt64.self); field += MemoryLayout<UInt64>.size }
                    var links: UInt32 = 1
                    if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 { links = field.loadUnaligned(as: UInt32.self); field += MemoryLayout<UInt32>.size }
                    var alloc: UInt64 = 0
                    if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 { alloc = UInt64(max(0, field.loadUnaligned(as: Int64.self))); field += MemoryLayout<Int64>.size }
                    cursor = start + length
                    if error == 0, let name { body(name, type, alloc, links, fileID, modified) }
                }
            }
        }
    }
}
