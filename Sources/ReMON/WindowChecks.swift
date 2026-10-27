import AppKit
import ReMONCore

/// 실제 NSApplication 이벤트 루프에서 창 활성화·메뉴 소유권을 검사한다. 수집·정리 엔진은 시작하지 않는다.
@MainActor
final class WindowChecks: NSObject, NSApplicationDelegate {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remon-window-check-" + UUID().uuidString)
    private lazy var model = AppModel(vault: RecoveryVault(folder: folder))
    private lazy var office = OfficeWindowController(model: model)
    private lazy var settings = SettingsWindowController(model: model)
    private var failures = 0
    private var step = 0
    private var status: StatusItemController?
    private var cleanupStarted = Date.distantPast
    private var savedDryRun = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setenv("REMON_VAULT_DIR", folder.path, 1)
        NSApp.setActivationPolicy(.accessory)
        let menu = NSMenu()
        let item = NSMenuItem()
        item.submenu = NSMenu(title: "ReMON 검사")
        item.submenu?.addItem(withTitle: "검사", action: nil, keyEquivalent: "")
        menu.addItem(item)
        NSApp.mainMenu = menu
        model.monitor.onOffice = nil
        model.monitor.onSystem = nil
        savedDryRun = model.settings.dryRun
        if CommandLine.arguments.contains("--status-cost") {
            status = StatusItemController(model: model)
            let started = cpuSeconds()
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                MainActor.assumeIsolated {
                    self.step += 1
                    self.model.system.cpuPercent = [40.0, 42, 39, 41][self.step % 4]
                    if self.step == 30 {
                        timer.invalidate()
                        print(String(format: "status-only CPU %.3f%% (30s)", (self.cpuSeconds() - started) / 30 * 100))
                        try? FileManager.default.removeItem(at: self.folder)
                        exit(0)
                    }
                }
            }
            return
        }
        advance()
    }

    private func cpuSeconds() -> Double {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        return Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec) + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
    }

    private func check(_ window: NSWindow?, _ label: String) {
        let ownsMenu = NSWorkspace.shared.menuBarOwningApplication?.processIdentifier == getpid()
        let ok = window?.isVisible == true && window?.isKeyWindow == true && NSApp.isActive && ownsMenu
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL") \(label): visible=\(window?.isVisible == true) key=\(window?.isKeyWindow == true) active=\(NSApp.isActive) menu=\(ownsMenu) policy=\(NSApp.activationPolicy().rawValue)")
    }

    private func advance() {
        switch step {
        case 0: office.show(from: nil)
        case 1: check(office.window, "처음 열기"); office.window?.close()
        case 2: office.show(from: nil)
        case 3: check(office.window, "다시 열기"); settings.show()
        case 4: check(settings.window, "사무실 위 설정 열기"); office.window?.close()
        case 5: check(settings.window, "사무실 닫은 뒤 설정 유지"); settings.window?.close()
        case 6:
            let released = settings.window == nil
            if !released { failures += 1 }
            print("\(released ? "PASS" : "FAIL") 닫힌 설정 창 해제")
            settings.show()
        case 7: check(settings.window, "메뉴 막대에서 설정만 열기"); settings.window?.close()
        case 8: office.show(from: nil)
        case 9: check(office.window, "설정 닫은 뒤 사무실 열기"); settings.show()
        case 10: settings.window?.close()
        case 11: check(office.window, "설정 닫은 뒤 사무실 입력 유지")
        case 12:
            let timer = Timer(timeInterval: 0.5, repeats: false) { _ in MainActor.assumeIsolated {
                self.check(NSApp.modalWindow, "확인 대화상자 입력")
                NSApp.abortModal()
            } }
            RunLoop.main.add(timer, forMode: .modalPanel)
            _ = Confirm.ask(title: "입력 검사", text: "실제 조치를 하지 않는 검사입니다.", action: "검사", destructive: true)
        case 13: startCleanup()
        case 14:
            if !model.projectCleaning.isEmpty && Date().timeIntervalSince(cleanupStarted) < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.advance() }
                return
            }
            let removed = !git(["show-ref", "--verify", "refs/heads/merged-test"]).succeeded
            let saved = model.vault.all().contains { $0.kind == .branch && $0.branch == "merged-test" }
            let reflected = model.roomClutter["청소검사"] == nil && office.scene.janitorBusy
            let ok = removed && saved && reflected && model.projectCleaning.isEmpty
            if !ok { failures += 1 }
            print("\(ok ? "PASS" : "FAIL") 프로젝트 청소: 더미 브랜치 제거=\(removed) 금고 기록=\(saved) 방 반영=\(reflected)")
            office.window?.close()
        default:
            model.settings.dryRun = savedDryRun
            try? FileManager.default.removeItem(at: folder)
            print(failures == 0 ? "ALL PASS" : "FAILURES: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        step += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.advance() }
    }

    private func git(_ arguments: [String]) -> CommandResult {
        var environment = LeftoverTools.commandEnvironment
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        return Shell.capture("/usr/bin/git", ["-C", folder.path, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-c", "user.name=ReMON test", "-c", "user.email=test@invalid"] + arguments, environment: environment, timeout: 10)
    }

    private func startCleanup() {
        _ = git(["init", "-b", "main"])
        _ = git(["commit", "--allow-empty", "-m", "dummy"])
        _ = git(["branch", "merged-test"])
        let head = git(["rev-parse", "HEAD"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let harness = SceneHarness()
        harness.sessions = [SceneChecks.session(93_001, "청소검사", .working, order: 0)]
        model.office = harness.snapshot()
        office.show(from: nil)
        model.leftovers = [ProjectLeftovers(project: "청소검사", repos: [folder.path], worktrees: [], branches: [BranchLeftover(repo: folder.path, project: "청소검사", name: "merged-test", merged: true, verdict: .cleanable(.deleteMergedBranch), head: head)])]
        model.projectGarbage = ["청소검사": ProjectGarbage(papers: 2)]
        model.refreshProjectGarbage()
        model.settings.dryRun = false
        cleanupStarted = Date()
        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in MainActor.assumeIsolated {
            func find(_ view: NSView) -> NSButton? {
                if let button = view as? NSButton, button.title == "청소부 투입" { return button }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            if let content = NSApp.modalWindow?.contentView, let button = find(content) { button.performClick(nil) }
            else { NSApp.abortModal() }
        } }
        RunLoop.main.add(timer, forMode: .modalPanel)
        model.cleanProject("청소검사")
    }
}
