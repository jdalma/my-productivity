import Foundation
import Testing
@testable import TowerCore
@testable import TowerApp

// T157: what a line says of how its task has gone, from `history` in board-status (my-team T156), and that a board
// without it is drawn as before. Example names only.

private func q(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "null" }

private func event(_ action: String, verdict: String? = nil, by: String? = "dev", at: String = "2026-11-11T09:00:00.000Z",
                   from: String? = "doing", to: String? = "review") -> String {
    #"{"action":"\#(action)","verdict":\#(q(verdict)),"by":\#(q(by)),"at":"\#(at)","state_from":\#(q(from)),"state_to":\#(q(to))}"#
}

private func history(landings: Int = 0, changes: Int = 0, event: String? = nil, since: String? = nil, progressBy: String? = nil,
                     cancelledFrom: String? = nil) -> String {
    #"{"landings":\#(landings),"verdicts":{"approve":0,"changes":\#(changes),"hold":0},"last_event":\#(event ?? "null"),"state_since":\#(q(since)),"last_progress_by":\#(q(progressBy)),"cancelled_from":\#(q(cancelledFrom))}"#
}

private func task(_ state: String, history: String? = nil, updated: String = "2026-11-11T08:00:00.000Z", note: String? = nil,
                  noteAt: String = "2026-11-11T08:30:00.000Z") throws -> TaskBoardTask {
    let progress = note.map { #","progress_summary":{"done_items":[1],"last_note":"\#($0)","last_at":"\#(noteAt)"}"# } ?? ""
    let json = #"{"id":"T1","parent_id":null,"title":"t","ticket_path":null,"state":"\#(state)","assignee":"dev","reviewer":"rv","priority":100,"created_by":"pm","created_at":"2026-11-11T07:00:00.000Z","updated_at":"\#(updated)"\#(progress)\#(history.map { #","history":\#($0)"# } ?? "")}"#
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(TaskBoardTask.self, from: Data(json.utf8))
}

private func clock(_ iso: String) throws -> String { boardClock(Date(timeIntervalSince1970: try #require(parseISO(iso)) / 1000)) }

@Test func aLineCountsHowOftenTheTaskCameBackAndWhichSubmissionIsUnderReview() throws {
    let back = try task("changes", history: history(landings: 2, changes: 2))
    #expect(reworkText(back) == "↺ 수정 2회")
    #expect(submissionOrdinal(back) == nil, "nothing is under review")
    let review = try task("review", history: history(landings: 3, changes: 2))
    #expect(reworkText(review) == "↺ 수정 2회" && submissionOrdinal(review) == "3차 제출")
    let first = try task("review", history: history(landings: 1))
    #expect(reworkText(first) == nil && submissionOrdinal(first) == "1차 제출")
    #expect(reworkText(try task("done", history: history(landings: 2, changes: 1))) == "↺ 수정 1회", "a finished task keeps its count")
}

@Test func aBoardWithoutHistoryDrawsTheLineAsBefore() throws {
    let now = Date(timeIntervalSince1970: try #require(parseISO("2026-11-11T08:10:00.000Z")) / 1000)
    for state in ["changes", "review", "doing"] {
        let t = try task(state, note: "halfway")
        #expect(reworkText(t) == nil && submissionOrdinal(t) == nil && lastEventLine(t) == nil, "\(state)")
        #expect(secondLine(t) == "\(try clock("2026-11-11T08:30:00.000Z")) · halfway", "the record, with no writer")
        #expect(taskTime(t, now: now) == "10분째", "since updated_at")
    }
    #expect(secondLine(try task("doing")) == nil)
    let cancelled = try task("cancelled")
    #expect(taskStep(cancelled) == nil)
    #expect(taskAccessibilityValue(TaskLine(task: cancelled, child: false, reasons: [], findingCount: 0), now: now).contains("멈춘 단계 모름"))
}

@Test func theSecondLineIsTheLaterOfTheLastEventAndTheLastRecord() throws {
    let landed = event("land", at: "2026-11-11T09:00:00.000Z")
    let after = try task("review", history: history(landings: 2, event: landed, progressBy: "dev"), note: "halfway")
    #expect(secondLine(after) == "\(try clock("2026-11-11T09:00:00.000Z")) · dev가 2차 제출", "the event came after the record")
    let before = try task("review", history: history(landings: 2, event: landed, progressBy: "dev"), note: "tidying", noteAt: "2026-11-11T09:30:00.000Z")
    #expect(secondLine(before) == "\(try clock("2026-11-11T09:30:00.000Z")) · dev · tidying", "the record came after, with who wrote it")
    let none = try task("ready", history: history(event: event("assign", by: "pm", from: "new", to: "ready")))
    #expect(secondLine(none) == "\(try clock("2026-11-11T09:00:00.000Z")) · pm이 배정", "no record: the event")
    #expect(secondLine(try task("new", history: history())) == nil, "neither")
    let approved = history(landings: 1, event: event("verdict", verdict: "approve", by: "rv", from: "review", to: "done"))
    #expect(secondLine(try task("done", history: approved)) == nil, "a task that is over: its state says how it ended")
    #expect(secondLine(try task("cancelled", history: history(event: event("cancel", by: "pm")))) == nil)
    #expect(secondLine(try task("done", history: approved, note: "halfway")) == "\(try clock("2026-11-11T08:30:00.000Z")) · halfway", "its record stays, as before")
}

@Test func anEventIsSaidOfWhoDidIt() throws {
    func text(_ json: String, landings: Int = 0) throws -> String {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return eventText(try d.decode(TaskEvent.self, from: Data(json.utf8)), landings: landings)
    }
    #expect(try text(event("add", by: "pm", from: nil, to: "new")) == "pm이 등록")
    #expect(try text(event("take", from: "ready", to: "doing")) == "dev가 시작")
    #expect(try text(event("take", from: "changes", to: "doing")) == "dev가 고치기 시작")
    #expect(try text(event("land"), landings: 3) == "dev가 3차 제출")
    #expect(try text(event("land")) == "dev가 제출", "no count: no ordinal")
    #expect(try text(event("verdict", verdict: "approve", by: "rv")) == "rv가 승인")
    #expect(try text(event("verdict", verdict: "changes", by: "rv")) == "rv가 수정 요청")
    #expect(try text(event("verdict", verdict: "hold", by: "rv")) == "rv가 보류")
    #expect(try text(event("wait")) == "dev가 사용자 결정 요청")
    #expect(try text(event("answer", by: "pm")) == "pm이 사용자 결정 기록")
    #expect(try text(event("cancel", by: "pm")) == "pm이 취소")
    #expect(try text(event("later-kind", by: nil)) == "later-kind", "an action a newer my-team adds is shown as it is")
}

@Test func theTimeOnALineIsSinceTheTaskEnteredItsState() throws {
    let now = Date(timeIntervalSince1970: try #require(parseISO("2026-11-11T10:00:00.000Z")) / 1000)
    // updated_at moved 5 minutes ago (a change of reviewer); the task has been in review for an hour
    let review = try task("review", history: history(landings: 1, since: "2026-11-11T09:00:00.000Z"), updated: "2026-11-11T09:55:00.000Z")
    #expect(taskTime(review, now: now) == "1시간째")
    #expect(elapsedMinutes(review, now: now) == 60)
    let done = try task("done", history: history(landings: 1, since: "2026-11-11T08:00:00.000Z"), updated: "2026-11-11T09:55:00.000Z")
    #expect(taskTime(done, now: now) == "2시간 전 끝남", "when it ended, not when its findings were tidied")
}

/// R18 L1: a `state_since` that is no time leaves the line its time, counted from `updated_at`, in the line and in
/// what a folded panel says of its longest wait.
@Test func aStateSinceThatIsNoTimeStillGivesTheLineItsTime() throws {
    let now = Date(timeIntervalSince1970: try #require(parseISO("2026-11-11T08:10:00.000Z")) / 1000)
    for bad in ["", "soon"] {
        let t = try task("doing", history: history(since: bad))
        #expect(taskTime(t, now: now) == "10분째", "'\(bad)'")
        #expect(elapsedMinutes(t, now: now) == 10)
        #expect(foldedSummary(.review, lines: [TaskLine(task: t, child: false, reasons: [], findingCount: 0)], decisions: [], now: now) == ["가장 오래 10분째"])
        #expect(taskTime(try task("done", history: history(since: bad)), now: now) == "10분 전 끝남")
    }
}

/// R18 L2: a task that is not cancelled and whose step is unknown (it waits, to go back to a state that has none)
/// is read as such, not as a step with no name.
@Test func voiceOverSaysSoWhenTheStepIsUnknown() throws {
    let now = Date(timeIntervalSince1970: try #require(parseISO("2026-11-11T08:10:00.000Z")) / 1000)
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    let t = try d.decode(TaskBoardTask.self, from: Data(#"{"id":"T1","title":"t","state":"waiting","priority":1,"waiting":{"question":"q","resume_state":"cancelled"}}"#.utf8))
    #expect(taskStep(t) == nil)
    let said = taskAccessibilityValue(TaskLine(task: t, child: false, reasons: [], findingCount: 0), now: now)
    #expect(said.contains("단계 모름") && !said.contains("단계 ."), "\(said)")
}

/// R19 L1: the words for where a task is, made in one place for VoiceOver and the step dots' tooltip: "stopped" only
/// of a cancelled task, whether or not the step is known.
@Test func whereATaskIsAmongTheStepsIsSaidInOnePlace() throws {
    let now = Date(timeIntervalSince1970: try #require(parseISO("2026-11-11T08:10:00.000Z")) / 1000)
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    let unknown = try d.decode(TaskBoardTask.self, from: Data(#"{"id":"T1","title":"t","state":"waiting","priority":1,"waiting":{"question":"q","resume_state":"cancelled"}}"#.utf8))
    let cases: [(TaskBoardTask, String)] = [
        (try task("doing"), "단계 작업"), (try task("new"), "단계 등록"), (try task("done"), "단계 끝"),
        (unknown, "단계 모름"),
        (try task("cancelled", history: history(cancelledFrom: "review")), "리뷰 단계에서 멈춤"),
        (try task("cancelled", history: history()), "멈춘 단계 모름"), (try task("cancelled"), "멈춘 단계 모름"),
    ]
    for (t, phrase) in cases {
        #expect(stepPhrase(t) == phrase)
        #expect(taskAccessibilityValue(TaskLine(task: t, child: false, reasons: [], findingCount: 0), now: now).components(separatedBy: ". ").contains(phrase), "\(phrase)")
        #expect(stepPhrase(t).contains("멈") == (t.state == "cancelled"), "\(phrase)")
    }
}

@Test func aCancelledTaskShowsTheStepItStoppedAt() throws {
    let now = Date(timeIntervalSince1970: try #require(parseISO("2026-11-11T10:00:00.000Z")) / 1000)
    let steps = try ["new", "ready", "doing", "changes", "review", "held"].map { taskStep(try task("cancelled", history: history(cancelledFrom: $0))) }
    #expect(steps == [.registered, .assigned, .working, .working, .review, .review])
    #expect(taskStep(try task("cancelled", history: history())) == nil, "the board says nothing: unknown")
    let stopped = TaskLine(task: try task("cancelled", history: history(cancelledFrom: "review")), child: false, reasons: [], findingCount: 0)
    #expect(taskAccessibilityValue(stopped, now: now).contains("리뷰 단계에서 멈춤"))
}

@Test func voiceOverReadsTheCountsAndTheLastEvent() throws {
    let now = Date(timeIntervalSince1970: try #require(parseISO("2026-11-11T10:00:00.000Z")) / 1000)
    let t = try task("review", history: history(landings: 3, changes: 2, event: event("land"), since: "2026-11-11T09:00:00.000Z"), note: "halfway")
    let said = taskAccessibilityValue(TaskLine(task: t, child: false, reasons: [], findingCount: 0), now: now)
    #expect(said.contains("수정 요청 2회. 3차 제출"))
    #expect(said.hasSuffix("마지막 사건 \(try clock("2026-11-11T09:00:00.000Z")) · dev가 3차 제출"))
}
