import Charts
import ReMONCore
import SwiftUI

// MARK: - 계기판(오른쪽 사이드바 위, 고정)

/// CPU·RAM·디스크·스왑은 사람이 아니라 기계다 — 금속판 계기로 그리고, 과열·꽉 참을 기계답게 보인다.
struct GaugePanel: View {
    @ObservedObject var model: AppModel
    @State private var chart: HistoryChartKind = .disk

    var body: some View {
        let system = model.system
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("계기판").font(.system(size: 13, weight: .bold))
                Spacer()
                PressureBadge(level: system.pressure)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    CPUEngineGauge(cpu: system.cpuPercent, cores: system.coreLoads).onTapGesture { open(.cpu) }
                    RAMTankGauge(memory: system.memory, pressure: system.pressure).onTapGesture { open(.ram) }
                }
                GridRow {
                    DiskSiloGauge(disk: system.disk, thresholdGB: model.settings.diskThresholdGB).onTapGesture { open(.disk) }
                    SwapCrateGauge(swap: system.swap).onTapGesture { open(.swap) }
                }
            }
            HistoryMiniChart(points: model.history, kind: $chart)
        }
    }

    private func open(_ machine: MachineKind) {
        model.selectMachine(machine)
        if model.page == .office { model.scene?.focus(.region(.machineRoom), animated: true) }
    }
}

struct PressureBadge: View {
    let level: PressureLevel
    var body: some View {
        let color: Color = level == .critical ? .red : level == .warning ? .orange : .green
        Text("메모리 압박 \(level.label)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

/// 기계 계기의 금속판 틀(리벳 네 개). 과열·꽉 참이면 테두리가 달아오른다.
struct MachinePlate<Content: View>: View {
    let title: String
    let icon: String
    var heat: Color? = nil
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9.5, weight: .bold))
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).opacity(hover ? 0.8 : 0)
            }
            .foregroundStyle(heat ?? Color.secondary)
            content
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(LinearGradient(colors: [Color.primary.opacity(hover ? 0.13 : 0.10), Color.primary.opacity(0.04)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(heat?.opacity(0.85) ?? Color.primary.opacity(0.14), lineWidth: heat == nil ? 0.5 : 1.3)
        )
        .overlay(rivets)
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onHover { hover = $0 }
        .help("\(title) 자세히 보기")
    }

    private var rivets: some View {
        GeometryReader { proxy in
            ForEach(0..<4, id: \.self) { index in
                Circle().fill(Color.primary.opacity(0.22)).frame(width: 3, height: 3)
                    .position(x: index % 2 == 0 ? 5 : proxy.size.width - 5, y: index < 2 ? 5 : proxy.size.height - 5)
            }
        }
        .allowsHitTesting(false)
    }
}

/// CPU 엔진: 바늘 계기(빨간 구간 80~100%) + 코어별 실린더. 85%를 넘으면 '과열'.
struct CPUEngineGauge: View {
    let cpu: Double
    let cores: [Double]

    var heat: Color? { cpu >= 85 ? .red : cpu >= 65 ? .orange : nil }

    var body: some View {
        MachinePlate(title: "CPU 엔진", icon: "cpu", heat: heat) {
            VStack(spacing: 1) {
                Dial(value: cpu / 100).frame(height: 36)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(Fmt.percent(cpu)).font(.system(size: 14, weight: .bold).monospacedDigit())
                    Text(cpu >= 85 ? "과열" : cpu >= 65 ? "뜨거움" : "정상").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(heat ?? Color.secondary)
                }
            }
            .frame(height: 54)
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(cores.prefix(16).enumerated()), id: \.offset) { _, load in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1).fill(Self.color(load)).frame(height: max(1.5, 12 * load / 100))
                    }
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.07)))
                }
            }
            .frame(height: 12)
        }
    }

    static func color(_ load: Double) -> Color { load >= 85 ? .red : load >= 60 ? .orange : Color(red: 0.35, green: 0.62, blue: 0.95) }
}

/// 반원 바늘 계기.
struct Dial: View {
    let value: Double   // 0~1

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 2)
            let radius = min(size.width / 2 - 4, size.height - 4)
            func point(_ fraction: Double, _ r: CGFloat) -> CGPoint {
                let angle = Double.pi * (1 - fraction)
                return CGPoint(x: center.x + CGFloat(cos(angle)) * r, y: center.y - CGFloat(sin(angle)) * r)
            }
            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            context.stroke(track, with: .color(.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            var red = Path()
            red.addArc(center: center, radius: radius, startAngle: .degrees(180 + 0.8 * 180), endAngle: .degrees(0), clockwise: false)
            context.stroke(red, with: .color(.red.opacity(0.75)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            for tick in 0...10 {
                let fraction = Double(tick) / 10
                var line = Path()
                line.move(to: point(fraction, radius - 4))
                line.addLine(to: point(fraction, radius - (tick % 5 == 0 ? 9 : 6)))
                context.stroke(line, with: .color(.primary.opacity(0.4)), lineWidth: tick % 5 == 0 ? 1.2 : 0.7)
            }
            let clamped = max(0, min(1, value))
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: point(clamped, radius - 6))
            context.stroke(needle, with: .color(clamped >= 0.85 ? .red : .primary), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(.primary.opacity(0.8)))
        }
    }
}

/// RAM 탱크: 앱(파랑) · 와이어드(분홍) · 압축(청록) 액체가 차오른다. 압박이 '위험'이면 '꽉 참'.
struct RAMTankGauge: View {
    let memory: MemoryStats
    let pressure: PressureLevel

    var heat: Color? { pressure == .critical ? .red : pressure == .warning ? .orange : nil }

    var body: some View {
        MachinePlate(title: "RAM 탱크", icon: "memorychip", heat: heat) {
            HStack(alignment: .bottom, spacing: 9) {
                Tank(fractions: fractions).frame(width: 26, height: 62)
                VStack(alignment: .leading, spacing: 1) {
                    Text("여유 \(Fmt.gb(memory.available))").font(.system(size: 14, weight: .bold).monospacedDigit()).foregroundStyle(heat ?? Color.primary)
                    Text("사용 \(Fmt.gb(memory.used)) / \(Fmt.gb(memory.physical))").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text(pressure == .critical ? "꽉 참" : pressure == .warning ? "거의 참" : "여유").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(heat ?? Color.green)
                    Text("압축 \(Fmt.gb(memory.compressed))").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(height: 62, alignment: .leading)
            }
        }
    }

    private var fractions: [(Double, Color)] {
        let total = max(1, Double(memory.physical))
        return [(Double(memory.wired) / total, Color(red: 0.95, green: 0.5, blue: 0.55)),
                (Double(memory.appMemory) / total, Color(red: 0.3, green: 0.55, blue: 0.95)),
                (Double(memory.compressed) / total, Color(red: 0.3, green: 0.78, blue: 0.68))]
    }
}

/// 세로 유리 탱크(아래부터 채움). 눈금 네 줄.
struct Tank: View {
    let fractions: [(Double, Color)]

    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height - 4
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07))
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ForEach(Array(fractions.reversed().enumerated()), id: \.offset) { _, part in
                        Rectangle().fill(part.1).frame(height: max(0, height * CGFloat(min(1, part.0))))
                    }
                }
                .padding(2)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { _ in
                        Spacer()
                        Rectangle().fill(Color.primary.opacity(0.25)).frame(width: 5, height: 0.7).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Spacer()
                }
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.3), lineWidth: 1)
            }
        }
    }
}

/// 디스크 저장고: 찬 칸(회색) · 빈 칸(초록, 임계 아래면 빨강) 막대와 임계 눈금.
struct DiskSiloGauge: View {
    let disk: DiskStats
    let thresholdGB: Double

    var low: Bool { disk.available > 0 && disk.available < UInt64(thresholdGB * Fmt.gib) }

    var body: some View {
        MachinePlate(title: "디스크 저장고", icon: "internaldrive", heat: low ? .red : nil) {
            VStack(alignment: .leading, spacing: 4) {
                Text("여유 \(Fmt.gb(disk.available))").font(.system(size: 14, weight: .bold).monospacedDigit()).foregroundStyle(low ? Color.red : Color.primary)
                GeometryReader { proxy in
                    let total = max(1, Double(disk.total))
                    let free = Double(disk.available) / total
                    let mark = min(1, thresholdGB * Fmt.gib / total)
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.28))
                        RoundedRectangle(cornerRadius: 3).fill(low ? Color.red : Color.green)
                            .frame(width: proxy.size.width * free)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 1, height: proxy.size.height + 4)
                            .offset(x: proxy.size.width * (1 - mark))
                    }
                }
                .frame(height: 12)
                Text("전체 \(Fmt.gb(disk.total)) · 정리 가능 포함 \(Fmt.gb(disk.availableForImportantUsage))").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                Text(low ? "여유 부족 · 기준 \(Int(thresholdGB))GB" : "기준 \(Int(thresholdGB))GB 이상").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(low ? Color.red : Color.green)
            }
        }
    }
}

/// 스왑 창고: RAM에서 넘친 상자(1개 = 1GB).
struct SwapCrateGauge: View {
    let swap: SwapStats

    var heat: Color? { Double(swap.used) / Fmt.gib >= 20 ? .orange : nil }

    var body: some View {
        let boxes = Int((Double(swap.used) / Fmt.gib).rounded())
        MachinePlate(title: "스왑 창고", icon: "shippingbox", heat: heat) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Fmt.gb(swap.used)).font(.system(size: 14, weight: .bold).monospacedDigit())
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(8), spacing: 2), count: 10), alignment: .leading, spacing: 2) {
                    ForEach(0..<30, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.2)
                            .fill(index < boxes ? Color(red: 0.78, green: 0.6, blue: 0.38) : Color.primary.opacity(0.08))
                            .frame(width: 8, height: 6)
                    }
                }
                Text(boxes > 30 ? "상자 \(boxes)개 · 창고가 넘침" : "RAM에서 넘친 상자 · 1개 = 1GB").font(.system(size: 9)).foregroundStyle(heat ?? Color.secondary).lineLimit(1)
            }
        }
    }
}

enum HistoryChartKind: String, CaseIterable, Identifiable {
    /// 기록에는 사용량만 있어, 여유 = 실제 메모리 − 사용으로 그린다.
    static let physicalMemory = ProcessInfo.processInfo.physicalMemory

    case disk = "디스크 여유", swap = "스왑", memory = "메모리 여유", sessions = "세션 수"
    var id: String { rawValue }

    func value(_ point: HistoryPoint) -> Double {
        switch self {
        case .disk: Double(point.diskAvailable) / Fmt.gib
        case .swap: Double(point.swapUsed) / Fmt.gib
        case .memory: max(0, Double(HistoryChartKind.physicalMemory) - Double(point.memoryUsed)) / Fmt.gib
        case .sessions: Double(point.sessions)
        }
    }
}

struct HistoryMiniChart: View {
    let points: [HistoryPoint]
    @Binding var kind: HistoryChartKind
    var height: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("24시간").font(.system(size: 11, weight: .semibold))
                Spacer()
                Picker("", selection: $kind) { ForEach(HistoryChartKind.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.menu).labelsHidden().fixedSize().controlSize(.small)
            }
            if points.count < 2 {
                Text("1분마다 기록합니다. 잠시 뒤 그래프가 그려집니다.").font(.system(size: 10)).foregroundStyle(.secondary).frame(height: height)
            } else {
                Chart(points, id: \.time) { point in
                    AreaMark(x: .value("시각", point.time), y: .value(kind.rawValue, kind.value(point)))
                        .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("시각", point.time), y: .value(kind.rawValue, kind.value(point)))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()) } }
                .chartYAxis { AxisMarks(position: .trailing) { _ in AxisGridLine(); AxisValueLabel() } }
                .frame(height: height)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

// MARK: - 기계 상세(인스펙터) — 원인과 조치를 바로 연결한다

struct MachineDetailCard: View {
    @ObservedObject var model: AppModel
    let machine: MachineKind

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(machine.label).font(.system(size: 15, weight: .bold))
            switch machine {
            case .cpu: cpu
            case .ram: ram
            case .disk: disk
            case .swap: swap
            case .system: system
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cpu: some View {
        let busy = (model.office?.processes ?? []).sorted { $0.cpuPercent > $1.cpuPercent }.prefix(8)
        return VStack(alignment: .leading, spacing: 8) {
            CPUEngineGauge(cpu: model.system.cpuPercent, cores: model.system.coreLoads)
            Text("CPU를 많이 쓰는 프로세스").font(.system(size: 12, weight: .semibold))
            ForEach(Array(busy), id: \.key) { record in
                OwnerRow(model: model, name: record.displayName, value: String(format: "%.1f%%", record.cpuPercent), pid: record.pid)
            }
        }
    }

    private var ram: some View {
        let sessions = (model.office?.sessions ?? []).sorted { $0.footprint > $1.footprint }.prefix(5)
        let apps = (model.office?.apps ?? []).filter { $0.category != .system }.sorted { $0.footprint > $1.footprint }.prefix(5)
        let resting = (model.office?.sessions ?? []).filter { $0.state.isResting || $0.state == .orphan }
        return VStack(alignment: .leading, spacing: 8) {
            RAMTankGauge(memory: model.system.memory, pressure: model.system.pressure)
            if !resting.isEmpty {
                Button { model.releaseMany(resting, title: "쉬는 세션 모두 정리") } label: {
                    Label("쉬는 세션 \(resting.count)개 모두 정리 · 약 \(Fmt.gb(resting.reduce(0) { $0 + $1.footprint }))", systemImage: "figure.strengthtraining.traditional")
                }
                .buttonStyle(.borderedProminent)
                .help("트레이너가 들어와 쉬는 세션을 정리합니다(확인 후 SIGTERM)")
            }
            Text("메모리를 많이 쥔 에이전트(사람)").font(.system(size: 12, weight: .semibold))
            ForEach(Array(sessions)) { session in
                Button { model.selectSession(session) } label: {
                    HStack {
                        AvatarView(session: session).frame(width: 18, height: 18)
                        Text("\(session.project) · \(session.kind.shortLabel)").font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text(Fmt.size(session.footprint)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("메모리를 많이 쥔 도구(앱)").font(.system(size: 12, weight: .semibold))
            ForEach(Array(apps)) { app in
                Button { model.selectedMachine = nil; model.selectedApp = app.id } label: {
                    HStack {
                        Image(systemName: "app.dashed").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(app.name).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text(Fmt.size(app.footprint)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var disk: some View {
        let items = model.diskItems.filter { ($0.category == .regenerable || $0.category == .temporary) && CacheDeletionPolicy.blockReason(for: $0) == nil }.sorted { $0.bytes > $1.bytes }.prefix(6)
        return VStack(alignment: .leading, spacing: 8) {
            DiskSiloGauge(disk: model.system.disk, thresholdGB: model.settings.diskThresholdGB)
            HStack {
                Button("정리 화면 열기") { model.page = .cleanup }.buttonStyle(.borderedProminent)
                Button(model.diskScanning ? "살펴보는 중…" : "다시 조사") { model.scanDisk() }.disabled(model.diskScanning)
            }
            // 분류별 구성(10-25 대표 요청): 무엇이 얼마를 차지하고 지금 치울 수 있는 양은 얼마인지. 줄을 누르면 정리 화면으로.
            DiskCompositionView(rows: model.diskComposition) { tag in
                model.diskMap.path = []; model.diskMap.filter = [tag]; model.page = .diskMap
            }
            if items.isEmpty {
                Text(model.diskScannedAt == nil ? "아직 디스크를 조사하지 않았습니다." : "바로 치울 캐시·임시 파일이 거의 없습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Text("바로 치울 수 있는 것").font(.system(size: 12, weight: .semibold))
                ForEach(Array(items)) { item in
                    HStack {
                        Text((item.path as NSString).lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Fmt.gb(item.bytes)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                        Button("휴지통") { model.trash(item) }.controlSize(.small)
                    }
                }
            }
        }
    }

    private var swap: some View {
        VStack(alignment: .leading, spacing: 8) {
            SwapCrateGauge(swap: model.system.swap)
            Text("스왑은 RAM 탱크가 넘쳐 디스크로 내려 둔 상자입니다. 줄이려면 메모리를 많이 쥔 세션·앱을 닫습니다. 상자가 쌓이면 디스크 여유도 그만큼 줄어듭니다.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("RAM 탱크 보기") { model.selectMachine(.ram) }.buttonStyle(.borderedProminent)
        }
    }

    private var system: some View {
        let system = (model.office?.apps ?? []).filter { $0.category == .system }
        return VStack(alignment: .leading, spacing: 8) {
            Text("macOS 시스템 프로세스 \(system.reduce(0) { $0 + $1.pids.count })개 · \(Fmt.gb(system.reduce(0) { $0 + $1.footprint }))").font(.system(size: 12))
            Text("시스템 프로세스는 보호 대상이라 ReMON에서 종료하지 않습니다.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// 프로세스 한 줄: 세션에 속하면 그 사람으로, 앱에 속하면 그 도구로 바로 이동한다.
struct OwnerRow: View {
    @ObservedObject var model: AppModel
    let name: String
    let value: String
    let pid: Int32

    var body: some View {
        let session = model.office?.sessions.first { $0.pids.contains(pid) }
        let app = session == nil ? model.office?.apps.first { $0.pids.contains(pid) } : nil
        HStack(spacing: 6) {
            Text(name).font(.system(size: 11)).lineLimit(1)
            Spacer()
            Text(value).font(.system(size: 11, weight: .semibold).monospacedDigit())
            if let session {
                Button("사람 보기") { model.selectSession(session) }.controlSize(.small)
            } else if let app {
                Button("도구 보기") { model.selectedMachine = nil; model.selectedApp = app.id }.controlSize(.small)
            }
        }
    }
}
