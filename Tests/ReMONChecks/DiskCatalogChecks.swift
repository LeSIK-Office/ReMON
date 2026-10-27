import Darwin
import Foundation
import ReMONCore

// 개발 캐시 카탈로그 · 시스템 데이터 · 큰 파일 검사. 실제 삭제·휴지통은 /private/tmp/remon-diskcatalog의 시험 폴더로만 한다
// (휴지통으로 옮긴 시험 파일은 바로 되돌린다 — 휴지통을 비우지 않는다). 마지막의 실제 홈 조사는 읽기 전용이다.

let catalogRoot = "/private/tmp/remon-diskcatalog"

final class RunnerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, [String])] = []
    func record(_ executable: String, _ arguments: [String]) { lock.lock(); items.append((executable, arguments)); lock.unlock() }
    var calls: [(String, [String])] { lock.lock(); defer { lock.unlock() }; return items }
}

/// 실제 바이트를 쓴다(성긴 파일은 할당량이 0이라 크기 시험이 무의미해진다).
func writeBytes(_ path: String, _ count: Int, modified: Date? = nil) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(repeating: 0x5A, count: count))
    if let modified { setModified(path, modified) }
}

func setModified(_ path: String, _ date: Date) {
    try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
}

func allocated(_ path: String) -> UInt64 {
    var info = stat()
    return lstat(path, &info) == 0 ? UInt64(info.st_blocks) * 512 : 0
}

func abbreviate(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

func diskCatalogCheck() {
    setvbuf(stdout, nil, _IOLBF, 0)   // 파일로 보내도 줄마다 바로 쓴다(중간에 멈춰도 결과가 남게)
    let fm = FileManager.default
    try? fm.removeItem(atPath: catalogRoot)
    try? fm.createDirectory(atPath: catalogRoot, withIntermediateDirectories: true)
    let audit = AuditLog(url: URL(fileURLWithPath: catalogRoot + "/actions.jsonl"))
    let vault = RecoveryVault(folder: URL(fileURLWithPath: catalogRoot + "/vault"))
    vault.audit = audit
    let now = Date()
    let old = now.addingTimeInterval(-40 * 86_400)
    let threeDays = now.addingTimeInterval(-3 * 86_400)
    let home = catalogRoot + "/home"
    let kb = 1024

    // 1) 시험 홈 만들기
    let library = home + "/Library"
    let derived = library + "/Developer/Xcode/DerivedData"
    try? fm.createDirectory(atPath: home + "/proj/Live.xcodeproj", withIntermediateDirectories: true)
    func derivedFolder(_ name: String, workspace: String) {
        writeBytes(derived + "/\(name)/Build/Intermediates.noindex/obj.o", 16 * kb)
        (["WorkspacePath": workspace] as NSDictionary).write(toFile: derived + "/\(name)/info.plist", atomically: true)
    }
    derivedFolder("Live-aaaa", workspace: home + "/proj/Live.xcodeproj")
    derivedFolder("Gone-bbbb", workspace: catalogRoot + "/nowhere/Gone.xcodeproj")
    derivedFolder("Offline-cccc", workspace: "/Volumes/NoSuchVolume-remon-check/Offline.xcodeproj")
    writeBytes(derived + "/ModuleCache.noindex/Foundation.pcm", 16 * kb)
    let oldSupport = library + "/Developer/Xcode/iOS DeviceSupport/17.0 (21A1)"
    writeBytes(oldSupport + "/Symbols/dyld", 16 * kb, modified: threeDays)
    setModified(oldSupport + "/Symbols", threeDays); setModified(oldSupport, threeDays)
    writeBytes(library + "/Developer/Xcode/macOS DeviceSupport/15.0/Symbols/dyld", 16 * kb)
    writeBytes(library + "/Developer/Xcode/Archives/2026-10-01/App.xcarchive/Info.plist", 8 * kb)
    writeBytes(home + "/.npm/_cacache/content-v2/sha512/aa", 16 * kb)
    writeBytes(library + "/pnpm/store/v3/files/00/pkg", 16 * kb, modified: threeDays)
    writeBytes(library + "/Caches/ms-playwright/chromium-1140/chrome", 16 * kb)
    writeBytes(home + "/.ollama/models/blobs/sha256-x", 16 * kb)
    let cursor = library + "/Application Support/Cursor"
    writeBytes(cursor + "/Cache/Cache_Data/index", 16 * kb)
    writeBytes(cursor + "/GPUCache/data_0", 8 * kb)
    func workspace(_ id: String, _ uri: String) {
        writeBytes(cursor + "/User/workspaceStorage/\(id)/state.vscdb", 8 * kb)
        FileManager.default.createFile(atPath: cursor + "/User/workspaceStorage/\(id)/workspace.json", contents: Data("{\"folder\":\"\(uri)\"}".utf8))
    }
    workspace("live1", "file://" + home + "/proj")
    workspace("orphan1", "file://" + catalogRoot + "/nowhere/gone%20folder")
    workspace("remote1", "vscode-remote://ssh-remote+box/home/me/proj")
    let chrome = library + "/Application Support/Google/Chrome"
    for name in ["GPUCache/data_0", "Code Cache/js/index", "Local Storage/leveldb/000003.log", "IndexedDB/https_x/0.blob", "Service Worker/CacheStorage/x", "Extensions/abc/Cache/x"] {
        writeBytes(chrome + "/Default/" + name, 8 * kb)
    }
    for name in ["Cookies", "History", "Login Data", "Web Data"] { writeBytes(chrome + "/Default/" + name, 8 * kb) }
    writeBytes(chrome + "/GrShaderCache/data_1", 8 * kb)
    writeBytes(chrome + "/ShaderCache/data_1", 8 * kb)
    writeBytes(chrome + "/Profile 1/GPUCache/data_0", 8 * kb)
    writeBytes(library + "/Caches/Google/Chrome/Default/Cache/Cache_Data/f_000001", 16 * kb)
    let logs = library + "/Logs"
    writeBytes(logs + "/OldApp/a.log", 200 * kb, modified: old); setModified(logs + "/OldApp", old)
    writeBytes(logs + "/NewApp/current.log", 200 * kb)
    writeBytes(logs + "/NewApp/rotated.log.1", 2 * 1024 * kb, modified: old)
    writeBytes(logs + "/old.log", 200 * kb, modified: old)
    writeBytes(logs + "/fresh.log", 200 * kb)
    writeBytes(logs + "/ReMON/actions.jsonl", 200 * kb, modified: old); setModified(logs + "/ReMON", old)
    writeBytes(logs + "/DiagnosticReports/Old-2026-09-01.ips", 4 * kb, modified: old)
    writeBytes(logs + "/DiagnosticReports/New-2026-10-25.ips", 4 * kb)
    writeBytes(home + "/.fakecache/blob", 16 * kb)

    let scanner = DiskScanner(home: home)
    scanner.minimumBytes = 0
    scanner.catalog = DiskCatalog.entries + [CatalogEntry(id: "check.fakeowner", group: .packages, title: "시험 캐시", paths: [".fakecache"], grade: .a,
                                                          owner: CacheOwner("시험 주인", processNames: ["fakeowner"]), hint: "시험용")]
    let items = scanner.catalogItems(running: RunningApps.empty, now: now)
    var byPath: [String: DiskItem] = [:]
    for item in items { byPath[item.path] = item }
    func item(_ path: String) -> DiskItem? { byPath[path] }
    func tier(_ path: String, running: RunningApps = .empty) -> CacheDeletionPolicy.Tier? {
        item(path).map { CacheDeletionPolicy.tier(for: $0, activeDirectories: [], now: now, running: running) }
    }
    print("fixture catalog items: \(items.count)")

    // 2) 등급
    let npm = home + "/.npm/_cacache", pnpm = library + "/pnpm/store"
    check(item(npm)?.grade == .a && tier(npm) == .pureCache, "등급 A: npm 캐시 → 순수 캐시(영구 삭제)")
    check(item(pnpm)?.grade == .b && tier(pnpm) == .trashOnly && item(pnpm).flatMap { CacheDeletionPolicy.blockReason(for: $0, running: RunningApps.empty) }?.contains("pnpm store prune") == true,
          "등급 B + 권장 명령: pnpm 저장소는 파일을 지우지 않고 'pnpm store prune'으로 안내")
    check(item(oldSupport)?.grade == .b && tier(oldSupport) == .rebuildable, "등급 B: 3일 쉰 DeviceSupport → 다시 만들 수 있음(영구 삭제)")
    let freshSupport = library + "/Developer/Xcode/macOS DeviceSupport/15.0"
    check(item(freshSupport)?.grade == .b && tier(freshSupport) == .trashOnly, "등급 B: 하루 안에 바뀐 DeviceSupport → 휴지통만")
    let archives = library + "/Developer/Xcode/Archives"
    check(item(archives)?.grade == .c && item(archives)?.category == .keep && tier(archives) == .trashOnly
          && item(archives).flatMap { CacheDeletionPolicy.blockReason(for: $0, running: RunningApps.empty) }?.hasPrefix("보기만") == true,
          "등급 C: Xcode Archives → 보기만(지우지 않음)")

    // 3) 삭제된 프로젝트 DerivedData
    check(item(derived + "/Gone-bbbb")?.grade == .a && item(derived + "/Gone-bbbb")?.note.contains("삭제된 프로젝트") == true && tier(derived + "/Gone-bbbb") == .pureCache,
          "DerivedData: WorkspacePath가 없는 프로젝트 → A '삭제된 프로젝트'")
    check(item(derived + "/Live-aaaa")?.grade == .b && item(derived + "/Live-aaaa")?.note.contains("프로젝트 · Live") == true, "DerivedData: 프로젝트가 있으면 B(다시 빌드)")
    check(item(derived + "/Offline-cccc")?.grade == .b && item(derived + "/Offline-cccc")?.note.contains("외장 볼륨") == true, "DerivedData: 빠진 외장 볼륨 프로젝트는 삭제로 보지 않음(B)")
    check(item(derived + "/ModuleCache.noindex")?.grade == .a, "DerivedData: ModuleCache.noindex → A")
    check(item(derived + "/Gone-bbbb").map(DiskCatalog.isRecommended) == true && item(derived + "/Live-aaaa").map(DiskCatalog.isRecommended) == false,
          "추천 선택: 삭제된 프로젝트는 고르고, 있는 프로젝트는 고르지 않음")

    // 4) 기본 제외
    let playwright = library + "/Caches/ms-playwright", ollama = home + "/.ollama/models"
    let excluded = [playwright, ollama, archives].compactMap(item)
    check(excluded.count == 3 && excluded.allSatisfy { $0.defaultExcluded && $0.category == .keep && !DiskCatalog.isRecommended($0) && DiskCatalog.group(of: $0) == .excluded }
          && [playwright, ollama, archives].allSatisfy { tier($0) == .trashOnly },
          "기본 제외: Playwright · Ollama 모델 · Archives는 묶음·자동 정리에서 빠짐(직접 고르면 휴지통)")
    check(item(playwright).flatMap { CacheDeletionPolicy.blockReason(for: $0, running: RunningApps.empty) } == nil && item(ollama).flatMap { CacheDeletionPolicy.blockReason(for: $0, running: RunningApps.empty) } != nil,
          "기본 제외 B(Playwright)는 직접 고를 수 있고, C(모델)는 막힘")

    // 5) 주인 실행 중이면 건너뜀(번들 id 주입)
    let cursorCache = cursor + "/Cache"
    let cursorRunning = RunningApps(bundleIDs: ["com.todesktop.230313mzl4w4u92"])
    let skipped = scanner.catalogItems(running: cursorRunning, now: now).first { $0.path == cursorCache }
    check(skipped?.skipReason?.contains("Cursor 실행 중") == true && tier(cursorCache, running: cursorRunning) == .trashOnly && tier(cursorCache) == .pureCache
          && skipped.map(DiskCatalog.isRecommended) == false, "주인 실행 중: Cursor가 켜져 있으면 캐시를 건너뛰고 이유를 보여 줌, 꺼지면 A")

    // 6) 주인 실행 중 — 실제 프로세스(더미 'fakeowner')로 실시간 판정
    let fakeCache = home + "/.fakecache"
    let owner = spawnDummy("fakeowner", ["--children", "0"])
    let liveRunning = RunningApps.live()
    let liveItem = scanner.catalogItems(running: liveRunning, now: now).first { $0.path == fakeCache }
    check(liveRunning.processNames.contains("fakeowner") && liveItem?.skipReason?.contains("시험 주인 실행 중") == true && tier(fakeCache, running: liveRunning) == .trashOnly,
          "실시간 주인 판정: 'fakeowner' 프로세스가 돌면 건너뜀(pid \(owner.processIdentifier))")
    owner.terminate(); owner.waitUntilExit()
    let afterRunning = RunningApps.live()
    check(!afterRunning.processNames.contains("fakeowner") && tier(fakeCache, running: afterRunning) == .pureCache, "실시간 주인 판정: 프로세스가 끝나면 다시 A(영구 삭제 가능)")
    check(RunningApps(commandLines: ["node /Users/x/.nvm/versions/node/v24/bin/npm install"]).isRunning(CacheOwners.npm) && !RunningApps(commandLines: ["node server.js"]).isRunning(CacheOwners.npm),
          "스크립트 주인: node 실행 인자 속 /bin/npm으로 npm 실행 중을 알아봄(일반 node는 아님)")

    // 7) 브라우저: 캐시 폴더만, 실행 중이면 건너뜀
    let browserItems = items.filter { $0.entryID == "browser.chrome" }
    let browserNames = Set(browserItems.map { ($0.path as NSString).lastPathComponent })
    let expectedChrome = [chrome + "/GrShaderCache", chrome + "/ShaderCache", chrome + "/Default/GPUCache", chrome + "/Default/Code Cache", chrome + "/Profile 1/GPUCache",
                          library + "/Caches/Google/Chrome/Default/Cache"]
    check(Set(browserItems.map(\.path)) == Set(expectedChrome) && browserNames.isSubset(of: DiskCatalog.browserCacheNames),
          "브라우저: 프로필의 Cache·Code Cache·GPUCache·셰이더 캐시만 \(browserItems.count)곳(확장 안 캐시 제외)")
    let touchesProtected = items.contains { item in item.path.split(separator: "/").contains { DiskCatalog.browserProtectedNames.contains(String($0)) } }
    check(!touchesProtected, "브라우저: Cookies·History·Login Data·Local Storage·IndexedDB·Service Worker는 목록에 없음")
    let chromeRunning = RunningApps(bundleIDs: ["com.google.Chrome"])
    let runningBrowser = scanner.catalogItems(running: chromeRunning, now: now).filter { $0.entryID == "browser.chrome" }
    check(!runningBrowser.isEmpty && runningBrowser.allSatisfy { $0.skipReason?.contains("Chrome 실행 중") == true && CacheDeletionPolicy.tier(for: $0, activeDirectories: [], now: now, running: chromeRunning) == .trashOnly }
          && browserItems.allSatisfy { $0.grade == .a && CacheDeletionPolicy.tier(for: $0, activeDirectories: [], now: now, running: RunningApps.empty) == .pureCache },
          "브라우저 실행 중: Chrome이 켜져 있으면 모두 건너뜀 · 꺼지면 A")

    // 8) 편집기 고아 작업 공간 · 로그
    let workspaceItems = items.filter { $0.entryID == "cursor.workspaceStorage" }
    check(workspaceItems.map { ($0.path as NSString).lastPathComponent } == ["orphan1"] && workspaceItems.first?.grade == .b && tier(cursor + "/User/workspaceStorage/orphan1") == .trashOnly,
          "편집기: 폴더가 사라진 작업 공간만(원격·있는 폴더 제외) · 영구 삭제 대신 휴지통")
    let logPaths = Set(items.filter { $0.entryID == "logs.user" || $0.entryID == "logs.diagnostic" }.map(\.path))
    let expectedLogs: Set<String> = [logs + "/OldApp", logs + "/NewApp/rotated.log.1", logs + "/old.log", logs + "/DiagnosticReports/Old-2026-09-01.ips"]
    check(logPaths == expectedLogs, "로그: 30일 넘은 로그만(쓰는 폴더의 최신 로그 · ReMON 기록 · 새 진단 보고서 제외) \(logPaths.count)개")
    check(items.allSatisfy { $0.grade != nil && $0.entryID != nil }, "모든 카탈로그 항목에 등급·항목 id가 있음")

    // 9) 실제 정리(시험 폴더만): A 영구 삭제는 재생성 방법을, 휴지통은 위치를 금고에 남긴다. 드라이런은 아무것도 안 바꾼다.
    if let gone = item(derived + "/Gone-bbbb"), let live = item(derived + "/Live-aaaa") {
        try? SafeFileOps.deletePermanently(live.path, userPIDs: [], dryRun: true, bytes: live.bytes, audit: audit, vault: nil, project: "시험", reason: "시험",
                                           regeneration: CacheDeletionPolicy.regenerationHint(for: live))
        check(fm.fileExists(atPath: live.path) && vault.all().isEmpty, "드라이런: 그대로 있고 금고 기록 없음")
        try? SafeFileOps.deletePermanently(gone.path, userPIDs: [], dryRun: false, bytes: gone.bytes, audit: audit, vault: vault, project: "공용 캐시", reason: "개발 캐시 정리",
                                           regeneration: CacheDeletionPolicy.regenerationHint(for: gone))
        let entry = vault.all().first { $0.originalPath == gone.path }
        check(!fm.fileExists(atPath: gone.path) && entry?.kind == .deleted && entry?.restoreHint == gone.hint && entry?.restorable == false,
              "A 영구 삭제: 삭제된 프로젝트 DerivedData를 지우고 재생성 방법('\(gone.hint ?? "")')을 금고에 기록")
    } else {
        check(false, "DerivedData 시험 항목을 찾지 못함")
    }
    if let orphan = workspaceItems.first {
        let trashed = try? SafeFileOps.moveToTrash(orphan.path, userPIDs: [], dryRun: false, bytes: orphan.bytes, audit: audit, vault: vault, project: "공용 캐시", reason: "개발 캐시 정리")
        let entry = vault.all().first { $0.kind == .trash && $0.originalPath == orphan.path }
        let back = entry.map { RecoveryRestorer.restoreTrash($0, vault: vault) }
        check(trashed != nil && entry?.trashedPath == trashed?.path && back?.ok == true && fm.fileExists(atPath: orphan.path + "/workspace.json"),
              "휴지통 정리: 고아 작업 공간을 휴지통으로 옮기고 금고에 기록 → 되돌리기로 원래 자리(휴지통에 남기지 않음)")
    }

    // 10) 큰 파일·폴더: 순위 · 제외 · 최상위 거부 · 하드링크 한 번 · 취소 · 메인 스레드 밖
    let home2 = catalogRoot + "/home2"
    let mb = 1024 * 1024
    writeBytes(home2 + "/Movies/big.mov", 3 * mb)
    writeBytes(home2 + "/Downloads/set/a.bin", 2 * mb)
    writeBytes(home2 + "/Downloads/set/b.bin", 1 * mb)
    writeBytes(home2 + "/DEV/proj/node_modules/pkg/blob", 3 * mb / 2)
    writeBytes(home2 + "/Documents/deep/chain/only/c.bin", 5 * mb / 2)
    writeBytes(home2 + "/top.bin", mb / 2)
    writeBytes(home2 + "/Library/huge.bin", 5 * mb)
    writeBytes(home2 + "/.Trash/t.bin", 5 * mb)
    writeBytes(home2 + "/Dropbox/d.bin", 5 * mb)
    writeBytes(home2 + "/.codex/sessions/2026/rollout.jsonl", mb)
    writeBytes(home2 + "/Pictures/Lib.photoslibrary/resources/derivatives/big.jpg", 7 * mb / 2)
    writeBytes(home2 + "/Applications/Tool.app/Contents/Resources/blob", mb / 2)
    let finder = LargeFileFinder(home: home2)
    finder.minimumFileBytes = 256 * 1024
    finder.minimumFolderBytes = 256 * 1024
    var offMain = true
    var report = LargeFileFinder.Report()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        offMain = !Thread.isMainThread
        report = finder.scan()
        done.signal()
    }
    done.wait()
    let fileOrder = report.files.map { String($0.path.dropFirst(home2.count + 1)) }
    let expectedFiles = ["Movies/big.mov", "Documents/deep/chain/only/c.bin", "Downloads/set/a.bin", "DEV/proj/node_modules/pkg/blob", ".codex/sessions/2026/rollout.jsonl", "Downloads/set/b.bin", "top.bin"]
    check(fileOrder == expectedFiles && report.files.first?.bytes == allocated(home2 + "/Movies/big.mov"),
          "큰 파일 순위: 실제 할당량 순서 \(fileOrder.prefix(3).joined(separator: " > ")) …")
    check(!report.files.contains { $0.path.contains("/Library/") || $0.path.contains("/.Trash/") || $0.path.contains("/Dropbox/") } && report.skipped.contains("Library") && report.skipped.contains("Dropbox"),
          "큰 파일 제외: ~/Library · 휴지통 · 클라우드 폴더는 들어가지 않음")
    let folderOrder = report.folders.map { String($0.path.dropFirst(home2.count + 1)) }
    check(folderOrder == ["Pictures/Lib.photoslibrary", "Downloads/set", "Documents/deep/chain/only", "DEV/proj/node_modules/pkg", ".codex/sessions/2026", "Applications/Tool.app"]
          && !folderOrder.contains("Movies"), "큰 폴더: 최상위 폴더 제외 · 한 하위 폴더가 거의 전부면 그 하위만 · 패키지는 한 덩어리 \(folderOrder.joined(separator: " · "))")
    let photos = report.folders.first { $0.path.hasSuffix(".photoslibrary") }
    check(!report.files.contains { $0.path.contains(".photoslibrary/") || $0.path.contains(".app/") } && photos?.refusal?.contains("앱 보관함") == true
          && report.folders.first { $0.path.hasSuffix("Tool.app") }?.refusal == nil
          && LargeFileFinder.refusalReason(home2 + "/Applications/Tool.app/Contents/Resources/blob", home: home2) != nil,
          "패키지: 사진 보관함·앱 안 파일은 후보가 아님 · 보관함은 옮기지 않음 · 앱은 통째로만")
    check(LargeFileFinder.refusalReason(home2 + "/Movies", home: home2) == "홈 최상위 폴더는 옮기지 않습니다" && LargeFileFinder.refusalReason(home2, home: home2) != nil
          && LargeFileFinder.refusalReason(home2 + "/top.bin", home: home2) == nil && LargeFileFinder.refusalReason(home2 + "/Movies/big.mov", home: home2) == nil
          && LargeFileFinder.refusalReason("/private/tmp/x", home: home2) != nil && report.files.first { $0.path.hasSuffix("rollout.jsonl") }?.refusal != nil,
          "거부: 홈·홈 최상위 폴더·홈 밖·AI 기록은 옮기지 않음(최상위 파일과 하위 항목은 가능)")
    let packRefusal = LargeFileFinder.refusalReason(home2 + "/DEV/proj/.git/objects/pack/pack-1.pack", home: home2, isDirectory: false)
    let asideRefusal = LargeFileFinder.refusalReason(home2 + "/.aside/u/0/memory/.history.jsonl", home: home2, isDirectory: false)
    let avdRefusal = LargeFileFinder.refusalReason(home2 + "/.android/avd/tab.avd/userdata-qemu.img.qcow2", home: home2, isDirectory: false)
    check(packRefusal?.contains("git") == true && asideRefusal != nil && avdRefusal != nil, "거부: git 저장소 내부 · AI 도구 기억(.aside) · 에뮬레이터 디스크는 옮기지 않음")
    let tempItem = DiskItem(path: "/private/tmp/old-thing", category: .temporary, bytes: 1, modified: old, note: "임시", grade: .a, entryID: "temp.old")
    // 10-25 독립 검토: /private/tmp에 롤백 백업·실행 중 데몬 폴더가 섞여 있었다 → 임시 파일은 영구 삭제하지 않고 휴지통만.
    check(!DiskCatalog.isRecommended(tempItem) && CacheDeletionPolicy.tier(for: tempItem, activeDirectories: [], running: RunningApps.empty) == .trashOnly,
          "임시 파일: 처음 선택에 넣지 않고, 영구 삭제하지 않음(휴지통만 · 주인을 모름)")
    var refused = false
    do { try LargeFileFinder.trash(LargeFileFinder.Entry(path: home2 + "/Movies", bytes: 1, isDirectory: true, modified: nil, refusal: nil), home: home2, userPIDs: [], dryRun: false, audit: audit, vault: vault) }
    catch { refused = true }
    check(refused && fm.fileExists(atPath: home2 + "/Movies/big.mov"), "거부: 홈 최상위 폴더 휴지통 요청은 던지고 그대로 둠")
    if let bin = report.files.first(where: { $0.path.hasSuffix("Downloads/set/b.bin") }) {
        let trashed = try? LargeFileFinder.trash(bin, home: home2, userPIDs: [], dryRun: false, audit: audit, vault: vault)
        let entry = vault.all().first { $0.kind == .trash && $0.originalPath == bin.path }
        let back = entry.map { RecoveryRestorer.restoreTrash($0, vault: vault) }
        check(trashed != nil && entry?.reason == "큰 파일 정리" && back?.ok == true && fm.fileExists(atPath: bin.path), "큰 파일 휴지통: 금고 기록 → 되돌리기로 원래 자리")
    }
    check(offMain, "큰 파일 조사가 메인 스레드 밖에서 돎")
    let home3 = catalogRoot + "/home3"
    writeBytes(home3 + "/data/a.bin", mb)
    try? fm.createDirectory(atPath: home3 + "/other", withIntermediateDirectories: true)
    link(home3 + "/data/a.bin", home3 + "/other/a-link.bin")
    let linkFinder = LargeFileFinder(home: home3)
    linkFinder.minimumFileBytes = 1
    let linkReport = linkFinder.scan()
    check(linkReport.scannedFiles == 2 && linkReport.scannedBytes == allocated(home3 + "/data/a.bin") && linkReport.files.count == 1, "하드링크: 같은 파일을 두 번 세지 않음")
    let cancelFinder = LargeFileFinder(home: home2)
    cancelFinder.minimumFileBytes = 1
    cancelFinder.progressEvery = 1
    let cancelled = cancelFinder.scan { _, _ in cancelFinder.cancel() }
    check(cancelled.cancelled && cancelled.scannedFiles < report.scannedFiles, "취소: 첫 폴더에서 멈춤(파일 \(cancelled.scannedFiles)/\(report.scannedFiles)개)")

    // 11) 시스템 데이터: 스냅샷·Docker 해석, 실패하면 이유만
    let snapshotText = "Snapshots for volume group containing disk /:\ncom.apple.TimeMachine.2026-10-25-101010.local\ncom.apple.os.update-ABC\n"
    check(SystemData.parseSnapshots(snapshotText) == ["com.apple.TimeMachine.2026-10-25-101010.local", "com.apple.os.update-ABC"], "스냅샷 목록 해석")
    let failing = SystemData.snapshots(runner: { _, _, _ in CommandResult(status: 1, stderr: "Operation not permitted") })
    check(failing.names == nil && failing.note?.contains("읽지 못했습니다") == true, "스냅샷: 실패하면 개수 대신 이유(권한 등)")
    let dfJSON = "{\"Active\":\"2\",\"Reclaimable\":\"812.4MB (66%)\",\"Size\":\"1.21GB\",\"TotalCount\":\"5\",\"Type\":\"Images\"}\n{\"Active\":\"1\",\"Reclaimable\":\"0B (0%)\",\"Size\":\"20.5MB\",\"TotalCount\":\"3\",\"Type\":\"Containers\"}\n"
    let parsed = SystemData.parseDockerDF(dfJSON)
    let table = SystemData.parseDockerDF("TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE\nImages          5         2         1.21GB    812.4MB (66%)\n")
    check(parsed.count == 2 && parsed[0].type == "Images" && parsed[0].reclaimable == "812.4MB (66%)" && table.first?.size == "1.21GB", "docker system df 해석(JSON·표)")
    let recorder = RunnerRecorder()
    let fakeDocker: CommandRunner = { exe, args, _ in recorder.record(exe, args); return CommandResult(status: 0, stdout: dfJSON) }
    let idle = SystemData.docker(running: RunningApps.empty, runner: fakeDocker)
    check(!idle.running && recorder.calls.isEmpty, "Docker가 꺼져 있으면 docker 명령을 부르지 않음")
    let busy = SystemData.docker(running: RunningApps(processNames: ["com.docker.backend"]), runner: fakeDocker)
    check(busy.engine == "Docker Desktop" && (busy.cli == nil || (busy.usage.count == 2 && recorder.calls.first?.1 == ["system", "df", "--format", "{{json .}}"])),
          "Docker 실행 중이면 docker system df(읽기 전용)만 부름 · \(busy.cli == nil ? "docker CLI 없음" : "행 \(busy.usage.count)개")")

    // 12) 도구 명령: 확인 명령 실패 → 실행 안 함, 미리보기는 읽기 전용 인자
    let commands = RunnerRecorder()
    let noSimctl: CommandRunner = { exe, args, _ in commands.record(exe, args); return CommandResult(status: args == ["--find", "simctl"] ? 1 : 0) }
    let blocked = ToolCommands.run(ToolCommands.simctlUnavailable, preview: false, runner: noSimctl)
    check(blocked.status == 127 && blocked.stderr.contains("Xcode가 없어") && commands.calls.allSatisfy { $0.1 == ["--find", "simctl"] }, "simctl: Xcode가 없으면 삭제 명령을 부르지 않음")
    let withSimctl: CommandRunner = { exe, args, _ in commands.record(exe, args); return CommandResult(status: 0) }
    _ = ToolCommands.run(ToolCommands.simctlUnavailable, preview: true, runner: withSimctl)
    _ = ToolCommands.run(ToolCommands.simctlUnavailable, preview: false, runner: withSimctl)
    let calls = commands.calls.map(\.1).filter { $0 != ["--find", "simctl"] }
    check(calls == [["simctl", "list", "devices", "unavailable"], ["simctl", "delete", "unavailable"]], "명령: 미리보기는 목록만, 실행은 delete unavailable")

    // 13) 실제 홈 읽기 전용 조사(아무것도 지우거나 옮기지 않는다)
    smokeScan()
}

/// 실제 홈: 등급별 합계 · 가장 큰 5곳 · 큰 파일·폴더 5개 · 시스템 데이터. 정리 API는 부르지 않는다.
func smokeScan() {
    print("— 실제 홈 읽기 전용 조사 —")
    let started = Date()
    let running = RunningApps.live()
    let scanner = DiskScanner()
    let items = scanner.scan(activeDirectories: [])
    let catalog = items.filter { $0.entryID != nil }
    print(String(format: "조사 %.1f초 · 항목 %d개(카탈로그·산출물 %d)", Date().timeIntervalSince(started), items.count, catalog.count))
    var rows: [[String: Any]] = []
    for grade in DiskGrade.allCases {
        let graded = items.filter { $0.grade == grade }
        let skipped = graded.filter { $0.skipReason != nil }
        let excluded = graded.filter(\.defaultExcluded)
        print("  등급 \(grade.rawValue)(\(grade.label)): \(graded.count)곳 · \(Fmt.gb(graded.reduce(0) { $0 + $1.bytes }))" +
              (skipped.isEmpty ? "" : " · 주인 실행 중 건너뜀 \(skipped.count)곳 \(Fmt.gb(skipped.reduce(0) { $0 + $1.bytes }))") +
              (excluded.isEmpty ? "" : " · 기본 제외 \(excluded.count)곳 \(Fmt.gb(excluded.reduce(0) { $0 + $1.bytes }))"))
        rows.append(["grade": grade.rawValue, "count": graded.count, "bytes": graded.reduce(UInt64(0)) { $0 + $1.bytes }, "skipped": skipped.count])
    }
    let ungraded = items.filter { $0.grade == nil }
    print("  등급 없음(휴지통 표시 등): \(ungraded.count)곳 · \(Fmt.gb(ungraded.reduce(0) { $0 + $1.bytes }))")
    let reasons = Set(items.compactMap(\.skipReason))
    if !reasons.isEmpty { print("  건너뛴 이유: " + reasons.sorted().joined(separator: " / ")) }
    let optimizable = items.filter { CacheDeletionPolicy.tier(for: $0, activeDirectories: [], running: running) != .trashOnly }
    print("  저장소 정리(영구 삭제) 대상: \(optimizable.count)곳 · \(Fmt.gb(optimizable.reduce(0) { $0 + $1.bytes }))")
    print("  가장 큰 5곳:")
    for item in items.filter({ $0.grade != nil }).prefix(5) {
        print("    [\(item.grade!.rawValue)] \(Fmt.size(item.bytes)) · \(abbreviate(item.path)) · \(item.note)" + (item.skipReason.map { " · \($0)" } ?? "") + (item.defaultExcluded ? " · 기본 제외" : ""))
    }
    check(!catalog.isEmpty && catalog.allSatisfy { $0.grade != nil }, "실제 홈: 카탈로그 항목 \(catalog.count)곳 모두 등급 있음")
    // 예외: 앱 오프라인 웹 데이터(apps.serviceWorker)는 기본 제외 · 휴지통 전용이라 'Service Worker' 경로를 보여 줄 수 있다(10-25 Mole 대조).
    check(!items.contains { item in item.entryID != "apps.serviceWorker" && item.path.split(separator: "/").contains { DiskCatalog.browserProtectedNames.contains(String($0)) } }
          && items.filter { $0.entryID == "apps.serviceWorker" }.allSatisfy { $0.defaultExcluded && CacheDeletionPolicy.tier(for: $0, activeDirectories: []) == .trashOnly },
          "실제 홈: 브라우저 보호 항목(Cookies 등) 없음 · Service Worker는 기본 제외·휴지통 전용만")
    check(!items.contains { $0.defaultExcluded && CacheDeletionPolicy.tier(for: $0, activeDirectories: [], running: running) != .trashOnly }, "실제 홈: 기본 제외 항목은 영구 삭제 대상이 아님")

    let finder = LargeFileFinder()
    let done = DispatchSemaphore(value: 0)
    var report = LargeFileFinder.Report()
    DispatchQueue.global(qos: .utility).async { report = finder.scan(); done.signal() }
    if done.wait(timeout: .now() + 240) == .timedOut { finder.cancel(); done.wait() }
    print(String(format: "  큰 파일 조사 %.1f초 · 파일 %d개 · 폴더 %d개 · %@%@ · 들어가지 않음: %@", report.elapsed, report.scannedFiles, report.scannedFolders, Fmt.gb(report.scannedBytes),
                 report.cancelled ? " · 시간 제한으로 중단" : "", report.skipped.joined(separator: ", ")))
    print("  큰 파일 5개:")
    for entry in report.files.prefix(5) { print("    \(Fmt.size(entry.bytes)) · \(abbreviate(entry.path))" + (entry.refusal.map { " · 옮기지 않음(\($0))" } ?? "")) }
    print("  큰 폴더 5개:")
    for entry in report.folders.prefix(5) { print("    \(Fmt.size(entry.bytes)) · \(abbreviate(entry.path))" + (entry.refusal.map { " · 옮기지 않음(\($0))" } ?? "")) }
    check(report.scannedFiles > 0 && !report.files.contains { $0.path.hasPrefix(NSHomeDirectory() + "/Library/") }, "실제 홈: 큰 파일 조사 완료 · ~/Library 제외")

    let systemStarted = Date()
    let system = SystemData.report(running: running)
    print(String(format: "  시스템 데이터 조사 %.1f초", Date().timeIntervalSince(systemStarted)))
    print("  시스템 데이터: 여유 \(Fmt.gb(system.space.available)) · 중요 용도 여유 \(Fmt.gb(system.space.importantAvailable)) · 정리 가능(purgeable) \(Fmt.gb(system.space.purgeable))")
    print("  로컬 스냅샷: " + (system.snapshots.count.map { "\($0)개(Time Machine \(system.snapshots.timeMachine) · OS 업데이트 \(system.snapshots.osUpdate))" } ?? (system.snapshots.note ?? "확인 안 됨")))
    for holder in system.holders {
        print("    보기만 · \(holder.title) \(holder.complete ? "" : "≥ ")\(Fmt.size(holder.bytes))" + (holder.logical.map { " (겉 크기 \(Fmt.size($0)))" } ?? "") +
              (holder.complete ? "" : " · 시간 제한으로 일부만") + " · \(abbreviate(holder.path))")
    }
    print("  Docker: " + (system.docker.engine.map { "\($0) 실행 중 · " + (system.docker.error ?? system.docker.usage.map { "\($0.type) \($0.size)(회수 \($0.reclaimable))" }.joined(separator: ", ")) } ?? "실행 중 아님(docker system df 생략)"))
    check(system.snapshots.names != nil, "tmutil listlocalsnapshots: 루트 없이 읽힘(\(system.snapshots.count ?? -1)개)")
    for command in ToolCommands.catalogCommands + [ToolCommands.pnpmPrune, ToolCommands.dockerPrune] {
        let available = ToolCommands.availability(command)
        print("  명령 \(command.title): " + (available.path.map { "사용 가능(\(abbreviate($0)))" } ?? (available.reason ?? "불가")))
    }
    writeEvidence("diskcatalog-smoke.json", ["grades": rows, "catalog_items": catalog.count, "large_files_scanned": report.scannedFiles, "large_elapsed": report.elapsed,
                                             "purgeable": system.space.purgeable, "snapshots": system.snapshots.count ?? -1])
}
