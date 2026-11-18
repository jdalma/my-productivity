import AppKit
import SwiftUI
import TowerCore

enum FolderList: Equatable {
    case reading
    case missing
    case rows([DocumentRow])
}

struct DocumentBlock: Equatable {
    enum Key: Hashable {
        case byTime
        case folder(String)
    }

    var key: Key
    var count: Int
    var shown: [DocumentRow]
    var more: Int
    var folded: Bool

    var folderName: String? {
        if case .folder(let name) = key { name } else { nil }
    }
}

let documentBlockLimit = 20

func documentBlocks(_ rows: [DocumentRow], byFolder: Bool, folded: Set<DocumentBlock.Key> = [], expanded: Set<DocumentBlock.Key> = [],
                    limit: Int = documentBlockLimit) -> [DocumentBlock] {
    let groups: [(key: DocumentBlock.Key, rows: [DocumentRow])] = byFolder ? groupByFolder(rows).map { (.folder($0.name), $0.rows) }
        : rows.isEmpty ? [] : [(.byTime, rows)]
    return groups.map { g in
        let isFolded = g.key != .byTime && folded.contains(g.key)
        let shown = isFolded ? [] : expanded.contains(g.key) ? g.rows : Array(g.rows.prefix(limit))
        return DocumentBlock(key: g.key, count: g.rows.count, shown: shown, more: isFolded ? 0 : g.rows.count - shown.count, folded: isFolded)
    }
}

func documentCount(_ shown: Int, of all: Int) -> String { shown == all ? "\(all)" : "\(shown)/\(all)" }

struct DocumentsArea: View {
    static let listShare = 0.45
    static let noteMinWidth = 72.0
    /// Between the title's (1) and the note's (0): the note is cut before why a line does not open.
    static let statePriority = 0.5
    static let folderReadEvery = Duration.seconds(10)

    let documents: TeamDocuments?
    var fileOpens: [Int: DocumentFileOpen] = [:]
    var storedEditor = ""
    /// What the last open said: an editor not found, a failure the system reported.
    var notice: String?
    let shownPagePath: String?
    let maxHeight: CGFloat
    let open: (DocumentRow) -> Void
    @AppStorage("taskBoardDocumentsOpen") private var unfolded = false
    @AppStorage("taskBoardDocumentsByFolder") private var byFolder = false
    @AppStorage("taskBoardPickedDocumentsOpen") private var pickedOpen = true
    @AppStorage("taskBoardAllDocumentsOpen") private var allOpen = true
    @State private var filter = documentsFilterAtStart
    @State private var folderList = FolderList.reading
    @State private var folderOpens: [Int: DocumentFileOpen] = [:]
    @State private var folderFiles: [FolderDocument] = []
    @State private var foldedBlocks: Set<DocumentBlock.Key> = []
    @State private var expandedBlocks: Set<DocumentBlock.Key> = []
    @State private var selected: Int?
    @FocusState private var focused: Bool
    @Environment(\.controlActiveState) private var active
    @Environment(\.boardFontScale) private var scale

    private var folder: String { documents?.folder ?? "" }

    private var noMatch: String { "'\(filter.trimmingCharacters(in: .whitespaces))'에 맞는 문서가 없습니다" }

    private var picked: Set<String> {
        Set((documents?.rows ?? []).compactMap { r in if case .file(let path) = r.target { path } else { nil } })
    }

    private var pickedSections: [DocumentSection] {
        (documents?.sections ?? []).map { DocumentSection(title: $0.title, rows: filterDocuments($0.rows, filter)) }.filter { !$0.rows.isEmpty }
    }

    private var folderRows: [DocumentRow] {
        if case .rows(let rows) = folderList { rows } else { [] }
    }

    private var blocks: [DocumentBlock] {
        documentBlocks(filterDocuments(folderRows, filter), byFolder: byFolder, folded: foldedBlocks, expanded: expandedBlocks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if unfolded {
                if let notice {
                    Text(notice).scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .padding(.horizontal, 16).padding(.bottom, 4)
                }
                lines
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: [folder, unfolded && allOpen ? "shown" : "", storedEditor] + picked.sorted()) { await readFolder() }
    }

    private func readFolder() async {
        guard unfolded, allOpen, !folder.isEmpty else { return }
        let (folder, storedEditor, picked) = (folder, storedEditor, picked)
        while !Task.isCancelled {
            let known = folderFiles
            let (list, files, opens) = await Task.detached { () -> (FolderList, [FolderDocument], [Int: DocumentFileOpen]) in
                guard case .listed(let files) = listFolderDocuments(folder, known: known) else { return (.missing, [], [:]) }
                let rows = TowerCore.folderRows(files)
                return (.rows(rows), files, fileOpensByRow(rows, stored: storedEditor, picked: picked))
            }.value
            guard !Task.isCancelled else { return }
            (folderList, folderFiles, folderOpens) = (list, files, opens)
            try? await Task.sleep(for: Self.folderReadEvery)
        }
    }

    private var head: some View {
        HStack(spacing: 8) {
            Button { unfolded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: unfolded ? "chevron.down" : "chevron.right")
                        .scaledFont(.caption1, weight: .semibold).foregroundStyle(.secondary).frame(width: 12 * scale)
                    Image(systemName: "doc.on.doc").foregroundStyle(.secondary)
                    Text("문서").fontWeight(.bold)
                    Text(documentsSummary(documents)).monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                }
                .scaledFont(.headline)
                .padding(.leading, 16).padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(unfolded ? "문서 접기" : "문서 펴기: 팀 목록 파일의 문서와 문서 폴더의 모든 문서")
            .accessibilityLabel("문서 \(documentsSummary(documents))")
            .accessibilityValue(unfolded ? "펼침" : "접힘")
            .accessibilityAddTraits(.isHeader)
            if unfolded, !folder.isEmpty {
                SearchField(text: $filter, prompt: "문서 걸러 보기", focusRequest: 0)
                    .frame(width: 200 * scale)
                    .help("제목과 경로에서 찾기")
                    .accessibilityLabel("문서 걸러 보기")
            }
        }
        .padding(.trailing, 16)
    }

    @ViewBuilder
    private var lines: some View {
        if let d = documents {
            ScrollViewReader { proxy in
                ScrollView {
                    // ponytail: every shown line is built, not only those in view. A block shows 20 until 더 보기; go
                    // lazy if a folder with thousands unfolded is slow.
                    VStack(alignment: .leading, spacing: 0) {
                        pickedLines(d)
                        if !folder.isEmpty { folderLines }
                    }
                    .padding(.horizontal, 4).padding(.bottom, 8)
                }
                .frame(maxHeight: maxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) { move(-1, proxy) }
                .onKeyPress(.downArrow) { move(1, proxy) }
                .onKeyPress(.return) {
                    guard let r = shownRows.first(where: { $0.id == selected }) else { return .ignored }
                    open(r)
                    return .handled
                }
            }
        } else {
            ProgressView().controlSize(.small).padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func pickedLines(_ d: TeamDocuments) -> some View {
        listHead("고른 문서", count: d.rows.isEmpty ? "" : documentCount(pickedSections.map(\.rows.count).reduce(0, +), of: d.rows.count),
                 open: $pickedOpen, help: "목록 파일(index.md)에 올린 문서와 링크")
        if pickedOpen {
            switch d.content {
            case .missing: note("목록 파일이 없습니다", path: d.indexPath)
            case .unreadable(let why): note(why, path: nil)
            case .groups:
                if d.rows.isEmpty { note("목록에 문서가 없습니다", path: d.indexPath) } else if pickedSections.isEmpty { note(noMatch, path: nil) }
                ForEach(Array(pickedSections.enumerated()), id: \.offset) { _, s in
                    if !s.title.isEmpty { groupTitle(s.title) }
                    ForEach(s.rows) { r in line(r) }
                }
            }
        }
    }

    @ViewBuilder
    private var folderLines: some View {
        let blocks = blocks
        HStack(spacing: 8) {
            listHead("모든 문서", count: folderRows.isEmpty ? "" : documentCount(blocks.map(\.count).reduce(0, +), of: folderRows.count),
                     open: $allOpen, help: "문서 폴더의 Markdown, HTML, PDF 파일")
            Spacer(minLength: 8)
            if allOpen {
                Picker("모든 문서 순서", selection: $byFolder) {
                    Text("최근순").tag(false)
                    Text("폴더별").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                .help("최근에 고친 순, 또는 폴더별로 묶어 보기")
                .padding(.trailing, 8)
            }
        }
        if allOpen { allLines(blocks) }
    }

    @ViewBuilder
    private func allLines(_ blocks: [DocumentBlock]) -> some View {
        switch folderList {
        case .reading: ProgressView().controlSize(.small).padding(.horizontal, 12).padding(.vertical, 4)
        case .missing: note("문서 폴더가 없습니다", path: folder)
        case .rows(let rows):
            if rows.isEmpty {
                note("폴더에 문서가 없습니다", path: folder)
            } else if blocks.isEmpty {
                note(noMatch, path: nil)
            }
            ForEach(blocks, id: \.key) { b in
                if let name = b.folderName { blockHead(b, name: name) }
                ForEach(b.shown) { r in line(r) }
                if b.more > 0 {
                    Button("더 보기 (\(b.more)개)") { expandedBlocks.insert(b.key) }
                        .buttonStyle(.link).scaledFont(.callout)
                        .padding(.leading, 34).padding(.vertical, 3)
                        .help(b.folderName.map { "\($0)의 나머지 문서 펴기" } ?? "나머지 문서 펴기")
                }
            }
        }
    }

    private func listHead(_ title: String, count: String, open: Binding<Bool>, help: String) -> some View {
        Button { open.wrappedValue.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right")
                    .scaledFont(.caption2, weight: .semibold).foregroundStyle(.secondary).frame(width: 10 * scale)
                Text(title).fontWeight(.semibold)
                Text(count).monospacedDigit().foregroundStyle(.secondary)
            }
            .scaledFont(.subheadline)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(count.isEmpty ? title : "\(title) \(count)")
        .accessibilityValue(open.wrappedValue ? "펼침" : "접힘")
        .accessibilityAddTraits(.isHeader)
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title).scaledFont(.callout, weight: .semibold).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func blockHead(_ b: DocumentBlock, name: String) -> some View {
        let shownName = name.isEmpty ? "문서 폴더 바로 아래" : name
        return Button {
            if b.folded { foldedBlocks.remove(b.key) } else { foldedBlocks.insert(b.key) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: b.folded ? "chevron.right" : "chevron.down")
                    .scaledFont(.caption2, weight: .semibold).frame(width: 10 * scale)
                Image(systemName: "folder")
                Text(shownName).fontWeight(.semibold)
                Text("\(b.count)").monospacedDigit()
                Spacer(minLength: 0)
            }
            .scaledFont(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(b.folded ? "\(shownName) 펴기" : "\(shownName) 접기")
        .accessibilityLabel("\(shownName) \(b.count)")
        .accessibilityValue(b.folded ? "접힘" : "펼침")
        .accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: String, path: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).scaledFont(.callout)
            if let path { Text(path).scaledFont(.callout, design: .monospaced).foregroundStyle(.secondary) }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 12).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shownRows: [DocumentRow] {
        (pickedOpen ? pickedSections.flatMap(\.rows) : []) + (allOpen ? blocks.flatMap(\.shown) : [])
    }

    private func move(_ by: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        let rows = shownRows
        guard !rows.isEmpty else { return .ignored }
        let at = rows.firstIndex { $0.id == selected }
        let next = rows[min(max((at ?? (by > 0 ? -1 : rows.count)) + by, 0), rows.count - 1)]
        selected = next.id
        proxy.scrollTo(next.id)
        return .handled
    }

    private func style(_ r: DocumentRow) -> DocumentRowStyle {
        DocumentRowStyle.of(r, fileOpen: r.isFromFolder ? folderOpens[r.id] : fileOpens[r.id])
    }

    private func activate(_ r: DocumentRow) {
        selected = r.id
        focused = true
        if style(r).state == nil { open(r) }
    }

    private func line(_ r: DocumentRow) -> some View {
        let st = style(r)
        let on = selected == r.id
        let emphasized = on && focused && active == .key
        let items = documentMenuItems(r)
        let marks = lineMarks(r, state: st.stateText, picked: picked, shownPagePath: shownPagePath)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: st.symbol).foregroundStyle(.secondary).frame(width: 18 * scale)
            Text(r.line.title).foregroundStyle(st.state == nil ? .primary : .secondary).lineLimit(1).layoutPriority(1)
            if !r.line.note.isEmpty {
                Text(r.line.note).scaledFont(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(r.isFromFolder ? .middle : .tail)
                    .frame(minWidth: Self.noteMinWidth * scale, alignment: .leading)
            }
            Spacer(minLength: 8)
            if !marks.isEmpty {
                Text(marks.joined(separator: " · ")).scaledFont(.caption1, weight: .semibold).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).layoutPriority(Self.statePriority)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.backgroundProminence, emphasized ? .increased : .standard)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 5)
                    .fill(emphasized ? Color(nsColor: .selectedContentBackgroundColor) : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { activate(r) }
        .help(st.help)
        .contextMenu {
            ForEach(items, id: \.self) { item in Button(item.title) { run(item) } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(st.label(r.line))
        .accessibilityValue(lineMarks(r, state: st.state, picked: picked, shownPagePath: shownPagePath).joined(separator: ", "))
        .accessibilityHint(st.help)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { activate(r) }
        .modifier(DocumentMenuActions(items: items))
        .id(r.id)
    }
}

func lineMarks(_ r: DocumentRow, state: String?, picked: Set<String>, shownPagePath: String?) -> [String] {
    var marks: [String] = []
    if case .folder(let modified) = r.origin { marks.append(boardClock(modified, withDay: true)) }
    if r.isFromFolder, case .file(let path) = r.target, picked.contains(path) { marks.append("고른 문서") }
    if let state {
        marks.append(state)
    } else if let shownPagePath, r.target == .file(shownPagePath) {
        marks.append("보는 중")
    }
    return marks
}

private struct DocumentMenuActions: ViewModifier {
    let items: [DocumentMenuItem]

    func body(content: Content) -> some View {
        items.reduce(AnyView(content)) { view, item in AnyView(view.accessibilityAction(named: item.title) { run(item) }) }
    }
}
