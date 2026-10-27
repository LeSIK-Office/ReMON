import Foundation
import ReMONCore

// git 사건 감지(커밋·푸시·배포)를 임시 저장소와 bare 원격으로 본다. 대표님 저장소는 건드리지 않는다.
func gitEventCheck() {
    let git = LeftoverTools.findGit()
    let root = checkRoot + "/gitevents"
    try? FileManager.default.removeItem(atPath: root)
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    let repo = root + "/DEV/SAMPLE", remote = root + "/remote.git"
    try? FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
    @discardableResult func g(_ args: [String], in dir: String = repo) -> CommandResult {
        Shell.capture(git, ["-C", dir] + args, environment: ["GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t", "HOME": root], timeout: 30)
    }
    g(["init", "-q", "-b", "main"]); g(["init", "-q", "--bare", remote], in: root)
    g(["remote", "add", "origin", remote])
    FileManager.default.createFile(atPath: repo + "/a.txt", contents: Data("a".utf8))
    g(["add", "."]); g(["commit", "-q", "-m", "첫 커밋"])
    let watcher = GitEventWatcher(projectName: { ($0 as NSString).lastPathComponent })
    check(watcher.observe(repos: [repo]).isEmpty, "처음 본 저장소는 기준만 잡고 사건을 내지 않음")
    FileManager.default.createFile(atPath: repo + "/b.txt", contents: Data("b".utf8))
    g(["add", "."]); g(["commit", "-q", "-m", "결제 모듈 리팩터링 secret=abc123"])
    let commits = watcher.observe(repos: [repo])
    check(commits.count == 1 && commits[0].kind == .commit && commits[0].project == "SAMPLE" && commits[0].label.contains("리팩터링") && !commits[0].label.contains("abc123"),
          "커밋 → 사건 1개(제목은 가림): \(commits.first?.label ?? "-")")
    check(watcher.observe(repos: [repo]).isEmpty, "같은 상태를 다시 보면 사건 없음")
    g(["checkout", "-q", "-b", "feature/x"])
    FileManager.default.createFile(atPath: repo + "/c.txt", contents: Data("c".utf8))
    g(["add", "."]); g(["commit", "-q", "-m", "기능"])
    g(["push", "-q", "-u", "origin", "feature/x"])
    let pushed = watcher.observe(repos: [repo])
    check(pushed.contains { $0.kind == .push && $0.label == "origin/feature/x" } && pushed.contains { $0.kind == .commit }, "기능 브랜치 푸시 → 푸시 사건(+커밋)")
    g(["checkout", "-q", "main"]); g(["merge", "-q", "feature/x"]); g(["push", "-q", "origin", "main"])
    let deployed = watcher.observe(repos: [repo])
    check(deployed.contains { $0.kind == .deploy && $0.label == "origin/main" }, "main 푸시 → 배포 사건")
    g(["tag", "v1.0.0"])
    let tagged = watcher.observe(repos: [repo])
    check(tagged.contains { $0.kind == .deploy && $0.label == "태그 v1.0.0" }, "새 태그 → 배포 사건")
    // 워크트리에서의 커밋도 메인 저장소 사건으로
    let wt = root + "/DEV/SAMPLE-wt"
    g(["worktree", "add", "-q", wt, "-b", "wt/branch"])
    _ = watcher.observe(repos: [repo])
    FileManager.default.createFile(atPath: wt + "/d.txt", contents: Data("d".utf8))
    g(["add", "."], in: wt); g(["commit", "-q", "-m", "워크트리 커밋"], in: wt)
    let fromWorktree = watcher.observe(repos: [repo])
    check(fromWorktree.contains { $0.kind == .commit && $0.label.contains("워크트리") }, "워크트리 커밋도 그 프로젝트 사건")
    check(GitEventWatcher.gitDirectory(of: wt) == repo + "/.git", "워크트리의 .git 파일 → 메인 .git 폴더")
    let log = repo + "/.git/logs/HEAD"
    let line = String(repeating: "0", count: 40) + " " + String(repeating: "1", count: 40) + " t <t@t> 1 +0000\tcommit: 캐시 갱신\n"
    try? Data(line.utf8).write(to: URL(fileURLWithPath: log), options: .atomic)
    _ = watcher.observe(repos: [repo])
    try? Data((line + line).utf8).write(to: URL(fileURLWithPath: log), options: .atomic)
    check(watcher.observe(repos: [repo]).filter { $0.label == "캐시 갱신" }.count == 1, "reflog 축소·파일 교체 뒤 추가한 커밋도 감지")
    check(watcher.observe(repos: [repo]).isEmpty, "변하지 않은 reflog를 재사용해도 사건 중복 없음")
}
