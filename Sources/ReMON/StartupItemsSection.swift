import ReMONCore
import SwiftUI

/// 시작 항목 조사 결과(화면 상태). 세 폴더 plist + 항목마다 launchctl print(읽기 전용, 항목당 수 ms)라 백그라운드에서 읽는다.
@MainActor
final class StartupItemsStore: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var scanning = false
    @Published var scannedAt: Date?

    func scan() {
        guard !scanning else { return }
        scanning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let items = StartupItemScanner().scan()
            DispatchQueue.main.async {
                guard let self else { return }
                // 확인 필요(반복 크래시·실행 파일 없음) → 내 에이전트 → 모든 사용자 에이전트 → 시스템 데몬, 같은 묶음은 라벨 순.
                self.items = items.sorted { lhs, rhs in
                    if lhs.flagged != rhs.flagged { return lhs.flagged }
                    if lhs.domain != rhs.domain { return StartupItem.Domain.allCases.firstIndex(of: lhs.domain)! < StartupItem.Domain.allCases.firstIndex(of: rhs.domain)! }
                    return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }
                self.scanning = false
                self.scannedAt = Date()
            }
        }
    }
}

/// 정리 화면의 '시작 항목 · 백그라운드 서비스' 구역(G4). 확인이 필요한 것(실행 파일 없음 · 반복 크래시)을 위에 보인다.
/// 끄기는 내 에이전트(~/Library/LaunchAgents)만: launchctl bootout + plist 휴지통(복구함에서 다시 켬).
/// 모든 사용자 에이전트·시스템 데몬은 보여 주기만 하고 시스템 설정(로그인 항목)을 연다.
struct StartupItemsSection: View {
    @ObservedObject var model: AppModel
    @StateObject private var store = StartupItemsStore()
    @State private var showSystem = false

    var body: some View {
        let flagged = store.items.filter(\.flagged)
        let mine = store.items.filter { !$0.flagged && $0.domain == .userAgent }
        let system = store.items.filter { !$0.flagged && $0.domain != .userAgent }
        let disabled = model.disabledStartupEntries
        CleanupBox(title: "시작 항목 · 백그라운드 서비스 \(store.items.count)개" + (flagged.isEmpty ? "" : " · 확인 필요 \(flagged.count)"),
                   hint: "로그인 때 뜨거나 꺼져도 다시 살아나는 프로그램입니다") {
            HStack(spacing: 6) {
                if store.scanning {
                    ProgressView().controlSize(.small)
                } else if let at = store.scannedAt {
                    Text("\(Fmt.ago(at)) 조사").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Button(store.scannedAt == nil ? "조사" : "다시 조사") { store.scan() }.disabled(store.scanning)
                Button { model.openLoginItemsSettings() } label: { Label("로그인 항목 설정", systemImage: "gearshape") }
                    .help("시스템 설정 › 일반 › 로그인 항목 및 확장 프로그램")
            }
            .controlSize(.small)
        } content: {
            if store.items.isEmpty {
                Text(store.scanning ? "LaunchAgents·LaunchDaemons를 읽는 중입니다…" : "시작 항목이 없습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                ForEach(flagged) { item in StartupItemRow(model: model, item: item) { store.scan() } }
                ForEach(mine) { item in StartupItemRow(model: model, item: item) { store.scan() } }
                if showSystem {
                    ForEach(system) { item in StartupItemRow(model: model, item: item) { store.scan() } }
                }
            }
            if !system.isEmpty {
                Button(showSystem ? "모든 사용자·시스템 항목 숨기기" : "모든 사용자·시스템 항목 \(system.count)개 보기(보여 주기만)") { showSystem.toggle() }
                    .controlSize(.small)
            }
            if !disabled.isEmpty {
                Divider()
                Text("최근에 끈 항목 · 다시 켜면 파일을 되돌리고 launchctl bootstrap합니다").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(disabled) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: "power.circle").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                        Text(entry.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text("\(Fmt.ago(entry.createdAt)) 끔").font(.system(size: 10.5)).foregroundStyle(.secondary)
                        Spacer()
                        Button("다시 켜기") { model.restoreStartupItem(entry) { store.scan() } }.controlSize(.small)
                    }
                    .help(entry.note ?? entry.title)
                }
            }
        }
        .onAppear { if store.scannedAt == nil { store.scan() } }
    }
}

struct StartupItemRow: View {
    @ObservedObject var model: AppModel
    let item: StartupItem
    let refresh: () -> Void

    var body: some View {
        GridRow {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(item.flagged ? Color.orange : Color.secondary).frame(width: 16)
                Text(item.label).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            }
            .help("\(item.domain.label)\n\(item.plistPath)" + (item.symlinkTarget.map { "\n→ \($0)" } ?? ""))
            Text(programText).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.missingProgram.map { "없는 파일: \($0)" } ?? (item.resolvedProgram ?? item.program ?? ""))
            HStack(spacing: 4) { tags }.fixedSize()
            HStack(spacing: 4) {
                Button { model.revealInFinder(item.plistPath) } label: { Image(systemName: "folder") }.help("Finder에서 plist 보기")
                if item.domain == .userAgent {
                    Button("끄기") { model.disableStartupItem(item, completion: refresh) }
                        .disabled(!item.canDisable)
                        .help(item.disableBlocker ?? "launchctl bootout으로 끄고 plist를 휴지통으로(복구함에서 다시 켬)")
                } else {
                    Button("설정") { model.openLoginItemsSettings() }.help(item.disableBlocker ?? "시스템 설정에서 관리합니다")
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var tags: some View {
        if item.crashLoop {
            DetailCard.Tag(text: "반복 크래시" + (item.state?.runs.map { " · \($0.formatted())회" } ?? " · 종료 \(exitCode)"), color: .red)
                .help("KeepAlive인데 마지막 종료 \(exitCode) — launchd가 계속 다시 띄웁니다")
        } else if item.lastRunFailed {
            DetailCard.Tag(text: "마지막 종료 \(exitCode)", color: .orange)
        }
        if item.missingProgram != nil { DetailCard.Tag(text: "실행 파일 없음", color: .orange) }
        if let state = item.state {
            if state.running { DetailCard.Tag(text: "실행 중", color: .green) }
            else if state.loaded { DetailCard.Tag(text: "대기") }
            else if state.error != nil { DetailCard.Tag(text: "상태 모름") }
            else { DetailCard.Tag(text: "꺼짐") }
        } else if !item.readable {
            DetailCard.Tag(text: "읽을 수 없음", color: .orange)
        }
        if item.protection != nil { DetailCard.Tag(text: "보호", color: .blue).help(item.protection ?? "") }
    }

    private var exitCode: String {
        if let code = item.state?.lastExitCode { return "\(code)" }
        return item.state?.lastSignal ?? "?"
    }

    private var programText: String {
        if let program = item.resolvedProgram ?? item.program { return program.replacingOccurrences(of: NSHomeDirectory(), with: "~") + (item.keepAlive.isOn ? " · \(item.keepAlive.label)" : "") }
        return item.parseError ?? "실행 파일 지정 없음"
    }

    private var icon: String {
        switch item.domain {
        case .userAgent: "person.crop.circle"
        case .globalAgent: "person.2.circle"
        case .systemDaemon: "gearshape.2"
        }
    }
}
