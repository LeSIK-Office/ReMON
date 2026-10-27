import AppKit
import ReMONCore

/// 개발 캐시 · 시스템 데이터 · 큰 파일 화면의 상태. AppModel에는 확장만 더할 수 있어(저장 속성 불가) 따로 둔다.
@MainActor
final class DiskToolsStore: ObservableObject {
    static let shared = DiskToolsStore()

    /// 개발 캐시 선택(경로). 새 조사 결과가 오면, 사람이 고친 적 없을 때만 추천 선택으로 다시 맞춘다.
    @Published var selection: Set<String> = []
    var selectionTouched = false
    var selectionBasis: Date?
    /// 접어 둔 묶음(로그·기본 제외는 처음에 접힘)
    @Published var collapsed: Set<CatalogGroup> = [.logs, .excluded, .projects]
    /// 명령 실행 가능 여부(id → 못 하는 이유, 빈 문자열 = 가능)
    @Published var commandAvailability: [String: String] = [:]
    @Published var commandRunning: String?
    /// 마지막 실행·미리보기 출력(id → 몇 줄)
    @Published var commandOutput: [String: String] = [:]

    @Published var systemData: SystemDataReport?
    @Published var systemDataLoading = false

    @Published var largeReport: LargeFileFinder.Report?
    @Published var largeScanning = false
    @Published var largeProgressFiles = 0
    @Published var largeProgressBytes: UInt64 = 0
    @Published var largeSelection: Set<String> = []
    var finder: LargeFileFinder?
}

// 개발 캐시 카탈로그 · 시스템 데이터 · 큰 파일 동작. 지우는 것은 모두 금고에 먼저 남는다(영구 삭제 = 재생성 방법, 휴지통 = 위치).
// 드라이런이면 지우지 않고 기록만 남긴다. 무거운 일은 메인 스레드 밖에서 돈다.
extension AppModel {
    var diskTools: DiskToolsStore { DiskToolsStore.shared }

    /// 카탈로그·빌드 산출물·임시 파일(등급과 항목 id가 있는 것). AI 기록·큰 DB·휴지통은 각자의 구역에서 보인다.
    var catalogDiskItems: [DiskItem] { diskItems.filter { $0.entryID != nil } }

    private func shortPath(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private func projectLabel(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory() + "/DEV/") ? SessionDetector.projectName(for: path) : "공용 캐시"
    }

    // MARK: 개발 캐시

    /// 새 조사 결과가 오면 추천 선택(주인이 꺼진 A)으로 맞춘다. 사람이 고친 선택은 사라진 항목만 뺀다.
    func syncCatalogSelection() {
        let store = diskTools
        guard store.selectionBasis != diskScannedAt else { return }
        store.selectionBasis = diskScannedAt
        let items = catalogDiskItems
        if store.selectionTouched {
            store.selection.formIntersection(Set(items.map(\.path)))
        } else {
            store.selection = Set(items.filter(DiskCatalog.isRecommended).map(\.path))
        }
    }

    func selectRecommendedCatalog() {
        diskTools.selection = Set(catalogDiskItems.filter(DiskCatalog.isRecommended).map(\.path))
        diskTools.selectionTouched = false
    }

    func toggleCatalogSelection(_ paths: [String], on: Bool) {
        if on { diskTools.selection.formUnion(paths) } else { diskTools.selection.subtract(paths) }
        diskTools.selectionTouched = true
    }

    /// 개발 캐시 정리(확인 한 번). 직전에 주인 앱 실행을 다시 확인하고, A·쉬는 B는 영구 삭제(재생성 방법을 금고에), 나머지는 휴지통(위치를 금고에).
    func cleanCatalog(_ items: [DiskItem]) {
        guard !items.isEmpty else { return }
        let running = RunningApps.live()
        let active = Set((office?.sessions ?? []).compactMap(\.cwd))
        var plan: [(item: DiskItem, delete: Bool)] = []
        var skipped: [(item: DiskItem, reason: String)] = []
        for item in items {
            if let reason = CacheDeletionPolicy.blockReason(for: item, running: running) { skipped.append((item, reason)); continue }
            plan.append((item, CacheDeletionPolicy.tier(for: item, activeDirectories: active, running: running) != .trashOnly))
        }
        guard !plan.isEmpty else {
            Confirm.info(title: "정리할 수 있는 항목이 없습니다", text: skipped.prefix(10).map { "• \(shortPath($0.item.path)) — \($0.reason)" }.joined(separator: "\n"))
            return
        }
        let deleteBytes = plan.filter(\.delete).reduce(UInt64(0)) { $0 + $1.item.bytes }
        let trashBytes = plan.filter { !$0.delete }.reduce(UInt64(0)) { $0 + $1.item.bytes }
        var lines = plan.prefix(12).map { "• \(shortPath($0.item.path)) · \(Fmt.size($0.item.bytes)) · " + ($0.delete ? "영구 삭제(\($0.item.grade?.rawValue ?? "-"))" : "휴지통") }
        if plan.count > 12 { lines.append("… 외 \(plan.count - 12)곳") }
        if !skipped.isEmpty { lines.append("\n제외 \(skipped.count)곳: " + skipped.prefix(4).map { "\(($0.item.path as NSString).lastPathComponent)(\($0.reason))" }.joined(separator: ", ")) }
        let text = lines.joined(separator: "\n") +
            "\n\n영구 삭제 \(Fmt.size(deleteBytes))는 공간이 바로 돌아오고, 복구함에 다시 생기는 방법이 남습니다. 휴지통 \(Fmt.size(trashBytes))는 복구함에서 되돌릴 수 있습니다(공간은 휴지통을 비워야 돌아옵니다)." +
            (settings.dryRun ? "\n\n드라이런: 지우지 않고 결과만 기록합니다." : "")
        guard Confirm.ask(title: "개발 캐시 정리 · \(plan.count)곳 · \(Fmt.size(deleteBytes + trashBytes))", text: text, action: settings.dryRun ? "드라이런" : "정리하기") else { return }
        let dryRun = settings.dryRun
        let pids = userPIDs
        let vault = self.vault
        let beforeFree = system.disk.available
        let labels = Dictionary(plan.map { ($0.item.path, projectLabel($0.item.path)) }, uniquingKeysWith: { first, _ in first })
        // 작은 파일이 많은 항목(진단 보고서·로그)은 금고에 한 줄로 묶어 남긴다(파일마다 감사 기록은 그대로 남는다).
        let deleteCounts = Dictionary(grouping: plan.filter(\.delete)) { $0.item.entryID ?? "" }.mapValues(\.count)
        let bundled = Set(deleteCounts.filter { !$0.key.isEmpty && $0.value > 10 }.keys)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var done: [(item: DiskItem, delete: Bool)] = []
            var failures: [String] = []
            var bundles: [String: [DiskItem]] = [:]
            var bundleEntries: [String: RecoveryEntry] = [:]
            for (item, delete) in plan {
                let project = labels[item.path] ?? "공용 캐시"
                let bundle = delete && bundled.contains(item.entryID ?? "")
                do {
                    if bundle, !dryRun, let id = item.entryID, bundleEntries[id] == nil {
                        var entry = RecoveryEntry(kind: .deleted, status: .retiring, project: "공용 캐시", title: DiskCatalog.entry(id)?.title ?? id,
                                                  reason: "개발 캐시 정리", bytes: 0)
                        entry.originalPath = (item.path as NSString).deletingLastPathComponent
                        entry.restoreHint = CacheDeletionPolicy.regenerationHint(for: item)
                        entry.note = "삭제 예정 · " + plan.filter { $0.delete && $0.item.entryID == id }.map(\.item.path).joined(separator: "\n")
                        try vault.add(entry)
                        bundleEntries[id] = entry
                    }
                    if delete {
                        try SafeFileOps.deletePermanently(item.path, userPIDs: pids, dryRun: dryRun, bytes: item.bytes, vault: (dryRun || bundle) ? nil : vault, project: project,
                                                          reason: "개발 캐시 정리", regeneration: CacheDeletionPolicy.regenerationHint(for: item))
                        if bundle { bundles[item.entryID ?? "", default: []].append(item) }
                    } else {
                        _ = try SafeFileOps.moveToTrash(item.path, userPIDs: pids, dryRun: dryRun, bytes: item.bytes, vault: dryRun ? nil : vault, project: project, reason: "개발 캐시 정리")
                    }
                    done.append((item, delete))
                } catch {
                    failures.append("\((item.path as NSString).lastPathComponent): \(error)")
                }
            }
            if !dryRun {
                for (id, recorded) in bundleEntries.sorted(by: { $0.key < $1.key }) {
                    let members = bundles[id] ?? []
                    guard !members.isEmpty else { try? vault.remove(recorded.id); continue }
                    let title = DiskCatalog.entry(id)?.title ?? id
                    let names = members.prefix(5).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
                    do {
                        try vault.update(recorded.id) {
                            $0.status = .gone; $0.title = "\(title) \(members.count)개"
                            $0.bytes = members.reduce(0) { $0 + $1.bytes }
                            $0.note = "영구 삭제 · 되돌릴 수 없음(재생성) · \(names)" + (members.count > 5 ? " 외 \(members.count - 5)개" : "")
                        }
                    } catch { failures.append("\(title): 삭제 전 기록은 보존했으나 완료 기록 갱신 실패") }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let deleted = done.filter(\.delete), trashed = done.filter { !$0.delete }
                let message = (dryRun ? "드라이런 · " : "") + "개발 캐시 정리 · 영구 삭제 \(deleted.count)곳 \(Fmt.size(deleted.reduce(0) { $0 + $1.item.bytes }))" +
                    " · 휴지통 \(trashed.count)곳 \(Fmt.size(trashed.reduce(0) { $0 + $1.item.bytes }))" +
                    (skipped.isEmpty ? "" : " · 제외 \(skipped.count)") + (failures.isEmpty ? "" : " · 건너뜀 \(failures.count)(\(failures.prefix(2).joined(separator: "; ")))")
                self.lastActionMessage = message
                self.append(.cleanup, message)
                if !dryRun {
                    let gone = Set(done.map(\.item.path).filter { !FileManager.default.fileExists(atPath: $0) })
                    self.diskItems.removeAll { gone.contains($0.path) }
                    self.diskTools.selection.subtract(gone)
                    let byProject = Dictionary(grouping: done.filter { gone.contains($0.item.path) }) { labels[$0.item.path] ?? "공용 캐시" }
                    for (project, members) in byProject.sorted(by: { $0.key < $1.key }) {
                        let bytes = members.reduce(UInt64(0)) { $0 + $1.item.bytes }
                        self.monitor.emit(OfficeEvent(kind: .tidy(reclaimedBytes: bytes, project: project == "공용 캐시" ? nil : project, items: members.count),
                                                      text: "청소 · \(project) · \(members.count)곳 · \(Fmt.size(bytes))"))
                    }
                }
                self.syncRecovery(force: true)
                self.refreshSuggestions()
                self.monitor.refreshNow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !dryRun else { return }
                    let after = self.system.disk.available
                    self.append(.cleanup, "디스크 여유 \(Fmt.gb(beforeFree)) → \(Fmt.gb(after))" + (after > beforeFree ? " (+\(Fmt.gb(after - beforeFree)))" : ""))
                }
            }
        }
    }

    // MARK: 도구 명령(brew cleanup · pnpm store prune · simctl · docker prune)

    /// 명령마다 실행할 수 있는지(도구 위치 · Xcode 여부) — 프로세스를 띄우므로 화면 밖에서 한 번만.
    func refreshCommandAvailability() {
        let store = diskTools
        let commands = ToolCommands.catalogCommands + [ToolCommands.pnpmPrune, ToolCommands.goModClean, ToolCommands.dockerPrune]
        DispatchQueue.global(qos: .utility).async {
            var result: [String: String] = [:]
            for command in commands { result[command.id] = ToolCommands.availability(command).reason ?? "" }
            DispatchQueue.main.async { store.commandAvailability = result }
        }
    }

    /// preview = 읽기 전용 미리보기(확인 없이). 실행은 확인 후 사용자 계정으로, 드라이런이면 미리보기만 돌리고 기록한다.
    func runToolCommand(_ command: ToolCommand, preview: Bool = false) {
        let store = diskTools
        guard store.commandRunning == nil else { return }
        if !preview {
            guard Confirm.ask(title: "\(command.title)을(를) 실행할까요?",
                              text: "\(command.detail)\n\n명령: \(command.commandLine)\n사용자 계정으로 실행하고 결과를 복구함에 기록합니다. 되돌릴 수 없지만 \(command.restoreHint)." +
                                (settings.dryRun ? "\n\n드라이런: 실행하지 않고 미리보기만 봅니다." : ""),
                              action: settings.dryRun ? "드라이런" : "실행", destructive: !settings.dryRun) else { return }
        }
        let dryRun = settings.dryRun && !preview
        let readOnly = preview || dryRun
        store.commandRunning = command.id
        let vault = self.vault
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let before = SystemData.volume("/").available
            let result = ToolCommands.run(command, preview: readOnly)
            let after = SystemData.volume("/").available
            let freed = after > before ? after - before : 0
            if dryRun {
                AuditLog.shared.write(action: "command.run", target: command.commandLine, result: "dry-run", dryRun: true)
            } else if !readOnly {
                AuditLog.shared.write(action: "command.run", target: command.commandLine, bytes: freed, result: result.succeeded ? "ok" : "error \(result.status)", dryRun: false,
                                      detail: ["stderr": String(result.stderr.suffix(400))])
                if result.succeeded {
                    var entry = RecoveryEntry(kind: .deleted, status: .gone, project: "공용 캐시", title: command.title, reason: "개발 캐시 정리", bytes: freed)
                    entry.restoreHint = command.restoreHint
                    entry.note = "명령 실행 · 되돌릴 수 없음(다시 받기)"
                    _ = try? vault.add(entry)
                }
            }
            let output = (result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = output.split(separator: "\n").suffix(12).joined(separator: "\n")
            DispatchQueue.main.async {
                guard let self else { return }
                store.commandRunning = nil
                store.commandOutput[command.id] = tail.isEmpty ? (result.succeeded ? "출력 없음" : "실패(종료 코드 \(result.status))") : tail
                let label = readOnly ? (dryRun ? "드라이런 · \(command.title) 미리보기" : "\(command.title) 미리보기") : command.title
                self.append(result.succeeded ? (readOnly ? .info : .cleanup) : .alert, label + (result.succeeded ? " · 완료" : " · 실패(\(result.status))") + (readOnly || freed == 0 ? "" : " · 약 \(Fmt.gb(freed)) 확보"))
                if !readOnly, result.succeeded {
                    self.syncRecovery(force: true)
                    self.scanDisk()
                    if command.id == ToolCommands.dockerPrune.id { self.refreshSystemData() }
                }
            }
        }
    }

    // MARK: 시스템 데이터

    /// 정리 가능 공간 · 스냅샷 · 가상 머신·백업 크기 · Docker(읽기 전용). 사람이 누를 때만(다른 앱 데이터 확인 창을 배경에서 띄우지 않게).
    func refreshSystemData() {
        let store = diskTools
        guard !store.systemDataLoading else { return }
        store.systemDataLoading = true
        DispatchQueue.global(qos: .utility).async {
            let report = SystemData.report()
            DispatchQueue.main.async {
                store.systemData = report
                store.systemDataLoading = false
            }
        }
    }

    /// docker system prune: Docker가 돌 때만, 확인 후 사용자 계정으로(볼륨·태그 있는 이미지는 남김).
    func dockerPrune() {
        guard diskTools.systemData?.docker.running == true else {
            Confirm.info(title: "Docker가 실행 중이 아닙니다", text: "Docker Desktop · OrbStack · Colima 중 하나가 돌고 있을 때만 정리할 수 있습니다.")
            return
        }
        runToolCommand(ToolCommands.dockerPrune)
    }

    // MARK: 큰 파일·폴더

    func scanLargeFiles() {
        let store = diskTools
        guard !store.largeScanning else { return }
        let finder = LargeFileFinder()
        store.finder = finder
        store.largeScanning = true
        store.largeProgressFiles = 0
        store.largeProgressBytes = 0
        store.largeSelection = []
        DispatchQueue.global(qos: .utility).async {
            var last = Date.distantPast
            let report = finder.scan { files, bytes in
                guard Date().timeIntervalSince(last) > 0.4 else { return }
                last = Date()
                DispatchQueue.main.async {
                    store.largeProgressFiles = files
                    store.largeProgressBytes = bytes
                }
            }
            DispatchQueue.main.async {
                store.largeReport = report
                store.largeScanning = false
                store.finder = nil
            }
        }
    }

    func cancelLargeFiles() { diskTools.finder?.cancel() }

    /// 고른 큰 파일·폴더를 휴지통으로(확인 한 번, 금고 기록). 거부 대상과 이미 고른 폴더 안의 항목은 뺀다.
    func trashLargeEntries(_ entries: [LargeFileFinder.Entry]) {
        let allowed = entries.filter { $0.refusal == nil }
        let folders = allowed.filter(\.isDirectory).map(\.path)
        let targets = allowed.filter { entry in !folders.contains { entry.path != $0 && entry.path.hasPrefix($0 + "/") } }
        guard !targets.isEmpty else {
            let reasons = entries.compactMap { entry in entry.refusal.map { "• \((entry.path as NSString).lastPathComponent) — \($0)" } }
            Confirm.info(title: "옮길 수 있는 항목이 없습니다", text: reasons.prefix(8).joined(separator: "\n"))
            return
        }
        let bytes = targets.reduce(UInt64(0)) { $0 + $1.bytes }
        var lines = targets.prefix(12).map { "• \(shortPath($0.path)) · \(Fmt.size($0.bytes))" }
        if targets.count > 12 { lines.append("… 외 \(targets.count - 12)개") }
        let text = lines.joined(separator: "\n") + "\n\n휴지통으로 옮기고 복구함에 위치를 남깁니다(비우지 않음 — 공간은 휴지통을 비워야 돌아옵니다)." +
            (settings.dryRun ? "\n\n드라이런: 옮기지 않고 결과만 기록합니다." : "")
        guard Confirm.ask(title: "큰 파일 정리 · \(targets.count)개 · \(Fmt.gb(bytes))", text: text, action: settings.dryRun ? "드라이런" : "휴지통으로") else { return }
        let dryRun = settings.dryRun
        let pids = userPIDs
        let vault = self.vault
        let store = diskTools
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var moved: [String] = []
            var failures: [String] = []
            for entry in targets {
                do {
                    try LargeFileFinder.trash(entry, userPIDs: pids, dryRun: dryRun, vault: vault)
                    moved.append(entry.path)
                } catch {
                    failures.append("\((entry.path as NSString).lastPathComponent): \(error)")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let movedBytes = targets.filter { moved.contains($0.path) }.reduce(UInt64(0)) { $0 + $1.bytes }
                let message = (dryRun ? "드라이런 · " : "") + "큰 파일 휴지통 · \(moved.count)개 · \(Fmt.gb(movedBytes))" + (failures.isEmpty ? "" : " · 건너뜀 \(failures.count)(\(failures.prefix(2).joined(separator: "; ")))")
                self.lastActionMessage = message
                self.append(.cleanup, message)
                if !dryRun, var report = store.largeReport {
                    let gone = Set(moved)
                    func kept(_ entry: LargeFileFinder.Entry) -> Bool { !gone.contains(entry.path) && !gone.contains { entry.path.hasPrefix($0 + "/") } }
                    report.files = report.files.filter(kept)
                    report.folders = report.folders.filter(kept)
                    store.largeReport = report
                    store.largeSelection.subtract(gone)
                    self.monitor.emit(OfficeEvent(kind: .tidy(reclaimedBytes: movedBytes, project: nil, items: moved.count), text: "청소 · 큰 파일 \(moved.count)개 · \(Fmt.gb(movedBytes))"))
                }
                self.syncRecovery(force: true)
            }
        }
    }
}
