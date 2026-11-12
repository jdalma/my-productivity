import Foundation
import Testing
@testable import TowerCore

// The task board v2 (T70b): who a line names and whose move it is, arrow keys over the visible lines, and the
// verdict a recent event carries. Fixtures use example names only.

private func task(_ id: String, _ state: String, parent: String? = nil, assignee: String? = "dev", reviewer: String? = "rv",
                  ticket: String? = "/tmp/example/t.md", priority: Int = 100) -> String {
    func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
    return #"{"id":"\#(id)","parent_id":\#(q(parent)),"title":"t","ticket_path":\#(q(ticket)),"state":"\#(state)","assignee":\#(q(assignee)),"reviewer":\#(q(reviewer)),"priority":\#(priority),"constraints":"none","created_by":"pm"}"#
}

private func status(_ tasks: [String], findings: String = "", recent: String = "") throws -> TaskBoardStatus {
    let json = #"{"tasks":[\#(tasks.joined(separator: ","))],"workers":[],"open_findings":[\#(findings)],"recent":[\#(recent)],"announcements":[]}"#
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(TaskBoardStatus.self, from: Data(json.utf8))
}

private func people(_ s: TaskBoardStatus, _ id: String) throws -> [TaskPerson] {
    let groups = taskGroups(s)
    let (g, line) = try #require(groups.lazy.flatMap { g, lines in lines.map { (g, $0) } }.first { $0.1.task.id == id })
    return taskPeople(line, in: g)
}

private func p(_ role: PersonRole, _ name: String?, turn: Bool = false) -> TaskPerson { TaskPerson(role: role, name: name, turn: turn) }

@Test func eachGroupNamesItsPeopleAndMarksOnlyWhoseMoveItIs() throws {
    let s = try status([task("T1", "doing"), task("T2", "changes"), task("T3", "ready"), task("T4", "review"),
                        task("T5", "held"), task("T6", "review", ticket: nil), task("T7", "new", assignee: nil),
                        task("T8", "done"), task("T9", "done"), task("T10", "cancelled", assignee: nil)],
                       findings: #"{"id":"R1 L1","task_id":"T9","severity":"low","summary":"s","state":"open"}"#)
    for id in ["T1", "T2", "T3"] {
        #expect(try people(s, id) == [p(.assignee, "dev", turn: true), p(.reviewer, "rv")], "active \(id): the assignee's move")
    }
    #expect(try people(s, "T4") == [p(.assignee, "dev"), p(.reviewer, "rv", turn: true)], "review: the reviewer's move")
    #expect(try people(s, "T5") == [p(.assignee, "dev"), p(.reviewer, "rv")], "held: pm's move, no one on the line")
    #expect(try people(s, "T6") == [p(.assignee, "dev"), p(.reviewer, "rv")], "incomplete review request: pm's move")
    #expect(try people(s, "T7") == [p(.registered, "pm"), p(.assignee, nil)], "new: 등록 pm → 담당 없음")
    #expect(try people(s, "T8") == [p(.registered, "pm"), p(.handled, "dev")], "finished: 등록 → 처리")
    #expect(try people(s, "T9") == [p(.registered, "pm"), p(.handled, "dev")], "done with open findings: as finished")
    #expect(try people(s, "T10") == [p(.registered, "pm"), p(.handled, nil)], "cancelled with no assignee: 처리 없음")
}

@Test func aLineWithoutAReviewerNamesOnlyItsAssignee() throws {
    let s = try status([task("T1", "doing", reviewer: nil)])
    #expect(try people(s, "T1") == [p(.assignee, "dev", turn: true)])
}

@Test func arrowKeysWalkTheVisibleLinesAcrossGroups() throws {
    let done = (1...7).map { task("D\($0)", "done", priority: $0) }
    let s = try status([task("A1", "held"), task("R1", "review"), task("V1", "doing"), task("V2", "ready", parent: "V1")] + done)
    let folded = visibleTaskIds(taskGroups(s), finishedOpen: false)
    #expect(folded == ["A1", "R1", "V1", "V2", "D1", "D2", "D3", "D4", "D5"], "groups in board order, finished folded to \(finishedShown)")
    #expect(visibleTaskIds(taskGroups(s), finishedOpen: true).count == 11)
    #expect(stepTask(nil, by: 1, in: folded) == "A1" && stepTask(nil, by: -1, in: folded) == "D5", "nothing picked: from either end")
    #expect(stepTask("A1", by: 1, in: folded) == "R1" && stepTask("R1", by: -1, in: folded) == "A1", "across a group's edge")
    #expect(stepTask("V1", by: 1, in: folded) == "V2", "into a child")
    #expect(stepTask("A1", by: -1, in: folded) == "A1" && stepTask("D5", by: 1, in: folded) == "D5", "stops at the ends")
    #expect(stepTask("D7", by: 1, in: folded) == "A1", "a pick the fold hides starts over")
    #expect(stepTask(nil, by: 1, in: []) == nil)
    let onlyDone = try status(done)
    #expect(visibleTaskIds(taskGroups(onlyDone), finishedOpen: false).count == 7, "nothing unfinished: finished is open")
}

@Test func aVerdictEventKeepsItsVerdict() throws {
    let s = try status([], recent: """
        {"seq":1,"at":"2026-11-11T00:00:00.000Z","actor":"rv","action":"verdict","kind":"verdict","ref":"R1","state_from":"review","state_to":"done","detail":{"landing":"T1#1","verdict":"hold"}},
        {"seq":2,"at":"2026-11-11T00:00:00.000Z","actor":"dev","action":"land","kind":"landing","ref":"T1#1","detail":{"task":"T1","superseded":null}},
        {"seq":3,"at":"2026-11-11T00:00:00.000Z","actor":"pm","action":"cancel","kind":"task","ref":"T2","detail":"text"}
        """)
    #expect(s.recent.map(\.verdict) == ["hold", nil, nil])
    #expect(s.recent[2].detail == "text")
}
