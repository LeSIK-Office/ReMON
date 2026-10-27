import AppKit
import Charts
import ReMONCore
import SpriteKit
import SwiftUI

// MARK: - 창 전체

/// Aside처럼 창 가장자리에 붙은 반투명 사이드바(뒤 바탕화면이 비침) + 가운데 불투명 카드.
/// 창 배경은 OfficeWindowController가 NSVisualEffectView(behindWindow)로 깐다.
struct OfficeShellView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    let skView: SKView

    init(model: AppModel, skView: SKView) {
        self.model = model
        self.settings = model.settings
        self.skView = skView
    }

    var body: some View {
        // 투명한 창 위에 오피스 박스(불투명 카드)가 올라온 구조. 계기판·사건 기록은 박스 안 오른쪽에서 열고 닫는다.
        HStack(spacing: 0) {
            LeftSidebar(model: model).frame(width: 248)
            CenterCard(model: model, settings: settings, skView: skView)
                .padding(.vertical, 10)
                .padding(.trailing, 10)
        }
        .ignoresSafeArea()
        .frame(minWidth: 1100, minHeight: 680)
        .sheet(isPresented: $model.auditReportPresented) {
            if let report = model.lastAudit {
                VStack(alignment: .leading, spacing: 12) {
                    Text("감사 보고서").font(.title2.bold())
                    Text(report.time, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                    Text(report.summary).font(.headline)
                    Text("판정: " + (report.seconds > 0 ? "\(report.model) · \(Int(report.seconds))초" : "규칙") + (report.costUSD.map { String(format: " · $%.3f", $0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(report.details).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                    Text("판정과 사유입니다. 실제 실행 결과는 사건 기록에서 확인합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("닫기") { model.auditReportPresented = false } }
                }
                .padding(20)
                .frame(width: 560, height: 420)
            }
        }
    }
}

// MARK: - 팀(프로젝트 방) 묶음

struct OfficeTeam: Identifiable {
    var id: String { name }
    let name: String
    let sessions: [AgentSession]
    var working: Int { sessions.filter { $0.state == .working || $0.state == .waiting }.count }
    var resting: Int { sessions.count - working }
    var memory: UInt64 { sessions.reduce(0) { $0 + $1.footprint } }
    var color: Color { Color(nsColor: TeamColor.ns(sessions.first?.kind)) }
}

extension AppModel {
    /// 방(프로젝트)별 세션. 일하는 사람이 있는 방을 먼저, 방 안에서는 일하는 사람 → 기다림 → 쉼 순.
    var teams: [OfficeTeam] {
        let groups = Dictionary(grouping: office?.sessions ?? [], by: \.project)
        return groups.map { name, sessions in
            OfficeTeam(name: name, sessions: sessions.sorted { lhs, rhs in
                lhs.state.rank != rhs.state.rank ? lhs.state.rank < rhs.state.rank : lhs.startTime > rhs.startTime
            })
        }
        .sorted { lhs, rhs in
            (lhs.working > 0) != (rhs.working > 0) ? lhs.working > 0 : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func focusOn(_ focus: OfficeFocus) {
        page = .office
        scene?.focus(focus, animated: true)
    }

    func selectSession(_ session: AgentSession) {
        selectedApp = nil
        selectedMachine = nil
        selectedBoss = false
        selectedSubagent = nil
        selectedRecovery = nil
        selectedSession = session.id
        page = .office
        scene?.select(session.id)
        scene?.focusWorker(session.id)
    }

    func selectMachine(_ machine: MachineKind) {
        selectedSession = nil
        selectedApp = nil
        selectedBoss = false
        selectedSubagent = nil
        selectedRecovery = nil
        selectedMachine = machine
        scene?.select(nil)
    }

    var hasInspector: Bool { selected != nil || selectedAppGroup != nil || selectedMachine != nil || selectedBoss || selectedRecoveryEntry != nil || selectedSubagent != nil }

    func closeInspector() {
        selectedSession = nil
        selectedApp = nil
        selectedMachine = nil
        selectedBoss = false
        selectedSubagent = nil
        selectedRecovery = nil
        scene?.select(nil)
    }
}

extension SessionState {
    /// 목록 정렬 순서: 일하는 중 → 기다림 → 고아 → 쉼 → 오래 쉼.
    var rank: Int {
        switch self {
        case .working: 0
        case .waiting: 1
        case .orphan: 2
        case .idle: 3
        case .longIdle: 4
        }
    }

    var color: Color {
        switch self {
        case .working: .green
        case .waiting: .orange
        case .idle: Color(white: 0.6)
        case .longIdle: Color(white: 0.45)
        case .orphan: .red
        }
    }

    /// '기다림'은 사용자 입력을 기다리는 상태라 '입력 필요'로 보여 준다.
    var listLabel: String { self == .waiting ? "입력 필요" : label }
}

extension AgentKind {
    /// 이름표·목록용 짧은 이름(종류가 들고 다닌다 — 표에서 늘어난 에이전트도 분기 없이 나온다).
    var shortLabel: String { shortName }
}

/// 세션 목록용 픽셀 얼굴(사무실 직원과 같은 생김새).
@MainActor
final class AvatarCache {
    static let shared = AvatarCache()
    private var cache: [WorkerLook: NSImage] = [:]

    func head(for session: AgentSession) -> NSImage {
        let look = OfficeScene.look(for: session)
        if let image = cache[look] { return image }
        let canvas = CharacterArt.worker(look, .stand(blink: false))
        var image = canvas.nsImage()
        // 머리와 어깨(위쪽 16줄)만 잘라 쓴다.
        if let cg = canvas.cgImage(scale: 4), let crop = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: min(cg.height, 16 * 4))) {
            image = NSImage(cgImage: crop, size: NSSize(width: crop.width / 4, height: crop.height / 4))
        }
        if cache.count > 300 { cache.removeAll() }
        cache[look] = image
        return image
    }
}

struct AvatarView: View {
    let session: AgentSession
    var body: some View {
        ZStack {
            Circle().fill(Color(nsColor: TeamColor.ns(session.kind)).opacity(0.22))
            Image(nsImage: AvatarCache.shared.head(for: session)).interpolation(.none).resizable().scaledToFit().padding(3)
        }
        .clipShape(Circle())
    }
}

struct StateDot: View {
    let state: SessionState
    var body: some View {
        Circle().fill(state.color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(state.color.opacity(0.35), lineWidth: state == .waiting ? 3 : 0))
            .help(state.listLabel)
    }
}

// MARK: - 왼쪽 사이드바

struct LeftSidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 44)   // 창 신호등 자리
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI 사무실").font(.system(size: 15, weight: .bold))
                    Text("프로세스 \(model.office?.processCount ?? 0) · 세션 \(model.office?.sessions.count ?? 0)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            VStack(spacing: 2) {
                ForEach(OfficePage.allCases) { page in
                    NavRow(page: page, selected: model.page == page, badge: badge(page)) { model.page = page }
                }
            }
            .padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("지금 상태").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("일하는 중 \(model.office?.workingCount ?? 0) · 쉬는 중 \(model.office?.restingCount ?? 0)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                // 대표님 답을 기다리는 세션(없으면 숨김) — 가장 오래 = 지금 − 마지막 기록.
                if let waiting = ContextText.waitingLine(model.office?.sessions ?? []) {
                    Text(waiting).font(.system(size: 10, weight: .semibold)).foregroundStyle(.orange).lineLimit(2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 6)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.teams) { team in
                        TeamHeaderRow(team: team, focused: model.page == .office && model.focus == .room(team.name)) { model.focusOn(.room(team.name)) }
                        ForEach(team.sessions) { session in
                            AgentRow(session: session, selected: model.selectedSession == session.id) { model.selectSession(session) }
                        }
                    }
                    if model.office?.sessions.isEmpty ?? true {
                        Text("지금 일하는 에이전트가 없습니다.").font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            OptimizePanel(model: model)
            ProjectCleanupPanel(model: model)
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("실시간 · \(Date(), format: .dateTime.hour().minute())").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Button { (NSApp.delegate as? AppDelegate)?.showSettings() } label: {
                    Image(systemName: "gearshape").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("설정")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private func badge(_ page: OfficePage) -> String? {
        switch page {
        case .office: nil
        case .dashboard: model.office.map { "\($0.sessions.count)" }
        case .cleanup:
            model.suggestions.isEmpty ? nil : Fmt.gb(model.suggestions.reduce(0) { $0 + $1.reclaimBytes })
        case .diskMap:
            model.diskMap.lastScan == nil ? nil : Fmt.gb(model.diskComposition.reduce(0) { $0 + $1.reclaimable })
        }
    }
}

struct NavRow: View {
    let page: OfficePage
    let selected: Bool
    let badge: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: page.icon).font(.system(size: 13, weight: .semibold)).frame(width: 20)
                Text(page.rawValue).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if let badge {
                    Text(badge).font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.10)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())   // 줄 전체가 눌리게(0.1.1의 '잘 안 눌림' 원인 제거)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.primary.opacity(0.13) : hover ? Color.primary.opacity(0.06) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(page.rawValue)
    }
}

struct TeamHeaderRow: View {
    let team: OfficeTeam
    let focused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(team.color).frame(width: 3, height: 12)
                Text(team.name).font(.system(size: 11, weight: .bold)).lineLimit(1)
                Spacer()
                Text("\(team.sessions.count)").font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                Image(systemName: "scope").font(.system(size: 9)).foregroundStyle(focused ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(team.name) 방으로 다가가기")
    }
}

struct AgentRow: View {
    let session: AgentSession
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AvatarView(session: session).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(session.kind.shortLabel).font(.system(size: 12, weight: .semibold))
                        Text(OfficeScene.shortAge(Date().timeIntervalSince(session.startTime))).font(.system(size: 10)).foregroundStyle(.tertiary)
                        if session.state == .waiting {
                            Text("입력 필요").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                        }
                        if session.tabLeftover {
                            Text("탭 닫힘").font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.purple.opacity(0.22)))
                                .foregroundStyle(.purple)
                        }
                        if session.activeSubagents > 0 {
                            Text("하위 \(session.activeSubagents)").font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.2)))
                                .foregroundStyle(.green)
                        }
                    }
                    Text(session.displayTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                StateDot(state: session.state)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.22) : hover ? Color.primary.opacity(0.05) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel("\(session.kind.shortLabel) \(session.project) \(session.displayTitle)")
    }
}

// MARK: - 가운데 카드

struct CenterCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    let skView: SKView

    var body: some View {
        HStack(spacing: 0) {
            Group {
                switch model.page {
                case .office: OfficePageView(model: model, settings: model.settings, skView: skView)
                case .dashboard: DashboardPageView(model: model)
                case .cleanup: CleanupPageView(model: model)
                case .diskMap: DiskMapPage(store: model.diskMap)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if settings.showRightSidebar {
                Divider()
                RightSidebar(model: model)
                    .frame(width: 292)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: settings.showRightSidebar)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 20, weight: .bold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct OfficePageView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    let skView: SKView

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "오피스", subtitle: "에이전트(사람)는 프로젝트 방에서, 도구(앱)는 도구실에서, CPU·RAM·디스크는 기계실에서 일합니다") {
                HStack(spacing: 8) {
                    AuditButton(model: model, idleTitle: "감사")
                        .help("감사관·비서가 들어와 건물을 둘러보며 세션을 판정하고(애매한 것만 로그인된 Claude에 물음), 승인하면 정리·재교육합니다. 판정 중에 누르면 취소")
                    if model.lastAudit != nil {
                        Button { model.auditReportPresented = true } label: { Label("보고서", systemImage: "doc.text") }
                            .help("마지막 감사 보고서 다시 보기")
                    }
                    Toggle(isOn: $settings.autoZoom) { Label("자동 줌", systemImage: "scope") }
                        .toggleStyle(.button)
                        .help("출근·퇴출·트레이너·청소·과열이 생기면 그 자리로 다가갔다가 돌아옵니다")
                    ControlGroup {
                        Button { model.scene?.zoomStep(-1) } label: { Image(systemName: "minus.magnifyingglass") }.help("축소")
                        Button { model.focusOn(.all) } label: { Text("전체") }.help("건물 전체 보기(Esc)")
                        Button { model.scene?.zoomStep(1) } label: { Image(systemName: "plus.magnifyingglass") }.help("확대")
                    }
                    .frame(width: 140)
                    Button { settings.showRightSidebar.toggle() } label: { Image(systemName: "sidebar.right") }
                        .help(settings.showRightSidebar ? "계기판·사건 기록 숨기기" : "계기판·사건 기록 보이기")
                }
                .controlSize(.regular)
            }
            RoomChips(model: model)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            HStack(spacing: 0) {
                FloorIndicator(model: model).frame(width: 176)
                ZStack {
                SpriteHost(view: skView)
                VStack {
                    if let caption = model.caption {
                        CaptionPill(text: caption).padding(.top, 12).transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                    HStack {
                        Text("스크롤·핀치로 확대 · 끌어서 이동 · 방을 누르면 다가가기 · Esc 전체")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.35)))
                        Spacer()
                    }
                    .padding(12)
                }
                .allowsHitTesting(false)
                HStack {
                    Spacer()
                    if model.hasInspector {
                        InspectorPanel(model: model)
                            .frame(width: 330)
                            .padding(12)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
                .animation(.easeOut(duration: 0.2), value: model.caption)
                .animation(.easeOut(duration: 0.2), value: model.hasInspector)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.trailing, 10)
                .padding(.bottom, 10)
            }
        }
        .onAppear { skView.isPaused = false }
        .onDisappear { skView.isPaused = true }
    }
}

/// 왼쪽 층 안내판(플로우 인디케이터): 위층부터 한 줄씩, 카메라가 보는 층을 표시하고 누르면 그 층으로 간다.
/// 사건(출근·퇴출·트레이너·청소)이 층을 옮겨 다닐 때 표시도 따라 움직인다.
struct FloorIndicator: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("층 안내").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 12).padding(.bottom, 6)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.floors) { floor in
                        FloorRow(floor: floor, current: model.viewportFloor == floor.id, focused: model.focus == floor.focus) {
                            model.focusOn(floor.focus)
                        }
                    }
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
            }
            Spacer(minLength: 0)
            if let caption = model.caption {
                HStack(spacing: 5) {
                    Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(.red)
                    Text(caption).font(.system(size: 10)).lineLimit(2)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
        }
        .padding(.top, 4)
    }
}

struct FloorRow: View {
    let floor: FloorSummary
    let current: Bool
    let focused: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                // 왼쪽 세로 레일 + 현재 층 표시
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 2)
                    Circle().fill(current ? Color.accentColor : Color.primary.opacity(0.25)).frame(width: current ? 9 : 6, height: current ? 9 : 6)
                        .overlay(Circle().stroke(Color.accentColor.opacity(current ? 0.35 : 0), lineWidth: 4))
                }
                .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Image(systemName: icon).font(.system(size: 9, weight: .semibold)).foregroundStyle(floor.warn ? Color.red : Color.secondary)
                        Text(floor.title).font(.system(size: 11.5, weight: current ? .bold : .medium)).lineLimit(1)
                        if floor.waiting > 0 { Circle().fill(Color.orange).frame(width: 5, height: 5) }
                    }
                    Text(floor.subtitle).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.trailing, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(focused ? Color.accentColor.opacity(0.16) : hover ? Color.primary.opacity(0.05) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("\(floor.title) 층으로 가기")
        .accessibilityLabel("층 \(floor.title)")
    }

    private var icon: String {
        switch floor.kind {
        case .roof: "sun.max"
        case .team: "person.2"
        case .hall: "chair"
        case .lobby: "door.left.hand.open"
        case .machines: "gearshape.2"
        }
    }
}

struct RoomChips: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(title: "전체", icon: "building.2", selected: model.focus == .all) { model.focusOn(.all) }
                // 상황실(대표)은 늘 앞에 둔다 — 나를 기다리는 세션 수를 함께.
                Chip(title: "상황실", icon: OfficeRegion.situationRoom.icon, count: model.office.map { $0.sessions.filter { $0.state == .waiting }.count }, color: .orange,
                     selected: model.focus == .region(.situationRoom)) { model.focusOn(.region(.situationRoom)) }
                ForEach(model.teams) { team in
                    Chip(title: team.name, count: team.sessions.count, color: team.color, selected: model.focus == .room(team.name)) { model.focusOn(.room(team.name)) }
                }
                Divider().frame(height: 16).padding(.horizontal, 2)
                ForEach(OfficeRegion.allCases.filter { $0 != .situationRoom }, id: \.self) { region in
                    Chip(title: region.label, icon: region.icon, selected: model.focus == .region(region)) { model.focusOn(.region(region)) }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

extension OfficeRegion {
    var icon: String {
        switch self {
        case .situationRoom: "person.crop.circle.badge.exclamationmark"
        case .lobby: "door.left.hand.open"
        case .toolRoom: "wrench.and.screwdriver"
        case .machineRoom: "gearshape.2"
        case .hall: "chair"
        case .rooftop: "sun.max"
        }
    }
}

struct Chip: View {
    let title: String
    var icon: String? = nil
    var count: Int? = nil
    var color: Color? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: selected ? .semibold : .medium)).lineLimit(1)
                if let count { Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit()).opacity(0.7) }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color(nsColor: .windowBackgroundColor) : Color.primary)
            .background(Capsule().fill(selected ? Color.primary : hover ? Color.primary.opacity(0.10) : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(count.map { "\(title) \($0)" } ?? title)
    }
}

struct CaptionPill: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 7, height: 7)
            Text(text).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThickMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }
}

/// 선택한 사람(세션) · 도구(앱) · 기계 상세. 가운데 카드 오른쪽에 붙는다(ANOGRO의 기록 패널 자리).
struct InspectorPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.closeInspector() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 15)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("닫기")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if model.selectedBoss {
                        BossCard(model: model)
                    } else if let picked = model.selectedSubagent {
                        SubagentCard(session: picked.session, subagent: picked.info)
                    } else if let entry = model.selectedRecoveryEntry {
                        RecoveryCard(model: model, entry: entry)
                    } else if let session = model.selected {
                        DetailCard(model: model, session: session)
                    } else if let app = model.selectedAppGroup {
                        AppDetailCard(model: model, app: app)
                    } else if let machine = model.selectedMachine {
                        MachineDetailCard(model: model, machine: machine)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var title: String {
        if model.selectedBoss { return "상황실 · 대표" }
        if model.selectedRecoveryEntry != nil { return "정신교육실 · 복구함" }
        if model.selected != nil { return "에이전트(사람)" }
        if model.selectedAppGroup != nil { return "도구(앱)" }
        return "기계"
    }
}

// MARK: - 오른쪽 사이드바: 계기판(고정) + 사건 기록(따로 스크롤)

struct RightSidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button { model.settings.showRightSidebar = false } label: { Image(systemName: "sidebar.right").font(.system(size: 12)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("계기판·사건 기록 닫기")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            GaugePanel(model: model)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            Divider()
            LogPanel(model: model)
        }
    }
}

struct LogPanel: View {
    @ObservedObject var model: AppModel
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "전체", people = "출근·퇴근", alerts = "경보", cleanup = "정리"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("사건 기록").font(.system(size: 13, weight: .bold))
                Text("\(entries.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if entries.isEmpty {
                        Text("출근·퇴근·정리·경보가 여기에 쌓입니다.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle().fill(entry.tone.color).frame(width: 6, height: 6)
                            Text(entry.time, format: .dateTime.hour().minute()).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                            Text(entry.text).font(.system(size: 11.5)).lineLimit(3).textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    private var entries: [EventLogEntry] {
        model.log.filter { entry in
            switch filter {
            case .all: true
            case .people: entry.tone == .arrive || entry.tone == .leave || entry.tone == .evict
            case .alerts: entry.tone == .alert || entry.tone == .trainer
            case .cleanup: entry.tone == .cleanup
            }
        }
    }
}

extension EventLogEntry.Tone {
    var color: Color {
        switch self {
        case .arrive: .teal
        case .leave: .blue
        case .evict: .red
        case .trainer: .pink
        case .alert: .orange
        case .cleanup: .green
        case .info: .gray
        }
    }
}


/// 상황실 사장 카드: 대표가 지금 해야 할 일(나를 기다리는 세션)과 한 번에 하는 관리.
struct BossCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let sessions = model.office?.sessions ?? []
        let waiting = sessions.filter { $0.state == .waiting }
        let system = model.system
        let targets = model.memoryCleanupTargets()
        VStack(alignment: .leading, spacing: 10) {
            Text("대표 할 일").font(.system(size: 15, weight: .bold))
            if waiting.isEmpty {
                Text("지금 대표님 답을 기다리는 세션은 없습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("내 답을 기다리는 세션 \(waiting.count)개").font(.system(size: 12, weight: .semibold)).foregroundStyle(.orange)
                ForEach(waiting) { session in
                    HStack(spacing: 8) {
                        AvatarView(session: session).frame(width: 22, height: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(session.project) · \(session.kind.shortLabel)").font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            Text(session.displayTitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button("가기") { model.revealTerminal(session) }
                            .controlSize(.small)
                            .disabled(session.terminalHost == nil && session.orcaHandle == nil)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if system.pressure != .normal { Label("메모리 압박 \(system.pressure.label) · 사용 \(Fmt.gb(system.memory.used))", systemImage: "exclamationmark.triangle.fill").foregroundStyle(system.pressure == .critical ? .red : .orange) }
                if system.disk.available < UInt64(model.settings.diskThresholdGB * Fmt.gib) { Label("디스크 여유 \(Fmt.gb(system.disk.available))", systemImage: "internaldrive.fill").foregroundStyle(.red) }
                if system.swap.used > UInt64(10 * Fmt.gib) { Label("스왑 \(Fmt.gb(system.swap.used))", systemImage: "shippingbox.fill").foregroundStyle(.orange) }
                if system.thermal.available && system.thermal.cpuTemperature >= 90 { Label("CPU \(Int(system.thermal.cpuTemperature))°C · 팬 \(Int(system.thermal.fanRPM))rpm", systemImage: "flame.fill").foregroundStyle(.red) }
            }
            .font(.system(size: 11))
            Text("한 번에 관리").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                AuditButton(model: model, idleTitle: "감사 시작(\(model.settings.auditModel.capitalized) 판정)", fill: true)
                    .buttonStyle(.borderedProminent)
                Button { model.cleanMemory(auto: false) } label: { Label("메모리 정리 · 오래 쉰·고아 \(targets.count)개 · \(Fmt.gb(targets.reduce(0) { $0 + $1.footprint }))", systemImage: "figure.strengthtraining.traditional").frame(maxWidth: .infinity) }
                    .disabled(targets.isEmpty)
                Button { model.cleanLeftovers() } label: { Label("부산물 청소 · \(model.leftoverCleanableTotal)개", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    .disabled(model.leftoverCleanableTotal == 0)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Toggle("메모리 경고 때 정리 가능한 세션 알림(자동으로 끄지 않음)", isOn: Binding(get: { model.settings.autoMemoryCleanup }, set: { model.settings.autoMemoryCleanup = $0 }))
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 10.5))
            if let message = model.lastActionMessage { Text(message).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// 감사 버튼: 평소 '감사' · 판정 대기 중 '판정 중 45초 · 취소'(누르면 취소) · 조치 중 '감사 중…'(누를 수 없음).
struct AuditButton: View {
    @ObservedObject var model: AppModel
    let idleTitle: String
    var fill = false

    var body: some View {
        // 판정을 기다릴 때만 1초마다 다시 그린다(평소엔 거의 쉬게 — 상주 앱 부하).
        TimelineView(.periodic(from: .now, by: model.auditJudging != nil ? 1 : 600)) { context in
            Button {
                if model.auditJudging != nil { model.cancelAudit() } else { model.runAudit() }
            } label: {
                Label(title(now: context.date), systemImage: model.auditJudging != nil ? "xmark.circle" : "checkmark.shield")
                    .frame(maxWidth: fill ? .infinity : nil)
            }
            .disabled(model.auditRunning && model.auditJudging == nil)
        }
    }

    private func title(now: Date) -> String {
        if let judging = model.auditJudging {
            let seconds = max(0, Int(now.timeIntervalSince(judging.started)))
            return (judging.asked == 0 ? "둘러보는 중 " : "판정 중 ") + (seconds >= 60 ? "\(seconds / 60)분 \(seconds % 60)초" : "\(seconds)초") + " · 취소"
        }
        return model.auditRunning ? "감사 중…" : idleTitle
    }
}
