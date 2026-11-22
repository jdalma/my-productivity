import Foundation
import Testing
@testable import TowerCore
import TowerTestSupport

/// A stall (a full stderr pipe nobody drains) would hold the child until the timeout kills it: status 0 is the check.
@Test func aLargeOutputIsReadWholeWithoutStalling() throws {
    let r = try runCommand(["/bin/sh", "-c", "head -c 8000000 /dev/zero | tr '\\0' x; head -c 300000 /dev/zero | tr '\\0' e >&2"],
                           timeout: 120)
    #expect(r.status == 0)
    #expect(r.stdout.utf8.count == 8_000_000)
    #expect(r.stderr.utf8.count == 300_000)
}

/// Killed by the timeout's SIGTERM, and back long before the child would have ended (T130: the wall bound allows a
/// loaded run's slow start; the status says it was our kill).
@Test func aChildPastItsTimeoutIsKilledAndReturns() throws {
    let start = Date()
    let r = try runCommand(["/bin/sleep", "300"], timeout: 0.5)
    #expect(r.status == SIGTERM)
    #expect(Date().timeIntervalSince(start) < 30)
}

/// Both block every GCD worker, so they must not overlap: run side by side, one's workers held the other's job past
/// 30 s on a 3-core CI runner. `blockEveryGCDWorker` also keeps them off TowerAppTests' (T223).
@Suite(.serialized) struct EveryGCDWorkerBlocked {
    /// The timeout fires while every GCD worker is blocked (T130): it waits on a thread of its own. Here the workers are
    /// let go after 20 s; a killer on a global queue would have waited for that.
    @Test func theTimeoutFiresWhileEveryGCDWorkerIsBlocked() throws {
        let start = Date()
        let r = try Self.withEveryGCDWorkerBlocked { try runCommand(["/bin/sleep", "300"], timeout: 0.5) }
        let took = Date().timeIntervalSince(start)
        #expect(r.status == SIGTERM)
        #expect(took < 10, "returned after \(took) s")
    }

    /// Every GCD worker held while `body` runs, and let go when it returns or throws (R51 L2); after 20 s regardless.
    private static func withEveryGCDWorkerBlocked<T>(_ body: () throws -> T) rethrows -> T {
        let release = blockEveryGCDWorker()
        defer { release() }
        return try body()
    }

    /// R51 L2: a body that throws still lets the workers go: a job on a global queue runs soon after, not 20 s later.
    @Test func blockedWorkersAreLetGoWhenTheBodyThrows() throws {
        struct Thrown: Error {}
        let start = Date()
        #expect(throws: Thrown.self) { try Self.withEveryGCDWorkerBlocked { throw Thrown() } }
        let thrown = Date().timeIntervalSince(start)
        let ran = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { ran.signal() }
        let got = ran.wait(timeout: .now() + 30)
        let took = Date().timeIntervalSince(start) - thrown
        #expect(got == .success && took < 10, "threw after \(thrown) s, the job ran after \(took) s (\(got))")
    }
}

/// R51 L1: the timeout counts from before the killer's thread exists, so a thread that starts late kills on time, not
/// a whole timeout after it starts. Here it starts 5 s late with a 4 s timeout: it kills at once (about 5 s), not at 9 s.
@Test func aKillerThatStartsLateStillKillsAtTheDeadline() throws {
    let start = Date()
    let r = try runCommand(["/bin/sleep", "300"], timeout: 4, startKiller: { killer in
        Thread { Thread.sleep(forTimeInterval: 5); killer() }.start()
    })
    let took = Date().timeIntervalSince(start)
    #expect(r.status == SIGTERM)
    #expect(took < 7.5, "returned after \(took) s")
}

/// R51 L3: a child that ignores SIGTERM is killed with SIGKILL a second later, and the call returns.
@Test func aChildThatIgnoresTheTermSignalIsKilled() throws {
    let start = Date()
    // an ignored signal stays ignored across exec, so sleep itself ignores TERM. The timeout leaves the shell time to
    // set its trap even when the tests run side by side: a TERM before the trap ends the shell itself.
    let r = try runCommand(["/bin/sh", "-c", "trap '' TERM; exec /bin/sleep 300"], timeout: 3)
    #expect(r.status == SIGKILL)
    #expect(Date().timeIntervalSince(start) < 30)
}

@Test func theExitStatusIsReported() throws {
    #expect(try runCommand(["/bin/sh", "-c", "exit 3"], timeout: 5).status == 3)
    #expect(try runCommand(["/bin/sh", "-c", "printf hi"], timeout: 5).stdout == "hi")
}

/// R55 L1: the child ends at SIGTERM while a grandchild it started holds the output on: no SIGKILL follows, nor any
/// signal once the child is gone, and the call returns when the grandchild lets the output go.
@Test func noSignalFollowsAChildThatEndedWhileAGrandchildHoldsItsOutput() throws {
    final class Sent: @unchecked Sendable {
        let lock = NSLock()
        var signals: [Int32] = []
        func add(_ s: Int32) { lock.lock(); signals.append(s); lock.unlock() }
    }
    let sent = Sent()
    let start = Date()
    // the timeout leaves the shell time to start the grandchild, tests running side by side
    let r = try runCommand(["/bin/sh", "-c", "/bin/sleep 6 & exec /bin/sleep 300"], timeout: 3,
                           signal: { pid, s in sent.add(s); _ = kill(pid, s) })
    #expect(r.status == SIGTERM)
    #expect(Date().timeIntervalSince(start) >= 5.5, "returned before the grandchild let the output go")
    #expect(sent.signals == [SIGTERM])
}

/// A child that ends before its timeout, while a grandchild holds the output past it, gets no signal at all.
@Test func aChildThatEndedBeforeItsTimeoutGetsNoSignal() throws {
    final class Sent: @unchecked Sendable {
        let lock = NSLock()
        var signals: [Int32] = []
        func add(_ s: Int32) { lock.lock(); signals.append(s); lock.unlock() }
    }
    let sent = Sent()
    let r = try runCommand(["/bin/sh", "-c", "/bin/sleep 5 & exit 0"], timeout: 3, signal: { pid, s in sent.add(s); _ = kill(pid, s) })
    #expect(r.status == 0)
    #expect(sent.signals.isEmpty)
}
