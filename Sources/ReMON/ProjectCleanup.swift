import AppKit
import ReMONCore
import SwiftUI

// 프로젝트(사무실) 단위 청소(10-25 대표 요청): 커밋·푸시·배포가 생기면 그 방에 '서류'가 쌓이고 왼쪽 사이드바에 '청소하기'가 뜬다.
// 누르면 그 프로젝트의 부산물(병합된 워크트리·브랜치)과 다시 생기는 캐시(쉬는 node_modules·빌드 산출물)를 확인 한 번 뒤 치우고, 청소부가 그 방에 들어온다.

struct ProjectGarbage: Equatable {
    var papers = 0                      // 사건이 쌓인 양(커밋 1 · 푸시 2 · 배포 3). 청소하면 0.
    var lastEvent: GitEvent?
    var leftoverCount = 0
    var leftoverBytes: UInt64 = 0
    var cacheCount = 0
    var cacheBytes: UInt64 = 0

    var cleanableCount: Int { leftoverCount + cacheCount }
    var cleanableBytes: UInt64 { leftoverBytes + cacheBytes }
    var needsCleaning: Bool { papers > 0 || cleanableCount > 0 }
}

extension AppModel {
    /// 15초마다: 아는 저장소(부산물 조사 결과 + 세션 작업 폴더)의 git 사건을 본다.
    func pollGitEvents() {
        var repos = Set(leftovers.flatMap(\.repos))
        for session in office?.sessions ?? [] {
            if let cwd = session.cwd, let root = Self.repoRoot(of: cwd) { repos.insert(root) }
        }
        guard !repos.isEmpty else { return }
        let watcher = gitWatcher
        let list = Array(repos)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let events = watcher.observe(repos: list)
            guard !events.isEmpty else { return }
            DispatchQueue.main.async { self?.handleGitEvents(events) }
        }
    }

    private func handleGitEvents(_ events: [GitEvent]) {
        recentGitEvents += events
        for event in events {
            var garbage = projectGarbage[event.project] ?? ProjectGarbage()
            garbage.papers += event.kind == .deploy ? 3 : event.kind == .push ? 2 : 1
            garbage.lastEvent = event
            projectGarbage[event.project] = garbage
            append(event.kind == .deploy ? .arrive : .info, event.text)
            let keys = (office?.sessions ?? []).filter { $0.project == event.project }.map(\.id)
            scene?.celebrate(project: event.project, keys: keys, kind: event.kind, label: event.label)
        }
        refreshProjectGarbage()
    }

    /// 부산물·디스크 조사 결과를 프로젝트별 '치울 것'으로 합친다(조사가 끝날 때마다 부른다).
    func refreshProjectGarbage() {
        var next: [String: ProjectGarbage] = [:]
        for (project, garbage) in projectGarbage where garbage.papers > 0 { next[project] = ProjectGarbage(papers: garbage.papers, lastEvent: garbage.lastEvent) }
        for project in leftovers where project.cleanableCount > 0 {
            var garbage = next[project.project] ?? ProjectGarbage()
            garbage.leftoverCount = project.cleanableCount
            garbage.leftoverBytes = project.cleanableBytes
            next[project.project] = garbage
        }
        let active = Set((office?.sessions ?? []).compactMap(\.cwd))
        for item in diskItems where item.category == .regenerable {
            guard item.path.hasPrefix(NSHomeDirectory() + "/DEV/"), CacheDeletionPolicy.tier(for: item, activeDirectories: active) != .trashOnly else { continue }
            let project = SessionDetector.projectName(for: item.path)
            var garbage = next[project] ?? ProjectGarbage()
            garbage.cacheCount += 1
            garbage.cacheBytes += item.bytes
            next[project] = garbage
        }
        if next != projectGarbage { projectGarbage = next }
        scene?.setPapers(next.compactMapValues { $0.papers > 0 ? $0.papers : nil })
        // 방 안 짐: 워크트리·브랜치 전부(치울 수 있는 것과 남길 것을 따로) + 서류. 무게에 비례해 쌓인다.
        var clutter: [String: RoomClutter] = [:]
        for project in leftovers {
            let room = RoomClutter(project, papers: next[project.project]?.papers ?? 0)
            if !room.isEmpty { clutter[project.project] = room }
        }
        for (project, garbage) in next where clutter[project] == nil && garbage.papers > 0 { clutter[project] = RoomClutter(papers: garbage.papers) }
        if clutter != roomClutter { roomClutter = clutter }
        scene?.setClutter(clutter)
        pushSpeechContext()
    }

    /// 대사 생성기에 줄 맥락(git 사건 1시간 · 금고 · 감사 · 정신교육실 인원). 세션·시스템은 장면의 스냅샷이 맡는다.
    func pushSpeechContext() {
        let hour = Date().addingTimeInterval(-3600)
        recentGitEvents.removeAll { $0.time < hour }
        let retired = recovery.filter { $0.kind == .session && ($0.status == .held || $0.status == .restoring) }.count
        scene?.setSpeech(git: recentGitEvents, vault: vaultCounts, audit: lastAudit.map { ($0.summary, $0.time) }, retired: retired)
    }

    /// 청소하기: 그 프로젝트의 부산물 + 다시 생기는 캐시를 확인 한 번 뒤 치운다. 청소부는 .tidy 사건으로 그 방에 들어온다.
    func cleanProject(_ project: String) {
        guard !projectCleaning.contains(project) else { return }
        let leftoverTargets = leftovers.filter { $0.project == project && $0.cleanableCount > 0 }
        let active = Set((office?.sessions ?? []).compactMap(\.cwd))
        let caches = diskItems.filter { item in
            item.category == .regenerable && item.path.hasPrefix(NSHomeDirectory() + "/DEV/") && SessionDetector.projectName(for: item.path) == project
                && CacheDeletionPolicy.tier(for: item, activeDirectories: active) != .trashOnly
        }
        let papers = projectGarbage[project]?.papers ?? 0
        guard !leftoverTargets.isEmpty || !caches.isEmpty else {
            guard papers > 0 else {
                lastActionMessage = "\(project) · 지금 정리할 수 있는 항목이 없습니다"
                return
            }
            lastActionMessage = settings.dryRun ? "드라이런 · \(project) · 서류 \(papers)장 정리 가능" : "\(project) · 서류 \(papers)장 정리했습니다"
            append(.cleanup, lastActionMessage!)
            if !settings.dryRun { finishProjectCleanup(project, items: 0, reclaimed: 0) }
            return
        }
        var lines: [String] = []
        for target in leftoverTargets {
            let worktrees = target.worktrees.filter(\.verdict.isCleanable), branches = target.branches.filter(\.verdict.isCleanable)
            if !worktrees.isEmpty { lines.append("• 병합된 워크트리 \(worktrees.count)개 · \(Fmt.gb(worktrees.reduce(0) { $0 + $1.bytes }))") }
            if !branches.isEmpty { lines.append("• 병합된 브랜치 \(branches.count)개") }
        }
        for item in caches.prefix(8) { lines.append("• " + item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + " · \(Fmt.gb(item.bytes))") }
        if caches.count > 8 { lines.append("• … 캐시 \(caches.count - 8)곳 더") }
        let bytes = leftoverTargets.reduce(UInt64(0)) { $0 + $1.cleanableBytes } + caches.reduce(UInt64(0)) { $0 + $1.bytes }
        let text = lines.joined(separator: "\n") + "\n\n워크트리·브랜치는 병합됐고 커밋 안 된 변경이 없고 아무도 쓰지 않는 것만(금고에 커밋을 적어 되살릴 수 있음). 캐시는 다시 생기는 것만 영구 삭제합니다. 항목마다 직전에 다시 확인합니다." +
            (papers > 0 ? "\n쌓인 서류 \(papers)장도 치웁니다." : "") + (settings.dryRun ? "\n\n드라이런: 실제로 치우지 않습니다." : "")
        guard Confirm.ask(title: "\(project) 청소 · \(leftoverTargets.reduce(0) { $0 + $1.cleanableCount } + caches.count)개 · 약 \(Fmt.gb(bytes))", text: text,
                          action: settings.dryRun ? "드라이런" : "청소부 투입", destructive: !caches.isEmpty) else { return }
        let dryRun = settings.dryRun
        let sessions = office?.sessions ?? []
        let vault = self.vault
        let pids = userPIDs
        projectCleaning.insert(project)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = leftoverTargets.isEmpty ? [] : LeftoverCleaner.clean(leftoverTargets, dryRun: dryRun, sessions: sessions, vault: dryRun ? nil : vault)
            var freed: UInt64 = 0, freedItems = 0, failures: [String] = []
            for item in caches {
                do {
                    try SafeFileOps.deletePermanently(item.path, userPIDs: pids, dryRun: dryRun, bytes: item.bytes, vault: dryRun ? nil : vault, project: project,
                                                      reason: "프로젝트 청소", regeneration: CacheDeletionPolicy.regenerationHint(for: item))
                    freed += item.bytes; freedItems += 1
                } catch { failures.append("\((item.path as NSString).lastPathComponent): \(error)") }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.projectCleaning.remove(project)
                let done = results.filter { $0.ok && !$0.skipped }
                let unverified = results.filter { !$0.ok && $0.message.hasPrefix("미확인") }
                let skipped = results.filter { ($0.skipped || !$0.ok) && !$0.message.hasPrefix("미확인") }
                let reclaimed = done.reduce(UInt64(0)) { $0 + $1.bytes } + freed
                let reasons = skipped.map(\.message) + failures
                var summary = (dryRun ? "드라이런 · " : "") + "\(project) 청소 · 부산물 \(done.count)개 · 캐시 \(freedItems)곳 · \(Fmt.gb(reclaimed))"
                if !reasons.isEmpty { summary += " · 건너뜀 \(reasons.count)개 — " + reasons.prefix(2).joined(separator: "; ") }
                if !unverified.isEmpty { summary += " · 미확인 \(unverified.count)개 — " + unverified.prefix(2).map(\.message).joined(separator: "; ") }
                self.lastActionMessage = summary
                self.append(.cleanup, summary)
                if !dryRun {
                    self.diskItems.removeAll { item in caches.contains { $0.path == item.path } && !FileManager.default.fileExists(atPath: item.path) }
                    if !done.isEmpty || freedItems > 0 || papers > 0 {
                        self.finishProjectCleanup(project, items: done.count + freedItems, reclaimed: reclaimed, completed: done)
                    }
                }
                self.syncRecovery(force: true)
                self.scanLeftovers()
            }
        }
    }

    private func finishProjectCleanup(_ project: String, items: Int, reclaimed: UInt64, completed: [LeftoverCleanResult] = []) {
        focusOn(.room(project))
        closeInspector()
        var shown = roomClutter
        if var room = shown[project] {
            room.cleanableWorktrees = completed.filter { $0.kind == .worktree }.count
            room.cleanableBranches = completed.filter { $0.kind == .branch }.count
            shown[project] = room
            scene?.setClutter(shown)
        }
        scene?.janitorVisit(project: project, items: items, reclaimed: reclaimed)
        let removed = Set(completed.map(\.id))
        for index in leftovers.indices {
            leftovers[index].worktrees.removeAll { removed.contains($0.id) }
            leftovers[index].branches.removeAll { removed.contains($0.id) }
        }
        projectGarbage[project]?.papers = 0
        refreshProjectGarbage()
    }

    /// 작업 폴더에서 위로 올라가며 .git이 있는 폴더(메인 작업 공간 또는 워크트리 루트).
    static func repoRoot(of path: String) -> String? {
        var current = path
        for _ in 0..<12 {
            if FileManager.default.fileExists(atPath: current + "/.git") { return current }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, parent.count > 1 else { return nil }
            current = parent
        }
        return nil
    }
}

/// 사이드바: 서류가 쌓였거나 치울 것이 있는 프로젝트마다 '청소하기' 한 줄.
struct ProjectCleanupPanel: View {
    @ObservedObject var model: AppModel
    @AppStorage("projectCleanupCollapsed") private var collapsed = false

    var body: some View {
        let rows = model.projectGarbage.filter { $0.value.needsCleaning }.sorted { $0.value.papers != $1.value.papers ? $0.value.papers > $1.value.papers : $0.key < $1.key }
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button { collapsed.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(.teal)
                        Text("청소하기 · 프로젝트").font(.system(size: 11, weight: .bold))
                        Spacer()
                        Text("\(rows.count)").font(.system(size: 10)).foregroundStyle(.secondary)
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsed ? "프로젝트 청소 펼치기" : "프로젝트 청소 접기")
                if !collapsed {
                    ForEach(rows, id: \.key) { project, garbage in
                    Button { model.cleanProject(project) } label: {
                        HStack(spacing: 7) {
                            Image(systemName: garbage.lastEvent?.kind == .deploy ? "party.popper" : "doc.on.doc").font(.system(size: 11, weight: .semibold)).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project).font(.system(size: 11.5, weight: .semibold))
                                Text(note(garbage)).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if model.projectCleaning.contains(project) { ProgressView().controlSize(.mini) } else { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.teal.opacity(0.14)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.projectCleaning.contains(project))
                    .help("\(project) 방에 청소부를 보내 병합된 부산물과 다시 생기는 캐시를 치웁니다(확인 한 번)")
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.teal.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.teal.opacity(0.3)))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    private func note(_ garbage: ProjectGarbage) -> String {
        var parts: [String] = []
        if let event = garbage.lastEvent { parts.append((event.kind == .deploy ? "배포 " : event.kind == .push ? "푸시 " : "커밋 ") + Fmt.ago(event.time)) }
        if garbage.papers > 0 { parts.append("서류 \(garbage.papers)") }
        if garbage.leftoverCount > 0 { parts.append("부산물 \(garbage.leftoverCount)") }
        if garbage.cacheCount > 0 { parts.append("캐시 \(Fmt.gb(garbage.cacheBytes))") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 금고 요약(기록 보관소 = 금고의 방에 보여 줄 수)

struct VaultCounts: Equatable {
    var sessions = 0      // 되살릴 수 있는 세션(보관 중·복귀 중)
    var files = 0         // 휴지통으로 보낸 파일
    var git = 0           // 지운 워크트리·브랜치(커밋 기록)
    var processes = 0     // 끝낸 보조 프로세스·앱(다시 띄우기)
    var expired = 0       // 되돌릴 수 없게 된 것(영구 삭제·만료·사라짐)
    var bytes: UInt64 = 0

    var total: Int { sessions + files + git + processes + expired }
}

extension AppModel {
    /// 복구 금고 항목을 종류별로 센다.
    var vaultCounts: VaultCounts {
        var counts = VaultCounts()
        for entry in recovery {
            let live = entry.status == .held || entry.status == .restoring || entry.status == .retiring
            switch entry.kind.rawValue {
            case "session": if live { counts.sessions += 1 } else { counts.expired += 1 }
            case "trash": if live { counts.files += 1 } else { counts.expired += 1 }
            case "branch", "worktree", "codexArchive": if live { counts.git += 1 } else { counts.expired += 1 }
            case "process": if live { counts.processes += 1 } else { counts.expired += 1 }
            default: counts.expired += 1
            }
            counts.bytes += entry.bytes
        }
        return counts
    }
}
