import Testing
import TowerCore
@testable import TowerApp

private func session(_ handle: String, myTurn: Bool) -> Session {
    Session(
        handle: handle, agent: .claude, pid: 1, cwd: "/x", startedAt: nil, status: myTurn ? .wait : .busy,
        myTurn: myTurn, since: nil, permissionPrompt: false, title: "", tmux: nil, transcript: nil,
        lastUser: "", lastAssistant: "", termProgram: nil)
}

private func board(_ sessions: Session...) -> Board {
    Board(at: "", teams: [], loose: sessions)
}

@Test func firstSnapshotNeverNotifies() {
    #expect(newlyMyTurn(prev: nil, next: board(session("a", myTurn: true))).isEmpty)
}

@Test func falseToTrueNotifiesOnce() {
    let before = board(session("a", myTurn: false), session("b", myTurn: true))
    let after = board(session("a", myTurn: true), session("b", myTurn: true))
    #expect(newlyMyTurn(prev: before, next: after).map(\.handle) == ["a"])
    #expect(newlyMyTurn(prev: after, next: after).isEmpty)
}

@Test func newSessionAlreadyWaitingDoesNotNotify() {
    #expect(newlyMyTurn(prev: board(), next: board(session("a", myTurn: true))).isEmpty)
}

@Test func teamWorkersCount() {
    let w = { (t: Bool) in
        Worker(session: session("pane:s:%1", myTurn: t), workerName: "w", role: nil, description: "", paneId: "%1",
               alive: true, spool: 0, inbox: 0, sentPending: 0, oldestPendingAt: nil, stateFile: nil)
    }
    let team = { (t: Bool) in Board(at: "", teams: [Team(name: "t", sessionName: "s", startedAt: nil, attached: true, workers: [w(t)])], loose: []) }
    #expect(newlyMyTurn(prev: team(false), next: team(true)).map(\.handle) == ["pane:s:%1"])
}
