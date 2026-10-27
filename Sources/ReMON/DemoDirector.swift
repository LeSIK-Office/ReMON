import AppKit
import ReMONCore

/// 검수용 데모 감독: `--demo --dummy-binary <DummyAgent> --snapshot <폴더> [--snapshot-exit]`.
/// 더미 프로세스만 써서(사양 12장) 출근 → 퇴근 → 소리침·경비원 퇴출 → 트레이너 → 스왑 상자 → 디스크 경보를 차례로 재생하고 캡처한다.
@MainActor
final class DemoDirector {
    static let root = "/private/tmp/remon-dummy"
    private let model: AppModel
    private let capture: (String) -> Void
    private var dummies: [String: Process] = [:]

    init(model: AppModel, capture: @escaping (String) -> Void) {
        self.model = model
        self.capture = capture
    }

    static var isActive: Bool { CommandLine.arguments.contains("--demo") }

    /// 더미 경로 아래 실행 파일로 뜬 세션만 자동 확인 대상이다(실제 세션은 절대 해당하지 않음).
    static func isDummy(_ session: AgentSession, processes: [ProcRecord]) -> Bool {
        guard isActive, let root = processes.first(where: { $0.pid == session.rootPID }) else { return false }
        return (root.path ?? "").hasPrefix(Self.root + "/")
    }

    func run() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--dummy-binary"), index + 1 < arguments.count else {
            print("demo: --dummy-binary 필요"); return
        }
        let binary = arguments[index + 1]
        let fm = FileManager.default
        let project = Self.root + "/데모팀"
        for directory in [project, Self.root + "/bin", Self.root + "/evict", Self.root + "/node_modules/@openai/codex"] {
            try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let copies = ["claude": Self.root + "/bin/claude", "codex": Self.root + "/node_modules/@openai/codex/codex", "evict": Self.root + "/evict/claude"]
        for (_, path) in copies {
            try? fm.removeItem(atPath: path)
            try? fm.copyItem(atPath: binary, toPath: path)
        }
        var timeline: [(Double, () -> Void)] = [
            (8, { self.capture("01-baseline") }),
            (9, { self.spawn("A", copies["claude"]!, cwd: project, children: 2, cpu: 14) })
        ]
        for t in stride(from: 9.6, through: 13.2, by: 0.3) { timeline.append((t, { self.capture(String(format: "02-arrive-%04.1f", t)) })) }
        timeline.append((13, { self.spawn("B", copies["codex"]!, cwd: project, children: 3, cpu: 0) }))
        timeline.append((18, { self.capture("03-two-sessions") }))
        timeline.append((19, { self.dummies["B"]?.terminate() }))
        for t in stride(from: 20.0, through: 25.0, by: 1.0) { timeline.append((t, { self.capture(String(format: "04-depart-%04.1f", t)) })) }
        timeline.append((26, { self.spawn("C", copies["evict"]!, cwd: project, children: 1, cpu: 9) }))
        timeline.append((31, { self.evictDummy() }))
        for t in stride(from: 31.4, through: 38.0, by: 0.8) { timeline.append((t, { self.capture(String(format: "05-evict-%04.1f", t)) })) }
        timeline.append((40, { self.model.monitor.emit(OfficeEvent(kind: .pressureChanged(from: .normal, to: .critical), text: "데모 · 메모리 압박 정상 → 위험(가상 사건)")) }))
        for t in stride(from: 40.6, through: 48.0, by: 0.9) { timeline.append((t, { self.capture(String(format: "06-trainer-%04.1f", t)) })) }
        timeline.append((49, { self.model.monitor.emit(OfficeEvent(kind: .swapMoved(deltaBytes: 3 * 1_073_741_824), text: "데모 · 스왑 3.0GB 증가(가상 사건)")) }))
        timeline.append((49.5, { self.capture("07-swap-49.5") }))
        timeline.append((50.1, { self.capture("07-swap-50.1") }))
        timeline.append((51, { self.model.monitor.emit(OfficeEvent(kind: .diskLow(availableBytes: 9 * 1_073_741_824), text: "데모 · 디스크 여유 임계 미만(가상 사건)")) }))
        timeline.append((52, { self.capture("08-disk-alarm") }))
        timeline.append((53, { self.model.monitor.emit(OfficeEvent(kind: .diskRecovered(availableBytes: 21 * 1_073_741_824), text: "데모 · 디스크 경보 해제(가상 사건)")) }))
        timeline.append((55, { self.dummies["A"]?.terminate() }))
        timeline.append((58, { self.capture("09-after") }))
        timeline.append((60, { self.finish() }))
        for (time, action) in timeline {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { action() }
        }
    }

    private func spawn(_ name: String, _ path: String, cwd: String, children: Int, cpu: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--children", "\(children)", "--cpu", "\(cpu)", "--lifetime", "120"]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            dummies[name] = process
            print("demo: spawned \(name) pid \(process.processIdentifier) \(path)")
        } catch {
            print("demo: spawn failed \(error)")
        }
    }

    private func evictDummy() {
        guard let pid = dummies["C"]?.processIdentifier, let session = model.office?.sessions.first(where: { $0.rootPID == pid }) else {
            print("demo: 퇴출 대상 더미 세션을 찾지 못함"); return
        }
        model.evict(session)
    }

    private func finish() {
        for process in dummies.values where process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(atPath: Self.root)
        print("demo: finished")
        if CommandLine.arguments.contains("--snapshot-exit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
        }
    }
}
