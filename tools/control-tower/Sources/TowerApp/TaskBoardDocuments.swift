import AppKit
import SwiftUI
import TowerCore
import UniformTypeIdentifiers

struct DocumentPage: Equatable {
    var title: String
    var path: String
    var folder: String
}

enum DocumentAction: Equatable {
    case showPage(String)
    case openURL(URL)
    case openFile(String)
    case none
}

func pickedPaths(_ index: [DocumentRow], folder: String) -> Set<String> {
    Set(index.compactMap { r in
        if case .file(let path) = documentTarget(r.line.link, folder: folder) { path } else { nil }
    })
}

/// `TOWER_DOCS_FILTER=<words>`: what 문서 걸러 보기 holds when the app starts. Typing does not reach the test instance.
let documentsFilterAtStart = ProcessInfo.processInfo.environment["TOWER_DOCS_FILTER"] ?? ""

/// What a click on the line does, judged again at the click. A file of the folder's own list opens only as one of
/// its kinds, and its `.html` only when a line of `index` opens the same file: the exception for `.html` (D#12) was
/// decided for what someone picked, not for every file a worker leaves in the folder.
func actionOnOpen(_ row: DocumentRow, folder: String, index: [DocumentRow] = []) -> DocumentAction {
    guard row.isFromFolder else {
        switch documentTarget(row.line.link, folder: folder) {
        case .web(let url): return .openURL(url)
        case .file(let path): return previewsAsMarkdown(path) ? .showPage(path) : .openFile(path)
        case .missing, .blocked: return .none
        }
    }
    guard case .file(let listed) = row.target, case .file(let path) = documentTarget(path: listed, folder: folder),
          DocumentKind(path: path) != nil else { return .none }
    if previewsAsMarkdown(path) { return .showPage(path) }
    if opensInBrowser(path), !pickedPaths(index, folder: folder).contains(path) { return .none }
    return .openFile(path)
}

/// The one kind of file the documents hand to the macOS default app that `defaultAppRefusal` keeps from it (D#12):
/// a team's mock is an `.html` file, and its default app is usually a browser. By the name's ending alone, so nothing
/// that merely is HTML to the system (a web archive, XHTML) comes with it; `openRefusal` still applies.
func opensInBrowser(_ path: String) -> Bool { ["html", "htm"].contains((path as NSString).pathExtension.lowercased()) }

enum DocumentFileOpen: Equatable {
    case refused(String)
    case needsEditor(notInstalled: String?)
    case unpickedFolderHTML
    case app(String)
    case defaultApp
    case window
}

func documentFileOpen(_ row: DocumentRow, stored: String, picked: Set<String> = [],
                      appURL: (String) -> URL? = { installedApp($0) }) -> DocumentFileOpen? {
    guard case .file(let path) = row.target else { return nil }
    if previewsAsMarkdown(path) { return .window }
    if opensInBrowser(path) {
        if row.isFromFolder, !picked.contains(path) { return .unpickedFolderHTML }
        return openRefusal(path).map { .refused($0) } ?? .defaultApp
    }
    var keptFromDefaultApp = false
    let plan = fileOpenPlan(path, stored: stored, defaultCheck: {
        let why = defaultAppRefusal($0)
        keptFromDefaultApp = why != nil
        return why
    }, appURL: appURL)
    switch plan {
    case .refused where keptFromDefaultApp: return .needsEditor(notInstalled: ["", systemDefaultEditor].contains(stored) ? nil : stored)
    case .refused(let why): return .refused(why)
    case .open(let app, _): return app.map { .app($0.deletingPathExtension().lastPathComponent) } ?? .defaultApp
    }
}

func fileKindName(_ path: String) -> String {
    let ending = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathExtension
    if ending.isEmpty { return "확장자 없는 파일" }
    return UTType(filenameExtension: ending)?.localizedDescription ?? ".\(ending) 파일"
}

func shownReason(_ refusal: String, path: String) -> String {
    var s = refusal
    if s.hasSuffix(": \(path)") { s.removeLast(path.count + 2) }
    if s.hasPrefix("열지 않았습니다: ") { s.removeFirst("열지 않았습니다: ".count) }
    let type = UTType(filenameExtension: URL(fileURLWithPath: path).resolvingSymlinksInPath().pathExtension) ?? .data
    return s.replacingOccurrences(of: "열지 않았습니다", with: "열지 않습니다")
        .replacingOccurrences(of: "(\(type.identifier))", with: "(\(fileKindName(path)))")
}

/// Hands an `.html` file of the documents to the macOS default app, usually a browser, whatever editor the settings name.
private func openInBrowser(_ path: String, dryRun: String?, failed: @escaping @Sendable (String) -> Void) -> String? {
    if let why = openRefusal(path) { return why }
    if let dryRun {
        recordDryRun("open-file macOS-default \(path)", to: dryRun)
    } else {
        workspaceOpen(URL(fileURLWithPath: path), nil) { e in if let e { failed("열지 못했습니다: \(e.localizedDescription)") } }
    }
    return nil
}

func fileOpensByRow(_ d: TeamDocuments, stored: String) -> [Int: DocumentFileOpen] {
    fileOpensByRow(d.rows, stored: stored)
}

func fileOpensByRow(_ rows: [DocumentRow], stored: String, picked: Set<String> = []) -> [Int: DocumentFileOpen] {
    Dictionary(rows.compactMap { r in documentFileOpen(r, stored: stored, picked: picked).map { (r.id, $0) } }, uniquingKeysWith: { a, _ in a })
}

/// Opens a line; `show` takes a Markdown file's path. The line to show the user, nil when it went as asked. Under
/// `TOWER_DRY_RUN` what would leave the app is a line in the log instead.
@MainActor func openDocument(_ row: DocumentRow, folder: String, index: [DocumentRow] = [], stored: String, dryRun: String? = towerDryRun,
                             appURL: (String) -> URL? = { installedApp($0) },
                             failed: @escaping @Sendable (String) -> Void = { _ in }, show: (String) -> Void) -> String? {
    switch actionOnOpen(row, folder: folder, index: index) {
    case .showPage(let path): show(path)
    case .openURL(let url):
        if let dryRun { recordDryRun("open-url \(url.absoluteString)", to: dryRun) } else { NSWorkspace.shared.open(url) }
    case .openFile(let path):
        return opensInBrowser(path) ? openInBrowser(path, dryRun: dryRun, failed: failed)
            : openFile(path, stored: stored, dryRun: dryRun, appURL: appURL, failed: failed)
    case .none: break
    }
    return nil
}

enum DocumentMenuItem: Hashable {
    case copyPath(String)
    case reveal(String)
    case copyLink(String)

    var title: String {
        switch self {
        case .copyPath: "경로 복사"
        case .reveal: "Finder에서 보기"
        case .copyLink: "링크 복사"
        }
    }
}

func documentMenuItems(_ row: DocumentRow) -> [DocumentMenuItem] {
    switch row.target {
    case .web(let url): [.copyLink(url.absoluteString)]
    case .file(let path): [.copyPath(path), .reveal(path)]
    case .missing(let path): [.copyPath(path)]
    case .blocked(.scheme): row.line.link.map { [.copyLink($0)] } ?? []
    case .blocked: row.line.link.map { [.copyPath($0)] } ?? []
    }
}

@MainActor func run(_ item: DocumentMenuItem, dryRun: String? = towerDryRun) {
    switch item {
    case .copyPath(let text), .copyLink(let text): copy(text)
    case .reveal(let path):
        if let dryRun { recordDryRun("reveal \(path)", to: dryRun) } else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
}

struct DocumentRowStyle: Equatable {
    enum Kind: String {
        case document = "문서"
        case link = "링크"
    }

    var symbol: String
    var kind: Kind
    var state: String?
    var reason: String?
    var help: String

    var stateText: String? { state.map { s in reason.map { "\(s): \($0)" } ?? s } }

    static func of(_ row: DocumentRow, fileOpen: DocumentFileOpen? = nil) -> DocumentRowStyle {
        switch row.target {
        case .web(let url): return DocumentRowStyle(symbol: "link", kind: .link, help: "브라우저에서 열기: \(url.absoluteString)")
        case .file(let path):
            switch fileOpen ?? .window {
            case .window: return DocumentRowStyle(symbol: "doc.text", kind: .document, help: "창 안에서 열기: \(path)")
            case .refused(let why):
                let reason = shownReason(why, path: path)
                return DocumentRowStyle(symbol: "nosign", kind: .document, state: "열 수 없음", reason: reason, help: "\(reason): \(path)")
            case .needsEditor(let notInstalled):
                let rule = "macOS 기본 앱은 마크다운, 일반 텍스트, PDF, 이미지만 엽니다(\(fileKindName(path)))"
                let help = notInstalled.map { "고른 에디터를 찾지 못했습니다(\($0)). \(rule). 설정에서 에디터를 다시 고르면 열 수 있습니다" }
                    ?? "\(rule). 설정에서 에디터를 고르면 열 수 있습니다"
                return DocumentRowStyle(symbol: "nosign", kind: .document, state: "열 수 없음",
                                        reason: notInstalled == nil ? "에디터를 골라야 엽니다" : "고른 에디터를 찾지 못했습니다", help: "\(help): \(path)")
            case .unpickedFolderHTML:
                return DocumentRowStyle(symbol: "nosign", kind: .document, state: "열 수 없음", reason: "목록 파일에 올린 HTML만 엽니다",
                                        help: "모든 문서의 HTML은 클릭으로 열지 않습니다. 목록 파일(index.md)에 올리면 열립니다: \(path)")
            case .app(let name):
                return DocumentRowStyle(symbol: "doc", kind: .document, help: "\(name) 앱으로 열기: \(path)")
            case .defaultApp:
                let by = opensInBrowser(path) ? "macOS 기본 앱(보통 브라우저)으로 열기" : "macOS 기본 앱으로 열기"
                return DocumentRowStyle(symbol: "doc", kind: .document, help: "\(by): \(path)")
            }
        case .missing(let path):
            return DocumentRowStyle(symbol: "doc.badge.ellipsis", kind: .document, state: "파일 없음", help: "파일이 없습니다: \(path)")
        case .blocked(let why):
            return DocumentRowStyle(symbol: "nosign", kind: why == .scheme ? .link : .document, state: "열 수 없음", reason: why.reason,
                                    help: why.reason + (row.line.link.map { ": \($0)" } ?? ""))
        }
    }

    func label(_ line: DocumentLine) -> String { ([line.title, kind.rawValue] + (line.note.isEmpty ? [] : [line.note])).joined(separator: ", ") }
}

func documentsSummary(_ d: TeamDocuments?) -> String {
    guard let d else { return "" }
    switch d.content {
    case .missing: return "목록 파일 없음"
    case .unreadable: return "읽지 못함"
    case .groups: return d.rows.isEmpty ? "없음" : "\(d.rows.count)"
    }
}

struct DocumentPageView: View {
    let title: String
    let path: String
    let folder: String
    let close: () -> Void
    @State private var blocks: [MarkdownBlock]?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).scaledFont(.title3, weight: .bold).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    Button("문서 닫기", systemImage: "xmark", action: close).labelStyle(.iconOnly).buttonStyle(.borderless)
                        .help("문서 닫기 (Esc)")
                }
                Text(path).scaledFont(.callout, design: .monospaced).foregroundStyle(.secondary).textSelection(.enabled)
                Divider()
                if let failure {
                    Text(failure).scaledFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                } else if let blocks {
                    MarkdownView(blocks: blocks)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: path) {
            let (path, folder) = (path, folder)
            (blocks, failure) = await Task.detached {
                switch readDocumentFile(path, folder: folder, what: "문서") {
                case .read(let text): (markdownBlocks(text), nil)
                case .unreadable(let why): (nil, why)
                }
            }.value
        }
    }
}
