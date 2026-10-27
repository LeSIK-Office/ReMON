import Darwin
import Foundation

/// 이 Mac에 설치된 에이전트 CLI 한 줄: 실행 파일 · 버전 · 데이터 폴더 · 이어 열기 지원.
public struct AgentInstall: Sendable, Equatable, Identifiable {
    public var kind: AgentKind
    public var id: String { kind.rawValue }
    /// 검색 순서대로 처음 찾은 실행 파일(nil = 설치 안 됨)
    public var path: String?
    /// 링크를 따라간 실제 파일
    public var resolvedPath: String?
    /// 같은 명령이 더 있는 곳(예: Homebrew와 nvm에 둘 다)
    public var otherPaths: [String] = []
    /// 이름만 같고 근거가 없다 — 같은 이름의 다른 도구일 수 있다(AWS copilot · pressly goose).
    public var nameOnly = false
    public var version: String?
    /// 버전을 읽은 곳("설치 경로" · "package.json" · "--version")
    public var versionSource: String?
    /// 처음 찾은 데이터 폴더(~ 표기)
    public var dataFolder: String?
    public var resume: AgentSignature.Resume

    public var installed: Bool { path != nil }
}

/// 설치 확인은 파일 시스템을 훑고, 버전 확인은 프로세스를 띄울 수도 있다 → 백그라운드에서 부르고 결과를 캐시한다(주기마다 부르지 않는다).
public enum AgentInventory {
    /// 사양의 검색 폴더(Homebrew · /usr/local · ~/.local · npm 전역 · bun · cargo · volta) + nvm 노드 버전별 bin(최신 먼저) + 흔한 버전 관리자 위치.
    public static func searchDirectories(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        var directories = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.npm-global/bin", home + "/.bun/bin", home + "/.cargo/bin", home + "/.volta/bin"]
        let nvm = home + "/.nvm/versions/node"
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: nvm)) ?? []).sorted { lhs, rhs in
            lhs.compare(rhs, options: .numeric) == .orderedDescending
        }
        directories += versions.map { nvm + "/" + $0 + "/bin" }
        directories += [home + "/.local/share/mise/shims", home + "/.asdf/shims", home + "/Library/pnpm", home + "/.yarn/bin", home + "/.deno/bin", home + "/.amp/bin", "/opt/local/bin"]
        return directories
    }

    /// 표 전체(+직접 추가)를 훑는다. probeVersions면 정적 판독이 안 될 때만 `<명령> --version`을 실행한다(네트워크 차단 샌드박스 · 4초 제한 · 결과 캐시).
    public static func scan(signatures: [AgentSignature] = AgentSignatures.all, custom: [CustomAgent] = [], probeVersions: Bool = true,
                            home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [AgentInstall] {
        let directories = searchDirectories(home: home)
        var rows: [AgentInstall] = []
        for signature in signatures {
            var row = AgentInstall(kind: signature.kind, resume: signature.resume)
            let found = signature.commands.flatMap { command in directories.map { $0 + "/" + command } }.filter { FileManager.default.isExecutableFile(atPath: $0) }
            if let first = found.first {
                row.path = first
                let resolved = (first as NSString).resolvingSymlinksInPath
                row.resolvedPath = resolved == first ? nil : resolved
                row.otherPaths = Array(found.dropFirst())
                if signature.nameNeedsEvidence {
                    row.nameOnly = !signature.markers.contains { marker in first.contains(marker) || resolved.contains(marker) }
                }
                if let (version, source) = staticVersion(resolved: resolved) {
                    row.version = version
                    row.versionSource = source
                } else if probeVersions, !row.nameOnly, let version = probeVersion(first, resolved: resolved) {
                    row.version = version
                    row.versionSource = "--version"
                }
            }
            row.dataFolder = signature.dataFolders.first { FileManager.default.fileExists(atPath: expand($0, home: home)) }
            rows.append(row)
        }
        // 직접 추가: 프로세스 이름으로 실행 파일만 찾는다. 사용자가 정한 프로그램이라 --version을 함부로 실행하지 않는다.
        for agent in custom {
            var row = AgentInstall(kind: agent.kind, resume: .unknown)
            if !agent.processName.isEmpty, let first = directories.map({ $0 + "/" + agent.processName }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                row.path = first
                let resolved = (first as NSString).resolvingSymlinksInPath
                row.resolvedPath = resolved == first ? nil : resolved
                if let (version, source) = staticVersion(resolved: resolved) { row.version = version; row.versionSource = source }
            }
            rows.append(row)
        }
        return rows
    }

    static func expand(_ path: String, home: String) -> String {
        path.hasPrefix("~") ? home + path.dropFirst() : path
    }

    /// 프로세스를 띄우지 않고 읽는 버전: 설치 경로(…/versions/<v>/ · Homebrew Cellar/<이름>/<v>/) 또는 가장 가까운 package.json.
    public static func staticVersion(resolved: String) -> (String, String)? {
        let parts = resolved.split(separator: "/").map(String.init)
        if let index = parts.lastIndex(of: "versions"), index + 1 < parts.count, parseVersion(parts[index + 1]) != nil {
            return (parts[index + 1], "설치 경로")
        }
        if let index = parts.firstIndex(of: "Cellar"), index + 2 < parts.count, parseVersion(parts[index + 2]) != nil {
            return (parts[index + 2], "설치 경로")
        }
        if resolved.contains("/node_modules/") {
            var directory = (resolved as NSString).deletingLastPathComponent
            for _ in 0..<4 {
                let manifest = directory + "/package.json"
                if let data = FileManager.default.contents(atPath: manifest),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = object["version"] as? String, object["name"] != nil {
                    return (version, "package.json")
                }
                directory = (directory as NSString).deletingLastPathComponent
            }
        }
        return nil
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var probeCache: [String: String?] = [:]

    /// `<명령> --version`을 한 번 실행한다. 네트워크를 막은 샌드박스(sandbox-exec)에서 4초 제한, 결과는 파일 수정 시각까지 묶어 캐시한다.
    /// 앱에서 실행되면 PATH가 짧아 `#!/usr/bin/env node`가 실패하므로 실행 파일 폴더와 nvm 노드 폴더를 PATH 앞에 둔다.
    public static func probeVersion(_ executable: String, resolved: String? = nil, timeout: TimeInterval = 4) -> String? {
        var info = stat()
        let stamp = stat(resolved ?? executable, &info) == 0 ? "\(info.st_mtimespec.tv_sec)" : "?"
        let key = executable + "|" + stamp
        cacheLock.lock()
        if let cached = probeCache[key] { cacheLock.unlock(); return cached }
        cacheLock.unlock()
        var environment = ProcessInfo.processInfo.environment
        let folders = [(executable as NSString).deletingLastPathComponent] + (resolved.map { [($0 as NSString).deletingLastPathComponent] } ?? [])
        let extra = searchDirectories().filter { $0.contains("/.nvm/") }.prefix(1)
        environment["PATH"] = (folders + extra + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        environment["NO_COLOR"] = "1"
        let sandbox = "/usr/bin/sandbox-exec"
        let result = FileManager.default.isExecutableFile(atPath: sandbox)
            ? Shell.capture(sandbox, ["-p", "(version 1)(allow default)(deny network*)", executable, "--version"], environment: environment, timeout: timeout)
            : Shell.capture(executable, ["--version"], environment: environment, timeout: timeout)
        let version = result.succeeded ? parseVersion(result.stdout) ?? parseVersion(result.stderr) : nil
        cacheLock.lock()
        probeCache[key] = .some(version)
        cacheLock.unlock()
        return version
    }

    /// 출력에서 첫 버전 모양(1.2 · 1.2.3 · 2026.10.01-e373342)을 고른다.
    public static func parseVersion(_ text: String) -> String? {
        guard let range = text.range(of: #"\d+\.\d+(\.\d+)?([-+][0-9A-Za-z.\-]+)?"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// 화면용: 홈을 ~로 줄인다.
    public static func abbreviate(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
