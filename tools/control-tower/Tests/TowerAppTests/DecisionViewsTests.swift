import Foundation
import Testing
import TowerCore
@testable import TowerApp

// The board's decisions in the app (T147): 내 차례 (menu bar count, dropdown, notifications), the task board's counts
// and rows. Reading `decisions` is TowerCore's DecisionsTests.

private func status(decisions: String?, tasks: String = "") throws -> TaskBoardStatus {
    let json = """
        {"tasks":[\(tasks)],"workers":[],"open_findings":[],"recent":[],"announcements":[]\(decisions.map { #","decisions":\#($0)"# } ?? "")}
        """
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(TaskBoardStatus.self, from: Data(json.utf8))
}

private func decision(_ id: String, state: String = "open", task: String? = nil, tasks: [String] = [], at: String,
                      chosen: String? = nil, answer: String? = nil) -> String {
    func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
    return """
        {"id":"\(id)","task_id":\(q(task)),"tasks":[\(tasks.map { "\"\($0)\"" }.joined(separator: ","))],"state":"\(state)",
         "question":"question \(id)","asked_by":"dev","asked_at":"\(at)","chosen":\(q(chosen)),"answer":\(q(answer))}
        """
}

private func task(_ id: String, _ state: String, title: String = "title") -> String {
    #"{"id":"\#(id)","parent_id":null,"title":"\#(title)","state":"\#(state)","priority":100}"#
}

private func team(_ name: String, board: Bool = true) -> Team {
    var t = Team(name: name, sessionName: "my-team-\(name)", startedAt: nil, attached: true, workers: [])
    t.hasTaskBoard = board
    return t
}

private let A = "2026-11-16T07:00:00.000Z", B = "2026-11-16T07:01:00.000Z", C = "2026-11-16T07:02:00.000Z"

@Test func openDecisionsCountInMyTurnAndOnlyForATeamThatKeepsABoard() throws {
    let board = Board(at: C, teams: [team("alpha"), team("plain", board: false)], loose: [])
    let alpha = try status(decisions: "[\(decision("D#1", at: B)),\(decision("D#2", state: "answered", at: A)),\(decision("T1:1", task: "T1", tasks: ["T1"], at: A))]")
    let boards = ["alpha": alpha, "plain": alpha]
    #expect(myTurnShown(board) == 0, "no board read: the sessions only")
    #expect(myTurnShown(board, taskBoards: boards) == 2, "the two open decisions of alpha; plain keeps no board")
    #expect(waitingDecisions(board, taskBoards: boards).map(\.decision.id) == ["T1:1", "D#1"], "in the order asked")
    let ended = Board(at: C, teams: [], loose: [])
    #expect(myTurnShown(ended, taskBoards: boards) == 0, "a team no longer running has no turn")
}

@Test func theDropdownListsWaitingDecisionsThatOpenTheirTaskBoard() throws {
    let board = Board(at: C, teams: [team("alpha")], loose: [])
    let alpha = try status(decisions: "[\(decision("D#1", at: B))]")
    let sections = menuSections(menuModel(board, history: [], home: "/Users/me", taskBoards: ["alpha": alpha]))
    let s = try #require(sections.first { $0.title.hasPrefix("결정 대기") })
    #expect(s.title == "결정 대기 1 · 작업판에서 열기")
    #expect(s.lines == [MenuItemLine(title: "question D#1 · alpha", symbol: "person.fill.questionmark", target: .decision(team: "alpha", id: "D#1"))])
    #expect(!menuSections(menuModel(board, history: [], home: "/Users/me")).contains { $0.title.hasPrefix("결정 대기") }, "none without a decision")
}

@Test func onlyANewDecisionIsNotifiedAndOnce() throws {
    let one = try status(decisions: "[\(decision("D#1", at: A))]")
    let two = try status(decisions: "[\(decision("D#1", at: A)),\(decision("D#2", at: B))]")
    var seen = SeenDecisions()
    #expect(decisionsToNotify(seen: &seen, next: ["alpha": one]).isEmpty, "the first read after launch tells nothing")
    #expect(decisionsToNotify(seen: &seen, next: ["alpha": two]).map(\.decision.id) == ["D#2"])
    #expect(decisionsToNotify(seen: &seen, next: ["alpha": two]).isEmpty, "the same decision is not told twice")
    let answered = try status(decisions: "[\(decision("D#1", at: A)),\(decision("D#3", state: "answered", at: C))]")
    #expect(decisionsToNotify(seen: &seen, next: ["alpha": answered]).isEmpty, "an answered decision is no news")
}

@Test func R4aL2_aTeamWhoseFirstReadFailedTellsNothingOnItsFirstGoodRead() throws {
    let one = try status(decisions: "[\(decision("D#1", at: A))]")
    let two = try status(decisions: "[\(decision("D#1", at: A)),\(decision("D#2", at: B))]")
    var seen = SeenDecisions()
    #expect(decisionsToNotify(seen: &seen, next: ["beta": one]).isEmpty, "launch: alpha's read failed, beta's went")
    #expect(decisionsToNotify(seen: &seen, next: ["alpha": two, "beta": one]).isEmpty, "alpha's first good read: what waits is no news")
    let three = try status(decisions: "[\(decision("D#1", at: A)),\(decision("D#2", at: B)),\(decision("D#3", at: C))]")
    #expect(decisionsToNotify(seen: &seen, next: ["alpha": three, "beta": one]).map(\.decision.id) == ["D#3"])
}

@Test func R4L1_aTeamStartedAgainTellsWhatWasAskedWhileItWasDown() throws {
    let one = try status(decisions: "[\(decision("D#1", at: A))]")
    let later = try status(decisions: "[\(decision("D#1", at: A)),\(decision("D#2", at: B))]")
    var seen = SeenDecisions()
    _ = decisionsToNotify(seen: &seen, next: ["alpha": one])
    #expect(decisionsToNotify(seen: &seen, next: [:]).isEmpty, "the team is down")
    #expect(decisionsToNotify(seen: &seen, next: ["alpha": later]).map(\.decision.id) == ["D#2"],
            "back up: the one asked meanwhile, not the one already told")
}

@Test func R4L4_aWaitIsNotToldAgainWhenTheBoardStartsListingDecisions() throws {
    let before = try status(decisions: nil, tasks: #"{"id":"T1","parent_id":null,"title":"t","state":"waiting","priority":100,"waiting":{"question":"question T1:1","asked_at":"\#(A)"}}"#)
    let after = try status(decisions: "[\(decision("T1:1", task: "T1", tasks: ["T1"], at: A))]")
    var seen = SeenDecisions()
    _ = decisionsToNotify(seen: &seen, next: ["alpha": before])
    #expect(decisionsToNotify(seen: &seen, next: ["alpha": after]).isEmpty)
}

@MainActor @Test func aDryRunDecisionNotificationIsALine() throws {
    let log = FileManager.default.temporaryDirectory.appending(path: "ct-decision-\(UUID().uuidString).log").path
    defer { try? FileManager.default.removeItem(atPath: log) }
    let n = Notifier(onClick: { _ in }, dryRun: log)
    let s = try status(decisions: "[\(decision("D#1", at: A))]")
    n.post(WaitingDecision(team: "alpha", decision: openDecisions(s)[0]))
    #expect(try String(contentsOfFile: log, encoding: .utf8) == "notify alpha · 결정 대기: question D#1 [D#1]\n")
}

@Test func theBoardsUserCountIsItsOpenDecisions() throws {
    let s = try status(decisions: "[\(decision("D#1", at: A)),\(decision("D#2", at: B)),\(decision("D#3", state: "answered", at: C))]",
                       tasks: task("T1", "doing"))
    #expect(TaskCounts(s).user == 2, "decisions, not waiting tasks")
    let before = try status(decisions: nil, tasks: task("T1", "waiting"))
    #expect(TaskCounts(before).user == 1, "a waiting task without its brief still waits for the user (R4 S1)")
}

@Test func aDecisionRowNamesItsTasksOrSaysItHasNone() throws {
    let s = try status(decisions: "[\(decision("D#1", tasks: ["T1", "T9"], at: A)),\(decision("D#2", at: B)),\(decision("D#3", state: "answered", at: C, chosen: "A", answer: "사용자: 좋다"))]",
                       tasks: task("T1", "doing", title: "결정 목록 화면"))
    let open = openDecisions(s)
    #expect(decisionTasksText(open[0], tasks: s.tasks, team: "alpha") == "T1 결정 목록 화면, T9", "a task off the board keeps its id")
    #expect(decisionTasksText(open[1], tasks: s.tasks, team: "alpha") == "작업 없음")
    let past = pastDecisions(s)[0]
    #expect(decisionAnswerText(past) == "A — 사용자: 좋다")
    #expect(decisionAccessibilityValue(past, tasks: s.tasks, team: "alpha", now: Date()).hasPrefix("답함, A — 사용자: 좋다, 작업 없음"))
    #expect(decisionMatches(open[0], query: "T9") && decisionMatches(open[1], query: "question d#2") && !decisionMatches(open[1], query: "T1"))
    let bare = try status(decisions: nil, tasks: task("T7", "waiting"))
    #expect(decisionQuestion(openDecisions(bare)[0]) == "T7의 결정 (질문이 기록되지 않음)")
}

@Test func aPickedDecisionReadsNoTaskFamily() {
    var picks = TaskBoardPicks()
    _ = picks.open("alpha", task: "D#1")
    _ = picks.open("beta", task: "T3")
    #expect(picks.reads(open: ["alpha", "beta"]) == [TaskRef(team: "beta", task: "T3")])
}

@Test func D1_theBoardsAreReadWithEveryWindowClosedEvery15Seconds() {
    let t = Date(timeIntervalSince1970: 1_000)
    #expect(taskBoardReadDue(windowsOpen: true, last: t, now: t), "a window open: every call reads (the 5 s timer, ⌘R)")
    #expect(taskBoardReadDue(windowsOpen: false, last: nil, now: t), "closed, never read: read")
    #expect(!taskBoardReadDue(windowsOpen: false, last: t, now: t.addingTimeInterval(10)))
    #expect(taskBoardReadDue(windowsOpen: false, last: t, now: t.addingTimeInterval(15)))
}

// MARK: - the detail as a document (T155)

@Test func aTasksDecisionTagSaysItsIdAndWhetherItWaitsOrWhatWasChosen() throws {
    let s = try status(decisions: "[" + [
        decision("D#1", tasks: ["T1"], at: "2026-11-11T00:00:00.000Z"),
        decision("T1:1", state: "answered", task: "T1", at: "2026-11-11T00:00:00.000Z", chosen: "A", answer: "go"),
        decision("D#2", state: "answered", tasks: ["T1"], at: "2026-11-11T00:00:00.000Z", answer: "in words"),
    ].joined(separator: ",") + "]", tasks: task("T1", "doing"))
    #expect(boardDecisions(s).map(decisionTagText) == ["D#1 답을 기다림", "T1:1 답함 · A", "D#2 답함"])
}

@Test func aFamilyTaskIsNamedByHowItStandsToTheOneShown() throws {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    func t(_ id: String, parent: String?) throws -> TaskBoardTask {
        try d.decode(TaskBoardTask.self, from: Data(#"{"id":"\#(id)","parent_id":\#(parent.map { "\"\($0)\"" } ?? "null"),"title":"t","state":"doing","priority":100}"#.utf8))
    }
    let root = try t("T1", parent: nil), a = try t("T2", parent: "T1"), b = try t("T3", parent: "T1")
    #expect(relationWord(root, to: a) == "상위")
    #expect(relationWord(a, to: root) == "하위")
    #expect(relationWord(b, to: a) == nil, "a sibling")
}

@Test func aNameKeepsOneColorOfTheListAndAMarkdownFileIsPreviewed() {
    #expect(personColor("core") == personColor("core"))
    #expect(Set(["core", "pm", "reviewer", "designer", "detail", "mac-ux", "tools", "", "한글"].map(personColor)).isSubset(of: Set(personColors)))
    #expect(previewsAsMarkdown("/tmp/example/T1-report.md") && previewsAsMarkdown("a.MD"))
    #expect(!previewsAsMarkdown("/tmp/example/report.txt") && !previewsAsMarkdown("/tmp/example/md"))
}

@Test func eachCalloutHasItsOwnNameAndSymbol() {
    let styles = CalloutKind.allCases.map(CalloutStyle.of)
    #expect(Set(styles.map(\.label)).count == 5 && Set(styles.map(\.symbol)).count == 5)
}
