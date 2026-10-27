import Foundation

// AI 데이터 위생 실행. 항목마다 직전에 다시 확인하고(조사 뒤 바뀌었거나 실행·보관·최근이면 건너뜀), 되돌리는 방법을 금고에 적는다.
// 대화(기록·스레드)는 휴지통·Codex 보관만, 영구 삭제는 앱이 꺼진 순수 캐시와 아무도 쓰지 않는 이전 버전뿐이다.
public enum AIDataCleaner {
    /// Claude 기록 → 휴지통(기록 파일, 그다음 같은 id의 하위 폴더). 금고에 원래 자리·휴지통 위치를 적어 되돌린다.
    public static func trashTranscripts(_ items: [ClaudeTranscript], paths: AIDataPaths, options: AIDataOptions, context: AIDataContext, vault: RecoveryVault?,
                                        audit: AuditLog = .shared, dryRun: Bool) -> [AIDataResult] {
        items.map { item in
            let label = item.title ?? String(item.sessionID.prefix(8))
            func skip(_ why: String) -> AIDataResult {
                audit.write(action: "aidata.transcript", target: item.path, bytes: item.bytes, result: "skipped: " + why, dryRun: dryRun)
                return AIDataResult(target: label, ok: false, skipped: true, bytes: 0, message: why)
            }
            // 모양: 기록 폴더 바로 아래의 <id>.jsonl(.gz) · 같은 id의 하위 폴더만(그 밖은 위생 기능도 옮기지 않는다)
            let folder = paths.claudeProjects + "/" + item.folder
            let name = (item.path as NSString).lastPathComponent
            guard !item.folder.isEmpty, !item.folder.contains("/"), (item.path as NSString).deletingLastPathComponent == folder,
                  ClaudeTranscriptName.isTranscriptEntry(name), item.companion.map({ $0 == folder + "/" + item.sessionID || $0 == item.path }) ?? true else {
                return skip("Claude 기록 폴더 바로 아래의 기록이 아닙니다")
            }
            guard let fresh = ClaudeTranscriptScanner.refresh(item, options: options, context: context) else { return skip("이미 없습니다") }
            guard fresh.selectable else { return skip(fresh.keepReason ?? "더 이상 정리 대상이 아닙니다") }
            guard abs(fresh.modified.timeIntervalSince(item.modified)) < 1 else { return skip("조사한 뒤 기록이 바뀌었습니다") }
            let reason = "AI 데이터 위생 · " + (item.group == .projectGone ? "프로젝트 폴더 소실" : "오래된 기록")
            var moved: UInt64 = 0
            var targets: [(path: String, title: String)] = [(item.path, item.isOrphanFolder ? label + " · 기록 없는 하위 폴더" : label)]
            if let companion = item.companion, companion != item.path { targets.append((companion, label + " · 하위 폴더(subagents·tool-results)")) }
            for (index, target) in targets.enumerated() {
                let bytes = DiskScanner.allocatedSize(target.path)
                do {
                    guard dryRun || vault != nil else { throw SafeFileOps.Failure.failed("복구 금고가 없어 기록을 옮기지 않습니다") }
                    var entry = RecoveryEntry(kind: .trash, status: .retiring, project: item.project, title: target.title, reason: reason, bytes: bytes)
                    entry.agent = AgentKind.claudeCode.rawValue
                    entry.cwd = item.cwd
                    entry.note = "Claude 기록 \(item.sessionID.prefix(8)) · \(item.folder)"
                    _ = try SafeFileOps.moveToTrash(target.path, userPIDs: context.userPIDs, dryRun: dryRun, bytes: bytes, audit: audit, vault: vault,
                                                    allowClaudeTranscript: true, entry: entry)
                    moved += bytes
                } catch {
                    let message = index == 0 ? "\(error)" : "기록은 옮겼지만 하위 폴더는 남았습니다: \(error)"
                    return AIDataResult(target: label, ok: false, skipped: false, bytes: moved, message: message)
                }
            }
            return AIDataResult(target: label, ok: true, skipped: false, bytes: moved, message: dryRun ? "드라이런 · 휴지통 예정" : "휴지통으로 옮김")
        }
    }

    /// Codex 스레드 → `codex archive`(스레드마다 금고 먼저).
    public static func archiveThreads(_ threads: [CodexThread], report: CodexThreadReport, options: AIDataOptions, context: AIDataContext, vault: RecoveryVault?,
                                      audit: AuditLog = .shared, dryRun: Bool) -> [AIDataResult] {
        threads.map { CodexThreadArchiver.archive($0, report: report, options: options, context: context, vault: vault, audit: audit, dryRun: dryRun) }
    }

    /// AI 앱 캐시 → 영구 삭제(앱이 꺼져 있을 때만). 금고에 '되돌릴 수 없음 · 재생성 방법'을 남긴다.
    public static func clearCaches(_ items: [AIAppCache], paths: AIDataPaths, context: AIDataContext, vault: RecoveryVault?, audit: AuditLog = .shared, dryRun: Bool) -> [AIDataResult] {
        items.map { item in
            let label = item.app + " · " + item.folder
            func skip(_ why: String) -> AIDataResult {
                audit.write(action: "aidata.cache", target: item.path, bytes: item.bytes, result: "skipped: " + why, dryRun: dryRun)
                return AIDataResult(target: label, ok: false, skipped: true, bytes: 0, message: why)
            }
            guard AIAppCacheCatalog.isKnownCache(item.path, paths: paths) else { return skip("알려진 AI 앱 캐시 폴더가 아닙니다") }
            guard fileType(item.path) == S_IFDIR else { return skip("이미 없습니다") }
            let fresh = AIAppCacheCatalog.classify(item, context: context)
            if let reason = fresh.keepReason { return skip(reason) }
            let bytes = DiskScanner.allocatedSize(item.path)
            do {
                try SafeFileOps.deletePermanently(item.path, userPIDs: context.userPIDs, dryRun: dryRun, bytes: bytes, audit: audit, vault: vault, project: item.app,
                                                  reason: "AI 데이터 위생 · 앱 캐시", regeneration: item.regeneration)
                return AIDataResult(target: label, ok: true, skipped: false, bytes: bytes, message: dryRun ? "드라이런 · 삭제 예정" : "비움")
            } catch {
                return AIDataResult(target: label, ok: false, skipped: false, bytes: 0, message: "\(error)")
            }
        }
    }

    /// 이전 CLI 버전 → 영구 삭제(현재 아님 · 아무도 실행하지 않음 · 하드링크 아님). 직전에 버전 목록을 새로 읽어 다시 판정한다.
    public static func deleteVersions(_ items: [CLIVersion], paths: AIDataPaths, options: AIDataOptions, context: AIDataContext, vault: RecoveryVault?,
                                      audit: AuditLog = .shared, dryRun: Bool) -> [AIDataResult] {
        let fresh = CLIVersionCatalog.scan(paths: paths, options: options, context: context)
        return items.map { item in
            let label = item.tool + " " + item.version
            func skip(_ why: String) -> AIDataResult {
                audit.write(action: "aidata.version", target: item.path, bytes: item.bytes, result: "skipped: " + why, dryRun: dryRun)
                return AIDataResult(target: label, ok: false, skipped: true, bytes: 0, message: why)
            }
            guard let now = fresh.first(where: { $0.path == item.path }) else { return skip("버전 목록에서 다시 찾지 못했습니다") }
            if let reason = now.keepReason { return skip(reason) }
            do {
                try SafeFileOps.deletePermanently(item.path, userPIDs: context.userPIDs, dryRun: dryRun, bytes: now.bytes, audit: audit, vault: vault, project: item.tool,
                                                  reason: "AI 데이터 위생 · 이전 CLI 버전", regeneration: now.regeneration)
                return AIDataResult(target: label, ok: true, skipped: false, bytes: now.bytes, message: dryRun ? "드라이런 · 삭제 예정" : "지움")
            } catch {
                return AIDataResult(target: label, ok: false, skipped: false, bytes: 0, message: "\(error)")
            }
        }
    }
}
