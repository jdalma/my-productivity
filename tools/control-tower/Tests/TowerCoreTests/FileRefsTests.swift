import Foundation
import Testing
@testable import TowerCore

// Locations in a finding's summary or repro, a landing's focus or a report (G4 W1, W6). The texts below are findings
// and focus lines as the task board held them (my-team families T1 to T12); folder names are generic.

private func ref(_ path: String, _ start: Int, _ end: Int? = nil, at commit: String? = nil) -> FileRef {
    FileRef(path: path, lineStart: start, lineEnd: end, commit: commit)
}

// MARK: - git show <rev>:<path> | sed -n

@Test func aGitShowPipedToSedIsTheFileAtThatCommit() {
    #expect(fileRefs(in: "git -C /work/repo show 6c0ca46:tools/my-team/package.json | cat -n | sed -n 10,19p")
            == [ref("tools/my-team/package.json", 10, 19, at: "6c0ca46")])
    #expect(fileRefs(in: "git -C /work/repo show 6c0ca46:tools/control-tower/Sources/TowerApp/TeamLaunch.swift | sed -n 93,101p")
            == [ref("tools/control-tower/Sources/TowerApp/TeamLaunch.swift", 93, 101, at: "6c0ca46")])
    #expect(fileRefs(in: "git show 6c0ca46:tools/my-team/src/lib/startup-notice.js | sed -n 29,32p")
            == [ref("tools/my-team/src/lib/startup-notice.js", 29, 32, at: "6c0ca46")])
}

@Test func aSedScriptOfSeveralRangesGivesOneRefEach() {
    #expect(fileRefs(in: #"git -C /work/repo show 6c0ca46:tools/my-team/src/commands/_manifest.js | sed -n 10,12p\;37,46p; 리포트 §3 S1 node 스크립트"#)
            == [ref("tools/my-team/src/commands/_manifest.js", 10, 12, at: "6c0ca46"),
                ref("tools/my-team/src/commands/_manifest.js", 37, 46, at: "6c0ca46")])
    let three = "git show 6c0ca46:tools/control-tower/Sources/TowerApp/BoardView.swift | sed -n '41,42p'; "
        + "git show 6c0ca46:tools/control-tower/Sources/TowerApp/FileEditor.swift | sed -n '74,81p;94,95p'; "
        + "git show 6c0ca46:tools/control-tower/Sources/TowerApp/PaneTerminal.swift | sed -n '270p'"
    #expect(fileRefs(in: three) == [
        ref("tools/control-tower/Sources/TowerApp/BoardView.swift", 41, 42, at: "6c0ca46"),
        ref("tools/control-tower/Sources/TowerApp/FileEditor.swift", 74, 81, at: "6c0ca46"),
        ref("tools/control-tower/Sources/TowerApp/FileEditor.swift", 94, 95, at: "6c0ca46"),
        ref("tools/control-tower/Sources/TowerApp/PaneTerminal.swift", 270, at: "6c0ca46"),
    ])
}

@Test func aSedOfAFileNamesThatFile() {
    #expect(fileRefs(in: "sed -n '198,234p' /work/repo/docs/analysis/control-tower-ide-feasibility.md")
            == [ref("/work/repo/docs/analysis/control-tower-ide-feasibility.md", 198, 234)])
    #expect(fileRefs(in: "sed -n '12p;74,80p;230p' ~/.my-team/docs/my-team/reports/T9-ct-ide-paths.md | cut -c1-80")
            == [ref("~/.my-team/docs/my-team/reports/T9-ct-ide-paths.md", 12),
                ref("~/.my-team/docs/my-team/reports/T9-ct-ide-paths.md", 74, 80),
                ref("~/.my-team/docs/my-team/reports/T9-ct-ide-paths.md", 230)])
    #expect(fileRefs(in: #"cd tools/control-tower && grep -c "@Test" Tests/TowerCoreTests/*.swift | awk -F: '{s+=$2} END{print s}'; sed -n '22,26p' Sources/TowerCore/Syntax.swift"#)
            == [ref("Sources/TowerCore/Syntax.swift", 22, 26)])
}

@Test func aSedWithNoFileAndNoGitShowBeforeItIsNoRef() {
    #expect(fileRefs(in: "cat notes.txt | sed -n 3,4p").isEmpty)
    // a git show in an earlier command of the line is not what this sed reads
    #expect(fileRefs(in: "git show 6c0ca46:a/b.swift; echo x | sed -n 3,4p").isEmpty)
    #expect(fileRefs(in: "git -C /work/repo grep -n detached 6c0ca46 -- tools/my-team/src").isEmpty)
}

// MARK: - path:line

@Test func aPathAndLineAndItsRange() {
    #expect(fileRefs(in: "History.swift:315 접두어 Team is live 확장이 다른 prompt를 member로 오인하지 않는지") == [ref("History.swift", 315)])
    #expect(fileRefs(in: "§2 LSP 없음 + TS 진단 의도적 비활성(monaco-setup.ts:59), 정의 이동은 codebase search") == [ref("monaco-setup.ts", 59)])
    #expect(fileRefs(in: "package.json 인용 drift: 19-21→17-19, 13-14→11").isEmpty)  // no line after the name
    #expect(fileRefs(in: "loadManifest가 MY_TEAM_STATE_ROOT를 안 봄(_manifest.js:10-12,37-40). 6-7 추론 태그 제거")
            == [ref("_manifest.js", 10, 12), ref("_manifest.js", 37, 40)])
    #expect(fileRefs(in: "- 분할 구현: tools/control-tower/Sources/TowerApp/TaskBoardView.swift:925-1080 (SplitLimits)")
            == [ref("tools/control-tower/Sources/TowerApp/TaskBoardView.swift", 925, 1080)])
}

@Test func moreLinesOfTheSameFileAfterACommaOrAnArrow() {
    #expect(fileRefs(in: "'0700 dirs, 0600 files' 틀림: AGENTS.md·guard-settings 0644 (start.js:174,338,357 mode 없음)")
            == [ref("start.js", 174), ref("start.js", 338), ref("start.js", 357)])
    #expect(fileRefs(in: "인용 줄 어긋남 4건: BoardView.swift:42→41(최소 크기, 두 곳), PaneTerminal.swift:273→270(firstResponder 판정), "
                     + "FileEditor.swift:78-85→74-81(workspaceOpen), FileEditor.swift:91-93→94-95(dry-run 기록)")
            == [ref("BoardView.swift", 42), ref("BoardView.swift", 41), ref("PaneTerminal.swift", 273), ref("PaneTerminal.swift", 270),
                ref("FileEditor.swift", 78, 85), ref("FileEditor.swift", 74, 81), ref("FileEditor.swift", 91, 93), ref("FileEditor.swift", 94, 95)])
    #expect(fileRefs(in: "ct core/TaskBoard.swift:849-889(TaskBoardLanding), :943, :1009, core/Diff.swift:7-15(GitRead)")
            == [ref("core/TaskBoard.swift", 849, 889), ref("core/TaskBoard.swift", 943), ref("core/TaskBoard.swift", 1009),
                ref("core/Diff.swift", 7, 15)])
    // an arrow to a name, not a line, ends the list
    #expect(fileRefs(in: "TeamLaunch.swift:64-94→folderIsGone 93-101") == [ref("TeamLaunch.swift", 64, 94)])
    // a count after ", " is not a line
    #expect(fileRefs(in: "a.swift:12, 13개 파일") == [ref("a.swift", 12)])
}

@Test func aCommitBeforeThePathIsKept() {
    #expect(fileRefs(in: "see 6c0ca46:tools/x/Y.swift:12-14") == [ref("tools/x/Y.swift", 12, 14, at: "6c0ca46")])
}

@Test func severalFormsInOneTextComeInTextOrder() {
    let s = "highlight.js 언어 11종→map 기준 10종(Syntax.swift:22-30; 번들은 35종 NOTICE.md:3), TowerCoreTests @Test 442→441"
    #expect(fileRefs(in: s) == [ref("Syntax.swift", 22, 30), ref("NOTICE.md", 3)])
}

// MARK: - Not a location

@Test func timesPortsBoardIdsAndVersionsAreNoRefs() {
    for s in ["12:30에 읽음", "10:30:00 시작", "http://localhost:8080/app.js:12", "https://example.com:443/a/b.swift:3",
              "T75#2 제출", "R9 L1, D#4:1", "v0.15.2:3", "§2.2(:257-258)와 C6(:256-257)에서 다름",
              "T9 보고서 줄 번호 4곳 어긋남: L1~L5 정의 :73-77→:74-80, polling :10→:12",
              "curl -s https://api.github.com/repos/CodeEditApp/CodeEditLanguages/license | grep message",
              "stat -f '%Sp %N' ~/.my-team/sessions/my-team ~/.my-team/sessions/my-team/workers",
              "a.swift:0", "§6-10 sqlite3 -readonly 실패 원인"] {
        #expect(fileRefs(in: s).isEmpty, "\(s)")
    }
}

// MARK: - R20 L1: a column after the line

@Test func aColumnAfterTheLineIsReadAndLeftOut() {
    #expect(fileRefs(in: "warning at X.swift:498:9 unused") == [ref("X.swift", 498)])
    #expect(fileRefs(in: "src/a.ts:12:3, b.ts:4") == [ref("src/a.ts", 12), ref("b.ts", 4)])
    #expect(fileRefs(in: "10:30:00 시작").isEmpty)  // a time has no file name before it
}

// MARK: - Where each one is written (G4 I12): the part a link covers

@Test func eachLocationKnowsTheCharactersItWasWrittenIn() {
    let text = "한글 앞 https://x.io/한 그리고 a.swift:12, :14 또 sed -n '3,4p' /w/b.md"
    let spans = fileRefSpans(in: text)
    func written(_ s: FileRefSpan) -> String {
        String(text[text.index(text.startIndex, offsetBy: s.range.lowerBound)..<text.index(text.startIndex, offsetBy: s.range.upperBound)])
    }
    #expect(spans.map(\.ref) == [ref("a.swift", 12), ref("a.swift", 14), ref("/w/b.md", 3, 4)])
    #expect(spans.map(written) == ["a.swift:12", ", :14", "sed -n '3,4p' /w/b.md"])
}

// MARK: - Which file a location opens (G4 I12, plan §2.1)

private struct Disk {
    var files: Set<String>
    var lists: [String: [String]] = [:]
    func isFile(_ p: String) -> Bool { files.contains(p) }
    func list(_ base: String) -> [String]? { lists[base] }
}

@Test func anAbsoluteOrHomePathIsThatFile() {
    let disk = Disk(files: ["/abs/a.md", "/home/u/.my-team/r.md"])
    #expect(fileTarget(ref("/abs/a.md", 3), repo: nil, workerCwd: nil, home: "/home/u", isFile: disk.isFile, filesIn: disk.list)
            == .file(path: "/abs/a.md", line: 3))
    #expect(fileTarget(ref("~/.my-team/r.md", 5), repo: nil, workerCwd: nil, home: "/home/u", isFile: disk.isFile, filesIn: disk.list)
            == .file(path: "/home/u/.my-team/r.md", line: 5))
    #expect(fileTarget(ref("/abs/gone.md", 3), repo: "/w", workerCwd: nil, home: "/home/u", isFile: disk.isFile, filesIn: disk.list) == nil)
}

@Test func aCommitAndPathIsReadAtThatCommitInTheLandingsRepo() {
    let disk = Disk(files: [])
    #expect(fileTarget(ref("tools/x/Y.swift", 12, at: "6c0ca46"), repo: "/w/dev", workerCwd: "/w/other", home: "/h",
                       isFile: disk.isFile, filesIn: disk.list) == .commit(repo: "/w/dev", commit: "6c0ca46", path: "tools/x/Y.swift", line: 12))
    // no landing repo: the worker's folder
    #expect(fileTarget(ref("a.swift", 1, at: "6c0ca46"), repo: nil, workerCwd: "/w/other", home: "/h", isFile: disk.isFile, filesIn: disk.list)
            == .commit(repo: "/w/other", commit: "6c0ca46", path: "a.swift", line: 1))
    #expect(fileTarget(ref("a.swift", 1, at: "6c0ca46"), repo: nil, workerCwd: nil, home: "/h", isFile: disk.isFile, filesIn: disk.list) == nil)
}

@Test func aRelativePathIsTriedInTheLandingsRepoThenTheWorkersFolder() {
    let disk = Disk(files: ["/w/dev/src/a.swift", "/w/cwd/src/b.swift", "/w/cwd/src/a.swift"])
    #expect(fileTarget(ref("src/a.swift", 2), repo: "/w/dev", workerCwd: "/w/cwd", home: "/h", isFile: disk.isFile, filesIn: disk.list)
            == .file(path: "/w/dev/src/a.swift", line: 2))
    #expect(fileTarget(ref("src/b.swift", 2), repo: "/w/dev", workerCwd: "/w/cwd", home: "/h", isFile: disk.isFile, filesIn: disk.list)
            == .file(path: "/w/cwd/src/b.swift", line: 2))
    // a document task: no repo, no worker, the text stays text
    #expect(fileTarget(ref("src/a.swift", 2), repo: nil, workerCwd: nil, home: "/h", isFile: disk.isFile, filesIn: disk.list) == nil)
}

@Test func aBareFileNameIsLinkedOnlyWhenOneFileHasIt() {
    let disk = Disk(files: [], lists: ["/w/dev": ["Sources/A/History.swift", "Sources/A/Board.swift", "Sources/B/Board.swift"]])
    #expect(fileTarget(ref("History.swift", 315), repo: "/w/dev", workerCwd: nil, home: "/h", isFile: disk.isFile, filesIn: disk.list)
            == .file(path: "/w/dev/Sources/A/History.swift", line: 315))
    #expect(fileTarget(ref("Board.swift", 3), repo: "/w/dev", workerCwd: nil, home: "/h", isFile: disk.isFile, filesIn: disk.list) == nil)
    #expect(fileTarget(ref("Nowhere.swift", 3), repo: "/w/dev", workerCwd: nil, home: "/h", isFile: disk.isFile, filesIn: disk.list) == nil)
}

// MARK: - A finding beside its line (G4 W5)

@Test func anOpenFindingMarksItsLinesInTheFileShownByItsSeverity() {
    let marks = [
        FindingMark(target: .file(path: "/w/a.swift", line: 12), severity: "must", id: "R9 M1", summary: "breaks", changed: false),
        FindingMark(target: .file(path: "/w/a.swift", line: 30), severity: "low", id: "R9 L1", summary: "wording", changed: true),
        FindingMark(target: .file(path: "/w/b.swift", line: 1), severity: "should", id: "R9 S1", summary: "other file", changed: false),
        FindingMark(target: .commit(repo: "/w", commit: "abc", path: "a.swift", line: 5), severity: "should", id: "R9 S2", summary: "at a commit", changed: false),
    ]
    #expect(editorMarkers(for: "/w/a.swift", marks: marks) == [
        EditorMarker(line: 12, severity: .error, message: "R9 M1 breaks"),
        EditorMarker(line: 30, severity: .hint, message: "R9 L1 wording (지적 뒤 파일이 바뀌어 줄이 어긋났을 수 있음)"),
        EditorMarker(line: 5, severity: .warning, message: "R9 S2 at a commit"),  // /w + a.swift is the file shown
    ])
    #expect(editorMarkers(for: "/w/c.swift", marks: marks).isEmpty)
}
