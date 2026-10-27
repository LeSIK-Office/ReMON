import Foundation

/// 시스템 건강 점수: 100점에서 요인별로 깎는다. 깎인 이유마다 바로 할 수 있는 조치를 붙인다(보기만 하는 점수가 아니게).
public enum HealthScore {
    public enum Action: String, Sendable { case optimizeMemory, optimizeProcesses, optimizeStorage, reviewStartup, reviewHelpers }

    public struct Factor: Sendable, Identifiable, Equatable {
        public var id: String
        public var label: String
        public var penalty: Int
        public var detail: String
        public var action: Action?
    }

    public struct Result: Sendable, Equatable {
        public var score: Int
        public var factors: [Factor]
        public var grade: String {
            switch score {
            case 90...: "좋음"
            case 70..<90: "보통"
            case 50..<70: "주의"
            default: "위험"
            }
        }
    }

    public static func compute(system: SystemSnapshot, sessions: [AgentSession], orphanHelpers: Int, suspected: Int, crashLoops: Int) -> Result {
        var factors: [Factor] = []
        func gb(_ bytes: UInt64) -> String { String(format: "%.1fGB", Double(bytes) / 1_073_741_824) }
        let memory = system.memory
        switch system.pressure {
        case .critical: factors.append(Factor(id: "pressure", label: "메모리 압박 심각", penalty: 30, detail: "macOS가 메모리를 강하게 회수하는 중", action: .optimizeMemory))
        case .warning: factors.append(Factor(id: "pressure", label: "메모리 압박 주의", penalty: 15, detail: "여유 \(gb(memory.available))", action: .optimizeMemory))
        case .normal:
            if memory.physical > 0, Double(memory.available) / Double(memory.physical) < 0.12 {
                factors.append(Factor(id: "free", label: "메모리 여유 적음", penalty: 8, detail: "여유 \(gb(memory.available)) / \(gb(memory.physical))", action: .optimizeMemory))
            }
        }
        let swap = system.swap.used, gib = UInt64(1_073_741_824)
        if swap >= 4 * gib {
            factors.append(Factor(id: "swap", label: "스왑 사용", penalty: swap >= 20 * gib ? 22 : swap >= 10 * gib ? 15 : 8, detail: "\(gb(swap)) — 디스크를 메모리처럼 쓰는 중", action: .optimizeMemory))
        }
        let disk = system.disk
        if disk.total > 0 {
            let ratio = Double(disk.available) / Double(disk.total)
            if ratio < 0.05 || disk.available < 10 * gib {
                factors.append(Factor(id: "disk", label: "디스크 여유 매우 적음", penalty: 20, detail: "여유 \(gb(disk.available))", action: .optimizeStorage))
            } else if ratio < 0.10 || disk.available < 20 * gib {
                factors.append(Factor(id: "disk", label: "디스크 여유 적음", penalty: 10, detail: "여유 \(gb(disk.available))", action: .optimizeStorage))
            }
        }
        if system.thermal.available, system.thermal.cpuTemperature >= 90 {
            factors.append(Factor(id: "heat", label: "CPU 과열", penalty: system.thermal.cpuTemperature >= 100 ? 15 : 10,
                                  detail: String(format: "%.0f°C · 팬 %.0frpm", system.thermal.cpuTemperature, system.thermal.fanRPM), action: nil))
        }
        let leftovers = sessions.filter { $0.tabLeftover || $0.state == .orphan }
        if !leftovers.isEmpty {
            factors.append(Factor(id: "leftover", label: "탭 닫힘·고아 세션", penalty: min(15, leftovers.count * 3),
                                  detail: "\(leftovers.count)개 · \(gb(leftovers.reduce(0) { $0 + $1.footprint }))", action: .optimizeProcesses))
        }
        if orphanHelpers + suspected > 0 {
            factors.append(Factor(id: "helpers", label: "남은 보조 프로세스", penalty: min(9, orphanHelpers * 3) + min(6, suspected * 2),
                                  detail: "확인됨 \(orphanHelpers) · 추정 \(suspected)", action: .reviewHelpers))
        }
        if crashLoops > 0 {
            factors.append(Factor(id: "startup", label: "반복 크래시 시작 항목", penalty: min(10, crashLoops * 5), detail: "\(crashLoops)개 — launchd가 계속 다시 띄움", action: .reviewStartup))
        }
        let score = max(0, 100 - factors.reduce(0) { $0 + $1.penalty })
        return Result(score: score, factors: factors.sorted { $0.penalty > $1.penalty })
    }
}
