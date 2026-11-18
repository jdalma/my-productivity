import Foundation
import Testing
@testable import TowerCore

@Test func theSearchPathCoversHomebrewForGUIApps() {
    #expect(searchPath.contains("/opt/homebrew/bin"))
    #expect(searchPath.contains("/usr/local/bin"))
}

private func failingDeps(_ teams: @escaping ([Pane]) throws -> [RawTeam]) -> CollectDeps {
    var d = CollectDeps.stub
    d.loadTeams = teams
    return d
}

@Test func aFailingMyTeamIsReportedNextToTheBoard() {
    let s = snapshot(deps: failingDeps { _ in throw MyTeamError(description: "cannot read my-team state dir /x: boom") })
    #expect(s.board.teams.isEmpty)
    #expect(s.myTeamError == "cannot read my-team state dir /x: boom")
}

@Test func aWorkingMyTeamReportsNoError() {
    #expect(snapshot(deps: failingDeps { _ in [] }).myTeamError == nil)
}

@Test func onlyLiveTeamsReachTheBoardAndTheyShareCollectsPaneListing() {
    let pane = Pane(session: "s", window: "@1", pane: "%1", pid: 1, dead: false, workerName: "w", title: "", cwd: "/")
    var d = failingDeps { panes in
        #expect(panes == [pane])
        return [true, false].map { RawTeam(teamName: "\($0)", session: "s:0", startedAt: nil, teamAlive: $0, workers: []) }
    }
    d.listPanes = { [pane] }
    #expect(snapshot(deps: d).board.teams.map(\.name) == ["true"])
}
