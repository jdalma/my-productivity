import CoreServices
import Foundation

// A work tree's file changes, for the IDE area's tree, the reload of a clean buffer and a dirty buffer's conflict
// (control-tower-ide-feasibility.md §3 "가져올 설계" 3, 4, 9). Timing follows orca's watcher (T13 §3.1, §3.4):
// a batch 75 ms after a quiet spell, then every 100 ms while writes keep coming, never a trailing debounce, which
// would hold every change back while an agent writes without a pause.

/// What changed under the root since the last batch, by path from the root.
public struct FileWatchBatch: Equatable, Sendable {
    /// Written, created or renamed into place: the path is there now.
    public var changed: Set<String> = []
    /// Gone, and still gone 250 ms later.
    public var deleted: Set<String> = []
    /// Events were dropped or too many came at once: read everything again.
    public var rescan = false

    public init(changed: Set<String> = [], deleted: Set<String> = [], rescan: Bool = false) {
        self.changed = changed
        self.deleted = deleted
        self.rescan = rescan
    }
}

/// Folders whose contents are never watched: version control, dependencies and build output.
let fileWatchIgnoredNames: Set<String> = [
    ".git", "node_modules", "dist", "build", ".build", ".next", ".cache", "target", ".venv", "__pycache__",
    ".dart_tool", ".gradle", ".turbo",
]

/// `path` (from the root) is inside, or is, an ignored folder.
func fileWatchIgnored(_ path: String) -> Bool {
    path.split(separator: "/").contains { fileWatchIgnoredNames.contains(String($0)) }
}

/// Milliseconds from `now` to the next flush, both in ms: 75 after a quiet spell, else 100 after the last flush,
/// and never more than 100, so a clock that went back cannot hold a batch.
func fileWatchFlushDelay(now: Double, lastFlush: Double, leading: Double = 75, interval: Double = 100) -> Double {
    min(interval, max(leading, lastFlush + interval - now))
}

/// The flags that say events were lost: the folder must be read again.
private let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)

/// The watch's bookkeeping, with no FSEvents and no clock: times are passed in (ms), the disk is `exists`.
/// A path is judged by the disk, not by its event's flags, which FSEvents joins across events: there at the flush,
/// it changed; gone, it waits 250 ms (an atomic save deletes then renames into place) and is deleted only if
/// still gone then.
struct FileWatchState {
    let root: String
    /// More paths than this in one batch ask for a rescan instead.
    let limit: Int
    static let deleteDelay: Double = 250

    private var touched: Set<String> = []
    private var overflow = false
    /// Paths gone at a flush, with when to judge them again.
    private var tombstones: [String: Double] = [:]
    private(set) var lastFlush: Double = 0

    init(root: String, limit: Int = 5000) {
        self.root = root.hasSuffix("/") ? String(root.dropLast()) : root
        self.limit = limit
    }

    /// Takes one FSEvents callback's paths (absolute) and flags; true when a flush must be scheduled: these are the
    /// first events since the last flush.
    mutating func receive(_ paths: [String], flags: [UInt32]) -> Bool {
        let idle = touched.isEmpty && !overflow
        for (path, flag) in zip(paths, flags) {
            if flag & rescanFlags != 0 { overflow = true; continue }
            guard path.hasPrefix(root + "/") else { continue }
            let relative = String(path.dropFirst(root.count + 1))
            if !relative.isEmpty, !fileWatchIgnored(relative) { touched.insert(relative) }
        }
        return idle && (!touched.isEmpty || overflow)
    }

    /// The batch at `now`: nil when there is nothing to say.
    mutating func flush(at now: Double, exists: (String) -> Bool) -> FileWatchBatch? {
        lastFlush = now
        defer { touched = [] }
        if overflow || touched.count > limit {
            overflow = false
            tombstones = [:]
            return FileWatchBatch(rescan: true)
        }
        var batch = FileWatchBatch()
        for path in touched {
            if exists(path) {
                batch.changed.insert(path)
                tombstones[path] = nil
            } else {
                tombstones[path] = now + Self.deleteDelay
            }
        }
        return batch.changed.isEmpty ? nil : batch
    }

    /// When the next tombstone is due; nil without one.
    var nextExpiry: Double? { tombstones.values.min() }

    /// The tombstones due at `now`: still gone, deleted; back, changed.
    mutating func expire(at now: Double, exists: (String) -> Bool) -> FileWatchBatch? {
        var batch = FileWatchBatch()
        for (path, due) in tombstones where due <= now {
            tombstones[path] = nil
            if exists(path) { batch.changed.insert(path) } else { batch.deleted.insert(path) }
        }
        return batch == FileWatchBatch() ? nil : batch
    }
}

/// FSEvents on a work tree's root, file events, from now on. Batches go to `deliver` on the watch's own queue.
/// Everything the watch holds is touched only on that queue, hence `@unchecked Sendable`.
public final class FileWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "control-tower.FileWatch")
    /// Marks the queue, so `stop` called on it (from `deliver`, or a deinit there) does not sync onto itself.
    private static let onQueue = DispatchSpecificKey<Void>()
    private let rootURL: URL
    private let deliver: @Sendable (FileWatchBatch) -> Void
    private var state: FileWatchState
    private var stream: FSEventStreamRef?
    private var flushDue = false
    private var expiryDue: Double?

    /// nil when `root` is not a folder or the stream does not start.
    public init?(root: String, deliver: @escaping @Sendable (FileWatchBatch) -> Void) {
        var isFolder: ObjCBool = false
        // FSEvents reports real paths (/private/var for /var): the root must be one too
        guard let real = realpath(root, nil) else { return nil }
        let resolved = String(cString: real)
        free(real)
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isFolder), isFolder.boolValue else { return nil }
        rootURL = URL(fileURLWithPath: resolved)
        state = FileWatchState(root: resolved)
        self.deliver = deliver
        queue.setSpecific(key: Self.onQueue, value: ())

        // the stream holds the sink, not the watch, and releases it with itself
        let sink = Unmanaged.passRetained(Sink(self)).toOpaque()
        var context = FSEventStreamContext(version: 0, info: sink, retain: nil,
                                           release: { Unmanaged<Sink>.fromOpaque($0!).release() }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
            | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        // ponytail: 10 ms of FSEvents latency under the 75 ms batch; raise it if callbacks ever cost too much
        guard let stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let flags = (0..<count).map { flags[$0] }
            Unmanaged<Sink>.fromOpaque(info!).takeUnretainedValue().watch?.receive(paths, flags: flags)
        }, &context, [resolved] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.01, flags)
        else {
            Unmanaged<Sink>.fromOpaque(sink).release()
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
    }

    deinit { stop() }

    /// Stops the stream; no batch is delivered after it returns. Callable from `deliver`.
    public func stop() {
        let end = {
            guard let stream = self.stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        if DispatchQueue.getSpecific(key: Self.onQueue) != nil { end() } else { queue.sync(execute: end) }
    }

    private final class Sink {
        weak var watch: FileWatch?
        init(_ watch: FileWatch) { self.watch = watch }
    }

    private var now: Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: rootURL.appending(path: path).path)
    }

    private func receive(_ paths: [String], flags: [UInt32]) {
        guard state.receive(paths, flags: flags), !flushDue else { return }
        flushDue = true
        let delay = fileWatchFlushDelay(now: now, lastFlush: state.lastFlush)
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay))) { [weak self] in self?.flush() }
    }

    private func flush() {
        flushDue = false
        guard stream != nil else { return }
        if let batch = state.flush(at: now, exists: exists) { deliver(batch) }
        scheduleExpiry()
    }

    private func scheduleExpiry() {
        guard let due = state.nextExpiry, expiryDue.map({ due < $0 }) ?? true else { return }
        expiryDue = due
        queue.asyncAfter(deadline: .now() + .milliseconds(max(0, Int((due - now).rounded(.up))))) { [weak self] in
            guard let self, self.stream != nil else { return }
            self.expiryDue = nil
            if let batch = self.state.expire(at: self.now, exists: self.exists) { self.deliver(batch) }
            self.scheduleExpiry()
        }
    }
}
