import Darwin
import Foundation

/// 진단 보고서(지원·문의용) — 사람이 붙여 넣을 텍스트. 경로는 ~로 줄이고 이름·비밀값은 가린다.
/// 세션 제목·명령 인자·파일 내용은 넣지 않는다(프로젝트 이름과 수치만).
public enum DiagnosticsReport {
    public struct Totals: Sendable, Equatable {
        public var sessionsRetired = 0
        public var sessionsRestorable = 0
        public var memoryBytes: UInt64 = 0
        public var diskBytes: UInt64 = 0
        public var restoredCount = 0
    }

    /// 복구 금고로 누적 정리량을 센다(세션 메모리 · 영구 삭제한 캐시 · 치운 워크트리).
    public static func totals(_ entries: [RecoveryEntry]) -> Totals {
        var totals = Totals()
        for entry in entries {
            switch entry.kind {
            case .session:
                guard entry.status != .retiring else { continue }
                totals.sessionsRetired += 1
                totals.memoryBytes += entry.bytes
                if entry.restorable { totals.sessionsRestorable += 1 }
            case .deleted, .worktree:
                totals.diskBytes += entry.bytes
            default:
                break
            }
            if entry.status == .restored { totals.restoredCount += 1 }
        }
        return totals
    }

    public static func build(system: SystemSnapshot, sessions: [AgentSession], processes: [ProcRecord], appVersion: String,
                             vault: [RecoveryEntry], actionsLog: URL, now: Date = Date()) -> String {
        var lines: [String] = []
        func gb(_ bytes: UInt64) -> String { String(format: "%.1fGB", Double(bytes) / 1_073_741_824) }
        lines.append("ReMON 진단 보고서 · \(ISO8601DateFormatter().string(from: now))")
        lines.append("ReMON \(appVersion) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(sysctlString("hw.model") ?? "?") · \(sysctlString("machdep.cpu.brand_string") ?? "?")")
        lines.append("가동 \(Int(ProcessInfo.processInfo.systemUptime / 3600))시간 · 전체 디스크 접근: \(fullDiskAccess.map { $0 ? "있음" : "없음" } ?? "확인 불가")")
        let memory = system.memory
        lines.append("메모리: 전체 \(gb(memory.physical)) · 여유 \(gb(memory.available)) · 압축 \(gb(memory.compressed)) · 압박 \(system.pressure.label) · 스왑 \(gb(system.swap.used))/\(gb(system.swap.total))")
        lines.append("디스크: 여유 \(gb(system.disk.available)) / 전체 \(gb(system.disk.total)) · 정리 가능 포함 여유 \(gb(system.disk.availableForImportantUsage))")
        if system.thermal.available { lines.append("열: CPU \(String(format: "%.0f", system.thermal.cpuTemperature))°C · 팬 \(system.thermal.fanCount)개 \(Int(system.thermal.fanRPM))rpm") }
        lines.append("CPU \(String(format: "%.0f", system.cpuPercent))% · 코어 \(system.coreCount)")
        lines.append("")
        let byKind = Dictionary(grouping: sessions, by: \.kind)
        lines.append("에이전트 세션 \(sessions.count)개: " + byKind.map { kind, list in "\(kind.label) \(list.count)" }.sorted().joined(separator: " · "))
        let byState = Dictionary(grouping: sessions, by: \.state)
        lines.append("상태: " + SessionState.allCases.compactMap { state in byState[state].map { "\(state.label) \($0.count)" } }.joined(separator: " · "))
        let leftovers = sessions.filter(\.tabLeftover).count
        if leftovers > 0 { lines.append("탭 닫힌 세션 \(leftovers)개") }
        lines.append("메모리 상위 프로세스:")
        for record in processes.sorted(by: { $0.footprint > $1.footprint }).prefix(8) {
            lines.append("  \(record.displayName) · \(gb(record.footprint)) · CPU \(String(format: "%.0f", record.cpuPercent))%")
        }
        lines.append("")
        let totals = totals(vault)
        lines.append("복구 금고: 세션 정리 \(totals.sessionsRetired)개(복귀 가능 \(totals.sessionsRestorable)) · 메모리 \(gb(totals.memoryBytes)) · 디스크 \(gb(totals.diskBytes)) · 되돌림 \(totals.restoredCount)건")
        lines.append("최근 행동(최대 15건):")
        for line in recentActions(actionsLog, limit: 15) { lines.append("  " + line) }
        return lines.map { Redactor.redact($0.replacingOccurrences(of: NSHomeDirectory(), with: "~")) }.joined(separator: "\n")
    }

    /// 전체 디스크 접근: 보호 폴더(Safari·Mail·Messages·시스템 TCC)를 열어 본다. 권한에 막히면 없음, 열리면 있음, 모두 없으면 확인 불가.
    /// (사용자 TCC.db는 macOS 26에서 그 자리에 없다 — 10-25 실측 ENOENT)
    public static var fullDiskAccess: Bool? {
        let candidates = ["/Library/Safari", "/Library/Mail", "/Library/Messages"].map { NSHomeDirectory() + $0 } + ["/Library/Application Support/com.apple.TCC"]
        var sawDenied = false
        for path in candidates {
            guard let directory = opendir(path) else {
                if errno == EPERM || errno == EACCES { sawDenied = true }
                continue
            }
            closedir(directory)
            return true
        }
        return sawDenied ? false : nil
    }

    static func recentActions(_ url: URL, limit: Int) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 64_000 ? size - 64_000 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n").suffix(limit).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            let time = (object["time"] as? String).map { String($0.prefix(16)) } ?? "?"
            // 대상·상세 결과에는 세션 제목이나 명령 인자가 들어갈 수 있어 지원용 보고서에는 상태만 싣는다.
            let raw = (object["result"] as? String ?? "").split(whereSeparator: { $0 == ":" || $0.isWhitespace }).first.map(String.init) ?? ""
            let result = ["ok", "dry-run", "blocked", "skipped", "failed", "error", "partial", "refused", "already-gone"].contains(raw) ? raw : "기록됨"
            let dry = (object["dryRun"] as? Bool) == true ? " (드라이런)" : ""
            return "\(time) \(object["action"] as? String ?? "?") · \(result)\(dry)"
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
