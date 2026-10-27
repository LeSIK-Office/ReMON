import Foundation
import ReMONCore

/// 읽기 전용: 지금 이 Mac에서 감지되는 세션을 방(프로젝트)별로 찍는다. 아무것도 바꾸지 않는다.
func sessionsProbe() {
    let sampler = ProcessSampler()
    let detector = SessionDetector()
    _ = detector.detect(records: sampler.sample(), sampler: sampler, orca: OrcaBridge.list() ?? [])
    Thread.sleep(forTimeInterval: 1)
    let records = sampler.sample()
    let result = detector.detect(records: records, sampler: sampler, orca: OrcaBridge.list() ?? [])
    let registry = ClaudeRegistry().load()
    let home = NSHomeDirectory()
    let now = Date()
    for session in result.sessions.sorted(by: { $0.project < $1.project }) {
        let idle = session.lastActivity.map { Int(now.timeIntervalSince($0) / 60) } ?? -1
        let age = Int(now.timeIntervalSince(session.startTime) / 3600)
        let reg = registry[session.rootPID]
        var parts: [String] = []
        parts.append("[\(session.project)] \(session.kind.name) pid \(session.rootPID)")
        parts.append(session.state.label)
        parts.append("쉰 \(idle)분")
        parts.append("나이 \(age)시간")
        parts.append("역할 \(session.role)")
        parts.append("하위 \(session.subagents.count)")
        parts.append(Fmt.size(session.footprint))
        parts.append("레지스트리 " + (reg?.kind ?? "-") + "/" + (reg?.status ?? "-"))
        parts.append("cwd " + (session.cwd ?? "-").replacingOccurrences(of: home, with: "~"))
        if session.tabLeftover { parts.append("탭닫힘") }
        if session.orcaHandle != nil { parts.append("Orca") }
        print(parts.joined(separator: " · "))
    }
    print("세션 \(result.sessions.count)개 · 대기 인력 \(result.standbySpares)")
}

/// 읽기 전용: 특정 pid의 프로세스 기록·레지스트리 시작 시각 비교.
func registryProbe(_ pids: [Int32]) {
    let sampler = ProcessSampler()
    let records = sampler.sample()
    let registry = ClaudeRegistry().load()
    for pid in pids {
        guard let record = records.first(where: { $0.pid == pid }) else { print("pid \(pid): 프로세스 기록 없음"); continue }
        let entry = registry[pid]
        let argv = sampler.arguments(for: record.key)?.argv ?? []
        let delta = entry?.procStart.map { $0.timeIntervalSince(record.startTime) }
        print("pid \(pid) · name '\(record.name)' · path '\(record.path ?? "nil")' · start \(record.startTime) · argv \(argv.prefix(3))")
        print("   레지스트리 kind \(entry?.kind ?? "-") · procStart \(entry?.procStart.map { "\($0)" } ?? "nil") · startedAt \(entry?.startedAt.map { "\($0)" } ?? "nil") · 차이 \(delta.map { String(format: "%.2f초", $0) } ?? "-")")
    }
}

/// 금고 사본 읽기(읽기 전용 · 배포 전 확인용): 원문 항목 수와 이 판이 읽어 낸 항목 수가 같은지. 대표님 금고는 사본 폴더로만 연다.
func vaultProbe(_ folder: String?) {
    guard let folder else { print("사용법: ReMONChecks vault-probe <금고 사본 폴더>"); failures += 1; return }
    let file = URL(fileURLWithPath: folder).appendingPathComponent("vault.json")
    let raw = (try? Data(contentsOf: file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] } ?? []
    let entries = RecoveryVault(folder: URL(fileURLWithPath: folder)).all()
    let byKind = Dictionary(grouping: entries, by: { "\($0.kind.rawValue)/\($0.status.rawValue)" }).mapValues(\.count).sorted { $0.key < $1.key }
    print("원문 항목 \(raw.count)개 · 읽음 \(entries.count)개 · " + byKind.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
    check(raw.count == entries.count, "금고 항목을 모두 이 판의 형식으로 읽음(모르는 항목 \(raw.count - entries.count)개)")
}
