import Darwin
import Foundation

// 디스크 지도의 크기 조사기 — 폴더 목록(대상)을 받아 각 대상 아래 전부의 실제 할당량(ATTR_FILE_ALLOCSIZE = st_blocks×512)·파일 수·
// 가장 최근 수정 시각을 getattrlistbulk로 센다. 일꾼 여러 개가 각자 깊이 우선으로 돌고, 노는 일꾼이 생기면 얕은 폴더를 나눠 준다.
// 링크는 따라가지 않고(O_NOFOLLOW · 목록의 링크는 크기만), 다른 볼륨(장치 번호가 다른 폴더)은 들어가지 않는다.
// 시간 제한·취소에 걸리면 남은 폴더의 대상은 timedOut(하한값)으로 남는다. iCloud 등 내용 없는(dataless) 항목은 내려받지 않는다.
// 하드링크는 대상(맨 위 칸)마다 한 번만 센다 — 같은 파일이 형제 폴더에 걸쳐 있으면 형제마다 한 번씩 센다(형제별 du -sk와 같음).

final class DiskTreeWalker: @unchecked Sendable {
    /// 조사할 폴더. split: 바로 아래 폴더마다 칸을 따로 둔다(캐시 — 다음 펼치기를 조사 없이 보여 준다).
    struct Target: Sendable {
        var path: String
        var split: Bool
        /// 이 폴더가 있어야 할 볼륨. 다르면(마운트 지점) 세지 않는다.
        var device: dev_t
    }

    /// 한 칸(대상 · 쪼갠 하위 폴더 · 번들)의 결과. 합계는 아래 칸까지 더한 값이다.
    struct Tally: Sendable {
        var path: String
        /// 위 칸(-1 = 대상)
        var parent: Int
        var isBundle: Bool
        var bytes: UInt64 = 0
        var files = 0
        /// 아래 전부에서 가장 최근 수정 시각(초)
        var newest = 0
        /// 이 폴더 자체의 수정 시각(초) — 캐시 키
        var dirMtime = 0
        /// 시간 제한·취소로 끝까지 못 셈
        var timedOut = false
        /// 권한 등으로 못 읽은 폴더 수
        var unreadable = 0
        /// 다른 앱 데이터(컨테이너)라 들어가지 않음
        var otherAppData = false
        /// 다른 볼륨이라 세지 않음(대상 자체가 마운트 지점)
        var otherVolume = false
        /// 대상이 없어짐
        var missing = false

        var partial: Bool { timedOut || unreadable > 0 || otherAppData }
    }

    struct LargeFile: Sendable, Equatable {
        var path: String
        var bytes: UInt64
        var modified: Int
        var isBundle: Bool
    }

    struct Result: Sendable {
        var tallies: [Tally]
        var large: [LargeFile]
        var directories: Int
        var files: Int
        var elapsed: TimeInterval
        var timedOut: Bool
    }

    /// 목록 한 줄(getattrlistbulk). type: 1 = 파일 · 2 = 폴더 · 5 = 링크.
    struct Entry: Sendable {
        var name: String
        var type: UInt32
        var alloc: UInt64
        var links: UInt32
        var fileID: UInt64
        var modified: Int
    }

    struct Listing: Sendable {
        var entries: [Entry]
        var device: dev_t
        var mtime: Int
        /// 끝까지 읽었는가(권한·입출력 오류면 false)
        var complete: Bool
    }

    var parallelism = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
    /// 안으로 들어가지 않는 폴더(다른 앱의 컨테이너 묶음 — 열면 macOS가 확인 창을 띄울 수 있다).
    var opaque: Set<String> = []
    /// 번들(.app 등)을 칸으로 따로 센다(큰 파일 찾기에서 번들을 한 덩어리로 올린다).
    var collectBundles = false
    var bundleExtensions: Set<String> = []
    /// 이 크기 이상 파일을 모은다(nil이면 모으지 않음).
    var largeThreshold: UInt64?
    var largeLimit = 50
    var isCancelled: @Sendable () -> Bool = { false }

    static let bufferSize = 256 * 1024

    // MARK: 한 폴더 목록

    /// 폴더 하나를 읽는다(링크는 따라가지 않는다). 없거나 폴더가 아니면 nil, 권한이 없으면 complete=false인 빈 목록.
    static func list(_ path: String) -> Listing? {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR || code == ELOOP { return nil }
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return Listing(entries: [], device: info.st_dev, mtime: Int(info.st_mtimespec.tv_sec), complete: false)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }
        var entries: [Entry] = []
        let ok = LargeFileFinder.Walker.read(fd: fd, buffer: buffer, size: bufferSize) { name, type, alloc, links, fileID, modified in
            entries.append(Entry(name: String(cString: name), type: type, alloc: alloc, links: links, fileID: fileID, modified: Int(modified)))
        }
        return Listing(entries: entries, device: info.st_dev, mtime: Int(info.st_mtimespec.tv_sec), complete: ok)
    }

    // MARK: 조사

    func run(_ targets: [Target], deadline: DispatchTime) -> Result {
        let started = Date()
        let state = WalkState(targets: targets)
        let pool = Pool(targets.enumerated().map { index, target in
            Job(path: target.path, acc: index, top: index, split: target.split, inBundle: false, device: target.device, accRoot: true)
        }, workers: parallelism)
        let workers = max(1, parallelism)
        let results = WorkerResults(count: workers)
        DispatchQueue.concurrentPerform(iterations: workers) { index in
            DiskScanner.withoutMaterializing {
                var worker = Worker(owner: self, state: state, pool: pool, deadline: deadline)
                worker.loop()
                results.set(index, worker.finish())
            }
        }
        // 일꾼별 차분을 합친 뒤, 아래 칸부터 위 칸으로 더한다(아래 칸은 늘 위 칸보다 뒤에 만들어진다).
        var tallies = state.snapshot()
        var large: [LargeFile] = []
        var directories = 0, files = 0
        var anyTimedOut = false
        for output in results.all {
            directories += output.directories
            files += output.files
            large += output.large
            for (index, delta) in output.deltas {
                tallies[index].bytes += delta.bytes
                tallies[index].files += delta.files
                tallies[index].newest = max(tallies[index].newest, delta.newest)
                if delta.dirMtime != 0 { tallies[index].dirMtime = delta.dirMtime }
                if delta.timedOut { tallies[index].timedOut = true; anyTimedOut = true }
                tallies[index].unreadable += delta.unreadable
                if delta.otherAppData { tallies[index].otherAppData = true }
                if delta.otherVolume { tallies[index].otherVolume = true }
                if delta.missing { tallies[index].missing = true }
            }
        }
        for index in tallies.indices.reversed() {
            let parent = tallies[index].parent
            guard parent >= 0 else { continue }
            let child = tallies[index]
            tallies[parent].bytes += child.bytes
            tallies[parent].files += child.files
            tallies[parent].newest = max(tallies[parent].newest, child.newest)
            if child.timedOut { tallies[parent].timedOut = true }
            tallies[parent].unreadable += child.unreadable
            if child.otherAppData { tallies[parent].otherAppData = true }
        }
        if let threshold = largeThreshold {
            for tally in tallies where tally.isBundle && tally.bytes >= threshold {
                large.append(LargeFile(path: tally.path, bytes: tally.bytes, modified: tally.newest, isBundle: true))
            }
            large.sort { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.path < $1.path }
            if large.count > largeLimit { large.removeLast(large.count - largeLimit) }
        }
        return Result(tallies: tallies, large: large, directories: directories, files: files, elapsed: Date().timeIntervalSince(started), timedOut: anyTimedOut)
    }

    static func pathExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    // MARK: - 내부

    struct Job {
        var path: String
        var acc: Int
        var top: Int
        var split: Bool
        var inBundle: Bool
        var device: dev_t
        /// 이 폴더가 칸의 맨 위(수정 시각을 캐시 키로 적는다)
        var accRoot: Bool
    }

    struct Delta {
        var bytes: UInt64 = 0
        var files = 0
        var newest = 0
        var dirMtime = 0
        var timedOut = false
        var unreadable = 0
        var otherAppData = false
        var otherVolume = false
        var missing = false
    }

    struct WorkerOutput {
        var deltas: [Int: Delta] = [:]
        var large: [LargeFile] = []
        var directories = 0
        var files = 0
    }

    /// 칸 목록(조사 중에 쪼갠 하위 폴더·번들 칸이 늘어난다)과 하드링크 기록.
    final class WalkState: @unchecked Sendable {
        private let lock = NSLock()
        private var tallies: [Tally]
        private var seenLinks = Set<LinkKey>()

        struct LinkKey: Hashable { var top: Int; var id: UInt64 }

        init(targets: [Target]) {
            tallies = targets.map { Tally(path: $0.path, parent: -1, isBundle: false) }
        }

        func register(path: String, parent: Int, isBundle: Bool) -> Int {
            lock.lock(); defer { lock.unlock() }
            tallies.append(Tally(path: path, parent: parent, isBundle: isBundle))
            return tallies.count - 1
        }

        /// 대상(맨 위 칸) 안에서 이 하드링크를 처음 보는가.
        func firstSighting(top: Int, id: UInt64) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return seenLinks.insert(LinkKey(top: top, id: id)).inserted
        }

        func snapshot() -> [Tally] {
            lock.lock(); defer { lock.unlock() }
            return tallies
        }
    }

    final class WorkerResults: @unchecked Sendable {
        private let lock = NSLock()
        private var outputs: [WorkerOutput]
        init(count: Int) { outputs = Array(repeating: WorkerOutput(), count: count) }
        func set(_ index: Int, _ output: WorkerOutput) { lock.lock(); outputs[index] = output; lock.unlock() }
        var all: [WorkerOutput] { lock.lock(); defer { lock.unlock() }; return outputs }
    }

    /// 나눠 쓰는 일감 더미. 일이 없으면 기다리고, 모두 기다리게 되면(남은 일 없음) 끝난다.
    final class Pool: @unchecked Sendable {
        private let condition = NSCondition()
        private var shared: [Job]
        private var waiting = 0
        private var stopped = false
        private let workers: Int

        init(_ jobs: [Job], workers: Int) {
            // 처음 대상은 앞에서부터 꺼내도록 뒤집어 둔다(스택).
            shared = jobs.reversed()
            self.workers = max(1, workers)
        }

        func take() -> Job? {
            condition.lock(); defer { condition.unlock() }
            while !stopped {
                if let job = shared.popLast() { return job }
                waiting += 1
                if waiting >= workers { stopped = true; condition.broadcast(); return nil }
                condition.wait()
                waiting -= 1
            }
            return nil
        }

        /// 노는 일꾼이 있고 나눌 일이 없으면 내 일의 얕은 쪽 절반을 내놓는다.
        func share(_ local: inout [Job]) {
            condition.lock(); defer { condition.unlock() }
            guard !stopped, waiting > 0, shared.isEmpty, local.count > 1 else { return }
            let half = local.count / 2
            shared.append(contentsOf: local[0..<half].reversed())
            local.removeFirst(half)
            condition.broadcast()
        }

        /// 시간 제한: 남은 일을 돌려주고 모두 멈춘다.
        func stop() -> [Job] {
            condition.lock(); defer { condition.unlock() }
            stopped = true
            let rest = shared
            shared = []
            condition.broadcast()
            return rest
        }
    }

    struct Worker {
        let owner: DiskTreeWalker
        let state: WalkState
        let pool: Pool
        let deadline: DispatchTime
        var output = WorkerOutput()
        var local: [Job] = []
        var top: [LargeFile] = []
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: DiskTreeWalker.bufferSize, alignment: 16)

        init(owner: DiskTreeWalker, state: WalkState, pool: Pool, deadline: DispatchTime) {
            self.owner = owner
            self.state = state
            self.pool = pool
            self.deadline = deadline
        }

        mutating func finish() -> WorkerOutput {
            buffer.deallocate()
            output.large = top
            return output
        }

        mutating func loop() {
            var processed = 0
            while true {
                if local.isEmpty {
                    guard let job = pool.take() else { break }
                    local.append(job)
                }
                // 시간은 폴더마다, 취소(조사기 잠금)는 32개마다 본다 — 수십만 폴더에서 잠금 경합을 줄인다.
                if DispatchTime.now() >= deadline || (processed & 31 == 0 && owner.isCancelled()) {
                    for job in local { output.deltas[job.acc, default: Delta()].timedOut = true }
                    local.removeAll()
                    for job in pool.stop() { output.deltas[job.acc, default: Delta()].timedOut = true }
                    break
                }
                let job = local.removeLast()
                process(job)
                processed += 1
                if processed & 15 == 0, local.count > 1 { pool.share(&local) }
            }
        }

        mutating func process(_ job: Job) {
            let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                let code = errno
                if code == ENOENT || code == ENOTDIR || code == ELOOP {
                    if job.accRoot && job.parentless { output.deltas[job.acc, default: Delta()].missing = true }
                } else {
                    output.deltas[job.acc, default: Delta()].unreadable += 1
                }
                return
            }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { output.deltas[job.acc, default: Delta()].unreadable += 1; return }
            // 마운트 지점(다른 볼륨)은 세지 않는다.
            guard info.st_dev == job.device else {
                if job.accRoot { output.deltas[job.acc, default: Delta()].otherVolume = true }
                return
            }
            if job.accRoot { output.deltas[job.acc, default: Delta()].dirMtime = Int(info.st_mtimespec.tv_sec) }
            if owner.opaque.contains(job.path) {
                output.deltas[job.acc, default: Delta()].otherAppData = true
                return
            }
            output.directories += 1
            var own: UInt64 = 0
            var files = 0
            var newest = Int(info.st_mtimespec.tv_sec)
            var subfolders: [Job] = []
            let threshold = owner.largeThreshold
            let device = info.st_dev
            var offers: [LargeFile] = []
            let ok = LargeFileFinder.Walker.read(fd: fd, buffer: buffer, size: DiskTreeWalker.bufferSize) { name, type, alloc, links, fileID, modified in
                if Int(modified) > newest { newest = Int(modified) }
                if type == 2 {
                    let childName = String(cString: name)
                    let childPath = job.path + "/" + childName
                    var acc = job.acc
                    var accRoot = false
                    var bundle = false
                    if job.split {
                        acc = state.register(path: childPath, parent: job.acc, isBundle: false)
                        accRoot = true
                    } else if owner.collectBundles, !job.inBundle, owner.bundleExtensions.contains(DiskTreeWalker.pathExtension(childName)) {
                        acc = state.register(path: childPath, parent: job.acc, isBundle: true)
                        accRoot = true
                        bundle = true
                    }
                    subfolders.append(Job(path: childPath, acc: acc, top: job.top, split: false, inBundle: job.inBundle || bundle, device: device, accRoot: accRoot))
                    return
                }
                var counted = alloc
                if type == 1 {
                    files += 1
                    // 하드링크는 대상 안에서 한 번만.
                    if links > 1, !state.firstSighting(top: job.top, id: fileID) { counted = 0 }
                    if let threshold, counted >= threshold, !job.inBundle {
                        offers.append(LargeFile(path: job.path + "/" + String(cString: name), bytes: counted, modified: Int(modified), isBundle: false))
                    }
                }
                own += counted
            }
            if !ok { output.deltas[job.acc, default: Delta()].unreadable += 1 }
            output.files += files
            var delta = output.deltas[job.acc, default: Delta()]
            delta.bytes += own
            delta.files += files
            if newest > delta.newest { delta.newest = newest }
            output.deltas[job.acc] = delta
            for offer in offers { offerLarge(offer) }
            // 이름 순으로 깊이 우선(스택이라 뒤집어 넣는다).
            local.append(contentsOf: subfolders.reversed())
        }

        mutating func offerLarge(_ file: LargeFile) {
            let limit = owner.largeLimit
            if top.count >= limit, let last = top.last, last.bytes >= file.bytes { return }
            let index = top.firstIndex { $0.bytes < file.bytes } ?? top.count
            top.insert(file, at: index)
            if top.count > limit { top.removeLast() }
        }
    }
}

extension DiskTreeWalker.Job {
    /// 처음 받은 대상인가(쪼갠 하위 칸·번들 칸이 아님). top == acc면 대상이다.
    var parentless: Bool { top == acc }
}
