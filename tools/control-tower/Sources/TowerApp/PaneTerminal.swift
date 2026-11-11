import AppKit
import SwiftTerm
import SwiftUI
import TowerCore

/// A live tmux pane in the detail, in place of the recent conversation: what the pane shows, as it changes, and
/// what the user types while the terminal has focus goes to the pane (PaneStream says what that touches).
/// The terminal has the pane's columns and rows, so lines wrap as they do in the user's own terminal. Its font is the
/// size at which those columns fill the detail's width: no larger than twice the board's text size (a pane of few
/// columns), and no smaller than the macOS mini control size, under which the detail scrolls sideways instead.
struct PaneTerminal: View {
    let ref: TmuxRef
    @Environment(\.boardFontScale) private var scale
    @State private var link = PaneLink()
    @State private var width: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("터미널").scaledFont(.headline, weight: .semibold)
                Text("클릭하면 이 pane에 입력 · Esc도 pane으로 · 나가기: ⌘K 또는 사이드바 클릭 · 글자 크기는 폭에 맞춤")
                    .scaledFont(.caption1).foregroundStyle(.secondary)
                Button("터미널에서 나가기") { PaneTerminalView.leave() }
                    .buttonStyle(.link).scaledFont(.caption1)
            }
            if let gone = link.gone {
                Text(gone).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView(.horizontal) {
                    PaneTerminalRepresentable(ref: ref, fontSize: NSFont.preferredFont(forTextStyle: .body).pointSize * scale,
                                              width: width, link: link)
                        .frame(width: link.size.width, height: link.size.height)
                }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
            }
        }
    }
}

/// What the AppKit side tells SwiftUI: the terminal's frame for the pane's size, or why the pane is not shown.
@MainActor @Observable
final class PaneLink {
    var size = CGSize(width: 0, height: 0)
    var gone: String?
}

private struct PaneTerminalRepresentable: NSViewRepresentable {
    let ref: TmuxRef
    let fontSize: CGFloat
    let width: CGFloat
    let link: PaneLink

    func makeNSView(context: Context) -> PaneTerminalView {
        let view = PaneTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.attach(PaneStream(ref: ref), link: link)
        return view
    }

    func updateNSView(_ view: PaneTerminalView, context: Context) {
        if width > 0 { view.place(width: width, largest: fontSize * 2) }
    }

    static func dismantleNSView(_ view: PaneTerminalView, coordinator: ()) { view.detach() }
}

/// The largest font size, between `smallest` and `largest`, at which `cols` cells fit in `width`; `smallest` when
/// none does. `cellWidth` is a cell's width at a size, never smaller at a larger one.
func paneFontSize(width: CGFloat, cols: Int, smallest: CGFloat, largest: CGFloat,
                  cellWidth: (CGFloat) -> CGFloat) -> CGFloat {
    func fits(_ size: CGFloat) -> Bool { cellWidth(size) * CGFloat(cols) <= width }
    if fits(largest) { return largest }
    var fit = smallest, over = largest
    guard fits(fit) else { return smallest }
    while over - fit > 0.01 {
        let mid = (fit + over) / 2
        if fits(mid) { fit = mid } else { over = mid }
    }
    return fit
}

/// SwiftTerm's view fed by a PaneStream instead of a local process.
final class PaneTerminalView: TerminalView, TerminalViewDelegate {
    private var stream: PaneStream?
    private weak var link: PaneLink?
    private var paneSize = (cols: 0, rows: 0)

    /// The pane terminal that has the keyboard, for the board's Esc: while one does, Esc is the pane's.
    static func focused() -> PaneTerminalView? { NSApp.keyWindow?.firstResponder as? PaneTerminalView }

    /// Gives the keyboard back to the board.
    static func leave() { if let t = focused() { t.window?.makeFirstResponder(nil) } }

    func attach(_ stream: PaneStream, link: PaneLink) {
        self.stream = stream
        self.link = link
        terminalDelegate = self
        // a drag selects text even while the pane's program has asked for mouse reports, which go nowhere anyway
        allowMouseReporting = false
        stream.onOutput = { [weak self] bytes in self?.feed(byteArray: bytes[...]) }
        stream.onSize = { [weak self] cols, rows in self?.follow(cols: cols, rows: rows) }
        stream.onGone = { [weak self] why in self?.link?.gone = why }
        stream.start()
    }

    func detach() {
        stream?.stop()
        stream = nil
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
    }

    private var width = CGFloat.infinity
    private var largest: CGFloat?

    /// Lays the terminal out for a detail `width` points wide, its font at most `largest`.
    func place(width: CGFloat, largest: CGFloat) {
        guard width != self.width || largest != self.largest else { return }
        self.width = width
        self.largest = largest
        fit()
    }

    /// The board's Esc while the terminal has the keyboard.
    func sendEscape() { stream?.send([0x1b]) }

    private func follow(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, (cols, rows) != paneSize else { return }
        paneSize = (cols, rows)
        fit()
    }

    /// The pane's columns and rows, the font that fits them in the width, and the frame that holds them.
    private func fit() {
        guard paneSize.cols > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1  // as SwiftTerm snaps cells
        let size = paneFontSize(width: width, cols: paneSize.cols, smallest: NSFont.systemFontSize(for: .mini),
                                largest: largest ?? font.pointSize) { size in
            // SwiftTerm's cell: the advance of W, snapped to the pixel grid
            let f = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            return (f.advancement(forGlyph: f.glyph(withName: "W")).width * scale).rounded() / scale
        }
        if font.pointSize != size { font = .monospacedSystemFont(ofSize: size, weight: .regular) }
        resize(cols: paneSize.cols, rows: paneSize.rows)
        link?.size = getOptimalFrameSize().size
    }

    /// On a screen of another pixel density SwiftTerm snaps its cells anew; the font that fits changes with them.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fit()
    }

    private var keys: Any?

    // Esc, ⌘V and ⌘C for a focused terminal, taken before AppKit offers them to anything else. Esc: the board's own
    // Esc shortcut must not take it from the pane. ⌘V and ⌘C (with a selection): the app has no Edit menu (it is a
    // menu bar app), so nothing else would turn them into a paste or a copy.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        guard window != nil else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let window = event.window, code = event.keyCode, key = event.charactersIgnoringModifiers
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let self, window === self.window, self.window?.firstResponder === self else { return false }
                if mods.isEmpty, code == 53 { self.sendEscape(); return true }
                if mods == .command, key == "v" { self.paste(self); return true }
                if mods == .command, key == "c", self.selectionActive { self.copy(self); return true }
                return false
            }
            return taken ? nil : event
        }
    }

    /// A paste goes through tmux, which brackets it when the pane's program asked for that.
    override func paste(_ sender: Any) {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { stream?.paste(text) }
    }

    /// What SwiftTerm's terminal writes back by itself (answers to the pane program's queries, focus and mouse
    /// reports) is dropped: tmux is the pane's terminal and answers for itself, and the app sends a pane nothing
    /// the user did not type. Typed keys, input method text and pastes come through `send(source: TerminalView)`.
    override nonisolated func send(source: Terminal, data: ArraySlice<UInt8>) {}

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) { stream?.send(Array(data)) }
    /// The terminal follows the pane; its own frame never resizes the pane.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
