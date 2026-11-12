import Foundation
import Testing
@testable import TowerCore

// One task's family from `board-status` with `task` (T70a): landings, verdicts, findings and notes, and the
// worker → task line. Fixtures use example names only.

private func taskJSON(_ id: String, _ state: String, parent: String? = nil, assignee: String? = "dev", reviewer: String? = "rv",
                      priority: Int = 100) -> String {
    func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
    return #"{"id":"\#(id)","parent_id":\#(q(parent)),"title":"title \#(id)","ticket_path":"/tmp/example/\#(id).md","state":"\#(state)","assignee":\#(q(assignee)),"reviewer":\#(q(reviewer)),"priority":\#(priority),"constraints":"none","created_at":"2026-11-11T00:00:00.000Z","created_by":"pm","updated_at":"2026-11-11T00:00:00.000Z"}"#
}

private let familyJSON = """
    {"ok":true,
     "root":\(taskJSON("T5", "done")),
     "tasks":[\(taskJSON("T5", "done")),\(taskJSON("T5a", "review", parent: "T5"))],
     "landings":[
       {"id":"T5#1","task_id":"T5","repo":"/tmp/example/repo","commit":"1111111aaaaaaa","base_commit":"0000000","commits":["1111111aaaaaaa"],
        "check_cmd":"swift test","check_result":"10 passed","focus":["a"],"closes":[],"report_path":"/tmp/example/r.md",
        "review_report_path":"/tmp/example/T5-review.md","deployed":null,"superseded_by":"T5#2","left_out":[],
        "created_at":"2026-11-11T01:00:00.000Z","created_by":"dev"},
       {"id":"T5#2","task_id":"T5","repo":"/tmp/example/repo","commit":"2222222bbbbbbb","base_commit":"0000000","commits":["2222222bbbbbbb"],
        "check_cmd":"swift test","check_result":"11 passed","focus":[],"closes":["R1 M1"],"report_path":null,
        "review_report_path":null,"deployed":{"at":"2026-11-11T05:00:00.000Z"},"superseded_by":null,"left_out":["3333333"],
        "created_at":"2026-11-11T02:00:00.000Z","created_by":"dev"},
       {"id":"T5a#1","task_id":"T5a","repo":"/tmp/example/repo","commit":"4444444","base_commit":"2222222","commits":["4444444"],
        "check_cmd":null,"check_result":null,"focus":[],"closes":["R2 L1"],"report_path":null,"review_report_path":null,
        "deployed":null,"superseded_by":null,"left_out":[],"created_at":"2026-11-11T03:00:00.000Z","created_by":"dev"}],
     "verdicts":[
       {"id":"R1","landing_id":"T5#1","verdict":"changes","verified_commit":"1111111aaaaaaa","report_path":"/tmp/example/T5-review.md",
        "rerun_cmd":"swift test","rerun_result":"10 passed","side_notes":null,"created_at":"2026-11-11T01:30:00.000Z","created_by":"rv"},
       {"id":"R2","landing_id":"T5#2","verdict":"approve","verified_commit":"2222222bbbbbbb","report_path":null,
        "rerun_cmd":null,"rerun_result":null,"side_notes":"looks fine","created_at":"2026-11-11T02:30:00.000Z","created_by":"rv"}],
     "findings":[
       {"id":"R1 M1","verdict_id":"R1","task_id":"T5","severity":"must","summary":"m","repro":"swift test --filter X","state":"fixed","fixed_in":"T5#2"},
       {"id":"R1 L1","verdict_id":"R1","task_id":"T5","severity":"low","summary":"l1","repro":null,"state":"backlog","fixed_in":null},
       {"id":"R1 L2","verdict_id":"R1","task_id":"T5","severity":"low","summary":"l2","repro":null,"state":"accepted-limit","fixed_in":null},
       {"id":"R1 L3","verdict_id":"R1","task_id":"T5","severity":"low","summary":"l3","repro":null,"state":"rejected","fixed_in":null},
       {"id":"R2 L1","verdict_id":"R2","task_id":"T5","severity":"low","summary":"l4","repro":null,"state":"fixed","fixed_in":"T5a#1"},
       {"id":"R2 R1","verdict_id":"R2","task_id":"T5","severity":"should","summary":"r","repro":null,"state":"open","fixed_in":null}],
     "notes":[
       {"seq":2,"task_id":"T5","body":"second","to":["pm"],"created_at":"2026-11-11T02:40:00.000Z","created_by":"dev"},
       {"seq":1,"task_id":"T5","body":"first","to":["dev","rv"],"created_at":"2026-11-11T01:40:00.000Z","created_by":"pm"}]}
    """

private func family() throws -> TaskFamily {
    guard case .success(let f) = parseTaskFamily(CommandResult(status: 0, stdout: familyJSON, stderr: "")) else {
        throw MyTeamError(description: "not ok")
    }
    return f
}

@Test func aFamilyBecomesCardsInTimeOrder() throws {
    let d = try #require(taskDetail(try family(), task: "T5"))
    #expect(d.task.id == "T5" && d.family.map(\.id) == ["T5", "T5a"])
    #expect(d.cards.map(\.landing.id) == ["T5#1", "T5#2", "T5a#1"], "the child's landing in the same timeline")
    #expect(d.cards[0].landing.supersededBy == "T5#2", "a superseded landing stays, marked")
    #expect(d.cards[1].landing.deployed && !d.cards[0].landing.deployed, "deployed: any value but null")
    #expect(d.cards[1].landing.leftOut == ["3333333"] && d.cards[0].landing.reviewReportPath == "/tmp/example/T5-review.md")
    #expect(d.cards.map { $0.verdicts.map(\.verdict.id) } == [["R1"], ["R2"], []], "verdicts under their landing")
    #expect(d.cards[0].verdicts[0].findings.map(\.id) == ["R1 M1", "R1 L1", "R1 L2", "R1 L3"])
    #expect(d.cards[1].verdicts[0].verdict.sideNotes == "looks fine")
    #expect(d.notes.map(\.seq) == [1, 2], "notes oldest first")
    #expect(d.notes[0].to == ["dev", "rv"])
    var shuffled = try family()
    shuffled.landings.reverse()
    #expect(taskDetail(shuffled, task: "T5")?.cards.map(\.landing.id) == ["T5#1", "T5#2", "T5a#1"], "by time, not by the answer's order")
}

@Test func findingStatesAreToldApart() throws {
    let d = try #require(taskDetail(try family(), task: "T5"))
    let byId = Dictionary(uniqueKeysWithValues: d.cards.flatMap(\.verdicts).flatMap(\.findings).map { ($0.id, $0) })
    let approved = d.approvedLandings
    #expect(findingStatus(byId["R1 M1"]!, approved: approved) == .fixedApproved("T5#2"))
    #expect(findingStatus(byId["R2 L1"]!, approved: approved) == .fixedPending("T5a#1"), "its landing has no approve yet")
    #expect(findingStatus(byId["R1 L1"]!, approved: approved) == .backlog)
    #expect(findingStatus(byId["R1 L2"]!, approved: approved) == .acceptedLimit)
    #expect(findingStatus(byId["R1 L3"]!, approved: approved) == .rejected)
    #expect(findingStatus(byId["R2 R1"]!, approved: approved) == .open)
    #expect(d.openFindings.map(\.id) == ["R2 L1", "R2 R1"], "open, and fixed in a landing not approved yet")
}

@Test func aChildsDetailShowsTheWholeFamily() throws {
    let d = try #require(taskDetail(try family(), task: "T5a"))
    #expect(d.task.id == "T5a" && d.cards.count == 3)
    #expect(d.openFindings.isEmpty, "open findings are the selected task's own")
    #expect(taskDetail(try family(), task: "T9") == nil)
}

@Test func failedFamilyReadsKeepTheirKind() {
    #expect(parseTaskFamily(CommandResult(status: 1, stdout: #"{"ok":false,"code":"not-found","message":"no task"}"#, stderr: ""))
            == .failure(.code("not-found", "no task")))
    #expect(parseTaskFamily(CommandResult(status: 0, stdout: "x", stderr: "")) == .failure(.unreadable("x")))
}

@Test func aWorkersTasksLineFollowsTheBoardsOrder() throws {
    let json = """
        {"tasks":[\(taskJSON("T1", "doing", assignee: "dev", priority: 50)),\(taskJSON("T2", "review", assignee: "other", reviewer: "dev")),
                  \(taskJSON("T3", "held", assignee: "dev")),\(taskJSON("T4", "done", assignee: "dev")),
                  \(taskJSON("T5", "cancelled", reviewer: "dev")),\(taskJSON("T6", "ready", assignee: "dev", priority: 10))],
         "workers":[],"recent":[],"announcements":[],
         "open_findings":[{"id":"R1 L1","task_id":"T4","severity":"low","summary":"s","state":"open"}]}
        """
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    let s = try d.decode(TaskBoardStatus.self, from: Data(json.utf8))
    #expect(workerTasks("dev", in: s).map(\.id) == ["T3", "T2", "T6", "T1"],
            "assignee or reviewer, unfinished only (T4 is done, though its open finding puts it in the action group); action, review, then active, each by priority")
    #expect(workerTasks("rv", in: s).map(\.id) == ["T3", "T6", "T1"], "the default reviewer of the fixture")
    #expect(workerTasks("nobody", in: s).isEmpty)
}

@Test func aReadKeepsWhatWasOpenWhileItIsThere() throws {
    let d = try #require(taskDetail(try family(), task: "T5"))
    #expect(keepOpenLandings(["T5#1", "T9#1"], in: d) == ["T5#1"], "a superseded card opened stays open; gone ones drop")
}
