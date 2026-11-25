import Foundation
import Testing
@testable import TowerCore

// W3: the files a worker wrote lately; W4: a task's open files, kept per task (G4 I14).

private let t0 = Date(timeIntervalSince1970: 1_000_000)

// MARK: - Worker writes

@Test func aWriteNotTheAppsIsAWorkersUntilItIsOld() {
    var w = WorkerWrites()
    w.record(FileWatchBatch(changed: ["a.swift", "b.swift"]), root: "/w", own: ["/w/b.swift"], at: t0)
    #expect(w.age("/w/a.swift", at: t0.addingTimeInterval(12)) == 12)
    #expect(w.age("/w/b.swift", at: t0) == nil)  // the app's own save
    #expect(w.age("/w/a.swift", at: t0.addingTimeInterval(WorkerWrites.window)) == nil)
    #expect(w.recent(at: t0.addingTimeInterval(1)) == ["/w/a.swift"])
}

@Test func aLaterWriteRestartsTheClockAndADeleteForgetsTheFile() {
    var w = WorkerWrites()
    w.record(FileWatchBatch(changed: ["a.swift", "c.swift"]), root: "/w", own: [], at: t0)
    w.record(FileWatchBatch(changed: ["a.swift"], deleted: ["c.swift"]), root: "/w", own: [], at: t0.addingTimeInterval(50))
    #expect(w.age("/w/a.swift", at: t0.addingTimeInterval(70)) == 20)
    #expect(w.age("/w/c.swift", at: t0.addingTimeInterval(51)) == nil)
}

@Test func aRescanTellsNoWriter() {
    var w = WorkerWrites()
    w.record(FileWatchBatch(rescan: true), root: "/w", own: [], at: t0)
    #expect(w.recent(at: t0).isEmpty)
}

@Test func oldWritesAreDroppedAsNewOnesCome() {
    var w = WorkerWrites()
    w.record(FileWatchBatch(changed: ["a.swift"]), root: "/w", own: [], at: t0)
    w.record(FileWatchBatch(changed: ["b.swift"]), root: "/w", own: [], at: t0.addingTimeInterval(WorkerWrites.window + 1))
    #expect(w.last.keys.sorted() == ["/w/b.swift"])
}

@Test func theWarningSaysWhoAndHowLongAgo() {
    #expect(workerWriteWarning(worker: "analyst", age: 12.4) == "analyst가 12초 전에 이 파일을 썼습니다")
    #expect(workerWriteWarning(worker: nil, age: 0.3) == "워커가 0초 전에 이 파일을 썼습니다")
}

// MARK: - A task's open files

@Test func aTasksTabsComeBackAsTheyWereLeft() {
    var m = TaskEditorMemory()
    m.remember(TaskEditorTabs(tabs: ["/w/a", "/w/b"], active: "/w/b", line: 42), team: "t", task: "T1", at: t0)
    m.remember(TaskEditorTabs(tabs: ["/w/c"], active: "/w/c", line: nil), team: "t", task: "T2", at: t0)
    #expect(m.tabs(team: "t", task: "T1") == TaskEditorTabs(tabs: ["/w/a", "/w/b"], active: "/w/b", line: 42))
    #expect(m.tabs(team: "u", task: "T1") == nil)  // another team's T1
    let again = readTaskEditorMemory(storedTaskEditorMemory(m))
    #expect(again == m)
}

@Test func noTabsForgetsTheTask() {
    var m = TaskEditorMemory()
    m.remember(TaskEditorTabs(tabs: ["/w/a"], active: "/w/a", line: 1), team: "t", task: "T1", at: t0)
    m.remember(TaskEditorTabs(tabs: [], active: nil, line: nil), team: "t", task: "T1", at: t0)
    #expect(m.tabs(team: "t", task: "T1") == nil)
}

@Test func pastTheLimitTheTaskLeftLongestAgoGoes() {
    var m = TaskEditorMemory()
    for i in 0..<TaskEditorMemory.limit {
        m.remember(TaskEditorTabs(tabs: ["/w/\(i)"], active: nil, line: nil), team: "t", task: "T\(i)", at: t0.addingTimeInterval(Double(i)))
    }
    // T0 is seen again, so T1 is now the oldest
    m.remember(TaskEditorTabs(tabs: ["/w/0"], active: nil, line: nil), team: "t", task: "T0", at: t0.addingTimeInterval(1000))
    m.remember(TaskEditorTabs(tabs: ["/w/new"], active: nil, line: nil), team: "t", task: "Tnew", at: t0.addingTimeInterval(1001))
    #expect(m.count == TaskEditorMemory.limit)
    #expect(m.tabs(team: "t", task: "T1") == nil)
    #expect(m.tabs(team: "t", task: "T0") != nil)
    #expect(m.tabs(team: "t", task: "Tnew") != nil)
}

@Test func aStoredValueThatDoesNotReadIsNoMemory() {
    #expect(readTaskEditorMemory("") == TaskEditorMemory())
    #expect(readTaskEditorMemory("{not json") == TaskEditorMemory())
}
