import ReMONCore
import SwiftUI

/// 정리 화면의 AI 데이터 위생 구역: Claude 기록(프로젝트 폴더 소실 · 오래됨) · Codex 스레드 · AI 앱 캐시 · 이전 CLI 버전.
/// 그룹마다 크기와 남기는 이유를 보이고, 버튼은 AppModel 확장(AIDataActions)을 부른다. 확인은 묶음마다 한 번이다.
struct AIDataSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: AIDataStore
    /// 펼친 그룹(projectGone · stale · codex · caches · versions)
    @State private var expanded: Set<String>

    @MainActor
    init(model: AppModel, store: AIDataStore? = nil, expanded: Set<String> = []) {
        self.model = model
        self.store = store ?? .shared
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        let report = store.report
        CleanupBox(title: "AI 데이터 위생" + (report.map { headline($0) } ?? ""), hint: "실행 중 · 복구함 보관 · 24시간 안에 바뀐 것은 건드리지 않습니다") {
            HStack(spacing: 6) {
                if store.scanning || store.working { ProgressView().controlSize(.small) }
                else if let note = store.note { Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
                Menu("기준 \(Int(store.staleDays))일") {
                    ForEach([30, 60, 90, 180], id: \.self) { days in
                        Button("\(days)일 넘게 활동 없음") { store.staleDays = Double(days); if store.report != nil { model.scanAIData() } }
                    }
                }
                .fixedSize()
                .help("Claude 기록 · Codex 스레드를 '오래됨'으로 보는 기준")
                Button(report == nil ? "조사" : "다시 조사") { model.scanAIData() }.disabled(store.scanning || store.working)
            }
            .controlSize(.small)
        } content: {
            if let report {
                VStack(spacing: 4) {
                    transcriptGroup(report, .projectGone)
                    transcriptGroup(report, .stale)
                    codexGroup(report)
                    cacheGroup(report)
                    versionGroup(report)
                }
                Text("조사 \(Fmt.ago(report.scannedAt)) · Claude 기록 \(report.transcriptCount)개 \(Fmt.gb(report.transcriptBytes)) · Codex 스레드 \(report.codex.totalThreads)개(보관 \(report.codex.archivedThreads))")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else {
                Text("아직 조사하지 않았습니다. '조사'를 누르면 Claude 기록 · Codex 스레드 · AI 앱 캐시 · 이전 CLI 버전을 읽기 전용으로 살펴봅니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        // 읽기 전용 조사(수 초)라 정리 화면을 열면 한 번 바로 살펴본다(디스크 조사와 같은 방식).
        .onAppear { if store.report == nil && !store.scanning { model.scanAIData() } }
    }

    private func headline(_ report: AIDataReport) -> String {
        let transcripts = report.transcripts.filter(\.selectable), caches = report.caches.filter(\.selectable), versions = report.versions.filter(\.selectable)
        let count = transcripts.count + report.codex.threads.filter(\.selectable).count + caches.count + versions.count
        let bytes = transcripts.reduce(UInt64(0)) { $0 + $1.bytes } + caches.reduce(UInt64(0)) { $0 + $1.bytes } + versions.reduce(UInt64(0)) { $0 + $1.bytes }
        return count == 0 ? " · 정리할 것 없음" : " · 정리 가능 \(count)개 · \(Fmt.gb(bytes))"
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    // MARK: Claude 기록

    @ViewBuilder
    private func transcriptGroup(_ report: AIDataReport, _ group: ClaudeTranscript.Group) -> some View {
        let items: [ClaudeTranscript] = report.transcripts(in: group)
        let ready: [ClaudeTranscript] = items.filter(\.selectable)
        let gone = group == .projectGone
        let title: String = gone ? "Claude 기록 · 프로젝트 폴더 소실" : "Claude 기록 · 오래됨 \(Int(report.options.staleDays))일+"
        let line: String = summary(ready.count, total(ready.map(\.bytes)), kept: items.count - ready.count)
        AIDataGroupRow(icon: gone ? "folder.badge.questionmark" : "clock.arrow.circlepath", title: title, summary: line,
                       expanded: expanded.contains(group.rawValue), toggle: { toggle(group.rawValue) }) {
            TranscriptActions(model: model, ready: ready, title: title, working: store.working)
        } rows: {
            if items.isEmpty { emptyLine(gone ? "작업 폴더가 사라진 기록이 없습니다." : "오래된 기록이 없습니다.") }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(items.prefix(40)) { item in TranscriptRow(model: model, item: item) }
            }
            more(items.count, shown: 40)
        }
    }

    // MARK: Codex 스레드

    @ViewBuilder
    private func codexGroup(_ report: AIDataReport) -> some View {
        let codex: CodexThreadReport = report.codex
        let ready: [CodexThread] = codex.threads.filter(\.selectable)
        let kept = codex.threads.count - ready.count
        let line: String = "보관 가능 \(ready.count)개" + (kept > 0 ? " · 남김 \(kept)" : "")
        let notes: [String] = [codex.schemaNote, codex.cliNote ?? ""].filter { !$0.isEmpty }
        let help: String = codex.actionBlock ?? "codex archive로 목록에서 내립니다 · 복구함에서 codex unarchive로 되돌립니다"
        AIDataGroupRow(icon: "archivebox", title: "Codex 스레드 · 오래됨 \(Int(report.options.staleDays))일+", summary: line,
                       expanded: expanded.contains("codex"), toggle: { toggle("codex") }) {
            Button("보관(archive)") { model.archiveCodexThreads(ready) }
                .disabled(!codex.canAct || ready.isEmpty || store.working)
                .help(help)
        } rows: {
            Text(notes.joined(separator: " · ") + " · 대화는 지우지 않고 Codex 목록에서만 내립니다")
                .font(.system(size: 10.5)).foregroundStyle(codex.canAct ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
            if codex.threads.isEmpty { emptyLine("오래된 스레드가 없습니다.") }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(codex.threads.prefix(40)) { thread in CodexThreadRow(thread: thread) }
            }
            more(codex.threads.count, shown: 40)
        }
    }

    // MARK: AI 앱 캐시

    @ViewBuilder
    private func cacheGroup(_ report: AIDataReport) -> some View {
        let caches: [AIAppCache] = report.caches
        let ready: [AIAppCache] = caches.filter(\.selectable)
        let line: String = summary(ready.count, total(ready.map(\.bytes)), kept: caches.count - ready.count, unit: "곳")
        AIDataGroupRow(icon: "sparkles", title: "AI 앱 캐시", summary: line, expanded: expanded.contains("caches"), toggle: { toggle("caches") }) {
            Button("캐시 비우기") { model.clearAIAppCaches(ready) }.disabled(ready.isEmpty || store.working)
                .help("앱이 꺼진 순수 캐시만 영구 삭제합니다(다시 열면 새로 만듭니다)")
        } rows: {
            if caches.isEmpty { emptyLine("AI 앱 캐시가 없습니다.") }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(caches.prefix(24)) { item in AppCacheRow(model: model, item: item) }
            }
            more(caches.count, shown: 24)
        }
    }

    // MARK: 이전 CLI 버전

    @ViewBuilder
    private func versionGroup(_ report: AIDataReport) -> some View {
        let versions: [CLIVersion] = report.versions
        let ready: [CLIVersion] = versions.filter(\.selectable)
        let line: String = summary(ready.count, total(ready.map(\.bytes)), kept: versions.count - ready.count)
        AIDataGroupRow(icon: "shippingbox", title: "이전 CLI 버전", summary: line, expanded: expanded.contains("versions"), toggle: { toggle("versions") }) {
            Button("이전 버전 지우기") { model.deleteOldCLIVersions(ready) }.disabled(ready.isEmpty || store.working)
                .help("현재가 아니고 아무 프로세스도 실행하지 않는 버전만 영구 삭제합니다")
        } rows: {
            if versions.isEmpty { emptyLine("설치된 버전 폴더가 없습니다.") }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                ForEach(versions) { item in CLIVersionRow(item: item) }
            }
        }
    }

    // MARK: 공통

    private func total(_ sizes: [UInt64]) -> UInt64 { sizes.reduce(0, +) }

    private func summary(_ count: Int, _ bytes: UInt64, kept: Int, unit: String = "개") -> String {
        "정리 가능 \(count)\(unit) · \(Fmt.gb(bytes))" + (kept > 0 ? " · 남김 \(kept)" : "")
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func more(_ total: Int, shown: Int) -> some View {
        if total > shown { Text("… 외 \(total - shown)개(버튼은 전체에 적용됩니다)").font(.system(size: 10.5)).foregroundStyle(.secondary) }
    }
}

/// 남김 · 이유 / 정리 가능.
struct AIDataStatusText: View {
    let keepReason: String?

    var body: some View {
        let text: String = keepReason.map { "남김 · " + $0 } ?? "정리 가능"
        Text(text).font(.system(size: 10.5)).foregroundStyle(keepReason == nil ? Color.green : Color.secondary)
            .lineLimit(1).help(keepReason ?? "고를 수 있습니다")
    }
}

/// Claude 기록 묶음 버튼: 외장 이전(기존 기능) · 휴지통.
struct TranscriptActions: View {
    @ObservedObject var model: AppModel
    let ready: [ClaudeTranscript]
    let title: String
    let working: Bool

    var body: some View {
        Menu("외장 이전") {
            let volumes = ExternalMigrator.externalVolumes()
            if volumes.isEmpty { Text("연결된 외장 볼륨이 없습니다") }
            ForEach(volumes, id: \.path) { volume in
                Button("\(volume.path) (\(volume.fsType))") { model.migrateTranscripts(ready, to: volume.path) }
            }
        }
        .fixedSize().disabled(ready.isEmpty || working)
        Button("휴지통으로") { model.trashTranscripts(ready, title: title) }.disabled(ready.isEmpty || working)
    }
}

struct TranscriptRow: View {
    @ObservedObject var model: AppModel
    let item: ClaudeTranscript

    var body: some View {
        let name: String = item.title ?? (item.isOrphanFolder ? "기록 없는 하위 폴더" : "제목 없음")
        let place: String = (item.cwd ?? "작업 폴더 모름") + "\n" + item.path + (item.note.map { "\n" + $0 } ?? "")
        var when: String = Fmt.ago(item.activity)
        if item.subagents > 0 { when += " · 하위 \(item.subagents)" }
        if item.compressed { when += " · 압축" }
        return GridRow {
            Text(item.project).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(place)
            Text(when).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            AIDataStatusText(keepReason: item.keepReason)
            Text(Fmt.size(item.bytes)).font(.system(size: 11, weight: .semibold).monospacedDigit()).gridColumnAlignment(.trailing)
            Button { model.revealInFinder(item.path) } label: { Image(systemName: "folder") }.controlSize(.mini).help("Finder에서 보기")
        }
    }
}

struct CodexThreadRow: View {
    let thread: CodexThread

    var body: some View {
        let when: String = Fmt.ago(thread.updatedAt) + (thread.children > 0 ? " · 하위 \(thread.children)" : "")
        let size: String = thread.rolloutBytes > 0 ? Fmt.size(thread.rolloutBytes) : "DB"
        let sizeHelp: String = thread.rolloutBytes > 0 ? "rollout 파일 크기" : "대화가 기록 DB 안에 있습니다(보관해도 공간은 그대로입니다)"
        return GridRow {
            Text(thread.project).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(thread.title ?? "제목 없음").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).help((thread.cwd ?? "") + "\n" + thread.id)
            Text(when).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            AIDataStatusText(keepReason: thread.keepReason)
            Text(size).font(.system(size: 11, weight: .semibold).monospacedDigit()).gridColumnAlignment(.trailing).help(sizeHelp)
        }
    }
}

struct AppCacheRow: View {
    @ObservedObject var model: AppModel
    let item: AIAppCache

    var body: some View {
        GridRow {
            Text(item.app).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(item.folder).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading).help(item.path)
            AIDataStatusText(keepReason: item.keepReason)
            Text(Fmt.size(item.bytes)).font(.system(size: 11, weight: .semibold).monospacedDigit()).gridColumnAlignment(.trailing)
            Button { model.revealInFinder(item.path) } label: { Image(systemName: "folder") }.controlSize(.mini).help("Finder에서 보기")
        }
    }
}

struct CLIVersionRow: View {
    let item: CLIVersion

    var body: some View {
        let name: String = item.version + (item.channel == "versions" ? "" : " · \(item.channel)")
        return GridRow {
            Text(item.tool).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(item.path)
            AIDataStatusText(keepReason: item.keepReason)
            Text(Fmt.size(item.bytes)).font(.system(size: 11, weight: .semibold).monospacedDigit()).gridColumnAlignment(.trailing)
        }
    }
}

/// 접고 펴는 한 그룹: 제목 · 요약 · 오른쪽 버튼 + 펼친 줄들.
struct AIDataGroupRow<Actions: View, Rows: View>: View {
    let icon: String
    let title: String
    let summary: String
    let expanded: Bool
    let toggle: () -> Void
    @ViewBuilder var actions: Actions
    @ViewBuilder var rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 12)
                        Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Text(summary).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                actions
            }
            .controlSize(.small)
            if expanded {
                VStack(alignment: .leading, spacing: 4) { rows }.padding(.leading, 20)
            }
        }
        .padding(.vertical, 3)
    }
}
