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

    // the board's ⌘K steps aside while the editor has the keyboard (KeyRouting.swift)
    override func becomeFirstResponder() -> Bool {
        defer { EditorKeyFocus.shared.update() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { EditorKeyFocus.shared.update() }
        return super.resignFirstResponder()
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
    /// A language server notice for the user: not installed (once per server), or ended.
    var onLanguageNotice: ((String) -> Void)?

    /// This editor's language servers (D#14 a: one client per server), by the channel the page names them with.
    let editorID = EditorController.nextID()
    private let servers: LanguageServerHost
    private var channels: [String: LanguageServerKey] = [:]
    private var noticed: Set<String> = []
    /// Server messages go to the page one after another, in the order the server wrote them.
    private var lspTail: Task<Void, Never>?

    private static var lastID = 0
    private static func nextID() -> Int {
        lastID += 1
        return lastID
    }

    /// The answer to each save the page asked for (its ⌘S and the save command alike), by the file's path.
    var onWrite: ((String, EditorReply) -> Void)?
    /// The page's process ended and the page was loaded again: its buffers are gone.
    var onRestart: (() -> Void)?

    var fontSize = baseFontSize {
        didSet { if fontSize != oldValue { Task { _ = await send(.setFontSize(fontSize)) } } }
    }

    init(roots: [String], page: URL, servers: LanguageServerHost = .shared) {
        files = EditorFiles(roots: roots)
        self.servers = servers
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
    func open(_ path: String, line: Int? = nil) async -> (path: String, hash: String, readOnly: Bool)? {
        guard let command = await files.open(path, line: line), case .openFile(let real, _, let hash, _, let readOnly) = command else { return nil }
        shown = (real, line)
        await send(command)
        return (real, hash, readOnly)
    }

    /// The page's process ended (a crash, memory pressure): its buffers are gone. Load it again, open the shown file
    /// from disk, and hold commands until the new page is ready. An unsaved edit is lost.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Self.log.error("editor page ended; loading it again")
        // the new page has no language client: its servers stop, and its files start them again when they open
        close()
        ready = false
        waiting = []
        loadPage()
        onRestart?()
        guard let shown else { return }
        onDirty?(shown.path, false)
        Task { _ = await open(shown.path, line: shown.line) }
    }

    /// The editor goes away: its language servers stop.
    func close() {
        servers.release(editor: editorID)
        channels = [:]
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
        case .lspSend(let channel, let message):
            // answered here, not in a Task: the client's messages reach the server in the order it sent them
            let sent = channels[channel].map { servers.send($0, message) } ?? false
            replyHandler(Self.object(sent ? .ok : .refused(.noChannel)), nil)
            return
        case .lspStart(let languageId, let path):
            Task { replyHandler(Self.object(await startLanguageServer(languageId, path)), nil) }
            return
        case .readFile, .writeFile, .cursor: break
        }
        Task {
            let reply = await files.handle(request)
            if case .writeFile(let path, _, _) = request { onWrite?(path, reply) }
            replyHandler(Self.object(reply), nil)
        }
    }

    private static func object(_ reply: EditorReply) -> Any? {
        (try? JSONEncoder().encode(reply)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }

    /// The page opened a file: its language's server from the fixed table (D#9 a), in the root the file is in.
    private func startLanguageServer(_ languageId: String, _ path: String) async -> EditorReply {
        guard let spec = languageServer(for: languageId) else { return .refused(.noLanguageServer) }
        guard let root = await files.root(of: path) else { return .refused(.outside) }
        let key = LanguageServerKey(editor: editorID, server: spec.id, root: root)
        if !servers.isRunning(key) {
            // xcrun --find may take a moment: off the main actor
            switch await Task.detached { launch(spec) }.value {
            case .notInstalled(let notice):
                if noticed.insert(spec.id).inserted { onLanguageNotice?(notice) }
                return .refused(.languageServerMissing)
            case .run(let executable, let arguments):
                let channel = key.channel
                if let failure = servers.start(key, executable: executable, arguments: arguments,
                                               onMessage: { [weak self] in self?.forward(.lspReceive(channel: channel, message: $0)) },
                                               onExit: { [weak self] in self?.serverEnded(key, label: spec.label) }) {
                    return .failed(message: failure)
                }
            }
        }
        channels[key.channel] = key
        return .lspStarted(channel: key.channel, root: root, languages: spec.languages)
    }

    private func serverEnded(_ key: LanguageServerKey, label: String) {
        channels[key.channel] = nil
        forward(.lspClosed(channel: key.channel))
        onLanguageNotice?("\(label) 언어 서버가 종료됐습니다. 그 언어의 파일을 다시 열면 새로 시작합니다.")
    }

    private func forward(_ command: EditorCommand) {
        let previous = lspTail
        lspTail = Task {
            await previous?.value
            await send(command)
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
