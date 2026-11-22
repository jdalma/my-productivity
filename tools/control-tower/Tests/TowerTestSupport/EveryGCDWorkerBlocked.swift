import Foundation
import os

/// One holder at a time in the whole test process: both test targets run in one, side by side, and two holders'
/// workers held each other's GCD jobs past 30 s on a 3-core CI runner. A suite's `.serialized` covers one suite only.
private let holder = DispatchSemaphore(value: 1)

/// Blocks every GCD worker until the returned function is called, or 20 s pass (R51 L2); calling it again does nothing.
public func blockEveryGCDWorker() -> @Sendable () -> Void {
    holder.wait()
    let workers = 100
    let gate = DispatchSemaphore(value: 0)
    for _ in 0..<workers { DispatchQueue.global().async { gate.wait() } }
    let held = OSAllocatedUnfairLock(initialState: true)
    let release: @Sendable () -> Void = {
        guard held.withLock({ h in defer { h = false }; return h }) else { return }
        for _ in 0..<workers { gate.signal() }
        holder.signal()
    }
    Thread { Thread.sleep(forTimeInterval: 20); release() }.start()
    return release
}
