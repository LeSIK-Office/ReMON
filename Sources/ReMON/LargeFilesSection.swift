import ReMONCore
import SwiftUI

/// 정리 화면의 큰 파일·폴더 구역: 홈 폴더(~/Library·클라우드 제외)에서 실제 할당량이 큰 것을 찾아 보여 준다.
/// 동작은 Finder에서 보기와 휴지통(복구함 기록)뿐이고, 홈 최상위 폴더와 앱이 관리하는 데이터는 고를 수 없다.
struct LargeFilesSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = DiskToolsStore.shared
    @State private var showFolders = false

    var body: some View {
        let report = store.largeReport
        let entries = showFolders ? (report?.folders ?? []) : (report?.files ?? [])
        let chosen = ((report?.files ?? []) + (report?.folders ?? [])).filter { store.largeSelection.contains($0.path) }
        CleanupBox(title: "큰 파일·폴더", hint: "홈 폴더만 · ~/Library·클라우드 제외 · Finder 보기와 휴지통만") {
            HStack(spacing: 6) {
                if store.largeScanning {
                    ProgressView().controlSize(.small)
                    Text("파일 \(store.largeProgressFiles.formatted())개 · \(Fmt.gb(store.largeProgressBytes))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                    Button("취소") { model.cancelLargeFiles() }
                } else {
                    Button(report == nil ? "찾기" : "다시 찾기") { model.scanLargeFiles() }
                }
                Button { model.trashLargeEntries(chosen) } label: { Label("선택 휴지통 \(chosen.count)개", systemImage: "trash") }
                    .disabled(chosen.isEmpty || store.largeScanning)
            }
            .controlSize(.small)
        } content: {
            if let report {
                HStack {
                    Picker("", selection: $showFolders) {
                        Text("파일 \(report.files.count)").tag(false)
                        Text("폴더 \(report.folders.count)").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Spacer()
                    Text(String(format: "파일 %@개 · 폴더 %@개 · %@ · %.1f초", report.scannedFiles.formatted(), report.scannedFolders.formatted(), Fmt.gb(report.scannedBytes), report.elapsed) +
                         (report.cancelled ? " · 중간에 멈춤" : ""))
                        .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                }
                if entries.isEmpty {
                    Text(showFolders ? "200MB 넘는 폴더가 없습니다." : "50MB 넘는 파일이 없습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(entries.prefix(30)) { entry in LargeEntryRow(model: model, entry: entry) }
                }
                Text("APFS 복제본은 블록을 함께 쓰므로 합계가 실제 사용량보다 클 수 있습니다(하드링크는 한 번만 셉니다). 휴지통으로 옮긴 것은 복구함에서 되돌릴 수 있습니다.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if !store.largeScanning {
                Text("'찾기'를 누르면 홈 폴더를 읽기 전용으로 훑어 큰 파일과 폴더를 보여 줍니다(언제든 취소할 수 있습니다).")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LargeEntryRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store = DiskToolsStore.shared
    let entry: LargeFileFinder.Entry

    var body: some View {
        GridRow {
            Toggle("", isOn: Binding(get: { store.largeSelection.contains(entry.path) },
                                     set: { if $0 { store.largeSelection.insert(entry.path) } else { store.largeSelection.remove(entry.path) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(entry.refusal != nil)
            Image(systemName: entry.isDirectory ? "folder" : "doc").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(entry.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).help(entry.path)
            Text(entry.refusal ?? Fmt.ago(entry.modified)).font(.system(size: 10.5)).foregroundStyle(entry.refusal == nil ? Color.secondary : Color.orange).lineLimit(1)
            Text(Fmt.size(entry.bytes)).font(.system(size: 11, weight: .semibold).monospacedDigit()).gridColumnAlignment(.trailing)
            Button { model.revealInFinder(entry.path) } label: { Image(systemName: "magnifyingglass") }.controlSize(.small).help("Finder에서 보기")
        }
    }
}
