import CoreServices
import Foundation
import Testing
@testable import TowerCore

// MARK: - batching and judging, without FSEvents

@Test func aBatchFlushesSoonAfterAQuietSpellAndOnAFixedBeatWhileWritesKeepComing() {
    #expect(fileWatchFlushDelay(now: 10_000, lastFlush: 0) == 75)  // nothing flushed lately: the leading 75 ms
    #expect(fileWatchFlushDelay(now: 10_000, lastFlush: 9_990) == 90)  // 100 ms after the last flush
    #expect(fileWatchFlushDelay(now: 10_000, lastFlush: 9_950) == 75)  // never sooner than 75 ms
    #expect(fileWatchFlushDelay(now: 10_000, lastFlush: 10_500) == 100)  // a clock that went back waits no more than 100
}

@Test func buildOutputAndVCSFoldersAreNotWatched() {
    #expect(fileWatchIgnored("node_modules/x/index.js"))
    #expect(fileWatchIgnored(".git/index"))
    #expect(fileWatchIgnored("tools/control-tower/.build/debug/x"))
    #expect(fileWatchIgnored("app/build"))
    #expect(!fileWatchIgnored("src/build.gradle"))
    #expect(!fileWatchIgnored("src/main.swift"))
}

private let file = UInt32(kFSEventStreamEventFlagItemIsFile)

@Test func aWrittenFileIsChangedAtTheFlush() {
    var s = FileWatchState(root: "/w")
    let r1 = s.receive(["/w/a.txt", "/w/a.txt", "/w/src/b.swift"], flags: [file, file, file])
    #expect(r1)
    let r2 = s.receive(["/w/c.txt"], flags: [file])
    #expect(!r2)  // a flush is already due
    let batch = s.flush(at: 100) { _ in true }
    #expect(batch == FileWatchBatch(changed: ["a.txt", "src/b.swift", "c.txt"]))
    let r101 = s.flush(at: 200) { _ in true }
    #expect(r101 == nil)  // nothing since
}

@Test func ignoredAndOutsidePathsAndTheRootItselfAreDropped() {
    var s = FileWatchState(root: "/w")
    let r3 = s.receive(["/w/node_modules/x.js", "/other/a.txt", "/w", "/wx/a.txt"], flags: [file, file, 0, file])
    #expect(!r3)
    let r102 = s.flush(at: 100) { _ in true }
    #expect(r102 == nil)
}

@Test func aFileGoneAtTheFlushIsDeletedOnlyWhenStillGone250msLater() {
    var s = FileWatchState(root: "/w")
    _ = s.receive(["/w/gone.txt"], flags: [file])
    let r103 = s.flush(at: 1_000) { _ in false }
    #expect(r103 == nil)  // not yet: an atomic save shows a delete first
    #expect(s.nextExpiry == 1_250)
    let r104 = s.expire(at: 1_200) { _ in false }
    #expect(r104 == nil)
    let r4 = s.expire(at: 1_250) { _ in false }
    #expect(r4 == FileWatchBatch(deleted: ["gone.txt"]))
    #expect(s.nextExpiry == nil)
}

@Test func aFileBackWithin250msIsChangedNotDeleted() {
    var s = FileWatchState(root: "/w")
    _ = s.receive(["/w/saved.txt"], flags: [file])
    let r105 = s.flush(at: 1_000) { _ in false }
    #expect(r105 == nil)
    // the rename half of the save: back again
    _ = s.receive(["/w/saved.txt"], flags: [file])
    let r5 = s.flush(at: 1_100) { _ in true }
    #expect(r5 == FileWatchBatch(changed: ["saved.txt"]))
    #expect(s.nextExpiry == nil)
    // or back without an event of its own by the deadline
    _ = s.receive(["/w/other.txt"], flags: [file])
    _ = s.flush(at: 2_000) { _ in false }
    let r6 = s.expire(at: 2_250) { _ in true }
    #expect(r6 == FileWatchBatch(changed: ["other.txt"]))
}

@Test func droppedEventsOrTooManyAskForAFullRescan() {
    var s = FileWatchState(root: "/w")
    _ = s.receive(["/w/a.txt"], flags: [file])
    _ = s.flush(at: 0) { _ in false }  // a.txt waits as a tombstone
    let r7 = s.receive(["/w"], flags: [UInt32(kFSEventStreamEventFlagMustScanSubDirs)])
    #expect(r7)
    let r8 = s.flush(at: 100) { _ in true }
    #expect(r8 == FileWatchBatch(rescan: true))
    #expect(s.nextExpiry == nil)  // the rescan reads a.txt's state anew

    var many = FileWatchState(root: "/w", limit: 3)
    _ = many.receive((0..<4).map { "/w/f\($0)" }, flags: Array(repeating: file, count: 4))
    let r9 = many.flush(at: 0) { _ in true }
    #expect(r9 == FileWatchBatch(rescan: true))

    var root = FileWatchState(root: "/w")
    _ = root.receive(["/w"], flags: [UInt32(kFSEventStreamEventFlagRootChanged)])
    let r10 = root.flush(at: 0) { _ in true }
    #expect(r10 == FileWatchBatch(rescan: true))
}

// MARK: - FSEvents on a real folder

/// Collects what a watch delivers, for a test to wait on.
private final class Batches: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [FileWatchBatch] = []

    func add(_ b: FileWatchBatch) { lock.withLock { all.append(b) } }
    var changed: Set<String> { lock.withLock { all.reduce(into: []) { $0.formUnion($1.changed) } } }
    var deleted: Set<String> { lock.withLock { all.reduce(into: []) { $0.formUnion($1.deleted) } } }

    /// Waits up to `seconds` for `done`.
    func wait(_ seconds: Double = 5, until done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }
}

@Test func aRealFolderReportsWritesAtomicSavesAndDeletes() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tower-watch-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir + "/node_modules", withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try "old".write(toFile: dir + "/saved.txt", atomically: false, encoding: .utf8)
    try "x".write(toFile: dir + "/doomed.txt", atomically: false, encoding: .utf8)
    // FSEvents may still report these writes to a stream started at once after them
    try await Task.sleep(for: .milliseconds(500))
    let got = Batches()
    let watch = try #require(FileWatch(root: dir) { got.add($0) })
    defer { watch.stop() }
    try await Task.sleep(for: .milliseconds(300))  // the stream is up; what came before it is not reported

    try "new".write(toFile: dir + "/new.txt", atomically: false, encoding: .utf8)
    // an atomic save: written beside, then renamed over the file
    try "edited".write(toFile: dir + "/.saved.txt.tmp", atomically: false, encoding: .utf8)
    #expect(rename(dir + "/.saved.txt.tmp", dir + "/saved.txt") == 0)
    try FileManager.default.removeItem(atPath: dir + "/doomed.txt")
    try "y".write(toFile: dir + "/node_modules/dep.js", atomically: false, encoding: .utf8)

    #expect(await got.wait { got.changed.isSuperset(of: ["new.txt", "saved.txt"]) && got.deleted.contains("doomed.txt") })
    try await Task.sleep(for: .milliseconds(500))  // past the tombstone of the temp file
    #expect(!got.deleted.contains("saved.txt"))
    #expect(!got.changed.contains { $0.hasPrefix("node_modules") })
}

@Test func aWatchOfAMissingFolderIsNil() {
    #expect(FileWatch(root: "/nonexistent-\(UUID().uuidString)") { _ in } == nil)
}

/// Holds the watch for its own deliver closure.
private final class WatchBox: @unchecked Sendable {
    var watch: FileWatch?
}

@Test func aWatchCanBeStoppedFromItsOwnBatch() async throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tower-watch-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let box = WatchBox(), got = Batches()
    box.watch = FileWatch(root: dir) { batch in
        box.watch?.stop()  // on the watch's own queue
        got.add(batch)
    }
    try "a".write(toFile: dir + "/a.txt", atomically: false, encoding: .utf8)
    #expect(await got.wait { got.changed.contains("a.txt") })
    try "b".write(toFile: dir + "/b.txt", atomically: false, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(400))
    #expect(!got.changed.contains("b.txt"))  // stopped: nothing after
}
