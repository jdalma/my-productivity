import Foundation
import Testing
@testable import TowerCore

private func members(_ text: String, java: Bool = false) -> [String] {
    scanSource(text, java: java).members.map { m in
        [m.name, m.owner ?? "-", m.receiver ?? "-", m.type ?? "-", m.local ? "local" : "member"].joined(separator: " ")
    }
}

@Test func kotlinMembers() {
    let m = members("""
        package com.example

        val top: Config = Config()
        fun topLevel(a: Int, b: String) = a
        fun <T> List<T>.second(): T = this[1]
        fun Foo?.orEmpty() {}
        class Box(val width: Int, var height: Int, plain: Int) {
            var label = "x"
            fun area(): Int {
                val local = width * height
                listOf(1).map { item -> item + local }
                helper(width)
                return local
            }
            companion object {
                const val MAX = 3
            }
        }
        """)
    #expect(m == [
        "top - - Config member",
        "topLevel - - - member", "a - - Int local", "b - - String local",
        "second - List - member",
        "orEmpty - Foo - member",
        "width com.example.Box - Int member", "height com.example.Box - Int member",
        "label com.example.Box - - member",
        "area com.example.Box - - member",
        "local - - - local",
        "MAX com.example.Box.Companion - - member",
    ])
}

@Test func javaMethodsAndFieldsNotCallsOrLocals() {
    let m = members("""
        package com.example;

        public class Repo<T> extends Base implements Api, Other {
            private final Store store = new Store(load());
            static int count, total;
            List<String> names;
            int[] grid;
            public Repo(Store s) { this.store = s; }
            public <R> List<R> find(String q) throws IOException, Other {
                int local = compute(q);
                return helper(local);
            }
            void find(int id) {}
            @Override public String toString() { return "x"; }
            enum Mode { ON, OFF; void flip() {} }
        }
        """, java: true)
    #expect(m == [
        "store com.example.Repo - Store member",
        "count com.example.Repo - int member", "total com.example.Repo - - member",
        "names com.example.Repo - - member",
        "grid com.example.Repo - - member",
        "Repo com.example.Repo - - member",
        "find com.example.Repo - - member",
        "find com.example.Repo - - member",
        "toString com.example.Repo - - member",
        "ON com.example.Repo.Mode - - member", "OFF com.example.Repo.Mode - - member",
        "flip com.example.Repo.Mode - - member",
    ])
}

private let files: [String: String] = [
    "src/app/Main.kt": """
        package com.example.app

        import com.example.model.User
        import com.example.util.format

        fun run(user: User, repo: Repo) {
            val total = 1
            user.save()
            repo.save()
            format(total)
            total.inc()
            Repo.create()
            save()
        }
        fun save() {}
        """,
    "src/app/Repo.kt": """
        package com.example.app

        class Repo {
            fun save() {}
            companion object {
                fun create() = Repo()
            }
        }
        """,
    "src/model/User.kt": "package com.example.model\n\nclass User {\n    fun save() {}\n}\n",
    "src/model/Ext.kt": "package com.example.model\n\nfun User.save(force: Boolean) {}\n",
    "src/util/Format.kt": "package com.example.util\n\nfun format(x: Int) = x\nfun format(x: String) = x\n",
    "src/other/Format.kt": "package com.example.other\n\nfun format(x: Long) = x\n",
    "src/other/Saver.java": "package com.example.other;\n\nclass Saver {\n    void save() {}\n}\n",
]

private func index() -> DeclIndex {
    DeclIndex(files: Dictionary(uniqueKeysWithValues: files.map { ($0.key, scanSource($0.value, java: $0.key.hasSuffix(".java"))) }))
}

private func paths(_ t: CodeTarget) -> [String] {
    switch t {
    case .found(let l): ["\(l.path):\(l.line)"]
    case .many(let c): c.map { "\($0.location.path):\($0.location.line)" }
    case .none: []
    }
}

@Test func memberCandidatesAreRanked() {
    let ix = index()
    let main = "src/app/Main.kt"
    // a bare name declared above in this file: straight there (locals and parameters too)
    #expect(ix.navigate(["total"], in: main, line: 10) == .found(CodeLocation(path: main, line: 7)))
    #expect(ix.navigate(["user"], in: main, line: 8) == .found(CodeLocation(path: main, line: 6)))
    // `user.save()`: `user` is a User, so User.save and the extension on User come first
    #expect(paths(ix.navigate(["user", "save"], in: main, line: 8)) == [
        "src/model/Ext.kt:3", "src/model/User.kt:4",  // receiver's type, by path
        "src/app/Main.kt:15",                          // this file
        "src/app/Repo.kt:4",                           // this package
        "src/other/Saver.java:4",                      // the rest
    ])
    // `repo.save()`: Repo's save first
    #expect(paths(ix.navigate(["repo", "save"], in: main, line: 9)).first == "src/app/Repo.kt:4")
    // a type as the receiver, its companion's member
    #expect(ix.navigate(["Repo", "create"], in: main, line: 12) == .found(CodeLocation(path: "src/app/Repo.kt", line: 6)))
    // overloads are each a candidate; the imported file before another package
    #expect(paths(ix.navigate(["format"], in: main, line: 10)) == ["src/util/Format.kt:3", "src/util/Format.kt:4", "src/other/Format.kt:3"])
    // a bare name declared only below: ranked, this file first
    #expect(paths(ix.navigate(["save"], in: main, line: 13)).first == "src/app/Main.kt:15")
    // a type keeps the type result; nothing anywhere is none
    #expect(ix.navigate(["User"], in: main, line: 1) == .found(CodeLocation(path: "src/model/User.kt", line: 3)))
    #expect(ix.navigate(["nothing"], in: main, line: 1) == .none)
    // locals of other files never appear
    #expect(paths(ix.navigate(["force"], in: main, line: 1)).isEmpty)
}

@Test func typeCandidatesCarryTheirLine() {
    let ix = DeclIndex(files: ["a/Dup.kt": scanSource("package com.example.a\nclass Dup\n", java: false),
                               "b/Dup.kt": scanSource("package com.example.b\nclass Dup(val x: Int)\n", java: false)])
    #expect(ix.navigate(["Dup"], in: "x.kts", line: 1) == .many([
        Candidate(location: CodeLocation(path: "a/Dup.kt", line: 2), snippet: "class Dup"),
        Candidate(location: CodeLocation(path: "b/Dup.kt", line: 2), snippet: "class Dup(val x: Int)"),
    ]))
}

/// The nearest declaration above counts only while its scope holds the click; members are ranked, so
/// overloads are all offered.
@Test func onlyLocalsInScopeOpenDirectly() {
    let kt = """
        package com.example
        enum class Status { ACTIVE, DONE }
        class A {
            val name = ""
            fun f() {
                val name = 1
                println(name)
            }
            fun g(id: Long) {
                println(name)
            }
            fun h() {
                println(id)
                load()
            }
            fun load() {}
            fun load(x: Int) {}
            fun k() {
                load()
                val s = Status.ACTIVE
            }
            fun e(v: Int) = v + 1
            fun after() = v
        }
        """
    let other = "package com.example.o\nclass B { val id = 0; fun load(y: String) {} }\n"
    let ix = DeclIndex(files: ["A.kt": scanSource(kt, java: false), "o/B.kt": scanSource(other, java: false)])
    let a = ix.files["A.kt"]!.members
    #expect(a.first { $0.name == "name" && $0.local }?.scopeEnd == 8)   // f's block
    #expect(a.first { $0.name == "id" }?.scopeEnd == 11)                  // g's body
    #expect(a.first { $0.name == "v" }?.scopeEnd == 22)                  // an expression body: its line
    #expect(ix.navigate(["name"], in: "A.kt", line: 7) == .found(CodeLocation(path: "A.kt", line: 6)))   // f's local
    #expect(ix.navigate(["name"], in: "A.kt", line: 10) == .found(CodeLocation(path: "A.kt", line: 4)))  // in g: the property
    // in h, g's parameter is out of scope: only B.id, unrelated, so listed rather than opened
    #expect(ix.navigate(["id"], in: "A.kt", line: 13) == .many([Candidate(location: CodeLocation(path: "o/B.kt", line: 2),
                                                                          snippet: "class B { val id = 0; fun load(y: String) {} }")]))
    // overloads above or below the click: the same list
    let loads = [CodeLocation(path: "A.kt", line: 16), CodeLocation(path: "A.kt", line: 17), CodeLocation(path: "o/B.kt", line: 2)]
    for at in [14, 19] {
        guard case .many(let c) = ix.navigate(["load"], in: "A.kt", line: at) else { Issue.record("load at \(at)"); continue }
        #expect(c.map(\.location) == loads)
    }
    #expect(ix.navigate(["v"], in: "A.kt", line: 23) == .none)            // after an expression body
    // enum entries are members of their enum
    #expect(ix.navigate(["Status", "ACTIVE"], in: "A.kt", line: 20) == .found(CodeLocation(path: "A.kt", line: 2)))
}

@Test func enumEntriesAndFieldLists() {
    let j = members("""
        package com.example;
        public class J {
            enum Kind { RED { void paint() {} }, BLUE("b"), GREEN; void common() {} }
            int a, b;
            int c = 1, d = f(1, 2);
            Map<String, Integer> m;
        }
        """, java: true)
    #expect(j == [
        "RED com.example.J.Kind - - member", "BLUE com.example.J.Kind - - member", "GREEN com.example.J.Kind - - member",
        "common com.example.J.Kind - - member",
        "a com.example.J - int member", "b com.example.J - - member",
        "c com.example.J - int member", "d com.example.J - - member",
        "m com.example.J - - member",
    ])
    let k = members("package com.example\nenum class Mode(val v: Int) { ON(1), OFF(0) { override fun x() = 1 };\n    fun flip() = 0 }\n")
    #expect(k == ["v com.example.Mode - Int member", "ON com.example.Mode - - member", "OFF com.example.Mode - - member",
                  "x - - - local", "flip com.example.Mode - - member"])  // an entry's own body: local, like Java's
}

/// A parameter's scope survives a lambda default value in its parameter list; annotated, `vararg`,
/// `noinline` and `crossinline` parameters are parameters too.
@Test func parametersWithDefaultsAnnotationsAndModifiers() {
    let kt = """
        package com.example
        class A(val a: Int) {
            val req = 0
            fun d(a: Int, cb: () -> Unit = { }) {
                println(a)
            }
            fun ann(@RequestBody req: Req, @field:Size(min = 1, max = 2) name: String, vararg more: Int,
                    noinline f: () -> Unit, @a.b.Ann crossinline g: () -> Unit) {
                println(req)
            }
        }
        """
    let f = scanSource(kt, java: false)
    let params = f.members.filter(\.local).map { "\($0.name)@\($0.line)→\($0.scopeEnd ?? -1)" }
    #expect(params == ["a@4→6", "cb@4→6", "req@7→10", "name@7→10", "more@7→10", "f@8→10", "g@8→10"])
    let idx = DeclIndex(files: ["A.kt": f])
    #expect(idx.navigate(["a"], in: "A.kt", line: 5) == .found(CodeLocation(path: "A.kt", line: 4)))    // the parameter, not property a
    #expect(idx.navigate(["req"], in: "A.kt", line: 9) == .found(CodeLocation(path: "A.kt", line: 7)))  // not property req
    #expect(idx.navigate(["more"], in: "A.kt", line: 9) == .found(CodeLocation(path: "A.kt", line: 7)))
}
