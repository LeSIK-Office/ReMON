import Darwin
import Foundation

public enum PressureLevel: Int, Sendable, Codable, Comparable {
    case normal = 1, warning = 2, critical = 4

    public var label: String {
        switch self {
        case .normal: "정상"
        case .warning: "주의"
        case .critical: "위험"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// host_statistics64(HOST_VM_INFO64) 기반 메모리. used는 활성 상태 보기의 '사용된 메모리'(앱 메모리 + 와이어드 + 압축) 기준.
public struct MemoryStats: Sendable, Codable, Equatable {
    public init() {}
    public var physical: UInt64 = 0
    public var free: UInt64 = 0
    public var active: UInt64 = 0
    public var inactive: UInt64 = 0
    public var speculative: UInt64 = 0
    public var wired: UInt64 = 0
    public var compressed: UInt64 = 0
    public var compressedOriginal: UInt64 = 0
    public var purgeable: UInt64 = 0
    public var external: UInt64 = 0
    public var internalPages: UInt64 = 0
    public var throttled: UInt64 = 0

    public var appMemory: UInt64 { internalPages > purgeable ? internalPages - purgeable : 0 }
    public var used: UInt64 { appMemory + wired + compressed }
    /// 여유 메모리 = 전체 − 사용(앱·와이어드·압축). 디스크 '여유'와 같은 방식으로 보여 준다(대표 지시 10-24).
    public var available: UInt64 { physical > used ? physical - used : 0 }
    public var cachedFiles: UInt64 { external + purgeable }
    /// top의 PhysMem 'used'와 같은 기준(전체 - free).
    public var topUsed: UInt64 { physical > free ? physical - free : 0 }
}

public struct SwapStats: Sendable, Codable, Equatable {
    public init(total: UInt64 = 0, used: UInt64 = 0, available: UInt64 = 0, encrypted: Bool = false) {
        self.total = total
        self.used = used
        self.available = available
        self.encrypted = encrypted
    }
    public var total: UInt64 = 0
    public var used: UInt64 = 0
    public var available: UInt64 = 0
    public var encrypted = false
}

public struct DiskStats: Sendable, Codable, Equatable {
    public init() {}
    /// statfs f_bavail 기준 — df의 Avail과 같은 값.
    public var available: UInt64 = 0
    public var total: UInt64 = 0
    /// Finder가 보여 주는 값(정리 가능한 공간 포함).
    public var availableForImportantUsage: UInt64 = 0
    /// /System/Volumes/VM 사용량(스왑 파일이 놓이는 볼륨).
    public var swapVolumeUsed: UInt64 = 0
}

public struct SystemSnapshot: Sendable, Codable, Equatable {
    public init() {}
    public var time = Date()
    public var memory = MemoryStats()
    public var swap = SwapStats()
    public var pressure: PressureLevel = .normal
    public var memoryFreePercent: Int = 100
    public var cpuPercent: Double = 0
    public var coreCount: Int = 0
    /// 코어별 사용률(%) — 사무실 'CPU 엔진'의 실린더 막대.
    public var coreLoads: [Double] = []
    public var disk = DiskStats()
    /// 팬 RPM·CPU 온도(SMC). 못 읽으면 `available == false`.
    public var thermal = SMCReader.Reading()
}

/// 1초 주기로 불러도 가벼운 시스템 수치 수집기. 스레드 하나에서만 사용한다.
public final class SystemSampler {
    private let host = mach_host_self()
    private var previousTicks: [UInt64] = []
    private var lastImportantUsageCheck = Date.distantPast
    private var cachedImportantUsage: UInt64 = 0
    private let thermalReader: () -> SMCReader.Reading
    private var lastThermalRead = Date.distantPast
    private var cachedThermal = SMCReader.Reading()

    public init(thermalReader: @escaping () -> SMCReader.Reading = SMCReader().read) {
        self.thermalReader = thermalReader
    }

    public func sample(now: Date = Date()) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.time = now
        snapshot.memory = memory()
        snapshot.swap = swap()
        snapshot.pressure = PressureLevel(rawValue: Int(Self.sysctlInt32("kern.memorystatus_vm_pressure_level") ?? 1)) ?? .normal
        snapshot.memoryFreePercent = Int(Self.sysctlInt32("kern.memorystatus_level") ?? 100)
        let cpu = cpuUsage()
        snapshot.cpuPercent = cpu.percent
        snapshot.coreCount = cpu.cores
        snapshot.coreLoads = cpu.loads
        // 온도·팬은 5초마다 갱신한다. CPU·메모리·압박 수치는 매번 새로 읽는다.
        if now.timeIntervalSince(lastThermalRead) >= 5 || now < lastThermalRead {
            cachedThermal = thermalReader()
            lastThermalRead = now
        }
        snapshot.thermal = cachedThermal
        snapshot.disk = disk(now: now)
        return snapshot
    }

    public func memory() -> MemoryStats {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        var memory = MemoryStats()
        memory.physical = Self.sysctlUInt64("hw.memsize") ?? 0
        guard result == KERN_SUCCESS else { return memory }
        let page = UInt64(vm_kernel_page_size)
        memory.free = UInt64(stats.free_count) * page
        memory.active = UInt64(stats.active_count) * page
        memory.inactive = UInt64(stats.inactive_count) * page
        memory.speculative = UInt64(stats.speculative_count) * page
        memory.wired = UInt64(stats.wire_count) * page
        memory.compressed = UInt64(stats.compressor_page_count) * page
        memory.compressedOriginal = UInt64(stats.total_uncompressed_pages_in_compressor) * page
        memory.purgeable = UInt64(stats.purgeable_count) * page
        memory.external = UInt64(stats.external_page_count) * page
        memory.internalPages = UInt64(stats.internal_page_count) * page
        memory.throttled = UInt64(stats.throttled_count) * page
        return memory
    }

    public func swap() -> SwapStats {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return SwapStats() }
        return SwapStats(total: usage.xsu_total, used: usage.xsu_used, available: usage.xsu_avail, encrypted: usage.xsu_encrypted != 0)
    }

    /// host_processor_info 코어별 tick 차분. 첫 호출은 부팅 이후 평균을 돌려준다.
    public func cpuUsage() -> (percent: Double, cores: Int, loads: [Double]) {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, 0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [UInt64] = []
        ticks.reserveCapacity(Int(cpuCount) * Int(CPU_STATE_MAX))
        for index in 0..<(Int(cpuCount) * Int(CPU_STATE_MAX)) {
            ticks.append(UInt64(UInt32(bitPattern: info[index])))
        }
        defer { previousTicks = ticks }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        var loads: [Double] = []
        let base = previousTicks.count == ticks.count ? previousTicks : Array(repeating: 0, count: ticks.count)
        for cpu in 0..<Int(cpuCount) {
            let offset = cpu * Int(CPU_STATE_MAX)
            func delta(_ state: Int32) -> UInt64 {
                let now = ticks[offset + Int(state)], before = base[offset + Int(state)]
                return now >= before ? now - before : now
            }
            let user = delta(CPU_STATE_USER), system = delta(CPU_STATE_SYSTEM), nice = delta(CPU_STATE_NICE), idle = delta(CPU_STATE_IDLE)
            busy += user + system + nice
            total += user + system + nice + idle
            let coreTotal = user + system + nice + idle
            loads.append(coreTotal == 0 ? 0 : Double(user + system + nice) / Double(coreTotal) * 100)
        }
        return (total == 0 ? 0 : Double(busy) / Double(total) * 100, Int(cpuCount), loads)
    }

    public func disk(now: Date = Date()) -> DiskStats {
        var disk = DiskStats()
        var root = statfs()
        if statfs("/", &root) == 0 {
            disk.available = UInt64(root.f_bavail) * UInt64(root.f_bsize)
            disk.total = UInt64(root.f_blocks) * UInt64(root.f_bsize)
        }
        var vm = statfs()
        if statfs("/System/Volumes/VM", &vm) == 0 {
            disk.swapVolumeUsed = (UInt64(vm.f_blocks) - UInt64(vm.f_bfree)) * UInt64(vm.f_bsize)
        }
        // 정리 가능 공간 계산은 상대적으로 비싸서 30초마다만 갱신한다.
        if now.timeIntervalSince(lastImportantUsageCheck) > 30 {
            lastImportantUsageCheck = now
            let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            cachedImportantUsage = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        }
        disk.availableForImportantUsage = cachedImportantUsage
        return disk
    }

    public static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }

    public static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}

