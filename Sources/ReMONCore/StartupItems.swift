import Darwin
import Foundation

// 시작 항목·백그라운드 서비스 점검(G4) — ~/Library/LaunchAgents · /Library/LaunchAgents · /Library/LaunchDaemons.
// 읽기: plist(Label·ProgramArguments/Program·RunAtLoad·KeepAlive) + launchctl print(상태·실행 횟수·마지막 종료 코드). 모두 읽기 전용.
// 강조: 실행 파일(또는 실행할 스크립트)이 없는 항목 · 반복 크래시(마지막 종료 코드 ≠ 0 + KeepAlive).
// 끄기는 내 에이전트(~/Library/LaunchAgents)만: launchctl bootout → plist를 휴지통(복구 금고 기록).
// 다시 켜기: 휴지통에서 원래 자리로 → launchctl bootstrap. 시스템 영역은 보여 주기만 한다(루트 권한을 쓰지 않음).

/// launchctl print로 읽은 상태(최상위 항목만).
public struct LaunchdJobState: Sendable, Equatable {
    /// launchd가 이 라벨을 아는가(print 성공)
    public var loaded: Bool
    public var running: Bool
    public var pid: Int32?
    public var runs: Int?
    /// 마지막 종료 코드. nil = 아직 끝난 적 없음 또는 모름
    public var lastExitCode: Int32?
    /// 원문(예: "127", "(never exited)")
    public var lastExit: String?
    /// 마지막 종료 신호(있을 때)
    public var lastSignal: String?
    public var program: String?
    /// 읽지 못한 이유
    public var error: String?

    public init(loaded: Bool, running: Bool, pid: Int32? = nil, runs: Int? = nil, lastExitCode: Int32? = nil, lastExit: String? = nil,
                lastSignal: String? = nil, program: String? = nil, error: String? = nil) {
        self.loaded = loaded
        self.running = running
        self.pid = pid
        self.runs = runs
        self.lastExitCode = lastExitCode
        self.lastExit = lastExit
        self.lastSignal = lastSignal
        self.program = program
        self.error = error
    }

    public static let notLoaded = LaunchdJobState(loaded: false, running: false)
}

public struct StartupItem: Identifiable, Sendable, Equatable {
    public enum Domain: String, Sendable, Codable, CaseIterable {
        case userAgent, globalAgent, systemDaemon

        public var label: String {
            switch self {
            case .userAgent: "내 에이전트"
            case .globalAgent: "모든 사용자 에이전트"
            case .systemDaemon: "시스템 데몬"
            }
        }

        /// launchctl 도메인. 에이전트는 로그인한 사용자의 gui 도메인에서 돈다.
        public func target(uid: uid_t) -> String { self == .systemDaemon ? "system" : "gui/\(uid)" }
    }

    public enum KeepAlive: String, Sendable, Equatable {
        case off, always, conditional
        public var isOn: Bool { self != .off }
        public var label: String {
            switch self {
            case .off: "한 번 실행"
            case .always: "항상 다시 띄움"
            case .conditional: "조건부 다시 띄움"
            }
        }
    }

    public var plistPath: String
    public var domain: Domain
    /// Label(없으면 파일 이름)
    public var label: String
    public var hasLabel: Bool
    /// Program 또는 ProgramArguments[0]
    public var program: String?
    public var arguments: [String]
    public var runAtLoad: Bool
    public var keepAlive: KeepAlive
    /// plist의 Disabled 키
    public var disabledInPlist: Bool
    public var readable: Bool
    public var parseError: String?
    /// plist가 링크면 가리키는 곳(앱 번들 안 등)
    public var symlinkTarget: String?
    /// 실제로 실행할 파일(슬래시 없는 이름은 launchd 기본 PATH에서 찾음)
    public var resolvedProgram: String?
    /// 없는 실행 파일·스크립트 경로
    public var missingProgram: String?
    /// 보호 사유(Apple·보안·MDM·VPN·ReMON). 있으면 끄지 않는다.
    public var protection: String?
    public var state: LaunchdJobState?

    public var id: String { plistPath }

    /// 마지막 실행이 실패로 끝남(0이 아닌 종료 코드 또는 신호).
    public var lastRunFailed: Bool {
        guard let state else { return false }
        return (state.lastExitCode ?? 0) != 0 || state.lastSignal != nil
    }

    /// 반복 크래시: KeepAlive인데 마지막 실행이 실패 → launchd가 계속 다시 띄운다.
    /// 실행 횟수를 알면 2회 이상일 때만 — 한 번 실패하고 대기 중인 것(10-25 실측: runs 1 · 78 EX_CONFIG · penalty box)은 '마지막 실행 실패'로만 보인다.
    public var crashLoop: Bool { keepAlive.isOn && lastRunFailed && (state?.runs ?? 2) >= 2 }

    /// 확인이 필요한 항목(실행 파일 없음 · 반복 크래시)
    public var flagged: Bool { crashLoop || missingProgram != nil }

    /// 끌 수 없는 이유(없으면 끌 수 있음).
    public var disableBlocker: String? {
        if domain != .userAgent { return "시스템 영역 항목은 보여 주기만 합니다 — 시스템 설정에서 관리합니다" }
        if let protection { return protection }
        if !readable { return "plist를 읽지 못했습니다" }
        if !hasLabel { return "Label이 없는 plist입니다" }
        return nil
    }

    public var canDisable: Bool { disableBlocker == nil }
}

/// 보호 목록(직접 작성): Apple · 보안 · 국내 금융 보안 모듈 · MDM · VPN · ReMON 자신.
public enum StartupProtection {
    /// 5자 이하 표식은 낱말이 정확히 같을 때만, 그보다 길면 포함만 해도 맞는 것으로 본다(오탐을 줄이려고).
    static let vendors: [(category: String, marks: [String])] = [
        ("보안 프로그램", ["crowdstrike", "sentinelone", "carbonblack", "cbdefense", "sophos", "malwarebytes", "eset", "kaspersky", "bitdefender", "avast", "avg",
                       "norton", "symantec", "mcafee", "trendmicro", "intego", "objective-see", "lulu", "blockblock", "littlesnitch", "obdev", "wdav",
                       "defender", "tanium", "qualys", "rapid7", "cylance", "cisco", "forcepoint", "checkpoint", "agilebits", "1password", "bitwarden",
                       "dashlane", "keepersecurity", "yubico", "clamxav", "virusbarrier", "webroot", "f-secure", "huntress", "elastic-agent", "osquery"]),
        ("국내 금융·공공 보안 모듈", ["ahnlab", "astx", "safetransaction", "wizvera", "veraport", "delfino", "initech", "inisafe", "raonsecure", "touchen",
                                 "nprotect", "inca", "xecure", "softforum", "ksign", "anysign", "hancomwith", "crossweb", "iniline", "dreamsecurity",
                                 "magicline", "interezen", "ipinside", "nwsdaemon", "mvaccine", "everspin", "kings"]),
        ("MDM(기기 관리)", ["jamf", "kandji", "mosyle", "addigy", "hexnode", "airwatch", "workspaceone", "intune", "companyportal", "fleetsmith",
                         "simplemdm", "miradore", "filewave", "absolute", "mdm"]),
        ("VPN", ["tailscale", "wireguard", "openvpn", "tunnelblick", "viscosity", "cloudflare", "warp", "mullvad", "nordvpn", "expressvpn", "protonvpn",
                 "surfshark", "globalprotect", "paloalto", "fortinet", "forticlient", "pulsesecure", "ivanti", "zscaler", "netskope", "anyconnect",
                 "secureclient", "windscribe", "privateinternetaccess", "astrill", "hotspotshield", "purevpn", "ipvanish", "vpn"])
    ]

    public static func reason(label: String, program: String?, plistPath: String) -> String? {
        if label.hasPrefix("com.apple.") || plistPath.hasPrefix("/System/") || (program ?? "").hasPrefix("/System/") || (program ?? "").hasPrefix("/usr/libexec/") {
            return "Apple 항목이라 끄지 않습니다"
        }
        if label == "local.remon" || label.hasPrefix("local.remon.") || (program ?? "").contains("/ReMON.app/") { return "ReMON 자신이라 끄지 않습니다" }
        let text = [label, program ?? "", plistPath].joined(separator: " ").lowercased()
        let tokens = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for vendor in vendors {
            if let mark = vendor.marks.first(where: { $0.count <= 5 ? tokens.contains($0) : text.contains($0) }) {
                return "\(vendor.category)(\(mark))이라 끄지 않습니다"
            }
        }
        return nil
    }
}

public struct StartupItemScanner: Sendable {
    public struct Folder: Sendable, Equatable {
        public var domain: StartupItem.Domain
        public var path: String
        public init(_ domain: StartupItem.Domain, _ path: String) {
            self.domain = domain
            self.path = path
        }
    }

    public struct ListEntry: Sendable, Equatable {
        public var pid: Int32?
        /// 마지막 종료 상태(음수 = 신호)
        public var status: Int32
    }

    public static let launchctl = "/bin/launchctl"
    /// launchd가 슬래시 없는 실행 이름에 쓰는 기본 PATH
    public static let defaultPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    static let interpreters: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "python", "python3", "node", "ruby", "perl", "osascript", "bun", "deno", "php"]

    public static var userAgentsFolder: String { FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents" }
    public static var defaultFolders: [Folder] {
        [Folder(.userAgent, userAgentsFolder), Folder(.globalAgent, "/Library/LaunchAgents"), Folder(.systemDaemon, "/Library/LaunchDaemons")]
    }

    public var folders: [Folder]
    public var uid: uid_t
    public var run: CommandRunner

    public init(folders: [Folder] = StartupItemScanner.defaultFolders, uid: uid_t = getuid(), run: @escaping CommandRunner = { Shell.capture($0, $1, timeout: $2) }) {
        self.folders = folders
        self.uid = uid
        self.run = run
    }

    /// 세 폴더의 plist를 읽는다. withState면 항목마다 launchctl print(읽기 전용)로 상태를 붙인다(항목당 수 ms).
    public func scan(withState: Bool = true) -> [StartupItem] {
        var items: [StartupItem] = []
        for folder in folders {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".plist") && !name.hasPrefix(".") {
                var item = Self.parse(path: folder.path + "/" + name, domain: folder.domain)
                if withState, item.hasLabel { item.state = state(label: item.label, domain: item.domain) }
                items.append(item)
            }
        }
        return items
    }

    public static func parse(path: String, domain: StartupItem.Domain) -> StartupItem {
        let fm = FileManager.default
        let fileName = (path as NSString).lastPathComponent
        var item = StartupItem(plistPath: path, domain: domain, label: (fileName as NSString).deletingPathExtension, hasLabel: false, program: nil, arguments: [],
                               runAtLoad: false, keepAlive: .off, disabledInPlist: false, readable: false)
        item.symlinkTarget = try? fm.destinationOfSymbolicLink(atPath: path)
        func finished(_ item: StartupItem) -> StartupItem {
            var item = item
            item.protection = StartupProtection.reason(label: item.label, program: item.resolvedProgram ?? item.program, plistPath: item.symlinkTarget ?? path)
            return item
        }
        guard let data = fm.contents(atPath: path) else {
            item.parseError = "읽을 수 없습니다(권한·깨진 링크)"
            return finished(item)
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            item.parseError = "plist 형식이 아닙니다"
            return finished(item)
        }
        item.readable = true
        if let label = plist["Label"] as? String, !label.isEmpty {
            item.label = label
            item.hasLabel = true
        }
        let arguments = (plist["ProgramArguments"] as? [Any])?.compactMap { $0 as? String } ?? []
        item.arguments = arguments
        let bundleProgram = plist["Program"] == nil && arguments.isEmpty ? plist["BundleProgram"] as? String : nil
        item.program = (plist["Program"] as? String) ?? arguments.first ?? bundleProgram
        item.runAtLoad = plist["RunAtLoad"] as? Bool ?? false
        switch plist["KeepAlive"] {
        case let flag as Bool: item.keepAlive = flag ? .always : .off
        case is [String: Any]: item.keepAlive = .conditional
        default: item.keepAlive = .off
        }
        item.disabledInPlist = plist["Disabled"] as? Bool ?? false
        if bundleProgram == nil {
            let searchPath = ((plist["EnvironmentVariables"] as? [String: Any])?["PATH"] as? String).map { $0.split(separator: ":").map(String.init) }
            let resolved = resolve(program: item.program, arguments: arguments, searchPath: searchPath, workingDirectory: plist["WorkingDirectory"] as? String)
            item.resolvedProgram = resolved.resolved
            item.missingProgram = resolved.missing
        }
        return finished(item)
    }

    /// 실행 파일을 찾고, 인터프리터(sh·zsh·python·node …)면 실행할 스크립트 파일도 있는지 본다.
    /// 예: `/bin/zsh -li ~/run.sh`에서 run.sh가 없으면 zsh가 127로 끝나고 KeepAlive가 몇 초마다 다시 띄운다.
    static func resolve(program: String?, arguments: [String], searchPath: [String]?, workingDirectory: String?) -> (resolved: String?, missing: String?) {
        guard let program, !program.isEmpty else { return (nil, "(실행 파일 지정 없음)") }
        let fm = FileManager.default
        let resolved: String
        if program.hasPrefix("/") {
            resolved = program
        } else if program.contains("/") {
            resolved = ((workingDirectory ?? "/") as NSString).appendingPathComponent(program)
        } else if let found = (searchPath ?? defaultPath).map({ $0 + "/" + program }).first(where: { fm.isExecutableFile(atPath: $0) }) {
            resolved = found
        } else {
            return (nil, program)
        }
        guard fm.fileExists(atPath: resolved) else { return (resolved, resolved) }
        let name = (resolved as NSString).lastPathComponent
        if interpreters.contains(name) || name.hasPrefix("python") {
            let rest = arguments.dropFirst()
            if rest.contains("-c") || rest.contains("-e") { return (resolved, nil) } // 명령을 인자로 바로 줌
            if let script = rest.first(where: { !$0.hasPrefix("-") }), script.hasPrefix("/"), !fm.fileExists(atPath: script) { return (resolved, script) }
        }
        return (resolved, nil)
    }

    /// launchctl print <도메인>/<라벨>. 못 찾으면 로드 안 됨.
    public func state(label: String, domain: StartupItem.Domain) -> LaunchdJobState {
        let result = run(Self.launchctl, ["print", domain.target(uid: uid) + "/" + label], 10)
        if result.succeeded { return Self.parsePrint(result.stdout) }
        let text = result.stderr + result.stdout
        if result.status == 113 || text.contains("Could not find service") { return .notLoaded }
        let reason = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init) ?? "종료 코드 \(result.status)"
        return LaunchdJobState(loaded: false, running: false, error: result.timedOut ? "시간 초과" : reason)
    }

    /// 최상위 항목(탭 하나)만 읽는다. 안쪽 블록(coalition 등)의 'state = active'는 무시한다.
    public static func parsePrint(_ text: String) -> LaunchdJobState {
        var state = LaunchdJobState(loaded: true, running: false)
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("\t"), !line.hasPrefix("\t\t"), let range = line.range(of: " = ") else { continue }
            let key = line[line.index(after: line.startIndex)..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "state": state.running = value == "running"
            case "pid": state.pid = Int32(value)
            case "runs": state.runs = Int(value)
            case "last exit code":
                state.lastExit = value
                state.lastExitCode = Int32(String(value.prefix { $0 == "-" || $0.isNumber }))
            case "last terminating signal": state.lastSignal = value
            case "program": state.program = value
            default: break
            }
        }
        return state
    }

    /// launchctl list(사용자 도메인): "PID\tStatus\tLabel".
    public static func parseList(_ text: String) -> [String: ListEntry] {
        var result: [String: ListEntry] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3, parts[0] != "PID" else { continue }
            result[String(parts[2])] = ListEntry(pid: Int32(parts[0]), status: Int32(parts[1]) ?? 0)
        }
        return result
    }
}

/// 끄기·다시 켜기. 시스템 영역은 다루지 않는다.
public struct StartupItemManager: Sendable {
    public static let vaultReason = "시작 항목 끄기"
    public static let loginItemsSettingsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    public enum Result: Sendable, Equatable {
        case done(String)
        case refused(String)
        case failed(String)

        public var ok: Bool { if case .done = self { return true }; return false }
        public var message: String {
            switch self {
            case .done(let text), .refused(let text), .failed(let text): text
            }
        }
    }

    public var uid: uid_t
    /// 끌 수 있는 plist가 있어야 하는 폴더(이 폴더 바로 아래 파일만 끈다)
    public var userAgentsFolder: String
    public var run: CommandRunner
    public var audit: AuditLog

    public init(uid: uid_t = getuid(), userAgentsFolder: String = StartupItemScanner.userAgentsFolder,
                run: @escaping CommandRunner = { Shell.capture($0, $1, timeout: $2) }, audit: AuditLog = .shared) {
        self.uid = uid
        self.userAgentsFolder = userAgentsFolder
        self.run = run
        self.audit = audit
    }

    /// 복구함의 시작 항목 기록인가(되돌릴 때 launchctl bootstrap이 필요).
    public static func isStartupEntry(_ entry: RecoveryEntry) -> Bool { entry.kind == .trash && entry.reason == vaultReason }

    /// 끄기: 실행 직전 재검증 → launchctl bootout gui/$UID/<라벨> → plist를 휴지통(금고 기록). 휴지통 이동이 실패하면 다시 켜 둔다.
    public func disable(_ item: StartupItem, vault: RecoveryVault?, dryRun: Bool) -> Result {
        let target = "\(item.label) (\(item.plistPath))"
        if let blocker = item.disableBlocker {
            audit.write(action: "startup.disable", target: target, result: "blocked: " + blocker, dryRun: dryRun)
            return .refused(blocker)
        }
        let folder = SafeFileOps.canonical(userAgentsFolder)
        guard SafeFileOps.canonical((item.plistPath as NSString).deletingLastPathComponent) == folder else {
            audit.write(action: "startup.disable", target: target, result: "blocked: outside user agents folder", dryRun: dryRun)
            return .refused("내 LaunchAgents 폴더 밖의 plist라 끄지 않습니다")
        }
        // 검토한 뒤 plist가 바뀌었으면(다른 라벨·보호 대상이 됨) 멈춘다.
        let fresh = StartupItemScanner.parse(path: item.plistPath, domain: item.domain)
        guard fresh.readable, fresh.label == item.label, fresh.canDisable else {
            audit.write(action: "startup.disable", target: target, result: "skipped: changed since review", dryRun: dryRun)
            return .refused("검토한 뒤 plist가 바뀌었습니다 — 다시 조사하세요")
        }
        if dryRun {
            audit.write(action: "startup.disable", target: target, result: "dry-run", dryRun: true)
            return .done("드라이런: \(item.label)을(를) 끄고 plist를 휴지통으로 옮깁니다")
        }
        let service = "gui/\(uid)/\(item.label)"
        let scanner = StartupItemScanner(folders: [], uid: uid, run: run)
        let wasLoaded = scanner.state(label: item.label, domain: .userAgent).loaded
        if wasLoaded {
            let out = run(StartupItemScanner.launchctl, ["bootout", service], 20)
            // 3(No such process) = 그사이 이미 내려감
            guard out.succeeded || out.status == 3 else {
                let why = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                audit.write(action: "startup.disable", target: target, result: "error: bootout \(out.status) \(why.prefix(160))", dryRun: false)
                return .failed("끄지 못했습니다(launchctl bootout \(out.status)): \(why.prefix(160))")
            }
        }
        var info = stat()
        let bytes = lstat(item.plistPath, &info) == 0 ? UInt64(info.st_size) : 0
        let trashed: URL?
        do {
            trashed = try SafeFileOps.moveToTrash(item.plistPath, userPIDs: [], dryRun: false, bytes: bytes, audit: audit, vault: vault, project: "", reason: Self.vaultReason)
        } catch {
            var rollback = ""
            if wasLoaded {
                let back = run(StartupItemScanner.launchctl, ["bootstrap", "gui/\(uid)", item.plistPath], 20)
                rollback = back.succeeded ? " · 다시 켜 두었습니다" : " · 다시 켜지 못했습니다(다음 로그인 때 켜짐)"
            }
            audit.write(action: "startup.disable", target: target, result: "error: trash \(error)" + rollback, dryRun: false)
            return .failed("plist를 휴지통으로 옮기지 못했습니다: \(error)" + rollback)
        }
        // 금고 항목에 라벨·다시 켜는 명령을 적는다(복구함 '명령 복사'와 다시 켜기에 쓰인다).
        if let vault, let path = trashed?.path, let entry = vault.all().first(where: { $0.trashedPath == path }) {
            try? vault.update(entry.id) { stored in
                stored.title = item.label
                stored.note = "\(item.domain.label) · \(item.program ?? "실행 파일 미상")" + (wasLoaded ? "" : " · 끄기 전에도 로드돼 있지 않았음")
                stored.restoreHint = "launchctl bootstrap gui/\(uid) \(ResumeKey.quote(item.plistPath))"
            }
        }
        let stillLoaded = wasLoaded && scanner.state(label: item.label, domain: .userAgent).loaded
        audit.write(action: "startup.disable", target: target, bytes: bytes, result: stillLoaded ? "partial: still loaded" : "ok", dryRun: false,
                    detail: ["trashed_to": trashed?.path ?? "", "was_loaded": wasLoaded])
        return .done(stillLoaded ? "\(item.label) plist는 휴지통으로 옮겼지만 아직 로드돼 있습니다(로그아웃하면 사라짐)"
                                 : "\(item.label) 끔 · plist는 휴지통으로 옮겼습니다(복구함에서 다시 켬)")
    }

    /// 다시 켜기: 휴지통에서 원래 자리로 → launchctl bootstrap gui/$UID <plist>. bootstrap이 실패해도 파일은 되돌려 다음 로그인 때 켜진다.
    public func restore(_ entry: RecoveryEntry, vault: RecoveryVault) -> Result {
        guard Self.isStartupEntry(entry), let original = entry.originalPath else { return .refused("시작 항목 기록이 아닙니다") }
        let moved = RecoveryRestorer.restoreTrash(entry, vault: vault)
        guard moved.ok else {
            audit.write(action: "startup.restore", target: original, result: "error: " + moved.message, dryRun: false, detail: ["entry": entry.id])
            return .failed(moved.message)
        }
        let label = entry.title
        let out = run(StartupItemScanner.launchctl, ["bootstrap", "gui/\(uid)", original], 20)
        // 이미 로드돼 있어도 5(Input/output error)가 난다 → print로 실제 상태를 본다.
        let loaded = out.succeeded || StartupItemScanner(folders: [], uid: uid, run: run).state(label: label, domain: .userAgent).loaded
        let note = loaded ? "원래 자리로 되돌리고 다시 켰습니다(launchctl bootstrap)" : "원래 자리로 되돌렸습니다 · 지금 켜지 못함(\(out.status)) — 다음 로그인 때 켜집니다"
        try? vault.update(entry.id) { $0.note = note }
        audit.write(action: "startup.restore", target: "\(label) (\(original))", result: loaded ? "ok" : "partial: bootstrap \(out.status) \(out.stderr.prefix(120))",
                    dryRun: false, detail: ["entry": entry.id])
        return .done(loaded ? "\(label) 다시 켰습니다" : "\(label) 파일은 되돌렸습니다 · 다음 로그인 때 켜집니다")
    }
}
