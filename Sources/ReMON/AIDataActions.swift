import AppKit
import ReMONCore

/// AI 데이터 위생 화면 상태. AppModel 확장에는 저장 속성을 둘 수 없어 따로 둔다(정리 화면 AIDataSection이 지켜본다).
@MainActor
final class AIDataStore: ObservableObject {
    static let shared = AIDataStore()

    @Published var report: AIDataReport?
    @Published var scanning = false
    /// 정리 실행 중(버튼 잠금)
    @Published var working = false
    @Published var note: String?
    /// '오래됨' 기준 일수(Claude 기록 · Codex 스레드)
    @Published var staleDays: Double { didSet { UserDefaults.standard.set(staleDays, forKey: "aiDataStaleDays") } }

    init() {
        staleDays = UserDefaults.standard.object(forKey: "aiDataStaleDays") as? Double ?? 60
    }

    var options: AIDataOptions { AIDataOptions(staleDays: staleDays) }
}

// AI 데이터 위생 실행. 확인은 묶음마다 한 번, 드라이런 설정을 따르고, 항목마다 직전에 다시 확인한다(AIDataCleaner).
extension AppModel {
    var aiData: AIDataStore { .shared }

    /// 세션 조사 전에는 '실행 중' 판정이 비어 정리하면 안 된다.
    private var aiDataReady: Bool { office != nil }

    /// 메인에서 세션·복구함·레지스트리를 모으고, 프로세스는 부르는 쪽(백그라운드)에서 새로 잰다.
    private func aiDataInputs() -> (sessions: [AgentSession], vault: [RecoveryEntry], registry: [Int32: ClaudeRegistryEntry]) {
        (office?.sessions ?? [], vault.all(), claudeRegistry.load())
    }

    nonisolated private static func context(_ inputs: (sessions: [AgentSession], vault: [RecoveryEntry], registry: [Int32: ClaudeRegistryEntry])) -> AIDataContext {
        AIDataContext.live(sessions: inputs.sessions, processes: ProcessSampler().sample(), vaultEntries: inputs.vault, registry: inputs.registry)
    }

    // MARK: 조사

    /// 읽기 전용 조사(수 초). 끝나면 정리 화면이 그룹·크기·남기는 이유를 그린다.
    func scanAIData() {
        guard !aiData.scanning else { return }
        guard aiDataReady else { aiData.note = "세션 조사가 끝나면 다시 눌러 주세요"; return }
        aiData.scanning = true
        let inputs = aiDataInputs()
        let options = aiData.options
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = AIDataScanner.scan(paths: AIDataPaths(), options: options, context: AppModel.context(inputs), codexCLI: CodexCLI.locate())
            DispatchQueue.main.async {
                guard let self else { return }
                self.aiData.report = report
                self.aiData.scanning = false
                let selectable = report.transcripts.filter(\.selectable).count + report.codex.threads.filter(\.selectable).count
                    + report.caches.filter(\.selectable).count + report.versions.filter(\.selectable).count
                self.aiData.note = String(format: "%.1f초 · 정리 가능 %d개", report.elapsed, selectable)
            }
        }
    }

    // MARK: Claude 기록

    /// 휴지통으로(확인 한 번). 원래 자리·휴지통 위치를 복구함에 적어 되돌린다.
    func trashTranscripts(_ items: [ClaudeTranscript], title: String) {
        let targets = items.filter(\.selectable)
        guard let report = aiData.report, !targets.isEmpty else { Confirm.info(title: "옮길 기록이 없습니다", text: "실행 중 · 복구함 보관 · 24시간 안에 바뀐 기록은 고를 수 없습니다."); return }
        let bytes = targets.reduce(UInt64(0)) { $0 + $1.bytes }
        var text = targets.prefix(12).map { "• \($0.project) · \($0.title ?? "제목 없음") · \(Fmt.ago($0.activity)) · \(Fmt.size($0.bytes))" }.joined(separator: "\n")
        if targets.count > 12 { text += "\n… 외 \(targets.count - 12)개" }
        text += "\n\n기록과 하위 폴더(subagents·tool-results)를 휴지통으로 옮깁니다(비우지 않음). 복구함에서 원래 자리로 되돌립니다. 영구 삭제는 하지 않습니다."
        text += settings.dryRun ? "\n드라이런: 옮기지 않고 결과만 기록합니다." : ""
        guard Confirm.ask(title: "\(title) · \(targets.count)개 · \(Fmt.gb(bytes))", text: text, action: settings.dryRun ? "드라이런" : "휴지통으로") else { return }
        let options = report.options, dryRun = settings.dryRun, vault = self.vault
        runAIData(title: "Claude 기록 휴지통", dryRun: dryRun) { context in
            AIDataCleaner.trashTranscripts(targets, paths: AIDataPaths(), options: options, context: context, vault: vault, dryRun: dryRun)
        }
    }

    /// 외장 이전(기존 기능): 파일 수·크기가 맞을 때만 원본을 지우고 링크를 남긴다(외장 이전 기록에서 되돌림).
    func migrateTranscripts(_ items: [ClaudeTranscript], to volume: String) {
        let targets = items.filter(\.selectable)
        guard let report = aiData.report, !targets.isEmpty else { return }
        let bytes = targets.reduce(UInt64(0)) { $0 + $1.bytes }
        let type = ExternalMigrator.filesystemType(volume)
        let text = "\(targets.count)개 기록(하위 폴더 포함) → \(volume) (\(type))\n\n파일 수·크기가 일치할 때만 원본을 지우고 원래 자리에 링크를 남깁니다. 외장 이전 기록에서 되돌립니다."
            + (settings.dryRun ? "\n\n드라이런: 옮기지 않고 결과만 기록합니다." : "")
        guard Confirm.ask(title: "Claude 기록 외장 이전 · \(targets.count)개 · \(Fmt.gb(bytes))", text: text, action: settings.dryRun ? "드라이런" : "옮기기") else { return }
        let options = report.options, dryRun = settings.dryRun, migrator = self.migrator
        runAIData(title: "Claude 기록 외장 이전", dryRun: dryRun, tidy: false) { context in
            targets.map { item in
                let label = item.title ?? String(item.sessionID.prefix(8))
                guard let fresh = ClaudeTranscriptScanner.refresh(item, options: options, context: context), fresh.selectable else {
                    return AIDataResult(target: label, ok: false, skipped: true, bytes: 0, message: "다시 확인하니 정리 대상이 아닙니다")
                }
                do {
                    for path in [item.path] + (item.companion.map { $0 == item.path ? [] : [$0] } ?? []) {
                        _ = try migrator.migrate(source: path, toVolume: volume, userPIDs: context.userPIDs, dryRun: dryRun)
                    }
                    return AIDataResult(target: label, ok: true, skipped: false, bytes: item.bytes, message: dryRun ? "드라이런 · 이전 예정" : "외장 이전")
                } catch {
                    return AIDataResult(target: label, ok: false, skipped: false, bytes: 0, message: "\(error)")
                }
            }
        }
    }

    // MARK: Codex 스레드

    /// Codex 자체 보관(`codex archive`). 스레드마다 금고에 `codex unarchive <id>`를 먼저 적는다.
    func archiveCodexThreads(_ threads: [CodexThread]) {
        guard let report = aiData.report else { return }
        guard report.codex.canAct else { Confirm.info(title: "보관할 수 없습니다", text: report.codex.actionBlock ?? "Codex 상태를 확인하지 못했습니다"); return }
        let targets = threads.filter(\.selectable)
        guard !targets.isEmpty else { Confirm.info(title: "보관할 스레드가 없습니다", text: "고정 · 실행 중 · 24시간 안에 바뀐 스레드는 고를 수 없습니다."); return }
        var text = targets.prefix(12).map { "• \($0.project) · \($0.title ?? "제목 없음") · \(Fmt.ago($0.updatedAt))" }.joined(separator: "\n")
        if targets.count > 12 { text += "\n… 외 \(targets.count - 12)개" }
        text += "\n\nCodex 자체 보관(codex archive)으로 스레드 목록에서 내립니다. 대화는 지우지 않고, 복구함에서 codex unarchive로 되돌립니다."
        text += settings.dryRun ? "\n드라이런: 보관하지 않고 결과만 기록합니다." : ""
        guard Confirm.ask(title: "Codex 스레드 보관 · \(targets.count)개", text: text, action: settings.dryRun ? "드라이런" : "보관하기") else { return }
        let options = report.options, dryRun = settings.dryRun, vault = self.vault, codex = report.codex
        runAIData(title: "Codex 스레드 보관", dryRun: dryRun, tidy: false) { context in
            AIDataCleaner.archiveThreads(targets, report: codex, options: options, context: context, vault: vault, dryRun: dryRun)
        }
    }

    /// 복구함 '되돌리기': `codex unarchive <id>` 뒤 상태 DB에서 확인한다.
    func restoreCodexThread(_ entry: RecoveryEntry) {
        guard Confirm.ask(title: "Codex 스레드를 되돌릴까요?", text: "\(entry.title)\n\n\(entry.restoreHint ?? "")\n\n보관을 풀어 Codex 스레드 목록에 다시 보이게 합니다.", action: "되돌리기") else { return }
        let vault = self.vault
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = RecoveryRestorer.restoreCodexArchive(entry, vault: vault)
            DispatchQueue.main.async {
                guard let self else { return }
                self.lastActionMessage = result.message
                self.append(result.ok ? .arrive : .alert, (result.ok ? "되돌리기 · " : "되돌리기 실패 · ") + "\(entry.project) · \(entry.title) · \(result.message)")
                if !result.ok { Confirm.info(title: "되돌리지 못했습니다", text: result.message + "\n\n직접 실행할 명령:\n\(entry.restoreHint ?? "")") }
                self.syncRecovery(force: true)
                if self.aiData.report != nil { self.scanAIData() }
            }
        }
    }

    // MARK: AI 앱 캐시 · 이전 CLI 버전(영구 삭제)

    /// 앱이 꺼진 순수 캐시만 영구 삭제(공간이 바로 돌아온다). 금고에 '되돌릴 수 없음 · 재생성 방법'을 남긴다.
    func clearAIAppCaches(_ items: [AIAppCache]) {
        let targets = items.filter(\.selectable)
        guard !targets.isEmpty else { Confirm.info(title: "비울 캐시가 없습니다", text: "앱이 실행 중이면 그 앱의 캐시는 건너뜁니다. 앱을 끄고 다시 조사해 주세요."); return }
        let bytes = targets.reduce(UInt64(0)) { $0 + $1.bytes }
        var text = targets.prefix(14).map { "• \($0.app) · \($0.folder) · \(Fmt.size($0.bytes))" }.joined(separator: "\n")
        if targets.count > 14 { text += "\n… 외 \(targets.count - 14)곳" }
        text += "\n\n순수 캐시라 영구 삭제합니다(앱을 다시 열면 새로 만듭니다). 로그인·저장 데이터(Local Storage · IndexedDB · Cookies · Login Data · History)는 건드리지 않습니다. 앱이 그사이 켜졌으면 건너뜁니다."
        text += settings.dryRun ? "\n드라이런: 지우지 않고 결과만 기록합니다." : ""
        guard Confirm.ask(title: "AI 앱 캐시 비우기 · \(targets.count)곳 · \(Fmt.gb(bytes))", text: text, action: settings.dryRun ? "드라이런" : "영구 삭제", destructive: !settings.dryRun) else { return }
        let dryRun = settings.dryRun, vault = self.vault
        runAIData(title: "AI 앱 캐시", dryRun: dryRun) { context in
            AIDataCleaner.clearCaches(targets, paths: AIDataPaths(), context: context, vault: vault, dryRun: dryRun)
        }
    }

    /// 현재 아님 · 아무도 실행하지 않는 이전 버전만 영구 삭제. 직전에 실행 중 프로세스를 새로 재서 다시 판정한다.
    func deleteOldCLIVersions(_ items: [CLIVersion]) {
        let targets = items.filter(\.selectable)
        guard let report = aiData.report, !targets.isEmpty else { Confirm.info(title: "지울 이전 버전이 없습니다", text: "현재 버전 · 실행 중인 세션이 쓰는 버전 · 하드링크 · 24시간 안에 설치된 버전은 남깁니다."); return }
        let bytes = targets.reduce(UInt64(0)) { $0 + $1.bytes }
        let text = targets.map { "• \($0.tool) \($0.version) · \(Fmt.size($0.bytes)) · 현재 \($0.current ?? "-")" }.joined(separator: "\n")
            + "\n\n아무 프로세스도 실행하지 않는 이전 버전만 영구 삭제합니다. 지우기 직전에 실행 중인 프로세스를 다시 확인해, 그사이 쓰기 시작한 버전은 건너뜁니다."
            + (settings.dryRun ? "\n드라이런: 지우지 않고 결과만 기록합니다." : "")
        guard Confirm.ask(title: "이전 CLI 버전 지우기 · \(targets.count)개 · \(Fmt.gb(bytes))", text: text, action: settings.dryRun ? "드라이런" : "영구 삭제", destructive: !settings.dryRun) else { return }
        let options = report.options, dryRun = settings.dryRun, vault = self.vault
        runAIData(title: "이전 CLI 버전", dryRun: dryRun) { context in
            AIDataCleaner.deleteVersions(targets, paths: AIDataPaths(), options: options, context: context, vault: vault, dryRun: dryRun)
        }
    }

    // MARK: 실행 공통

    /// 백그라운드에서 새 판정 기준으로 실행 → 결과 기록 · 청소 인력(실제 실행이고 회수가 있을 때) · 복구함 갱신 · 다시 조사.
    private func runAIData(title: String, dryRun: Bool, tidy: Bool = true, _ work: @escaping @Sendable (AIDataContext) -> [AIDataResult]) {
        guard aiDataReady else { Confirm.info(title: "아직 실행할 수 없습니다", text: "세션 조사가 끝난 뒤 다시 시도해 주세요(실행 중 세션을 먼저 알아야 합니다)."); return }
        guard !aiData.working else { return }
        aiData.working = true
        let inputs = aiDataInputs()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = work(AppModel.context(inputs))
            DispatchQueue.main.async {
                guard let self else { return }
                self.aiData.working = false
                let done = results.filter(\.ok), skipped = results.filter { !$0.ok }
                let bytes = done.reduce(UInt64(0)) { $0 + $1.bytes }
                let message = (dryRun ? "드라이런 · " : "") + "\(title) · \(done.count)개" + (bytes > 0 ? " · \(Fmt.gb(bytes))" : "")
                    + (skipped.isEmpty ? "" : " · 건너뜀 \(skipped.count)개(\(skipped.prefix(2).map { "\($0.target): \($0.message)" }.joined(separator: "; ")))")
                self.lastActionMessage = message
                self.aiData.note = message
                self.append(.cleanup, message)
                if tidy, !dryRun, !done.isEmpty {
                    self.monitor.emit(OfficeEvent(kind: .tidy(reclaimedBytes: bytes, project: nil, items: done.count), text: "청소 · \(title) · \(done.count)개" + (bytes > 0 ? " · \(Fmt.gb(bytes))" : "")))
                }
                self.migrations = self.migrator.records()
                self.syncRecovery(force: true)
                self.scanAIData()
            }
        }
    }
}
