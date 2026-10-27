import Darwin
import Foundation
import ReMONCore

// 실전 복구 검사(외부 호출 있음 — 로그인된 Claude·Codex CLI로 아주 짧은 더미 대화). 진짜 에이전트 더미 세션을
// 비공개 tmux 서버(-L remon-recovery-test, 사용자 tmux와 분리)에 띄워 → 조사기로 감지 → 금고 먼저 정리(실제 SIGTERM) →
// 금고에 적힌 리줌 명령으로 같은 대화가 돌아오는지(앞서 말한 암호를 기억하는지) 확인 → 더미 흔적(기록·스레드)을 지운다.
// 대화형 Claude는 처음 보는 폴더에서 신뢰 확인 창을 띄운다(10-25 실측) → 검사 전용 폴더에서 '신뢰'를 골라 넘긴다
// (Claude가 ~/.claude.json에 그 임시 폴더 한 줄을 적는 것은 새 폴더를 열 때와 같다). Codex는 --no-daemon으로 띄운다
// (기본 데몬 방식이면 rollout을 데몬이 쥐고, 클라이언트가 끝나도 데몬이 남는다 — 10-25 실측).

let liveSocket = "remon-recovery-test"

func runIn(_ directory: String, _ arguments: [String], timeout: TimeInterval = 240) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: directory)
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice   // codex exec는 표준 입력이 열려 있으면 기다린다(10-25 실측)
    do { try process.run() } catch { return CommandResult(status: -1, stderr: "\(error)") }
    final class Box: @unchecked Sendable { var out = Data(), err = Data() }
    let box = Box(), group = DispatchGroup()
    group.enter(); DispatchQueue.global().async { box.out = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter(); DispatchQueue.global().async { box.err = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    if group.wait(timeout: .now() + timeout) == .timedOut { process.terminate(); return CommandResult(status: -2, stderr: "시간 초과", timedOut: true) }
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, stdout: String(decoding: box.out, as: UTF8.self), stderr: String(decoding: box.err, as: UTF8.self))
}

func liveDescendants(of root: Int32, in records: [ProcRecord]) -> [ProcRecord] {
    var children: [Int32: [ProcRecord]] = [:]
    for record in records { children[record.ppid, default: []].append(record) }
    var result: [ProcRecord] = [], queue = [root]
    while let pid = queue.popLast() { for child in children[pid] ?? [] { result.append(child); queue.append(child.pid) } }
    return result
}

func recoveryLiveCheck() {
    let fm = FileManager.default
    guard let tmuxPath = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].first(where: { fm.isExecutableFile(atPath: $0) }) else {
        check(false, "tmux가 없어 실전 검사를 못 함"); return
    }
    @discardableResult func tmux(_ arguments: [String]) -> CommandResult { Shell.capture(tmuxPath, ["-L", liveSocket] + arguments, timeout: 10) }
    let root = checkRoot + "/recovery-live"
    let repo = root + "/proj"
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
    let audit = AuditLog(url: URL(fileURLWithPath: root + "/actions.jsonl"))
    let vault = RecoveryVault(folder: URL(fileURLWithPath: root + "/vault"))
    vault.audit = audit
    defer { tmux(["kill-server"]) }

    func retire(_ session: AgentSession, registryID: String?, records: [ProcRecord]) -> RecoveryEntry? {
        let terminator = SessionTerminator(registry: TerminationRegistry())
        terminator.audit = audit
        let retirer = SessionRetirer(vault: vault, terminator: terminator)
        retirer.audit = audit
        let members = records.filter { session.pids.contains($0.pid) }
        let plan = terminator.plan(session: session, members: members, environments: [:], context: ProtectionContext(), pinKey: "live")
        let prepared = retirer.prepare(plan: plan, registrySessionID: registryID, argv: ProcessSampler.readArguments(pid: session.rootPID)?.argv ?? [], reason: "실전 검사", requireKey: true)
        let outcome = retirer.execute(prepared, dryRun: false, force: false, footprints: [:]) { _ in false }
        print("  정리: \(outcome.message)")
        return outcome.entry
    }

    // ── Claude Code ──
    let claudeID = UUID().uuidString.lowercased()
    let common = ["--model", "haiku", "--setting-sources", "", "--strict-mcp-config"]
    let created = runIn(repo, ["claude", "-p", "암호는 바나나야. OK라고만 답해.", "--session-id", claudeID, "--tools", ""] + common)
    check(created.succeeded, "Claude 더미 대화 만들기(암호 알려 주기) · \(created.stdout.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20))")
    tmux(["new-session", "-d", "-s", "claude", "-x", "120", "-y", "40", "-c", repo, "claude --resume \(claudeID) --model haiku --setting-sources '' --strict-mcp-config"])
    var claudePID: Int32?
    var trusted = false
    for _ in 0..<60 {
        Thread.sleep(forTimeInterval: 0.5)
        if !trusted, tmux(["capture-pane", "-t", "claude", "-p"]).stdout.contains("Yes, I trust this folder") {
            tmux(["send-keys", "-t", "claude", "Down"]); Thread.sleep(forTimeInterval: 0.3); tmux(["send-keys", "-t", "claude", "Enter"])
            trusted = true
        }
        let pane = Int32(tmux(["list-panes", "-t", "claude", "-F", "#{pane_pid}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let candidates = [pane] + liveDescendants(of: pane, in: ProcessSampler().sample()).map(\.pid)
        claudePID = candidates.first { fm.fileExists(atPath: NSHomeDirectory() + "/.claude/sessions/\($0).json") }
        if claudePID != nil { break }
    }
    let registry = ClaudeRegistry().load()
    check(claudePID != nil && registry[claudePID ?? 0]?.sessionId == claudeID, "Claude 더미 대화형 세션 기동(tmux) · 레지스트리 sessionId 일치 · pid \(claudePID ?? 0)")
    if let claudePID {
        let sampler = ProcessSampler()
        _ = SessionDetector().detect(records: sampler.sample(), sampler: sampler, orca: [])
        Thread.sleep(forTimeInterval: 1)
        let records = sampler.sample()
        let detected = SessionDetector().detect(records: records, sampler: sampler, orca: []).sessions.first { $0.rootPID == claudePID }
        let key = detected.map { ResumeKey.resolve($0, registrySessionID: claudeID, argv: ProcessSampler.readArguments(pid: claudePID)?.argv ?? []) }
        check(detected != nil && key?.key?.id == claudeID, "조사기가 더미를 Claude 세션으로 감지 · 복구 키 정확(\(key?.label ?? "없음"))")
        if let detected, let entry = retire(detected, registryID: claudeID, records: records) {
            Thread.sleep(forTimeInterval: 0.5)
            check(entry.status == .held && kill(claudePID, 0) != 0, "실제 SIGTERM으로 정리 · 금고 '보관 중' · 프로세스 없음")
            let args = (entry.resumeArgs ?? []) + ["-p", "암호가 뭐였지? 한 단어로만.", "--setting-sources", "", "--strict-mcp-config", "--tools", ""]
            let resumed = runIn(entry.cwd ?? repo, args)
            let answer = resumed.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            check(answer.contains("바나나"), "금고의 리줌 명령으로 같은 대화 복귀 · 암호 기억: \"\(answer.prefix(30))\" · 명령 \((entry.resumeArgs ?? []).joined(separator: " "))")
        } else {
            check(false, "Claude 더미 정리 실패")
        }
    }
    // 더미 흔적: 검사 전용 폴더의 Claude 프로젝트 기록 폴더를 통째로 지운다(이름에 remon-check가 있을 때만).
    let encoded = repo.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
    if encoded.contains("remon-check") { try? fm.removeItem(atPath: NSHomeDirectory() + "/.claude/projects/\(encoded)") }

    // ── Codex CLI ──
    let made = runIn(repo, ["codex", "exec", "--skip-git-repo-check", "-c", "model_reasoning_effort=\"low\"", "--json", "암호는 바나나야. OK라고만 답해."])
    let threadID = made.stdout.split(separator: "\n").compactMap { line -> String? in
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], (object["type"] as? String) == "thread.started" else { return nil }
        return object["thread_id"] as? String
    }.first
    check(made.succeeded && threadID != nil, "Codex 더미 스레드 만들기(암호 알려 주기) · \(threadID?.prefix(8) ?? "없음")")
    guard let threadID else { return }
    tmux(["new-session", "-d", "-s", "codex", "-x", "120", "-y", "40", "-c", repo, "codex --no-daemon resume \(threadID)"])
    var codexRoot: Int32?
    for _ in 0..<60 {
        Thread.sleep(forTimeInterval: 0.5)
        let pane = Int32(tmux(["list-panes", "-t", "codex", "-F", "#{pane_pid}"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let tree = [pane] + liveDescendants(of: pane, in: ProcessSampler().sample()).map(\.pid)
        if tree.contains(where: { pid in ProcessSampler.openFiles(pid: pid).contains { $0.hasSuffix(threadID + ".jsonl") } }) { codexRoot = pane; break }
    }
    if codexRoot == nil { print(tmux(["capture-pane", "-t", "codex", "-p"]).stdout.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix(12).joined(separator: "\n")) }
    check(codexRoot != nil, "Codex 더미 대화형 세션 기동(tmux) · rollout을 연 프로세스 확인")
    if codexRoot != nil {
        let sampler = ProcessSampler()
        _ = SessionDetector().detect(records: sampler.sample(), sampler: sampler, orca: [])
        Thread.sleep(forTimeInterval: 1)
        let records = sampler.sample()
        let detected = SessionDetector().detect(records: records, sampler: sampler, orca: []).sessions.first { session in
            session.kind == .codexCLI && (session.logPath?.hasSuffix(threadID + ".jsonl") == true || session.extraLogPaths.contains { $0.hasSuffix(threadID + ".jsonl") })
        }
        let key = detected.map { ResumeKey.resolve($0, registrySessionID: nil, argv: ProcessSampler.readArguments(pid: $0.rootPID)?.argv ?? []) }
        check(key?.key?.id == threadID, "조사기가 더미를 Codex 세션으로 감지 · 주 스레드 복구 키 정확(\(key?.label ?? "없음"))")
        if let detected, let entry = retire(detected, registryID: nil, records: records) {
            Thread.sleep(forTimeInterval: 0.5)
            check(entry.status == .held && kill(detected.rootPID, 0) != 0, "실제 SIGTERM으로 정리 · 금고 '보관 중' · 프로세스 없음")
            let resumed = runIn(entry.cwd ?? repo, ["codex", "exec", "--skip-git-repo-check", "-c", "model_reasoning_effort=\"low\"", "--json", "resume", threadID, "암호가 뭐였지? 한 단어로만."])
            let replies = resumed.stdout.split(separator: "\n").compactMap { line -> String? in
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], (object["type"] as? String) == "item.completed",
                      let item = object["item"] as? [String: Any] else { return nil }
                return item["text"] as? String
            }
            check(replies.last?.contains("바나나") == true, "금고의 리줌 키로 같은 스레드 복귀 · 암호 기억: \"\(replies.last?.prefix(30) ?? "")\" · 명령 \((entry.resumeArgs ?? []).joined(separator: " "))")
        } else {
            check(false, "Codex 더미 정리 실패")
        }
    }
    tmux(["kill-server"])
    Thread.sleep(forTimeInterval: 1)
    let deleted = runIn(repo, ["codex", "delete", "--force", threadID], timeout: 30)
    print("  더미 스레드 삭제(codex delete): 종료 코드 \(deleted.status) \(deleted.stdout.prefix(60))\(deleted.stderr.prefix(60))")
}
