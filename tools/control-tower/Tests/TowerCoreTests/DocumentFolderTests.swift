import Foundation
import Testing
@testable import TowerCore

private func scratch() throws -> (root: String, folder: String) {
    let made = NSTemporaryDirectory() + "tower-folder-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: made + "/docs/example-team", withIntermediateDirectories: true)
    let root = try #require(realpath(made, nil).map { p in defer { free(p) }; return String(cString: p) })
    return (root, root + "/docs/example-team")
}

private func write(_ path: String, _ text: String = "x", at time: TimeInterval? = nil) throws {
    let fm = FileManager.default
    try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    if let time { try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: path) }
}

private func listed(_ d: FolderDocuments) -> [FolderDocument] {
    if case .listed(let docs) = d { return docs }
    return []
}

@Test func aDocumentIsAMarkdownHTMLOrPDFFileByItsEnding() {
    #expect(DocumentKind(path: "/a/report.md") == .markdown)
    #expect(DocumentKind(path: "/a/REPORT.MD") == .markdown)
    #expect(DocumentKind(path: "/a/mock.html") == .html)
    #expect(DocumentKind(path: "/a/mock.HTM") == .html)
    #expect(DocumentKind(path: "/a/paper.pdf") == .pdf)
    for name in ["shot.png", "notes.txt", "run.sh", "run.command", "out.log", "data.json", "x.svg", "x.xhtml", "x.md.txt", "md", "README"] {
        #expect(DocumentKind(path: "/a/\(name)") == nil, "\(name)")
    }
}

@Test func theFolderListsItsDocumentsHoweverDeepNewestFirst() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try write("\(folder)/index.md", "# the index", at: 900)
    try write("\(folder)/top.md", "# Top", at: 100)
    try write("\(folder)/reports/a.md", "intro\n\n## Report A\n", at: 300)
    try write("\(folder)/reports/deep/er/b.md", "no heading here", at: 200)
    try write("\(folder)/design/mock.html", "<h1>not read</h1>", at: 400)
    try write("\(folder)/design/paper.pdf", "%PDF", at: 50)
    for name in ["reports/shot.png", "reports/notes.txt", "tools/run.sh", "reports/out.log", "reports/.hidden.md", ".git/x.md"] {
        try write("\(folder)/\(name)", "# never", at: 999)
    }
    let docs = listed(listFolderDocuments(folder))
    #expect(docs.map(\.relative) == ["design/mock.html", "reports/a.md", "reports/deep/er/b.md", "top.md", "design/paper.pdf"])
    #expect(docs.map(\.title) == ["mock.html", "Report A", "b.md", "Top", "paper.pdf"])
    #expect(docs.map(\.kind) == [.html, .markdown, .markdown, .markdown, .pdf])
    #expect(docs.map(\.path) == docs.map { "\(folder)/\($0.relative)" })
    #expect(docs[1].stamp.modified == Date(timeIntervalSince1970: 300))
}

@Test func aSymbolicLinkIsNeitherFollowedNorListed() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let fm = FileManager.default
    try write("\(root)/outside/secret.md", "# Secret")
    try write("\(folder)/reports/real.md", "# Real")
    try fm.createSymbolicLink(atPath: "\(folder)/escape.md", withDestinationPath: "\(root)/outside/secret.md")
    try fm.createSymbolicLink(atPath: "\(folder)/away", withDestinationPath: "\(root)/outside")
    try fm.createSymbolicLink(atPath: "\(folder)/inside.md", withDestinationPath: "\(folder)/reports/real.md")
    try fm.createSymbolicLink(atPath: "\(folder)/again", withDestinationPath: "\(folder)/reports")
    #expect(listed(listFolderDocuments(folder)).map(\.relative) == ["reports/real.md"])
    #expect(markdownTitle("\(folder)/escape.md") == nil)
}

@Test func aFolderThatIsNotThereOrHoldsNoDocumentSaysSo() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    #expect(listFolderDocuments(folder + "/nowhere") == .missing)
    try write("\(folder)/a-file", "x")
    #expect(listFolderDocuments(folder + "/a-file") == .missing)
    try write("\(folder)/index.md", "# only the index")
    #expect(listFolderDocuments(folder) == .listed([]))
}

@Test func aTitleIsReadAgainOnlyWhenTheFileChanged() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try write("\(folder)/a.md", "# A", at: 100)
    try write("\(folder)/b.md", "# B", at: 200)
    var reads: [String] = []
    func title(_ path: String) -> String? {
        reads.append((path as NSString).lastPathComponent)
        return markdownTitle(path)
    }
    let first = listed(listFolderDocuments(folder, title: title))
    #expect(reads.sorted() == ["a.md", "b.md"])
    reads = []
    #expect(listed(listFolderDocuments(folder, known: first, title: title)) == first)
    #expect(reads.isEmpty)
    try write("\(folder)/a.md", "# A, changed", at: 300)
    let third = listed(listFolderDocuments(folder, known: first, title: title))
    #expect(reads == ["a.md"])
    #expect(third.map(\.title) == ["A, changed", "B"])
}

@Test func aTitleIsTheFirstHeadingOutsideCode() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    func title(_ text: String) throws -> String? {
        try write("\(folder)/t.md", text)
        return markdownTitle("\(folder)/t.md")
    }
    #expect(try title("# T1 — **bold** `code`\n\n## later") == "T1 — bold code")
    #expect(try title("```sh\n# a comment\n```\n\n### Third level ###\n") == "Third level")
    #expect(try title("#not a heading\n\ntext") == nil)
    #expect(try title("") == nil)
    #expect(try title(String(repeating: "x\n", count: titleReadLimit) + "# too far") == nil)
    #expect(markdownTitle("\(folder)/nowhere.md") == nil)
    #expect(markdownTitle(folder) == nil)
}

@Test func aListedFileOpensOnlyWhileItsRealPathIsInTheFolder() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let fm = FileManager.default
    try write("\(root)/outside/secret.md", "# Secret")
    try write("\(folder)/reports/a.md", "# A")
    #expect(documentTarget(path: "\(folder)/reports/a.md", folder: folder) == .file("\(folder)/reports/a.md"))
    try fm.removeItem(atPath: "\(folder)/reports/a.md")
    #expect(documentTarget(path: "\(folder)/reports/a.md", folder: folder) == .missing("\(folder)/reports/a.md"))
    try fm.createSymbolicLink(atPath: "\(folder)/reports/a.md", withDestinationPath: "\(root)/outside/secret.md")
    #expect(documentTarget(path: "\(folder)/reports/a.md", folder: folder) == .blocked(.outside))
    try fm.removeItem(atPath: "\(folder)/reports")
    try fm.createSymbolicLink(atPath: "\(folder)/reports", withDestinationPath: "\(root)/outside")
    try write("\(root)/outside/a.md", "# moved")
    #expect(documentTarget(path: "\(folder)/reports/a.md", folder: folder) == .blocked(.outside))
}

@Test func aFilterFindsEveryWordInTheTitleOrThePath() {
    let rows = folderRows([
        FolderDocument(path: "/d/reports/T177-app-report.md", relative: "reports/T177-app-report.md", kind: .markdown,
                       title: "T177 보고서 — Dashboard", stamp: FileStamp(modified: Date(timeIntervalSince1970: 3), size: 1)),
        FolderDocument(path: "/d/review/T177-review.md", relative: "review/T177-review.md", kind: .markdown,
                       title: "Review of the dashboard", stamp: FileStamp(modified: Date(timeIntervalSince1970: 2), size: 1)),
        FolderDocument(path: "/d/design/mock.html", relative: "design/mock.html", kind: .html,
                       title: "mock.html", stamp: FileStamp(modified: Date(timeIntervalSince1970: 1), size: 1)),
    ])
    func found(_ query: String) -> [String] { filterDocuments(rows, query).map { $0.line.link ?? "" } }
    #expect(found("") == rows.map { $0.line.link ?? "" })
    #expect(found("   ") == rows.map { $0.line.link ?? "" })
    #expect(found("t177") == ["reports/T177-app-report.md", "review/T177-review.md"])
    #expect(found("review") == ["review/T177-review.md"])
    #expect(found("DASHBOARD") == ["reports/T177-app-report.md", "review/T177-review.md"])
    #expect(found("보고서") == ["reports/T177-app-report.md"])
    #expect(found("t177  review") == ["review/T177-review.md"])
    #expect(found("design/") == ["design/mock.html"])
    #expect(found("nothing here").isEmpty)
    let fromIndex = DocumentRow(id: 0, line: DocumentLine(title: "Canvas", link: "https://example.com/a", note: "an example link"),
                                target: .blocked(.noLink))
    #expect(filterDocuments([fromIndex], "example.com") == [fromIndex])
    #expect(filterDocuments([fromIndex], "LINK canvas") == [fromIndex])
    #expect(filterDocuments([fromIndex], "report").isEmpty)
}

@Test func theFoldersLinesGroupByTheFolderRightUnderTheDocuments() {
    let rows = folderRows(["reports/3.md", "top.md", "review/1.md", "reports/deep/2.md", "Design/x.md", "reports/1.md"].enumerated().map { i, r in
        FolderDocument(path: "/d/\(r)", relative: r, kind: .markdown, title: r, stamp: FileStamp(modified: Date(timeIntervalSince1970: Double(-i)), size: 1))
    })
    let groups = groupByFolder(rows)
    #expect(groups.map(\.name) == ["", "Design", "reports", "review"])
    #expect(groups.map { $0.rows.map { $0.line.link ?? "" } } == [["top.md"], ["Design/x.md"], ["reports/3.md", "reports/deep/2.md", "reports/1.md"], ["review/1.md"]])
    #expect(groupByFolder([]).isEmpty)
}

private let docsFixture = URL(fileURLWithPath: #filePath)
    .appending(path: "../../../scripts/test-instance/docs-fixture.py").standardized.path

private func fixtureFolder(_ mode: String? = nil) throws -> (t: String, folder: String) {
    let made = FileManager.default.temporaryDirectory.appending(path: "tower-folder-fixture-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: made + "/my-team/sessions", withIntermediateDirectories: true)
    let t = try #require(realpath(made, nil).map { p in defer { free(p) }; return String(cString: p) })
    let r = try runCommand(["python3", docsFixture, t], timeout: 120, env: mode.map { ["CT_TEST_DOCS": $0] } ?? [:],
                           unset: mode == nil ? ["CT_TEST_DOCS"] : [])
    #expect(r.status == 0, "\(r.stderr)")
    return (t, t + "/my-team/docs/example-team")
}

@Test func theFixturesFolderListsItsDocumentsAndNothingElse() throws {
    let (t, folder) = try fixtureFolder()
    defer { try? FileManager.default.removeItem(atPath: t) }
    let docs = listed(listFolderDocuments(folder))
    #expect(docs.count == 43)
    #expect(DocumentKind.allCases.map { k in docs.filter { $0.kind == k }.count } == [40, 2, 1])
    #expect(groupByFolder(folderRows(docs)).map { "\($0.name) \($0.rows.count)" } == [" 1", "design 4", "reports 30", "review 3", "tickets 5"])
    #expect(docs.prefix(3).map(\.relative) == ["reports/example-report-10.md", "reports/example-report-11.md", "reports/example-report-12.md"])
    #expect(docs.first { $0.relative == "tickets/example-ticket-without-a-heading.md" }?.title == "example-ticket-without-a-heading.md")
    #expect(docs.first { $0.relative == "reports/example-report-10.md" }?.title == "Example report 10")
    for name in ["index.md", "escape.md", "reports/example-output.txt", "reports/example-shot.png", "reports/.example-hidden.md",
                 "tools/example.command", "design/example-picture.svg"] {
        #expect(!docs.contains { $0.relative == name }, "\(name)")
    }
    #expect(FileManager.default.fileExists(atPath: "\(folder)/reports/.example-hidden.md"))
    #expect(docs.allSatisfy { $0.title.lowercased().contains("example") })
}

@Test func theFixturesFolderIsEmptyWithoutAnIndexOrWithAnEmptyOne() throws {
    for mode in ["none", "empty"] {
        let (t, folder) = try fixtureFolder(mode)
        defer { try? FileManager.default.removeItem(atPath: t) }
        #expect(listFolderDocuments(folder) == .listed([]), "\(mode)")
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["TOWER_DOCS_TEAM"] != nil))
func theRealFolderOfATeamLists() throws {
    let team = try #require(ProcessInfo.processInfo.environment["TOWER_DOCS_TEAM"])
    let folder = try #require(documentsFolder(team: team, base: stateRootBase()))
    let clock = ContinuousClock()
    var first: [FolderDocument] = []
    let cold = clock.measure { first = listed(listFolderDocuments(folder)) }
    var second: [FolderDocument] = []
    var reads = 0
    let warm = clock.measure { second = listed(listFolderDocuments(folder, known: first) { reads += 1; return markdownTitle($0) }) }
    #expect(!first.isEmpty)
    #expect(second.map(\.relative) == first.map(\.relative))
    let kinds = DocumentKind.allCases.map { k in "\(k.rawValue) \(first.filter { $0.kind == k }.count)" }.joined(separator: ", ")
    print("T197 real folder \(folder): \(first.count) documents (\(kinds)); first read \(cold), next read \(warm) with \(reads) titles read again")
}
