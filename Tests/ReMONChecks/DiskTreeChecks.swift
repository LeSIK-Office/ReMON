import Darwin
import Foundation
import ReMONCore

// 디스크 지도 검사(시험 홈) — 크기(du -sk 대조) · 번들 · 링크 · 시간 제한 · 태그 · 조치 · 금고. 실제 정리는 /private/tmp/remon-disktree 안에서만 한다
// (휴지통으로 옮긴 시험 파일은 바로 되돌린다 — 휴지통을 비우지 않는다). disktree-probe는 실제 홈을 읽기만 한다(조치 없음).

let diskTreeRoot = "/private/tmp/remon-disktree"

/// 시험용 실행기: 정해진 출력만 돌려주고 받은 명령을 적는다(진짜 docker·brew·tmutil은 부르지 않는다).
final class DiskTreeFakeTools: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[String]] = []
    var calls: [[String]] { lock.lock(); defer { lock.unlock() }; return log }
    static let dockerJSON = "{\"Active\":\"2\",\"Reclaimable\":\"812.4MB (66%)\",\"Size\":\"1.21GB\",\"TotalCount\":\"5\",\"Type\":\"Images\"}\n"
        + "{\"Active\":\"1\",\"Reclaimable\":\"0B (0%)\",\"Size\":\"20.5MB\",\"TotalCount\":\"3\",\"Type\":\"Containers\"}\n"
        + "{\"Active\":\"1\",\"Reclaimable\":\"100MB (50%)\",\"Size\":\"200MB\",\"TotalCount\":\"2\",\"Type\":\"Local Volumes\"}\n"
        + "{\"Active\":\"0\",\"Reclaimable\":\"500MB\",\"Size\":\"500MB\",\"TotalCount\":\"40\",\"Type\":\"Build Cache\"}\n"
    static let brewPreview = "==> Downloading Homebrew API data\nWarning: Skipping abseil: most recent version 20260817.0 not installed\n"
        + "Would remove: /opt/homebrew/Cellar/pcre2/10.47_1 (244 files, 7.3MB)\nWould remove: /opt/homebrew/Cellar/ripgrep/15.1.0 (14 files, 6.4MB)\n"
        + "Would remove: /Users/x/Library/Caches/Homebrew/downloads/abc--foo-1.0.tar.gz (1.5KB)\n"
        + "==> This operation would free approximately 48.4MB of disk space.\n"

    func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        lock.lock(); log.append([(executable as NSString).lastPathComponent] + arguments); lock.unlock()
        let tool = (executable as NSString).lastPathComponent
        switch (tool, arguments) {
        case ("tmutil", ["listlocalsnapshots", "/"]):
            return CommandResult(status: 0, stdout: "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-20-101010.local\ncom.apple.os.update-ABCDEF\n")
        case ("docker", ["version", "--format", "{{.Server.Version}}"]):
            return CommandResult(status: 0, stdout: "29.6.2\n")
        case ("docker", ["system", "df", "--format", "{{json .}}"]):
            return CommandResult(status: 0, stdout: Self.dockerJSON)
        case ("docker", ["system", "df"]):
            return CommandResult(status: 0, stdout: "TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE\nImages          5         2         1.21GB    812.4MB (66%)\n")
        case ("docker", ["image", "prune", "-f"]):
            return CommandResult(status: 0, stdout: "Deleted Images:\ndeleted: sha256:abc\n\nTotal reclaimed space: 1.2GB\n")
        case ("docker", ["builder", "prune", "-f"]):
            return CommandResult(status: 0, stdout: "Total reclaimed space: 500MB\n")
        case ("brew", ["cleanup", "-n", "--prune=all"]):
            return CommandResult(status: 0, stdout: Self.brewPreview)
        case ("brew", ["cleanup", "--prune=all"]):
            return CommandResult(status: 0, stdout: "Removing: /opt/homebrew/Cellar/pcre2/10.47_1... (244 files, 7.3MB)\n==> This operation has freed approximately 48.4MB of disk space.\n")
        default:
            return CommandResult(status: 99, stderr: "시험 실행기가 모르는 명령: \(tool) \(arguments.joined(separator: " "))")
        }
    }
}

/// 시험용 .DS_Store(Bud1 + B-트리 잎 하나): 휴지통 '되돌려 놓기' 기록(ptbN·ptbL).
func makeDSStore(_ records: [(file: String, code: String, value: String)]) -> Data {
    func be32(_ value: Int) -> [UInt8] { [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)] }
    func utf16(_ text: String) -> [UInt8] { text.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xff)] } }
    var leaf = be32(0) + be32(records.count)
    for record in records.sorted(by: { ($0.file, $0.code) < ($1.file, $1.code) }) {
        leaf += be32(record.file.utf16.count) + utf16(record.file) + Array(record.code.utf8) + Array("ustr".utf8) + be32(record.value.utf16.count) + utf16(record.value)
    }
    // 블록(주소 = 오프셋 | log2(크기), 파일 위치 = 오프셋 + 4): DSDB 32바이트 @64 · 할당 루트 2048바이트 @2048 · 잎 4096바이트 @4096
    var file = [UInt8](repeating: 0, count: 4 + 8192)
    func put(_ bytes: [UInt8], at offset: Int) { for (index, byte) in bytes.enumerated() { file[offset + index] = byte } }
    put(be32(1) + Array("Bud1".utf8) + be32(2048) + be32(2048) + be32(2048), at: 0)
    var root = be32(3) + be32(0) + be32(2048 | 11) + be32(64 | 5) + be32(4096 | 12)
    root += [UInt8](repeating: 0, count: (256 - 3) * 4)
    root += be32(1) + [4] + Array("DSDB".utf8) + be32(1)
    put(root, at: 2048 + 4)
    put(be32(2) + be32(0) + be32(records.count) + be32(1) + be32(0x1000), at: 64 + 4)
    put(leaf, at: 4096 + 4)
    return Data(file)
}

/// du -sk(KiB). 실패하면 nil.
func duKilobytes(_ path: String) -> UInt64? {
    let result = Shell.capture("/usr/bin/du", ["-sk", path], timeout: 60)
    guard result.succeeded else { return nil }
    return result.stdout.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.flatMap { UInt64($0) }
}

/// 폴더 아래 전부(폴더 포함)의 수정 시각을 바꾼다(파일을 쓴 뒤 — 폴더 시각은 안에 쓰면 바뀌므로 마지막에).
func ageTree(_ path: String, days: Double) {
    let date = Date().addingTimeInterval(-days * 86_400)
    var items = [path]
    if let enumerator = FileManager.default.enumerator(atPath: path) { while let relative = enumerator.nextObject() as? String { items.append(path + "/" + relative) } }
    for item in items.reversed() { try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item) }
}

func diskTreeCheck() {
    setvbuf(stdout, nil, _IOLBF, 0)
    let fm = FileManager.default
    let root = diskTreeRoot
    try? fm.removeItem(atPath: root)
    try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    let home = root + "/home"
    let kb = 1024, mb = 1024 * 1024
    let audit = AuditLog(url: URL(fileURLWithPath: root + "/actions.jsonl"))
    let vault = RecoveryVault(folder: URL(fileURLWithPath: root + "/vault"))
    vault.audit = audit

    // 1) 시험 홈
    for (index, size) in [3 * mb / 2, 700 * kb, 300 * kb].enumerated() { writeBytes(home + "/DEV/proj/src/file\(index).bin", size) }
    writeBytes(home + "/DEV/proj/docs/guide.md", 64 * kb)
    writeBytes(home + "/DEV/proj/package-lock.json", 4 * kb)
    writeBytes(home + "/DEV/proj/node_modules/pkg/index.js", 900 * kb)
    writeBytes(home + "/DEV/proj/node_modules/pkg/lib/util.js", 300 * kb)
    ageTree(home + "/DEV/proj/node_modules", days: 3)
    writeBytes(home + "/DEV/fresh/package-lock.json", 4 * kb)
    writeBytes(home + "/DEV/fresh/node_modules/pkg/index.js", 200 * kb)
    writeBytes(home + "/Documents/report.pdf", 2 * mb)
    writeBytes(home + "/Documents/notes/a.txt", 600 * kb)
    writeBytes(home + "/Documents/hard/a.bin", 2 * mb)
    link(home + "/Documents/hard/a.bin", home + "/Documents/hard/b.bin")
    writeBytes(root + "/outside/big.bin", 5 * mb)
    try? fm.createSymbolicLink(atPath: home + "/Documents/outside-link", withDestinationPath: root + "/outside")
    writeBytes(home + "/Applications/Tool.app/Contents/MacOS/tool", mb)
    writeBytes(home + "/Applications/Tool.app/Contents/Resources/data", 2 * mb)
    (["CFBundleIdentifier": "com.example.tool"] as NSDictionary).write(toFile: home + "/Applications/Tool.app/Contents/Info.plist", atomically: true)
    // 앱 데이터: 설치된 앱(Tool) · 지운 앱(GoneApp)의 찌꺼기 · 설정 파일
    writeBytes(home + "/Library/Application Support/Tool/state.db", 64 * kb)
    writeBytes(home + "/Library/Application Support/GoneApp/cache.db", 64 * kb)
    writeBytes(home + "/Library/Preferences/com.example.tool.plist", 4 * kb)
    writeBytes(home + "/Library/Preferences/com.gone.app.plist", 4 * kb)
    writeBytes(home + "/Library/Containers/com.example.tool/Data/x", 4 * kb)
    writeBytes(home + "/.npm/_cacache/content-v2/sha512/aa", mb)
    writeBytes(home + "/Library/Caches/com.apple.fakeagent/blob", 64 * kb)
    writeBytes(home + "/Library/Caches/my-tool/blob", 6 * mb)
    writeBytes(home + "/.claude/projects/-tmp-x/11111111-2222-3333-4444-555555555555.jsonl", 8 * kb)
    // 다운로드: 오래되고 큰 것 · 새로 받은 큰 것 · 오래된 작은 것
    let day: TimeInterval = 86_400
    writeBytes(home + "/Downloads/old-installer.dmg", 51 * mb, modified: Date().addingTimeInterval(-40 * day))
    writeBytes(home + "/Downloads/new-big.zip", 51 * mb)
    writeBytes(home + "/Downloads/old-small.txt", kb, modified: Date().addingTimeInterval(-40 * day))
    // 휴지통 + 되돌려 놓기 기록(.DS_Store)
    writeBytes(home + "/.Trash/renamed 10.23.45.txt", 8 * kb)
    writeBytes(home + "/.Trash/plain.txt", 8 * kb)
    let trashedFrom = String((home + "/Documents/").dropFirst())
    fm.createFile(atPath: home + "/.Trash/.DS_Store", contents: makeDSStore([("renamed 10.23.45.txt", "ptbN", "원래이름.txt"), ("renamed 10.23.45.txt", "ptbL", trashedFrom),
                                                                             ("plain.txt", "ptbL", trashedFrom)]))
    // 임시(T) · 캐시(C)
    let user = root + "/var/folders/ab/cdef0123"
    let temp = user + "/T", cache = user + "/C"
    writeBytes(temp + "/old-dir/inner.txt", 64 * kb)
    ageTree(temp + "/old-dir", days: 10)
    writeBytes(temp + "/fresh.txt", 8 * kb)
    writeBytes(temp + "/com.apple.fakeservice/state", 8 * kb)
    ageTree(temp + "/com.apple.fakeservice", days: 10)
    writeBytes(temp + "/open.log", 8 * kb, modified: Date().addingTimeInterval(-10 * day))
    writeBytes(cache + "/org.example.tool/blob", 64 * kb)
    ageTree(cache + "/org.example.tool", days: 10)
    writeBytes(cache + "/com.apple.cachey/blob", 8 * kb)
    ageTree(cache + "/com.apple.cachey", days: 10)
    // Xcode: 시뮬레이터 기기(오래됨 · 최근 부팅 · 실행 중) · 아카이브
    let devices = home + "/Library/Developer/CoreSimulator/Devices"
    func device(_ udid: String, name: String, state: Int, lastBooted: Date?, createdDaysAgo: Double) {
        var plist: [String: Any] = ["name": name, "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "state": state, "UDID": udid]
        if let lastBooted { plist["lastBootedAt"] = lastBooted }
        try? fm.createDirectory(atPath: devices + "/" + udid + "/data/Library", withIntermediateDirectories: true)
        writeBytes(devices + "/" + udid + "/data/Library/state.db", 64 * kb)
        (plist as NSDictionary).write(toFile: devices + "/" + udid + "/device.plist", atomically: true)
        setModified(devices + "/" + udid + "/device.plist", Date().addingTimeInterval(-createdDaysAgo * day))
    }
    device("AAAAAAAA-0000-0000-0000-000000000001", name: "iPhone Old", state: 1, lastBooted: nil, createdDaysAgo: 120)
    device("AAAAAAAA-0000-0000-0000-000000000002", name: "iPhone Recent", state: 1, lastBooted: Date().addingTimeInterval(-10 * day), createdDaysAgo: 200)
    device("AAAAAAAA-0000-0000-0000-000000000003", name: "iPhone Booted", state: 3, lastBooted: Date().addingTimeInterval(-200 * day), createdDaysAgo: 300)
    writeBytes(home + "/Library/Developer/Xcode/Archives/2026-01-01/App 1.xcarchive/Info.plist", 8 * kb)
    // 기기 백업
    let backupFolder = home + "/Library/Application Support/MobileSync/Backup/00008110-TEST"
    writeBytes(backupFolder + "/Manifest.db", 64 * kb)
    (["Device Name": "테스트 아이폰", "Product Type": "iPhone15,2", "Last Backup Date": Date().addingTimeInterval(-40 * day)] as NSDictionary).write(toFile: backupFolder + "/Info.plist", atomically: true)
    // 스왑·잠자기 이미지(가짜 볼륨 폴더)
    writeBytes(root + "/vm/swapfile0", mb)
    writeBytes(root + "/varvm/sleepimage", mb)
    // 많은 폴더(시간 제한 시험)
    for index in 0..<1_500 { writeBytes(root + "/many/d\(index / 50)/e\(index)/f.txt", 4 * kb) }
    // docker·brew를 찾게 하는 빈 실행 파일(실행되지 않는다 — 시험 실행기가 가로챈다)
    for tool in ["docker", "brew"] {
        writeBytes(home + "/.local/bin/" + tool, 16)
        chmod(home + "/.local/bin/" + tool, 0o755)
    }

    let tools = DiskTreeFakeTools()
    let scanner = DiskTreeScanner(home: home)
    scanner.temporaryFolders = [temp]
    scanner.cacheFolders = [cache]
    scanner.vmFolder = root + "/vm"
    scanner.sleepImageFolder = root + "/varvm"
    scanner.runningProbe = { RunningApps.empty }
    scanner.activeDirectoriesProbe = { [] }
    scanner.executablesProbe = { [] }
    scanner.userPIDsProbe = { [getpid()] }
    scanner.measuresOtherAppData = true
    scanner.applicationFolders = [home + "/Applications"]
    scanner.commandRunner = { executable, arguments, _ in tools.run(executable, arguments) }
    let openHandle = FileHandle(forReadingAtPath: temp + "/open.log")

    // 2) 크기: du -sk와 1% 안 · 번들은 한 칸 · 링크는 따라가지 않음 · 하드링크는 한 번
    let roots = [home + "/DEV", home + "/Documents", home + "/Applications", home + "/Downloads", home + "/.npm"]
    let scanned = scanner.scan(roots: roots, budget: 20)
    let firstReport = scanner.lastReport
    var byPath: [String: DiskNode] = [:]
    for node in scanned {
        byPath[node.path] = node
        for child in node.children ?? [] { byPath[child.path] = child }
    }
    func node(_ path: String) -> DiskNode? { byPath[path] }
    var compared = 0, mismatches: [String] = []
    for path in roots + [home + "/DEV/proj", home + "/DEV/fresh", home + "/Documents/notes", home + "/Documents/hard", home + "/Applications/Tool.app"] {
        guard let measured = node(path), let reference = duKilobytes(path) else { mismatches.append(path + " 없음"); continue }
        compared += 1
        let ours = Double(measured.bytes) / 1024
        if abs(ours - Double(reference)) > max(Double(reference) * 0.01, 4) { mismatches.append("\(abbreviate(path)) \(Int(ours))KB vs du \(reference)KB") }
    }
    check(mismatches.isEmpty && compared == 10, "크기: du -sk와 1% 안 \(compared)곳" + (mismatches.isEmpty ? "" : " · 어긋남 \(mismatches.joined(separator: ", "))"))
    check(firstReport.complete && !scanned.contains(where: \.partial), "시간 제한 안에 끝까지 셈(partial 없음) · 폴더 \(firstReport.directories)개 · 파일 \(firstReport.files)개")
    let tool = node(home + "/Applications/Tool.app")
    check(tool?.isDirectory == false && tool?.children == [] && tool?.tags.contains(.bundle) == true && (tool?.fileCount ?? 0) == 3,
          "번들(.app)은 한 칸: 펼치지 않음 · 크기·파일 수는 안까지(\(Fmt.size(tool?.bytes ?? 0)), 파일 \(tool?.fileCount ?? 0)개)")
    let documents = node(home + "/Documents"), outsideLink = node(home + "/Documents/outside-link")
    check(outsideLink?.isDirectory == false && (outsideLink?.bytes ?? .max) < 64 * 1024 && (documents?.bytes ?? .max) < 5 * UInt64(mb) + allocated(home + "/Documents/report.pdf")
          && outsideLink?.hint?.contains("링크") == true, "링크는 따라가지 않음: 바깥 5MB가 Documents 크기에 들지 않음 · 링크 칸은 잎(\(outsideLink?.bytes ?? 0)바이트)")
    let hard = node(home + "/Documents/hard")
    check(hard?.bytes == allocated(home + "/Documents/hard/a.bin") && hard?.fileCount == 2, "하드링크: 같은 파일 두 이름을 한 번만 셈(\(Fmt.size(hard?.bytes ?? 0)))")

    // 3) 태그 · 조치
    let cacheNode = node(home + "/.npm/_cacache")
    check(cacheNode?.tags.contains(.cache) == true && cacheNode?.actions.contains(.deletePermanently) == true && cacheNode?.isSafeToDeletePermanently == true,
          "가짜 캐시(npm, 등급 A): 캐시 · 영구 삭제 가능 [\(cacheNode?.actions.map(\.rawValue).joined(separator: ",") ?? "-")]")
    let proj = scanner.expand(node(home + "/DEV/proj")!, budget: 10)
    let modules = proj.children?.first { $0.name == "node_modules" }
    let freshModules = scanner.expand(node(home + "/DEV/fresh")!, budget: 10).children?.first { $0.name == "node_modules" }
    check(modules?.tags == [.regenerable] && modules?.actions == [.reveal, .trash, .deletePermanently] && freshModules?.actions == [.reveal, .trash],
          "node_modules(B): 쉬는 것(잠금 파일 · 3일 전)은 영구 삭제 가능 · 방금 바뀐 것은 휴지통만")
    // 큰 node_modules(2만 항목 넘음): 조사 때 영구 삭제 가능이면 정리 직전 재판정도 같아야 한다(최근 수정 시각을 끝까지 본다).
    let bigModules = home + "/DEV/big/node_modules"
    writeBytes(home + "/DEV/big/package-lock.json", 4 * kb)
    for folder in 0..<210 {
        try? fm.createDirectory(atPath: bigModules + "/p\(folder)", withIntermediateDirectories: true)
        for file in 0..<100 { fm.createFile(atPath: bigModules + "/p\(folder)/f\(file).js", contents: nil) }
    }
    ageTree(bigModules, days: 3)
    let bigLevel = scanner.scan(roots: [home + "/DEV/big"], budget: 20).first?.children?.first { $0.name == "node_modules" }
    let bigDry = bigLevel.map { DiskTreeActions.perform(.deletePermanently, on: $0, dryRun: true, vault: vault, userPIDs: [], environment: scanner.actionEnvironment(audit: audit)) }
    check(bigLevel?.actions.contains(.deletePermanently) == true && bigDry?.ok == true && bigDry?.refused == false && fm.fileExists(atPath: bigModules),
          "큰 node_modules(파일 \(bigLevel?.fileCount ?? 0)개): 조사·정리 직전 재판정이 같음(드라이런 통과 · \(bigDry?.message ?? "-"))")
    let report = documents?.children?.first { $0.name == "report.pdf" }
    check(report?.tags == [.userFile] && report?.actions == [.reveal, .trash] && report?.isSafeToDeletePermanently == false, "사용자 파일: 휴지통만(영구 삭제 없음)")
    let dmg = node(home + "/Downloads/old-installer.dmg"), newZip = node(home + "/Downloads/new-big.zip"), oldSmall = node(home + "/Downloads/old-small.txt")
    check(dmg?.tags == [.download, .large] && dmg?.actions == [.reveal, .trash] && newZip?.tags == [.download, .userFile] && oldSmall?.tags == [.download, .userFile],
          "다운로드: 30일 넘고 50MB 넘는 것만 '다운로드·큰 파일'(새로 받은 큰 것 · 오래된 작은 것은 사용자 파일)")
    let tempLevel = scanner.scan(roots: [temp, cache], budget: 10)
    func tempChild(_ name: String) -> DiskNode? { tempLevel.flatMap { $0.children ?? [] }.first { $0.name == name } }
    check(tempChild("old-dir")?.tags == [.temp] && tempChild("old-dir")?.actions == [.reveal, .trash] && tempChild("fresh.txt")?.actions == [.reveal]
          && tempChild("com.apple.fakeservice")?.actions == [.reveal], "임시: 7일 넘고 연 프로그램 없는 것만 휴지통 · 새것·macOS 서비스 몫은 보기만")
    check(tempChild("open.log")?.actions == [.reveal] && tempChild("open.log")?.hint?.contains("pid \(getpid())") == true,
          "임시: 오래됐어도 열어 둔 프로그램이 있으면 그대로(pid \(getpid()) — SafeFileOps와 같은 열린 파일 확인)")
    check(tempChild("org.example.tool")?.tags == [.cache] && tempChild("org.example.tool")?.actions == [.reveal, .deletePermanently] && tempChild("com.apple.cachey")?.actions == [.none],
          "사용자 캐시(C): 7일 넘은 것은 캐시 A(영구 삭제) · com.apple.*은 보기만")
    try? openHandle?.close()
    let trashLevel = scanner.scan(roots: [home + "/.Trash"], budget: 10).first
    let renamed = trashLevel?.children?.first { $0.path.hasSuffix("renamed 10.23.45.txt") }, plain = trashLevel?.children?.first { $0.path.hasSuffix("plain.txt") }
    check(trashLevel?.tags == [.trash] && renamed?.tags == [.trash] && renamed?.actions == [.reveal] && renamed?.name == "원래이름.txt" && renamed?.hint?.contains("~/Documents") == true
          && plain?.hint?.contains("~/Documents") == true, "휴지통 안: 보기만 · 원래 이름('\(renamed?.name ?? "-")')·원래 위치(.DS_Store 되돌려 놓기 기록) · 비우기는 Finder")
    let parsedStore = TrashPutBack.parse(makeDSStore([("x.txt", "ptbN", "y.txt"), ("x.txt", "ptbL", "System/Volumes/Data/Users/u/Desktop/")]))
    check(parsedStore["x.txt"] == TrashPutBack.Origin(name: "y.txt", folder: "/Users/u/Desktop") && TrashPutBack.parse(Data("garbage".utf8)).isEmpty,
          ".DS_Store 해석: /System/Volumes/Data 접두를 뗀 원래 폴더 · 깨진 파일은 빈 결과")

    // 4) Xcode · 백업 · AI 기록 · 시스템 · 스왑
    let deviceLevel = scanner.scan(roots: [devices], budget: 10).first?.children ?? []
    func sim(_ name: String) -> DiskNode? { deviceLevel.first { $0.name.hasPrefix(name) } }
    check(sim("iPhone Old")?.tags == [.xcode, .regenerable] && sim("iPhone Old")?.actions == [.reveal, .trash] && sim("iPhone Old")?.name == "iPhone Old · iOS 26.5"
          && sim("iPhone Recent")?.actions == [.reveal] && sim("iPhone Booted")?.actions == [.reveal],
          "시뮬레이터: 90일 넘게 안 쓴 기기만 휴지통(다시 만들 수 있음) · 최근 부팅·실행 중은 보기만 · 이름은 device.plist에서")
    let archive = scanner.describe(home + "/Library/Developer/Xcode/Archives/2026-01-01/App 1.xcarchive")
    check(archive?.tags == [.xcode, .userFile, .bundle] && archive?.actions == [.reveal, .trash], "Xcode 아카이브: 사용자 산출물 · 휴지통만(번들 한 칸)")
    let backup = scanner.describe(backupFolder)
    check(backup?.tags == [.backup] && backup?.actions == [.reveal, .trash] && backup?.name == "테스트 아이폰" && backup?.hint?.contains("40일 전") == true,
          "기기 백업: Info.plist의 기기 이름·마지막 백업 날짜 · 휴지통(확인 뒤)")
    let transcript = scanner.describe(home + "/.claude/projects/-tmp-x/11111111-2222-3333-4444-555555555555.jsonl")
    check(transcript?.tags == [.aiTranscript] && transcript?.actions == [.none], "AI 대화 기록: 보기만(조치 없음)")
    let installedData = scanner.describe(home + "/Library/Application Support/Tool"), leftoverData = scanner.describe(home + "/Library/Application Support/GoneApp")
    let installedPrefs = scanner.describe(home + "/Library/Preferences/com.example.tool.plist"), leftoverPrefs = scanner.describe(home + "/Library/Preferences/com.gone.app.plist")
    let installedContainer = scanner.describe(home + "/Library/Containers/com.example.tool")
    check(installedData?.actions == [.reveal] && installedPrefs?.actions == [.reveal] && installedContainer?.actions == [.reveal]
          && leftoverData?.actions == [.reveal, .trash] && leftoverData?.hint?.contains("찌꺼기") == true && leftoverPrefs?.actions == [.reveal, .trash],
          "앱 데이터: 설치된 앱(Tool.app · 번들 id)의 데이터·설정·보관함은 보기만 · 찾지 못한 앱의 찌꺼기만 휴지통")
    let appleCache = scanner.describe(home + "/Library/Caches/com.apple.fakeagent"), toolCache = scanner.describe(home + "/Library/Caches/my-tool")
    check(appleCache?.actions == [.none] && toolCache?.tags == [.cache] && toolCache?.actions == [.reveal, .deletePermanently], "Library/Caches: macOS 캐시(C)는 보기만 · 일반 앱 캐시(A)는 영구 삭제")
    let swapLevel = scanner.scan(roots: [root + "/varvm"], budget: 5).first
    check(swapLevel?.tags == [.swap, .system] && swapLevel?.children?.contains { $0.path == root + "/vm/swapfile0" && $0.tags == [.swap] && $0.actions == [.none] } == true
          && swapLevel?.hint?.contains("스왑") == true, "스왑: 잠자기 이미지 폴더 아래에 스왑 볼륨의 파일까지 · 보기만(vm.swapusage 설명)")
    let system = scanner.describe("/Applications")
    check(system?.tags == [.system] && system?.actions.contains(.trash) == false, "홈 밖 시스템 영역(/Applications 자체): 보기만")
    if FileManager.default.fileExists(atPath: "/System/Volumes/VM/swapfile0") {
        let real = DiskTreeScanner().describe("/System/Volumes/VM/swapfile0")
        check(real?.tags.contains(.swap) == true && real?.actions == [.none] && real?.isSafeToDeletePermanently == false,
              "실제 스왑 파일(/System/Volumes/VM): 스왑 · 보기만(읽기 전용 판정) [\(real?.tags.map(\.rawValue).sorted().joined(separator: ",") ?? "-")]")
    }

    // 5) 시간 제한 → partial, 캐시는 남기지 않는다
    let starved = scanner.scan(roots: [root + "/many"], budget: 0.000_001).first
    check(starved?.partial == true && starved?.children?.contains(where: \.partial) == true && scanner.lastReport.complete == false,
          "시간 제한: 끝까지 못 센 칸은 partial(하한값 \(Fmt.size(starved?.bytes ?? 0)))")
    let full = scanner.scan(roots: [root + "/many"], budget: 20).first
    check(full?.partial == false && duKilobytes(root + "/many").map { abs(Double(full?.bytes ?? 0) / 1024 - Double($0)) <= max(Double($0) * 0.01, 4) } == true,
          "시간을 주면 다시 끝까지(partial 결과는 캐시하지 않음) · 폴더 \(scanner.lastReport.directories)개")
    // 다른 볼륨: /System/Volumes 아래 VM 볼륨은 세지 않는다(데이터 볼륨은 시간 제한으로 일부만 — 읽기 전용).
    let volumes = DiskTreeScanner().scan(roots: ["/System/Volumes"], budget: 0.3).first
    if let vm = volumes?.children?.first(where: { $0.name == "VM" }) {
        check(vm.bytes == 0 && vm.hint?.contains("다른 볼륨") == true, "다른 볼륨(마운트 지점)은 세지 않음: /System/Volumes/VM")
    } else {
        print("SKIP /System/Volumes/VM 없음")
    }

    // 취소: 실제 ~/Library를 읽다가(읽기 전용) 0.2초 뒤 cancel() → 곧 멈추고 partial로 돌아온다.
    let cancelScanner = DiskTreeScanner()
    let cancelStarted = Date()
    let cancelTimer = DispatchQueue.global()
    cancelTimer.asyncAfter(deadline: .now() + 0.2) { cancelScanner.cancel() }
    let cancelled = cancelScanner.scan(roots: [NSHomeDirectory() + "/Library"], budget: 60).first
    let cancelElapsed = Date().timeIntervalSince(cancelStarted)
    if cancelElapsed < 0.2 {
        print("SKIP 취소: ~/Library가 0.2초 안에 끝남")
    } else {
        check(cancelled?.partial == true && cancelElapsed < 5, String(format: "취소: cancel() 뒤 곧 멈춤(%.2f초 · partial)", cancelElapsed))
    }

    // 6) 캐시: 펼치기는 형제를 다시 재지 않는다 · 바뀐 폴더만 다시 잰다 · invalidate
    _ = scanner.scan(roots: [home + "/DEV"], budget: 10)
    let projNode = scanner.scan(roots: [home + "/DEV"], budget: 10).first?.children?.first { $0.name == "proj" }
    _ = scanner.expand(projNode!, budget: 10)
    let warm = scanner.lastReport
    writeBytes(home + "/DEV/proj/src/added.bin", 100 * kb)
    _ = scanner.expand(projNode!, budget: 10)
    let changed = scanner.lastReport
    scanner.invalidate(home + "/DEV/proj")
    _ = scanner.expand(projNode!, budget: 10)
    let invalidated = scanner.lastReport
    check(warm.measured == 0 && warm.cacheHits >= 3 && changed.measured == 1 && invalidated.measured >= 3,
          "캐시: 펼치기는 조사 없이(캐시 \(warm.cacheHits)칸) · 바뀐 폴더만 다시(\(changed.measured)칸) · invalidate 뒤 전부 다시(\(invalidated.measured)칸)")

    // 7) 조치: 영구 삭제 거절 · 휴지통(금고 → 되돌리기) · 캐시 영구 삭제(금고 '지움')
    let environment = scanner.actionEnvironment(audit: audit)
    guard let report else { check(false, "report.pdf 칸 없음"); return }
    var forged = report
    forged.actions = [.reveal, .trash, .deletePermanently]
    let refused = DiskTreeActions.perform(.deletePermanently, on: forged, dryRun: false, vault: vault, userPIDs: [], environment: environment)
    let transcriptRefused = transcript.map { DiskTreeActions.perform(.deletePermanently, on: $0, dryRun: false, vault: vault, userPIDs: [], environment: environment) }
    let swapRefused = swapLevel.map { DiskTreeActions.perform(.deletePermanently, on: $0, dryRun: false, vault: vault, userPIDs: [], environment: environment) }
    check(refused.refused && refused.message.contains("사용자 파일") && fm.fileExists(atPath: report.path) && transcriptRefused?.refused == true && transcriptRefused?.message.contains("AI 대화") == true
          && swapRefused?.refused == true && vault.all().isEmpty, "영구 삭제 거절: 사용자 파일(조치 목록을 꾸며도) · AI 기록 · 스왑 — 이유를 말하고 아무것도 안 함")
    // 손으로 만든 칸(캐시라고 꾸민 사용자 파일)도 정리 직전 규칙으로 다시 판정해 막는다 — 환경이 재판정기를 안 줘도.
    let disguised = DiskNode(path: home + "/Documents/notes/a.txt", bytes: 600 * 1024, isDirectory: false, children: [], tags: [.cache], actions: [.reveal, .deletePermanently])
    let disguisedResult = DiskTreeActions.perform(.deletePermanently, on: disguised, dryRun: false, vault: vault, userPIDs: [], environment: DiskTreeActions.Environment(audit: audit))
    check(disguisedResult.refused && fm.fileExists(atPath: disguised.path) && vault.all().isEmpty, "꾸민 칸의 영구 삭제도 거절(기본 재판정 · \(disguisedResult.message.prefix(40))…)")
    let runningScanner = DiskTreeScanner(home: home)
    runningScanner.runningProbe = { RunningApps(appNames: ["tool"]) }
    runningScanner.applicationFolders = [home + "/Applications"]
    let runningApp = runningScanner.describe(home + "/Applications/Tool.app")
    check(runningApp?.actions == [.reveal] && runningApp?.hint?.contains("실행 중") == true, "실행 중인 앱 번들은 휴지통 조치 없음(위치와 상관없이)")
    let dry = DiskTreeActions.perform(.trash, on: report, dryRun: true, vault: vault, userPIDs: [], environment: environment)
    check(dry.ok && dry.dryRun && fm.fileExists(atPath: report.path) && vault.all().isEmpty, "휴지통 드라이런: 그대로 · 금고 기록 없음")
    let trashed = DiskTreeActions.perform(.trash, on: report, dryRun: false, vault: vault, userPIDs: [], environment: environment)
    let entry = vault.all().first { $0.id == trashed.vaultEntryID }
    check(trashed.ok && !fm.fileExists(atPath: report.path) && entry?.kind == .trash && entry?.status == .held && entry?.originalPath == report.path
          && entry?.trashedPath.map(fm.fileExists(atPath:)) == true, "휴지통: 금고에 원래 자리·휴지통 위치(보관 중) · \(entry?.title ?? "-")")
    let restored = entry.map { RecoveryRestorer.restoreTrash($0, vault: vault) }
    check(restored?.ok == true && fm.fileExists(atPath: report.path) && vault.entry(entry?.id ?? "")?.status == .restored, "되돌리기: RecoveryRestorer.restoreTrash로 원래 자리")
    if let cacheNode {
        let deleted = DiskTreeActions.perform(.deletePermanently, on: cacheNode, dryRun: false, vault: vault, userPIDs: [], environment: environment)
        let gone = vault.all().first { $0.id == deleted.vaultEntryID }
        check(deleted.ok && !fm.fileExists(atPath: cacheNode.path) && gone?.kind == .deleted && gone?.status == .gone && gone?.restorable == false && gone?.restoreHint == cacheNode.hint,
              "캐시 영구 삭제: 금고에 '지움'(되돌릴 수 없음 · 재생성 방법) 먼저")
    }
    let systemTrash = DiskTreeActions.perform(.trash, on: transcript!, dryRun: false, vault: vault, userPIDs: [], environment: environment)
    check(systemTrash.refused && fm.fileExists(atPath: transcript!.path), "AI 기록은 휴지통 조치도 거절(허용 조치 아님)")

    // 8) 큰 파일: 번들은 한 덩어리 · 번들 안 파일은 없음 · 종류 · 사용자 파일만 휴지통
    let large = scanner.largeFiles(under: [home], minimumBytes: UInt64(mb), budget: 10)
    let largeNames = large.map { ($0.path as NSString).lastPathComponent }
    let dmgLarge = large.first { $0.path.hasSuffix("old-installer.dmg") }
    check(largeNames.first == "old-installer.dmg" || largeNames.first == "new-big.zip", "큰 파일: 큰 것부터 \(largeNames.prefix(4).joined(separator: " > "))")
    check(large.contains { $0.path.hasSuffix("Tool.app") && $0.tags.contains(.bundle) } && !large.contains { $0.path.contains("Tool.app/") }
          && large.filter { $0.path.hasSuffix(".bin") && $0.path.contains("/hard/") }.count == 1, "큰 파일: 번들은 한 덩어리 · 번들 안 파일 없음 · 하드링크 한 번")
    check(dmgLarge?.tags.contains(.large) == true && dmgLarge?.hint?.contains("디스크 이미지") == true && large.allSatisfy { $0.tags.contains(.large) }
          && large.first { $0.path.hasSuffix("report.pdf") }?.actions == [.reveal, .trash] && large.allSatisfy { $0.actions.contains(.trash) == !$0.tags.isDisjoint(with: [.userFile, .download]) },
          "큰 파일: 종류(디스크 이미지 …) · 기본 조치는 보기 · 사용자 파일만 휴지통")

    // 9) Docker·Homebrew 해석(가짜 출력 — 엔진 없이)
    check(DockerDiskUsage.bytes("1.21GB") == 1_210_000_000 && DockerDiskUsage.bytes("812.4MB (66%)") == 812_400_000 && DockerDiskUsage.bytes("0B") == 0
          && DockerDiskUsage.reclaimed("Deleted: x\nTotal reclaimed space: 1.2GB\n") == 1_200_000_000, "docker 크기 해석(1000 단위) · prune 회수량")
    let preview = HomebrewPreview.parse(DiskTreeFakeTools.brewPreview)
    check(preview.items.count == 3 && preview.items[0] == HomebrewPreview.Item(path: "/opt/homebrew/Cellar/pcre2/10.47_1", files: 244, bytes: UInt64(7.3 * 1_048_576))
          && preview.items[2].files == nil && preview.total == UInt64(48.4 * 1_048_576), "brew cleanup -n 해석: 지울 경로 3개 · 파일 수 · 크기 · 합계")

    // 10) 묶음 보기(가짜 docker·brew·tmutil · 시험 저장소의 git 부산물)
    let git = LeftoverTools.findGit()
    let repo = home + "/DEV/app", worktreePath = home + "/DEV/app-done"
    var gitFailures = 0
    @discardableResult func g(_ arguments: [String]) -> CommandResult {
        let result = setupGit(git, arguments)
        if !result.succeeded { gitFailures += 1; print("  준비 실패: git \(arguments.joined(separator: " ")) → \(result.stderr.prefix(160))") }
        return result
    }
    g(["init", "-q", "-b", "main", repo])
    g(["-C", repo, "config", "user.name", "ReMON Check"])
    g(["-C", repo, "config", "user.email", "check@remon.invalid"])
    writeBytes(repo + "/README.md", 64)
    g(["-C", repo, "add", "-A"]); g(["-C", repo, "commit", "-q", "-m", "c1"])
    g(["-C", repo, "checkout", "-q", "-b", "feature/merged"])
    writeBytes(repo + "/merged.txt", 64)
    g(["-C", repo, "add", "-A"]); g(["-C", repo, "commit", "-q", "-m", "c2"])
    g(["-C", repo, "checkout", "-q", "main"])
    g(["-C", repo, "merge", "-q", "--no-ff", "-m", "merge", "feature/merged"])
    g(["-C", repo, "worktree", "add", "-q", "-b", "wt/done", worktreePath, "main"])
    scanner.devRoot = home + "/DEV"
    scanner.leftoverTools = LeftoverTools(git: git, orca: nil)
    var options = LeftoverScanOptions()
    options.codexWorktreesRoot = root + "/codex-worktrees"
    options.projectName = { _ in "disktree" }
    scanner.leftoverOptions = options
    scanner.refreshGit(budget: 20)
    let categories = scanner.categories(budget: 30)
    func category(_ id: String) -> DiskNode? { categories.first { $0.path == DiskNodeVirtual.path("category", id) || $0.path == DiskNodeVirtual.path(id, "cleanup") } }
    let snapshotCategory = category("snapshot"), dockerCategory = category("docker"), brewCategory = category("homebrew"), gitCategory = category("git")
    check(gitFailures == 0 && categories.count == 10, "묶음 보기: 10묶음(스왑·스냅샷·휴지통·임시·다운로드·Docker·Xcode·Homebrew·백업·git)")
    check(snapshotCategory?.children?.count == 2 && snapshotCategory?.children?.allSatisfy { $0.tags == [.snapshot] && $0.actions == [.none] && ($0.hint ?? "").contains("tmutil thinlocalsnapshots") } == true
          && snapshotCategory?.children?.first?.isVirtual == true, "로컬 스냅샷: tmutil 목록 → 보기만 · thinlocalsnapshots 명령 안내")
    let images = dockerCategory?.children?.first { $0.path == DiskNodeVirtual.path("docker", "images") }
    let volumesRow = dockerCategory?.children?.first { $0.path == DiskNodeVirtual.path("docker", "local-volumes") }
    check(images?.bytes == 1_210_000_000 && images?.actions == [.prune] && images?.hint?.contains("docker image prune -f") == true && volumesRow?.actions == [.none]
          && dockerCategory?.children?.contains(where: { $0.path == DiskNodeVirtual.path("docker", "build-cache") && $0.actions == [.prune] }) == true,
          "Docker: df 숫자 · 이미지·빌드 캐시만 정리 명령 · 볼륨·컨테이너는 보기만")
    check(category("swap")?.children?.contains { $0.tags == [.swap] } == true && category("trash")?.children?.count == 2 && category("download")?.children?.count == 1
          && category("xcode")?.children?.contains { $0.name.hasPrefix("iPhone Old") } == true && category("backup")?.children?.first?.name == "테스트 아이폰"
          && category("temp")?.children?.contains { $0.name == "old-dir" } == true, "묶음: 스왑 · 휴지통 2 · 오래된 큰 다운로드 1 · 오래된 시뮬레이터 · 백업 · 오래된 임시")
    check(brewCategory?.actions == [.prune] && brewCategory?.children?.count == 3 && brewCategory?.children?.first?.name == "pcre2 10.47_1", "Homebrew: 미리보기 3개 · 정리 명령 한 번")
    let worktreeNode = gitCategory?.children?.first { $0.path == worktreePath }
    let branchNode = gitCategory?.children?.first { $0.path == DiskNodeVirtual.path("git-branch", repo + "#feature/merged") }
    check(worktreeNode?.tags == [.gitByproduct] && worktreeNode?.actions == [.reveal, .trash] && branchNode?.actions == [.prune],
          "git 부산물: 병합된 워크트리 → 휴지통(LeftoverCleaner) · 병합된 브랜치 → 정리 명령")
    let repoNode = scanner.describe(repo)
    check(repoNode?.actions == [.reveal] && repoNode?.hint?.contains("git 저장소") == true, "저장소 자체는 통째로 옮기지 않음")

    // 11) 정리 명령: 미리보기는 읽기 전용 인자 · 실행은 금고 '지움' 먼저 · -a·볼륨 없음
    let before = tools.calls.count
    let dockerDry = images.map { DiskTreeActions.perform(.prune, on: $0, dryRun: true, vault: vault, userPIDs: [], environment: environment) }
    let previewCalls = Array(tools.calls.dropFirst(before))
    check(dockerDry?.ok == true && dockerDry?.command == "docker image prune -f" && previewCalls == [["docker", "system", "df"]], "docker 드라이런: docker system df만(정리 명령은 안 돈다)")
    let dockerRun = images.map { DiskTreeActions.perform(.prune, on: $0, dryRun: false, vault: vault, userPIDs: [], environment: environment) }
    let dockerEntry = vault.all().first { $0.id == dockerRun?.vaultEntryID }
    check(dockerRun?.ok == true && dockerEntry?.kind == .deleted && dockerEntry?.status == .gone && dockerEntry?.bytes == 1_200_000_000 && dockerEntry?.note?.contains("되돌릴 수 없음") == true,
          "docker 정리: 금고에 '지움'(회수 1.2GB · 되돌릴 수 없음)")
    let volumeRefused = volumesRow.map { DiskTreeActions.perform(.prune, on: $0, dryRun: false, vault: vault, userPIDs: [], environment: environment) }
    check(volumeRefused?.refused == true && !tools.calls.contains { $0.contains("-a") || $0.contains("--all") || $0.contains("volume") }, "docker: 볼륨 정리 거절 · -a·volume 명령은 한 번도 없음")
    if let brewCategory {
        let brewDry = DiskTreeActions.perform(.prune, on: brewCategory, dryRun: true, vault: vault, userPIDs: [], environment: environment)
        let brewRun = DiskTreeActions.perform(.prune, on: brewCategory, dryRun: false, vault: vault, userPIDs: [], environment: environment)
        let brewEntry = vault.all().first { $0.id == brewRun.vaultEntryID }
        check(brewDry.ok && tools.calls.contains(["brew", "cleanup", "-n", "--prune=all"]) && brewRun.ok && tools.calls.contains(["brew", "cleanup", "--prune=all"])
              && brewEntry?.kind == .deleted && brewEntry?.bytes == UInt64(48.4 * 1_048_576), "brew: 미리보기(-n) → 확인 뒤 cleanup --prune=all · 금고 '지움'(회수 48.4MB)")
    }

    // 12) git 부산물 정리: 워크트리(금고 → 같은 커밋으로 되살림) · 병합된 브랜치
    let fresh = scanner.actionEnvironment(audit: audit)
    if let worktreeNode {
        let removed = DiskTreeActions.perform(.trash, on: worktreeNode, dryRun: false, vault: vault, userPIDs: [], environment: fresh)
        let wtEntry = vault.all().first { $0.kind == .worktree && $0.worktreePath == worktreePath }
        check(removed.ok && !fm.fileExists(atPath: worktreePath) && wtEntry?.status == .held && removed.vaultEntryID == wtEntry?.id,
              "워크트리 정리: LeftoverCleaner(git worktree remove) · 금고에 커밋 \(wtEntry?.head?.prefix(8) ?? "-")")
        let back = wtEntry.map { RecoveryRestorer.restoreGit($0, vault: vault, git: git) }
        check(back?.ok == true && fm.fileExists(atPath: worktreePath + "/README.md"), "워크트리 되살리기: 같은 커밋")
    }
    if let branchNode {
        let pruned = DiskTreeActions.perform(.prune, on: branchNode, dryRun: false, vault: vault, userPIDs: [], environment: fresh)
        let branchEntry = vault.all().first { $0.kind == .branch && $0.branch == "feature/merged" }
        let exists = setupGit(git, ["-C", repo, "show-ref", "--verify", "--quiet", "refs/heads/feature/merged"]).succeeded
        check(pruned.ok && !exists && branchEntry?.status == .held, "병합된 브랜치 정리: git branch -d · 금고에 커밋")
    }

    // 13) 표 판정이 DiskScanner와 같은지(같은 시험 홈 — 표 경로를 몇 곳 더 만든다)
    let derived = home + "/Library/Developer/Xcode/DerivedData"
    writeBytes(derived + "/Gone-bbbb/Build/x.o", 16 * kb)
    (["WorkspacePath": root + "/nowhere/Gone.xcodeproj"] as NSDictionary).write(toFile: derived + "/Gone-bbbb/info.plist", atomically: true)
    writeBytes(derived + "/ModuleCache.noindex/a.pcm", 16 * kb)
    writeBytes(home + "/Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A1)/Symbols/dyld", 16 * kb)
    writeBytes(home + "/Library/Application Support/FakeApp/Local Storage/leveldb/x", 10)
    writeBytes(home + "/Library/Application Support/FakeApp/Code Cache/js/a", 2 * mb)
    writeBytes(home + "/Library/Application Support/Google/Chrome/Default/GPUCache/data_0", 16 * kb)
    writeBytes(home + "/Library/Logs/OldApp/a.log", 200 * kb, modified: Date().addingTimeInterval(-40 * day))
    setModified(home + "/Library/Logs/OldApp", Date().addingTimeInterval(-40 * day))
    let catalogScanner = DiskScanner(home: home)
    catalogScanner.minimumBytes = 0
    let catalogItems = catalogScanner.catalogItems(running: RunningApps.empty)
    let disagreements = catalogItems.filter { item in
        let found = DiskCatalog.match(item.path, home: home)
        return found?.entry.id != item.entryID || found?.grade != item.grade
    }
    check(catalogItems.count >= 8 && disagreements.isEmpty, "표 판정 = DiskScanner.catalogItems(\(catalogItems.count)곳)" + disagreements.map { " · 어긋남 \(abbreviate($0.path))" }.joined())
    let gone = scanner.describe(derived + "/Gone-bbbb")
    check(gone?.tags == [.cache, .xcode] && gone?.actions == [.reveal, .deletePermanently] && gone?.hint?.contains("삭제된 프로젝트") == true, "디스크 지도 태그도 표를 따름: 삭제된 프로젝트 DerivedData → 캐시 A")
    writeEvidence("disktree-check.json", ["fixture": root, "vault_entries": vault.all().count, "large": largeNames])
}

/// 실제 홈 읽기 전용 조사: 기본 뿌리의 크기 상위 15칸(태그·설명) · 걸린 시간 · 펼치기 캐시 · 묶음 보기 · 큰 파일. 정리 API는 부르지 않는다.
func diskTreeProbe() {
    setvbuf(stdout, nil, _IOLBF, 0)
    let budget = CommandLine.arguments.dropFirst(2).first.flatMap(Double.init) ?? 30
    // ~/Library만(차가운 캐시 · 새 조사기): 50만 파일 안팎이 예산 안에 끝나는지.
    let libraryScanner = DiskTreeScanner()
    let libraryStarted = Date()
    let library = libraryScanner.scan(roots: [NSHomeDirectory() + "/Library"], budget: budget).first
    let libraryReport = libraryScanner.lastReport
    print(String(format: "~/Library만: %.1f초 · 폴더 %d개 · 파일 %d개 · %@ · %@%@", Date().timeIntervalSince(libraryStarted), libraryReport.directories, libraryReport.files,
                 Fmt.size(library?.bytes ?? 0), libraryReport.complete ? "끝까지 셈" : "시간 제한으로 일부", library?.partial == true ? " · 권한 등으로 일부 못 읽음" : ""))
    check(libraryReport.complete, "~/Library 조사가 예산(\(Int(budget))초) 안에 끝남")
    let scanner = DiskTreeScanner()
    let roots = DiskTreeRoots.defaults()
    let started = Date()
    let nodes = scanner.scan(roots: roots, budget: budget)
    let report = scanner.lastReport
    print(String(format: "조사 %.1f초(제한 %.0f초) · 뿌리 %d개 · 폴더 %d개 · 파일 %d개 · %@ · 캐시 %d칸 · 잰 칸 %d", Date().timeIntervalSince(started), budget, nodes.count,
                 report.directories, report.files, report.complete ? "끝까지 셈" : "시간 제한으로 일부(partial)", report.cacheHits, report.measured))
    for node in nodes.sorted(by: { $0.bytes > $1.bytes }) {
        print("  뿌리 \(Fmt.size(node.bytes))\(node.partial ? "+" : "") · \(abbreviate(node.path)) · [\(node.tags.map(\.rawValue).sorted().joined(separator: ","))]")
    }
    let children = nodes.flatMap { $0.children ?? [] }.sorted { $0.bytes > $1.bytes }
    print("— 크기 상위 15칸(뿌리 바로 아래) —")
    for node in children.prefix(15) {
        let tags = node.tags.map(\.rawValue).sorted().joined(separator: ",")
        let actions = node.actions.map(\.rawValue).joined(separator: ",")
        print("  \(Fmt.size(node.bytes))\(node.partial ? "+" : "") · \(abbreviate(node.path))\(node.name != (node.path as NSString).lastPathComponent ? " (\(node.name))" : "") · [\(tags)] · 조치 \(actions)")
        if let hint = node.hint { print("      \(hint)") }
    }
    check(!nodes.isEmpty && !children.isEmpty, "실제 홈: 뿌리 \(nodes.count)개 · 바로 아래 \(children.count)칸")
    check(children.allSatisfy { !$0.actions.isEmpty }, "모든 칸에 조치(최소 '보기만')가 있음")
    check(!children.contains { $0.actions.contains(.deletePermanently) && !$0.isSafeToDeletePermanently }, "영구 삭제 조치는 안전 판정과 어긋나지 않음")

    // 펼치기: 캐시로 형제를 다시 재지 않는다.
    if let library = nodes.first(where: { $0.path == NSHomeDirectory() + "/Library" }) {
        let expandStarted = Date()
        let expanded = scanner.expand(library, budget: budget)
        let expandReport = scanner.lastReport
        print(String(format: "펼치기 ~/Library: %.2f초 · 캐시 %d칸 · 새로 잰 칸 %d · 바로 아래 %d칸", Date().timeIntervalSince(expandStarted), expandReport.cacheHits, expandReport.measured,
                     expanded.children?.count ?? 0))
        if let biggest = expanded.children?.first(where: { $0.isDirectory }) {
            let deeperStarted = Date()
            let deeper = scanner.expand(biggest, budget: budget)
            print(String(format: "펼치기 %@: %.2f초 · 캐시 %d칸 · 새로 잰 칸 %d", abbreviate(biggest.path), Date().timeIntervalSince(deeperStarted), scanner.lastReport.cacheHits,
                         scanner.lastReport.measured))
            for node in (deeper.children ?? []).prefix(5) {
                print("    \(Fmt.size(node.bytes))\(node.partial ? "+" : "") · \(node.name) · [\(node.tags.map(\.rawValue).sorted().joined(separator: ","))] · \(node.actions.map(\.rawValue).joined(separator: ","))")
            }
        }
    }

    // 사용자 임시·캐시 폴더 안(무엇이 큰지)
    for folder in scanner.temporaryFolders + scanner.cacheFolders {
        guard let level = scanner.scan(roots: [folder], budget: budget).first else { continue }
        print("— \(abbreviate(folder)): \(Fmt.size(level.bytes))\(level.partial ? "+" : "") · \(level.children?.count ?? 0)칸 —")
        for node in (level.children ?? []).prefix(5) {
            print("    \(Fmt.size(node.bytes)) · \(node.name) · [\(node.tags.map(\.rawValue).sorted().joined(separator: ","))] · \(node.actions.map(\.rawValue).joined(separator: ",")) · \(node.hint ?? "")")
        }
    }

    // 묶음 보기
    let categoryStarted = Date()
    let categories = scanner.categories(budget: budget)
    print(String(format: "— 묶음 보기 %.1f초 —", Date().timeIntervalSince(categoryStarted)))
    for category in categories {
        print("  \(category.name): \(Fmt.size(category.bytes))\(category.partial ? "+" : "") · \(category.children?.count ?? 0)칸 · \(category.hint ?? "")")
        for child in (category.children ?? []).prefix(4) {
            print("      \(Fmt.size(child.bytes)) · \(child.name) · [\(child.tags.map(\.rawValue).sorted().joined(separator: ","))] · \(child.actions.map(\.rawValue).joined(separator: ","))"
                  + (category.tags.contains(.trash) ? " · \(child.hint ?? "")" : ""))
        }
    }
    check(categories.count == 10 && categories.allSatisfy(\.isVirtual), "묶음 보기 10묶음(파일이 아닌 칸)")

    // 큰 파일
    let largeStarted = Date()
    let large = scanner.largeFiles(under: [NSHomeDirectory()], minimumBytes: 500 * 1_048_576, budget: budget)
    let largeReport = scanner.lastReport
    print(String(format: "— 큰 파일(500MB 이상) %.1f초 · 폴더 %d개 · 파일 %d개 · %@ —", Date().timeIntervalSince(largeStarted), largeReport.directories, largeReport.files,
                 largeReport.complete ? "끝까지" : "시간 제한"))
    for node in large.prefix(10) {
        print("  \(Fmt.size(node.bytes)) · \(abbreviate(node.path)) · [\(node.tags.map(\.rawValue).sorted().joined(separator: ","))] · \(node.actions.map(\.rawValue).joined(separator: ",")) · \(node.hint ?? "")")
    }
    check(large.allSatisfy { $0.tags.contains(.large) && $0.bytes >= 500 * 1_048_576 }, "큰 파일: 모두 500MB 이상 · '큰 파일' 태그")
    writeEvidence("disktree-probe.json", ["elapsed": Date().timeIntervalSince(started), "roots": nodes.count, "top": children.prefix(15).map { ["path": abbreviate($0.path), "bytes": $0.bytes, "tags": $0.tags.map(\.rawValue).sorted(), "partial": $0.partial] }])
}
