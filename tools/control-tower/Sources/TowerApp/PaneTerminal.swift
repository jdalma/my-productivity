import AppKit
import SwiftTerm
import SwiftUI
import TowerCore

/// A live tmux pane in the detail, filling the height under the detail's head: what the pane shows, as it changes,
/// and what the user types while the terminal has focus goes to the pane (PaneStream says what that touches).
/// The terminal has the pane's columns and rows, so lines wrap as they do in the user's own terminal, at the board's
/// text size for every pane (T83). A pane larger than the space scrolls inside it, first showing the cursor's row,
/// where the input line is (T106: not the last rows, which are blank while the screen fills from the top); a smaller
/// one sits at the top left.
struct PaneTerminal: View {
    let ref: TmuxRef
    @Environment(\.boardFontScale) private var scale
    @State private var link = PaneLink()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("터미널").scaledFont(.headline, weight: .semibold)
                // the tint is the border's: as text it reads under 4.5:1 on the window background
                Text(link.typing ? "입력 중 · 나가기 ⌘K" : "클릭해서 입력")
                    .scaledFont(.caption1, weight: link.typing ? .semibold : .regular)
                    .foregroundStyle(link.typing ? .primary : .secondary)
            }
            .help("클릭하면 키가 이 pane으로 갑니다. Esc도 pane으로 갑니다. 나가려면 ⌘K를 누르거나 사이드바를 클릭합니다. 글자는 보드 글자 크기(⌘+/-)이고, pane이 영역보다 크면 터미널 안에서 스크롤합니다.")
            if let gone = link.gone {
                Text(gone).foregroundStyle(.secondary).padding(.vertical, 8)
                Spacer(minLength: 0)
            } else {
                PaneTerminalRepresentable(ref: ref, fontSize: NSFont.preferredFont(forTextStyle: .body).pointSize * scale,
                                          link: link)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(link.typing ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                          lineWidth: link.typing ? 2 : 1)
                    }
            }
        }
    }
}

/// What the AppKit side tells SwiftUI: why the pane is not shown, and whether it has the keyboard.
@MainActor @Observable
final class PaneLink {
    var gone: String?
    /// The terminal has the keyboard: what the user types goes to the pane.
    var typing = false
}

private struct PaneTerminalRepresentable: NSViewRepresentable {
    let ref: TmuxRef
    let fontSize: CGFloat
    let link: PaneLink

    func makeNSView(context: Context) -> PaneScrollView {
        let view = PaneTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: fontSize, weight: .regular))
        view.attach(PaneStream(ref: ref), link: link)
        return PaneScrollView(terminal: view)
    }

    func updateNSView(_ scroll: PaneScrollView, context: Context) { scroll.terminal.setFontSize(fontSize) }

    static func dismantleNSView(_ scroll: PaneScrollView, coordinator: ()) { scroll.terminal.detach() }
}

/// The terminal's one scroll: AppKit's, with the terminal as its document, from the top left (a flipped clip view).
final class PaneScrollView: NSScrollView {
    let terminal: PaneTerminalView
    /// Scroll to the cursor's row at the next layout: the pane's size, its first screen or the font changed.
    var showsCursorRow = true

    init(terminal: PaneTerminalView) {
        self.terminal = terminal
        super.init(frame: .zero)
        contentView = Flipped()
        documentView = terminal
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard showsCursorRow, contentView.bounds.height > 0 else { return }
        showsCursorRow = false
        let y = scrollToCursorRow(row: terminal.cursorRow, rows: terminal.rows,
                                  document: terminal.frame.height, visible: contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }

    private final class Flipped: NSClipView {
        override var isFlipped: Bool { true }
        /// A pane smaller than the space keeps its size and sits top left (T83): the rest is the terminal's own
        /// background, read when drawn since the terminal sets it after it is made, not a band (T108).
        override var backgroundColor: NSColor {
            get { (documentView as? TerminalView)?.nativeBackgroundColor ?? super.backgroundColor }
            set { super.backgroundColor = newValue }
        }
    }
}

/// The scroll offset that shows the cursor's row (0-based, of `rows`) as low as it fits: the pane's last rows when the
/// cursor is on them, as a full-screen program or a prompt at the bottom has it, the top when the screen is still
/// short. `document` and `visible` are heights in points.
func scrollToCursorRow(row: Int, rows: Int, document: CGFloat, visible: CGFloat) -> CGFloat {
    guard rows > 0, document > visible else { return 0 }
    let below = document / CGFloat(rows) * CGFloat(min(row, rows - 1) + 1)
    return min(max(0, below - visible), document - visible)
}

/// A wheel or trackpad scroll over the terminal: the scroll view's when the pane overflows the visible area along the
/// scroll's main axis, the terminal's own (its scrollback) otherwise.
func wheelScrollsThePane(delta: CGVector, document: CGSize, visible: CGSize) -> Bool {
    abs(delta.dx) > abs(delta.dy) ? document.width > visible.width : document.height > visible.height
}

/// One trackpad gesture goes to one place (R11 L1): its first moving event decides, and the rest of the gesture, its
/// momentum included, follows. A mouse wheel, which has no phases, decides at each event. `over`: the pointer is over
/// this pane; a gesture's start clears the last decision even away from it (R46 L1), so a pane that comes under the
/// pointer mid-gesture decides afresh instead of following the gesture before.
struct WheelGesture {
    private var pane: Bool?

    mutating func route(phase: NSEvent.Phase, momentum: NSEvent.Phase, delta: CGVector, document: CGSize, visible: CGSize,
                        over: Bool = true) -> Bool {
        if phase.contains(.began) || phase.contains(.mayBegin) { pane = nil }
        guard over else { return false }
        let decide = { wheelScrollsThePane(delta: delta, document: document, visible: visible) }
        if phase.isEmpty && momentum.isEmpty { return decide() }
        if pane == nil, delta != .zero { pane = decide() }
        return pane ?? false
    }
}

/// What a pane's wheel monitor reads of one scroll event.
struct WheelEvent {
    /// The event is in this pane's window.
    var inWindow: Bool
    /// The pointer is over this pane.
    var over: Bool
    var phase: NSEvent.Phase = []
    var momentum: NSEvent.Phase = []
    var delta: CGVector
}

extension WheelGesture {
    /// Whether this pane takes `e`, the whole of the wheel monitor's decision (R56 L1): any event of the pane's window
    /// reaches `route`, the pointer elsewhere too, so a gesture's start clears the last decision wherever it starts
    /// (R46 L1). `visible`: the pane's scroll view's visible size; nil without one.
    mutating func take(_ e: WheelEvent, document: CGSize, visible: CGSize?) -> Bool {
        guard e.inWindow, let visible else { return false }
        return route(phase: e.phase, momentum: e.momentum, delta: e.delta, document: document, visible: visible, over: e.over)
    }
}

/// SwiftTerm's view fed by a PaneStream instead of a local process.
final class PaneTerminalView: TerminalView, TerminalViewDelegate {
    private var stream: PaneStream?
    private weak var link: PaneLink?
    private var paneSize = (cols: 0, rows: 0)

    /// The pane terminal that has the keyboard, for the board's Esc: while one does, Esc is the pane's.
    static func focused() -> PaneTerminalView? { NSApp.keyWindow?.firstResponder as? PaneTerminalView }

    func attach(_ stream: PaneStream, link: PaneLink) {
        self.stream = stream
        self.link = link
        terminalDelegate = self
        // a drag selects text even while the pane's program has asked for mouse reports, which go nowhere anyway
        allowMouseReporting = false
        stream.onOutput = { [weak self] bytes in self?.feed(byteArray: bytes[...]) }
        stream.onSize = { [weak self] cols, rows, cursorRow in self?.follow(cols: cols, rows: rows, cursorRow: cursorRow) }
        stream.onGone = { [weak self] why in self?.link?.gone = why }
        stream.start()
    }

    func detach() {
        stream?.stop()
        stream = nil
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        if let wheel { NSEvent.removeMonitor(wheel) }
        wheel = nil
        responder = nil
        keyWindow.forEach(NotificationCenter.default.removeObserver)
        keyWindow = []
    }

    /// The board's text size, ⌘+/- included.
    func setFontSize(_ size: CGFloat) {
        guard size != font.pointSize else { return }
        font = .monospacedSystemFont(ofSize: size, weight: .regular)
        fit()
    }

    /// The board's Esc while the terminal has the keyboard.
    func sendEscape() { stream?.send([0x1b]) }

    private func follow(cols: Int, rows: Int, cursorRow: Int) {
        self.cursorRow = cursorRow
        guard cols > 0, rows > 0, (cols, rows) != paneSize else { return }
        paneSize = (cols, rows)
        fit()
    }

    /// The pane's columns and rows at the set font, and the frame that holds them.
    private func fit() {
        guard paneSize.cols > 0 else { return }
        resize(cols: paneSize.cols, rows: paneSize.rows)
        setFrameSize(getOptimalFrameSize().size)
        scrollToCursor()
    }

    /// Where tmux had the cursor at its last size answer (just before the first screen, then at each layout change),
    /// and the pane's rows: a scroll to the cursor shows that row.
    private(set) var cursorRow = 0
    var rows: Int { paneSize.rows }

    private func scrollToCursor() {
        (enclosingScrollView as? PaneScrollView)?.showsCursorRow = true
        enclosingScrollView?.needsLayout = true
    }

    /// On a screen of another pixel density SwiftTerm snaps its cells anew, and the frame changes with them.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fit()
    }

    private var keys: Any?
    private var wheel: Any?
    private var gesture = WheelGesture()
    private var responder: NSKeyValueObservation?
    private var keyWindow: [NSObjectProtocol] = []

    private func followKeyboard() { link?.typing = window?.isKeyWindow == true && window?.firstResponder === self }

    // Esc, ⌘V and ⌘C for a focused terminal, taken before AppKit offers them to anything else. Esc: the 이동 menu's
    // Esc must not take it from the pane. ⌘V and ⌘C (with a selection): written when the app had no Edit menu; since
    // T73 the Edit menu should reach `paste`/`copy` too, kept until that is seen in the running app (T73 report).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keys { NSEvent.removeMonitor(keys) }
        keys = nil
        if let wheel { NSEvent.removeMonitor(wheel) }
        wheel = nil
        responder = nil
        keyWindow.forEach(NotificationCenter.default.removeObserver)
        keyWindow = []
        guard let window else { return }
        // SwiftTerm's own first responder overrides are closed to subclasses; the window says who has the keyboard,
        // and only while it is the key window: another app in front takes the keys
        responder = window.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.followKeyboard() }
        }
        keyWindow = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map {
            NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.followKeyboard() }
            }
        }
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
        // SwiftTerm takes every wheel event over it and its own handler is closed to subclasses: an overflowing pane
        // would not scroll sideways at all, nor down past the visible rows
        wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let taken = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                let scroll = self.enclosingScrollView
                let seen = WheelEvent(inWindow: event.window === self.window,
                                      over: self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)),
                                      phase: event.phase, momentum: event.momentumPhase,
                                      delta: CGVector(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY))
                guard let scroll, self.gesture.take(seen, document: self.frame.size, visible: scroll.contentView.bounds.size)
                else { return false }
                scroll.scrollWheel(with: event)
                return true
            }
            return taken ? nil : event
        }
    }

    /// A paste goes through tmux, which brackets it when the pane's program asked for that.
    override func paste(_ sender: Any) {
        if let text = appPasteboard().string(forType: .string), !text.isEmpty { stream?.paste(text) }
    }

    /// SwiftTerm's own Copy writes the system clipboard; this one writes the app's (T97).
    override func copy(_ sender: Any) {
        if let text = getSelection() { appPasteboard().put(text) }
    }

    /// SwiftTerm's find writes the find pasteboard every app shares; the test instance has no find in a pane (T97).
    override func performFindPanelAction(_ sender: Any?) {
        guard towerDryRun == nil else { return }
        super.performFindPanelAction(sender)
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
        appPasteboard().put(String(decoding: content, as: UTF8.self))
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
