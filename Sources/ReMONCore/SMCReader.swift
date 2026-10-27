import Foundation
import IOKit

/// SMC(System Management Controller) 읽기 전용 접근: 팬 RPM·온도. 쓰기는 하지 않는다.
/// 사용자 권한으로 AppleSMC 사용자 클라이언트를 열어 `kSMCHandleYPCEvent`(선택자 2)로 키를 읽는다.
/// Apple Silicon의 온도 키 이름은 칩마다 다르므로 시작할 때 전체 키를 한 번 훑어(수천 개, 0.1초 안팎) 후보를 고른다.
public final class SMCReader {
    public struct Reading: Sendable, Equatable, Codable {
        public var fanCount = 0
        /// 첫 번째 팬의 현재·최소·최대 RPM
        public var fanRPM: Double = 0
        public var fanMinRPM: Double = 0
        public var fanMaxRPM: Double = 0
        /// CPU(다이) 온도 °C. 후보 키 중 최댓값.
        public var cpuTemperature: Double = 0
        public var temperatureKey = ""
        public var available = false
        public init() {}

        /// 팬 회전 비율 0~1(최소~최대 사이).
        public var fanFraction: Double {
            guard fanMaxRPM > fanMinRPM else { return 0 }
            return max(0, min(1, (fanRPM - fanMinRPM) / (fanMaxRPM - fanMinRPM)))
        }
    }

    private struct KeyData {
        var key: UInt32 = 0
        var vers = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt16(0))
        var pLimit = (UInt16(0), UInt16(0), UInt32(0), UInt32(0), UInt32(0))
        // C 구조체와 같은 80바이트가 되도록 keyInfo 뒤를 명시적으로 채운다(안 채우면 76바이트 → kIOReturnBadArgument).
        var keyInfo = (dataSize: UInt32(0), dataType: UInt32(0), dataAttributes: UInt8(0), pad0: UInt8(0), pad1: UInt8(0), pad2: UInt8(0))
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var connection: io_connect_t = 0
    private var temperatureKeys: [(name: String, key: UInt32)] = []
    private var fanKeys: (actual: UInt32, min: UInt32, max: UInt32)?
    private var fanCount = 0
    private var opened = false
    private var lastReading = Reading()
    private var keyInfo: [UInt32: KeyData] = [:]

    public init() {}

    deinit { if connection != 0 { IOServiceClose(connection) } }

    public static func fourCC(_ text: String) -> UInt32 { text.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    static func name(_ value: UInt32) -> String {
        String(bytes: [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)], encoding: .ascii) ?? "????"
    }

    /// 연결을 열고 키 후보를 고른다. 실패하면 `available = false`인 읽기만 돌려준다(앱은 CPU 사용률로 대신한다).
    @discardableResult
    public func open() -> Bool {
        guard !opened else { return connection != 0 }
        opened = true
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { connection = 0; return false }
        discover()
        return true
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private func info(_ key: UInt32) -> KeyData? {
        if let cached = keyInfo[key] { return cached }
        var input = KeyData()
        input.key = key
        input.data8 = 9   // kSMCGetKeyInfo
        let result = call(&input)
        keyInfo[key] = result
        return result
    }

    private func readFloat(_ key: UInt32) -> Double? {
        guard let info = info(key), Self.name(info.keyInfo.dataType) == "flt ", info.keyInfo.dataSize == 4 else { return nil }
        var input = KeyData()
        input.key = key
        input.keyInfo = info.keyInfo
        input.data8 = 5   // kSMCReadKey
        guard let output = call(&input) else { return nil }
        return Double(withUnsafeBytes(of: output.bytes) { $0.load(as: Float.self) })
    }

    private func readUInt8(_ key: UInt32) -> Int? {
        guard let info = info(key), info.keyInfo.dataSize == 1 else { return nil }
        var input = KeyData()
        input.key = key
        input.keyInfo = info.keyInfo
        input.data8 = 5
        guard let output = call(&input) else { return nil }
        return Int(output.bytes.0)
    }

    /// 전체 키를 훑어 온도 후보(T로 시작, flt, 15~120°C)와 팬 키를 찾는다.
    private func discover() {
        fanCount = readUInt8(Self.fourCC("FNum")) ?? 0
        if fanCount > 0, readFloat(Self.fourCC("F0Ac")) != nil {
            fanKeys = (Self.fourCC("F0Ac"), Self.fourCC("F0Mn"), Self.fourCC("F0Mx"))
        }
        guard let countInfo = info(Self.fourCC("#KEY")) else { return }
        var input = KeyData()
        input.key = Self.fourCC("#KEY")
        input.keyInfo = countInfo.keyInfo
        input.data8 = 5
        guard let output = call(&input) else { return }
        let total = withUnsafeBytes(of: output.bytes) { UInt32($0[0]) << 24 | UInt32($0[1]) << 16 | UInt32($0[2]) << 8 | UInt32($0[3]) }
        var candidates: [(String, UInt32, Double)] = []
        for index in 0..<min(total, 8000) {
            var query = KeyData()
            query.data8 = 8   // kSMCGetKeyFromIndex
            query.data32 = index
            guard let entry = call(&query) else { continue }
            let name = Self.name(entry.key)
            guard name.hasPrefix("T"), let value = readFloat(entry.key), value > 15, value < 120 else { continue }
            candidates.append((name, entry.key, value))
        }
        // 다이 온도 키를 우선한다(M5: TPD*, M1~M3: Tp*·Tc*·Te*·Tf*). 가상 센서(TV*)·배터리(TB*)는 제외.
        let preferred = ["TPD", "Tp", "Tc", "Te", "Tf", "TC"]
        for prefix in preferred {
            let matched = candidates.filter { $0.0.hasPrefix(prefix) }
            if !matched.isEmpty { temperatureKeys = matched.map { ($0.0, $0.1) }; return }
        }
        temperatureKeys = candidates.filter { !$0.0.hasPrefix("TV") && !$0.0.hasPrefix("TB") }.map { ($0.0, $0.1) }
    }

    /// 현재 값. 키 수십 개를 읽는 데 1ms 안팎.
    public func read() -> Reading {
        guard open() else { return Reading() }
        var reading = Reading()
        reading.available = fanKeys != nil || !temperatureKeys.isEmpty
        reading.fanCount = fanCount
        if let fanKeys {
            reading.fanRPM = readFloat(fanKeys.actual) ?? lastReading.fanRPM
            reading.fanMinRPM = readFloat(fanKeys.min) ?? lastReading.fanMinRPM
            reading.fanMaxRPM = readFloat(fanKeys.max) ?? lastReading.fanMaxRPM
        }
        var best = 0.0
        var bestKey = ""
        for entry in temperatureKeys {
            if let value = readFloat(entry.key), value > best, value < 120 { best = value; bestKey = entry.name }
        }
        reading.cpuTemperature = best
        reading.temperatureKey = bestKey
        lastReading = reading
        return reading
    }
}
