import Foundation
import ReMONCore

// Mole '정리할 준비 완료' 화면(10-25 08:37 대표 캡처)의 항목과 ReMON 조사 결과를 같은 순간 이 Mac에서 맞대 본다. 읽기 전용.

private struct MoleItem {
    let label: String
    let path: String
    let size: String
    let selected: Bool
    let group: String
}

private let moleItems: [MoleItem] = [
    MoleItem(label: "Notion Service Worker Cache", path: "~/Library/Application Support/Notion/Partitions/notion/Service Worker/CacheStorage", size: "2.65 GB", selected: true, group: "앱 캐시"),
    MoleItem(label: "Chrome Caches", path: "~/Library/Caches/Google/Chrome", size: "1.33 GB", selected: true, group: "앱 캐시"),
    MoleItem(label: "Chrome Default Service Worker Cache(사용 중)", path: "~/Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage", size: "669 MB", selected: false, group: "앱 캐시"),
    MoleItem(label: "Aside(사용 중)", path: "~/Library/Caches/Aside", size: "268 MB", selected: false, group: "앱 캐시"),
    MoleItem(label: "aikido-mcp", path: "~/Library/Caches/aikido-mcp", size: "200 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "Claude Code Cache", path: "~/Library/Application Support/Claude/Code Cache", size: "199 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "GeoServices", path: "~/Library/Caches/GeoServices", size: "183 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "오래된 업데이트 패키지", path: "~/Library/Application Support/Caches/notion-updater/pending/Notion-arm64-7.40.0.zip", size: "136 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "smooth-ai Cache", path: "~/Library/Application Support/smooth-ai/Cache", size: "67.2 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "aside-memory", path: "~/Library/Caches/aside-memory", size: "62.5 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "obsidian Code Cache", path: "~/Library/Application Support/obsidian/Code Cache", size: "21.3 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "com.apple.VisualIntelligenceCore", path: "~/Library/Caches/com.apple.VisualIntelligenceCore", size: "19.4 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "com.apple.icloudmailagent", path: "~/Library/Caches/com.apple.icloudmailagent", size: "19.2 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "Grok Bot Code Cache", path: "~/Library/Application Support/Grok Bot/Code Cache", size: "17.2 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "com.apple.parsecd", path: "~/Library/Caches/com.apple.parsecd", size: "17 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "uv Cache", path: "~/.cache/uv", size: "16.6 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "Aside Graphite Dawn Cache", path: "~/Library/Application Support/Aside/GraphiteDawnCache", size: "13.1 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "com.apple.appstoreagent", path: "~/Library/Caches/com.apple.appstoreagent", size: "9.75 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "storearc-tools", path: "~/Library/Caches/storearc-tools", size: "9.72 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "orca GPU Cache", path: "~/Library/Application Support/orca/GPUCache", size: "5.84 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "pip", path: "~/Library/Caches/pip", size: "5.46 MB", selected: true, group: "앱 캐시"),
    MoleItem(label: "npm Logs", path: "~/.npm/_logs", size: "49 KB", selected: true, group: "앱 캐시"),
    MoleItem(label: "Gradle Daemon 8.11.1", path: "~/.gradle/daemon/8.11.1", size: "1.53 MB", selected: false, group: "앱 캐시"),
    MoleItem(label: "Cursor Agent 이전 버전 6개", path: "~/Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/.local/share/cursor-agent/versions", size: "1.25 GB", selected: true, group: "AI 도구"),
    MoleItem(label: "Gemini Browser Cache", path: "~/.gemini/antigravity-browser-profile/Default/Cache", size: "167 MB", selected: true, group: "AI 도구"),
    MoleItem(label: "Gemini Browser Code Cache", path: "~/.gemini/antigravity-browser-profile/Default/Code Cache", size: "35.2 MB", selected: true, group: "AI 도구"),
    MoleItem(label: "Codex Temp", path: "~/.codex/.tmp", size: "34.4 MB", selected: true, group: "AI 도구"),
    MoleItem(label: "Claude Code Cache(~/.claude/cache)", path: "~/.claude/cache", size: "1.25 MB", selected: true, group: "AI 도구"),
    MoleItem(label: "Claude Code Cache(~/.claude/Cache)", path: "~/.claude/Cache", size: "1.25 MB", selected: true, group: "AI 도구"),
    MoleItem(label: "Simulator System Caches", path: "/Library/Developer/CoreSimulator/Caches", size: "6.05 GB", selected: true, group: "시스템"),
    MoleItem(label: "시스템 로그", path: "/private/var/log", size: "47 MB", selected: true, group: "시스템"),
    MoleItem(label: "고립된 서비스 AppTamer.Helper", path: "/Library/LaunchDaemons/com.stclairsoft.AppTamer.Helper.plist", size: "1 KB", selected: false, group: "시스템"),
]

func moleCompare() {
    let home = NSHomeDirectory()
    func expand(_ path: String) -> String { path.hasPrefix("~") ? home + path.dropFirst() : path }
    let sampler = ProcessSampler()
    let detector = SessionDetector()
    _ = detector.detect(records: sampler.sample(), sampler: sampler, orca: [])
    Thread.sleep(forTimeInterval: 1)
    let records = sampler.sample()
    let sessions = detector.detect(records: records, sampler: sampler, orca: OrcaBridge.list() ?? []).sessions
    let started = Date()
    let disk = DiskScanner().scan(activeDirectories: Set(sessions.compactMap(\.cwd)))
    let context = AIDataContext.live(sessions: sessions, processes: records, vaultEntries: RecoveryVault.shared.all(), registry: ClaudeRegistry().load())
    let ai = AIDataScanner.scan(context: context, codexCLI: nil)
    print(String(format: "ReMON 조사: 디스크 %d곳 · AI 캐시 %d곳 · CLI 버전 %d개 · %.1f초", disk.count, ai.caches.count, ai.versions.count, Date().timeIntervalSince(started)))
    let protectedReason: (String) -> String? = { AIDataProtection.reason(for: $0, home: home, removal: true) }

    for item in moleItems {
        let path = expand(item.path)
        var verdict = "ReMON 없음"
        if let d = disk.first(where: { $0.path == path || path.hasPrefix($0.path + "/") || $0.path.hasPrefix(path + "/") }) {
            let tier = CacheDeletionPolicy.tier(for: d, activeDirectories: Set(sessions.compactMap(\.cwd)))
            let block = CacheDeletionPolicy.blockReason(for: d)
            verdict = "ReMON 디스크 \(d.grade.map { "\($0)" } ?? "-") · \(tier.rawValue)" + (block.map { " · \($0)" } ?? "") + " · \(Fmt.size(d.bytes))"
        } else if let c = ai.caches.first(where: { $0.path == path || path.hasPrefix($0.path + "/") || $0.path.hasPrefix(path + "/") }) {
            verdict = "ReMON AI 캐시 · \(c.keepReason.map { "남김: \($0)" } ?? "정리 가능") · \(Fmt.size(c.bytes))"
        } else if ai.versions.contains(where: { $0.path.hasPrefix(path + "/") || $0.path == path }) {
            let versions = ai.versions.filter { $0.path.hasPrefix(path + "/") || $0.path == path }
            verdict = "ReMON 이전 버전 \(versions.count)개"
        } else if let reason = protectedReason(path) {
            verdict = "ReMON 보호: \(reason)"
        }
        let exists = FileManager.default.fileExists(atPath: path)
        print("MOLE \(item.selected ? "[선택]" : "[ ]") \(item.group) · \(item.label) · \(item.size)\(exists ? "" : " (지금 없음)") → \(verdict)")
    }
    // ReMON에만 있는 큰 항목(Mole 목록에 없는 것) 상위
    let molePaths = moleItems.map { expand($0.path) }
    let ours = disk.filter { d in !molePaths.contains { $0 == d.path || $0.hasPrefix(d.path + "/") || d.path.hasPrefix($0 + "/") } }.sorted { $0.bytes > $1.bytes }
    print("--- ReMON에만 있는 항목(크기순 상위 15) ---")
    for d in ours.prefix(15) {
        let tier = CacheDeletionPolicy.tier(for: d, activeDirectories: Set(sessions.compactMap(\.cwd)))
        print("REMON \(d.path.replacingOccurrences(of: home, with: "~")) · \(d.category) · \(d.grade.map { "\($0)" } ?? "-") · \(tier.rawValue) · \(Fmt.size(d.bytes))" + (CacheDeletionPolicy.blockReason(for: d).map { " · \($0)" } ?? ""))
    }
    for v in ai.versions { print("REMON 버전 \(v.tool) \(v.version) · \(v.isCurrent ? "현재" : v.inUse.isEmpty ? "정리 가능" : "실행 중 \(v.inUse.count)") · \(Fmt.size(v.bytes))") }
    let movable = ai.transcripts.filter { $0.keepReason == nil }
    print("REMON Claude 기록 정리 후보 \(movable.count)개 · \(Fmt.size(movable.reduce(0) { $0 + $1.bytes })) · Codex 보관 후보 \(ai.codex.threads.count)개")
}
