import Darwin
import Foundation
import ReMONCore

// AI 데이터 위생 검사. 실제 휴지통·보관·삭제는 /private/tmp/remon-check/aidata 아래 시험 데이터(가짜 홈)로만 한다.
// 보호 경로는 진짜 경로를 드라이런으로 시도해 거절을 증명한다(검증이 드라이런 분기보다 먼저라 실제 삭제와 같은 길이다).
// 마지막의 실제 ~/.claude · ~/.codex 조사는 읽기 전용(개수·크기만 출력, 실행 없음).

let aiDataRoot = checkRoot + "/aidata"

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func aiSetModified(_ path: String, _ date: Date) {
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

/// Claude 기록 모양: cwd 없는 줄 → (제목) → 사용자(cwd·timestamp) → 응답(timestamp).
private func writeTranscript(_ path: String, cwd: String, id: String, last: Date, title: String? = nil) {
    var lines: [[String: Any]] = [["type": "queue-operation", "operation": "enqueue", "sessionId": id, "timestamp": iso(last.addingTimeInterval(-120))]]
    if let title { lines.append(["type": "ai-title", "aiTitle": title, "sessionId": id]) }
    lines.append(["type": "user", "cwd": cwd, "sessionId": id, "timestamp": iso(last.addingTimeInterval(-60)), "message": ["role": "user", "content": "시험 요청"]])
    lines.append(["type": "assistant", "cwd": cwd, "sessionId": id, "timestamp": iso(last), "message": ["role": "assistant", "content": [["type": "text", "text": "네"]]]])
    writeLines(path, lines)
}

private func ageAll(_ root: String, _ date: Date) {
    // 파일 → 폴더 순(파일을 만들면 폴더 시각이 바뀐다)
    var directories: [String] = [root]
    if let walker = FileManager.default.enumerator(atPath: root) {
        while let relative = walker.nextObject() as? String {
            let path = root + "/" + relative
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            if isDirectory.boolValue { directories.append(path) } else { aiSetModified(path, date) }
        }
    }
    for directory in directories.reversed() { aiSetModified(directory, date) }
}

@discardableResult
private func spawnFrom(_ executable: String) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["--children", "0", "--lifetime", "90"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
        fputs("FAIL 더미 프로세스를 실행하지 못했습니다: \(error.localizedDescription)\n", stderr)
        exit(2)
    }
    Thread.sleep(forTimeInterval: 0.5)
    return process
}

private func copyDummy(to path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.copyItem(atPath: dummyBinary(), toPath: path)
}

private func sql(_ database: String, _ statements: String) {
    let result = Shell.capture("/usr/bin/sqlite3", [database, statements], timeout: 20)
    if !result.succeeded { print("  sqlite3 실패: \(result.stderr.prefix(200))") }
}

private func refused(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch SafeFileOps.Failure.forbidden { return true } catch { return false }
}

func aiDataCheck() {
    let fm = FileManager.default
    chmod(aiDataRoot + "/work/locked", 0o755)   // 지난 실행이 중간에 끊겼으면 잠근 폴더부터 푼다
    try? fm.removeItem(atPath: aiDataRoot)
    try? fm.createDirectory(atPath: aiDataRoot, withIntermediateDirectories: true)
    let home = aiDataRoot + "/home"
    let paths = AIDataPaths(home: home)
    let audit = AuditLog(url: URL(fileURLWithPath: aiDataRoot + "/actions.jsonl"))
    let vault = RecoveryVault(folder: URL(fileURLWithPath: aiDataRoot + "/vault"))
    vault.audit = audit
    let options = AIDataOptions(staleDays: 60)
    let now = Date()
    let day: TimeInterval = 86_400
    var spawned: [Process] = []
    defer { for process in spawned where process.isRunning { process.terminate() } }

    // ── 1) Claude 기록: 그룹 · 제외(실행 중 · 복구함 · 24시간) ──
    let alive = aiDataRoot + "/work/alive", gone = aiDataRoot + "/work/gone"
    try? fm.createDirectory(atPath: alive, withIntermediateDirectories: true)
    let projects = paths.claudeProjects
    let aliveFolder = projects + "/-fx-alive", goneFolder = projects + "/-fx-gone", volumeFolder = projects + "/-fx-vol"
    func uuid() -> String { UUID().uuidString.lowercased() }
    let (a, b, c, d, e, f, g, h, i, j) = (uuid(), uuid(), uuid(), uuid(), uuid(), uuid(), uuid(), uuid(), uuid(), uuid())
    let k = uuid()
    let locked = aiDataRoot + "/work/locked"
    try? fm.createDirectory(atPath: locked + "/inner", withIntermediateDirectories: true)
    writeTranscript(aliveFolder + "/\(k).jsonl", cwd: locked + "/inner", id: k, last: now - 90 * day)
    writeTranscript(aliveFolder + "/\(a).jsonl", cwd: alive, id: a, last: now - 90 * day, title: "Alpha task")
    writeLines(aliveFolder + "/\(a)/subagents/agent-1.jsonl", [["type": "user", "cwd": alive, "timestamp": iso(now - 90 * day)]])
    try? fm.createDirectory(atPath: aliveFolder + "/\(a)/tool-results", withIntermediateDirectories: true)
    fm.createFile(atPath: aliveFolder + "/\(a)/tool-results/r.txt", contents: Data(repeating: 7, count: 64 * 1024))
    writeTranscript(goneFolder + "/\(b).jsonl", cwd: gone, id: b, last: now - 10 * day)
    writeTranscript(goneFolder + "/\(c).jsonl", cwd: gone, id: c, last: now - 10 * day)
    writeTranscript(aliveFolder + "/\(d).jsonl", cwd: alive, id: d, last: now - 90 * day)
    writeTranscript(aliveFolder + "/\(e).jsonl", cwd: alive, id: e, last: now - 90 * day)
    writeTranscript(aliveFolder + "/\(f).jsonl", cwd: alive, id: f, last: now - 5 * day)
    writeTranscript(aliveFolder + "/\(g).jsonl", cwd: gone, id: g, last: now - 80 * day, title: "Gzip task")
    _ = Shell.capture("/usr/bin/gzip", ["-n", "-f", aliveFolder + "/\(g).jsonl"], timeout: 20)
    writeTranscript(volumeFolder + "/\(h).jsonl", cwd: "/Volumes/remon-check-missing-volume/proj", id: h, last: now - 10 * day)
    writeLines(goneFolder + "/\(i)/subagents/agent-2.jsonl", [["type": "user", "cwd": gone, "timestamp": iso(now - 20 * day)]])
    writeTranscript(aliveFolder + "/\(j).jsonl", cwd: alive, id: j, last: now - 90 * day)
    try? fm.createDirectory(atPath: aliveFolder + "/memory", withIntermediateDirectories: true)
    fm.createFile(atPath: aliveFolder + "/memory/MEMORY.md", contents: Data("메모리".utf8))
    ageAll(projects, now - 90 * day)
    for (id, folder, age) in [(b, goneFolder, 10.0), (h, volumeFolder, 10.0), (f, aliveFolder, 5.0)] { aiSetModified(folder + "/\(id).jsonl", now - age * day) }
    aiSetModified(goneFolder + "/\(c).jsonl", now)   // 방금 바뀜(24시간 제외)
    ageAll(goneFolder + "/\(i)", now - 20 * day)
    aiSetModified(aliveFolder + "/\(g).jsonl.gz", now - 80 * day)

    var running = AgentSession(id: ProcessKey(pid: 999_991, start: 1), kind: .claudeCode, rootPID: 999_991, pids: [999_991], cwd: alive)
    running.logPath = aliveFolder + "/\(d).jsonl"
    var resumedElsewhere = AgentSession(id: ProcessKey(pid: 999_992, start: 1), kind: .claudeCode, rootPID: 999_992, pids: [999_992], cwd: alive)
    resumedElsewhere.logPath = aiDataRoot + "/elsewhere/\(j).jsonl"   // 같은 대화를 다른 폴더에서 이어 쓰는 세션(id로 제외)
    var held = RecoveryEntry(kind: .session, status: .held, project: "시험", title: "보관 세션", reason: "시험")
    held.transcript = aliveFolder + "/\(e).jsonl"
    held.resumeID = e
    let context = AIDataContext.live(sessions: [running, resumedElsewhere], processes: [], vaultEntries: [held], registry: [:], now: now)
    chmod(locked, 0o000)   // 권한이 없어 확인할 수 없는 작업 폴더(보호 폴더 EPERM과 같은 경우)
    let claude = ClaudeTranscriptScanner.scan(paths: paths, options: options, context: context)
    chmod(locked, 0o755)
    func item(_ id: String) -> ClaudeTranscript? { claude.items.first { $0.sessionID == id } }
    check(item(k)?.group == .stale && item(k)?.note?.contains("확인하지 못했습니다") == true,
          "권한 없는 작업 폴더는 '소실'로 보지 않음(ENOENT만 소실) · \(item(k)?.note ?? "-")")
    check(item(b)?.group == .projectGone && item(b)?.selectable == true, "Claude 그룹: 작업 폴더가 사라진 기록 → '프로젝트 폴더 소실'(고를 수 있음)")
    check(item(a)?.group == .stale && item(a)?.selectable == true && item(a)?.title == "Alpha task" && item(a)?.subagents == 1
          && (item(a)?.bytes ?? 0) > DiskScanner.allocatedSize(aliveFolder + "/\(a).jsonl") + 60 * 1024
          && abs((item(a)?.lastActivity ?? .distantPast).timeIntervalSince(now - 90 * day)) < 1,
          "Claude 그룹: 90일 쉰 기록 → '오래됨 60일+' · 제목(ai-title) · 마지막 timestamp · 하위 폴더 크기·하위 기록 수 포함")
    check(item(g)?.compressed == true && item(g)?.cwd == gone && item(g)?.group == .projectGone && item(g)?.title == "Gzip task", "압축 기록(.jsonl.gz): 앞부분만 풀어 cwd·제목을 읽음")
    check(item(i)?.isOrphanFolder == true && item(i)?.group == .projectGone && item(i)?.selectable == true, "기록 없이 남은 하위 폴더: 하위 기록의 cwd로 판정")
    check(item(c)?.group == .projectGone && item(c)?.keepReason?.contains("24시간") == true, "제외: 24시간 안에 바뀐 기록은 남김(\(item(c)?.keepReason ?? "-"))")
    check(item(d)?.keepReason?.contains("실행 중") == true, "제외: 실행 중 세션의 기록(logPath) → 남김")
    check(item(j)?.keepReason?.contains("실행 중") == true, "제외: 다른 폴더에서 같은 대화를 쓰는 세션(id 일치) → 남김")
    check(item(e)?.keepReason?.contains("복구함") == true, "제외: 복구함이 보관 중인 세션의 기록 → 남김")
    check(item(f) == nil && item(h) == nil, "그룹 밖: 5일 된 기록 · 외장 볼륨이 빠진 작업 폴더(소실로 보지 않음)")
    check(claude.scanned == 11, "조사한 기록 \(claude.scanned)개(하위 폴더만 남은 것 포함)")
    guard let itemA = item(a), let itemB = item(b), let itemC = item(c), let itemD = item(d), let itemG = item(g) else {
        check(false, "Claude 시험 기록을 찾지 못해 실행 검사를 건너뜀"); return
    }

    // ── 2) 휴지통 → 금고 → 되돌리기 ──
    let originals = [itemA, itemB].map { (try? Data(contentsOf: URL(fileURLWithPath: $0.path))) ?? Data() }
    let dry = AIDataCleaner.trashTranscripts([itemA, itemB], paths: paths, options: options, context: context, vault: vault, audit: audit, dryRun: true)
    check(dry.allSatisfy(\.ok) && fm.fileExists(atPath: itemA.path) && vault.all().isEmpty, "휴지통 드라이런: 그대로 · 금고 기록 없음")
    var outside = itemB
    outside.path = alive + "/\(b).jsonl"
    fm.createFile(atPath: outside.path, contents: Data("x".utf8))
    let refusedShape = AIDataCleaner.trashTranscripts([outside], paths: paths, options: options, context: context, vault: vault, audit: audit, dryRun: false)
    check(refusedShape.first?.skipped == true && fm.fileExists(atPath: outside.path), "모양 확인: 기록 폴더 밖 파일은 옮기지 않음(\(refusedShape.first?.message ?? "-"))")
    aiSetModified(itemG.path, now)   // 조사 뒤 바뀜
    let results = AIDataCleaner.trashTranscripts([itemA, itemB, itemC, itemD, itemG], paths: paths, options: options, context: context, vault: vault, audit: audit, dryRun: false)
    let trashEntries = vault.all().filter { $0.kind == .trash && $0.status == .held }
    check(results[0].ok && results[1].ok && !fm.fileExists(atPath: itemA.path) && !fm.fileExists(atPath: aliveFolder + "/\(a)") && !fm.fileExists(atPath: itemB.path),
          "휴지통: 기록 + 하위 폴더를 옮김(\(results.filter(\.ok).count)개)")
    check(results[2].skipped && results[3].skipped && results[4].skipped && fm.fileExists(atPath: itemC.path) && fm.fileExists(atPath: itemG.path),
          "실행 직전 재확인: 24시간 · 실행 중 · 조사 뒤 바뀐 기록은 건너뜀(\(results[4].message))")
    check(trashEntries.count == 3 && trashEntries.allSatisfy { $0.trashedPath.map(fm.fileExists) == true && $0.restorable },
          "금고: 기록 2 + 하위 폴더 1의 휴지통 위치를 적음(\(trashEntries.count)건)")
    for entry in trashEntries { _ = RecoveryRestorer.restoreTrash(entry, vault: vault) }
    let restored = [itemA, itemB].map { (try? Data(contentsOf: URL(fileURLWithPath: $0.path))) ?? Data() }
    check(restored == originals && !originals[0].isEmpty && fm.fileExists(atPath: aliveFolder + "/\(a)/subagents/agent-1.jsonl")
          && vault.all().filter { $0.kind == .trash }.allSatisfy { $0.status == .restored }, "되돌리기: 기록 · 하위 폴더가 원래 자리로(내용 동일)")
    check(fm.fileExists(atPath: aliveFolder + "/memory/MEMORY.md"), "프로젝트 메모리 폴더는 그대로")
    for entry in vault.all() where entry.kind == .trash { if let trashed = entry.trashedPath, fm.fileExists(atPath: trashed) { try? fm.removeItem(atPath: trashed) } }

    // ── 3) 보호 경로: 규칙(가짜 홈) + 진짜 경로 드라이런 거절 ──
    let fake = aiDataRoot + "/fakehome"
    let support = fake + "/Library/Application Support"
    try? fm.createDirectory(atPath: support + "/Claude/Partitions/p1", withIntermediateDirectories: true)
    fm.createFile(atPath: support + "/Claude/Partitions/p1/Cookies", contents: Data())
    let transcriptName = UUID().uuidString.lowercased() + ".jsonl"
    let blockedCases: [(String, Bool)] = [
        (fake + "/.claude/file-history/x", true), (fake + "/.claude/paste-cache", true), (fake + "/.claude/sessions/1.json", false), (fake + "/.claude/projects", false),
        (fake + "/.claude/projects/-p/memory/MEMORY.md", false), (fake + "/.claude/projects/-p/" + transcriptName, true), (fake + "/.claude/projects/-p", true),
        (fake + "/.codex/attachments/a.png", true), (fake + "/.codex/computer-use", true), (fake + "/.codex/auth.json", false), (fake + "/.codex/state_5.sqlite", true),
        (fake + "/.codex/state_5.sqlite-wal", true), (fake + "/.codex/thread_history_1.sqlite", true), (support + "/Claude", true), (support + "/Claude/Local Storage", true),
        (support + "/Claude/Cookies-journal", true), (support + "/Cursor/Partitions/x/IndexedDB", true), (support + "/Antigravity/Default/Login Data", true),
        (support + "/Codex/History", true), (support + "/com.openai.chat/Local State", true), (support + "/Claude/Partitions", true), (support + "/Claude/Partitions/p1", true),
        (fake + "/.Claude/File-History/x", true), (fake + "/.codex/AUTH.json", false), (support + "/claude/local storage", true), (fake + "/.claude/Projects/-p/Memory", false)
    ]
    let blockedMisses = blockedCases.filter { AIDataProtection.reason(for: $0.0, home: fake, removal: $0.1) == nil }.map(\.0)
    check(blockedMisses.isEmpty, "보호 규칙(가짜 홈): \(blockedCases.count)개 경로 모두 막음" + (blockedMisses.isEmpty ? "" : " · 놓침: \(blockedMisses)"))
    let allowedCases: [(String, Bool, Bool)] = [
        (fake + "/.claude/projects/-p/" + transcriptName, true, true), (fake + "/.claude/projects/-p/" + transcriptName.dropLast(6), true, true),
        (fake + "/.claude/projects/-p/" + transcriptName, false, false), (fake + "/.claude/projects/-p", false, false),
        (support + "/Claude/Code Cache", true, false), (support + "/Claude/Default/Cache", true, false), (fake + "/.codex/sessions/2026/09", false, false)
    ]
    let allowedMisses = allowedCases.filter { AIDataProtection.reason(for: $0.0, home: fake, removal: $0.1, allowClaudeTranscript: $0.2) != nil }.map(\.0)
    let deeper = AIDataProtection.reason(for: fake + "/.claude/projects/-p/\(transcriptName.dropLast(6))/subagents/a.jsonl", home: fake, removal: true, allowClaudeTranscript: true)
    check(allowedMisses.isEmpty && deeper != nil, "허용 규칙: 위생 기능의 기록·하위 폴더 휴지통 · 외장 이전 · 캐시만 통과, 하위 폴더 안쪽은 막음" + (allowedMisses.isEmpty ? "" : " · 막힘: \(allowedMisses)"))

    let realHome = FileManager.default.homeDirectoryForCurrentUser.path
    var realTargets = [".claude/file-history", ".claude/paste-cache", ".claude/sessions", ".claude/projects", ".codex/attachments", ".codex/computer-use", ".codex/auth.json",
                       "Library/Application Support/Claude/Local Storage", "Library/Application Support/Claude/Cookies", "Library/Application Support/Claude/IndexedDB",
                       "Library/Application Support/Cursor/Local Storage", "Library/Application Support/Codex/Default", "Library/Application Support/Claude"].map { realHome + "/" + $0 }
    if let database = CodexStateReader.locateDatabase() { realTargets.append(database) }
    let realProjects = realHome + "/.claude/projects"
    let projectFolders = ((try? fm.contentsOfDirectory(atPath: realProjects)) ?? []).sorted()
    if let memory = projectFolders.map({ realProjects + "/" + $0 + "/memory" }).first(where: { fm.fileExists(atPath: $0) }) { realTargets.append(memory) }
    realTargets = realTargets.filter { fm.fileExists(atPath: $0) }
    var realMisses: [String] = []
    for target in realTargets {
        let all = refused { _ = try SafeFileOps.validate(target, removal: true) }
            && refused { _ = try SafeFileOps.moveToTrash(target, userPIDs: [], dryRun: true, bytes: 0, audit: audit) }
            && refused { try SafeFileOps.deletePermanently(target, userPIDs: [], dryRun: true, bytes: 0, audit: audit) }
        if !all || !fm.fileExists(atPath: target) { realMisses.append(target.replacingOccurrences(of: realHome, with: "~")) }
    }
    check(!realTargets.isEmpty && realMisses.isEmpty, "진짜 보호 경로 \(realTargets.count)곳: 검증·휴지통·영구 삭제 모두 거절(드라이런 — 검증이 먼저라 실제 삭제와 같은 길)" + (realMisses.isEmpty ? "" : " · 통과됨: \(realMisses)"))
    let realTranscript = projectFolders.lazy.compactMap { folder -> String? in
        let directory = realProjects + "/" + folder
        return ((try? fm.contentsOfDirectory(atPath: directory)) ?? []).first { ClaudeTranscriptName.sessionID($0) != nil }.map { directory + "/" + $0 }
    }.first
    if let realTranscript {
        let withoutFeature = refused { _ = try SafeFileOps.moveToTrash(realTranscript, userPIDs: [], dryRun: true, bytes: 0, audit: audit) }
        let permanent = refused { try SafeFileOps.deletePermanently(realTranscript, userPIDs: [], dryRun: true, bytes: 0, audit: audit) }
        let featureOK = (try? SafeFileOps.validate(realTranscript, removal: true, allowClaudeTranscript: true)) != nil
        let migrateOK = (try? SafeFileOps.validate(realTranscript)) != nil
        check(withoutFeature && permanent && featureOK && migrateOK && fm.fileExists(atPath: realTranscript),
              "진짜 Claude 기록 1개: 일반 휴지통·영구 삭제는 거절, 위생 기능의 휴지통·외장 이전 검증만 통과(실행하지 않음)")
    } else {
        check(false, "진짜 Claude 기록을 찾지 못해 허용 규칙을 확인하지 못함")
    }

    // ── 4) Codex 스레드: 시험 DB(sqlite3) + 가짜 codex ──
    let codexHome = paths.codexHome
    try? fm.createDirectory(atPath: codexHome + "/sessions/2026/07", withIntermediateDirectories: true)
    let database = codexHome + "/state_5.sqlite"
    let ids = (1...7).map { _ in UUID().uuidString.lowercased() }
    let rollout1 = codexHome + "/sessions/2026/07/rollout-2026-07-01T00-00-00-\(ids[0]).jsonl", rollout7 = codexHome + "/sessions/2026/07/rollout-2026-07-02T00-00-00-\(ids[6]).jsonl"
    fm.createFile(atPath: rollout1, contents: Data(repeating: 1, count: 32 * 1024))
    fm.createFile(atPath: rollout7, contents: Data(repeating: 1, count: 1024))
    aiSetModified(rollout1, now - 90 * day)
    let old = Int(now.timeIntervalSince1970 - 90 * day), recent = Int(now.timeIntervalSince1970 - 3 * day)
    func row(_ index: Int, updated: Int, archived: Int = 0, pinned: Int = 0, source: String = "cli", rollout: String = "") -> String {
        "('\(ids[index])', '\(rollout)', \(updated), \(updated), \(updated * 1000), '\(alive)', '스레드 \(index + 1)', NULL, \(archived), \(pinned), '\(source)', 'user', '')"
    }
    sql(database, """
        CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, updated_at_ms INTEGER, cwd TEXT NOT NULL,
          title TEXT NOT NULL, name TEXT, archived INTEGER NOT NULL DEFAULT 0, is_pinned INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL, thread_source TEXT, first_user_message TEXT NOT NULL);
        CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL, child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL);
        INSERT INTO threads (id, rollout_path, created_at, updated_at, updated_at_ms, cwd, title, name, archived, is_pinned, source, thread_source, first_user_message) VALUES
          \(row(0, updated: old, rollout: rollout1)), \(row(1, updated: old, pinned: 1)), \(row(2, updated: old)), \(row(3, updated: recent)),
          \(row(4, updated: old, archived: 1)), \(row(5, updated: old, source: "{\"subagent\":{\"thread_spawn\":{}}}")), \(row(6, updated: old, rollout: rollout7));
        INSERT INTO thread_spawn_edges VALUES ('\(ids[0])', '\(ids[5])', 'open');
        """)
    let fakeLog = aiDataRoot + "/fake-codex.log"
    let fakeCodex = aiDataRoot + "/bin/codex"
    try? fm.createDirectory(atPath: aiDataRoot + "/bin", withIntermediateDirectories: true)
    let script = """
        #!/bin/sh
        # 가짜 codex: 시험 DB만 고친다. cat은 표준 입력이 닫혀 있어야 바로 끝난다(열려 있으면 시간 초과로 실패).
        echo "$@" >> "$REMON_FAKE_CODEX_LOG"
        case "$1" in
          --help) printf 'Commands:\\n  exec       Run\\n  archive    Archive a saved session\\n  unarchive  Unarchive a saved session\\n'; exit 0 ;;
          archive) cat > /dev/null; /usr/bin/sqlite3 "$REMON_FAKE_CODEX_DB" "UPDATE threads SET archived=1 WHERE id='$2';"; exit 0 ;;
          unarchive) cat > /dev/null; /usr/bin/sqlite3 "$REMON_FAKE_CODEX_DB" "UPDATE threads SET archived=0 WHERE id='$2';"; exit 0 ;;
        esac
        exit 2
        """
    try? script.write(toFile: fakeCodex, atomically: true, encoding: .utf8)
    chmod(fakeCodex, 0o755)
    let cli = CodexCLI(executable: fakeCodex, environment: ["REMON_FAKE_CODEX_DB": database, "REMON_FAKE_CODEX_LOG": fakeLog, "PATH": "/usr/bin:/bin"])
    var codexSession = AgentSession(id: ProcessKey(pid: 999_993, start: 1), kind: .codexCLI, rootPID: 999_993, pids: [999_993], cwd: alive)
    codexSession.logPath = aiDataRoot + "/elsewhere/rollout-2026-07-03T00-00-00-\(ids[2]).jsonl"
    let codexContext = AIDataContext.live(sessions: [codexSession], processes: [], vaultEntries: [], registry: [:], now: now)
    let codex = CodexStateReader.report(paths: paths, options: options, context: codexContext, cli: cli)
    func thread(_ index: Int) -> CodexThread? { codex.threads.first { $0.id == ids[index] } }
    check(codex.canAct && codex.totalThreads == 7 && codex.archivedThreads == 1 && codex.schemaNote.contains("열 확인됨"),
          "Codex DB(읽기 전용): 열 확인(pragma_table_info) · 전체 \(codex.totalThreads) · 보관 \(codex.archivedThreads) · \(codex.schemaNote) · \(codex.cliNote ?? "-")")
    check(thread(0)?.selectable == true && thread(0)?.children == 1 && thread(0)?.rolloutBytes ?? 0 > 0 && thread(0)?.title == "스레드 1",
          "Codex 고르기: 90일 쉰 최상위 · 미고정 · 미보관 스레드(하위 에이전트 1개 · rollout 크기)")
    check(thread(1)?.keepReason?.contains("고정") == true && thread(2)?.keepReason?.contains("실행 중") == true && thread(6)?.keepReason?.contains("24시간") == true,
          "Codex 제외: 고정 · 실행 중(rollout 스레드 id) · 24시간 안에 바뀐 rollout")
    check(thread(3) == nil && thread(4) == nil && thread(5) == nil, "Codex 목록 밖: 최근 3일 · 이미 보관 · 하위 에이전트 스레드")
    guard let thread0 = thread(0), let thread1 = thread(1) else { check(false, "Codex 시험 스레드를 찾지 못해 보관 검사를 건너뜀"); return }
    let dryArchive = AIDataCleaner.archiveThreads([thread0], report: codex, options: options, context: codexContext, vault: vault, audit: audit, dryRun: true)
    check(dryArchive.first?.ok == true && CodexStateReader.row(database: database, id: ids[0])?.archived == false && !vault.all().contains { $0.kind == .codexArchive }
          && !((try? String(contentsOfFile: fakeLog, encoding: .utf8)) ?? "").contains("archive "), "Codex 보관 드라이런: DB 그대로 · 금고 기록 없음 · codex 호출 없음")
    let archiveStarted = Date()
    let archived = AIDataCleaner.archiveThreads([thread0, thread1], report: codex, options: options, context: codexContext, vault: vault, audit: audit, dryRun: false)
    let archiveElapsed = Date().timeIntervalSince(archiveStarted)
    let codexEntry = vault.all().first { $0.kind == .codexArchive && $0.resumeID == ids[0] }
    check(archived[0].ok && archived[1].skipped && CodexStateReader.row(database: database, id: ids[0])?.archived == true && CodexStateReader.row(database: database, id: ids[1])?.archived == false,
          String(format: "codex archive <id>: 보관 확인(DB) · 고정 스레드는 건너뜀 · %.1f초(표준 입력 닫힘 — 열려 있으면 시간 초과)", archiveElapsed))
    check(codexEntry?.status == .held && codexEntry?.restorable == true && codexEntry?.restoreHint == "codex unarchive \(ids[0])", "금고: codexArchive 항목 · 되돌리기 명령 codex unarchive <id>")
    if let codexEntry {
        let back = RecoveryRestorer.restoreCodexArchive(codexEntry, vault: vault, cli: cli, database: database)
        check(back.ok && CodexStateReader.row(database: database, id: ids[0])?.archived == false && vault.entry(codexEntry.id)?.status == .restored,
              "되돌리기: codex unarchive 뒤 DB에서 보관 해제 확인 · 금고 '되돌림'(\(back.message))")
    }
    let calls = ((try? String(contentsOfFile: fakeLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    check(calls.contains("archive \(ids[0])") && calls.contains("unarchive \(ids[0])") && !calls.contains { $0.contains(ids[1]) }, "codex 호출 기록: archive·unarchive만, 고정 스레드는 부르지 않음")

    // 스키마를 모르면 보여 주기만 · CLI가 모르면 끔 · DB 없음
    let home2 = aiDataRoot + "/home2", paths2 = AIDataPaths(home: home2)
    try? fm.createDirectory(atPath: paths2.codexHome, withIntermediateDirectories: true)
    let database2 = paths2.codexHome + "/state_9.sqlite"
    sql(database2, "CREATE TABLE threads (id TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, title TEXT); INSERT INTO threads VALUES ('\(ids[0])', \(old), '옛 스레드');")
    let unknown = CodexStateReader.report(paths: paths2, options: options, context: codexContext, cli: cli)
    let unknownRun = AIDataCleaner.archiveThreads(unknown.threads, report: unknown, options: options, context: codexContext, vault: vault, audit: audit, dryRun: false)
    check(!unknown.canAct && unknown.schemaNote.contains("필요한 열이 없습니다") && unknown.threads.count == 1 && unknown.threads[0].keepReason != nil
          && unknownRun.allSatisfy(\.skipped), "스키마 모름: 목록만 보이고 버튼 끔(\(unknown.schemaNote))")
    let fakeOld = aiDataRoot + "/bin/codex-old"
    try? "#!/bin/sh\nprintf 'Commands:\\n  exec  Run\\n'\n".write(toFile: fakeOld, atomically: true, encoding: .utf8)
    chmod(fakeOld, 0o755)
    let oldCLI = CodexStateReader.report(paths: paths, options: options, context: codexContext, cli: CodexCLI(executable: fakeOld))
    let noDB = CodexStateReader.report(paths: AIDataPaths(home: aiDataRoot + "/home3"), options: options, context: codexContext, cli: cli)
    check(!oldCLI.canAct && oldCLI.cliNote?.contains("모릅니다") == true && !noDB.canAct && noDB.database == nil, "archive를 모르는 codex · DB 없음 → 버튼 끔")

    // ── 5) 이전 CLI 버전: 실행 중(경로 · 하드링크 inode) 제외 ──
    let versions = paths.claudeVersions
    for version in ["1.0.0", "1.0.1", "1.0.2", "1.0.3", "1.0.4", "1.0.5"] { copyDummy(to: versions + "/" + version) }
    try? fm.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: paths.claudeLauncher, withDestinationPath: versions + "/1.0.4")
    let appBinary = home + "/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"
    try? fm.createDirectory(atPath: (appBinary as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    link(versions + "/1.0.1", appBinary)
    link(versions + "/1.0.0", aiDataRoot + "/hardlink-1.0.0")
    let releases = codexHome + "/packages/app-server-daemon/releases"
    for release in ["0.1.0-x", "0.2.0-x", "0.3.0-x", "0.4.0-x"] { copyDummy(to: releases + "/" + release + "/bin/codex") }
    try? fm.createSymbolicLink(atPath: codexHome + "/packages/app-server-daemon/current", withDestinationPath: releases + "/0.3.0-x")
    ageAll(versions, now - 3 * day)
    ageAll(releases, now - 3 * day)
    let byPath = spawnFrom(versions + "/1.0.2"), byLink = spawnFrom(appBinary), byRelease = spawnFrom(releases + "/0.1.0-x/bin/codex")
    spawned += [byPath, byLink, byRelease]
    func liveContext() -> AIDataContext { AIDataContext.live(sessions: [], processes: ProcessSampler().sample(), vaultEntries: [], registry: [:]) }
    let catalog = CLIVersionCatalog.scan(paths: paths, options: options, context: liveContext())
    func version(_ name: String) -> CLIVersion? { catalog.first { $0.version == name } }
    check(version("1.0.2")?.inUse.contains(byPath.processIdentifier) == true && version("1.0.1")?.inUse.contains(byLink.processIdentifier) == true
          && version("0.1.0-x")?.inUse.contains(byRelease.processIdentifier) == true,
          "실행 중 버전 제외: 경로로(1.0.2) · 하드링크 inode로(ClaudeCode.app → 1.0.1) · 릴리스 폴더 아래 실행 파일로(0.1.0)")
    check(version("1.0.4")?.isCurrent == true && version("0.3.0-x")?.isCurrent == true && version("1.0.5")?.keepReason?.contains("새 버전") == true
          && version("0.4.0-x")?.keepReason?.contains("새 버전") == true && version("1.0.0")?.keepReason?.contains("하드링크") == true,
          "현재(링크 대상) · 현재보다 새 버전 · 하드링크는 남김")
    check(version("1.0.3")?.selectable == true && version("0.2.0-x")?.selectable == true && catalog.filter(\.selectable).count == 2, "고를 수 있음: 1.0.3 · 0.2.0만")
    let lateUser = spawnFrom(releases + "/0.2.0-x/bin/codex")   // 조사 뒤에 쓰기 시작
    spawned.append(lateUser)
    let first = AIDataCleaner.deleteVersions(catalog, paths: paths, options: options, context: liveContext(), vault: vault, audit: audit, dryRun: false)
    let skippedLate = first.first { $0.target.hasSuffix("0.2.0-x") }
    check(!fm.fileExists(atPath: versions + "/1.0.3") && fm.fileExists(atPath: releases + "/0.2.0-x") && skippedLate?.skipped == true
          && ["1.0.0", "1.0.1", "1.0.2", "1.0.4", "1.0.5"].allSatisfy { fm.fileExists(atPath: versions + "/" + $0) },
          "삭제 직전 재확인: 1.0.3만 지움 · 조사 뒤 실행된 0.2.0은 건너뜀(\(skippedLate?.message ?? "-"))")
    lateUser.terminate(); lateUser.waitUntilExit()
    Thread.sleep(forTimeInterval: 0.3)
    let second = AIDataCleaner.deleteVersions(catalog.filter { $0.version == "0.2.0-x" }, paths: paths, options: options, context: liveContext(), vault: vault, audit: audit, dryRun: false)
    let deletedEntries = vault.all().filter { $0.kind == .deleted && $0.reason.contains("이전 CLI") }
    check(second.first?.ok == true && !fm.fileExists(atPath: releases + "/0.2.0-x") && deletedEntries.count == 2 && deletedEntries.allSatisfy { $0.restoreHint?.contains("현재 버전") == true },
          "프로세스가 끝난 뒤 0.2.0 삭제 · 금고에 '영구 삭제 · 재생성 안내' 2건")
    check(byPath.isRunning && byLink.isRunning && byRelease.isRunning, "실행 중이던 더미 3개는 그대로 살아 있음")

    // ── 6) AI 앱 캐시: 앱이 실행 중이면 건너뜀 ──
    let appSupport = paths.appSupport
    for file in ["Claude/Code Cache/js/a", "Claude/GPUCache/data_0", "Claude/Local Storage/leveldb/x.ldb", "Cursor/Cache/Cache_Data/f", "Codex/Default/Code Cache/js/b"] {
        try? fm.createDirectory(atPath: (appSupport + "/" + file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        fm.createFile(atPath: appSupport + "/" + file, contents: Data(repeating: 3, count: 16 * 1024))
    }
    fm.createFile(atPath: appSupport + "/Claude/Cookies", contents: Data(repeating: 1, count: 4096))
    fm.createFile(atPath: appSupport + "/Codex/Default/Cookies", contents: Data(repeating: 1, count: 4096))
    try? fm.createDirectory(atPath: paths.caches + "/claude-cli-nodejs", withIntermediateDirectories: true)
    fm.createFile(atPath: paths.caches + "/claude-cli-nodejs/log.txt", contents: Data(repeating: 2, count: 16 * 1024))
    let cursorMain = aiDataRoot + "/apps/Cursor.app/Contents/MacOS/Cursor", nativeHost = aiDataRoot + "/apps/Claude.app/Contents/Helpers/chrome-native-host"
    let crashpad = aiDataRoot + "/apps/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Helpers/browser_crashpad_handler"
    copyDummy(to: cursorMain); copyDummy(to: nativeHost); copyDummy(to: crashpad); copyDummy(to: aiDataRoot + "/bin2/claude")
    let cursorProcess = spawnFrom(cursorMain), hostProcess = spawnFrom(nativeHost), crashpadProcess = spawnFrom(crashpad), cliProcess = spawnFrom(aiDataRoot + "/bin2/claude")
    spawned += [cursorProcess, hostProcess, crashpadProcess, cliProcess]
    // 실제 Claude·Codex 앱이 켜져 있어도 결과가 같도록 판정 기준에는 시험 더미 프로세스만 넣는다(수집 경로는 실제와 같다).
    func fixtureContext() -> AIDataContext {
        let pids = Set([cursorProcess, hostProcess, crashpadProcess, cliProcess].map(\.processIdentifier))
        return AIDataContext.live(sessions: [], processes: ProcessSampler().sample().filter { pids.contains($0.pid) }, vaultEntries: [], registry: [:])
    }
    let caches = AIAppCacheCatalog.scan(paths: paths, context: fixtureContext())
    func cache(_ suffix: String) -> AIAppCache? { caches.first { $0.path.hasSuffix(suffix) } }
    check(cache("/Claude/Code Cache")?.selectable == true && cache("/Claude/GPUCache")?.selectable == true
          && cache("/Codex/Default/Code Cache")?.folder == "Default/Code Cache" && cache("/Codex/Default/Code Cache")?.selectable == true,
          "앱 캐시: 꺼진 앱의 Chromium 캐시(프로필 Default 안 포함) — 확장 도우미(Contents/Helpers)·남은 crashpad 처리기는 실행으로 보지 않음")
    check(cache("/Cursor/Cache")?.keepReason?.contains("실행 중") == true && cache("/claude-cli-nodejs")?.keepReason?.contains("실행 중") == true,
          "앱 캐시 건너뜀: Cursor.app 실행 중(Contents/MacOS) · Claude CLI 실행 중(claude-cli-nodejs)")
    check(!caches.contains { $0.path.contains("Local Storage") || $0.path.hasSuffix("Cookies") }, "로그인·저장 데이터(Local Storage · Cookies)는 목록에 없음")
    guard var disguised = cache("/Claude/Code Cache") else { check(false, "Claude 시험 캐시를 찾지 못해 삭제 검사를 건너뜀"); return }
    disguised.path = appSupport + "/Claude/Local Storage"
    let cleared = AIDataCleaner.clearCaches(caches + [disguised], paths: paths, context: fixtureContext(), vault: vault, audit: audit, dryRun: false)
    check(!fm.fileExists(atPath: appSupport + "/Claude/Code Cache") && !fm.fileExists(atPath: appSupport + "/Claude/GPUCache") && !fm.fileExists(atPath: appSupport + "/Codex/Default/Code Cache")
          && fm.fileExists(atPath: appSupport + "/Cursor/Cache/Cache_Data/f") && fm.fileExists(atPath: paths.caches + "/claude-cli-nodejs/log.txt")
          && fm.fileExists(atPath: appSupport + "/Claude/Local Storage/leveldb/x.ldb") && fm.fileExists(atPath: appSupport + "/Claude/Cookies") && fm.fileExists(atPath: appSupport + "/Codex/Default/Cookies")
          && cleared.last?.skipped == true,
          "캐시 비우기: 꺼진 앱 캐시 3곳만 영구 삭제 · 실행 중 앱 캐시·로그인 데이터 그대로 · 캐시로 위장한 Local Storage는 거절(\(cleared.last?.message ?? "-"))")
    let cacheEntries = vault.all().filter { $0.kind == .deleted && $0.reason.contains("앱 캐시") }
    check(cacheEntries.count == 3 && cacheEntries.allSatisfy { $0.restoreHint?.contains("다시 열면") == true && !$0.restorable }, "금고: 캐시 삭제 3건 · 재생성 안내 · 되돌리기 버튼 없음")

    // ── 7) 한 번에 조사(시험 홈) ──
    let report = AIDataScanner.scan(paths: paths, options: options, context: liveContext(), codexCLI: cli)
    check(report.codex.canAct && report.transcripts.count == claude.items.count && !report.versions.isEmpty, String(format: "한 번에 조사(시험 홈) %.2f초", report.elapsed))
    for process in spawned where process.isRunning { process.terminate() }

    // ── 8) 실제 Mac 읽기 전용 조사(개수·크기만, 실행 없음) ──
    aiDataSmoke()
}

/// 실제 ~/.claude · ~/.codex · 앱 캐시 · 버전 폴더를 읽기만 한다. 대화 내용·제목은 출력하지 않는다.
func aiDataSmoke() {
    let sampler = ProcessSampler()
    let detector = SessionDetector()
    _ = detector.detect(records: sampler.sample(), sampler: sampler, orca: [])
    Thread.sleep(forTimeInterval: 0.5)
    let records = sampler.sample()
    let sessions = detector.detect(records: records, sampler: sampler, orca: OrcaBridge.list() ?? []).sessions
    let context = AIDataContext.live(sessions: sessions, processes: records, vaultEntries: RecoveryVault.shared.all(), registry: ClaudeRegistry().load())
    let report = AIDataScanner.scan(paths: AIDataPaths(), options: AIDataOptions(staleDays: 60), context: context, codexCLI: CodexCLI.locate())
    func size(_ items: [UInt64]) -> String { Fmt.gb(items.reduce(0, +)) }
    func reasons(_ values: [String?]) -> String {
        let counts = Dictionary(grouping: values.compactMap { $0 }) { $0 }.mapValues(\.count)
        return counts.isEmpty ? "없음" : counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
    }
    print(String(format: "실제 Mac 조사(읽기 전용) %.1f초 · 세션 %d개 · 프로세스 %d개", report.elapsed, sessions.count, records.count))
    print("  Claude 기록: 전체 \(report.transcriptCount)개 · \(Fmt.gb(report.transcriptBytes))")
    for group in ClaudeTranscript.Group.allCases {
        let items = report.transcripts(in: group), ready = items.filter(\.selectable)
        print("    \(group == .projectGone ? "프로젝트 폴더 소실" : "오래됨 60일+"): \(items.count)개 · 정리 가능 \(ready.count)개 \(size(ready.map(\.bytes))) · 남김 \(items.count - ready.count)개 \(size(items.filter { !$0.selectable }.map(\.bytes))) (\(reasons(items.map(\.keepReason))))")
    }
    print("    압축 기록 \(report.transcripts.filter(\.compressed).count)개(그룹 안) · 기록 없는 하위 폴더 \(report.transcripts.filter(\.isOrphanFolder).count)개(그룹 안)")
    let codex = report.codex, threadsReady = codex.threads.filter(\.selectable)
    print("  Codex 스레드: DB \((codex.database as NSString?)?.lastPathComponent ?? "없음") · \(codex.schemaNote) · \(codex.cliNote ?? "-") · 버튼 \(codex.canAct ? "켬" : "끔")")
    print("    전체 \(codex.totalThreads)개 · 이미 보관 \(codex.archivedThreads)개 · 오래된 최상위 \(codex.threads.count)개 · 보관 가능 \(threadsReady.count)개 · rollout \(size(threadsReady.map(\.rolloutBytes))) · 남김 (\(reasons(codex.threads.map(\.keepReason))))")
    let cachesReady = report.caches.filter(\.selectable)
    print("  AI 앱 캐시: \(report.caches.count)곳 \(size(report.caches.map(\.bytes))) · 정리 가능 \(cachesReady.count)곳 \(size(cachesReady.map(\.bytes))) · 남김 (\(reasons(report.caches.map { $0.keepReason.map { _ in "실행 중" } }))))")
    for app in Set(report.caches.map(\.app)).sorted() {
        let items = report.caches.filter { $0.app == app }
        print("    \(app): \(items.count)곳 \(size(items.map(\.bytes))) · \(items.allSatisfy(\.selectable) ? "정리 가능" : (items.contains(where: \.selectable) ? "일부 정리 가능" : "실행 중이라 남김"))")
    }
    let versionsReady = report.versions.filter(\.selectable)
    print("  이전 CLI 버전: \(report.versions.count)개 · 정리 가능 \(versionsReady.count)개 \(size(versionsReady.map(\.bytes)))")
    for version in report.versions {
        print("    \(version.tool) \(version.version) · \(Fmt.size(version.bytes)) · \(version.keepReason ?? "정리 가능")")
    }
    check(report.transcriptCount > 0, "실제 조사: Claude 기록을 읽음(\(report.transcriptCount)개)")
    check(codex.database != nil && codex.columns["archived"] != nil && codex.columns["pinned"] != nil, "실제 조사: Codex 상태 DB 열 확인(\(codex.schemaNote))")
    check(report.versions.contains { $0.isCurrent }, "실제 조사: 현재 버전을 찾음(\(report.versions.filter(\.isCurrent).map { $0.tool + " " + $0.version }.joined(separator: ", ")))")
    check(report.versions.filter { !$0.inUse.isEmpty }.allSatisfy { !$0.selectable }, "실제 조사: 실행 중인 버전은 모두 남김(\(report.versions.filter { !$0.inUse.isEmpty }.map(\.version).joined(separator: ", ")))")
    writeEvidence("aidata-smoke.json", ["elapsed": report.elapsed, "transcripts": report.transcriptCount, "transcript_bytes": report.transcriptBytes,
                                         "project_gone": report.transcripts(in: .projectGone).count, "stale": report.transcripts(in: .stale).count,
                                         "selectable_transcripts": report.transcripts.filter(\.selectable).count, "codex_total": codex.totalThreads, "codex_archived": codex.archivedThreads,
                                         "codex_old_top": codex.threads.count, "codex_selectable": threadsReady.count, "codex_can_act": codex.canAct,
                                         "caches": report.caches.count, "caches_selectable_bytes": cachesReady.reduce(0) { $0 + $1.bytes },
                                         "versions": report.versions.map { ["tool": $0.tool, "version": $0.version, "bytes": $0.bytes, "keep": $0.keepReason ?? ""] }])
}
