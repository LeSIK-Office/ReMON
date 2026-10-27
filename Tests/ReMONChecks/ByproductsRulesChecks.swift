import Darwin
import Foundation
import ReMONCore

// 부산물 판정 규칙 검사(10-25 CEO 공유 — 실제 프로젝트를 정리한 Codex 규칙과 맞춤). 시험 저장소는 /private/tmp/remon-byproducts-rules에만 만든다.
// 1 실제 상태(추적 안 된 파일 · 열린 파일) 2 지우기 전 기록 · git 이력만 결합 근거(조상 · git cherry · squash patch-id) · 마지막 참조 보호
// 3 판정(분리된 HEAD · 통합 기준 · 기본 브랜치 작업 공간) 4 링크 의존 5 지운 뒤 확인(옮겨짐 · Orca 목록 · 함께 지워진 브랜치의 커밋) 6 보고(SHA · 근거).

let rulesRoot = "/private/tmp/remon-byproducts-rules"

/// 가짜 Orca: 작업 공간마다 'rm'이 실제로 하는 일을 정한다(사후 확인이 잡아내야 하는 경우들). 진짜 Orca는 부르지 않는다.
final class RulesFakeOrca: @unchecked Sendable {
    enum Removal: Sendable {
        /// git worktree remove + 목록에서 뺌.
        case normal
        /// 지우지 않고 git worktree move로 옆에 숨긴 뒤 목록에서만 뺌('지우는 중' 응답만 믿으면 지운 것으로 착각한다).
        case moveHidden(to: String)
        /// 지우지만 Orca 목록에는 남김.
        case keepRow
        /// 지우면서 그 브랜치도 함께 지움.
        case deleteBranch(String)
        /// 지우고 브랜치도 지운 뒤 main을 병합 전으로 되감음(함께 지워진 브랜치의 커밋이 어디에도 남지 않는 경우).
        case deleteBranchRewind(branch: String, main: String)
    }

    struct Row {
        var row: OrcaWorktree
        var repo: String
        var removal: Removal
    }

    private let lock = NSLock()
    private var rows: [Row]
    let git: String

    init(rows: [Row], git: String) {
        self.rows = rows
        self.git = git
    }

    var currentRows: [OrcaWorktree] { lock.lock(); defer { lock.unlock() }; return rows.map(\.row) }

    func respond(_ args: [String]) -> CommandResult {
        func json(_ object: [String: Any]) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self) }
        if args == ["worktree", "list", "--json"] {
            let list = currentRows.map { row -> [String: Any] in
                ["path": row.path, "branch": row.branch.map { "refs/heads/" + $0 } ?? "", "isMainWorktree": row.isMainWorktree, "repoId": row.repoId,
                 "displayName": row.displayName, "isPinned": row.isPinned]
            }
            return CommandResult(status: 0, stdout: json(["id": "fake", "ok": true, "result": ["worktrees": list, "totalCount": list.count, "truncated": false]]))
        }
        if args == ["terminal", "list", "--json"] {
            return CommandResult(status: 0, stdout: json(["id": "fake", "ok": true, "result": ["terminals": [Any]()]]))
        }
        if args.count == 5, args[0] == "worktree", args[1] == "rm", args[2] == "--worktree", args[3].hasPrefix("path:"), args[4] == "--json" {
            let path = String(args[3].dropFirst("path:".count))
            lock.lock()
            let found = rows.first { $0.row.path == path }
            lock.unlock()
            func failed(_ message: String) -> CommandResult { CommandResult(status: 1, stdout: json(["id": "fake", "ok": false, "error": ["code": "remove_failed", "message": message]])) }
            guard let found else { return failed("목록에 없음") }
            func run(_ arguments: [String]) -> CommandResult { setupGit(git, ["-C", found.repo] + arguments) }
            var keepRow = false
            switch found.removal {
            case .normal:
                let removed = run(["worktree", "remove", path])
                guard removed.succeeded else { return failed(removed.stderr) }
            case .moveHidden(let target):
                let moved = run(["worktree", "move", path, target])
                guard moved.succeeded else { return failed(moved.stderr) }
            case .keepRow:
                let removed = run(["worktree", "remove", path])
                guard removed.succeeded else { return failed(removed.stderr) }
                keepRow = true
            case .deleteBranch(let branch):
                let removed = run(["worktree", "remove", path])
                guard removed.succeeded else { return failed(removed.stderr) }
                _ = run(["update-ref", "-d", "refs/heads/" + branch])
            case .deleteBranchRewind(let branch, let main):
                let removed = run(["worktree", "remove", path])
                guard removed.succeeded else { return failed(removed.stderr) }
                _ = run(["update-ref", "-d", "refs/heads/" + branch])
                _ = run(["update-ref", "refs/heads/main", main])
            }
            if !keepRow {
                lock.lock()
                rows.removeAll { $0.row.path == path }
                lock.unlock()
            }
            return CommandResult(status: 0, stdout: json(["id": "fake", "ok": true, "result": ["removed": true]]))
        }
        return CommandResult(status: 2, stderr: "가짜 Orca가 모르는 명령: \(args.joined(separator: " "))")
    }
}

/// 부모가 바로 끝나는 프로세스(launchd 아래로 감)를 띄워 pid를 돌려준다. 이 검사가 직접 띄운 자식은 '이 프로세스의 도우미'로 빠지므로 손자로 띄운다.
func spawnOrphan(_ command: [String]) -> Int32? {
    let script = command.map(ResumeKey.quote).joined(separator: " ") + " </dev/null >/dev/null 2>&1 & echo $!"
    let result = Shell.capture("/bin/sh", ["-c", script], timeout: 10)
    return Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
}

func byproductsRulesCheck() {
    let fm = FileManager.default
    let root = rulesRoot
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root + "/wt", withIntermediateDirectories: true)
    let git = LeftoverTools.findGit()
    var setupFailures = 0
    @discardableResult func g(_ arguments: [String]) -> CommandResult {
        let result = setupGit(git, arguments)
        if !result.succeeded {
            setupFailures += 1
            print("  준비 실패: git \(arguments.joined(separator: " ")) → \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result
    }
    func write(_ path: String, _ text: String) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: Data(text.utf8))
    }
    func commit(_ directory: String, _ file: String, _ text: String, _ message: String) {
        write(directory + "/" + file, text)
        g(["-C", directory, "add", "-A"])
        g(["-C", directory, "commit", "-q", "-m", message])
    }
    /// 그 파일만 커밋한다(메인 작업 공간의 추적 안 된 .claude 링크는 건드리지 않는다). cherry-pick 전에 main을 한 칸 옮겨
    /// 같은 부모·같은 초에 똑같은 커밋이 다시 만들어지는 일(빨리 감기와 같아져 '조상'이 됨)을 막는다.
    func commitOnly(_ directory: String, _ file: String, _ text: String, _ message: String) {
        write(directory + "/" + file, text)
        g(["-C", directory, "add", "--", file])
        g(["-C", directory, "commit", "-q", "-m", message])
    }
    func sha(_ directory: String, _ revision: String) -> String { g(["-C", directory, "rev-parse", revision]).stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
    func initRepo(_ path: String) {
        g(["init", "-q", "-b", "main", path])
        g(["-C", path, "config", "user.name", "ReMON Check"])
        g(["-C", path, "config", "user.email", "check@remon.invalid"])
    }

    // 0) 직접 계산하는 patch-id가 git patch-id --stable과 같은지(squash 동등 판정의 바탕).
    patchIDAgreementCheck(git: git, folder: root + "/aux")

    // 1) 저장소 A: squash 병합 · cherry-pick · 미결합(유일) · 다른 참조가 지키는 커밋 · upstream 사라짐([gone]) · 통합 기준.
    let repo = root + "/repo"
    initRepo(repo)
    commit(repo, ".gitignore", "node_modules/\n.env\n", "c1 gitignore")
    commit(repo, "README.md", "rules check\nline2\nline3\n", "c2 readme")
    commit(repo, "packages/lib/index.js", "export const lib = 1\n", "c3 lib")
    g(["-C", repo, "checkout", "-q", "-b", "feature/squash"])
    commit(repo, "README.md", "rules check\nline2 squashed\nline3\n", "s1 edit readme")
    commit(repo, "squash.txt", "squash work\n", "s2 add file")
    let squashHead = sha(repo, "feature/squash")
    let squashCommits = Set([squashHead, sha(repo, "feature/squash~1")])
    g(["-C", repo, "checkout", "-q", "main"])
    g(["-C", repo, "merge", "-q", "--squash", "feature/squash"])
    g(["-C", repo, "commit", "-q", "-m", "squash feature/squash (#1)"])
    let squashCommit = sha(repo, "main")
    g(["-C", repo, "checkout", "-q", "-b", "feature/pick"])
    commit(repo, "pick1.txt", "pick one\n", "p1")
    commit(repo, "pick2.txt", "pick two\n", "p2")
    let pickHead = sha(repo, "feature/pick")
    g(["-C", repo, "checkout", "-q", "main"])
    commitOnly(repo, "main-1.txt", "main moves before pick\n", "m1")
    g(["-C", repo, "cherry-pick", "feature/pick~1", "feature/pick"])
    g(["-C", repo, "checkout", "-q", "-b", "feature/unique"])
    commit(repo, "unique1.txt", "u1\n", "u1")
    commit(repo, "unique2.txt", "u2\n", "u2")
    g(["-C", repo, "checkout", "-q", "-b", "feature/shared", "main"])
    commit(repo, "shared.txt", "shared\n", "sh1")
    g(["-C", repo, "branch", "feature/shared-copy", "feature/shared"])
    g(["-C", repo, "checkout", "-q", "-b", "feature/gone", "main"])
    commit(repo, "gone.txt", "gone\n", "g1")
    g(["-C", repo, "checkout", "-q", "main"])
    for (key, value) in [("branch.feature/gone.remote", "origin"), ("branch.feature/gone.merge", "refs/heads/feature/gone"),
                         ("remote.origin.url", root + "/no-such-remote.git"), ("remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*")] {
        g(["-C", repo, "config", key, value])
    }
    g(["-C", repo, "branch", "feature/base2", "main"])
    g(["-C", repo, "branch", "feature/child2", "main"])
    g(["-C", repo, "branch", "--set-upstream-to=feature/base2", "feature/child2"])

    // 2) 작업 공간들.
    func worktree(_ name: String, detach: Bool = false) -> String {
        let path = root + "/wt/" + name
        if detach { g(["-C", repo, "worktree", "add", "-q", "--detach", path, "main"]) } else { g(["-C", repo, "worktree", "add", "-q", "-b", "wt/" + name, path, "main"]) }
        return path
    }
    let untracked = worktree("untracked")
    write(untracked + "/notes/todo.txt", "todo\n")
    write(untracked + "/notes/deep/idea.txt", "idea\n")
    let linked = worktree("linked")
    let sibling = worktree("sibling")
    try? fm.createDirectory(atPath: sibling + "/node_modules", withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: sibling + "/node_modules/lib", withDestinationPath: linked + "/packages/lib")
    let claudeTarget = worktree("claude-target")
    try? fm.createDirectory(atPath: repo + "/.claude/worktrees", withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: repo + "/.claude/worktrees/agent-link", withDestinationPath: claudeTarget)
    let detachedUnique = worktree("detached-unique", detach: true)
    commit(detachedUnique, "detached.txt", "only here\n", "du1 detached only")
    let detachedPicked = worktree("detached-picked", detach: true)
    commit(detachedPicked, "picked-detached.txt", "picked\n", "dp1 detached picked")
    commitOnly(repo, "main-2.txt", "main moves before detached pick\n", "m2")
    g(["-C", repo, "cherry-pick", sha(detachedPicked, "HEAD")])
    let base = worktree("base")
    g(["-C", repo, "branch", "feature/child", "wt/base"])
    g(["-C", repo, "branch", "--set-upstream-to=wt/base", "feature/child"])
    let squashWorktree = worktree("squash-wt")
    commit(squashWorktree, "sqwt1.txt", "squash wt one\n", "sqwt1")
    commit(squashWorktree, "sqwt2.txt", "squash wt two\n", "sqwt2")
    let squashWorktreeHead = sha(squashWorktree, "HEAD")
    g(["-C", repo, "merge", "-q", "--squash", "wt/squash-wt"])
    g(["-C", repo, "commit", "-q", "-m", "squash wt/squash-wt (#2)"])
    let openPath = worktree("open")
    let openLive = worktree("open-live")
    let orcaMoved = worktree("orca-moved")
    let orcaSticky = worktree("orca-sticky")
    let orcaAlongside = worktree("orca-alongside")
    commit(orcaAlongside, "oa1.txt", "alongside one\n", "oa1")
    commit(orcaAlongside, "oa2.txt", "alongside two\n", "oa2")
    g(["-C", repo, "merge", "-q", "--squash", "wt/orca-alongside"])
    g(["-C", repo, "commit", "-q", "-m", "squash wt/orca-alongside (#3)"])
    let gitMoved = worktree("git-moved")

    // 3) 저장소 B: 메인 작업 공간은 다른 브랜치, 기본 브랜치(main)는 링크된 작업 공간에 있음(통합 대상의 작업 공간 → 보존).
    let repoB = root + "/repo-b"
    initRepo(repoB)
    commit(repoB, "b.txt", "b\n", "b1")
    g(["-C", repoB, "checkout", "-q", "-b", "side"])
    let bMain = root + "/wt/b-main"
    g(["-C", repoB, "worktree", "add", "-q", bMain, "main"])

    // 4) 저장소 C: 병합(--no-ff)된 브랜치의 Orca 작업 공간 — 가짜 Orca가 브랜치까지 지우고 main을 되감는다.
    let repoC = root + "/repo-c"
    initRepo(repoC)
    commit(repoC, "c.txt", "c\n", "c1")
    let cBefore = sha(repoC, "main")
    g(["-C", repoC, "checkout", "-q", "-b", "c-feature"])
    commit(repoC, "cf.txt", "feature\n", "cf1")
    let cFeatureHead = sha(repoC, "c-feature")
    g(["-C", repoC, "checkout", "-q", "main"])
    g(["-C", repoC, "merge", "-q", "--no-ff", "-m", "merge c-feature", "c-feature"])
    let cWorktree = root + "/wt/c-wt"
    g(["-C", repoC, "worktree", "add", "-q", cWorktree, "c-feature"])
    check(setupFailures == 0, "시험 저장소 3개 준비: squash·cherry-pick·유일 커밋·[gone]·통합 기준 브랜치 · 링크된 작업 공간 16개(링크·분리된 HEAD·가짜 Orca·가짜 git)")

    // 5) 가짜 도구: Orca(경로마다 다른 rm) · git(이 경로의 worktree remove는 지우지 않고 옆에 숨긴다).
    let movedHidden = root + "/wt/.orca-moved-gone"
    let gitMovedHidden = root + "/wt/.git-moved-hidden"
    let fakeOrca = RulesFakeOrca(rows: [
        .init(row: OrcaWorktree(path: orcaMoved, branch: "wt/orca-moved", repoId: "fake-a", displayName: "숨겨 옮기는 Orca"), repo: repo, removal: .moveHidden(to: movedHidden)),
        .init(row: OrcaWorktree(path: orcaSticky, branch: "wt/orca-sticky", repoId: "fake-a", displayName: "목록에 남는 Orca"), repo: repo, removal: .keepRow),
        .init(row: OrcaWorktree(path: orcaAlongside, branch: "wt/orca-alongside", repoId: "fake-a", displayName: "브랜치도 지우는 Orca"), repo: repo,
              removal: .deleteBranch("wt/orca-alongside")),
        .init(row: OrcaWorktree(path: cWorktree, branch: "c-feature", repoId: "fake-c", displayName: "main을 되감는 Orca"), repo: repoC,
              removal: .deleteBranchRewind(branch: "c-feature", main: cBefore)),
    ], git: git)
    let fakeOrcaPath = root + "/fake-bin/orca" // 없는 경로 — 실행기가 가로챈다
    let recorder = CommandRecorder()
    let runner: CommandRunner = { executable, arguments, timeout in
        recorder.record(executable, arguments)
        if executable == fakeOrcaPath { return fakeOrca.respond(arguments) }
        if (executable as NSString).lastPathComponent == "orca" { return CommandResult(status: 99, stderr: "진짜 Orca 호출 차단") }
        if arguments.suffix(3) == ["worktree", "remove", gitMoved] {
            do {
                try FileManager.default.moveItem(atPath: gitMoved, toPath: gitMovedHidden)
                return CommandResult(status: 0)
            } catch {
                return CommandResult(status: 1, stderr: "\(error)")
            }
        }
        return LeftoverTools.defaultRunner(executable, arguments, timeout)
    }
    let tools = LeftoverTools(git: git, orca: fakeOrcaPath, run: runner)
    var options = LeftoverScanOptions()
    options.codexWorktreesRoot = root + "/codex-worktrees"
    options.projectName = { _ in "rules" }

    // 6) 실제 상태: 작업 폴더는 바깥이지만 안의 파일을 연 프로세스(살아 있는 tail · 주입한 편집기).
    let tailPID = spawnOrphan(["/usr/bin/tail", "-f", openLive + "/README.md"])
    defer { if let tailPID { kill(tailPID, SIGTERM) } }
    var live = ProcessPresence.live()
    for _ in 0..<30 where !live.contains(where: { $0.pid == tailPID && $0.openFiles.contains { $0.hasSuffix("/wt/open-live/README.md") } }) {
        Thread.sleep(forTimeInterval: 0.1)
        live = ProcessPresence.live()
    }
    let tailSeen = live.first { $0.pid == tailPID }
    check(tailPID != nil && tailSeen?.openFiles.contains { $0.hasSuffix("/wt/open-live/README.md") } == true && tailSeen?.cwd.hasPrefix(root) == false,
          "프로세스 스냅샷: 작업 폴더가 바깥인 tail(pid \(tailPID.map(String.init) ?? "-"))의 열린 파일까지 읽음")
    let editor = ProcessPresence(pid: 4_242_424, name: "editor", cwd: "", openFiles: [openPath + "/README.md"])

    // 7) 조사(읽기 전용).
    let beforeScan = treeSnapshot(root, excluding: ["audit", "vault", "aux"])
    let report = LeftoverScanner.report(devRoot: root, sessions: [], orcaTerminals: [], orcaWorktrees: fakeOrca.currentRows, processes: live + [editor], tools: tools, options: options)
    check(treeSnapshot(root, excluding: ["audit", "vault", "aux"]) == beforeScan && report.repoCount == 3,
          "조사는 읽기 전용: 저장소 3개 · 파일·인덱스 변화 없음 · \(String(format: "%.0fms", report.elapsed * 1000))")
    let scanCalls = recorder.calls
    let scanKinds = Set(scanCalls.compactMap { call -> String? in
        var rest = call.args[...]
        while let first = rest.first, first.hasPrefix("-") { rest = rest.dropFirst(first == "-C" || first == "-c" ? 2 : 1) }
        return rest.first
    })
    check(scanCalls.allSatisfy { isReadOnlyCommand($0.exe, $0.args) } && scanKinds.isSuperset(of: ["cherry", "rev-list", "diff", "log"]),
          "조사 명령 \(scanCalls.count)회 모두 읽기 전용(\(scanKinds.sorted().joined(separator: "·")))")

    let worktrees = Dictionary(report.projects.flatMap(\.worktrees).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    let branches = Dictionary(report.projects.flatMap(\.branches).map { ($0.repo + "#" + $0.name, $0) }, uniquingKeysWith: { first, _ in first })
    func branch(_ name: String, in repository: String? = nil) -> BranchLeftover? { branches[(repository ?? repo) + "#" + name] }
    func expect(_ path: String, _ verdict: LeftoverVerdict, _ label: String) {
        check(worktrees[path]?.verdict == verdict, "\(label) → \(verdictText(worktrees[path]?.verdict))")
    }
    func expectBranch(_ name: String, _ verdict: LeftoverVerdict, _ label: String, in repository: String? = nil) {
        check(branch(name, in: repository)?.verdict == verdict, "\(label) → \(verdictText(branch(name, in: repository)?.verdict))")
    }

    // 규칙 2: 결합 근거는 git 이력만 — squash(patch-id) · cherry-pick(git cherry '-') · 마지막 참조 보호.
    let squash = branch("feature/squash")
    check(squash?.verdict == .cleanable(.deleteMergedBranch) && squash?.integration?.method == .squash && squash?.integration?.counterpart == squashCommit
          && Set(squash?.integration?.commits ?? []) == squashCommits && squash?.merged == false,
          "squash 병합 브랜치(커밋 2개 → main 커밋 1개) → \(verdictText(squash?.verdict)) · \(squash?.integration?.evidence ?? "근거 없음")")
    let pick = branch("feature/pick")
    check(pick?.verdict == .cleanable(.deleteMergedBranch) && pick?.integration?.method == .cherry && pick?.integration?.commits.count == 2,
          "cherry-pick 브랜치 → \(verdictText(pick?.verdict)) · \(pick?.integration?.evidence ?? "근거 없음")")
    check(branch("feature/unique")?.verdict == .keep("미결합 커밋 2개의 유일한 참조") && branch("feature/unique")?.uniqueCommits == 2,
          "미결합 커밋이 여기에만 있는 브랜치 → \(verdictText(branch("feature/unique")?.verdict))")
    check(branch("feature/shared")?.verdict == .keep("병합 안 됨") && branch("feature/shared-copy")?.verdict == .keep("병합 안 됨") && branch("feature/shared")?.uniqueCommits == 0,
          "같은 커밋을 다른 브랜치도 지키면 '유일한 참조'가 아님 → \(verdictText(branch("feature/shared")?.verdict))(병합 안 됨이라 보존)")
    let gone = branch("feature/gone")
    check(gone?.upstreamGone == true && gone?.verdict == .keep("미결합 커밋 1개의 유일한 참조") && gone?.integration == nil,
          "원격 브랜치가 사라짐([gone] — 닫힌 PR처럼 '끝난' 표시)이어도 병합 근거가 아님 → \(verdictText(gone?.verdict))")

    // 규칙 1·3: 실제 상태 · 판정.
    expect(untracked, .keep("미커밋 변경 2개(추적 안 된 파일 2개)"), "추적 안 된 파일 2개(하위 폴더 안까지 하나하나 셈)")
    expect(detachedUnique, .keep("미결합 커밋 1개의 유일한 참조"), "분리된 HEAD에만 있는 커밋")
    check(worktrees[detachedPicked]?.verdict == .cleanable(.removeWorktree) && worktrees[detachedPicked]?.integration?.method == .cherry,
          "분리된 HEAD 커밋이 main에 cherry-pick됨 → \(verdictText(worktrees[detachedPicked]?.verdict))")
    expect(base, .keep("통합 기준 브랜치(feature/child의 upstream)"), "다른 브랜치가 upstream으로 삼는 작업 공간")
    expectBranch("feature/base2", .keep("통합 기준 브랜치(feature/child2의 upstream)"), "다른 브랜치가 upstream으로 삼는 브랜치")
    expectBranch("feature/child", .cleanable(.deleteMergedBranch), "통합 기준을 추적하는 쪽(병합됨)")
    expect(bMain, .keep("보호 브랜치(main) 작업 공간"), "기본 브랜치(main)가 체크아웃된 링크 작업 공간")
    check(worktrees[squashWorktree]?.verdict == .cleanable(.removeWorktree) && worktrees[squashWorktree]?.integration?.method == .squash,
          "squash 병합된 브랜치의 작업 공간 → \(verdictText(worktrees[squashWorktree]?.verdict))")
    expect(openPath, .keep("사용 중: 열린 파일 editor(pid 4242424)"), "작업 폴더는 바깥, 안의 파일을 연 편집기")
    check(worktrees[openLive]?.verdict.keepReason?.contains("열린 파일 tail(pid \(tailPID.map(String.init) ?? "-"))") == true,
          "살아 있는 프로세스가 안의 파일을 엶 → \(verdictText(worktrees[openLive]?.verdict))")

    // 규칙 4: 링크 의존.
    expect(linked, .keep("링크가 이 안을 가리킴(sibling/node_modules/lib)"), "형제 작업 공간의 node_modules 링크가 가리키는 작업 공간")
    expect(claudeTarget, .keep("링크가 이 안을 가리킴(repo/.claude/worktrees/agent-link)"), "메인 작업 공간의 .claude/worktrees 링크가 가리키는 작업 공간")
    expect(sibling, .cleanable(.removeWorktree), "링크를 가진 쪽(가리킴을 당하지 않음)")
    for path in [orcaMoved, orcaSticky, orcaAlongside, cWorktree] where worktrees[path]?.verdict != .cleanable(.orcaRemoveWorktree) {
        check(false, "가짜 Orca 작업 공간 \((path as NSString).lastPathComponent) → \(verdictText(worktrees[path]?.verdict))")
    }
    check(worktrees[gitMoved]?.verdict == .cleanable(.removeWorktree) && [orcaMoved, orcaSticky, orcaAlongside, cWorktree].allSatisfy { worktrees[$0]?.verdict == .cleanable(.orcaRemoveWorktree) },
          "사후 확인용 작업 공간 5개(가짜 Orca 4 · 가짜 git 1) 정리 가능")

    // 8) 드라이런: 동등 병합 브랜치는 기록한 SHA일 때만 지우는 update-ref -d로 계획 — 쓰기 없음.
    let audit = AuditLog(url: URL(fileURLWithPath: root + "/audit/actions.jsonl"))
    let callsBeforeDry = recorder.calls.count
    let dry = squash.map { LeftoverCleaner.clean(worktrees: [], branches: [$0], dryRun: true, audit: audit, tools: tools, options: options) } ?? []
    check(dry.count == 1 && dry[0].ok && dry[0].dryRun && dry[0].command == [git, "-C", repo, "update-ref", "-d", "refs/heads/feature/squash", squashHead]
          && recorder.calls.dropFirst(callsBeforeDry).allSatisfy { isReadOnlyCommand($0.exe, $0.args) },
          "드라이런: \(dry.first?.message ?? "-")")

    // 9) 실제 정리(금고 기록 → 실행 → 사후 확인).
    let vault = RecoveryVault(folder: URL(fileURLWithPath: root + "/vault"))
    vault.audit = audit
    let real = LeftoverCleaner.clean(report.projects, dryRun: false, audit: audit, sessions: [], orcaTerminals: [], tools: tools, options: options, vault: vault)
    let results = Dictionary(real.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for result in real { print("  정리 결과: \(result.ok ? "OK " : "--  ")\((result.id as NSString).lastPathComponent) · \(result.action.rawValue) · \(result.message)") }
    let entries = vault.all()
    func worktreeEntry(_ path: String) -> RecoveryEntry? { entries.first { $0.kind == .worktree && $0.worktreePath == path } }
    func branchEntry(_ name: String, _ repository: String = repo) -> RecoveryEntry? { entries.first { $0.kind == .branch && $0.branch == name && $0.repo == repository } }

    // 링크 대상은 건드리지 않는다: 링크를 가진 작업 공간을 지워도 가리키던 작업 공간·파일은 그대로.
    check(results[sibling]?.ok == true && !fm.fileExists(atPath: sibling) && fm.fileExists(atPath: linked + "/packages/lib/index.js") && fm.fileExists(atPath: claudeTarget),
          "링크를 가진 작업 공간 정리 · 링크 대상(linked/packages/lib) 그대로 · \(results[sibling]?.message ?? "-")")
    // 규칙 2·6: 금고 근거(경로 · 브랜치 · HEAD 전체 SHA · upstream · 결합 근거 · 동등이면 커밋 SHA) + 사후 확인 기록.
    let squashWorktreeEntry = worktreeEntry(squashWorktree)
    check(results[squashWorktree]?.ok == true && squashWorktreeEntry?.status == .held && squashWorktreeEntry?.head == squashWorktreeHead && squashWorktreeEntry?.branch == "wt/squash-wt"
          && squashWorktreeEntry?.note?.contains(LeftoverRules.equivalenceNote) == true && squashWorktreeEntry?.commits?.count == 2
          && squashWorktreeEntry?.evidence?.contains("squash 동등") == true,
          "squash 작업 공간 금고 기록: HEAD \(squashWorktreeEntry?.head ?? "-") · \(squashWorktreeEntry?.note ?? "-")")
    let squashVerification = squashWorktreeEntry?.verification ?? ""
    check(["폴더 없음", "git 목록에서 빠짐", "git 관리 기록 없음", "브랜치 wt/squash-wt 남아 있음(커밋 보존)"].allSatisfy(squashVerification.contains)
          && results[squashWorktree]?.message.contains(String(squashWorktreeHead.prefix(12))) == true && results[squashWorktree]?.evidence.contains(squashWorktreeHead) == true,
          "사후 확인 기록: \(squashVerification)")
    check(results[detachedPicked]?.ok == true && results[detachedPicked]?.verification.contains { $0.hasPrefix("분리된 HEAD 커밋 보존 확인") } == true,
          "분리된 HEAD 작업 공간 정리 · 지운 뒤 커밋 보존 다시 확인(\(results[detachedPicked]?.verification.last ?? "-"))")

    // 규칙 5: 옮겨진 것은 지운 것으로 보고하지 않는다(미확인).
    let movedResult = results[orcaMoved]
    check(movedResult?.ok == false && movedResult?.skipped == false && movedResult?.message.hasPrefix("미확인:") == true && movedResult?.message.contains("옮겨짐") == true
          && fm.fileExists(atPath: movedHidden) && worktreeEntry(orcaMoved)?.status == .gone && worktreeEntry(orcaMoved)?.note?.hasPrefix("삭제되지 않고 옮겨짐") == true,
          "가짜 Orca가 지우지 않고 옆에 숨김(git worktree move) → \(movedResult?.message ?? "-")")
    let gitMovedResult = results[gitMoved]
    check(gitMovedResult?.ok == false && gitMovedResult?.message.contains("git 목록에 남아 있음") == true && gitMovedResult?.message.contains("옮겨짐") == true
          && fm.fileExists(atPath: gitMovedHidden) && worktreeEntry(gitMoved)?.status == .gone,
          "가짜 git이 폴더만 옮김 → \(gitMovedResult?.message ?? "-")")
    check(results[orcaSticky]?.ok == false && results[orcaSticky]?.message == "미확인: Orca 목록에 남아 있음" && !fm.fileExists(atPath: orcaSticky)
          && worktreeEntry(orcaSticky)?.status == .held,
          "지웠지만 Orca 목록에 남음 → \(results[orcaSticky]?.message ?? "-")")
    check(results[orcaAlongside]?.ok == true && results[orcaAlongside]?.verification.contains { $0.contains("함께 지워짐 · 커밋 보존 확인") } == true,
          "Orca가 브랜치까지 지움 → 지운 뒤 squash 동등으로 커밋 보존 확인(\(results[orcaAlongside]?.verification.first { $0.contains("함께") } ?? "-"))")
    let cEntry = worktreeEntry(cWorktree)
    check(results[cWorktree]?.ok == false && results[cWorktree]?.message.contains("커밋 보존 미확인") == true && cEntry?.status == .held
          && cEntry?.note?.hasPrefix("커밋 보존 미확인") == true && cEntry?.head == cFeatureHead,
          "브랜치가 함께 지워졌는데 커밋이 어디에도 없음 → \(results[cWorktree]?.message ?? "-")")

    // 동등 병합 브랜치: 기록한 SHA일 때만 지우는 update-ref -d · 금고 메모 · 커밋 SHA.
    let squashResult = results[repo + "#feature/squash"], squashEntry = branchEntry("feature/squash")
    check(squashResult?.ok == true && squashResult?.command == [git, "-C", repo, "update-ref", "-d", "refs/heads/feature/squash", squashHead]
          && squashEntry?.head == squashHead && Set(squashEntry?.commits ?? []) == squashCommits && squashEntry?.note?.hasPrefix(LeftoverRules.equivalenceNote) == true
          && squashEntry?.evidence?.contains("squash 동등") == true && squashEntry?.verification?.contains("브랜치 없음 확인") == true
          && squashEntry?.verification?.contains("커밋 보존 확인") == true,
          "squash 브랜치 정리: \(squashResult?.message ?? "-") · 금고 \(squashEntry?.note ?? "-")")
    check(results[repo + "#feature/pick"]?.ok == true && results[repo + "#feature/pick"]?.command.contains("update-ref") == true
          && branchEntry("feature/pick")?.head == pickHead && branchEntry("feature/pick")?.evidence?.contains("cherry-pick 동등") == true,
          "cherry-pick 브랜치 정리: \(results[repo + "#feature/pick"]?.message ?? "-")")
    check(results[repo + "#feature/child"]?.ok == true && results[repo + "#feature/child"]?.command.suffix(2) == ["-d", "feature/child"]
          && results[repo + "#feature/child2"]?.ok == true,
          "조상 병합 브랜치는 git branch -d(\(results[repo + "#feature/child"]?.message ?? "-"))")

    // 보존 대상은 그대로.
    func branchExists(_ name: String, _ repository: String = repo) -> Bool { setupGit(git, ["-C", repository, "show-ref", "--verify", "--quiet", "refs/heads/" + name]).status == 0 }
    let listed = Set(PorcelainPaths.list(git: git, repo: repo))
    let keptWorktrees = [untracked, linked, claudeTarget, detachedUnique, base, openPath, openLive]
    check(keptWorktrees.allSatisfy { fm.fileExists(atPath: $0) && listed.contains($0) } && fm.fileExists(atPath: bMain)
          && ["feature/unique", "feature/shared", "feature/shared-copy", "feature/gone", "feature/base2"].allSatisfy { branchExists($0) },
          "보존 대상 작업 공간 \(keptWorktrees.count + 1)개 · 브랜치 5개 그대로")
    let all = recorder.calls
    let forced = all.filter { call in call.args.contains { ["--force", "-f", "-D", "--run-hooks"].contains($0) } || call.args.contains("prune") || call.args.contains("gc") }
    check(forced.isEmpty && !all.contains { ($0.exe as NSString).lastPathComponent == "orca" && $0.exe != fakeOrcaPath },
          "강제 옵션·prune·gc 0회 · 진짜 Orca 0회")

    // 규칙 6: 보고 — 지운 것마다 HEAD SHA·근거, 미확인은 완료로 세지 않는다.
    let acted = real.filter { !$0.skipped }
    check(acted.allSatisfy { !$0.evidence.isEmpty && !$0.verification.isEmpty } && real.filter { $0.ok && !$0.skipped }.count == 8
          && real.filter { !$0.ok && !$0.skipped }.count == 4,
          "보고: 실제 동작 \(acted.count)건 모두 근거·확인 기록 · 완료 \(real.filter { $0.ok && !$0.skipped }.count)건 · 미확인 \(real.filter { !$0.ok && !$0.skipped }.count)건(완료로 세지 않음)")

    // 10) 금고 SHA로 되살리기: 동등 판정으로 지운 브랜치 · 커밋 보존 미확인으로 남은 작업 공간.
    if let squashEntry {
        let back = RecoveryRestorer.restoreGit(squashEntry, vault: vault, git: git)
        check(back.ok && sha(repo, "refs/heads/feature/squash") == squashHead && vault.entry(squashEntry.id)?.status == .restored,
              "동등 판정으로 지운 브랜치를 금고 SHA로 되살림: \(back.message)")
    } else {
        check(false, "동등 판정으로 지운 브랜치의 금고 항목 없음")
    }
    if let cEntry {
        let back = RecoveryRestorer.restoreGit(cEntry, vault: vault, git: git)
        check(back.ok && fm.fileExists(atPath: cWorktree + "/cf.txt") && sha(cWorktree, "HEAD") == cFeatureHead && branchExists("c-feature", repoC),
              "커밋 보존 미확인 작업 공간도 금고 SHA로 브랜치·작업 공간 되살림: \(back.message)")
    }

    if let tailPID { kill(tailPID, SIGTERM) }
    try? fm.removeItem(atPath: root)
    check(!fm.fileExists(atPath: root), "시험 폴더 정리: \(root) 삭제")
}

/// 직접 계산한 patch-id가 같은 diff 글을 받은 `git patch-id --stable`과 같은지(글자 고침+새 파일 · 끝 줄바꿈 없음 · 이진 파일 · 지움 · 권한만 · 전부 합침).
func patchIDAgreementCheck(git: String, folder: String) {
    let fm = FileManager.default
    let repo = folder + "/patchid"
    try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
    var failures = 0
    @discardableResult func g(_ arguments: [String]) -> CommandResult {
        let result = setupGit(git, arguments)
        if !result.succeeded { failures += 1; print("  준비 실패: git \(arguments.joined(separator: " ")) → \(result.stderr.prefix(160))") }
        return result
    }
    func put(_ name: String, _ data: Data) { fm.createFile(atPath: repo + "/" + name, contents: data) }
    func snapshot(_ message: String) {
        g(["-C", repo, "add", "-A"])
        g(["-C", repo, "commit", "-q", "-m", message])
    }
    g(["init", "-q", "-b", "main", repo])
    g(["-C", repo, "config", "user.name", "ReMON Check"])
    g(["-C", repo, "config", "user.email", "check@remon.invalid"])
    put("a.txt", Data("one\ntwo\nthree\nfour\nfive\nsix\nseven\n".utf8))
    put("tail.txt", Data("no newline".utf8))
    put("bin.dat", Data([0, 1, 2, 3, 255, 0, 7]))
    put("gone.txt", Data("to be deleted\n".utf8))
    put("mode.sh", Data("#!/bin/sh\necho hi\n".utf8))
    snapshot("base")
    put("a.txt", Data("one\ntwo changed\nthree\nfour\nfive\nsix\nseven  with  spaces\n".utf8))
    put("new.txt", Data("brand new\n".utf8))
    snapshot("text edits + new file")
    put("tail.txt", Data("no newline still".utf8))
    snapshot("no newline at end")
    put("bin.dat", Data([0, 1, 2, 3, 254, 0, 9, 10]))
    snapshot("binary change")
    try? fm.removeItem(atPath: repo + "/gone.txt")
    snapshot("delete")
    chmod(repo + "/mode.sh", 0o755)
    snapshot("mode only")
    let options = ["--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--full-index", "--src-prefix=a/", "--dst-prefix=b/", "-U3"]
    let cases = [("HEAD~5", "HEAD~4", "고침+새 파일"), ("HEAD~4", "HEAD~3", "끝 줄바꿈 없음"), ("HEAD~3", "HEAD~2", "이진 파일"), ("HEAD~2", "HEAD~1", "지움"),
                 ("HEAD~1", "HEAD", "권한만"), ("HEAD~5", "HEAD", "전부 합침")]
    var agreed: [String] = []
    for (index, (from, to, label)) in cases.enumerated() {
        let diff = g(["-C", repo, "diff"] + options + [from, to]).stdout
        let file = folder + "/case-\(index).diff"
        fm.createFile(atPath: file, contents: Data(diff.utf8))
        let theirs = Shell.capture("/bin/sh", ["-c", "\"$0\" patch-id --stable < \"$1\"", git, file], timeout: 20).stdout.split(separator: " ").first.map(String.init)
        let ours = PatchID.stable(diff)
        if ours != nil, ours == theirs { agreed.append(label) } else { print("  patch-id 불일치(\(label)): ReMON \(ours ?? "nil") · git \(theirs ?? "nil")") }
    }
    check(failures == 0 && agreed.count == cases.count, "patch-id: diff \(cases.count)가지 모두 git patch-id --stable과 같음(\(agreed.joined(separator: " · ")))")
}
