import Foundation
import SwiftUI
import TowerCore

// The file:line places a task board text names (G4 I12, W1, W5, W6): made links that open in the task board window's
// read-only editor, and the open findings' places as markers there.

/// The files of each folder, for a bare file name (`fileTarget`'s `filesIn`): read once per folder.
// ponytail: never read again, so a file added later is found by its bare name only after a relaunch; re-read on a miss if that matters
@Observable final class FileLists: @unchecked Sendable {
    static let shared = FileLists()
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var byFolder: [String: [String]?] = [:]
    @ObservationIgnored private var reading: Set<String> = []
    /// Counts the folders read in the background: a view that asked `filesIfRead` draws again when one comes.
    private(set) var foldersRead = 0

    /// Reads `folder`'s files the first time (git ls-files, long in a big repo): off the main actor only.
    func files(_ folder: String) -> [String]? {
        if let known = lock.withLock({ byFolder[folder] }) { return known }
        let read = workspaceFiles(toplevel: folder, scope: "")
        lock.withLock { byFolder[folder] = read }
        return read
    }

    /// For a view's body: the files read so far, nil until then; the first ask reads them in the background (R34 S1).
    @MainActor func filesIfRead(_ folder: String) -> [String]? {
        _ = foldersRead
        if let known = lock.withLock({ byFolder[folder] }) { return known }
        guard lock.withLock({ reading.insert(folder).inserted }) else { return nil }
        Task.detached { [self] in
            _ = files(folder)
            await MainActor.run { foldersRead += 1 }
        }
        return nil
    }
}

/// Where `ref` opens for a text of a landing in `repo`, by a task whose worker works in `workerCwd` (plan §2.1).
/// Off the main actor: it may read a folder's files.
func refTarget(_ ref: FileRef, repo: String?, workerCwd: String?) -> FileTarget? {
    fileTarget(ref, repo: repo, workerCwd: workerCwd, filesIn: FileLists.shared.files)
}

/// `refTarget` for a view's body: a bare file name is placed once its folder was read, and the view draws again then.
@MainActor func refTargetNow(_ ref: FileRef, repo: String?, workerCwd: String?) -> FileTarget? {
    fileTarget(ref, repo: repo, workerCwd: workerCwd, filesIn: FileLists.shared.filesIfRead)
}

/// An open finding's texts and the landing its review was of: what its markers come from.
struct FindingPlace: Hashable, Sendable {
    var id: String
    var severity: String
    var summary: String
    var repro: String?
    var repo: String?
    var commit: String?
}

/// The places the open findings name, each marked faint when its file changed after the reviewed commit. Runs git:
/// off the main actor.
func findingMarks(_ places: [FindingPlace], workerCwd: String?) -> [FindingMark] {
    places.flatMap { p in
        let targets = (fileRefs(in: p.summary) + fileRefs(in: p.repro ?? "")).compactMap { refTarget($0, repo: p.repo, workerCwd: workerCwd) }
        return targets.reduce(into: [FileTarget]()) { if !$0.contains($1) { $0.append($1) } }.map { t in
            FindingMark(target: t, severity: p.severity, id: p.id, summary: p.summary, changed: movedSince(t, p))
        }
    }
}

/// The file of `t` is not as the review saw it at the landing's commit.
private func movedSince(_ t: FileTarget, _ p: FindingPlace) -> Bool {
    guard let commit = p.commit else { return false }
    switch t {
    case .file(let path, _):
        guard let repo = p.repo, path.hasPrefix(repo + "/") else { return false }
        return fileChanged(dir: repo, since: commit, path: String(path.dropFirst(repo.count + 1))) ?? false
    case .commit(let repo, let at, let path, _):
        return at != commit && (fileChanged(dir: repo, since: commit, to: at, path: path) ?? false)
    }
}

/// Inline Markdown with each file:line that `resolve` places made a link opening in the window's editor; as before
/// where the window has no editor (the board window) or nothing resolves.
struct RefText: View {
    let text: String
    let resolve: (FileRef) -> FileTarget?
    @Environment(\.openTargetInIde) private var openTarget

    var body: some View {
        let (shown, targets) = linked()
        Text(shown).environment(\.openURL, OpenURLAction { url in
            guard url.scheme == RefText.scheme, let i = Int(url.lastPathComponent), targets.indices.contains(i) else { return .systemAction }
            openTarget?(targets[i])
            return .handled
        })
    }

    static let scheme = "ctref"

    private func linked() -> (AttributedString, [FileTarget]) {
        openTarget == nil ? (inlineMarkdown(text), []) : linkedRefs(text, resolve: resolve)
    }
}

/// `text` as inline Markdown, each place `resolve` finds a `ctref://open/<n>` link over the characters it was written
/// in (inside a code span too), and the targets by n.
func linkedRefs(_ text: String, resolve: (FileRef) -> FileTarget?) -> (AttributedString, [FileTarget]) {
    var shown = inlineMarkdown(text)
    var targets: [FileTarget] = []
    // the places are read in the text as shown: Markdown's marks are gone, so the offsets are the shown characters'
    var linked: [Range<Int>] = []
    for span in fileRefSpans(in: String(shown.characters)) {
        // the ranges of one sed share its characters: the first is the link (R34 L1)
        guard !linked.contains(where: { $0.overlaps(span.range) }), let t = resolve(span.ref) else { continue }
        linked.append(span.range)
        let chars = shown.characters
        let range = chars.index(chars.startIndex, offsetBy: span.range.lowerBound)..<chars.index(chars.startIndex, offsetBy: span.range.upperBound)
        shown[range].link = URL(string: "\(RefText.scheme)://open/\(targets.count)")
        targets.append(t)
    }
    return (shown, targets)
}

/// The places a text names, as links under it: for a command (a repro) that stays whole for copying.
struct RefLinks: View {
    let text: String
    let resolve: (FileRef) -> FileTarget?
    @Environment(\.openTargetInIde) private var openTarget

    var body: some View {
        let places = openTarget == nil ? [] : fileRefSpans(in: text).compactMap { s in resolve(s.ref).map { (s.ref, $0) } }
        if !places.isEmpty {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("열기").scaledFont(.caption1).foregroundStyle(.secondary)
                ForEach(Array(places.enumerated()), id: \.offset) { _, place in
                    Button { openTarget?(place.1) } label: {
                        Text("\((place.0.path as NSString).lastPathComponent):\(place.0.lineStart)").underline().foregroundStyle(.link)
                            .scaledFont(.caption1, design: .monospaced)
                    }
                    .buttonStyle(.plain)
                    .help("편집기에서 열기: \(place.1.editorPath):\(place.1.line)")
                }
            }
        }
    }
}
