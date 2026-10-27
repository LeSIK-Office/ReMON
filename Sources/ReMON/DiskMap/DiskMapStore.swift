import AppKit
import Combine
import ReMONCore

// 디스크 지도 상태: 조사 결과 나무 · 들어간 경로 · 고른 칸 · 태그 필터 · 큰 파일 · 조치.
// 화면(DiskMapPage)은 이 가게만 본다. 조사기·조치 실행기는 아래 두 연결 지점(HOOK)으로 바꿔 끼운다.

// MARK: - 연결 지점(HOOK) — 실제 조사기·실제 조치 실행기는 여기만 바꾼다

@MainActor
enum DiskMapHooks {
    /// HOOK 1 · 실제 조사기 — ReMONCore의 DiskTreeScanner가 들어오면 이 줄을 `{ DiskTreeScanner() }`로 바꾼다
    /// (또는 앱 시작 때 `DiskMapHooks.makeSource = { DiskTreeScanner() }`). 지금은 가짜 홈을 돌려주는 MockDiskTreeSource.
    static var makeSource: () -> any DiskTreeSource = { DiskTreeScanner() }   // 실제 조사기(가짜는 미리보기 하네스에서만)

    /// HOOK 2 · 실제 조치 실행기 — DiskTreeActions.perform(...)이 들어오면 이 줄을 그 호출로 바꾼다. 예:
    /// `{ action, node, dryRun in DiskTreeActions.perform(action, node: node, dryRun: dryRun) }`
    /// 약속: (조치, 칸, 드라이런) → (성공, 사람이 읽는 결과 문장). 휴지통·영구 삭제·정리 명령은 실행기가 복구 금고에 기록한다.
    /// 드라이런 = 아무것도 바꾸지 않고 무엇을 할지 문장만(정리 명령은 이 문장을 '미리보기'로 먼저 보여 준다).
    static var actionRunner: DiskMapStore.ActionRunner = { action, node, dryRun in
        // 실제 조치: 금고에 먼저 적고(휴지통·영구 삭제·정리 명령), 직전에 규칙을 다시 확인한다. 열린 파일 검사는 커널 메모리 출처가 있는 사용자 프로세스 pid로.
        let pids = ProcessSampler().sample().filter { $0.memorySource == .kernel }.map(\.pid)
        let result = DiskTreeActions.perform(action, on: node, dryRun: dryRun, vault: RecoveryVault.shared, userPIDs: pids)
        return (result.ok, result.message)
    }
}

// MARK: - 가게

@MainActor
final class DiskMapStore: ObservableObject {
    /// (조치, 칸, 드라이런) → (성공, 결과 문장). 화면 밖(백그라운드)에서 부른다.
    typealias ActionRunner = @Sendable (DiskNodeAction, DiskNode, Bool) -> (ok: Bool, message: String)

    struct TagStat: Identifiable, Equatable {
        var id: DiskTag { tag }
        let tag: DiskTag
        let count: Int
        let bytes: UInt64
    }

    /// '한눈에' 한 칸: 그 태그의 합계와 할 수 있는 조치.
    struct Glance: Identifiable, Equatable {
        var id: DiskTag { tag }
        let tag: DiskTag
        let bytes: UInt64
        let count: Int
        let partial: Bool
        let actions: Set<DiskNodeAction>
        let largest: DiskNode?
    }

    /// 조사 결과 뿌리들(펼친 곳까지 자식이 들어 있다).
    @Published private(set) var roots: [DiskNode] = [] { didSet { refreshDerived() } }
    /// 들어간 경로(뿌리부터 지금 단계까지의 칸 경로). 비면 맨 위(뿌리들).
    @Published var path: [String] = [] { didSet { if path != oldValue { checked = []; refreshDerived() } } }
    /// 자세히 보는 칸(오른쪽 아래 설명판).
    @Published var selection: String? { didSet { if selection != oldValue { refreshSelection() } } }
    /// 목록에서 체크한 칸들(묶음 휴지통 — 묶음은 휴지통만, 영구 삭제는 하나씩만).
    @Published var checked: Set<String> = []
    /// 태그 필터(하나라도 맞으면 보임). 켜면 지금 단계 아래 펼친 곳 전체에서 맞는 칸을 모아 보여 준다.
    @Published var filter: Set<DiskTag> = [] { didSet { if filter != oldValue { checked = []; refreshDerived() } } }
    /// 큰 파일(뿌리 아래 전체, 시간 제한 안에서 찾은 것).
    @Published private(set) var largeFiles: [DiskNode] = [] { didSet { refreshDerived() } }
    @Published private(set) var scanning = false
    @Published private(set) var largeScanning = false
    @Published private(set) var scanStartedAt: Date?
    @Published private(set) var lastScan: Date?
    @Published private(set) var lastScanDuration: TimeInterval?
    /// 마지막 결과·안내 한 줄.
    @Published var note: String?
    /// 마우스를 올린 칸(트리맵 아래 설명 줄).
    @Published var hovered: String?
    /// 지금 펼치는 중인 칸들.
    @Published private(set) var expanding: Set<String> = []
    /// 조치가 도는 중인 칸들(버튼 잠금).
    @Published private(set) var busy: Set<String> = []

    // 파생 값(나무·경로·필터가 바뀔 때만 다시 계산 — 마우스 이동마다 다시 세지 않게).
    @Published private(set) var currentNode: DiskNode?
    @Published private(set) var levelItems: [DiskNode] = []
    @Published private(set) var displayed: [DiskMapItem] = []
    @Published private(set) var tagStats: [TagStat] = []
    @Published private(set) var glances: [Glance] = []
    @Published private(set) var selectedNode: DiskNode?

    let source: any DiskTreeSource
    let actionRunner: ActionRunner
    /// 가짜 조사기로 그리는 중(화면에 '가짜 데이터' 띠를 띄운다 — 은유가 사실을 넘지 않게).
    let isMockSource: Bool
    var rootPaths: [String]
    /// 전체 조사 시간 제한(초): 뿌리 조사 50% · 큰 폴더 미리 펼치기 20% · 큰 파일 나머지.
    var scanBudget: TimeInterval = 30
    /// 한 칸 펼치기 시간 제한(초).
    var expandBudget: TimeInterval = 10
    /// 큰 파일 기준(바이트).
    var largeFileMinimum: UInt64 = 1 << 30
    /// 조사 직후 미리 펼칠 칸 수(뿌리 바로 아래의 큰 폴더 — 태그 칸 먼저). 트리맵 안쪽 칸·한눈에·필터가 바로 쓸모 있게.
    var prefetchLimit = 12
    /// 폴더에 들어간 뒤 미리 펼칠 자식 수와 시간(초). 안쪽 칸(구조)과 태그 개수가 바로 보이게 — 새로 들어가면 멈춘다.
    var lookAheadLimit = 6
    var lookAheadBudget: TimeInterval = 6
    /// 확인 창(제목, 본문, 실행 버튼, 파괴적). 기본은 앱 공통 Confirm.ask — 시험·미리보기에서 바꿔 끼운다.
    var confirm: (String, String, String, Bool) -> Bool = { Confirm.ask(title: $0, text: $1, action: $2, destructive: $3) }
    var inform: (String, String) -> Void = { Confirm.info(title: $0, text: $1) }
    /// 드라이런 여부. 기본은 앱 설정(Settings.dryRun이 UserDefaults "dryRun"에 저장)을 그대로 읽는다.
    var dryRun: () -> Bool = { UserDefaults.standard.bool(forKey: "dryRun") }
    /// 조치 결과를 앱 사건 기록에 남기고 싶을 때(선택): 예) `store.onActionLog = { model.append(.cleanup, $0) }`.
    var onActionLog: ((String) -> Void)?
    /// 사무실 연출 연결: 조치가 시작될 때(실측 기준점) · 실제로 끝났을 때(성공한 칸들만, 드라이런 제외).
    var onActionsStarted: ((DiskNodeAction, [DiskNode]) -> Void)?
    var onActionsPerformed: ((DiskNodeAction, [DiskNode]) -> Void)?

    /// '한눈에' 띠에 보이는 묶음(순서 고정).
    static let glanceTags: [DiskTag] = [.docker, .xcode, .homebrew, .temp, .trash, .swap, .snapshot]
    /// 미리 펼칠 때 먼저 고르는 태그.
    nonisolated static let prefetchTags: Set<DiskTag> = [.cache, .xcode, .docker, .homebrew, .temp, .trash, .gitByproduct]
    /// 미리 펼치지 않는 칸(보기만·번들 — 안쪽이 쓸모없거나 비싸다).
    nonisolated static let noPrefetchTags: Set<DiskTag> = [.system, .aiTranscript, .bundle, .snapshot, .swap]

    init(source: (any DiskTreeSource)? = nil, actionRunner: ActionRunner? = nil, rootPaths: [String]? = nil) {
        let resolved = source ?? DiskMapHooks.makeSource()
        self.source = resolved
        self.actionRunner = actionRunner ?? DiskMapHooks.actionRunner
        self.isMockSource = resolved is MockDiskTreeSource
        self.rootPaths = rootPaths ?? DiskTreeRoots.defaults()
    }

    // MARK: 지금 단계

    var levelTotal: UInt64 { displayed.reduce(0) { $0 + $1.node.bytes } + looseBytes }
    var levelPartial: Bool { displayed.contains { $0.node.partial } || (filter.isEmpty && currentNode?.partial == true) }
    var isExpandingCurrent: Bool { path.last.map { expanding.contains($0) } ?? false }

    /// 폴더 크기 − 자식 합(따로 나누지 않은 바로 아래 파일). 필터 중·맨 위에서는 0.
    var looseBytes: UInt64 {
        guard filter.isEmpty, let node = currentNode else { return 0 }
        return DiskMapTree.looseBytes(of: node)
    }

    /// 이 단계의 모든 칸에 붙은 태그(색을 고를 때 뺀다 — 모두 같은 색이면 아무것도 말하지 않으므로).
    var sharedTags: Set<DiskTag> { DiskTag.shared(by: displayed.map(\.node)) }

    /// 마우스를 올린 칸(지금 단계의 칸 또는 큰 칸 안쪽에 그린 자식 칸).
    var hoveredNode: DiskNode? {
        guard let hovered else { return nil }
        if let item = displayed.first(where: { $0.node.path == hovered }) { return item.node }
        for item in displayed { if let child = item.node.children?.first(where: { $0.path == hovered }) { return child } }
        return nil
    }

    /// 체크한 칸 중 지금 보이고 휴지통이 허용된 것(겹치면 바깥 것만).
    var checkedNodes: [DiskNode] {
        DiskMapTree.outermost(displayed.map(\.node).filter { checked.contains($0.path) && $0.actions.contains(.trash) })
    }

    func node(at path: String) -> DiskNode? {
        DiskMapTree.find(path, in: roots) ?? largeFiles.first { $0.path == path }
    }

    // MARK: 이동

    /// 트리맵 칸을 눌렀을 때: 폴더는 들어가고 파일은 고른다.
    func activate(_ node: DiskNode) {
        if node.isDirectory { drillDown(node) } else { select(node) }
    }

    func select(_ node: DiskNode?) { selection = node?.path }

    /// 폴더 안으로 들어간다(필터 결과에서 들어가면 필터를 끈다 — 들어간 폴더의 전부를 보도록). 들어간 폴더를 자세히 보기로 고른다.
    func drillDown(_ node: DiskNode) {
        guard node.isDirectory else { select(node); return }
        guard let chain = DiskMapTree.chain(to: node.path, in: roots) else { locate(node.path); return }
        filter = []
        path = chain
        selection = node.path
        launch {
            await self.expand(node.path)
            await self.lookAhead(under: node.path)
        }
    }

    /// 빵 부스러기: depth 0 = 맨 위.
    func go(toDepth depth: Int) {
        let target = Array(path.prefix(max(0, depth)))
        path = target
        selection = target.last
    }

    func goUp() { go(toDepth: path.count - 1) }

    func toggleFilter(_ tag: DiskTag) {
        if filter.contains(tag) { filter.remove(tag) } else { filter.insert(tag) }
    }

    /// '한눈에' 칸: 맨 위에서 그 태그만 모아 보고, 가장 큰 칸을 자세히 본다.
    func focus(_ glance: Glance) {
        path = []
        filter = [glance.tag]
        selection = glance.largest?.path
    }

    /// 나무 밖(아직 펼치지 않은 곳)의 칸까지 찾아 들어간다: 뿌리부터 차례로 펼치며 부모 단계로 가서 그 칸을 고른다.
    func locate(_ target: String) {
        launch {
            if let chain = DiskMapTree.chain(to: target, in: self.roots) {
                self.filter = []
                self.path = Array(chain.dropLast())
                self.selection = target
                return
            }
            guard let root = self.roots.first(where: { $0.path == target || DiskMapTree.isAncestor($0.path, of: target) }) else {
                self.selection = target
                return
            }
            if root.path == target {
                self.filter = []; self.path = []; self.selection = target
                return
            }
            var chain = [root.path]
            var current = root.path
            for component in target.dropFirst(root.path.count).split(separator: "/").dropLast() {
                current += "/" + component
                chain.append(current)
            }
            var reached: [String] = []
            for step in chain {
                await self.expand(step)
                guard DiskMapTree.find(step, in: self.roots) != nil else { break }
                reached.append(step)
            }
            self.filter = []
            self.path = reached
            self.selection = target
            if let level = reached.last { await self.lookAhead(under: level) }
        }
    }

    // MARK: 조사

    func scanIfNeeded() {
        if lastScan == nil && !scanning { rescan() }
    }

    /// 다시 조사: 백그라운드에서 뿌리 조사 → 큰 폴더 미리 펼치기 → (나무를 먼저 보여 주고) 큰 파일. 들어간 경로는 유지한다.
    func rescan() {
        guard !scanning else { return }
        scanning = true
        largeScanning = true
        let started = Date()
        scanStartedAt = started
        note = nil
        let source = source, roots = rootPaths, budget = scanBudget, minimum = largeFileMinimum, limit = prefetchLimit
        Task.detached(priority: .utility) { [weak self] in
            let deadline = started.addingTimeInterval(budget)
            var nodes = source.scan(roots: roots, budget: budget * 0.5)
            nodes = Self.prefetch(nodes, source: source, limit: limit, until: started.addingTimeInterval(budget * 0.7))
            await self?.finishTree(nodes)
            let large = source.largeFiles(under: roots, minimumBytes: minimum, budget: max(1, deadline.timeIntervalSinceNow))
            await self?.finishLarge(large, started: started)
        }
    }

    /// 뿌리 바로 아래의 큰 폴더 몇 개를 한 단계 더 펼친다(태그 칸 먼저, 시간 제한 안에서).
    nonisolated static func prefetch(_ nodes: [DiskNode], source: any DiskTreeSource, limit: Int, until deadline: Date) -> [DiskNode] {
        var result = nodes
        var candidates: [(root: Int, child: Int, score: Double)] = []
        for (rootIndex, root) in nodes.enumerated() {
            for (childIndex, child) in (root.children ?? []).enumerated()
            where child.isDirectory && child.children == nil && child.bytes > 0 && child.tags.isDisjoint(with: noPrefetchTags) {
                let tagged = !child.tags.isDisjoint(with: prefetchTags)
                candidates.append((rootIndex, childIndex, Double(child.bytes) * (tagged ? 2 : 1)))
            }
        }
        for candidate in candidates.sorted(by: { $0.score > $1.score }).prefix(limit) {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0.2, let child = result[candidate.root].children?[candidate.child] else { break }
            let expanded = source.expand(child, budget: remaining)
            result[candidate.root].children?[candidate.child] = DiskMapTree.merge(old: child, new: expanded)
        }
        return result
    }

    private func finishTree(_ nodes: [DiskNode]) {
        var old: [String: DiskNode] = [:]
        for root in roots where old[root.path] == nil { old[root.path] = root }
        roots = nodes.map { DiskMapTree.merge(old: old[$0.path], new: $0) }
        validateNavigation()
        // 조사는 뿌리 + 한 단계까지 새로 센다. 그보다 깊이 들어가 있으면 지금 단계를 새로 센다.
        if path.count >= 2, let current = path.last { launch { await self.expand(current, force: true) } }
    }

    private func finishLarge(_ files: [DiskNode], started: Date) {
        largeFiles = DiskMapTree.sortedBySize(files)
        largeScanning = false
        scanning = false
        lastScan = Date()
        lastScanDuration = Date().timeIntervalSince(started)
        validateNavigation()
    }

    /// 한 칸을 펼친다(이미 펼쳤으면 그대로, force면 새로 센다). 백그라운드에서 조사기를 부르고 끝날 때까지 기다린다.
    func expand(_ path: String, force: Bool = false, budget: TimeInterval? = nil, priority: TaskPriority = .userInitiated) async {
        guard let node = DiskMapTree.find(path, in: roots), node.isDirectory else { return }
        if !force && node.children != nil { return }
        if expanding.contains(path) {
            while expanding.contains(path) { try? await Task.sleep(nanoseconds: 50_000_000) }
            return
        }
        expanding.insert(path)
        let source = source, budget = budget ?? expandBudget
        let expanded = await Task.detached(priority: priority) { source.expand(node, budget: budget) }.value
        expanding.remove(path)
        DiskMapTree.replace(path, in: &roots) { current in current = DiskMapTree.merge(old: current, new: expanded) }
        validateNavigation()
    }

    private var lookAheadGeneration = 0

    /// 들어간 폴더의 큰 자식 몇 개를 한 단계 더 펼친다(트리맵 안쪽 칸·태그 개수용). 다른 곳으로 들어가면 멈춘다.
    private func lookAhead(under path: String) async {
        lookAheadGeneration += 1
        let generation = lookAheadGeneration
        guard let node = DiskMapTree.find(path, in: roots), let children = node.children else { return }
        let candidates = DiskMapTree.sortedBySize(children.filter { $0.isDirectory && $0.children == nil && $0.bytes > 0 && $0.tags.isDisjoint(with: Self.noPrefetchTags) })
        let deadline = Date().addingTimeInterval(lookAheadBudget)
        for child in candidates.prefix(lookAheadLimit) {
            let remaining = deadline.timeIntervalSinceNow
            guard generation == lookAheadGeneration, remaining > 0.2 else { return }
            await expand(child.path, budget: min(expandBudget, remaining), priority: .utility)
        }
    }

    /// 나무가 바뀐 뒤: 사라진 단계·선택·체크를 정리한다(경로는 남아 있는 가장 깊은 곳까지 유지).
    private func validateNavigation() {
        var valid: [String] = []
        for step in path {
            guard DiskMapTree.find(step, in: roots) != nil else { break }
            valid.append(step)
        }
        if valid != path { path = valid }
        if let selection, node(at: selection) == nil { self.selection = path.last }
        let existing = checked.filter { DiskMapTree.find($0, in: roots) != nil }
        if existing != checked { checked = existing }
        refreshSelection()
    }

    // MARK: 파생 값

    private func refreshDerived() {
        let current = path.last.flatMap { DiskMapTree.find($0, in: roots) }
        currentNode = current
        let level = path.isEmpty ? roots : (current?.children ?? [])
        levelItems = DiskMapTree.sortedBySize(level)
        let base = path.isEmpty ? nil : path.last
        if filter.isEmpty {
            // 맨 위: 홈 바로 아래가 아닌 뿌리(/private/var/vm 등)는 이름만으로 모르니 전체 경로를 함께 보인다.
            let home = NSHomeDirectory()
            displayed = levelItems.map { node in
                let parent = (node.path as NSString).deletingLastPathComponent
                return DiskMapItem(node: node, context: path.isEmpty && parent != home ? DiskMapFormat.home(node.path) : nil)
            }
        } else {
            let found = DiskMapTree.matches(in: level, under: base, largeFiles: largeFiles, tags: filter)
            displayed = found.sorted { $0.node.bytes > $1.node.bytes }
        }
        tagStats = DiskTag.allCases.compactMap { tag -> TagStat? in
            let found = DiskMapTree.matches(in: level, under: base, largeFiles: largeFiles, tags: [tag])
            guard !found.isEmpty else { return nil }
            return TagStat(tag: tag, count: found.count, bytes: found.reduce(0) { $0 + $1.node.bytes })
        }
        .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.count > $1.count }
        // 조사 결과가 없으면 '한눈에'를 비운다(못 찾음과 아직 안 봄을 섞지 않게).
        glances = roots.isEmpty ? [] : Self.glanceTags.map { tag in
            // 크기는 겹치지 않게(가장 바깥 칸 + 펼치지 않은 곳의 큰 파일), 할 수 있는 조치는 안쪽 칸까지 모은다(영구 삭제는 안전한 칸만).
            let found = DiskMapTree.matches(in: roots, under: nil, largeFiles: largeFiles, tags: [tag]).map(\.node)
            var actions = Set<DiskNodeAction>()
            for node in found + DiskMapTree.allMatches(in: roots, tags: [tag]) {
                for action in node.actions where action != .deletePermanently || node.isSafeToDeletePermanently { actions.insert(action) }
            }
            return Glance(tag: tag, bytes: found.reduce(0) { $0 + $1.bytes }, count: found.count, partial: found.contains(where: \.partial),
                          actions: actions, largest: found.max { $0.bytes < $1.bytes })
        }
        refreshSelection()
    }

    private func refreshSelection() {
        let resolved = selection.flatMap { node(at: $0) }
        if resolved != selectedNode { selectedNode = resolved }
    }

    // MARK: 조치

    /// 설명판 버튼: 파괴적인 조치는 한 번 묻는다(Confirm.ask) — 모두 복구 금고에 기록한다는 문장을 함께 보여 준다.
    func perform(_ action: DiskNodeAction, on node: DiskNode) {
        guard !busy.contains(node.path) else { return }
        let size = DiskMapFormat.size(node)
        let place = DiskMapFormat.home(node.path)
        switch action {
        case .none:
            return
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: node.path)])
        case .trash:
            let dry = dryRun()
            let text = place + (node.hint.map { "\n\n" + $0 } ?? "") + "\n\n휴지통으로 옮깁니다(비우지 않음) — 휴지통에서 되돌릴 수 있습니다. 복구 금고에 기록합니다." + dryNote(dry)
            guard confirm("휴지통으로 옮길까요? · \(node.name) · \(size)", text, dry ? "드라이런" : "휴지통으로", false) else { return }
            run(.trash, on: [node], dryRun: dry)
        case .deletePermanently:
            guard node.isSafeToDeletePermanently else {
                inform("영구 삭제할 수 없는 칸입니다", "사용자 파일·AI 기록·시스템 영역이 섞였을 수 있는 칸은 영구 삭제하지 않습니다. 휴지통을 쓰세요.")
                return
            }
            let dry = dryRun()
            let text = place + (node.hint.map { "\n\n" + $0 } ?? "") +
                "\n\n되돌릴 수 없습니다 — 휴지통을 거치지 않고 지웁니다. 다시 만들어질 때(재설치·재빌드·다시 받기)만 돌아옵니다." +
                "\n복구 금고에 기록합니다('지움'으로 남김)." + dryNote(dry)
            guard confirm("영구 삭제할까요? · \(node.name) · \(size)", text, dry ? "드라이런" : "영구 삭제", !dry) else { return }
            run(.deletePermanently, on: [node], dryRun: dry)
        case .prune:
            prune(node)
        }
    }

    /// 정리 명령: 먼저 미리보기 문장(실행기의 드라이런)을 받아 보여 주고, 확인하면 실행한다.
    private func prune(_ node: DiskNode) {
        busy.insert(node.path)
        note = "정리 명령 미리보기를 준비하는 중… · \(node.name)"
        let runner = actionRunner
        launch {
            let preview = await Task.detached(priority: .userInitiated) { runner(.prune, node, true) }.value
            self.busy.remove(node.path)
            self.note = nil
            guard preview.ok else {
                self.inform("정리 명령을 준비하지 못했습니다", preview.message)
                self.note = "정리 명령 준비 실패 · \(node.name)"
                return
            }
            let dry = self.dryRun()
            let text = "미리보기\n" + preview.message + "\n\n지운 이미지·캐시는 다시 받거나 다시 빌드해야 돌아옵니다. 복구 금고에 기록합니다." + self.dryNote(dry)
            guard self.confirm("정리 명령을 실행할까요? · \(node.name)", text, dry ? "드라이런" : "실행", false) else { return }
            self.run(.prune, on: [node], dryRun: dry)
        }
    }

    /// 목록에서 체크한 것을 한꺼번에 휴지통으로(묶음은 휴지통만 — 영구 삭제는 하나씩만).
    func trashChecked() {
        let targets = checkedNodes
        guard !targets.isEmpty else { return }
        let dry = dryRun()
        let bytes = targets.reduce(UInt64(0)) { $0 + $1.bytes }
        var lines = targets.prefix(12).map { "· \($0.name) — \(DiskMapFormat.size($0))" }
        if targets.count > 12 { lines.append("… 외 \(targets.count - 12)개") }
        let text = lines.joined(separator: "\n") +
            "\n\n하나씩 휴지통으로 옮기고 복구 금고에 기록합니다(휴지통에서 되돌릴 수 있음). 여러 개를 한 번에 영구 삭제하지는 않습니다." + dryNote(dry)
        guard confirm("선택한 \(targets.count)개를 휴지통으로 옮길까요? · \(DiskMapFormat.size(bytes))", text, dry ? "드라이런" : "휴지통으로", false) else { return }
        checked = []
        run(.trash, on: targets, dryRun: dry)
    }

    private func dryNote(_ dry: Bool) -> String {
        dry ? "\n\n드라이런: 실제로 옮기거나 지우지 않고 결과만 기록합니다." : ""
    }

    private func run(_ action: DiskNodeAction, on nodes: [DiskNode], dryRun: Bool) {
        let paths = nodes.map(\.path)
        busy.formUnion(paths)
        if !dryRun { onActionsStarted?(action, nodes) }
        let runner = actionRunner
        launch {
            let results = await Task.detached(priority: .userInitiated) { nodes.map { (node: $0, result: runner(action, $0, dryRun)) } }.value
            self.busy.subtract(paths)
            self.apply(action, results: results, dryRun: dryRun)
        }
    }

    private func apply(_ action: DiskNodeAction, results: [(node: DiskNode, result: (ok: Bool, message: String))], dryRun: Bool) {
        let succeeded = results.filter(\.result.ok)
        let failed = results.filter { !$0.result.ok }
        if !dryRun, !succeeded.isEmpty { onActionsPerformed?(action, succeeded.map(\.node)) }
        if !dryRun {
            switch action {
            case .trash, .deletePermanently:
                for item in succeeded { removeNode(item.node.path) }
            case .prune:
                for item in succeeded {
                    let target = item.node.isDirectory ? item.node.path : (item.node.path as NSString).deletingLastPathComponent
                    launch { await self.expand(target, force: true) }
                }
            case .reveal, .none:
                break
            }
        }
        let bytes = succeeded.reduce(UInt64(0)) { $0 + $1.node.bytes }
        let verb = switch action {
        case .trash: "휴지통으로"
        case .deletePermanently: "영구 삭제"
        case .prune: "정리 명령"
        case .reveal, .none: "보기"
        }
        let summary: String
        if results.count == 1, let only = results.first {
            summary = only.result.message.isEmpty ? "\(verb) · \(only.node.name) · \(only.result.ok ? "완료" : "실패")" : only.result.message
        } else {
            summary = "\(verb) · \(succeeded.count)개 · \(DiskMapFormat.size(bytes))" + (failed.isEmpty ? "" : " · 실패 \(failed.count)개") + (dryRun ? " · 드라이런(기록만)" : "")
        }
        note = summary
        onActionLog?("디스크 지도 · " + summary)
        if !failed.isEmpty {
            let lines = failed.prefix(8).map { "· \($0.node.name): \($0.result.message)" }.joined(separator: "\n")
            inform(failed.count == 1 ? "하지 못했습니다" : "\(failed.count)개는 하지 못했습니다", lines)
        }
    }

    /// 휴지통·영구 삭제가 끝난 칸을 나무·큰 파일·선택에서 뺀다(조상 크기에서도 덜어낸다).
    private func removeNode(_ target: String) {
        DiskMapTree.remove(target, in: &roots)
        largeFiles.removeAll { $0.path == target || DiskMapTree.isAncestor(target, of: $0.path) }
        checked.remove(target)
        if let index = path.firstIndex(where: { $0 == target || DiskMapTree.isAncestor(target, of: $0) }) { path = Array(path.prefix(index)) }
        if let selection, selection == target || DiskMapTree.isAncestor(target, of: selection) { self.selection = path.last }
        validateNavigation()
    }

    // MARK: 비동기 일

    /// 가게가 띄운 일의 수(펼치기·찾아가기·조치). 미리보기·시험이 끝날 때까지 기다리는 데 쓴다.
    private var inflight = 0

    private func launch(_ work: @escaping @MainActor () async -> Void) {
        inflight += 1
        Task { @MainActor in
            await work()
            self.inflight -= 1
        }
    }

    /// 미리보기 하네스가 조사·펼치기·조치가 끝날 때까지 기다린다(메인 런루프를 돌린다). 앱에서는 쓰지 않는다.
    func waitUntilIdle(timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        } while (scanning || inflight > 0 || !expanding.isEmpty || !busy.isEmpty) && Date() < deadline
    }
}
