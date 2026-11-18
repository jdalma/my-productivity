import AppKit
import Foundation
import Testing
import TowerCore
@testable import TowerApp

private func scratch() throws -> (root: String, folder: String) {
    let made = FileManager.default.temporaryDirectory.appending(path: "tower-folder-list-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: made + "/docs/example-team/reports", withIntermediateDirectories: true)
    let real = realpath(made, nil)!
    defer { free(real) }
    let root = String(cString: real), folder = root + "/docs/example-team"
    for (name, text) in [("reports/a.md", "# Report A"), ("mock.html", "<p>mock</p>"), ("picked.html", "<p>picked</p>"), ("paper.pdf", "%PDF"),
                         ("notes.txt", "notes")] {
        try text.write(toFile: "\(folder)/\(name)", atomically: true, encoding: .utf8)
    }
    try "# Secret".write(toFile: root + "/outside.md", atomically: true, encoding: .utf8)
    return (root, folder)
}

private func listed(_ folder: String) -> [DocumentRow] {
    guard case .listed(let files) = listFolderDocuments(folder) else { return [] }
    return folderRows(files)
}

private func row(_ rows: [DocumentRow], _ relative: String) throws -> DocumentRow {
    try #require(rows.first { $0.line.link == relative })
}

private func indexRow(_ link: String, folder: String) -> DocumentRow {
    DocumentRow(id: 0, line: DocumentLine(title: link, link: link), target: documentTarget(link, folder: folder))
}

private func lines(_ path: String) -> [String] {
    ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

@Test func aFileOfTheFolderIsALineWithItsPathAndAnIdOfItsOwn() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let rows = listed(folder)
    #expect(Set(rows.map { $0.line.link ?? "" }) == ["reports/a.md", "mock.html", "picked.html", "paper.pdf"])
    let a = try row(rows, "reports/a.md")
    #expect(a.line == DocumentLine(title: "Report A", link: "reports/a.md", note: "reports/a.md"))
    #expect(a.target == .file("\(folder)/reports/a.md"))
    #expect(a.isFromFolder)
    #expect(!indexRow("reports/a.md", folder: folder).isFromFolder)
    #expect(rows.allSatisfy { $0.id < 0 })
    #expect(Set(rows.map(\.id)).count == rows.count)
    #expect(listed(folder).map(\.id) == rows.map(\.id))
}

@Test func anHTMLFileOfTheFolderOpensOnlyWhenTheIndexListsIt() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let rows = listed(folder)
    let index = [indexRow("picked.html", folder: folder), indexRow("https://example.com/a", folder: folder), indexRow("gone.html", folder: folder)]
    let picked = pickedPaths(index, folder: folder)
    #expect(picked == ["\(folder)/picked.html"])
    #expect(actionOnOpen(try row(rows, "reports/a.md"), folder: folder, index: index) == .showPage("\(folder)/reports/a.md"))
    #expect(actionOnOpen(try row(rows, "paper.pdf"), folder: folder, index: index) == .openFile("\(folder)/paper.pdf"))
    #expect(actionOnOpen(try row(rows, "picked.html"), folder: folder, index: index) == .openFile("\(folder)/picked.html"))
    #expect(actionOnOpen(try row(rows, "mock.html"), folder: folder, index: index) == DocumentAction.none)
    #expect(actionOnOpen(try row(rows, "picked.html"), folder: folder) == DocumentAction.none)
    #expect(actionOnOpen(indexRow("mock.html", folder: folder), folder: folder) == .openFile("\(folder)/mock.html"))

    let mock = try row(rows, "mock.html"), listedToo = try row(rows, "picked.html")
    #expect(documentFileOpen(mock, stored: systemDefaultEditor, picked: picked) == .unpickedFolderHTML)
    #expect(documentFileOpen(mock, stored: "com.example.editor", picked: picked, appURL: { _ in URL(fileURLWithPath: "/Applications/E.app") }) == .unpickedFolderHTML)
    #expect(documentFileOpen(listedToo, stored: systemDefaultEditor, picked: picked) == .defaultApp)
    #expect(documentFileOpen(listedToo, stored: systemDefaultEditor) == .unpickedFolderHTML)
    #expect(documentFileOpen(try row(rows, "reports/a.md"), stored: systemDefaultEditor) == .window)
    let opens = fileOpensByRow(rows, stored: systemDefaultEditor, picked: picked)
    #expect(opens[mock.id] == .unpickedFolderHTML)
    #expect(opens[listedToo.id] == .defaultApp)
    #expect(opens[try row(rows, "paper.pdf").id] == .defaultApp)

    let style = DocumentRowStyle.of(mock, fileOpen: .unpickedFolderHTML)
    #expect(style.stateText == "열 수 없음: 목록 파일에 올린 HTML만 엽니다")
    #expect(style.help == "모든 문서의 HTML은 클릭으로 열지 않습니다. 목록 파일(index.md)에 올리면 열립니다: \(folder)/mock.html")
    #expect(documentMenuItems(mock) == [.copyPath("\(folder)/mock.html"), .reveal("\(folder)/mock.html")])
}

@MainActor @Test func aClickOnTheFoldersHTMLLeavesNothingInTheLog() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let log = root + "/actions.log"
    let rows = listed(folder)
    let index = [indexRow("picked.html", folder: folder)]
    var shown: [String] = []
    #expect(openDocument(try row(rows, "mock.html"), folder: folder, index: index, stored: systemDefaultEditor, dryRun: log) { shown.append($0) } == nil)
    #expect(lines(log).isEmpty)
    #expect(openDocument(try row(rows, "picked.html"), folder: folder, index: index, stored: systemDefaultEditor, dryRun: log) { shown.append($0) } == nil)
    #expect(lines(log) == ["open-file macOS-default \(folder)/picked.html"])
    #expect(openDocument(try row(rows, "reports/a.md"), folder: folder, index: index, stored: systemDefaultEditor, dryRun: log) { shown.append($0) } == nil)
    #expect(shown == ["\(folder)/reports/a.md"])
    #expect(lines(log).count == 1)
}

@Test func aFileOfTheFolderReplacedSinceItWasListedDoesNotOpen() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let fm = FileManager.default
    let rows = listed(folder)
    let a = try row(rows, "reports/a.md"), paper = try row(rows, "paper.pdf"), mock = try row(rows, "mock.html")
    let index = [indexRow("picked.html", folder: folder)]

    try fm.removeItem(atPath: "\(folder)/reports/a.md")
    #expect(actionOnOpen(a, folder: folder, index: index) == DocumentAction.none)
    try fm.createSymbolicLink(atPath: "\(folder)/reports/a.md", withDestinationPath: "\(root)/outside.md")
    #expect(actionOnOpen(a, folder: folder, index: index) == DocumentAction.none)

    try fm.removeItem(atPath: "\(folder)/paper.pdf")
    try fm.createSymbolicLink(atPath: "\(folder)/paper.pdf", withDestinationPath: "\(folder)/notes.txt")
    #expect(actionOnOpen(paper, folder: folder, index: index) == DocumentAction.none)

    try fm.removeItem(atPath: "\(folder)/paper.pdf")
    try fm.createSymbolicLink(atPath: "\(folder)/paper.pdf", withDestinationPath: "\(folder)/mock.html")
    #expect(actionOnOpen(paper, folder: folder, index: index) == DocumentAction.none)
    #expect(actionOnOpen(mock, folder: folder, index: index) == DocumentAction.none)
}

@Test func theFoldersLinesAreBlocksByTimeOrByFolder() {
    func made(_ relative: String) -> DocumentRow {
        DocumentRow(id: folderRowID(relative), line: DocumentLine(title: relative, link: relative, note: relative),
                    target: .file("/docs/\(relative)"), origin: .folder(modified: Date(timeIntervalSince1970: 0)))
    }
    let rows = ["reports/3.md", "top.md", "review/1.md", "reports/deep/2.md", "reports/1.md"].map(made)
    #expect(documentBlocks([], byFolder: false).isEmpty)
    #expect(documentBlocks([], byFolder: true).isEmpty)

    let byTime = documentBlocks(rows, byFolder: false, limit: 2)
    #expect(byTime == [DocumentBlock(key: .byTime, count: 5, shown: Array(rows.prefix(2)), more: 3, folded: false)])
    #expect(documentBlocks(rows, byFolder: false, expanded: [.byTime], limit: 2).first?.shown == rows)
    #expect(documentBlocks(rows, byFolder: false, folded: [.byTime], limit: 2).first?.shown.count == 2)

    let byFolder = documentBlocks(rows, byFolder: true, limit: 2)
    #expect(byFolder.map(\.folderName) == ["", "reports", "review"])
    #expect(byFolder.map(\.count) == [1, 3, 1])
    #expect(byFolder[1].shown.map { $0.line.link } == ["reports/3.md", "reports/deep/2.md"])
    #expect(byFolder.map(\.more) == [0, 1, 0])
    let folded = documentBlocks(rows, byFolder: true, folded: [.folder("reports")], expanded: [.folder("reports")], limit: 2)
    #expect(folded[1] == DocumentBlock(key: .folder("reports"), count: 3, shown: [], more: 0, folded: true))
    #expect(documentBlocks(rows, byFolder: true, expanded: [.folder("reports")], limit: 2)[1].shown.count == 3)
    #expect(documentBlocks(rows, byFolder: true).allSatisfy { $0.more == 0 })
}

@Test func aLineOfTheFolderSaysWhenItChangedAndThatItIsPicked() {
    let date = Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 7, minute: 5))!
    let fromFolder = DocumentRow(id: -1, line: DocumentLine(title: "A", link: "reports/a.md", note: "reports/a.md"),
                                 target: .file("/docs/reports/a.md"), origin: .folder(modified: date))
    let fromIndex = DocumentRow(id: 0, line: DocumentLine(title: "A", link: "reports/a.md"), target: .file("/docs/reports/a.md"))
    #expect(lineMarks(fromFolder, state: nil, picked: [], shownPagePath: nil) == ["03/09 07:05"])
    #expect(lineMarks(fromFolder, state: nil, picked: ["/docs/reports/a.md"], shownPagePath: nil) == ["03/09 07:05", "고른 문서"])
    #expect(lineMarks(fromFolder, state: nil, picked: [], shownPagePath: "/docs/reports/a.md") == ["03/09 07:05", "보는 중"])
    #expect(lineMarks(fromFolder, state: "열 수 없음", picked: [], shownPagePath: "/docs/reports/a.md") == ["03/09 07:05", "열 수 없음"])
    #expect(lineMarks(fromIndex, state: nil, picked: ["/docs/reports/a.md"], shownPagePath: nil).isEmpty)
    #expect(lineMarks(fromIndex, state: "파일 없음", picked: [], shownPagePath: nil) == ["파일 없음"])
    #expect(lineMarks(fromIndex, state: nil, picked: [], shownPagePath: "/docs/reports/a.md") == ["보는 중"])
    #expect(documentCount(12, of: 12) == "12")
    #expect(documentCount(3, of: 12) == "3/12")
    #expect(documentCount(0, of: 12) == "0/12")
}
