import Foundation
import Testing
@testable import TowerApp

// T137: a report or ticket path opens in the chosen editor.

private let vsCode = URL(fileURLWithPath: "/Apps/Visual Studio Code.app")
private let zed = URL(fileURLWithPath: "/Apps/Zed.app")
private func installed(_ apps: [String: URL]) -> (String) -> URL? { { apps[$0] } }
private func openable(_: String) -> String? { nil }

@Test func withNothingChosenVSCodeOpensTheFileWhenInstalledElseTheMacOSDefault() {
    #expect(fileOpenPlan("/r/a.md", stored: "", check: openable, appURL: installed([vsCodeID: vsCode]))
            == .open(app: vsCode, note: nil))
    #expect(fileOpenPlan("/r/a.md", stored: "", check: openable, appURL: installed([:])) == .open(app: nil, note: nil))
}

@Test func theChosenEditorOpensTheFileAndMacOSDefaultIsTheSystems() {
    let apps = installed([vsCodeID: vsCode, "dev.zed.Zed": zed])
    #expect(fileOpenPlan("/r/a.md", stored: "dev.zed.Zed", check: openable, appURL: apps) == .open(app: zed, note: nil))
    #expect(fileOpenPlan("/r/a.md", stored: systemDefaultEditor, check: openable, appURL: apps) == .open(app: nil, note: nil))
}

@Test func aChosenEditorNoLongerInstalledFallsBackToTheMacOSDefaultAndSaysSo() {
    guard case .open(nil, let note?) = fileOpenPlan("/r/a.md", stored: "dev.zed.Zed", check: openable, appURL: installed([vsCodeID: vsCode]))
    else { Issue.record("no fallback"); return }
    #expect(note.contains("에디터를 찾지 못해") && note.contains("기본 앱"))
}

@Test func aFileTheCheckRefusesOpensInNoAppAndSaysWhy() {
    // R54 L1: the same check whichever app would open it, the chosen editor too
    for stored in ["", systemDefaultEditor, "dev.zed.Zed", "com.example.Gone"] {
        #expect(fileOpenPlan("/r/x.command", stored: stored, check: { _ in "열지 않았습니다: 이유" },
                             appURL: installed([vsCodeID: vsCode, "dev.zed.Zed": zed])) == .refused("열지 않았습니다: 이유"))
    }
}

/// The test instance opens nothing: the request (which app, which file) is a line in its actions log.
@Test func underADryRunTheOpenIsALineNamingTheAppAndTheFile() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "report.md").path, log = dir.appending(path: "actions.log").path
    try "x".write(toFile: file, atomically: true, encoding: .utf8)
    let opened = Opened()
    #expect(openFile(file, stored: "", dryRun: log, appURL: installed([vsCodeID: vsCode]), opener: opened.open, failed: opened.fail) == nil)
    #expect(openFile(file, stored: systemDefaultEditor, dryRun: log, appURL: installed([:]), opener: opened.open, failed: opened.fail) == nil)
    #expect(openFile(dir.appending(path: "gone.md").path, stored: "", dryRun: log, appURL: installed([:]), opener: opened.open, failed: opened.fail)?
            .hasPrefix("파일이 없습니다") == true)
    #expect(try String(contentsOfFile: log, encoding: .utf8)
            == "open-file \(vsCode.path) \(file)\nopen-file macOS-default \(file)\n")
    // R54 S2: logged, and never opened
    #expect(opened.calls.isEmpty && opened.failures.isEmpty)
}

@Test func theSettingShowsTheInstalledEditorsTheDefaultAndAnotherPickedApp() {
    let apps = installed([vsCodeID: vsCode, "dev.zed.Zed": zed, "com.example.Picked": URL(fileURLWithPath: "/Apps/Picked.app")])
    #expect(editorChoices(stored: "", appURL: apps).map(\.id) == [vsCodeID, "dev.zed.Zed", systemDefaultEditor])
    #expect(editorChoices(stored: "com.example.Picked", appURL: apps).map(\.id)
            == [vsCodeID, "dev.zed.Zed", "com.example.Picked", systemDefaultEditor])
    let gone = editorChoices(stored: "com.example.Gone", appURL: apps).first { $0.id == "com.example.Gone" }
    #expect(gone?.name == "com.example.Gone (찾지 못함)")
    #expect(shownEditor(stored: "", appURL: apps) == vsCodeID)
    #expect(shownEditor(stored: "", appURL: installed([:])) == systemDefaultEditor)
}

/// What `openFile` asked to open, and what it said failed.
private final class Opened: @unchecked Sendable {
    var calls: [(file: String, app: URL?)] = []
    var failures: [String] = []
    var error: Error?
    func open(_ file: URL, _ app: URL?, _ done: @escaping @Sendable (Error?) -> Void) {
        calls.append((file.path, app))
        done(error)
    }
    func fail(_ why: String) { failures.append(why) }
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "t137-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Outside the test instance the file goes to the opener, its links followed; a failure the app reports is said (R54 S1).
@Test func outsideADryRunTheOpenerGetsTheFileAndTheAppAndItsFailureIsSaid() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appending(path: "report.md"), link = dir.appending(path: "link.md")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let opened = Opened()
    #expect(openFile(link.path, stored: "", dryRun: nil, appURL: installed([vsCodeID: vsCode]), opener: opened.open, failed: opened.fail) == nil)
    #expect(opened.calls.map(\.file) == [file.path] && opened.calls.map(\.app) == [vsCode])
    opened.error = CocoaError(.fileReadNoPermission)
    _ = openFile(file.path, stored: systemDefaultEditor, dryRun: nil, appURL: installed([:]), opener: opened.open, failed: opened.fail)
    #expect(opened.calls.last?.app == nil)
    #expect(opened.failures.count == 1 && opened.failures[0].hasPrefix("열지 못했습니다: "))
}

/// R54 M1: only a document opens; what would run (an app, a script, an installer, an internet shortcut, a file that
/// may be executed), a folder, a relative path, or a link to any of them, is refused with why.
@Test func onlyADocumentIsOpenedNeverSomethingThatRuns() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fm = FileManager.default
    func file(_ name: String, executable: Bool = false) throws -> String {
        let p = dir.appending(path: name).path
        try "x".write(toFile: p, atomically: true, encoding: .utf8)
        if executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p) }
        return p
    }
    for ok in ["report.md", "notes.txt", "data.json", "shot.png", "doc.pdf"] { #expect(openRefusal(try file(ok)) == nil, "\(ok)") }
    let app = dir.appending(path: "Calc.app").path
    try fm.createDirectory(atPath: app + "/Contents", withIntermediateDirectories: true)
    let refused = [
        try file("run.command"), try file("run.sh"), try file("run.py"), try file("site.webloc"), try file("site.url"),
        try file("setup.pkg"), try file("tool.jar"), try file("noext"), try file("report2.md", executable: true),
        app, dir.path, dir.appending(path: "gone.md").path, "reports/T1.md",
    ]
    try fm.createSymbolicLink(atPath: dir.appending(path: "to-app.md").path, withDestinationPath: app)
    try fm.createSymbolicLink(atPath: dir.appending(path: "to-command.md").path, withDestinationPath: dir.appending(path: "run.command").path)
    for p in refused + [dir.appending(path: "to-app.md").path, dir.appending(path: "to-command.md").path] {
        let why = openRefusal(p)
        #expect(why != nil && why!.hasSuffix(p), "\(p): \(why ?? "opened")")
    }
    #expect(openRefusal(dir.appending(path: "gone.md").path) == "파일이 없습니다: \(dir.appending(path: "gone.md").path)")
}

/// R54a L1: the macOS default app opens only Markdown, plain text, PDF and images; a chosen editor keeps the wider
/// rule. Real file names, the real checks.
@Test func theMacOSDefaultAppOpensOnlyDocumentsItShowsAndAnEditorTheRest() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    func file(_ name: String) throws -> String {
        let p = dir.appending(path: name).path
        try "x".write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }
    let editor = installed([vsCodeID: vsCode, "dev.zed.Zed": zed])
    for name in ["report.md", "notes.txt", "run.log", "data.csv", "doc.pdf", "shot.png"] {
        #expect(fileOpenPlan(try file(name), stored: systemDefaultEditor, appURL: editor) == .open(app: nil, note: nil), "\(name)")
    }
    for name in ["page.html", "event.ics", "card.vcf", "profile.mobileconfig", "app.jnlp", "data.json", "pic.svg"] {
        let p = try file(name)
        for stored in [systemDefaultEditor, "com.example.Gone"] {
            guard case .refused(let why) = fileOpenPlan(p, stored: stored, appURL: editor) else { Issue.record("\(name) opened"); continue }
            #expect(why.hasPrefix("macOS 기본 앱으로 열지 않았습니다") && why.hasSuffix(p))
        }
        #expect(fileOpenPlan(p, stored: "", appURL: installed([:])) != .open(app: nil, note: nil), "\(name) with no editor installed")
        #expect(fileOpenPlan(p, stored: "dev.zed.Zed", appURL: editor) == .open(app: zed, note: nil), "\(name) in the chosen editor")
        #expect(fileOpenPlan(p, stored: "", appURL: editor) == .open(app: vsCode, note: nil), "\(name) in VS Code")
    }
}
