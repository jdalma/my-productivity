import Testing
@testable import TowerCore
@testable import TowerApp

private func file(_ path: String, _ added: Int = 1, _ removed: Int = 0, binary: Bool = false) -> FileDiff {
    FileDiff(path: path, added: added, removed: removed, binary: binary, lines: [])
}

/// `name` for a file, `name/` then indented children for a directory.
private func outline(_ nodes: [ChangeTreeNode], _ depth: Int = 0) -> [String] {
    nodes.flatMap { n -> [String] in
        let pad = String(repeating: "  ", count: depth)
        switch n.kind {
        case .directory(let children): return ["\(pad)\(n.name)/"] + outline(children, depth + 1)
        case .file: return ["\(pad)\(n.name)"]
        }
    }
}

@Test func filesGroupUnderTheirDirectoriesWithRootFilesLast() {
    let tree = changeTree(DiffSection(files: [file("README.md"), file("src/b.swift"), file("src/a.swift"), file("docs/x.md")],
                                      untracked: []))
    #expect(outline(tree) == ["docs/", "  x.md", "src/", "  a.swift", "  b.swift", "README.md"])
}

@Test func aChainOfSingleChildDirectoriesIsOneLine() {
    let tree = changeTree(DiffSection(files: [file("Sources/TowerApp/Views/A.swift"), file("Sources/TowerApp/Views/B.swift"),
                                              file("Sources/TowerCore/C.swift")], untracked: []))
    #expect(outline(tree) == ["Sources/", "  TowerApp/Views/", "    A.swift", "    B.swift", "  TowerCore/", "    C.swift"])
    #expect(outline(changeTree(DiffSection(files: [file("a/b/c/d.txt")], untracked: []))) == ["a/b/c/", "  d.txt"])
}

@Test func fileNodesKeepTheirFullPathAndChange() {
    let tree = changeTree(DiffSection(files: [file("a/b/x.swift", 3, 2), file("a/b/logo.png", binary: true)],
                                      untracked: ["a/b/new.txt"]))
    guard case .directory(let files) = tree[0].kind else { Issue.record("expected a directory"); return }
    #expect(tree[0].name == "a/b")
    #expect(files.map(\.path) == ["a/b/logo.png", "a/b/new.txt", "a/b/x.swift"])
    #expect(files.map(\.kind) == [.file(.binary), .file(.untracked), .file(.lines(added: 3, removed: 2))])
}

@Test func untrackedFilesJoinTheTreeAndAnEmptySectionHasNone() {
    let tree = changeTree(DiffSection(files: [file("src/a.swift")], untracked: ["src/new.swift", "notes.txt"]))
    #expect(outline(tree) == ["src/", "  a.swift", "  new.swift", "notes.txt"])
    #expect(changeTree(DiffSection(files: [], untracked: [])).isEmpty)
}

@Test func spacesAndQuotedPathCharactersStayInTheName() {
    // FileDiff paths arrive unquoted (Diff.swift); a space or a quote is part of the name.
    let tree = changeTree(DiffSection(files: [file("my dir/a \"b\".txt"), file("my dir/한글 파일.md")], untracked: []))
    #expect(outline(tree) == ["my dir/", "  a \"b\".txt", "  한글 파일.md"])
}

@Test func theSameFileInBothSectionsAppearsInEachTree() {
    let committed = changeTree(DiffSection(files: [file("src/a.swift")], untracked: []))
    let uncommitted = changeTree(DiffSection(files: [file("src/a.swift", 0, 4)], untracked: []))
    #expect(outline(committed) == outline(uncommitted))
    guard case .directory(let c) = committed[0].kind, case .directory(let u) = uncommitted[0].kind else {
        Issue.record("expected directories"); return
    }
    #expect(c[0].kind == .file(.lines(added: 1, removed: 0)))
    #expect(u[0].kind == .file(.lines(added: 0, removed: 4)))
}

@Test func aFileHeaderSplitsItsNameFromItsDirectory() {
    #expect(splitPath("tools/control-tower/Sources/TowerApp/Sidebar.swift") == ("tools/control-tower/Sources/TowerApp/", "Sidebar.swift"))
    #expect(splitPath("README.md") == ("", "README.md"))
}

@Test func zeroCountsAreLeftOut() {
    #expect(changeCounts(added: 3, removed: 0) == ["+3"])
    #expect(changeCounts(added: 0, removed: 2) == ["−2"])
    #expect(changeCounts(added: 1, removed: 1) == ["+1", "−1"])
    #expect(changeCounts(added: 0, removed: 0) == [])
}

@Test func tabsShowAsFourSpaces() {
    #expect(displayLine("\tif x {\t// y") == "    if x {    // y")
    #expect(displayLine("plain") == "plain")
}
