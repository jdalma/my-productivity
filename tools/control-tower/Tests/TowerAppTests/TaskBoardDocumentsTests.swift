import AppKit
import Foundation
import Testing
import TowerCore
@testable import TowerApp

private func scratch() throws -> (root: String, folder: String) {
    let root = FileManager.default.temporaryDirectory.appending(path: "tower-documents-\(UUID().uuidString)").path
    let folder = root + "/docs/example-team"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    for (name, text) in [("page.md", "# page"), ("mock.html", "<p>mock</p>"), ("notes.txt", "notes"), ("pic.svg", "<svg/>")] {
        try text.write(toFile: folder + "/" + name, atomically: true, encoding: .utf8)
    }
    try "outside".write(toFile: root + "/outside.md", atomically: true, encoding: .utf8)
    let real = realpath(folder, nil)!
    defer { free(real) }
    return (root, String(cString: real))
}

private func refuses(_ row: DocumentRow, stored: String, appURL: (String) -> URL? = { installedApp($0) }) -> Bool {
    switch documentFileOpen(row, stored: stored, appURL: appURL) {
    case .refused, .needsEditor: true
    default: false
    }
}

private func row(_ link: String?, folder: String, title: String = "Example") -> DocumentRow {
    DocumentRow(id: 0, line: DocumentLine(title: title, link: link, note: "an example note"), target: documentTarget(link, folder: folder))
}

private func lines(_ path: String) -> [String] {
    ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
}

@Test func aLineOpensAsAPageAWebLinkOrAFile() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    guard case .showPage(let page) = actionOnOpen(row("page.md", folder: folder), folder: folder) else {
        Issue.record("page.md is not a page")
        return
    }
    #expect(page.hasSuffix("/docs/example-team/page.md"))
    guard case .openFile(let mock) = actionOnOpen(row("mock.html", folder: folder), folder: folder) else {
        Issue.record("mock.html is not a file")
        return
    }
    #expect(mock.hasSuffix("/docs/example-team/mock.html"))
    #expect(actionOnOpen(row("https://example.com/a", folder: folder), folder: folder) == .openURL(URL(string: "https://example.com/a")!))
    for link in ["../../outside.md", root + "/outside.md", "file://\(folder)/page.md", "x-example://open", "later.md", nil] {
        #expect(actionOnOpen(row(link, folder: folder), folder: folder) == .none, "\(link ?? "nil")")
    }
}

@Test func aLineReplacedByALinkOutOfTheFolderSinceTheReadDoesNotOpen() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let read = row("page.md", folder: folder)
    #expect(read.target.opens)
    try FileManager.default.removeItem(atPath: folder + "/page.md")
    try FileManager.default.createSymbolicLink(atPath: folder + "/page.md", withDestinationPath: root + "/outside.md")
    #expect(actionOnOpen(read, folder: folder) == .none)
}

@MainActor @Test func underADryRunWhatLeavesTheAppIsALineInTheLog() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let log = root + "/actions.log"
    var shown: [String] = []
    var said: [String?] = []
    for link in ["https://example.com/a", "notes.txt", "page.md", "pic.svg"] {
        said.append(openDocument(row(link, folder: folder), folder: folder, stored: systemDefaultEditor, dryRun: log) { shown.append($0) })
    }
    #expect(lines(log).first == "open-url https://example.com/a")
    #expect(lines(log).count == 2)
    #expect(lines(log).last?.hasPrefix("open-file macOS-default /") == true)
    #expect(lines(log).last?.hasSuffix("/docs/example-team/notes.txt") == true)
    #expect(shown == ["\(folder)/page.md"])
    #expect(said.prefix(3) == [nil, nil, nil])
    #expect(said[3]?.hasPrefix("macOS 기본 앱으로 열지 않았습니다") == true)
    let editor = URL(fileURLWithPath: "/Applications/Example Editor.app")
    #expect(openDocument(row("pic.svg", folder: folder), folder: folder, stored: "com.example.editor", dryRun: log,
                         appURL: { _ in editor }) { shown.append($0) } == nil)
    #expect(lines(log).last?.hasPrefix("open-file \(editor.path) /") == true)
    #expect(lines(log).last?.hasSuffix("/docs/example-team/pic.svg") == true)
    for stored in [systemDefaultEditor, "com.example.editor"] {
        #expect(openDocument(row("mock.html", folder: folder), folder: folder, stored: stored, dryRun: log,
                             appURL: { _ in editor }) { shown.append($0) } == nil)
        #expect(lines(log).last == "open-file macOS-default \(folder)/mock.html")
    }
    run(.reveal("\(folder)/page.md"), dryRun: log)
    #expect(lines(log).last == "reveal \(folder)/page.md")
}

@Test func aFileThatLeavesTheAppGoesThroughTheBoardsOpenRules() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let fm = FileManager.default
    for name in ["run.command", "plain.command", "run.sh", "x.webloc", "x.pkg", "x.mobileconfig", "x.ics", "x.vcf", "x.xhtml",
                 "x.webarchive", "x.shtml", "x.html.txt", "run.html", "page.HTM"] {
        try "x".write(toFile: "\(folder)/\(name)", atomically: true, encoding: .utf8)
    }
    for name in ["run.command", "run.sh", "run.html"] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(folder)/\(name)") }
    try fm.createDirectory(atPath: "\(folder)/sub", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: "\(folder)/Fake.app/Contents", withIntermediateDirectories: true)
    let editor = URL(fileURLWithPath: "/Applications/Example Editor.app")
    try fm.createDirectory(atPath: "\(folder)/folder.html", withIntermediateDirectories: true)
    for link in ["run.command", "plain.command", "run.sh", "x.webloc", "x.pkg", "sub", ".", "Fake.app", "run.html", "folder.html"] {
        let r = row(link, folder: folder)
        #expect(r.target.opens, "\(link)")
        #expect(refuses(r, stored: systemDefaultEditor), "\(link)")
        #expect(refuses(r, stored: "com.example.editor", appURL: { _ in editor }), "\(link)")
        let style = DocumentRowStyle.of(r, fileOpen: documentFileOpen(r, stored: systemDefaultEditor))
        #expect(style.state == "열 수 없음", "\(link)")
        #expect(style.reason?.isEmpty == false, "\(link)")
    }
    for link in ["x.mobileconfig", "pic.svg", "x.ics", "x.vcf", "x.xhtml", "x.shtml"] {
        let r = row(link, folder: folder)
        #expect(documentFileOpen(r, stored: systemDefaultEditor) == .needsEditor(notInstalled: nil), "\(link)")
        #expect(documentFileOpen(r, stored: "", appURL: { _ in nil }) == .needsEditor(notInstalled: nil), "\(link)")
        #expect(documentFileOpen(r, stored: "com.example.gone", appURL: { _ in nil }) == .needsEditor(notInstalled: "com.example.gone"), "\(link)")
        #expect(!refuses(r, stored: "com.example.editor", appURL: { _ in editor }), "\(link)")
    }
    #expect(refuses(row("x.webarchive", folder: folder), stored: systemDefaultEditor))
    // the one exception (D#12): a file named .html or .htm, and nothing else
    for link in ["mock.html", "page.HTM"] {
        #expect(opensInBrowser(link))
        #expect(!refuses(row(link, folder: folder), stored: systemDefaultEditor), "\(link)")
    }
    for name in ["x.xhtml", "x.shtml", "x.webarchive", "x.html.txt", "pic.svg", "x.mobileconfig", "html", "x.htmlx"] {
        #expect(!opensInBrowser(name), "\(name)")
    }
    for link in ["notes.txt", "x.html.txt", "page.md", "https://example.com/a", "later.md", "../../outside.md"] {
        #expect(!refuses(row(link, folder: folder), stored: systemDefaultEditor), "\(link)")
    }
    let d = TeamDocuments(folder: folder, indexPath: folder + "/index.md", stamp: nil, content: .groups([]), sections: [
        DocumentSection(title: "", rows: ["page.md", "run.command", "notes.txt", "sub"].enumerated().map { i, link in
            DocumentRow(id: i, line: DocumentLine(title: link, link: link), target: documentTarget(link, folder: folder))
        }),
    ])
    #expect(fileOpensByRow(d, stored: systemDefaultEditor) == [
        0: .window, 1: .refused(openRefusal("\(folder)/run.command")!), 2: .defaultApp, 3: .refused(openRefusal("\(folder)/sub")!),
    ])
}

@MainActor @Test func aRefusedFileIsNeverHandedOverEvenWhenOpenIsAsked() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try "x".write(toFile: "\(folder)/run.command", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(folder)/run.command")
    try FileManager.default.createDirectory(atPath: "\(folder)/sub", withIntermediateDirectories: true)
    let log = root + "/actions.log"
    try "x".write(toFile: "\(folder)/run.html", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(folder)/run.html")
    for link in ["run.command", "sub", "pic.svg", "run.html"] {
        let said = openDocument(row(link, folder: folder), folder: folder, stored: systemDefaultEditor, dryRun: log) { _ in }
        #expect(said != nil, "\(link)")
    }
    #expect(lines(log).isEmpty)
}

@Test func aLineThatDoesNotOpenSaysWhyOnTheLineInThePresent() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try "x".write(toFile: "\(folder)/run.command", atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: "\(folder)/run.command")
    try "x".write(toFile: "\(folder)/x.pkg", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: "\(folder)/sub", withIntermediateDirectories: true)
    func style(_ link: String?, stored: String = systemDefaultEditor) -> DocumentRowStyle {
        let r = row(link, folder: folder)
        return DocumentRowStyle.of(r, fileOpen: documentFileOpen(r, stored: stored))
    }
    #expect(style("run.command").stateText == "열 수 없음: 실행 권한이 있는 파일입니다")
    #expect(style("run.command").help == "실행 권한이 있는 파일입니다: \(folder)/run.command")
    #expect(style("sub").stateText == "열 수 없음: 문서 파일이 아닙니다(폴더, 앱, 묶음)")
    #expect(style("x.pkg").stateText?.hasPrefix("열 수 없음: 문서가 아닌 파일 종류입니다(") == true)
    #expect(style("x.pkg").stateText?.contains("com.apple.installer-package-archive") == false)
    #expect(fileKindName("\(folder)/x.zzunknown") == ".zzunknown 파일")
    #expect(fileKindName("\(folder)/sub") == "확장자 없는 파일")
    #expect(style("pic.svg").stateText == "열 수 없음: 에디터를 골라야 엽니다")
    #expect(style("pic.svg").help.hasPrefix("macOS 기본 앱은 마크다운, 일반 텍스트, PDF, 이미지만 엽니다("))
    #expect(style("pic.svg").help.hasSuffix("). 설정에서 에디터를 고르면 열 수 있습니다: \(folder)/pic.svg"))
    #expect(!style("pic.svg").help.contains("public.svg-image"))
    #expect(style("pic.svg", stored: "com.example.gone").stateText == "열 수 없음: 고른 에디터를 찾지 못했습니다")
    #expect(style("pic.svg", stored: "com.example.gone").help.hasPrefix("고른 에디터를 찾지 못했습니다(com.example.gone). "))
    #expect(style("pic.svg", stored: "com.example.gone").help.hasSuffix("설정에서 에디터를 다시 고르면 열 수 있습니다: \(folder)/pic.svg"))
    #expect(style("../../outside.md").stateText == "열 수 없음: 팀 문서 폴더 밖의 경로라 열지 않습니다")
    #expect(style("file:///etc/hosts").stateText == "열 수 없음: http, https 링크만 엽니다")
    #expect(style(nil).stateText == "열 수 없음: 링크가 없는 줄입니다")
    #expect(style("later.md").stateText == "파일 없음")
    for link in ["run.command", "sub", "x.pkg", "pic.svg", "mock.html", "notes.txt", "page.md", "https://example.com/a"] {
        let s = style(link)
        #expect(s.stateText?.contains("않았습니다") != true, "\(link)")
        #expect(s.stateText?.contains(folder) != true, "\(link)")
        #expect(!s.help.isEmpty, "\(link)")
    }
}

@Test func aLineThatOpensSaysWhatOpensIt() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let editor = URL(fileURLWithPath: "/Applications/Example Editor.app")
    func help(_ link: String, stored: String) -> String {
        let r = row(link, folder: folder)
        return DocumentRowStyle.of(r, fileOpen: documentFileOpen(r, stored: stored, appURL: { _ in editor })).help
    }
    #expect(help("notes.txt", stored: systemDefaultEditor) == "macOS 기본 앱으로 열기: \(folder)/notes.txt")
    #expect(help("notes.txt", stored: "com.example.editor") == "Example Editor 앱으로 열기: \(folder)/notes.txt")
    #expect(help("pic.svg", stored: "com.example.editor") == "Example Editor 앱으로 열기: \(folder)/pic.svg")
    for stored in [systemDefaultEditor, "com.example.editor"] {
        #expect(help("mock.html", stored: stored) == "macOS 기본 앱(보통 브라우저)으로 열기: \(folder)/mock.html")
    }
    #expect(help("page.md", stored: systemDefaultEditor) == "창 안에서 열기: \(folder)/page.md")
    #expect(help("https://example.com/a", stored: systemDefaultEditor) == "브라우저에서 열기: https://example.com/a")
    #expect(shownReason("열지 않았습니다: 실행 권한이 있는 파일입니다: /a/b", path: "/a/b") == "실행 권한이 있는 파일입니다")
    #expect(shownReason("파일이 없습니다: /a/b", path: "/a/b") == "파일이 없습니다")
}

@Test func aLinesMenuCopiesItsPathOrItsLink() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    #expect(documentMenuItems(row("page.md", folder: folder)) == [.copyPath("\(folder)/page.md"), .reveal("\(folder)/page.md")])
    #expect(documentMenuItems(row("https://example.com/a", folder: folder)) == [.copyLink("https://example.com/a")])
    #expect(documentMenuItems(row("later.md", folder: folder)) == [.copyPath("\(folder)/later.md")])
    #expect(documentMenuItems(row("../../outside.md", folder: folder)) == [.copyPath("../../outside.md")])
    #expect(documentMenuItems(row("file:///etc/hosts", folder: folder)) == [.copyLink("file:///etc/hosts")])
    #expect(documentMenuItems(row(nil, folder: folder)).isEmpty)
    #expect(DocumentMenuItem.copyPath("").title == "경로 복사")
    #expect(DocumentMenuItem.reveal("").title == "Finder에서 보기")
    #expect(DocumentMenuItem.copyLink("").title == "링크 복사")
}

@Test func aLineSaysItsKindAndWhyItDoesNotOpen() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let page = row("page.md", folder: folder), web = row("https://example.com/a", folder: folder)
    #expect(DocumentRowStyle.of(page).label(page.line) == "Example, 문서, an example note")
    #expect(DocumentRowStyle.of(web).label(web.line) == "Example, 링크, an example note")
    #expect(DocumentRowStyle.of(page).state == nil)
    #expect(DocumentRowStyle.of(row("later.md", folder: folder)).state == "파일 없음")
    let outside = DocumentRowStyle.of(row("../../outside.md", folder: folder))
    #expect(outside.state == "열 수 없음")
    #expect(outside.help == "팀 문서 폴더 밖의 경로라 열지 않습니다: ../../outside.md")
    #expect(DocumentRowStyle.of(row("file:///etc/hosts", folder: folder)).help == "http, https 링크만 엽니다: file:///etc/hosts")
}

@Test func theHeadSaysHowManyDocumentsOrWhyNone() {
    func documents(_ content: DocumentIndexContent, rows: Int = 0) -> TeamDocuments {
        let section = DocumentSection(title: "", rows: (0..<rows).map { DocumentRow(id: $0, line: DocumentLine(title: "t", link: nil), target: .blocked(.noLink)) })
        return TeamDocuments(folder: "/d", indexPath: "/d/index.md", stamp: nil, content: content, sections: rows > 0 ? [section] : [])
    }
    #expect(documentsSummary(nil) == "")
    #expect(documentsSummary(documents(.missing)) == "목록 파일 없음")
    #expect(documentsSummary(documents(.unreadable("x"))) == "읽지 못함")
    #expect(documentsSummary(documents(.groups([]))) == "없음")
    #expect(documentsSummary(documents(.groups([]), rows: 3)) == "3")
}

// MARK: - T218: an Excalidraw drawing opens in the app macOS has for it, else Finder shows it

@MainActor @Test func aDrawingOpensInItsAppOrFinderShowsIt() throws {
    let (root, folder) = try scratch()
    defer { try? FileManager.default.removeItem(atPath: root) }
    let drawing = folder + "/flow.excalidraw"
    try #"{"type":"excalidraw"}"#.write(toFile: drawing, atomically: true, encoding: .utf8)
    let app = URL(fileURLWithPath: "/Applications/Example Draw.app")
    let line = row("flow.excalidraw", folder: folder)
    // macOS knows no document type for it, yet the board's other open rules still hold
    #expect(openRefusal(drawing) != nil && openRefusal(drawing, documentType: false) == nil)
    #expect(drawingOpen(drawing, app: { _ in app }) == .app(app))
    #expect(drawingOpen(drawing, app: { _ in nil }) == .reveal)
    // whatever editor the settings name: the drawing goes by its own rule
    #expect(documentFileOpen(line, stored: vsCodeID, drawingApp: { _ in app }) == .app("Example Draw"))
    #expect(documentFileOpen(line, stored: "", drawingApp: { _ in nil }) == .reveal)
    #expect(DocumentRowStyle.of(line, fileOpen: .reveal).help.hasPrefix("이 파일을 여는 앱이 없어 Finder에서 보여 줍니다"))
    // what leaves the app, as the dry run writes it: the app, or Finder
    let log = root + "/actions.log"
    #expect(openDocument(line, folder: folder, stored: vsCodeID, dryRun: log, drawingApp: { _ in app }, show: { _ in }) == nil)
    #expect(openDocument(line, folder: folder, stored: vsCodeID, dryRun: log, drawingApp: { _ in nil }, show: { _ in }) == nil)
    let opened = URL(fileURLWithPath: drawing).resolvingSymlinksInPath().path  // as `openFile` writes a path
    #expect(lines(log) == ["open-file \(app.path) \(opened)", "reveal \(opened)"])
    // a drawing that could run is not opened, nor shown
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drawing)
    guard case .refused = drawingOpen(drawing, app: { _ in app }) else { Issue.record("an executable drawing must be refused"); return }
    #expect(openDocument(line, folder: folder, stored: "", dryRun: log, drawingApp: { _ in app }, show: { _ in })?.contains("실행 권한") == true)
}
