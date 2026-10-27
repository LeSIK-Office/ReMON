import Foundation

/// 세션 기록(jsonl) 꼬리만 읽어 마지막 활동 시각과 마지막 사용자 요청 첫 줄을 얻는다.
/// 사양 4장: 수정 시각이 아니라 마지막 항목의 timestamp로 판정한다. 원문은 저장하지 않는다.
public final class SessionLogReader {
    public struct Info: Sendable, Equatable {
        public var lastActivity: Date?
        public var title: String?
        public var threadID: String?
    }

    private struct CacheEntry {
        var size: UInt64
        var modified: Date
        var info: Info
    }

    private var cache: [String: CacheEntry] = [:]
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public init() {}

    public func read(path: String, kind: AgentKind) -> Info {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return Info() }
        if let cached = cache[path], cached.size == size, cached.modified == modified { return cached.info }
        if let cached = cache[path], size > cached.size {
            // 이어 쓰기: 새로 붙은 부분(+줄 경계 여유 64KB)만 읽는다. 이전에 찾은 시각·제목은 유지한다.
            // (제목을 못 찾은 세션을 주기마다 32MB씩 다시 훑어 상주 CPU가 1.8%까지 오르던 문제)
            let appended = size - cached.size + (64 << 10)
            var fresh = autoreleasepool { scan(path: path, size: size, kind: kind, wantTitle: true, limit: min(appended, 4 << 20)) }
            if fresh.lastActivity == nil { fresh.lastActivity = cached.info.lastActivity }
            if fresh.title == nil { fresh.title = cached.info.title }
            fresh.threadID = Self.threadID(fromPath: path)
            cache[path] = CacheEntry(size: size, modified: modified, info: fresh)
            return fresh
        }
        let previous = cache[path]?.info
        // 처음(또는 파일이 줄었을 때)만 깊게 읽는다: 사용자 요청 제목을 찾을 때까지 최대 32MB(이미지 base64 줄이 큼).
        var info = autoreleasepool { scan(path: path, size: size, kind: kind, wantTitle: true, limit: 32 << 20) }
        if info.title == nil { info.title = previous?.title }
        info.threadID = Self.threadID(fromPath: path)
        cache[path] = CacheEntry(size: size, modified: modified, info: info)
        if cache.count > 400 { cache.removeAll(keepingCapacity: true) }
        return info
    }

    /// 파일 끝에서 1MB씩 거꾸로 읽으며 완전한 줄만 해석한다. 한 줄이 아주 길어도(이미지) 이어 붙여 처리한다.
    private func scan(path: String, size: UInt64, kind: AgentKind, wantTitle: Bool, limit: UInt64) -> Info {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Info() }
        defer { try? handle.close() }
        var info = Info()
        var position = size
        var carry = Data()
        var scanned: UInt64 = 0
        let chunk: UInt64 = 1 << 20
        while position > 0, info.lastActivity == nil || (wantTitle && info.title == nil), scanned < limit {
            // 이어 읽기는 한도(새로 붙은 양 + 여유)만큼만 읽는다. 1MB 단위로 읽으면 매번 큰 도구 결과 줄까지 해석하게 된다.
            let length = min(chunk, position, limit - scanned)
            position -= length
            scanned += length
            do { try handle.seek(toOffset: position) } catch { break }
            guard let piece = try? handle.read(upToCount: Int(length)) else { break }
            var buffer = piece
            buffer.append(carry)
            var parts = buffer.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            carry = position > 0 && !parts.isEmpty ? Data(parts.removeFirst()) : Data()
            // 이미지 같은 거대한 줄은 끝부분(timestamp가 있는 쪽)만 남겨 메모리를 아낀다.
            if carry.count > 2 << 20 { carry = carry.suffix(64 << 10) }
            for line in parts.reversed() where !line.isEmpty {
                autoreleasepool { consume(Data(line), kind: kind, wantTitle: wantTitle, into: &info) }
                if info.lastActivity != nil && (!wantTitle || info.title != nil) { break }
            }
        }
        // 한도 안이 거대한 줄 하나뿐이면(이미지 등) 완전한 줄이 없다 → 잘린 줄 끝에서 timestamp만 찾는다.
        if info.lastActivity == nil, !carry.isEmpty { info.lastActivity = timestamp(inRawLine: carry) }
        return info
    }

    private static let userMarkers = [Data("\"user\"".utf8), Data("user_message".utf8)]

    private func consume(_ line: Data, kind: AgentKind, wantTitle: Bool, into info: inout Info) {
        // 시각을 이미 찾았다면 사용자 요청 표식이 없는 줄(도구 결과·이미지)은 해석하지 않는다.
        if info.lastActivity != nil, !Self.userMarkers.contains(where: { line.range(of: $0) != nil }) { return }
        if line.count > 4 << 20 {
            // 거대한 줄(도구 결과의 이미지 등)은 해석하지 않고 timestamp만 찾는다.
            if info.lastActivity == nil { info.lastActivity = timestamp(inRawLine: line) }
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if info.lastActivity == nil, let stamp = object["timestamp"] as? String {
            info.lastActivity = fractional.date(from: stamp) ?? plain.date(from: stamp)
        }
        if wantTitle, info.title == nil, let text = Self.userText(object, kind: kind) {
            info.title = Redactor.headline(text)
        }
    }

    private func timestamp(inRawLine line: Data) -> Date? {
        let needle = Data("\"timestamp\":\"".utf8)
        for window in [line.suffix(4096), line.prefix(4096)] {
            guard let range = window.range(of: needle) else { continue }
            let rest = window[range.upperBound...].prefix(40)
            guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { continue }
            let stamp = String(decoding: rest[rest.startIndex..<end], as: UTF8.self)
            if let date = fractional.date(from: stamp) ?? plain.date(from: stamp) { return date }
        }
        return nil
    }

    /// 사용자가 직접 입력한 요청만 고른다(도구 결과·시스템 주입 문맥 제외).
    static func userText(_ object: [String: Any], kind: AgentKind) -> String? {
        func isInjected(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return true }
            let prefixes = ["<environment_context", "<user_instructions", "# AGENTS.md", "<permissions", "<skill", "<command-", "<local-command", "<system-reminder",
                            "Caveat:", "<task-notification", "[Request interrupted", "This session is being continued", "Name this chat", "<turn_aborted", "<subagent"]
            return prefixes.contains { trimmed.hasPrefix($0) }
        }
        switch kind {
        case .claudeCode:
            guard object["type"] as? String == "user", (object["isMeta"] as? Bool) != true,
                  let message = object["message"] as? [String: Any] else { return nil }
            if let text = message["content"] as? String { return isInjected(text) ? nil : text }
            if let parts = message["content"] as? [[String: Any]] {
                for part in parts where part["type"] as? String == "text" {
                    if let text = part["text"] as? String, !isInjected(text) { return text }
                }
            }
            return nil
        default:
            if object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
               payload["type"] as? String == "user_message", let text = payload["message"] as? String {
                return isInjected(text) ? nil : text
            }
            if object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any],
               payload["type"] as? String == "message", payload["role"] as? String == "user",
               let parts = payload["content"] as? [[String: Any]] {
                for part in parts {
                    if let text = part["text"] as? String, !isInjected(text) { return text }
                }
            }
            return nil
        }
    }

    /// rollout-…-<uuid>.jsonl, <uuid>.jsonl 에서 uuid를 뽑는다.
    public static func threadID(fromPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        let pattern = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        guard let range = stem.range(of: pattern, options: .regularExpression) else { return nil }
        return String(stem[range])
    }
}

/// Orca 터미널 제목 연결. JSON에 pid가 없어 작업 폴더 + 에이전트 종류로 맞춘다(추정).
public struct OrcaTerminal: Sendable, Equatable {
    public var handle: String
    public var title: String
    public var worktreePath: String
    public var agent: String?
    public var lastOutputAt: Date?
    public var connected: Bool
    /// 탭은 닫혔는데 PTY(와 그 안의 프로세스)는 살아 있다(Orca가 tabId를 'pty:…'로 둔다, 10-24 실측).
    public var orphaned: Bool = false
    /// 탭·창 id — 탭 안 프로세스의 ORCA_TAB_ID · ORCA_AGENT_PANE(탭:창)과 맞대 정확히 짝짓는다.
    public var tabId: String? = nil
    public var leafId: String? = nil

    public init(handle: String, title: String, worktreePath: String, agent: String?, lastOutputAt: Date?, connected: Bool, orphaned: Bool = false,
                tabId: String? = nil, leafId: String? = nil) {
        self.handle = handle
        self.title = title
        self.worktreePath = worktreePath
        self.agent = agent
        self.lastOutputAt = lastOutputAt
        self.connected = connected
        self.orphaned = orphaned
        self.tabId = tabId
        self.leafId = leafId
    }
}

public enum OrcaBridge {
    /// CLI 링크를 설치하지 않은 Mac도 앱 번들 안 CLI로 붙는다(Orca가 아예 없으면 nil → 제목은 기록에서, 탭 상태는 'Orca 밖').
    public static let candidates = ["/usr/local/bin/orca", "/opt/homebrew/bin/orca", "/Applications/Orca.app/Contents/Resources/bin/orca",
                                    FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/Orca.app/Contents/Resources/bin/orca"]

    /// 쓸 수 있는 Orca CLI(없으면 nil).
    public static var executable: String? { candidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    public static func list() -> [OrcaTerminal]? {
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let text = Shell.run(executable, ["terminal", "list", "--json"], timeout: 6),
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terminals = ((root["result"] as? [String: Any])?["terminals"] ?? root["terminals"]) as? [[String: Any]] else { return nil }
        return terminals.compactMap { item in
            guard let path = item["worktreePath"] as? String else { return nil }
            let rawTitle = item["title"] as? String ?? ""
            let lastOutput = (item["lastOutputAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return OrcaTerminal(handle: item["handle"] as? String ?? "", title: cleanTitle(rawTitle), worktreePath: path, agent: item["agentIdentity"] as? String, lastOutputAt: lastOutput,
                                connected: (item["connected"] as? Bool) ?? false, orphaned: (item["orphaned"] as? Bool) ?? false,
                                tabId: item["tabId"] as? String, leafId: item["leafId"] as? String)
        }
    }

    /// "✳ DWG 매장 인테리어 CAD", "⠇ 프로젝트 분석 | STOREARC" → 앞의 상태 기호와 뒤의 프로젝트 꼬리를 뗀다.
    public static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespaces)
        while let first = title.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first), first != "(", first != "[" {
            title.removeFirst()
            title = title.trimmingCharacters(in: .whitespaces)
        }
        if let bar = title.range(of: " | ", options: .backwards) {
            let head = String(title[..<bar.lowerBound]), tail = String(title[bar.upperBound...])
            // "OC | 제목"(opencode)처럼 앞이 짧은 접두어면 뒤가 제목, "제목 | 프로젝트"면 앞이 제목.
            title = head.count <= 3 && !tail.isEmpty ? tail : head
        }
        return title
    }
}
