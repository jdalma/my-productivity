import Foundation
import Testing
import TowerCore
@testable import TowerApp

// T92: the task detail's summary, finding lines and history (design task-board-window-v3.md §3). Example names only.

private func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }
private func list(_ xs: [String]) -> String { "[" + xs.map { q($0) }.joined(separator: ",") + "]" }

private func task(_ state: String, assignee: String? = "dev", assignedAt: String = "2026-11-11T00:00:30.000Z",
                  updatedBy: String? = "pm") -> String {
    #"{"id":"T1","parent_id":null,"title":"example","ticket_path":"/tmp/example/T1.md","state":"\#(state)","assignee":\#(q(assignee)),"reviewer":"rv","priority":100,"base_commit":"0000000aaaa","constraints":"none","assigned_at":"\#(assignedAt)","created_at":"2026-11-11T00:00:00.000Z","created_by":"pm","updated_at":"2026-11-11T05:00:00.000Z","updated_by":\#(q(updatedBy))}"#
}

private func landing(_ id: String, at: String, focus: [String] = ["a"], closes: [String] = [], supersededBy: String? = nil) -> String {
    #"{"id":"\#(id)","task_id":"\#(landingTask(id))","commit":"1111111aaaaaaa","check_cmd":"swift test","check_result":"ok","focus":\#(list(focus)),"closes":\#(list(closes)),"report_path":null,"review_report_path":null,"deployed":null,"superseded_by":\#(q(supersededBy)),"left_out":[],"created_at":"2026-11-11T\#(at):00.000Z","created_by":"dev"}"#
}

private func verdict(_ id: String, on landing: String, _ verdict: String, at: String, by: String = "rv") -> String {
    #"{"id":"\#(id)","landing_id":"\#(landing)","verdict":"\#(verdict)","report_path":null,"rerun_cmd":null,"rerun_result":null,"side_notes":null,"created_at":"2026-11-11T\#(at):00.000Z","created_by":"\#(by)"}"#
}

private func finding(_ id: String, by verdict: String, _ severity: String, _ state: String = "open", fixedIn: String? = nil) -> String {
    #"{"id":"\#(id)","verdict_id":"\#(verdict)","task_id":"T1","severity":"\#(severity)","summary":"s","repro":null,"state":"\#(state)","fixed_in":\#(q(fixedIn))}"#
}

private func detail(_ task: String, landings: [String] = [], verdicts: [String] = [], findings: [String] = [],
                    elsewhere: String = "[]") throws -> TaskDetail {
    let json = """
        {"root":\(task),"tasks":[\(task)],"landings":[\(landings.joined(separator: ","))],"verdicts":[\(verdicts.joined(separator: ","))],
         "findings":[\(findings.joined(separator: ","))],"notes":[],"fixed_elsewhere":\(elsewhere)}
        """
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try #require(taskDetail(try d.decode(TaskFamily.self, from: Data(json.utf8)), task: "T1"))
}

private func summary(_ task: String, landings: [String] = [], verdicts: [String] = [], findings: [String] = []) throws -> TaskSummary {
    taskSummary(try detail(task, landings: landings, verdicts: verdicts, findings: findings))
}

@Test func theSummaryTellsTheLastEventAndWhoseMoveItIsInEveryState() throws {
    #expect(try summary(task("new", assignee: nil))
            == TaskSummary(at: "2026-11-11T00:00:00.000Z", event: "pm이 등록했습니다", rest: "pm이 담당을 정할 차례입니다"))
    #expect(try summary(task("ready"))
            == TaskSummary(at: "2026-11-11T00:00:30.000Z", event: "dev에게 맡겼습니다", rest: "dev가 시작할 차례입니다"))
    #expect(try summary(task("doing")) == TaskSummary(at: "2026-11-11T05:00:00.000Z", event: "dev가 작업 중입니다", rest: "아직 제출 없음"))

    let one = [landing("T1#1", at: "01:00")]
    #expect(try summary(task("doing"), landings: one, verdicts: [verdict("R1", on: "T1#1", "changes", at: "01:10")],
                        findings: [finding("R1 M1", by: "R1", "must")])
            == TaskSummary(at: "2026-11-11T05:00:00.000Z", event: "dev가 고치는 중입니다", rest: "1차 제출에 수정 요청 · 필수 1 열림"),
            "taken again after a request for changes")
    #expect(try summary(task("review"), landings: one + [landing("T1#2", at: "02:00")])
            == TaskSummary(at: "2026-11-11T02:00:00.000Z", event: "2차 제출을 dev가 냈습니다", rest: "rv가 리뷰할 차례입니다"))
    #expect(try summary(task("changes"), landings: one, verdicts: [verdict("R1", on: "T1#1", "changes", at: "01:10")],
                        findings: [finding("R1 M1", by: "R1", "must"), finding("R1 S1", by: "R1", "should"),
                                   finding("R1 L1", by: "R1", "low", "backlog")])
            == TaskSummary(at: "2026-11-11T01:10:00.000Z", event: "rv가 1차 제출에 수정을 요청했습니다",
                           rest: "dev가 고칠 차례입니다 · 필수 1 · 권장 1 열림"), "a settled finding is not left to fix")
    #expect(try summary(task("held"), landings: one, verdicts: [verdict("R1", on: "T1#1", "hold", at: "01:10")])
            == TaskSummary(at: "2026-11-11T01:10:00.000Z", event: "rv가 보류했습니다", rest: "pm이 풀거나 취소할 차례입니다"))
    #expect(try summary(task("held")).event == "pm이 보류했습니다", "held by pm, with no verdict")
    #expect(try summary(task("cancelled")) == TaskSummary(at: "2026-11-11T05:00:00.000Z", event: "pm이 취소했습니다", rest: nil))
}

@Test func aDoneTasksSummarySaysWhoApprovedAndWhatIsLeftOpen() throws {
    let three = [landing("T1#1", at: "01:00", supersededBy: "T1#2"), landing("T1#2", at: "01:02", supersededBy: "T1#3"), landing("T1#3", at: "01:20")]
    #expect(try summary(task("done"), landings: three, verdicts: [verdict("R1", on: "T1#3", "approve", at: "01:30")])
            == TaskSummary(at: "2026-11-11T01:30:00.000Z", event: "rv가 3차 제출을 승인했습니다", rest: "남은 지적 없음"))
    let one = [landing("T1#1", at: "01:00")]
    let lows = (1...3).map { finding("R1 L\($0)", by: "R1", "low") }
    #expect(try summary(task("done"), landings: one, verdicts: [verdict("R1", on: "T1#1", "approve", at: "01:30", by: "pm")], findings: lows)
            == TaskSummary(at: "2026-11-11T01:30:00.000Z", event: "pm이 1차 제출을 승인했습니다", rest: "낮음 지적 3건이 열려 있어 pm 정리 대기"),
            "pm approved it without the reviewer")
    #expect(try summary(task("done"), landings: one, verdicts: [verdict("R1", on: "T1#1", "approve", at: "01:30")],
                        findings: [finding("R1 L1", by: "R1", "low"), finding("R1 M1", by: "R1", "must")]).rest
            == "지적 2건(필수 1 · 낮음 1)이 열려 있어 pm 정리 대기")
    #expect(try summary(task("done")) == TaskSummary(at: "2026-11-11T05:00:00.000Z", event: "완료됐습니다", rest: "남은 지적 없음"),
            "done with no approve on the board")
}

/// Three submissions: the first sent again two minutes later unchanged, the second sent back with three findings,
/// the third approved; one finding fixed in another task.
private func threeSubmissions(firstFocus: [String] = ["a"]) throws -> TaskDetail {
    try detail(task("done"),
               landings: [landing("T1#1", at: "01:00", focus: firstFocus, supersededBy: "T1#2"), landing("T1#2", at: "01:02", supersededBy: "T1#3"),
                          landing("T1#3", at: "01:20", closes: ["R1 M1", "R1 L1"])],
               verdicts: [verdict("R1", on: "T1#2", "changes", at: "01:10"), verdict("R1a", on: "T1#3", "approve", at: "01:30")],
               findings: [finding("R1 M1", by: "R1", "must", "fixed", fixedIn: "T1#3"), finding("R1 L1", by: "R1", "low", "fixed", fixedIn: "T1#3"),
                          finding("R1 L2", by: "R1", "low", "fixed", fixedIn: "T9#1")],
               elsewhere: #"[{"landing":"T9#1","task_id":"T9","approved":true}]"#)
}

@Test func theHistoryReadsInTimeOrderAndFoldsASubmissionSentAgain() throws {
    let d = try threeSubmissions()
    let h = taskHistory(d)
    #expect(h.map(\.text) == ["pm이 등록, 담당 dev", "dev 1차 제출 → 2분 뒤 다시 제출", "dev 2차 제출", "rv가 수정 요청 · 지적 3건 ↑",
                              "dev 3차 제출 · 고친 지적 2건", "rv가 승인", "T9에서 지적 1건 수정 (승인됨)"])
    #expect(h.map(\.ref) == [nil, "T1#1", "T1#2", "R1", "T1#3", "R1a", "T9#1"], "the board's ids only in the tooltip and the copy")
    #expect(h[1].detail == nil, "sent again with the same focus: nothing more to see")
    #expect(h[5].detail == nil, "a review with no rerun, report or note has nothing to fold")
    #expect(h.last?.at == nil, "the board keeps no time of another task's fix")
    #expect(historyOpenAtFirst(d) == ["T1#3", "R1a"], "the last submission and its review start open")
    #expect(taskSummary(d).rest == "남은 지적 없음")

    let changed = taskHistory(try threeSubmissions(firstFocus: ["b"]))
    #expect(changed[1].detail != nil, "sent again with another focus: its details stay")
}

@Test func aTaskWithNoSubmissionHasOnlyItsStart() throws {
    let h = taskHistory(try detail(task("ready", assignedAt: "2026-11-11T01:00:00.000Z")))
    #expect(h.map(\.text) == ["pm이 등록", "담당 지정 · dev"], "assigned an hour after it was registered: two lines")
    #expect(h.map(\.at) == ["2026-11-11T00:00:00.000Z", "2026-11-11T01:00:00.000Z"])
    #expect(try detail(task("ready")).cards.isEmpty)
}

@Test func aFindingSaysWhichReviewRaisedItAndWhereItWasFixed() throws {
    let d = try threeSubmissions()
    let origin = Dictionary(uniqueKeysWithValues: d.findings.map { ($0.finding.id, findingOrigin($0, task: "T1")) })
    #expect(origin["R1 M1"] == "2차 제출 리뷰에서 · 3차 제출에서 수정됨")
    #expect(origin["R1 L2"] == "2차 제출 리뷰에서 · T9에서 수정됨", "fixed in another task: that task's name")
    let pending = try detail(task("review"), landings: [landing("T1#1", at: "01:00"), landing("T1#2", at: "02:00", closes: ["R1 M1"])],
                             verdicts: [verdict("R1", on: "T1#1", "changes", at: "01:10")],
                             findings: [finding("R1 M1", by: "R1", "must", "fixed", fixedIn: "T1#2"), finding("R1 L1", by: "R1", "low", "backlog")])
    let p = Dictionary(uniqueKeysWithValues: pending.findings.map { ($0.finding.id, (findingOrigin($0, task: "T1"), $0.pile)) })
    #expect(p["R1 M1"]?.0 == "1차 제출 리뷰에서 · 2차 제출에서 고침 · 리뷰 대기" && p["R1 M1"]?.1 == .open, "fixed, not yet approved: still open")
    #expect(p["R1 L1"]?.0 == "1차 제출 리뷰에서 · 나중에 하기로" && p["R1 L1"]?.1 == .settled)
}

@Test func aNamesParticleFollowsHowItEnds() {
    #expect(["pm", "detail", "team", "song", "T1", "김민준"].map(subject) == ["pm이", "detail이", "team이", "song이", "T1이", "김민준이"])
    #expect(["lists", "reviewer", "core", "mac-ux", "T2", "이수"].map(subject) == ["lists가", "reviewer가", "core가", "mac-ux가", "T2가", "이수가"])
}

@Test func otherTasksLandingsInTheFamilyNameTheirTask() {
    #expect(submissionText("T1#2", of: "T1") == "2차 제출")
    #expect(submissionText("T1a#1", of: "T1") == "T1a 1차 제출")
}

private let briefJSON = #"{"question":"A or B?","context":"Why.","options":[{"label":"A","pros":["p"],"cons":[]},{"label":"B"}],"recommendation":{"option":"A","reason":"r"},"impact":"i","refs":[],"asked_by":"dev","asked_at":"2026-11-11T03:30:00.000Z","resume_state":"doing"}"#

/// T116: a waiting task's summary says who asked the user, from when it was asked.
@Test func aWaitingTasksSummarySaysWhoAskedTheUser() throws {
    let t = task("waiting").replacingOccurrences(of: #""updated_by":"pm"}"#, with: #""updated_by":"pm","waiting":\#(briefJSON)}"#)
    let s = try summary(t)
    #expect(s == TaskSummary(at: "2026-11-11T03:30:00.000Z", event: "dev가 사용자에게 결정을 요청했습니다", rest: "사용자가 정할 차례입니다"))
}

/// T116 What 2: an answer is a history line where its time falls, "사용자 결정: <chosen> — <answer>", that folds out
/// the brief as it was; one without a brief has nothing to fold.
@Test func anAnswerIsAHistoryLineInItsTimeThatFoldsOutItsBrief() throws {
    let json = """
        {"root":\(task("doing")),"tasks":[\(task("doing"))],
         "landings":[\(landing("T1#1", at: "02:00")),\(landing("T1#2", at: "05:00"))],"verdicts":[],"findings":[],"notes":[],
         "answers":[{"task_id":"T1","question":"A or B?","chosen":"A","answer":"A, as recommended.","answered_by":"pm","answered_at":"2026-11-11T04:00:00.000Z","brief":\(briefJSON)},
                    {"task_id":"T1","question":"Q?","chosen":null,"answer":"later","answered_by":"pm","answered_at":"2026-11-11T06:00:00.000Z"}]}
        """
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    let detail = try #require(taskDetail(try d.decode(TaskFamily.self, from: Data(json.utf8)), task: "T1"))
    let h = taskHistory(detail)
    #expect(h.map(\.id) == ["made", "T1#1", "answer 0", "T1#2", "answer 1"])
    #expect(h[2].text == "사용자 결정: A — A, as recommended.")
    guard case .decision(let b) = h[2].detail else { Issue.record("no brief to fold out"); return }
    #expect(b.question == "A or B?")
    #expect(h[4].text == "사용자 결정: later" && h[4].detail == nil)
}

/// T116 contract update: a recommendation names its option, or says there is none and why.
@Test func aRecommendationNamesItsOptionOrSaysThereIsNone() {
    #expect(recommendationText(DecisionRecommendation(option: "A", reason: "faster")) == "A. faster")
    #expect(recommendationText(DecisionRecommendation(option: nil, reason: "both cost the same")) == "추천 없음 — both cost the same")
    #expect(recommendationText(DecisionRecommendation(option: nil, reason: nil)) == "추천 없음")
}

/// R41 L4: an answer the board kept no time of goes last, after every line with a time, an answer included.
@Test func anAnswerWithoutATimeGoesLast() throws {
    let json = """
        {"root":\(task("doing")),"tasks":[\(task("doing"))],"landings":[\(landing("T1#1", at: "02:00"))],"verdicts":[],"findings":[],"notes":[],
         "answers":[{"task_id":"T1","question":"Q?","chosen":"A","answer":"no time"},
                    {"task_id":"T1","question":"Q2?","chosen":"B","answer":"late","answered_at":"2026-11-11T09:00:00.000Z"}]}
        """
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    let h = taskHistory(try #require(taskDetail(try d.decode(TaskFamily.self, from: Data(json.utf8)), task: "T1")))
    #expect(h.map(\.text).suffix(2) == ["사용자 결정: B — late", "사용자 결정: A — no time"])
    #expect(h.first?.id == "made")
}

/// R41 L3: the card says how many options it could not read.
@Test func theCardSaysHowManyOptionsItCouldNotRead() throws {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    let broken = try d.decode(TaskWaiting.self, from: Data(#"{"question":"Q?","options":[{"label":"A"},{"label":"B","cons":"x"},{"label":"C","pros":1}]}"#.utf8))
    #expect(unreadOptionsText(broken) == "선택지 2개는 읽지 못해 빠졌습니다")
    let whole = try d.decode(TaskWaiting.self, from: Data(#"{"question":"Q?","options":[{"label":"A"}]}"#.utf8))
    #expect(unreadOptionsText(whole) == nil)
}

/// R43 L1: the options part stays, with its count of options read and not, when every option failed to read, so the
/// warning shows; with no options at all there is no part.
@Test func theOptionsPartStaysWhenEveryOptionFailedToRead() throws {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    func brief(_ json: String) throws -> TaskWaiting { try d.decode(TaskWaiting.self, from: Data(json.utf8)) }
    #expect(optionsHeading(try brief(#"{"question":"Q?","options":[{"label":"B","cons":"x"},{"label":"C","pros":1}]}"#)) == "선택지 2")
    #expect(optionsHeading(try brief(#"{"question":"Q?","options":[{"label":"A"},{"label":"B","cons":"x"}]}"#)) == "선택지 2")
    #expect(optionsHeading(try brief(#"{"question":"Q?","options":[{"label":"A"}]}"#)) == "선택지 1")
    #expect(optionsHeading(try brief(#"{"question":"Q?"}"#)) == nil)
}

/// T155: the properties say who registered the task and when, and when the assignee was set if that came later;
/// never a start time, which the board does not keep.
@Test func theRegisteredPropertySaysWhoWhenAndTheAssignment() throws {
    let now = try #require(parseISO("2026-11-11T06:00:00.000Z").map { Date(timeIntervalSince1970: $0 / 1000) })
    let d = try detail(task("doing"))
    let made = try #require(detailClock("2026-11-11T00:00:00.000Z", now: now)), set = try #require(detailClock("2026-11-11T00:00:30.000Z", now: now))
    #expect(registeredText(d.task, now: now) == "pm · \(made) · 담당 지정 \(set)")
    #expect(registeredText(try detail(task("doing", assignedAt: "2026-11-11T00:00:00.000Z")).task, now: now) == "pm · \(made)")
}

@Test func aWaitingDecisionComesBeforeThePropertiesAndTheRecordAfterTheFindings() {
    #expect(detailBlocks(waits: true, record: .read) == [
        .head, .decisions, .properties, .goal, .todo, .ticket, .findings, .history, .commits, .notes, .taskInfo,
    ])
    #expect(detailBlocks(waits: false, record: .read) == [
        .head, .properties, .goal, .todo, .ticket, .findings, .history, .commits, .notes, .taskInfo,
    ])
    #expect(detailBlocks(waits: true, record: .reading) == [.head, .decisions, .properties, .reading, .taskInfo])
    #expect(detailBlocks(waits: false, record: .failed) == [.head, .properties, .failed, .taskInfo])
}
