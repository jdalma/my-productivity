import SwiftUI
import TowerCore

// Quick open and text search of one folder (G4 I10), in Swift: the page cannot start git. A picked result goes to
// `open`, which shows it in the editor.

/// `CT_EDITOR_SEARCH=<words>`: what the search field holds when the panel first shows, as a text search. Typing does
/// not reach the test instance.
let searchAtStart = ProcessInfo.processInfo.environment["CT_EDITOR_SEARCH"] ?? ""

enum SearchMode: Hashable {
    case files, text
}

/// What the panel lists under its field.
enum SearchFound: Equatable, Sendable {
    /// Nothing typed.
    case idle
    /// git gave no answer: the folder is in no repository, or git failed or took too long.
    case failed
    case files([String])
    case text(SearchResult)

    /// The first result: what Return opens.
    var first: (path: String, line: Int?)? {
        switch self {
        case .files(let paths): paths.first.map { ($0, nil) }
        case .text(let r): r.hits.first.map { ($0.path, $0.line) }
        case .idle, .failed: nil
        }
    }
}

/// The results of `query` in `root`. `files` is the folder's file list when the caller has it already; the list read
/// here is returned for the next call.
func search(_ mode: SearchMode, _ query: String, in root: String, files: [String]?) -> (found: SearchFound, files: [String]?) {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return (.idle, files) }
    switch mode {
    case .files:
        guard let list = files ?? workspaceFiles(toplevel: root, scope: "") else { return (.failed, nil) }
        return (.files(quickOpen(query, files: list)), list)
    case .text:
        return (searchText(query, in: root).map(SearchFound.text) ?? .failed, files)
    }
}

/// The field, the choice of files or text, and the results. `open` gets a path from `root`, and a text hit's line.
struct SearchPanel: View {
    let root: String
    let open: (String, Int?) -> Void
    @State private var mode = searchAtStart.isEmpty ? SearchMode.files : .text
    @State private var query = searchAtStart
    @State private var found = SearchFound.idle
    /// The folder's files, listed when a quick open starts and dropped when the field is emptied: the next one lists
    /// them again, with the files made since.
    @State private var files: [String]?
    @FocusState private var focused: Bool

    private struct Key: Equatable {
        var mode: SearchMode
        var query: String
        var root: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 6) {
                Picker("찾을 것", selection: $mode) {
                    Text("파일").tag(SearchMode.files)
                    Text("내용").tag(SearchMode.text)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("파일 이름으로 열기, 또는 파일 내용에서 찾기 (git이 무시하는 파일 제외)")
                TextField(mode == .files ? "파일 이름" : "찾을 글자", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if let first = found.first { open(first.path, first.line) } }
            }
            .padding(8)
            Divider()
            results
        }
        .scaledFont(.callout)
        .onAppear { focused = true }
        .onChange(of: query.isEmpty) { _, empty in if empty { files = nil } }
        .task(id: Key(mode: mode, query: query, root: root)) {
            // typing: one search for the last of a run of keys
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let (mode, query, root, known) = (mode, query, root, files)
            let r = await Task.detached { search(mode, query, in: root, files: known) }.value
            guard !Task.isCancelled else { return }
            found = r.found
            if !query.isEmpty { files = r.files }
        }
    }

    @ViewBuilder
    private var results: some View {
        switch found {
        case .idle:
            note("")
        case .failed:
            note("찾지 못함: git 저장소가 아니거나 git이 답하지 않음")
        case .files(let paths):
            if paths.isEmpty { note("맞는 파일 없음") }
            list {
                ForEach(paths, id: \.self) { path in
                    row(path, line: nil) { name(path) }
                }
            }
        case .text(let r):
            if r.hits.isEmpty { note("찾은 줄 없음") }
            list {
                ForEach(r.hits, id: \.self) { hit in
                    row(hit.path, line: hit.line) {
                        VStack(alignment: .leading, spacing: 1) {
                            name(hit.path, line: hit.line)
                            Text(displayLine(hit.text).trimmingCharacters(in: .whitespaces))
                                .scaledFont(.caption1, design: .monospaced).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                if r.more { Text("\(r.hits.count)줄까지만 보임. 더 길게 적으면 줄어듦").scaledFont(.caption1).foregroundStyle(.secondary).padding(8) }
            }
        }
    }

    private func list(@ViewBuilder _ rows: () -> some View) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) { rows() }
        }
    }

    private func row(_ path: String, line: Int?, @ViewBuilder label: () -> some View) -> some View {
        Button { open(path, line) } label: {
            label()
                .padding(.horizontal, 10).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(path)
    }

    /// The file name, then its line, then its folder dimmer: the name is what was typed for.
    private func name(_ path: String, line: Int? = nil) -> some View {
        let (dir, name) = splitPath(path)
        return (Text(name).fontWeight(.semibold) + Text(line.map { ":\($0)" } ?? "") + Text(dir.isEmpty ? "" : "  " + dir).foregroundStyle(.secondary))
            .lineLimit(1).truncationMode(.tail)
    }

    private func note(_ text: String) -> some View {
        Text(text).scaledFont(.caption1).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading)
    }
}
