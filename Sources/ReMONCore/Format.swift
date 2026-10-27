import Foundation

/// 화면 표기 규칙: 용량은 GB 소수 1자리(1024 기준, 활성 상태 보기·df -h와 같은 기준), 시간은 '3시간 전'.
public enum Fmt {
    public static let gib: Double = 1_073_741_824

    public static func gb(_ bytes: UInt64) -> String {
        String(format: "%.1fGB", Double(bytes) / gib)
    }

    public static func gb(_ bytes: Int64) -> String {
        let sign = bytes < 0 ? "-" : ""
        return sign + gb(UInt64(bytes.magnitude))
    }

    /// 1GB 미만은 MB로 보여 준다(도우미 프로세스처럼 작은 값).
    public static func size(_ bytes: UInt64) -> String {
        if Double(bytes) >= gib { return gb(bytes) }
        return String(format: "%.0fMB", Double(bytes) / 1_048_576)
    }

    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value)
    }

    public static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "기록 없음" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "방금"
        case ..<3600: return "\(Int(seconds / 60))분 전"
        case ..<86_400: return "\(Int(seconds / 3600))시간 전"
        default: return "\(Int(seconds / 86_400))일 전"
        }
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 3600 { return "\(s / 60)분" }
        if s < 86_400 { return "\(s / 3600)시간 \((s % 3600) / 60)분" }
        return "\(s / 86_400)일 \((s % 86_400) / 3600)시간"
    }
}
