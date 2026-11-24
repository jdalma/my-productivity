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

/// Every location `text` names, in text order.
public func fileRefs(in text: String) -> [FileRef] {
    // a URL's host, port and path look like `name.ext:line`: blank URLs out first (risk 4 of the plan)
    let s = text.replacing(#/[A-Za-z][A-Za-z0-9+.\-]*:\/\/\S+/#) { String(repeating: " ", count: $0.output.count) }
    var found: [(at: String.Index, ref: FileRef)] = []

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
            found.append((m.range.lowerBound, FileRef(path: path, lineStart: a, lineEnd: r.output.2.flatMap { Int($0) }, commit: commit)))
        }
    }

    // path:line[-line], with more lines of the same file after it
    for m in s.matches(of: #/(?:([0-9a-f]{7,40}):)?([A-Za-z0-9_.\/~@+\-]*\.[A-Za-z][A-Za-z0-9_]*):(\d+)(?:-(\d+))?(?![A-Za-z0-9_:]|\.\d)/#) {
        let path = String(m.output.2), commit = m.output.1.map(String.init)
        guard let a = Int(m.output.3), a > 0 else { continue }
        found.append((m.range.lowerBound, FileRef(path: path, lineStart: a, lineEnd: m.output.4.flatMap { Int($0) }, commit: commit)))
        // `,338` `, :943` `→41` `→:74-80`, a parenthesized note allowed before each
        var rest = s[m.range.upperBound...]
        while let c = rest.prefixMatch(of: #/(?:\([^()]*\))?(?:,|,\s*:|→:?)(\d+)(?:-(\d+))?(?![A-Za-z0-9_:]|\.\d|\p{L})/#),
              let b = Int(c.output.1), b > 0 {
            found.append((c.range.lowerBound, FileRef(path: path, lineStart: b, lineEnd: c.output.2.flatMap { Int($0) }, commit: commit)))
            rest = rest[c.range.upperBound...]
        }
    }
    // several ranges of one sed share its place: the order they were found in breaks the tie
    return found.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element.ref)
}
