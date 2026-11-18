import AppKit
import SwiftUI
import TowerCore

/// How a callout looks (T155, H4): a symbol, a name and a color, so color is never the only cue.
struct CalloutStyle: Equatable {
    var label: String
    var symbol: String
    var color: Color

    /// Under a callout's gray, so the gray never mixes with what the callout lies on, a decision brief's pink or gray
    /// (R12 L5).
    static let ground = Color(nsColor: .windowBackgroundColor)
    /// A callout's own ground, one gray for every kind (T205, brief G): the kind's color is on its name and symbol only.
    static let fill = Color(nsColor: .quaternaryLabelColor).opacity(0.6)

    static func of(_ kind: CalloutKind) -> CalloutStyle {
        switch kind {
        case .note: CalloutStyle(label: "참고", symbol: "info.circle", color: TaskColor.blue)
        case .tip: CalloutStyle(label: "도움말", symbol: "lightbulb", color: TaskColor.green)
        case .important: CalloutStyle(label: "중요", symbol: "exclamationmark.bubble", color: TaskColor.purple)
        case .warning: CalloutStyle(label: "주의", symbol: "exclamationmark.triangle", color: TaskColor.orange)
        case .caution: CalloutStyle(label: "위험", symbol: "xmark.octagon", color: TaskColor.red)
        }
    }
}

/// A check box as a picture (H3): this window changes nothing, so it is never a control.
struct CheckBoxMark: View {
    let done: Bool

    var body: some View {
        Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? TaskColor.green : TaskColor.gray)
            .accessibilityHidden(true)
    }
}

/// Markdown drawn as a document (T136, T155): headings by level, lists indented, check boxes, code and tables apart,
/// quotes with a bar, callouts on a gray ground; every text selectable.
struct MarkdownView: View {
    /// A long text is split by `markdownBlocks` off the main thread (R53 L2).
    let blocks: [MarkdownBlock]

    init(blocks: [MarkdownBlock]) { self.blocks = blocks }

    /// A few lines of a decision brief, split as the view is made.
    init(short text: String) { blocks = markdownBlocks(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: DocumentType.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in block(b, first: i == 0) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ b: MarkdownBlock, first: Bool) -> some View {
        switch b {
        case .heading(let level, let text):
            inline(text).documentHeading(level, weight: level == 1 ? .bold : .semibold)
                .padding(.top, first ? 0 : DocumentType.headingSpaceAbove - DocumentType.blockSpacing)
                .accessibilityAddTraits(.isHeader)
        case .listItem(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).scaledFont(.body).foregroundStyle(.secondary).monospacedDigit()
                inline(text).documentText()
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .task(let depth, let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CheckBoxMark(done: done).scaledFont(.body)
                inline(text).documentText().foregroundStyle(done ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(depth) * 18)
            .accessibilityElement(children: .combine)
            .accessibilityValue(done ? "끝남" : "안 함")
        case .code(let language, let lines):
            literal(lines, language: language)
        case .raw(let lines):
            literal(lines)
        case .table(let header, let rows):
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, c in
                        cell(c, weight: .semibold).frame(maxHeight: .infinity, alignment: .topLeading).background(.quaternary.opacity(0.6))
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider()
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, c in cell(c, weight: .regular) } }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .clipShape(.rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        case .callout(let kind, let text):
            let style = CalloutStyle.of(kind)
            VStack(alignment: .leading, spacing: 4) {
                Label(style.label, systemImage: style.symbol).scaledFont(.callout, weight: .semibold).foregroundStyle(style.color)
                inline(text).documentText()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CalloutStyle.fill, in: .rect(cornerRadius: 6))
            .background(CalloutStyle.ground, in: .rect(cornerRadius: 6))
            .modifier(IncreasedContrastBorder(color: style.color, radius: 6))
        case .rule:
            Divider().padding(.vertical, 4)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                inline(text).documentText().foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            inline(text).documentText()
        }
    }

    private func inline(_ s: String) -> some View {
        Text(inlineMarkdown(s)).fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ s: String, weight: Font.Weight) -> some View {
        inline(s).scaledFont(.callout, weight: weight).padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Lines as written in a fixed-width font on a tinted ground, a code block's language above them; a long line
    /// scrolls sideways instead of wrapping.
    private func literal(_ lines: [String], language: String? = nil) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let language {
                Text(language).scaledFont(.caption1).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 4)
                    .accessibilityLabel("코드 언어 \(language)")
            }
            ScrollView(.horizontal) {
                Text(lines.joined(separator: "\n")).scaledFont(.callout, design: .monospaced).fixedSize().padding(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.6)))
    }
}
