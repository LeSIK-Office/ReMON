import Darwin
import Foundation

// AI 데이터 보호 목록 — 어떤 정리로도 지우지 않는 대화 원본·첨부·자격 증명·앱 로그인 정보(G1, Mole 보호 목록을 참고해 다시 씀).
// SafeFileOps.validate가 부른다. 홈은 인자로 받아 시험에서는 가짜 홈으로 규칙만 따로 검사한다.
public enum AIDataProtection {
    /// 그 자신과 아래 전부를 막는다(홈 기준).
    public static let protectedPrefixes = [".claude/file-history", ".claude/paste-cache", ".claude/sessions", ".claude/.credentials.json",
                                           ".codex/attachments", ".codex/computer-use", ".codex/auth.json"]
    /// AI 데스크톱 앱 지원 폴더(~/Library/Application Support/<이름>).
    public static let appSupportFolders = ["Claude", "Codex", "Cursor", "Antigravity", "com.openai.chat"]
    /// 앱 안의 로그인·저장 데이터(Chromium). 이름 자체와 '-journal' 같은 짝 파일을 막는다.
    /// Local State는 쿠키·로그인 암호화 키를 품고 있어 지우면 로그인이 풀린다.
    public static let appDataNames: Set<String> = ["Local Storage", "IndexedDB", "Cookies", "Login Data", "Login Data For Account", "History", "Web Data", "Local State", "Session Storage"]

    /// 막는 이유(없으면 nil).
    /// - removal: 휴지통·영구 삭제(외장 이전은 false — 원본을 확인 뒤 링크로 남겨 되돌릴 수 있다)
    /// - allowClaudeTranscript: AI 데이터 위생이 Claude 기록 하나를 휴지통으로 옮길 때만 true
    public static func reason(for rawPath: String, home rawHome: String, removal: Bool, allowClaudeTranscript: Bool = false) -> String? {
        // APFS는 대소문자를 가리지 않는다 — 비교는 소문자로 한다(~/.Claude/File-History도 같은 폴더).
        let path = rawPath.lowercased()
        let home = (rawHome.hasSuffix("/") ? String(rawHome.dropLast()) : rawHome).lowercased()
        func under(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        for relative in protectedPrefixes where under(home + "/" + relative.lowercased()) { return "AI 대화 원본·첨부·자격 증명(~/\(relative))" }
        // Codex 상태·대화 기록 DB(state_*.sqlite · thread_history_*.sqlite …)와 짝 파일(-wal·-shm). 지우면 스레드 목록·대화가 깨진다.
        let name = (path as NSString).lastPathComponent
        if (path as NSString).deletingLastPathComponent == home + "/.codex", name.range(of: #"\.sqlite(-wal|-shm|-journal)?$"#, options: .regularExpression) != nil {
            return "Codex 상태·대화 기록 DB(\(name))"
        }
        // ~/.claude/projects: 폴더 자체·프로젝트 메모리는 늘 막고, 지우기는 위생 기능의 기록 휴지통만 허용한다.
        let projects = home + "/.claude/projects"
        if path == projects { return "Claude 기록 폴더 자체" }
        if path.hasPrefix(projects + "/") {
            let parts = path.dropFirst(projects.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2, parts[1] == "memory" { return "Claude 프로젝트 메모리" }
            if removal, !(allowClaudeTranscript && parts.count == 2 && ClaudeTranscriptName.isTranscriptEntry(parts[1])) {
                return "Claude 기록은 AI 데이터 위생에서 기록 하나씩만 휴지통으로 옮깁니다"
            }
        }
        // AI 앱의 로그인·저장 데이터: 앱 폴더 자체 · 보호 이름 · 그것을 담은 프로필 폴더(Default·Partitions …)
        let support = home + "/library/application support"
        for folder in appSupportFolders {
            let root = support + "/" + folder.lowercased()
            guard under(root) else { continue }
            if path == root { return "\(folder) 앱 데이터 폴더 자체" }
            let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
            if parts.contains(where: isAppData) { return "\(folder) 로그인·저장 데이터" }
            if AIAppCacheCatalog.containsCacheFolder(parts) { return nil }
            if containsAppData(rawPath, depth: 3) { return "\(folder) 로그인·저장 데이터를 담은 폴더" }
        }
        return nil
    }

    static func isAppData(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return appDataNames.contains { lowered == $0.lowercased() || lowered.hasPrefix($0.lowercased() + "-") }
    }

    /// 아래 depth 단계 안에 보호 데이터가 있는 폴더인가(링크는 따라가지 않는다).
    static func containsAppData(_ path: String, depth: Int) -> Bool {
        guard depth > 0, let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        for name in names {
            if isAppData(name) { return true }
            var info = stat()
            let child = path + "/" + name
            if lstat(child, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, containsAppData(child, depth: depth - 1) { return true }
        }
        return false
    }
}
