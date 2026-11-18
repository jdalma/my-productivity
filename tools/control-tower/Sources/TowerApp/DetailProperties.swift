import AppKit
import SwiftUI
import TowerCore

// What a detail shares to read as a document (T155; design task-board-visual-v4.md §3 안 1 and its HIG pair H1, H2):
// where it is, its properties as names and values in two columns, a person's tag, the to-do bar, a link to a task,
// and a section's title under a line.

private func pair(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { DiffColors.rgba($0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light) })
}

/// The grounds a worker's initial is drawn on: hues no task state uses, each reading 4.5:1 under `personInk`.
let personColors = [pair(0x0b6b74ff, 0x76d9e6ff), pair(0x7a4a12ff, 0xe0b072ff), pair(0x3d4bb3ff, 0xa5b4fcff),
                    pair(0x4f6410ff, 0xb8cf6aff), pair(0x4b5563ff, 0xb8c0ccff)]
let personInk = pair(0xffffffff, 0x0d1117ff)

/// The same color for a name every time the app runs (`Hasher` is seeded per launch).
func personColor(_ name: String) -> Color {
    personColors[Int(name.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value } % UInt32(personColors.count))]
}

/// A worker as its initial on its own color and its name: the name is always there, so the color is not the only cue.
/// A list line's (T152, T162) is smaller, its initial alone when `compact` (the name is its tooltip), and carries the
/// worker's state when it works or failed; the waiting hand is the board window's (S4).
struct PersonTag: View {
    let name: String
    var compact = false
    var initialOnly = false
    var row: LiveRow?
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let style: NSFont.TextStyle = compact ? .caption1 : .callout
        let side = (StatusIconView.size(style, scale: scale) + 2).rounded(.up)
        HStack(spacing: 4) {
            if let row, [.spinner, .alert].contains(row.badge.icon) { StatusIconView(badge: row.badge, style: .caption1) }
            Text(name.prefix(1).lowercased()).scaledFont(compact ? .caption2 : .caption1, weight: .bold).foregroundStyle(personInk)
                .frame(width: side, height: side).background(personColor(name), in: .circle)
                .accessibilityHidden(true)
            if !initialOnly { Text(name).scaledFont(style).lineLimit(1) }
        }
        .padding(.leading, 3).padding(.trailing, initialOnly ? 3 : compact ? 6 : 8).padding(.vertical, compact ? 1 : 2)
        .background(.quaternary.opacity(0.6), in: .capsule)
        .fixedSize()
        .help(name)
    }
}

/// How many of the to-do items are done, as a short bar and `4 / 6`; shorter and smaller on a list line (T162).
struct TodoBar: View {
    let done: Int
    let total: Int
    var compact = false
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        HStack(spacing: compact ? 4 : 8) {
            ProgressView(value: Double(min(done, total)), total: Double(max(total, 1))).progressViewStyle(.linear)
                .tint(TaskColor.blue).frame(width: (compact ? 36 : 72) * scale)
            Text("\(done) / \(total)").scaledFont(compact ? .caption1 : .callout).monospacedDigit()
                .foregroundStyle(compact ? .secondary : .primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("할 일")
        .accessibilityValue("\(total)개 중 \(done)개 끝남")
    }
}

/// Where a detail is: `example-team 작업판 › 진행 중 › T5`.
struct DetailLocation: View {
    let parts: [String]

    var body: some View {
        Text(parts.joined(separator: " › ")).scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            .accessibilityLabel(parts.joined(separator: ", "))
    }
}

/// A detail's properties: names in the first column, as wide as the longest, values in the second (H1).
struct PropertyGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 8) { content }
    }
}

struct PropertyName: View {
    let name: String
    let symbol: String

    init(_ name: String, symbol: String) {
        self.name = name
        self.symbol = symbol
    }

    var body: some View {
        Label(name, systemImage: symbol).scaledFont(.callout).foregroundStyle(.secondary).gridColumnAlignment(.leading)
    }
}

/// A word on its color's tint, as a state's tag is drawn.
struct ToneTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text).scaledFont(.caption1, weight: .semibold).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(TaskPanelStyle.tagOpacity), in: .rect(cornerRadius: 4))
            .modifier(IncreasedContrastBorder(color: color, radius: 4))
    }
}

/// A task as a link that picks it in the same window (H2): its state, its id monospaced, its title. A task the board
/// does not list is its id alone and goes nowhere.
struct TaskLink: View {
    let id: String
    let task: TaskBoardTask?
    let team: String
    /// `상위`, `하위`: how it stands to the task shown.
    var relation: String?
    let pick: (String?) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let relation { Text(relation).scaledFont(.caption1).foregroundStyle(.secondary) }
            Button { pick(id) } label: {
                HStack(spacing: 5) {
                    if let task { TaskStateIcon(state: task.state, style: .callout) }
                    Text(id).scaledFont(.callout, design: .monospaced)
                    if let task { Text(shownTitle(task.title, team: team)).scaledFont(.callout).lineLimit(1) }
                }
            }
            .buttonStyle(.link)
            .disabled(task == nil)
            .help(task?.title ?? "작업판에 없는 작업입니다")
            .accessibilityHint(task == nil ? "작업판에 없는 작업입니다" : "작업 상세로 갑니다")
        }
    }
}

/// A section of a detail: a line, then its title, so the detail reads as parts and not as one run of text.
struct DetailSection<Content: View>: View {
    let title: String
    /// Beside the title, in secondary: `4/6`.
    var count: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            DetailSectionTitle(title: title, count: count)
            content
        }
        .padding(.top, 6)
    }
}

struct DetailSectionTitle: View {
    let title: String
    var count: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).scaledFont(.title3, weight: .semibold)
            if let count { Text(count).scaledFont(.callout).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A report (`.md`) read inside the detail (H6): folded until asked for, and folded again with another task. The
/// file is read each time it opens, and only read.
struct ReportPreview: View {
    let path: String
    /// `담당 보고서`
    let what: String
    @State private var open = false
    @State private var blocks: [MarkdownBlock]?
    @State private var failure: String?

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Group {
                if let failure {
                    Text(failure).scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else if let blocks {
                    MarkdownView(blocks: blocks)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .padding(.top, 4)
        } label: {
            Text("미리 보기").scaledFont(.callout)
        }
        .accessibilityLabel("\(what) 미리 보기")
        .task(id: open) {
            guard open else { return }
            let path = path
            (blocks, failure) = await Task.detached {
                switch readPage(path, what: "보고서") {
                case .read(let text): (markdownBlocks(text), nil)
                case .unreadable(let why): (nil, why)
                }
            }.value
        }
    }
}

/// Only a Markdown file is previewed; anything else opens in the editor as before.
func previewsAsMarkdown(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == "md" }

/// A task's state as a tag (v2 §A.3): icon and word in a fixed width, on the state's tint unless the task is over.
/// The detail's state row has it; the list's lines dropped it (T152, S1).
struct TaskStateTag: View {
    let state: String
    let tinted: Bool
    @Environment(\.boardFontScale) private var scale

    var body: some View {
        let s = TaskStateStyle.of(state)
        HStack(spacing: 3) {
            Image(systemName: s.symbol).font(.system(size: StatusIconView.size(.caption1, scale: scale)))
            Text(s.label).scaledFont(.caption1, weight: .semibold).lineLimit(1)
        }
        .foregroundStyle(s.color)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .frame(width: 92 * scale, alignment: .leading)
        .background(tinted ? s.color.opacity(TaskPanelStyle.tagOpacity) : .clear, in: .rect(cornerRadius: 4))
        .modifier(IncreasedContrastBorder(color: s.color, radius: 4))
    }
}
