import AppKit

/// How this process was started. Only a login-item launch keeps the board closed.
enum LaunchKind: String, Equatable {
    case user, login

    var opensBoard: Bool { self == .user }
}

/// Reads the open-application event: a login item launch carries `keyAELaunchedAsLogInItem` in `keyAEPropData`.
/// Whether SMAppService.mainApp launches carry it is unconfirmed; `launch.log` records the raw event to check.
func launchKind(_ event: NSAppleEventDescriptor?) -> LaunchKind {
    guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEOpenApplication),
          event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    else { return .user }
    return .login
}

/// `log` plus `line`, cut to the last `keep` lines.
func appendLine(_ log: String, _ line: String, keep: Int) -> String {
    let lines = log.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) + [line]
    return lines.suffix(keep).map { $0 + "\n" }.joined()
}

/// Owns the collection loop so launch and reopen can ask for the board.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let tower = Tower()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let kind = launchKind(event)
        writeLaunchLog("launch kind=\(kind.rawValue) event=\(event.map { "\($0)" } ?? "none")")
        if kind.opensBoard { tower.boardOpenRequested = true }
    }

    /// Opening the app again while it runs (Spotlight, Finder, `open`) brings the board forward; no second instance.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        writeLaunchLog("reopen")
        tower.boardOpenRequested = true
        return false
    }
}

/// `~/Library/Logs/ControlTower/launch.log`, the last 20 lines: evidence for how login launches arrive.
private func writeLaunchLog(_ entry: String) {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/ControlTower")
    let file = dir.appending(path: "launch.log")
    let line = "\(Date().formatted(.iso8601)) \(entry.replacingOccurrences(of: "\n", with: " "))"
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    try? appendLine(old, line, keep: 20).write(to: file, atomically: true, encoding: .utf8)
}
