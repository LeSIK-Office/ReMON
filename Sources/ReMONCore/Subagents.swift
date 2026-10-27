import Foundation

/// 세션 안에서 일하는 하위 에이전트(Claude 서브에이전트·워크플로 에이전트, Codex 하위 스레드).
/// 에이전트는 사람이다 — 프로세스(도구)인 '하위 프로세스'와 구분해 따로 센다.
public struct SubagentInfo: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case subagent, workflow, thread }
    public var id: String
    /// 사람이 읽는 이름(예: "collect:notice-standard", "Audit engine console data sources")
    public var label: String
    /// sonnet · haiku · opus 등(없으면 nil)
    public var model: String?
    public var kind: Kind
    /// 워크플로 id(워크플로 에이전트만)
    public var workflow: String?
    public var phase: String?
    public var lastActivity: Date?
    /// 최근(2분 안)에 기록을 썼고 끝나지 않았다.
    public var active: Bool
    /// 멈춘 워크플로(잔재 후보): 워크플로 일지에 끝난 기록(완료·실패·취소)이 없는데 20분 넘게 기록을 쓰지 않았다.
    /// active는 '2분 안에 씀'까지 뜻해 20분 조용과 함께 참일 수 없다 — 그래서 '끝나지 않음'은 일지로 본다.
    /// 일지가 없는 일반 하위 에이전트·Codex 하위 스레드는 끝났는지 알 수 없어 늘 false.
    public var stale: Bool

    public init(id: String, label: String, model: String?, kind: Kind, workflow: String?, phase: String?, lastActivity: Date?, active: Bool, stale: Bool = false) {
        self.id = id
        self.label = label
        self.model = model
        self.kind = kind
        self.workflow = workflow
        self.phase = phase
        self.lastActivity = lastActivity
        self.active = active
        self.stale = stale
    }
}

/// Claude Code는 하위 에이전트 기록을 세션 폴더에 따로 남긴다(10-24 실측):
///   <projects>/<proj>/<sessionId>/subagents/agent-<id>.jsonl (+ .meta.json: description·model·requestShape)
///   <projects>/<proj>/<sessionId>/subagents/workflows/wf_<id>/agent-<id>.jsonl (+ .meta.json, journal.jsonl)
/// 프로세스는 하나라 프로세스 목록으로는 안 보인다 → 파일의 수정 시각으로 '지금 일하는지'를 본다. 읽기 전용.
public final class SubagentScanner {
    public static let activeWindow: TimeInterval = 120
    /// 오래된 하위 에이전트 기록은 보지 않는다(세션 하나에 며칠 치가 쌓인다).
    public static let recentWindow: TimeInterval = 6 * 3600
    /// 끝나지 않은 워크플로 에이전트가 이만큼 기록을 쓰지 않으면 멈춘 것(stale)으로 본다.
    public static let staleAfter: TimeInterval = 20 * 60

    private struct Meta { var label: String; var model: String?; var kind: SubagentInfo.Kind; var phase: String? }
    private var metaCache: [String: Meta] = [:]
    private var finishedCache: [String: (modified: Date, finished: Set<String>)] = [:]

    public init() {}

    /// 주 기록 경로(<sessionId>.jsonl) → 같은 이름 폴더의 subagents를 훑는다.
    public func scanClaude(sessionLog: String, now: Date = Date()) -> [SubagentInfo] {
        let base = (sessionLog as NSString).deletingPathExtension + "/subagents"
        let fm = FileManager.default
        guard fm.fileExists(atPath: base) else { return [] }
        var result: [SubagentInfo] = []
        result += scanFolder(base, workflow: nil, now: now)
        if let workflows = try? fm.contentsOfDirectory(atPath: base + "/workflows") {
            for name in workflows where name.hasPrefix("wf_") {
                result += scanFolder(base + "/workflows/" + name, workflow: name, now: now)
            }
        }
        return result.sorted { ($0.active ? 0 : 1, $0.label) < ($1.active ? 0 : 1, $1.label) }
    }

    /// Codex 하위 스레드: 공급 프로세스가 연 추가 rollout 파일.
    public func scanCodex(extraLogs: [String], now: Date = Date()) -> [SubagentInfo] {
        extraLogs.enumerated().compactMap { element -> SubagentInfo? in
            let (index, path) = element
            let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            let active = modified.map { now.timeIntervalSince($0) < Self.activeWindow } ?? false
            return SubagentInfo(id: (path as NSString).lastPathComponent, label: "하위 스레드 \(index + 1)", model: nil, kind: .thread,
                                workflow: nil, phase: nil, lastActivity: modified, active: active)
        }
    }

    private func scanFolder(_ folder: String, workflow: String?, now: Date) -> [SubagentInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return [] }
        let finished: Set<String> = workflow == nil ? [] : finishedAgents(journal: folder + "/journal.jsonl")
        var result: [SubagentInfo] = []
        for name in names where name.hasPrefix("agent-") && name.hasSuffix(".jsonl") {
            let path = folder + "/" + name
            guard let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) < Self.recentWindow else { continue }
            let agentID = String(name.dropFirst("agent-".count).dropLast(".jsonl".count))
            let meta = self.meta(folder + "/agent-" + agentID + ".meta.json", workflow: workflow)
            let done = finished.contains(agentID)
            let silence = now.timeIntervalSince(modified)
            // 멈춘 워크플로: 일지가 있는 워크플로 폴더의 에이전트만(끝났는지 일지로 안다).
            let stale = workflow != nil && meta.kind == .workflow && !done && silence >= Self.staleAfter
            result.append(SubagentInfo(id: agentID, label: meta.label, model: meta.model, kind: meta.kind, workflow: workflow, phase: meta.phase,
                                       lastActivity: modified, active: !done && silence < Self.activeWindow, stale: stale))
        }
        return result
    }

    private func meta(_ path: String, workflow: String?) -> Meta {
        if let cached = metaCache[path] { return cached }
        var meta = Meta(label: workflow == nil ? "하위 에이전트" : "워크플로 에이전트", model: nil, kind: workflow == nil ? .subagent : .workflow, phase: nil)
        if let data = FileManager.default.contents(atPath: path), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let description = object["description"] as? String, !description.isEmpty { meta.label = description }
            meta.model = object["model"] as? String
            meta.phase = object["workflowPhase"] as? String
            if (object["agentType"] as? String) == "workflow-subagent" { meta.kind = .workflow }
        }
        if metaCache.count > 2000 { metaCache.removeAll() }
        metaCache[path] = meta
        return meta
    }

    /// 워크플로 일지에서 끝난 에이전트(완료·실패·취소).
    private func finishedAgents(journal: String) -> Set<String> {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: journal))?[.modificationDate] as? Date else { return [] }
        if let cached = finishedCache[journal], cached.modified == modified { return cached.finished }
        var finished = Set<String>()
        if let text = try? String(contentsOfFile: journal, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                guard line.contains("agentId"), let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let type = object["type"] as? String, let agent = object["agentId"] as? String else { continue }
                if ["completed", "finished", "failed", "cancelled", "canceled", "succeeded", "done", "error"].contains(type) { finished.insert(agent) }
            }
        }
        finishedCache[journal] = (modified, finished)
        return finished
    }
}
