import Darwin
import Foundation

/// 같은 pid가 재사용돼도 섞이지 않도록 시작 시각(µs)까지 묶은 식별자.
public struct ProcessKey: Hashable, Sendable, Codable, Comparable {
    public var pid: Int32
    public var start: Int64

    public init(pid: Int32, start: Int64) {
        self.pid = pid
        self.start = start
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { (lhs.pid, lhs.start) < (rhs.pid, rhs.start) }
}

public enum MemorySource: String, Sendable, Codable {
    case kernel      // proc_pid_rusage(RUSAGE_INFO_V6).ri_phys_footprint
    case top         // 권한 밖 프로세스: /usr/bin/top(setuid) MEM 열로 보충
    case unavailable
}

public struct ProcRecord: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var ppid: Int32
    public var uid: UInt32
    public var name: String
    public var startTime: Date
    public var key: ProcessKey
    public var path: String?
    public var footprint: UInt64 = 0
    public var memorySource: MemorySource = .unavailable
    public var cpuTimeNs: UInt64 = 0
    public var cpuPercent: Double = 0
    /// 제어 터미널 장치(kinfo_proc e_tdev). 없으면 -1(NODEV) — 터미널 창이 닫혀 남은 프로세스를 가린다.
    public var ttyDevice: Int32 = -1
    public var id: ProcessKey { key }

    public var hasTTY: Bool { ttyDevice != -1 }

    public var displayName: String {
        if let path, !path.isEmpty { return (path as NSString).lastPathComponent }
        return name
    }
}

extension ProcRecord {
    /// 시험용 합성 기록(감지기를 가짜 프로세스 표로 돌릴 때).
    public init(pid: Int32, ppid: Int32, uid: UInt32 = getuid(), name: String, path: String?, startTime: Date = Date(), cpuPercent: Double = 0, footprint: UInt64 = 0, ttyDevice: Int32 = -1) {
        self.init(pid: pid, ppid: ppid, uid: uid, name: name, startTime: startTime,
                  key: ProcessKey(pid: pid, start: Int64(startTime.timeIntervalSince1970 * 1_000_000)), path: path)
        self.cpuPercent = cpuPercent
        self.footprint = footprint
        self.memorySource = .kernel
        self.ttyDevice = ttyDevice
    }
}

public struct ProcArgs: Sendable, Equatable {
    public var executable: String
    public var argv: [String]
    /// 판정에 필요한 환경 변수만 보관한다(비밀값을 들고 있지 않기 위해 나머지는 버린다).
    public var environment: [String: String]

    public init(executable: String, argv: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.argv = argv
        self.environment = environment
    }
}

/// 감지기가 프로세스마다 더 읽는 정보(argv · 작업 폴더 · 열린 파일). 실제로는 ProcessSampler, 시험에서는 합성 표.
public protocol ProcessDetailSource: AnyObject {
    func arguments(for key: ProcessKey) -> ProcArgs?
    func workingDirectory(for key: ProcessKey, now: Date) -> String?
    func openFiles(for key: ProcessKey, pid: Int32) -> [String]
}

extension ProcessDetailSource {
    /// 기본: 커널에서 열린 파일을 읽는다(PROC_PIDLISTFDS).
    public func openFiles(for key: ProcessKey, pid: Int32) -> [String] { ProcessSampler.openFiles(pid: pid) }
}

extension ProcessSampler: ProcessDetailSource {}

/// 프로세스 목록·메모리·CPU 수집기. 커널 API(sysctl KERN_PROC_ALL, proc_pid_rusage, proc_pidpath, KERN_PROCARGS2, proc_pidinfo)만 쓴다.
public final class ProcessSampler {
    public static let keptEnvironmentKeys: Set<String> = ["CFFIXED_USER_HOME", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CODEX_HOME", "TERM_PROGRAM", "ORCA_TERMINAL_ID",
                                                         "ORCA_TERMINAL_HANDLE", "ORCA_TAB_ID", "ORCA_AGENT_PANE", "__CFBundleIdentifier"]

    private let selfUID = getuid()
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(1, info.denom)))
    }()
    private var pathCache: [ProcessKey: String] = [:]
    private var argsCache: [ProcessKey: ProcArgs] = [:]
    private var cwdCache: [ProcessKey: (path: String?, at: Date)] = [:]
    private var previousCPU: [ProcessKey: (ns: UInt64, at: Date)] = [:]
    private var topFallback: [Int32: UInt64] = [:]

    public init() {}

    /// top 보충값(pid → 바이트). 권한 밖 프로세스에만 쓰인다.
    public func updateTopFallback(_ values: [Int32: UInt64]) {
        topFallback = values
    }

    public func sample(now: Date = Date()) -> [ProcRecord] {
        let kinfos = Self.allKinfo()
        var records: [ProcRecord] = []
        records.reserveCapacity(kinfos.count)
        var seen = Set<ProcessKey>()
        for info in kinfos {
            let pid = info.kp_proc.p_pid
            let tv = info.kp_proc.p_un.__p_starttime
            let startMicros = Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec)
            let key = ProcessKey(pid: pid, start: startMicros)
            seen.insert(key)
            var record = ProcRecord(
                pid: pid,
                ppid: info.kp_eproc.e_ppid,
                uid: info.kp_eproc.e_ucred.cr_uid,
                name: Self.comm(info),
                startTime: Date(timeIntervalSince1970: TimeInterval(startMicros) / 1_000_000),
                key: key
            )
            record.path = path(for: key)
            record.ttyDevice = info.kp_eproc.e_tdev
            if let usage = Self.rusage(pid) {
                record.footprint = usage.ri_phys_footprint
                record.memorySource = .kernel
                let ns = (usage.ri_user_time + usage.ri_system_time) &* timebase.numer / timebase.denom
                record.cpuTimeNs = ns
                if let previous = previousCPU[key] {
                    let wall = now.timeIntervalSince(previous.at)
                    if wall > 0.2, ns >= previous.ns {
                        record.cpuPercent = Double(ns - previous.ns) / (wall * 1_000_000_000) * 100
                    }
                }
                previousCPU[key] = (ns, now)
            } else if let value = topFallback[pid] {
                record.footprint = value
                record.memorySource = .top
            }
            records.append(record)
        }
        // 사라진 프로세스의 캐시 정리.
        if previousCPU.count > seen.count + 256 {
            previousCPU = previousCPU.filter { seen.contains($0.key) }
            pathCache = pathCache.filter { seen.contains($0.key) }
            argsCache = argsCache.filter { seen.contains($0.key) }
            cwdCache = cwdCache.filter { seen.contains($0.key) }
        }
        return records
    }

    public func path(for key: ProcessKey) -> String? {
        if let cached = pathCache[key] { return cached.isEmpty ? nil : cached }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(key.pid, &buffer, UInt32(buffer.count))
        let value = length > 0 ? String(cString: buffer) : ""
        pathCache[key] = value
        return value.isEmpty ? nil : value
    }

    /// argv와 판정용 환경 변수. 같은 사용자 프로세스에서만 읽힌다.
    public func arguments(for key: ProcessKey) -> ProcArgs? {
        if let cached = argsCache[key] { return cached }
        guard let parsed = Self.readArguments(pid: key.pid) else { return nil }
        argsCache[key] = parsed
        return parsed
    }

    /// 작업 폴더(PROC_PIDVNODEPATHINFO). 30초 캐시.
    public func workingDirectory(for key: ProcessKey, now: Date = Date()) -> String? {
        if let cached = cwdCache[key], now.timeIntervalSince(cached.at) < 30 { return cached.path }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let result = proc_pidinfo(key.pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        var value: String?
        if result == size {
            value = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if value?.isEmpty == true { value = nil }
        }
        cwdCache[key] = (value, now)
        return value
    }

    /// 열린 일반 파일 경로(PROC_PIDLISTFDS + PROC_PIDFDVNODEPATHINFO). lsof 대신 쓴다.
    public static func openFiles(pid: Int32) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let filled = fds.withUnsafeMutableBytes { raw in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard filled > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    // MARK: - Kernel calls

    static func allKinfo() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
            let stride = MemoryLayout<kinfo_proc>.stride
            var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            size = buffer.count * stride
            let result = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, 4, raw.baseAddress, &size, nil, 0)
            }
            if result == 0 { return Array(buffer.prefix(size / stride)) }
            if errno != ENOMEM { return [] }
        }
        return []
    }

    static func comm(_ info: kinfo_proc) -> String {
        var copy = info.kp_proc.p_comm
        return withUnsafeBytes(of: &copy) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    static func rusage(_ pid: Int32) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        return result == 0 ? info : nil
    }

    public static func readArguments(pid: Int32) -> ProcArgs? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        func readString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let value = String(decoding: buffer[start..<index], as: UTF8.self)
            return value
        }
        let executable = readString() ?? ""
        while index < size, buffer[index] == 0 { index += 1 }
        var argv: [String] = []
        for _ in 0..<max(0, Int(argc)) {
            guard let value = readString() else { break }
            argv.append(value)
            index += 1
        }
        var environment: [String: String] = [:]
        while index < size {
            guard let entry = readString() else { break }
            index += 1
            if entry.isEmpty { break }
            if let separator = entry.firstIndex(of: "=") {
                let name = String(entry[..<separator])
                if keptEnvironmentKeys.contains(name) {
                    environment[name] = String(entry[entry.index(after: separator)...])
                }
            }
        }
        return ProcArgs(executable: executable, argv: argv, environment: environment)
    }
}
