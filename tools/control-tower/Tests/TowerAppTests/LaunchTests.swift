import AppKit
import Foundation
import Testing
@testable import TowerApp

private func openApp(prop: OSType?) -> NSAppleEventDescriptor {
    let e = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                   targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                   transactionID: AETransactionID(kAnyTransactionID))
    if let prop { e.setParam(NSAppleEventDescriptor(enumCode: prop), forKeyword: AEKeyword(keyAEPropData)) }
    return e
}

@Test func aLoginItemOpenEventIsALoginLaunch() {
    #expect(launchKind(openApp(prop: OSType(keyAELaunchedAsLogInItem))) == .login)
}

@Test func anyOtherLaunchIsTheUsers() {
    #expect(launchKind(nil) == .user)
    #expect(launchKind(openApp(prop: nil)) == .user)
    #expect(launchKind(openApp(prop: OSType(keyAELaunchedAsServiceItem))) == .user)
    let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                        targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                        transactionID: AETransactionID(kAnyTransactionID))
    #expect(launchKind(reopen) == .user)
}

@Test func onlyALoginLaunchLeavesTheBoardClosed() {
    #expect(LaunchKind.user.opensBoard)
    #expect(!LaunchKind.login.opensBoard)
}

@Test func theLaunchLogKeepsTheLastLines() {
    let lines = (0..<25).map { "line \($0)" }
    let log = lines.reduce("") { appendLine($0, $1, keep: 20) }
    #expect(log == (5..<25).map { "line \($0)\n" }.joined())
    #expect(appendLine("", "a", keep: 20) == "a\n")
}
