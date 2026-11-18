import AppKit
import SwiftUI
import TowerCore
import UniformTypeIdentifiers

// A report or ticket path opens in the editor the settings name (T137). The editor is kept by its bundle identifier,
// never its folder: an app moved to Downloads is the same app.

let fileEditorKey = "fileEditor"
let vsCodeID = "com.microsoft.VSCode"
/// The stored value for "the app macOS gives that kind of file"; an empty value is nothing chosen yet.
let systemDefaultEditor = "system"

/// The editors offered when installed, in this order; any other app is picked with 다른 앱 선택….
let knownEditors = [vsCodeID, "com.todesktop.230313mzl4w4u92", "dev.zed.Zed", "com.jetbrains.intellij", "com.jetbrains.intellij.ce",
                    "com.sublimetext.4", "com.panic.Nova", "com.barebones.bbedit", "com.vscodium", "com.apple.dt.Xcode"]

func installedApp(_ id: String) -> URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

enum FileOpenPlan: Equatable {
    /// `app` nil: the macOS default for the file. `note`: what the reader should know, said beside the path.
    case open(app: URL?, note: String?)
    /// Not opened, and why.
    case refused(String)
}

/// Why `path` is not opened, nil when it may be (R54 M1). The path comes from the task board, and a click must never
/// run anything, in whichever app it opens: so only an absolute path whose target, links followed, is a regular file
/// with no execute permission and a document's type (text, PDF, image), never a script, an executable or an internet
/// shortcut. An app, an installer, a folder or any other bundle is no regular file or no document.
func openRefusal(_ path: String) -> String? {
    guard path.hasPrefix("/") else { return "열지 않았습니다: 절대 경로가 아닙니다: \(path)" }
    let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
    guard let a = try? FileManager.default.attributesOfItem(atPath: target.path) else { return "파일이 없습니다: \(path)" }
    guard a[.type] as? FileAttributeType == .typeRegular else { return "열지 않았습니다: 문서 파일이 아닙니다(폴더, 앱, 묶음): \(path)" }
    if let mode = a[.posixPermissions] as? Int, mode & 0o111 != 0 { return "열지 않았습니다: 실행 권한이 있는 파일입니다: \(path)" }
    let type = UTType(filenameExtension: target.pathExtension) ?? .data
    let runs: [UTType] = [.executable, .script, .internetLocation, .internetShortcut]
    guard [.text, .pdf, .image].contains(where: type.conforms), !runs.contains(where: type.conforms) else {
        return "열지 않았습니다: 문서가 아닌 파일 종류입니다(\(type.identifier)): \(path)"
    }
    return nil
}

/// Why `path` is not handed to the macOS default app, nil when it may be (R54a L1). That app is whatever the system
/// gives the type: for HTML a browser, for a calendar or contact file an import, for a profile its install screen. So
/// only what it shows as a document: plain text (Markdown among it), PDF, and an image that is not also text (an SVG
/// opens in a browser). Applies after `openRefusal`.
func defaultAppRefusal(_ path: String) -> String? {
    let type = UTType(filenameExtension: URL(fileURLWithPath: path).resolvingSymlinksInPath().pathExtension) ?? .data
    if type.conforms(to: .plainText) || type.conforms(to: .pdf) || (type.conforms(to: .image) && !type.conforms(to: .text)) { return nil }
    return "macOS 기본 앱으로 열지 않았습니다: 마크다운, 일반 텍스트, PDF, 이미지만 엽니다(\(type.identifier)). 설정에서 에디터를 고르면 열 수 있습니다: \(path)"
}

func fileOpenPlan(_ path: String, stored: String, check: (String) -> String? = { openRefusal($0) },
                  defaultCheck: (String) -> String? = { defaultAppRefusal($0) },
                  appURL: (String) -> URL? = { installedApp($0) }) -> FileOpenPlan {
    if let why = check(path) { return .refused(why) }
    let app: URL?, note: String?
    switch stored {
    case "": (app, note) = (appURL(vsCodeID), nil)
    case systemDefaultEditor: (app, note) = (nil, nil)
    default:
        app = appURL(stored)
        note = app == nil ? "에디터를 찾지 못해 macOS 기본 앱으로 열었습니다 (\(stored))" : nil
    }
    if app == nil, let why = defaultCheck(path) { return .refused(why) }
    return .open(app: app, note: note)
}

/// Hands `file` to `app`, or with none to the macOS default for it; `done` gets what the system says went wrong.
func workspaceOpen(_ file: URL, _ app: URL?, _ done: @escaping @Sendable (Error?) -> Void) {
    let config = NSWorkspace.OpenConfiguration()
    if let app {
        NSWorkspace.shared.open([file], withApplicationAt: app, configuration: config) { _, e in done(e) }
    } else {
        NSWorkspace.shared.open(file, configuration: config) { _, e in done(e) }
    }
}

/// Opens `path` as the settings say, its links followed; the line to show beside it, nil when it went as asked. A
/// failure the system reports later goes to `failed` (R54 S1). Under `TOWER_DRY_RUN` the request is a line in that
/// file and `opener` is never called (R54 S2).
func openFile(_ path: String, stored: String, dryRun: String? = towerDryRun, appURL: (String) -> URL? = { installedApp($0) },
              opener: (URL, URL?, @escaping @Sendable (Error?) -> Void) -> Void = { workspaceOpen($0, $1, $2) },
              failed: @escaping @Sendable (String) -> Void) -> String? {
    switch fileOpenPlan(path, stored: stored, appURL: appURL) {
    case .refused(let why):
        return why
    case .open(let app, let note):
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if let dryRun {
            recordDryRun("open-file \(app?.path ?? "macOS-default") \(file.path)", to: dryRun)
        } else {
            opener(file, app) { e in if let e { failed("열지 못했습니다: \(e.localizedDescription)") } }
        }
        return note
    }
}

struct EditorChoice: Equatable {
    var id: String
    var name: String
}

private func appName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

/// The settings' list: the known editors installed, the app picked before (said so when it is gone), the macOS default.
func editorChoices(stored: String, appURL: (String) -> URL? = { installedApp($0) }) -> [EditorChoice] {
    var list = knownEditors.compactMap { id in appURL(id).map { EditorChoice(id: id, name: appName($0)) } }
    if !stored.isEmpty, stored != systemDefaultEditor, !list.contains(where: { $0.id == stored }) {
        list.append(EditorChoice(id: stored, name: appURL(stored).map(appName) ?? "\(stored) (찾지 못함)"))
    }
    return list + [EditorChoice(id: systemDefaultEditor, name: "macOS 기본 앱")]
}

/// What the setting shows: the choice made, or with none the one a path would open in.
func shownEditor(stored: String, appURL: (String) -> URL? = { installedApp($0) }) -> String {
    stored.isEmpty ? (appURL(vsCodeID) != nil ? vsCodeID : systemDefaultEditor) : stored
}

/// The settings' 파일을 열 에디터 row.
struct EditorPicker: View {
    @AppStorage(fileEditorKey) private var stored = ""
    private static let other = "\u{1}other"

    var body: some View {
        Picker("파일을 열 에디터", selection: Binding(get: { shownEditor(stored: stored) }, set: { choose($0) })) {
            ForEach(editorChoices(stored: stored), id: \.id) { Text($0.name).tag($0.id) }
            Divider()
            Text("다른 앱 선택…").tag(Self.other)
        }
    }

    private func choose(_ id: String) {
        guard id == Self.other else { stored = id; return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "선택"
        if panel.runModal() == .OK, let picked = panel.url.flatMap({ Bundle(url: $0)?.bundleIdentifier }) { stored = picked }
    }
}

/// A file's path as its name, looking like a link: pressing it opens the file in the chosen editor; the copy button
/// and the context menu copy the whole path. What happened when it could not open as asked is said under it.
struct OpenPath: View {
    let path: String
    /// What the file is, for labels: `담당 보고서` → `담당 보고서 열기`, `담당 보고서 경로 복사`.
    let what: String
    var mono = false
    @AppStorage(fileEditorKey) private var stored = ""
    @State private var note: String?

    var body: some View {
        let name = (path as NSString).lastPathComponent
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Button(action: open) {
                    Text(mono ? path : name).underline().foregroundStyle(.link)
                        .scaledFont(.callout, design: .monospaced).fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .help("\(what) 열기: \(path)")
                .accessibilityLabel("\(what) 열기: \(name)")
                .contextMenu {
                    Button("열기", action: open)
                    Button("경로 복사") { copy(path) }
                }
                Button { copy(path) } label: { Image(systemName: "doc.on.doc").scaledFont(.caption1) }
                    .buttonStyle(.borderless)
                    .help("\(what) 경로 복사: \(path)")
                    .accessibilityLabel("\(what) 경로 복사")
            }
            if let note {
                Label(note, systemImage: "exclamationmark.triangle").scaledFont(.caption1).foregroundStyle(TaskColor.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func open() {
        let shown = $note
        note = openFile(path, stored: stored) { why in Task { @MainActor in shown.wrappedValue = why } }
    }
}
