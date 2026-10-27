import AppKit
import ReMONCore
import SwiftUI

/// 상주 수명주기(Folder Backup 방식): 창 닫기·⌘Q는 메뉴 막대로 보내고, '완전히 종료…'와 로그아웃·재시동만 실제로 끝낸다.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var status: StatusItemController?
    private lazy var office = OfficeWindowController(model: model)
    private lazy var settings = SettingsWindowController(model: model)
    private var setupSheet: NSWindow?
    private var reallyQuit = false
    private var demo: DemoDirector?
    private var perf: PerfDirector?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppIcon.apply()   // 사용자마다 다른 엄지척 직원(번들은 건드리지 않음)
        buildMenu()
        model.start()
        let status = StatusItemController(model: model)
        status.onOpenOffice = { [weak self] rect in self?.office.show(from: rect) }
        status.onSettings = { [weak self] in self?.showSettings() }
        self.status = status
        if PerfDirector.isActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.office.show(from: nil) }
            let director = PerfDirector(model: model, office: office)
            perf = director
            director.run()
        }
        // 검수용: 메뉴 막대 패널을 열어 실제 창 위치를 확인한다.
        if CommandLine.arguments.contains("--open-menu-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.status?.togglePanel() }
        }
        if CommandLine.arguments.contains("--open-office") || SnapshotTool.folder() != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.office.show(from: nil) }
        }
        // 검수용: `--page dashboard` 대시보드로 · `--settings <탭>` 설정 창 · `--capture-ui <폴더>` 설정 탭·도우미·대시보드 캡처.
        if let index = CommandLine.arguments.firstIndex(of: "--page"), index + 1 < CommandLine.arguments.count, let page = OfficePage.allCases.first(where: { "\($0)" == CommandLine.arguments[index + 1] }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.model.page = page }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--settings"), index + 1 < CommandLine.arguments.count, let tab = SettingsTab(argument: CommandLine.arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.showSettings(tab: tab) }
        }
        if let folder = SnapshotTool.uiFolder() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.captureUI(to: folder) }
        }
        // 첫 실행: 권한 점검을 사무실 창 위 시트로 한 번 띄운다(설정 '권한' 탭에서 다시 볼 수 있다).
        if SetupAssistant.shouldShowOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.presentSetupAssistant() }
        }
        if let folder = SnapshotTool.folder() {
            let capture: (String) -> Void = { [weak self] tag in self?.office.snapshot(to: folder, tag: tag) }
            if DemoDirector.isActive {
                let director = DemoDirector(model: model, capture: capture)
                demo = director
                director.run()
            } else {
                // REMON_SNAPSHOT_AT: 첫 캡처 시각(초). 부하가 크면 첫 감지가 늦어 6초 캡처에 세션이 비어 보인다.
                let at = Double(ProcessInfo.processInfo.environment["REMON_SNAPSHOT_AT"] ?? "") ?? 6
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { capture("a") }
                DispatchQueue.main.asyncAfter(deadline: .now() + at + 3) { capture("b") }
                if CommandLine.arguments.contains("--snapshot-exit") { DispatchQueue.main.asyncAfter(deadline: .now() + at + 4) { exit(0) } }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        office.show(from: nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if reallyQuit || Self.isSystemShutdown() { return .terminateNow }
        sendToMenuBar()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.monitor.stop()
    }

    @objc func sendToMenuBar() {
        // 상태 막대 창(NSStatusBarWindow)은 숨기지 않는다(LeCIE 교훈: 전체 orderOut 시 상단 아이콘까지 사라짐).
        for window in NSApp.windows where window.isVisible && window.level == .normal && !(window.className.contains("StatusBar")) {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc func quitForReal() {
        guard Confirm.ask(title: "ReMON을 완전히 종료할까요?", text: "메뉴 막대 상주와 경보·기록이 멈춥니다.", action: "완전히 종료") else { return }
        reallyQuit = true
        NSApp.terminate(nil)
    }

    @objc func showSettings() { showSettings(tab: nil) }

    /// 설정 창(일반 · 에이전트 · 정리·복구 · 권한 · 정보). tab이 있으면 그 탭을 연다.
    func showSettings(tab: SettingsTab?) {
        settings.show(tab: tab)
    }

    /// 권한 점검 시트: 사무실 창을 열고 그 위에 붙인다. 띄운 순간 '보였음'으로 기록한다(첫 실행 한 번).
    func presentSetupAssistant() {
        if let sheet = setupSheet, sheet.sheetParent == nil { setupSheet = nil }   // 사무실 창과 함께 닫힌 시트
        guard setupSheet == nil else { return }
        office.show(from: nil)
        guard let parent = office.window else { return }
        let controller = NSHostingController(rootView: SetupAssistantView(model: model, mode: .sheet) { [weak self] in self?.closeSetupAssistant() })
        controller.sizingOptions = [.preferredContentSize]
        let sheet = NSWindow(contentViewController: controller)
        sheet.styleMask = [.titled]
        setupSheet = sheet
        parent.beginSheet(sheet)
        SetupAssistant.markShown()
    }

    private func closeSetupAssistant() {
        guard let sheet = setupSheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        setupSheet = nil
    }

    /// 검수용 캡처: 설정 탭 5개 · 첫 실행 시트 · 대시보드를 PNG로 남기고(화면 기록 권한 불필요) `--snapshot-exit`면 끝낸다.
    /// 첫 감지(세션 목록)가 끝나야 '실행 중' 수가 맞으므로 그때까지 기다린다(최대 150초 — 부하가 큰 Mac에서 첫 감지가 느리다).
    private func captureUI(to folder: URL, waited: Double = 0) {
        guard model.office != nil || waited >= 150 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.captureUI(to: folder, waited: waited + 0.5) }
            return
        }
        var steps: [(Double, @MainActor @Sendable () -> Void)] = []
        for (offset, tab) in SettingsTab.allCases.enumerated() {
            let at = Double(offset) * 1.6
            steps.append((at, { [weak self] in self?.showSettings(tab: tab) }))
            steps.append((at + 1.2, { [weak self] in SnapshotTool.captureWindow(self?.settings.window, to: folder, name: "settings-\(tab.rawValue)-\(tab)") }))
        }
        let base = Double(SettingsTab.allCases.count) * 1.6
        steps.append((base, { [weak self] in self?.settings.window?.orderOut(nil); self?.model.page = .dashboard; self?.office.show(from: nil) }))
        steps.append((base + 4.0, { [weak self] in
            print("capture: 세션 \(self?.model.office?.sessions.count ?? -1) · 프로세스 \(self?.model.office?.processCount ?? -1) · 대기 \(waited)초")
            SnapshotTool.captureWindow(self?.office.window, to: folder, name: "dashboard")
        }))
        // 대시보드는 스크롤 화면이라 카드가 접힌 아래쪽에 있을 수 있다 → '이 Mac에서 찾은 에이전트' 카드만 따로 창에 띄워 남긴다.
        steps.append((base + 4.2, { [weak self] in
            guard let self else { return }
            let card = NSWindow(contentViewController: NSHostingController(rootView: AgentInventoryCard(model: self.model).padding(16).frame(width: 980)))
            card.title = "이 Mac에서 찾은 에이전트"
            card.styleMask = [.titled]
            card.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                SnapshotTool.captureWindow(card, to: folder, name: "dashboard-agents-card")
                card.orderOut(nil)
            }
        }))
        steps.append((base + 5.2, { [weak self] in self?.presentSetupAssistant() }))
        steps.append((base + 7.0, { [weak self] in SnapshotTool.captureWindow(self?.setupSheet, to: folder, name: "setup-sheet"); SnapshotTool.captureWindow(self?.office.window, to: folder, name: "setup-sheet-parent") }))
        steps.append((base + 7.5, { [weak self] in self?.closeSetupAssistant() }))
        // 표 에이전트(Gemini 등)가 돌고 있으면 사무실에서 그 직원을 골라 상세 카드까지 남긴다.
        steps.append((base + 8.5, { [weak self] in
            guard let self, let session = self.model.office?.sessions.first(where: { $0.kind.isGeneric }) else { return }
            self.model.selectSession(session)
        }))
        steps.append((base + 14.5, { [weak self] in
            guard let self, self.model.selected?.kind.isGeneric == true else { return }
            SnapshotTool.captureWindow(self.office.window, to: folder, name: "office-generic-agent")
            self.office.snapshot(to: folder, tag: "generic")
        }))
        if CommandLine.arguments.contains("--snapshot-exit") { steps.append((base + 16, { exit(0) })) }
        for (time, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: step) }
    }

    @objc func openOffice() { office.show(from: nil) }

    private static func isSystemShutdown() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let reason = event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown].map { OSType($0) }.contains(reason)
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "AI 사무실 열기", action: #selector(openOffice), keyEquivalent: "o")
        appMenu.addItem(withTitle: "설정…", action: #selector(showSettings as () -> Void), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "메뉴 막대로 보내기", action: #selector(sendToMenuBar), keyEquivalent: "q")
        let quit = appMenu.addItem(withTitle: "완전히 종료…", action: #selector(quitForReal), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = [.command, .option]
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "편집")
        edit.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "모두 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "닫기", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }
}
