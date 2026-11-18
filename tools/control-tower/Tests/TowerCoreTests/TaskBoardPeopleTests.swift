import Foundation
import Testing
@testable import TowerCore

// The task board v2 (T70b): arrow keys over the visible lines, and the
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


@Test func theArrowsRunAcrossPanelsAndPassAFoldedOne() throws {
    let done = (1...7).map { task("D\($0)", "done", priority: $0) }
    let s = try status([task("A1", "held"), task("R1", "review"), task("V1", "doing"), task("V2", "ready", parent: "V1")] + done)
    let panels = taskPanels(s)
    func ids(_ prefs: TaskPanelPrefs = TaskPanelPrefs(), searching: Bool = false, doneOpen: Bool = false) -> [String] {
        visibleIds(order: TaskPanel.allCases, panels: panels, decisions: ["D#1"], prefs: prefs, searching: searching, doneOpen: doneOpen)
    }
    #expect(ids() == ["V2", "D#1", "V1", "R1", "A1", "D1", "D2", "D3", "D4", "D5"],
            "panels in order, the decisions among them; V2 is ready, apart from its parent; done shows its first \(finishedShown)")
    #expect(ids(doneOpen: true).count == 12)
    let folded = TaskPanelPrefs(folded: [.decisions, .doing])
    #expect(ids(folded) == ["V2", "R1", "A1", "D1", "D2", "D3", "D4", "D5"], "a folded panel's lines are passed")
    #expect(ids(folded, searching: true).count == 12, "a search shows every line it finds")
    let order = ids(folded)
    #expect(step(order, from: "V2", by: 1) == "R1", "down from the last of one panel to the first of the next, over the folded")
    #expect(step(order, from: "R1", by: -1) == "V2")
    #expect(step(order, from: "D5", by: 1) == "D5" && step(order, from: "V2", by: -1) == "V2", "held at the ends")
    #expect(step(order, from: nil, by: 1) == "V2" && step(order, from: nil, by: -1) == "D5")
    #expect(step(order, from: "V1", by: 1) == "V2", "a pick gone from the screen starts from the top")
    #expect(step([], from: nil, by: 1) == nil)
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
