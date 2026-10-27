import Darwin
import Foundation

// 개발 캐시 카탈로그 — "어디가 무엇이고, 지워도 되는지"를 코드가 아니라 표로 둔다.
// 등급: A 순수 캐시(영구 삭제 · 도구가 다시 받음) · B 다시 빌드·설치해야 생김(쉬는 것만) · C 지우지 않음(보기만).
// 주인 앱·프로세스가 실행 중이면 건너뛰고 이유를 보여 준다. 기본 제외 항목은 묶음·자동 정리에 끼지 않는다.

/// 화면의 소제목(순서대로 보인다).
public enum CatalogGroup: String, Sendable, CaseIterable, Codable {
    case xcode, packages, homebrew, simulators, editors, apps, browsers, logs, projects, temporary, excluded

    public var label: String {
        switch self {
        case .xcode: "Xcode"
        case .packages: "패키지 관리자"
        case .homebrew: "Homebrew"
        case .simulators: "시뮬레이터"
        case .editors: "편집기(VS Code·Cursor)"
        case .apps: "앱 캐시(Electron 앱 · Library/Caches)"
        case .browsers: "브라우저 캐시"
        case .logs: "오래된 로그"
        case .projects: "프로젝트 빌드 산출물"
        case .temporary: "임시 파일"
        case .excluded: "기본 제외"
        }
    }
}

/// 파일을 직접 지우는 대신 도구에게 맡기는 정리. 사용자 계정으로 실행하고, 확인을 받은 뒤에만 돈다.
public struct ToolCommand: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    /// 찾을 실행 파일 이름(brew · pnpm · xcrun · docker · go)
    public var tool: String
    public var arguments: [String]
    /// 읽기 전용 미리보기(드라이런 때 이것만 돈다). nil이면 미리보기 없음.
    public var previewArguments: [String]?
    public var detail: String
    /// 금고에 남길 재생성 방법
    public var restoreHint: String
    public var timeout: TimeInterval
    /// 실행 전에 성공해야 하는 확인 명령의 인자(같은 도구). 예: xcrun --find simctl
    public var requirement: [String]?
    /// 확인 명령이 실패했을 때 보여 줄 이유
    public var requirementNote: String?

    public init(id: String, title: String, tool: String, arguments: [String], previewArguments: [String]?, detail: String, restoreHint: String,
                timeout: TimeInterval, requirement: [String]? = nil, requirementNote: String? = nil) {
        self.id = id
        self.title = title
        self.tool = tool
        self.arguments = arguments
        self.previewArguments = previewArguments
        self.detail = detail
        self.restoreHint = restoreHint
        self.timeout = timeout
        self.requirement = requirement
        self.requirementNote = requirementNote
    }

    /// 사람이 그대로 칠 수 있는 한 줄.
    public var commandLine: String { ([tool] + arguments).map(ResumeKey.quote).joined(separator: " ") }
}

public struct CatalogEntry: Sendable, Identifiable {
    public enum Expansion: Sendable, Equatable {
        /// 경로 하나 = 항목 하나
        case whole
        /// 바로 아래 폴더 하나씩(DeviceSupport의 OS 버전 폴더)
        case children
        /// 프로젝트 폴더마다: info.plist의 WorkspacePath가 없으면 A(삭제된 프로젝트), 있으면 B, *.noindex는 A
        case derivedData
        /// 폴더가 사라진 작업 공간(workspace.json)만
        case workspaceStorage
        /// 브라우저 프로필의 Cache·Code Cache·GPUCache·ShaderCache·GrShaderCache만
        case browserProfiles
        /// days일 넘게 아무것도 쓰지 않은 로그(폴더는 가장 최근 수정 기준). skip은 다른 항목이 맡는 이름.
        case oldLogs(days: Double, skip: [String])
        /// days일 지난 파일 하나씩(진단 보고서)
        case oldFiles(days: Double)
        /// ~/Library/Application Support/<앱>(과 Partitions/*)의 Chromium 캐시 하위 폴더. skip = 다른 항목이 맡는 앱 폴더.
        case electronApps(skip: [String])
        /// 같은 앱들의 Service Worker 저장소(오프라인 웹 데이터 — 기본 제외)
        case electronServiceWorkers(skip: [String])
        /// ~/Library/Caches/<이름> 하나씩. skip = 다른 항목이 맡는 이름. com.apple.*·memory는 보기만.
        case libraryCaches(skip: [String])
    }

    public var id: String
    public var group: CatalogGroup
    public var title: String
    /// 홈 기준 경로. 한 단계 안에서 '*' 글롭을 쓴다(예: Library/Developer/Xcode/*DeviceSupport).
    public var paths: [String]
    public var grade: DiskGrade
    public var owner: CacheOwner?
    public var defaultExcluded: Bool
    public var hint: String
    public var expansion: Expansion
    /// 파일 대신 권장하는 명령(있으면 파일은 영구 삭제하지 않는다).
    public var command: ToolCommand?
    /// 영구 삭제 대신 휴지통(다시 생기지 않는 상태가 섞인 것 — 고아 작업 공간).
    public var trashPreferred: Bool

    public init(id: String, group: CatalogGroup, title: String, paths: [String], grade: DiskGrade, owner: CacheOwner? = nil, defaultExcluded: Bool = false,
                hint: String, expansion: Expansion = .whole, command: ToolCommand? = nil, trashPreferred: Bool = false) {
        self.id = id
        self.group = group
        self.title = title
        self.paths = paths
        self.grade = grade
        self.owner = owner
        self.defaultExcluded = defaultExcluded
        self.hint = hint
        self.expansion = expansion
        self.command = command
        self.trashPreferred = trashPreferred
    }
}

// MARK: - 주인 · 명령

public enum CacheOwners {
    public static let xcode = CacheOwner("Xcode", bundleIDs: ["com.apple.dt.Xcode"], processNames: ["Xcode", "xcodebuild", "XCBBuildService", "SWBBuildService"])
    public static let simulator = CacheOwner("시뮬레이터", bundleIDs: ["com.apple.iphonesimulator"], processNames: ["Simulator", "launchd_sim"])
    public static let swiftPM = CacheOwner("SwiftPM", processNames: ["swift-build", "swift-package", "swift-test", "swift-run"])
    public static let cocoaPods = CacheOwner("CocoaPods", processNames: ["pod"], commandMarkers: ["/bin/pod ", "cocoapods-"])
    public static let npm = CacheOwner("npm", processNames: ["npm", "npx"], commandMarkers: ["/bin/npm", "npm-cli.js", "/bin/npx", "npx-cli.js"])
    public static let yarn = CacheOwner("Yarn", processNames: ["yarn"], commandMarkers: ["/bin/yarn", "yarn.js", "yarn.cjs"])
    public static let pnpm = CacheOwner("pnpm", processNames: ["pnpm"], commandMarkers: ["/bin/pnpm", "pnpm.cjs", "pnpm.mjs"])
    public static let bun = CacheOwner("Bun", processNames: ["bun"])
    public static let deno = CacheOwner("Deno", processNames: ["deno"])
    public static let go = CacheOwner("Go", processNames: ["go", "gopls"])
    public static let cargo = CacheOwner("Cargo", processNames: ["cargo", "rustc"])
    public static let gradle = CacheOwner("Gradle", processNames: ["gradle"], commandMarkers: ["GradleDaemon", "GradleWrapperMain", "org.gradle.launcher"])
    public static let conda = CacheOwner("conda", processNames: ["conda", "mamba", "micromamba"], commandMarkers: ["/bin/conda"])
    public static let dart = CacheOwner("Dart·Flutter", processNames: ["dart", "flutter"])
    public static let dotnet = CacheOwner(".NET", processNames: ["dotnet"])
    public static let homebrew = CacheOwner("Homebrew", processNames: ["brew"], commandMarkers: ["Homebrew/brew.rb", "/bin/brew "])
    public static let vscode = CacheOwner("VS Code", bundleIDs: ["com.microsoft.VSCode"])
    public static let cursor = CacheOwner("Cursor", bundleIDs: ["com.todesktop.230313mzl4w4u92"], processNames: ["Cursor"])
}

public enum ToolCommands {
    public static let brewCleanup = ToolCommand(id: "brew-cleanup", title: "brew cleanup", tool: "brew", arguments: ["cleanup"], previewArguments: ["cleanup", "-n"],
                                                detail: "Homebrew 이전 버전과 오래된 다운로드를 Homebrew가 직접 지웁니다", restoreHint: "필요하면 brew install로 다시 설치합니다", timeout: 600)
    public static let pnpmPrune = ToolCommand(id: "pnpm-prune", title: "pnpm store prune", tool: "pnpm", arguments: ["store", "prune"], previewArguments: ["store", "path"],
                                              detail: "어느 프로젝트도 쓰지 않는 패키지만 저장소에서 지웁니다", restoreHint: "pnpm install이 필요할 때 다시 받습니다", timeout: 600)
    public static let simctlUnavailable = ToolCommand(id: "simctl-unavailable", title: "xcrun simctl delete unavailable", tool: "xcrun", arguments: ["simctl", "delete", "unavailable"],
                                                      previewArguments: ["simctl", "list", "devices", "unavailable"], detail: "런타임이 없어 쓸 수 없는 시뮬레이터만 지웁니다",
                                                      restoreHint: "Xcode에서 시뮬레이터를 다시 만듭니다", timeout: 180, requirement: ["--find", "simctl"],
                                                      requirementNote: "Xcode가 없어 simctl을 쓸 수 없습니다(Command Line Tools만 설치됨)")
    public static let goModClean = ToolCommand(id: "go-modcache", title: "go clean -modcache", tool: "go", arguments: ["clean", "-modcache"], previewArguments: ["env", "GOMODCACHE"],
                                               detail: "Go 모듈 캐시를 Go가 직접 지웁니다(파일이 읽기 전용이라 직접 지우면 실패합니다)", restoreHint: "go build가 모듈을 다시 받습니다", timeout: 600)
    public static let dockerPrune = ToolCommand(id: "docker-prune", title: "docker system prune", tool: "docker", arguments: ["system", "prune", "-f"], previewArguments: ["system", "df"],
                                                detail: "멈춘 컨테이너 · 안 쓰는 네트워크 · 이름 없는 이미지 · 빌드 캐시를 지웁니다(볼륨과 태그 있는 이미지는 남김)",
                                                restoreHint: "필요하면 docker pull·docker build로 다시 받습니다", timeout: 600)

    /// 화면에 '명령' 줄로 보이는 것(경로 항목과 별개로 크기를 미리 알 수 없는 정리).
    public static let catalogCommands: [ToolCommand] = [brewCleanup, simctlUnavailable]

    /// 앱은 로그인 셸 PATH를 모른다 — 흔한 설치 위치를 직접 본다(nvm은 가장 새 버전).
    public static func locate(_ tool: String, home: String = NSHomeDirectory()) -> String? {
        if tool == "xcrun" { return FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") ? "/usr/bin/xcrun" : nil }
        var folders = ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.local/share/pnpm", home + "/Library/pnpm", home + "/.bun/bin", home + "/.volta/bin",
                       home + "/.cargo/bin", home + "/go/bin", "/usr/local/go/bin", home + "/.docker/bin", home + "/.orbstack/bin",
                       "/Applications/Docker.app/Contents/Resources/bin", "/Applications/OrbStack.app/Contents/MacOS/xbin", "/usr/bin"]
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            folders.insert(contentsOf: sorted.map { nvm + "/" + $0 + "/bin" }, at: 2)
        }
        return folders.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 실행할 수 있는가: (실행 파일, 못 하는 이유).
    public static func availability(_ command: ToolCommand, home: String = NSHomeDirectory(), runner: CommandRunner? = nil) -> (path: String?, reason: String?) {
        guard let path = locate(command.tool, home: home) else { return (nil, "\(command.tool)를 찾지 못했습니다") }
        if let requirement = command.requirement {
            let result = (runner ?? defaultRunner(toolPath: path))(path, requirement, 15)
            if !result.succeeded { return (nil, command.requirementNote ?? "\(command.tool) 확인에 실패했습니다") }
        }
        return (path, nil)
    }

    /// 실행. preview면 읽기 전용 미리보기 인자로 돈다. 표준 입력은 닫혀 있어 프롬프트에서 멈추지 않는다.
    public static func run(_ command: ToolCommand, preview: Bool, home: String = NSHomeDirectory(), runner: CommandRunner? = nil) -> CommandResult {
        let available = availability(command, home: home, runner: runner)
        guard let path = available.path else { return CommandResult(status: 127, stderr: available.reason ?? "실행할 수 없습니다") }
        let arguments = preview ? (command.previewArguments ?? []) : command.arguments
        guard !arguments.isEmpty else { return CommandResult(status: 0, stdout: "미리보기가 없는 명령입니다") }
        return (runner ?? defaultRunner(toolPath: path))(path, arguments, command.timeout)
    }

    /// 도구가 있는 폴더를 PATH 앞에 둔다(nvm의 pnpm은 같은 폴더의 node가 필요하다). Homebrew 자동 업데이트·분석은 끈다.
    static func defaultRunner(toolPath: String) -> CommandRunner {
        var environment = ProcessInfo.processInfo.environment
        let folder = (toolPath as NSString).deletingLastPathComponent
        environment["PATH"] = ([folder, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ANALYTICS"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NO_COLOR"] = "1"
        let fixed = environment
        return { executable, arguments, timeout in
            if (executable as NSString).lastPathComponent == "brew" {
                return Shell.capture("/usr/bin/sandbox-exec", ["-p", "(version 1)(allow default)(deny network*)", executable] + arguments, environment: fixed, timeout: timeout)
            }
            return Shell.capture(executable, arguments, environment: fixed, timeout: timeout)
        }
    }
}

// MARK: - 표

public enum DiskCatalog {
    static let browserHint = "브라우저가 다시 받습니다(로그인·방문 기록·쿠키는 그대로)"

    public static let entries: [CatalogEntry] = [
        // Xcode
        CatalogEntry(id: "xcode.derivedData", group: .xcode, title: "DerivedData", paths: ["Library/Developer/Xcode/DerivedData"], grade: .b, owner: CacheOwners.xcode,
                     hint: "Xcode가 다음 빌드 때 다시 만듭니다(전체 빌드·색인)", expansion: .derivedData),
        CatalogEntry(id: "xcode.deviceSupport", group: .xcode, title: "DeviceSupport", paths: ["Library/Developer/Xcode/*DeviceSupport"], grade: .b, owner: CacheOwners.xcode,
                     hint: "기기를 다시 연결하면 Xcode가 기호 파일을 다시 복사합니다", expansion: .children),
        CatalogEntry(id: "xcode.deviceLogs", group: .xcode, title: "기기 로그", paths: ["Library/Developer/Xcode/DeviceLogs", "Library/Developer/Xcode/iOS Device Logs"], grade: .a,
                     owner: CacheOwners.xcode, hint: "기기에서 가져온 로그 사본입니다(지워도 됩니다)"),
        CatalogEntry(id: "xcode.documentation", group: .xcode, title: "문서 캐시", paths: ["Library/Developer/Xcode/DocumentationCache"], grade: .a, owner: CacheOwners.xcode,
                     hint: "Xcode가 문서를 열 때 다시 받습니다"),
        // 패키지 관리자
        CatalogEntry(id: "swiftpm.cache", group: .packages, title: "SwiftPM 캐시", paths: ["Library/Caches/org.swift.swiftpm"], grade: .a, owner: CacheOwners.swiftPM,
                     hint: "swift build가 필요할 때 다시 받습니다"),
        CatalogEntry(id: "cocoapods.cache", group: .packages, title: "CocoaPods 캐시", paths: ["Library/Caches/CocoaPods"], grade: .a, owner: CacheOwners.cocoaPods,
                     hint: "pod install이 필요할 때 다시 받습니다"),
        CatalogEntry(id: "npm.cache", group: .packages, title: "npm 캐시", paths: [".npm/_cacache"], grade: .a, owner: CacheOwners.npm, hint: "npm이 필요할 때 다시 받습니다"),
        CatalogEntry(id: "npm.npx", group: .packages, title: "npx 캐시", paths: [".npm/_npx"], grade: .a, owner: CacheOwners.npm, hint: "npx가 다음 실행 때 다시 받습니다"),
        CatalogEntry(id: "yarn.cache", group: .packages, title: "Yarn 캐시", paths: ["Library/Caches/Yarn", ".cache/yarn", ".yarn/cache", ".yarn/berry/cache"], grade: .a,
                     owner: CacheOwners.yarn, hint: "Yarn이 필요할 때 다시 받습니다"),
        CatalogEntry(id: "bun.cache", group: .packages, title: "Bun 캐시", paths: [".bun/install/cache"], grade: .a, owner: CacheOwners.bun, hint: "bun install이 필요할 때 다시 받습니다"),
        CatalogEntry(id: "deno.cache", group: .packages, title: "Deno 캐시", paths: ["Library/Caches/deno", ".cache/deno"], grade: .a, owner: CacheOwners.deno,
                     hint: "Deno가 필요할 때 다시 받습니다"),
        CatalogEntry(id: "go.build", group: .packages, title: "Go 빌드 캐시", paths: ["Library/Caches/go-build", ".cache/go-build"], grade: .a, owner: CacheOwners.go,
                     hint: "go build가 다시 만듭니다"),
        CatalogEntry(id: "pnpm.metadata", group: .packages, title: "pnpm 메타데이터 캐시", paths: ["Library/Caches/pnpm", ".cache/pnpm"], grade: .a, owner: CacheOwners.pnpm,
                     hint: "pnpm이 필요할 때 다시 받습니다"),
        CatalogEntry(id: "pnpm.store", group: .packages, title: "pnpm 저장소", paths: ["Library/pnpm/store", ".local/share/pnpm/store"], grade: .b, owner: CacheOwners.pnpm,
                     hint: "pnpm store prune으로 안 쓰는 패키지만 지웁니다(통째로 지우면 공간이 거의 안 돌아옵니다)", command: ToolCommands.pnpmPrune),
        CatalogEntry(id: "go.modules", group: .packages, title: "Go 모듈", paths: ["go/pkg/mod"], grade: .b, owner: CacheOwners.go,
                     hint: "go clean -modcache로 지웁니다", command: ToolCommands.goModClean),
        CatalogEntry(id: "cargo.registry", group: .packages, title: "Cargo 레지스트리", paths: [".cargo/registry", ".cargo/git"], grade: .b, owner: CacheOwners.cargo,
                     hint: "cargo build가 다시 받습니다"),
        CatalogEntry(id: "gradle.caches", group: .packages, title: "Gradle 캐시", paths: [".gradle/caches", ".gradle/daemon", ".gradle/wrapper/dists"], grade: .b,
                     owner: CacheOwners.gradle, hint: "Gradle이 다음 빌드 때 다시 받습니다"),
        CatalogEntry(id: "conda.pkgs", group: .packages, title: "conda 패키지", paths: [".conda/pkgs", "miniconda3/pkgs", "anaconda3/pkgs", "miniforge3/pkgs"], grade: .b,
                     owner: CacheOwners.conda, hint: "conda가 필요할 때 다시 받습니다(conda clean과 같습니다)"),
        CatalogEntry(id: "dart.pub", group: .packages, title: "Dart pub 캐시", paths: [".pub-cache"], grade: .b, owner: CacheOwners.dart, hint: "dart pub get이 다시 받습니다"),
        CatalogEntry(id: "nuget.packages", group: .packages, title: "NuGet 패키지", paths: [".nuget/packages"], grade: .b, owner: CacheOwners.dotnet, hint: "dotnet restore가 다시 받습니다"),
        // Homebrew
        CatalogEntry(id: "brew.cache", group: .homebrew, title: "Homebrew 다운로드", paths: ["Library/Caches/Homebrew/downloads", "Library/Caches/Homebrew/Cask",
                                                                                         "Library/Caches/Homebrew/bootsnap", "Library/Caches/Homebrew/api"],
                     grade: .a, owner: CacheOwners.homebrew, hint: "Homebrew가 필요할 때 다시 받습니다"),
        CatalogEntry(id: "brew.logs", group: .homebrew, title: "Homebrew 로그", paths: ["Library/Logs/Homebrew"], grade: .a, owner: CacheOwners.homebrew,
                     hint: "설치 기록 로그입니다(지워도 됩니다)"),
        // 시뮬레이터
        CatalogEntry(id: "simulator.devices", group: .simulators, title: "시뮬레이터 기기", paths: ["Library/Developer/CoreSimulator/Devices"], grade: .b, owner: CacheOwners.simulator,
                     hint: "쓸 수 없는 시뮬레이터만 xcrun simctl로 지웁니다", command: ToolCommands.simctlUnavailable),
        CatalogEntry(id: "simulator.caches", group: .simulators, title: "시뮬레이터 캐시", paths: ["Library/Developer/CoreSimulator/Caches"], grade: .a, owner: CacheOwners.simulator,
                     hint: "시뮬레이터가 다음 부팅 때 다시 만듭니다"),
        // 편집기
        CatalogEntry(id: "vscode.cache", group: .editors, title: "VS Code 캐시", paths: ["Library/Application Support/Code/Cache", "Library/Application Support/Code/CachedData",
                                                                                     "Library/Application Support/Code/Code Cache", "Library/Application Support/Code/GPUCache"],
                     grade: .a, owner: CacheOwners.vscode, hint: "VS Code가 다음 실행 때 다시 만듭니다"),
        CatalogEntry(id: "cursor.cache", group: .editors, title: "Cursor 캐시", paths: ["Library/Application Support/Cursor/Cache", "Library/Application Support/Cursor/CachedData",
                                                                                    "Library/Application Support/Cursor/Code Cache", "Library/Application Support/Cursor/GPUCache"],
                     grade: .a, owner: CacheOwners.cursor, hint: "Cursor가 다음 실행 때 다시 만듭니다"),
        CatalogEntry(id: "vscode.workspaceStorage", group: .editors, title: "VS Code 고아 작업 공간", paths: ["Library/Application Support/Code/User/workspaceStorage"], grade: .b,
                     owner: CacheOwners.vscode, hint: "폴더가 사라진 작업 공간의 편집기 상태입니다 — 휴지통으로 옮깁니다", expansion: .workspaceStorage, trashPreferred: true),
        CatalogEntry(id: "cursor.workspaceStorage", group: .editors, title: "Cursor 고아 작업 공간", paths: ["Library/Application Support/Cursor/User/workspaceStorage"], grade: .b,
                     owner: CacheOwners.cursor, hint: "폴더가 사라진 작업 공간의 편집기·대화 상태입니다 — 휴지통으로 옮깁니다", expansion: .workspaceStorage, trashPreferred: true),
        // 앱 캐시(10-25 Mole 대조로 추가): Electron 앱의 Chromium 캐시 · ~/Library/Caches 항목 · 업데이트 대기 파일.
        // 주인 앱이 실행 중이면 건너뛰고(.app 번들 이름·번들 id·프로세스 이름), 지우기 직전 열린 파일이 있으면 SafeFileOps가 막는다.
        CatalogEntry(id: "apps.electron", group: .apps, title: "앱 캐시", paths: ["Library/Application Support"], grade: .a,
                     hint: "앱이 다음 실행 때 다시 만듭니다(순수 캐시)", expansion: .electronApps(skip: electronSkip)),
        CatalogEntry(id: "apps.serviceWorker", group: .apps, title: "앱 오프라인 웹 데이터", paths: ["Library/Application Support"], grade: .b, defaultExcluded: true,
                     hint: "Service Worker 저장소 — 앱이 다시 받습니다(오프라인으로 보던 문서는 다시 동기화)", expansion: .electronServiceWorkers(skip: electronSkip)),
        CatalogEntry(id: "apps.updaterPending", group: .apps, title: "업데이트 대기 파일", paths: ["Library/Application Support/Caches/*-updater/pending", "Library/Caches/*-updater/pending"],
                     grade: .a, hint: "앱이 받아 둔 업데이트 설치 파일입니다 — 지우면 다음 업데이트 때 다시 받습니다"),
        CatalogEntry(id: "caches.library", group: .apps, title: "Library/Caches", paths: ["Library/Caches"], grade: .a,
                     hint: "앱이 필요할 때 다시 만듭니다(쓰는 중이면 건너뜀)", expansion: .libraryCaches(skip: libraryCacheSkip)),
        CatalogEntry(id: "uv.cache", group: .packages, title: "uv 캐시", paths: [".cache/uv"], grade: .a, owner: CacheOwner("uv", processNames: ["uv", "uvx"]),
                     hint: "uv가 필요할 때 다시 받습니다"),
        CatalogEntry(id: "npm.logs", group: .packages, title: "npm 로그", paths: [".npm/_logs"], grade: .a, owner: CacheOwners.npm, hint: "npm 실행 기록 로그입니다(지워도 됩니다)"),
        // 브라우저(프로필의 캐시 폴더만)
        CatalogEntry(id: "browser.chrome", group: .browsers, title: "Chrome", paths: ["Library/Application Support/Google/Chrome", "Library/Caches/Google/Chrome"], grade: .a,
                     owner: CacheOwner("Chrome", bundleIDs: ["com.google.Chrome"], processNames: ["Google Chrome"]), hint: browserHint, expansion: .browserProfiles),
        CatalogEntry(id: "browser.edge", group: .browsers, title: "Edge", paths: ["Library/Application Support/Microsoft Edge", "Library/Caches/Microsoft Edge"], grade: .a,
                     owner: CacheOwner("Edge", bundleIDs: ["com.microsoft.edgemac"], processNames: ["Microsoft Edge"]), hint: browserHint, expansion: .browserProfiles),
        CatalogEntry(id: "browser.brave", group: .browsers, title: "Brave", paths: ["Library/Application Support/BraveSoftware/Brave-Browser", "Library/Caches/BraveSoftware/Brave-Browser"],
                     grade: .a, owner: CacheOwner("Brave", bundleIDs: ["com.brave.Browser"], processNames: ["Brave Browser"]), hint: browserHint, expansion: .browserProfiles),
        CatalogEntry(id: "browser.arc", group: .browsers, title: "Arc", paths: ["Library/Application Support/Arc/User Data", "Library/Caches/Arc/User Data"], grade: .a,
                     owner: CacheOwner("Arc", bundleIDs: ["company.thebrowser.Browser"], processNames: ["Arc"]), hint: browserHint, expansion: .browserProfiles),
        CatalogEntry(id: "browser.vivaldi", group: .browsers, title: "Vivaldi", paths: ["Library/Application Support/Vivaldi", "Library/Caches/Vivaldi"], grade: .a,
                     owner: CacheOwner("Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"], processNames: ["Vivaldi"]), hint: browserHint, expansion: .browserProfiles),
        CatalogEntry(id: "browser.opera", group: .browsers, title: "Opera", paths: ["Library/Application Support/com.operasoftware.Opera", "Library/Caches/com.operasoftware.Opera"], grade: .a,
                     owner: CacheOwner("Opera", bundleIDs: ["com.operasoftware.Opera"], processNames: ["Opera"]), hint: browserHint, expansion: .browserProfiles),
        // 로그(쓰는 중인 로그는 건드리지 않음 — 비우기(truncate)도 하지 않는다)
        CatalogEntry(id: "logs.user", group: .logs, title: "사용자 로그", paths: ["Library/Logs"], grade: .a, hint: "30일 넘게 쓰지 않은 로그입니다(지워도 됩니다)",
                     expansion: .oldLogs(days: 30, skip: ["DiagnosticReports", "ReMON", "Homebrew"])),
        CatalogEntry(id: "logs.diagnostic", group: .logs, title: "진단 보고서", paths: ["Library/Logs/DiagnosticReports"], grade: .a, hint: "30일 지난 충돌·진단 보고서입니다(지워도 됩니다)",
                     expansion: .oldFiles(days: 30)),
        // 기본 제외(묶음 정리에서 빠짐)
        CatalogEntry(id: "xcode.archives", group: .excluded, title: "Xcode Archives", paths: ["Library/Developer/Xcode/Archives"], grade: .c, defaultExcluded: true,
                     hint: "배포 원본·충돌 기호(dSYM)입니다 — 지우지 않습니다"),
        CatalogEntry(id: "playwright.browsers", group: .excluded, title: "Playwright 브라우저", paths: ["Library/Caches/ms-playwright"], grade: .b, defaultExcluded: true,
                     hint: "npx playwright install로 다시 받습니다"),
        CatalogEntry(id: "maven.repository", group: .excluded, title: "Maven 저장소", paths: [".m2/repository"], grade: .b, defaultExcluded: true,
                     hint: "Maven이 다시 받습니다(사내 저장소 산출물은 다시 못 받을 수 있습니다)"),
        CatalogEntry(id: "jetbrains", group: .excluded, title: "JetBrains", paths: ["Library/Caches/JetBrains", "Library/Application Support/JetBrains"], grade: .c, defaultExcluded: true,
                     hint: "IDE 설정·색인입니다 — IDE에서 관리합니다"),
        CatalogEntry(id: "models.ollama", group: .excluded, title: "Ollama 모델", paths: [".ollama/models"], grade: .c, defaultExcluded: true, hint: "ollama rm <모델>로 지웁니다"),
        CatalogEntry(id: "models.lmstudio", group: .excluded, title: "LM Studio 모델", paths: [".lmstudio/models", ".cache/lm-studio/models"], grade: .c, defaultExcluded: true,
                     hint: "LM Studio에서 모델을 지웁니다"),
        CatalogEntry(id: "models.huggingface", group: .excluded, title: "Hugging Face 캐시", paths: [".cache/huggingface"], grade: .c, defaultExcluded: true,
                     hint: "huggingface-cli delete-cache로 고릅니다"),
    ]

    private static let index: [String: CatalogEntry] = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    /// 앱 캐시 훑기에서 빼는 Application Support 폴더: 다른 항목(편집기·브라우저·AI 앱)이 맡거나 캐시가 아닌 것.
    static let electronSkip = ["Code", "Cursor", "Claude", "Codex", "com.openai.chat", "Antigravity", "Google", "Microsoft Edge", "BraveSoftware", "Arc", "Vivaldi",
                               "com.operasoftware.Opera", "JetBrains", "Caches", "ReMON", "local.remon"]
    /// ~/Library/Caches에서 빼는 이름: 다른 항목(패키지·브라우저·AI 앱 캐시)이 맡는 것.
    static let libraryCacheSkip = ["Google", "Homebrew", "Yarn", "pnpm", "deno", "go-build", "CocoaPods", "org.swift.swiftpm", "ms-playwright", "JetBrains", "Microsoft Edge",
                                   "BraveSoftware", "Vivaldi", "com.operasoftware.Opera", "Arc", "com.anthropic.claudefordesktop", "claude-cli-nodejs", "Codex", "com.openai.chat",
                                   "ChatGPTHelper", "com.cursor.Cursor", "cursor-compile-cache", "com.lmstudio.lmstudio", "local.remon", "ReMON", "notion-updater"]
    /// macOS가 쓰는데 com.apple. 접두가 없는 캐시(보기만).
    static let appleUnprefixed: Set<String> = ["GeoServices", "CloudKit", "FamilyCircle", "familycircled", "Metadata", "SessionRestore"]
    /// Electron(Chromium) 프로필의 순수 캐시 하위 폴더.
    static let electronCacheNames = ["Cache", "Code Cache", "GPUCache", "GraphiteDawnCache", "DawnGraphiteCache", "DawnWebGPUCache", "DawnCache", "ShaderCache", "GrShaderCache",
                                     "Crashpad/completed", "Shared Dictionary/cache", "component_crx_cache", "extensions_crx_cache"]
    static let serviceWorkerNames = ["Service Worker/CacheStorage", "Service Worker/ScriptCache"]
    /// Chromium 프로필이라는 표시(이게 있어야 'Cache' 같은 흔한 이름을 캐시로 본다).
    static let chromiumMarkers = ["Local Storage", "Session Storage", "Preferences", "Code Cache", "GPUCache", "Network"]

    public static func entry(_ id: String) -> CatalogEntry? { index[id] }

    /// 브라우저에서 지워도 되는 폴더 이름(이 밖의 것은 절대 건드리지 않는다).
    public static let browserCacheNames: Set<String> = ["Cache", "Code Cache", "GPUCache", "ShaderCache", "GrShaderCache"]
    /// 브라우저에서 절대 건드리지 않는 것(검사가 목록에 없음을 확인한다).
    public static let browserProtectedNames: Set<String> = ["Cookies", "History", "Login Data", "Local Storage", "IndexedDB", "Service Worker", "Web Data", "Bookmarks", "Preferences", "Sessions"]

    /// 화면 묶음.
    public static func group(of item: DiskItem) -> CatalogGroup {
        if item.defaultExcluded { return .excluded }
        if let id = item.entryID {
            if let entry = entry(id) { return entry.group }
            if id.hasPrefix("project.") { return .projects }
            if id == "temp.old" { return .temporary }
        }
        return item.category == .temporary ? .temporary : .projects
    }

    /// 처음 고를 것: 주인이 꺼져 있는 A(순수 캐시)만. 삭제된 프로젝트의 DerivedData도 A라 함께 골라진다.
    /// 임시 파일은 주인을 알 수 없어(시스템 데몬의 임시 폴더일 수 있음) 사람이 직접 고를 때만.
    public static func isRecommended(_ item: DiskItem) -> Bool {
        item.grade == .a && !item.defaultExcluded && item.skipReason == nil && !item.permissionNeeded && item.category == .regenerable && item.entryID != "temp.old"
    }

    /// 등급 없는 기존 항목(옛 초기화로 만든 것)의 등급: 표의 경로와 같으면 그 등급, 빌드 산출물 이름이면 B.
    public static func inferredGrade(for item: DiskItem, home: String = NSHomeDirectory()) -> (grade: DiskGrade, entryID: String?)? {
        if item.category == .temporary { return (.a, "temp.old") }
        guard item.category == .regenerable else { return nil }
        for entry in entries where entry.expansion == .whole || entry.expansion == .children {
            if entry.paths.contains(where: { home + "/" + $0 == item.path }) { return (entry.grade, entry.id) }
        }
        // 예전 고정 목록(통째 항목)
        let legacy: [String: String?] = ["Library/Developer/Xcode/DerivedData": nil, "Library/Caches/Homebrew": "brew.cache", "Library/Caches/Yarn": "yarn.cache"]
        for (relative, id) in legacy where home + "/" + relative == item.path { return (.a, id) }
        switch (item.path as NSString).lastPathComponent {
        case ".build", ".build-test", "DerivedData": return (.b, "project.build")
        case "node_modules": return (.b, "project.node_modules")
        default: return nil
        }
    }
}

// MARK: - 표대로 찾기

extension DiskScanner {
    /// 카탈로그 항목 전부(조사 시점의 실행 중 앱으로 건너뛸 이유를 적는다). 위험한 동작 없음 — 읽기만 한다.
    public func catalogItems(running: RunningApps, now: Date = Date()) -> [DiskItem] {
        var items: [DiskItem] = []
        for entry in catalog {
            if cancelled { break }
            for pattern in entry.paths {
                for path in expand(pattern) {
                    autoreleasepool { items += catalogItems(entry, at: path, running: running, now: now) }
                }
            }
        }
        return Self.unique(items)
    }

    /// 홈 기준 경로의 '*'를 한 단계씩 펼친다(fnmatch).
    func expand(_ pattern: String) -> [String] {
        var current = [home]
        for component in pattern.split(separator: "/").map(String.init) {
            var next: [String] = []
            for base in current {
                if component.contains("*") {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                    for name in names.sorted() where fnmatch(component, name, 0) == 0 { next.append(base + "/" + name) }
                } else {
                    next.append(base + "/" + component)
                }
            }
            current = next
        }
        return current.filter { path in var info = stat(); return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) != S_IFLNK }
    }

    private func catalogItems(_ entry: CatalogEntry, at path: String, running: RunningApps, now: Date) -> [DiskItem] {
        switch entry.expansion {
        case .whole:
            var owned = entry
            // 업데이트 대기 파일: 주인 = '<앱>-updater' 폴더의 앱(켜져 있으면 받는 중일 수 있어 건너뜀).
            if entry.id == "apps.updaterPending" { owned.owner = DiskScanner.folderOwner(((path as NSString).deletingLastPathComponent as NSString).lastPathComponent) }
            return [make(owned, path: path, running: running)].compactMap { $0 }
        case .children:
            return directories(in: path).compactMap { make(entry, path: $0, note: entry.title + " · " + ($0 as NSString).lastPathComponent, running: running) }
        case .derivedData:
            return derivedData(entry, root: path, running: running)
        case .workspaceStorage:
            return orphanWorkspaces(entry, root: path, running: running)
        case .browserProfiles:
            return browserCaches(entry, root: path, running: running)
        case .oldLogs(let days, let skip):
            return oldLogs(entry, root: path, days: days, skip: Set(skip), running: running, now: now)
        case .oldFiles(let days):
            return oldFiles(entry, root: path, days: days, running: running, now: now)
        case .electronApps(let skip):
            return electronCaches(entry, root: path, skip: Set(skip), serviceWorkers: false, running: running)
        case .electronServiceWorkers(let skip):
            return electronCaches(entry, root: path, skip: Set(skip), serviceWorkers: true, running: running)
        case .libraryCaches(let skip):
            return libraryCaches(entry, root: path, skip: Set(skip), running: running)
        }
    }

    /// Application Support/<앱>(과 Partitions/*)이 Chromium 프로필이면 그 안의 캐시 하위 폴더. 주인 = 앱 폴더 이름과 같은 .app·프로세스.
    func electronCaches(_ entry: CatalogEntry, root: String, skip: Set<String>, serviceWorkers: Bool, running: RunningApps) -> [DiskItem] {
        var items: [DiskItem] = []
        for app in directories(in: root) {
            let name = (app as NSString).lastPathComponent
            guard !skip.contains(name), !name.hasPrefix("com.apple.") else { continue }
            var owned = entry
            owned.owner = DiskScanner.folderOwner(name)
            for base in [app] + directories(in: app + "/Partitions") {
                // Chromium 프로필 표시: 프로필 파일이나 크롬 전용 캐시 이름(GraphiteDawnCache 등)이 하나라도 있어야 한다(흔한 'Cache'만으로는 안 됨).
                let markers = DiskCatalog.chromiumMarkers + DiskCatalog.electronCacheNames.filter { $0 != "Cache" }
                guard markers.contains(where: { FileManager.default.fileExists(atPath: base + "/" + $0) }) else { continue }
                for cache in serviceWorkers ? DiskCatalog.serviceWorkerNames : DiskCatalog.electronCacheNames {
                    let path = base + "/" + cache
                    var info = stat()
                    // 권한이 없어 못 읽는 폴더는 '권한 필요' 빈 항목으로 늘어놓지 않는다.
                    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, access(path, R_OK | X_OK) == 0 else { continue }
                    let label = base == app ? name : "\(name) · \((base as NSString).lastPathComponent)"
                    if let item = make(owned, path: path, note: "\(label) · \(cache)", running: running, minimum: 1_048_576) { items.append(item) }
                }
            }
        }
        return items
    }

    /// 캐시 폴더 이름으로 주인 앱·프로세스를 넓게 알아본다: 이름 그대로 · 업데이트 꼬리(-updater · .ShipIt · -update)를 뗀 이름 ·
    /// 번들 id 꼴이면 마지막 조각 · 스크립트로 도는 도구(MCP 서버 등)는 실행 인자에 폴더 이름이 보이면 실행 중으로 본다.
    /// 10-25: Orca가 켜져 있는데 ~/Library/Caches/orca-updater를 영구 삭제했다(이름이 'orca'와 정확히 같지 않아 주인을 못 알아봄).
    static func folderOwner(_ name: String) -> CacheOwner {
        var names: Set<String> = [name]
        let lower = name.lowercased()
        for suffix in ["-updater", ".shipit", "-update", "-helper"] where lower.hasSuffix(suffix) && name.count > suffix.count {
            names.insert(String(name.dropLast(suffix.count)))
        }
        for base in names where base.contains(".") {
            if let last = base.split(separator: ".").last, last.count >= 3 { names.insert(String(last)) }
        }
        let markers = name.count >= 6 ? [name] : []
        return CacheOwner(name, bundleIDs: names.filter { $0.contains(".") }.sorted(), processNames: names.sorted(), commandMarkers: markers, appNames: names.sorted())
    }

    /// ~/Library/Caches/<이름>: 5MB 이상만. macOS 캐시(com.apple.* 등)와 'memory'가 든 이름(AI 도구 기억일 수 있음)은 보기만(C).
    func libraryCaches(_ entry: CatalogEntry, root: String, skip: Set<String>, running: RunningApps) -> [DiskItem] {
        directories(in: root).compactMap { path in
            let name = (path as NSString).lastPathComponent
            guard !skip.contains(name), access(path, R_OK | X_OK) == 0 else { return nil }
            var owned = entry
            owned.owner = DiskScanner.folderOwner(name)
            if name.hasPrefix("com.apple.") || DiskCatalog.appleUnprefixed.contains(name) {
                return make(owned, path: path, grade: .c, note: "macOS · \(name)", hint: "macOS 데몬이 쓰는 캐시입니다 — 지우지 않습니다(필요하면 macOS가 비웁니다)",
                            running: running, minimum: 5 << 20)
            }
            if name.lowercased().contains("memory") {
                return make(owned, path: path, grade: .c, note: name, hint: "AI 도구의 기억일 수 있어 지우지 않습니다", running: running, minimum: 1 << 20)
            }
            return make(owned, path: path, note: name, running: running, minimum: 5 << 20)
        }
    }

    /// 항목 하나. 너무 작으면 버리고, 읽을 수 없으면 '권한 필요'로 남긴다.
    func make(_ entry: CatalogEntry, path: String, grade: DiskGrade? = nil, note: String? = nil, hint: String? = nil, running: RunningApps,
              minimum: UInt64? = nil, modified: Date? = nil) -> DiskItem? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        let grade = grade ?? entry.grade
        let category: DiskCategory = (entry.defaultExcluded || grade == .c) ? .keep : .regenerable
        let skip = entry.owner.flatMap { running.isRunning($0) ? "\($0.name) 실행 중 — 종료한 뒤 정리합니다" : nil }
        if isDirectory, access(path, R_OK | X_OK) != 0 {
            return DiskItem(path: path, category: category, bytes: 0, modified: nil, note: (note ?? entry.title) + " · 권한 필요", grade: grade, owner: entry.owner,
                            defaultExcluded: entry.defaultExcluded, entryID: entry.id, hint: hint ?? entry.hint, skipReason: skip, permissionNeeded: true)
        }
        let bytes = Self.allocatedSize(path)
        guard bytes >= (minimum ?? minimumBytes), bytes > 0 else { return nil }
        // B는 '하루 안에 바뀌었나'를 정책이 보므로 바로 아래 항목까지 본 가장 최근 시각을 쓴다(맨 위 폴더 시각만으로는 캐시 사용을 놓친다).
        let stamp = modified ?? (grade == .b && isDirectory ? Self.newestModification(path) : Self.modified(path))
        return DiskItem(path: path, category: category, bytes: bytes, modified: stamp, note: note ?? entry.title, grade: grade, owner: entry.owner,
                        defaultExcluded: entry.defaultExcluded, entryID: entry.id, hint: hint ?? entry.hint, skipReason: skip)
    }

    func directories(in path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted().map { path + "/" + $0 }.filter { child in
            var info = stat()
            return lstat(child, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
        }
    }

    /// DerivedData: 프로젝트 폴더마다 info.plist의 WorkspacePath를 본다. 없으면 '삭제된 프로젝트'(A), 외장 볼륨이 빠졌으면 판단 보류(B).
    func derivedData(_ entry: CatalogEntry, root: String, running: RunningApps) -> [DiskItem] {
        directories(in: root).compactMap { folder in
            let name = (folder as NSString).lastPathComponent
            if name.hasSuffix(".noindex") {
                return make(entry, path: folder, grade: .a, note: "Xcode 공용 캐시 · \(name)", hint: "Xcode가 필요할 때 다시 만듭니다", running: running)
            }
            let projectName = name.split(separator: "-").dropLast().joined(separator: "-")
            guard let workspace = Self.derivedDataWorkspace(folder) else {
                return make(entry, path: folder, note: "DerivedData · \(name)", running: running)
            }
            let shown = projectName.isEmpty ? ((workspace as NSString).lastPathComponent as NSString).deletingPathExtension : projectName
            if FileManager.default.fileExists(atPath: workspace) {
                return make(entry, path: folder, note: "프로젝트 · \(shown)", running: running)
            }
            if workspace.hasPrefix("/Volumes/") {
                let volume = "/Volumes/" + (workspace.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? "")
                if !FileManager.default.fileExists(atPath: volume) {
                    return make(entry, path: folder, note: "외장 볼륨 프로젝트(연결 안 됨) · \(shown)", running: running)
                }
            }
            return make(entry, path: folder, grade: .a, note: "삭제된 프로젝트 · \(shown)", hint: "프로젝트가 없어 다시 쓰이지 않습니다(지워도 됩니다)", running: running)
        }
    }

    static func derivedDataWorkspace(_ folder: String) -> String? {
        guard let plist = NSDictionary(contentsOfFile: folder + "/info.plist"), let path = plist["WorkspacePath"] as? String, path.hasPrefix("/") else { return nil }
        return path
    }

    /// VS Code·Cursor workspaceStorage: workspace.json의 로컬 폴더(또는 .code-workspace)가 사라진 것만. 원격·외장 볼륨은 판단하지 않는다.
    func orphanWorkspaces(_ entry: CatalogEntry, root: String, running: RunningApps) -> [DiskItem] {
        directories(in: root).compactMap { folder in
            guard let target = Self.workspaceTarget(folder) else { return nil }
            if FileManager.default.fileExists(atPath: target) { return nil }
            if target.hasPrefix("/Volumes/") { return nil }
            return make(entry, path: folder, note: "사라진 폴더 · " + target.replacingOccurrences(of: home, with: "~"), running: running, minimum: 0)
        }
    }

    static func workspaceTarget(_ folder: String) -> String? {
        guard let data = FileManager.default.contents(atPath: folder + "/workspace.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let raw = (object["folder"] as? String) ?? (object["workspace"] as? String) ?? (object["configuration"] as? String),
              let url = URL(string: raw), url.isFileURL else { return nil }
        let path = url.path
        return path.hasPrefix("/") ? path : nil
    }

    /// 브라우저 프로필 캐시: 맨 위(공용 셰이더 캐시)와 프로필 폴더(Default · Profile N · Guest/System Profile)의 허용된 이름만.
    func browserCaches(_ entry: CatalogEntry, root: String, running: RunningApps) -> [DiskItem] {
        var items: [DiskItem] = []
        let browser = entry.title
        func add(_ folder: String, _ label: String) {
            for name in DiskCatalog.browserCacheNames.sorted() {
                let path = folder + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
                if let item = make(entry, path: path, note: "\(browser) · \(label) · \(name)", running: running) { items.append(item) }
            }
        }
        add(root, "공용")
        for folder in directories(in: root) {
            let name = (folder as NSString).lastPathComponent
            guard name == "Default" || name.hasPrefix("Profile ") || name == "Guest Profile" || name == "System Profile" else { continue }
            add(folder, name)
        }
        return items
    }

    /// ~/Library/Logs: days일 넘게 아무것도 안 쓴 파일·폴더. 지금 쓰는 폴더는 통째로 두고 그 안의 오래된 1MB 이상 파일만.
    func oldLogs(_ entry: CatalogEntry, root: String, days: Double, skip: Set<String>, running: RunningApps, now: Date) -> [DiskItem] {
        var items: [DiskItem] = []
        let limit = now.addingTimeInterval(-days * 86_400)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() where !skip.contains(name) && !name.hasPrefix(".") {
            let path = root + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG:
                let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
                if modified < limit, let item = make(entry, path: path, note: "로그 · \(name)", running: running, minimum: 100 * 1024, modified: modified) { items.append(item) }
            case S_IFDIR:
                if let newest = Self.newestModificationDeep(path), newest < limit {
                    if let item = make(entry, path: path, note: "로그 폴더 · \(name)", running: running, minimum: 100 * 1024, modified: newest) { items.append(item) }
                } else {
                    for child in ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted() {
                        let file = path + "/" + child
                        var childInfo = stat()
                        guard lstat(file, &childInfo) == 0, (childInfo.st_mode & S_IFMT) == S_IFREG else { continue }
                        let modified = Date(timeIntervalSince1970: TimeInterval(childInfo.st_mtimespec.tv_sec))
                        if modified < limit, let item = make(entry, path: file, note: "로그 · \(name)/\(child)", running: running, modified: modified) { items.append(item) }
                    }
                }
            default:
                continue
            }
        }
        return items
    }

    /// 진단 보고서: days일 지난 파일 하나씩(크기 제한 없음). 큰 것부터 maxOldFiles개까지만 올린다 — 한 번에 수천 건이 금고를 채우지 않게
    /// (나머지는 다음 정리 때). 하위 폴더는 통째로 오래됐을 때만.
    func oldFiles(_ entry: CatalogEntry, root: String, days: Double, running: RunningApps, now: Date) -> [DiskItem] {
        var items: [DiskItem] = []
        let limit = now.addingTimeInterval(-days * 86_400)
        for name in ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted() where !name.hasPrefix(".") {
            if items.count >= 5_000 { break }
            let path = root + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            let modified = kind == S_IFDIR ? Self.newestModificationDeep(path) : Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard kind == S_IFREG || kind == S_IFDIR, let modified, modified < limit else { continue }
            if let item = make(entry, path: path, note: "진단 보고서 · \(name)", running: running, minimum: 0, modified: modified) { items.append(item) }
        }
        return Array(items.sorted { $0.bytes > $1.bytes }.prefix(maxOldFiles))
    }
}

// MARK: - 경로 하나 판정(디스크 지도, 10-25)

/// 디스크 지도가 경로 하나를 표로 판정한 결과. 크기는 재지 않는다 — DiskScanner.catalogItems와 같은 규칙이고,
/// 목록 소음을 줄이는 최소 크기만 보지 않는다(작은 캐시도 캐시다). 시험이 두 결과가 같은지 대조한다.
public struct CatalogMatch: Sendable {
    /// 주인이 정해진 항목(업데이트 대기 파일 · 앱 캐시 · Library/Caches는 폴더 이름으로 주인을 정한다)
    public var entry: CatalogEntry
    public var grade: DiskGrade
    public var note: String
    public var hint: String

    /// 정책(CacheDeletionPolicy)에 넘길 항목. 주인이 실행 중이면 건너뛸 이유를 적는다(DiskScanner.make와 같다).
    public func item(path: String, bytes: UInt64, modified: Date?, running: RunningApps) -> DiskItem {
        let category: DiskCategory = (entry.defaultExcluded || grade == .c) ? .keep : .regenerable
        let skip = entry.owner.flatMap { running.isRunning($0) ? "\($0.name) 실행 중 — 종료한 뒤 정리합니다" : nil }
        return DiskItem(path: path, category: category, bytes: bytes, modified: modified, note: note, grade: grade, owner: entry.owner,
                        defaultExcluded: entry.defaultExcluded, entryID: entry.id, hint: hint, skipReason: skip)
    }
}

extension DiskCatalog {
    /// 경로 하나가 표의 어느 항목인지. 표 순서대로 처음 맞는 것(DiskScanner가 같은 경로를 두 번 잡으면 먼저 것만 남기는 것과 같다).
    /// newest: 폴더 전체의 가장 최근 수정 시각을 이미 알면 넘긴다(오래된 로그 판정) — 없으면 직접 잰다.
    public static func match(_ path: String, home rawHome: String, now: Date = Date(), newest: Date? = nil, entries: [CatalogEntry] = DiskCatalog.entries) -> CatalogMatch? {
        let home = rawHome.hasSuffix("/") ? String(rawHome.dropLast()) : rawHome
        guard path.hasPrefix(home + "/") else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return nil }
        let parts = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        for entry in entries {
            for pattern in entry.paths {
                let components = pattern.split(separator: "/").map(String.init)
                guard parts.count >= components.count, zip(components, parts).allSatisfy({ fnmatch($0, $1, 0) == 0 }) else { continue }
                let base = home + "/" + parts[0..<components.count].joined(separator: "/")
                let rest = Array(parts[components.count...])
                // 표의 경로 자체가 링크면 DiskScanner도 건너뛴다.
                if !rest.isEmpty {
                    var baseInfo = stat()
                    guard lstat(base, &baseInfo) == 0, (baseInfo.st_mode & S_IFMT) == S_IFDIR else { continue }
                }
                if let found = matchExpansion(entry, path: path, base: base, rest: rest, info: info, home: home, now: now, newest: newest) { return found }
            }
        }
        return nil
    }

    private static func matchExpansion(_ entry: CatalogEntry, path: String, base: String, rest: [String], info: stat, home: String, now: Date, newest: Date?) -> CatalogMatch? {
        let kind = info.st_mode & S_IFMT
        let isDirectory = kind == S_IFDIR
        let readable = !isDirectory || access(path, R_OK | X_OK) == 0
        func found(_ grade: DiskGrade? = nil, _ note: String, _ hint: String? = nil, owner: CacheOwner? = nil) -> CatalogMatch {
            var owned = entry
            if let owner { owned.owner = owner }
            return CatalogMatch(entry: owned, grade: grade ?? entry.grade, note: note, hint: hint ?? entry.hint)
        }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        switch entry.expansion {
        case .whole:
            guard rest.isEmpty else { return nil }
            if entry.id == "apps.updaterPending" {
                return found(nil, entry.title, owner: DiskScanner.folderOwner(((path as NSString).deletingLastPathComponent as NSString).lastPathComponent))
            }
            return found(nil, entry.title)
        case .children:
            guard rest.count == 1, isDirectory else { return nil }
            return found(nil, entry.title + " · " + rest[0])
        case .derivedData:
            guard rest.count == 1, isDirectory else { return nil }
            let name = rest[0]
            if name.hasSuffix(".noindex") { return found(.a, "Xcode 공용 캐시 · \(name)", "Xcode가 필요할 때 다시 만듭니다") }
            let projectName = name.split(separator: "-").dropLast().joined(separator: "-")
            guard let workspace = DiskScanner.derivedDataWorkspace(path) else { return found(nil, "DerivedData · \(name)") }
            let shown = projectName.isEmpty ? ((workspace as NSString).lastPathComponent as NSString).deletingPathExtension : projectName
            if FileManager.default.fileExists(atPath: workspace) { return found(nil, "프로젝트 · \(shown)") }
            if workspace.hasPrefix("/Volumes/") {
                let volume = "/Volumes/" + (workspace.dropFirst("/Volumes/".count).split(separator: "/").first.map(String.init) ?? "")
                if !FileManager.default.fileExists(atPath: volume) { return found(nil, "외장 볼륨 프로젝트(연결 안 됨) · \(shown)") }
            }
            return found(.a, "삭제된 프로젝트 · \(shown)", "프로젝트가 없어 다시 쓰이지 않습니다(지워도 됩니다)")
        case .workspaceStorage:
            guard rest.count == 1, isDirectory, let target = DiskScanner.workspaceTarget(path), !FileManager.default.fileExists(atPath: target), !target.hasPrefix("/Volumes/") else { return nil }
            return found(nil, "사라진 폴더 · " + target.replacingOccurrences(of: home, with: "~"))
        case .browserProfiles:
            guard isDirectory else { return nil }
            if rest.count == 1, DiskCatalog.browserCacheNames.contains(rest[0]) { return found(nil, "\(entry.title) · 공용 · \(rest[0])") }
            let profile = rest.first ?? ""
            if rest.count == 2, profile == "Default" || profile.hasPrefix("Profile ") || profile == "Guest Profile" || profile == "System Profile",
               DiskCatalog.browserCacheNames.contains(rest[1]) { return found(nil, "\(entry.title) · \(profile) · \(rest[1])") }
            return nil
        case .oldLogs(let days, let skip):
            let limit = now.addingTimeInterval(-days * 86_400)
            guard let first = rest.first, !skip.contains(first), !first.hasPrefix(".") else { return nil }
            if rest.count == 1 {
                if kind == S_IFREG, modified < limit { return found(nil, "로그 · \(first)") }
                if isDirectory, let latest = newest ?? DiskScanner.newestModificationDeep(path), latest < limit { return found(nil, "로그 폴더 · \(first)") }
                return nil
            }
            // 쓰는 중인 로그 폴더 안의 오래된 파일 하나씩(통째로 오래된 폴더 안의 파일도 같은 판정이다).
            if rest.count == 2, kind == S_IFREG, modified < limit { return found(nil, "로그 · \(first)/\(rest[1])") }
            return nil
        case .oldFiles(let days):
            let limit = now.addingTimeInterval(-days * 86_400)
            guard rest.count == 1, !rest[0].hasPrefix("."), kind == S_IFREG || isDirectory else { return nil }
            let latest = isDirectory ? (newest ?? DiskScanner.newestModificationDeep(path)) : modified
            guard let latest, latest < limit else { return nil }
            return found(nil, "진단 보고서 · \(rest[0])")
        case .electronApps(let skip), .electronServiceWorkers(let skip):
            var serviceWorkers = false
            if case .electronServiceWorkers = entry.expansion { serviceWorkers = true }
            guard rest.count >= 2, isDirectory, readable else { return nil }
            let app = rest[0]
            guard !skip.contains(app), !app.hasPrefix("com.apple.") else { return nil }
            // 프로필 바탕: 앱 폴더 자체 또는 Partitions/<이름>.
            var profile = base + "/" + app
            var cache = Array(rest.dropFirst())
            var label = app
            if rest.count >= 4, rest[1] == "Partitions" {
                profile += "/Partitions/" + rest[2]
                cache = Array(rest.dropFirst(3))
                label = "\(app) · \(rest[2])"
            }
            let name = cache.joined(separator: "/")
            guard (serviceWorkers ? DiskCatalog.serviceWorkerNames : DiskCatalog.electronCacheNames).contains(name) else { return nil }
            let markers = DiskCatalog.chromiumMarkers + DiskCatalog.electronCacheNames.filter { $0 != "Cache" }
            guard markers.contains(where: { FileManager.default.fileExists(atPath: profile + "/" + $0) }) else { return nil }
            return found(nil, "\(label) · \(name)", owner: DiskScanner.folderOwner(app))
        case .libraryCaches(let skip):
            guard rest.count == 1, isDirectory, readable, !skip.contains(rest[0]) else { return nil }
            let name = rest[0]
            let owner = DiskScanner.folderOwner(name)
            if name.hasPrefix("com.apple.") || DiskCatalog.appleUnprefixed.contains(name) {
                return found(.c, "macOS · \(name)", "macOS 데몬이 쓰는 캐시입니다 — 지우지 않습니다(필요하면 macOS가 비웁니다)", owner: owner)
            }
            if name.lowercased().contains("memory") { return found(.c, name, "AI 도구의 기억일 수 있어 지우지 않습니다", owner: owner) }
            return found(nil, name, owner: owner)
        }
    }
}

extension ToolCommands {
    /// 디스크 지도의 Homebrew 정리: 옛 버전·다운로드를 기간과 상관없이(--prune=all). 미리보기(-n)는 아무것도 지우지 않는다.
    public static let brewCleanupAll = ToolCommand(id: "brew-cleanup-all", title: "brew cleanup --prune=all", tool: "brew", arguments: ["cleanup", "--prune=all"],
                                                   previewArguments: ["cleanup", "-n", "--prune=all"],
                                                   detail: "Homebrew 옛 버전·받아 둔 설치 파일을 Homebrew가 직접 지웁니다",
                                                   restoreHint: "필요하면 brew install로 다시 설치합니다", timeout: 900)
    /// 이름 없는(dangling) 이미지만 — 태그 있는 이미지·컨테이너·볼륨은 남긴다(-a·볼륨 정리는 쓰지 않는다).
    public static let dockerImagePrune = ToolCommand(id: "docker-image-prune", title: "docker image prune -f", tool: "docker", arguments: ["image", "prune", "-f"],
                                                     previewArguments: ["system", "df"], detail: "이름 없는(dangling) 이미지만 지웁니다 — 태그 있는 이미지·볼륨은 남깁니다",
                                                     restoreHint: "되돌릴 수 없습니다 — 필요하면 docker pull·docker build로 다시 받습니다", timeout: 600)
    public static let dockerBuilderPrune = ToolCommand(id: "docker-builder-prune", title: "docker builder prune -f", tool: "docker", arguments: ["builder", "prune", "-f"],
                                                       previewArguments: ["system", "df"], detail: "빌드 캐시를 지웁니다(다음 빌드가 처음부터 다시 받습니다)",
                                                       restoreHint: "되돌릴 수 없습니다 — 다음 docker build가 다시 만듭니다", timeout: 600)
}
