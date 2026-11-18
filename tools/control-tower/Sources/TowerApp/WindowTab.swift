import AppKit
import SwiftUI

/// The kinds of window that join one another as tabs of one window, each kind apart from the other and from the
/// board window (T142, T149).
enum WindowTabKind: String {
    case taskBoard, diff

    var tabbingIdentifier: String { "local.control-tower.\(rawValue)" }
}

/// Puts its window in the tab group of `kind`, whatever the system's tab preference says, under the tab title `title`.
/// A window of one tab keeps its own title.
struct WindowTab: NSViewRepresentable {
    let kind: WindowTabKind
    let title: String

    func makeNSView(context: Context) -> Probe { Probe(kind: kind, title: title) }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.title = title }

    final class Probe: NSView {
        private let kind: WindowTabKind
        var title: String { didSet { window?.tab.title = title } }
        /// The tab group this window is in, watched for the tab it shows; it changes when the window joins another
        /// group or is dragged out of one.
        private weak var group: NSWindowTabGroup?
        private var watches: [NSKeyValueObservation] = []

        init(kind: WindowTabKind, title: String) {
            self.kind = kind
            self.title = title
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not in a nib") }

        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.tabbingIdentifier = kind.tabbingIdentifier
            window.tabbingMode = .preferred
            window.tab.title = title
            WindowTabSelection.shared.tabs.add(window)
            // a hop later: the window is shown and in its group by then
            DispatchQueue.main.async { [weak self] in self?.follow() }
        }

        /// Watches the group the window is in now: the tab it shows, and its windows, to follow the window into
        /// another group.
        private func follow() {
            guard let window, let now = window.tabGroup, now !== group else { return }
            group = now
            // AppKit changes a tab group only on the main thread, so its KVO calls come on main (R5 L1)
            watches = [
                now.observe(\.selectedWindow, options: [.initial, .new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { WindowTabSelection.shared.selected(self?.group) }
                },
                now.observe(\.windows, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.follow() }
                },
            ]
        }
    }
}

/// The tab each tab group last showed (T148, R2 L1): the tab bar's + makes a blank tab and selects it, and the
/// blank tab gives the selection back to this one as it closes.
@MainActor final class WindowTabSelection {
    static let shared = WindowTabSelection()
    /// The windows with a `WindowTab`; a blank tab is never one.
    let tabs = NSHashTable<NSWindow>.weakObjects()
    /// By tab group identifier.
    private let last = NSMapTable<NSString, NSWindow>.strongToWeakObjects()

    func selected(_ group: NSWindowTabGroup?) {
        if let group, let window = group.selectedWindow, tabs.contains(window) {
            last.setObject(window, forKey: group.identifier as NSString)
        }
    }

    func last(in group: NSWindowTabGroup) -> NSWindow? {
        last.object(forKey: group.identifier as NSString).flatMap { group.windows.contains($0) ? $0 : nil }
    }
}

/// A window of a tabbed window group with no value: what the tab bar's new tab button (+) opens. It closes as it
/// opens and selects the tab that was showing, so the + changes nothing (T148, R2 L1). The + itself cannot be
/// hidden: AppKit shows it while something in the window's responder chain implements `newWindowForTab:`, and
/// SwiftUI's window does.
struct ClosesItself: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                let group = window.tabGroup
                let back = group.flatMap { WindowTabSelection.shared.last(in: $0) }
                window.close()
                if let group, let back { group.selectedWindow = back }
            }
        }
    }
}
