import Foundation
import Testing
@testable import TowerCore

@Test func theIndexReadsAsGroupsOfTitledLines() {
    let groups = parseDocumentIndex("""
    # example documents

    A note for whoever edits this file.

    - [Above any group](top.md)

    ## Design

    - [Example design](design/example.md): shapes, **bold** and `code` (T1)
    - [Example canvas](https://example.com/a_(b)): two sections
    - [No note](<notes/with space.md>)
    - a line without a link

    ## Empty

    ## Reports
    * [Wrapped](reports/wrapped.md): first
      second
    """)
    #expect(groups.map(\.title) == ["", "Design", "Reports"])
    #expect(groups[0].lines == [DocumentLine(title: "Above any group", link: "top.md")])
    #expect(groups[1].lines == [
        DocumentLine(title: "Example design", link: "design/example.md", note: "shapes, bold and code (T1)"),
        DocumentLine(title: "Example canvas", link: "https://example.com/a_(b)", note: "two sections"),
        DocumentLine(title: "No note", link: "notes/with space.md"),
        DocumentLine(title: "a line without a link", link: nil),
    ])
    #expect(groups[2].lines == [DocumentLine(title: "Wrapped", link: "reports/wrapped.md", note: "first second")])
}

@Test func aLinkAnywhereOnTheLineIsTheDocument() {
    let lines = parseDocumentIndex("""
    - **[B](b.md)**: n
    - report: [A](a.md)
    - <https://example.com/x>
    - [A [x] b](a.md)
    - [D](a.md "title"): n
    """).flatMap(\.lines)
    #expect(lines == [
        DocumentLine(title: "B", link: "b.md", note: "n"),
        DocumentLine(title: "A", link: "a.md", note: "report"),
        DocumentLine(title: "https://example.com/x", link: "https://example.com/x"),
        DocumentLine(title: "A [x] b", link: "a.md"),
        DocumentLine(title: "D", link: "a.md", note: "n"),
    ])
}

@Test func anImageOrCodeIsNotTheDocumentAndTheNoteKeepsNoMarks() {
    let lines = parseDocumentIndex("""
    - ![alt](x.png) [A](a.md)
    - `[x](y.md)` [A](a.md)
    - `<https://example.com/x>` then <https://example.com/y>
    - ![only an image](x.png)
    - report (**[A](a.md)**) end
    - ~~[A](a.md)~~: gone
    - _[A](a.md)_: note
    """).flatMap(\.lines)
    #expect(lines.map(\.link) == ["a.md", "a.md", "https://example.com/y", nil, "a.md", "a.md", "a.md"])
    #expect(lines.map(\.title) == ["A", "A", "https://example.com/y", "only an image", "A", "A", "A"])
    #expect(lines[1].note == "[x](y.md)")
    #expect(lines[2].note == "<https://example.com/x> then")
    #expect(lines.suffix(3).map(\.note) == ["report end", "gone", "note"])
    #expect(parseDocumentIndex("- [A](a.md): calls `init()` and a[]").flatMap(\.lines).map(\.note) == ["calls init() and a[]"])
}

@Test func aByteOrderMarkDoesNotHideTheFirstLine() {
    #expect(parseDocumentIndex("\u{FEFF}## G\n- [A](a.md)") == [DocumentGroup(title: "G", lines: [DocumentLine(title: "A", link: "a.md")])])
    #expect(parseDocumentIndex("\u{FEFF}- [A](a.md)").flatMap(\.lines).map(\.title) == ["A"])
}

@Test func anEmptyIndexHasNoGroups() {
    #expect(parseDocumentIndex("").isEmpty)
    #expect(parseDocumentIndex("# title\n\nonly words\n\n## group\n").isEmpty)
}

private struct Scratch {
    let root: String
    var base: String { root + "/sessions" }
    var folder: String { root + "/docs/example-team" }

    init() throws {
        root = (try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                            appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()), create: true)).path
        try FileManager.default.createDirectory(atPath: root + "/docs/example-team/reports", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/sessions", withIntermediateDirectories: true)
        try write("reports/in.md", "# in")
        try "secret".write(toFile: root + "/outside.md", atomically: true, encoding: .utf8)
    }

    func write(_ path: String, _ text: String) throws {
        try text.write(toFile: folder + "/" + path, atomically: true, encoding: .utf8)
    }

    func remove() { try? FileManager.default.removeItem(atPath: root) }
}

private func resolved(_ path: String) -> String {
    let p = realpath(path, nil)!
    defer { free(p) }
    return String(cString: p)
}

@Test func aFileInTheFolderOpensByItsRealPath() throws {
    let s = try Scratch()
    defer { s.remove() }
    let file = DocumentTarget.file(resolved(s.folder + "/reports/in.md"))
    #expect(documentTarget("reports/in.md", folder: s.folder) == file)
    #expect(documentTarget("reports/../reports/in.md", folder: s.folder) == file)
    #expect(documentTarget(s.folder + "/reports/in.md", folder: s.folder) == file)
    #expect(documentTarget("reports/in.md#part", folder: s.folder) == file)
    try s.write("with space.md", "x")
    #expect(documentTarget("with%20space.md", folder: s.folder) == .file(resolved(s.folder + "/with space.md")))
    try FileManager.default.createSymbolicLink(atPath: s.folder + "/alias.md", withDestinationPath: "reports/in.md")
    #expect(documentTarget("alias.md", folder: s.folder) == file)
}

@Test func aPathThatLeavesTheFolderIsBlocked() throws {
    let s = try Scratch()
    defer { s.remove() }
    #expect(documentTarget("../../outside.md", folder: s.folder) == .blocked(.outside))
    #expect(documentTarget(s.root + "/outside.md", folder: s.folder) == .blocked(.outside))
    #expect(documentTarget("/etc/hosts", folder: s.folder) == .blocked(.outside))
    #expect(documentTarget("reports/../../../outside.md", folder: s.folder) == .blocked(.outside))
    #expect(documentTarget("..%2F..%2Foutside.md", folder: s.folder) == .blocked(.outside))
    try FileManager.default.createSymbolicLink(atPath: s.folder + "/escape.md", withDestinationPath: s.root + "/outside.md")
    try FileManager.default.createSymbolicLink(atPath: s.folder + "/up", withDestinationPath: s.root)
    #expect(documentTarget("escape.md", folder: s.folder) == .blocked(.outside))
    #expect(documentTarget("up/outside.md", folder: s.folder) == .blocked(.outside))
    #expect(documentTarget("../nothing.md", folder: s.folder) == .blocked(.outside))
    try FileManager.default.createDirectory(atPath: s.folder + "-other", withIntermediateDirectories: true)
    try "x".write(toFile: s.folder + "-other/a.md", atomically: true, encoding: .utf8)
    #expect(documentTarget("../example-team-other/a.md", folder: s.folder) == .blocked(.outside))
}

@Test func onlyWebAddressesOpenAmongSchemes() throws {
    let s = try Scratch()
    defer { s.remove() }
    #expect(documentTarget("https://example.com/a", folder: s.folder) == .web(URL(string: "https://example.com/a")!))
    #expect(documentTarget("HTTP://example.com", folder: s.folder) == .web(URL(string: "HTTP://example.com")!))
    for link in ["file://\(s.folder)/reports/in.md", "file:///etc/hosts", "x-example://open", "javascript:alert(1)",
                 "mailto:a@example.com", "https:", "http:///no-host"] {
        #expect(documentTarget(link, folder: s.folder) == .blocked(.scheme), "\(link)")
    }
    #expect(documentTarget(nil, folder: s.folder) == .blocked(.noLink))
    #expect(documentTarget("  ", folder: s.folder) == .blocked(.noLink))
}

@Test func aFileWhoseNameHasAColonIsAPathNotAScheme() throws {
    let s = try Scratch()
    defer { s.remove() }
    try s.write("T1:report.md", "x")
    #expect(documentTarget("T1:report.md", folder: s.folder) == .file(resolved(s.folder + "/T1:report.md")))
    #expect(documentTarget("x-example:open", folder: s.folder) == .blocked(.scheme))
    try FileManager.default.createDirectory(atPath: s.folder + "/file:", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: s.folder + "/file:/out.md", withDestinationPath: s.root + "/outside.md")
    #expect(documentTarget("file:/out.md", folder: s.folder) == .blocked(.outside))
}

@Test func aDocumentFileIsReadOnlyWhenWhatOpenedIsInTheFolder() throws {
    let s = try Scratch()
    defer { s.remove() }
    let page = resolved(s.folder + "/reports/in.md")
    #expect(readDocumentFile(page, folder: s.folder, what: "문서") == .read("# in"))
    try FileManager.default.removeItem(atPath: page)
    try FileManager.default.createSymbolicLink(atPath: page, withDestinationPath: s.root + "/outside.md")
    guard case .unreadable(let why) = readDocumentFile(page, folder: s.folder, what: "문서") else {
        Issue.record("a file outside the folder was read")
        return
    }
    #expect(why.contains("팀 문서 폴더 밖"))
    #expect(readDocumentFile(s.root + "/outside.md", folder: s.folder, what: "문서") != .read("secret"))
    #expect(readDocumentFile(s.folder, folder: s.folder, what: "문서") != .read(""))
}

@Test func anIndexThatIsALinkOutOfTheFolderIsNotRead() throws {
    let s = try Scratch()
    defer { s.remove() }
    try "- [Secret](a.md)\n".write(toFile: s.root + "/elsewhere.md", atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(atPath: s.folder + "/index.md", withDestinationPath: s.root + "/elsewhere.md")
    let d = readTeamDocuments(team: "example-team", base: s.base, known: nil, stamp: fileStamp) {
        readDocumentFile($0, folder: $1, what: "목록")
    }
    guard case .unreadable = d.content else {
        Issue.record("\(d.content)")
        return
    }
    #expect(d.rows.isEmpty)
}

@Test func aPathInTheFolderWithoutAFileIsMissing() throws {
    let s = try Scratch()
    defer { s.remove() }
    guard case .missing(let path) = documentTarget("reports/later.md", folder: s.folder) else {
        Issue.record("not missing")
        return
    }
    #expect(path.hasSuffix("/docs/example-team/reports/later.md"))
    #expect(!DocumentTarget.missing(path).opens)
}

@Test func theIndexIsReadAgainOnlyWhenItsFileChanged() throws {
    let s = try Scratch()
    defer { s.remove() }
    var reads = 0
    var stamp: FileStamp? = FileStamp(modified: Date(timeIntervalSince1970: 1), size: 10)
    var text = "## Reports\n- [In](reports/in.md)\n- [Later](reports/later.md)\n"
    func read(_ known: TeamDocuments?) -> TeamDocuments {
        readTeamDocuments(team: "example-team", base: s.base, known: known, stamp: { _ in stamp }) { _, _ in
            reads += 1
            return .read(text)
        }
    }
    let first = read(nil)
    #expect(first.indexPath == s.folder + "/index.md")
    #expect(first.rows.map(\.line.title) == ["In", "Later"])
    #expect((first.rows.count, first.openable) == (2, 1))
    text = "- [Changed](reports/in.md)\n"
    try s.write("reports/later.md", "x")
    let second = read(first)
    #expect(reads == 1)
    #expect(second.rows.map(\.line.title) == ["In", "Later"])
    #expect(second.openable == 2)
    stamp = FileStamp(modified: Date(timeIntervalSince1970: 2), size: 10)
    #expect(read(second).rows.map(\.line.title) == ["Changed"])
    #expect(reads == 2)
    let other = readTeamDocuments(team: "other-team", base: s.base, known: second, stamp: { _ in stamp }) { _, _ in
        reads += 1
        return .read("- [Other](a.md)\n")
    }
    #expect(other.rows.map(\.line.title) == ["Other"])
    #expect(reads == 3)
    stamp = nil
    let gone = read(second)
    #expect(gone.content == .missing)
    #expect(gone.rows.isEmpty)
    #expect(reads == 3)
}

@Test func aTeamNameThatIsNotAFolderNameReadsNothing() {
    for team in ["..", "a/b", ""] {
        let d = readTeamDocuments(team: team, base: "/x/sessions", known: nil, stamp: { _ in nil }) { _, _ in .read("- [a](a.md)") }
        guard case .unreadable = d.content else {
            Issue.record("\(team) was read")
            continue
        }
    }
    #expect(documentsFolder(team: "example-team", base: "/x/.my-team/sessions") == "/x/.my-team/docs/example-team")
}

private let docsFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "../../scripts/test-instance/docs-fixture.py").standardized.path

private func fixtureDocuments(_ mode: String? = nil) throws -> (t: String, documents: TeamDocuments) {
    let t = FileManager.default.temporaryDirectory.appending(path: "tower-docs-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: t + "/my-team/sessions", withIntermediateDirectories: true)
    let r = try runCommand(["python3", docsFixture, t], timeout: 120, env: mode.map { ["CT_TEST_DOCS": $0] } ?? [:],
                           unset: mode == nil ? ["CT_TEST_DOCS"] : [])
    #expect(r.status == 0, "\(r.stderr)")
    return (t, readTeamDocuments(team: "example-team", base: t + "/my-team/sessions", known: nil, stamp: fileStamp) {
        readDocumentFile($0, folder: $1, what: "목록")
    })
}

@Test func theFixturesDocumentsOpenOnlyInsideTheFolderAndOnTheWeb() throws {
    let (t, d) = try fixtureDocuments()
    defer { try? FileManager.default.removeItem(atPath: t) }
    #expect(d.sections.map(\.title) == ["Example designs", "Example reports", "Does not open"])
    #expect((d.rows.count, d.openable) == (21, 16))
    let closed = d.rows.filter { !$0.target.opens }
    #expect(closed.map(\.line.title) == ["Report not written yet", "Outside the folder", "Link out of the folder", "A file address",
                                         "an example line without a link"])
    #expect(closed.dropFirst().map(\.target) == [.blocked(.outside), .blocked(.outside), .blocked(.scheme), .blocked(.noLink)])
    #expect(d.rows[2].target == .web(URL(string: "https://example.com/canvas")!))
    #expect(d.rows[0].line.note == "shapes, sizes and an example table (T5)")
    let index = try String(contentsOfFile: d.indexPath, encoding: .utf8)
    #expect(index.matches(of: #/https?://[^\s)]+/#).allSatisfy { $0.output.contains("://example.com") })
}

@Test func theFixtureHasAStateWithoutAnIndexAndOneWithoutLines() throws {
    let none = try fixtureDocuments("none")
    defer { try? FileManager.default.removeItem(atPath: none.t) }
    #expect(none.documents.content == .missing)
    #expect(none.documents.indexPath == none.t + "/my-team/docs/example-team/index.md")
    let empty = try fixtureDocuments("empty")
    defer { try? FileManager.default.removeItem(atPath: empty.t) }
    #expect(empty.documents.content == .groups([]))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TOWER_DOCS_TEAM"] != nil))
func theRealIndexOfATeamReads() {
    let d = readTeamDocuments(team: ProcessInfo.processInfo.environment["TOWER_DOCS_TEAM"]!, known: nil)
    print("documents: \(d.indexPath): \(d.rows.count) lines in \(d.sections.count) groups, \(d.openable) open")
    for r in d.rows where !r.target.opens { print("  not opened: \(r.line.title) (\(r.line.link ?? "no link")): \(r.target)") }
    guard case .groups = d.content else {
        Issue.record("\(d.content)")
        return
    }
}
