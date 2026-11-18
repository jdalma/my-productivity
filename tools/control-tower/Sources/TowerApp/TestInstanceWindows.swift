import AppKit
import SwiftUI
import TowerCore

struct TestInstanceWindows: Equatable {
    enum Spot: Equatable {
        case bottomRightCorner
        case topLeftFromScreenTopLeft(CGPoint)
    }

    var spot = Spot.bottomRightCorner
    /// The desktop picture's window is at `desktopWindow` - 1, and a window at that same level is ordered in front of
    /// it; only `minimumWindow` hides one. `screencapture -l` and accessibility still reach a window down here.
    var hiddenLevel: NSWindow.Level? = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.minimumWindow)))

    init?(env: [String: String]) {
        guard dryRunLog(env) != nil else { return nil }
        let parts = (env["CT_TEST_ORIGIN"] ?? "").split(separator: ",", omittingEmptySubsequences: false).map { Double($0) }
        if parts.count == 2, let x = parts[0], let y = parts[1] { spot = .topLeftFromScreenTopLeft(CGPoint(x: x, y: y)) }
        if env["CT_TEST_VISIBLE"] == "1" { hiddenLevel = nil }
    }

    func behavior(_ current: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        // at most one of each group may be set
        current.subtracting([.moveToActiveSpace, .fullScreenPrimary, .fullScreenNone])
            .union([.canJoinAllSpaces, .fullScreenAuxiliary])
    }

    func appKitFrameOrigin(size: CGSize, screen: CGRect, visible: CGRect) -> CGPoint {
        switch spot {
        case .bottomRightCorner: CGPoint(x: visible.maxX - size.width, y: visible.minY)
        case .topLeftFromScreenTopLeft(let p): CGPoint(x: screen.minX + p.x, y: screen.maxY - p.y - size.height)
        }
    }
}

let testInstanceWindows = TestInstanceWindows(env: ProcessInfo.processInfo.environment)

struct TestWindowPlacement: NSViewRepresentable {
    var windows = testInstanceWindows

    func makeNSView(context: Context) -> NSView { makeProbe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeProbe() -> NSView { windows.map(Probe.init) ?? NSView() }

    private final class Probe: NSView {
        private let windows: TestInstanceWindows
        /// SwiftUI writes its own behavior back after the window mounts, as on the board (FullScreenCapable).
        private var rewrite: NSKeyValueObservation?

        init(_ windows: TestInstanceWindows) {
            self.windows = windows
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not in a nib") }

        override func viewDidMoveToWindow() {
            rewrite = nil
            guard let window else { return }
            keep(window)
            rewrite = window.observe(\.collectionBehavior) { [weak self] window, _ in
                MainActor.assumeIsolated { self?.keep(window) }
            }
            // a hop later, so this comes after whatever first puts the new window on screen
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, let screen = NSScreen.screens.first else { return }
                window.setFrameOrigin(self.windows.appKitFrameOrigin(size: window.frame.size, screen: screen.frame, visible: screen.visibleFrame))
            }
        }

        private func keep(_ window: NSWindow) {
            let behavior = windows.behavior(window.collectionBehavior)
            if behavior != window.collectionBehavior { window.collectionBehavior = behavior }
            if let hiddenLevel = windows.hiddenLevel, window.level != hiddenLevel { window.level = hiddenLevel }
        }
    }
}
