import AppKit
import ReMONCore
import Security
import SwiftUI

// MARK: - 설정 창(여러 탭): 일반 · 에이전트 · 정리·복구 · 권한 · 정보
// macOS 기본 설정 창처럼 도구 막대 탭(NSTabViewController .toolbar)을 쓰고, 탭마다 SwiftUI 화면을 넣는다.

enum SettingsTab: Int, CaseIterable {
    case general, agents, recovery, permissions, about

    var label: String {
        switch self {
        case .general: "일반"
        case .agents: "에이전트"
        case .recovery: "정리·복구"
        case .permissions: "권한"
        case .about: "정보"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .agents: "person.2"
        case .recovery: "arrow.uturn.backward.circle"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }

    /// 검수용 `--settings <탭>` 인자(general · agents · recovery · permissions · about).
    init?(argument: String) {
        let names: [String: SettingsTab] = ["general": .general, "agents": .agents, "recovery": .recovery, "permissions": .permissions, "about": .about]
        guard let tab = names[argument] else { return nil }
        self = tab
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private(set) var window: NSWindow?
    private var tabs: SettingsTabController?

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show(tab: SettingsTab? = nil) {
        if window == nil { build() }
        if let tab { tabs?.selectedTabViewItemIndex = tab.rawValue }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        WindowActivation.closing(window)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible != true else { return }
            self.window?.contentViewController = nil
            self.tabs = nil
            self.window = nil
        }
    }

    func select(_ tab: SettingsTab) { tabs?.selectedTabViewItemIndex = tab.rawValue }

    private func build() {
        let tabs = SettingsTabController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let controller = NSHostingController(rootView: AnyView(content(for: tab)))
            controller.sizingOptions = [.preferredContentSize]
            controller.title = tab.label
            let item = NSTabViewItem(viewController: controller)
            item.label = tab.label
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.label)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.isRestorable = false   // 다음 실행 때 저절로 다시 열리지 않게
        window.delegate = self
        window.center()
        self.tabs = tabs
        self.window = window
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView(model: model)
        case .agents: AgentSettingsView(model: model)
        case .recovery: RecoverySettingsView(model: model)
        case .permissions: SetupAssistantView(model: model, mode: .tab)
        case .about: AboutSettingsView()
        }
    }
}

/// 탭을 바꾸면 창 크기를 그 탭 화면에 맞춘다(위쪽 모서리 고정).
final class SettingsTabController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard let controller = tabViewItem?.viewController, let window = view.window else { return }
        let size = controller.preferredContentSize.width > 0 ? controller.preferredContentSize : controller.view.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.minY, width: size.width, height: size.height))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

// MARK: - 일반

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: Settings

    init(model: AppModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        Form {
            Section("메뉴 막대") {
                ForEach(MenuMetric.allCases) { metric in
                    Toggle(metric.label, isOn: Binding(get: { settings.menuMetrics.contains(metric) }, set: { on in
                        if on { settings.menuMetrics.append(metric) } else { settings.menuMetrics.removeAll { $0 == metric } }
                        settings.menuMetrics = MenuMetric.allCases.filter { settings.menuMetrics.contains($0) }
                    }))
                }
            }
            Section("경보") {
                HStack {
                    Text("디스크 여유 임계")
                    Slider(value: $settings.diskThresholdGB, in: 5...60, step: 1)
                    Text("\(Int(settings.diskThresholdGB))GB").monospacedDigit().frame(width: 44)
                }
                Text("스왑이 1분에 1GB 넘게 늘거나 메모리 압박이 '위험'이면 알림을 보냅니다.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("정리") {
                Toggle("드라이런(실행 없이 결과만 기록)", isOn: $settings.dryRun)
                Text("보호 고정 \(settings.pinnedSessions.count)개 · 기록: ~/Library/Logs/ReMON/actions.jsonl").font(.footnote).foregroundStyle(.secondary)
            }
            Section("시작") {
                Toggle("로그인할 때 실행(메뉴 막대 상주)", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.launchAtLogin = $0; model.applyLoginItem() }))
                Text("응용 프로그램 폴더에 설치된 앱에서만 적용됩니다. 외부로 아무것도 보내지 않습니다.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 600)
    }
}

// MARK: - 에이전트

/// 서명 표의 모든 에이전트와 직접 추가한 에이전트: 켜기·끄기 · 설치 경로 · 버전 · 실행 중 · 이어 열기 · 데이터 폴더.
struct AgentSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var inventory = AgentInventoryModel.shared
    @State private var name = ""
    @State private var processName = ""
    @State private var pathPattern = ""
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("프로세스 표와 각 에이전트의 기록만 읽습니다. 끄면 그 에이전트를 사무실에서 빼고 다른 프로세스로 셉니다.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(inventory.allKinds.enumerated()), id: \.element) { index, kind in
                        if index > 0 { Divider().padding(.leading, 58) }
                        AgentSettingsRow(model: model, kind: kind, install: inventory.install(for: kind), enabled: inventory.catalog.isEnabled(kind.rawValue),
                                         custom: inventory.catalog.custom.first { $0.id == kind.rawValue })
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            }
            customForm
            HStack(spacing: 8) {
                if inventory.scanning {
                    ProgressView().controlSize(.small)
                    Text("설치를 확인하는 중…").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if let at = inventory.scannedAt {
                    Text("설치 확인 \(Fmt.ago(at)) · 버전은 설치 경로 · package.json에서 읽고, 안 되면 `--version`을 네트워크 없이 한 번 실행합니다")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("다시 확인") { inventory.refresh(force: true) }.disabled(inventory.scanning)
            }
        }
        .padding(18)
        .frame(width: 700, height: 640)
        .onAppear { inventory.refresh() }
    }

    private var customForm: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("이름").font(.system(size: 12))
                        TextField("예: 사내 에이전트", text: $name).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("프로세스 이름").font(.system(size: 12))
                        TextField("예: acme-agent · 실행 파일 또는 node·python 스크립트 이름", text: $processName).textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        Text("경로 조각").font(.system(size: 12))
                        TextField("예: /opt/acme/ · 실행 경로나 스크립트 경로에 들어 있는 글자", text: $pathPattern).textFieldStyle(.roundedBorder)
                    }
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(message ?? "둘 다 넣으면 둘 다 맞아야 합니다. 직접 추가한 에이전트는 이어 열기 키가 없어 자동으로 정리하지 않습니다.")
                        .font(.system(size: 11)).foregroundStyle(message == nil ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("추가") { add() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(4)
        } label: {
            Text("직접 추가").font(.system(size: 12, weight: .semibold))
        }
    }

    private func add() {
        let agent = CustomAgent(name: name, processName: processName, pathPattern: pathPattern)
        if let error = AgentCatalog.shared.upsert(agent) {
            message = error
            return
        }
        name = ""; processName = ""; pathPattern = ""
        message = "\(agent.name)을(를) 추가했습니다. 다음 감지부터 사무실에 나옵니다."
        model.monitor.refreshNow()
    }
}

struct AgentSettingsRow: View {
    @ObservedObject var model: AppModel
    let kind: AgentKind
    let install: AgentInstall?
    let enabled: Bool
    let custom: CustomAgent?

    var body: some View {
        let running = model.runningCount(kind)
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: Binding(get: { enabled }, set: { on in
                AgentCatalog.shared.setEnabled(kind.rawValue, on)
                model.monitor.refreshNow()
            }))
            .toggleStyle(.switch).labelsHidden().controlSize(.small)
            .help(enabled ? "끄면 이 에이전트를 세션으로 세지 않습니다" : "켜면 다시 세션으로 셉니다")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(Color(nsColor: TeamColor.ns(kind))).frame(width: 8, height: 8)
                    Text(kind.name).font(.system(size: 13, weight: .semibold))
                    if let version = install?.version {
                        Text(version).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    if running > 0 { Text("실행 중 \(running)").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.green) }
                    if custom != nil { Text("직접 추가").font(.system(size: 10, weight: .semibold)).foregroundStyle(.purple) }
                    if install?.nameOnly == true { Text("같은 이름의 다른 도구일 수 있음").font(.system(size: 10)).foregroundStyle(.orange) }
                }
                Text(installLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(detailLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            if let custom {
                Button("삭제", role: .destructive) {
                    AgentCatalog.shared.removeCustom(id: custom.id)
                    model.monitor.refreshNow()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(enabled ? 1 : 0.6)
    }

    private var installLine: String {
        guard let path = install?.path else { return custom == nil ? "설치 안 됨(검색 폴더에서 찾지 못함)" : "실행 파일을 검색 폴더에서 찾지 못함" }
        let others = install?.otherPaths ?? []
        return "설치: " + AgentInventory.abbreviate(path) + (others.isEmpty ? "" : " · 외 \(others.count)곳")
    }

    private var detailLine: String {
        let resume = "이어 열기: " + (install?.resume ?? AgentSignatures.resume(for: kind)).label
        let data = install?.dataFolder.map { "데이터: \($0)" } ?? "데이터 폴더 없음"
        if let custom {
            let rule = [custom.processName.isEmpty ? nil : "프로세스 이름 \(custom.processName)", custom.pathPattern.isEmpty ? nil : "경로 조각 \(custom.pathPattern)"].compactMap { $0 }
            return rule.joined(separator: " · ") + " · " + resume
        }
        return resume + " · " + data
    }
}

// MARK: - 정보

/// 정보 탭 맨 위 아이콘 자리. 사용자별 픽셀 '엄지 척' 아이콘이 생기면 여기에 넣는다(지금은 앱 아이콘).
struct AboutIconSlot: View {
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 96, height: 96)
            .accessibilityLabel("ReMON 아이콘")
    }
}

struct AboutSettingsView: View {
    @State private var signing = "확인하는 중…"

    var body: some View {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        let log = AuditLog.shared.url
        VStack(spacing: 14) {
            AboutIconSlot()
            VStack(spacing: 3) {
                Text("ReMON").font(.system(size: 22, weight: .bold))
                Text("AI 사무실 · 메뉴 막대 시스템 모니터").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                AboutRow(label: "버전", value: version ?? "개발용 실행(번들 없음)")
                AboutRow(label: "빌드", value: build ?? "—")
                AboutRow(label: "위치", value: AgentInventory.abbreviate(Bundle.main.bundlePath))
                AboutRow(label: "서명", value: signing)
                GridRow {
                    Text("행동 기록").font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(AgentInventory.abbreviate(log.path)).font(.system(size: 12)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([log]) }
                        Button("열기") { NSWorkspace.shared.open(log) }
                    }
                    .controlSize(.small)
                    .disabled(!FileManager.default.fileExists(atPath: log.path))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            Text("외부 전송 없음 · 텔레메트리 없음 · 대화 원문은 저장하지 않습니다").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 560, height: 430, alignment: .top)
        .task {
            let path = Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath : (Bundle.main.executablePath ?? Bundle.main.bundlePath)
            let summary = await Task.detached(priority: .utility) { AboutSettingsView.signingSummary(path: path) }.value
            signing = summary
        }
    }

    /// 코드 서명 요약(Security 프레임워크, 프로세스 실행 없음 · 네트워크 없음). 공증 여부는 온라인 확인이 필요해 보지 않는다.
    nonisolated static func signingSummary(path: String) -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return "확인할 수 없음" }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return "서명 없음" }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        if flags & 0x0002 != 0 { return "ad-hoc 서명(개발용)" }   // kSecCodeSignatureAdhoc
        let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first,
           let subject = SecCertificateCopySubjectSummary(leaf) as String? {
            return subject + (team.map { " · 팀 \($0)" } ?? "")
        }
        return team.map { "서명됨 · 팀 \($0)" } ?? "서명됨"
    }
}

private struct AboutRow: View {
    let label: String
    let value: String
    var body: some View {
        GridRow {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12)).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
        }
    }
}
