import Foundation

/// One list line of the index, as written.
public struct DocumentLine: Hashable, Sendable {
    public var title: String
    /// A path or a URL; nil for a list line without a link.
    public var link: String?
    public var note: String

    public init(title: String, link: String?, note: String = "") {
        self.title = title
        self.link = link
        self.note = note
    }
}

public struct DocumentGroup: Hashable, Sendable {
    /// Empty for the lines above the first group heading.
    public var title: String
    public var lines: [DocumentLine]

    public init(title: String, lines: [DocumentLine]) {
        self.title = title
        self.lines = lines
    }
}

func plainOneLine(_ s: String) -> String {
    String(inlineMarkdown(s).characters).split(whereSeparator: \.isNewline).joined(separator: " ").trimmed
}

private func note(_ text: String, without link: Range<String.Index>) -> String {
    let linkPlaceholder = "\u{E000}"
    return plainOneLine(String(text[..<link.lowerBound]) + linkPlaceholder + String(text[link.upperBound...]))
        .replacing(#/\(\s*\x{E000}\s*\)|\[\s*\x{E000}\s*\]/#, with: "")
        .replacingOccurrences(of: linkPlaceholder, with: "")
        .split(separator: " ").joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: ":：*_-–— \t\n"))
}

/// The first link of a list line is the document, wherever it stands (`- **[title](link)**: note`,
/// `- note: [title](link)`, `- <https://…>`); the line's other words are its note. An image (`![alt](file)`) and a
/// link written inside code are not links. The title may hold one level of brackets and the link one level of
/// parentheses, a `<…>` around it and a `"title"` after it.
private func documentLine(_ text: String) -> DocumentLine {
    let code = text.ranges(of: #/(`+).+?\1/#)
    func isALink(_ r: Range<String.Index>) -> Bool {
        !code.contains { $0.overlaps(r) } && !(r.lowerBound > text.startIndex && text[text.index(before: r.lowerBound)] == "!")
    }
    if let m = text.matches(of: #/\[((?:[^\[\]\\]|\\.|\[[^\[\]]*\])+)\]\(((?:[^()]|\([^()]*\))*)\)/#).first(where: { isALink($0.range) }) {
        var link = String(m.2).trimmed
        if let titled = link.wholeMatch(of: #/(.*\S)\s+"[^"]*"/#) { link = String(titled.1) }
        link = link.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        return DocumentLine(title: plainOneLine(String(m.1)), link: link.nonEmpty, note: note(text, without: m.range))
    }
    if let m = text.matches(of: #/<(https?://[^>\s]+)>/#).first(where: { isALink($0.range) }) {
        return DocumentLine(title: String(m.1), link: String(m.1), note: note(text, without: m.range))
    }
    return DocumentLine(title: plainOneLine(text), link: nil)
}

/// The index's groups: each heading under the file's title opens one, each list line is a document. Other text
/// (the file's title, a paragraph of notes) is not a document and is left out; a group without lines is too.
public func parseDocumentIndex(_ text: String) -> [DocumentGroup] {
    var groups = [DocumentGroup(title: "", lines: [])]
    for block in markdownBlocks(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text) {
        switch block {
        case .heading(let level, let title) where level > 1: groups.append(DocumentGroup(title: plainOneLine(title), lines: []))
        case .listItem(_, _, let text), .task(_, _, let text): groups[groups.count - 1].lines.append(documentLine(text))
        default: break
        }
    }
    return groups.filter { !$0.lines.isEmpty }
}

public enum DocumentBlockReason: Hashable, Sendable {
    /// A path that leaves the team's documents folder, once links and `..` are resolved.
    case outside
    /// An address that is not `http` or `https`: `file://`, an app's own scheme.
    case scheme
    case noLink

    public var reason: String {
        switch self {
        case .outside: "팀 문서 폴더 밖의 경로라 열지 않습니다"
        case .scheme: "http, https 링크만 엽니다"
        case .noLink: "링크가 없는 줄입니다"
        }
    }
}

public enum DocumentTarget: Hashable, Sendable {
    case web(URL)
    /// A file in the team's documents folder, by its path with symbolic links and `..` resolved.
    case file(String)
    /// A path in the folder with no file there.
    case missing(String)
    case blocked(DocumentBlockReason)

    public var opens: Bool {
        switch self {
        case .web, .file: true
        case .missing, .blocked: false
        }
    }
}

func realPath(_ path: String) -> String? {
    guard let p = realpath(path, nil) else { return nil }
    defer { free(p) }
    return String(cString: p)
}

func isInside(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

/// What `link` opens for the team whose documents are in `folder`: a web address, or a file whose real path is in
/// the folder. Anything else is blocked: a path that leaves the folder (by `..`, an absolute path or a symbolic
/// link) and every scheme but http and https.
public func documentTarget(_ link: String?, folder: String) -> DocumentTarget {
    guard let link = link?.trimmed.nonEmpty else { return .blocked(.noLink) }
    let root = realPath(folder) ?? URL(fileURLWithPath: folder).standardizedFileURL.path
    func joined(_ p: String) -> String { p.hasPrefix("/") ? p : folder + "/" + p }
    if let scheme = link.prefixMatch(of: #/([A-Za-z][A-Za-z0-9+.\-]*):/#)?.1.lowercased() {
        if ["http", "https"].contains(scheme) {
            guard let url = URL(string: link), url.host() != nil else { return .blocked(.scheme) }
            return .web(url)
        }
        let isNameOfAFile = realPath(joined(link)) != nil
        guard isNameOfAFile else { return .blocked(.scheme) }
    }
    let written = link.removingPercentEncoding ?? link
    let wholeThenWithoutFragment = [written] + (written.contains("#") ? [String(written.prefix { $0 != "#" })] : [])
    for c in wholeThenWithoutFragment {
        if let real = realPath(joined(c)) { return isInside(real, root) ? .file(real) : .blocked(.outside) }
    }
    let last = wholeThenWithoutFragment.last!
    let lexical = URL(fileURLWithPath: last.hasPrefix("/") ? last : root + "/" + last).standardizedFileURL.path
    return isInside(lexical, root) ? .missing(lexical) : .blocked(.outside)
}

public struct DocumentRow: Hashable, Sendable, Identifiable {
    public enum Origin: Hashable, Sendable {
        case index
        case folder(modified: Date)
    }

    /// A line of the index: its place there, top to bottom. A file of the folder: `folderRowID`.
    public var id: Int
    public var line: DocumentLine
    public var target: DocumentTarget
    public var origin: Origin

    public init(id: Int, line: DocumentLine, target: DocumentTarget, origin: Origin = .index) {
        self.id = id
        self.line = line
        self.target = target
        self.origin = origin
    }

    public var isFromFolder: Bool { origin != .index }
}

/// Below zero, so it never meets a place in the index, and from the path, so the same file keeps its id (and the
/// selection) when the folder is read again.
// ponytail: a hash, unique in practice for the files of one folder; keep rows by path if two ever meet.
public func folderRowID(_ relative: String) -> Int { -1 - Int(UInt(bitPattern: relative.hashValue) >> 1) }

/// The folder's files as lines: the title, the path from the folder as the note, and the file itself to open.
public func folderRows(_ docs: [FolderDocument]) -> [DocumentRow] {
    docs.map { d in
        DocumentRow(id: folderRowID(d.relative), line: DocumentLine(title: d.title, link: d.relative, note: d.relative),
                    target: .file(d.path), origin: .folder(modified: d.stamp.modified))
    }
}

/// The lines whose title, link or note holds every word of `query`, whatever the case; all of them for no word.
public func filterDocuments(_ rows: [DocumentRow], _ query: String) -> [DocumentRow] {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return rows }
    return rows.filter { r in
        let text = [r.line.title, r.line.link ?? "", r.line.note].joined(separator: "\n")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}

public struct DocumentFolderGroup: Hashable, Sendable {
    /// The folder right under the team's documents folder; empty for the files in the documents folder itself.
    public var name: String
    public var rows: [DocumentRow]
}

/// The folder's lines by the folder they are in right under the documents folder, the names in order and the files
/// outside any folder first; each group keeps the order the lines came in.
public func groupByFolder(_ rows: [DocumentRow]) -> [DocumentFolderGroup] {
    func folder(_ r: DocumentRow) -> String {
        let parts = (r.line.link ?? "").split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : ""
    }
    return Dictionary(grouping: rows, by: folder).map { DocumentFolderGroup(name: $0.key, rows: $0.value) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

public struct DocumentSection: Hashable, Sendable {
    public var title: String
    public var rows: [DocumentRow]

    public init(title: String, rows: [DocumentRow]) {
        self.title = title
        self.rows = rows
    }
}

public struct FileStamp: Hashable, Sendable {
    public var modified: Date
    public var size: Int

    public init(modified: Date, size: Int) {
        self.modified = modified
        self.size = size
    }
}

public func fileStamp(_ path: String) -> FileStamp? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: path), let m = a[.modificationDate] as? Date,
          let n = a[.size] as? Int else { return nil }
    return FileStamp(modified: m, size: n)
}

public enum DocumentIndexContent: Hashable, Sendable {
    case missing
    case unreadable(String)
    case groups([DocumentGroup])
}

public struct TeamDocuments: Hashable, Sendable {
    public var folder: String
    public var indexPath: String
    /// The index file as it was read; nil when there was none.
    public var stamp: FileStamp?
    public var content: DocumentIndexContent
    public var sections: [DocumentSection]

    public init(folder: String, indexPath: String, stamp: FileStamp?, content: DocumentIndexContent, sections: [DocumentSection]) {
        self.folder = folder
        self.indexPath = indexPath
        self.stamp = stamp
        self.content = content
        self.sections = sections
    }

    public var rows: [DocumentRow] { sections.flatMap(\.rows) }
    public var openable: Int { rows.filter(\.target.opens).count }
}

/// `<state folder>/docs/<team>`, the state folder being the parent of `stateRootBase` (`~/.my-team`); nil for a team
/// name that is not one folder's name.
func documentsFolder(team: String, base: String) -> String? {
    guard !team.isEmpty, !team.contains("/"), team != ".", team != ".." else { return nil }
    return URL(fileURLWithPath: base).deletingLastPathComponent().appendingPathComponent("docs/\(team)").path
}

/// The team's index read again only when its file changed since `known` (by modification time and size); what each
/// line opens is looked at every time, since a report can appear without the index changing.
func readTeamDocuments(team: String, base: String, known: TeamDocuments?, stamp: (String) -> FileStamp?,
                       page: (_ path: String, _ folder: String) -> PageRead) -> TeamDocuments {
    guard let folder = documentsFolder(team: team, base: base) else {
        return TeamDocuments(folder: "", indexPath: "", stamp: nil, content: .unreadable("팀 이름 '\(team)'으로는 문서 폴더를 정할 수 없습니다"), sections: [])
    }
    let path = folder + "/index.md"
    let now = stamp(path)
    let content: DocumentIndexContent
    if let known, known.indexPath == path, known.stamp == now, now != nil {
        content = known.content
    } else if now == nil {
        content = .missing
    } else {
        switch page(path, folder) {
        case .read(let text): content = .groups(parseDocumentIndex(text))
        case .unreadable(let why): content = .unreadable(why)
        }
    }
    var sections: [DocumentSection] = []
    if case .groups(let groups) = content {
        var id = 0
        for g in groups {
            sections.append(DocumentSection(title: g.title, rows: g.lines.map { line in
                defer { id += 1 }
                return DocumentRow(id: id, line: line, target: documentTarget(line.link, folder: folder))
            }))
        }
    }
    return TeamDocuments(folder: folder, indexPath: path, stamp: now, content: content, sections: sections)
}

public func readTeamDocuments(team: String, known: TeamDocuments?) -> TeamDocuments {
    readTeamDocuments(team: team, base: stateRootBase(), known: known, stamp: fileStamp) { readDocumentFile($0, folder: $1, what: "목록") }
}

/// Reads a file of the team's documents, never writing. The file is opened once and what was opened is what is
/// judged and read: its real path must be in `folder`, so a path replaced by a link out of the folder after it was
/// judged is not read. Only a regular file within `pageSizeLimit`, as `readPage`.
public func readDocumentFile(_ path: String, folder: String, what: String) -> PageRead {
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else {
        return .unreadable(errno == ENOENT ? "\(what) 파일이 없습니다: \(path)" : "\(what) 파일을 읽지 못했습니다: \(path)")
    }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var opened = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard fcntl(fd, F_GETPATH, &opened) == 0, let root = realPath(folder),
          isInside(opened.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }, root) else {
        return .unreadable("\(what) 파일을 읽지 않았습니다: \(DocumentBlockReason.outside.reason): \(path)")
    }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= pageSizeLimit,
          let data = try? file.read(upToCount: pageSizeLimit + 1) ?? Data(), data.count <= pageSizeLimit else {
        return .unreadable("\(what) 파일을 읽지 못함: 1MB 이하의 일반 파일이 아닙니다: \(path)")
    }
    guard let text = String(data: data, encoding: .utf8) else { return .unreadable("\(what) 파일을 읽지 못했습니다: \(path)") }
    return .read(text)
}
