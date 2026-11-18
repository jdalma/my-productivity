import Foundation

// Java/Kotlin declarations of a workspace, for Command-click to a definition. A byte scan, not a parser:
// package, imports, type and member declarations, with comments and strings skipped.

public struct TypeDecl: Hashable, Sendable {
    public var name: String
    /// Package, enclosing types and the name, dot separated.
    public var qualified: String
    public var line: Int
    /// Character offset of the name in its line.
    public var column: Int
    /// The declaring line, trimmed: what a candidate list shows.
    public var snippet: String
}

/// A function, property or field; in Kotlin also a local `val`/`var`/`fun` or a function parameter.
public struct MemberDecl: Hashable, Sendable {
    public var name: String
    public var line: Int
    public var column: Int
    /// The qualified name of the type whose body declares it; nil at the top level or for a local.
    public var owner: String?
    /// A Kotlin extension's receiver type, its last simple name: `Foo` for `fun a.Foo<T>.bar()`.
    public var receiver: String?
    /// A property's declared type, its first simple name, when the declaration states it
    /// (`val a: Foo`, `val a = Foo(…)`, Java `Foo a;`).
    public var type: String?
    /// Inside a function or initializer body, or a parameter: seen only from its own file.
    public var local: Bool
    public var snippet: String
    /// A local's last line: its block's closing line; a parameter's, its function body's (an expression
    /// body's last line). nil for a member.
    public var scopeEnd: Int? = nil
}

public struct ImportDecl: Hashable, Sendable {
    /// `a.b.C`, or the package `a.b` of a wildcard import.
    public var path: String
    public var alias: String?
    public var wildcard: Bool
}

public struct SourceFacts: Hashable, Sendable {
    public var package = ""
    public var imports: [ImportDecl] = []
    public var types: [TypeDecl] = []
    public var members: [MemberDecl] = []
}

private let declKeywords: Set = ["class", "interface", "object", "typealias", "enum"]
/// A word after a declaration keyword that is another keyword, not a name: `enum class`, `fun interface`'s neighbors.
private let notNames: Set = ["class", "interface", "object", "fun", "enum"]
/// A header continued on the next line: `class A\n    : B {`, Java's `extends` on its own line.
private let continuations: Set = ["extends", "implements", "where", "permits"]
/// Kotlin parameter modifiers before a parameter's name.
private let paramModifiers: Set = ["vararg", "noinline", "crossinline"]
/// Java words that look like a type or a name in a class body but are neither.
private let javaNotNames: Set = ["if", "for", "while", "switch", "catch", "synchronized", "return", "new", "throw", "else",
                                 "try", "do", "case", "default", "static", "final", "assert", "super", "this", "throws"]

private func isIdent(_ c: UInt8) -> Bool {
    c >= 0x80 || c == UInt8(ascii: "_") || c == UInt8(ascii: "$") || (48...57).contains(c) || (97...122).contains(c | 0x20)
}

private func isIdentStart(_ c: UInt8) -> Bool { isIdent(c) && !(48...57).contains(c) }

/// The package, imports and type declarations of one source file. Declarations inside comments and
/// strings are ignored. A type's body is the first `{` outside parentheses after its name; a header that
/// ends a line without one has no body unless the next line continues it (`{`, `:`, `,`, `extends` …).
/// Kotlin block comments nest, Java's do not. Java alone has `record`.
///
/// Members. Kotlin: every `fun`, `val` and `var` (an extension's receiver kept), and function parameters;
/// one directly in a type body (or a primary constructor's `val`) is that type's member, one at the top
/// level has no owner, any other is local, with the line its scope ends on. Java: only directly in a type
/// body, outside parentheses and initializers, a word after a type (a word, `>` or `]`) and before `(` is
/// a method, before `=`, `;` or `,` a field, and so is a word after `,` in a field list (`int a, b;`).
/// Enum entries (`A`, `B(1)`, `C { … }` before the body's first `;`) are members of their enum.
/// Calls, Java locals and parameters, and lambda parameters are not declarations.
public func scanSource(_ text: String, java: Bool) -> SourceFacts {
    let b = Array(text.utf8), n = b.count
    var facts = SourceFacts()
    // a UTF-8 BOM would otherwise read as the start of a word and hide `package`
    let bom = b.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
    var i = bom, line = 1, lineStart = bom
    var depth = 0, parens = 0
    var stack: [(name: String, depth: Int)] = []
    var pending: String?
    var checkPending = false, lineHasToken = false
    var last: UInt8 = 0
    /// The last word read, for a Java field's type.
    var lastWord = ""
    /// Java: the current class-body statement has had an `=`, so its words are an initializer.
    var initializer = false
    /// Kotlin: the parenthesis depth of the parameter list of the `fun` just read.
    var params: Int?
    /// Kotlin: a parameter may start here (after `(` or `,`, through annotations and modifiers).
    var paramOpen = false
    /// Kotlin: locals whose scope ends when the block at `depth` closes.
    var scopes: [(index: Int, depth: Int)] = []
    /// Kotlin: parameters read, waiting for their function's body; the `fun`'s brace depth.
    var awaiting: [Int] = [], funDepth = 0
    /// The type `pending` names is an enum; `entries` is its body's depth while entries are read.
    var pendingEnum = false
    var entries: Int?
    /// Java: the class-body statement declares fields, so `, b` declares another.
    var fieldList = false
    let keywords = java ? declKeywords.union(["record"]) : declKeywords

    func byte(_ k: Int) -> UInt8 { k < n ? b[k] : 0 }
    func identEnd(_ k: Int) -> Int {
        var e = k
        while e < n, isIdent(b[e]) { e += 1 }
        return e
    }
    func word(_ r: Range<Int>) -> String { String(decoding: b[r], as: UTF8.self) }
    func newline(at k: Int) {
        line += 1
        lineStart = k + 1
        lineHasToken = false
    }
    func skipSpaces(_ k: Int) -> Int {
        var e = k
        while e < n, b[e] == UInt8(ascii: " ") || b[e] == UInt8(ascii: "\t") { e += 1 }
        return e
    }
    /// Past a balanced `<…>` starting at `k` on the same line; `k` when there is none.
    func skipAngles(_ k: Int) -> Int {
        guard byte(k) == UInt8(ascii: "<") else { return k }
        var d = 0, j = k
        while j < n {
            switch b[j] {
            case UInt8(ascii: "<"): d += 1
            case UInt8(ascii: ">"): d -= 1; if d == 0 { return j + 1 }
            case UInt8(ascii: "\n"), UInt8(ascii: "{"), UInt8(ascii: ";"): return k
            default: break
            }
            j += 1
        }
        return k
    }
    func nextSignificant(_ k: Int) -> Int {
        var e = k
        while e < n, b[e] == UInt8(ascii: " ") || b[e] == UInt8(ascii: "\t") || b[e] == UInt8(ascii: "\n") || b[e] == UInt8(ascii: "\r") { e += 1 }
        return e
    }
    func snippet() -> String {
        var e = lineStart
        while e < n, b[e] != UInt8(ascii: "\n") { e += 1 }
        return String(word(lineStart..<e).trimmingCharacters(in: .whitespaces).prefix(160))
    }
    func column(_ k: Int) -> Int { String(decoding: b[lineStart..<k], as: UTF8.self).count }
    func prefix() -> [String] { [facts.package] + stack.map(\.name) }
    func qualify(_ names: [String]) -> String { names.filter { !$0.isEmpty }.joined(separator: ".") }
    /// Kotlin: where a member read now belongs.
    func placement(constructor: Bool) -> (owner: String?, local: Bool) {
        if constructor, let p = pending, parens > 0 { return (qualify(prefix() + [p]), false) }
        if depth == 0 { return (nil, false) }
        if let top = stack.last, top.depth == depth { return (qualify(prefix()), false) }
        return (nil, true)
    }
    /// `fun <T> a.Foo<T>.name`, `val name: Type`, `var name = Type(…)` after the keyword ending at `k`.
    func kotlinMember(_ kw: String, after k0: Int) -> (MemberDecl, Int)? {
        var k = skipSpaces(skipAngles(skipSpaces(k0)))
        var receiver: String?, name: String?, nameStart = k
        while k < n, isIdentStart(b[k]) {
            let e = identEnd(k), id = word(k..<e)
            var j = skipAngles(e)
            if byte(j) == UInt8(ascii: "?") { j += 1 }
            if byte(j) == UInt8(ascii: "."), isIdentStart(byte(j + 1)) {
                receiver = id
                k = j + 1
                continue
            }
            name = id
            nameStart = k
            k = e
            break
        }
        // `fun interface X`: a type, read by the type branch
        guard let name, !notNames.contains(name) else { return nil }
        var type: String?
        if kw != "fun" {
            var t = skipSpaces(k)
            if byte(t) == UInt8(ascii: ":"), byte(t + 1) != UInt8(ascii: ":") {
                t = skipSpaces(t + 1)
                if isIdentStart(byte(t)) { type = word(t..<identEnd(t)) }
            } else if byte(t) == UInt8(ascii: "="), byte(t + 1) != UInt8(ascii: "=") {
                t = skipSpaces(t + 1)
                let e = identEnd(t)
                if e > t, byte(skipAngles(e)) == UInt8(ascii: "("), word(t..<e).first?.isUppercase == true { type = word(t..<e) }
            }
        }
        let place = placement(constructor: kw != "fun")
        return (MemberDecl(name: name, line: line, column: column(nameStart), owner: place.owner, receiver: receiver,
                           type: type, local: place.local, snippet: snippet()), k)
    }
    func endAwaiting() {
        for k in awaiting { facts.members[k].scopeEnd = line }
        awaiting = []
    }
    func lineRest(from k: Int) -> (String, Int) {
        var e = k
        while e < n, b[e] != UInt8(ascii: "\n") { e += 1 }
        return (word(k..<e), e)
    }

    while i < n {
        let c = b[i]
        if c == UInt8(ascii: "\n") {
            if pending != nil, parens == 0, last != UInt8(ascii: ":"), last != UInt8(ascii: ",") { checkPending = true }
            // an expression body or a body-less function ends with its line
            if !awaiting.isEmpty, parens == 0, !"=:,(".utf8.contains(last) { endAwaiting() }
            newline(at: i)
            i += 1
            continue
        }
        if c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\r") { i += 1; continue }
        if c == UInt8(ascii: "/"), byte(i + 1) == UInt8(ascii: "/") {
            while i < n, b[i] != UInt8(ascii: "\n") { i += 1 }
            continue
        }
        if c == UInt8(ascii: "/"), byte(i + 1) == UInt8(ascii: "*") {
            var nest = 1
            i += 2
            while i < n, nest > 0 {
                if b[i] == UInt8(ascii: "*"), byte(i + 1) == UInt8(ascii: "/") { nest -= 1; i += 2; continue }
                if !java, b[i] == UInt8(ascii: "/"), byte(i + 1) == UInt8(ascii: "*") { nest += 1; i += 2; continue }
                if b[i] == UInt8(ascii: "\n") { newline(at: i) }
                i += 1
            }
            continue
        }
        if checkPending, !lineHasToken {
            checkPending = false
            let first = isIdentStart(c) ? word(i..<identEnd(i)) : ""
            let keep = c == UInt8(ascii: "{") || c == UInt8(ascii: ":") || c == UInt8(ascii: ",") || continuations.contains(first)
            if !keep { pending = nil }
        }
        let firstOnLine = !lineHasToken
        lineHasToken = true

        if c == UInt8(ascii: "\"") {
            if byte(i + 1) == UInt8(ascii: "\""), byte(i + 2) == UInt8(ascii: "\"") {
                i += 3
                while i < n, !(b[i] == UInt8(ascii: "\"") && byte(i + 1) == UInt8(ascii: "\"") && byte(i + 2) == UInt8(ascii: "\"")) {
                    if b[i] == UInt8(ascii: "\n") { newline(at: i) }
                    i += 1
                }
                i += 3
            } else {
                i += 1
                while i < n, b[i] != UInt8(ascii: "\""), b[i] != UInt8(ascii: "\n") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
                if byte(i) == UInt8(ascii: "\"") { i += 1 }
            }
            last = UInt8(ascii: "\"")
            continue
        }
        if c == UInt8(ascii: "'") {
            // a char literal, 'A' at most; a lone quote is left as is
            var j = i + 1
            while j < n, j < i + 9, b[j] != UInt8(ascii: "'"), b[j] != UInt8(ascii: "\n") { j += b[j] == UInt8(ascii: "\\") ? 2 : 1 }
            i = byte(j) == UInt8(ascii: "'") ? j + 1 : i + 1
            last = UInt8(ascii: "'")
            continue
        }
        switch c {
        case UInt8(ascii: "{"):
            if let p = pending, parens == 0 {
                stack.append((p, depth + 1))
                if pendingEnum { entries = depth + 1 }
            }
            if !awaiting.isEmpty, parens == 0, depth == funDepth {
                scopes += awaiting.map { ($0, depth + 1) }
                awaiting = []
            }
            pending = nil
            pendingEnum = false
            params = nil
            initializer = false
            fieldList = false
            depth += 1
        case UInt8(ascii: "}"):
            if stack.last?.depth == depth { stack.removeLast() }
            while let s = scopes.last, s.depth == depth {
                facts.members[s.index].scopeEnd = line
                scopes.removeLast()
            }
            // a lambda default value in the parameter list closes inside parentheses: not the body
            if !awaiting.isEmpty, parens == 0 { endAwaiting() }
            if entries == depth { entries = nil }
            depth = max(0, depth - 1)
            initializer = false
            fieldList = false
        case UInt8(ascii: "("):
            parens += 1
            if params == parens { paramOpen = true }
        case UInt8(ascii: ")"):
            parens = max(0, parens - 1)
            if let p = params, parens < p { params = nil }
        case UInt8(ascii: ";"):
            if parens == 0 {
                pending = nil
                if !awaiting.isEmpty { endAwaiting() }
                if entries == depth { entries = nil }
            }
            initializer = false
            fieldList = false
        case UInt8(ascii: ","):
            if fieldList, parens == 0 { initializer = false }
            if params == parens { paramOpen = true }
        case UInt8(ascii: "="):
            if parens == 0, byte(i + 1) != UInt8(ascii: "="), !"=!<>".utf8.contains(last) { initializer = true }
        default: break
        }
        guard isIdentStart(c) else {
            last = c
            i += 1
            continue
        }
        let end = identEnd(i)
        let w = word(i..<end)
        if firstOnLine, depth == 0, w == "package" || w == "import" {
            let (rest, e) = lineRest(from: end)
            if w == "package" {
                facts.package = String(rest.drop { $0 == " " }.prefix { $0.isLetter || $0.isNumber || "_$.".contains($0) })
            } else if let imp = parseImport(rest) {
                facts.imports.append(imp)
            }
            i = e
            continue
        }
        if keywords.contains(w), last != UInt8(ascii: "."), last != UInt8(ascii: ":") {
            var k = end
            while k < n, b[k] == UInt8(ascii: " ") || b[k] == UInt8(ascii: "\t") { k += 1 }
            let nameEnd = identEnd(k)
            if k < n, isIdentStart(b[k]), !notNames.contains(word(k..<nameEnd)) {
                let name = word(k..<nameEnd)
                let qualified = ([facts.package] + stack.map(\.name) + [name]).filter { !$0.isEmpty }.joined(separator: ".")
                facts.types.append(TypeDecl(name: name, qualified: qualified, line: line, column: column(k), snippet: snippet()))
                pending = w == "typealias" ? nil : name
                pendingEnum = w == "enum" || lastWord == "enum"
                last = b[nameEnd - 1]
                lastWord = name
                i = nameEnd
                continue
            }
            // an unnamed `companion object` or object expression: its body holds members, not locals
            if w == "object", !java { pending = "Companion" }
        }
        if let e = entries, depth == e, parens == 0, last == UInt8(ascii: "{") || last == UInt8(ascii: ",") {
            facts.members.append(MemberDecl(name: w, line: line, column: column(i), owner: qualify(prefix()), receiver: nil,
                                            type: nil, local: false, snippet: snippet()))
        }
        if !java, w == "fun" || w == "val" || w == "var", last != UInt8(ascii: "."), let (m, e) = kotlinMember(w, after: end) {
            if m.local { scopes.append((facts.members.count, depth)) }
            facts.members.append(m)
            if w == "fun" {
                params = parens + 1
                if !awaiting.isEmpty { endAwaiting() }
                funDepth = depth
            }
            last = b[e - 1]
            lastWord = m.name
            i = e
            continue
        }
        let next = nextSignificant(end)
        // `@Ann`, `@a.b.Ann`, `@field:Ann` and `vararg`/`noinline`/`crossinline` keep a parameter open
        let annotation = last == UInt8(ascii: "@") || last == UInt8(ascii: ".") || last == UInt8(ascii: ":")
        if !java, paramOpen, let p = params, parens == p, !annotation, !paramModifiers.contains(w) {
            paramOpen = false
            if byte(next) == UInt8(ascii: ":"), byte(next + 1) != UInt8(ascii: ":") {
                let t = skipSpaces(next + 1)
                awaiting.append(facts.members.count)
                facts.members.append(MemberDecl(name: w, line: line, column: column(i), owner: nil, receiver: nil,
                                                type: isIdentStart(byte(t)) ? word(t..<identEnd(t)) : nil, local: true, snippet: snippet()))
            }
        }
        if java, pending == nil, let top = stack.last, top.depth == depth, parens == 0, !initializer,
           isIdent(last) || last == UInt8(ascii: ">") || last == UInt8(ascii: "]") || (fieldList && last == UInt8(ascii: ",")),
           !javaNotNames.contains(w), !javaNotNames.contains(lastWord) || !isIdent(last) {
            let after = byte(next)
            let method = after == UInt8(ascii: "(")
            let field = after == UInt8(ascii: ";") || after == UInt8(ascii: ",") || (after == UInt8(ascii: "=") && byte(next + 1) != UInt8(ascii: "="))
            if field { fieldList = true }
            if method || field {
                facts.members.append(MemberDecl(name: w, line: line, column: column(i), owner: qualify(prefix()), receiver: nil,
                                                type: field && isIdent(last) ? lastWord : nil, local: false, snippet: snippet()))
            }
        }
        last = b[end - 1]
        lastWord = w
        i = end
    }
    for s in scopes { facts.members[s.index].scopeEnd = line }
    for k in awaiting { facts.members[k].scopeEnd = line }
    return facts
}

/// ` a.b.C`, ` static a.b.c`, ` a.b.*;`, ` a.b.C as D` after `import`.
private func parseImport(_ rest: String) -> ImportDecl? {
    var words = rest.replacingOccurrences(of: ";", with: " ").split(separator: " ").map(String.init)
    if words.first == "static" { words.removeFirst() }
    guard var path = words.first, !path.isEmpty else { return nil }
    let alias = words.count >= 3 && words[1] == "as" ? words[2] : nil
    let wildcard = path.hasSuffix(".*")
    if wildcard { path.removeLast(2) }
    return ImportDecl(path: path, alias: alias, wildcard: wildcard)
}

/// Where a Command-clicked type name leads.
public enum TypeTarget: Hashable, Sendable {
    case found(CodeLocation)
    /// More than one declaration fits; sorted.
    case many([CodeLocation])
    case none
}

/// A declaration offered in the candidate list.
public struct Candidate: Hashable, Sendable {
    public var location: CodeLocation
    public var snippet: String
}

/// Where a Command-click on any name leads.
public enum CodeTarget: Hashable, Sendable {
    case found(CodeLocation)
    /// Best first.
    case many([Candidate])
    case none
}

/// Every scanned file of a workspace, looked up by simple and by qualified type name and by member name.
public struct DeclIndex: Sendable {
    public let files: [String: SourceFacts]
    private let byName: [String: [Ref]]
    private let byQualified: [String: [Ref]]
    /// Members that are not local.
    private let byMember: [String: [MemberRef]]

    private struct Ref: Hashable, Sendable {
        var path: String
        var decl: TypeDecl
    }

    private struct MemberRef: Hashable, Sendable {
        var path: String
        var decl: MemberDecl
    }

    public init(files: [String: SourceFacts]) {
        self.files = files
        let refs = files.flatMap { path, f in f.types.map { Ref(path: path, decl: $0) } }
        byName = Dictionary(grouping: refs, by: \.decl.name)
        byQualified = Dictionary(grouping: refs, by: \.decl.qualified)
        byMember = Dictionary(grouping: files.flatMap { path, f in f.members.filter { !$0.local }.map { MemberRef(path: path, decl: $0) } },
                              by: \.decl.name)
    }

    /// A Command-click on `name` (dotted segments) on `line` of `path`. A type, as `resolve` finds it,
    /// comes first. Else members of that name:
    /// - a bare name that is a local or parameter of this file whose scope holds `line` (the nearest
    ///   above) is the answer;
    /// - otherwise every non-local member, ranked: declared in the receiver's
    ///   type (`X.name` with `X` a type, or a property of this file whose declared type is one), or an
    ///   extension on it; this file; files of explicit imports (a type's file, or a top-level member
    ///   imported by name); this package and wildcard-imported packages; the rest. Then by path and line.
    ///   A single candidate opens, unless it ranks last (no relation to this file): then it is listed, for
    ///   the user to judge.
    public func navigate(_ name: [String], in path: String, line: Int) -> CodeTarget {
        guard let last = name.last else { return .none }
        let types = typeRefs(name, path)
        if !types.isEmpty {
            return candidates(types.sorted { ($0.path, $0.decl.line) < ($1.path, $1.decl.line) }
                .map { Candidate(location: CodeLocation(path: $0.path, line: $0.decl.line), snippet: $0.decl.snippet) })
        }
        let facts = files[path] ?? SourceFacts()
        /// The local or parameter `n` in scope at `line`.
        func inScope(_ n: String) -> MemberDecl? {
            facts.members.filter { $0.name == n && $0.local && $0.line <= line && line <= ($0.scopeEnd ?? 0) }.max { $0.line < $1.line }
        }
        if name.count == 1, let near = inScope(last) { return .found(CodeLocation(path: path, line: near.line)) }

        var owners: Set<String> = [], receivers: Set<String> = []
        if name.count > 1 {
            let x = Array(name.dropLast())
            var t = typeRefs(x, path)
            if t.isEmpty, x.count == 1, let v = inScope(x[0]) ?? facts.members.first(where: { $0.name == x[0] && !$0.local }), let vt = v.type {
                t = typeRefs([vt], path)
            }
            owners = Set(t.flatMap { [$0.decl.qualified, $0.decl.qualified + ".Companion"] })
            receivers = Set(t.map(\.decl.name))
        }
        let explicit = facts.imports.filter { !$0.wildcard }
        let importedFiles = Set(explicit.flatMap { byQualified[$0.path] ?? [] }.map(\.path))
        let importedNames = Set(explicit.map(\.path))
        let packages = Set([facts.package] + facts.imports.filter(\.wildcard).map(\.path))
        func rank(_ r: MemberRef) -> Int {
            if let o = r.decl.owner, owners.contains(o) { return 0 }
            if let rc = r.decl.receiver, receivers.contains(rc) { return 0 }
            if r.path == path { return 1 }
            let package = files[r.path]?.package ?? ""
            if importedFiles.contains(r.path) || (r.decl.owner == nil && importedNames.contains(package + "." + r.decl.name)) { return 2 }
            if packages.contains(package) { return 3 }
            return 4
        }
        let ranked = (byMember[last] ?? []).map { (rank($0), $0) }
            .sorted { ($0.0, $0.1.path, $0.1.decl.line) < ($1.0, $1.1.path, $1.1.decl.line) }
        let result = candidates(ranked.map { Candidate(location: CodeLocation(path: $0.1.path, line: $0.1.decl.line), snippet: $0.1.decl.snippet) })
        if case .found(let only) = result, ranked.first?.0 == 4 {
            return .many([Candidate(location: only, snippet: ranked[0].1.decl.snippet)])
        }
        return result
    }

    /// One location found, several listed (each location once, in order), or none.
    private func candidates(_ list: [Candidate]) -> CodeTarget {
        var seen = Set<CodeLocation>()
        let unique = list.filter { seen.insert($0.location).inserted }
        switch unique.count {
        case 0: return .none
        case 1: return .found(unique[0].location)
        default: return .many(unique)
        }
    }

    /// `name`'s segments (`["a", "b", "C"]` for `a.b.C`) as written in `path`. A dotted name is first
    /// a qualified name; else its first segment resolves as a simple name and the rest are nested types
    /// in it; else the last segment alone. A simple name: (a) this file, (b) an explicit import or its
    /// alias, which is final even when the type is outside the workspace, (c) this file's package,
    /// (d) wildcard imports, (e) the one type of that name in the workspace, only for a file with no
    /// `package` or one not scanned. In a file with a package a name (a)–(d) miss comes from a default
    /// import (`kotlin.*`, `java.lang.*` …) or a wildcard outside the workspace, never another package.
    public func resolve(_ name: [String], in path: String) -> TypeTarget {
        target(typeRefs(name, path))
    }

    private func typeRefs(_ name: [String], _ path: String) -> [Ref] {
        guard let head = name.first else { return [] }
        let facts = files[path] ?? SourceFacts()
        if name.count == 1 { return simple(head, facts, path) }
        if let q = byQualified[name.joined(separator: ".")] { return q }
        let rest = name.dropFirst().joined(separator: ".")
        let nested = simple(head, facts, path).flatMap { byQualified[$0.decl.qualified + "." + rest] ?? [] }
        return nested.isEmpty ? simple(name[name.count - 1], facts, path) : nested
    }

    private func simple(_ n: String, _ facts: SourceFacts, _ path: String) -> [Ref] {
        let here = facts.types.filter { $0.name == n }
        if !here.isEmpty { return here.map { Ref(path: path, decl: $0) } }
        let explicit = facts.imports.filter { !$0.wildcard && ($0.alias ?? $0.path.split(separator: ".").last.map(String.init)) == n }
        if !explicit.isEmpty { return explicit.flatMap { byQualified[$0.path] ?? [] } }
        if let same = byQualified[facts.package.isEmpty ? n : facts.package + "." + n] { return same }
        let wild = facts.imports.filter(\.wildcard).flatMap { byQualified[$0.path + "." + n] ?? [] }
        if !wild.isEmpty { return wild }
        return facts.package.isEmpty ? byName[n] ?? [] : []
    }

    private func target(_ refs: [Ref]) -> TypeTarget {
        let locations = Set(refs.map { CodeLocation(path: $0.path, line: $0.decl.line) })
            .sorted { ($0.path, $0.line) < ($1.path, $1.line) }
        switch locations.count {
        case 0: return .none
        case 1: return .found(locations[0])
        default: return .many(locations)
        }
    }
}

/// The dotted name ending at the identifier under `offset`: `["a", "b", "C"]` for a click on `C` of
/// `a.b.C`, `["a", "b"]` for one on `b`.
public func dottedName(in line: String, at offset: Int, dollar: Bool = true) -> [String]? {
    guard let w = identifier(in: line, at: offset, dollar: dollar) else { return nil }
    let chars = Array(line)
    var parts = [w.name], lo = w.range.lowerBound
    while lo >= 2, chars[lo - 1] == ".", let prev = identifier(in: line, at: lo - 2, dollar: dollar) {
        parts.insert(prev.name, at: 0)
        lo = prev.range.lowerBound
    }
    return parts
}

private let sourceExtensions: Set = ["kt", "kts", "java"]

/// Each workspace's index, kept between clicks. A lookup lists the files (`git ls-files -co
/// --exclude-standard`) and rescans only those whose size or modification time changed.
/// `@unchecked Sendable`: `repos` and `scans` change only inside `lock`; `scans` is read without it by
/// tests alone, after the calls they count have returned.
public final class DeclIndexCache: @unchecked Sendable {
    private struct Stamp: Equatable {
        var size: Int64
        var seconds: Int
        var nanoseconds: Int
    }

    private struct Repo {
        var stamps: [String: Stamp] = [:]
        var facts: [String: SourceFacts] = [:]
        var index = DeclIndex(files: [:])
    }

    private let lock = NSLock()
    private var repos: [String: Repo] = [:]
    /// Files scanned so far, by tests only.
    private(set) var scans = 0

    public init() {}

    public func index(toplevel: String) -> DeclIndex {
        let paths = (out(.lsFiles, ["-co", "--exclude-standard", "-z"], in: toplevel) ?? "")
            .split(separator: "\0").map(String.init)
            .filter { sourceExtensions.contains(($0 as NSString).pathExtension) }
        return lock.withLock {
            var repo = repos[toplevel] ?? Repo()
            var stamps: [String: Stamp] = [:], facts: [String: SourceFacts] = [:]
            for p in paths {
                var st = stat()
                let full = toplevel + "/" + p
                guard stat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
                let stamp = Stamp(size: st.st_size, seconds: st.st_mtimespec.tv_sec, nanoseconds: st.st_mtimespec.tv_nsec)
                stamps[p] = stamp
                if repo.stamps[p] == stamp, let f = repo.facts[p] {
                    facts[p] = f
                } else if let text = try? String(contentsOfFile: full, encoding: .utf8) {
                    scans += 1
                    facts[p] = scanSource(text, java: p.hasSuffix(".java"))
                }
            }
            if stamps != repo.stamps || facts.count != repo.facts.count {
                repo = Repo(stamps: stamps, facts: facts, index: DeclIndex(files: facts))
                repos[toplevel] = repo
            }
            return repo.index
        }
    }
}

public let declIndexCache = DeclIndexCache()
