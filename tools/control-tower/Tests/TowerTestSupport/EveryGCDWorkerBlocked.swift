import Foundation
import os

/// One holder at a time in the whole test process: both test targets run in one, side by side, and two holders'
/// workers held each other's GCD jobs past 30 s on a 3-core CI runner. A suite's `.serialized` covers one suite only.
/// The next holder waits suspended, not blocked: a blocked waiter took a cooperative thread from the holder, whose
/// async test then resumed only when its workers were let go, 20 s later (T228, R19 L2).
private let holder = OSAllocatedUnfairLock(initialState: (held: false, waiting: [CheckedContinuation<Void, Never>]()))

private func takeHolder() async {
    await withCheckedContinuation { c in
        let free = holder.withLock { h -> Bool in
            if h.held { h.waiting.append(c); return false }
            h.held = true
            return true
        }
        if free { c.resume() }
    }
}

private func passHolder() {
    let next = holder.withLock { h in
        if h.waiting.isEmpty { h.held = false; return nil as CheckedContinuation<Void, Never>? }
        return h.waiting.removeFirst()
    }
    next?.resume()
}

/// Runs `body` while no test blocks the GCD workers (T48): a test that waits on work off the main actor (a detached
/// task, a file watch) waits for a holder's 20 s first, instead of counting them against its own deadline.
public func withGCDWorkersFree<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
    await takeHolder()
    defer { passHolder() }
    return try await body()
}

/// Blocks every GCD worker until the returned function is called, or 20 s pass (R51 L2); calling it again does nothing.
public func blockEveryGCDWorker() async -> @Sendable () -> Void {
    await takeHolder()
    let workers = 100
    let gate = DispatchSemaphore(value: 0)
    for _ in 0..<workers { DispatchQueue.global().async { gate.wait() } }
    let held = OSAllocatedUnfairLock(initialState: true)
    let release: @Sendable () -> Void = {
        guard held.withLock({ h in defer { h = false }; return h }) else { return }
        for _ in 0..<workers { gate.signal() }
        passHolder()
    }
    Thread { Thread.sleep(forTimeInterval: 20); release() }.start()
    return release
}
