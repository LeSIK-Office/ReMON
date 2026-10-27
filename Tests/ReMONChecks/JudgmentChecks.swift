import Foundation
import ReMONCore

// 설계 감사(10-25) P0: 상태 판정의 증거 등급 · 압박 전환 히스테리시스 · 대화 끝 읽기. 합성 자료로만 본다.

func judgmentCheck() {
    // 1) 증거 등급: 레지스트리 상태 = 확인 · 기록 연결 추정·CPU 패턴 = 추정 · 부모 launchd = 확인
    let fake = FakeProcesses()
    let folder = NSTemporaryDirectory() + "remon-judgment-\(getpid())"
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let shell = fake.add("zsh", "/bin/zsh", ["-zsh"], cwd: "/Users/test/DEV/판정")
    let registered = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude"], parent: shell.pid, cwd: "/Users/test/DEV/판정")
    let orphanLike = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude"], parent: 1, cwd: "/Users/test/DEV/판정2", tty: false)
    let quiet = fake.add("claude", "/Users/u/.local/share/claude/versions/2.1.310", ["claude"], parent: shell.pid, cwd: "/Users/test/DEV/판정3")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC"); formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    let entry: [String: Any] = ["pid": Int(registered.pid), "sessionId": "11111111-1111-4111-8111-111111111111", "cwd": "/Users/test/DEV/판정", "kind": "interactive", "status": "busy",
                                "startedAt": Int(fake.started.timeIntervalSince1970 * 1000), "procStart": formatter.string(from: fake.started), "statusUpdatedAt": Int(Date().timeIntervalSince1970 * 1000)]
    FileManager.default.createFile(atPath: folder + "/\(registered.pid).json", contents: try? JSONSerialization.data(withJSONObject: entry))
    let detector = SessionDetector()
    detector.catalog = AgentCatalog(defaults: nil, initial: AgentCatalog.State())
    detector.claudeRegistry = ClaudeRegistry(directory: folder)
    let result = detector.detect(records: fake.records, sampler: fake, orca: [])
    func session(_ record: ProcRecord) -> AgentSession? { result.sessions.first { $0.rootPID == record.pid } }
    check(session(registered)?.state == .working && session(registered)?.stateConfidence == .confirmed, "레지스트리 busy → 일하는 중 · 확인 등급")
    check(session(orphanLike)?.state == .orphan && session(orphanLike)?.stateConfidence == .confirmed, "부모 launchd · 터미널 없음 → 고아 · 확인 등급(커널 사실)")
    check(session(quiet).map { $0.stateConfidence == .estimated && $0.state != .orphan } == true, "기록 없음 · CPU 0 → 추정 등급 · 고아 아님(\(session(quiet)?.state.label ?? "-"))")
    let estimated = AuditRules.localVerdict(state: .longIdle, idleMinutes: 500, memoryMB: 900, cpu: 0, pinned: false, blockers: [], confirmed: false)
    let confirmed = AuditRules.localVerdict(state: .longIdle, idleMinutes: 500, memoryMB: 900, cpu: 0, pinned: false, blockers: [], confirmed: true)
    check(estimated?.verdict == "keep" && confirmed == nil, "감사 규칙: 추정 상태의 오래 쉼은 유지, 확인 등급만 모델에 물음")

    // 2) 압박 전환 히스테리시스: 5분 유지된 변화만 · 위험은 바로
    var gate = PressureGate(hold: 300)
    let t0 = Date()
    check(gate.observe(.normal, now: t0) == nil && gate.observe(.warning, now: t0.addingTimeInterval(10)) == nil && gate.observe(.normal, now: t0.addingTimeInterval(20)) == nil,
          "10초 만에 되돌아온 전환은 알리지 않음")
    _ = gate.observe(.warning, now: t0.addingTimeInterval(60))
    let held = gate.observe(.warning, now: t0.addingTimeInterval(60 + 301))
    check(held.map { $0.from == .normal && $0.to == .warning } == true, "5분 유지된 '주의'만 전환으로 알림")
    let critical = gate.observe(.critical, now: t0.addingTimeInterval(400))
    check(critical.map { $0.to == .critical } == true, "'위험'은 바로 알림")

    // 3) 대화 끝 읽기(Claude · Codex)
    let claudeLog = folder + "/claude.jsonl"
    writeLines(claudeLog, [["type": "user", "message": ["content": "결제 모듈 리팩터링 마저 해 줘"]],
                           ["type": "assistant", "message": ["content": [["type": "text", "text": "리팩터링을 마쳤고 테스트 12개가 통과했습니다."]]]],
                           ["type": "user", "message": ["content": "<system-reminder>주입</system-reminder>"]]])
    let claude = TranscriptPeek.lastExchange(claudeLog, kind: .claudeCode)
    check(claude.request == "결제 모듈 리팩터링 마저 해 줘" && claude.reply?.hasPrefix("리팩터링을 마쳤고") == true, "Claude 기록 끝: 마지막 요청·답변(주입 글은 건너뜀)")
    let rollout = folder + "/rollout.jsonl"
    writeLines(rollout, [["type": "event_msg", "payload": ["type": "user_message", "message": "DWG 변환 이어서"]],
                         ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "변환기 절반까지 구현했습니다. 다음은 치수선입니다."]]]],
                         ["type": "event_msg", "payload": ["type": "token_count", "info": NSNull()]]])
    let codex = TranscriptPeek.lastExchange(rollout, kind: .codexCLI)
    check(codex.request == "DWG 변환 이어서" && codex.reply?.hasPrefix("변환기 절반까지") == true, "Codex 기록 끝: 마지막 요청·답변")
}
