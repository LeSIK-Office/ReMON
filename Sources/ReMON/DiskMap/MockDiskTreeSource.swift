import Foundation
import ReMONCore

// 미리보기·시험용 가짜 조사기와 가짜 조치 실행기. 실제 디스크는 한 바이트도 읽거나 바꾸지 않는다.
// 실제 조사기(DiskTreeScanner)·실행기(DiskTreeActions)가 들어오면 DiskMapHooks 두 줄만 바꾼다(DiskMapStore.swift).

/// 그럴듯한 가짜 홈(개발 프로젝트·node_modules·.git·워크트리·Library 캐시·Docker VM·Xcode·휴지통·임시·다운로드·큰 파일).
/// 같은 입력이면 늘 같은 나무를 돌려준다(경로 해시 씨앗). 뿌리 목록은 무시하고 늘 같은 가짜 홈을 돌려준다.
struct MockDiskTreeSource: DiskTreeSource {
    var home: String = NSHomeDirectory()
    /// 조사가 걸리는 시간 흉내(초). 펼치기는 이 값의 절반.
    var latency: TimeInterval = 0.6

    func scan(roots: [String], budget: TimeInterval) -> [DiskNode] {
        pause(min(latency, budget))
        return Self.tree(home: home).map { Self.trimmed($0, depth: 1) }
    }

    func expand(_ node: DiskNode, budget: TimeInterval) -> DiskNode {
        pause(min(latency / 2, budget))
        guard let full = Self.find(node.path, in: Self.tree(home: home)) ?? (node.isDirectory ? Self.synthesized(node) : nil) else {
            var empty = node
            if node.isDirectory { empty.children = [] }
            return empty
        }
        var expanded = full
        if expanded.isDirectory && expanded.children == nil { expanded = Self.synthesized(expanded) }
        return Self.trimmed(expanded, depth: 1)
    }

    func largeFiles(under roots: [String], minimumBytes: UInt64, budget: TimeInterval) -> [DiskNode] {
        pause(min(latency / 2, budget))
        var result: [DiskNode] = []
        func walk(_ nodes: [DiskNode]) {
            for node in nodes {
                if !node.isDirectory, node.bytes >= minimumBytes, !node.tags.contains(.snapshot) {   // 스냅샷은 찾을 수 있는 파일이 아니다
                    var file = node
                    file.tags.insert(.large)
                    result.append(file)
                }
                walk(node.children ?? [])
            }
        }
        walk(Self.tree(home: home))
        return DiskMapTree.sortedBySize(result)
    }

    private func pause(_ seconds: TimeInterval) {
        if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
    }

    // MARK: 나무 만들기

    static func trimmed(_ node: DiskNode, depth: Int) -> DiskNode {
        var copy = node
        guard node.isDirectory else { copy.children = nil; return copy }
        if depth <= 0 {
            copy.children = nil
        } else if let children = node.children {
            copy.children = children.map { trimmed($0, depth: depth - 1) }
        }
        return copy
    }

    static func find(_ path: String, in nodes: [DiskNode]) -> DiskNode? { DiskMapTree.find(path, in: nodes) }

    /// 자식을 적어 두지 않은 가짜 폴더를 펼치면: 경로 해시로 그 종류다운 하위 폴더 몇 개 + 작은 파일 몇 개를 만들어 크기를 나눠 준다.
    static func synthesized(_ node: DiskNode) -> DiskNode {
        var copy = node
        var random = SeededRandom(seed: fnv(node.path))
        let total = node.bytes
        guard total > 0 else { copy.children = []; return copy }
        let names = syntheticNames(for: node)
        let folderNames = shuffled(names.folders, &random)
        let fileNames = shuffled(names.files, &random)
        let folders = total > 64 * 1_048_576 ? min(folderNames.count, 3 + random.next(5)) : 0
        let files = max(1, min(fileNames.count, 2 + random.next(3)))
        // 폴더가 대부분을 갖고, 파일은 합쳐 6%만(실제 폴더처럼 큰 덩어리는 하위 폴더에).
        let fileShare = folders == 0 ? 1.0 : 0.06
        let folderWeights = (0..<folders).map { _ in pow(Double(1 + random.next(1000)) / 1000, 2.0) + 0.05 }
        let fileWeights = (0..<files).map { _ in Double(1 + random.next(100)) }
        let folderSum = folderWeights.reduce(0, +), fileSum = fileWeights.reduce(0, +)
        var remaining = total
        var remainingFiles = max(node.fileCount, folders + files)
        var children: [DiskNode] = []
        for index in 0..<(folders + files) {
            let isFolder = index < folders
            let last = index == folders + files - 1
            let share = isFolder ? (1 - fileShare) * folderWeights[index] / folderSum : fileShare * fileWeights[index - folders] / fileSum
            let bytes = last ? remaining : min(remaining, UInt64(Double(total) * share))
            remaining -= bytes
            let count = isFolder ? max(1, Int(Double(node.fileCount) * share)) : 1
            remainingFiles = max(0, remainingFiles - count)
            let name = isFolder ? folderNames[index] : fileNames[index - folders]
            children.append(DiskNode(path: node.path + "/" + name, bytes: bytes, fileCount: count, isDirectory: isFolder,
                                     modified: node.modified?.addingTimeInterval(-Double(random.next(86_400 * 20))), children: nil,
                                     tags: node.tags.subtracting([.large]), hint: node.hint, actions: node.actions, partial: node.partial))
        }
        copy.children = children
        return copy
    }

    /// 가짜 자식 이름(폴더 종류별로 그럴듯하게).
    private static func syntheticNames(for node: DiskNode) -> (folders: [String], files: [String]) {
        let path = node.path, tags = node.tags
        if path.contains("node_modules") {
            return (["next", "@swc", "typescript", "esbuild", "@img", "lightningcss", "prisma", "@next", "react-dom", "date-fns", "lodash", "@babel", "webpack", "sharp", "rxjs", "@tanstack"],
                    [".package-lock.json", ".modules.yaml", ".pnpm-workspace-state.json"])
        }
        if tags.contains(.gitByproduct) {
            return (["node_modules", "src", "apps", "dist", ".next", "packages", ".turbo"], [".git", "package.json", "README.md", "pnpm-lock.yaml"])
        }
        if tags.contains(.trash) { return (["node_modules", "옛 버전", "백업"], ["설치 파일.dmg", "화면 기록.mov", "압축.zip"]) }
        if !tags.isDisjoint(with: [.aiTranscript, .aiData]) {
            return (["2026", "-Users-me-DEV-ReMON", "-Users-me-DEV-shop-web", "-Users-me-DEV-landing", "archive"], ["history.jsonl", "session-index.json", "rollout-2026-10-25.jsonl"])
        }
        if tags.contains(.temp) { return (["TemporaryItems", "com.apple.metal", "swift-build", "node-compile-cache", "claude-501"], ["tmp.lock", "cache.db", "session.tmp"]) }
        if tags.contains(.docker) { return (["vms", "log", "tasks", "buildkit"], ["settings.json", "daemon.json", "log.txt"]) }
        if !tags.isDisjoint(with: [.cache, .regenerable, .xcode, .homebrew]) {
            return (["arm64-apple-macosx", "debug", "release", "objects", "index", "ModuleCache", "intermediates", "packs", "static", "server"], ["build.db", "manifest.json", "cache.bin", "index.lock"])
        }
        if tags.contains(.userFile) { return (["2026", "2025", "자료", "프로젝트", "참고", "백업", "사진"], ["메모.txt", "보고서.pdf", "발표.key", "정리.xlsx", "회의록.docx"]) }
        return (["data", "assets", "lib", "resources", "logs", "cache"], ["data.db", "index.json", "log.txt", "settings.plist"])
    }

    private static func shuffled(_ items: [String], _ random: inout SeededRandom) -> [String] {
        var result = items
        for index in result.indices.reversed() where index > 0 { result.swapAt(index, random.next(index + 1)) }
        return result
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [DiskNode]] = [:]

    /// 가짜 홈 전체(모든 단계). 한 번 만들어 두고 다시 쓴다.
    static func tree(home: String) -> [DiskNode] {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cache[home] { return cached }
        let built = MockHome(home: home).roots()
        cache[home] = built
        return built
    }

    /// 경로 해시(FNV-1a) — 실행마다 같은 값(Swift Hasher는 실행마다 바뀐다).
    static func fnv(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return hash
    }
}

/// 씨앗이 같으면 같은 수열(SplitMix64).
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return bound <= 0 ? 0 : Int(z % UInt64(bound))
    }
}

/// 가짜 홈 설계도. 크기는 GB(1024 기준), 나이는 '며칠 전 수정'.
private struct MockHome {
    let home: String
    let now = Date()

    /// 설계도 한 칸.
    struct Entry {
        var name: String
        /// 화면 이름(경로 이름과 다를 때만).
        var label: String?
        var gb: Double = 0
        var files = 1
        var isDirectory = true
        var tags: Set<DiskTag> = []
        var hint: String?
        var actions: [DiskNodeAction]?
        var partial = false
        var age: Double = 4
        var children: [Entry]?
    }

    static func dir(_ name: String, _ tags: Set<DiskTag> = [], hint: String? = nil, actions: [DiskNodeAction]? = nil, partial: Bool = false, _ children: [Entry]) -> Entry {
        Entry(name: name, tags: tags, hint: hint, actions: actions, partial: partial, children: children)
    }

    /// 자식을 적지 않은 폴더(펼치면 가짜 자식을 만든다).
    static func blob(_ name: String, _ gb: Double, _ tags: Set<DiskTag> = [], files: Int = 1200, hint: String? = nil, actions: [DiskNodeAction]? = nil, partial: Bool = false, age: Double = 4) -> Entry {
        Entry(name: name, gb: gb, files: files, tags: tags, hint: hint, actions: actions, partial: partial, age: age, children: nil)
    }

    static func file(_ name: String, _ gb: Double, _ tags: Set<DiskTag> = [], hint: String? = nil, actions: [DiskNodeAction]? = nil, age: Double = 9) -> Entry {
        Entry(name: name, gb: gb, files: 1, isDirectory: false, tags: tags, hint: hint, actions: actions, age: age, children: nil)
    }

    // 설명 문구(태그별 기본).
    static let hintNodeModules = "패키지 설치본입니다. 지워도 pnpm/npm install로 다시 만들어집니다."
    static let hintBuild = "빌드 산출물입니다. 다음 빌드 때 다시 생깁니다."
    static let hintGit = "저장소 이력(.git)입니다. 지우면 커밋 기록이 사라지므로 손대지 않습니다 — 줄이려면 git gc."
    static let hintWorktrees = "에이전트가 만든 워크트리 묶음입니다. 병합됐고 변경이 없는 것만 치우세요(정리 화면의 부산물 청소가 판정합니다)."
    static let hintWorktree = "에이전트 워크트리입니다. 브랜치가 병합됐는지 확인한 뒤 휴지통으로 옮기세요."
    static let hintUser = "직접 만든 파일입니다. 자동으로 치우지 않습니다 — 필요 없을 때만 휴지통으로."
    static let hintTrash = "휴지통 안입니다. Finder에서 '휴지통 비우기'를 해야 공간이 돌아옵니다(ReMON은 비우지 않습니다)."

    func roots() -> [DiskNode] {
        let h = home
        let entries: [(String, Entry)] = [
            (h, devFolder()),
            (h, library()),
            (h, Self.dir("Downloads", [.download], hint: "내려받은 파일입니다. 설치를 마친 dmg·xip·iso는 휴지통으로 옮겨도 됩니다.", actions: [.reveal], downloads())),
            (h, Self.dir("Documents", [.userFile], hint: Self.hintUser, actions: [.reveal], documents())),
            (h, Self.dir("Desktop", [.userFile], hint: Self.hintUser, actions: [.reveal], [
                Self.blob("스크린샷", 1.4, [.userFile], files: 860, age: 1), Self.file("ReMON 기획 v3.key", 0.42, [.userFile], age: 2),
                Self.blob("정리할 것", 0.9, [.userFile], files: 210, age: 30), Self.file("화면 기록 2026-10-24 오후 11.02.11.mov", 0.38, [.userFile], age: 1)])),
            (h, Self.dir("Movies", [.userFile], hint: Self.hintUser, actions: [.reveal], [
                Self.file("화면 기록 2026-10-21 오후 3.12.04.mov", 8.4, [.userFile], age: 4), Self.file("화면 기록 2026-10-09 오전 10.41.37.mov", 5.1, [.userFile], age: 16),
                Self.blob("CapCut", 6.2, [.userFile], files: 3400, hint: "CapCut 편집 프로젝트입니다. 끝난 프로젝트만 정리하세요.", age: 12),
                Self.blob("Final Cut 백업", 4.6, [.userFile, .backup], files: 120, age: 80)])),
            (h, Self.dir("Pictures", [.userFile], hint: Self.hintUser, actions: [.reveal], [
                Self.blob("Photos Library.photoslibrary", 13.6, [.bundle, .userFile], files: 48_000, hint: "사진 보관함(번들)입니다. 사진 앱에서만 정리하세요.", actions: [.reveal]),
                Self.blob("스크린샷 보관", 0.7, [.userFile], files: 1900)])),
            (h, Self.dir("Music", [.userFile], hint: Self.hintUser, actions: [.reveal], [Self.blob("Music", 2.1, [.userFile], files: 900, age: 200)])),
            (h, Self.dir(".Trash", [.trash], hint: Self.hintTrash, actions: [.reveal], [
                Self.file("shop-web-backup-1019.zip", 2.1, [.trash], hint: Self.hintTrash, actions: [.reveal], age: 6),
                Self.blob("node_modules 3", 1.9, [.trash], files: 52_000, hint: Self.hintTrash, actions: [.reveal], age: 3),
                Self.file("화면 기록 2026-10-02 오전 11.04.31.mov", 1.6, [.trash], hint: Self.hintTrash, actions: [.reveal], age: 20),
                Self.file("Docker 4.33.dmg", 0.9, [.trash], hint: Self.hintTrash, actions: [.reveal], age: 40),
                Self.blob("오래된 워크트리 7개", 0.8, [.trash], files: 9100, hint: Self.hintTrash, actions: [.reveal], age: 2)])),
            (h, Self.dir(".cache", [.cache], hint: "여러 도구의 캐시입니다. 지우면 필요할 때 다시 받습니다.", [
                Self.dir("huggingface", [.cache, .aiData], hint: "내려받은 AI 모델입니다. 지우면 다음에 다시 받습니다(수 GB, 시간이 걸림).", [
                    Self.file("model-00001-of-00002.safetensors", 4.9, [.cache, .aiData], hint: "Qwen2.5-7B 모델 조각 — 다시 받을 수 있습니다.", age: 25),
                    Self.file("model-00002-of-00002.safetensors", 3.8, [.cache, .aiData], hint: "Qwen2.5-7B 모델 조각 — 다시 받을 수 있습니다.", age: 25),
                    Self.blob("xet", 0.9, [.cache], files: 2400)]),
                Self.blob("uv", 1.4, [.cache, .regenerable], files: 31_000), Self.blob("pip", 0.6, [.cache, .regenerable], files: 4100),
                Self.blob("puppeteer", 0.5, [.cache, .regenerable], files: 900, hint: "헤드리스 Chrome 설치본 — 필요할 때 다시 받습니다.")])),
            (h, Self.dir(".npm", [.cache, .regenerable], hint: "npm 내려받기 캐시입니다. 지워도 설치할 때 다시 받습니다.", [
                Self.blob("_cacache", 5.2, [.cache, .regenerable], files: 210_000), Self.blob("_npx", 0.3, [.cache, .regenerable], files: 18_000)])),
            (h, Self.dir(".claude", [.aiData], hint: "Claude Code 데이터입니다. 대화 기록은 세션 복구 자원이라 지우지 않습니다.", actions: [.reveal], [
                Self.blob("projects", 5.2, [.aiTranscript], files: 2900, hint: "Claude 대화 기록입니다. 세션을 되살리는 데 쓰므로 지우지 않습니다(외장 이전은 정리 화면에서).", actions: [.reveal], age: 0.1),
                Self.blob("file-history", 0.4, [.aiData], files: 12_000, hint: "편집 되돌리기 기록입니다. 오래된 것만 정리됩니다."),
                Self.blob("shell-snapshots", 0.2, [.aiData], files: 3100), Self.blob("todos", 0.01, [.aiData], files: 800)])),
            (h, Self.dir(".codex", [.aiData], hint: "Codex 데이터입니다. 세션 기록은 복구 자원이라 지우지 않습니다.", actions: [.reveal], [
                Self.blob("sessions", 3.9, [.aiTranscript], files: 1400, hint: "Codex 세션 기록(rollout)입니다. 세션을 되살리는 데 쓰므로 지우지 않습니다.", actions: [.reveal], age: 0.1),
                Self.blob("archived_sessions", 0.4, [.aiTranscript], files: 300, actions: [.reveal], age: 9),
                Self.blob("log", 0.3, [.aiData], files: 40), Self.file("state_5.sqlite", 0.05, [.aiData], hint: "Codex 상태 DB — 손대지 않습니다.", actions: [.reveal], age: 0.1)])),
            (h, Self.dir(".docker", [.docker], hint: "Docker CLI 설정·buildx 캐시입니다.", [
                Self.blob("buildx", 0.9, [.docker, .cache, .regenerable], files: 5200, hint: "buildx 빌드 캐시 — 다음 빌드 때 다시 생깁니다."),
                Self.blob("contexts", 0.01, [.docker], files: 12, actions: [.reveal])])),
            (h, Self.dir(".gradle", [.cache, .regenerable], hint: "Gradle 캐시입니다. 다음 빌드 때 다시 받습니다.", [
                Self.blob("caches", 3.6, [.cache, .regenerable], files: 88_000), Self.blob("wrapper", 0.5, [.regenerable], files: 900)])),
            (h, Self.dir(".cargo", [.regenerable], hint: "Rust 패키지 캐시·도구입니다.", [
                Self.blob("registry", 1.9, [.cache, .regenerable], files: 64_000), Self.blob("bin", 0.4, [.regenerable], files: 30)])),
            (h, Self.dir(".rustup", [.regenerable], hint: "Rust 도구 모음 설치본입니다. rustup으로 다시 설치할 수 있습니다.", [Self.blob("toolchains", 3.4, [.regenerable], files: 41_000)])),
            (h, Self.dir(".nvm", [.regenerable], hint: "Node 버전 설치본입니다. 안 쓰는 버전만 지우세요(nvm uninstall).", [
                Self.blob("versions", 2.1, [.regenerable], files: 120_000), Self.blob(".cache", 0.2, [.cache, .regenerable], files: 40)])),
            (h, Self.dir(".local", [], hint: "도구 설치본과 데이터가 섞인 폴더입니다.", actions: [.reveal], [
                Self.dir("share", [], actions: [.reveal], [
                    Self.blob("claude", 1.6, [.aiData, .regenerable], files: 60, hint: "Claude CLI 버전들입니다. 이전 버전은 지워도 됩니다(정리 화면의 AI 데이터에서 판정)."),
                    Self.blob("pnpm", 2.4, [.cache, .regenerable], files: 140_000, hint: "pnpm 저장소 — 지우면 다음 설치 때 다시 받습니다.")])])),
            (h, Self.dir("orca", [.gitByproduct], hint: "Orca 작업 공간(워크트리)입니다. 부산물 청소는 정리 화면에서 병합 여부를 확인하고 합니다.", [
                Self.blob("workspaces", 7.2, [.gitByproduct], files: 310_000, hint: Self.hintWorktrees, actions: [.trash, .reveal], age: 1),
                Self.blob("logs", 0.2, [.temp], files: 900)])),
            ("/private/var", Self.dir("vm", [.swap, .system], hint: "스왑 파일입니다. 메모리가 넘칠 때 macOS가 씁니다 — 보기만 합니다(세션을 정리해 메모리가 줄면 macOS가 줄입니다).", actions: [.none],
                                     (0..<8).map { Self.file("swapfile\($0)", 1, [.swap, .system], hint: "macOS가 관리하는 스왑 파일입니다.", actions: [.none], age: 0.05) })),
            ("/private/var", Self.dir("folders", [.temp, .system], hint: "macOS·앱의 임시 폴더입니다. 실행 중인 앱이 쓰는 중일 수 있어 휴지통만 허용합니다(영구 삭제 안 함).", actions: [.reveal], partial: true, [
                Self.dir("j8", [.temp], actions: [.reveal], partial: true, [
                    Self.dir("z1x7q9_n2kd8s0000gn", [.temp], actions: [.reveal], partial: true, [
                        Self.blob("T", 4.1, [.temp], files: 26_000, hint: "앱이 쓰고 남긴 임시 파일입니다. 휴지통으로 옮길 수 있습니다(영구 삭제 안 함).", actions: [.trash, .reveal], age: 0.5),
                        Self.blob("C", 1.8, [.cache, .temp], files: 14_000, hint: "앱 캐시(임시 영역)입니다.", actions: [.trash, .reveal], age: 1),
                        Self.blob("0", 0.3, [.system], files: 300, actions: [.none], age: 1)])]),
                Self.blob("zz", 0.2, [.system], files: 400, hint: "시스템 계정의 임시 폴더 — 권한이 없어 끝까지 세지 못했습니다.", actions: [.none], partial: true)])),
            ("/Library", Self.dir("Developer", [.xcode, .system], hint: "명령줄 도구(CLT)입니다. 빌드에 필요하므로 지우지 마세요.", actions: [.reveal], [
                Self.blob("CommandLineTools", 4.2, [.xcode, .system], files: 61_000, hint: "명령줄 도구 — 지우면 swift·git 빌드가 멈춥니다.", actions: [.reveal])])),
            ("/", Self.dir("Applications", [.bundle], hint: "설치한 앱입니다. 앱은 통째로 다룹니다 — 지우려면 Finder에서 휴지통으로.", actions: [.reveal], [
                Self.blob("Xcode.app", 12.4, [.bundle, .xcode], files: 410_000, actions: [.reveal], age: 30), Self.blob("Docker.app", 2.1, [.bundle, .docker], files: 9000, actions: [.reveal], age: 40),
                Self.blob("Google Chrome.app", 1.3, [.bundle], files: 1400, actions: [.reveal]), Self.blob("Orca.app", 0.6, [.bundle], files: 3100, actions: [.reveal]),
                Self.blob("Claude.app", 0.5, [.bundle], files: 2200, actions: [.reveal]), Self.blob("Final Cut Pro.app", 5.8, [.bundle], files: 21_000, actions: [.reveal], age: 90),
                Self.blob("기타 앱 34개", 6.9, [.bundle], files: 88_000, actions: [.reveal], age: 60)])),
            ("/Volumes", Entry(name: "com.apple.TimeMachine.localsnapshots", label: "Time Machine 로컬 스냅샷", tags: [.snapshot, .system],
                               hint: "Time Machine 로컬 스냅샷입니다. 공간이 모자라면 macOS가 먼저 지웁니다 — 보기만 합니다(크기는 macOS가 알려 준 추정치).",
                               actions: [.none], partial: true, children: [
                                Self.file("com.apple.TimeMachine.2026-10-25-091502.local", 7.4, [.snapshot, .system], actions: [.none], age: 0.2),
                                Self.file("com.apple.TimeMachine.2026-10-24-211733.local", 6.1, [.snapshot, .system], actions: [.none], age: 0.7),
                                Self.file("com.apple.TimeMachine.2026-10-24-091120.local", 4.5, [.snapshot, .system], actions: [.none], age: 1.2)])),
        ]
        return entries.map { parent, entry in build(entry, parent: parent) }
    }

    private func devFolder() -> Entry {
        Self.dir("DEV", [], hint: "개발 프로젝트 폴더입니다. 원본 코드와 다시 만들 수 있는 부산물이 섞여 있습니다.", actions: [.reveal], [
            project("shop-web", nodeModules: 18.4, extras: [
                Self.blob(".next", 6.2, [.regenerable, .cache], files: 38_000, hint: "Next.js 빌드 캐시입니다. 다음 빌드 때 다시 생깁니다."),
                Self.blob(".turbo", 2.3, [.cache, .regenerable], files: 9000, hint: "Turborepo 캐시입니다. 다시 생깁니다."),
                Self.blob("apps", 4.8, [.userFile], files: 21_000, hint: Self.hintUser, age: 0.2), Self.blob("packages", 0.9, [.userFile], files: 6000, hint: Self.hintUser, age: 0.3)],
                    git: 3.1, worktrees: [("agent-a0b00ad4", 2.4), ("agent-a65d4f02", 2.1), ("agent-c19e7720", 1.9), ("hotfix-order-sync", 1.7), ("agent-f3b8e912", 1.6), ("agent-07aa13c5", 1.5), ("agent-d4410b6e", 1.4)]),
            project("store-app", nodeModules: 9.9, extras: [
                Self.blob(".turbo", 3.3, [.cache, .regenerable], files: 12_000, hint: "Turborepo 캐시입니다. 다시 생깁니다."),
                Self.dir("ios", [.userFile], actions: [.reveal], [Self.blob("Pods", 6.1, [.regenerable], files: 52_000, hint: "CocoaPods 설치본입니다. pod install로 다시 만들어집니다."), Self.blob("App", 0.4, [.userFile], hint: Self.hintUser)]),
                Self.dir("android", [.userFile], actions: [.reveal], [Self.blob(".gradle", 2.2, [.cache, .regenerable], files: 7000, hint: "Gradle 프로젝트 캐시 — 다시 생깁니다."), Self.blob("app", 0.6, [.userFile], hint: Self.hintUser)]),
                Self.blob("src", 0.7, [.userFile], files: 4100, hint: Self.hintUser, age: 1)],
                    git: 5.4, worktrees: [("agent-store-9a1", 2.2), ("release-0.9", 1.8)]),
            project("landing", nodeModules: 11.2, extras: [
                Self.blob("dist", 1.1, [.regenerable], files: 3000, hint: Self.hintBuild), Self.blob("src", 0.6, [.userFile], files: 3800, hint: Self.hintUser, age: 3)],
                    git: 2.4, worktrees: [("landing-sub-1", 3.4), ("landing-sub-2", 3.3), ("codex-exec-0731", 3.1)]),
            project("ReMON", nodeModules: 0, extras: [
                Self.blob(".build", 14.2, [.regenerable, .cache], files: 61_000, hint: "SwiftPM 빌드 산출물입니다. swift build로 다시 만들어집니다."),
                Self.blob("Sources", 0.004, [.userFile], files: 120, hint: Self.hintUser, age: 0.01), Self.blob("Evidence", 0.21, [.userFile], files: 340, hint: Self.hintUser, age: 1),
                Self.blob("design", 0.3, [.userFile], files: 210, hint: Self.hintUser, age: 1), Self.blob("dist", 0.9, [.userFile], files: 12, hint: "배포본(dmg)입니다. 공증한 배포본은 다시 만들기 번거로우니 남겨 두세요.", age: 0.5)],
                    git: 0.4, worktrees: [("agent-a0b00ad4bd37acb9d", 1.9), ("agent-aa5c7874e6bacf4c6", 1.8), ("agent-a65d4f02523f8c308", 1.7)]),
            project("folder-backup", nodeModules: 0, extras: [
                Self.blob(".build", 9.6, [.regenerable, .cache], files: 44_000, hint: "SwiftPM 빌드 산출물입니다. 다시 만들어집니다."),
                Self.blob("dist-release", 4.1, [.userFile], files: 30, hint: "공증한 배포본입니다. 남겨 두는 편이 좋습니다.", age: 20), Self.blob("Sources", 0.01, [.userFile], hint: Self.hintUser)],
                    git: 1.2, worktrees: []),
            Self.dir("notes", [.userFile], actions: [.reveal], [Self.file("기획.md", 0.0001, [.userFile], hint: Self.hintUser, age: 1), Self.blob("references", 0.8, [.userFile], files: 40, age: 2)]),
            Self.blob("playground", 2.6, [.userFile], files: 18_000, hint: Self.hintUser, age: 45),
        ])
    }

    private func project(_ name: String, nodeModules: Double, extras: [Entry], git: Double, worktrees: [(String, Double)]) -> Entry {
        var children = extras
        if nodeModules > 0 { children.append(Self.blob("node_modules", nodeModules, [.regenerable], files: Int(nodeModules * 22_000), hint: Self.hintNodeModules, age: 2)) }
        children.append(Self.blob(".git", git, [.gitByproduct], files: Int(git * 3000), hint: Self.hintGit, actions: [.reveal], age: 0.1))
        if !worktrees.isEmpty {
            children.append(Self.dir(".claude", [], actions: [.reveal], [
                Self.dir("worktrees", [.gitByproduct], hint: Self.hintWorktrees, actions: [.trash, .reveal],
                         worktrees.enumerated().map { index, item in
                             Self.blob(item.0, item.1, [.gitByproduct], files: Int(item.1 * 20_000), hint: Self.hintWorktree, actions: [.trash, .reveal], age: Double(1 + index * 2))
                         })]))
        }
        return Self.dir(name, [], hint: "프로젝트 폴더입니다. 원본(소스)과 다시 만들 수 있는 것(node_modules·빌드)이 섞여 있습니다.", actions: [.reveal], children)
    }

    private func library() -> Entry {
        Self.dir("Library", [], hint: "앱 데이터·캐시·설정이 있는 곳입니다. 폴더 통째로는 건드리지 않고 안쪽에서 골라 치웁니다.", actions: [.reveal], [
            Self.dir("Containers", [], hint: "샌드박스 앱의 데이터입니다. 일부는 권한 때문에 끝까지 세지 못했습니다.", actions: [.reveal], partial: true, [
                Self.dir("com.docker.docker", [.docker], hint: "Docker Desktop 데이터입니다. 가상 디스크는 직접 지우지 말고 정리 명령(docker system prune)으로 줄입니다.", actions: [.prune, .reveal], [
                    Self.dir("Data", [.docker], actions: [.prune, .reveal], [
                        Self.dir("vms", [.docker], actions: [.prune, .reveal], [
                            Self.dir("0", [.docker], actions: [.prune, .reveal], [
                                Self.dir("data", [.docker], actions: [.prune, .reveal], [
                                    Self.file("Docker.raw", 61.8, [.docker], hint: "Docker 이미지·컨테이너·볼륨이 든 가상 디스크입니다. 파일을 지우면 모두 사라지므로 정리 명령으로 줄입니다.", actions: [.prune, .reveal], age: 0.02)])])]),
                        Self.blob("log", 0.6, [.docker, .temp], files: 300, actions: [.trash, .reveal])])]),
                Self.blob("com.apple.mail", 1.9, [], files: 9000, hint: "메일 앱 데이터입니다.", actions: [.reveal], partial: true),
                Self.blob("기타 컨테이너 212개", 3.4, [], files: 40_000, actions: [.reveal], partial: true)]),
            Self.dir("Caches", [.cache], hint: "앱 캐시입니다. 지우면 앱이 필요할 때 다시 만듭니다(처음 한 번 느려질 수 있음).", [
                Self.blob("Homebrew", 6.8, [.homebrew, .cache], files: 2300, hint: "Homebrew 내려받기 캐시·옛 버전입니다. brew cleanup으로 정리합니다.", actions: [.prune, .trash, .deletePermanently, .reveal]),
                Self.blob("ms-playwright", 3.2, [.cache, .regenerable], files: 8000, hint: "Playwright 브라우저 설치본입니다. 필요할 때 다시 받습니다."),
                Self.blob("Google", 2.9, [.cache], files: 41_000), Self.blob("Yarn", 2.6, [.cache, .regenerable], files: 160_000),
                Self.blob("pip", 1.4, [.cache, .regenerable], files: 9000), Self.blob("com.apple.dt.Xcode", 1.1, [.cache, .xcode], files: 3000),
                Self.blob("com.openai.chat", 0.8, [.cache, .aiData], files: 6000), Self.blob("node-gyp", 0.3, [.cache, .regenerable], files: 4000),
                Self.blob("기타 캐시 140개", 1.7, [.cache], files: 33_000)]),
            Self.dir("Developer", [.xcode], hint: "Xcode 데이터입니다. DerivedData는 다시 빌드되면 생기고, Archives는 배포 기록입니다.", actions: [.reveal], [
                Self.dir("Xcode", [.xcode], actions: [.reveal], [
                    Self.blob("DerivedData", 17.5, [.xcode, .regenerable, .cache], files: 240_000, hint: "Xcode 빌드 중간 산출물입니다. 영구 삭제해도 다음 빌드 때 다시 생깁니다.", age: 1),
                    Self.blob("Archives", 6.2, [.xcode], files: 900, hint: "배포한 빌드 보관본입니다. 같은 빌드를 다시 만들기 어려울 수 있어 휴지통만 허용합니다.", actions: [.trash, .reveal], age: 60),
                    Self.blob("iOS DeviceSupport", 9.1, [.xcode, .regenerable], files: 70_000, hint: "기기 연결 때 받는 심볼 파일입니다. 기기를 다시 연결하면 다시 받습니다.", age: 90)]),
                Self.blob("CoreSimulator", 5.3, [.xcode], files: 120_000, hint: "시뮬레이터 기기·런타임입니다. xcrun simctl delete unavailable로 정리합니다.", actions: [.trash, .reveal], age: 14)]),
            Self.dir("Application Support", [], hint: "앱이 저장한 데이터입니다. 앱이 관리하므로 대부분 그대로 둡니다.", actions: [.reveal], [
                Self.dir("MobileSync", [.backup], actions: [.reveal], [
                    Self.blob("Backup", 9.7, [.backup], files: 110_000, hint: "iPhone·iPad 백업입니다. 지우면 그 시점으로 복원할 수 없습니다.", actions: [.trash, .reveal], age: 120)]),
                Self.blob("Claude", 3.8, [.aiData], files: 21_000, hint: "Claude 앱 데이터입니다. 캐시 부분만 정리 화면에서 비웁니다.", actions: [.reveal]),
                Self.blob("Google", 4.4, [], files: 52_000, hint: "Chrome 프로필입니다.", actions: [.reveal]),
                Self.blob("Code", 2.1, [], files: 30_000, actions: [.reveal]), Self.blob("Orca", 1.2, [], files: 4000, actions: [.reveal]),
                Self.blob("기타 앱 데이터", 2.8, [], files: 31_000, actions: [.reveal])]),
            Self.blob("Group Containers", 4.1, [], files: 26_000, actions: [.reveal], partial: true),
            Self.blob("Mail", 3.4, [], files: 61_000, actions: [.reveal]),
            Self.blob("Messages", 2.2, [], files: 18_000, actions: [.reveal]),
            Self.blob("Logs", 1.1, [.temp], files: 5200, hint: "앱 기록 파일입니다. 오래된 것은 휴지통으로 옮겨도 됩니다.", actions: [.trash, .reveal]),
            Self.blob("Mobile Documents", 6.0, [.userFile], files: 14_000, hint: "iCloud Drive 파일입니다. 여기서 지우면 다른 기기에서도 사라집니다.", actions: [.reveal]),
        ])
    }

    private func downloads() -> [Entry] {
        [Self.file("Xcode_26.1.xip", 11.8, [.download], hint: "Xcode 설치 파일입니다. 설치를 마쳤으면 휴지통으로 옮겨도 됩니다.", age: 21),
         Self.file("ubuntu-24.04.1-desktop-arm64.iso", 6.1, [.download], hint: "설치 디스크 이미지입니다. 다시 받을 수 있습니다.", age: 50),
         Self.file("Docker.dmg", 0.6, [.download], age: 40), Self.file("FolderBackup-0.3.2.dmg", 0.1, [.download], age: 6),
         Self.file("2026 사업계획서_최종.hwpx", 0.003, [.download], age: 3), Self.blob("카카오톡 받은 파일", 1.3, [.download], files: 620, age: 2),
         Self.blob("기타 412개", 2.2, [.download], files: 412, age: 30)]
    }

    private func documents() -> [Entry] {
        [Self.blob("회사", 3.1, [.userFile], files: 4200, age: 2), Self.blob("Zoom", 2.6, [.userFile], files: 90, hint: "Zoom 녹화본입니다.", age: 33),
         Self.blob("ReMON 자료", 1.2, [.userFile], files: 300, age: 1), Self.blob("계약서", 0.4, [.userFile], files: 160, age: 70),
         Self.file("세무 2025.zip", 0.9, [.userFile], age: 200), Self.blob("기타", 1.0, [.userFile], files: 2100, age: 15)]
    }

    /// 설계도 → DiskNode(폴더 크기·파일 수 = 자식 합, 수정 = 가장 최근 자식). 조치는 태그에서 정한다(적어 둔 것이 우선).
    private func build(_ entry: Entry, parent: String) -> DiskNode {
        let path = parent == "/" ? "/" + entry.name : parent + "/" + entry.name
        let actions = entry.actions ?? Self.defaultActions(entry.tags)
        let hint = entry.hint ?? Self.defaultHint(entry.tags)
        if let children = entry.children {
            let built = children.map { build($0, parent: path) }
            return DiskNode(path: path, name: entry.label ?? entry.name, bytes: built.reduce(0) { $0 + $1.bytes }, fileCount: built.reduce(0) { $0 + $1.fileCount },
                            isDirectory: true, modified: built.compactMap(\.modified).max(), children: built, tags: entry.tags, hint: hint,
                            actions: actions, partial: entry.partial || built.contains(where: \.partial))
        }
        return DiskNode(path: path, name: entry.label ?? entry.name, bytes: UInt64(entry.gb * 1_073_741_824), fileCount: entry.isDirectory ? entry.files : 1,
                        isDirectory: entry.isDirectory, modified: now.addingTimeInterval(-entry.age * 86_400), children: nil,
                        tags: entry.tags, hint: hint, actions: actions, partial: entry.partial)
    }

    /// 가짜 조사기의 조치 규칙(실제 규칙은 DiskTreeScanner가 정한다): 되돌릴 수 있는 쪽이 기본, 영구 삭제는 다시 생기는 것만.
    static func defaultActions(_ tags: Set<DiskTag>) -> [DiskNodeAction] {
        if !tags.isDisjoint(with: [.swap, .snapshot]) { return [.none] }
        if !tags.isDisjoint(with: [.system, .aiTranscript, .trash, .bundle]) { return [.reveal] }
        if tags.contains(.temp) { return [.trash, .reveal] }   // 임시 파일은 실행 중인 앱이 쓰는 중일 수 있어 영구 삭제하지 않는다
        if tags.contains(.userFile) || tags.contains(.backup) || tags.contains(.download) { return [.trash, .reveal] }
        if !tags.isDisjoint(with: [.cache, .regenerable]) { return [.trash, .deletePermanently, .reveal] }
        return [.trash, .reveal]
    }

    static func defaultHint(_ tags: Set<DiskTag>) -> String? {
        if tags.contains(.cache) { return "다시 생기는 캐시입니다. 지워도 필요할 때 다시 만들어집니다." }
        if tags.contains(.regenerable) { return "다시 만들 수 있습니다(설치·빌드 명령으로 되살아남)." }
        if tags.contains(.userFile) { return hintUser }
        if tags.contains(.temp) { return "임시 파일입니다. 휴지통으로 옮길 수 있습니다(영구 삭제 안 함)." }
        if tags.contains(.download) { return "내려받은 파일입니다. 다시 받을 수 있으면 휴지통으로 옮겨도 됩니다." }
        if tags.contains(.aiData) { return "AI 도구 데이터입니다." }
        return nil
    }
}

/// 가짜 조치 실행기: 실제 파일은 건드리지 않고, 실행한 것처럼 결과 문장만 돌려준다(dryRun = 미리보기·기록만).
enum MockDiskActions {
    static let run: DiskMapStore.ActionRunner = { action, node, dryRun in
        Thread.sleep(forTimeInterval: 0.25)
        let size = DiskMapFormat.size(node)
        switch action {
        case .trash:
            return (true, dryRun ? "드라이런 · 휴지통으로 옮길 대상만 기록했습니다 · \(node.name) · \(size)"
                                 : "가짜 실행 · 휴지통으로 옮긴 것으로 표시만 했습니다(실제 파일은 그대로) · \(node.name) · \(size)")
        case .deletePermanently:
            return (true, dryRun ? "드라이런 · 영구 삭제할 대상만 기록했습니다 · \(node.name) · \(size)"
                                 : "가짜 실행 · 영구 삭제한 것으로 표시만 했습니다(실제 파일은 그대로) · \(node.name) · \(size)")
        case .prune:
            if dryRun { return (true, preview(node)) }
            return (true, "가짜 실행 · 정리 명령을 실행한 것으로 표시만 했습니다(실제로 실행하지 않음)")
        case .reveal, .none:
            return (true, "")
        }
    }

    static func preview(_ node: DiskNode) -> String {
        if node.tags.contains(.docker) {
            return "가짜 미리보기 · docker system prune\n· 멈춘 컨테이너 6개\n· 어디에도 안 쓰는 이미지 14개 · 23.1GB\n· 빌드 캐시 9.8GB\n볼륨(데이터베이스 등)은 지우지 않습니다. 가상 디스크 파일 크기는 Docker Desktop이 나중에 줄일 수 있습니다."
        }
        if node.tags.contains(.homebrew) {
            return "가짜 미리보기 · brew cleanup --prune=all\n· 옛 버전 23개 · 4.2GB\n· 내려받기 캐시 2.6GB\n설치된 현재 버전은 그대로 둡니다."
        }
        return "가짜 미리보기 · \(node.name) 정리 명령 — 지울 수 있는 것: \(DiskMapFormat.size(node))"
    }
}
