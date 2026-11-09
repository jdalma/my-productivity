import AppKit
import SwiftUI
import TowerCore

/// The diff line under the pointer, which a Command-click opens. Lines register while hovered; one
/// local event monitor takes the click, so a click without Command reaches text selection untouched.
@MainActor enum CommandClick {
    struct Target {
        let id: UUID
        let open: () -> Void
        /// Re-reads the Command key for the underline when it is pressed or released without a move.
        let refresh: () -> Void
    }

    static var target: Target?

    static func hover(_ t: Target) { target = t }
    static func leave(_ id: UUID) { if target?.id == id { target = nil } }

    /// Command alone: Command-Shift and the like stay with the system.
    static func isCommandOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .shift, .option, .control]) == .command
    }

    /// true: a Command-click on a registered line, opened; the event is consumed.
    static func handle(_ type: NSEvent.EventType, clickCount: Int, flags: NSEvent.ModifierFlags) -> Bool {
        if type == .flagsChanged {
            target?.refresh()
            return false
        }
        guard type == .leftMouseDown, clickCount == 1, isCommandOnly(flags), let target else { return false }
        target.open()
        return true
    }

    static func install() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .flagsChanged]) { event in
            let (type, flags) = (event.type, event.modifierFlags)
            let count = type == .leftMouseDown ? event.clickCount : 0
            return MainActor.assumeIsolated { handle(type, clickCount: count, flags: flags) } ? nil : event
        }
    }
}

/// The font `scaledFont(.callout, design: .monospaced)` draws diff lines with.
func codeFont(scale: Double) -> NSFont {
    .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize * scale, weight: .regular)
}

/// The Character offset of `text` drawn under `point` (from the text's top left), the text wrapped at
/// `width` and drawn `height` tall; nil past a line's end. SwiftUI `Text` reports no glyph positions, so
/// TextKit lays out the same string in the same font, breaking lines as `Text` does (`.standard`: Hangul
/// by word). At fractional scales `Text` lines are up to 1 pt taller than TextKit's, so `y` is scaled by
/// the two heights.
func characterIndex(at point: CGPoint, in text: String, font: NSFont, width: CGFloat, height: CGFloat) -> Int? {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakStrategy = .standard
    let storage = NSTextStorage(string: text, attributes: [.font: font, .paragraphStyle: paragraph])
    let layout = NSLayoutManager()
    storage.addLayoutManager(layout)
    // one point of slack: a line SwiftUI fit exactly must not wrap here
    let container = NSTextContainer(size: CGSize(width: width + 1, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    layout.addTextContainer(container)
    guard layout.numberOfGlyphs > 0, height > 0 else { return nil }
    layout.ensureLayout(for: container)
    let point = CGPoint(x: point.x, y: point.y * layout.usedRect(for: container).height / height)
    let glyph = layout.glyphIndex(for: point, in: container)
    let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
    guard point.x >= rect.minX, point.x < rect.maxX else { return nil }
    let ns = text as NSString
    let start = ns.rangeOfComposedCharacterSequence(at: layout.characterIndexForGlyph(at: glyph)).location
    return text.distance(from: text.startIndex, to: String.Index(utf16Offset: start, in: text))
}

/// The working-tree file at the history's current location, read-only, in place of the diff: line
/// numbers, the diff's syntax colors, the line scrolled to and briefly marked.
struct FileCodeView: View {
    let toplevel: String
    let location: CodeLocation
    @Bindable var state: ChangesState
    @State private var shown: Shown?
    @State private var flash: Int?

    private struct Shown: Equatable {
        var location: CodeLocation
        var file: WorkingFile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if let shown, shown.location == location { content(shown.file) }
                }
                .task(id: location) { await load(proxy) }
            }
        }
        .background(DiffColors.canvas)
        .foregroundStyle(DiffColors.text, DiffColors.mutedText)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { state.history.back() } label: { Image(systemName: "chevron.left") }
                .help("뒤로 (⌘[)")
            Button { state.history.forward() } label: { Image(systemName: "chevron.right") }
                .help("앞으로 (⌘])").disabled(!state.history.canGoForward)
            Image(systemName: "doc.text").foregroundStyle(DiffColors.mutedText)
            let (dir, name) = splitPath(location.path)
            (Text(dir).foregroundStyle(DiffColors.mutedText) + Text(name).fontWeight(.semibold).foregroundStyle(DiffColors.text)
                + Text(":\(location.line)").foregroundStyle(DiffColors.mutedText))
                .scaledFont(.body, design: .monospaced)
                .lineLimit(1).truncationMode(.head).textSelection(.enabled)
                .help(location.path)
            Spacer()
            Text("작업 트리 · 읽기 전용").scaledFont(.caption1).foregroundStyle(DiffColors.mutedText)
            Button("diff로 (Esc)") { state.history.toDiff() }.buttonStyle(.link)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(DiffColors.header)
    }

    @ViewBuilder
    private func content(_ file: WorkingFile) -> some View {
        switch file {
        case .missing:
            note("작업 트리에 이 파일이 없음 (삭제됐거나 이름이 바뀜)")
        case .binary:
            note("바이너리 파일")
        case .text(let lines, let total):
            LazyVStack(alignment: .leading, spacing: 0) {
                let first = lines.first?.new ?? 1
                if first > 1 { note("앞 \(first - 1)줄 생략") }
                ForEach(lines, id: \.new) { line in
                    LineView(line: line, side: .new, target: line.new.map { CodeLocation(path: location.path, line: $0) })
                        .fixedSize(horizontal: false, vertical: true)
                        .background(flash == line.new ? DiffColors.targetLine : .clear)
                        .id(line.new)
                }
                let after = total - (lines.last?.new ?? 0)
                if after > 0 { note("뒤 \(after)줄 생략") }
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).scaledFont(.caption1).foregroundStyle(DiffColors.mutedText).padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// One color at once, syntax colors when ready; then the scroll and the mark.
    private func load(_ proxy: ScrollViewProxy) async {
        let (top, loc) = (toplevel, location)
        let read = await Task.detached { readWorkingFile(toplevel: top, path: loc.path, around: loc.line) }.value
        guard !Task.isCancelled else { return }
        shown = Shown(location: loc, file: read)
        guard case .text(let lines, let total) = read, total > 0 else { return }
        let target = min(max(1, loc.line), total)
        await Task.yield()
        proxy.scrollTo(target, anchor: .center)
        flash = target
        let lit = await highlightedLines(lines, path: loc.path)
        guard !Task.isCancelled else { return }
        shown = Shown(location: loc, file: .text(lines: lit, total: total))
        try? await Task.sleep(for: .seconds(1.5))
        withAnimation(.easeOut(duration: 0.5)) { flash = nil }
    }
}

/// The declarations a Command-click could mean: file name, dimmer directory, line, the declaring line.
/// Up and down arrows move, Return opens, a click opens; the popover closes on Esc.
struct CandidateListView: View {
    let items: [Candidate]
    let choose: (Candidate) -> Void
    @State private var selected = 0
    @FocusState private var focused: Bool

    static let limit = 50

    /// The rows shown and how many are left out.
    static func page(_ items: [Candidate]) -> (shown: [Candidate], more: Int) {
        (Array(items.prefix(limit)), max(0, items.count - limit))
    }

    var body: some View {
        let (shown, more) = Self.page(items)
        VStack(alignment: .leading, spacing: 0) {
            Text("후보 \(items.count)개 · ↑↓ Enter").scaledFont(.caption1).foregroundStyle(.secondary).padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.offset) { i, c in
                            row(c, selected: i == selected).id(i)
                        }
                        if more > 0 {
                            Text("\(more)개 더").scaledFont(.caption1).foregroundStyle(.secondary).padding(8)
                        }
                    }
                }
                .onChange(of: selected) { _, i in proxy.scrollTo(i) }
            }
        }
        .frame(width: 520)
        .frame(maxHeight: 420)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { selected = max(0, selected - 1); return .handled }
        .onKeyPress(.downArrow) { selected = min(shown.count - 1, selected + 1); return .handled }
        .onKeyPress(.return) { choose(shown[selected]); return .handled }
    }

    private func row(_ c: Candidate, selected: Bool) -> some View {
        let (dir, name) = splitPath(c.location.path)
        return Button { choose(c) } label: {
            VStack(alignment: .leading, spacing: 2) {
                (Text(name).fontWeight(.semibold) + Text(":\(c.location.line)") + Text("  " + dir).foregroundStyle(.secondary))
                    .lineLimit(1).truncationMode(.head)
                Text(c.snippet).scaledFont(.caption1, design: .monospaced).foregroundStyle(.secondary).lineLimit(1)
            }
            .scaledFont(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.2) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
