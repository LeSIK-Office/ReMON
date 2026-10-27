import Foundation

/// 권한 밖(root·다른 사용자) 프로세스의 메모리를 /usr/bin/top으로 보충한다.
/// top은 setuid root + com.apple.system-task-ports.read라서 WindowServer 같은 시스템 프로세스도 읽는다.
/// 셸 명령은 마지막 수단이라 30초 이상 간격으로만 부른다. 별칭(top→btop) 함정을 피해 절대 경로를 쓴다.
public enum TopReader {
    public static let executable = "/usr/bin/top"

    public struct PhysMem: Sendable, Equatable {
        public var used: UInt64
        public var wired: UInt64
        public var compressor: UInt64
        public var unused: UInt64
    }

    public struct Output: Sendable {
        public var memoryByPID: [Int32: UInt64]
        public var physMem: PhysMem?
    }

    public static func run(timeout: TimeInterval = 8) -> Output? {
        guard let text = Shell.run(executable, ["-l", "1", "-stats", "pid,mem", "-o", "mem"], timeout: timeout) else { return nil }
        return parse(text)
    }

    public static func parse(_ text: String) -> Output {
        var memory: [Int32: UInt64] = [:]
        var physMem: PhysMem?
        var inTable = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("PhysMem:") {
                physMem = parsePhysMem(trimmed)
                continue
            }
            if trimmed.hasPrefix("PID") { inTable = true; continue }
            guard inTable else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]), let bytes = parseSize(String(parts[1])) else { continue }
            memory[pid] = bytes
        }
        return Output(memoryByPID: memory, physMem: physMem)
    }

    /// "PhysMem: 23G used (2829M wired, 6573M compressor), 263M unused."
    static func parsePhysMem(_ line: String) -> PhysMem? {
        func value(before word: String) -> UInt64? {
            guard let range = line.range(of: " " + word) else { return nil }
            let head = line[..<range.lowerBound]
            let token = head.split(whereSeparator: { $0 == " " || $0 == "(" || $0 == "," }).last.map(String.init) ?? ""
            return parseSize(token)
        }
        guard let used = value(before: "used"), let unused = value(before: "unused") else { return nil }
        return PhysMem(used: used, wired: value(before: "wired") ?? 0, compressor: value(before: "compressor") ?? 0, unused: unused)
    }

    /// "3325M", "512K", "23G", "1024B", 끝의 +/- 표시 허용.
    public static func parseSize(_ token: String) -> UInt64? {
        var text = token.trimmingCharacters(in: CharacterSet(charactersIn: "+-*"))
        guard let unit = text.last else { return nil }
        let multipliers: [Character: Double] = ["B": 1, "K": 1024, "M": 1_048_576, "G": 1_073_741_824, "T": 1_099_511_627_776]
        var multiplier = 1.0
        if let m = multipliers[unit] {
            multiplier = m
            text.removeLast()
        }
        guard let number = Double(text) else { return nil }
        return UInt64(number * multiplier)
    }
}

/// 절대 경로 실행 + 타임아웃. 출력은 문자열로만 받는다.
public enum Shell {
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        var data = Data()
        DispatchQueue.global(qos: .utility).async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
