import Foundation
import Testing
@testable import TowerCore

// `my-team api goal-order --json` read into a model (T213). Fixtures/goal-order.json is the real output of my-team
// at T212 (4af917d) for a temporary team: G2 without `## 순서`, the dashboard order G3 against a board where
// T178–T181 are under way and T181 reported item 1, the cycle G4, the syntax error G5.

private func ok(_ json: String) -> CommandResult { CommandResult(status: 0, stdout: json, stderr: "") }

private func goals(_ json: String) throws -> [GoalOrder] {
    guard case .ok(let g) = parseGoalOrder(ok(json)) else { throw MyTeamError(description: "not ok") }
    return g
}

@Test func goalOrderJSONBecomesTheModel() throws {
    let all = try goals(fixture("goal-order.json"))
    #expect(all.map(\.id) == ["G2", "G3", "G4", "G5"])
    let plain = all[0]
    #expect(plain.title == "no order yet" && plain.waves.isEmpty && plain.cycle == nil && plain.errors.isEmpty)

    let dash = all[1]
    #expect(dash.title == "대시보드: 사용량·인사이트")
    #expect(dash.waves.map { $0.map(\.ref) } == [["T178"], ["T179", "T180"], ["T181", "T177"], ["T177:4-7"], ["T192"]])
    #expect(dash.readyNow == ["T178"] && dash.unregistered == ["T192"])
    let range = dash.waves[3][0]
    #expect(range.task == "T177" && range.items == [4, 5, 6, 7] && range.title == "title T177")
    #expect(range.state == "ready" && range.status == "waiting")
    #expect(range.after.map(\.ref) == ["T179", "T180", "T181:1"] && range.after[2].items == [1])
    #expect(range.blockedBy == [GoalBlock(ref: "T179", state: "doing"), GoalBlock(ref: "T180", state: "doing")],
            "T181 item 1 is reported, so it no longer blocks")
    let notOnBoard = dash.waves[4][0]
    #expect(notOnBoard.status == "unregistered" && notOnBoard.title == nil && notOnBoard.state == nil && notOnBoard.items == nil)
}

@Test func aCycleOrASyntaxErrorHasNoWaves() throws {
    let all = try goals(fixture("goal-order.json"))
    let loop = all[2], typo = all[3]
    #expect(loop.cycle == ["A", "B", "A"] && loop.waves.isEmpty && loop.readyNow.isEmpty)
    #expect(typo.cycle == nil && typo.waves.isEmpty)
    #expect(typo.errors == [GoalOrderError(line: 4, text: "- A => C", reason: #"expected exactly one "->""#)])
}

@Test func emptyWavesAndUnknownFieldsRead() throws {
    let all = try goals("""
        {"ok":true,"later":1,"goals":[{"id":"G1","title":null,"path":"/tmp/example/G1-x.md","waves":[],"ready_now":[],
         "unregistered":[],"cycle":null,"errors":[],"later":{"a":1}}]}
        """)
    #expect(all.count == 1 && all[0].title == nil && all[0].waves.isEmpty)
    #expect(try goals(#"{"ok":true,"goals":[]}"#).isEmpty)
}

@Test func twoFilesWithOneGNumberAreBothKept() throws {
    // my-team T212 R7 L1: G3-a.md and G3-b.md both come out as G3
    func goal(_ path: String) -> String {
        #"{"id":"G3","title":"t","path":"\#(path)","waves":[],"ready_now":[],"unregistered":[],"cycle":null,"errors":[]}"#
    }
    let all = try goals(#"{"ok":true,"goals":[\#(goal("/tmp/example/G3-a.md")),\#(goal("/tmp/example/G3-b.md"))]}"#)
    #expect(all.map(\.id) == ["G3", "G3"])
    #expect(Set(all.map(\.path)).count == 2 && Set(all).count == 2)
}

@Test func anOlderMyTeamIsUnsupportedAndOtherFailuresStayFailures() {
    func read(_ status: Int32, _ out: String, _ err: String = "") -> GoalOrderRead { parseGoalOrder(CommandResult(status: status, stdout: out, stderr: err)) }
    // what my-team before T212 answers (commander), measured with the installed one
    #expect(read(1, "", "error: unknown command 'goal-order'\n") == .unsupported)
    #expect(read(1, #"{"ok":false,"code":"not-found","message":"no goal G4"}"#) == .failed(.code("not-found", "no goal G4")))
    #expect(read(1, "", "error: unknown command 'other'\n") == .failed(.unreadable("error: unknown command 'other'")))
    #expect(read(127, "", "env: node: No such file or directory") == .failed(.launch("env: node: No such file or directory")))
}

@Test func goalOrderIsReadOnlyForOpenViews() {
    var calls: [[String]] = []
    let run: TaskBoardRunner = { argv, _, _ in calls.append(argv); return ok(#"{"ok":true,"goals":[]}"#) }
    #expect(readGoalOrders(openViews: [], bin: "/opt/example/my-team", run: run).isEmpty)
    #expect(calls.isEmpty, "no order view open: my-team is never run")
    let reads = readGoalOrders(openViews: ["shop"], bin: "/opt/example/my-team", run: run)
    #expect(reads == ["shop": .ok([])])
    #expect(calls == [["/opt/example/my-team", "api", "goal-order", "--input", #"{"team_name":"shop"}"#, "--json"]])
}
