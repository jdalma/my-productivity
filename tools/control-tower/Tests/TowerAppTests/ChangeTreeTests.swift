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

private func diff(committed: [FileDiff]? = nil, uncommitted: [FileDiff] = [], untracked: [String] = []) -> WorkspaceDiff {
    WorkspaceDiff(toplevel: "/w", base: .none, committed: committed.map { DiffSection(files: $0, untracked: []) },
                  uncommitted: DiffSection(files: uncommitted, untracked: untracked))
}

/// Every file of `nodes` with its change, folders as `name/`.
private func changes(_ nodes: [ChangeTreeNode]) -> [String: FileChange] {
    var out: [String: FileChange] = [:]
    func walk(_ ns: [ChangeTreeNode]) {
        for n in ns {
            switch n.kind {
            case .directory(let c): walk(c)
            case .file(let ch): out[n.path] = ch
            }
        }
    }
    walk(nodes)
    return out
}

@Test func theFullTreeNestsEveryListedFileAndMarksTheChangedOnes() {
    let d = diff(committed: [file("src/a.swift", 2, 1), file("src/both.swift", 9, 9)],
                 uncommitted: [file("src/both.swift", 1, 0), file("gone.txt", 0, 3)], untracked: ["src/new.swift"])
    // gone.txt was deleted and staged: the list no longer has it
    let tree = folderTree(files: ["README.md", "src/a.swift", "src/both.swift", "src/new.swift", "src/deep/x/y.swift"], diff: d)
    #expect(outline(tree) == ["src/", "  deep/x/", "    y.swift", "  a.swift", "  both.swift", "  new.swift", "README.md", "gone.txt"])
    #expect(changes(tree) == [
        "README.md": .unchanged, "src/deep/x/y.swift": .unchanged,
        "src/a.swift": .lines(added: 2, removed: 1),
        "src/both.swift": .lines(added: 1, removed: 0),  // the work tree's change over the committed one
        "src/new.swift": .untracked, "gone.txt": .lines(added: 0, removed: 3),
    ])
}

@Test func theFoldersHoldingAChangeAreTheOnesTheFullTreeOpens() {
    let d = diff(committed: [file("a/b/c.swift")], untracked: ["x/y.txt", "top.txt"])
    #expect(changedFolders(d) == ["a", "a/b", "x"])
    #expect(changedFolders(diff()) == [])
}

@Test func aFolderNodeListsItsChildrenAndAFileNone() {
    let tree = folderTree(files: ["lib/x.swift", "lib/y.swift", "README.md"], diff: diff())
    #expect(tree.map { $0.name } == ["lib", "README.md"])
    #expect(tree[0].children?.map { $0.path } == ["lib/x.swift", "lib/y.swift"])
    #expect(tree[1].children == nil)
    #expect(tree[0].children?[0].children == nil)
}

@Test func aTreeLineIsUniqueAcrossSectionsAndModes() throws {
    let node = try #require(changeTree(diff(uncommitted: [file("src/a.swift")]).uncommitted).first)
    let lines = [TreeLine(node, part: .committed), TreeLine(node, part: .uncommitted), TreeLine(node, part: nil)]
    #expect(Set(lines).count == 3)
    #expect(lines.map(\.id) == ["c:src", "u:src", "a:src"])
    #expect(lines.allSatisfy { $0.isFolder })
    let leaf = try #require(node.children?.first)
    #expect(TreeLine(leaf, part: nil) == TreeLine.file("src/a.swift"))
}

extension TreeLine {
    static func file(_ path: String, part: DiffPart? = nil) -> TreeLine {
        TreeLine(ChangeTreeNode(name: path, path: path, kind: .file(.unchanged)), part: part)
    }
}
