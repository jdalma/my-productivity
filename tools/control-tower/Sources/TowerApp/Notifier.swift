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
    /// A decision notification's click: its team and decision id (T147).
    private let onDecision: (String, String) -> Void
    /// Under `TOWER_DRY_RUN` a notification is a line in that file (T96).
    private let dryRun: String?
    /// UNUserNotificationCenter throws outside an app bundle (`swift run`), so it stays nil there, and under a dry run.
    let center: UNUserNotificationCenter?

    init(onClick: @escaping (String) -> Void, onDecision: @escaping (String, String) -> Void = { _, _ in },
         dryRun: String? = towerDryRun) {
        self.onClick = onClick
        self.onDecision = onDecision
        self.dryRun = dryRun
        center = dryRun != nil || Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
        super.init()
        center?.delegate = self
        center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ session: Session, title: String) {
        if let dryRun { return recordDryRun("notify \(title): \(session.lastAssistant)", to: dryRun) }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = session.lastAssistant
        content.sound = .default
        content.userInfo = ["handle": session.handle]
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A decision now waiting for the user (T147); clicking it opens the team's task board on it.
    func post(_ w: WaitingDecision) {
        let title = "\(w.team) · 결정 대기"
        let body = decisionQuestion(w.decision)
        if let dryRun { return recordDryRun("notify \(title): \(body) [\(w.decision.id)]", to: dryRun) }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["team": w.team, "decision": w.decision.id]
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// A failure with no board window to show it; a click on it does nothing.
    func post(_ failure: Failure) {
        if let dryRun { return recordDryRun("notify \(failure.title): \(failure.reason)", to: dryRun) }
        let content = UNMutableNotificationContent()
        content.title = failure.title
        content.body = failure.reason
        center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        if let team = info["team"] as? String, let id = info["decision"] as? String {
            return await MainActor.run { onDecision(team, id) }
        }
        guard let handle = info["handle"] as? String else { return }
        await MainActor.run { onClick(handle) }
    }

    /// Show the banner even while the board window is frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}
