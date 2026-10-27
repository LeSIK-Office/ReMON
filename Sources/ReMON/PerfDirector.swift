import AppKit
import Darwin
import ReMONCore

/// 성능 실측(사양 11장): `--perf --dummy-binary <DummyAgent> --perf-log <json> [--perf-sessions 30]`.
/// 더미를 분리 실행(부모 = launchd)으로 띄워 세션 수를 맞춘 뒤 ① 사무실 창 60fps ② 새 세션 반영 지연 ③ 창을 닫은 상주 상태의
/// 앱 CPU·메모리(자기 자신 rusage)를 잰다. 끝나면 더미를 정리하고 종료한다.
@MainActor
final class PerfDirector {
    static let root = "/private/tmp/remon-perf"
    static var isActive: Bool { CommandLine.arguments.contains("--perf") }

    private let model: AppModel
    private let office: OfficeWindowController
    private lazy var settings = SettingsWindowController(model: model)
    private var results: [String: Any] = [:]
    private var probeSpawnedAt: Date?
    private var probeKey: String?

    init(model: AppModel, office: OfficeWindowController) {
        self.model = model
        self.office = office
    }

    private func argument(_ flag: String) -> String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    func run() {
        guard let binary = argument("--dummy-binary"), let log = argument("--perf-log") else { print("perf: 인자 부족"); return }
        let target = Int(argument("--perf-sessions") ?? "30") ?? 30
        let fm = FileManager.default
        try? fm.createDirectory(atPath: Self.root + "/bin", withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: Self.root + "/부하시험", withIntermediateDirectories: true)
        let dummy = Self.root + "/bin/claude"
        try? fm.removeItem(atPath: dummy)
        try? fm.copyItem(atPath: binary, toPath: dummy)

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.settings.show() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { self.settings.window?.close() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [self] in
            let existing = model.office?.sessions.count ?? 0
            let needed = max(0, target - existing)
            results["real_sessions_before"] = existing
            results["dummy_sessions_spawned"] = needed
            for _ in 0..<needed { Self.spawnDetached(dummy, cwd: Self.root + "/부하시험") }
            print("perf: real \(existing), spawned \(needed)")
        }
        // 지연 측정용 더미 하나: 생성 시각 → 장면 출근 연출 시작 시각
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
            probeSpawnedAt = Date()
            Self.spawnDetached(dummy, cwd: Self.root + "/지연측정")
        }
        office.scene.onArrival = { [weak self] session in
            guard let self, let spawned = self.probeSpawnedAt, self.probeKey == nil, session.cwd?.hasSuffix("/지연측정") == true else { return }
            self.probeKey = session.project
            self.results["arrival_latency_seconds"] = Date().timeIntervalSince(spawned)
            print("perf: arrival latency \(Date().timeIntervalSince(spawned))s")
        }
        try? fm.createDirectory(atPath: Self.root + "/지연측정", withIntermediateDirectories: true)
        // 창이 열린 상태에서 FPS(20초)와 CPU
        DispatchQueue.main.asyncAfter(deadline: .now() + 26) { [self] in
            results["sessions_during_fps"] = model.office?.sessions.count ?? 0
            office.scene.startFPSMeter()
            let cpu = SelfUsage.begin()
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [self] in
                let fps = office.scene.stopFPSMeter()
                results["fps"] = ["average": fps.average, "p5_low": fps.low, "frames": fps.frames, "seconds": fps.seconds]
                results["window_open_cpu_percent"] = cpu.cpuPercentSinceBegin()
                results["window_open_footprint_mb"] = Double(SelfUsage.footprint()) / 1_048_576
                if let snapshot = office.window.map({ _ in true }), snapshot { office.snapshot(to: URL(fileURLWithPath: (log as NSString).deletingLastPathComponent), tag: "perf-30-sessions") }
                office.window?.close()
                // 창 정리(내용 해제·텍스처 정리)가 끝나도록 15초 안정화한 뒤 상주 상태를 잰다.
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.measureResident(log: log) }
            }
        }
    }

    /// 창을 닫은 상주 상태(메뉴 막대만): 5분 동안 자기 CPU 시간과 메모리.
    private func measureResident(log: String) {
        let cpu = SelfUsage.begin()
        var peak: UInt64 = 0
        var samples: [UInt64] = []
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { timer in
            let value = SelfUsage.footprint()
            peak = max(peak, value)
            samples.append(value)
            if samples.count >= 60 {
                timer.invalidate()
                Task { @MainActor in
                    self.results["resident_cpu_percent"] = cpu.cpuPercentSinceBegin()
                    self.results["resident_footprint_mb_avg"] = Double(samples.reduce(0, +)) / Double(samples.count) / 1_048_576
                    self.results["resident_footprint_mb_peak"] = Double(peak) / 1_048_576
                    self.results["sessions_during_resident"] = self.model.office?.sessions.count ?? 0
                    self.results["time"] = ISO8601DateFormatter().string(from: Date())
                    self.finish(log: log)
                }
            }
        }
    }

    private func finish(log: String) {
        _ = Shell.run("/usr/bin/pkill", ["-f", Self.root + "/bin/claude"], timeout: 5)
        try? FileManager.default.removeItem(atPath: Self.root)
        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: log))
        }
        print("perf: \(results)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
    }

    /// sh가 바로 끝나므로 더미의 부모는 launchd가 된다(다른 세션의 하위로 묶이지 않게).
    static func spawnDetached(_ path: String, cwd: String) {
        let quoted = path.replacingOccurrences(of: "'", with: "'\\''")
        let directory = cwd.replacingOccurrences(of: "'", with: "'\\''")
        _ = Shell.runStatus("/bin/sh", ["-c", "cd '\(directory)' && nohup '\(quoted)' --children 1 --cpu 1 --lifetime 240 >/dev/null 2>&1 &"], timeout: 5)
    }
}

/// 앱 자신의 CPU·메모리(proc_pid_rusage). 타임베이스 변환은 수집 엔진과 같다(Apple Silicon: ×125/3).
struct SelfUsage {
    let cpuNs: UInt64
    let wall: Date

    static func now() -> UInt64 {
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return (info.ri_user_time + info.ri_system_time) &* UInt64(timebase.numer) / UInt64(max(1, timebase.denom))
    }

    static func footprint() -> UInt64 {
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0) } }
        return info.ri_phys_footprint
    }

    static func begin() -> SelfUsage { SelfUsage(cpuNs: now(), wall: Date()) }

    func cpuPercentSinceBegin() -> Double {
        let elapsed = Date().timeIntervalSince(wall)
        guard elapsed > 0 else { return 0 }
        return Double(Self.now() - cpuNs) / (elapsed * 1_000_000_000) * 100
    }
}
