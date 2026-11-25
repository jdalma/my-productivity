import Foundation

// What the IDE area remembers beyond a file's buffer (G4 I14, plan §2.3 W3): the files a worker wrote lately.

// MARK: - W3: a worker's writes

/// The files under a worktree written lately by something other than this app: the worker, since a worktree has no
/// other writer and the app's own saves are known (`WorkingFileWriter.isSelfWrite`). Who wrote is not known: no
/// transcript is read (plan §2.3).
public struct WorkerWrites: Equatable, Sendable {
    /// How long a write marks its file. Measured (T35 report): of 882 back-to-back Edit/Write calls on one file in
    /// 14 days of this machine's Claude transcripts, the median gap was 5 s and 75% came within 60 s.
    public static let window: TimeInterval = 60

    /// Real path → when it was last written.
    public private(set) var last: [String: Date] = [:]

    public init() {}

    /// Takes in a watch batch of `root` (its paths are relative to it): a changed file that is not one of `own` (the
    /// app's saves, real paths) is a worker's, a deleted one is forgotten, and writes past the window go.
    public mutating func record(_ batch: FileWatchBatch, root: String, own: Set<String>, at now: Date) {
        expire(at: now)
        for p in batch.deleted { last[root + "/" + p] = nil }
        for p in batch.changed where !own.contains(root + "/" + p) { last[root + "/" + p] = now }
    }

    /// Drops the writes past the window.
    public mutating func expire(at now: Date) { last = last.filter { now.timeIntervalSince($0.value) < Self.window } }

    /// Seconds since a worker wrote `path`; nil when it did not lately.
    public func age(_ path: String, at now: Date) -> TimeInterval? {
        guard let t = last[path], now.timeIntervalSince(t) < Self.window else { return nil }
        return now.timeIntervalSince(t)
    }

    public func recent(at now: Date) -> Set<String> { Set(last.keys.filter { age($0, at: now) != nil }) }
}

/// The line that warns before an edit of a file a worker just wrote.
public func workerWriteWarning(worker: String?, age: TimeInterval) -> String {
    "\(worker ?? "워커")가 \(Int(age))초 전에 이 파일을 썼습니다"
}
