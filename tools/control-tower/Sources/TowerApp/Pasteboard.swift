import AppKit
import TowerCore

/// The test instance's own clipboard (T97): copies and pastes under `TOWER_DRY_RUN` stay in it.
func testInstancePasteboard(bundleID: String? = Bundle.main.bundleIdentifier) -> NSPasteboard.Name {
    NSPasteboard.Name((bundleID ?? "local.control-tower.test") + ".pasteboard")
}

/// The clipboard the app's own copy and paste use: the system's, or under `TOWER_DRY_RUN` the test instance's, so
/// a test never replaces or reads what the user copied.
func appPasteboard(dryRun: String? = towerDryRun) -> NSPasteboard {
    dryRun == nil ? .general : NSPasteboard(name: testInstancePasteboard())
}

func copy(_ text: String, to pasteboard: NSPasteboard = appPasteboard()) {
    pasteboard.put(text)
}

extension NSPasteboard {
    /// The text alone, replacing what was there. A view whose own `copy(_:)` hides the free function calls this.
    func put(_ text: String) {
        clearContents()
        setString(text, forType: .string)
    }
}
