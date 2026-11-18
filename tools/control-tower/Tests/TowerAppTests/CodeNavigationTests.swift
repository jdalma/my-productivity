import AppKit
import SwiftUI
import Testing
@testable import TowerCore
@testable import TowerApp

/// TextKit finds the character under a point the way the monospaced line draws it; past the end is nil.
@MainActor @Test func aPointMapsToTheCharacterUnderIt() {
    let font = codeFont(scale: 1)
    let w = ("a" as NSString).size(withAttributes: [.font: font]).width
    let lh = NSLayoutManager().defaultLineHeight(for: font)
    let text = "val a.b = List<T>()"
    func at(_ i: Double) -> Int? {
        characterIndex(at: CGPoint(x: w * i, y: 2), in: text, font: font, width: 1000, height: lh)
    }
    #expect(at(0.5) == 0)
    #expect(at(4.5) == 4)
    #expect(at(4.95) == 4)                       // the right edge of a character is still that character
    #expect(at(Double(text.count) - 0.5) == text.count - 1)
    #expect(at(Double(text.count) + 0.5) == nil)  // past the line's end
    #expect(characterIndex(at: .zero, in: "", font: font, width: 100, height: lh) == nil)
    // wrapped at 10 characters: the second visual line starts at the 11th
    let wrapped = characterIndex(at: CGPoint(x: w * 0.5, y: lh * 1.5), in: "abcdefghijklmnop", font: font, width: w * 10, height: lh * 2)
    #expect(wrapped == 10)
    // a character past the BMP and a Hangul syllable count as one Character each
    let wide = "😀가b"
    let bx = ("😀가" as NSString).size(withAttributes: [.font: font]).width
    #expect(characterIndex(at: CGPoint(x: bx + w / 2, y: 2), in: wide, font: font, width: 1000, height: lh) == 2)
}

@MainActor @Test func onlyACommandClickOnAHoveredLineIsTaken() {
    var opened = 0
    CommandClick.target = nil
    #expect(!CommandClick.handle(.leftMouseDown, clickCount: 1, flags: .command))  // nothing hovered
    let id = UUID()
    CommandClick.hover(.init(id: id, open: { opened += 1 }, refresh: {}))
    #expect(!CommandClick.handle(.leftMouseDown, clickCount: 1, flags: []))          // selection's click
    #expect(!CommandClick.handle(.leftMouseDown, clickCount: 1, flags: [.command, .shift]))
    #expect(!CommandClick.handle(.leftMouseDown, clickCount: 2, flags: .command))
    #expect(opened == 0)
    #expect(CommandClick.handle(.leftMouseDown, clickCount: 1, flags: [.command, .capsLock]))
    #expect(opened == 1)
    CommandClick.leave(UUID())  // another line leaving keeps this one
    #expect(CommandClick.target != nil)
    CommandClick.leave(id)
    #expect(CommandClick.target == nil)
}

@MainActor @Test func historyFollowsTheWorkspaceAndTheTree() {
    let s = ChangesState()
    s.select(workspace: "/w1")
    s.open(CodeLocation(path: "A.kt", line: 3))
    #expect(s.history.current == CodeLocation(path: "A.kt", line: 3))
    s.select(workspace: "/w1")
    #expect(s.history.current != nil)  // the same workspace keeps it
    s.reveal(DiffFileKey(part: .uncommitted, path: "B.kt"))
    #expect(s.history.current == nil && s.history.canGoForward)  // a tree click shows the diff
    s.select(workspace: "/w2")
    #expect(s.history == CodeHistory())
}

/// A navigating line draws exactly as before: the Command-click support adds nothing visible.
@MainActor @Test func aNavigatingLineLooksTheSame() throws {
    var line = DiffLine(kind: .added, old: nil, new: 4, text: "let a = b.c")
    line.changes = [4..<5]
    line.syntax = [SyntaxSpan(range: 0..<3, kind: .keyword)]
    func pixels(_ target: CodeLocation?) throws -> Data {
        let r = ImageRenderer(content: LineView(line: line, target: target).frame(width: 400).environment(\.colorScheme, .dark))
        r.scale = 1
        return try #require(r.nsImage).tiffRepresentation!
    }
    #expect(try pixels(nil) == pixels(CodeLocation(path: "a.swift", line: 4)))
}

/// The premise of `characterIndex`: every character `Text` draws in the diff font, wrapped or not and at
/// fractional scales, maps back to itself. Each probed character is drawn alone in black; the center of its
/// ink goes through `characterIndex` with the text's own size, as `LineView` measures it.
@MainActor @Test func everyDrawnCharacterMapsBackToItself() throws {
    let texts = [
        "val result = repository.findAllByOwnerIdAndStatus(ownerId, Status.ACTIVE).map { it.toDto() }",
        "// 사용자 목록을 불러온 뒤 상태가 활성인 항목만 남긴다 그리고 이름순으로 정렬한다",
        "String 이름 = user.getName(); // 한글 mixed 식별자 테스트 값",
    ]
    var total = 0, bad: [String] = []
    for scale in [0.8, 1.0, 1.3] {
        for width in [120.0, 2000.0] {
            for text in texts {
                func view(_ k: Int?) -> some View {
                    var a = AttributedString(text)
                    a.foregroundColor = .white
                    if let k {
                        let lo = a.characters.index(a.startIndex, offsetBy: k)
                        a[lo..<a.characters.index(after: lo)].foregroundColor = .black
                    }
                    return Text(a).scaledFont(.callout, design: .monospaced).environment(\.boardFontScale, scale)
                }
                let size = NSHostingController(rootView: view(nil).fixedSize(horizontal: false, vertical: true))
                    .sizeThatFits(in: CGSize(width: width, height: .infinity))
                let chars = Array(text)
                for k in stride(from: 0, to: chars.count, by: 3) where !chars[k].isWhitespace {
                    let r = ImageRenderer(content: view(k).frame(width: size.width, height: size.height, alignment: .topLeading).background(.white))
                    r.scale = 1
                    let rep = NSBitmapImageRep(cgImage: try #require(r.cgImage))
                    var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
                    for y in 0..<rep.pixelsHigh {
                        for x in 0..<rep.pixelsWide where rep.colorAt(x: x, y: y)!.brightnessComponent < 0.6 {
                            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                        }
                    }
                    guard maxX >= 0 else { continue }  // too little ink, a period
                    total += 1
                    let p = CGPoint(x: Double(minX + maxX) / 2 + 0.5, y: Double(minY + maxY) / 2 + 0.5)
                    let hit = characterIndex(at: p, in: text, font: codeFont(scale: scale), width: size.width, height: size.height)
                    if hit != k { bad.append("scale \(scale) width \(width) '\(chars[k])' \(k) → \(hit.map(String.init) ?? "nil")") }
                }
            }
        }
    }
    #expect(total > 200)
    #expect(bad.isEmpty, "\(bad.count) of \(total): \(bad.prefix(5))")
}

/// A Command-click: a type opens its declaration, recording the file-view line it left; otherwise the
/// diff opens the line and the file view says it found nothing; several candidates are only counted.
@MainActor @Test func aCommandClickFollowsTypes() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "click-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    let dir = String(cString: realpath(url.path, nil))
    _ = try runCommand(["git", "-C", dir, "init", "-q"], timeout: 30, env: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
    let sources = ["Main.kt": "package com.example\n\nval u = User()\n", "User.kt": "package com.example\n\nclass User\n",
                   "a/Dup.kt": "package com.example.a\nclass Dup\n", "b/Dup.kt": "package com.example.b\nclass Dup\n"]
    for (p, text) in sources {
        try FileManager.default.createDirectory(atPath: (dir + "/" + p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try text.write(toFile: dir + "/" + p, atomically: true, encoding: .utf8)
    }
    let s = ChangesState()
    s.select(workspace: dir)
    s.accept(Loaded(workspace: dir, result: .diff(WorkspaceDiff(toplevel: dir, base: .none, committed: nil,
                                                                 uncommitted: DiffSection(files: [], untracked: []))), candidates: []))
    func settle(_ done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }
    let line3 = CodeLocation(path: "Main.kt", line: 3)
    s.commandClick(line3, name: ["User"])  // from the diff
    await settle { s.history.current != nil }
    #expect(s.history.current == CodeLocation(path: "User.kt", line: 3))
    s.history.back()
    #expect(s.history.current == nil)  // back to the diff

    s.commandClick(line3, name: ["value"])  // not a type, in the diff: the line itself
    #expect(s.history.current == nil)
    await settle { s.history.current != nil }
    #expect(s.history.current == line3)

    s.commandClick(CodeLocation(path: "Main.kt", line: 1), name: ["value"])  // in the file view: a notice, no move
    await settle { s.notice != nil }
    #expect(s.notice == "정의를 찾지 못함" && s.history.current == line3)

    let owner = UUID()
    s.commandClick(CodeLocation(path: "gone.kts", line: 2), name: ["Dup"], owner: owner)  // no package context: (e) counts both
    await settle { s.candidates != nil }
    #expect(s.candidates?.owner == owner && s.candidates?.items.map(\.location.path) == ["a/Dup.kt", "b/Dup.kt"])
    #expect(s.history.current == line3)  // listed, not opened
    s.choose(try #require(s.candidates?.items[1]))
    #expect(s.candidates == nil && s.history.current == CodeLocation(path: "b/Dup.kt", line: 2))
    s.history.back()
    #expect(s.history.current == CodeLocation(path: "gone.kts", line: 2))  // chosen from the file view: back to the click
    s.history.open(line3)

    s.commandClick(CodeLocation(path: "Main.kt", line: 3), name: ["User"])  // from the file view: back returns to line 3
    await settle { s.history.current?.path == "User.kt" }
    s.history.back()
    #expect(s.history.current == line3)
}

/// The list shows 50 and counts the rest.
@MainActor @Test func theCandidateListShowsFifty() {
    let items = (1...73).map { Candidate(location: CodeLocation(path: "F\($0).kt", line: $0), snippet: "fun f()") }
    let page = CandidateListView.page(items)
    #expect(page.shown.count == 50 && page.shown.last?.location.line == 50 && page.more == 23)
    #expect(CandidateListView.page(Array(items.prefix(3))).more == 0)
}
