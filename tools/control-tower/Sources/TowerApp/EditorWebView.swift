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

/// A web view that tells its controller when the app's appearance changes, for the page's theme.
final class EditorPageView: WKWebView {
    var appearanceChanged: (@MainActor (Bool) -> Void)?

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?(isDark)
    }
}

/// One editor: the page, its files, and the commands waiting for the page to be ready.
@MainActor final class EditorController: NSObject, WKScriptMessageHandlerWithReply {
    static let scheme = "ctedit"
    /// The page's font size at the standard scale, Monaco's own default.
    static let baseFontSize = 13.0
    private static let log = Logger(subsystem: "local.control-tower", category: "editor")

    let files: EditorFiles
    let web: EditorPageView
    private var ready = false
    private var waiting: [EditorCommand] = []
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
        web.appearanceChanged = { [weak self] dark in Task { _ = await self?.send(.setTheme(dark: dark)) } }
        web.load(URLRequest(url: URL(string: "\(Self.scheme)://app/index.html")!))
    }

    /// Opens `path` read-only (D#5 b); false when it is outside the roots or not a text file.
    func open(_ path: String, line: Int? = nil) async -> Bool {
        guard let command = await files.open(path, line: line) else { return false }
        await send(command)
        return true
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

// MARK: - The temporary way in

/// `CT_EDITOR_TRY=<file>` opens that file in an editor window at launch, its folder the editor's only root.
// ponytail: I4's one way to try the editor; I5 puts it in the board (IdeArea) and removes this window.
let editorTryPath = ProcessInfo.processInfo.environment["CT_EDITOR_TRY"]

struct EditorTryWindow: View {
    let path: String
    @State private var controller: EditorController?
    @State private var readOnly = true
    @State private var dirty = false
    @State private var status = ""
    @AppStorage(FontScale.storageKey) private var storedScale = FontScale.standard.value

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(path + (dirty ? " •" : "")).lineLimit(1).truncationMode(.head)
                Spacer()
                Text(status).foregroundStyle(.secondary)
                Button(readOnly ? "잠금 해제" : "잠그기") {
                    readOnly.toggle()
                    Task { await controller?.setReadOnly(path, readOnly) }
                }
                .disabled(controller == nil)
                Button("저장") {
                    Task {
                        let r = await controller?.send(.save)
                        status = "저장: " + ((r?["result"] as? String).map { [$0, r?["reason"] as? String].compactMap { $0 }.joined(separator: " ") } ?? "응답 없음")
                    }
                }
                .disabled(controller == nil || readOnly)
            }
            .padding(8)
            Divider()
            if let controller {
                EditorWebView(controller: controller)
            } else {
                Text(editorPageFolder == nil ? "편집기 페이지가 빌드되지 않았습니다 (editor-web에서 npm run build)" : "여는 중")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .navigationTitle("편집기 시험")
        .environment(\.boardFontScale, FontScale(stored: storedScale).value)
        .background(NotRestorable())
        .background(TestWindowPlacement())
        .task {
            guard let page = editorPageFolder else { return }
            let c = EditorController(roots: [URL(fileURLWithPath: path).deletingLastPathComponent().path], page: page)
            c.onDirty = { dirty = $1 }
            controller = c
            status = await c.open(path) ? "열림" : "열 수 없음"
        }
    }
}
