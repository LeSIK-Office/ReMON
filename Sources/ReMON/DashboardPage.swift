import AppKit
import ReMONCore
import SwiftUI

// MARK: - 대시보드(카드) — 사무실이 그래픽이라면, 여기는 같은 정보를 카드로 쭉 펼쳐 바로 관리한다.

struct DashboardPageView: View {
    @ObservedObject var model: AppModel
    @State private var mode = 0   // 0 카드 · 1 표

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "대시보드", subtitle: "기계 · 에이전트 팀 · 도구 · 정리 제안 — 누르면 바로 관리합니다") {
                Picker("", selection: $mode) { Text("카드").tag(0); Text("표").tag(1) }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
            }
            if mode == 1 {
                TablePanel(model: model)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
            } else {
                GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 22) {
                        WaitingBanner(model: model)
                        DashboardSection(title: "건강 점수", subtitle: "100점에서 요인별로 깎습니다 · 깎인 이유마다 바로 할 수 있는 조치") {
                            HealthCard(model: model)
                        }
                        DashboardSection(title: "세션 자원", subtitle: "대화가 길면 세션 메모리도 커지기 쉽습니다 · 컨텍스트가 70% 이상이면 인계를 권합니다") {
                            ContextLeadersCard(model: model, availableWidth: geometry.size.width - 36)
                        }
                        DashboardSection(title: "기계", subtitle: "CPU·RAM·디스크·스왑은 사람이 아니라 장치입니다") {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: min(4, max(1, Int((geometry.size.width - 24) / 242)))), alignment: .leading, spacing: 12) {
                                MachineCard(model: model, machine: .cpu)
                                MachineCard(model: model, machine: .ram)
                                MachineCard(model: model, machine: .disk)
                                MachineCard(model: model, machine: .swap)
                            }
                        }
                        DashboardSection(title: "에이전트 팀", subtitle: "프로젝트 = 방 · 세션마다 사람 한 명") {
                            if model.teams.isEmpty {
                                Text("지금 일하는 에이전트가 없습니다.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 12, alignment: .top)], spacing: 12) {
                                ForEach(model.teams) { team in TeamCard(model: model, team: team) }
                            }
                        }
                        DashboardSection(title: "이 Mac에서 찾은 에이전트", subtitle: "설치 · 실행 중 · 이어 열기 · 데이터 폴더 — 설치 확인은 10분에 한 번") {
                            AgentInventoryCard(model: model)
                        }
                        DashboardSection(title: "도구(앱)", subtitle: "에이전트가 쓰는 도구 — 사람으로 세지 않습니다") {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                                ForEach(tools) { app in ToolCard(model: model, app: app) }
                            }
                        }
                        DashboardSection(title: "정리 제안", subtitle: "누르면 확인 후 바로 실행합니다") {
                            if model.suggestions.isEmpty {
                                Text(model.diskScanning ? "디스크를 살펴보는 중…" : "지금은 정리할 것이 거의 없습니다.").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            VStack(spacing: 8) {
                                ForEach(model.suggestions) { suggestion in SuggestionRow(model: model, suggestion: suggestion) }
                            }
                        }
                    }
                    .padding(18)
                }
                }
            }
        }
        .overlay(alignment: .trailing) {
            if model.hasInspector {
                InspectorPanel(model: model)
                    .frame(width: 330)
                    .padding(12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.hasInspector)
    }

    private var tools: [AppGroup] {
        (model.office?.apps ?? []).filter { $0.category != .system }.sorted { $0.footprint > $1.footprint }.prefix(12).map { $0 }
    }
}

struct DashboardSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 15, weight: .bold))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            content
        }
    }
}

/// 카드 틀(불투명 카드 위 옅은 판).
struct CardBox<Content: View>: View {
    var accent: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder((accent ?? Color.primary).opacity(accent == nil ? 0.08 : 0.5), lineWidth: accent == nil ? 0.5 : 1))
    }
}

struct MachineCard: View {
    @ObservedObject var model: AppModel
    let machine: MachineKind

    var body: some View {
        let system = model.system
        CardBox {
            switch machine {
            case .cpu:
                CPUEngineGauge(cpu: system.cpuPercent, cores: system.coreLoads)
                let busy = (model.office?.processes ?? []).sorted { $0.cpuPercent > $1.cpuPercent }.prefix(3)
                ForEach(Array(busy), id: \.key) { record in
                    OwnerRow(model: model, name: record.displayName, value: String(format: "%.1f%%", record.cpuPercent), pid: record.pid)
                }
            case .ram:
                RAMTankGauge(memory: system.memory, pressure: system.pressure)
                let resting = (model.office?.sessions ?? []).filter { $0.state.isResting || $0.state == .orphan }
                Button { model.releaseMany(resting, title: "쉬는 세션 모두 정리") } label: {
                    Label("쉬는 세션 \(resting.count)개 정리 · 약 \(Fmt.gb(resting.reduce(0) { $0 + $1.footprint }))", systemImage: "figure.strengthtraining.traditional")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(resting.isEmpty)
            case .disk:
                DiskSiloGauge(disk: system.disk, thresholdGB: model.settings.diskThresholdGB)
                DiskCompositionView(rows: model.diskComposition, compact: true) { tag in
                    model.diskMap.path = []; model.diskMap.filter = [tag]; model.page = .diskMap
                }
                Button { model.page = .cleanup } label: { Label("정리 화면 열기", systemImage: "sparkles").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
            case .swap:
                SwapCrateGauge(swap: system.swap)
                Text("RAM 탱크가 넘쳐 디스크로 내려 둔 상자입니다. 메모리를 많이 쥔 세션·앱을 닫으면 줄어듭니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .system:
                EmptyView()
            }
            Button("자세히") { model.selectMachine(machine) }.buttonStyle(.link).font(.system(size: 11))
        }
    }
}

struct TeamCard: View {
    @ObservedObject var model: AppModel
    let team: OfficeTeam

    var body: some View {
        let resting = team.sessions.filter { $0.state.isResting || $0.state == .orphan }
        CardBox(accent: team.color) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(team.color).frame(width: 4, height: 18)
                Text(team.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                Spacer()
                Text("일하는 중 \(team.working) · 쉬는 중 \(team.resting) · \(Fmt.gb(team.memory))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                ForEach(team.sessions.prefix(6)) { session in
                    SessionLine(model: model, session: session)
                }
                if team.sessions.count > 6 {
                    Text("… 외 \(team.sessions.count - 6)명").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 8) {
                Button { model.focusOn(.room(team.name)) } label: { Label("사무실에서 보기", systemImage: "scope") }
                Button { model.releaseMany(resting, title: "\(team.name) 쉬는 세션 정리") } label: { Label("쉬는 세션 정리 \(resting.count)", systemImage: "figure.strengthtraining.traditional") }
                    .disabled(resting.isEmpty)
                Spacer()
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }
}

/// 세션 한 줄: 누르면 사무실에서 그 사람을 고르고, 오른쪽 버튼으로 바로 정리한다.
struct SessionLine: View {
    @ObservedObject var model: AppModel
    let session: AgentSession
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            AvatarView(session: session).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(session.displayTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(session.kind.shortLabel) · \(OfficeScene.shortAge(Date().timeIntervalSince(session.startTime))) · 마지막 기록 \(Fmt.ago(session.lastActivity))"
                     + (ContextText.compact(session).map { " · " + $0 } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(session.state.listLabel).font(.system(size: 10, weight: .semibold)).foregroundStyle(session.state.color)
            Text(Fmt.size(session.footprint)).font(.system(size: 11, weight: .semibold).monospacedDigit()).frame(width: 58, alignment: .trailing)
            Menu {
                Button("사무실에서 보기") { model.selectSession(session) }
                Button("터미널로 이동") { model.revealTerminal(session) }.disabled(session.terminalHost == nil && session.orcaHandle == nil)
                Button("이어 열기 명령 복사") { model.copyResume(session) }.disabled(session.resumeCommand == nil)
                if let cwd = session.cwd { Button("작업 폴더 열기") { model.revealInFinder(cwd) } }
                Divider()
                Button(model.isPinned(session) ? "보호 해제" : "보호 고정") { model.togglePin(session) }
                Button("정리하기(퇴근)") { model.release(session) }
                Button("강제 종료", role: .destructive) { model.evict(session) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { model.selectSession(session) }
    }
}

struct ToolCard: View {
    @ObservedObject var model: AppModel
    let app: AppGroup

    var body: some View {
        let blockers = model.appBlockers(app)
        CardBox {
            HStack(spacing: 10) {
                if let icon = model.icon(for: app) {
                    Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 22)).frame(width: 30, height: 30).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("프로세스 \(app.pids.count) · CPU \(Fmt.percent(app.cpuPercent))").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(Fmt.gb(app.footprint)).font(.system(size: 14, weight: .bold).monospacedDigit())
            }
            if !blockers.isEmpty {
                Text("보호 대상 · " + blockers.joined(separator: ", ")).font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(2)
            }
            HStack(spacing: 8) {
                Button("보기") { model.activate(app) }
                Button("종료") { model.quitApp(app) }.disabled(!blockers.isEmpty)
                Button("강제 종료", role: .destructive) { model.forceQuitApp(app) }.disabled(!blockers.isEmpty)
                Spacer()
                Button("자세히") { model.selectedSession = nil; model.selectedMachine = nil; model.selectedApp = app.id }.buttonStyle(.link)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }
}

struct SuggestionRow: View {
    @ObservedObject var model: AppModel
    let suggestion: CleanupSuggestion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Color.accentColor).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title).font(.system(size: 12.5, weight: .semibold))
                Text(suggestion.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(Fmt.gb(suggestion.reclaimBytes)).font(.system(size: 13, weight: .bold).monospacedDigit())
            Button(actionTitle) { model.perform(suggestion) }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }

    private var icon: String {
        switch suggestion.action {
        case .sessions: "figure.strengthtraining.traditional"
        case .trashPaths: "trash"
        case .migratePaths: "externaldrive"
        case .info: "info.circle"
        }
    }

    private var actionTitle: String {
        switch suggestion.action {
        case .sessions: "정리"
        case .trashPaths: "휴지통"
        case .migratePaths, .info: "열기"
        }
    }
}
