import ReMONCore
import SwiftUI

// 사람(세션) · 도구(앱) 상세 카드, 표 보기, 정리 화면. 창 구조는 OfficeShell.swift.

/// 직원(세션)을 누르면 나오는 상세 카드(사양 2-2). 보기만 하지 않고 여기서 바로 관리한다.
struct DetailCard: View {
    @ObservedObject var model: AppModel
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(session: session).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle).font(.system(size: 14, weight: .bold)).lineLimit(3)
                    HStack(spacing: 5) {
                        Tag(text: session.kind.label)
                        Tag(text: session.state.listLabel, color: session.state.color)
                        if model.isPinned(session) { Tag(text: "보호 고정", color: .blue) }
                        if session.tabLeftover { Tag(text: "Orca 탭 닫힘", color: .purple) }
                        if session.tabUnknown { Tag(text: "Orca 탭 못 찾음(추정)", color: .gray) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Row(label: "방(프로젝트)", value: session.project)
                Row(label: "역할", value: session.role)
                Row(label: "pid", value: "\(session.rootPID) · 하위 \(session.childCount)개")
                Row(label: "메모리 · CPU", value: "\(Fmt.size(session.footprint)) · \(Fmt.percent(session.cpuPercent))")
                Row(label: "작업 폴더", value: session.cwd ?? "확인 안 됨")
                Row(label: "실행 시간", value: Fmt.duration(Date().timeIntervalSince(session.startTime)))
                Row(label: "마지막 기록", value: Fmt.ago(session.lastActivity))
                Row(label: "기록 파일", value: session.logPath.map { ($0 as NSString).lastPathComponent + (session.logLinkIsEstimate ? " (추정)" : "") } ?? "연결 안 됨")
                Row(label: "호스트", value: session.terminalHost ?? "없음")
                Row(label: "판정 근거", value: session.stateReason)
                Row(label: "제목 출처", value: session.titleSource)
            }
            SessionContextSection(model: model, session: session)
            if !session.subagents.isEmpty {
                Divider()
                Text("하위 에이전트 \(session.subagents.count)명 · 일하는 중 \(session.activeSubagents)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(session.subagents.prefix(12)) { agent in
                    HStack(spacing: 6) {
                        Circle().fill(agent.active ? Color.green : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
                        Text(agent.label).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 4)
                        if agent.kind == .workflow { Text("워크플로").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.yellow) }
                        if let model = agent.model { Text(model).font(.system(size: 9.5)).foregroundStyle(.secondary) }
                        Text(Fmt.ago(agent.lastActivity)).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                }
                if session.subagents.count > 12 { Text("… 외 \(session.subagents.count - 12)명").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
            DisclosureGroup("왜 실행 중?") { model.whyCard(pid: session.rootPID) }.font(.system(size: 11, weight: .semibold))
            Divider()
            Text("관리").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    Button { model.release(session) } label: { Label("정리하기", systemImage: "figure.walk.departure").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button(role: .destructive) { model.evict(session) } label: { Label("강제 종료", systemImage: "xmark.octagon").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).tint(.red)
                }
                GridRow {
                    Button { model.revealTerminal(session) } label: { Label("터미널로 이동", systemImage: "terminal").frame(maxWidth: .infinity) }
                        .disabled(session.terminalHost == nil && session.orcaHandle == nil)
                    Button { model.copyResume(session) } label: { Label("이어 열기 복사", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                        .disabled(session.resumeCommand == nil)
                }
                GridRow {
                    Button { if let cwd = session.cwd { model.revealInFinder(cwd) } } label: { Label("작업 폴더", systemImage: "folder").frame(maxWidth: .infinity) }
                        .disabled(session.cwd == nil)
                    Button { if let log = session.logPath { model.revealInFinder(log) } } label: { Label("기록 파일", systemImage: "doc.text").frame(maxWidth: .infinity) }
                        .disabled(session.logPath == nil)
                }
                GridRow {
                    Button { model.togglePin(session) } label: { Label(model.isPinned(session) ? "보호 해제" : "보호 고정", systemImage: model.isPinned(session) ? "lock.open" : "lock").frame(maxWidth: .infinity) }
                        .gridCellColumns(2)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let message = model.lastActionMessage { Text(message).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }

    struct Row: View {
        let label: String
        let value: String
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                Text(value).font(.system(size: 11)).textSelection(.enabled).lineLimit(3)
                Spacer(minLength: 0)
            }
        }
    }

    struct Tag: View {
        let text: String
        var color: Color? = nil
        var body: some View {
            Text(text).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color ?? Color.primary)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill((color ?? Color.primary).opacity(0.14)))
        }
    }
}

/// 도구(앱)를 누르면 나오는 카드. 도구는 사람이 아니므로 '종료'만 있다.
struct AppDetailCard: View {
    @ObservedObject var model: AppModel
    let app: AppGroup

    var body: some View {
        let blockers = model.appBlockers(app)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                if let icon = model.icon(for: app) {
                    Image(nsImage: icon).resizable().frame(width: 38, height: 38)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 28)).foregroundStyle(.secondary).frame(width: 38, height: 38)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.system(size: 15, weight: .bold))
                    DetailCard.Tag(text: categoryLabel)
                }
            }
            DetailCard.Row(label: "메모리 · CPU", value: "\(Fmt.gb(app.footprint)) · \(Fmt.percent(app.cpuPercent))")
            DetailCard.Row(label: "프로세스", value: "\(app.pids.count)개")
            DetailCard.Row(label: "수치 출처", value: app.memorySourceNote ?? "커널(phys_footprint)")
            if !blockers.isEmpty {
                Text("보호 대상 · " + blockers.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.orange)
            }
            Divider()
            HStack(spacing: 6) {
                Button { model.activate(app) } label: { Label("앱 보기", systemImage: "macwindow") }
                Button { model.quitApp(app) } label: { Label("종료", systemImage: "power") }.disabled(!blockers.isEmpty)
                Button(role: .destructive) { model.forceQuitApp(app) } label: { Label("강제 종료", systemImage: "xmark.octagon") }.disabled(!blockers.isEmpty)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let pid = app.pids.first {
                DisclosureGroup("왜 실행 중?") { model.whyCard(pid: pid) }.font(.system(size: 11, weight: .semibold))
            }
        }
    }

    private var categoryLabel: String {
        switch app.category {
        case .app: "앱(도구)"
        case .agentApp: "AI 앱(도구)"
        case .host: "터미널 호스트"
        case .system: "시스템"
        case .other: "기타"
        }
    }
}

// MARK: - 표 보기(대시보드의 '표' 모드)

struct TablePanel: View {
    @ObservedObject var model: AppModel
    @State private var kind = 0
    @State private var filter = ""
    @State private var sessionOrder = [KeyPathComparator(\AgentSessionRow.memory, order: .reverse)]
    @State private var appOrder = [KeyPathComparator(\AppRow.memory, order: .reverse)]
    @State private var processOrder = [KeyPathComparator(\ProcessRow.memory, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $kind) { Text("세션").tag(0); Text("앱").tag(1); Text("프로세스").tag(2) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                TextField("필터", text: $filter).textFieldStyle(.roundedBorder).frame(width: 220)
                Spacer()
            }
            switch kind {
            case 0:
                Table(sessionRows.sorted(using: sessionOrder), selection: Binding(get: { model.selectedSession.map { Set([$0]) } ?? [] }, set: { model.selectedSession = $0.first; model.scene?.select($0.first) }), sortOrder: $sessionOrder) {
                    TableColumn("프로젝트", value: \.project)
                    TableColumn("종류", value: \.kind)
                    TableColumn("상태", value: \.state)
                    TableColumn("메모리", value: \.memory) { Text(Fmt.size($0.memory)).monospacedDigit() }
                    TableColumn("CPU", value: \.cpu) { Text(Fmt.percent($0.cpu)).monospacedDigit() }
                    TableColumn("마지막 기록", value: \.lastSort) { Text(Fmt.ago($0.last)) }
                    TableColumn("제목", value: \.title)
                }
            case 1:
                Table(appRows.sorted(using: appOrder), selection: Binding(get: { model.selectedApp.map { Set([$0]) } ?? [] }, set: { model.selectedApp = $0.first }), sortOrder: $appOrder) {
                    TableColumn("앱", value: \.name)
                    TableColumn("분류", value: \.category)
                    TableColumn("프로세스", value: \.count) { Text("\($0.count)").monospacedDigit() }
                    TableColumn("메모리", value: \.memory) { Text(Fmt.size($0.memory)).monospacedDigit() }
                    TableColumn("CPU", value: \.cpu) { Text(Fmt.percent($0.cpu)).monospacedDigit() }
                    TableColumn("출처", value: \.note)
                }
            default:
                Table(processRows.sorted(using: processOrder), sortOrder: $processOrder) {
                    TableColumn("pid", value: \.pid) { Text("\($0.pid)").monospacedDigit() }
                    TableColumn("이름", value: \.name)
                    TableColumn("메모리", value: \.memory) { Text(Fmt.size($0.memory)).monospacedDigit() }
                    TableColumn("CPU", value: \.cpu) { Text(String(format: "%.1f%%", $0.cpu)).monospacedDigit() }
                    TableColumn("부모", value: \.ppid) { Text("\($0.ppid)").monospacedDigit() }
                    TableColumn("출처", value: \.source)
                }
            }
        }
    }

    private func matches(_ text: String) -> Bool { filter.isEmpty || text.localizedCaseInsensitiveContains(filter) }

    private var sessionRows: [AgentSessionRow] {
        (model.office?.sessions ?? []).map(AgentSessionRow.init).filter { matches($0.project + $0.title + $0.kind) }
    }

    private var appRows: [AppRow] {
        (model.office?.apps ?? []).map(AppRow.init).filter { matches($0.name) }
    }

    private var processRows: [ProcessRow] {
        (model.office?.processes ?? []).map(ProcessRow.init).filter { matches($0.name + "\($0.pid)") }
    }
}

struct AgentSessionRow: Identifiable {
    let id: ProcessKey
    let project: String, kind: String, state: String, title: String
    let memory: UInt64, cpu: Double, last: Date?
    var lastSort: Double { last?.timeIntervalSince1970 ?? 0 }
    init(_ session: AgentSession) {
        id = session.id; project = session.project; kind = session.kind.label; state = session.state.listLabel; title = session.displayTitle
        memory = session.footprint; cpu = session.cpuPercent; last = session.lastActivity
    }
}

struct AppRow: Identifiable {
    let id: String, name: String, category: String, note: String
    let count: Int, memory: UInt64, cpu: Double
    init(_ app: AppGroup) {
        id = app.id; name = app.name; count = app.pids.count; memory = app.footprint; cpu = app.cpuPercent; note = app.memorySourceNote ?? "커널"
        category = ["app": "앱", "agentApp": "AI 앱", "host": "호스트", "system": "시스템", "other": "기타"][app.category.rawValue] ?? app.category.rawValue
    }
}

struct ProcessRow: Identifiable {
    let id: ProcessKey, pid: Int32, ppid: Int32, name: String, source: String
    let memory: UInt64, cpu: Double
    init(_ record: ProcRecord) {
        id = record.key; pid = record.pid; ppid = record.ppid; name = record.displayName; memory = record.footprint; cpu = record.cpuPercent
        source = record.memorySource == .kernel ? "커널" : record.memorySource == .top ? "top" : "권한 밖"
    }
}

// MARK: - 정리 화면(칸을 Grid로 맞춘다)

struct CleanupPageView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "정리", subtitle: "정리 전에 되돌릴 방법을 먼저 적어 둡니다(복구함) · 영구 삭제는 다시 생기는 캐시만 · 휴지통 비우기는 하지 않음") {
                HStack(spacing: 10) {
                    Toggle("드라이런", isOn: Binding(get: { model.settings.dryRun }, set: { model.settings.dryRun = $0 })).toggleStyle(.switch).controlSize(.small)
                    if model.diskScanning {
                        ProgressView().controlSize(.small)
                        Text("살펴보는 중…").font(.system(size: 11))
                    } else if let at = model.diskScannedAt {
                        Text("\(Fmt.ago(at)) 조사").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Button("다시 조사") { model.scanDisk() }.disabled(model.diskScanning)
                    Button { model.copyDiagnostics() } label: { Label("진단 보고서", systemImage: "stethoscope") }.help("지원·문의용 진단 보고서를 복사합니다(경로는 ~, 비밀값·세션 제목 제외)")
                }
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    sessionsSection
                    RecoverySection(model: model)
                    OrphanHelpersSection(model: model)
                    LeftoversSection(model: model)
                    AIDataSection(model: model)
                    DevCacheSection(model: model)
                    SystemDataSection(model: model)
                    LargeFilesSection(model: model)
                    StartupItemsSection(model: model)
                    // 카탈로그가 보여 주는 캐시(entryID 있음)와 '보기만' 묶음은 위 개발 캐시 구역에서 다룬다 — 여기선 나머지(휴지통·AI 기록·큰 DB·카탈로그 밖)만.
                    ForEach(DiskCategory.allCases.filter { $0 != .keep }, id: \.self) { category in
                        let items = model.diskItems.filter { $0.category == category && $0.entryID == nil }
                        if !items.isEmpty { section(category, items) }
                    }
                    migrationsSection
                    explainer
                }
                .padding(18)
            }
        }
        .overlay(alignment: .trailing) {
            if model.hasInspector {
                InspectorPanel(model: model).frame(width: 330).padding(12)
            }
        }
        // 첫 디스크 조사는 실행 5분 뒤지만, 정리 화면을 열면 바로 시작한다.
        .onAppear { if model.diskScannedAt == nil && !model.diskScanning { model.scanDisk() } }
    }

    private var sessionsSection: some View {
        let resting = (model.office?.sessions ?? []).filter { $0.state == .longIdle || $0.state == .orphan || $0.state == .idle }.sorted { $0.footprint > $1.footprint }
        return CleanupBox(title: "쉬는 세션 · 고아 세션 \(resting.count)개 · \(Fmt.gb(resting.reduce(0) { $0 + $1.footprint }))", hint: "정리하면 트레이너가 들어와 퇴근시킵니다") {
            Button { model.releaseMany(resting, title: "쉬는 세션 모두 정리") } label: { Label("모두 정리", systemImage: "figure.strengthtraining.traditional") }
                .buttonStyle(.borderedProminent).controlSize(.small).disabled(resting.isEmpty)
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(resting.prefix(20)) { session in
                    GridRow {
                        HStack(spacing: 6) {
                            AvatarView(session: session).frame(width: 18, height: 18)
                            Text(session.project).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        }
                        Text("\(session.kind.shortLabel) · \(session.state.label)").font(.system(size: 11)).foregroundStyle(session.state.color)
                        Text(session.displayTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Fmt.size(session.footprint)).font(.system(size: 11, weight: .semibold).monospacedDigit()).gridColumnAlignment(.trailing)
                        HStack(spacing: 4) {
                            Button("보기") { model.selectSession(session) }
                            Button("정리하기") { model.release(session) }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func section(_ category: DiskCategory, _ items: [DiskItem]) -> some View {
        let actionable = items.filter { !$0.permissionNeeded && ($0.category == .regenerable || $0.category == .temporary) }
        return CleanupBox(title: "\(category.label) · \(Fmt.gb(items.reduce(0) { $0 + $1.bytes }))", hint: category.actionHint) {
            if !actionable.isEmpty {
                Button { model.trashMany(actionable, title: category.label) } label: { Label("모두 휴지통", systemImage: "trash") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        } content: {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(items.prefix(16)) { item in
                    GridRow {
                        Text(item.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(item.path)
                        Text(item.note).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        Text(item.permissionNeeded ? "권한 필요" : Fmt.gb(item.bytes)).font(.system(size: 11, weight: .semibold).monospacedDigit()).gridColumnAlignment(.trailing)
                        actions(category, item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ category: DiskCategory, _ item: DiskItem) -> some View {
        HStack(spacing: 4) {
            Button { model.revealInFinder(item.path) } label: { Image(systemName: "folder") }.help("Finder에서 보기")
            switch category {
            case .regenerable, .temporary:
                Button("휴지통") { model.trash(item) }
                Menu { Button("영구 삭제", role: .destructive) { model.trash(item, permanently: true) } } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            case .aiLogs:
                Menu("외장 이전") {
                    let volumes = ExternalMigrator.externalVolumes()
                    if volumes.isEmpty { Text("연결된 외장 볼륨이 없습니다") }
                    ForEach(volumes, id: \.path) { volume in
                        Button("\(volume.path) (\(volume.fsType))") { model.migrate(item, to: volume.path) }
                    }
                }
                .fixedSize()
            default:
                EmptyView()
            }
        }
        .controlSize(.small)
    }

    private var migrationsSection: some View {
        let volumes = ExternalMigrator.externalVolumes()
        return CleanupBox(title: "외장 이전 기록 · 이미지", hint: nil) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.migrations.reversed()) { record in
                    HStack {
                        Text((record.source as NSString).lastPathComponent).font(.system(size: 11))
                        Text("\(record.files)개 · \(Fmt.gb(record.bytes))").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        switch model.migrator.status(record) {
                        case .ok: Text("링크 정상").font(.system(size: 10)).foregroundStyle(.green)
                        case .broken(let image):
                            Text("링크 깨짐").font(.system(size: 10)).foregroundStyle(.red)
                            if let image { Button("연결") { model.attachImage(image) }.controlSize(.small) }
                        case .notALink: Text("링크 없음").font(.system(size: 10)).foregroundStyle(.secondary)
                        case .undone: Text("되돌림").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        if !record.undone { Button("되돌리기") { model.undo(record) }.controlSize(.small) }
                    }
                }
                ForEach(volumes, id: \.path) { volume in
                    ForEach(volume.images, id: \.self) { image in
                        HStack {
                            Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                            Text(image).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("연결") { model.attachImage(image) }.controlSize(.small)
                        }
                    }
                }
                if model.migrations.isEmpty && volumes.allSatisfy({ $0.images.isEmpty }) {
                    Text("아직 이전한 항목이 없습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var explainer: some View {
        CleanupBox(title: "용어 설명", hint: nil) { EmptyView() } content: {
            VStack(alignment: .leading, spacing: 5) {
                Text("스왑: RAM 탱크가 넘칠 때 macOS가 당장 안 쓰는 메모리를 디스크에 내려 두는 상자입니다. 메모리를 많이 쓰면 스왑이 커지고, 그만큼 디스크 여유가 줄어듭니다.")
                Text("압축 메모리: 자주 안 쓰는 메모리를 압축해 같은 공간에 더 담아 둔 것입니다. 늘어나면 메모리가 빠듯하다는 신호입니다.")
                Text("메모리 압박: macOS가 메모리를 얼마나 힘들게 확보하는지 나타냅니다. 정상·주의·위험 세 단계입니다.")
                Text("부산물: 에이전트가 작업하며 남긴 워크트리·브랜치입니다. 병합되고 변경이 없으며 아무도 쓰지 않는 것만 청소합니다.")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 정리 화면의 구역 상자: 제목 · 설명 · 오른쪽 묶음 버튼 + 내용.
struct CleanupBox<Trailing: View, Content: View>: View {
    let title: String
    let hint: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                Spacer()
                trailing
            }
            content
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

/// 에이전트 부산물(워크트리·브랜치) 구역: 방마다 치울 수 있는 것·남기는 이유를 보여 주고, 청소 버튼으로 청소 인력을 부른다.
struct LeftoversSection: View {
    @ObservedObject var model: AppModel
    @State private var expanded: Set<String> = []

    var body: some View {
        let total = model.leftoverCleanableTotal
        let bytes = model.leftovers.reduce(UInt64(0)) { $0 + $1.cleanableBytes }
        CleanupBox(title: "에이전트 부산물 · 워크트리 · 브랜치" + (total > 0 ? " · 치울 수 있음 \(total)개 · \(Fmt.gb(bytes))" : ""), hint: "병합됐고 변경이 없으며 아무도 쓰지 않는 것만 청소합니다") {
            HStack(spacing: 6) {
                if model.leftoversScanning { ProgressView().controlSize(.small) }
                else if let note = model.leftoversNote { Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary) }
                Button(model.leftoversScannedAt == nil ? "조사" : "다시 조사") { model.scanLeftovers() }.disabled(model.leftoversScanning)
                Button { model.cleanLeftovers() } label: { Label("모두 청소", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).disabled(total == 0 || model.leftoversScanning)
            }
            .controlSize(.small)
        } content: {
            if model.leftovers.isEmpty {
                Text(model.leftoversScannedAt == nil ? "아직 조사하지 않았습니다. '조사'를 누르면 \(OrcaBridge.executable == nil ? "~/DEV를" : "~/DEV와 Orca 작업 공간을") 읽기 전용으로 살펴봅니다." : "부산물이 없습니다.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                ForEach(model.leftovers.filter { $0.cleanableCount > 0 || $0.keepCount > 0 }) { project in
                    LeftoverProjectRow(model: model, project: project, expanded: expanded.contains(project.id)) {
                        if expanded.contains(project.id) { expanded.remove(project.id) } else { expanded.insert(project.id) }
                    }
                }
            }
        }
    }
}

struct LeftoverProjectRow: View {
    @ObservedObject var model: AppModel
    let project: ProjectLeftovers
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 12)
                }
                .buttonStyle(.plain)
                Text(project.project).font(.system(size: 12, weight: .semibold))
                Text("치울 수 있음 \(project.cleanableCount) · 남김 \(project.keepCount)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.gb(project.cleanableBytes)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                Button("청소") { model.cleanLeftovers([project]) }.controlSize(.small).disabled(project.cleanableCount == 0)
                Button { model.focusOn(.room(project.project)) } label: { Image(systemName: "scope") }.controlSize(.small).help("사무실에서 보기")
            }
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    ForEach(project.worktrees.filter(\.isClutter)) { worktree in
                        GridRow {
                            Image(systemName: "folder.badge.gearshape").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text((worktree.path as NSString).lastPathComponent + (worktree.branch.map { " (\($0))" } ?? "")).font(.system(size: 11)).lineLimit(1).truncationMode(.middle).help(worktree.path)
                            Text(worktree.manager.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(worktree.verdict.isCleanable ? "치움" : "남김 · " + (worktree.verdict.keepReason ?? "")).font(.system(size: 10.5)).foregroundStyle(worktree.verdict.isCleanable ? Color.green : Color.secondary).lineLimit(1)
                            Text(worktree.bytes > 0 ? Fmt.gb(worktree.bytes) : "").font(.system(size: 10.5).monospacedDigit()).gridColumnAlignment(.trailing)
                            Button { model.revealInFinder(worktree.path) } label: { Image(systemName: "folder") }.controlSize(.mini).disabled(worktree.prunable)
                        }
                    }
                    ForEach(project.branches.filter(\.isClutter)) { branch in
                        GridRow {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(branch.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                            Text((branch.repo as NSString).lastPathComponent).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            Text(branch.verdict.isCleanable ? "치움" : "남김 · " + (branch.verdict.keepReason ?? "")).font(.system(size: 10.5)).foregroundStyle(branch.verdict.isCleanable ? Color.green : Color.secondary).lineLimit(1)
                            Text(branch.lastCommit.map { Fmt.ago($0) } ?? "").font(.system(size: 10.5)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text("")
                        }
                    }
                }
                .padding(.leading, 20)
            }
        }
        .padding(.vertical, 3)
    }
}
