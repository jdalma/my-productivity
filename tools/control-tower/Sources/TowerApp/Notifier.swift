import Foundation
import TowerCore
import UserNotifications

/// Sessions that were on the previous board with my_turn false and are my_turn now.
/// The first snapshot (`prev == nil`) yields nothing, and a session that appears
/// already waiting is new rather than a transition.
func newlyMyTurn(prev: Board?, next: Board) -> [Session] {
    guard let prev else { return [] }
    let was = Dictionary(sessions(prev).map { ($0.handle, $0.myTurn) }, uniquingKeysWith: { a, _ in a })
    return sessions(next).filter { $0.myTurn && was[$0.handle] == false }
}

/// Posts one notification per my_turn transition; clicking one focuses that session.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let onClick: (String) -> Void
    /// UNUserNotificationCenter throws outside an app bundle (`swift run`), so it stays nil there.
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()

    init(onClick: @escaping (String) -> Void) {
        self.onClick = onClick
        super.init()
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ session: Session, title: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = session.lastAssistant
        content.sound = .default
        content.userInfo = ["handle": session.handle]
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let handle = response.notification.request.content.userInfo["handle"] as? String else { return }
        await MainActor.run { onClick(handle) }
    }

    /// Show the banner even while the board window is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
