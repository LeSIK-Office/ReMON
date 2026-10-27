import Darwin
import Foundation
import zlib

// AI 데이터 위생(G1): 저장된 Claude 기록 · Codex 스레드 · AI 앱 캐시 · 이전 CLI 버전을 '남기는 이유가 보이는' 검토 목록으로 만든다.
// 실행 중 · 복구함 보관 · 24시간 안에 바뀐 것은 고를 수 없다. 대화는 휴지통(되돌리기)·Codex 자체 보관(unarchive)만,
// 영구 삭제는 다시 생기는 캐시(A)와 아무도 쓰지 않는 이전 버전(B)뿐이다. 조사는 읽기 전용이고, 실행 직전에 다시 확인한다.

/// 위생 기능이 보는 위치. 시험은 임시 폴더로 바꾼다.
public struct AIDataPaths: Sendable, Equatable {
    public var home: String
    public var claudeProjects: String
    public var claudeVersions: String
    /// 현재 Claude 버전을 가리키는 링크(~/.local/bin/claude → versions/<버전>)
    public var claudeLauncher: String
    public var codexHome: String
    public var appSupport: String
    public var caches: String
    /// Cursor Agent 버전 폴더 · 현재 버전 링크 · 표시 이름(독립 설치 · Cursor 앱 안)
    public var cursorAgentRoots: [(versions: String, launcher: String, channel: String)] {
        let embedded = appSupport + "/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local"
        return [(home + "/.local/share/cursor-agent/versions", home + "/.local/bin/cursor-agent", "독립 설치"),
                (embedded + "/share/cursor-agent/versions", embedded + "/bin/cursor-agent", "Cursor 앱 안")]
    }

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        claudeProjects = home + "/.claude/projects"
        claudeVersions = home + "/.local/share/claude/versions"
        claudeLauncher = home + "/.local/bin/claude"
        codexHome = home + "/.codex"
        appSupport = home + "/Library/Application Support"
        caches = home + "/Library/Caches"
    }

    /// Codex 패키지 묶음(독립 실행 · 앱 서버 데몬). 묶음마다 current 링크가 현재 버전이다.
    public var codexPackageRoots: [String] { ["standalone", "app-server-daemon"].map { codexHome + "/packages/" + $0 } }
}

public struct AIDataOptions: Sendable, Equatable {
    /// 이 일수보다 오래 활동이 없으면 '오래됨'(Claude 기록 · Codex 스레드).
    public var staleDays: Double
    /// 이 시간 안에 바뀐 것은 고르지 않는다.
    public var recentGuard: TimeInterval = 86_400

    public init(staleDays: Double = 60) { self.staleDays = staleDays }
}

/// 파일 정체(장치 + inode). 하드링크·링크로 다른 이름이어도 같은 파일인지 본다.
public struct FileIdentity: Hashable, Sendable {
    public var device: Int64
    public var inode: UInt64

    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        device = Int64(info.st_dev)
        inode = UInt64(info.st_ino)
    }
}

/// 실행 중인 프로세스의 실행 파일. 이전 버전이 아직 쓰이는지(경로 · inode)를 가린다.
public struct RunningExecutable: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    /// 커널이 아는 실행 파일 경로(proc_pidpath, 정식 경로). 업데이트로 파일이 지워졌으면 nil.
    public var path: String?
    /// path가 없을 때만: execve에 넘긴 경로(KERN_PROCARGS2)
    public var execPath: String?
    public var identity: FileIdentity?

    public init(pid: Int32, name: String, path: String?, execPath: String? = nil, identity: FileIdentity? = nil) {
        self.pid = pid
        self.name = name
        self.path = path
        self.execPath = execPath
        self.identity = identity
    }

    /// 같은 사용자 프로세스 전부. 하드링크(ClaudeCode.app ↔ versions/<버전>, 10-25 실측)도 잡도록 inode까지 적는다.
    public static func collect(_ records: [ProcRecord], uid: UInt32 = getuid()) -> [RunningExecutable] {
        records.filter { $0.uid == uid }.map { record in
            if let path = record.path, !path.isEmpty {
                return RunningExecutable(pid: record.pid, name: record.name, path: SafeFileOps.canonical(path), identity: FileIdentity(path: path))
            }
            let exec = ProcessSampler.readArguments(pid: record.pid)?.executable
            let resolved = exec.flatMap { $0.hasPrefix("/") ? SafeFileOps.canonical($0) : nil }
            return RunningExecutable(pid: record.pid, name: record.name, path: nil, execPath: resolved)
        }
    }
}

/// 정리하면 안 되는 것을 가리는 지금 상태(실행 중 세션 · 복구함 · 프로세스). 조사 직전과 실행 직전에 새로 만든다.
public struct AIDataContext: Sendable {
    public var now: Date
    /// 실행 중 세션이 쓰는 기록 파일(정식 경로)
    public var runningTranscripts: Set<String>
    /// 실행 중 세션의 대화 id(소문자) — Claude 레지스트리 sessionId · Codex rollout 스레드 id
    public var runningSessionIDs: Set<String>
    /// 복구함이 보관 중인 세션의 기록 · id(되살릴 때 쓴다)
    public var vaultTranscripts: Set<String>
    public var vaultSessionIDs: Set<String>
    public var executables: [RunningExecutable]
    /// 열린 파일 확인에 쓰는 사용자 프로세스
    public var userPIDs: [Int32]

    public init(now: Date = Date(), runningTranscripts: Set<String> = [], runningSessionIDs: Set<String> = [], vaultTranscripts: Set<String> = [],
                vaultSessionIDs: Set<String> = [], executables: [RunningExecutable] = [], userPIDs: [Int32] = []) {
        self.now = now
        self.runningTranscripts = Set(runningTranscripts.map(SafeFileOps.canonical))
        self.runningSessionIDs = Set(runningSessionIDs.map { $0.lowercased() })
        self.vaultTranscripts = Set(vaultTranscripts.map(SafeFileOps.canonical))
        self.vaultSessionIDs = Set(vaultSessionIDs.map { $0.lowercased() })
        self.executables = executables
        self.userPIDs = userPIDs
    }

    /// 앱의 지금 상태로 만든다. Codex 데스크톱 앱 서버처럼 세션 목록에 없는 프로세스가 연 rollout도 실행 중으로 본다.
    public static func live(sessions: [AgentSession], processes: [ProcRecord], vaultEntries: [RecoveryEntry], registry: [Int32: ClaudeRegistryEntry], now: Date = Date()) -> AIDataContext {
        var transcripts = Set<String>(), ids = Set<String>()
        func note(_ path: String) {
            transcripts.insert(path)
            if let id = SessionLogReader.threadID(fromPath: path) { ids.insert(id) }
        }
        for session in sessions { ([session.logPath].compactMap { $0 } + session.extraLogPaths).forEach(note) }
        for entry in registry.values { if let id = entry.sessionId { ids.insert(id) } }
        let uid = getuid()
        for record in processes where record.uid == uid && (record.name == "codex" || (record.path ?? "").lowercased().contains("codex")) {
            for file in ProcessSampler.openFiles(pid: record.pid) where file.hasSuffix(".jsonl") && file.contains("/.codex/") { note(file) }
        }
        var vaultTranscripts = Set<String>(), vaultIDs = Set<String>()
        for entry in vaultEntries where entry.kind == .session && [.held, .restoring, .retiring].contains(entry.status) {
            if let transcript = entry.transcript { vaultTranscripts.insert(transcript) }
            if let id = entry.resumeID { vaultIDs.insert(id) }
        }
        return AIDataContext(now: now, runningTranscripts: transcripts, runningSessionIDs: ids, vaultTranscripts: vaultTranscripts, vaultSessionIDs: vaultIDs,
                             executables: RunningExecutable.collect(processes), userPIDs: processes.filter { $0.memorySource == .kernel }.map(\.pid))
    }
}

/// 실행 결과 한 줄(항목마다).
public struct AIDataResult: Sendable, Equatable {
    public var target: String
    public var ok: Bool
    public var skipped: Bool
    public var bytes: UInt64
    public var message: String

    public init(target: String, ok: Bool, skipped: Bool, bytes: UInt64, message: String) {
        self.target = target
        self.ok = ok
        self.skipped = skipped
        self.bytes = bytes
        self.message = message
    }
}

// MARK: - Claude 기록

public enum ClaudeTranscriptName {
    static let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#

    public static func isUUID(_ text: String) -> Bool { text.range(of: uuidPattern, options: .regularExpression) != nil }

    /// <id>.jsonl · <id>.jsonl.gz(압축된 옛 기록, 10-25 실측 45개) → id
    public static func sessionID(_ name: String) -> (id: String, compressed: Bool)? {
        if name.hasSuffix(".jsonl.gz"), isUUID(String(name.dropLast(9))) { return (String(name.dropLast(9)).lowercased(), true) }
        if name.hasSuffix(".jsonl"), isUUID(String(name.dropLast(6))) { return (String(name.dropLast(6)).lowercased(), false) }
        return nil
    }

    /// 기록 폴더 바로 아래에서 위생 기능이 휴지통으로 옮길 수 있는 이름(기록 파일 · 같은 id의 하위 폴더).
    public static func isTranscriptEntry(_ name: String) -> Bool { sessionID(name) != nil || isUUID(name) }
}

public struct ClaudeTranscript: Identifiable, Sendable, Equatable {
    public enum Group: String, Sendable, CaseIterable {
        case projectGone, stale
    }

    public var id: String { path }
    /// 기록 파일(<id>.jsonl · .jsonl.gz). 기록 없이 남은 하위 폴더면 그 폴더.
    public var path: String
    public var sessionID: String
    /// 프로젝트 기록 폴더 이름(작업 폴더를 '-'로 이은 것)
    public var folder: String
    /// 같은 id의 하위 폴더(subagents · tool-results)
    public var companion: String?
    public var subagents: Int
    public var compressed: Bool
    public var cwd: String?
    public var project: String
    public var title: String?
    /// 기록의 마지막 timestamp(압축 기록은 nil — 수정 시각으로 대신 본다)
    public var lastActivity: Date?
    public var modified: Date
    /// 기록 · 하위 폴더 · 하위 기록 중 가장 최근 수정 시각
    public var newestChange: Date
    public var bytes: UInt64
    public var group: Group?
    public var keepReason: String?
    /// 판정 참고(외장 볼륨 미연결 등)
    public var note: String?

    public var isOrphanFolder: Bool { companion == path }
    public var selectable: Bool { group != nil && keepReason == nil }
    public var activity: Date { lastActivity ?? modified }
}

public enum ClaudeTranscriptScanner {
    public struct Summary: Sendable, Equatable {
        public var items: [ClaudeTranscript]
        public var scanned: Int
        public var bytes: UInt64
    }

    /// 그룹(프로젝트 폴더 소실 · 오래됨)에 드는 기록만 돌려준다(남기는 이유가 있어도 함께 — 화면에 이유를 보인다).
    public static func scan(paths: AIDataPaths, options: AIDataOptions, context: AIDataContext) -> Summary {
        let fm = FileManager.default
        var items: [ClaudeTranscript] = []
        var scanned = 0
        var total: UInt64 = 0
        for folder in ((try? fm.contentsOfDirectory(atPath: paths.claudeProjects)) ?? []).sorted() {
            let directory = paths.claudeProjects + "/" + folder
            // 링크(외장 이전된 폴더)는 건너뛴다.
            guard fileType(directory) == S_IFDIR else { continue }
            let names = ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).sorted()
            var claimed = Set<String>()
            // 압축본과 원본이 함께 있으면 하위 폴더는 원본이 가진다.
            let transcripts = names.compactMap { name -> (name: String, id: String, compressed: Bool)? in
                ClaudeTranscriptName.sessionID(name).map { (name, $0.id, $0.compressed) }
            }.sorted { !$0.compressed && $1.compressed }
            for entry in transcripts {
                let path = directory + "/" + entry.name
                guard fileType(path) == S_IFREG else { continue }
                let companionPath = directory + "/" + entry.id
                let companion = !claimed.contains(entry.id) && fileType(companionPath) == S_IFDIR ? companionPath : nil
                claimed.insert(entry.id)
                var item = autoreleasepool { read(path: path, id: entry.id, folder: folder, compressed: entry.compressed, companion: companion) }
                classify(&item, options: options, context: context)
                scanned += 1
                total += item.bytes
                if item.group != nil { items.append(item) }
            }
            // 기록 없이 남은 하위 폴더(기록만 지워지고 subagents·tool-results가 남은 것, 10-25 실측 2개)
            for name in names where ClaudeTranscriptName.isUUID(name) && !claimed.contains(name.lowercased()) {
                let path = directory + "/" + name
                guard fileType(path) == S_IFDIR else { continue }
                var item = autoreleasepool { read(path: path, id: name.lowercased(), folder: folder, compressed: false, companion: path) }
                classify(&item, options: options, context: context)
                scanned += 1
                total += item.bytes
                if item.group != nil { items.append(item) }
            }
        }
        return Summary(items: items.sorted { $0.bytes > $1.bytes }, scanned: scanned, bytes: total)
    }

    /// 기록 하나의 사실: 앞부분에서 cwd·제목, 끝부분에서 마지막 timestamp, 크기(하위 폴더 포함).
    public static func read(path: String, id: String, folder: String, compressed: Bool, companion: String?) -> ClaudeTranscript {
        let orphan = companion == path
        let modified = modificationDate(path) ?? .distantPast
        var head = HeadFacts()
        var last: Date?
        if !orphan {
            head = headFacts(compressed ? gunzipHead(path, limit: 1 << 20) : readHead(path, 1 << 20))
            if !compressed { last = lastTimestamp(readTail(path, 256 << 10)) }
        }
        var newest = modified
        var subagents = 0
        if let companion {
            let subfolder = companion + "/subagents"
            let names = (try? FileManager.default.contentsOfDirectory(atPath: subfolder)) ?? []
            let logs = names.filter { $0.hasSuffix(".jsonl") }.sorted()
            subagents = logs.count
            for name in names { if let date = modificationDate(subfolder + "/" + name), date > newest { newest = date } }
            for path in [companion, subfolder, companion + "/tool-results"] { if let date = modificationDate(path), date > newest { newest = date } }
            // 기록 없는 하위 폴더는 하위 기록에서 cwd·마지막 시각을 읽는다.
            if head.cwd == nil, let first = logs.first { head.cwd = headFacts(readHead(subfolder + "/" + first, 256 << 10)).cwd }
            if orphan { last = logs.compactMap { lastTimestamp(readTail(subfolder + "/" + $0, 64 << 10)) }.max() }
        }
        let bytes = (orphan ? 0 : DiskScanner.allocatedSize(path)) + (companion.map(DiskScanner.allocatedSize) ?? 0)
        return ClaudeTranscript(path: path, sessionID: id, folder: folder, companion: companion, subagents: subagents, compressed: compressed, cwd: head.cwd,
                                project: SessionDetector.projectName(for: head.cwd), title: head.title, lastActivity: last, modified: modified, newestChange: newest,
                                bytes: bytes, group: nil, keepReason: nil, note: nil)
    }

    /// 그룹과 남기는 이유. 실행 직전 다시 확인할 때도 같은 규칙을 쓴다.
    public static func classify(_ item: inout ClaudeTranscript, options: AIDataOptions, context: AIDataContext) {
        item.group = nil
        item.keepReason = nil
        item.note = nil
        if let cwd = item.cwd, !cwd.isEmpty {
            let state = folderState(cwd)
            if state.gone { item.group = .projectGone } else { item.note = state.note }
        }
        if item.group == nil, context.now.timeIntervalSince(item.activity) >= options.staleDays * 86_400 { item.group = .stale }
        guard item.group != nil else { return }
        let canonical = SafeFileOps.canonical(item.path)
        if context.runningTranscripts.contains(canonical) || context.runningSessionIDs.contains(item.sessionID) {
            item.keepReason = "실행 중인 세션의 기록입니다"
        } else if context.vaultTranscripts.contains(canonical) || context.vaultSessionIDs.contains(item.sessionID) {
            item.keepReason = "복구함이 이 기록으로 세션을 되살립니다"
        } else if context.now.timeIntervalSince(item.newestChange) < options.recentGuard {
            item.keepReason = "최근 24시간 안에 바뀌었습니다"
        }
    }

    /// 실행 직전: 수정 시각만 다시 재고 같은 규칙으로 다시 판정한다(내용은 다시 읽지 않는다).
    public static func refresh(_ item: ClaudeTranscript, options: AIDataOptions, context: AIDataContext) -> ClaudeTranscript? {
        guard fileType(item.path) != nil else { return nil }
        var fresh = item
        fresh.modified = modificationDate(item.path) ?? item.modified
        var newest = fresh.modified
        if let companion = item.companion {
            let subfolder = companion + "/subagents"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: subfolder)) ?? [] {
                if let date = modificationDate(subfolder + "/" + name), date > newest { newest = date }
            }
            for path in [companion, subfolder, companion + "/tool-results"] { if let date = modificationDate(path), date > newest { newest = date } }
        }
        fresh.newestChange = newest
        classify(&fresh, options: options, context: context)
        return fresh
    }

    /// 작업 폴더가 정말 없는가(ENOENT · ENOTDIR). 권한 없음(보호 폴더 EPERM 등)·빠진 외장 볼륨은 '모름'으로 두고 소실로 보지 않는다.
    static func folderState(_ path: String) -> (gone: Bool, note: String?) {
        var info = stat()
        guard stat(path, &info) != 0 else { return (false, nil) }
        let code = errno
        guard code == ENOENT || code == ENOTDIR else { return (false, "폴더를 확인하지 못했습니다(\(String(cString: strerror(code))))") }
        if let volume = unmountedVolume(path) { return (false, "외장 볼륨(\(volume))이 연결되지 않아 폴더를 확인하지 못했습니다") }
        return (true, nil)
    }

    static func unmountedVolume(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        let volume = "/Volumes/" + parts[1]
        return FileManager.default.fileExists(atPath: volume) ? nil : String(parts[1])
    }

    // MARK: 읽기

    struct HeadFacts { var cwd: String?; var title: String? }

    /// 앞부분 줄들: 첫 cwd, 제목(ai-title > summary > 첫 사용자 요청). 큰 줄은 표식이 있을 때만 해석한다.
    static func headFacts(_ data: Data) -> HeadFacts {
        var facts = HeadFacts()
        var aiTitle: String?, summary: String?, userText: String?
        let cwdMarker = Data("\"cwd\"".utf8), titleMarker = Data("\"ai-title\"".utf8), summaryMarker = Data("\"summary\"".utf8), userMarker = Data("\"type\":\"user\"".utf8)
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // 한도에서 잘린 마지막 줄은 버린다.
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        for line in lines {
            guard line.first == UInt8(ascii: "{"), line.count < 4 << 20 else { continue }
            let wantCwd = facts.cwd == nil && line.range(of: cwdMarker) != nil
            let wantTitle = (aiTitle == nil && line.range(of: titleMarker) != nil) || (summary == nil && line.range(of: summaryMarker) != nil) || (userText == nil && line.range(of: userMarker) != nil)
            guard wantCwd || wantTitle, let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if facts.cwd == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty { facts.cwd = cwd }
            switch object["type"] as? String {
            case "ai-title": if aiTitle == nil { aiTitle = object["aiTitle"] as? String }
            case "summary": if summary == nil { summary = object["summary"] as? String }
            default: if userText == nil { userText = SessionLogReader.userText(object, kind: .claudeCode) }
            }
            if facts.cwd != nil, aiTitle != nil { break }
        }
        facts.title = [aiTitle, summary, userText].compactMap { $0.flatMap { Redactor.headline($0) } }.first
        return facts
    }

    /// 끝부분의 마지막 "timestamp":"…"(거대한 줄이 잘려 있어도 원문에서 바로 찾는다. 문자열 안의 것은 \"로 이스케이프돼 걸리지 않는다).
    static func lastTimestamp(_ data: Data) -> Date? {
        let needle = Data("\"timestamp\":\"".utf8)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var end = data.endIndex
        while let range = data.range(of: needle, options: .backwards, in: data.startIndex..<end) {
            let rest = data[range.upperBound...].prefix(40)
            if let close = rest.firstIndex(of: UInt8(ascii: "\"")) {
                let text = String(decoding: rest[rest.startIndex..<close], as: UTF8.self)
                if let date = fractional.date(from: text) ?? plain.date(from: text) { return date }
            }
            end = range.lowerBound
        }
        return nil
    }

    static func readHead(_ path: String, _ count: Int) -> Data { ResumeKey.readHead(path, count) }
    static func readTail(_ path: String, _ count: Int) -> Data { ResumeKey.readTail(path, count) }

    /// gzip 기록의 앞부분만 푼다(zlib, 끝까지 풀지 않는다).
    static func gunzipHead(_ path: String, limit: Int) -> Data {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Data() }
        defer { try? handle.close() }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Data() }
        defer { inflateEnd(&stream) }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var finished = false
        while !finished, output.count < limit, let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty {
            var input = [UInt8](chunk)
            input.withUnsafeMutableBufferPointer { source in
                stream.next_in = source.baseAddress
                stream.avail_in = uInt(source.count)
                repeat {
                    let status: Int32 = buffer.withUnsafeMutableBufferPointer { target in
                        stream.next_out = target.baseAddress
                        stream.avail_out = uInt(target.count)
                        let status = inflate(&stream, Z_NO_FLUSH)
                        output.append(target.baseAddress!, count: target.count - Int(stream.avail_out))
                        return status
                    }
                    if status != Z_OK { finished = true }
                } while !finished && stream.avail_in > 0 && output.count < limit
            }
        }
        return output.count > limit ? output.prefix(limit) : output
    }
}

// MARK: - 파일 도우미

/// lstat 종류(S_IFREG · S_IFDIR · S_IFLNK …). 없으면 nil.
func fileType(_ path: String) -> mode_t? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return info.st_mode & S_IFMT
}

func modificationDate(_ path: String) -> Date? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
}

// MARK: - 한 번에 조사

public struct AIDataReport: Sendable, Equatable {
    public var scannedAt: Date
    public var elapsed: TimeInterval
    public var options: AIDataOptions
    /// 그룹에 든 Claude 기록(남기는 이유 포함)
    public var transcripts: [ClaudeTranscript]
    public var transcriptCount: Int
    public var transcriptBytes: UInt64
    public var codex: CodexThreadReport
    public var caches: [AIAppCache]
    public var versions: [CLIVersion]

    public func transcripts(in group: ClaudeTranscript.Group) -> [ClaudeTranscript] { transcripts.filter { $0.group == group } }
}

public enum AIDataScanner {
    /// 읽기 전용 조사. codexCLI가 있으면 archive·unarchive 지원을 도움말로 확인한다(표준 입력 닫음).
    public static func scan(paths: AIDataPaths = AIDataPaths(), options: AIDataOptions = AIDataOptions(), context: AIDataContext, codexCLI: CodexCLI?) -> AIDataReport {
        let started = Date()
        let claude = ClaudeTranscriptScanner.scan(paths: paths, options: options, context: context)
        let codex = CodexStateReader.report(paths: paths, options: options, context: context, cli: codexCLI)
        let caches = AIAppCacheCatalog.scan(paths: paths, context: context)
        let versions = CLIVersionCatalog.scan(paths: paths, options: options, context: context)
        return AIDataReport(scannedAt: context.now, elapsed: Date().timeIntervalSince(started), options: options, transcripts: claude.items, transcriptCount: claude.scanned,
                            transcriptBytes: claude.bytes, codex: codex, caches: caches, versions: versions)
    }
}
