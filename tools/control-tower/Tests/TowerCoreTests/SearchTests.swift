import Foundation
import Testing
@testable import TowerCore

// MARK: - git grep's output

@Test func grepOutputIsReadAsPathLineAndText() {
    let out = "src/a.swift\u{0}12\u{0}let a = 1\nnotes/10:30 plan.md\u{0}3\u{0}at 10:30: start\nx\u{0}7\u{0}\n"
    #expect(parseGrep(out) == [
        SearchHit(path: "src/a.swift", line: 12, text: "let a = 1"),
        // a colon in the path or the text splits nothing: the fields end at NUL
        SearchHit(path: "notes/10:30 plan.md", line: 3, text: "at 10:30: start"),
        SearchHit(path: "x", line: 7, text: ""),
    ])
    #expect(parseGrep("") == [])
}

@Test func aHitCutOffByTheOutputLimitIsLeftOut() {
    #expect(parseGrep("a\u{0}1\u{0}one\nb\u{0}2\u{0}tw").map(\.path) == ["a"])
    #expect(parseGrep("a\u{0}1\u{0}one\nb\u{0}2").map(\.path) == ["a"])
    #expect(parseGrep("a\u{0}1\u{0}one\nb").map(\.path) == ["a"])
}

@Test func aLongLineIsCut() {
    let hit = parseGrep("min.js\u{0}1\u{0}" + String(repeating: "x", count: searchLineLimit + 50) + "\n")
    #expect(hit.first?.text.count == searchLineLimit)
    // characters, not bytes
    let wide = parseGrep("ko.md\u{0}1\u{0}" + String(repeating: "가", count: searchLineLimit + 50) + "\n")
    #expect(wide.first?.text == String(repeating: "가", count: searchLineLimit))
}

/// R25 M1: a Character holds CR LF as one, so a parser that looks for "\n" in the String joined these into one hit.
@Test func aCRLFLineEndsAHitAndIsNotPartOfItsText() {
    let out = "crlf.txt\u{0}1\u{0}needle one\r\ncrlf.txt\u{0}2\u{0}needle two\r\nlf.txt\u{0}1\u{0}needle three\nblank.txt\u{0}4\u{0}\r\n"
    #expect(parseGrep(out) == [
        SearchHit(path: "crlf.txt", line: 1, text: "needle one"),
        SearchHit(path: "crlf.txt", line: 2, text: "needle two"),
        SearchHit(path: "lf.txt", line: 1, text: "needle three"),
        SearchHit(path: "blank.txt", line: 4, text: ""),
    ])
    // a CR inside the line is the line's
    #expect(parseGrep("a\u{0}1\u{0}one\rtwo\n").first?.text == "one\rtwo")
}

/// R25 S1: the output cut off inside a line longer than a hit shows is that hit, not nothing.
@Test func aCutOffLineLongerThanAHitShowsIsStillAHit() {
    let long = String(repeating: "x", count: searchLineLimit + 1)
    #expect(parseGrep("a\u{0}1\u{0}one\nmin.js\u{0}1\u{0}" + long) == [
        SearchHit(path: "a", line: 1, text: "one"),
        SearchHit(path: "min.js", line: 1, text: String(long.prefix(searchLineLimit))),
    ])
    // shorter than that, its end is not known: left out
    #expect(parseGrep("min.js\u{0}1\u{0}" + String(repeating: "x", count: searchLineLimit - 1)).isEmpty)
}

// MARK: - A search in a repository

/// A repository that reads no git configuration of the user's, with `files` written and those in `tracked` committed.
private func repo(_ files: [String: String], tracked: Set<String>) throws -> String {
    let url = FileManager.default.temporaryDirectory.appending(path: "tower-search-\(UUID().uuidString)")
    for (path, text) in files {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    let env = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
    func git(_ args: [String]) throws {
        let r = try runCommand(["git", "-C", url.path, "-c", "user.name=Example", "-c", "user.email=example@example.invalid",
                                "-c", "commit.gpgsign=false"] + args, timeout: 30, env: env)
        guard r.status == 0 else { throw CommandError(description: r.stderr) }
    }
    try git(["init", "-q", "-b", "main"])
    try git(["add", "--"] + tracked.sorted())
    try git(["commit", "-q", "-m", "base"])
    return url.path
}

@Test func aSearchFindsTheQueryAsTypedInTrackedAndUntrackedFiles() throws {
    let dir = try repo([
        "src/a.swift": "let total = 1\nlet Total2 = a.b(c)\n",
        "src/new.swift": "// total, untracked\n",
        "build/out.txt": "total, ignored\n",
        "bin.dat": "total\u{0}binary\n",
        ".gitignore": "build/\n",
        "-e.txt": "--untracked is a flag\n",
    ], tracked: ["src/a.swift", ".gitignore", "bin.dat", "-e.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }

    // any case; the ignored folder and the binary file are left out
    #expect(searchText("total", in: dir) == SearchResult(hits: [
        SearchHit(path: "src/a.swift", line: 1, text: "let total = 1"),
        SearchHit(path: "src/a.swift", line: 2, text: "let Total2 = a.b(c)"),
        SearchHit(path: "src/new.swift", line: 1, text: "// total, untracked"),
    ], more: false))
    // no pattern: `.` and `(` are themselves
    #expect(searchText("a.b(c", in: dir)?.hits.map(\.line) == [2])
    #expect(searchText("a.c", in: dir)?.hits == [])
    // a query that looks like an option is searched for, not obeyed
    #expect(searchText("--untracked", in: dir)?.hits.map(\.path) == ["-e.txt"])
    // from a folder inside: only that folder, paths from it
    #expect(searchText("total", in: dir + "/src")?.hits.map(\.path) == ["a.swift", "a.swift", "new.swift"])

    #expect(searchText("no such words here", in: dir) == SearchResult(hits: [], more: false))
    #expect(searchText("", in: dir) == SearchResult(hits: [], more: false))
}

/// R25 M1, in a repository: CRLF files, and a file that is not UTF-8.
@Test func aSearchReadsCRLFFilesLineByLine() throws {
    let dir = try repo(["crlf.txt": "needle one\r\nother\r\nneedle three\r\n", "lf.txt": "needle lf\n"], tracked: ["crlf.txt", "lf.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try Data([0x6E, 0x65, 0x65, 0x64, 0x6C, 0x65, 0x20, 0xE9, 0x0A]).write(to: URL(fileURLWithPath: dir + "/latin.txt"))  // "needle é" in Latin-1
    #expect(searchText("needle", in: dir)?.hits == [
        SearchHit(path: "crlf.txt", line: 1, text: "needle one"),
        SearchHit(path: "crlf.txt", line: 3, text: "needle three"),
        SearchHit(path: "latin.txt", line: 1, text: "needle \u{FFFD}"),
        SearchHit(path: "lf.txt", line: 1, text: "needle lf"),
    ])
}

/// R25 S1: a minified file's line, longer than what the hits of `limit` lines take, before every other hit.
@Test func aVeryLongLineAmongTheFirstHitsLeavesTheHitsAfterIt() throws {
    let long = "var needle=" + String(repeating: "x", count: 400_000) + "\n"
    let dir = try repo(["a.min.js": long, "b.txt": "needle here\n", "c.txt": "needle there\n"], tracked: ["a.min.js", "b.txt", "c.txt"])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let r = try #require(searchText("needle", in: dir))
    #expect(r.hits.map(\.path) == ["a.min.js", "b.txt", "c.txt"] && !r.more)
    #expect(r.hits[0].text.count == searchLineLimit)

    // a line past the whole read: that line's start is the one hit, and more is true
    let huge = "var needle=" + String(repeating: "x", count: 3 << 20) + "\n"
    try huge.write(toFile: dir + "/a.min.js", atomically: true, encoding: .utf8)
    let cut = try #require(searchText("needle", in: dir))
    #expect(cut.hits.map(\.path) == ["a.min.js"] && cut.more)
}

@Test func aSearchOutsideARepositoryFails() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tower-search-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try "total\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
    // GIT_CEILING_DIRECTORIES is not set for the app's git: the temporary folder is in no repository
    #expect(searchText("total", in: dir) == nil)
}

/// A query in every line of a large tree: the read stops near the limit, and the call returns without the rest.
@Test func aSearchWithTooManyHitsStopsAtTheLimit() throws {
    let line = "the same words on every line of this file, again and again\n"
    var files: [String: String] = [:]
    for i in 0..<40 { files["f\(i).txt"] = String(repeating: line, count: 5_000) }  // 200,000 hits, 12 MB of output
    let dir = try repo(files, tracked: Set(files.keys))
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let started = Date()
    let r = try #require(searchText("same words", in: dir, limit: 20))
    #expect(r.hits.count == 20 && r.more)
    #expect(r.hits.allSatisfy { $0.text == String(line.dropLast()) })
    #expect(Date().timeIntervalSince(started) < 5, "git ended at the closed output, not at the last file")

    let all = try #require(searchText("same words", in: dir, limit: 300_000))
    #expect(all.hits.count == 200_000 && !all.more)
}

// MARK: - Quick open

@Test func aFuzzyMatchNeedsEveryCharacterInOrder() {
    #expect(fuzzyScore("dw", "Sources/TowerApp/DiffWindow.swift") != nil)
    #expect(fuzzyScore("DIFFWINDOW", "Sources/TowerApp/DiffWindow.swift") != nil)
    #expect(fuzzyScore("diff window", "Sources/TowerApp/DiffWindow.swift") != nil, "spaces are skipped")
    #expect(fuzzyScore("wd", "dw.txt") == nil, "in order")
    #expect(fuzzyScore("xyz", "Sources/TowerApp/DiffWindow.swift") == nil)
    #expect(fuzzyScore("", "a.swift") == nil)
    #expect(fuzzyScore("  ", "a.swift") == nil)
}

@Test func theFileNameCountsMoreThanTheFoldersAndLettersInARowMoreThanScattered() throws {
    func score(_ q: String, _ p: String) throws -> Int { try #require(fuzzyScore(q, p)) }
    // in the name over in a folder
    #expect(try score("search", "core/Search.swift") > score("search", "search/core/Index.swift"))
    // one piece over scattered letters
    #expect(try score("diff", "app/DiffWindow.swift") > score("diff", "app/DashboardInfoFooFile.swift"))
    // word starts over the middle of words
    #expect(try score("cv", "app/CodeView.swift") > score("cv", "app/Recover.swift"))
    // the shorter path of two equal matches
    #expect(try score("a.swift", "a.swift") > score("a.swift", "deep/er/folder/a.swift"))
}

@Test func quickOpenListsTheBestFilesFirstAndNoMoreThanTheLimit() {
    let files = ["README.md", "Sources/TowerCore/Diff.swift", "Sources/TowerApp/DiffWindow.swift", "Sources/TowerApp/DiffColors.swift",
                 "Tests/TowerCoreTests/DiffTests.swift", "docs/different/notes.md"]
    #expect(quickOpen("diff", files: files) == [
        "Sources/TowerCore/Diff.swift", "Sources/TowerApp/DiffColors.swift", "Sources/TowerApp/DiffWindow.swift",
        "Tests/TowerCoreTests/DiffTests.swift", "docs/different/notes.md",
    ])
    // Diff.swift answers too (the w of swift), far below the name that holds the query in one piece
    #expect(quickOpen("diffw", files: files).first == "Sources/TowerApp/DiffWindow.swift")
    #expect(quickOpen("diffwin", files: files) == ["Sources/TowerApp/DiffWindow.swift"])
    #expect(quickOpen("diff", files: files, limit: 2).count == 2)
    #expect(quickOpen("", files: files) == [])
}

// MARK: - A real worktree, by hand

/// `CT_SEARCH_BENCH=<worktree> swift test --filter searchingARealWorktree`: how long a search and a quick open take
/// there (G4 I10: about a second in a repository of orca's size). Not run without the variable.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CT_SEARCH_BENCH"] != nil))
func searchingARealWorktree() throws {
    let dir = try #require(ProcessInfo.processInfo.environment["CT_SEARCH_BENCH"])
    func timed<T>(_ what: String, _ body: () -> T) -> T {
        let started = Date()
        let r = body()
        print("CT_SEARCH_BENCH \(what): \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        return r
    }
    let files = try #require(timed("list files") { workspaceFiles(toplevel: dir, scope: "") })
    print("CT_SEARCH_BENCH files: \(files.count)")
    for q in (ProcessInfo.processInfo.environment["CT_SEARCH_QUERIES"] ?? "useState,e,zzzz no such words").split(separator: ",").map(String.init) {
        let r = try #require(timed("search '\(q)'") { searchText(q, in: dir) })
        print("CT_SEARCH_BENCH   hits \(r.hits.count) more \(r.more)")
    }
    for q in ["main", "srcindex", "e"] {
        let r = timed("quick open '\(q)'") { quickOpen(q, files: files) }
        print("CT_SEARCH_BENCH   first \(r.first ?? "-")")
    }
}
