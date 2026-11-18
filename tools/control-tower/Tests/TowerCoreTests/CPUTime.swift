import Darwin

/// The CPU time `body` takes on the calling thread (T130). A bound on it holds under a loaded run, where wall time
/// also counts the waits for a core; the work itself, linear or quadratic, is what it measures.
func threadCPUTime(_ body: () -> Void) -> Duration {
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    body()
    return .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start))
}
