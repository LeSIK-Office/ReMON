import Foundation
import ReMONCore

// 10-25 Mole 대조로 넣은 항목 검사(가짜 홈): Electron 앱 캐시 · Service Worker(기본 제외) · ~/Library/Caches(macOS·memory는 보기만) ·
// 업데이트 대기 파일 · uv · Cursor Agent 이전 버전 · Gemini 브라우저 캐시 · Codex 임시(실행 중이면 남김). 실제 홈은 건드리지 않는다.

private func fill(_ path: String, bytes: Int) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x5A, count: bytes))
}

private func age(_ path: String, days: Double) {
    let date = Date().addingTimeInterval(-days * 86_400)
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

func appCacheCheck() {
    let fm = FileManager.default
    let home = "/private/tmp/remon-appcache-check"
    try? fm.removeItem(atPath: home)
    let support = home + "/Library/Application Support", caches = home + "/Library/Caches"
    // Electron 앱(크롬 프로필 표시가 있음) · 표시 없는 앱의 'Cache'
    fill(support + "/FakeApp/Local Storage/leveldb/x", bytes: 10)
    fill(support + "/FakeApp/Code Cache/js/a", bytes: 2 << 20)
    fill(support + "/FakeApp/GPUCache/b", bytes: 2 << 20)
    fill(support + "/FakeApp/Service Worker/CacheStorage/c", bytes: 3 << 20)
    fill(support + "/FakeApp/Partitions/main/Preferences", bytes: 10)
    fill(support + "/FakeApp/Partitions/main/Cache/d", bytes: 2 << 20)
    fill(support + "/PlainApp/Cache/e", bytes: 3 << 20)
    fill(support + "/Caches/fake-updater/pending/FakeApp-2.0.zip", bytes: 2 << 20)
    // Library/Caches
    fill(caches + "/com.apple.fakeagent/f", bytes: 6 << 20)
    fill(caches + "/aside-memory/g", bytes: 2 << 20)
    fill(caches + "/my-tool/h", bytes: 6 << 20)
    fill(caches + "/tiny-tool/i", bytes: 1 << 20)
    fill(caches + "/Homebrew/downloads/j", bytes: 6 << 20)
    fill(home + "/.cache/uv/k", bytes: 2 << 20)

    let scanner = DiskScanner(home: home)
    let items = scanner.catalogItems(running: RunningApps.empty)
    func item(_ suffix: String) -> DiskItem? { items.first { $0.path == home + suffix } }
    let codeCache = item("/Library/Application Support/FakeApp/Code Cache"), worker = item("/Library/Application Support/FakeApp/Service Worker/CacheStorage")
    check(codeCache?.grade == .a && item("/Library/Application Support/FakeApp/GPUCache") != nil && item("/Library/Application Support/FakeApp/Partitions/main/Cache") != nil,
          "Electron 앱 캐시: Code Cache · GPUCache · Partitions/*/Cache를 A로 찾음")
    check(item("/Library/Application Support/PlainApp/Cache") == nil, "크롬 프로필 표시가 없는 앱의 'Cache'는 캐시로 보지 않음")
    check(worker?.grade == .b && worker?.defaultExcluded == true, "Service Worker 저장소는 B · 기본 제외(오프라인 웹 데이터)")
    check(item("/Library/Application Support/Caches/fake-updater/pending")?.grade == .a, "업데이트 대기 파일(*-updater/pending)은 A")
    check(item("/Library/Caches/com.apple.fakeagent")?.grade == .c && item("/Library/Caches/aside-memory")?.grade == .c, "Library/Caches: macOS(com.apple.*)·'memory'는 보기만(C)")
    check(item("/Library/Caches/my-tool")?.grade == .a && item("/Library/Caches/tiny-tool") == nil && items.filter { $0.path.hasPrefix(caches + "/Homebrew") }.allSatisfy { $0.entryID == "brew.cache" },
          "Library/Caches: 5MB 이상 일반 항목은 A · 작은 것 생략 · Homebrew는 원래 항목이 맡음")
    check(item("/.cache/uv")?.entryID == "uv.cache", "uv 캐시 찾음")
    // 주인 앱이 실행 중이면(.app 번들 이름) 건너뜀 → 영구 삭제 등급도 휴지통으로
    let running = RunningApps(appNames: ["fakeapp"])
    let skipped = scanner.catalogItems(running: running).first { $0.path == codeCache?.path }
    check(skipped?.skipReason != nil && skipped.map { CacheDeletionPolicy.tier(for: $0, activeDirectories: [], running: running) } == .trashOnly,
          "FakeApp.app 실행 중이면 그 캐시는 건너뜀(\(skipped?.skipReason ?? "이유 없음"))")

    // 10-25 실사고: Orca 실행 중 ~/Library/Caches/orca-updater를 지움 → 업데이트 꼬리를 뗀 이름·실행 인자로도 주인을 알아봐야 한다.
    fill(caches + "/orca-updater/pending/Orca-2.0.zip", bytes: 6 << 20)
    fill(caches + "/aikido-mcp/index/db", bytes: 6 << 20)
    fill(support + "/Caches/orca-updater/pending/Orca-2.1.zip", bytes: 2 << 20)
    let orcaOn = RunningApps(appNames: ["orca"])
    let withOrca = scanner.catalogItems(running: orcaOn)
    let updater = withOrca.first { $0.path == caches + "/orca-updater" }, pending = withOrca.first { $0.path == support + "/Caches/orca-updater/pending" }
    check(updater?.skipReason != nil && pending?.skipReason != nil && updater.map { CacheDeletionPolicy.tier(for: $0, activeDirectories: [], running: orcaOn) } == .trashOnly,
          "Orca가 켜져 있으면 orca-updater 캐시·업데이트 대기 파일은 건너뜀(\(updater?.skipReason ?? "이유 없음"))")
    check(scanner.catalogItems(running: RunningApps.empty).first { $0.path == caches + "/orca-updater" }?.skipReason == nil, "Orca가 꺼져 있으면 orca-updater는 정리 가능(A)")
    let mcpOn = RunningApps(commandLines: ["node /Users/u/.npm/_npx/1a2b/node_modules/.bin/aikido-mcp --stdio"])
    check(scanner.catalogItems(running: mcpOn).first { $0.path == caches + "/aikido-mcp" }?.skipReason != nil, "MCP 서버가 돌고 있으면(실행 인자에 aikido-mcp) 그 캐시는 건너뜀")

    // Cursor Agent 이전 버전 · Gemini 브라우저 캐시 · Codex 임시
    let versions = home + "/.local/share/cursor-agent/versions"
    fill(versions + "/2026.07.01-aaaaaaa/cursor-agent", bytes: 3 << 20)
    fill(versions + "/2026.10.01-bbbbbbb/cursor-agent", bytes: 3 << 20)
    age(versions + "/2026.07.01-aaaaaaa", days: 30); age(versions + "/2026.10.01-bbbbbbb", days: 3)
    try? fm.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
    try? fm.createSymbolicLink(atPath: home + "/.local/bin/cursor-agent", withDestinationPath: versions + "/2026.10.01-bbbbbbb/cursor-agent")
    fill(home + "/.gemini/antigravity-browser-profile/Default/Cache/l", bytes: 2 << 20)
    fill(home + "/.codex/.tmp/m", bytes: 2 << 20)
    let paths = AIDataPaths(home: home)
    let idle = AIDataContext()
    let found = CLIVersionCatalog.scan(paths: paths, options: AIDataOptions(), context: idle).filter { $0.tool == "Cursor Agent" }
    let old = found.first { $0.version.hasPrefix("2026.07") }, current = found.first { $0.version.hasPrefix("2026.10") }
    check(old?.selectable == true && current?.isCurrent == true && current?.selectable == false, "Cursor Agent: 링크가 가리키는 현재 버전은 남기고 이전 버전은 정리 가능")
    let caches1 = AIAppCacheCatalog.scan(paths: paths, context: idle)
    check(caches1.contains { $0.path.hasSuffix("antigravity-browser-profile/Default/Cache") } && caches1.contains { $0.path.hasSuffix("/.codex/.tmp") && $0.selectable },
          "AI 캐시: Gemini 브라우저 프로필 캐시 · Codex 임시(.tmp) 찾음")
    let codexRunning = AIDataContext(executables: [RunningExecutable(pid: 4242, name: "codex", path: "/opt/homebrew/bin/codex")])
    let tmp = AIAppCacheCatalog.scan(paths: paths, context: codexRunning).first { $0.path.hasSuffix("/.codex/.tmp") }
    check(tmp?.selectable == false && tmp?.keepReason?.contains("실행 중") == true, "Codex가 돌고 있으면 .tmp는 남김(실행 중인 세션이 씀)")
    check(AIAppCacheCatalog.isKnownCache(home + "/.codex/.tmp", paths: paths) && AIAppCacheCatalog.isKnownCache(home + "/.gemini/antigravity-browser-profile/Default/Cache", paths: paths),
          "지우기 직전 모양 확인이 새 AI 캐시 경로를 알아봄")
    try? fm.removeItem(atPath: home)
}
