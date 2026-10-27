import Darwin
import Foundation

// 프로젝트의 git 사건(커밋·푸시·배포)을 .git 파일만 읽어 알아챈다(git 프로세스를 띄우지 않는다). 10-25 대표 요청:
// "배포하면 애들이 소리 지르고 꽃가루 뿌리고 서류가 쌓인다 → 청소하기 버튼 → 그 프로젝트에 청소부 투입".

public struct GitEvent: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case commit, push, deploy }
    public var project: String
    public var repo: String
    public var kind: Kind
    /// 사람이 읽는 한 줄(커밋 제목 · 브랜치 · 태그). 커밋 제목은 가린다.
    public var label: String
    public var time: Date

    public init(project: String, repo: String, kind: Kind, label: String, time: Date) {
        self.project = project
        self.repo = repo
        self.kind = kind
        self.label = label
        self.time = time
    }

    public var text: String {
        switch kind {
        case .commit: "커밋 · \(project) · \(label)"
        case .push: "푸시 · \(project) · \(label)"
        case .deploy: "배포 · \(project) · \(label)"
        }
    }
}

/// 저장소마다 마지막으로 본 상태(HEAD 기록 줄 수 · 원격 참조 기록 줄 수 · 태그 목록)를 들고, 바뀐 만큼만 사건으로 낸다.
/// 처음 보는 저장소는 기준만 잡고 사건을 내지 않는다(앱을 켜자마자 과거 커밋을 축하하지 않게).
public final class GitEventWatcher: @unchecked Sendable {
    private struct Seen: Equatable {
        var headLines: [String: Int] = [:]      // logs/HEAD 경로 → 줄 수(메인 + 워크트리)
        var remoteLines: [String: Int] = [:]    // logs/refs/remotes/<remote>/<branch> → 줄 수
        var tags: Set<String> = []
    }

    private let lock = NSLock()
    private var seen: [String: Seen] = [:]
    private struct LogStamp: Equatable {
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int
        init(_ info: stat) {
            inode = info.st_ino; size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec; modifiedNanos = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec; changedNanos = info.st_ctimespec.tv_nsec
        }
    }
    private var logCounts: [String: (stamp: LogStamp, count: Int)] = [:]
    private let projectName: @Sendable (String) -> String

    public init(projectName: @escaping @Sendable (String) -> String) {
        self.projectName = projectName
    }

    /// 저장소 목록(메인 작업 공간 경로)을 보고 새 사건을 돌려준다. 호출 간격은 호출자가 정한다(15초 권장 · stat 몇 번이 전부).
    public func observe(repos: [String], now: Date = Date()) -> [GitEvent] {
        lock.lock(); defer { lock.unlock() }
        var events: [GitEvent] = []
        for repo in Set(repos) {
            guard let gitDir = Self.gitDirectory(of: repo) else { continue }
            let current = snapshot(gitDir: gitDir)
            let previous = seen[repo]
            seen[repo] = current.seen
            guard let previous else { continue }
            let project = projectName(repo)
            // 커밋: HEAD 기록에 새 줄 — 메시지가 "commit"·"commit (merge)"·"commit (amend)"로 시작하는 줄만(checkout·reset은 아님).
            // 전에 없던 기록 파일(새 워크트리·처음 푸시한 브랜치)은 0줄에서 시작한 것으로 본다.
            for (path, count) in current.seen.headLines {
                let before = previous.headLines[path] ?? 0
                guard count > before else { continue }
                for line in Self.tailLines(path, count: count - before) {
                    guard let message = Self.reflogMessage(line), message.hasPrefix("commit") else { continue }
                    let title = message.split(separator: ":", maxSplits: 1).count == 2 ? String(message.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) : ""
                    events.append(GitEvent(project: project, repo: repo, kind: .commit, label: Redactor.headline(title, limit: 48) ?? "커밋", time: now))
                }
            }
            // 푸시: 원격 추적 참조 기록에 "update by push" 줄. 보호 브랜치(main·master·production 등)면 배포로 본다.
            for (path, count) in current.seen.remoteLines {
                let before = previous.remoteLines[path] ?? 0
                guard count > before else { continue }
                let pushed = Self.tailLines(path, count: count - before).contains { Self.reflogMessage($0)?.contains("update by push") == true }
                guard pushed else { continue }
                let branch = Self.branchName(fromRemoteLog: path, gitDir: gitDir)
                let deploy = LeftoverRules.protectedBranchNames.contains(branch.split(separator: "/").last.map(String.init) ?? branch)
                events.append(GitEvent(project: project, repo: repo, kind: deploy ? .deploy : .push, label: branch, time: now))
            }
            // 태그: 새 태그 = 배포(버전 표시).
            for tag in current.seen.tags.subtracting(previous.tags).sorted() {
                events.append(GitEvent(project: project, repo: repo, kind: .deploy, label: "태그 " + tag, time: now))
            }
        }
        return events
    }

    /// 시험용: 저장소의 기준 상태를 지운다.
    public func forget(_ repo: String) { lock.lock(); seen[repo] = nil; lock.unlock() }

    private func snapshot(gitDir: String) -> (seen: Seen, dummy: Void) {
        var seen = Seen()
        var heads = [gitDir + "/logs/HEAD"]
        if let worktrees = try? FileManager.default.contentsOfDirectory(atPath: gitDir + "/worktrees") {
            heads += worktrees.map { gitDir + "/worktrees/" + $0 + "/logs/HEAD" }
        }
        for path in heads { if let count = lineCount(path) { seen.headLines[path] = count } }
        let remotesRoot = gitDir + "/logs/refs/remotes"
        if let enumerator = FileManager.default.enumerator(atPath: remotesRoot) {
            for case let relative as String in enumerator {
                let path = remotesRoot + "/" + relative
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, let count = lineCount(path) else { continue }
                seen.remoteLines[path] = count
            }
        }
        if let tags = try? FileManager.default.contentsOfDirectory(atPath: gitDir + "/refs/tags") { seen.tags.formUnion(tags) }
        if let packed = try? String(contentsOfFile: gitDir + "/packed-refs", encoding: .utf8) {
            for line in packed.split(separator: "\n") where line.contains(" refs/tags/") {
                if let range = line.range(of: " refs/tags/") { seen.tags.insert(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)) }
            }
        }
        return (seen, ())
    }

    /// 작업 공간의 .git 폴더(워크트리면 `.git` 파일의 gitdir를 따라 메인 .git으로).
    public static func gitDirectory(of repo: String) -> String? {
        let dotGit = repo + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8), let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let target = String(line.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
        let resolved = target.hasPrefix("/") ? target : repo + "/" + target
        // …/.git/worktrees/<name> → 메인 .git
        if let range = resolved.range(of: "/.git/worktrees/") { return String(resolved[..<range.lowerBound]) + "/.git" }
        return resolved
    }

    private func lineCount(_ path: String) -> Int? {
        var info = stat()
        guard stat(path, &info) == 0 else { logCounts[path] = nil; return nil }
        let stamp = LogStamp(info)
        if let cached = logCounts[path], cached.stamp == stamp { return cached.count }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let count = data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) }
        logCounts[path] = (stamp, count)
        return count
    }

    static func tailLines(_ path: String, count: Int) -> [String] {
        guard count > 0, let data = FileManager.default.contents(atPath: path) else { return [] }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(count).map(String.init)
    }

    /// reflog 줄 "old new name <email> time tz\tmessage" → message
    static func reflogMessage(_ line: String) -> String? {
        guard let tab = line.firstIndex(of: "\t") else { return nil }
        return String(line[line.index(after: tab)...])
    }

    static func branchName(fromRemoteLog path: String, gitDir: String) -> String {
        let prefix = gitDir + "/logs/refs/remotes/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : (path as NSString).lastPathComponent
    }
}
