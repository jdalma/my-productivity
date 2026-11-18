import Foundation

// What a task is for and how far it has come (T128): its ticket's goal and to-do items, the assignee's progress on
// each, and the commits on the worker's branch since the task's start commit. Read only: a ticket file, and git log in
// the worker's folder through `git(_:_:in:)`.

// MARK: - Board data (T127 contract)

/// One `board-progress` record: how the assignee says an item of the ticket's to-do list stands.
public struct TaskProgress: Decodable, Hashable, Sendable {
    /// The to-do item's number, from 1; 0 for work outside the list.
    public var item: Int
    public var note: String
    public var done: Bool
    public var by: String?
    public var at: String?

    public init(item: Int, note: String, done: Bool, by: String? = nil, at: String? = nil) {
        self.item = item
        self.note = note
        self.done = done
        self.by = by
        self.at = at
    }
}

/// A listed task's progress at a glance: the items done, and the last record's note and time.
public struct ProgressSummary: Decodable, Hashable, Sendable {
    public var doneItems: [Int]
    public var lastNote: String?
    public var lastAt: String?

    public init(doneItems: [Int], lastNote: String?, lastAt: String?) {
        self.doneItems = doneItems
        self.lastNote = lastNote
        self.lastAt = lastAt
    }
}

// MARK: - Ticket

/// What a ticket says the task is for, and its to-do list: the numbered list of its What (고칠 것, 할 일) section, in
/// order, which `board-progress` numbers from 1.
public struct TicketOutline: Equatable, Sendable {
    public var goal: String?
    public var items: [String]
}

/// A section head as these tickets write it: a line starting `**Label:**` or `**Label (…):**`, the text after it on
/// the same line belonging to the section; or a Markdown heading below the title (`##` and down).
private func sectionHead(_ line: String) -> (label: String, rest: String)? {
    if let m = line.wholeMatch(of: #/\*\*([^*]+?):\*\*\s*(.*)/#) {
        let label = String(m.1).replacing(#/\s*\(.*\)\s*$/#, with: "").trimmingCharacters(in: .whitespaces)
        return (label, String(m.2))
    }
    if let m = line.wholeMatch(of: #/#{2,6}\s+(.+)/#) {
        let label = String(m.1).replacing(#/\s*\(.*\)\s*$/#, with: "").trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        return (label, "")
    }
    return nil
}

/// The goal and to-do list of a ticket's Markdown, their inline marks kept for the detail to show (T136).
/// - goal: the 사용자 목표 (or 목표) section's text; without one, the first paragraph after the title that is not the
///   ticket's `담당: …` line, nor a section head.
/// - items: the numbered lines, at the start of the line, of the first What, 고칠 것 or 할 일 section that has any; a
///   bulleted list is not numbered, and such a ticket's progress is all item 0 (T127 contract).
public func parseTicket(_ text: String) -> TicketOutline {
    let lines = text.components(separatedBy: "\n")
    var sections: [(label: String, body: [String])] = []
    var preamble: [String] = []
    for line in lines {
        if let head = sectionHead(line) {
            sections.append((head.label, head.rest.isEmpty ? [] : [head.rest]))
        } else if sections.isEmpty {
            preamble.append(line)
        } else {
            sections[sections.count - 1].body.append(line)
        }
    }
    func paragraph(_ body: [String]) -> String? {
        let words = body.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
    let goal = sections.first { ["사용자 목표", "목표"].contains($0.label) }.flatMap { paragraph($0.body) }
        ?? firstParagraph(preamble)
    let numbered = sections.filter { ["what", "고칠 것", "할 일"].contains($0.label.lowercased()) }.lazy
        .map { $0.body.compactMap { line -> String? in
            line.wholeMatch(of: #/\d+\.\s+(.+)/#).map { String($0.1).trimmingCharacters(in: .whitespaces) }
        } }
        .first { !$0.isEmpty } ?? []
    return TicketOutline(goal: goal, items: numbered)
}

/// The first paragraph of the text before any section: not the title, not the ticket's `담당: …` line.
private func firstParagraph(_ lines: [String]) -> String? {
    var paragraphs: [[String]] = [[]]
    for line in lines {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { paragraphs.append([]) } else { paragraphs[paragraphs.count - 1].append(line) }
    }
    let text = paragraphs.lazy.filter { !$0.isEmpty }
        .first { p in !p[0].hasPrefix("#") && !p[0].hasPrefix("담당:") }
    return text.map { $0.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ") }
}

/// A task's ticket as the detail shows it: its outline and its whole text, or why there is none.
public enum TicketRead: Equatable, Sendable {
    case read(TicketOutline, full: String)
    case none
    case unreadable(String)
}

/// The largest page read (T131, R47b L3): a ticket or a report is a page of Markdown.
let pageSizeLimit = 1 << 20

/// A page of Markdown as a file gave it, or why it could not be read.
public enum PageRead: Equatable, Sendable {
    case read(String)
    case unreadable(String)
}

/// Reads the file at `path`, never writing; `what` names it in the reason (`티켓`, `보고서`). Only a regular file
/// within `pageSizeLimit`: a folder, a pipe or a device would hang or fill memory (T131, R47b L3). A symbolic link is
/// followed (R12 L4): the file is opened once, without waiting on a pipe, and what was opened is what is checked and
/// read, so nothing can be swapped in between.
public func readPage(_ path: String, what: String) -> PageRead {
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
        return .unreadable(errno == ENOENT ? "\(what) 파일이 없습니다: \(path)" : "\(what) 파일을 읽지 못했습니다: \(path)")
    }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= pageSizeLimit,
          // one byte past the limit: a file that grew after the check is not read whole. At the end of the file the
          // read gives nil, not an error: an empty file is an empty page (R13 L1)
          let data = try? file.read(upToCount: pageSizeLimit + 1) ?? Data(), data.count <= pageSizeLimit else {
        return .unreadable("\(what) 파일을 읽지 못함: 1MB 이하의 일반 파일이 아닙니다: \(path)")
    }
    guard let text = String(data: data, encoding: .utf8) else { return .unreadable("\(what) 파일을 읽지 못했습니다: \(path)") }
    return .read(text)
}

/// Reads `path` (a task's `ticket_path`); nil path, no ticket.
public func readTicket(_ path: String?) -> TicketRead {
    guard let path, !path.isEmpty else { return .none }
    switch readPage(path, what: "티켓") {
    case .read(let text): return .read(parseTicket(text), full: text)
    case .unreadable(let why): return .unreadable(why)
    }
}

// MARK: - To-do and progress

public enum TodoStatus: Equatable, Sendable { case done, doing, notYet }

/// A to-do item and where it stands: by its last progress record, done or still going; with none, not yet.
public struct TodoLine: Equatable, Sendable {
    public var number: Int
    public var text: String
    public var status: TodoStatus
    public var last: TaskProgress?
}

/// The ticket's items with their progress, and the records outside the list (item 0, or a number the list does not
/// have) in time order.
public func todoLines(items: [String], progress: [TaskProgress]) -> (lines: [TodoLine], outside: [TaskProgress]) {
    let ordered = progress.enumerated().sorted { a, b in
        (a.element.at ?? "", a.offset) < (b.element.at ?? "", b.offset)
    }.map(\.element)
    let lines = items.enumerated().map { i, text in
        let last = ordered.last { $0.item == i + 1 }
        return TodoLine(number: i + 1, text: text, status: last.map { $0.done ? .done : .doing } ?? .notYet, last: last)
    }
    return (lines, ordered.filter { $0.item < 1 || $0.item > items.count })
}

/// A listed task's progress on its second line: `할 일 2/5 · <last note>`; without the ticket's count, the items done.
/// nil from a board that keeps no progress (before T127), or with nothing recorded yet.
public func progressText(_ s: ProgressSummary?, total: Int?) -> String? {
    guard let s, !s.doneItems.isEmpty || s.lastNote?.isEmpty == false else { return nil }
    let done = Set(s.doneItems).count
    let count = total.map { $0 > 0 ? "할 일 \(min(done, $0))/\($0)" : nil } ?? (done > 0 ? "할 일 \(done)개 끝남" : nil)
    let note = s.lastNote.map { oneLineHead($0, 40) }
    return [count, note].compactMap { $0 }.joined(separator: " · ").nonEmpty
}

/// The first `n` characters of `s` on one line, with an ellipsis when cut.
public func oneLineHead(_ s: String, _ n: Int) -> String {
    let flat = s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return flat.count > n ? String(flat.prefix(n - 1)) + "…" : flat
}

// MARK: - Commits

/// A commit on the worker's branch since the task's start commit.
public struct CommitLine: Equatable, Sendable {
    public var sha: String
    public var subject: String
    /// ISO 8601, the committer's.
    public var at: String
    /// Files the commit changed; nil for a merge, which git log does not count.
    public var files: Int?
}

let commitRecord = "\u{1e}", commitField = "\u{1f}"

/// `git log --format=<record>%H<field>%cI<field>%s --shortstat`, oldest first as asked.
func parseCommitLog(_ text: String) -> [CommitLine] {
    text.components(separatedBy: commitRecord).compactMap { record in
        let lines = record.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard let head = lines.first else { return nil }
        let f = head.components(separatedBy: commitField)
        guard f.count == 3, !f[0].isEmpty else { return nil }
        let files = lines.dropFirst().lazy.compactMap { $0.firstMatch(of: #/(\d+) files? changed/#).flatMap { Int($0.1) } }.first
        return CommitLine(sha: f[0], subject: f[2], at: f[1], files: files)
    }
}

/// The commits from `base` (the task's start commit) to HEAD in `dir`, oldest first, at most `limit` (the newest).
/// nil when `dir` is not a git working tree there or `base` is not a commit in it: the detail then shows none.
/// The folder is another worker's (T131, R47b): `base` comes after `--end-of-options` in both reads, so a value like
/// `--output=…` is a revision git cannot find, never an option that writes; and `--no-show-signature` keeps the
/// repository's own `log.showSignature` from running its `gpg.program`.
public func commitFlow(dir: String?, base: String?, limit: Int = 50) -> [CommitLine]? {
    guard let dir, let base, !base.isEmpty, FileManager.default.fileExists(atPath: dir),
          out(.revParse, ["--verify", "--quiet", "--end-of-options", "\(base)^{commit}"], in: dir) != nil else { return nil }
    guard let log = out(.log, ["--no-show-signature", "--reverse", "--max-count=\(limit)", "--shortstat",
                              "--format=\(commitRecord)%H\(commitField)%cI\(commitField)%s",
                              "--end-of-options", "\(base)..HEAD"], in: dir)
    else { return nil }
    return parseCommitLog(log)
}
