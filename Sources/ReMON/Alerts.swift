import Foundation
import ReMONCore
import UserNotifications

/// 경보 알림(사양 6장). 권한은 첫 경보 때 한 번 묻는다. 거절해도 메뉴 막대 표시와 사건 기록은 남는다.
enum Alerts {
    private static var requested = false

    static func post(_ alert: ReMONAlert) {
        // 번들 없이 실행한 개발용 바이너리에서는 알림 센터를 쓸 수 없다(예외로 종료됨).
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.causes.isEmpty ? alert.body : alert.body + "\n원인 후보: " + alert.causes.joined(separator: " · ")
            content.sound = .default
            center.add(UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil))
        }
        if requested {
            send()
        } else {
            requested = true
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { send() } }
        }
    }

    /// 설정 도우미: 지금 알림 권한(메인 스레드로 돌려준다). 번들 없는 개발용 실행이면 nil.
    static func authorizationStatus(_ done: @escaping (UNAuthorizationStatus?) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { DispatchQueue.main.async { done(nil) }; return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            DispatchQueue.main.async { done(status) }
        }
    }

    /// 설정 도우미의 '알림 허용 요청' 버튼. 이미 정한 사용자에게는 시스템이 다시 묻지 않는다.
    static func requestAuthorization(_ done: @escaping (Bool) -> Void) {
        guard Bundle.main.bundleIdentifier != nil else { DispatchQueue.main.async { done(false) }; return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }
}
