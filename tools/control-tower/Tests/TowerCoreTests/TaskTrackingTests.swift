import Foundation
import Testing
@testable import TowerCore

// T128: what a task is for (its ticket's goal and to-do list) and how far it has come (progress, commits).

// MARK: - tickets, in the formats this team's tickets use

@Test func aTicketWithAUserGoalAndANumberedWhatGivesBoth() {
    let t = parseTicket("""
    # T9 — example: the list reads its ticket

    담당: alpha · 리뷰: reviewer · 발행: pm · base abc1234

    **사용자 목표 (원문):** "작업 내용을 이해할 수 있게 한다."
    이어지는 둘째 줄.

    **지금 [pm 확인]:** something else.

    **What:**
    1. **무엇을 하는 작업인지.** 티켓을 읽는다. `ticket_path`
       - a nested detail line
    2. **어디까지 왔는지.** 진행 기록.
       - another detail
    3. 목록 줄.

    **Acceptance:**
    1. `swift test` 통과.
    """)
    #expect(t.goal == "\"작업 내용을 이해할 수 있게 한다.\" 이어지는 둘째 줄.")
    #expect(t.items == ["**무엇을 하는 작업인지.** 티켓을 읽는다. `ticket_path`", "**어디까지 왔는지.** 진행 기록.", "목록 줄."])
}

@Test func aTicketWithAGoalAndAWhatWithANoteInItsHead() {
    let t = parseTicket("""
    # T8 — example: tool refuses keys

    담당: beta · 리뷰: reviewer

    **목표:** E2E를 돌리는 AI가 클립보드를 건드리지 못한다.

    **What (커밋 단위 순서대로):**
    1. 키 경로에서 거부한다.
    2. press 경로에서 거부한다.
    """)
    #expect(t.goal == "E2E를 돌리는 AI가 클립보드를 건드리지 못한다.")
    #expect(t.items == ["키 경로에서 거부한다.", "press 경로에서 거부한다."])
}

/// A 고칠 것 list of bullets is no numbered list: the task's progress is all item 0. With no goal section, the first
/// paragraph that is neither the title nor the `담당:` line.
@Test func aTicketWithBulletsHasNoItemsAndItsFirstParagraphIsTheGoal() {
    let t = parseTicket("""
    # T7 — example: tidy the findings

    담당: gamma · 리뷰: reviewer · base abc1234

    Three low findings from the last reviews, each small.

    **고칠 것:**
    - R1 L1: one
    - R1 L2: two
    """)
    #expect(t.items.isEmpty)
    #expect(t.goal == "Three low findings from the last reviews, each small.")
}

@Test func aTicketWithMarkdownHeadingsReadsTheSame() {
    let t = parseTicket("""
    # T6 example

    ## 사용자 목표
    Headings instead of bold heads.

    ## What
    1. first
    2. second
    10. tenth
    """)
    #expect(t.goal == "Headings instead of bold heads.")
    #expect(t.items == ["first", "second", "tenth"])
}

/// The section pm writes tickets with from T136 on.
@Test func aTicketWithAToDoSectionReadsItsNumberedList() {
    let t = parseTicket("""
    # T4 example

    ## 사용자 목표

    The list reads its own to-do section.

    ## 할 일

    1. first
       - detail
    2. second

    ## 확인 기준

    1. not an item
    """)
    #expect(t.goal == "The list reads its own to-do section.")
    #expect(t.items == ["first", "second"])
}

@Test func aTicketOfNothingButATitleHasNeitherGoalNorItems() {
    #expect(parseTicket("# T5 only a title\n") == TicketOutline(goal: nil, items: []))
}

@Test func aMissingTicketIsSaidSoAndNoPathIsNoTicket() throws {
    #expect(readTicket(nil) == .none)
    #expect(readTicket("") == .none)
    let missing = FileManager.default.temporaryDirectory.appending(path: "no-ticket-\(UUID().uuidString).md").path
    guard case .unreadable(let why) = readTicket(missing) else { Issue.record("not unreadable"); return }
    #expect(why.contains(missing))
    let path = FileManager.default.temporaryDirectory.appending(path: "ticket-\(UUID().uuidString).md").path
    try "# T1\n\n**What:**\n1. one\n".write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard case .read(let outline, let full) = readTicket(path) else { Issue.record("not read"); return }
    #expect(outline.items == ["one"] && full.hasPrefix("# T1"))
}

// MARK: - to-do with progress

@Test func eachItemStandsByItsLastRecordAndTheRestIsOutsideTheList() {
    let p = [
        TaskProgress(item: 1, note: "first part", done: false, by: "alpha", at: "2026-11-14T10:00:00.000Z"),
        TaskProgress(item: 0, note: "set up the repo", done: false, by: "alpha", at: "2026-11-14T09:00:00.000Z"),
        TaskProgress(item: 1, note: "first done", done: true, by: "alpha", at: "2026-11-14T11:00:00.000Z"),
        TaskProgress(item: 2, note: "second done, then", done: true, by: "alpha", at: "2026-11-14T11:10:00.000Z"),
        TaskProgress(item: 2, note: "second reopened", done: false, by: "alpha", at: "2026-11-14T11:20:00.000Z"),
        TaskProgress(item: 9, note: "a number the list lacks", done: true, by: "alpha", at: "2026-11-14T11:30:00.000Z"),
    ]
    let (lines, outside) = todoLines(items: ["one", "two", "three"], progress: p)
    #expect(lines.map(\.status) == [.done, .doing, .notYet])
    #expect(lines.map(\.number) == [1, 2, 3])
    #expect(lines[0].last?.note == "first done")
    #expect(lines[1].last?.note == "second reopened")
    #expect(lines[2].last == nil)
    #expect(outside.map(\.note) == ["set up the repo", "a number the list lacks"], "item 0 and out of range, in time order")
}

@Test func aTicketWithoutItemsPutsEveryRecordOutsideTheList() {
    let (lines, outside) = todoLines(items: [], progress: [TaskProgress(item: 0, note: "n", done: false)])
    #expect(lines.isEmpty && outside.count == 1)
}

// MARK: - the list's second line

@Test func theListSaysItemsDoneOfTheTicketsAndTheLastNote() {
    let s = ProgressSummary(doneItems: [1, 2], lastNote: "읽기 함수를 다 썼고 화면이 남았다. 아주 긴 문장이 이어진다 계속 계속 계속", lastAt: nil)
    let head = "읽기 함수를 다 썼고 화면이 남았다. 아주 긴 문장이 이어진다 계속 계…"  // 39 characters and the ellipsis
    #expect(head.count == 40)
    #expect(progressText(s, total: 5) == "할 일 2/5 · " + head)
    #expect(progressText(s, total: nil) == "할 일 2개 끝남 · " + head)
    #expect(progressText(ProgressSummary(doneItems: [], lastNote: "시작했다", lastAt: nil), total: 3) == "할 일 0/3 · 시작했다")
    #expect(progressText(ProgressSummary(doneItems: [2, 2], lastNote: nil, lastAt: nil), total: 0) == nil, "no list, no note")
    #expect(progressText(nil, total: 5) == nil, "a board before T127")
    #expect(progressText(ProgressSummary(doneItems: [], lastNote: nil, lastAt: nil), total: 5) == nil)
}

// MARK: - board answers, new and old

@Test func progressDecodesFromTheBoardAndAnOlderBoardHasNone() throws {
    let task = #"{"id":"T1","title":"t","state":"doing","priority":100"#
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let withSummary = try decoder.decode(TaskBoardTask.self, from: Data((task + #","progress_summary":{"done_items":[1,3],"last_note":"n","last_at":"2026-11-14T00:00:00.000Z"}}"#).utf8))
    #expect(withSummary.progressSummary == ProgressSummary(doneItems: [1, 3], lastNote: "n", lastAt: "2026-11-14T00:00:00.000Z"))
    #expect(try decoder.decode(TaskBoardTask.self, from: Data((task + #","progress_summary":null}"#).utf8)).progressSummary == nil)
    #expect(try decoder.decode(TaskBoardTask.self, from: Data((task + "}").utf8)).progressSummary == nil)

    let family = #"{"root":\#(task)},"tasks":[\#(task)}],"landings":[],"verdicts":[],"findings":[],"notes":[]"#
    let newer = try decoder.decode(TaskFamily.self, from: Data((family + #","progress":[{"item":1,"note":"n","done":true,"by":"alpha","at":"2026-11-14T00:00:00.000Z"}]}"#).utf8))
    #expect(newer.progress == [TaskProgress(item: 1, note: "n", done: true, by: "alpha", at: "2026-11-14T00:00:00.000Z")])
    #expect(taskDetail(newer, task: "T1")?.progress.count == 1)
    #expect(try decoder.decode(TaskFamily.self, from: Data((family + "}").utf8)).progress.isEmpty)
}

// MARK: - commits

@Test func aLogReadsAsCommitsWithTheirFileCounts() {
    let r = commitRecord, f = commitField
    let log = "\(r)aaa\(f)2026-11-14T10:00:00+09:00\(f)first change\n\n 3 files changed, 10 insertions(+)\n"
        + "\(r)bbb\(f)2026-11-14T10:05:00+09:00\(f)merge: a branch\n"
        + "\(r)ccc\(f)2026-11-14T10:09:00+09:00\(f)one file\n\n 1 file changed, 1 deletion(-)\n"
    #expect(parseCommitLog(log) == [
        CommitLine(sha: "aaa", subject: "first change", at: "2026-11-14T10:00:00+09:00", files: 3),
        CommitLine(sha: "bbb", subject: "merge: a branch", at: "2026-11-14T10:05:00+09:00", files: nil),
        CommitLine(sha: "ccc", subject: "one file", at: "2026-11-14T10:09:00+09:00", files: 1),
    ])
}

/// A throwaway repository that reads no git configuration of the user's.
private func repo() throws -> (dir: String, git: ([String]) throws -> String) {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tower-commits-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let env = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Example", "GIT_AUTHOR_EMAIL": "example@example.invalid",
               "GIT_COMMITTER_NAME": "Example", "GIT_COMMITTER_EMAIL": "example@example.invalid"]
    let git = { (args: [String]) throws -> String in
        let r = try runCommand(["git", "-C", dir, "-c", "commit.gpgsign=false"] + args, timeout: 20, env: env)
        guard r.status == 0 else { throw CommandError(description: r.stderr) }
        return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    _ = try git(["init", "-q", "-b", "main"])
    return (dir, git)
}

@Test func theCommitsSinceTheStartCommitAreReadOldestFirst() throws {
    let (dir, git) = try repo()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try "a\n".write(toFile: "\(dir)/a.txt", atomically: true, encoding: .utf8)
    _ = try git(["add", "-A"]); _ = try git(["commit", "-q", "-m", "base"])
    let base = try git(["rev-parse", "HEAD"])
    try "a\nb\n".write(toFile: "\(dir)/a.txt", atomically: true, encoding: .utf8)
    try "c\n".write(toFile: "\(dir)/c.txt", atomically: true, encoding: .utf8)
    _ = try git(["add", "-A"]); _ = try git(["commit", "-q", "-m", "first: two files"])
    try "d\n".write(toFile: "\(dir)/d.txt", atomically: true, encoding: .utf8)
    _ = try git(["add", "-A"]); _ = try git(["commit", "-q", "-m", "second: one file"])

    let flow = try #require(commitFlow(dir: dir, base: base))
    #expect(flow.map(\.subject) == ["first: two files", "second: one file"])
    #expect(flow.map(\.files) == [2, 1])
    #expect(flow.allSatisfy { parseISO($0.at) != nil })
    #expect(commitFlow(dir: dir, base: try git(["rev-parse", "HEAD"])) == [], "nothing since the start commit")
    #expect(commitFlow(dir: dir, base: "0123456789abcdef0123456789abcdef01234567") == nil, "a start commit the folder lacks")
    #expect(commitFlow(dir: dir, base: nil) == nil)
    #expect(commitFlow(dir: nil, base: base) == nil)
    let plain = FileManager.default.temporaryDirectory.appending(path: "tower-plain-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: plain) }
    #expect(commitFlow(dir: plain, base: base) == nil, "not a repository")
    #expect(try git(["status", "--porcelain"]).isEmpty, "reading changed nothing in the folder")
}

// MARK: - reading another worker's folder and ticket safely (T131, R47b)

/// R47b L1: a start commit that reads as an option never reaches git log as one: nothing is written, nothing listed.
@Test func aStartCommitThatLooksLikeAnOptionWritesNothing() throws {
    let (dir, git) = try repo()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try "a\n".write(toFile: "\(dir)/a.txt", atomically: true, encoding: .utf8)
    _ = try git(["add", "-A"]); _ = try git(["commit", "-q", "-m", "base"])
    let target = "\(dir)/written-by-log.txt"
    for base in ["--output=\(target)", "--output=\(target)^{commit}", "-o\(target)"] {
        #expect(commitFlow(dir: dir, base: base) == nil, "\(base)")
    }
    #expect(!FileManager.default.fileExists(atPath: target))
}

/// R47b L2: a worker repository's own settings can turn on showing signatures and name a signing program; reading
/// its commits never runs that program.
@Test func readingCommitsNeverRunsTheRepositorysSigningProgram() throws {
    let (dir, git) = try repo()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try "a\n".write(toFile: "\(dir)/a.txt", atomically: true, encoding: .utf8)
    _ = try git(["add", "-A"]); _ = try git(["commit", "-q", "-m", "base"])
    let base = try git(["rev-parse", "HEAD"])
    // a commit carrying a signature header, made by hand: showing it asks the signing program to check it
    let tree = try git(["rev-parse", "HEAD^{tree}"])
    let body = "tree \(tree)\nparent \(base)\nauthor Example <example@example.invalid> 1700000000 +0000\n"
        + "committer Example <example@example.invalid> 1700000000 +0000\n"
        + "gpgsig -----BEGIN PGP SIGNATURE-----\n \n -----END PGP SIGNATURE-----\n\nsigned example\n"
    let object = "\(dir)/commit.txt"
    try body.write(toFile: object, atomically: true, encoding: .utf8)
    let signed = try git(["hash-object", "-t", "commit", "-w", object])
    try FileManager.default.removeItem(atPath: object)
    _ = try git(["update-ref", "HEAD", signed])
    let marker = "\(dir)/.signing-program-ran"
    let program = "\(dir)/.fake-gpg"
    try "#!/bin/sh\ntouch '\(marker)'\nexit 1\n".write(toFile: program, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program)
    _ = try git(["config", "log.showSignature", "true"])
    _ = try git(["config", "gpg.program", program])

    let flow = try #require(commitFlow(dir: dir, base: base))
    #expect(flow.map(\.subject) == ["signed example"])
    #expect(!FileManager.default.fileExists(atPath: marker), "the repository's signing program ran")
}

/// R47b L3: only a regular file under 1 MB is read as a ticket; a folder, a pipe or a huge file is said so at once.
@Test func onlyARegularFileOfAReasonableSizeIsReadAsATicket() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tower-tickets-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    func unreadable(_ path: String) -> Bool { if case .unreadable = readTicket(path) { return true } else { return false } }
    #expect(unreadable(dir), "a folder")
    let fifo = "\(dir)/pipe.md"
    #expect(mkfifo(fifo, 0o600) == 0)
    let start = Date()
    #expect(unreadable(fifo), "a pipe")
    #expect(Date().timeIntervalSince(start) < 2, "a pipe nobody writes to is not waited on")
    let big = "\(dir)/big.md"
    try Data(count: 1_048_577).write(to: URL(fileURLWithPath: big))
    #expect(unreadable(big), "over 1 MB")
    let fine = "\(dir)/fine.md"
    try "# T1\n\n**What:**\n1. one\n".write(toFile: fine, atomically: true, encoding: .utf8)
    guard case .read(let o, _) = readTicket(fine) else { Issue.record("a regular small ticket is read"); return }
    #expect(o.items == ["one"])
}

/// R52 L1: a character device is no ticket, even one that reads as empty: without the type check `/dev/null` would
/// read as an empty ticket.
@Test func aCharacterDeviceIsNoTicket() {
    guard case .unreadable(let why) = readTicket("/dev/null") else { Issue.record("read /dev/null as a ticket"); return }
    #expect(why.contains("일반 파일"))
}

/// T155: a report is read by the same rules as a ticket, and the reason names what it is.
@Test func aReportIsReadAsAPageAndTheReasonNamesIt() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tower-pages-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let report = "\(dir)/report.md"
    try "# report\n".write(toFile: report, atomically: true, encoding: .utf8)
    #expect(readPage(report, what: "보고서") == .read("# report\n"))
    #expect(readPage("\(dir)/gone.md", what: "보고서") == .unreadable("보고서 파일이 없습니다: \(dir)/gone.md"))
    guard case .unreadable(let why) = readPage(dir, what: "보고서") else { Issue.record("read a folder"); return }
    #expect(why.hasPrefix("보고서 파일을 읽지 못함"))
    try Data([0xff, 0xfe, 0xfd]).write(to: URL(fileURLWithPath: "\(dir)/binary.md"))
    #expect(readPage("\(dir)/binary.md", what: "보고서") == .unreadable("보고서 파일을 읽지 못했습니다: \(dir)/binary.md"))
}

/// R12 L4, L5: a link to a report is followed, and what it points at is held to the same rules: a regular file of at
/// most 1 MB.
@Test func aLinkedReportIsReadAndTheLimitIsOneMegabyte() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tower-links-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    func unreadable(_ path: String, _ word: String) -> Bool {
        if case .unreadable(let why) = readPage(path, what: "보고서") { return why.contains(word) } else { return false }
    }
    try "# real\n".write(toFile: "\(dir)/real.md", atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: "\(dir)/link.md", withDestinationPath: "\(dir)/real.md")
    #expect(readPage("\(dir)/link.md", what: "보고서") == .read("# real\n"))
    try FileManager.default.createSymbolicLink(atPath: "\(dir)/to-folder.md", withDestinationPath: dir)
    #expect(unreadable("\(dir)/to-folder.md", "일반 파일"))
    try FileManager.default.createSymbolicLink(atPath: "\(dir)/dangling.md", withDestinationPath: "\(dir)/gone.md")
    #expect(unreadable("\(dir)/dangling.md", "파일이 없습니다"))
    #expect(mkfifo("\(dir)/pipe", 0o600) == 0)
    try FileManager.default.createSymbolicLink(atPath: "\(dir)/to-pipe.md", withDestinationPath: "\(dir)/pipe")
    let start = Date()
    #expect(unreadable("\(dir)/to-pipe.md", "일반 파일"))
    #expect(Date().timeIntervalSince(start) < 2, "a linked pipe nobody writes to is not waited on")

    try Data(repeating: 0x61, count: 1 << 20).write(to: URL(fileURLWithPath: "\(dir)/limit.md"))
    #expect(readPage("\(dir)/limit.md", what: "보고서") == .read(String(repeating: "a", count: 1 << 20)), "exactly 1 MB is read")
    try Data(repeating: 0x61, count: (1 << 20) + 1).write(to: URL(fileURLWithPath: "\(dir)/over.md"))
    #expect(unreadable("\(dir)/over.md", "1MB"))
    try FileManager.default.createSymbolicLink(atPath: "\(dir)/to-over.md", withDestinationPath: "\(dir)/over.md")
    #expect(unreadable("\(dir)/to-over.md", "1MB"))
}

/// R13 L1: an empty file is an empty page, as before the file was read through a handle; a ticket of no bytes is a
/// ticket with no goal and no items.
@Test func anEmptyFileIsReadAsAnEmptyPage() throws {
    let path = FileManager.default.temporaryDirectory.appending(path: "tower-empty-\(UUID().uuidString).md").path
    #expect(FileManager.default.createFile(atPath: path, contents: Data()))
    defer { try? FileManager.default.removeItem(atPath: path) }
    #expect(readPage(path, what: "보고서") == .read(""))
    #expect(readTicket(path) == .read(TicketOutline(goal: nil, items: []), full: ""))
}
