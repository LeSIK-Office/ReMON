import Foundation

// 디스크 지도(10-25 대표 요청): 캐시 찌꺼기만이 아니라 구조를 들어가 보며 — 브랜치·부산물·도커·임시 파일·휴지통·스왑·큰 파일·기존 파일 —
// 무엇이 얼마를 차지하는지 보고, 정말 필요 없는 것을 골라 치울 수 있게 한다. 여기는 '계약'(타입·규칙)만 둔다. 조사기·화면은 따로.

/// 한 경로가 무엇인지(여러 개 가능). 화면의 색·기본 조치·설명이 여기서 나온다.
public enum DiskTag: String, Codable, Sendable, CaseIterable {
    case cache          // 다시 생기는 캐시(등급은 DiskCatalog)
    case regenerable    // 다시 만들 수 있음(node_modules·빌드 산출물·설치본)
    case aiTranscript   // AI 대화 기록(복구 자원 — 지우지 않음)
    case aiData         // AI 도구 데이터(옛 버전·임시 등)
    case gitByproduct   // 워크트리·브랜치·.git 묶음
    case docker         // Docker 이미지·컨테이너·볼륨·빌드 캐시·VM 디스크
    case xcode          // DerivedData·Archives·DeviceSupport·시뮬레이터
    case homebrew       // Homebrew 캐시·옛 버전
    case temp           // 임시 파일(TMPDIR·/private/var/folders)
    case trash          // 휴지통 안
    case download       // 다운로드 폴더
    case backup         // 기기 백업(MobileSync 등)
    case snapshot       // Time Machine 로컬 스냅샷
    case swap           // 스왑 파일(macOS가 관리)
    case system         // 루트 권한·macOS 영역(보기만)
    case bundle         // .app 등 번들(통째로 다룬다)
    case large          // 큰 파일(기준 이상)
    case userFile       // 사용자 파일(원본 — 자동 조치 없음)

    public var label: String {
        switch self {
        case .cache: "캐시"
        case .regenerable: "다시 만들 수 있음"
        case .aiTranscript: "AI 대화 기록"
        case .aiData: "AI 도구 데이터"
        case .gitByproduct: "git 부산물"
        case .docker: "Docker"
        case .xcode: "Xcode"
        case .homebrew: "Homebrew"
        case .temp: "임시 파일"
        case .trash: "휴지통"
        case .download: "다운로드"
        case .backup: "기기 백업"
        case .snapshot: "로컬 스냅샷"
        case .swap: "스왑"
        case .system: "시스템"
        case .bundle: "앱 번들"
        case .large: "큰 파일"
        case .userFile: "사용자 파일"
        }
    }
}

/// 어떤 조치가 허용되는가. 되돌릴 수 있는 쪽이 기본이다.
public enum DiskNodeAction: String, Codable, Sendable {
    case trash                // 휴지통으로(금고에 원래 자리 기록 → 되돌리기)
    case deletePermanently    // 영구 삭제 — 다시 생기는 캐시만(금고에 '지움' 기록)
    case prune                // 외부 도구의 정리 명령(docker/brew) — 미리보기 뒤 실행
    case reveal               // Finder에서 보기만
    case none                 // 보기만(스왑·시스템·AI 기록)
}

/// 디스크 지도의 한 칸.
public struct DiskNode: Identifiable, Sendable, Equatable {
    public var id: String { path }
    public var path: String
    public var name: String
    /// 실제 할당량(POSIX allocated blocks 합). 폴더는 아래 전부.
    public var bytes: UInt64
    public var fileCount: Int
    public var isDirectory: Bool
    public var modified: Date?
    /// nil = 아직 펼치지 않음, [] = 비어 있음.
    public var children: [DiskNode]?
    public var tags: Set<DiskTag>
    /// 사람이 읽는 설명(왜 이 태그인지 · 지우면 어떻게 되는지).
    public var hint: String?
    /// 허용 조치(가장 안전한 것부터).
    public var actions: [DiskNodeAction]
    /// 조사가 끝까지 들어가지 못함(권한·시간 제한) — 숫자가 하한일 수 있음.
    public var partial: Bool

    public init(path: String, name: String? = nil, bytes: UInt64 = 0, fileCount: Int = 0, isDirectory: Bool = true, modified: Date? = nil, children: [DiskNode]? = nil,
                tags: Set<DiskTag> = [], hint: String? = nil, actions: [DiskNodeAction] = [.reveal], partial: Bool = false) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.bytes = bytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.modified = modified
        self.children = children
        self.tags = tags
        self.hint = hint
        self.actions = actions
        self.partial = partial
    }

    /// 사용자 파일이 섞였을 수 있으면 자동 조치 금지.
    public var isSafeToDeletePermanently: Bool { actions.contains(.deletePermanently) && tags.isDisjoint(with: [.userFile, .aiTranscript, .system, .swap, .snapshot]) }
}

/// 조사기 계약: 화면은 이 프로토콜만 본다(시험·화면 미리보기는 가짜 조사기를 꽂는다).
public protocol DiskTreeSource: Sendable {
    /// 뿌리들을 한 단계 조사한다(각 뿌리의 크기·태그, 바로 아래 자식까지). budget: 전체 시간 제한(초).
    func scan(roots: [String], budget: TimeInterval) -> [DiskNode]
    /// 한 칸을 한 단계 더 펼친다(자식 크기 계산 포함).
    func expand(_ node: DiskNode, budget: TimeInterval) -> DiskNode
    /// 기준(바이트) 이상 큰 파일을 찾는다(뿌리 아래 전체, 시간 제한).
    func largeFiles(under roots: [String], minimumBytes: UInt64, budget: TimeInterval) -> [DiskNode]
    /// (10-25 더함) 묶음별 찌꺼기: 스왑 · 로컬 스냅샷 · 휴지통 · 임시 파일 · 오래된 큰 다운로드 · Docker · Xcode · Homebrew · 기기 백업 · git 부산물.
    /// 묶음 칸은 파일이 아니라 경로가 DiskNodeVirtual 꼴이다. 기본 구현은 빈 목록(가짜 조사기는 그대로 둬도 된다).
    func categories(budget: TimeInterval) -> [DiskNode]
    /// (10-25 더함) 정리한 뒤 그 경로와 위 폴더들의 크기 캐시를 버린다(다음 조사가 새로 잰다). 기본 구현은 아무것도 하지 않는다.
    func invalidate(_ path: String)
}

extension DiskTreeSource {
    public func categories(budget: TimeInterval) -> [DiskNode] { [] }
    public func invalidate(_ path: String) {}
}

/// 파일이 아닌 칸(Docker 이미지 · 로컬 스냅샷 · git 브랜치 · 묶음)의 경로. '/'로 시작하지 않아 파일 조치(휴지통 · 삭제)가 닿지 않는다
/// (SafeFileOps가 절대 경로가 아니라며 막는다). 화면은 이런 칸에 'Finder에서 보기'를 두지 않는다.
public enum DiskNodeVirtual {
    public static let scheme = "remon://"

    public static func path(_ kind: String, _ detail: String) -> String { scheme + kind + "/" + detail }

    public static func isVirtual(_ path: String) -> Bool { path.hasPrefix(scheme) }

    /// "remon://docker/images" → ("docker", "images")
    public static func parse(_ path: String) -> (kind: String, detail: String)? {
        guard path.hasPrefix(scheme) else { return nil }
        let rest = path.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/") else { return (String(rest), "") }
        return (String(rest[..<slash]), String(rest[rest.index(after: slash)...]))
    }
}

extension DiskNode {
    /// 파일이 아닌 칸(묶음 · Docker 이미지 · 스냅샷 · 브랜치).
    public var isVirtual: Bool { DiskNodeVirtual.isVirtual(path) }
}

/// 디스크 지도의 기본 뿌리: 홈의 큰 묶음과, 보기만 하는 시스템 영역.
public enum DiskTreeRoots {
    public static func defaults(home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        [home + "/DEV", home + "/Library", home + "/Downloads", home + "/Documents", home + "/Desktop", home + "/Movies", home + "/Pictures", home + "/Music",
         home + "/.Trash", home + "/.cache", home + "/.npm", home + "/.codex", home + "/.claude", home + "/.gemini", home + "/.docker", home + "/.gradle", home + "/.m2", home + "/.cargo", home + "/.rustup",
         home + "/.local", home + "/.nvm", home + "/.pyenv", home + "/.orca", home + "/orca",
         "/private/var/vm", "/private/var/folders", "/Library/Developer", "/Applications"]
            .filter { FileManager.default.fileExists(atPath: $0) }
    }
}
