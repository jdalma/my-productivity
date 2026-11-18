import AppKit
import Testing
@testable import TowerApp

@MainActor private func window(_ behavior: NSWindow.CollectionBehavior = []) -> NSWindow {
    let w = NSWindow(contentRect: .init(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
    w.collectionBehavior = behavior
    return w
}

private let dryRun = ["TOWER_DRY_RUN": "/t/actions.log"]
private let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
private let visible = CGRect(x: 0, y: 70, width: 1728, height: 1014)

@Test func onlyADryRunIsATestInstance() {
    #expect(TestInstanceWindows(env: [:]) == nil)
    #expect(TestInstanceWindows(env: ["CT_TEST_ORIGIN": "40,40"]) == nil, "the origin alone changes nothing")
    #expect(TestInstanceWindows(env: ["TOWER_DRY_RUN": ""]) == nil)
    #expect(TestInstanceWindows(env: dryRun) != nil)
}

@Test func theOriginIsReadFromTheEnvironmentOrLeftToTheCorner() {
    #expect(TestInstanceWindows(env: dryRun)?.spot == .bottomRightCorner)
    #expect(TestInstanceWindows(env: dryRun.merging(["CT_TEST_ORIGIN": "40,60"]) { $1 })?.spot == .topLeftFromScreenTopLeft(CGPoint(x: 40, y: 60)))
    for bad in ["", "40", "40,", "a,b", "1,2,3"] {
        #expect(TestInstanceWindows(env: dryRun.merging(["CT_TEST_ORIGIN": bad]) { $1 })?.spot == .bottomRightCorner, "\(bad)")
    }
}

@Test func aTestWindowJoinsEverySpaceAndSitsBesideAFullScreenWindow() throws {
    let t = try #require(TestInstanceWindows(env: dryRun))
    #expect(t.behavior([]) == [.canJoinAllSpaces, .fullScreenAuxiliary])
    #expect(t.behavior([.primary, .fullScreenPrimary, .managed]) == [.primary, .managed, .canJoinAllSpaces, .fullScreenAuxiliary])
    #expect(t.behavior([.moveToActiveSpace, .fullScreenNone]) == [.canJoinAllSpaces, .fullScreenAuxiliary])
}

@Test func aTestWindowOpensInTheBottomRightCornerOrWhereTheOriginSays() throws {
    let size = CGSize(width: 1200, height: 760)
    let corner = try #require(TestInstanceWindows(env: dryRun))
    #expect(corner.appKitFrameOrigin(size: size, screen: screen, visible: visible) == CGPoint(x: 528, y: 70))
    let placed = try #require(TestInstanceWindows(env: dryRun.merging(["CT_TEST_ORIGIN": "40,60"]) { $1 }))
    #expect(placed.appKitFrameOrigin(size: size, screen: screen, visible: visible) == CGPoint(x: 40, y: 1117 - 60 - 760))
}

@MainActor @Test func theProbeKeepsTheBehaviorOnATestInstancesWindowThroughLaterWrites() {
    let w = window([.fullScreenPrimary, .primary])
    w.contentView = TestWindowPlacement(windows: TestInstanceWindows(env: dryRun)).makeProbe()
    #expect(w.collectionBehavior == [.primary, .canJoinAllSpaces, .fullScreenAuxiliary])
    w.collectionBehavior = [.auxiliary, .fullScreenNone]
    #expect(w.collectionBehavior == [.auxiliary, .canJoinAllSpaces, .fullScreenAuxiliary])
    #expect(!w.isVisible)
}

@MainActor @Test func outsideATestInstanceTheProbeLeavesTheWindowAsItIs() {
    let w = window([.fullScreenPrimary, .primary])
    w.contentView = TestWindowPlacement(windows: nil).makeProbe()
    #expect(w.collectionBehavior == [.fullScreenPrimary, .primary])
    w.collectionBehavior = [.fullScreenNone]
    #expect(w.collectionBehavior == [.fullScreenNone])
}

@Test func aTestInstanceStaysAnAccessoryWhateverIsOpen() {
    #expect(OpenWindows.applied(.regular, test: true) == .accessory)
    #expect(OpenWindows.applied(.accessory, test: true) == .accessory)
    #expect(OpenWindows.applied(.regular, test: false) == .regular)
    #expect(OpenWindows.applied(.accessory, test: false) == .accessory)
}

@Test func aTestWindowIsUnderTheDesktopPictureUnlessAskedToShow() throws {
    let hidden = try #require(TestInstanceWindows(env: dryRun))
    #expect(hidden.hiddenLevel == NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow))))
    let pictureLevel = Int(CGWindowLevelForKey(.desktopWindow)) - 1
    #expect(try #require(hidden.hiddenLevel).rawValue < pictureLevel)
    #expect(TestInstanceWindows(env: dryRun.merging(["CT_TEST_VISIBLE": "1"]) { $1 })?.hiddenLevel == nil)
    for other in ["", "0", "yes"] {
        #expect(TestInstanceWindows(env: dryRun.merging(["CT_TEST_VISIBLE": other]) { $1 })?.hiddenLevel != nil, "\(other)")
    }
}

@MainActor @Test func theProbePutsATestInstancesWindowUnderTheDesktopPicture() throws {
    let w = window()
    w.contentView = TestWindowPlacement(windows: TestInstanceWindows(env: dryRun)).makeProbe()
    #expect(w.level.rawValue == Int(CGWindowLevelForKey(.minimumWindow)))

    let shown = window()
    shown.contentView = TestWindowPlacement(windows: TestInstanceWindows(env: dryRun.merging(["CT_TEST_VISIBLE": "1"]) { $1 })).makeProbe()
    #expect(shown.level == .normal)

    let installed = window()
    installed.contentView = TestWindowPlacement(windows: nil).makeProbe()
    #expect(installed.level == .normal)
}
