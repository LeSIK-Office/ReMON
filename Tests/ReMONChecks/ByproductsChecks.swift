import Darwin
import Foundation
import ReMONCore

// 부산물(워크트리·브랜치) 조사·정리 검사. 실제 정리는 /private/tmp/remon-byproducts의 시험 저장소에서만 한다.
// 마지막의 실제 ~/DEV 조사는 읽기 전용(허용 목록 밖 명령은 실행하지 않고 위반으로 센다) — 정리기는 부르지 않는다.

let byproductsRoot = "/private/tmp/remon-byproducts"

final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(exe: String, args: [String])] = []
    func record(_ exe: String, _ args: [String]) { lock.lock(); items.append((exe, args)); lock.unlock() }
    var calls: [(exe: String, args: [String])] { lock.lock(); defer { lock.unlock() }; return items }
}

/// 명령 종류(git 하위 명령)별 걸린 시간 합 — 실제 조사가 어디서 시간을 쓰는지 보인다.
final class CommandTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var totals: [String: (count: Int, seconds: Double)] = [:]

    func add(_ executable: String, _ arguments: [String], _ seconds: Double) {
        var rest = arguments[...]
        while let first = rest.first, first.hasPrefix("-") { rest = rest.dropFirst(first == "-C" || first == "-c" ? 2 : 1) }
        let key = (executable as NSString).lastPathComponent + " " + (rest.first ?? "?")
        lock.lock()
        let old = totals[key] ?? (0, 0)
        totals[key] = (old.count + 1, old.seconds + seconds)
        lock.unlock()
    }

    func summary() -> String {
        lock.lock(); defer { lock.unlock() }
        return totals.sorted { $0.value.seconds > $1.value.seconds }.map { String(format: "%@ %d회 %.1f초", $0.key, $0.value.count, $0.value.seconds) }.joined(separator: " · ")
    }
}

/// 가짜 Orca: 목록·터미널은 주입한 값, rm은 git worktree remove(강제 없음)로 흉내 낸다.
final class FakeOrca: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [OrcaWorktree]
    private let terminals: [OrcaTerminal]
    let repo: String

    init(rows: [OrcaWorktree], terminals: [OrcaTerminal], repo: String) {
        self.rows = rows
        self.terminals = terminals
        self.repo = repo
    }

    var currentRows: [OrcaWorktree] { lock.lock(); defer { lock.unlock() }; return rows }

    func respond(_ args: [String], git: String) -> CommandResult {
        func json(_ object: [String: Any]) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self) }
        if args == ["worktree", "list", "--json"] {
            let list = currentRows.map { row -> [String: Any] in
                ["path": row.path, "branch": row.branch.map { "refs/heads/" + $0 } ?? "", "isMainWorktree": row.isMainWorktree, "repoId": row.repoId,
                 "displayName": row.displayName, "isPinned": row.isPinned]
            }
            return CommandResult(status: 0, stdout: json(["id": "fake", "ok": true, "result": ["worktrees": list, "totalCount": list.count, "truncated": false]]))
        }
        if args == ["terminal", "list", "--json"] {
            let list = terminals.map { item -> [String: Any] in
                ["handle": item.handle, "title": item.title, "worktreePath": item.worktreePath, "agentIdentity": item.agent ?? NSNull(), "connected": item.connected]
            }
            return CommandResult(status: 0, stdout: json(["id": "fake", "ok": true, "result": ["terminals": list]]))
        }
        if args.count == 5, args[0] == "worktree", args[1] == "rm", args[2] == "--worktree", args[3].hasPrefix("path:"), args[4] == "--json" {
            let path = String(args[3].dropFirst("path:".count))
            let removed = LeftoverTools.defaultRunner(git, ["-C", repo, "worktree", "remove", path], 30)
            guard removed.succeeded else {
                return CommandResult(status: 1, stdout: json(["id": "fake", "ok": false, "error": ["code": "remove_failed", "message": removed.stderr]]))
            }
            lock.lock(); rows.removeAll { $0.path == path }; lock.unlock()
            return CommandResult(status: 0, stdout: json(["id": "fake", "ok": true, "result": ["removed": true]]))
        }
        return CommandResult(status: 2, stderr: "가짜 Orca가 모르는 명령: \(args.joined(separator: " "))")
    }
}

/// 시험 저장소 준비용 git: 사용자 전역 설정·훅·서명과 분리한다.
func setupGit(_ git: String, _ arguments: [String]) -> CommandResult {
    var environment = LeftoverTools.commandEnvironment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    return Shell.capture(git, ["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "init.defaultBranch=main"] + arguments,
                         environment: environment, timeout: 30)
}

/// 폴더 아래 모든 항목의 종류·크기·수정 시각(나노초). 읽기 전용 증명용.
func treeSnapshot(_ root: String, excluding: [String]) -> [String: String] {
    var result: [String: String] = [:]
    guard let enumerator = FileManager.default.enumerator(atPath: root) else { return result }
    while let relative = enumerator.nextObject() as? String {
        if excluding.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { continue }
        var info = stat()
        guard lstat(root + "/" + relative, &info) == 0 else { continue }
        result[relative] = "\(info.st_mode)-\(info.st_size)-\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
    }
    return result
}

/// 실제 저장소 조사에서 허용하는 읽기 전용 명령.
func isReadOnlyCommand(_ executable: String, _ arguments: [String]) -> Bool {
    if (executable as NSString).lastPathComponent == "orca" {
        return arguments == ["terminal", "list", "--json"] || arguments == ["worktree", "list", "--json"]
    }
    guard (executable as NSString).lastPathComponent == "git" else { return false }
    var rest = arguments[...]
    while let first = rest.first {
        if first == "-C" || first == "-c" { rest = rest.dropFirst(2) } else if first == "--no-optional-locks" { rest = rest.dropFirst() } else { break }
    }
    guard let command = rest.first else { return false }
    let tail = Array(rest.dropFirst())
    switch command {
    case "worktree": return tail.first == "list"
    case "for-each-ref", "symbolic-ref", "merge-base", "show-ref", "cherry", "rev-list": return true
    // diff·log는 파일로 쓰는 --output만 막는다(커밋끼리 비교는 인덱스를 건드리지 않는다).
    case "log", "diff": return !tail.contains { $0.hasPrefix("--output") }
    case "branch": return tail.first == "--list" && !tail.contains("-d") && !tail.contains("-D") && !tail.contains("-m")
    case "status": return arguments.contains("--no-optional-locks")
    default: return false
    }
}

func verdictText(_ verdict: LeftoverVerdict?) -> String {
    switch verdict {
    case .cleanable(let action)?: "정리 가능(\(action.rawValue))"
    case .keep(let reason)?: "보존(\(reason))"
    case nil: "항목 없음"
    }
}

func byproductsCheck() {
    let fm = FileManager.default
    let root = byproductsRoot
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

    // 1) 시험 저장소: main + 병합된 브랜치 + 병합 안 된 브랜치.
    let repo = root + "/repo"
    g(["init", "-q", "-b", "main", repo])
    g(["-C", repo, "config", "user.name", "ReMON Check"])
    g(["-C", repo, "config", "user.email", "check@remon.invalid"])
    commit(repo, ".gitignore", "node_modules/\n.env\n", "c1 gitignore")
    commit(repo, "README.md", "ReMON byproducts check\n", "c2 readme")
    g(["-C", repo, "checkout", "-q", "-b", "feature/merged"])
    commit(repo, "merged.txt", "merged work\n", "c3 merged work")
    g(["-C", repo, "checkout", "-q", "main"])
    g(["-C", repo, "merge", "-q", "--no-ff", "-m", "merge feature/merged", "feature/merged"])
    g(["-C", repo, "checkout", "-q", "-b", "feature/unmerged"])
    commit(repo, "unmerged.txt", "unmerged work\n", "c4 unmerged work")
    g(["-C", repo, "checkout", "-q", "main"])

    // 2) 작업 공간들.
    func addWorktree(_ name: String, path: String? = nil, detach: Bool = false) -> String {
        let target = path ?? root + "/wt/" + name
        if detach { g(["-C", repo, "worktree", "add", "-q", "--detach", target, "main"]) } else { g(["-C", repo, "worktree", "add", "-q", "-b", "wt/" + name, target, "main"]) }
        return target
    }
    let clean = addWorktree("clean-merged")
    write(clean + "/node_modules/pkg/index.js", "// 재생성 캐시\n")
    let dirty = addWorktree("dirty")
    write(dirty + "/notes.txt", "draft\n")
    let unmerged = addWorktree("unmerged")
    commit(unmerged, "work.txt", "work in progress\n", "unmerged worktree commit")
    let gone = addWorktree("gone")
    try? fm.removeItem(atPath: gone)
    let locked = addWorktree("locked")
    g(["-C", repo, "worktree", "lock", "--reason", "remon check", locked])
    let busy = addWorktree("busy")
    let term = addWorktree("term")
    let later = addWorktree("later")
    let orcaPath = addWorktree("orca")
    let pinned = addWorktree("pinned")
    let secret = addWorktree("secret")
    write(secret + "/.env", "LOCAL_SETTING=1\n")
    let claudePath = addWorktree("agent-check", path: repo + "/.claude/worktrees/agent-check")
    let codexPath = addWorktree("codex", path: root + "/codex-worktrees/1234/repo", detach: true)
    check(setupFailures == 0, "시험 저장소 준비: 작업 공간 13개 + 메인, 브랜치 병합/미병합/main")

    // 3) 가짜 세션·Orca(진짜 Orca는 절대 부르지 않는다).
    let session = AgentSession(id: ProcessKey(pid: 999_999, start: 1), kind: .claudeCode, rootPID: 999_999, pids: [999_999], cwd: busy + "/src", project: "byproducts")
    let terminals = [OrcaTerminal(worktreePath: term, connected: true, handle: "term_fake_live", agent: "claude"),
                     OrcaTerminal(worktreePath: clean, connected: false, handle: "term_fake_closed")]
    let orcaRows = [OrcaWorktree(path: orcaPath, branch: "wt/orca", repoId: "fake-repo", displayName: "가짜 Orca 작업 공간"),
                    OrcaWorktree(path: pinned, branch: "wt/pinned", repoId: "fake-repo", displayName: "고정된 작업 공간", isPinned: true)]
    let fakeOrcaPath = root + "/fake-bin/orca" // 존재하지 않는 경로 — 실행기가 가로챈다
    let fakeOrca = FakeOrca(rows: orcaRows, terminals: terminals, repo: repo)
    let recorder = CommandRecorder()
    let realOrca = Set(OrcaBridge.candidates + ["/Applications/Orca.app/Contents/Resources/bin/orca"])
    let runner: CommandRunner = { executable, arguments, timeout in
        recorder.record(executable, arguments)
        if executable == fakeOrcaPath { return fakeOrca.respond(arguments, git: git) }
        if realOrca.contains(executable) || (executable as NSString).lastPathComponent == "orca" { return CommandResult(status: 99, stderr: "진짜 Orca 호출 차단") }
        return LeftoverTools.defaultRunner(executable, arguments, timeout)
    }
    let tools = LeftoverTools(git: git, orca: fakeOrcaPath, run: runner)
    var options = LeftoverScanOptions()
    options.codexWorktreesRoot = root + "/codex-worktrees"
    options.projectName = { _ in "byproducts" }

    // 4) 조사(읽기 전용 증명: 조사 전후 파일·인덱스가 그대로).
    let beforeScan = treeSnapshot(root, excluding: ["audit"])
    let report = LeftoverScanner.report(devRoot: root, sessions: [session], orcaTerminals: terminals, orcaWorktrees: orcaRows, tools: tools, options: options)
    let afterScan = treeSnapshot(root, excluding: ["audit"])
    check(beforeScan == afterScan, "조사는 읽기 전용: 시험 저장소·작업 공간 항목 \(beforeScan.count)개(.git 인덱스 포함) 변화 없음 · \(String(format: "%.0fms", report.elapsed * 1000))")
    check(report.repoCount == 1 && report.skippedRepos.isEmpty, "저장소 1개로 묶음(devRoot 폴더 + Orca 작업 공간의 저장소 중복 제거), 건너뜀 \(report.skippedRepos.count)")
    let project = report.projects.first { $0.project == "byproducts" }
    let worktrees = Dictionary((project?.worktrees ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    let branches = Dictionary((project?.branches ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    func expect(_ path: String, _ verdict: LeftoverVerdict, _ label: String) {
        check(worktrees[path]?.verdict == verdict, "\(label) → \(verdictText(worktrees[path]?.verdict))")
    }
    check(worktrees[repo]?.isMain == true && worktrees[repo]?.verdict == .keep("메인 작업 공간"), "메인 작업 공간 → \(verdictText(worktrees[repo]?.verdict))")
    expect(clean, .cleanable(.removeWorktree), "깨끗+병합(무시된 node_modules·끊긴 Orca 터미널만 있음)")
    expect(dirty, .keep("미커밋 변경 1개(추적 안 된 파일 1개)"), "변경 있음(추적 안 된 파일)")
    expect(unmerged, .keep("병합 안 됨"), "병합 안 됨")
    expect(gone, .cleanable(.pruneWorktreeMetadata), "폴더가 지워진 작업 공간(prunable)")
    expect(locked, .keep("잠금 설정됨"), "잠김")
    expect(busy, .keep("사용 중: 세션 pid 999999"), "세션 작업 폴더가 안에 있음")
    expect(term, .keep("사용 중: Orca 터미널"), "연결된 Orca 터미널")
    expect(later, .cleanable(.removeWorktree), "나중에 변경될 작업 공간(조사 시점엔 깨끗)")
    expect(orcaPath, .cleanable(.orcaRemoveWorktree), "가짜 Orca 목록의 작업 공간")
    expect(pinned, .keep("Orca에서 고정됨"), "Orca 고정")
    expect(secret, .keep("지우면 사라질 무시 파일 1개(.env)"), "무시된 .env만 있음")
    expect(claudePath, .cleanable(.removeWorktree), "Claude 작업 공간(.claude/worktrees)")
    expect(codexPath, .cleanable(.removeWorktree), "Codex 작업 공간(분리된 HEAD, 병합됨)")
    check(worktrees[orcaPath]?.manager == .orca && worktrees[claudePath]?.manager == .claude && worktrees[codexPath]?.manager == .codex && worktrees[clean]?.manager == .git,
          "관리 주체: Orca 목록 → orca · .claude/worktrees → claude · codex 루트 → codex · 그 외 git")
    let gw = worktrees[gone], dw = worktrees[dirty], uw = worktrees[unmerged], lw = worktrees[locked], cw = worktrees[codexPath]
    check(gw?.prunable == true && lw?.locked == true && dw?.dirtyFiles == 1 && uw?.merged == false && worktrees[clean]?.merged == true && cw?.branch == nil && cw?.merged == true,
          "사실 필드: prunable·locked·dirtyFiles·merged·분리된 HEAD")
    check(worktrees[clean]?.lastCommit != nil && (worktrees[clean]?.bytes ?? 0) > 0 && worktrees[clean]?.bytesComplete == true,
          "마지막 커밋 시각·실제 할당량 \(worktrees[clean]?.bytes ?? 0)바이트")
    check(branches["main"]?.verdict == .keep("기본 브랜치") && branches["main"]?.isDefault == true, "main → \(verdictText(branches["main"]?.verdict))")
    check(branches["feature/merged"]?.verdict == .cleanable(.deleteMergedBranch), "병합된 브랜치 → \(verdictText(branches["feature/merged"]?.verdict))")
    check(branches["feature/unmerged"]?.verdict == .keep("미결합 커밋 1개의 유일한 참조"), "병합 안 된 브랜치(커밋 1개가 여기에만) → \(verdictText(branches["feature/unmerged"]?.verdict))")
    check(branches["wt/clean-merged"]?.verdict == .keep("작업 공간에 체크아웃됨(clean-merged)") && branches["wt/clean-merged"]?.checkedOutAt == clean,
          "작업 공간에 체크아웃된 브랜치 → \(verdictText(branches["wt/clean-merged"]?.verdict))")
    check(project?.cleanableCount == 7 && project?.keepCount == 8, "방 집계: 정리 가능 \(project?.cleanableCount ?? -1)개(7) · 보존 잡동사니 \(project?.keepCount ?? -1)개(8) · \(project?.cleanableBytes ?? 0)바이트")
    let home = fm.homeDirectoryForCurrentUser.path
    check(LeftoverScanner.defaultProjectName(home + "/DEV/ReMON/.claude/worktrees/agent-x") == "ReMON"
          && LeftoverScanner.defaultProjectName(home + "/orca/workspaces/STOREARC/b-object-library") == "STOREARC"
          && LeftoverScanner.defaultProjectName(home + "/.codex/worktrees/7462/KITCHEN") == "KITCHEN", "기본 방 규칙 = 세션과 같은 규칙(DEV/X · orca/workspaces/X · .codex/worktrees/id/X)")

    // 5) 드라이런: 아무것도 실행하지 않는다.
    let audit = AuditLog(url: URL(fileURLWithPath: root + "/audit/actions.jsonl"))
    let beforeDry = treeSnapshot(root, excluding: ["audit"])
    let callsBeforeDry = recorder.calls.count
    let dry = LeftoverCleaner.clean(report.projects, dryRun: true, audit: audit, sessions: [session], orcaTerminals: terminals, tools: tools, options: options)
    let dryCalls = recorder.calls.dropFirst(callsBeforeDry)
    check(dry.count == 7 && dry.allSatisfy { $0.ok && $0.dryRun && !$0.skipped }, "드라이런: 정리 가능 7개 모두 '할 수 있음' (\(dry.filter { !$0.ok }.map(\.message).joined(separator: "; ")))")
    check(treeSnapshot(root, excluding: ["audit"]) == beforeDry, "드라이런: 파일·인덱스 변화 없음")
    check(dryCalls.allSatisfy { isReadOnlyCommand($0.exe, $0.args) }, "드라이런: 쓰기 명령 0회(읽기 \(dryCalls.count)회)")

    // 6) 조사와 정리 사이에 변경이 생긴 작업 공간 → 정리기가 거부해야 한다.
    write(later + "/late.txt", "scan 뒤에 생긴 변경\n")
    let real = LeftoverCleaner.clean(report.projects, dryRun: false, audit: audit, sessions: [session], orcaTerminals: terminals, tools: tools, options: options)
    let results = Dictionary(real.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for result in real { print("  정리 결과: \(result.ok ? "OK " : "--  ")\((result.id as NSString).lastPathComponent) · \(result.action.rawValue) · \(result.message)") }
    check(results[later]?.ok == false && results[later]?.skipped == true && (results[later]?.message.contains("미커밋 변경") ?? false) && fm.fileExists(atPath: later),
          "정리 직전 재확인: 조사 뒤 변경된 작업 공간은 건너뜀(\(results[later]?.message ?? "-"))")
    for (path, label) in [(clean, "깨끗+병합"), (claudePath, "Claude"), (codexPath, "Codex"), (orcaPath, "Orca")] {
        check(results[path]?.ok == true && results[path]?.skipped == false && !fm.fileExists(atPath: path), "실제 정리: \(label) 작업 공간 삭제(\(results[path]?.message ?? "-"))")
    }
    let listed = Set(PorcelainPaths.list(git: git, repo: repo))
    check(results[gone]?.ok == true && !listed.contains(gone) && results[gone]?.command.suffix(3) == ["worktree", "remove", gone],
          "실제 정리: 끊긴 작업 공간 기록만 그 경로 하나(git worktree remove — prune 아님)(\(results[gone]?.message ?? "-"))")
    let keeps = [dirty, unmerged, locked, busy, term, pinned, secret, later]
    check(keeps.allSatisfy { fm.fileExists(atPath: $0) && listed.contains($0) } && listed.contains(repo), "보존 대상 \(keeps.count)개 + 메인은 그대로(폴더·git 목록)")
    check(fm.fileExists(atPath: dirty + "/notes.txt") && fm.fileExists(atPath: secret + "/.env"), "보존 대상의 변경·무시 파일 그대로")
    func branchExists(_ name: String) -> Bool { setupGit(git, ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/" + name]).status == 0 }
    check(results[repo + "#feature/merged"]?.ok == true && !branchExists("feature/merged"), "실제 정리: 병합된 브랜치 -d 삭제(\(results[repo + "#feature/merged"]?.message ?? "-"))")
    check(branchExists("feature/unmerged") && branchExists("main"), "병합 안 된 브랜치·main은 그대로")
    let orcaRemovals = recorder.calls.filter { $0.exe == fakeOrcaPath && $0.args.count > 1 && $0.args[0] == "worktree" && $0.args[1] == "rm" }
    check(orcaRemovals.count == 1 && orcaRemovals.first?.args == ["worktree", "rm", "--worktree", "path:" + orcaPath, "--json"],
          "Orca 경로: 주입한 실행기로 orca worktree rm 1회(\(orcaRemovals.first?.args.joined(separator: " ") ?? "-"))")
    let realOrcaCalls = recorder.calls.filter { $0.exe != fakeOrcaPath && ($0.exe as NSString).lastPathComponent == "orca" }
    check(realOrcaCalls.isEmpty, "진짜 Orca 호출 0회")
    let forced = recorder.calls.filter { call in call.args.contains { ["--force", "-f", "-D", "--run-hooks", "--allow-failed-archive-hook"].contains($0) } }
    let gitWrites = recorder.calls.filter { $0.exe == git && !isReadOnlyCommand($0.exe, $0.args) }.map { $0.args.drop { $0 == "-C" || $0.hasPrefix("/") }.prefix(2).joined(separator: " ") }
    let broad = recorder.calls.filter { call in call.args.contains("prune") || call.args.contains("gc") }
    check(forced.isEmpty && broad.isEmpty, "강제 옵션(--force·-f·-D·--run-hooks) 0회 · prune·gc 0회 · git 쓰기 명령: \(gitWrites.joined(separator: ", "))")
    let auditLines = ((try? String(contentsOfFile: root + "/audit/actions.jsonl", encoding: .utf8)) ?? "").split(separator: "\n")
    check(auditLines.count == dry.count + real.count && auditLines.filter { $0.contains("\"dryRun\":false") && $0.contains("\"result\":\"ok\"") }.count == 6,
          "감사 기록 \(auditLines.count)줄(드라이런 \(dry.count) + 실제 \(real.count), 실제 성공 6)")

    // 7) 다시 조사: 지운 작업 공간의 브랜치는 이제 체크아웃이 풀려 정리 가능.
    let rescan = LeftoverScanner.scan(devRoot: root, sessions: [session], orcaTerminals: terminals, orcaWorktrees: fakeOrca.currentRows, tools: tools, options: options)
    let rescanBranches = Dictionary((rescan.first?.branches ?? []).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    check(rescanBranches["wt/clean-merged"]?.verdict == .cleanable(.deleteMergedBranch) && rescanBranches["feature/merged"] == nil,
          "다시 조사: 풀려난 브랜치 wt/clean-merged → \(verdictText(rescanBranches["wt/clean-merged"]?.verdict))")

    // 8) 끊긴 기록 정리는 그 경로 하나만(git worktree remove <경로> — 저장소 전체에 적용되는 prune은 쓰지 않는다) → 보존 대상인 다른 끊긴 작업 공간은 그대로.
    //    브랜치는 조사 뒤 새 커밋이 생기면 거부.
    let gone2 = addWorktree("gone2"), gone3 = addWorktree("gone3")
    try? fm.removeItem(atPath: gone2)
    try? fm.removeItem(atPath: gone3)
    g(["-C", repo, "branch", "feature/late", "main"])
    let ghost = AgentSession(id: ProcessKey(pid: 999_998, start: 1), kind: .codexCLI, rootPID: 999_998, pids: [999_998], cwd: gone3, project: "byproducts")
    let guardScan = LeftoverScanner.scan(devRoot: root, sessions: [session, ghost], orcaTerminals: terminals, orcaWorktrees: fakeOrca.currentRows, tools: tools, options: options)
    let prune2 = guardScan.flatMap(\.worktrees).first { $0.path == gone2 }
    let prune3 = guardScan.flatMap(\.worktrees).first { $0.path == gone3 }
    let lateBranch = guardScan.flatMap(\.branches).first { $0.name == "feature/late" }
    check(prune2?.verdict == .cleanable(.pruneWorktreeMetadata) && prune3?.verdict == .keep("사용 중: 세션 pid 999998") && lateBranch?.verdict == .cleanable(.deleteMergedBranch),
          "끊긴 작업 공간 2개(하나는 세션이 안에 있음) · 병합된 브랜치 feature/late 준비")
    g(["-C", repo, "checkout", "-q", "feature/late"])
    commit(repo, "late-branch.txt", "late\n", "commit after scan")
    g(["-C", repo, "checkout", "-q", "main"])
    var guarded: [LeftoverCleanResult] = []
    if let prune2, let lateBranch {
        guarded = LeftoverCleaner.clean(worktrees: [prune2], branches: [lateBranch], dryRun: false, audit: audit, sessions: [session, ghost], orcaTerminals: terminals, tools: tools, options: options)
    }
    let listedAfterGuard = Set(PorcelainPaths.list(git: git, repo: repo))
    let narrow = guarded.first { $0.kind == .worktree }, lateResult = guarded.first { $0.kind == .branch }
    check(guarded.count == 2 && narrow?.ok == true && narrow?.skipped == false && narrow?.command.suffix(3) == ["worktree", "remove", gone2]
          && !listedAfterGuard.contains(gone2) && listedAfterGuard.contains(gone3) && lateResult?.skipped == true && lateResult?.ok == false && branchExists("feature/late"),
          "끊긴 기록은 그 경로 하나만 정리(gone2 정리 · 세션이 안에 있는 gone3는 그대로) · 브랜치 보류: \(guarded.map(\.message).joined(separator: " / "))")

    try? fm.removeItem(atPath: root)
    check(!fm.fileExists(atPath: root), "시험 폴더 정리: \(root) 삭제")

    byproductsSmokeScan()
}

/// 실제 ~/DEV 읽기 전용 조사. 정리기는 부르지 않고, 허용 목록 밖 명령은 실행하지 않은 채 위반으로 센다.
func byproductsSmokeScan() {
    let recorder = CommandRecorder()
    let violations = CommandRecorder()
    let timing = CommandTiming()
    let guarded: CommandRunner = { executable, arguments, timeout in
        guard isReadOnlyCommand(executable, arguments) else {
            violations.record(executable, arguments)
            return CommandResult(status: 98, stderr: "읽기 전용 검사에서 차단")
        }
        recorder.record(executable, arguments)
        let started = Date()
        let result = LeftoverTools.defaultRunner(executable, arguments, timeout)
        timing.add(executable, arguments, Date().timeIntervalSince(started))
        return result
    }
    let presenceStarted = Date()
    let presence = ProcessPresence.live()
    print(String(format: "  프로세스 스냅샷: %d개(열린 파일 있는 것 %d개) · %.0fms", presence.count, presence.filter { !$0.openFiles.isEmpty }.count,
                 Date().timeIntervalSince(presenceStarted) * 1000))
    defer { print("  명령별 시간(합): " + timing.summary()) }
    let tools = LeftoverTools(run: guarded)
    let sampler = ProcessSampler()
    let terminals = LeftoverOrca.terminals(tools: tools) ?? []
    let sessions = SessionDetector().detect(records: sampler.sample(), sampler: sampler, orca: terminals).sessions
    let started = Date()
    let report = LeftoverScanner.report(sessions: sessions, orcaTerminals: terminals, orcaWorktrees: nil, tools: tools)
    let elapsed = Date().timeIntervalSince(started)
    var totals = (worktrees: 0, clutter: 0, branches: 0, branchClutter: 0, cleanable: 0, keep: 0, bytes: UInt64(0))
    print("  실제 ~/DEV 조사(읽기 전용): 저장소 \(report.repoCount) · 방 \(report.projects.count) · Orca 목록 \(report.orcaRead ? "읽음" : "없음") · 세션 \(sessions.count)")
    for project in report.projects {
        let clutter = project.worktrees.filter(\.isClutter).count
        let branchClutter = project.branches.filter(\.isClutter).count
        totals.worktrees += project.worktrees.count
        totals.clutter += clutter
        totals.branches += project.branches.count
        totals.branchClutter += branchClutter
        totals.cleanable += project.cleanableCount
        totals.keep += project.keepCount
        totals.bytes += project.cleanableBytes
        print("    \(project.project): 작업 공간 \(project.worktrees.count)(잡동사니 \(clutter)) · 브랜치 \(project.branches.count)(잡동사니 \(branchClutter)) · 정리 가능 \(project.cleanableCount) · 보존 \(project.keepCount) · \(Fmt.size(project.cleanableBytes))")
        for item in project.worktrees where item.isClutter {
            let size = item.verdict.isCleanable ? " · " + Fmt.size(item.bytes) + (item.bytesComplete ? "" : "+(시간 제한)") : ""
            print("      wt \(verdictText(item.verdict)) · \(item.manager.rawValue) · \((item.path as NSString).lastPathComponent)\(size)")
        }
        let keptBranches = project.branches.filter { $0.isClutter && !$0.verdict.isCleanable }
        let cleanableBranches = project.branches.filter(\.verdict.isCleanable)
        if !cleanableBranches.isEmpty {
            let named = cleanableBranches.prefix(6).map { "\($0.name)(\($0.integration?.method.rawValue ?? "-"))" }
            print("      브랜치 정리 가능 \(cleanableBranches.count): \(named.joined(separator: ", "))\(cleanableBranches.count > 6 ? " …" : "")")
        }
        if !keptBranches.isEmpty {
            let reasons = Dictionary(grouping: keptBranches, by: { $0.verdict.keepReason ?? "-" }).map { "\($0.key) \($0.value.count)" }.sorted()
            print("      브랜치 보존 \(keptBranches.count): \(reasons.joined(separator: ", "))")
        }
    }
    for (path, reason) in report.skippedRepos.sorted(by: { $0.key < $1.key }) { print("    건너뜀: \(path) — \(reason)") }
    print(String(format: "  합계: 작업 공간 %d(잡동사니 %d) · 브랜치 %d(잡동사니 %d) · 정리 가능 %d · 보존 %d · 정리 가능 용량 %@ · %.1f초 · 명령 %d회",
                 totals.worktrees, totals.clutter, totals.branches, totals.branchClutter, totals.cleanable, totals.keep, Fmt.size(totals.bytes), elapsed, recorder.calls.count))
    check(report.repoCount > 0, "실제 ~/DEV 저장소 \(report.repoCount)개 조사")
    check(violations.calls.isEmpty, "실제 저장소에는 읽기 전용 명령만(\(recorder.calls.count)회, 차단 \(violations.calls.count)회: \(violations.calls.prefix(3).map { $0.args.joined(separator: " ") }.joined(separator: " | ")))")
    check(elapsed < 45, String(format: "실제 조사 시간 %.1f초 < 45초", elapsed))
}

/// git 목록의 작업 공간 경로(시험 확인용).
enum PorcelainPaths {
    static func list(git: String, repo: String) -> [String] {
        let result = LeftoverTools.defaultRunner(git, ["-C", repo, "worktree", "list", "--porcelain", "-z"], 10)
        return result.stdout.split(separator: "\0").compactMap { $0.hasPrefix("worktree ") ? String($0.dropFirst("worktree ".count)) : nil }
    }
}
