import ReMONCore
import SwiftUI

/// 정리 화면의 '시스템 데이터' 해설: macOS 저장 공간 막대에서 정체가 안 보이는 덩어리(정리 가능 공간 · 스냅샷 ·
/// 가상 머신 디스크 · iOS 백업 · iCloud 로컬 사본)를 보기만 하고, Docker가 돌면 docker system df와 prune(확인 후)을 보여 준다.
struct SystemDataSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = DiskToolsStore.shared

    var body: some View {
        let report = store.systemData
        CleanupBox(title: "시스템 데이터 해설" + (report.map { " · 정리 가능 \(Fmt.gb($0.space.purgeable)) · 보기만 \(Fmt.gb($0.holderBytes))" } ?? ""),
                   hint: "보기만 합니다 — 각 앱·시스템 설정에서 관리합니다") {
            HStack(spacing: 6) {
                if store.systemDataLoading { ProgressView().controlSize(.small) }
                else if let report { Text("\(Fmt.ago(report.at)) 조사").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                Button(report == nil ? "조사" : "다시 조사") { model.refreshSystemData() }.disabled(store.systemDataLoading)
            }
            .controlSize(.small)
        } content: {
            if let report {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("정리 가능 공간").font(.system(size: 12, weight: .semibold))
                        Text(Fmt.gb(report.space.purgeable)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                        Text("macOS가 공간이 필요할 때 스스로 비우는 캐시·스냅샷입니다 · 여유 \(Fmt.gb(report.space.available)) + 정리 가능 = \(Fmt.gb(report.space.importantAvailable))")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                        Text("")
                    }
                    GridRow {
                        Text("로컬 스냅샷").font(.system(size: 12, weight: .semibold))
                        Text(report.snapshots.count.map { "\($0)개" } ?? "확인 안 됨").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        Text(snapshotText(report.snapshots)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                            .help(report.snapshots.names?.joined(separator: "\n") ?? "")
                        Text("")
                    }
                    ForEach(report.holders) { holder in
                        GridRow {
                            Text(holder.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Text(holder.permissionNeeded ? "권한 필요" : (holder.complete ? "" : "≥ ") + Fmt.size(holder.bytes)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .help(holder.complete ? "" : "시간 제한으로 일부만 셌습니다(실제는 더 큽니다)")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(holder.manage).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                                Text(holder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + (holder.logical.map { " · 겉 크기 \(Fmt.size($0))" } ?? ""))
                                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                            }
                            Button { model.revealInFinder(holder.path) } label: { Image(systemName: "folder") }.controlSize(.small).help("Finder에서 보기")
                        }
                    }
                }
                Divider()
                dockerBlock(report.docker)
            } else {
                Text("'조사'를 누르면 정리 가능 공간 · 로컬 스냅샷 · 가상 머신 디스크 · iOS 백업 · iCloud 로컬 사본의 크기를 읽기 전용으로 봅니다. 아무것도 지우지 않습니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func snapshotText(_ info: SnapshotInfo) -> String {
        guard let count = info.count else { return info.note ?? "목록을 읽지 못했습니다" }
        if count == 0 { return "로컬 스냅샷이 없습니다" }
        return "Time Machine \(info.timeMachine)개 · OS 업데이트 \(info.osUpdate)개 — macOS가 공간이 부족하면 스스로 지웁니다(ReMON은 지우지 않음)"
    }

    @ViewBuilder
    private func dockerBlock(_ docker: DockerStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Docker").font(.system(size: 12, weight: .semibold))
                Text(docker.engine.map { "\($0) 실행 중" } ?? "실행 중이 아닙니다 — 디스크 이미지 크기만 위에 보입니다").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                if store.commandRunning == ToolCommands.dockerPrune.id { ProgressView().controlSize(.small) }
                Button("docker system prune") { model.dockerPrune() }
                    .controlSize(.small).disabled(!docker.running || docker.cli == nil || store.commandRunning != nil)
                    .help(ToolCommands.dockerPrune.detail)
            }
            if let error = docker.error { Text(error).font(.system(size: 10.5)).foregroundStyle(.orange) }
            if !docker.usage.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    GridRow {
                        ForEach(["종류", "개수", "사용 중", "크기", "회수 가능"], id: \.self) { Text($0).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
                    }
                    ForEach(docker.usage) { row in
                        GridRow {
                            Text(row.type).font(.system(size: 11))
                            Text(row.total).font(.system(size: 11).monospacedDigit())
                            Text(row.active).font(.system(size: 11).monospacedDigit())
                            Text(row.size).font(.system(size: 11).monospacedDigit())
                            Text(row.reclaimable).font(.system(size: 11).monospacedDigit())
                        }
                    }
                }
                .padding(.leading, 20)
            }
            if let output = store.commandOutput[ToolCommands.dockerPrune.id] {
                Text(output).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(6)
            }
        }
    }
}
