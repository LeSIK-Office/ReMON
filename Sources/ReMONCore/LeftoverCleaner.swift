import Darwin
import Foundation

/// 정리 결과(정리 가능 항목마다 하나).
public struct LeftoverCleanResult: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case worktree, branch }

    /// 항목 id(WorktreeLeftover.id = 경로, BranchLeftover.id = 저장소#이름).
    public var id: String
    public var kind: Kind
    public var project: String
    public var action: LeftoverAction
    /// 끝난 뒤 그 항목이 치워졌고 확인까지 끝났는지(드라이런이면 '치울 수 있음', 이미 없으면 true). 확인하지 못한 것이 하나라도 있으면 false.
    public var ok: Bool
    /// 명령을 실행하지 않음(재확인에서 바뀜·이미 없음·의존이 있어 보류).
    public var skipped: Bool
    public var dryRun: Bool
    public var message: String
    /// 실행한(드라이런이면 실행할) 명령.
    public var command: [String]
    public var bytes: UInt64
    /// 지우기 전에 남긴 근거: 경로 · 브랜치 · HEAD 전체 SHA · upstream · 결합 근거(git 이력).
    public var evidence: String = ""
    /// 지운 뒤 확인한 것(폴더 없음 · git/Orca 목록에서 빠짐 · 커밋 보존). 확인하지 못한 것은 '미확인'으로 적는다.
    public var verification: [String] = []
    /// 금고 항목 id(실제로 지웠을 때).
    public var vaultEntryID: String?
}

/// 부산물 정리. 항목마다 지우기 직전에 실제 상태를 다시 읽고(같은 조사기·같은 판정 규칙), 하나라도 바뀌었으면 건너뛴다.
/// 명령은 판정한 경로·ref 하나에만 쓴다(prune·gc·강제 없음): 작업 공간 → `git worktree remove <경로>`(끊긴 기록도 같은 명령),
/// Orca → `orca worktree rm --worktree path:<경로> --json`(--force·--run-hooks 없음), 조상 병합 브랜치 → `git branch -d <이름>`,
/// 동등(squash·cherry-pick) 병합 브랜치 → `git update-ref -d refs/heads/<이름> <기록한 SHA>`(그 SHA일 때만 지운다).
/// 지우기 전에 금고에 근거를 먼저 적고, 지운 뒤 정말 사라졌는지(옮겨지지 않았는지) · 커밋이 남았는지 확인한다. 실제 동작·드라이런·건너뜀은 모두 감사 기록에 남긴다.
public enum LeftoverCleaner {
    public static func clean(_ projects: [ProjectLeftovers], dryRun: Bool, audit: AuditLog = .shared, sessions: [AgentSession] = [], orcaTerminals: [OrcaTerminal] = [],
                             tools: LeftoverTools = .live, options: LeftoverScanOptions = LeftoverScanOptions(), vault: RecoveryVault? = nil) -> [LeftoverCleanResult] {
        clean(worktrees: projects.flatMap(\.worktrees), branches: projects.flatMap(\.branches), dryRun: dryRun, audit: audit, sessions: sessions,
              orcaTerminals: orcaTerminals, tools: tools, options: options, vault: vault)
    }

    /// 정리 가능(cleanable) 판정만 다룬다. 작업 공간 먼저, 브랜치 나중.
    public static func clean(worktrees: [WorktreeLeftover], branches: [BranchLeftover], dryRun: Bool, audit: AuditLog = .shared, sessions: [AgentSession] = [],
                             orcaTerminals: [OrcaTerminal] = [], tools: LeftoverTools = .live, options: LeftoverScanOptions = LeftoverScanOptions(),
                             vault: RecoveryVault? = nil) -> [LeftoverCleanResult] {
        let worktreeTargets = worktrees.filter(\.verdict.isCleanable)
        let branchTargets = branches.filter(\.verdict.isCleanable)
        guard !worktreeTargets.isEmpty || !branchTargets.isEmpty else { return [] }
        // 관리 주체 재확인용 Orca 목록. Orca가 없으면 빈 목록, 읽기 실패면 nil(이때 Orca 항목은 지우기 직전에 다시 읽어야만 진행).
        let orcaRows: [OrcaWorktree]? = tools.orca == nil ? [] : LeftoverOrca.worktrees(tools: tools)
        // 사용 중 재확인용 Orca 터미널: 부른 쪽이 준 것 + 지금 Orca가 아는 것(Orca가 관리하지 않는 작업 공간 안에서도 터미널이 돌 수 있다).
        var terminals = orcaTerminals
        if !worktreeTargets.isEmpty, tools.orca != nil, let live = LeftoverOrca.terminals(tools: tools) {
            terminals += live.filter { item in item.handle.isEmpty || !orcaTerminals.contains { $0.handle == item.handle } }
        }
        let links = LinkCache()
        var results: [LeftoverCleanResult] = []
        for item in worktreeTargets {
            results.append(cleanWorktree(item, dryRun: dryRun, audit: audit, sessions: sessions, orcaTerminals: terminals, orcaRows: orcaRows, tools: tools,
                                         options: options, vault: vault, links: links))
        }
        for item in branchTargets {
            results.append(cleanBranch(item, dryRun: dryRun, audit: audit, tools: tools, options: options, vault: vault))
        }
        return results
    }

    // MARK: - 작업 공간

    static func cleanWorktree(_ item: WorktreeLeftover, dryRun: Bool, audit: AuditLog, sessions: [AgentSession], orcaTerminals: [OrcaTerminal], orcaRows: [OrcaWorktree]?,
                              tools: LeftoverTools, options: LeftoverScanOptions, vault: RecoveryVault? = nil, links: LinkCache = LinkCache()) -> LeftoverCleanResult {
        guard let action = item.verdict.action else { preconditionFailure("cleanable만 넘어온다") }
        var result = LeftoverCleanResult(id: item.id, kind: .worktree, project: item.project, action: action, ok: false, skipped: true, dryRun: dryRun,
                                         message: "", command: [], bytes: item.bytes)
        var head = item.head
        func finish(ok: Bool, skipped: Bool, _ message: String, audited: String, extra: [String: Any] = [:]) -> LeftoverCleanResult {
            result.ok = ok
            result.skipped = skipped
            result.message = message
            var detail: [String: Any] = ["repo": item.repo, "project": item.project, "manager": item.manager.rawValue, "head": head, "branch": item.branch ?? "",
                                         "command": result.command, "evidence": result.evidence, "verification": result.verification]
            if let entry = result.vaultEntryID { detail["entry"] = entry }
            detail.merge(extra) { $1 }
            audit.write(action: "leftover." + action.rawValue, target: item.path, bytes: item.bytes, result: audited, dryRun: dryRun, detail: detail)
            return result
        }
        func skip(_ reason: String) -> LeftoverCleanResult { finish(ok: false, skipped: true, reason, audited: "skipped: " + reason) }

        // 1) 라벨이 아니라 지금 상태를 다시 읽는다. 프로세스(작업 폴더·열린 파일)는 git을 띄우기 전에 찍는다.
        let processes = ProcessPresence.live()
        var terminals = orcaTerminals
        var rows = orcaRows ?? []
        if action == .orcaRemoveWorktree {
            // orca worktree rm은 그 작업 공간의 터미널을 멈춘다 → 지우기 직전에 터미널·목록을 반드시 다시 읽는다.
            guard tools.orca != nil else { return skip("Orca CLI가 없어 건너뜀") }
            guard let liveTerminals = LeftoverOrca.terminals(tools: tools), let liveRows = LeftoverOrca.worktrees(tools: tools) else {
                return skip("Orca 상태를 읽지 못해 건너뜀")
            }
            terminals += liveTerminals
            rows = liveRows
        }
        let inspector = LeftoverInspector(tools: tools, options: options, sessions: sessions, terminals: terminals, processes: processes, orcaRows: rows)
        guard let state = inspector.loadRepo(path: item.repo) else { return skip("저장소를 다시 읽지 못해 건너뜀") }
        guard let index = state.entries.firstIndex(where: { samePath($0.path, item.path) }) else {
            return finish(ok: true, skipped: true, "이미 정리됨", audited: "skipped: already gone")
        }
        guard index != 0, !samePath(item.path, state.repo) else { return skip("메인 작업 공간이라 건너뜀") }
        let entry = state.entries[index]
        let fresh = inspector.inspectWorktree(entry, isMain: false, state: state)
        if let reason = changeReason(old: item, new: fresh) { return skip(reason) }
        head = fresh.head
        result.evidence = evidence(for: fresh)

        // 2) 동작별 확인 — 판정한 경로 하나만 다룬다.
        var identity: FolderIdentity?
        var adminDir: String?
        switch action {
        case .pruneWorktreeMetadata:
            // 폴더가 다시 보이면(외장 볼륨 재연결 등) 기록만 지우는 동작이 맞지 않는다.
            guard !pathExists(item.path) else { return skip("폴더가 다시 보여 보류") }
            adminDir = adminDirectory(of: entry, repo: state.repo)
            // 저장소 전체에 적용되는 git worktree prune 대신, 그 경로 하나만 지우는 git worktree remove(폴더가 없으면 기록만 지운다).
            result.command = [tools.git, "-C", state.repo, "worktree", "remove", entry.path]
        case .removeWorktree, .orcaRemoveWorktree:
            do { _ = try SafeFileOps.validate(item.path) } catch { return skip("\(error)") }
            let holders = SafeFileOps.openFileUsers(under: item.path, pids: ProcessPresence.sameUserPIDs())
            if !holders.isEmpty { return skip("열린 파일이 있어 보류(pid \(holders.prefix(3).map(String.init).joined(separator: ",")))") }
            // 링크 의존: 메인·형제 작업 공간 안의 링크가 이 안을 가리키면 지우지 않는다(링크도 그 대상도 건드리지 않는다).
            let linkIndex = links.index(for: state, inspector: inspector)
            let referrers = linkIndex.referrers(into: item.path).map(\.display)
            if !referrers.isEmpty { return skip("보류: " + LeftoverRules.linkReason(referrers)) }
            if !linkIndex.complete { return skip("보류: 링크 의존 확인 못 함(시간 제한)") }
            identity = FolderIdentity(path: item.path)
            adminDir = adminDirectory(of: entry, repo: state.repo)
            if action == .removeWorktree {
                result.command = [tools.git, "-C", state.repo, "worktree", "remove", entry.path]
            } else {
                guard let orca = tools.orca, let row = rows.first(where: { samePath($0.path, item.path) }) else { return skip("Orca 목록에 없어 보류") }
                result.command = [orca, "worktree", "rm", "--worktree", "path:" + row.path, "--json"]
            }
        case .deleteMergedBranch:
            return skip("작업 공간에 맞지 않는 동작")
        }

        // 3) 드라이런은 여기까지(아무것도 실행하지 않는다).
        if dryRun { return finish(ok: true, skipped: false, "드라이런: " + describe(action) + " · " + summary(fresh), audited: "dry-run") }

        // 4) 지우기 전에 금고에 먼저 적는다: 경로 · 브랜치 · HEAD 전체 SHA · upstream · 결합 근거. 못 적으면 지우지 않는다.
        //    끊긴 기록 정리는 폴더가 이미 없어 되살릴 것이 없다 — 근거는 감사 기록에 남긴다.
        var pending: RecoveryEntry?
        if let vault, action != .pruneWorktreeMetadata {
            var record = RecoveryEntry(kind: .worktree, status: .retiring, project: item.project, title: (item.path as NSString).lastPathComponent, reason: "부산물 청소",
                                       bytes: item.bytes)
            record.repo = item.repo
            record.worktreePath = item.path
            record.branch = fresh.branch
            record.head = fresh.head
            record.upstream = fresh.upstream
            record.evidence = fresh.integration?.evidence
            record.restoreHint = "git -C \(ResumeKey.quote(item.repo)) worktree add \(ResumeKey.quote(item.path)) " + (fresh.branch.map(ResumeKey.quote) ?? "--detach \(fresh.head)")
            var notes: [String] = []
            if let integration = fresh.integration, integration.isEquivalence {
                record.commits = integration.commits
                notes.append(LeftoverRules.equivalenceNote + "(\(integration.commits.count)개)")
            }
            notes.append(item.manager == .orca ? "Orca 표시 이름·메모는 되살아나지 않습니다 · 무시 캐시(node_modules 등)는 다시 설치" : "무시 캐시(node_modules 등)는 다시 설치")
            record.note = notes.joined(separator: " · ")
            do {
                try vault.add(record)
                pending = record
                result.vaultEntryID = record.id
            } catch {
                return finish(ok: false, skipped: true, "복구 금고에 기록하지 못해 건너뜀", audited: "skipped: vault write failed", extra: ["error": error.localizedDescription])
            }
        }

        // 5) 실행.
        let run = tools.run(result.command[0], Array(result.command.dropFirst()), action == .orcaRemoveWorktree ? 120 : 60)
        var failure: String?
        if !run.succeeded {
            failure = run.timedOut ? "시간 초과" : firstLine(run.stderr.isEmpty ? orcaError(run.stdout) : run.stderr)
        } else if action == .orcaRemoveWorktree, let error = orcaFailure(run.stdout) {
            failure = error
        }

        // 6) 정말 사라졌는지 확인한다 — '지우는 중' 응답만으로는 끝이 아니다.
        let check = verifyRemoval(item: item, entry: entry, action: action, state: state, inspector: inspector, tools: tools, identity: identity, adminDir: adminDir)
        result.verification = check.lines + check.problems

        // 7) 금고: 원래 자리가 그대로면 지우고, 옮겨졌으면 '기록만'(옮겨진 곳), 사라졌으면 보관(같은 커밋으로 되살린다).
        if let vault, let pending {
            if !check.changed {
                try? vault.remove(pending.id)
                result.vaultEntryID = nil
            } else {
                let verification = result.verification.joined(separator: " · ")
                try? vault.update(pending.id) { stored in
                    stored.status = check.movedTo == nil ? .held : .gone
                    stored.verification = verification
                    var prefix: [String] = []
                    if let moved = check.movedTo { prefix.append("삭제되지 않고 옮겨짐: \(moved)") }
                    if check.commitsUnverified { prefix.append("커밋 보존 미확인") }
                    if !prefix.isEmpty { stored.note = (prefix + [stored.note].compactMap { $0 }).joined(separator: " · ") }
                }
            }
        }
        if let failure {
            let text = check.changed && !check.problems.isEmpty ? failure + " · 미확인: " + check.problems.joined(separator: " · ") : failure
            return finish(ok: false, skipped: false, "실패: " + text, audited: "error: " + text)
        }
        if !check.problems.isEmpty {
            let text = check.problems.joined(separator: " · ")
            return finish(ok: false, skipped: false, "미확인: " + text, audited: "unverified: " + text)
        }
        return finish(ok: true, skipped: false, done(action) + " · " + summary(fresh), audited: "ok")
    }

    /// 지운 뒤 확인 결과.
    struct RemovalCheck {
        /// 확인된 것.
        var lines: [String] = []
        /// 남아 있거나 확인하지 못한 것(하나라도 있으면 완료로 보고하지 않는다).
        var problems: [String] = []
        /// 원래 자리에서 무언가 바뀌었는지(폴더가 없어졌거나 git 등록이 빠졌다) — 금고 항목을 남길지.
        var changed = false
        /// 같은 폴더(장치·inode·생성 시각)가 옆 자리나 휴지통에 있으면 그 경로.
        var movedTo: String?
        var commitsUnverified = false
    }

    /// 폴더가 정말 없어졌는지(옮겨지거나 숨겨지지 않았는지) · git 목록·관리 기록에서 빠졌는지 · Orca 목록에서 빠졌는지 ·
    /// 브랜치가 함께 지워졌다면(분리된 HEAD면 그 커밋이) 기본 브랜치에 남았거나 동등한지.
    static func verifyRemoval(item: WorktreeLeftover, entry: PorcelainWorktree, action: LeftoverAction, state: RepoState, inspector: LeftoverInspector,
                              tools: LeftoverTools, identity: FolderIdentity?, adminDir: String?) -> RemovalCheck {
        var check = RemovalCheck()
        let folderGone = !pathExists(item.path)
        var unregistered = false
        if let listed = inspector.worktreeList(at: state.repo).entries {
            if listed.contains(where: { samePath($0.path, item.path) }) {
                check.problems.append("git 목록에 남아 있음")
            } else {
                unregistered = true
                check.lines.append("git 목록에서 빠짐")
            }
            // 브랜치는 작업 공간 한 곳에만 체크아웃된다 — 다른 경로에 같은 브랜치가 있으면 지워진 게 아니라 옮겨진 것이다.
            if let ref = entry.branchRef, let other = listed.first(where: { $0.branchRef == ref && !samePath($0.path, item.path) }) {
                check.problems.append("브랜치 \(LeftoverScanner.shortBranch(ref))가 다른 곳(\(other.path))에 체크아웃돼 있음 — 옮겨진 것으로 보임")
            }
        } else {
            check.problems.append("git 목록 확인 못 함(미확인)")
        }
        if action != .pruneWorktreeMetadata {
            if folderGone { check.lines.append("폴더 없음") } else { check.problems.append("폴더가 남아 있음") }
            if folderGone, let identity, let moved = identity.findMoved() {
                check.movedTo = moved
                check.problems.append("폴더가 지워지지 않고 옮겨짐(\(moved))")
            }
        }
        // git 관리 기록(.git/worktrees/<이름>) — git worktree move로 옮기면 이것이 그대로 남는다.
        if let adminDir {
            if pathExists(adminDir) { check.problems.append("git 관리 기록이 남아 있음(\((adminDir as NSString).lastPathComponent))") } else { check.lines.append("git 관리 기록 없음") }
        }
        if item.manager == .orca {
            if let rows = LeftoverOrca.worktrees(tools: tools) {
                if rows.contains(where: { samePath($0.path, item.path) }) { check.problems.append("Orca 목록에 남아 있음") } else { check.lines.append("Orca 목록에서 빠짐") }
            } else {
                check.problems.append("Orca 목록 확인 못 함(미확인)")
            }
        }
        check.changed = (action != .pruneWorktreeMetadata && folderGone) || unregistered
        guard check.changed else { return check }
        // 커밋 보존: 브랜치가 함께 지워졌으면(Orca 등) 그 커밋이 기본 브랜치에 남았거나 동등한지. 분리된 HEAD면 그 커밋을.
        if let ref = entry.branchRef {
            let branch = LeftoverScanner.shortBranch(ref)
            let exists = inspector.git(["-C", state.repo, "show-ref", "--verify", "--quiet", ref])
            if exists.succeeded {
                check.lines.append("브랜치 \(branch) 남아 있음(커밋 보존)")
            } else if exists.status == 1 && !exists.timedOut {
                let holds = inspector.integrationHolds(entry.head, state: state)
                if holds.holds == true {
                    check.lines.append("브랜치 \(branch)도 함께 지워짐 · 커밋 보존 확인(\(holds.evidence))")
                } else {
                    check.problems.append("브랜치 \(branch)가 함께 지워짐 · 커밋 보존 미확인(지우기 전 SHA \(entry.head))")
                    check.commitsUnverified = true
                }
            } else {
                check.problems.append("브랜치 \(branch) 상태 확인 못 함(미확인)")
            }
        } else if LeftoverScanner.isFullSHA(entry.head) {
            let holds = inspector.integrationHolds(entry.head, state: state)
            if holds.holds == true {
                check.lines.append("분리된 HEAD 커밋 보존 확인(\(holds.evidence))")
            } else {
                check.problems.append("분리된 HEAD 커밋 보존 미확인(지우기 전 SHA \(entry.head))")
                check.commitsUnverified = true
            }
        }
        return check
    }

    /// 판정에 쓰인 사실이 바뀌었으면 사유.
    static func changeReason(old: WorktreeLeftover, new: WorktreeLeftover) -> String? {
        if new.head != old.head { return "HEAD가 바뀌어 보류" }
        if new.branch != old.branch { return "브랜치가 바뀌어 보류" }
        guard new.verdict == old.verdict else {
            if let reason = new.verdict.keepReason { return "보류: " + reason }
            return "정리 방법이 바뀌어 보류(\(new.verdict.action?.rawValue ?? "-"))"
        }
        return nil
    }

    /// 금고·감사 기록에 남기는 근거: 경로 · 브랜치 · HEAD 전체 SHA · upstream · 결합 근거.
    static func evidence(for item: WorktreeLeftover) -> String {
        var parts = ["경로 \(item.path)", item.branch.map { "브랜치 \($0)" } ?? "분리된 HEAD", "HEAD \(item.head)"]
        if let upstream = item.upstream { parts.append("upstream \(LeftoverScanner.shortRef(upstream))") }
        parts.append(integrationText(item))
        return parts.joined(separator: " · ")
    }

    /// 결과 메시지에 붙이는 짧은 근거(HEAD 앞 12자 · 결합 근거).
    static func summary(_ item: WorktreeLeftover) -> String {
        "HEAD \(item.head.prefix(12)) · " + integrationText(item)
    }

    static func integrationText(_ item: WorktreeLeftover) -> String {
        if let integration = item.integration { return integration.evidence }
        return item.prunable && item.branch != nil ? "브랜치가 커밋을 지킴(기록만 정리)" : "결합 근거 없음"
    }

    /// 작업 공간의 git 관리 폴더(.git/worktrees/<이름>). 작업 공간의 .git 파일, 없으면 관리 폴더들의 gitdir 파일에서 찾는다.
    static func adminDirectory(of entry: PorcelainWorktree, repo: String) -> String? {
        if let text = try? String(contentsOfFile: entry.path + "/.git", encoding: .utf8), text.hasPrefix("gitdir: ") {
            let directory = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return directory.hasPrefix("/") ? directory : LinkIndex.normalize(entry.path + "/" + directory)
        }
        let root = repo + "/.git/worktrees"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        for name in names {
            guard let pointer = try? String(contentsOfFile: root + "/" + name + "/gitdir", encoding: .utf8) else { continue }
            let target = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
            if samePath((target as NSString).deletingLastPathComponent, entry.path) { return root + "/" + name }
        }
        return nil
    }

    // MARK: - 브랜치

    static func cleanBranch(_ item: BranchLeftover, dryRun: Bool, audit: AuditLog, tools: LeftoverTools, options: LeftoverScanOptions, vault: RecoveryVault? = nil) -> LeftoverCleanResult {
        let action = LeftoverAction.deleteMergedBranch
        var result = LeftoverCleanResult(id: item.id, kind: .branch, project: item.project, action: action, ok: false, skipped: true, dryRun: dryRun,
                                         message: "", command: [], bytes: 0)
        var commits: [String] = []
        func finish(ok: Bool, skipped: Bool, _ message: String, audited: String, extra: [String: Any] = [:]) -> LeftoverCleanResult {
            result.ok = ok
            result.skipped = skipped
            result.message = message
            var detail: [String: Any] = ["repo": item.repo, "project": item.project, "branch": item.name, "head": item.head, "command": result.command,
                                         "evidence": result.evidence, "verification": result.verification]
            if !commits.isEmpty { detail["commits"] = commits }
            if let entry = result.vaultEntryID { detail["entry"] = entry }
            detail.merge(extra) { $1 }
            audit.write(action: "leftover." + action.rawValue, target: item.id, result: audited, dryRun: dryRun, detail: detail)
            return result
        }
        func skip(_ reason: String) -> LeftoverCleanResult { finish(ok: false, skipped: true, reason, audited: "skipped: " + reason) }

        guard item.verdict == .cleanable(action), !item.name.isEmpty, !item.name.hasPrefix("-") else { return skip("정리할 수 없는 브랜치") }
        let inspector = LeftoverInspector(tools: tools, options: options, sessions: [], terminals: [], processes: [], orcaRows: [])
        guard let state = inspector.loadRepo(path: item.repo) else { return skip("저장소를 다시 읽지 못해 건너뜀") }
        guard let fresh = inspector.inspectBranch(named: item.name, state: state) else {
            return finish(ok: true, skipped: true, "이미 정리됨", audited: "skipped: already gone")
        }
        if fresh.head != item.head { return skip("새 커밋이 있어 보류") }
        if fresh.verdict != item.verdict { return skip(fresh.verdict.keepReason.map { "보류: " + $0 } ?? "판정이 바뀌어 보류") }
        guard let integration = fresh.integration else { return skip("결합 근거가 없어 보류") }
        commits = integration.commits
        var parts = ["브랜치 \(item.name)", "HEAD \(fresh.head)"]
        if let upstream = fresh.upstream { parts.append("upstream \(LeftoverScanner.shortRef(upstream))") }
        parts.append(integration.evidence)
        result.evidence = parts.joined(separator: " · ")
        let ref = "refs/heads/" + item.name
        // 조상 병합은 git branch -d(git이 한 번 더 확인한다). 동등 병합은 -d가 받아 주지 않으므로, 기록한 SHA를 그대로 가리킬 때만 지우는
        // update-ref -d <ref> <SHA>(비교 후 삭제 — 강제가 아니다: 그 사이 움직였으면 git이 거부한다).
        result.command = integration.isEquivalence ? [tools.git, "-C", state.repo, "update-ref", "-d", ref, fresh.head]
                                                   : [tools.git, "-C", state.repo, "branch", "-d", item.name]
        let short = "\(fresh.head.prefix(12)) · \(integration.evidence)"
        if dryRun {
            let plan = integration.isEquivalence ? "git update-ref -d(기록한 SHA일 때만)로 동등 병합 브랜치를 지웁니다" : describe(action)
            return finish(ok: true, skipped: false, "드라이런: " + plan + " · " + short, audited: "dry-run")
        }

        // 지우기 전에 금고에 먼저 적는다(브랜치 · HEAD 전체 SHA · upstream · 결합 근거 · 동등이면 커밋 SHA). 못 적으면 지우지 않는다.
        var pending: RecoveryEntry?
        if let vault {
            var record = RecoveryEntry(kind: .branch, status: .retiring, project: item.project, title: item.name, reason: "부산물 청소")
            record.repo = item.repo
            record.branch = item.name
            record.head = fresh.head
            record.upstream = fresh.upstream
            record.evidence = integration.evidence
            record.restoreHint = "git -C \(ResumeKey.quote(item.repo)) branch \(ResumeKey.quote(item.name)) \(fresh.head)"
            if integration.isEquivalence {
                record.commits = integration.commits
                record.note = LeftoverRules.equivalenceNote + "(\(integration.commits.count)개) · 원래 커밋은 저장소의 git gc가 지우기 전까지 이 SHA로 되살릴 수 있습니다"
            }
            do {
                try vault.add(record)
                pending = record
                result.vaultEntryID = record.id
            } catch {
                return finish(ok: false, skipped: true, "복구 금고에 기록하지 못해 건너뜀", audited: "skipped: vault write failed", extra: ["error": error.localizedDescription])
            }
        }

        let run = tools.run(result.command[0], Array(result.command.dropFirst()), options.commandTimeout * 2)
        let failure: String? = run.succeeded ? nil : (run.timedOut ? "시간 초과" : firstLine(run.stderr))
        // 확인 1: 브랜치가 정말 없어졌는지. 확인 2: 그 커밋이 기본 브랜치에 남았거나(조상) 같은 패치가 있는지(동등).
        let check = inspector.git(["-C", state.repo, "show-ref", "--verify", "--quiet", ref])
        let gone: Bool? = check.status == 1 && !check.timedOut ? true : (check.succeeded ? false : nil)
        var lines: [String] = [], problems: [String] = []
        var commitsUnverified = false
        switch gone {
        case true?: lines.append("브랜치 없음 확인")
        case false?: problems.append(failure == nil ? "명령은 끝났지만 브랜치가 남아 있음" : "브랜치가 남아 있음")
        case nil: problems.append("정리 뒤 상태를 확인하지 못함")
        }
        if gone == true {
            let holds = inspector.integrationHolds(fresh.head, state: state)
            if holds.holds == true {
                lines.append("커밋 보존 확인(\(holds.evidence))")
            } else {
                problems.append("커밋 보존 미확인")
                commitsUnverified = true
            }
        }
        result.verification = lines + problems
        // 금고: 지워졌으면(또는 모르면) 보관 — 같은 SHA로 되살린다. 그대로 남았으면 지운다.
        if let vault, let pending {
            if gone == false {
                try? vault.remove(pending.id)
                result.vaultEntryID = nil
            } else {
                let verification = result.verification.joined(separator: " · ")
                try? vault.update(pending.id) { stored in
                    stored.status = .held
                    stored.verification = verification
                    if commitsUnverified { stored.note = (["커밋 보존 미확인"] + [stored.note].compactMap { $0 }).joined(separator: " · ") }
                }
            }
        }
        if let failure, gone != true { return finish(ok: false, skipped: false, "실패: " + failure, audited: "error: " + failure) }
        if commitsUnverified {
            let text = "브랜치는 지웠지만 커밋 보존을 확인하지 못함 · 지우기 전 SHA \(fresh.head)" + (result.vaultEntryID != nil ? " · 복구함에 기록" : "")
            return finish(ok: false, skipped: false, "미확인: " + text, audited: "unverified: " + text)
        }
        if !problems.isEmpty {
            let text = problems.joined(separator: " · ")
            return finish(ok: false, skipped: false, "실패: " + text, audited: "error: " + text)
        }
        return finish(ok: true, skipped: false, (integration.isEquivalence ? "squash/cherry-pick 동등 브랜치 삭제 완료" : done(action)) + " · " + short, audited: "ok")
    }

    // MARK: - 보조

    static func samePath(_ a: String, _ b: String) -> Bool {
        a == b || SafeFileOps.canonical(a) == SafeFileOps.canonical(b)
    }

    /// 그 자리에 무엇이든 있는지(링크 자체 포함 — 따라가지 않는다).
    static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func describe(_ action: LeftoverAction) -> String {
        switch action {
        case .pruneWorktreeMetadata: "git worktree remove로 끊긴 작업 공간 기록만 정리합니다(그 경로 하나만)"
        case .removeWorktree: "git worktree remove로 작업 공간을 지웁니다"
        case .orcaRemoveWorktree: "orca worktree rm으로 Orca 작업 공간을 지웁니다"
        case .deleteMergedBranch: "git branch -d로 병합된 브랜치를 지웁니다"
        }
    }

    static func done(_ action: LeftoverAction) -> String {
        switch action {
        case .pruneWorktreeMetadata: "끊긴 작업 공간 기록 정리 완료"
        case .removeWorktree: "작업 공간 삭제 완료"
        case .orcaRemoveWorktree: "Orca 작업 공간 삭제 완료"
        case .deleteMergedBranch: "병합된 브랜치 삭제 완료"
        }
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "알 수 없는 오류" : Redactor.redact(String(line.prefix(200)))
    }

    /// Orca JSON이 실패(ok=false)를 알리면 그 메시지.
    static func orcaFailure(_ stdout: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any], (root["ok"] as? Bool) == false else { return nil }
        return orcaError(stdout)
    }

    static func orcaError(_ stdout: String) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any] else { return stdout }
        let error = root["error"] as? [String: Any]
        return (error?["message"] as? String) ?? (error?["code"] as? String) ?? (root["error"] as? String) ?? "Orca 오류"
    }
}

/// 한 번의 청소 동안 저장소마다 링크 의존 목록을 한 번만 만든다(작업 공간을 지울 때마다 모든 작업 공간을 다시 걷지 않게).
/// 먼저 지운 작업 공간 안에 있던 링크는 LinkIndex.referrers가 지금 없으면 뺀다.
final class LinkCache: @unchecked Sendable {
    private let lock = NSLock()
    private var indexes: [String: LinkIndex] = [:]

    func index(for state: RepoState, inspector: LeftoverInspector) -> LinkIndex {
        let key = SafeFileOps.canonical(state.repo)
        lock.lock()
        if let cached = indexes[key] { lock.unlock(); return cached }
        lock.unlock()
        let index = inspector.linkIndex(state: state)
        lock.lock(); indexes[key] = index; lock.unlock()
        return index
    }
}

/// 지우기 전 폴더의 정체(장치·inode·생성 시각). 지운 뒤 같은 폴더가 옆 자리(이름만 바뀜·숨김)나 휴지통에 '옮겨져' 있지 않은지 본다.
struct FolderIdentity: Sendable {
    var path: String
    var device: dev_t
    var inode: ino_t
    var birthSeconds: Int
    var birthNanoseconds: Int

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        self.path = path
        device = info.st_dev
        inode = info.st_ino
        birthSeconds = info.st_birthtimespec.tv_sec
        birthNanoseconds = info.st_birthtimespec.tv_nsec
    }

    func matches(_ candidate: String) -> Bool {
        var info = stat()
        return lstat(candidate, &info) == 0 && info.st_dev == device && info.st_ino == inode
            && info.st_birthtimespec.tv_sec == birthSeconds && info.st_birthtimespec.tv_nsec == birthNanoseconds
    }

    /// 같은 폴더가 원래 부모 폴더 안 또는 휴지통 맨 위에 있으면 그 경로. 휴지통을 읽을 수 없으면 그쪽은 건너뛴다.
    func findMoved(trashFolders: [String]? = nil) -> String? {
        let parent = (path as NSString).deletingLastPathComponent
        for folder in [parent] + (trashFolders ?? Self.trashFolders(for: path)) {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for name in names where matches(folder + "/" + name) { return folder + "/" + name }
        }
        return nil
    }

    static func trashFolders(for path: String) -> [String] {
        var folders = [FileManager.default.homeDirectoryForCurrentUser.path + "/.Trash"]
        if path.hasPrefix("/Volumes/"), let volume = path.split(separator: "/").dropFirst().first {
            folders.append("/Volumes/\(volume)/.Trashes/\(getuid())")
        }
        return folders
    }
}
