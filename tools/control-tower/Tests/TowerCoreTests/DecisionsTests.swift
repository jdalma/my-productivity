import Foundation
import Testing
@testable import TowerCore

// The board's decisions (T147): `decisions` of board-status as my-team T146 writes it (Fixtures/board-decisions.json
// is its real output: D#1 open, D#2 answered, T1:1 the wait of task T1), and a board from before T146 without it.

private func status(_ json: String) throws -> TaskBoardStatus {
    guard case .ok(let s) = parseTaskBoard(CommandResult(status: 0, stdout: json, stderr: "")) else { throw MyTeamError(description: "not ok") }
    return s
}

private func board() throws -> TaskBoardStatus { try status(try fixture("board-decisions.json")) }

/// The fixture with its `decisions` replaced: by `items`, or left out (a my-team before T146).
private func board(decisions items: String?) throws -> TaskBoardStatus {
    var json = try JSONSerialization.jsonObject(with: try fixtureData("board-decisions.json")) as! [String: Any]
    json["decisions"] = items.map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) }
    return try status(String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!)
}

@Test func readsOpenAnsweredAndTaskBoundDecisions() throws {
    let s = try board()
    #expect(openDecisions(s).map(\.id) == ["D#1", "T1:1"], "open ones in the order asked")
    #expect(pastDecisions(s).map(\.id) == ["D#2"])
    let d1 = try #require(openDecisions(s).first)
    #expect(d1.taskId == nil && d1.tasks == ["T1"] && d1.open)
    #expect(d1.brief.question == "결정 목록을 작업 목록과 합칩니까?")
    #expect(d1.brief.context == "작업판 창에 결정 목록을 넣는다")
    #expect(d1.brief.options.map(\.label) == ["A", "B"] && d1.brief.options[0].pros == ["한눈에 본다"])
    #expect(d1.brief.recommendation?.option == "B" && d1.brief.refs == ["docs/board.md"])
    #expect(d1.brief.askedBy == "dev" && d1.brief.askedAt != nil)
    let d2 = try #require(pastDecisions(s).first)
    #expect(!d2.open && d2.chosen == "A" && d2.answer == "사용자: 전부 보여 준다" && d2.answeredBy == "pm" && d2.answeredAt != nil)
    let wait = openDecisions(s)[1]
    #expect(wait.taskId == "T1" && wait.related == ["T1"])
}

@Test func aDecisionMissingFieldsStillReads() throws {
    let s = try board(decisions: #"[{"id":"D#9","state":"open"},{"id":"D#8","state":"answered","question":"q","options":[{"label":"A"},7]}]"#)
    #expect(openDecisions(s).map(\.id) == ["D#9"])
    let open = try #require(openDecisions(s).first)
    #expect(open.brief.question == "" && open.brief.options.isEmpty && open.tasks.isEmpty && open.taskId == nil)
    let past = try #require(pastDecisions(s).first)
    #expect(past.brief.options.map(\.label) == ["A"] && past.brief.unreadOptions == 1 && past.chosen == nil)
}

@Test func R4L2_aFieldOfTheWrongTypeOrAnEntryThatIsNoObjectFailsNoRead() throws {
    let s = try board(decisions: #"[{"id":"D#1","state":"open","question":5,"tasks":"T1"},7,{"id":"D#2","state":"open","question":"ok"}]"#)
    #expect(openDecisions(s).map(\.id).contains("D#2"))
    let bad = try #require(boardDecisions(s).first { $0.id == "D#1" })
    #expect(bad.open && bad.brief.question == "" && bad.tasks.isEmpty, "the rest of the entry stays")
}

@Test func R4L3_onlyOpenIsOpenAndDecisionsWithoutAnIdAreToldApart() throws {
    let s = try board(decisions: #"[{"state":"open","question":"a"},{"state":"open","question":"b"},{"id":"D#3","state":"later"},{"id":"D#4"}]"#)
    #expect(boardDecisions(s).map(\.id) == ["?1", "?2", "D#3", "D#4"])
    #expect(openDecisions(s).map(\.brief.question) == ["a", "b"], "an unknown or missing state is not the user's turn")
}

@Test func aBoardBeforeT146StandsItsWaitingTasksForDecisions() throws {
    let s = try board(decisions: nil)
    #expect(s.decisions == nil)
    #expect(openDecisions(s).map(\.id) == ["T1:?"])
    #expect(openDecisions(s)[0].brief.question == "결정 목록은 어느 창에 둡니까?" && openDecisions(s)[0].taskId == "T1")
    #expect(pastDecisions(s).isEmpty)
}

@Test func R4S1_aWaitingTaskWithoutABriefIsStillADecision() throws {
    var json = try JSONSerialization.jsonObject(with: try fixtureData("board-decisions.json")) as! [String: Any]
    json["decisions"] = nil
    var tasks = json["tasks"] as! [[String: Any]]
    tasks[0]["waiting"] = NSNull()
    json["tasks"] = tasks
    let s = try status(String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!)
    #expect(openDecisions(s).map(\.id) == ["T1:?"])
    #expect(openDecisions(s)[0].brief.question == "" && openDecisions(s)[0].taskId == "T1")
}

@Test func aTasksDecisionsAreTheOnesTiedToIt() throws {
    let s = try board()
    #expect(decisions(of: "T1", in: s).map(\.id) == ["D#1", "T1:1", "D#2"], "open first in the order asked, then the answered")
    #expect(decisions(of: "T2", in: s).isEmpty)
}

@Test func R4L4_aWaitIsTheSameDecisionBeforeAndAfterT146() throws {
    var seen = SeenDecisions()
    #expect(seen.news(try board(decisions: nil), team: "alpha").isEmpty, "the first read tells nothing")
    #expect(seen.news(try board(), team: "alpha").map(\.id) == ["D#1"], "T1:? and T1:1 are one decision; D#1 is new")
}

/// The fixture's wait of T1 as a board lists it, asked at `at`.
private func waitOfT1(at: String) throws -> TaskBoardStatus {
    try board(decisions: #"[{"id":"T1:1","task_id":"T1","tasks":["T1"],"state":"open","question":"결정 목록은 어느 창에 둡니까?","asked_at":"\#(at)"}]"#)
}

@Test func R4aL1_aWaitStampedAMomentApartIsOneDecision() throws {
    var seen = SeenDecisions()
    _ = seen.news(try waitOfT1(at: "2026-11-16T07:00:00.100Z"), team: "alpha")
    #expect(seen.news(try waitOfT1(at: "2026-11-16T07:00:00.101Z"), team: "alpha").isEmpty, "1 ms apart: the same wait")
    #expect(seen.news(try waitOfT1(at: "2026-11-16T07:05:00.000Z"), team: "alpha").map(\.id) == ["T1:1"],
            "the same question asked again minutes later is a new decision")
}

@Test func R4aL2_eachTeamsFirstReadTellsNothing() throws {
    var seen = SeenDecisions()
    _ = seen.news(try board(decisions: "[]"), team: "beta")
    #expect(seen.news(try board(), team: "alpha").isEmpty, "alpha's first good read came late: still nothing")
    #expect(seen.news(try board(), team: "alpha").isEmpty)
}

@Test func aPickedDecisionStaysPickedAndIsToldFromATask() throws {
    let s = try board()
    #expect(keepTaskSelection("D#1", in: s) == "D#1")
    #expect(keepTaskSelection("T1:1", in: s) == "T1:1")
    #expect(keepTaskSelection("D#7", in: s) == nil)
    #expect(isDecisionId("D#1") && isDecisionId("T1:1") && !isDecisionId("T1") && !isDecisionId("D1"))
}
