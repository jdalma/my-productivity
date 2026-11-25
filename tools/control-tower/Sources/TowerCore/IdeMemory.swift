import Foundation

// What the IDE area remembers beyond a file's buffer (G4 I14, plan §2.3 W3, §2.4 W4): the files a worker wrote lately,
// and the files each task had open.

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

// MARK: - W4: a task's open files

/// The files a task's editor had open, the one shown and its cursor line.
public struct TaskEditorTabs: Codable, Equatable, Sendable {
    public var tabs: [String]
    public var active: String?
    public var line: Int?

    public init(tabs: [String], active: String?, line: Int?) {
        self.tabs = tabs
        self.active = active
        self.line = line
    }
}

/// Every task's open files, by team and task, kept as one stored string as the panel prefs are (`readPanelPrefs`).
public struct TaskEditorMemory: Codable, Equatable, Sendable {
    /// The most tasks kept; the one left longest ago goes first.
    public static let limit = 50

    private struct Entry: Codable, Equatable, Sendable {
        var tabs: TaskEditorTabs
        var at: Date
    }

    private var tasks: [String: Entry] = [:]

    public init() {}

    public var count: Int { tasks.count }

    private static func key(_ team: String, _ task: String) -> String { team + "\u{1f}" + task }

    public func tabs(team: String, task: String) -> TaskEditorTabs? { tasks[Self.key(team, task)]?.tabs }

    /// Keeps what `task` has open as it is left; no tabs forgets it.
    public mutating func remember(_ tabs: TaskEditorTabs, team: String, task: String, at now: Date) {
        let key = Self.key(team, task)
        guard !tabs.tabs.isEmpty else {
            tasks[key] = nil
            return
        }
        tasks[key] = Entry(tabs: tabs, at: now)
        while tasks.count > Self.limit, let oldest = tasks.min(by: { $0.value.at < $1.value.at })?.key { tasks[oldest] = nil }
    }
}

/// The stored memory; one that does not read is no memory.
public func readTaskEditorMemory(_ stored: String) -> TaskEditorMemory {
    (try? JSONDecoder().decode(TaskEditorMemory.self, from: Data(stored.utf8))) ?? TaskEditorMemory()
}

public func storedTaskEditorMemory(_ memory: TaskEditorMemory) -> String {
    let e = JSONEncoder()
    e.outputFormatting = .sortedKeys
    return (try? e.encode(memory)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
}
