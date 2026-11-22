import Foundation
import os
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
/// T228: the child's death is timed on a thread of its own, which lets the workers go at once. Timing `run`'s return
/// instead also timed the wait for a cooperative thread, and tests blocked on GCD held them all: 19 s on CI.
@Test func theTimeoutFiresWhileEveryGCDWorkerIsBlocked() async throws {
    let pidFile = FileManager.default.temporaryDirectory.appending(path: "t228-\(UUID().uuidString)").path
    defer { try? FileManager.default.removeItem(atPath: pidFile) }
    let release = await blockEveryGCDWorker()
    defer { release() }
    let start = Date()
    let died = OSAllocatedUnfairLock<Date?>(initialState: nil), watched = DispatchSemaphore(value: 0)
    Thread {
        var pid: pid_t = 0
        while pid == 0, Date().timeIntervalSince(start) < 30 {
            pid = (try? String(contentsOfFile: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            Thread.sleep(forTimeInterval: 0.01)
        }
        while pid != 0, kill(pid, 0) == 0, Date().timeIntervalSince(start) < 30 { Thread.sleep(forTimeInterval: 0.01) }
        died.withLock { $0 = Date() }
        release()
        watched.signal()
    }.start()
    await #expect(throws: CommandError.self) {
        try await FocusRunner.run([["/bin/sh", "-c", "echo $$ > \(pidFile); exec /bin/sleep 300"]], timeout: 1, dryRun: nil)
    }
    await withCheckedContinuation { c in Thread { watched.wait(); c.resume() }.start() }
    let took = died.withLock { $0 }.map { $0.timeIntervalSince(start) } ?? .infinity
    #expect(took < 10, "the child died after \(took) s")
}
