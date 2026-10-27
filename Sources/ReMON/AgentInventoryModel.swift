import AppKit
import ReMONCore
import SwiftUI

/// 이 Mac의 에이전트 설치 현황(설치 경로 · 버전 · 데이터 폴더) 캐시. 대시보드 카드 · 설정 '에이전트' 탭 · 설정 도우미가 함께 쓴다.
/// 파일 시스템을 훑고 버전 확인은 프로세스를 띄울 수도 있어, 백그라운드에서 10분에 한 번만 한다(주기마다 하지 않는다).
@MainActor
final class AgentInventoryModel: ObservableObject {
    static let shared = AgentInventoryModel()

    @Published private(set) var installs: [AgentInstall] = []
    @Published private(set) var scanning = false
    @Published private(set) var scannedAt: Date?
    /// 켜기·끄기와 직접 추가 목록(설정이 바뀌면 다시 읽는다)
    @Published private(set) var catalog: AgentCatalog.State = AgentCatalog.shared.current
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: AgentCatalog.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.catalog.custom
                self.catalog = AgentCatalog.shared.current
                // 직접 추가가 바뀌면 그 줄의 설치 경로를 다시 찾는다.
                if before != self.catalog.custom { self.refresh(force: true) }
            }
        }
    }

    /// force가 아니면 10분 안의 결과를 그대로 쓴다.
    func refresh(force: Bool = false) {
        guard !scanning else { return }
        if !force, let at = scannedAt, Date().timeIntervalSince(at) < 600 { return }
        scanning = true
        let custom = AgentCatalog.shared.current.custom
        DispatchQueue.global(qos: .utility).async {
            let rows = AgentInventory.scan(custom: custom, probeVersions: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let model = AgentInventoryModel.shared
                    model.installs = rows
                    model.scanning = false
                    model.scannedAt = Date()
                }
            }
        }
    }

    func install(for kind: AgentKind) -> AgentInstall? { installs.first { $0.kind == kind } }

    /// 표의 모든 종류 + 직접 추가(설정 '에이전트' 탭 순서).
    var allKinds: [AgentKind] { AgentSignatures.all.map(\.kind) + catalog.custom.map(\.kind) }
}

extension AppModel {
    /// 지금 도는 세션 수(종류별)
    func runningCount(_ kind: AgentKind) -> Int { office?.sessions.filter { $0.kind == kind }.count ?? 0 }

    /// 지금 세션을 띄운 터미널 분포("Ghostty 2 · Orca 10 · 호스트 없음 1")
    var terminalHostSummary: [(name: String, count: Int)] {
        let groups = Dictionary(grouping: office?.sessions ?? []) { $0.terminalHost ?? "호스트 없음" }
        return groups.map { ($0.key, $0.value.count) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// 설정 창을 특정 탭으로 연다.
    func openSettings(_ tab: SettingsTab) {
        (NSApp.delegate as? AppDelegate)?.showSettings(tab: tab)
    }
}

// MARK: - 대시보드 카드: 이 Mac에서 찾은 에이전트

/// 설치됐거나 · 지금 돌거나 · 데이터 폴더가 있는 에이전트만 표로 보여 주고, 나머지는 이름만 한 줄로 적는다.
struct AgentInventoryCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var inventory = AgentInventoryModel.shared

    var body: some View {
        let kinds = inventory.allKinds
        // 실행 중 많은 순 → 설치된 것 → 표 순서(정렬이 매번 같아야 갱신 때 줄이 뒤섞이지 않는다).
        let order = Dictionary(kinds.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let shown = kinds.filter { kind in
            let install = inventory.install(for: kind)
            return install?.installed == true || model.runningCount(kind) > 0 || install?.dataFolder != nil
        }.sorted { lhs, rhs in
            let l = model.runningCount(lhs), r = model.runningCount(rhs)
            if l != r { return l > r }
            let li = inventory.install(for: lhs)?.installed == true, ri = inventory.install(for: rhs)?.installed == true
            if li != ri { return li }
            return order[lhs, default: 0] < order[rhs, default: 0]
        }
        let rest = kinds.filter { !shown.contains($0) }
        CardBox {
            if inventory.installs.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("설치된 에이전트를 찾는 중입니다…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                    GridRow {
                        Text("에이전트"); Text("설치"); Text("실행 중"); Text("이어 열기"); Text("데이터 폴더")
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    Divider().gridCellColumns(5)
                    ForEach(shown, id: \.self) { kind in
                        AgentInventoryRow(kind: kind, install: inventory.install(for: kind), running: model.runningCount(kind), enabled: inventory.catalog.isEnabled(kind.rawValue))
                    }
                }
                if !rest.isEmpty {
                    Text("그 밖에 알아보는 에이전트: " + rest.map(\.name).joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(hostLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 8)
                Button("다시 확인") { inventory.refresh(force: true) }.disabled(inventory.scanning)
                Button("에이전트 설정") { model.openSettings(.agents) }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
        .onAppear { inventory.refresh() }
    }

    private var hostLine: String {
        let hosts = model.terminalHostSummary.map { "\($0.name) \($0.count)" }
        let orca = OrcaBridge.executable.map { "Orca CLI 있음(\(AgentInventory.abbreviate($0)))" } ?? "제목은 기록에서 읽습니다"
        return (hosts.isEmpty ? "터미널: 세션 없음" : "터미널: " + hosts.joined(separator: " · ")) + " · " + orca
    }
}

/// 표 한 줄: 이름 · 설치(경로) · 실행 중 · 이어 열기 · 데이터 폴더.
struct AgentInventoryRow: View {
    let kind: AgentKind
    let install: AgentInstall?
    let running: Int
    let enabled: Bool

    var body: some View {
        GridRow {
            HStack(spacing: 6) {
                Circle().fill(Color(nsColor: TeamColor.ns(kind))).frame(width: 8, height: 8)
                Text(kind.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !enabled { Text("꺼짐").font(.system(size: 9.5, weight: .bold)).foregroundStyle(.secondary) }
            }
            installCell
            Text(running > 0 ? "\(running)" : "—").font(.system(size: 12, weight: running > 0 ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(running > 0 ? Color.green : Color.secondary)
            resumeCell
            Text(install?.dataFolder ?? "없음").font(.system(size: 11)).foregroundStyle(install?.dataFolder == nil ? Color.secondary : Color.primary).lineLimit(1)
        }
    }

    @ViewBuilder private var installCell: some View {
        if let install, let path = install.path {
            HStack(spacing: 4) {
                Image(systemName: install.nameOnly ? "questionmark.circle" : "checkmark.circle.fill").foregroundStyle(install.nameOnly ? Color.orange : Color.green)
                Text(install.version ?? (install.nameOnly ? "이름만 일치" : "설치됨")).font(.system(size: 11).monospacedDigit()).lineLimit(1)
            }
            .help(AgentInventory.abbreviate(path) + (install.otherPaths.isEmpty ? "" : "\n외 \(install.otherPaths.count)곳: " + install.otherPaths.map { AgentInventory.abbreviate($0) }.joined(separator: ", ")))
        } else {
            HStack(spacing: 4) {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                Text("없음").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var resumeCell: some View {
        let resume = install?.resume ?? AgentSignatures.resume(for: kind)
        switch resume {
        case .known(let command):
            Text("지원").font(.system(size: 11, weight: .semibold)).foregroundStyle(.green).help(command)
        case .unknown:
            Text("모름").font(.system(size: 11)).foregroundStyle(.secondary).help("이어 열기 형식을 확인하지 못했습니다. 이어 열기 키가 없어 자동 정리하지 않습니다.")
        }
    }
}
