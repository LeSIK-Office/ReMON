import Darwin
import Foundation

// MARK: - AI 앱 캐시(A 등급: 순수 캐시 — 앱이 꺼져 있을 때만 영구 삭제)

/// 캐시를 쓰는 앱. 앱 번들은 가장 바깥 .app의 Contents/MacOS·Frameworks 안 프로세스만 실행 중으로 본다.
/// 브라우저 확장이 띄운 도우미(Claude.app/Contents/Helpers/chrome-native-host)와 앱이 꺼진 뒤 남는 crashpad 처리기
/// (Cursor·ChatGPT.app의 Frameworks/…/chrome_crashpad_handler)는 캐시를 쓰지 않아 실행으로 보지 않는다(10-25 실측).
/// 그래도 열린 파일이 있으면 SafeFileOps.deletePermanently가 막는다.
public struct AIAppOwner: Sendable, Equatable {
    public var label: String
    public var bundles: [String]
    /// CLI: 프로세스 이름(p_comm) · 실행 경로 조각
    public var processNames: [String] = []
    public var pathFragments: [String] = []

    public static let claudeDesktop = AIAppOwner(label: "Claude", bundles: ["Claude.app"])
    /// Codex 데스크톱 앱은 ChatGPT.app(번들 id com.openai.codex)이다(10-25 실측).
    public static let codexDesktop = AIAppOwner(label: "Codex Desktop", bundles: ["ChatGPT.app", "Codex.app"])
    public static let chatGPT = AIAppOwner(label: "ChatGPT", bundles: ["ChatGPT.app"])
    public static let cursor = AIAppOwner(label: "Cursor", bundles: ["Cursor.app"], processNames: ["cursor-agent"], pathFragments: ["/cursor-agent/"])
    public static let antigravity = AIAppOwner(label: "Antigravity", bundles: ["Antigravity.app"])
    /// Gemini CLI가 띄우는 브라우저(Chrome for Testing 등)는 실행 파일 이름이 제각각이라 경로 조각으로 본다. 그래도 열린 파일이 있으면 지우기가 막힌다.
    public static let geminiBrowser = AIAppOwner(label: "Gemini 브라우저", bundles: [], processNames: [], pathFragments: ["antigravity-browser", "/.gemini/"])
    public static let lmStudio = AIAppOwner(label: "LM Studio", bundles: ["LM Studio.app"])
    public static let claudeCLI = AIAppOwner(label: "Claude Code", bundles: ["ClaudeCode.app"], processNames: ["claude"], pathFragments: ["/.local/share/claude/versions/", "/@anthropic-ai/claude-code/"])
    public static let codexAny = AIAppOwner(label: "Codex", bundles: ["ChatGPT.app", "Codex.app"], processNames: ["codex"], pathFragments: ["/@openai/codex", "/.codex/packages/"])

    /// 지금 이 앱으로 도는 프로세스.
    public func runningPIDs(_ executables: [RunningExecutable]) -> [Int32] {
        executables.filter { executable in
            if processNames.contains(executable.name) { return true }
            for path in [executable.path, executable.execPath].compactMap({ $0 }) {
                if pathFragments.contains(where: { path.contains($0) }) { return true }
                guard let range = path.range(of: ".app/") else { continue }
                let bundle = (String(path[..<range.lowerBound]) as NSString).lastPathComponent + ".app"
                let rest = path[range.upperBound...]
                guard bundles.contains(bundle) else { continue }
                if rest.hasPrefix("Contents/MacOS/") { return true }
                if rest.hasPrefix("Contents/Frameworks/"), !(path as NSString).lastPathComponent.contains("crashpad_handler") { return true }
            }
            return false
        }.map(\.pid)
    }
}

public struct AIAppCache: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var app: String
    /// 캐시 이름(Code Cache · GPUCache …, 프로필 안이면 'Default/Cache')
    public var folder: String
    public var bytes: UInt64
    public var owner: AIAppOwner
    public var keepReason: String?

    public var selectable: Bool { keepReason == nil && bytes > 0 }
    public var regeneration: String { "\(app)을(를) 다시 열면 새로 만듭니다(순수 캐시)" }
}

public enum AIAppCacheCatalog {
    /// ~/Library/Application Support/<폴더>와 주인 앱.
    public static let supportApps: [(folder: String, owner: AIAppOwner)] = [("Claude", .claudeDesktop), ("Codex", .codexDesktop), ("Cursor", .cursor),
                                                                            ("Antigravity", .antigravity), ("com.openai.chat", .chatGPT)]
    /// Chromium 캐시 하위 폴더(이것만 지운다).
    public static let cacheNames = ["Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GraphiteDawnCache",
                                    "component_crx_cache", "extensions_crx_cache", "Shared Dictionary/cache", "Crashpad/completed"]
    /// ~/Library/Caches/<이름>과 주인.
    public static let libraryCaches: [(name: String, owner: AIAppOwner)] = [("com.anthropic.claudefordesktop", .claudeDesktop), ("claude-cli-nodejs", .claudeCLI),
                                                                            ("Codex", .codexAny), ("com.openai.chat", .chatGPT), ("ChatGPTHelper", .chatGPT),
                                                                            ("com.cursor.Cursor", .cursor), ("cursor-compile-cache", .cursor), ("com.lmstudio.lmstudio", .lmStudio)]

    /// 홈 기준 Chromium 프로필(앱 폴더가 Application Support 밖인 것).
    public static let homeProfiles: [(relative: String, owner: AIAppOwner)] = [(".gemini/antigravity-browser-profile", .geminiBrowser)]
    /// 홈 기준 통째 캐시 폴더. Codex 임시(.tmp)는 실행 중인 세션이 쓰므로 Codex가 하나도 안 돌 때만 비운다(10-25 Mole 대조: Mole은 실행 중에도 기본 선택).
    public static let homeCaches: [(relative: String, owner: AIAppOwner)] = [(".codex/.tmp", .codexAny)]

    /// 경로 조각에 캐시 하위 폴더가 들어 있는가(보호 규칙이 캐시는 지나가게 한다). 대소문자는 가리지 않는다.
    public static func containsCacheFolder(_ parts: [String]) -> Bool {
        let names = Set(cacheNames.map { $0.lowercased() })
        let lowered = parts.map { $0.lowercased() }
        for (index, part) in lowered.enumerated() {
            if names.contains(part) { return true }
            if index + 1 < lowered.count, names.contains(part + "/" + lowered[index + 1]) { return true }
        }
        return false
    }

    /// 프로필 폴더(앱 폴더 · Default · Profile N · Partitions/*) 안의 캐시 하위 폴더 + ~/Library/Caches 항목. 크기가 0이면 뺀다.
    public static func scan(paths: AIDataPaths, context: AIDataContext) -> [AIAppCache] {
        var items: [AIAppCache] = []
        for (folder, owner) in supportApps {
            let root = paths.appSupport + "/" + folder
            guard fileType(root) == S_IFDIR else { continue }
            for base in profileFolders(root) {
                for name in cacheNames {
                    let path = base + "/" + name
                    guard fileType(path) == S_IFDIR else { continue }
                    let relative = String(path.dropFirst(root.count + 1))
                    items.append(AIAppCache(path: path, app: owner.label, folder: relative, bytes: DiskScanner.allocatedSize(path), owner: owner, keepReason: nil))
                }
            }
        }
        for (name, owner) in libraryCaches {
            let path = paths.caches + "/" + name
            guard fileType(path) == S_IFDIR else { continue }
            items.append(AIAppCache(path: path, app: owner.label, folder: "Caches/" + name, bytes: DiskScanner.allocatedSize(path), owner: owner, keepReason: nil))
        }
        for (relative, owner) in homeProfiles {
            let root = paths.home + "/" + relative
            guard fileType(root) == S_IFDIR else { continue }
            for base in profileFolders(root) {
                for name in cacheNames where fileType(base + "/" + name) == S_IFDIR {
                    let path = base + "/" + name
                    items.append(AIAppCache(path: path, app: owner.label, folder: String(path.dropFirst(root.count + 1)), bytes: DiskScanner.allocatedSize(path), owner: owner, keepReason: nil))
                }
            }
        }
        for (relative, owner) in homeCaches {
            let path = paths.home + "/" + relative
            guard fileType(path) == S_IFDIR else { continue }
            items.append(AIAppCache(path: path, app: owner.label, folder: relative, bytes: DiskScanner.allocatedSize(path), owner: owner, keepReason: nil))
        }
        return items.filter { $0.bytes > 0 }.map { classify($0, context: context) }.sorted { $0.bytes > $1.bytes }
    }

    public static func classify(_ item: AIAppCache, context: AIDataContext) -> AIAppCache {
        var item = item
        let running = item.owner.runningPIDs(context.executables)
        item.keepReason = running.isEmpty ? nil : "\(item.owner.label) 실행 중 — 끄면 비울 수 있습니다(pid \(running.prefix(3).map(String.init).joined(separator: ",")))"
        return item
    }

    static func profileFolders(_ root: String) -> [String] {
        var folders = [root]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for name in names.sorted() where name == "Default" || name.hasPrefix("Profile ") {
            if fileType(root + "/" + name) == S_IFDIR { folders.append(root + "/" + name) }
        }
        let partitions = root + "/Partitions"
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: partitions)) ?? []).sorted() where fileType(partitions + "/" + name) == S_IFDIR {
            folders.append(partitions + "/" + name)
        }
        return folders
    }

    /// 실행 직전 모양 확인: 알려진 앱 폴더 안의 캐시 하위 폴더 또는 알려진 ~/Library/Caches 항목만.
    public static func isKnownCache(_ path: String, paths: AIDataPaths) -> Bool {
        if libraryCaches.contains(where: { paths.caches + "/" + $0.name == path }) { return true }
        if homeCaches.contains(where: { paths.home + "/" + $0.relative == path }) { return true }
        for (relative, _) in homeProfiles {
            let root = paths.home + "/" + relative
            if path.hasPrefix(root + "/"), profileFolders(root).contains(where: { base in cacheNames.contains { base + "/" + $0 == path } }) { return true }
        }
        for (folder, _) in supportApps {
            let root = paths.appSupport + "/" + folder
            guard path.hasPrefix(root + "/") else { continue }
            let relative = String(path.dropFirst(root.count + 1))
            return profileFolders(root).contains { base in cacheNames.contains { base + "/" + $0 == path } } && !relative.isEmpty
        }
        return false
    }
}

// MARK: - 이전 CLI 버전(B 등급: 현재 아님 · 아무도 실행하지 않음일 때만 영구 삭제)

public struct CLIVersion: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var tool: String
    /// versions · standalone · app-server-daemon
    public var channel: String
    public var version: String
    public var current: String?
    public var bytes: UInt64
    public var isCurrent: Bool
    public var inUse: [Int32]
    public var keepReason: String?

    public var selectable: Bool { keepReason == nil }
    public var regeneration: String { "현재 버전 \(current ?? "-")을(를) 씁니다 — 이전 버전이 필요하면 다시 설치합니다" }
}

public enum CLIVersionCatalog {
    /// Claude: ~/.local/share/claude/versions/*(파일) — 현재 = ~/.local/bin/claude가 가리키는 것.
    /// Codex: ~/.codex/packages/{standalone,app-server-daemon}/(releases/)* — 현재 = 묶음의 current 링크.
    public static func scan(paths: AIDataPaths, options: AIDataOptions, context: AIDataContext) -> [CLIVersion] {
        var items: [CLIVersion] = []
        if fileType(paths.claudeVersions) == S_IFDIR {
            let launcher = fileType(paths.claudeLauncher) != nil ? SafeFileOps.canonical(paths.claudeLauncher) : nil
            let directory = SafeFileOps.canonical(paths.claudeVersions)
            let current = launcher.flatMap { (($0 as NSString).deletingLastPathComponent == directory) ? $0 : nil }
            items += versions(in: paths.claudeVersions, tool: "Claude Code", channel: "versions", current: current,
                              currentNote: "현재 버전을 ~/.local/bin/claude로 확인하지 못했습니다", options: options, context: context)
        }
        for root in paths.codexPackageRoots where fileType(root) == S_IFDIR {
            let releases = root + "/releases"
            let folder = fileType(releases) == S_IFDIR ? releases : root
            let link = root + "/current"
            let current = fileType(link) != nil ? SafeFileOps.canonical(link) : nil
            items += versions(in: folder, tool: "Codex", channel: (root as NSString).lastPathComponent, current: current,
                              currentNote: "현재 버전 링크(current)를 확인하지 못했습니다", options: options, context: context)
        }
        // Cursor Agent: 독립 설치와 Cursor 앱 안 설치가 따로 버전을 쌓는다. 현재 = 같은 묶음의 .local/bin/cursor-agent 링크가 가리키는 버전 폴더(10-25 실측).
        for (folder, launcher, channel) in paths.cursorAgentRoots where fileType(folder) == S_IFDIR {
            let target = fileType(launcher) != nil ? SafeFileOps.canonical(launcher) : nil
            let directory = SafeFileOps.canonical(folder)
            let current = target.flatMap { (($0 as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent == directory ? ($0 as NSString).deletingLastPathComponent : nil }
            items += versions(in: folder, tool: "Cursor Agent", channel: channel, current: current,
                              currentNote: "현재 버전을 .local/bin/cursor-agent 링크로 확인하지 못했습니다", options: options, context: context)
        }
        return items.sorted { lhs, rhs in lhs.tool != rhs.tool ? lhs.tool < rhs.tool : versionKey(lhs.version).lexicographicallyPrecedes(versionKey(rhs.version)) }
    }

    static func versions(in folder: String, tool: String, channel: String, current: String?, currentNote: String, options: AIDataOptions, context: AIDataContext) -> [CLIVersion] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let currentName = current.map { ($0 as NSString).lastPathComponent }
        return names.filter { $0.first?.isNumber == true && $0.contains(".") }.sorted().compactMap { name in
            let path = folder + "/" + name
            guard let type = fileType(path), type == S_IFREG || type == S_IFDIR else { return nil }
            var item = CLIVersion(path: path, tool: tool, channel: channel, version: name, current: currentName, bytes: DiskScanner.allocatedSize(path),
                                  isCurrent: current == SafeFileOps.canonical(path), inUse: [], keepReason: nil)
            classify(&item, type: type, currentNote: currentNote, options: options, context: context)
            return item
        }
    }

    /// 남기는 이유: 현재 · 실행 중 · 현재보다 새 버전 · 하드링크 · 24시간 안에 설치 · 현재 버전 모름.
    static func classify(_ item: inout CLIVersion, type: mode_t, currentNote: String, options: AIDataOptions, context: AIDataContext) {
        item.inUse = users(of: item.path, isDirectory: type == S_IFDIR, executables: context.executables)
        var info = stat()
        lstat(item.path, &info)
        let installed = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        if item.isCurrent {
            item.keepReason = "현재 버전입니다"
        } else if !item.inUse.isEmpty {
            item.keepReason = "실행 중인 프로세스 \(item.inUse.count)개가 이 버전을 씁니다(pid \(item.inUse.prefix(4).map(String.init).joined(separator: ",")))"
        } else if item.current == nil {
            item.keepReason = currentNote
        } else if let current = item.current, versionKey(current).lexicographicallyPrecedes(versionKey(item.version)) {
            item.keepReason = "현재보다 새 버전입니다(업데이트 대기일 수 있음)"
        } else if type == S_IFREG, info.st_nlink > 1 {
            item.keepReason = "다른 곳(ClaudeCode.app 등)과 같은 파일(하드링크)이라 지워도 공간이 돌아오지 않습니다"
        } else if context.now.timeIntervalSince(installed) < options.recentGuard {
            item.keepReason = "최근 24시간 안에 설치됐습니다"
        }
    }

    /// 이 버전(파일 또는 폴더)에서 실행 중인 프로세스: 경로가 같거나 아래이거나, 실행 파일 inode가 같다(하드링크).
    public static func users(of path: String, isDirectory: Bool, executables: [RunningExecutable]) -> [Int32] {
        let canonical = SafeFileOps.canonical(path)
        var identities = Set<FileIdentity>()
        if isDirectory {
            if let walker = FileManager.default.enumerator(atPath: path) {
                var count = 0
                while let relative = walker.nextObject() as? String, count < 5000 {
                    count += 1
                    if fileType(path + "/" + relative) == S_IFREG, let identity = FileIdentity(path: path + "/" + relative) { identities.insert(identity) }
                }
            }
        } else if let identity = FileIdentity(path: path) {
            identities.insert(identity)
        }
        return executables.filter { executable in
            if let identity = executable.identity, identities.contains(identity) { return true }
            for candidate in [executable.path, executable.execPath].compactMap({ $0 }) {
                if candidate == canonical || (isDirectory && candidate.hasPrefix(canonical + "/")) { return true }
            }
            return false
        }.map(\.pid)
    }

    /// "2.1.310" · "0.163.0-aarch64-apple-darwin" → [2, 1, 310]
    static func versionKey(_ name: String) -> [Int] {
        let core = name.split(separator: "-").first.map(String.init) ?? name
        return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
