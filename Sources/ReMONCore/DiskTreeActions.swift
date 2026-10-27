import Foundation

// 디스크 지도의 정리 — "금고에 먼저 적고, 되돌릴 수 있는 쪽이 기본."
// 휴지통: 금고에 '옮기는 중'(retiring)을 먼저 적고 → SafeFileOps.moveToTrash(보호 경로 · 열린 파일 확인) → 휴지통 위치를 적어 '보관 중'.
//         되돌리기는 RecoveryRestorer.restoreTrash. 옮기지 못하면 금고 기록을 지운다.
// 영구 삭제: 다시 생기는 캐시만(node.isSafeToDeletePermanently + 직전 재판정) — 금고에 '지움'을 먼저 적고 SafeFileOps.deletePermanently.
// 정리 명령(prune): docker image/builder prune(-a·볼륨 없음) · brew cleanup --prune=all · 표의 도구 명령 · git 부산물(LeftoverCleaner — 자기 금고 기록).
//         드라이런은 미리보기만 돈다(읽기 전용 인자). 실행 결과는 금고에 '지움'(되돌릴 수 없음)으로 남긴다.
// 사용자 파일·AI 기록·시스템·스왑·스냅샷의 영구 삭제는 이유를 말하고 거절한다.

public enum DiskTreeActions {
    public struct Result: Sendable, Equatable {
        public var action: DiskNodeAction
        public var path: String
        /// 끝난 뒤 바라던 상태인지(드라이런이면 '할 수 있음')
        public var ok: Bool
        public var dryRun: Bool
        /// 규칙상 하지 않음(이유는 message)
        public var refused: Bool
        public var message: String
        /// 실행한(드라이런이면 실행할) 명령 한 줄
        public var command: String?
        /// 도구 출력(미리보기 · 정리 결과) 앞부분
        public var output: String?
        public var bytes: UInt64
        public var vaultEntryID: String?
        public var trashedPath: String?

        init(action: DiskNodeAction, path: String, ok: Bool, dryRun: Bool, refused: Bool = false, message: String, command: String? = nil, output: String? = nil,
             bytes: UInt64 = 0, vaultEntryID: String? = nil, trashedPath: String? = nil) {
            self.action = action
            self.path = path
            self.ok = ok
            self.dryRun = dryRun
            self.refused = refused
            self.message = message
            self.command = command
            self.output = output
            self.bytes = bytes
            self.vaultEntryID = vaultEntryID
            self.trashedPath = trashedPath
        }
    }

    /// 정리에 필요한 바깥 상태. DiskTreeScanner.actionEnvironment()가 채운다(시험은 가짜 실행기·부산물을 넣는다).
    public struct Environment: Sendable {
        public var audit: AuditLog
        public var home: String = NSHomeDirectory()
        /// docker · brew · 도구 명령 실행기(nil = 실제)
        public var runner: CommandRunner?
        /// 부산물 조사 결과(워크트리·브랜치 칸)
        public var leftovers: [ProjectLeftovers] = []
        public var leftoverTools: LeftoverTools = .live
        public var leftoverOptions = LeftoverScanOptions()
        public var sessions: [AgentSession] = []
        /// 정리 직전 다시 판정. 없으면 이 홈의 기본 조사기로 판정한다 — 손으로 만든 칸이 규칙을 건너뛰지 못하게.
        public var reclassify: (@Sendable (String) -> DiskNode?)?
        /// 정리한 뒤(조사기 캐시 비우기)
        public var afterChange: (@Sendable (String) -> Void)?
        /// Finder에서 보기
        public var revealer: @Sendable (String) -> Bool = { path in Shell.capture("/usr/bin/open", ["-R", path], timeout: 10).succeeded }

        public init(audit: AuditLog = .shared) { self.audit = audit }
    }

    static let project = "디스크 지도"
    static let forbiddenPermanent: [(DiskTag, String)] = [
        (.userFile, "사용자 파일은 영구 삭제하지 않습니다 — 휴지통으로 옮기면 되돌릴 수 있습니다"),
        (.aiTranscript, "AI 대화 기록은 지우지 않습니다 — 세션을 되살리는 복구 자원입니다"),
        (.system, "시스템 영역은 지우지 않습니다 — macOS·앱이 관리합니다"),
        (.swap, "스왑 파일은 지울 수 없습니다 — macOS가 관리하고, 메모리를 아끼면 줄어듭니다"),
        (.snapshot, "로컬 스냅샷은 ReMON이 지우지 않습니다 — tmutil thinlocalsnapshots로 줄이거나 macOS가 스스로 지웁니다"),
    ]

    public static func perform(_ action: DiskNodeAction, on node: DiskNode, dryRun: Bool, vault: RecoveryVault?, userPIDs: [Int32],
                               environment: Environment = Environment()) -> Result {
        func refuse(_ why: String) -> Result {
            environment.audit.write(action: "disktree." + action.rawValue, target: node.path, bytes: node.bytes, result: "refused: " + why, dryRun: dryRun)
            return Result(action: action, path: node.path, ok: false, dryRun: dryRun, refused: true, message: why)
        }
        if action == .deletePermanently, let forbidden = forbiddenPermanent.first(where: { node.tags.contains($0.0) }) { return refuse(forbidden.1) }
        guard action != .none else { return refuse("보기만 하는 칸입니다 — 할 수 있는 조치가 없습니다") }
        guard node.actions.contains(action) else {
            return refuse("이 칸에 허용되지 않은 조치입니다(허용: \(node.actions.map(\.rawValue).joined(separator: ", ")))")
        }
        switch action {
        case .none:
            return refuse("보기만 하는 칸입니다")
        case .reveal:
            guard !node.isVirtual else { return refuse("파일이 아닌 칸이라 Finder에서 열 수 없습니다") }
            if dryRun { return Result(action: action, path: node.path, ok: true, dryRun: true, message: "드라이런: Finder에서 보여 줍니다") }
            let opened = environment.revealer(node.path)
            return Result(action: action, path: node.path, ok: opened, dryRun: false, message: opened ? "Finder에서 보여 줬습니다" : "Finder에서 열지 못했습니다")
        case .trash:
            if node.tags.contains(.gitByproduct) { return worktree(node, dryRun: dryRun, vault: vault, environment: environment, refuse: refuse) }
            return trash(node, dryRun: dryRun, vault: vault, userPIDs: userPIDs, environment: environment, refuse: refuse)
        case .deletePermanently:
            return delete(node, dryRun: dryRun, vault: vault, userPIDs: userPIDs, environment: environment, refuse: refuse)
        case .prune:
            return prune(node, dryRun: dryRun, vault: vault, environment: environment, refuse: refuse)
        }
    }

    // MARK: 휴지통

    /// 정리 직전 판정(환경이 주지 않으면 그 홈의 기본 조사기).
    static func fresh(_ path: String, _ environment: Environment) -> DiskNode? {
        if let reclassify = environment.reclassify { return reclassify(path) }
        return DiskTreeScanner(home: environment.home).describe(path)
    }

    static func trash(_ node: DiskNode, dryRun: Bool, vault: RecoveryVault?, userPIDs: [Int32], environment: Environment, refuse: (String) -> Result) -> Result {
        guard !node.isVirtual else { return refuse("파일이 아닌 칸이라 휴지통으로 옮길 수 없습니다") }
        guard let fresh = fresh(node.path, environment) else { return refuse("이미 없습니다") }
        guard fresh.actions.contains(.trash) else { return refuse("조사 뒤 상태가 바뀌어 옮기지 않습니다: " + (fresh.hint ?? "휴지통 조치 없음")) }
        let validated: String
        do { validated = try SafeFileOps.validate(node.path, removal: true).path } catch { return refuse("\(error)") }
        if dryRun {
            do {
                _ = try SafeFileOps.moveToTrash(validated, userPIDs: userPIDs, dryRun: true, bytes: node.bytes, audit: environment.audit, vault: nil, project: project, reason: "디스크 지도 정리")
                return Result(action: .trash, path: node.path, ok: true, dryRun: true, message: "드라이런: 휴지통으로 옮길 수 있습니다(복구함에서 되돌리기)", bytes: node.bytes)
            } catch { return Result(action: .trash, path: node.path, ok: false, dryRun: true, message: "\(error)") }
        }
        guard let vault else { return refuse("복구 금고가 없어 옮기지 않습니다(금고에 먼저 적어야 합니다)") }
        let note = node.tags.map(\.label).sorted().joined(separator: " · ")
        var entry = RecoveryEntry(kind: .trash, status: .retiring, project: project, title: node.name, reason: "디스크 지도 정리", bytes: node.bytes)
        entry.originalPath = validated
        entry.restoreHint = "Finder 휴지통에서 '되돌려 놓기'"
        entry.note = note
        do { try vault.add(entry) } catch { return refuse("복구 금고에 기록하지 못해 옮기지 않습니다") }
        do {
            let trashed = try SafeFileOps.moveToTrash(validated, userPIDs: userPIDs, dryRun: false, bytes: node.bytes, audit: environment.audit, vault: nil, project: project,
                                                      reason: "디스크 지도 정리")
            // 그 사이 금고 정리(settleRetiring)가 상태·메모를 바꿨어도 여기서 확정한다.
            try? vault.update(entry.id) { stored in
                stored.status = .held
                stored.trashedPath = trashed?.path
                stored.note = trashed == nil ? note + " · 휴지통 위치를 받지 못함 — Finder 휴지통에서 되돌립니다" : note
            }
            environment.afterChange?(node.path)
            return Result(action: .trash, path: node.path, ok: true, dryRun: false, message: "휴지통으로 옮겼습니다 — 복구함에서 되돌릴 수 있습니다", bytes: node.bytes,
                          vaultEntryID: entry.id, trashedPath: trashed?.path)
        } catch {
            try? vault.remove(entry.id)
            return Result(action: .trash, path: node.path, ok: false, dryRun: false, message: "\(error)")
        }
    }

    // MARK: 영구 삭제

    static func delete(_ node: DiskNode, dryRun: Bool, vault: RecoveryVault?, userPIDs: [Int32], environment: Environment, refuse: (String) -> Result) -> Result {
        guard node.isSafeToDeletePermanently else { return refuse("다시 생기는 캐시로 판정된 칸만 영구 삭제합니다") }
        guard !node.isVirtual else { return refuse("파일이 아닌 칸입니다") }
        guard let fresh = fresh(node.path, environment) else { return refuse("이미 없습니다") }
        guard fresh.isSafeToDeletePermanently else { return refuse("조사 뒤 상태가 바뀌어 영구 삭제하지 않습니다: " + (fresh.hint ?? "영구 삭제 조치 없음")) }
        let regeneration = node.hint ?? "다시 만들어지는 캐시입니다"
        if dryRun {
            do {
                try SafeFileOps.deletePermanently(node.path, userPIDs: userPIDs, dryRun: true, bytes: node.bytes, audit: environment.audit, vault: nil, project: project,
                                                  reason: "디스크 지도 정리", regeneration: regeneration)
                return Result(action: .deletePermanently, path: node.path, ok: true, dryRun: true, message: "드라이런: 영구 삭제할 수 있습니다(되돌릴 수 없음 · 다시 생김)", bytes: node.bytes)
            } catch { return Result(action: .deletePermanently, path: node.path, ok: false, dryRun: true, message: "\(error)") }
        }
        guard let vault else { return refuse("복구 금고가 없어 지우지 않습니다(금고에 먼저 적어야 합니다)") }
        var entry = RecoveryEntry(kind: .deleted, status: .retiring, project: project, title: node.name, reason: "디스크 지도 정리", bytes: node.bytes)
        entry.originalPath = node.path
        entry.restoreHint = regeneration
        entry.note = "영구 삭제 · 되돌릴 수 없음(재생성)"
        do { try vault.add(entry) } catch { return refuse("복구 금고에 기록하지 못해 지우지 않습니다") }
        do {
            try SafeFileOps.deletePermanently(node.path, userPIDs: userPIDs, dryRun: false, bytes: node.bytes, audit: environment.audit, vault: nil, project: project,
                                              reason: "디스크 지도 정리", regeneration: regeneration)
            try? vault.update(entry.id) { stored in
                stored.status = .gone
                stored.note = "영구 삭제 · 되돌릴 수 없음(재생성)"
            }
            environment.afterChange?(node.path)
            return Result(action: .deletePermanently, path: node.path, ok: true, dryRun: false, message: "영구 삭제했습니다(다시 생기는 캐시 · 금고에 기록)", bytes: node.bytes,
                          vaultEntryID: entry.id)
        } catch {
            try? vault.remove(entry.id)
            return Result(action: .deletePermanently, path: node.path, ok: false, dryRun: false, message: "\(error)")
        }
    }

    // MARK: 정리 명령

    static func prune(_ node: DiskNode, dryRun: Bool, vault: RecoveryVault?, environment: Environment, refuse: (String) -> Result) -> Result {
        if let parsed = DiskNodeVirtual.parse(node.path) {
            let detail = parsed.detail
            switch parsed.kind {
            case "docker":
                guard let command = DockerDiskUsage.command(forType: detail.replacingOccurrences(of: "-", with: " ")) else { return refuse("이 Docker 칸은 정리하지 않습니다(볼륨·컨테이너)") }
                return run(command, node: node, dryRun: dryRun, vault: vault, environment: environment, refuse: refuse)
            case "homebrew":
                return run(ToolCommands.brewCleanupAll, node: node, dryRun: dryRun, vault: vault, environment: environment, refuse: refuse)
            case "git-prune":
                guard let item = environment.leftovers.flatMap(\.worktrees).first(where: { $0.path == detail && $0.verdict == .cleanable(.pruneWorktreeMetadata) }) else {
                    return refuse("부산물 조사 결과에서 끊긴 워크트리 기록을 찾지 못했습니다 — 다시 조사하세요")
                }
                return leftover(worktrees: [item], branches: [], node: node, action: .prune, dryRun: dryRun, vault: vault, environment: environment)
            case "git-branch":
                guard let hash = detail.lastIndex(of: "#") else { return refuse("브랜치 칸이 아닙니다") }
                let repo = String(detail[..<hash]), name = String(detail[detail.index(after: hash)...])
                guard let item = environment.leftovers.flatMap(\.branches).first(where: { $0.repo == repo && $0.name == name && $0.verdict.isCleanable }) else {
                    return refuse("부산물 조사 결과에서 정리 가능한 브랜치로 찾지 못했습니다 — 다시 조사하세요")
                }
                return leftover(worktrees: [], branches: [item], node: node, action: .prune, dryRun: dryRun, vault: vault, environment: environment)
            default:
                return refuse("정리 명령이 없는 칸입니다")
            }
        }
        if node.path == environment.home + "/Library/Caches/Homebrew" {
            return run(ToolCommands.brewCleanupAll, node: node, dryRun: dryRun, vault: vault, environment: environment, refuse: refuse)
        }
        if let command = DiskCatalog.match(node.path, home: environment.home)?.entry.command {
            return run(command, node: node, dryRun: dryRun, vault: vault, environment: environment, refuse: refuse)
        }
        return refuse("정리 명령이 없는 칸입니다")
    }

    /// 도구 명령: 드라이런은 미리보기 인자(읽기 전용)만. 실행은 금고에 '지움'을 먼저 적은 뒤.
    static func run(_ command: ToolCommand, node: DiskNode, dryRun: Bool, vault: RecoveryVault?, environment: Environment, refuse: (String) -> Result) -> Result {
        if dryRun {
            let preview = ToolCommands.run(command, preview: true, home: environment.home, runner: environment.runner)
            environment.audit.write(action: "disktree.prune", target: command.commandLine, bytes: node.bytes, result: preview.succeeded ? "dry-run" : "preview failed", dryRun: true)
            let output = String((preview.stdout + preview.stderr).prefix(4000))
            guard preview.succeeded else {
                return Result(action: .prune, path: node.path, ok: false, dryRun: true, message: "미리보기 실패: " + firstLine(preview.stderr.isEmpty ? preview.stdout : preview.stderr),
                              command: command.commandLine, output: output)
            }
            return Result(action: .prune, path: node.path, ok: true, dryRun: true, message: "미리보기 — 실행하면: \(command.commandLine) · \(command.detail) · \(command.restoreHint)",
                          command: command.commandLine, output: output, bytes: node.bytes)
        }
        guard let vault else { return refuse("복구 금고가 없어 실행하지 않습니다(금고에 먼저 적어야 합니다)") }
        var entry = RecoveryEntry(kind: .deleted, status: .retiring, project: project, title: command.title, reason: "디스크 지도 정리 명령", bytes: node.bytes)
        entry.originalPath = node.isVirtual ? nil : node.path
        entry.restoreHint = command.restoreHint
        entry.note = "정리 명령(\(command.commandLine)) · 되돌릴 수 없음"
        do { try vault.add(entry) } catch { return refuse("복구 금고에 기록하지 못해 실행하지 않습니다") }
        let result = ToolCommands.run(command, preview: false, home: environment.home, runner: environment.runner)
        let output = String((result.stdout + "\n" + result.stderr).prefix(4000))
        guard result.succeeded else {
            try? vault.remove(entry.id)
            let why = result.timedOut ? "시간 초과" : firstLine(result.stderr.isEmpty ? result.stdout : result.stderr)
            environment.audit.write(action: "disktree.prune", target: command.commandLine, bytes: 0, result: "error: " + why, dryRun: false)
            return Result(action: .prune, path: node.path, ok: false, dryRun: false, message: "실패: " + why, command: command.commandLine, output: output)
        }
        let reclaimed = command.tool == "docker" ? DockerDiskUsage.reclaimed(result.stdout) : HomebrewPreview.parse(result.stdout + "\n" + result.stderr).total
        let bytes = reclaimed ?? node.bytes
        try? vault.update(entry.id) { stored in
            stored.status = .gone
            stored.bytes = bytes
            stored.note = "정리 명령(\(command.commandLine)) · 회수 \(reclaimed.map(Fmt.size) ?? "알 수 없음") · 되돌릴 수 없음"
        }
        environment.audit.write(action: "disktree.prune", target: command.commandLine, bytes: bytes, result: "ok", dryRun: false, detail: ["entry": entry.id])
        environment.afterChange?(node.isVirtual ? environment.home : node.path)
        return Result(action: .prune, path: node.path, ok: true, dryRun: false, message: "정리 명령을 실행했습니다 · 회수 \(reclaimed.map(Fmt.size) ?? "알 수 없음")(되돌릴 수 없음 · 금고에 기록)",
                      command: command.commandLine, output: output, bytes: bytes, vaultEntryID: entry.id)
    }

    // MARK: git 부산물

    static func worktree(_ node: DiskNode, dryRun: Bool, vault: RecoveryVault?, environment: Environment, refuse: (String) -> Result) -> Result {
        guard let item = environment.leftovers.flatMap(\.worktrees).first(where: { LeftoverCleaner.samePath($0.path, node.path) }), item.verdict.isCleanable, !item.isMain else {
            return refuse("부산물 조사 결과에서 정리 가능한 워크트리로 찾지 못했습니다 — 다시 조사하세요")
        }
        guard dryRun || vault != nil else { return refuse("복구 금고가 없어 지우지 않습니다(금고에 먼저 적어야 합니다)") }
        return leftover(worktrees: [item], branches: [], node: node, action: .trash, dryRun: dryRun, vault: vault, environment: environment)
    }

    /// LeftoverCleaner: 지우기 직전 다시 읽고(바뀌었으면 건너뜀), 금고에 커밋을 먼저 적은 뒤 git worktree remove · git branch -d(강제 없음).
    static func leftover(worktrees: [WorktreeLeftover], branches: [BranchLeftover], node: DiskNode, action: DiskNodeAction, dryRun: Bool, vault: RecoveryVault?,
                         environment: Environment) -> Result {
        let results = LeftoverCleaner.clean(worktrees: worktrees, branches: branches, dryRun: dryRun, audit: environment.audit, sessions: environment.sessions,
                                            tools: environment.leftoverTools, options: environment.leftoverOptions, vault: vault)
        guard let first = results.first else { return Result(action: action, path: node.path, ok: false, dryRun: dryRun, message: "정리할 항목이 없습니다") }
        let entry = vault?.all().first { stored in
            (stored.kind == .worktree && worktrees.contains { $0.path == stored.worktreePath }) || (stored.kind == .branch && branches.contains { $0.repo == stored.repo && $0.name == stored.branch })
        }
        if first.ok, !first.skipped, !dryRun { environment.afterChange?(worktrees.first?.path ?? environment.home) }
        return Result(action: action, path: node.path, ok: first.ok && (!first.skipped || first.message == "이미 정리됨"), dryRun: dryRun, refused: first.skipped && !first.ok,
                      message: first.message, command: first.command.isEmpty ? nil : first.command.joined(separator: " "), bytes: first.bytes,
                      vaultEntryID: dryRun ? nil : entry?.id)
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "알 수 없는 오류" : Redactor.redact(String(line.prefix(200)))
    }
}
