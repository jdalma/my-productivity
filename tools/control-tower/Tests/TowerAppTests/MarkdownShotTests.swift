import AppKit
import SwiftUI
import Testing
@testable import TowerCore
@testable import TowerApp

// Every screen that draws `MarkdownView` (T205), at the board's font scales, for CT_MARKDOWN_SHOTS. Invented text only.

private let sample = """
# 한 쪽 요약

첫 문단은 두세 줄로 넘어가도록 길게 쓴다. 작업판의 결정 요청과 보고서를 사용자가 빠르게 읽고 판단하는지 본다. 행간이 넓어지면 줄 사이가 얼마나 벌어지는지 이 문단에서 보인다.

## 바꾼 것

- 첫째 항목은 짧다.
- 둘째 항목은 길게 써서 한 줄을 넘긴다. 목록 안에서도 줄이 넘어갈 때 행간이 어떻게 보이는지 확인한다.
  - 안쪽 항목
- [x] 끝난 일
- [ ] 남은 일은 길게 써서 한 줄을 넘긴다. 확인란 옆의 글도 줄이 넘어갈 때 행간이 같은지 본다.

### 세부

> 인용은 회색 막대 옆에 놓인다. 인용도 두 줄이 되도록 조금 길게 쓴다. 인용도 두 줄이 되도록 조금 길게 쓴다.

> [!NOTE]
> 참고 callout의 본문이다. 두 줄로 넘어가도록 길게 쓴다. 배경과 라벨의 색이 어떻게 보이는지 이 상자에서 본다.

> [!TIP]
> 도움말 callout.

> [!IMPORTANT]
> 중요 callout.

> [!WARNING]
> 주의 callout.

> [!CAUTION]
> 위험 callout.

| 항목 | 값 |
|---|---|
| 행간 | 1.5 |
| 제목 | 1.875 |

```swift
let sample = 1
```

#### 네 번째 단계 제목

마지막 문단.
"""

private let ticket = """
# T900 — 예시 작업

## 사용자 목표

목표 문단은 길게 써서 두 줄을 넘긴다. 작업 상세의 목표 칸에서도 본문 행간이 문서의 행간과 같은지 이 문단으로 본다.

## 할 일

1. 첫 할 일은 길게 써서 한 줄을 넘긴다. 할 일 목록의 행간도 문서 본문과 같은지 본다.
2. 둘째 할 일.

\(sample)
"""

/// The brief's numbers (T205): the user may tune them, and a change shows here.
@Test func aDocumentsMeasuresAreTheBriefs() {
    #expect(DocumentType.bodyLineHeight == 1.5)
    #expect(DocumentType.headingLineHeight == 1.3)
    #expect((1...4).map(DocumentType.headingSize) == [1.875, 1.5, 1.25, 1])
    #expect(DocumentType.headingSpaceAbove == 3 * DocumentType.blockSpacing && DocumentType.blockSpacing == 8)
    // the system body is 13 pt on 16 pt lines: 3.5 more makes 19.5, 1.5 times 13
    #expect(abs(DocumentType.lineGap(size: 13, height: 1.5) - 3.5) < 0.01)
    for size in [10.4, 13, 26] { #expect(DocumentType.lineGap(size: size, height: 1.5) > 0) }
}

private func decoded<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return try d.decode(type, from: Data(json.utf8))
}

private func quoted(_ s: String) throws -> String { String(decoding: try JSONEncoder().encode(s), as: UTF8.self) }

@MainActor private func shoot(_ view: some View, width: CGFloat, height: CGFloat, scale: Double, dark: Bool, to file: URL?) async throws {
    let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: width * scale, height: height * scale),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.contentView = NSHostingView(rootView: view.environment(\.boardFontScale, scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor)))
    defer { window.contentView = nil }
    for _ in 0..<40 {
        window.contentView!.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(25))
    }
    let v = window.contentView!
    let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
    v.cacheDisplay(in: v.bounds, to: rep)
    #expect(rep.pixelsWide > 0)
    if let file { try rep.representation(using: .png, properties: [:])?.write(to: file) }
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["CT_MARKDOWN_SHOTS"] != nil))
func everyScreenThatDrawsMarkdown() async throws {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CT_MARKDOWN_SHOTS"]!)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let work = FileManager.default.temporaryDirectory.appending(path: "markdown-shots-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: work) }
    let ticketPath = work.appending(path: "T900-example.md")
    try ticket.write(to: ticketPath, atomically: true, encoding: .utf8)
    let docPath = work.appending(path: "notes.md")
    try sample.write(to: docPath, atomically: true, encoding: .utf8)

    let root = #"{"id":"T900","parent_id":null,"title":"예시 작업","ticket_path":\#(try quoted(ticketPath.path)),"state":"doing","assignee":"dev","reviewer":"rv","priority":100,"created_by":"pm","created_at":"2026-11-17T07:00:00.000Z"}"#
    let family = try decoded(TaskFamily.self,
        #"{"root":\#(root),"tasks":[\#(root)],"landings":[],"verdicts":[],"findings":[],"notes":[],"answers":[],"progress":[]}"#)
    let waiting = try decoded(TaskWaiting.self, #"""
    {"question":"어느 쪽으로 합니까?","context":\#(try quoted(sample)),"options":[{"label":"A","detail":"첫 안의 설명은 두 줄로 넘어가도록 길게 쓴다. 선택지의 설명도 문서 본문과 같은 행간으로 그린다.","pros":["빠르다"],"cons":["좁다"]}],"impact":"정하지 않으면 작업이 멈춘다.","refs":[],"asked_by":"dev","asked_at":"2026-11-17T07:00:00.000Z"}
    """#)

    let suite = "markdown-shots-\(UUID().uuidString)"
    defer { UserDefaults().removePersistentDomain(forName: suite) }
    let store = UsageAdviceStore(path: work.appending(path: "advice/v1.json").path)
    var record = UsageAdviceRecord()
    record.take(.success(sample), of: DashboardSamples.week, at: DashboardSamples.now)
    store.save(record)
    let advisor = UsageAdvisor(defaults: UserDefaults(suiteName: suite)!, store: store, run: { _ in .success("") })

    let now = DashboardSamples.now
    for (scale, dark) in [(0.8, false), (1.0, false), (2.0, false), (1.0, true)] {
        func file(_ screen: String) -> URL {
            dir.appending(path: "\(screen)-\(dark ? "dark" : "light")-s\(String(format: "%.1f", scale)).png")
        }
        try await shoot(TaskDetailView(team: "example", line: TaskLine(task: family.root, child: false, reasons: [], findingCount: 0),
                                       family: TaskFamilyState(ref: TaskRef(team: "example", task: "T900"), family: family),
                                       now: now, workerRow: { _ in nil }, pick: { _ in }, select: { _ in }, reload: {}),
                        width: 760, height: 2400, scale: scale, dark: dark, to: file("task-detail"))
        try await shoot(ScrollView { DecisionBriefView(brief: waiting, now: now).padding(16) },
                        width: 640, height: 2000, scale: scale, dark: dark, to: file("decision-brief"))
        // a report preview opens only by a click, which an offscreen window does not take: its open body as it frames it
        try await shoot(MarkdownView(blocks: markdownBlocks(sample)).padding(10)
                            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary)).padding(16),
                        width: 640, height: 2000, scale: scale, dark: dark, to: file("report-preview"))
        try await shoot(DocumentPageView(title: "notes.md", path: docPath.path, folder: work.path, close: {}),
                        width: 640, height: 2000, scale: scale, dark: dark, to: file("document"))
        try await shoot(AdviceSheet(advisor: advisor, report: DashboardSamples.week),
                        width: 640, height: 2000, scale: scale, dark: dark, to: file("advice"))
    }
}
