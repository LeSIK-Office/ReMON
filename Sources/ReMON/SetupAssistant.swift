import AppKit
import Darwin
import ReMONCore
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - 설정 도우미(권한 점검)
// 첫 실행 때 한 번 시트로 띄우고, 설정 '권한' 탭에서 언제든 다시 본다.
// 설치하는 것이 없다: 권한 도우미(privileged helper)를 깔지 않고, 에이전트 설정 파일(~/.claude/settings.json · ~/.codex/config.toml)에 훅을 넣지 않는다.

enum SetupAssistant {
    private static let shownKey = "setupAssistant.shown"

    static var hasShown: Bool { UserDefaults.standard.bool(forKey: shownKey) }
    static func markShown() { UserDefaults.standard.set(true, forKey: shownKey) }

    /// 첫 실행에 한 번. 검수 모드(성능·데모·스냅샷)는 건너뛰고, `--setup-assistant`면 언제든 띄운다.
    @MainActor static var shouldShowOnLaunch: Bool {
        if CommandLine.arguments.contains("--setup-assistant") { return true }
        if PerfDirector.isActive || DemoDirector.isActive || SnapshotTool.folder() != nil || CommandLine.arguments.contains("--capture-ui") { return false }
        return !hasShown
    }

    static let fullDiskSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static var notificationSettings: URL? {
        guard let bundle = Bundle.main.bundleIdentifier else { return nil }
        return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundle)")
    }

    /// 앱 번들로 실행 중인가(번들 없는 개발용 실행은 알림·로그인 실행을 쓸 수 없다).
    static var isBundledApp: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }
    static var isInApplications: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }

    /// 전체 디스크 접근: 보호된 파일을 열어만 보고 바로 닫는다(내용은 읽지 않는다). 열리면 허용, 권한 오류면 꺼짐.
    /// 파일이 없으면 Safari 폴더 목록으로 한 번 더 본다. 둘 다 판단이 안 되면 nil.
    static func probeFullDiskAccess(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool? {
        let protected = home + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = open(protected, O_RDONLY)
        if descriptor >= 0 { close(descriptor); return true }
        if errno == EPERM || errno == EACCES { return false }
        let safari = home + "/Library/Safari"
        guard FileManager.default.fileExists(atPath: safari) else { return nil }
        return (try? FileManager.default.contentsOfDirectory(atPath: safari)) != nil
    }
}

/// 점검 결과(앱이 다시 앞으로 오면 새로 잰다 — 시스템 설정에서 권한을 바꾸고 돌아온 경우).
@MainActor
final class SetupChecks: ObservableObject {
    @Published var fullDisk: Bool?
    /// nil = 번들 없는 개발용 실행이라 알림 센터를 쓸 수 없음
    @Published var notifications: UNAuthorizationStatus?
    @Published var loginItem: SMAppService.Status = .notRegistered
    @Published var orcaPath: String?
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        fullDisk = SetupAssistant.probeFullDiskAccess()
        loginItem = SMAppService.mainApp.status
        orcaPath = OrcaBridge.executable
        Alerts.authorizationStatus { [weak self] status in
            MainActor.assumeIsolated { self?.notifications = status }
        }
    }
}

/// 점검 화면. 시트(첫 실행)와 설정 탭이 같은 내용을 쓴다.
struct SetupAssistantView: View {
    enum Mode { case sheet, tab }

    @ObservedObject var model: AppModel
    let mode: Mode
    var onClose: () -> Void = {}
    @StateObject private var checks = SetupChecks()
    @ObservedObject private var inventory = AgentInventoryModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if mode == .sheet {
                HStack(alignment: .center, spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ReMON 시작 점검").font(.system(size: 18, weight: .bold))
                        Text("프로세스 표와 에이전트 기록 파일만 읽습니다. 아래 항목은 있으면 더 정확해지고, 없어도 기본 기능은 동작합니다.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("있으면 더 정확해지는 권한과 연동을 점검합니다. 시스템 설정에서 바꾸고 돌아오면 다시 잽니다.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                fullDiskRow
                Divider().padding(.leading, 44)
                notificationRow
                Divider().padding(.leading, 44)
                loginRow
                Divider().padding(.leading, 44)
                if checks.orcaPath != nil { orcaRow }   // Orca가 없는 Mac에는 Orca 줄을 보이지 않는다
                Divider().padding(.leading, 44)
                agentsRow
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            Text("설치하는 것이 없습니다. 권한 도우미를 깔지 않고, 에이전트 설정 파일(~/.claude/settings.json · ~/.codex/config.toml)에 훅을 넣지 않습니다." + (OrcaBridge.executable != nil ? " 선택 연동은 Orca CLI 하나입니다." : "")
                 + (mode == .sheet ? " 이 점검은 설정의 '권한' 탭에서 다시 볼 수 있습니다." : ""))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("다시 확인") { checks.refresh(); inventory.refresh(force: true) }
                if mode == .sheet {
                    Button("시작하기") { onClose() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: mode == .sheet ? 600 : 620, alignment: .topLeading)
        .onAppear { inventory.refresh() }
    }

    // MARK: 항목

    private var fullDiskRow: some View {
        let granted = checks.fullDisk
        let note = Bundle.main.bundleIdentifier == nil ? " 터미널에서 실행하면 그 터미널 앱의 권한으로 판정합니다." : ""
        return SetupCheckRow(symbol: "internaldrive", title: "전체 디스크 접근",
                             badge: granted == true ? .good("허용됨") : granted == false ? .warn("꺼져 있음") : .neutral("확인할 수 없음"),
                             detail: "휴지통 크기와 다른 앱 폴더의 용량을 재는 데 씁니다. 없어도 세션 감지와 정리는 그대로 동작합니다." + note) {
            if granted != true {
                Button("시스템 설정 열기") { NSWorkspace.shared.open(SetupAssistant.fullDiskSettings) }
            }
        }
    }

    private var notificationRow: some View {
        let badge: SetupBadge
        switch checks.notifications {
        case .some(.authorized), .some(.provisional), .some(.ephemeral): badge = .good("허용됨")
        case .some(.denied): badge = .warn("꺼져 있음")
        case .some(.notDetermined): badge = .neutral("아직 묻지 않음")
        case .some: badge = .neutral("확인할 수 없음")
        case .none: badge = .neutral("앱으로 설치하면 확인합니다")
        }
        return SetupCheckRow(symbol: "bell.badge", title: "알림", badge: badge,
                             detail: "디스크 여유 부족 · 스왑 급증 · 메모리 압박 위험을 알립니다. 꺼 두어도 메뉴 막대와 사건 기록에는 남습니다.") {
            AnyView(Group {
                if checks.notifications == .notDetermined {
                    Button("알림 허용 요청") { Alerts.requestAuthorization { _ in MainActor.assumeIsolated { checks.refresh() } } }
                } else if checks.notifications == .denied, let url = SetupAssistant.notificationSettings {
                    Button("시스템 설정 열기") { NSWorkspace.shared.open(url) }
                }
            })
        }
    }

    private var loginRow: some View {
        let badge: SetupBadge
        switch checks.loginItem {
        case .enabled: badge = .good("켜짐")
        case .requiresApproval: badge = .warn("승인 필요")
        case .notRegistered: badge = .neutral("꺼짐")
        case .notFound: badge = .neutral("등록할 수 없음")
        @unknown default: badge = .neutral("확인할 수 없음")
        }
        let outside = !SetupAssistant.isInApplications
        return SetupCheckRow(symbol: "power", title: "로그인할 때 실행", badge: badge,
                             detail: "로그인하면 메뉴 막대에 바로 뜹니다. 응용 프로그램 폴더에 설치한 앱에서만 등록합니다." + (outside ? " 지금은 응용 프로그램 폴더 밖에서 실행 중입니다." : "")) {
            AnyView(Group {
                if checks.loginItem == .requiresApproval {
                    Button("시스템 설정 열기") { SMAppService.openSystemSettingsLoginItems() }
                } else if checks.loginItem != .enabled {
                    Button("등록") {
                        model.settings.launchAtLogin = true
                        model.applyLoginItem()
                        checks.refresh()
                    }
                    .disabled(outside)
                }
            })
        }
    }

    private var orcaRow: some View {
        SetupCheckRow(symbol: "rectangle.split.3x1", title: "Orca CLI · 선택",
                      badge: checks.orcaPath != nil ? .good("찾음") : .neutral("없음"),
                      detail: "있으면 Orca 탭 제목을 작업 제목으로 쓰고, 탭을 닫은 뒤 남은 세션을 찾고, '터미널로 이동'이 그 탭을 엽니다. 없어도 제목은 기록에서 읽고 나머지 기능은 그대로입니다."
                        + (checks.orcaPath.map { " 위치: \(AgentInventory.abbreviate($0))" } ?? "")) {
            EmptyView()
        }
    }

    private var agentsRow: some View {
        let found = inventory.installs.filter(\.installed)
        let names = found.map { $0.kind.name + ($0.version.map { " \($0)" } ?? "") }
        return SetupCheckRow(symbol: "person.2", title: "에이전트 CLI",
                             badge: inventory.installs.isEmpty ? .neutral("찾는 중") : found.isEmpty ? .warn("찾지 못함") : .good("\(found.count)개 찾음"),
                             detail: (names.isEmpty ? "검색 폴더(Homebrew · ~/.local/bin · npm 전역 · nvm 등)에서 에이전트 CLI를 찾지 못했습니다." : names.joined(separator: " · "))
                                + "\n'에이전트' 탭에서 켜고 끄거나 직접 추가할 수 있습니다.") {
            Button("에이전트 설정") { model.openSettings(.agents) }
        }
    }
}

/// 점검 상태 배지: 좋음(초록) · 손볼 것(주황) · 중립(회색).
enum SetupBadge {
    case good(String), warn(String), neutral(String)
    var text: String { switch self { case .good(let t), .warn(let t), .neutral(let t): t } }
    var color: Color { switch self { case .good: .green; case .warn: .orange; case .neutral: .secondary } }
}

/// 점검 한 줄: 아이콘 · 제목 · 상태 배지 · 설명 · 오른쪽 버튼.
struct SetupCheckRow<Action: View>: View {
    let symbol: String
    let title: String
    let badge: SetupBadge
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(badge.color)
                .frame(width: 22, height: 22).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(badge.text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(badge.color)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(Capsule().fill(badge.color.opacity(0.14)))
                }
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action.controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
