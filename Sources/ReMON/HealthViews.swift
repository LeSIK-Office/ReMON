import ReMONCore
import SwiftUI

// 건강 점수 카드(대시보드 맨 위). 시작 항목은 10분에 한 번만 조사한다(launchctl 호출이 있어서).

@MainActor
private enum HealthCache {
    static var crashLoops = 0
    static var scannedAt = Date.distantPast
    static var scanning = false
}

extension AppModel {
    var health: HealthScore.Result {
        if !HealthCache.scanning, Date().timeIntervalSince(HealthCache.scannedAt) > 600 {
            HealthCache.scanning = true
            DispatchQueue.global(qos: .utility).async {
                let loops = StartupItemScanner().scan().filter(\.crashLoop).count
                DispatchQueue.main.async { HealthCache.crashLoops = loops; HealthCache.scannedAt = Date(); HealthCache.scanning = false }
            }
        }
        return HealthScore.compute(system: system, sessions: office?.sessions ?? [], orphanHelpers: orphanHelpers.count,
                                   suspected: suspectedOrphans.count, crashLoops: HealthCache.crashLoops)
    }

    func perform(_ action: HealthScore.Action) {
        switch action {
        case .optimizeMemory: optimizeMemory()
        case .optimizeProcesses: optimizeProcesses()
        case .optimizeStorage: optimizeStorage()
        case .reviewStartup, .reviewHelpers: page = .cleanup
        }
    }
}

struct HealthCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let health = model.health
        let color: Color = health.score >= 90 ? .green : health.score >= 70 ? .yellow : health.score >= 50 ? .orange : .red
        CardBox(accent: color) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().stroke(color.opacity(0.18), lineWidth: 8)
                    Circle().trim(from: 0, to: CGFloat(health.score) / 100).stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(health.score)").font(.system(size: 26, weight: .bold).monospacedDigit())
                        Text(health.grade).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
                    }
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 6) {
                    if health.factors.isEmpty {
                        Text("깎인 점수가 없습니다. 메모리·스왑·디스크·열·남은 세션 모두 괜찮습니다.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    ForEach(health.factors) { factor in
                        HStack(spacing: 8) {
                            Text("−\(factor.penalty)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(color).frame(width: 30, alignment: .trailing)
                            Text(factor.label).font(.system(size: 12, weight: .semibold))
                            Text(factor.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            Spacer(minLength: 4)
                            if let action = factor.action {
                                Button(actionTitle(action)) { model.perform(action) }.controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    private func actionTitle(_ action: HealthScore.Action) -> String {
        switch action {
        case .optimizeMemory: "메모리 최적화"
        case .optimizeProcesses: "프로세스 최적화"
        case .optimizeStorage: "저장소 정리"
        case .reviewStartup: "시작 항목 보기"
        case .reviewHelpers: "보조 프로세스 보기"
        }
    }
}
