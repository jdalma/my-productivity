import Foundation
import Testing
@testable import TowerCore

private func index(_ files: [String: String]) -> DeclIndex {
    DeclIndex(files: files.mapValues { scanSource($0, java: false) }.merging(
        files.filter { $0.key.hasSuffix(".java") }.mapValues { scanSource($0, java: true) }) { $1 })
}

private func at(_ path: String, _ line: Int) -> TypeTarget { .found(CodeLocation(path: path, line: line)) }

@Test func kotlinDeclarationsWithNestingAndKinds() {
    let f = scanSource("""
        package com.example.app

        import com.example.util.Helper
        import com.example.other.*
        import com.example.util.Long as Lng

        data class Point(
            val x: Int,
        ) : Shape {
            companion object Factory {
                fun make() = Point(0)
            }
            enum class Kind { A, B { override fun x() {} } }
        }
        sealed interface Shape
        object Registry
        annotation class Marker
        value class Id(val v: Long)
        typealias Points = List<Point>
        fun interface Action { fun run() }
        class After { inner class In }
        """, java: false)
    #expect(f.package == "com.example.app")
    #expect(f.imports == [ImportDecl(path: "com.example.util.Helper", alias: nil, wildcard: false),
                          ImportDecl(path: "com.example.other", alias: nil, wildcard: true),
                          ImportDecl(path: "com.example.util.Long", alias: "Lng", wildcard: false)])
    #expect(f.types.map(\.qualified) == [
        "com.example.app.Point", "com.example.app.Point.Factory", "com.example.app.Point.Kind",
        "com.example.app.Shape", "com.example.app.Registry", "com.example.app.Marker", "com.example.app.Id",
        "com.example.app.Points", "com.example.app.Action", "com.example.app.After", "com.example.app.After.In",
    ])
    #expect(f.types[0].line == 7 && f.types[0].column == 11)
    #expect(f.types[1].line == 10)
}

@Test func javaDeclarationsIncludingRecordAndAnnotation() {
    let f = scanSource("""
        package com.example.j;

        import static com.example.j.Util.helper;
        import java.util.*;

        public class Outer<T extends Comparable<T>>
                extends Base implements Api {
            public record Pair(int a, int b) {}
            @interface Tag {}
            enum Color { RED; class InEnum {} }
            Object object = Outer.class;
            Record record;
        }
        interface Api {}
        """, java: true)
    #expect(f.package == "com.example.j")
    #expect(f.imports.map(\.path) == ["com.example.j.Util.helper", "java.util"])
    #expect(f.types.map(\.qualified) == ["com.example.j.Outer", "com.example.j.Outer.Pair", "com.example.j.Outer.Tag",
                                         "com.example.j.Outer.Color", "com.example.j.Outer.Color.InEnum", "com.example.j.Api"])
}

/// Declarations inside comments and strings are not declarations.
@Test func commentsAndStringsAreIgnored() {
    let f = scanSource("""
        package com.example
        // class InLineComment
        /* class InBlock /* nested class StillComment */ class AlsoComment */
        val s = "class InString { }"
        val raw = \"\"\"
            class InRaw {
        \"\"\"
        val c = '{'
        val t = Foo::class
        class Real {
            val brace = "}"
        }
        class Next
        """, java: false)
    #expect(f.types.map(\.qualified) == ["com.example.Real", "com.example.Next"])
    // Java comments do not nest: the first `*/` ends it
    let j = scanSource("/* /* */ class AfterComment {}", java: true)
    #expect(j.types.map(\.name) == ["AfterComment"])
    // a UTF-8 BOM before `package`
    let bom = scanSource("\u{FEFF}package com.example.bom\n\nclass B\n", java: false)
    #expect(bom.package == "com.example.bom" && bom.types.first?.qualified == "com.example.bom.B" && bom.types.first?.column == 6)
}

private let files = [
    "src/app/Main.kt": """
        package com.example.app

        import com.example.model.User
        import com.example.lib.Thing as LibThing
        import com.example.wild.*
        import org.external.Outside

        class Local
        val a: User = User()
        """,
    "src/app/Sibling.kt": "package com.example.app\n\nclass Sibling\n",
    "src/model/User.kt": "package com.example.model\n\nclass User {\n    class Inner\n    companion object\n}\n",
    "src/other/User.kt": "package com.example.other\n\nclass User\n",
    "src/lib/Thing.kt": "package com.example.lib\n\nclass Thing\n",
    "src/wild/Wide.kt": "package com.example.wild\n\nclass Wide\n",
    "src/one/Only.java": "package com.example.one;\n\npublic class Only {}\n",
    "src/a/Dup.kt": "package com.example.a\n\nclass Dup\n",
    "src/b/Dup.kt": "package com.example.b\n\nclass Dup\n",
    "src/b/Outside.kt": "package com.example.b\n\nclass Outside\n",
    "build.gradle.kts": "class Script\nval d: Dup? = null\n",
    "src/other/String.kt": "package com.example.other\n\nclass String\n",
]

@Test func resolutionOrder() {
    let ix = index(files)
    let main = "src/app/Main.kt"
    #expect(ix.resolve(["Local"], in: main) == at(main, 8))                          // (a) this file
    #expect(ix.resolve(["User"], in: main) == at("src/model/User.kt", 3))             // (b) import wins over other.User
    #expect(ix.resolve(["LibThing"], in: main) == at("src/lib/Thing.kt", 3))          // (b) alias
    #expect(ix.resolve(["Sibling"], in: main) == at("src/app/Sibling.kt", 3))         // (c) same package
    #expect(ix.resolve(["Wide"], in: main) == at("src/wild/Wide.kt", 3))              // (d) wildcard
    // a file with a package: a name (a)–(d) miss is a default import or from outside, never another package
    #expect(ix.resolve(["Only"], in: main) == .none)
    #expect(ix.resolve(["String"], in: main) == .none)                                // kotlin.String, not other.String
    #expect(ix.resolve(["Dup"], in: main) == .none)
    // (e) only without a package: a script, or a file not scanned
    let script = "build.gradle.kts"
    #expect(ix.resolve(["Only"], in: script) == at("src/one/Only.java", 3))           // (e) unique in the workspace
    #expect(ix.resolve(["Script"], in: script) == at(script, 1))                      // .kts scanned, (a)
    #expect(ix.resolve(["Dup"], in: script) == .many([CodeLocation(path: "src/a/Dup.kt", line: 3),
                                                      CodeLocation(path: "src/b/Dup.kt", line: 3)]))  // (e) two: many
    #expect(ix.resolve(["count"], in: main) == .none)                                 // (f)
    // an explicit import outside the workspace is final: never another type of that name
    #expect(ix.resolve(["Outside"], in: main) == .none)
    // a file the index does not know (deleted, unreadable): only (e)
    #expect(ix.resolve(["Only"], in: "deleted/Gone.kt") == at("src/one/Only.java", 3))
}

@Test func dottedNames() {
    let ix = index(files)
    let main = "src/app/Main.kt"
    #expect(ix.resolve(["com", "example", "other", "User"], in: main) == at("src/other/User.kt", 3))  // FQN first
    #expect(ix.resolve(["User", "Inner"], in: main) == at("src/model/User.kt", 4))                    // nested via the import
    #expect(ix.resolve(["com", "example", "model", "User", "Inner"], in: main) == at("src/model/User.kt", 4))
    #expect(ix.resolve(["value", "Sibling"], in: main) == at("src/app/Sibling.kt", 3))                // a receiver: the last name
    #expect(dottedName(in: "val x = com.example.model.User.Inner()", at: 31) == ["com", "example", "model", "User", "Inner"])
    #expect(dottedName(in: "val x = com.example.model.User.Inner()", at: 26) == ["com", "example", "model", "User"])
    #expect(dottedName(in: "a?.B", at: 3) == ["B"])
    #expect(dottedName(in: "a . b", at: 4) == ["b"])
}

/// The cache lists files with git and rescans only what changed.
@Test func theCacheRescansOnlyChangedFiles() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "decl-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url.appending(path: "src"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let dir = String(cString: realpath(url.path, nil))
    _ = try runCommand(["git", "-C", dir, "init", "-q"], timeout: 30, env: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    try "package com.example\nclass A\n".write(toFile: dir + "/src/A.kt", atomically: true, encoding: .utf8)
    try "package com.example;\nclass B {}\n".write(toFile: dir + "/src/B.java", atomically: true, encoding: .utf8)
    try "class NotSource\n".write(toFile: dir + "/src/C.txt", atomically: true, encoding: .utf8)
    try "ignored/\n".write(toFile: dir + "/.gitignore", atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(atPath: dir + "/ignored", withIntermediateDirectories: true)
    try "class Ignored\n".write(toFile: dir + "/ignored/I.kt", atomically: true, encoding: .utf8)

    let cache = DeclIndexCache()
    let first = cache.index(toplevel: dir)
    #expect(Set(first.files.keys) == ["src/A.kt", "src/B.java"])
    #expect(cache.scans == 2)
    _ = cache.index(toplevel: dir)
    #expect(cache.scans == 2)
    try "package com.example\nclass A\nclass A2\n".write(toFile: dir + "/src/A.kt", atomically: true, encoding: .utf8)
    let third = cache.index(toplevel: dir)
    #expect(cache.scans == 3)
    #expect(third.resolve(["A2"], in: "src/B.java") == .found(CodeLocation(path: "src/A.kt", line: 3)))
    try FileManager.default.removeItem(atPath: dir + "/src/B.java")
    #expect(cache.index(toplevel: dir).files.keys.sorted() == ["src/A.kt"])
}
