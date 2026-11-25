import AppKit
import Observation

// Shortcuts the app and the editor (or a pane terminal) both know (G4 I8, plan §5 risk 2). WebKit offers a key
// equivalent to the page first and passes on only what the page did not take (T14 §5.3); the page takes the editor's
// keys below even when Monaco leaves one (editor-web/src/keys.ts), and the app's menu acts on one of them only
// when `keyConsumer` says it is the app's. The app never re-sends a key to the editor: that loops (T14 §5.4).

/// The shortcuts in question: the app's menu items and hidden buttons that a focused editor or terminal also uses.
enum SharedKey: CaseIterable {
    case find            // ⌘F: the window's search; the editor's find
    case searchK         // ⌘K: the board's hidden search button, the way out of a pane terminal; the editor's chord prefix
    case escape          // Esc: the window's 닫기; the editor's widgets
    case back, forward   // ⌘[ ⌘]: history; outdent, indent
    case openDiff        // ⌘D: 변경 보기; add the next match to the selection
    case undo            // ⌘Z
    case quickOpen       // ⌘P
    case commandPalette  // ⌘⇧P
    case close           // ⌘W: the window
    case fontBigger, fontSmaller, fontReset  // ⌘+ ⌘- ⌘0: the app's text scale, which the editor follows
}

enum KeyFocus: Equatable {
    case editor, terminal, other

    /// What has the keyboard: an editor (its web view or a view in it), a pane terminal, or anything else.
    @MainActor init(responder: NSResponder?) {
        var view = responder as? NSView
        if view is PaneTerminalView {
            self = .terminal
            return
        }
        while let v = view {
            if v is EditorPageView {
                self = .editor
                return
            }
            view = v.superview
        }
        self = .other
    }

    @MainActor static var current: KeyFocus { KeyFocus(responder: NSApp.keyWindow?.firstResponder) }
}

enum KeyConsumer: Equatable { case editor, terminal, app }

/// Who takes `key` while `focus` has the keyboard.
func keyConsumer(_ key: SharedKey, focus: KeyFocus) -> KeyConsumer {
    switch (focus, key) {
    case (.editor, .find), (.editor, .searchK), (.editor, .escape), (.editor, .back), (.editor, .forward),
         (.editor, .openDiff), (.editor, .undo), (.editor, .quickOpen), (.editor, .commandPalette): .editor
    // the terminal keeps ⌘F; ⌘K still takes the keyboard out of it to the search field
    case (.terminal, .find): .terminal
    default: .app
    }
}

/// Whether the app's menu item for `key` should act now.
@MainActor func appTakes(_ key: SharedKey) -> Bool { keyConsumer(key, focus: .current) == .app }

/// Whether the key window's keyboard is in an editor, for a SwiftUI shortcut that must not catch the editor's key
/// (⌘K): a disabled button lets the key go on. Kept up to date by the editors and by the key window changing.
@MainActor @Observable final class EditorKeyFocus {
    static let shared = EditorKeyFocus()
    private(set) var inKeyWindow = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { EditorKeyFocus.shared.update() }
        }
    }

    /// After a responder change: AppKit sets the window's first responder once becomeFirstResponder returns.
    func update() {
        DispatchQueue.main.async {
            let editor = KeyFocus.current == .editor
            if self.inKeyWindow != editor { self.inKeyWindow = editor }
        }
    }
}
