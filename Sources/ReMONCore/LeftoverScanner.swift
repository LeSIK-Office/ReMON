import CryptoKit
import Darwin
import Foundation

// MARK: - 명령 실행

/// 명령 결과(종료 코드·표준 출력·표준 오류). 시간 초과면 timedOut.
public struct CommandResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }

    public init(status: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// 주입 가능한 실행기(실행 파일, 인자, 시간 제한). 시험에서는 가짜 Orca로 바꾼다.
public typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> CommandResult

extension Shell {
    /// 종료 코드와 출력이 모두 필요한 명령. 표준 입력은 닫는다(프롬프트로 멈추지 않게).
    public static func capture(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 10) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return CommandResult(status: -1, stderr: error.localizedDescription) }
        final class Box: @unchecked Sendable { var out = Data(), err = Data() }
        let box = Box()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { box.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { box.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return CommandResult(status: -2, stderr: "시간 초과(\(Int(timeout))초)", timedOut: true)
        }
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: String(decoding: box.out, as: UTF8.self), stderr: String(decoding: box.err, as: UTF8.self))
    }
}

/// 부산물 조사·정리에 쓰는 바깥 도구. Orca 경로와 실행기를 바꿔 시험이 진짜 Orca를 부르지 않게 한다.
public struct LeftoverTools: Sendable {
    public var git: String
    /// nil이면 Orca 없음(Orca 관리 작업 공간은 정리하지 않는다).
    public var orca: String?
    public var run: CommandRunner

    public init(git: String = LeftoverTools.findGit(), orca: String? = LeftoverTools.findOrca(), run: @escaping CommandRunner = LeftoverTools.defaultRunner) {
        self.git = git
        self.orca = orca
        self.run = run
    }

    public static var live: LeftoverTools { LeftoverTools() }

    /// git 환경: 프롬프트 금지, 선택적 잠금(인덱스 갱신) 금지, 영어 메시지. 바깥의 GIT_DIR 같은 변수는 지운다(-C가 엉뚱한 저장소를 보지 않게).
    public static let commandEnvironment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        return environment
    }()

    public static let defaultRunner: CommandRunner = { executable, arguments, timeout in
        Shell.capture(executable, arguments, environment: commandEnvironment, timeout: timeout)
    }

    /// xcrun 경유(/usr/bin/git)보다 실제 바이너리를 먼저 쓴다(호출당 수십 ms 절약).
    public static func findGit() -> String {
        ["/Library/Developer/CommandLineTools/usr/bin/git", "/Applications/Xcode.app/Contents/Developer/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"
    }

    public static func findOrca() -> String? {
        OrcaBridge.candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - 설정·입력

public struct LeftoverScanOptions: Sendable {
    public var commandTimeout: TimeInterval = 5
    public var statusTimeout: TimeInterval = 8
    /// 저장소 하나에 쓰는 최대 시간. 넘으면 남은 작업 공간은 '상태 확인 실패'(보존)로 둔다.
    public var repoBudget: TimeInterval = 30
    public var parallelism = 4
    public var measureBytes = true
    /// 보존 대상 작업 공간 크기도 잴지(기본은 정리 가능한 것만 — node_modules 전체 순회 비용).
    public var measureKeptBytes = false
    public var bytesTimePerWorktree: TimeInterval = 1.5
    public var bytesTimeTotal: TimeInterval = 6
    public var codexWorktreesRoot = FileManager.default.homeDirectoryForCurrentUser.path + "/.codex/worktrees"
    /// 저장소 하나에서 동등(cherry · squash patch-id) 확인을 하는 최대 항목 수. 넘으면 '병합 안 됨(동등 확인 못 함)'으로 보존한다.
    public var integrationChecksPerRepo = 30
    /// 링크 의존 조사(메인·형제 작업 공간의 심볼릭 링크)에 저장소마다 쓰는 시간·항목 수. 다 못 보면 '링크 의존 확인 못 함'으로 보존한다.
    public var linkScanTime: TimeInterval = 4
    public var linkScanEntries = 400_000
    /// devRoot 바로 아래 외에 더 볼 저장소.
    public var extraRepos: [String] = []
    /// 경로 → 방 이름. 기본은 세션과 같은 규칙.
    public var projectName: @Sendable (String) -> String = LeftoverScanner.defaultProjectName

    public init() {}
}

/// 작업 폴더가 있거나 파일을 열어 둔 사용자 프로세스(에이전트 세션이 아닌 셸·개발 서버·편집기까지 잡는다).
public struct ProcessPresence: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    /// 작업 폴더. "/"·알 수 없음이면 빈 문자열.
    public var cwd: String
    /// 열어 둔 파일·폴더(커널이 알려 주는 정식 경로, 시스템 경로 제외). 작업 폴더가 바깥이어도 안의 파일을 연 프로세스를 '사용 중'으로 본다.
    public var openFiles: [String]

    public init(pid: Int32, name: String, cwd: String, openFiles: [String] = []) {
        self.pid = pid
        self.name = name
        self.cwd = cwd
        self.openFiles = openFiles
    }

    /// 같은 사용자 프로세스의 작업 폴더(PROC_PIDVNODEPATHINFO)와 열린 파일(PROC_PIDLISTFDS). 이 프로세스가 띄운 도우미(git 등)는 빼고,
    /// 이 프로세스 자신의 열린 파일(기록·금고)은 세지 않는다.
    public static func live(openFiles includeOpenFiles: Bool = true) -> [ProcessPresence] {
        let me = getpid(), uid = getuid()
        var result: [ProcessPresence] = []
        for info in ProcessSampler.allKinfo() where info.kp_eproc.e_ucred.cr_uid == uid {
            let pid = info.kp_proc.p_pid
            guard pid > 0, info.kp_eproc.e_ppid != me else { continue }
            var cwd = ""
            var vnode = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, size) == size {
                cwd = withUnsafeBytes(of: vnode.pvi_cdir.vip_path) { raw in String(cString: raw.bindMemory(to: CChar.self).baseAddress!) }
                if cwd == "/" { cwd = "" }
            }
            let files = includeOpenFiles && pid != me ? ProcessSampler.openFiles(pid: pid).filter(isUserPath) : []
            guard !cwd.isEmpty || !files.isEmpty else { continue }
            result.append(ProcessPresence(pid: pid, name: ProcessSampler.comm(info), cwd: cwd, openFiles: files))
        }
        return result
    }

    /// 작업 공간이 있을 수 없는 시스템 경로(라이브러리·장치)는 열린 파일 목록에서 뺀다.
    static func isUserPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1 else { return false }
        return !["/dev/", "/System/", "/usr/", "/bin/", "/sbin/", "/Library/", "/Applications/", "/private/var/db/"].contains { path.hasPrefix($0) }
    }

    static func sameUserPIDs() -> [Int32] {
        let uid = getuid()
        return ProcessSampler.allKinfo().filter { $0.kp_eproc.e_ucred.cr_uid == uid && $0.kp_proc.p_pid > 0 }.map(\.kp_proc.p_pid)
    }
}

/// `orca worktree list --json`의 한 줄.
public struct OrcaWorktree: Sendable, Equatable {
    public var path: String
    public var branch: String?
    public var isMainWorktree: Bool
    public var repoId: String
    public var displayName: String
    public var isPinned: Bool

    public init(path: String, branch: String? = nil, isMainWorktree: Bool = false, repoId: String = "", displayName: String = "", isPinned: Bool = false) {
        self.path = path
        self.branch = branch
        self.isMainWorktree = isMainWorktree
        self.repoId = repoId
        self.displayName = displayName
        self.isPinned = isPinned
    }
}

extension OrcaTerminal {
    /// 시험·주입용 공개 초기화.
    public init(worktreePath: String, connected: Bool, handle: String = "", title: String = "", agent: String? = nil, lastOutputAt: Date? = nil) {
        self.init(handle: handle, title: title, worktreePath: worktreePath, agent: agent, lastOutputAt: lastOutputAt, connected: connected)
    }
}

/// Orca 읽기(읽기 전용 명령만). 정리기는 지우기 직전에 이것으로 터미널·작업 공간을 다시 읽는다.
public enum LeftoverOrca {
    public static func worktrees(tools: LeftoverTools, timeout: TimeInterval = 15) -> [OrcaWorktree]? {
        guard let orca = tools.orca else { return nil }
        let result = tools.run(orca, ["worktree", "list", "--json"], timeout)
        return result.succeeded ? parseWorktrees(result.stdout) : nil
    }

    public static func terminals(tools: LeftoverTools, timeout: TimeInterval = 15) -> [OrcaTerminal]? {
        guard let orca = tools.orca else { return nil }
        let result = tools.run(orca, ["terminal", "list", "--json"], timeout)
        return result.succeeded ? parseTerminals(result.stdout) : nil
    }

    public static func parseWorktrees(_ json: String) -> [OrcaWorktree]? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], (root["ok"] as? Bool) != false,
              let rows = ((root["result"] as? [String: Any])?["worktrees"] ?? root["worktrees"]) as? [[String: Any]] else { return nil }
        return rows.compactMap { row in
            guard let path = row["path"] as? String, !path.isEmpty else { return nil }
            let branch = (row["branch"] as? String).map(LeftoverScanner.shortBranch).flatMap { $0.isEmpty ? nil : $0 }
            return OrcaWorktree(path: path, branch: branch, isMainWorktree: (row["isMainWorktree"] as? Bool) ?? false, repoId: row["repoId"] as? String ?? "",
                                displayName: row["displayName"] as? String ?? "", isPinned: (row["isPinned"] as? Bool) ?? false)
        }
    }

    public static func parseTerminals(_ json: String) -> [OrcaTerminal]? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], (root["ok"] as? Bool) != false,
              let rows = ((root["result"] as? [String: Any])?["terminals"] ?? root["terminals"]) as? [[String: Any]] else { return nil }
        return rows.compactMap { item in
            guard let path = item["worktreePath"] as? String else { return nil }
            let lastOutput = (item["lastOutputAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return OrcaTerminal(handle: item["handle"] as? String ?? "", title: OrcaBridge.cleanTitle(item["title"] as? String ?? ""), worktreePath: path,
                                agent: item["agentIdentity"] as? String, lastOutputAt: lastOutput, connected: (item["connected"] as? Bool) ?? false)
        }
    }
}

/// 조사 결과 + 진단(건너뛴 저장소·걸린 시간).
public struct LeftoverScanReport: Sendable {
    public var projects: [ProjectLeftovers]
    /// 경로 → 건너뛴 이유.
    public var skippedRepos: [String: String]
    public var repoCount: Int
    public var elapsed: TimeInterval
    public var orcaRead: Bool
}

// MARK: - 스캐너(읽기 전용)

/// git 워크트리·로컬 브랜치 부산물 조사. 저장소에 아무것도 쓰지 않는다(status는 --no-optional-locks).
/// 수 초가 걸릴 수 있으니 메인 스레드 밖에서 부른다.
public enum LeftoverScanner {
    public static let defaultDevRoot = FileManager.default.homeDirectoryForCurrentUser.path + "/DEV"

    nonisolated(unsafe) private static let namer = SessionDetector()

    /// 세션과 같은 방 규칙(~/DEV/X/…→X, ~/orca/workspaces/X/…→X, ~/.codex/worktrees/<id>/X→X).
    public static let defaultProjectName: @Sendable (String) -> String = { path in namer.projectName(for: path) }

    /// Orca 자료를 주입받는다(시험은 가짜 목록을 넣는다).
    public static func scan(devRoot: String = defaultDevRoot, sessions: [AgentSession], orcaTerminals: [OrcaTerminal], orcaWorktrees: [OrcaWorktree],
                            processes: [ProcessPresence]? = nil, tools: LeftoverTools = .live, options: LeftoverScanOptions = LeftoverScanOptions()) -> [ProjectLeftovers] {
        report(devRoot: devRoot, sessions: sessions, orcaTerminals: orcaTerminals, orcaWorktrees: orcaWorktrees, processes: processes, tools: tools, options: options).projects
    }

    /// 실제 Orca를 읽는 편의 함수(`orca terminal list --json`·`orca worktree list --json`, 없으면 Orca 없이).
    public static func scanLive(devRoot: String = defaultDevRoot, sessions: [AgentSession], tools: LeftoverTools = .live, options: LeftoverScanOptions = LeftoverScanOptions()) -> [ProjectLeftovers] {
        report(devRoot: devRoot, sessions: sessions, orcaTerminals: nil, orcaWorktrees: nil, tools: tools, options: options).projects
    }

    /// orcaTerminals·orcaWorktrees가 nil이면 tools.orca로 실제 Orca를 읽는다. processes가 nil이면 지금 프로세스를 읽는다.
    public static func report(devRoot: String = defaultDevRoot, sessions: [AgentSession], orcaTerminals: [OrcaTerminal]?, orcaWorktrees: [OrcaWorktree]?,
                              processes: [ProcessPresence]? = nil, tools: LeftoverTools = .live, options: LeftoverScanOptions = LeftoverScanOptions()) -> LeftoverScanReport {
        let started = Date()
        // 프로세스는 git을 띄우기 전에 찍는다(git -C가 작업 공간 안에서 돌기 때문).
        let presence = processes ?? ProcessPresence.live()
        let liveTerminals = orcaTerminals == nil ? LeftoverOrca.terminals(tools: tools) : nil
        let liveWorktrees = orcaWorktrees == nil ? LeftoverOrca.worktrees(tools: tools) : nil
        let terminals = orcaTerminals ?? liveTerminals ?? []
        let orcaRows = orcaWorktrees ?? liveWorktrees ?? []
        let inspector = LeftoverInspector(tools: tools, options: options, sessions: sessions, terminals: terminals, processes: presence, orcaRows: orcaRows)

        // 1) 후보: devRoot 바로 아래 git 폴더 + Orca 저장소(저장소마다 메인 줄, 없으면 아무 줄) + 추가 경로.
        var candidates: [String] = []
        var seen = Set<String>()
        func add(_ path: String) {
            let key = SafeFileOps.canonical(path)
            if seen.insert(key).inserted { candidates.append(path) }
        }
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: devRoot)) ?? []).sorted() where !name.hasPrefix(".") {
            let path = devRoot + "/" + name
            var info = stat()
            // 링크는 따라가지 않는다(devRoot 밖을 훑지 않게).
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, fm.fileExists(atPath: path + "/.git") else { continue }
            add(path)
        }
        for (_, rows) in Dictionary(grouping: orcaRows, by: { $0.repoId.isEmpty ? $0.path : $0.repoId }).sorted(by: { $0.key < $1.key }) {
            let existing = rows.filter { fm.fileExists(atPath: $0.path) }
            if let row = existing.first(where: \.isMainWorktree) ?? existing.first { add(row.path) }
        }
        options.extraRepos.forEach(add)

        // 2) 후보마다 worktree list → 메인 경로로 같은 저장소를 묶는다.
        let lists = parallelMap(candidates, limit: options.parallelism) { inspector.worktreeList(at: $0) }
        var skipped: [String: String] = [:]
        var repos: [(path: String, entries: [PorcelainWorktree])] = []
        var claimed = Set<String>()
        for (candidate, list) in zip(candidates, lists) {
            guard let entries = list.entries, let main = entries.first else { skipped[candidate] = list.error ?? "worktree list 실패"; continue }
            if claimed.insert(SafeFileOps.canonical(main.path)).inserted { repos.append((main.path, entries)) }
        }

        // 3) 저장소별 조사(병렬, 저장소마다 시간 예산·동등 확인 횟수 한도). 정리 후보가 된 작업 공간만 링크 의존을 본다.
        let states = parallelMap(repos, limit: options.parallelism) { repo -> (RepoState?, [WorktreeLeftover], [BranchLeftover]) in
            guard let state = inspector.loadRepo(path: repo.path, entries: repo.entries) else { return (nil, [], []) }
            let deadline = Date().addingTimeInterval(options.repoBudget)
            let budget = IntegrationBudget(checks: options.integrationChecksPerRepo, deadline: deadline)
            var worktrees = state.entries.enumerated().map { index, entry in
                inspector.inspectWorktree(entry, isMain: index == 0, state: state, deadline: deadline, budget: budget)
            }
            inspector.applyLinkDependencies(&worktrees, state: state)
            return (state, worktrees, inspector.inspectBranches(state: state, deadline: deadline, budget: budget))
        }
        var worktrees: [WorktreeLeftover] = []
        var branches: [BranchLeftover] = []
        var scanned = 0
        for (repo, result) in zip(repos, states) {
            guard result.0 != nil else { skipped[repo.path] = "저장소 정보를 읽지 못함"; continue }
            scanned += 1
            worktrees += result.1
            branches += result.2
        }

        // 4) 크기(참고용): 정리 가능한 것부터(보존 대상은 measureKeptBytes일 때만), 전체 시간 예산 안에서만. 재지 않은 것은 bytesComplete=false.
        if options.measureBytes {
            let budgetEnd = Date().addingTimeInterval(options.bytesTimeTotal)
            let candidates = worktrees.indices.filter { !worktrees[$0].isMain && !worktrees[$0].prunable }
            for index in candidates where !worktrees[index].verdict.isCleanable && !options.measureKeptBytes { worktrees[index].bytesComplete = false }
            let order = candidates.filter { worktrees[$0].verdict.isCleanable || options.measureKeptBytes }
                .sorted { (worktrees[$0].verdict.isCleanable ? 0 : 1, worktrees[$0].path) < (worktrees[$1].verdict.isCleanable ? 0 : 1, worktrees[$1].path) }
            for index in order {
                let now = Date()
                guard now < budgetEnd else { worktrees[index].bytesComplete = false; continue }
                let measured = allocatedSize(worktrees[index].path, deadline: min(budgetEnd, now.addingTimeInterval(options.bytesTimePerWorktree)))
                worktrees[index].bytes = measured.bytes
                worktrees[index].bytesComplete = measured.complete
            }
        }

        // 5) 방별로 묶는다.
        var byProject: [String: (repos: Set<String>, worktrees: [WorktreeLeftover], branches: [BranchLeftover])] = [:]
        for item in worktrees {
            byProject[item.project, default: ([], [], [])].repos.insert(item.repo)
            byProject[item.project, default: ([], [], [])].worktrees.append(item)
        }
        for item in branches {
            byProject[item.project, default: ([], [], [])].repos.insert(item.repo)
            byProject[item.project, default: ([], [], [])].branches.append(item)
        }
        let projects = byProject.keys.sorted().map { key -> ProjectLeftovers in
            let group = byProject[key]!
            let sortedWorktrees = group.worktrees.sorted { ($0.isMain ? 0 : 1, $0.repo, $0.path) < ($1.isMain ? 0 : 1, $1.repo, $1.path) }
            let sortedBranches = group.branches.sorted { ($0.repo, $0.name) < ($1.repo, $1.name) }
            return ProjectLeftovers(project: key, repos: group.repos.sorted(), worktrees: sortedWorktrees, branches: sortedBranches)
        }
        return LeftoverScanReport(projects: projects, skippedRepos: skipped, repoCount: scanned, elapsed: Date().timeIntervalSince(started),
                                  orcaRead: orcaWorktrees != nil || liveWorktrees != nil)
    }

    // MARK: 보조

    /// "refs/heads/feat/x" → "feat/x".
    public static func shortBranch(_ ref: String) -> String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    /// "refs/heads/main" → "main", "refs/remotes/origin/main" → "origin/main".
    public static func shortRef(_ ref: String) -> String {
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        if ref.hasPrefix("refs/remotes/") { return String(ref.dropFirst("refs/remotes/".count)) }
        return ref
    }

    /// 전체 커밋 id(SHA-1 40자 · SHA-256 64자)인지.
    static func isFullSHA(_ text: String) -> Bool {
        (text.count == 40 || text.count == 64) && text.allSatisfy(\.isHexDigit)
    }

    /// 실제 할당량(st_blocks×512)을 시간 제한 안에서 잰다. 제한에 걸리면 complete=false(하한값).
    public static func allocatedSize(_ path: String, deadline: Date) -> (bytes: UInt64, complete: Bool) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return (0, true) }
        if (info.st_mode & S_IFMT) != S_IFDIR { return (UInt64(info.st_blocks) * 512, true) }
        let stream: UnsafeMutablePointer<FTS>? = path.withCString { cPath in
            var paths: [UnsafeMutablePointer<CChar>?] = [strdup(cPath), nil]
            defer { free(paths[0]) }
            return fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil)
        }
        guard let stream else { return (0, false) }
        defer { fts_close(stream) }
        var total: UInt64 = 0
        var count = 0
        while let entry = fts_read(stream) {
            switch Int32(entry.pointee.fts_info) {
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT, FTS_D:
                if let stat = entry.pointee.fts_statp { total += UInt64(stat.pointee.st_blocks) * 512 }
            default: break
            }
            count += 1
            if count % 512 == 0, Date() >= deadline { return (total, false) }
        }
        return (total, true)
    }

    static func parallelMap<T, R>(_ items: [T], limit: Int, _ transform: (T) -> R) -> [R] {
        guard items.count > 1 else { return items.map(transform) }
        let lock = NSLock()
        var results = [R?](repeating: nil, count: items.count)
        let gate = DispatchSemaphore(value: max(1, limit))
        withoutActuallyEscaping(transform) { transform in
            DispatchQueue.concurrentPerform(iterations: items.count) { index in
                gate.wait()
                defer { gate.signal() }
                let value = transform(items[index])
                lock.lock(); results[index] = value; lock.unlock()
            }
        }
        return results.map { $0! }
    }
}

// MARK: - git 해석

/// `git worktree list --porcelain -z`의 한 항목.
struct PorcelainWorktree: Sendable, Equatable {
    var path: String
    var head = ""
    var branchRef: String?
    var bare = false
    var locked = false
    var prunable = false

    var branch: String? { branchRef.map(LeftoverScanner.shortBranch) }

    static func parse(_ text: String) -> [PorcelainWorktree] {
        var result: [PorcelainWorktree] = []
        var current: PorcelainWorktree?
        for field in text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init) {
            if field.isEmpty {
                if let item = current { result.append(item) }
                current = nil
                continue
            }
            if field.hasPrefix("worktree ") {
                if let item = current { result.append(item) }
                current = PorcelainWorktree(path: String(field.dropFirst("worktree ".count)))
            } else if field.hasPrefix("HEAD ") {
                current?.head = String(field.dropFirst("HEAD ".count))
            } else if field.hasPrefix("branch ") {
                current?.branchRef = String(field.dropFirst("branch ".count))
            } else if field == "bare" {
                current?.bare = true
            } else if field == "locked" || field.hasPrefix("locked ") {
                current?.locked = true
            } else if field == "prunable" || field.hasPrefix("prunable ") {
                current?.prunable = true
            }
        }
        if let item = current { result.append(item) }
        return result
    }
}

struct BranchRef: Sendable {
    var ref: String
    var sha: String
    var upstreamGone: Bool
    var date: Date?
    /// upstream ref(refs/remotes/origin/x · 로컬 추적이면 refs/heads/y). 없으면 nil.
    var upstream: String? = nil
    var name: String { LeftoverScanner.shortBranch(ref) }
}

struct RepoState: Sendable {
    var repo: String
    var entries: [PorcelainWorktree]
    var defaultBranch: String?
    /// 병합 비교 대상(refs/heads/<기본>, refs/remotes/origin/<기본> 중 있는 것).
    var defaultRefs: [String]
    var branches: [BranchRef]
    /// 기본 브랜치에 병합된 로컬 브랜치 ref. 확인 못 하면 nil.
    var mergedRefs: Set<String>?
    var commitDates: [String: Date]
    /// 병합된 브랜치 ref → 그것을 품은 기본 ref(짧은 이름).
    var mergedBy: [String: String] = [:]
    /// upstream ref → 그것을 upstream으로 삼는 로컬 브랜치(짧은 이름). 통합 기준 판정용.
    var trackers: [String: [String]] = [:]
    /// 동등 비교 대상: 기본 ref 중 다른 쪽을 품는 것(같으면 하나, 갈라졌으면 둘 다).
    var equivalenceTargets: [String] = []
    /// 기본 ref → 지금 가리키는 SHA(동등 확인 결과를 기억하는 열쇠).
    var defaultSHAs: [String: String] = [:]

    var defaultName: String { defaultBranch ?? "기본 브랜치" }
}

/// 끝까지 확인한 동등 결과를 (저장소, tip, 기본 브랜치 SHA) 열쇠로 기억한다 — 같은 커밋들 사이의 git 이력은 바뀌지 않는다.
/// 시간·한도로 끝까지 못 본 결과는 기억하지 않는다. 너무 많아지면 비운다.
final class IntegrationMemo: @unchecked Sendable {
    static let shared = IntegrationMemo()
    private let lock = NSLock()
    private var entries: [String: IntegrationProbe] = [:]

    func get(_ key: String) -> IntegrationProbe? { lock.lock(); defer { lock.unlock() }; return entries[key] }

    func set(_ key: String, _ probe: IntegrationProbe) {
        lock.lock()
        if entries.count >= 5000 { entries.removeAll() }
        entries[key] = probe
        lock.unlock()
    }
}

/// 저장소 하나의 동등 확인 한도(횟수·시각)와 결과 캐시. 같은 커밋(브랜치와 그 작업 공간)은 한 번만 확인한다.
final class IntegrationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    let deadline: Date
    private var cache: [String: IntegrationProbe] = [:]

    init(checks: Int, deadline: Date) {
        remaining = checks
        self.deadline = deadline
    }

    /// 한도 없음(정리 직전 재확인 — 항목 하나만 본다).
    static func unlimited(until deadline: Date = .distantFuture) -> IntegrationBudget { IntegrationBudget(checks: .max, deadline: deadline) }

    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard remaining > 0, Date() < deadline else { return false }
        remaining -= 1
        return true
    }

    func cached(_ tip: String) -> IntegrationProbe? { lock.lock(); defer { lock.unlock() }; return cache[tip] }
    func store(_ tip: String, _ probe: IntegrationProbe) { lock.lock(); cache[tip] = probe; lock.unlock() }
}

/// 동등 확인 결과. integration이 nil이면 결합을 증명하지 못한 것(checked=false면 한도·시간 때문에 끝까지 못 봄).
struct IntegrationProbe: Sendable {
    var integration: LeftoverIntegration?
    var checked: Bool
    /// 기본 브랜치에 같은 패치가 있는 이쪽 커밋(git cherry '-') — 유일 커밋 수에서 뺀다.
    var equivalent: Set<String> = []
}

/// 무시(ignored) 파일 중 지워도 다시 생기는 것. 나머지(.env 등)는 '지우면 사라질 파일'로 본다.
public enum IgnoredFiles {
    // 빌드 산출물이라도 dist·build·out·target·.output·storybook-static에는 배포본(공증 영수증·DMG 등)이 들 수 있고,
    // .venv·.idea·.vercel(프로젝트 연결)·.wrangler(로컬 DB)·*.log에는 다시 못 만드는 것이 섞인다 → '지우면 사라질 파일'로 본다(10-25 검토).
    public static let regenerableNames: Set<String> = ["node_modules", ".build", ".next", ".nuxt", ".svelte-kit", ".turbo", ".cache",
                                                ".parcel-cache", ".vite", "coverage", ".nyc_output", "__pycache__", ".pytest_cache", ".mypy_cache",
                                                ".ruff_cache", ".tox", ".gradle", "Pods", "DerivedData", ".swiftpm", ".expo",
                                                ".angular", ".docusaurus", ".DS_Store", "Thumbs.db", ".eslintcache", ".stylelintcache"]
    public static let regenerableSuffixes = [".tsbuildinfo", ".pyc", ".pyo"]

    public static func isRegenerable(_ rawPath: String) -> Bool {
        var path = rawPath
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
        if path.hasSuffix("/") { path.removeLast() }
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last else { return false }
        if components.contains(where: regenerableNames.contains) { return true }
        return regenerableSuffixes.contains { name.hasSuffix($0) }
    }
}

/// 스캐너와 정리기가 같이 쓰는 조사기. 모든 git 명령은 읽기 전용이다.
struct LeftoverInspector: Sendable {
    let tools: LeftoverTools
    let options: LeftoverScanOptions
    let sessions: [AgentSession]
    let terminals: [OrcaTerminal]
    let processes: [ProcessPresence]
    let orcaByPath: [String: OrcaWorktree]
    /// 세션 작업 폴더·터미널 경로의 원래/정식 경로(작업 공간마다 realpath를 반복하지 않게 미리 구한다).
    private let sessionPaths: [[String]]
    private let terminalPaths: [[String]]

    init(tools: LeftoverTools, options: LeftoverScanOptions, sessions: [AgentSession], terminals: [OrcaTerminal], processes: [ProcessPresence], orcaRows: [OrcaWorktree]) {
        self.tools = tools
        self.options = options
        self.sessions = sessions
        self.terminals = terminals
        self.processes = processes
        sessionPaths = sessions.map { session in session.cwd.map { Array(Set([$0, SafeFileOps.canonical($0)])) } ?? [] }
        terminalPaths = terminals.map { Array(Set([$0.worktreePath, SafeFileOps.canonical($0.worktreePath)])) }
        var index: [String: OrcaWorktree] = [:]
        for row in orcaRows {
            index[row.path] = row
            index[SafeFileOps.canonical(row.path)] = row
        }
        orcaByPath = index
    }

    func git(_ arguments: [String], timeout: TimeInterval? = nil) -> CommandResult {
        tools.run(tools.git, arguments, timeout ?? options.commandTimeout)
    }

    func worktreeList(at path: String) -> (entries: [PorcelainWorktree]?, error: String?) {
        let result = git(["-C", path, "worktree", "list", "--porcelain", "-z"])
        guard result.succeeded else { return (nil, result.timedOut ? "시간 초과" : Redactor.redact(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))) }
        let entries = PorcelainWorktree.parse(result.stdout)
        return entries.isEmpty ? (nil, "작업 공간 없음") : (entries, nil)
    }

    /// 저장소 공통 정보: 기본 브랜치, 로컬 브랜치(upstream 포함), 병합된 브랜치, 동등 비교 대상, 커밋 시각.
    func loadRepo(path: String, entries known: [PorcelainWorktree]? = nil) -> RepoState? {
        guard let entries = known ?? worktreeList(at: path).entries, let main = entries.first else { return nil }
        let repo = main.path
        let format = "%(refname)%00%(objectname)%00%(upstream:track)%00%(committerdate:unix)%00%(upstream)"
        let refs = git(["-C", repo, "for-each-ref", "--format=" + format, "refs/heads", "refs/remotes/origin"])
        guard refs.succeeded else { return nil }
        var branches: [BranchRef] = []
        var refSHAs: [String: String] = [:]
        for line in refs.stdout.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { continue }
            refSHAs[fields[0]] = fields[1]
            guard fields[0].hasPrefix("refs/heads/") else { continue }
            let upstream = fields.count >= 5 && !fields[4].isEmpty ? fields[4] : nil
            branches.append(BranchRef(ref: fields[0], sha: fields[1], upstreamGone: fields[2].contains("gone"), date: Double(fields[3]).map { Date(timeIntervalSince1970: $0) },
                                      upstream: upstream))
        }
        let allRefs = Set(refSHAs.keys)
        // 기본 브랜치: origin/HEAD → main → master.
        var defaultBranch: String?
        let symbolic = git(["-C", repo, "symbolic-ref", "-q", "refs/remotes/origin/HEAD"])
        let target = symbolic.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if symbolic.succeeded, target.hasPrefix("refs/remotes/origin/") { defaultBranch = String(target.dropFirst("refs/remotes/origin/".count)) }
        if defaultBranch == nil {
            defaultBranch = ["main", "master"].first { allRefs.contains("refs/heads/" + $0) || allRefs.contains("refs/remotes/origin/" + $0) }
        }
        let defaultRefs = defaultBranch.map { name in ["refs/heads/" + name, "refs/remotes/origin/" + name].filter(allRefs.contains) } ?? []
        // 병합된 브랜치(git branch --merged <기본>). 대상 중 하나라도 읽으면 그 합집합, 모두 실패면 모름. 어느 쪽에 들어갔는지도 남긴다(근거).
        var merged: Set<String>?
        var mergedBy: [String: String] = [:]
        for ref in defaultRefs {
            let result = git(["-C", repo, "branch", "--list", "--merged", ref, "--format=%(refname)"])
            guard result.succeeded else { continue }
            let names = result.stdout.split(separator: "\n").map(String.init)
            merged = (merged ?? []).union(names)
            for name in names where mergedBy[name] == nil { mergedBy[name] = LeftoverScanner.shortRef(ref) }
        }
        // 통합 기준: upstream → 그것을 추적하는 로컬 브랜치.
        var trackers: [String: [String]] = [:]
        for branch in branches { if let upstream = branch.upstream { trackers[upstream, default: []].append(branch.name) } }
        // 동등 비교 대상: 로컬·origin 기본 ref가 같거나 한쪽이 다른 쪽을 품으면 앞선 쪽 하나, 갈라졌으면 둘 다.
        var equivalenceTargets = defaultRefs
        if defaultRefs.count == 2 {
            let (local, remote) = (defaultRefs[0], defaultRefs[1])
            if refSHAs[local] == refSHAs[remote] {
                equivalenceTargets = [local]
            } else if git(["-C", repo, "merge-base", "--is-ancestor", local, remote]).status == 0 {
                equivalenceTargets = [remote]
            } else if git(["-C", repo, "merge-base", "--is-ancestor", remote, local]).status == 0 {
                equivalenceTargets = [local]
            }
        }
        // 작업 공간 HEAD 커밋 시각(한 번에).
        var dates: [String: Date] = [:]
        for branch in branches { if let date = branch.date { dates[branch.sha] = date } }
        let heads = Set(entries.map(\.head).filter { !$0.isEmpty && dates[$0] == nil && $0.allSatisfy(\.isHexDigit) })
        if !heads.isEmpty {
            let log = git(["-C", repo, "log", "--no-walk=unsorted", "--ignore-missing", "--format=%H%x00%ct"] + heads.sorted() + ["--"])
            for line in log.stdout.split(separator: "\n") {
                let fields = line.split(separator: "\0").map(String.init)
                if fields.count == 2, let seconds = Double(fields[1]) { dates[fields[0]] = Date(timeIntervalSince1970: seconds) }
            }
        }
        return RepoState(repo: repo, entries: entries, defaultBranch: defaultBranch, defaultRefs: defaultRefs, branches: branches, mergedRefs: merged, commitDates: dates,
                         mergedBy: mergedBy, trackers: trackers, equivalenceTargets: equivalenceTargets,
                         defaultSHAs: refSHAs.filter { defaultRefs.contains($0.key) })
    }

    func inspectWorktree(_ entry: PorcelainWorktree, isMain: Bool, state: RepoState, deadline: Date = .distantFuture, budget: IntegrationBudget? = nil) -> WorktreeLeftover {
        let fm = FileManager.default
        let path = entry.path
        let exists = fm.fileExists(atPath: path)
        let orca = orcaByPath[path] ?? orcaByPath[SafeFileOps.canonical(path)]
        var item = WorktreeLeftover(repo: state.repo, project: options.projectName(path), path: path, branch: entry.branch, head: entry.head,
                                    manager: manager(for: path, orca: orca), prunable: !isMain && (entry.prunable || (!exists && !entry.locked && !entry.bare)),
                                    locked: entry.locked, lastCommit: state.commitDates[entry.head], isMain: isMain || entry.bare,
                                    repoProject: options.projectName(state.repo), orcaDisplayName: orca?.displayName, orcaPinned: orca?.isPinned ?? false)
        if !item.isMain {
            item.inUse = inUseReasons(for: path)
            if path.hasPrefix("/Volumes/") {
                let volume = "/Volumes/" + (path.split(separator: "/").dropFirst().first.map(String.init) ?? "")
                item.volumeOffline = !fm.fileExists(atPath: volume)
            }
            if let ref = entry.branchRef {
                item.upstream = state.branches.first { $0.ref == ref }?.upstream
                item.trackedBy = (state.trackers[ref] ?? []).filter { $0 != entry.branch }
            }
            let merge = mergedState(entry, state: state, deadline: deadline)
            item.merged = merge.merged
            if merge.merged == true { item.integration = LeftoverIntegration(method: .ancestor, target: merge.target ?? state.defaultName) }
            if !item.prunable && exists {
                if Date() < deadline, let status = status(at: path) {
                    item.dirtyFiles = status.dirty
                    item.untrackedFiles = status.untracked
                    item.preciousIgnored = status.precious
                } else {
                    item.statusKnown = false
                }
            }
        }
        item.verdict = LeftoverRules.verdict(for: item, defaultBranch: state.defaultBranch)
        // 동등 확인(git cherry · patch-id)은 판정이 결합 근거에만 걸릴 때만 한다(git 호출 절약).
        if !item.isMain, LeftoverRules.blockedOnlyByIntegration(item, defaultBranch: state.defaultBranch) {
            let probe = integration(tip: entry.head, state: state, budget: budget ?? .unlimited(until: deadline))
            if probe.integration?.method == .ancestor { item.merged = true }
            item.integration = probe.integration
            item.integrationChecked = probe.checked
            // 분리된 HEAD는 작업 공간이 그 커밋의 유일한 참조일 수 있다.
            if probe.integration == nil, entry.branchRef == nil {
                item.uniqueCommits = uniqueCommits(tip: entry.head, excludeRef: nil, equivalent: probe.equivalent, repo: state.repo, deadline: deadline)
            }
            item.verdict = LeftoverRules.verdict(for: item, defaultBranch: state.defaultBranch)
        }
        return item
    }

    func inspectBranches(state: RepoState, deadline: Date = .distantFuture, budget: IntegrationBudget? = nil) -> [BranchLeftover] {
        let project = options.projectName(state.repo)
        let budget = budget ?? .unlimited(until: deadline)
        return state.branches.map { inspect($0, project: project, state: state, deadline: deadline, budget: budget) }
    }

    /// 브랜치 하나만 다시 본다(정리 직전 재확인 — 같은 저장소의 다른 브랜치는 동등 확인하지 않는다).
    func inspectBranch(named name: String, state: RepoState, deadline: Date = .distantFuture) -> BranchLeftover? {
        state.branches.first { $0.name == name }.map { inspect($0, project: options.projectName(state.repo), state: state, deadline: deadline, budget: .unlimited(until: deadline)) }
    }

    private func inspect(_ branch: BranchRef, project: String, state: RepoState, deadline: Date, budget: IntegrationBudget) -> BranchLeftover {
        let merged = state.mergedRefs?.contains(branch.ref) ?? false
        var item = BranchLeftover(repo: state.repo, project: project, name: branch.name, merged: merged,
                                  lastCommit: branch.date, checkedOutAt: state.entries.first { $0.branchRef == branch.ref }?.path,
                                  isDefault: branch.name == state.defaultBranch, upstreamGone: branch.upstreamGone, head: branch.sha,
                                  isProtected: LeftoverRules.isProtected(branch.name), mergeKnown: state.mergedRefs != nil,
                                  upstream: branch.upstream, trackedBy: (state.trackers[branch.ref] ?? []).filter { $0 != branch.name })
        if merged { item.integration = LeftoverIntegration(method: .ancestor, target: state.mergedBy[branch.ref] ?? state.defaultName) }
        item.verdict = LeftoverRules.verdict(for: item)
        if LeftoverRules.blockedOnlyByIntegration(item) {
            let probe = integration(tip: branch.sha, state: state, budget: budget)
            if probe.integration?.method == .ancestor { item.merged = true }
            item.integration = probe.integration
            item.integrationChecked = probe.checked
            // 결합되지 않았으면 이 브랜치가 그 커밋의 마지막 참조인지 센다(자기 ref를 뺀 모든 참조·작업 공간 HEAD와 비교).
            if probe.integration == nil {
                item.uniqueCommits = uniqueCommits(tip: branch.sha, excludeRef: branch.ref, equivalent: probe.equivalent, repo: state.repo, deadline: deadline)
            }
            item.verdict = LeftoverRules.verdict(for: item)
        }
        return item
    }

    func manager(for path: String, orca: OrcaWorktree?) -> LeftoverManager {
        if orca != nil { return .orca }
        let root = options.codexWorktreesRoot.hasSuffix("/") ? options.codexWorktreesRoot : options.codexWorktreesRoot + "/"
        if path.hasPrefix(root) || SafeFileOps.canonical(path).hasPrefix(SafeFileOps.canonical(options.codexWorktreesRoot) + "/") { return .codex }
        if path.contains("/.claude/worktrees/") { return .claude }
        return .git
    }

    /// HEAD가 기본 브랜치(로컬·origin 중 하나)의 조상인지와 그 ref(짧은 이름). 브랜치는 --merged 목록, 분리된 HEAD는 merge-base로 본다.
    func mergedState(_ entry: PorcelainWorktree, state: RepoState, deadline: Date) -> (merged: Bool?, target: String?) {
        guard !entry.head.isEmpty, entry.head.allSatisfy(\.isHexDigit), !state.defaultRefs.isEmpty else { return (nil, nil) }
        if let ref = entry.branchRef, let merged = state.mergedRefs { return (merged.contains(ref), state.mergedBy[ref]) }
        guard Date() < deadline else { return (nil, nil) }
        var sawNo = false
        for target in state.defaultRefs {
            let result = git(["-C", state.repo, "merge-base", "--is-ancestor", entry.head, target])
            if result.timedOut { continue }
            if result.status == 0 { return (true, LeftoverScanner.shortRef(target)) }
            if result.status == 1 { sawNo = true }
        }
        return (sawNo ? false : nil, nil)
    }

    /// 미커밋 변경 수(추적 안 된 파일은 하나하나 — --untracked-files=all, .gitignore로 무시된 것은 빼고)와 지우면 사라질 무시 파일.
    /// 인덱스를 다시 쓰지 않는다(--no-optional-locks).
    func status(at path: String) -> (dirty: Int, untracked: Int, precious: [String])? {
        let result = git(["--no-optional-locks", "-c", "core.fsmonitor=false", "-C", path, "status", "--porcelain=v2", "-z", "--untracked-files=all",
                          "--ignored=matching", "--ignore-submodules=none"], timeout: options.statusTimeout)
        guard result.succeeded else { return nil }
        var tracked = 0, untracked = 0
        var precious: [String] = []
        var skipOriginalPath = false
        for field in result.stdout.split(separator: "\0") {
            if skipOriginalPath { skipOriginalPath = false; continue }
            switch field.first {
            case "#": continue
            case "!":
                let file = String(field.dropFirst(2))
                if !IgnoredFiles.isRegenerable(file), precious.count < 50 { precious.append(file) }
            case "?": untracked += 1
            case "2": tracked += 1; skipOriginalPath = true // 이름 바뀜: 다음 칸은 원래 경로
            default: tracked += 1 // 1(변경) · u(충돌) · 모르는 줄도 변경으로 센다(보수적)
            }
        }
        return (tracked + untracked, untracked, precious)
    }

    /// 작업 공간 안(같거나 아래)에서 도는 세션·연결된 Orca 터미널·프로세스(작업 폴더) · 안의 파일을 연 프로세스.
    func inUseReasons(for path: String) -> [String] {
        let roots = Set([path, SafeFileOps.canonical(path)])
        func inside(_ candidate: String) -> Bool { roots.contains { candidate == $0 || candidate.hasPrefix($0 + "/") } }
        var reasons: [String] = []
        var sessionPIDs = Set<Int32>()
        for (session, paths) in zip(sessions, sessionPaths) where paths.contains(where: inside) {
            reasons.append("세션 pid \(session.rootPID)")
            sessionPIDs.formUnion(session.pids)
            sessionPIDs.insert(session.rootPID)
        }
        let connected = zip(terminals, terminalPaths).filter { $0.0.connected && $0.1.contains(where: inside) }.count
        if connected > 0 { reasons.append(connected == 1 ? "Orca 터미널" : "Orca 터미널 \(connected)개") }
        let others = processes.filter { !sessionPIDs.contains($0.pid) && inside($0.cwd) }
        for process in others.prefix(3) { reasons.append("프로세스 \(process.name)(pid \(process.pid))") }
        if others.count > 3 { reasons.append("프로세스 \(others.count - 3)개 더") }
        let counted = sessionPIDs.union(others.map(\.pid))
        let holders = processes.filter { !counted.contains($0.pid) && $0.openFiles.contains(where: inside) }
        for process in holders.prefix(3) { reasons.append("열린 파일 \(process.name)(pid \(process.pid))") }
        if holders.count > 3 { reasons.append("열린 파일 프로세스 \(holders.count - 3)개 더") }
        return reasons
    }

    // MARK: 결합(동등) 확인 — git 이력만 근거로 쓴다.

    /// 이쪽 커밋이 이보다 많으면 동등 확인을 하지 않는다(오래 갈라진 브랜치 — 보존).
    static let rangeCap = 500
    /// squash 확인: 바뀐 파일이 이보다 많으면 건너뛰고, 기본 브랜치 쪽 후보 커밋은 이만큼까지만 본다.
    static let squashFileCap = 300
    static let squashLogCap = 400
    static let squashCandidateCap = 5

    /// tip이 기본 브랜치에 결합됐는지: git cherry(이쪽 커밋 모두 '-' · 병합 커밋 없음) → squash(합친 변경의 patch-id가 기본 브랜치 커밋 하나와 같음).
    /// 조사 때는 기본 브랜치를 읽어 둔 SHA로 비교하고, 결과는 (tip, 그 SHA)가 같으면 바뀌지 않으므로 끝까지 확인한 것은 기억해 둔다.
    /// memo=false(지운 뒤 확인)는 지금의 기본 브랜치(이름)로 다시 비교하고 기억을 읽지도 쓰지도 않는다.
    func integration(tip: String, state: RepoState, budget: IntegrationBudget, memo: Bool = true) -> IntegrationProbe {
        if let cached = budget.cached(tip) { return cached }
        let memoKey = SafeFileOps.canonical(state.repo) + "|" + tip + "|" + state.equivalenceTargets.map { $0 + "=" + (state.defaultSHAs[$0] ?? "?") }.joined(separator: ",")
        if memo, let known = IntegrationMemo.shared.get(memoKey) {
            budget.store(tip, known)
            return known
        }
        guard LeftoverScanner.isFullSHA(tip), !state.equivalenceTargets.isEmpty, budget.take() else { return IntegrationProbe(integration: nil, checked: false) }
        var checked = true
        var equivalent = Set<String>()
        func done(_ integration: LeftoverIntegration?) -> IntegrationProbe {
            let probe = IntegrationProbe(integration: integration, checked: integration != nil || checked, equivalent: equivalent)
            budget.store(tip, probe)
            if memo, probe.checked { IntegrationMemo.shared.set(memoKey, probe) }
            return probe
        }
        for ref in state.equivalenceTargets {
            guard Date() < budget.deadline else { checked = false; break }
            let name = LeftoverScanner.shortRef(ref)
            let target = memo ? (state.defaultSHAs[ref] ?? ref) : ref
            // 1) git cherry: 기본 브랜치에 없는 이쪽 커밋(병합 커밋 제외)마다 '-'는 같은 패치가 기본 브랜치에 있음, '+'는 없음.
            let cherry = git(["-C", state.repo, "cherry", target, tip])
            guard cherry.succeeded else { checked = false; continue }
            var plus = 0
            var minus = Set<String>()
            for line in cherry.stdout.split(separator: "\n") {
                if line.hasPrefix("- ") { minus.insert(String(line.dropFirst(2))) } else if line.hasPrefix("+ ") { plus += 1 }
            }
            equivalent.formUnion(minus)
            if plus == 0 {
                // 병합 커밋은 cherry가 보지 않는다 → 범위를 직접 본다: 비었으면 조상, 병합 커밋 없이 모두 '-'면 cherry 동등.
                guard let range = rangeCommits(tip: tip, target: target, repo: state.repo) else { checked = false; continue }
                if range.commits.isEmpty { return done(LeftoverIntegration(method: .ancestor, target: name)) }
                if !range.hasMerges, !minus.isEmpty { return done(LeftoverIntegration(method: .cherry, target: name, commits: range.commits)) }
            } else if plus == 1, minus.isEmpty {
                // 커밋 하나짜리는 squash 패치가 그 커밋의 패치와 같다 — cherry가 이미 비교했으므로 patch-id 탐색을 건너뛴다.
                continue
            }
            // 2) squash: 합친 변경이 기본 브랜치 커밋 하나와 같은 패치인지(patch-id).
            switch squashMatch(tip: tip, target: target, repo: state.repo, deadline: budget.deadline) {
            case .match(let counterpart):
                guard let range = rangeCommits(tip: tip, target: target, repo: state.repo) else { checked = false; continue }
                return done(LeftoverIntegration(method: .squash, target: name, commits: range.commits, counterpart: counterpart))
            case .noMatch: break
            case .unknown: checked = false
            }
        }
        return done(nil)
    }

    /// 기본 브랜치에 없는 이쪽 커밋(전체 SHA, 최신 먼저)과 병합 커밋이 있는지. rangeCap보다 많거나 읽지 못하면 nil.
    func rangeCommits(tip: String, target: String, repo: String) -> (commits: [String], hasMerges: Bool)? {
        let range = git(["-C", repo, "rev-list", "--parents", "--max-count=\(Self.rangeCap + 1)", tip, "^" + target])
        guard range.succeeded else { return nil }
        let rows = range.stdout.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }.filter { !$0.isEmpty }
        guard rows.count <= Self.rangeCap else { return nil }
        return (rows.map { $0[0] }, rows.contains { $0.count > 2 })
    }

    enum SquashMatch: Equatable { case match(String), noMatch, unknown }

    /// 합친 변경(target...tip = merge-base..tip)의 바뀐 파일과 똑같은 파일만 바꾼 기본 브랜치 커밋(tip..target)을 찾아 patch-id를 비교한다. 모두 읽기 전용.
    func squashMatch(tip: String, target: String, repo: String, deadline: Date) -> SquashMatch {
        guard Date() < deadline else { return .unknown }
        let combined = target + "..." + tip
        let names = git(["-C", repo, "diff", "--name-only", "--no-renames", "-z", combined])
        guard names.succeeded else { return .unknown } // 공통 조상이 없으면 git이 거부한다 → 모름(보존)
        let files = Set(names.stdout.split(separator: "\0").map(String.init))
        if files.isEmpty { return .noMatch } // 합친 변경이 없다(커밋 뒤 되돌림) — 같은 패치가 있을 수 없다
        guard files.count <= Self.squashFileCap, Date() < deadline else { return .unknown }
        let log = git(["-C", repo, "log", "--no-merges", "--full-diff", "--format=%x00%H", "--name-only", "--no-renames", "-z", "--max-count=\(Self.squashLogCap)",
                       tip + ".." + target, "--"] + files.sorted().map { ":(literal)" + $0 })
        guard log.succeeded else { return .unknown }
        let commits = Self.parseNameLog(log.stdout)
        let candidates = commits.filter { $0.files == files }.prefix(Self.squashCandidateCap)
        guard !candidates.isEmpty else { return commits.count >= Self.squashLogCap ? .unknown : .noMatch }
        guard let mine = patchID(of: [combined], repo: repo) else { return .unknown }
        var unknown = false
        for candidate in candidates {
            guard Date() < deadline else { return .unknown }
            guard let theirs = patchID(of: [candidate.sha + "^", candidate.sha], repo: repo) else { unknown = true; continue }
            if theirs == mine { return .match(candidate.sha) }
        }
        return unknown ? .unknown : .noMatch
    }

    /// `git log --format=%x00%H --name-only -z` → (커밋, 바뀐 파일). 필드 순서: "", SHA, "\n파일", "파일", "", SHA, …
    static func parseNameLog(_ text: String) -> [(sha: String, files: Set<String>)] {
        var result: [(sha: String, files: Set<String>)] = []
        var previousEmpty = true
        for raw in text.split(separator: "\0", omittingEmptySubsequences: false) {
            let field = raw.hasPrefix("\n") ? String(raw.dropFirst()) : String(raw)
            if field.isEmpty { previousEmpty = true; continue }
            if previousEmpty, LeftoverScanner.isFullSHA(field) { result.append((field, [])) } else if !result.isEmpty { result[result.count - 1].files.insert(field) }
            previousEmpty = false
        }
        return result
    }

    /// 변경(["A...B"] 또는 ["A", "B"])의 `git patch-id --stable` 값. 비교하는 양쪽에 같은 diff 옵션을 쓴다(색·외부 diff·이름 바꿈 감지 끔).
    func patchID(of revisions: [String], repo: String) -> String? {
        let diff = git(["-C", repo, "diff"] + Self.patchDiffOptions + revisions)
        // 실행기는 출력을 UTF-8로 읽는다 — 깨진 바이트(대체 문자)가 있으면 서로 다른 diff가 같아 보일 수 있으므로 비교하지 않는다(모름 → 보존).
        guard diff.succeeded, !diff.stdout.contains("\u{FFFD}") else { return nil }
        return PatchID.stable(diff.stdout)
    }

    static let patchDiffOptions = ["--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", "--full-index", "--src-prefix=a/", "--dst-prefix=b/", "-U3"]

    /// tip에서만 닿는 커밋 중 기본 브랜치와 동등하지 않은 것의 수(이 수가 0보다 크면 그 참조가 마지막 참조다).
    /// 브랜치는 자기 ref를 뺀 모든 참조(다른 작업 공간 HEAD 포함)와 비교하고, 분리된 HEAD는 모든 ref + 메인 작업 공간 HEAD와 비교한다
    /// (--single-worktree: 다른 작업 공간의 HEAD는 지켜 주는 참조로 치지 않는다 — 그쪽도 정리될 수 있으므로 보수적으로).
    func uniqueCommits(tip: String, excludeRef: String?, equivalent: Set<String>, repo: String, deadline: Date) -> Int? {
        guard Date() < deadline, LeftoverScanner.isFullSHA(tip) else { return nil }
        var arguments = ["-C", repo, "rev-list", "--max-count=\(LeftoverRules.uniqueCommitCap)", tip, "--not"]
        if let excludeRef {
            // --exclude는 glob이다 — 이름에 glob 문자가 있으면 정확히 뺄 수 없어 세지 않는다.
            guard !excludeRef.contains(where: { "*?[\\".contains($0) }) else { return nil }
            arguments += ["--exclude=" + excludeRef, "--all"]
        } else {
            arguments += ["--single-worktree", "--all"]
        }
        let result = git(arguments)
        guard result.succeeded else { return nil }
        return result.stdout.split(separator: "\n").filter { !equivalent.contains(String($0)) }.count
    }

    /// 지운 뒤 확인: sha의 커밋이 기본 브랜치에 남아 있는지(조상) 또는 같은 패치가 있는지(동등). 확인하지 못하면 holds = nil.
    func integrationHolds(_ sha: String, state: RepoState) -> (holds: Bool?, evidence: String) {
        var unknown = false
        for ref in state.defaultRefs {
            let result = git(["-C", state.repo, "merge-base", "--is-ancestor", sha, ref])
            if result.succeeded { return (true, "조상: \(LeftoverScanner.shortRef(ref))에 남아 있음") }
            if result.status != 1 || result.timedOut { unknown = true }
        }
        // 지운 뒤에 지금의 기본 브랜치로 실제로 다시 확인한다(기억해 둔 결과를 쓰지 않는다).
        let probe = integration(tip: sha, state: state, budget: .unlimited(), memo: false)
        if let integration = probe.integration { return (true, integration.evidence) }
        return (unknown || !probe.checked || state.defaultRefs.isEmpty ? nil : false, "")
    }

    // MARK: 링크 의존

    /// 정리 후보가 된 작업 공간마다, 메인·형제 작업 공간 안에서 그 안을 가리키는 심볼릭 링크를 찾는다(저장소마다 한 번 걷는다).
    func applyLinkDependencies(_ worktrees: inout [WorktreeLeftover], state: RepoState) {
        let candidates = worktrees.indices.filter { [.cleanable(.removeWorktree), .cleanable(.orcaRemoveWorktree)].contains(worktrees[$0].verdict) }
        guard !candidates.isEmpty else { return }
        let index = linkIndex(state: state)
        for position in candidates {
            worktrees[position].linkReferrers = index.referrers(into: worktrees[position].path).map(\.display)
            worktrees[position].linksChecked = index.complete
            worktrees[position].verdict = LeftoverRules.verdict(for: worktrees[position], defaultBranch: state.defaultBranch)
        }
    }

    func linkIndex(state: RepoState) -> LinkIndex {
        LinkIndex.scan(roots: state.entries.filter { !$0.bare }.map(\.path), deadline: Date().addingTimeInterval(options.linkScanTime), maxEntries: options.linkScanEntries)
    }
}

// MARK: - 링크 의존

/// 메인·형제 작업 공간 안의 심볼릭 링크 중 다른 작업 공간 안을 가리키는 것(node_modules 링크 · .claude/worktrees 링크 등).
/// 링크는 따라 들어가지 않고(readlink로 글만 읽는다) 대상도 건드리지 않는다.
struct LinkIndex: Sendable {
    struct Link: Sendable, Equatable {
        /// 표시용 '작업공간이름/상대 경로'.
        var display: String
        /// 링크 자체의 경로.
        var path: String
        /// 링크가 가리키는 작업 공간 루트(정식 경로).
        var targetRoot: String
    }

    var links: [Link] = []
    /// 시간·항목 한도 안에 다 봤는지(false면 '못 찾음'이 '없음'이 아니다).
    var complete = true
    var entries = 0

    /// root 안을 가리키는 링크. 지금도 있는 것만(먼저 지운 작업 공간 안의 링크는 뺀다).
    func referrers(into root: String) -> [Link] {
        let key = SafeFileOps.canonical(root)
        return links.filter { link in
            var info = stat()
            return link.targetRoot == key && lstat(link.path, &info) == 0
        }
    }

    private enum Depth { case normal, nodeModules, scope, shallow }

    /// 빌드 산출물 폴더는 맨 위 항목만 본다(dist/assets 같은 링크는 잡고, 수십만 개 산출물은 걷지 않는다).
    static let shallowNames: Set<String> = ["target", "dist", "build", "out", ".output", "storybook-static"]

    /// roots: 저장소의 작업 공간 루트(메인 포함). 루트마다 걸으며 다른 루트 안을 가리키는 링크를 모은다.
    /// .git · 다른 작업 공간 루트(중첩 — 따로 걷는다) · 재생성 캐시 폴더에는 들어가지 않고, node_modules는 패키지 자리(node_modules/x · node_modules/@scope/x)만,
    /// 빌드 산출물 폴더는 맨 위만 본다.
    static func scan(roots rawRoots: [String], deadline: Date, maxEntries: Int) -> LinkIndex {
        var seen = Set<String>()
        let roots = rawRoots.map(SafeFileOps.canonical).filter { seen.insert($0).inserted }
        let rootSet = Set(roots)
        var index = LinkIndex()
        func owner(of path: String) -> String? {
            var best: String?
            for root in roots where path == root || path.hasPrefix(root + "/") {
                if (best?.count ?? -1) < root.count { best = root }
            }
            return best
        }
        let skipNames = IgnoredFiles.regenerableNames.subtracting(["node_modules"])
        for root in roots {
            var rootInfo = stat()
            guard lstat(root, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else { continue }
            let rootName = (root as NSString).lastPathComponent
            var stack: [(path: String, relative: String, depth: Depth)] = [(root, "", .normal)]
            while let (directory, relative, depth) = stack.popLast() {
                guard let handle = opendir(directory) else { continue }
                defer { closedir(handle) }
                while let entry = readdir(handle) {
                    let length = Int(entry.pointee.d_namlen)
                    let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in String(decoding: raw.prefix(length), as: UTF8.self) }
                    if name == "." || name == ".." { continue }
                    index.entries += 1
                    if index.entries % 1024 == 0, Date() >= deadline || index.entries >= maxEntries {
                        index.complete = false
                        return index
                    }
                    let path = directory + "/" + name
                    let rel = relative.isEmpty ? name : relative + "/" + name
                    var type = Int32(entry.pointee.d_type)
                    if type == DT_UNKNOWN {
                        var info = stat()
                        guard lstat(path, &info) == 0 else { continue }
                        switch info.st_mode & S_IFMT {
                        case S_IFLNK: type = DT_LNK
                        case S_IFDIR: type = DT_DIR
                        default: type = DT_REG
                        }
                    }
                    if type == DT_LNK {
                        guard let target = linkTarget(path, in: directory), let targetRoot = owner(of: target) ?? owner(of: SafeFileOps.canonical(target)),
                              targetRoot != root else { continue }
                        index.links.append(Link(display: rootName + "/" + rel, path: path, targetRoot: targetRoot))
                    } else if type == DT_DIR {
                        guard name != ".git", !rootSet.contains(path) else { continue }
                        let next: Depth
                        switch depth {
                        case .normal:
                            if name == "node_modules" {
                                next = .nodeModules
                            } else if skipNames.contains(name) {
                                continue
                            } else {
                                next = shallowNames.contains(name) ? .shallow : .normal
                            }
                        case .nodeModules:
                            guard name.hasPrefix("@") else { continue }
                            next = .scope
                        case .scope, .shallow:
                            continue
                        }
                        var info = stat()
                        guard lstat(path, &info) == 0, info.st_dev == rootInfo.st_dev else { continue } // 다른 볼륨은 넘지 않는다
                        stack.append((path, rel, next))
                    }
                }
            }
        }
        return index
    }

    /// 링크 글을 읽어 절대 경로로 바꾼다(. · .. 은 글자로만 정리). 링크를 따라가지 않는다.
    static func linkTarget(_ path: String, in directory: String) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = buffer.withUnsafeMutableBufferPointer { raw in
            raw.baseAddress!.withMemoryRebound(to: CChar.self, capacity: raw.count) { readlink(path, $0, Int(PATH_MAX)) }
        }
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
        return normalize(text.hasPrefix("/") ? text : directory + "/" + text)
    }

    /// 경로 글자 정리: 빈 칸·"."은 빼고 ".."은 앞 칸을 지운다(파일 시스템을 보지 않는다).
    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}

// MARK: - patch-id

/// `git patch-id --stable`과 같은 값(파일마다 SHA-1, 20바이트 덧셈 · 공백과 줄 번호 무시). 실행기는 표준 입력을 넘기지 않으므로
/// squash 동등을 확인할 때 diff 글을 직접 읽는다. git의 patch-id.c와 같은 순서로 줄을 읽는다(이진 파일은 앞·뒤 blob id). 빈 패치면 nil.
public enum PatchID {
    public static func stable(_ diff: String) -> String? {
        var result = [UInt8](repeating: 0, count: Insecure.SHA1.byteCount)
        var hasher = Insecure.SHA1()
        var patchLength = 0
        var before = -1, after = -1
        var binary = false
        var preImage: [UInt8] = [], postImage: [UInt8] = []

        func flush() {
            let digest = Array(hasher.finalize())
            hasher = Insecure.SHA1()
            var carry: UInt16 = 0
            for index in result.indices {
                carry += UInt16(result[index]) + UInt16(digest[index])
                result[index] = UInt8(truncatingIfNeeded: carry)
                carry >>= 8
            }
        }

        let bytes = Array(diff.utf8)
        var lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        if bytes.last == 0x0A { lines.removeLast() } // 마지막 줄바꿈 뒤의 빈 조각은 줄이 아니다
        lineLoop: for slice in lines {
            let line = Array(slice)
            func starts(_ prefix: String) -> Bool { line.starts(with: prefix.utf8) }
            let isCommit = starts("commit "), isFrom = starts("From ")
            // "\ No newline at end of file"은 건너뛴다.
            if !isCommit && !isFrom && starts("\\ ") && line.count + 1 > 12 { continue }
            // 다음 커밋 머리(16진수 id)면 이 패치는 끝(git diff 출력에는 없다).
            let head = isCommit ? line.dropFirst(7) : isFrom ? line.dropFirst(5) : line[...]
            if head.count >= 40, head.prefix(40).allSatisfy(isHex) { break lineLoop }
            if patchLength == 0 && !starts("diff ") { continue }
            if before == -1 {
                if starts("GIT binary patch") || starts("Binary files") {
                    binary = true
                    before = 0
                    hasher.update(data: preImage)
                    hasher.update(data: postImage)
                    flush()
                    continue
                } else if starts("index ") {
                    if let dots = firstRange(of: [0x2E, 0x2E], in: line) {
                        let space = line[(dots + 2)...].firstIndex(of: 0x20) ?? line.count
                        preImage = Array(line[6..<max(6, dots)].prefix(64))
                        postImage = Array(line[(dots + 2)..<space].prefix(64))
                    }
                    continue
                } else if starts("--- ") {
                    before = 1
                    after = 1
                } else if !(line.first.map(isAlpha) ?? false) {
                    break lineLoop
                }
            }
            if binary {
                if starts("diff ") {
                    binary = false
                    before = -1
                }
                continue
            }
            if before == 0 && after == 0 {
                if starts("@@ -") {
                    scanHunkHeader(line, &before, &after)
                    continue
                }
                if !starts("diff ") { break lineLoop }
                flush()
                before = -1
                after = -1
            }
            if let first = line.first {
                if first == UInt8(ascii: "-") || first == UInt8(ascii: " ") { before -= 1 }
                if first == UInt8(ascii: "+") || first == UInt8(ascii: " ") { after -= 1 }
            }
            let kept = line.filter { $0 != 0x20 && $0 != 0x09 && $0 != 0x0A && $0 != 0x0D }
            patchLength += kept.count
            hasher.update(data: kept)
        }
        flush()
        guard patchLength > 0 else { return nil }
        return result.map { String(format: "%02x", $0) }.joined()
    }

    static func isHex(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte) }
    static func isAlpha(_ byte: UInt8) -> Bool { (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }

    static func firstRange(of needle: [UInt8], in line: [UInt8]) -> Int? {
        guard line.count >= needle.count else { return nil }
        for start in 0...(line.count - needle.count) where line[start] == needle[0] && Array(line[start..<(start + needle.count)]) == needle { return start }
        return nil
    }

    /// "@@ -a[,b] +c[,d] @@"에서 앞·뒤 줄 수만 읽는다(줄 번호는 버린다) — git scan_hunk_header와 같다.
    static func scanHunkHeader(_ line: [UInt8], _ before: inout Int, _ after: inout Int) {
        func digits(_ start: Int) -> Int {
            var count = 0
            while start + count < line.count, (0x30...0x39).contains(line[start + count]) { count += 1 }
            return count
        }
        func number(_ start: Int) -> Int { Int(String(decoding: line[start..<(start + digits(start))], as: UTF8.self)) ?? 0 }
        var q = 4
        var n = digits(q)
        if q + n < line.count, line[q + n] == UInt8(ascii: ",") {
            q += n + 1
            before = number(q)
            n = digits(q)
        } else {
            before = 1
        }
        guard n != 0, q + n + 1 < line.count, line[q + n] == UInt8(ascii: " "), line[q + n + 1] == UInt8(ascii: "+") else { return }
        var r = q + n + 2
        n = digits(r)
        if r + n < line.count, line[r + n] == UInt8(ascii: ",") {
            r += n + 1
            after = number(r)
        } else {
            after = 1
        }
    }
}
