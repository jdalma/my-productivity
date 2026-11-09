import Foundation
import Testing
@testable import TowerCore

@Test func aLargeOutputIsReadWholeWithoutStalling() throws {
    let start = Date()
    let r = try runCommand(["/bin/sh", "-c", "head -c 8000000 /dev/zero | tr '\\0' x; head -c 300000 /dev/zero | tr '\\0' e >&2"],
                           timeout: 20)
    #expect(r.status == 0)
    #expect(r.stdout.utf8.count == 8_000_000)
    #expect(r.stderr.utf8.count == 300_000)
    #expect(Date().timeIntervalSince(start) < 10)
}

@Test func aChildPastItsTimeoutIsKilledAndReturns() throws {
    let start = Date()
    let r = try runCommand(["/bin/sleep", "30"], timeout: 0.5)
    #expect(r.status != 0)
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func theExitStatusIsReported() throws {
    #expect(try runCommand(["/bin/sh", "-c", "exit 3"], timeout: 5).status == 3)
    #expect(try runCommand(["/bin/sh", "-c", "printf hi"], timeout: 5).stdout == "hi")
}
