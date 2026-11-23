import Foundation
import Testing
@testable import TowerCore
@testable import TowerApp

// The 순서 view's words and order (T214, design design/goal-order-view.md). The goals come from TowerCoreTests'
// goal-order.json: my-team's real answer at T212 for G2 (no order), G3 (the dashboard: T178 doing; T179, T180
// doing; T181 doing, T177 ready; T177:4-7; T192 not on the board), G4 (a cycle), G5 (a syntax error).

private func fixtureGoals() throws -> [GoalOrder] {
    struct Answer: Decodable { var goals: [GoalOrder] }
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "../TowerCoreTests/Fixtures/goal-order.json").standardized
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(Answer.self, from: Data(contentsOf: url)).goals
}

private func node(_ ref: String, state: String?, status: String, blocked: [(String, String)] = [], after: [String] = [],
                  title: String? = "t") -> GoalNode {
    let parts = ref.split(separator: ":")
    func items(_ s: Substring?) -> [Int]? {
        guard let s else { return nil }
        let r = s.split(separator: "-").compactMap { Int($0) }
        return r.count == 2 ? Array(r[0]...r[1]) : r
    }
    let refs = after.map { a -> GoalRef in
        let p = a.split(separator: ":")
        return GoalRef(ref: a, task: String(p[0]), items: items(p.count > 1 ? p[1] : nil))
    }
    return GoalNode(ref: ref, task: String(parts[0]), items: items(parts.count > 1 ? parts[1] : nil), after: refs,
                    title: state == nil ? nil : title, state: state, status: status,
                    blockedBy: blocked.map { GoalBlock(ref: $0.0, state: $0.1) })
}

private func goal(_ id: String, _ waves: [[GoalNode]], cycle: [String]? = nil, errors: [GoalOrderError] = []) -> GoalOrder {
    GoalOrder(id: id, title: "title \(id)", path: "/tmp/example/\(id).md", waves: waves, readyNow: [], unregistered: [],
              cycle: cycle, errors: errors)
}

@Test func aCardSaysWhatTheTaskWaitsForInWords() throws {
    let g3 = try fixtureGoals()[1]
    let lines = g3.waves.map { $0.map { GoalCardLine($0).text() } }
    // T178 is ready_now but already under way: not 지금 시작 가능 (design §2 주의)
    #expect(lines == [["진행 중"], ["대기: T178", "대기: T178"], ["대기: T179, T180", "대기: T179, T180"],
                      ["대기: T179, T180"], ["작업판에 없음"]])
    #expect(GoalCardLine(node("T1", state: "ready", status: "ready_now")).text() == "지금 시작 가능")
    #expect(GoalCardLine(node("T1", state: "new", status: "ready_now")) == .startable)
    #expect(GoalCardLine(node("T1", state: "done", status: "done")).text() == "완료")
    #expect(GoalCardLine(node("T1", state: "cancelled", status: "waiting", blocked: [("T0", "doing")])).text() == "취소됨")
    // an item and a range read as items; more than three predecessors are cut, the tooltip has them all
    let many = GoalCardLine(node("T9", state: "ready", status: "waiting",
                                 blocked: [("T181:1", "doing"), ("T177:4-7", "ready"), ("T5", "doing"), ("T6", "doing")]))
    #expect(many.text() == "대기: T181 할 일 1, T177 할 일 4–7 외 2")
    #expect(many.text(full: true) == "대기: T181 할 일 1, T177 할 일 4–7, T5, T6")
    let stuck = GoalCardLine(node("T9", state: "ready", status: "waiting", blocked: [("T179", "cancelled")]))
    #expect(stuck.text() == "대기: T179 (취소됨)" && stuck.blockedByCancelled)
}

@Test func aCardReadsAsOneLineToVoiceOver() throws {
    let g3 = try fixtureGoals()[1]
    #expect(goalCardSpoken(g3.waves[3][0]) == "T177 할 일 4에서 7, title T177, 시작 전, 대기: T179, T180")
    #expect(goalCardSpoken(g3.waves[4][0]) == "T192, 작업판에 없음")
    #expect(goalCardSpoken(g3.waves[0][0]) == "T178, title T178, 진행 중")  // the status line only names the state: once
    #expect(goalCardSpoken(node("T1", state: "done", status: "done")) == "T1, t, 완료")
    #expect(goalRefSpoken("T177:4-7") == "T177 할 일 4에서 7" && goalRefLabel("T181:1") == "T181 할 일 1")
}

@Test func aWavesCardsGoStartableFirstAndNotOnTheBoardLast() {
    let wave = [
        node("T5", state: nil, status: "unregistered"),
        node("T4", state: "done", status: "done"),
        node("T3", state: "ready", status: "waiting", blocked: [("T1", "doing")]),
        node("T2", state: "doing", status: "ready_now"),
        node("T6", state: "cancelled", status: "cancelled"),
        node("T10", state: "ready", status: "ready_now"),
        node("T1", state: "ready", status: "ready_now"),
    ]
    #expect(waveCards(wave).map(\.ref) == ["T1", "T10", "T2", "T3", "T4", "T6", "T5"])
}

@Test func aWaveHeadCountsClosedNodesAndChecksOnlyAllComplete() {
    let done = WaveHead([node("T1", state: "done", status: "done"), node("T2", state: "done", status: "done")], number: 1)
    #expect(done.count == "2/2" && done.allComplete && done.spoken == "단계 1, 작업 2개 중 2개 완료")
    // a cancelled node closes the wave's count, and keeps the check off (R4 S1)
    let cancelled = WaveHead([node("T1", state: "done", status: "done"), node("T2", state: "cancelled", status: "cancelled")], number: 2)
    #expect(cancelled.count == "2/2" && !cancelled.allComplete)
    #expect(WaveHead([node("T1", state: "doing", status: "ready_now")], number: 3).count == "0/1")
}

@Test func theWavesStackAllOrNone() {
    // design §2: 5 waves × 200 + 4 × 12 = 1048
    #expect(!wavesStack(waves: 5, width: 1048, scale: 1))
    #expect(wavesStack(waves: 5, width: 1047, scale: 1))
    #expect(!wavesStack(waves: 5, width: 848, scale: 0.8))   // 160 a column at 0.8
    #expect(wavesStack(waves: 2, width: 800, scale: 2))      // 400 a column at 2.0
    #expect(!wavesStack(waves: 1, width: 200, scale: 1))
}

@Test func aGoalsTagAndPlaceFollowItsTasks() throws {
    let all = try fixtureGoals()
    #expect(all.map { GoalTag($0) } == [.noOrder, .underWay(1), .cycle, .unreadable])
    let startable = goal("G7", [[node("T1", state: "ready", status: "ready_now")]])
    let done = goal("G1", [[node("T1", state: "done", status: "done"), node("T2", state: "cancelled", status: "cancelled")]])
    // a cancelled predecessor leaves a waiting task: not 모두 끝남, but pm's to fix (R4 S1)
    let stuck = goal("G8", [[node("T1", state: "cancelled", status: "cancelled")],
                            [node("T2", state: "ready", status: "waiting", blocked: [("T1", "cancelled")], after: ["T1"])]])
    #expect(GoalTag(startable).text == "지금 시작 가능 1" && GoalTag(done) == .allDone && GoalTag(stuck) == .cancelledPredecessor(1))
    #expect(GoalTag(stuck).text == "취소된 선행 1" && GoalTag(stuck).warns)
    #expect(goalsInOrder(all + [startable, done, stuck]).map(\.id) == ["G7", "G3", "G4", "G5", "G8", "G2", "G1"])
    // only a goal all done starts folded; what the user did stays
    #expect(goalFolded(done, stored: [:]) && !goalFolded(stuck, stored: [:]))
    #expect(!goalFolded(done, stored: [done.path: false]) && goalFolded(startable, stored: [startable.path: true]))
    #expect(goalSpoken(all[1]) == "목표 G3, 대시보드: 사용량·인사이트, 진행 중 1, 단계 5개")
    #expect(goalErrorLine(all[3].errors) == #"순서 4번째 줄을 읽지 못함: expected exactly one "->""#)
    let twoFiles = goal("G5", [], errors: ["a", "b"].map { GoalOrderError(line: nil, text: "/tmp/G5-\($0).md", reason: "G5 names 2 files") })
    #expect(GoalTag(twoFiles) == .unreadable && goalErrorLine(twoFiles.errors) == "목표 파일 오류: G5 names 2 files 외 1")
}

@Test func theOrderViewShowsOnlyWhereMyTeamCanAnswerIt() {
    #expect(TaskBoardMode.shown(stored: "order", supported: true) == .order)
    #expect(TaskBoardMode.shown(stored: "order", supported: false) == .panels)  // an older my-team: the board as before
    #expect(TaskBoardMode.shown(stored: nil, supported: true) == .panels)
    #expect(TaskBoardMode.shown(stored: "later", supported: true) == .panels)
}

@Test func theSearchDimsCardsAndKeepsThemInPlace() throws {
    let n = try fixtureGoals()[1].waves[3][0]
    #expect(goalCardMatches(n, query: "") && goalCardMatches(n, query: "t177") && goalCardMatches(n, query: "title"))
    #expect(!goalCardMatches(n, query: "T181"))
}

@Test func theArrowsMoveWithinAWaveAndToTheSameHeightNextToIt() {
    let sizes = [1, 2, 0, 3]
    #expect(movedCard((1, 0), .down, sizes: sizes)! == (1, 1))
    #expect(movedCard((1, 1), .down, sizes: sizes) == nil)
    #expect(movedCard((0, 0), .up, sizes: sizes) == nil)
    #expect(movedCard((1, 1), .left, sizes: sizes)! == (0, 0))   // the last card when the next wave is shorter
    #expect(movedCard((1, 1), .right, sizes: sizes)! == (3, 1))  // an empty wave is skipped
    #expect(movedCard((3, 2), .right, sizes: sizes) == nil)
}

@Test func aTasksDetailNamesItsGoalAndWhatItWaitsFor() throws {
    let all = try fixtureGoals()
    let t181 = goalLinks(of: "T181", in: all)
    #expect(t181.count == 1 && t181[0].goalLine == "G3 대시보드: 사용량·인사이트 · 단계 3/5")
    #expect(t181[0].before.map(\.task) == ["T179", "T180"] && t181[0].before.allSatisfy { $0.caption == nil })
    // T177's range waits for T181's item 1, and T192 for T181: one relation reads the same from both ends (R4 L2)
    #expect(t181[0].after == [GoalRelation(task: "T177", caption: "할 일 4–7 · 할 일 1에서", spoken: "할 일 4에서 7, 할 일 1 이후"),
                              GoalRelation(task: "T192", caption: nil, spoken: nil)])
    let t177 = goalLinks(of: "T177", in: all)
    #expect(t177[0].wave == 3)
    #expect(t177[0].before.contains(GoalRelation(task: "T181", caption: "할 일 4–7 · 할 일 1에서", spoken: "할 일 4에서 7, 할 일 1 이후")))
    #expect(t177[0].before.filter { $0.task == "T179" }.map(\.caption) == [nil, "할 일 4–7"])
    #expect(goalLinks(of: "T999", in: all).isEmpty)  // in no order: no 목표·선행·후행 lines
}

@Test func arrowsGoFromEachPredecessorsCardToItsSuccessor() throws {
    let g3 = try fixtureGoals()[1]
    #expect(goalEdges(g3) == [
        GoalEdge(from: "T178", to: "T179"), GoalEdge(from: "T178", to: "T180"),
        GoalEdge(from: "T179", to: "T181"), GoalEdge(from: "T180", to: "T181"),
        GoalEdge(from: "T179", to: "T177"), GoalEdge(from: "T180", to: "T177"),
        GoalEdge(from: "T179", to: "T177:4-7"), GoalEdge(from: "T180", to: "T177:4-7"),
        GoalEdge(from: "T181", to: "T177:4-7"),  // T181:1 has no card of its own: from T181's
        GoalEdge(from: "T177", to: "T192"), GoalEdge(from: "T181", to: "T192"),
    ])
    #expect(goalEdges(goal("G9", [[node("T2", state: "ready", status: "waiting", after: ["T1"])]])).isEmpty)  // T1 has no card
}
