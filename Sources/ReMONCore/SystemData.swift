import Darwin
import Foundation

// "시스템 데이터" 해설 — macOS 저장 공간 막대에서 정체가 안 보이는 덩어리를 풀어 보여 준다.
// 정리 가능 공간(purgeable) · 로컬 스냅샷 · 가상 머신 디스크 · iOS 백업 · iCloud 로컬 사본은 '보기만' 하고,
// Docker가 돌고 있으면 docker system df를 보여 준다(prune은 확인 후 사용자 계정으로만). 루트 권한은 쓰지 않는다.

public struct VolumeSpace: Sendable, Equatable {
    public var total: UInt64 = 0
    public var available: UInt64 = 0
    /// 중요한 용도로 쓸 수 있는 공간(macOS가 필요하면 비우는 캐시·스냅샷 포함)
    public var importantAvailable: UInt64 = 0

    public init(total: UInt64 = 0, available: UInt64 = 0, importantAvailable: UInt64 = 0) {
        self.total = total
        self.available = available
        self.importantAvailable = importantAvailable
    }

    /// 정리 가능 공간 = 중요 용도 여유 − 실제 여유(음수면 0)
    public var purgeable: UInt64 { importantAvailable > available ? importantAvailable - available : 0 }
}

public struct SnapshotInfo: Sendable, Equatable {
    /// nil = 목록을 읽지 못함
    public var names: [String]?
    public var note: String?

    public var count: Int? { names?.count }
    public var timeMachine: Int { names?.filter { $0.contains("TimeMachine") }.count ?? 0 }
    public var osUpdate: Int { names?.filter { $0.contains("os.update") }.count ?? 0 }
}

/// 보기만 하는 공간 덩어리(가상 머신 디스크·백업·iCloud 로컬 사본).
public struct SpaceHolder: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var title: String
    public var path: String
    /// 실제 할당량(성긴 디스크 이미지는 겉 크기보다 작다)
    public var bytes: UInt64
    /// 겉 크기(파일 하나일 때)
    public var logical: UInt64?
    /// 관리 방법(어디서 줄이는지)
    public var manage: String
    public var permissionNeeded: Bool
    /// false면 시간 제한으로 일부만 셌다(실제는 더 큼)
    public var complete: Bool = true
}

public struct DockerUsage: Sendable, Equatable, Identifiable {
    public var id: String { type }
    public var type: String
    public var total: String
    public var active: String
    public var size: String
    public var reclaimable: String
}

public struct DockerStatus: Sendable, Equatable {
    /// 돌고 있는 엔진(Docker Desktop · OrbStack · Colima·Lima · Rancher Desktop). nil = 돌지 않음
    public var engine: String?
    public var cli: String?
    public var usage: [DockerUsage] = []
    public var error: String?

    public var running: Bool { engine != nil }
}

public struct SystemDataReport: Sendable, Equatable {
    public var at: Date
    public var space: VolumeSpace
    public var snapshots: SnapshotInfo
    public var holders: [SpaceHolder]
    public var docker: DockerStatus

    public var holderBytes: UInt64 { holders.reduce(0) { $0 + $1.bytes } }
}

public enum SystemData {
    /// 볼륨 용량(URL 자원 값 — Finder·시스템 설정과 같은 출처).
    public static func volume(_ path: String = "/") -> VolumeSpace {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys) else { return VolumeSpace() }
        return VolumeSpace(total: UInt64(max(0, values.volumeTotalCapacity ?? 0)), available: UInt64(max(0, values.volumeAvailableCapacity ?? 0)),
                           importantAvailable: UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? 0)))
    }

    /// tmutil listlocalsnapshots / — 루트 없이 동작(10-25 실측). 실패하면 이유만 남기고 개수는 비운다.
    public static func snapshots(runner: CommandRunner? = nil) -> SnapshotInfo {
        let run = runner ?? { Shell.capture($0, $1, environment: ["LC_ALL": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: $2) }
        let result = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], 20)
        guard result.succeeded else {
            let why = result.timedOut ? "시간 초과" : (result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120).description)
            return SnapshotInfo(names: nil, note: "스냅샷 목록을 읽지 못했습니다(\(why.isEmpty ? "종료 코드 \(result.status)" : why))")
        }
        return SnapshotInfo(names: parseSnapshots(result.stdout), note: nil)
    }

    /// "Snapshots for volume group containing disk /:" 다음 줄들 중 com.apple.… 이름만.
    public static func parseSnapshots(_ text: String) -> [String] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("com.") }
    }

    /// 보기만 하는 덩어리. 앱이 설치된 경우에만 그 앱의 컨테이너를 본다(다른 앱 데이터 접근 확인 창을 괜히 띄우지 않게).
    /// iCloud처럼 파일 제공자가 관리하는 곳은 내려받지 않고(dataless 금지) 항목마다 시간 제한(budget초) 안에서만 센다.
    public static func holders(home: String = NSHomeDirectory(), budget: TimeInterval = 8) -> [SpaceHolder] {
        DiskScanner.withoutMaterializing { measureHolders(home: home, budget: budget) }
    }

    static func measureHolders(home: String, budget: TimeInterval) -> [SpaceHolder] {
        var result: [SpaceHolder] = []
        for (title, path, manage) in holderCandidates(home: home) {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            if isDirectory, access(path, R_OK | X_OK) != 0 {
                result.append(SpaceHolder(title: title, path: path, bytes: 0, logical: nil, manage: manage, permissionNeeded: true))
                continue
            }
            let measured = DiskScanner.allocatedSize(path, until: Date().addingTimeInterval(budget))
            guard measured.bytes > 0 else { continue }
            result.append(SpaceHolder(title: title, path: path, bytes: measured.bytes, logical: isDirectory ? nil : UInt64(max(0, info.st_size)), manage: manage,
                                      permissionNeeded: false, complete: measured.complete))
        }
        return result.sorted { $0.bytes > $1.bytes }
    }

    /// 보기만 하는 덩어리 후보(제목 · 경로 · 관리 방법). 디스크 지도도 같은 표로 태그·설명을 붙인다.
    public static func holderCandidates(home: String = NSHomeDirectory()) -> [(title: String, path: String, manage: String)] {
        let fm = FileManager.default
        func installed(_ app: String) -> Bool { fm.fileExists(atPath: "/Applications/\(app).app") || fm.fileExists(atPath: home + "/Applications/\(app).app") }
        var candidates: [(title: String, path: String, manage: String)] = [
            ("iOS·iPadOS 백업", home + "/Library/Application Support/MobileSync/Backup", "Finder › 기기 › 백업 관리에서 지웁니다"),
            ("Colima 가상 머신", home + "/.colima", "colima delete <프로필>로 지웁니다"),
            ("Lima 가상 머신", home + "/.lima", "limactl delete <이름>으로 지웁니다"),
            ("Tart 가상 머신", home + "/.tart", "tart delete <이름>으로 지웁니다"),
            ("Parallels 가상 머신", home + "/Parallels", "Parallels 제어 센터에서 지우거나 디스크 회수를 씁니다"),
            ("VirtualBox 가상 머신", home + "/VirtualBox VMs", "VirtualBox에서 가상 머신을 지웁니다"),
            ("iCloud Drive 로컬 사본", home + "/Library/Mobile Documents", "Finder에서 '다운로드한 항목 제거'를 누르면 iCloud에 남기고 공간을 돌려받습니다"),
            // 루트 소유 시스템 캐시(10-25 Mole 대조: Mole은 암호 없는 sudo 규칙으로 지운다). ReMON은 루트 도우미가 없어 크기와 직접 칠 명령만 알려 준다.
            ("시뮬레이터 시스템 캐시(관리자 권한)", "/Library/Developer/CoreSimulator/Caches",
             "시뮬레이터를 끄고 터미널에서 sudo rm -rf /Library/Developer/CoreSimulator/Caches/* (다음 부팅 때 다시 만듭니다)"),
            ("시스템 로그(관리자 권한)", "/private/var/log", "macOS가 스스로 돌려 지웁니다 — 직접 지우지 않는 것을 권합니다"),
        ]
        if installed("Docker") || fm.fileExists(atPath: home + "/Library/Containers/com.docker.docker") {
            candidates.insert(("Docker Desktop 디스크(Docker.raw)", home + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
                               "Docker Desktop › 설정 › Resources에서 줄이거나 docker system prune을 씁니다"), at: 1)
        }
        if installed("OrbStack") {
            candidates.insert(("OrbStack 디스크(data.img)", home + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img", "OrbStack 설정에서 관리합니다"), at: 1)
        }
        if installed("UTM") {
            candidates.append(("UTM 가상 머신", home + "/Library/Containers/com.utmapp.UTM/Data/Documents", "UTM에서 가상 머신을 지웁니다"))
        }
        return candidates
    }

    static let engines: [(String, CacheOwner)] = [
        ("Docker Desktop", CacheOwner("Docker Desktop", bundleIDs: ["com.docker.docker"], processNames: ["com.docker.backend", "Docker Desktop"])),
        ("OrbStack", CacheOwner("OrbStack", bundleIDs: ["dev.kdrag0n.MacVirt"], processNames: ["OrbStack", "OrbStack Helper"])),
        ("Colima·Lima", CacheOwner("Colima·Lima", processNames: ["colima", "limactl"])),
        ("Rancher Desktop", CacheOwner("Rancher Desktop", bundleIDs: ["io.rancherdesktop.app"])),
    ]

    public static func dockerEngine(_ running: RunningApps) -> String? {
        engines.first { running.isRunning($0.1) }?.0
    }

    /// 엔진이 돌 때만 docker system df(읽기 전용)를 부른다.
    public static func docker(running: RunningApps, home: String = NSHomeDirectory(), runner: CommandRunner? = nil) -> DockerStatus {
        let cli = ToolCommands.locate("docker", home: home)
        guard let engine = dockerEngine(running) else { return DockerStatus(engine: nil, cli: cli) }
        guard let cli else { return DockerStatus(engine: engine, cli: nil, error: "docker 명령을 찾지 못했습니다") }
        let run = runner ?? ToolCommands.defaultRunner(toolPath: cli)
        let result = run(cli, ["system", "df", "--format", "{{json .}}"], 20)
        guard result.succeeded else {
            return DockerStatus(engine: engine, cli: cli, error: "docker system df 실패: " + (result.timedOut ? "시간 초과" : String(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))))
        }
        return DockerStatus(engine: engine, cli: cli, usage: parseDockerDF(result.stdout))
    }

    /// --format '{{json .}}' 한 줄에 하나(없으면 표 형식도 읽는다).
    public static func parseDockerDF(_ text: String) -> [DockerUsage] {
        var rows: [DockerUsage] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else { continue }
            func field(_ key: String) -> String { (object[key] as? String) ?? (object[key] as? NSNumber)?.stringValue ?? "" }
            rows.append(DockerUsage(type: field("Type"), total: field("TotalCount"), active: field("Active"), size: field("Size"), reclaimable: field("Reclaimable")))
        }
        if !rows.isEmpty { return rows }
        // 표 형식: TYPE TOTAL ACTIVE SIZE RECLAIMABLE (칸은 공백 두 칸 이상으로 나뉜다)
        for line in text.split(separator: "\n").dropFirst() {
            let columns = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if columns.count >= 5 { rows.append(DockerUsage(type: columns[0], total: columns[1], active: columns[2], size: columns[3], reclaimable: columns[4])) }
        }
        return rows
    }

    /// 한 번에 모은 해설(읽기 전용). 무거운 부분(iCloud·가상 머신 크기)은 부르는 쪽이 백그라운드에서 돌린다.
    public static func report(home: String = NSHomeDirectory(), running: RunningApps = .live(), runner: CommandRunner? = nil) -> SystemDataReport {
        SystemDataReport(at: Date(), space: volume("/"), snapshots: snapshots(runner: runner), holders: holders(home: home), docker: docker(running: running, home: home, runner: runner))
    }
}
