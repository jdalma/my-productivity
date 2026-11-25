import Foundation
import Testing
import TowerCore
@testable import TowerApp

// A task board text's file:line places as links (G4 I12): over the characters written, code spans included, and
// only where the place resolves.

@Test func aPlaceIsALinkOverWhatWasWrittenAndAnUnknownOneStaysText() {
    let resolve: (FileRef) -> FileTarget? = { $0.path == "X.swift" ? .file(path: "/w/X.swift", line: $0.lineStart) : nil }
    let (shown, targets) = linkedRefs("고칠 곳 `X.swift:12`, 그리고 Y.swift:3 **굵게**", resolve: resolve)
    #expect(String(shown.characters) == "고칠 곳 X.swift:12, 그리고 Y.swift:3 굵게")
    #expect(targets == [.file(path: "/w/X.swift", line: 12)])
    let linked = shown.runs.filter { $0.link != nil }.map { String(shown[$0.range].characters) }
    #expect(linked == ["X.swift:12"])
    #expect(shown.runs.first { $0.link != nil }?.link == URL(string: "ctref://open/0"))
}

@Test func aWebLinkStaysAndNoOtherSchemeIsLetIn() {
    let (shown, targets) = linkedRefs("[문서](https://example.com/a.md:3) [x](file:///etc/passwd)", resolve: { _ in .file(path: "/w/a.md", line: 3) })
    #expect(targets.isEmpty)  // the URL is blanked out before places are read
    #expect(shown.runs.compactMap(\.link) == [URL(string: "https://example.com/a.md:3")!])
}

/// R34 L1: the ranges of one sed share its characters: the first is the link, the rest are not lost to it.
@Test func placesWrittenInTheSameCharactersMakeOneLink() {
    let (shown, targets) = linkedRefs("git show abc1234:lib/a.swift | sed -n '2,3p;9p'", resolve: { .file(path: "/w/a.swift", line: $0.lineStart) })
    #expect(targets == [.file(path: "/w/a.swift", line: 2)])
    #expect(shown.runs.compactMap(\.link) == [URL(string: "ctref://open/0")!])
}
