import Foundation

/// Claude Code 세션 레지스트리(`~/.claude/sessions/<pid>.json`, REA 조사 2026-10-24).
/// sessionId · cwd · kind(interactive/bg/…) · status(busy/shell/idle/waiting) · name을 읽는다.
/// 같은 폴더의 `*.key`(인증값)는 절대 읽지 않는다.
public struct ClaudeRegistryEntry: Sendable, Equatable {
    public var pid: Int32
    public var sessionId: String?
    public var cwd: String?
    public var kind: String?
    public var status: String?
    public var statusUpdatedAt: Date?
    public var name: String?
    public var startedAt: Date?
    public var waitingFor: String?
    public var spare: Bool
    public var nameSource: String?
    /// 프로세스 실제 시작 시각(`ps -o lstart` 꼴 UTC 문자열 → 초 단위). 백그라운드 세션은 미리 띄워 둔 예비 프로세스를 나중에 넘겨받아
    /// startedAt(넘겨받은 시각)이 프로세스 시작과 몇 분씩 벌어진다(10-25 실측 6분) — pid 재사용 판별은 이것으로 한다.
    public var procStart: Date? = nil

    /// 사용자·Orca(peer)가 붙인 이름만 제목으로 쓸 만하다(derived·auto는 'remon-51' 같은 폴더 기반 자동 이름).
    public var meaningfulName: String? {
        guard let name, !name.isEmpty, let source = nameSource, source == "user" || source == "peer" else { return nil }
        return name
    }
}

public final class ClaudeRegistry {
    private let directory: String
    private var cache: [String: (modified: Date, entry: ClaudeRegistryEntry?)] = [:]

    public init(directory: String = FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/sessions") {
        self.directory = directory
    }

    public func load() -> [Int32: ClaudeRegistryEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [:] }
        var result: [Int32: ClaudeRegistryEntry] = [:]
        var seen = Set<String>()
        for name in names where name.hasSuffix(".json") && !name.contains(".key") {
            let path = directory + "/" + name
            seen.insert(path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let modified = attributes[.modificationDate] as? Date else { continue }
            if let cached = cache[path], cached.modified == modified {
                if let entry = cached.entry { result[entry.pid] = entry }
                continue
            }
            let entry = Self.parse(path)
            cache[path] = (modified, entry)
            if let entry { result[entry.pid] = entry }
        }
        cache = cache.filter { seen.contains($0.key) }
        return result
    }

    static func parse(_ path: String) -> ClaudeRegistryEntry? {
        guard let data = FileManager.default.contents(atPath: path), data.count < 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value else { return nil }
        func date(_ key: String) -> Date? { (object[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } }
        return ClaudeRegistryEntry(pid: pid, sessionId: object["sessionId"] as? String, cwd: object["cwd"] as? String, kind: object["kind"] as? String,
                                   status: object["status"] as? String, statusUpdatedAt: date("statusUpdatedAt"), name: object["name"] as? String,
                                   startedAt: date("startedAt"), waitingFor: object["waitingFor"] as? String, spare: (object["spare"] as? Bool) ?? false,
                                   nameSource: object["nameSource"] as? String, procStart: (object["procStart"] as? String).flatMap(procStartDate))
    }

    /// "Sun Oct 25 01:11:15 2026"(C 로캘 · UTC, 한 자리 날짜는 공백 두 칸) → Date.
    public static func procStartDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " "))
    }
}
