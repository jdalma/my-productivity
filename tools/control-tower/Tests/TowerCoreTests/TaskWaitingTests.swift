import Foundation
import Testing
@testable import TowerCore

// A task waiting on the user's decision (T116): the decision brief on a task, its group ahead of every other, and
// the answers a family keeps. Boards from a my-team before T115 have none of it. Fixtures use example names only.

private func task(_ id: String, _ state: String, waiting: String? = nil) -> String {
    #"{"id":"\#(id)","parent_id":null,"title":"title \#(id)","ticket_path":"/tmp/example/\#(id).md","state":"\#(state)","assignee":"dev","reviewer":"rv","priority":100,"constraints":"none","created_at":"2026-11-11T00:00:00.000Z","created_by":"pm","updated_at":"2026-11-11T00:00:00.000Z"\#(waiting.map { #","waiting":\#($0)"# } ?? "")}"#
}

private let briefJSON = #"""
    {"question":"A or B?","context":"Why now.\nChecked: src/a.swift:12.",
     "options":[{"label":"A","detail":"Do A.","pros":["fast"],"cons":["one more state","a test"]},
                {"label":"B","detail":"Do B.","pros":[],"cons":["slow"]}],
     "recommendation":{"option":"A","reason":"Both callers want it."},"impact":"dev waits.","refs":["/tmp/example/a.md"],
     "asked_by":"dev","asked_at":"2026-11-11T02:00:00.000Z","resume_state":"doing"}
    """#

private func status(_ tasks: [String]) throws -> TaskBoardStatus {
    let json = #"{"ok":true,"tasks":[\#(tasks.joined(separator: ","))],"workers":[],"open_findings":[],"recent":[],"announcements":[]}"#
    guard case .ok(let s) = parseTaskBoard(CommandResult(status: 0, stdout: json, stderr: "")) else { throw MyTeamError(description: "not ok") }
    return s
}

/// Acceptance 2: the brief read whole; null, a missing key and an unknown state read as before.
@Test func aWaitingTaskCarriesItsBriefAndOlderBoardsReadAsBefore() throws {
    let s = try status([task("T1", "waiting", waiting: briefJSON), task("T2", "doing", waiting: "null"), task("T3", "doing"),
                        task("T4", "paused")])
    let w = try #require(s.tasks[0].waiting)
    #expect(w.question == "A or B?" && w.context == "Why now.\nChecked: src/a.swift:12.")
    #expect(w.options.map(\.label) == ["A", "B"] && w.options[0].pros == ["fast"] && w.options[0].cons == ["one more state", "a test"])
    #expect(w.options[1].pros == [] && w.options[1].detail == "Do B.")
    #expect(w.recommendation == DecisionRecommendation(option: "A", reason: "Both callers want it."))
    #expect(w.impact == "dev waits." && w.refs == ["/tmp/example/a.md"])
    #expect(w.askedBy == "dev" && w.askedAt == "2026-11-11T02:00:00.000Z" && w.resumeState == "doing")
    #expect(s.tasks[1].waiting == nil && s.tasks[2].waiting == nil, "null, and no key")
    #expect(taskPanels(s)[.doing]?.map(\.task.id) == ["T1", "T2", "T3", "T4"], "an unknown state goes on as in progress; T1 waits to go on doing")
}

/// A brief that says less still reads: no recommendation, no refs, an option without pros.
@Test func aShortBriefReadsWithWhatItHas() throws {
    let s = try status([task("T1", "waiting", waiting: #"{"question":"Q?","options":[{"label":"Yes","cons":["c"]},{"label":"No"}],"recommendation":null}"#),
                        task("T2", "waiting", waiting: #"{"question":"Q?","options":[],"recommendation":{"option":null,"reason":"both cost the same"}}"#)])
    let w = try #require(s.tasks[0].waiting)
    #expect(w.recommendation == nil && w.refs == [] && w.context == nil)
    #expect(s.tasks[1].waiting?.recommendation == DecisionRecommendation(option: nil, reason: "both cost the same"), "none recommended, and why")
    #expect(w.options.map(\.pros) == [[], []] && w.options[0].cons == ["c"])
}

/// T152: a waiting task stays in the panel of the state it goes back to, with its decision on the line.
@Test func aWaitingTaskStaysWhereItGoesBackTo() throws {
    func waiting(_ resume: String?) -> String {
        task("T2", "waiting", waiting: #"{"question":"Q?","asked_at":"2026-11-11T02:00:00.000Z""# + (resume.map { #","resume_state":"\#($0)""# } ?? "") + "}")
    }
    for (resume, p) in [("ready", TaskPanel.start), ("doing", .doing), ("changes", .doing), ("review", .review), ("held", .held)] {
        let s = try status([task("T1", "held"), waiting(resume), task("T3", "doing")])
        #expect(taskPanels(s)[p]?.contains { $0.task.id == "T2" } == true, "\(resume) → \(p)")
    }
    let s = try status([task("T1", "held"), waiting(nil), task("T3", "doing")])
    #expect(taskPanels(s)[.doing]?.map(\.task.id) == ["T2", "T3"], "no state to go back to: in progress")
    #expect(taskPanels(s)[.doing]?.first?.decisions == ["T2:?"], "the wait itself, before a board lists decisions")
    #expect(taskPanels(s)[.decisions] == [], "the decisions panel lists decisions, not tasks")
    #expect(workerTasks("dev", in: s).map(\.id) == ["T2", "T3", "T1"])
}

private func family(answers: String?) -> String {
    #"{"ok":true,"root":\#(task("T5", "doing")),"tasks":[\#(task("T5", "doing")),\#(task("T6", "doing"))],"landings":[],"verdicts":[],"findings":[],"notes":[]\#(answers.map { #","answers":\#($0)"# } ?? "")}"#
}

/// The family's answers (pm decision, lists option 1): the selected task's, oldest first; none from an older board.
@Test func aFamilyKeepsItsAnswersAndAnOlderOneHasNone() throws {
    let answers = #"""
        [{"task_id":"T5","question":"Later?","chosen":"B","answer":"B then.","answered_by":"pm","answered_at":"2026-11-11T05:00:00.000Z","brief":null},
         {"task_id":"T6","question":"Other?","chosen":"A","answer":"A.","answered_by":"pm","answered_at":"2026-11-11T04:00:00.000Z"},
         {"task_id":"T5","question":"A or B?","chosen":"A","answer":"A, as recommended.","answered_by":"pm","answered_at":"2026-11-11T03:00:00.000Z","brief":\#(briefJSON)}]
        """#
    guard case .success(let f) = parseTaskFamily(CommandResult(status: 0, stdout: family(answers: answers), stderr: "")) else {
        Issue.record("not read"); return
    }
    let d = try #require(taskDetail(f, task: "T5"))
    #expect(d.answers.map(\.chosen) == ["A", "B"], "T5's own, oldest first")
    #expect(d.answers[0].brief?.question == "A or B?" && d.answers[1].brief == nil)
    for old in [nil, "[]"] {
        guard case .success(let o) = parseTaskFamily(CommandResult(status: 0, stdout: family(answers: old), stderr: "")) else {
            Issue.record("not read: \(old ?? "no key")"); continue
        }
        #expect(o.answers == [])
    }
}

/// R41 L3: one option that does not read is left out alone, and counted; the others stay.
@Test func anOptionThatDoesNotReadIsLeftOutAloneAndCounted() throws {
    let s = try status([task("T1", "waiting", waiting: #"{"question":"Q?","options":[{"label":"A","pros":["p"]},{"label":"B","pros":"not a list"},{"label":"C"}]}"#),
                        task("T2", "waiting", waiting: #"{"question":"Q?","options":"not a list"}"#)])
    let w = try #require(s.tasks[0].waiting)
    #expect(w.options.map(\.label) == ["A", "C"] && w.unreadOptions == 1)
    #expect(s.tasks[1].waiting?.options == [] && s.tasks[1].waiting?.unreadOptions == 0, "no list at all: no options, nothing counted")
}
