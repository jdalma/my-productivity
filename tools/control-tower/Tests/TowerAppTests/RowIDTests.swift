import Testing
import TowerCore
@testable import TowerApp

private func session(_ handle: String, pid: Int) -> Session {
    Session(
        handle: handle, agent: .claude, pid: pid, cwd: "/x", startedAt: nil, status: .unknown,
        myTurn: true, since: nil, permissionPrompt: true, title: "", tmux: nil, transcript: nil,
        lastUser: "", lastAssistant: "", termProgram: nil)
}

/// Two unrecognized workers (pid 0) with permission modals, plus a second process claiming a worker's pane.
@Test func rowIDsStayUnique() {
    let rows = [
        session("pane:s:%1", pid: 0), session("pane:s:%2", pid: 0),
        session("pane:s:%3", pid: 10), session("pane:s:%3", pid: 11),
    ]
    #expect(Set(rows.map(\.pid)).count < rows.count)
    #expect(Set(rows.map(\.handle)).count < rows.count)
    #expect(Set(rows.map(\.rowID)).count == rows.count)
}
