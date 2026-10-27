import Foundation

/// 감사의 규칙 판정(모델에 묻기 전에 정해지는 것). 앱(AuditRunner)과 시험이 같은 함수를 쓴다.
public enum AuditRules {
    public struct Verdict: Sendable, Equatable {
        public var verdict: String
        public var reason: String
    }

    /// nil이면 규칙으로 정할 수 없어 모델에 묻는다(2시간 넘게 쉰 · 확인 등급 세션만 여기 온다).
    public static func localVerdict(state: SessionState, idleMinutes: Int, memoryMB: Int, cpu: Int, pinned: Bool, blockers: [String], confirmed: Bool) -> Verdict? {
        let memory = memoryMB >= 1024 ? String(format: "%.1fGB", Double(memoryMB) / 1024) : "\(memoryMB)MB"
        let idle = idleMinutes >= 1440 ? "\(idleMinutes / 1440)일" : idleMinutes >= 60 ? "\(idleMinutes / 60)시간" : "\(idleMinutes)분"
        if state == .working { return Verdict(verdict: "praise", reason: "일하는 중 · CPU \(cpu)% · \(memory)") }
        if state == .waiting { return Verdict(verdict: "keep", reason: "입력 대기 \(idle) · \(memory)") }
        if pinned { return Verdict(verdict: "keep", reason: "보호 고정 · \(memory)") }
        if let blocker = blockers.first { return Verdict(verdict: "keep", reason: blocker) }
        // 추정 상태(기록 연결 추정·CPU 패턴)는 퇴출·재교육 근거가 못 된다 → 유지.
        if !confirmed { return Verdict(verdict: "keep", reason: "상태가 추정이라 유지 · \(idle) 쉼") }
        if state == .orphan { return Verdict(verdict: "evict", reason: "고아 · \(idle) 쉼 · \(memory)") }
        if idleMinutes < 120 { return Verdict(verdict: "keep", reason: "\(idle) 쉼 · 아직 짧음") }
        return nil
    }
}
