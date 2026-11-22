import Foundation
import Testing
@testable import TowerApp
import TowerTestSupport

/// A child that writes more stderr than a pipe buffer (64 KB) must not stall the runner.
@Test(.timeLimit(.minutes(1))) func largeStderrDoesNotHang() async {
    do {
        try await FocusRunner.run([["perl", "-e", "print STDERR 'x' x 200000; exit 1"]])
        Issue.record("expected failure")
    } catch let e as CommandError {
        #expect(e.output.count == 200000)
    } catch {
        Issue.record("unexpected \(error)")
    }
}

/// A program that cannot launch throws instead of leaving the stderr drain waiting.
@Test(.timeLimit(.minutes(1))) func unlaunchableProgramThrows() async {
    await #expect(throws: (any Error).self) {
        try await FocusRunner.run([["no-such-program-control-tower"]])
    }
}

/// T223: the timeout fires while every GCD worker is blocked. A timer on a global queue waited for a worker to come back:
/// a 1 s timeout took 27 s on CI. The workers are let go after 20 s, so 20 s is what the old timer took here.
@Test func theTimeoutFiresWhileEveryGCDWorkerIsBlocked() async throws {
    let release = blockEveryGCDWorker()
    defer { release() }
    let start = Date()
    await #expect(throws: CommandError.self) { try await FocusRunner.run([["/bin/sleep", "300"]], timeout: 1, dryRun: nil) }
    let took = Date().timeIntervalSince(start)
    #expect(took < 10, "returned after \(took) s")
}
