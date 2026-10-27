import Foundation
import SQLite3

// Codex 스레드 위생: ~/.codex/state_*.sqlite를 읽기 전용(SQLITE_OPEN_READONLY)으로 열어 오래된 스레드를 고르고,
// 정리는 Codex 자체 보관(`codex archive <id>`)만 쓴다 — `codex unarchive <id>`로 되돌린다. 열 이름은 pragma_table_info로 확인하고,
// 필요한 열(id · 갱신 시각 · 고정 · 보관)을 모두 찾지 못하면 목록만 보이고 버튼을 끈다. 10-25 실측: state_5 · threads 2,840개(하위 1,900).

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite 읽기 전용 연결. Codex가 쓰는 중이어도 읽기만 한다(WAL 공유 잠금).
final class ReadOnlySQLite {
    enum Value: Equatable {
        case integer(Int64), real(Double), text(String), null
        var integer: Int64? {
            switch self {
            case .integer(let value): value
            case .real(let value): Int64(value)
            case .text(let value): Int64(value)
            case .null: nil
            }
        }
        var text: String? {
            switch self {
            case .text(let value): value
            case .integer(let value): String(value)
            case .real(let value): String(value)
            case .null: nil
            }
        }
    }

    private var handle: OpaquePointer?

    init?(path: String) {
        guard fileType(path) == S_IFREG else { return nil }
        let escaped = path.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "?", with: "%3f").replacingOccurrences(of: "#", with: "%23")
        guard sqlite3_open_v2("file:" + escaped + "?mode=ro", &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close_v2(handle)
            handle = nil
            return nil
        }
        sqlite3_busy_timeout(handle, 3000)
    }

    deinit { sqlite3_close_v2(handle) }

    /// 행(열 이름 → 값). 실패하면 nil.
    func rows(_ sql: String, _ arguments: [String] = []) -> [[String: Value]]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        for (index, argument) in arguments.enumerated() { sqlite3_bind_text(statement, Int32(index + 1), argument, -1, SQLITE_TRANSIENT) }
        var result: [[String: Value]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            var row: [String: Value] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_NULL: row[name] = .null
                default: row[name] = sqlite3_column_text(statement, column).map { .text(String(cString: $0)) } ?? .null
                }
            }
            result.append(row)
        }
        return result
    }
}

public struct CodexThread: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String?
    public var cwd: String?
    public var project: String
    public var rolloutPath: String?
    /// rollout 파일이 있을 때 그 크기(대부분은 대화 기록 DB 안에 있어 0, 10-25 실측 2,840개 중 226개만 파일)
    public var rolloutBytes: UInt64
    public var updatedAt: Date?
    public var pinned: Bool?
    public var archived: Bool?
    /// 이 스레드가 띄운 하위 에이전트 스레드 수
    public var children: Int
    public var keepReason: String?

    public var selectable: Bool { keepReason == nil }
}

public struct CodexThreadReport: Sendable, Equatable {
    public var database: String?
    /// 열 확인 결과(화면 표시용 한 줄)
    public var schemaNote: String
    /// 역할 → 실제 열 이름
    public var columns: [String: String]
    /// 버튼을 켜도 되는가(필요한 열 + CLI의 archive·unarchive 지원)
    public var canAct: Bool
    public var cli: CodexCLI?
    public var cliNote: String?
    public var totalThreads: Int
    public var archivedThreads: Int
    /// 오래된 최상위 · 보관 안 된 스레드(남기는 이유 포함)
    public var threads: [CodexThread]

    public static func empty(_ note: String) -> CodexThreadReport {
        CodexThreadReport(database: nil, schemaNote: note, columns: [:], canAct: false, cli: nil, cliNote: nil, totalThreads: 0, archivedThreads: 0, threads: [])
    }

    /// 버튼을 끈 이유(켜져 있으면 nil): 스키마가 먼저, 그다음 CLI.
    public var actionBlock: String? {
        guard !canAct else { return nil }
        if database == nil || CodexStateReader.requiredForActions.contains(where: { columns[$0] == nil }) { return schemaNote }
        return cliNote ?? schemaNote
    }
}

public enum CodexStateReader {
    /// ~/.codex/state_<N>.sqlite 중 N이 가장 큰 것.
    public static func locateDatabase(codexHome: String = NSHomeDirectory() + "/.codex") -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: codexHome)) ?? []
        let numbered = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"), let number = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (number, name)
        }
        return numbered.max { $0.0 < $1.0 }.map { codexHome + "/" + $0.1 }
    }

    /// 역할별 후보 열(앞의 것 우선).
    static let candidates: [(role: String, names: [String])] = [
        ("id", ["id", "thread_id"]), ("rollout", ["rollout_path"]), ("updatedMs", ["updated_at_ms", "recency_at_ms"]), ("updated", ["updated_at", "recency_at"]),
        ("pinned", ["is_pinned", "pinned"]), ("archived", ["archived", "is_archived"]), ("cwd", ["cwd"]), ("name", ["name"]), ("title", ["title"]),
        ("preview", ["preview", "first_user_message"]), ("source", ["source"]), ("threadSource", ["thread_source"])
    ]
    static let requiredForActions = ["id", "pinned", "archived"]

    static func columns(_ db: ReadOnlySQLite, table: String) -> Set<String> {
        Set((db.rows("SELECT name FROM pragma_table_info(?)", [table]) ?? []).compactMap { $0["name"]?.text })
    }

    static func schema(_ db: ReadOnlySQLite) -> [String: String] {
        let available = columns(db, table: "threads")
        var mapped: [String: String] = [:]
        for (role, names) in candidates { if let found = names.first(where: available.contains) { mapped[role] = found } }
        return mapped
    }

    /// 읽기 전용 조사. 스키마를 모르면 목록만(또는 빈 목록) 보이고 canAct = false.
    public static func report(paths: AIDataPaths, options: AIDataOptions, context: AIDataContext, cli: CodexCLI?) -> CodexThreadReport {
        guard let database = locateDatabase(codexHome: paths.codexHome) else { return .empty("Codex 상태 DB(state_*.sqlite)가 없습니다") }
        guard let db = ReadOnlySQLite(path: database) else { return .empty("Codex 상태 DB를 읽기 전용으로 열지 못했습니다") }
        let columns = schema(db)
        guard columns["id"] != nil, columns["updatedMs"] != nil || columns["updated"] != nil else {
            var report = CodexThreadReport.empty("스키마를 모릅니다(threads 표의 id·갱신 시각 열 없음) — 보여 주기만 합니다")
            report.database = database
            return report
        }
        let missing = requiredForActions.filter { columns[$0] == nil }
        let selected = Array(Set(columns.values)).sorted()
        let sql = "SELECT " + selected.map { "\"\($0)\"" }.joined(separator: ", ") + " FROM threads"
        guard let rows = db.rows(sql) else { var report = CodexThreadReport.empty("threads 표를 읽지 못했습니다"); report.database = database; return report }
        // 하위 에이전트 관계(thread_spawn_edges)가 있으면 최상위만 고른다.
        var parentOf: [String: String] = [:], children: [String: Int] = [:]
        let edgeColumns = self.columns(db, table: "thread_spawn_edges")
        if edgeColumns.isSuperset(of: ["parent_thread_id", "child_thread_id"]) {
            for row in db.rows("SELECT parent_thread_id, child_thread_id FROM thread_spawn_edges") ?? [] {
                guard let parent = row["parent_thread_id"]?.text?.lowercased(), let child = row["child_thread_id"]?.text?.lowercased() else { continue }
                parentOf[child] = parent
                children[parent, default: 0] += 1
            }
        }
        var threads: [CodexThread] = []
        var archivedCount = 0
        for row in rows {
            guard let rawID = columns["id"].flatMap({ row[$0]?.text }), !rawID.isEmpty else { continue }
            let id = rawID.lowercased()
            let archived = columns["archived"].flatMap { row[$0]?.integer }.map { $0 != 0 }
            if archived == true { archivedCount += 1; continue }
            // 하위 에이전트·검토 스레드(source {"subagent":…} · thread_source subagent/guardian_review)는 최상위가 아니다.
            let source = ["source", "threadSource"].compactMap { columns[$0].flatMap { row[$0]?.text } }.joined(separator: " ")
            if parentOf[id] != nil || source.contains("subagent") || source.contains("guardian") { continue }
            let updated = updatedDate(row, columns)
            guard let updated, context.now.timeIntervalSince(updated) >= options.staleDays * 86_400 else { continue }
            var thread = CodexThread(id: id, title: nil, cwd: columns["cwd"].flatMap { row[$0]?.text }, project: "", rolloutPath: columns["rollout"].flatMap { row[$0]?.text },
                                     rolloutBytes: 0, updatedAt: updated, pinned: columns["pinned"].flatMap { row[$0]?.integer }.map { $0 != 0 }, archived: archived,
                                     children: children[id] ?? 0, keepReason: nil)
            thread.project = SessionDetector.projectName(for: thread.cwd)
            thread.title = ["name", "title", "preview"].compactMap { columns[$0].flatMap { row[$0]?.text }.flatMap { Redactor.headline($0) } }.first
            if let rollout = thread.rolloutPath, fileType(rollout) == S_IFREG { thread.rolloutBytes = DiskScanner.allocatedSize(rollout) }
            classify(&thread, options: options, context: context)
            threads.append(thread)
        }
        var report = CodexThreadReport(database: database, schemaNote: "", columns: columns, canAct: false, cli: cli, cliNote: nil, totalThreads: rows.count,
                                       archivedThreads: archivedCount, threads: threads.sorted { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) })
        if missing.isEmpty {
            report.schemaNote = "열 확인됨(" + requiredForActions.compactMap { columns[$0] }.joined(separator: " · ") + ")"
        } else {
            report.schemaNote = "필요한 열이 없습니다(\(missing.joined(separator: ", "))) — 보여 주기만 합니다"
        }
        if let cli {
            let supported = cli.supportsArchive()
            report.cliNote = supported ? "codex archive · unarchive 지원" : "설치된 codex가 archive·unarchive를 모릅니다 — 업데이트가 필요합니다"
            report.canAct = missing.isEmpty && supported
        } else {
            report.cliNote = "codex CLI를 찾지 못했습니다"
        }
        return report
    }

    /// 남기는 이유: 고정 · 실행 중 · 24시간 안에 바뀐 rollout · 고정 여부 모름.
    static func classify(_ thread: inout CodexThread, options: AIDataOptions, context: AIDataContext) {
        let rolloutChanged = thread.rolloutPath.flatMap(modificationDate)
        if thread.pinned == true {
            thread.keepReason = "고정된 스레드입니다"
        } else if context.runningSessionIDs.contains(thread.id) || thread.rolloutPath.map({ context.runningTranscripts.contains(SafeFileOps.canonical($0)) }) == true {
            thread.keepReason = "실행 중인 스레드입니다"
        } else if let rolloutChanged, context.now.timeIntervalSince(rolloutChanged) < options.recentGuard {
            thread.keepReason = "최근 24시간 안에 바뀌었습니다"
        } else if thread.pinned == nil {
            thread.keepReason = "고정 여부를 확인할 수 없습니다"
        } else {
            thread.keepReason = nil
        }
    }

    static func updatedDate(_ row: [String: ReadOnlySQLite.Value], _ columns: [String: String]) -> Date? {
        if let ms = columns["updatedMs"].flatMap({ row[$0]?.integer }), ms > 0 { return Date(timeIntervalSince1970: Double(ms) / 1000) }
        guard let raw = columns["updated"].flatMap({ row[$0]?.integer }), raw > 0 else { return nil }
        // 초 또는 밀리초(값의 크기로 가린다)
        return Date(timeIntervalSince1970: raw > 100_000_000_000 ? Double(raw) / 1000 : Double(raw))
    }

    /// 실행 직전 · 보관 확인: 스레드 한 줄의 지금 상태.
    public struct Row: Sendable, Equatable {
        public var archived: Bool?
        public var pinned: Bool?
        public var updatedAt: Date?
    }

    public static func row(database: String, id: String) -> Row? {
        guard let db = ReadOnlySQLite(path: database) else { return nil }
        let columns = schema(db)
        guard let idColumn = columns["id"] else { return nil }
        let wanted = Array(Set(["archived", "pinned", "updatedMs", "updated"].compactMap { columns[$0] })).sorted()
        guard !wanted.isEmpty, let rows = db.rows("SELECT " + wanted.map { "\"\($0)\"" }.joined(separator: ", ") + " FROM threads WHERE lower(\"\(idColumn)\") = lower(?) LIMIT 1", [id]),
              let row = rows.first else { return nil }
        return Row(archived: columns["archived"].flatMap { row[$0]?.integer }.map { $0 != 0 }, pinned: columns["pinned"].flatMap { row[$0]?.integer }.map { $0 != 0 },
                   updatedAt: updatedDate(row, columns))
    }
}

/// 설치된 codex CLI. 표준 입력은 늘 닫는다(codex는 열린 표준 입력을 기다린다 — 10-25 실측).
public struct CodexCLI: Sendable, Equatable {
    public var executable: String
    public var environment: [String: String]?

    public init(executable: String, environment: [String: String]? = nil) {
        self.executable = executable
        self.environment = environment
    }

    /// 앱(launchd)의 PATH에는 nvm·Homebrew가 없어 알려진 자리를 차례로 본다. npm 설치본은 '#!/usr/bin/env node'라 실행 폴더를 PATH 앞에 둔다.
    public static func locate(home: String = NSHomeDirectory()) -> CodexCLI? {
        var candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", home + "/.local/bin/codex"]
        let nvm = home + "/.nvm/versions/node"
        let nodes = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted { lhs, rhs in
            CLIVersionCatalog.versionKey(String(rhs.drop { !$0.isNumber })).lexicographicallyPrecedes(CLIVersionCatalog.versionKey(String(lhs.drop { !$0.isNumber })))
        }
        candidates += nodes.map { nvm + "/" + $0 + "/bin/codex" }
        candidates += [home + "/.volta/bin/codex", home + "/.bun/bin/codex", home + "/.codex/packages/standalone/current/codex", home + "/.codex/packages/standalone/current/bin/codex",
                       "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
        guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (found as NSString).deletingLastPathComponent + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        return CodexCLI(executable: found, environment: environment)
    }

    public func run(_ arguments: [String], timeout: TimeInterval) -> CommandResult {
        Shell.capture(executable, arguments, environment: environment, timeout: timeout)
    }

    /// 도움말의 명령 목록에 archive · unarchive가 모두 있는가.
    public func supportsArchive() -> Bool {
        let help = run(["--help"], timeout: 30)
        guard help.succeeded else { return false }
        let commands = Set(help.stdout.split(separator: "\n").compactMap { $0.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) })
        return commands.contains("archive") && commands.contains("unarchive")
    }
}

public enum CodexThreadArchiver {
    /// 보관: 다시 확인(DB 한 줄 · 실행 중 · 고정 · 오래됨) → 금고에 먼저 적고(`codex unarchive <id>`) → `codex archive <id>` → DB에서 보관 확인.
    /// 금고에 못 적으면 보관하지 않는다(fail-closed). 명령이 실패하고 보관도 안 됐으면 금고 기록을 지운다.
    public static func archive(_ thread: CodexThread, report: CodexThreadReport, options: AIDataOptions, context: AIDataContext, vault: RecoveryVault?,
                               audit: AuditLog = .shared, dryRun: Bool) -> AIDataResult {
        let label = thread.title ?? String(thread.id.prefix(8))
        func skip(_ why: String) -> AIDataResult {
            audit.write(action: "aidata.codex.archive", target: thread.id, result: "skipped: " + why, dryRun: dryRun)
            return AIDataResult(target: label, ok: false, skipped: true, bytes: 0, message: why)
        }
        guard report.canAct, let database = report.database, let cli = report.cli else { return skip(report.actionBlock ?? "보관할 수 없습니다") }
        guard let row = CodexStateReader.row(database: database, id: thread.id) else { return skip("스레드를 DB에서 다시 찾지 못했습니다") }
        guard row.archived == false else { return skip(row.archived == true ? "이미 보관됐습니다" : "보관 여부를 읽지 못했습니다") }
        guard row.pinned == false else { return skip(row.pinned == true ? "고정된 스레드입니다" : "고정 여부를 읽지 못했습니다") }
        guard let updated = row.updatedAt, context.now.timeIntervalSince(updated) >= options.staleDays * 86_400 else { return skip("조사한 뒤 다시 활동했습니다") }
        var fresh = thread
        fresh.pinned = row.pinned
        CodexStateReader.classify(&fresh, options: options, context: context)
        if let reason = fresh.keepReason { return skip(reason) }
        if dryRun {
            audit.write(action: "aidata.codex.archive", target: thread.id, result: "dry-run", dryRun: true, detail: ["title": label])
            return AIDataResult(target: label, ok: true, skipped: false, bytes: 0, message: "드라이런 · 보관 예정")
        }
        var entry = RecoveryEntry(kind: .codexArchive, status: .held, project: thread.project, title: label, reason: "AI 데이터 위생 · 오래된 Codex 스레드", bytes: thread.rolloutBytes)
        entry.agent = AgentKind.codexCLI.rawValue
        entry.resumeID = thread.id
        entry.cwd = thread.cwd
        entry.transcript = thread.rolloutPath
        entry.restoreHint = "codex unarchive \(thread.id)"
        entry.note = "Codex 자체 보관(archive) · 하위 에이전트 \(thread.children)개"
        if let vault {
            do { try vault.add(entry) } catch { return skip("복구 금고에 기록하지 못했습니다(\(error.localizedDescription))") }
        }
        let result = cli.run(["archive", thread.id], timeout: 90)
        let verified = waitFor(database: database, id: thread.id, archived: true)
        audit.write(action: "aidata.codex.archive", target: thread.id, result: verified ? "ok" : "unverified: status \(result.status)", dryRun: false,
                    detail: ["title": label, "stderr": String(result.stderr.prefix(200))])
        if verified {
            try? vault?.update(entry.id) { $0.note = "Codex 자체 보관(archive) 확인 · 하위 에이전트 \(thread.children)개" }
            return AIDataResult(target: label, ok: true, skipped: false, bytes: thread.rolloutBytes, message: "보관함")
        }
        if result.succeeded {
            // 명령은 성공했는데 아직 DB에 안 보이면 금고 기록은 남긴다(되돌리기 = unarchive, 해가 없다).
            try? vault?.update(entry.id) { $0.note = "보관 명령은 성공했지만 DB에서 확인하지 못했습니다" }
            return AIDataResult(target: label, ok: false, skipped: false, bytes: 0, message: "보관 확인 안 됨")
        }
        try? vault?.remove(entry.id)
        return AIDataResult(target: label, ok: false, skipped: false, bytes: 0, message: "codex archive 실패: " + String((result.stderr.isEmpty ? result.stdout : result.stderr).prefix(160)))
    }

    /// 되돌리기: `codex unarchive <id>` 뒤 DB에서 보관이 풀렸는지 확인한다.
    public static func unarchive(id: String, database: String?, cli: CodexCLI?) -> (ok: Bool, message: String) {
        guard let database else { return (false, "Codex 상태 DB를 찾지 못했습니다") }
        if CodexStateReader.row(database: database, id: id)?.archived == false { return (true, "이미 보관이 풀려 있습니다") }
        guard let cli else { return (false, "codex CLI를 찾지 못했습니다 — 터미널에서 codex unarchive \(id)") }
        let result = cli.run(["unarchive", id], timeout: 90)
        guard waitFor(database: database, id: id, archived: false) else {
            return (false, "보관 해제를 확인하지 못했습니다(종료 코드 \(result.status)) " + String((result.stderr.isEmpty ? result.stdout : result.stderr).prefix(160)))
        }
        return (true, "codex unarchive로 되돌렸습니다")
    }

    /// DB에 보관 상태가 반영될 때까지 잠깐(최대 5초) 기다린다.
    static func waitFor(database: String, id: String, archived: Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if CodexStateReader.row(database: database, id: id)?.archived == archived { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
    }
}
