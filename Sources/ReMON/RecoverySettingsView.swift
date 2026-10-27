import ReMONCore
import SwiftUI

// MARK: - 설정 > 정리·복구 탭
// 복구 금고: 세션은 이어 열기 키를 먼저 금고에 적은 뒤에만 정리하고, 파일은 휴지통 위치를, git 부산물은 커밋을 적어 되돌린다.
// 묶음·자동 정리(메모리·프로세스 최적화, 정리 제안, 감사 퇴출, 자동 메모리 정리)는 키가 확인된 세션만 다룬다.

struct RecoverySettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: Settings

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        let totals = model.recoveryTotals
        Form {
            Section("복구 금고") {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "shippingbox.and.arrow.backward").font(.system(size: 20)).foregroundStyle(.purple).frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("정리하기 전에 되돌릴 방법을 먼저 적어 둡니다").font(.system(size: 13, weight: .semibold))
                        Text("세션은 이어 열기 키와 대화 기록 보관본을, 휴지통은 옮긴 위치를, 워크트리·브랜치는 커밋을 금고에 적습니다. 금고에 적지 못하면 정리하지 않습니다.")
                            .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                Stepper(value: $settings.recoveryRetentionDays, in: 7...180, step: 1) {
                    Text("세션 보관 기간 \(Int(settings.recoveryRetentionDays))일")
                }
                Text("기간이 지나면 대화 기록 보관본을 지우고 '만료'로 바꿉니다. Claude Code는 기본으로 30일 지난 기록을 스스로 지웁니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent("누적 정리") {
                    Text("세션 \(totals.sessionsRetired)개(복귀 가능 \(totals.sessionsRestorable)) · 메모리 \(Fmt.gb(totals.memoryBytes)) · 디스크 \(Fmt.gb(totals.diskBytes)) · 되돌림 \(totals.restoredCount)건")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack {
                    Button("복구함 열기") { model.page = .cleanup; (NSApp.delegate as? AppDelegate)?.openOffice() }
                    Button("금고 폴더 보기") { NSWorkspace.shared.activateFileViewerSelecting([model.vault.fileURL]) }
                    Spacer()
                }
            }
            Section("자동 정리 정책") {
                Toggle("메모리 경고 때 정리 가능한 세션 알림(자동으로 끄지 않음)", isOn: $settings.autoMemoryCleanup)
                Toggle("드라이런(실행 없이 결과만 기록)", isOn: $settings.dryRun)
                VStack(alignment: .leading, spacing: 4) {
                    Label("세션을 끝내는 결정은 항상 사람이 합니다 — 묶음 정리는 목록을 확인한 뒤, 이어 열기 키와 '확인' 등급 상태가 있는 세션만", systemImage: "checkmark.shield")
                    Label("일하는 중 · 입력 대기 · 보호 고정 세션은 정리하지 않습니다", systemImage: "hand.raised")
                    Label("키를 모르는 에이전트(표·직접 추가)와 Codex 공유 데몬 클라이언트는 세션 카드에서 하나씩, 경고를 확인한 뒤에만 정리합니다", systemImage: "exclamationmark.triangle")
                    Label("영구 삭제는 다시 생기는 캐시만 — 나머지는 휴지통(되돌리기 가능)", systemImage: "trash")
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 600)
    }
}
