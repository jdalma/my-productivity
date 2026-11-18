import Foundation
import Testing
@testable import TowerCore

@Test func parseTmuxTargetParsesTheSessionsJsonTmuxField() {
    #expect(parseTmuxTarget("my-team-demo-team-mvtepzfv:@5.%42")
        == TmuxRef(session: "my-team-demo-team-mvtepzfv", window: "@5", pane: "%42"))
    #expect(parseTmuxTarget(nil) == nil)
    #expect(parseTmuxTarget("garbage") == nil)
}

@Test func handleOfPrefersThePaneHandle() {
    #expect(handleOf(TmuxRef(session: "s", window: "@1", pane: "%7"), pid: 123) == "pane:s:%7")
    #expect(handleOf(nil, pid: 123) == "pid:123")
}

@Test func fixtureBoardConformsToTheModelVocabulary() throws {
    let board = try JSONDecoder().decode(Board.self, from: fixtureData("board.json"))
    for t in board.teams {
        for w in t.workers { #expect(w.handle == "pane:\(t.sessionName):\(w.paneId)") }
    }
    for s in board.loose { #expect(s.handle == handleOf(s.tmux, pid: s.pid)) }
}

private func keySets(_ json: Any, path: String = "$") -> [String: Set<String>] {
    var out: [String: Set<String>] = [:]
    if let o = json as? [String: Any] {
        out[path] = Set(o.keys)
        for (k, v) in o { out.merge(keySets(v, path: "\(path).\(k)")) { $0.union($1) } }
    } else if let a = json as? [Any] {
        for v in a { out.merge(keySets(v, path: "\(path)[]")) { $0.union($1) } }
    }
    return out
}

@Test func boardFixtureRoundTripsWithTheSameKeysAndNulls() throws {
    let data = try fixtureData("board.json")
    let encoded = try JSONEncoder().encode(JSONDecoder().decode(Board.self, from: data))
    let original = try JSONSerialization.jsonObject(with: data)
    let again = try JSONSerialization.jsonObject(with: encoded)
    #expect(keySets(again) == keySets(original))
    #expect((again as! NSDictionary) == (original as! NSDictionary))
}
