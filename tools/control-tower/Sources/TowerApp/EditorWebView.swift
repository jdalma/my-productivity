import AppKit
import os
import SwiftUI
import TowerCore
import WebKit

// The editor (G4 I4): the Monaco page editor-web builds, in a WKWebView, served from the app's own scheme, with the
// bridge of EditorBridge.swift. The page is outside the trust boundary: it reaches files only through `EditorFiles`.

/// The built editor page: Contents/Resources/editor in the app, or SwiftPM's resource bundle beside the executable
/// (`swift run`). nil when editor-web was not built: the editor is off, the rest of the app is not.
let editorPageFolder: URL? = {
    let swiftPM = Bundle.main.bundleURL.appending(path: "ControlTower_TowerCore.bundle/Resources/editor")
    return [Bundle.main.resourceURL?.appending(path: "editor"), swiftPM].compactMap { $0 }
        .first { FileManager.default.fileExists(atPath: $0.appending(path: "index.html").path) }
}()

/// The editor at the font scale of the board; `controller` keeps the page and its files across SwiftUI updates.
struct EditorWebView: NSViewRepresentable {
    let controller: EditorController
    @Environment(\.boardFontScale) private var scale

    func makeNSView(context: Context) -> EditorPageView { controller.web }

    func updateNSView(_ nsView: EditorPageView, context: Context) {
        controller.fontSize = EditorController.baseFontSize * scale
    }
}

/// The editor in the board: one page per controller. The identity is the controller's: another one (another
/// worktree) makes the view again, so its page joins the window; a representable otherwise keeps the view it made
/// first, and the new page, never in a window, has no size and Monaco does not start (T33).
struct EditorSlot: View {
    let editor: EditorController

    var body: some View {
        EditorWebView(controller: editor).id(ObjectIdentifier(editor))
    }
}

/// A web view that tells its controller when the app's appearance changes, for the page's theme.
final class EditorPageView: WKWebView {
    var appearanceChanged: (@MainActor (Bool) -> Void)?
    /// The view is in a window and has a size: the first time, the page may load (T33).
    var shown: (@MainActor () -> Void)?

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?(isDark)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        tellShown()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        tellShown()
    }

    private func tellShown() {
        guard window != nil, bounds.width > 0, bounds.height > 0, let shown else { return }
        self.shown = nil
        shown()
    }
}

/// One editor: the page, its files, and the commands waiting for the page to be ready.
@MainActor final class EditorController: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    static let scheme = "ctedit"
    /// The page's font size at the standard scale, Monaco's own default.
    static let baseFontSize = 13.0
    private static let log = Logger(subsystem: "local.control-tower", category: "editor")

    let files: EditorFiles
    let web: EditorPageView
    private var ready = false
    private var waiting: [EditorCommand] = []
    /// The file the page shows, opened again when the page has to load again.
    private var shown: (path: String, line: Int?)?
    /// What the page last said of each file it shows.
    var onDirty: ((String, Bool) -> Void)?

    var fontSize = baseFontSize {
        didSet { if fontSize != oldValue { Task { _ = await send(.setFontSize(fontSize)) } } }
    }

    init(roots: [String], page: URL) {
        files = EditorFiles(roots: roots)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(EditorPageScheme(folder: page.path), forURLScheme: Self.scheme)
        web = EditorPageView(frame: .zero, configuration: config)
        super.init()
        // the controller holds the view; the content controller would hold the controller back, so it gets a proxy
        config.userContentController.addScriptMessageHandler(WeakReplyHandler(self), contentWorld: .page, name: "ct")
        web.isInspectable = true
        web.navigationDelegate = self
        web.appearanceChanged = { [weak self] dark in Task { _ = await self?.send(.setTheme(dark: dark)) } }
        // Monaco reads the page's size when it starts: a page loaded in no window (another worktree's editor made
        // before SwiftUI shows it, a hidden tab) fails or stays blank. It loads once the view is shown (T33).
        web.shown = { [weak self] in self?.loadPage() }
    }

    private func loadPage() { web.load(URLRequest(url: URL(string: "\(Self.scheme)://app/index.html")!)) }

    /// Opens `path`, read-only unless Swift unlocked it (D#5 b): its real path and whether it is locked; nil when it
    /// is outside the roots or not a text file.
    func open(_ path: String, line: Int? = nil) async -> (path: String, readOnly: Bool)? {
        guard let command = await files.open(path, line: line), case .openFile(let real, _, _, _, let readOnly) = command else { return nil }
        shown = (real, line)
        await send(command)
        return (real, readOnly)
    }

    /// The page's process ended (a crash, memory pressure): its buffers are gone. Load it again, open the shown file
    /// from disk, and hold commands until the new page is ready. An unsaved edit is lost.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("editor page ended; loading it again")
        ready = false
        waiting = []
        loadPage()
        guard let shown else { return }
        onDirty?(shown.path, false)
        Task { _ = await open(shown.path, line: shown.line) }
    }

    func setReadOnly(_ path: String, _ readOnly: Bool) async {
        if let command = await files.setReadOnly(path, readOnly) { await send(command) }
    }

    /// Runs `command` in the page, after it is ready; the page's answer, nil while it waits or when the call failed.
    @discardableResult
    func send(_ command: EditorCommand) async -> [String: Any]? {
        guard ready else {
            waiting.append(command)
            return nil
        }
        do {
            let m = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command))
            let r = try await web.callAsyncJavaScript("return await window.ctBridge.receive(m)", arguments: ["m": m], contentWorld: .page)
            return r as? [String: Any]
        } catch {
            Self.log.error("editor command failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: message.body),
              let request = try? JSONDecoder().decode(EditorRequest.self, from: data) else {
            replyHandler(nil, "unknown message")
            return
        }
        switch request {
        case .ready: becomeReady()
        case .dirtyChanged(let path, let dirty): onDirty?(path, dirty)
        case .log(let text): Self.log.error("editor page: \(text, privacy: .public)")
        case .readFile, .writeFile, .cursor: break
        }
        Task {
            let reply = await files.handle(request)
            let object = (try? JSONEncoder().encode(reply)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
            replyHandler(object, nil)
        }
    }

    private func becomeReady() {
        ready = true
        let queued = [.setTheme(dark: web.isDark), .setFontSize(fontSize)] + waiting
        waiting = []
        Task { for command in queued { await send(command) } }
    }
}

/// Passes the page's messages to the controller without the content controller keeping it alive.
private final class WeakReplyHandler: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: EditorController?

    init(_ target: EditorController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let target else { return replyHandler(nil, "editor closed") }
        target.userContentController(controller, didReceive: message, replyHandler: replyHandler)
    }
}

/// `ctedit://app/<path>`: the built page's files, and nothing outside its folder (`editorPageFile`).
private final class EditorPageScheme: NSObject, WKURLSchemeHandler {
    let folder: String

    init(folder: String) { self.folder = folder }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        guard let file = editorPageFile(folder: folder, urlPath: url.path), let data = FileManager.default.contents(atPath: file) else {
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            task.didFinish()
            return
        }
        let type = editorContentType(URL(fileURLWithPath: file).pathExtension)
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": type, "Content-Length": "\(data.count)"])!)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
