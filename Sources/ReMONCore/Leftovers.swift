import Foundation

// 부산물(에이전트가 남긴 git 워크트리·로컬 브랜치) — 방마다 '잡동사니'로 보이고, 정리 버튼으로 치운다.
// 판정은 보수적이다: 애매하면 보존(keep)하고 사유를 짧은 한국어로 남긴다.

/// 부산물을 만든(관리하는) 쪽.
public enum LeftoverManager: String, Sendable, CaseIterable {
    case orca, codex, claude, git
}

/// 정리 동작. 어떤 경우에도 강제 옵션(--force·-D)은 쓰지 않는다.
public enum LeftoverAction: String, Sendable, CaseIterable {
    case pruneWorktreeMetadata, removeWorktree, orcaRemoveWorktree, deleteMergedBranch
}

/// 판정. keep 사유는 화면에 그대로 보이는 짧은 한국어.
public enum LeftoverVerdict: Sendable, Equatable {
    case cleanable(LeftoverAction), keep(String)

    public var isCleanable: Bool { action != nil }

    public var action: LeftoverAction? {
        if case .cleanable(let action) = self { return action }
        return nil
    }

    public var keepReason: String? {
        if case .keep(let reason) = self { return reason }
        return nil
    }
}

/// 기본 브랜치에 결합됐다는 git 이력 근거. PR 상태·브랜치 이름·나이·'완료' 표시는 근거가 아니다(git 이력만 본다).
public struct LeftoverIntegration: Sendable, Equatable {
    public enum Method: String, Sendable {
        /// HEAD가 기본 브랜치의 조상(merge · fast-forward).
        case ancestor
        /// `git cherry <기본> <HEAD>`: 기본 브랜치에 없는 커밋이 모두 '-'(같은 패치가 기본 브랜치에 있음 — cherry-pick · rebase).
        case cherry
        /// 합친 변경(merge-base..HEAD)의 patch-id가 기본 브랜치 커밋 하나와 같음(squash merge).
        case squash
    }

    public var method: Method
    /// 비교한 기본 브랜치(짧은 이름: main · origin/main).
    public var target: String
    /// 기본 브랜치에 조상으로 들어가지 않은 이쪽 커밋(전체 SHA, 최신 먼저). 조상 병합이면 비어 있다.
    public var commits: [String]
    /// squash면 같은 patch-id를 가진 기본 브랜치 커밋(전체 SHA).
    public var counterpart: String?

    public init(method: Method, target: String, commits: [String] = [], counterpart: String? = nil) {
        self.method = method
        self.target = target
        self.commits = commits
        self.counterpart = counterpart
    }

    /// 같은 패치로만 결합(squash · cherry-pick). 원래 커밋은 지우면 어느 참조에서도 닿지 않으므로 금고에 SHA를 남긴다.
    public var isEquivalence: Bool { method != .ancestor }

    /// 금고·결과 메시지에 남기는 근거 한 줄.
    public var evidence: String {
        switch method {
        case .ancestor: "조상 병합: \(target)에 포함"
        case .cherry: "cherry-pick 동등: 커밋 \(commits.count)개 모두 \(target)에 같은 패치(git cherry '-')"
        case .squash: "squash 동등: 합친 변경의 patch-id가 \(target)의 \((counterpart ?? "").prefix(12))와 같음"
        }
    }
}

public struct WorktreeLeftover: Sendable, Equatable, Identifiable {
    public var id: String { path }
    /// 저장소(메인 작업 공간 경로).
    public var repo: String
    /// 방 이름 — 세션과 같은 규칙(SessionDetector.projectName)을 워크트리 경로에 적용.
    public var project: String
    public var path: String
    /// 짧은 브랜치 이름. 분리된 HEAD면 nil.
    public var branch: String?
    public var head: String
    public var manager: LeftoverManager
    public var prunable: Bool
    public var locked: Bool
    public var dirtyFiles: Int
    /// HEAD가 기본 브랜치에 들어갔는지. 확인 못 하면 nil.
    public var merged: Bool?
    public var lastCommit: Date?
    /// 실제 할당량(참고용, 시간 제한 안에서만 잰다).
    public var bytes: UInt64
    /// 사용 중 근거("세션 pid N", "Orca 터미널", "프로세스 zsh(pid N)").
    public var inUse: [String]
    public var verdict: LeftoverVerdict

    // 추가 필드(사양 외)
    public var isMain: Bool
    /// 저장소 쪽 방 이름(워크트리 경로의 방이 화면에 없을 때 쓰는 대체 방).
    public var repoProject: String
    /// git status를 끝까지 읽었는지(시간 초과·오류면 false → 보존).
    public var statusKnown: Bool
    /// 지우면 사라지는 무시(ignored) 파일 중 재생성 캐시가 아닌 것(.env 등).
    public var preciousIgnored: [String]
    public var orcaDisplayName: String?
    public var orcaPinned: Bool
    /// /Volumes 아래 작업 공간인데 볼륨이 연결돼 있지 않음.
    public var volumeOffline: Bool
    /// 크기 측정이 시간 제한 안에 끝났는지(false면 bytes는 하한값).
    public var bytesComplete: Bool
    /// 추적 안 된(무시되지 않은) 파일 수. dirtyFiles에 포함된다.
    public var untrackedFiles: Int
    /// 결합 근거(조상 · cherry · squash). nil이면 git 이력으로 결합을 증명하지 못했다.
    public var integration: LeftoverIntegration?
    /// 동등(cherry · squash) 확인을 끝까지 했는지. 시간·횟수 한도로 못 했으면 false(보존).
    public var integrationChecked: Bool
    /// 다른 어떤 참조에도 없고 기본 브랜치와 동등하지도 않은 커밋 수(분리된 HEAD에서만 잰다). 모르면 nil.
    public var uniqueCommits: Int?
    /// 브랜치의 upstream(refs/remotes/origin/x · refs/heads/y).
    public var upstream: String?
    /// 이 브랜치를 upstream으로 삼는 다른 로컬 브랜치(통합 기준이면 보존).
    public var trackedBy: [String]
    /// 메인·형제 작업 공간 안에서 이 작업 공간 안을 가리키는 심볼릭 링크(표시용 '작업공간/경로').
    public var linkReferrers: [String]
    /// 링크 의존 조사를 끝냈는지. nil = 조사하지 않음(정리 후보가 아님) · false = 시간 제한으로 다 못 봄(보존).
    public var linksChecked: Bool?

    /// 방에 잡동사니로 보일 항목인지(메인 작업 공간은 아니다).
    public var isClutter: Bool { !isMain }

    /// git 이력으로 기본 브랜치에 결합됐음이 증명됐는지(조상 또는 동등).
    public var isIntegrated: Bool { merged == true || integration?.isEquivalence == true }

    public init(repo: String, project: String, path: String, branch: String? = nil, head: String = "", manager: LeftoverManager = .git,
                prunable: Bool = false, locked: Bool = false, dirtyFiles: Int = 0, merged: Bool? = nil, lastCommit: Date? = nil, bytes: UInt64 = 0,
                inUse: [String] = [], verdict: LeftoverVerdict = .keep("미판정"), isMain: Bool = false, repoProject: String? = nil, statusKnown: Bool = true,
                preciousIgnored: [String] = [], orcaDisplayName: String? = nil, orcaPinned: Bool = false, volumeOffline: Bool = false, bytesComplete: Bool = true,
                untrackedFiles: Int = 0, integration: LeftoverIntegration? = nil, integrationChecked: Bool = true, uniqueCommits: Int? = nil, upstream: String? = nil,
                trackedBy: [String] = [], linkReferrers: [String] = [], linksChecked: Bool? = nil) {
        self.repo = repo
        self.project = project
        self.path = path
        self.branch = branch
        self.head = head
        self.manager = manager
        self.prunable = prunable
        self.locked = locked
        self.dirtyFiles = dirtyFiles
        self.merged = merged
        self.lastCommit = lastCommit
        self.bytes = bytes
        self.inUse = inUse
        self.verdict = verdict
        self.isMain = isMain
        self.repoProject = repoProject ?? project
        self.statusKnown = statusKnown
        self.preciousIgnored = preciousIgnored
        self.orcaDisplayName = orcaDisplayName
        self.orcaPinned = orcaPinned
        self.volumeOffline = volumeOffline
        self.bytesComplete = bytesComplete
        self.untrackedFiles = untrackedFiles
        self.integration = integration
        self.integrationChecked = integrationChecked
        self.uniqueCommits = uniqueCommits
        self.upstream = upstream
        self.trackedBy = trackedBy
        self.linkReferrers = linkReferrers
        self.linksChecked = linksChecked
    }
}

public struct BranchLeftover: Sendable, Equatable, Identifiable {
    public var id: String { repo + "#" + name }
    public var repo: String
    public var project: String
    public var name: String
    public var merged: Bool
    public var lastCommit: Date?
    /// 이 브랜치를 체크아웃한 작업 공간 경로(끊긴 작업 공간 포함).
    public var checkedOutAt: String?
    public var isDefault: Bool
    /// 원격 추적 브랜치가 사라짐([gone]).
    public var upstreamGone: Bool
    public var verdict: LeftoverVerdict

    // 추가 필드(사양 외)
    /// 브랜치 끝 커밋(정리 직전 재확인용).
    public var head: String
    public var isProtected: Bool
    /// 병합 여부를 실제로 확인했는지(false면 merged=false는 '모름').
    public var mergeKnown: Bool
    /// 결합 근거(조상 · cherry · squash). nil이면 git 이력으로 결합을 증명하지 못했다. upstreamGone([gone])·닫힌 PR은 근거가 아니다.
    public var integration: LeftoverIntegration?
    /// 동등(cherry · squash) 확인을 끝까지 했는지. 시간·횟수 한도로 못 했으면 false(보존).
    public var integrationChecked: Bool
    /// 이 브랜치에서만 닿고 기본 브랜치와 동등하지도 않은 커밋 수 — 0보다 크면 이 브랜치가 그 커밋의 마지막 참조다. 모르면 nil.
    public var uniqueCommits: Int?
    /// upstream(refs/remotes/origin/x · refs/heads/y).
    public var upstream: String?
    /// 이 브랜치를 upstream으로 삼는 다른 로컬 브랜치(통합 기준이면 보존).
    public var trackedBy: [String]

    /// 방에 잡동사니로 보일 항목인지. 기본·보호 브랜치와, 작업 공간에 체크아웃된 브랜치(워크트리 쪽으로 보인다)는 아니다.
    public var isClutter: Bool { !isDefault && !isProtected && checkedOutAt == nil }

    /// git 이력으로 기본 브랜치에 결합됐음이 증명됐는지(조상 또는 동등).
    public var isIntegrated: Bool { merged || integration?.isEquivalence == true }

    public init(repo: String, project: String, name: String, merged: Bool = false, lastCommit: Date? = nil, checkedOutAt: String? = nil, isDefault: Bool = false,
                upstreamGone: Bool = false, verdict: LeftoverVerdict = .keep("미판정"), head: String = "", isProtected: Bool = false, mergeKnown: Bool = true,
                integration: LeftoverIntegration? = nil, integrationChecked: Bool = true, uniqueCommits: Int? = nil, upstream: String? = nil, trackedBy: [String] = []) {
        self.repo = repo
        self.project = project
        self.name = name
        self.merged = merged
        self.lastCommit = lastCommit
        self.checkedOutAt = checkedOutAt
        self.isDefault = isDefault
        self.upstreamGone = upstreamGone
        self.verdict = verdict
        self.head = head
        self.isProtected = isProtected
        self.mergeKnown = mergeKnown
        self.integration = integration
        self.integrationChecked = integrationChecked
        self.uniqueCommits = uniqueCommits
        self.upstream = upstream
        self.trackedBy = trackedBy
    }
}

/// 방(프로젝트) 하나의 부산물.
public struct ProjectLeftovers: Sendable, Equatable, Identifiable {
    public var id: String { project }
    public var project: String
    public var repos: [String]
    public var worktrees: [WorktreeLeftover]
    public var branches: [BranchLeftover]

    public init(project: String, repos: [String], worktrees: [WorktreeLeftover], branches: [BranchLeftover]) {
        self.project = project
        self.repos = repos
        self.worktrees = worktrees
        self.branches = branches
    }

    public var cleanableCount: Int {
        worktrees.filter(\.verdict.isCleanable).count + branches.filter(\.verdict.isCleanable).count
    }

    /// 보존 판정을 받은 잡동사니 수. 메인 작업 공간·기본/보호 브랜치·체크아웃된 브랜치는 세지 않는다.
    public var keepCount: Int {
        worktrees.filter { $0.isClutter && !$0.verdict.isCleanable }.count + branches.filter { $0.isClutter && !$0.verdict.isCleanable }.count
    }

    public var cleanableBytes: UInt64 {
        worktrees.filter(\.verdict.isCleanable).reduce(0) { $0 + $1.bytes }
    }
}

/// 방(프로젝트)에 쌓인 짐의 양 — 장면이 책상 서류 → 바닥 상자 → 벽 쌓기로 그린다(10-25 대표 요청: 워크트리·브랜치가 많을수록 더 복잡하고 쌓인 느낌).
/// 숫자는 전부 실제 개수다. 치울 수 있는 것(병합·미사용)과 남길 것(쓰는 중·미병합)을 따로 센다 — 청소하면 치울 수 있는 것만 사라진다.
public struct RoomClutter: Sendable, Equatable, Codable {
    public var worktrees: Int
    public var branches: Int
    public var cleanableWorktrees: Int
    public var cleanableBranches: Int
    /// 워크트리들이 차지하는 디스크(할당량 합).
    public var bytes: UInt64
    /// 커밋·푸시·배포로 쌓인 서류(프로젝트 청소가 치운다).
    public var papers: Int

    public init(worktrees: Int = 0, branches: Int = 0, cleanableWorktrees: Int = 0, cleanableBranches: Int = 0, bytes: UInt64 = 0, papers: Int = 0) {
        self.worktrees = worktrees
        self.branches = branches
        self.cleanableWorktrees = cleanableWorktrees
        self.cleanableBranches = cleanableBranches
        self.bytes = bytes
        self.papers = papers
    }

    /// 짐의 무게: 워크트리 3 · 브랜치 1 · 서류 1. 장면의 단계(0~5)는 여기서 나온다.
    public var load: Int { worktrees * 3 + branches + papers }
    public var cleanableLoad: Int { cleanableWorktrees * 3 + cleanableBranches + papers }
    /// 0 깨끗 · 1 책상 위 서류 · 2 서류 더미 + 상자 하나 · 3 바닥에 상자들 · 4 벽에 2단 · 5 천장까지(창문 가림).
    public var level: Int {
        switch load {
        case 0: 0
        case 1...2: 1
        case 3...6: 2
        case 7...14: 3
        case 15...30: 4
        default: 5
        }
    }
    public var isEmpty: Bool { load == 0 }

    public init(_ project: ProjectLeftovers, papers: Int = 0) {
        // 메인 작업 공간·기본/보호 브랜치·워크트리에 체크아웃된 브랜치(워크트리 쪽으로 이미 센다)는 짐이 아니다.
        let worktrees = project.worktrees.filter(\.isClutter)
        let branches = project.branches.filter(\.isClutter)
        self.init(worktrees: worktrees.count, branches: branches.count,
                  cleanableWorktrees: worktrees.filter(\.verdict.isCleanable).count, cleanableBranches: branches.filter(\.verdict.isCleanable).count,
                  bytes: worktrees.reduce(0) { $0 + $1.bytes }, papers: papers)
    }
}

/// 판정 규칙. 스캐너와 정리기(정리 직전 재확인)가 같은 함수를 쓴다.
/// 실제 상태만 본다: git 이력(조상·동등) · 미커밋/추적 안 된 파일 · 세션·Orca 터미널·프로세스(작업 폴더·열린 파일) · 링크 의존.
/// 오래됐다는 것, '완료'·'쉬는 중' 표시, 원격 브랜치가 사라졌다는 것([gone])·닫힌 PR은 정리 근거가 아니다.
public enum LeftoverRules {
    public static let protectedBranchNames: Set<String> = ["main", "master", "develop", "dev", "production"]
    /// 유일 커밋은 이 수까지만 센다(그 이상은 'N개 이상').
    public static let uniqueCommitCap = 1000
    /// 동등(squash · cherry-pick)으로 판정해 지운 항목의 금고 메모 머리말.
    public static let equivalenceNote = "squash/cherry-pick 동등으로 판정 · 커밋 SHA 보존"

    public static func isProtected(_ branch: String) -> Bool {
        protectedBranchNames.contains(branch) || branch.hasPrefix("release/")
    }

    /// 워크트리: 메인 → 잠금 → 사용 중 → (Orca 고정·외장 미연결) → 상태 미확인·미커밋 변경(추적 안 된 파일 포함)·보존 파일·보호 브랜치
    /// → 통합 기준(다른 브랜치의 upstream) → 링크 의존 → 병합 미확인 → 결합 안 됨(분리된 HEAD는 유일 커밋 수).
    public static func verdict(for item: WorktreeLeftover, defaultBranch: String?) -> LeftoverVerdict {
        if item.isMain { return .keep("메인 작업 공간") }
        if item.locked { return .keep("잠금 설정됨") }
        if let first = item.inUse.first { return .keep("사용 중: " + first + (item.inUse.count > 1 ? " 외 \(item.inUse.count - 1)" : "")) }
        if item.orcaPinned { return .keep("Orca에서 고정됨") }
        if item.volumeOffline { return .keep("외장 볼륨 연결 안 됨") }
        if !item.prunable {
            if !item.statusKnown { return .keep("상태 확인 실패") }
            if item.dirtyFiles > 0 { return .keep(dirtyReason(total: item.dirtyFiles, untracked: item.untrackedFiles)) }
            if let first = item.preciousIgnored.first { return .keep("지우면 사라질 무시 파일 \(item.preciousIgnored.count)개(\(first))") }
            if let branch = item.branch, branch == defaultBranch || isProtected(branch) { return .keep("보호 브랜치(\(branch)) 작업 공간") }
            if !item.trackedBy.isEmpty { return .keep(trackedReason(item.trackedBy)) }
            if !item.linkReferrers.isEmpty { return .keep(linkReason(item.linkReferrers)) }
            if item.linksChecked == false { return .keep("링크 의존 확인 못 함(시간 제한)") }
        }
        guard let merged = item.merged else { return .keep("병합 여부 확인 불가") }
        if !merged && item.integration?.isEquivalence != true {
            // 분리된 HEAD는 작업 공간이 그 커밋의 유일한 참조일 수 있다 → 끊긴 기록 정리(prune)라도 결합된 것만.
            if item.branch == nil {
                if let unique = item.uniqueCommits, unique > 0 { return .keep(uniqueReason(unique)) }
                return .keep(item.integrationChecked ? "분리된 HEAD 커밋 병합 안 됨" : "분리된 HEAD 커밋 병합 안 됨(동등 확인 못 함)")
            }
            // 끊긴 작업 공간의 브랜치는 브랜치가 커밋을 지킨다 → 기록만 정리할 수 있다.
            if !item.prunable { return .keep(item.integrationChecked ? "병합 안 됨" : "병합 안 됨(동등 확인 못 함)") }
        }
        if item.prunable { return .cleanable(.pruneWorktreeMetadata) }
        return .cleanable(item.manager == .orca ? .orcaRemoveWorktree : .removeWorktree)
    }

    /// 브랜치: 기본 → 보호 → 체크아웃됨 → 통합 기준 → 병합 미확인 → 결합 안 됨(유일 커밋이면 마지막 참조). 조상 병합은 -d, 동등 병합은 기록한 SHA일 때만 지운다.
    public static func verdict(for item: BranchLeftover) -> LeftoverVerdict {
        if item.isDefault { return .keep("기본 브랜치") }
        if item.isProtected { return .keep("보호 브랜치") }
        if let path = item.checkedOutAt { return .keep("작업 공간에 체크아웃됨(\((path as NSString).lastPathComponent))") }
        if !item.trackedBy.isEmpty { return .keep(trackedReason(item.trackedBy)) }
        if !item.mergeKnown { return .keep("병합 여부 확인 불가") }
        if !item.isIntegrated {
            if let unique = item.uniqueCommits, unique > 0 { return .keep(uniqueReason(unique)) }
            return .keep(item.integrationChecked ? "병합 안 됨" : "병합 안 됨(동등 확인 못 함)")
        }
        return .cleanable(.deleteMergedBranch)
    }

    /// 결합(동등) 근거만 있으면 정리할 수 있는지 — 비싼 동등 확인(cherry · patch-id)은 판정이 거기에만 걸릴 때만 한다.
    public static func blockedOnlyByIntegration(_ item: WorktreeLeftover, defaultBranch: String?) -> Bool {
        guard item.merged == false, item.integration?.isEquivalence != true, !verdict(for: item, defaultBranch: defaultBranch).isCleanable else { return false }
        var integrated = item
        integrated.integration = LeftoverIntegration(method: .cherry, target: "")
        return verdict(for: integrated, defaultBranch: defaultBranch).isCleanable
    }

    public static func blockedOnlyByIntegration(_ item: BranchLeftover) -> Bool {
        guard item.mergeKnown, !item.merged, item.integration?.isEquivalence != true, !verdict(for: item).isCleanable else { return false }
        var integrated = item
        integrated.integration = LeftoverIntegration(method: .cherry, target: "")
        return verdict(for: integrated).isCleanable
    }

    public static func dirtyReason(total: Int, untracked: Int) -> String {
        untracked > 0 ? "미커밋 변경 \(total)개(추적 안 된 파일 \(untracked)개)" : "미커밋 변경 \(total)개"
    }

    public static func uniqueReason(_ count: Int) -> String {
        "미결합 커밋 \(count >= uniqueCommitCap ? "\(count)개 이상" : "\(count)개")의 유일한 참조"
    }

    public static func trackedReason(_ branches: [String]) -> String {
        "통합 기준 브랜치(\(branches[0])" + (branches.count > 1 ? " 외 \(branches.count - 1)개" : "") + "의 upstream)"
    }

    public static func linkReason(_ referrers: [String]) -> String {
        "링크가 이 안을 가리킴(\(referrers[0])" + (referrers.count > 1 ? " 외 \(referrers.count - 1)개" : "") + ")"
    }
}
