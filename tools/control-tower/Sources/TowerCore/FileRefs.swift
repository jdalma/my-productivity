import Foundation

// The file locations a task board text names: a finding's summary and repro, a landing's focus, a report line
// (G4 W1, W6). The board keeps them as free text, so the forms reviewers write are read here:
//   `Name.swift:123`, `a/b.swift:10-20`, `start.js:174,338`, `X.swift:42→41`, `T.swift:849-889(note), :943`
//   `<commit>:path:12`
//   `sed -n '198,234p' /abs/path`, `sed -n '12p;74,80p' path`
//   `git [-C dir] show <commit>:<path> | [cat -n |] sed -n a,bp`
// Purely lexical: a ref is only a place to try. The caller links it only when the path resolves to a file.

public struct FileRef: Hashable, Sendable {
    /// As written: absolute, `~/…`, or relative (to a landing's repo, a worker's folder, or a bare file name).
    public var path: String
    public var lineStart: Int
    /// The range's last line; nil for one line.
    public var lineEnd: Int?
    /// The revision the text reads the file at (`git show <commit>:path`, `<commit>:path:line`); nil for the work tree.
    public var commit: String?

    public init(path: String, lineStart: Int, lineEnd: Int? = nil, commit: String? = nil) {
        self.path = path
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.commit = commit
    }
}

/// A location and the characters of the text it was read from: what a link covers.
public struct FileRefSpan: Hashable, Sendable {
    /// Character offsets in the text, `Character` counted.
    public var range: Range<Int>
    public var ref: FileRef
}

/// Every location `text` names, in text order.
public func fileRefs(in text: String) -> [FileRef] { fileRefSpans(in: text).map(\.ref) }

/// Every location `text` names with the characters it was written in, in text order. A sed's ranges share its span.
public func fileRefSpans(in text: String) -> [FileRefSpan] {
    // a URL's host, port and path look like `name.ext:line`: blank URLs out first (risk 4 of the plan); character for
    // character, so offsets in `s` are offsets in `text`
    let s = text.replacing(#/[A-Za-z][A-Za-z0-9+.\-]*:\/\/\S+/#) { String(repeating: " ", count: $0.output.count) }
    func offsets(_ r: Range<String.Index>) -> Range<Int> {
        let a = s.distance(from: s.startIndex, to: r.lowerBound)
        return a..<(a + s.distance(from: r.lowerBound, to: r.upperBound))
    }
    var found: [(range: Range<Int>, ref: FileRef)] = []

    // sed -n '<ranges>' [file], its file the argument or the git show piped into it
    let shows = s.matches(of: #/git\s+(?:-C\s+\S+\s+)?show\s+(?:--\S+\s+)*([^\s:'"|;]+):([^\s'"|;]+)/#)
    for m in s.matches(of: #/sed\s+-n\s+(?:'([^']*)'|"([^"]*)"|(\S+))(?:[ \t]+([^\s|;&<>]+))?/#) {
        let unquoted = m.output.3
        let script = String(m.output.1 ?? m.output.2 ?? unquoted ?? "")
        var path: String?, commit: String?
        // an unquoted script that ends its command with `;` has no file after it
        if let arg = m.output.4, !(unquoted?.hasSuffix(";") ?? false), arg.contains(where: { $0 == "/" || $0 == "." }) {
            path = String(arg)
        } else if let show = shows.last(where: { $0.range.upperBound <= m.range.lowerBound }),
                  s[show.range.upperBound..<m.range.lowerBound].wholeMatch(of: #/\s*(?:\|\s*cat\s+-n\s*)?\|\s*/#) != nil {
            (path, commit) = (String(show.output.2), String(show.output.1))
        }
        guard let path else { continue }
        for part in script.replacing("\\", with: "").split(separator: ";") {
            guard let r = part.wholeMatch(of: #/\s*(\d+)(?:,(\d+))?p\s*/#), let a = Int(r.output.1), a > 0 else { continue }
            found.append((offsets(m.range), FileRef(path: path, lineStart: a, lineEnd: r.output.2.flatMap { Int($0) }, commit: commit)))
        }
    }

    // path:line[-line][:column], with more lines of the same file after it; the column is read and left out (R20 L1)
    for m in s.matches(of: #/(?:([0-9a-f]{7,40}):)?([A-Za-z0-9_.\/~@+\-]*\.[A-Za-z][A-Za-z0-9_]*):(\d+)(?:-(\d+))?(?::\d+)?(?![A-Za-z0-9_:]|\.\d)/#) {
        let path = String(m.output.2), commit = m.output.1.map(String.init)
        guard let a = Int(m.output.3), a > 0 else { continue }
        found.append((offsets(m.range), FileRef(path: path, lineStart: a, lineEnd: m.output.4.flatMap { Int($0) }, commit: commit)))
        // `,338` `, :943` `→41` `→:74-80`, a parenthesized note allowed before each
        var rest = s[m.range.upperBound...]
        while let c = rest.prefixMatch(of: #/(?:\([^()]*\))?(?:,|,\s*:|→:?)(\d+)(?:-(\d+))?(?![A-Za-z0-9_:]|\.\d|\p{L})/#),
              let b = Int(c.output.1), b > 0 {
            found.append((offsets(c.range), FileRef(path: path, lineStart: b, lineEnd: c.output.2.flatMap { Int($0) }, commit: commit)))
            rest = rest[c.range.upperBound...]
        }
    }
    // several ranges of one sed share its place: the order they were found in breaks the tie
    return found.enumerated().sorted { ($0.element.range.lowerBound, $0.offset) < ($1.element.range.lowerBound, $1.offset) }
        .map { FileRefSpan(range: $0.element.range, ref: $0.element.ref) }
}

// MARK: - Which file a location opens (G4 I12)

/// A place the task board's editor opens: a file on disk, or a file as a commit holds it.
public enum FileTarget: Hashable, Sendable {
    case file(path: String, line: Int)
    case commit(repo: String, commit: String, path: String, line: Int)

    public var line: Int {
        switch self {
        case .file(_, let line), .commit(_, _, _, let line): line
        }
    }

    /// The path the editor names the file by (`commitOpen` names a commit's file under its repo).
    public var editorPath: String {
        switch self {
        case .file(let path, _): path
        case .commit(let repo, _, let path, _): repo + "/" + path
        }
    }
}

/// Where `ref` opens, in the order of plan §2.1: an absolute or `~/` path that is a file; `<commit>:path` in the
/// landing's repo, else the worker's folder; a relative path that is a file under the landing's repo, then under the
/// worker's folder; a bare file name that exactly one file of those folders has (`filesIn`, paths from the folder).
/// nil when none: the text stays text (a document task, a file gone).
public func fileTarget(_ ref: FileRef, repo: String?, workerCwd: String?, home: String = NSHomeDirectory(),
                       isFile: (String) -> Bool = isRegularFile, filesIn: (String) -> [String]? = { _ in nil }) -> FileTarget? {
    let bases = [repo, workerCwd].compactMap { $0 }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    let path = ref.path.hasPrefix("~/") ? home + ref.path.dropFirst() : ref.path
    if let commit = ref.commit {
        guard !path.hasPrefix("/"), let base = bases.first else { return nil }
        return .commit(repo: base, commit: commit, path: path, line: ref.lineStart)
    }
    if path.hasPrefix("/") { return isFile(path) ? .file(path: path, line: ref.lineStart) : nil }
    if let base = bases.first(where: { isFile($0 + "/" + path) }) { return .file(path: base + "/" + path, line: ref.lineStart) }
    guard !path.contains("/") else { return nil }
    let named = bases.flatMap { base in (filesIn(base) ?? []).filter { ($0 as NSString).lastPathComponent == path }.map { base + "/" + $0 } }
    return named.count == 1 ? .file(path: named[0], line: ref.lineStart) : nil
}

/// A regular file (links followed).
public func isRegularFile(_ path: String) -> Bool {
    var folder: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &folder) && !folder.boolValue
}

// MARK: - An open finding beside its line (G4 W5)

public struct FindingMark: Hashable, Sendable {
    public var target: FileTarget
    public var severity: String
    public var id: String
    public var summary: String
    /// The file changed after the review that raised it: its line may have moved.
    public var changed: Bool

    public init(target: FileTarget, severity: String, id: String, summary: String, changed: Bool) {
        self.target = target
        self.severity = severity
        self.id = id
        self.summary = summary
        self.changed = changed
    }
}

/// The markers of the file the editor shows as `path`: each mark there, by severity, faint where the file changed
/// since the review.
public func editorMarkers(for path: String, marks: [FindingMark]) -> [EditorMarker] {
    // the editor names a file by its real path; a mark may name it through a link (/var for /private/var)
    let shown = realPath(path) ?? path
    return marks.filter { (realPath($0.target.editorPath) ?? $0.target.editorPath) == shown }.map { m in
        let severity: EditorMarker.Severity = switch (m.changed, m.severity) {
        case (true, _): .hint
        case (false, "must"): .error
        case (false, "should"): .warning
        default: .info
        }
        return EditorMarker(line: m.target.line, severity: severity,
                            message: "\(m.id) \(m.summary)" + (m.changed ? " (지적 뒤 파일이 바뀌어 줄이 어긋났을 수 있음)" : ""))
    }
}

/// Whether `path` (from `dir`'s top) differs between `commit` and the work tree, or `to` when given; nil when git
/// cannot tell (no such commit).
public func fileChanged(dir: String, since commit: String, to: String? = nil, path: String) -> Bool? {
    out(.diff, ["--no-ext-diff", "--name-only", "--end-of-options", commit] + (to.map { [$0] } ?? []) + ["--", path], in: dir)
        .map { !$0.trimmed.isEmpty }
}
