import AppKit
import ServiceManagement

let arguments = CommandLine.arguments
if arguments.contains("--window-check") || arguments.contains("--status-cost") {
    let application = NSApplication.shared
    MainActor.assumeIsolated {
        let delegate = WindowChecks()
        application.delegate = delegate
        application.run()
    }
}
// 설치 검증용: 로그인 실행 등록 상태만 출력하고 끝낸다(실행 중인 상주 앱과 무관).
if arguments.contains("--login-item-status") {
    let labels: [SMAppService.Status: String] = [.notRegistered: "notRegistered", .enabled: "enabled", .requiresApproval: "requiresApproval", .notFound: "notFound"]
    print("login item: \(labels[SMAppService.mainApp.status] ?? "unknown") · \(Bundle.main.bundlePath)")
    exit(0)
}
if let index = arguments.firstIndex(of: "--render-sprites"), index + 1 < arguments.count {
    SpritePreview.render(to: arguments[index + 1])
    exit(0)
}
// 검수용: 장면 시험(가짜 스냅샷 + 직접 돌리는 시계). 창을 띄우지 않고 결과만 출력한다.
if let index = arguments.firstIndex(of: "--scene-check") {
    // 같은 씨앗이면 매번 같은 결과: 사전 순회 순서(해시 씨앗)도 고정하려고 환경 변수를 넣어 자신을 한 번 다시 실행한다.
    if ProcessInfo.processInfo.environment["SWIFT_DETERMINISTIC_HASHING"] == nil, let path = Bundle.main.executablePath {
        setenv("SWIFT_DETERMINISTIC_HASHING", "1", 1)
        execv(path, CommandLine.unsafeArgv)
    }
    let name = index + 1 < arguments.count ? arguments[index + 1] : "all"
    let out = arguments.firstIndex(of: "--out").flatMap { $0 + 1 < arguments.count ? URL(fileURLWithPath: arguments[$0 + 1]) : nil }
    _ = NSApplication.shared
    let code = MainActor.assumeIsolated { SceneChecks.run(name, out: out) }
    exit(code)
}
if let index = arguments.firstIndex(of: "--render-floors"), index + 1 < arguments.count {
    SpritePreview.renderFloors(to: arguments[index + 1])
    exit(0)
}
if let index = arguments.firstIndex(of: "--render-icon"), index + 1 < arguments.count {
    let seed = arguments.firstIndex(of: "--icon-seed").flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil }
    AppIcon.writeIconset(to: arguments[index + 1], seed: seed)
    exit(0)
}
if let index = arguments.firstIndex(of: "--render-disk-sections"), index + 1 < arguments.count {
    MainActor.assumeIsolated { DiskSectionsPreview.render(to: arguments[index + 1]) }
    exit(0)
}

let application = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
