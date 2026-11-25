import Foundation
import Testing
import TowerCore
@testable import TowerApp

@Test func aBlankQueryFindsNothingAndReadsNothing() {
    #expect(search(.files, "  ", in: "/no/such/folder", files: nil).found == .idle)
    #expect(search(.text, "", in: "/no/such/folder", files: nil).found == .idle)
    #expect(SearchFound.idle.first == nil)
}

@Test func aQuickOpenUsesTheListItWasGivenAndReturnsIt() {
    let files = ["docs/guide.md", "src/main.swift"]
    // no git here: the folder does not exist, the list is enough
    let r = search(.files, "main", in: "/no/such/folder", files: files)
    #expect(r.found == .files(["src/main.swift"]))
    #expect(r.files == files)
    #expect(r.found.first?.path == "src/main.swift" && r.found.first?.line == nil)
}

@Test func aFolderInNoRepositoryFailsBothSearches() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "tower-panel-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    #expect(search(.files, "a", in: dir, files: nil).found == .failed)
    #expect(search(.text, "a", in: dir, files: nil).found == .failed)
}

@Test func returnOpensTheFirstTextHitAtItsLine() {
    let hits = [SearchHit(path: "a.swift", line: 12, text: "let a"), SearchHit(path: "b.swift", line: 3, text: "let a")]
    let first = SearchFound.text(SearchResult(hits: hits, more: false)).first
    #expect(first?.path == "a.swift" && first?.line == 12)
    #expect(SearchFound.failed.first == nil)
}
