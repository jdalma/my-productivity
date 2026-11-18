import Foundation

public enum DocumentKind: String, Hashable, Sendable, CaseIterable {
    case markdown
    case html
    case pdf

    public init?(path: String) {
        switch (path as NSString).pathExtension.lowercased() {
        case "md": self = .markdown
        case "html", "htm": self = .html
        case "pdf": self = .pdf
        default: return nil
        }
    }
}

public struct FolderDocument: Hashable, Sendable {
    public var path: String
    /// From the team's documents folder.
    public var relative: String
    public var kind: DocumentKind
    /// A Markdown file's first heading; the file's name for one without, and for the other kinds.
    public var title: String
    public var stamp: FileStamp

    public init(path: String, relative: String, kind: DocumentKind, title: String, stamp: FileStamp) {
        self.path = path
        self.relative = relative
        self.kind = kind
        self.title = title
        self.stamp = stamp
    }
}

public enum FolderDocuments: Hashable, Sendable {
    case missing
    /// The latest change first.
    case listed([FolderDocument])
}

/// The first heading in the first `titleReadLimit` bytes of the Markdown file at `path`, nil without one. A `#` line
/// inside a code fence is not a heading. The file is opened without following a link in its last place.
public func markdownTitle(_ path: String) -> String? {
    let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { return nil }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, let data = try? file.read(upToCount: titleReadLimit) else { return nil }
    var fenced = false
    for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init) {
        if line.trimmed.hasPrefix("```") || line.trimmed.hasPrefix("~~~") {
            fenced.toggle()
        } else if !fenced, let m = line.wholeMatch(of: #/\s{0,3}#{1,6}\s+(.+?)\s*#*\s*/#) {
            return plainOneLine(String(m.1)).nonEmpty
        }
    }
    return nil
}

let titleReadLimit = 8192

/// Every document under `folder`, however deep: regular files of a `DocumentKind`. A symbolic link is neither
/// followed nor listed, so nothing outside the folder is; hidden files, what is inside a bundle and the index file
/// itself are left out. A file whose time and size are as in `known` keeps its title unread.
public func listFolderDocuments(_ folder: String, known: [FolderDocument] = [], title: (String) -> String? = markdownTitle) -> FolderDocuments {
    var isFolder: ObjCBool = false
    guard let root = realPath(folder), FileManager.default.fileExists(atPath: root, isDirectory: &isFolder), isFolder.boolValue else { return .missing }
    let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
    guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return .missing }
    let before = Dictionary(known.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    var found: [FolderDocument] = []
    for case let url as URL in walk {
        guard let kind = DocumentKind(path: url.path), url.path.hasPrefix(root + "/"),
              let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true, v.isSymbolicLink != true,
              let modified = v.contentModificationDate, let size = v.fileSize else { continue }
        let relative = String(url.path.dropFirst(root.count + 1))
        guard relative != "index.md" else { continue }
        let stamp = FileStamp(modified: modified, size: size)
        let name = url.lastPathComponent
        let was = before[url.path]
        let shown = was?.stamp == stamp ? was!.title : (kind == .markdown ? title(url.path) : nil) ?? name
        found.append(FolderDocument(path: url.path, relative: relative, kind: kind, title: shown, stamp: stamp))
    }
    return .listed(found.sorted { ($0.stamp.modified, $1.relative) > ($1.stamp.modified, $0.relative) })
}

/// What a file the folder's list holds opens, judged again by where its path leads now: the file only while its real
/// path is still in `folder`.
public func documentTarget(path: String, folder: String) -> DocumentTarget {
    guard let real = realPath(path) else { return .missing(path) }
    return isInside(real, realPath(folder) ?? URL(fileURLWithPath: folder).standardizedFileURL.path) ? .file(real) : .blocked(.outside)
}
