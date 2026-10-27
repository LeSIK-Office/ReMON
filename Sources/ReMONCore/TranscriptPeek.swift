import Foundation

/// 대화 기록 끝에서 마지막 사용자 요청과 마지막 답변을 한 줄씩(가려서) 꺼낸다 — 감사가 '제목'이 아니라 실제 대화 끝을 보고 판단하게(10-25 설계 감사).
public enum TranscriptPeek {
    public struct Exchange: Sendable, Equatable {
        public var request: String?
        public var reply: String?
    }

    public static func lastExchange(_ path: String, kind: AgentKind, bytes: Int = 131_072) -> Exchange {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Exchange() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(bytes) ? size - UInt64(bytes) : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let lines = text.split(separator: "\n").dropFirst(size > UInt64(bytes) ? 1 : 0)
        var exchange = Exchange()
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if exchange.reply == nil, let reply = assistantText(object, kind: kind) { exchange.reply = Redactor.headline(reply, limit: 90) }
            if exchange.request == nil, let request = SessionLogReader.userText(object, kind: kind) { exchange.request = Redactor.headline(request, limit: 90) }
            if exchange.reply != nil && exchange.request != nil { break }
        }
        return exchange
    }

    static func assistantText(_ object: [String: Any], kind: AgentKind) -> String? {
        switch kind {
        case .claudeCode:
            guard object["type"] as? String == "assistant", let message = object["message"] as? [String: Any], let parts = message["content"] as? [[String: Any]] else { return nil }
            return parts.last { $0["type"] as? String == "text" }.flatMap { $0["text"] as? String }.flatMap { $0.isEmpty ? nil : $0 }
        default:
            if object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any],
               payload["type"] as? String == "agent_message", let text = payload["message"] as? String, !text.isEmpty { return text }
            guard object["type"] as? String == "response_item", let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message", payload["role"] as? String == "assistant",
                  let parts = payload["content"] as? [[String: Any]] else { return nil }
            return parts.compactMap { $0["text"] as? String }.last { !$0.isEmpty }
        }
    }
}
