import AppKit
import Testing
@testable import TowerApp

// The test instance's clipboard (T97, R22 L1). These tests never write the user's general pasteboard: they compare
// its change count and identity only, and write named pasteboards they release afterwards.

@MainActor @Test func aDryRunCopiesToTheTestInstancesOwnPasteboard() {
    let general = NSPasteboard.general.changeCount
    let test = appPasteboard(dryRun: "/t/actions.log")
    defer { test.releaseGlobally() }
    #expect(test.name == testInstancePasteboard())
    #expect(test !== NSPasteboard.general)
    copy("T1 fixture", to: test)
    #expect(test.string(forType: .string) == "T1 fixture")
    #expect(NSPasteboard.general.changeCount == general, "the user's clipboard is not touched")
}

@Test func eachTestBundleHasItsOwnPasteboard() {
    let a = testInstancePasteboard(bundleID: "local.control-tower.test-alpha")
    let b = testInstancePasteboard(bundleID: "local.control-tower.test-beta")
    #expect(a.rawValue == "local.control-tower.test-alpha.pasteboard")
    #expect(a != b)
    #expect(testInstancePasteboard(bundleID: nil).rawValue == "local.control-tower.test.pasteboard")
}

@MainActor @Test func withoutADryRunTheAppUsesTheSystemPasteboard() {
    #expect(appPasteboard(dryRun: nil) === NSPasteboard.general)
}

/// What `copy` does to whichever pasteboard it is given: the text alone, replacing what was there.
@MainActor @Test func aCopyReplacesThePasteboardsContents() {
    let p = NSPasteboard(name: .init("local.control-tower.tests.\(UUID().uuidString)"))
    defer { p.releaseGlobally() }
    p.clearContents()
    p.setData(Data([1]), forType: .png)
    copy("one", to: p)
    #expect(p.string(forType: .string) == "one")
    #expect(p.data(forType: .png) == nil)
}
