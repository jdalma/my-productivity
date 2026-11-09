import Testing
@testable import TowerApp

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
