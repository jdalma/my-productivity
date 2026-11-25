import Foundation

// The editor's buffers as Swift holds them (G4 I7, plan K8 b): which files are open, in what order, which one shows,
// which are unlocked, which hold an edit that is not saved, and what the disk did under each. The text itself stays in
// the page; every change of state goes through here, and what must happen next comes back as a `BufferEffect`.
// No file, no page and no clock here: the caller reads the disk and talks to the page.

/// The disk against the bytes a buffer started from (`EditorBuffer.base`).
public enum BufferDisk: Equatable, Sendable {
    case same
    /// Other bytes now, with their hash: what 덮어쓰기 replaces.
    case changed(hash: String)
    /// Gone, and still gone 250 ms later (`FileWatchBatch.deleted`).
    case deleted
}

public struct EditorBuffer: Equatable, Sendable {
    /// SHA-256 of the disk bytes the buffer's text started from: its read, its last reload or its last save.
    public var base: String
    /// Locked until the user unlocks it (D#5 b).
    public var readOnly = true
    /// The page's text differs from `base`'s.
    public var dirty = false
    public var disk = BufferDisk.same
    /// The user chose 내 편집 유지 for this change of the disk: no banner until the disk changes again.
    public var kept = false

    public init(base: String, readOnly: Bool = true) {
        (self.base, self.readOnly) = (base, readOnly)
    }
}

/// What the user picks when the disk changed under an edit that is not saved. Nothing merges by itself.
public enum BannerChoice: String, CaseIterable, Sendable {
    /// Show the disk's text against the buffer's; the banner stays.
    case compare
    /// Take the disk's text; the edit goes (the editor's undo brings it back).
    case reload
    /// Write the buffer over the disk's new bytes: the only choice that writes.
    case overwrite
    /// Keep editing; a later save still finds the disk changed and asks again.
    case keep
}

/// What the shown file's banner says.
public enum EditorBanner: Equatable, Sendable {
    /// The disk changed under an edit that is not saved: the four choices.
    case changed(path: String)
    /// The file is gone from the disk. The buffer stays to copy from; nothing saves it back.
    case deleted(path: String, dirty: Bool)
}

/// What the caller does after a change of state.
public enum BufferEffect: Equatable, Sendable {
    /// Send the disk's text to the page. `force` false: for a clean buffer, and the page keeps its text if it was
    /// edited meanwhile (then `reloaded(applied: false)`). `force` true: the user chose it.
    case reload(path: String, force: Bool)
    /// Tell the page the file is gone.
    case deleted(path: String)
    /// Save the buffer over the disk bytes that hash to `diskHash`, and over no others.
    case overwrite(path: String, diskHash: String)
    case compare(path: String)
}

public struct EditorBuffers: Equatable, Sendable {
    /// By real path.
    public private(set) var files: [String: EditorBuffer] = [:]
    /// The open files in the order they were opened.
    // ponytail: no closing of a tab yet; the tabs go with the worktree's editor. A closeFile command to the page when the row gets long.
    public private(set) var tabs: [String] = []
    public private(set) var shown: String?

    public init() {}

    /// The files with an edit that is not saved, in tab order.
    public var unsaved: [String] { tabs.filter { files[$0]?.dirty == true } }

    public var banner: EditorBanner? {
        guard let shown, let f = files[shown] else { return nil }
        switch f.disk {
        case .same: return nil
        case .deleted: return .deleted(path: shown, dirty: f.dirty)
        case .changed: return f.dirty && !f.kept ? .changed(path: shown) : nil
        }
    }

    /// The page shows `path`, read from disk bytes that hash to `hash`. A file already open keeps its edit and its
    /// lock: the page keeps a dirty buffer's text, and `hash` is then the disk's, not the buffer's base.
    public mutating func open(_ path: String, hash: String, readOnly: Bool) {
        if var f = files[path] {
            if f.dirty {
                if hash != f.base, f.disk != .changed(hash: hash) { (f.disk, f.kept) = (.changed(hash: hash), false) }
            } else {
                (f.base, f.disk, f.kept) = (hash, .same, false)
            }
            files[path] = f
        } else {
            files[path] = EditorBuffer(base: hash, readOnly: readOnly)
            tabs.append(path)
        }
        shown = path
    }

    public mutating func setReadOnly(_ path: String, _ readOnly: Bool) {
        files[path]?.readOnly = readOnly
    }

    /// The page says the buffer differs, or no longer differs, from what it started from. An edit undone to nothing
    /// under a changed disk leaves a clean buffer with old text: it reloads.
    public mutating func setDirty(_ path: String, _ dirty: Bool) -> BufferEffect? {
        guard var f = files[path], f.dirty != dirty else { return nil }
        f.dirty = dirty
        files[path] = f
        if !dirty, case .changed = f.disk { return .reload(path: path, force: false) }
        return nil
    }

    /// The watch saw `path` change: `hash` is its bytes' now, nil when it is gone. A clean buffer reloads; a dirty
    /// one keeps its text and shows the banner. The disk back at the buffer's base (this app's own save, a change
    /// undone) is no change.
    public mutating func diskChanged(_ path: String, hash: String?) -> BufferEffect? {
        guard var f = files[path] else { return nil }
        defer { files[path] = f }
        guard let hash else {
            guard f.disk != .deleted else { return nil }
            (f.disk, f.kept) = (.deleted, false)
            return .deleted(path: path)
        }
        if hash == f.base {
            // back from deleted with the same bytes: the page still holds them, but it locked the file
            let wasDeleted = f.disk == .deleted
            (f.disk, f.kept) = (.same, false)
            return wasDeleted ? .reload(path: path, force: false) : nil
        }
        if f.dirty {
            if f.disk != .changed(hash: hash) { (f.disk, f.kept) = (.changed(hash: hash), false) }
            return nil
        }
        f.disk = .changed(hash: hash)
        return .reload(path: path, force: false)
    }

    /// The page answered a reload with the disk text that hashes to `hash`: it took it, or (not forced) kept an edit
    /// made meanwhile. An edit kept over the bytes it started from is no change of the disk: no banner.
    public mutating func reloaded(_ path: String, hash: String, applied: Bool) {
        guard var f = files[path] else { return }
        if applied {
            (f.base, f.dirty, f.disk, f.kept) = (hash, false, .same, false)
        } else {
            (f.dirty, f.disk, f.kept) = (true, hash == f.base ? .same : .changed(hash: hash), false)
        }
        files[path] = f
    }

    /// A save wrote the buffer: the disk holds its text, with this hash.
    public mutating func saved(_ path: String, hash: String) {
        guard var f = files[path] else { return }
        (f.base, f.dirty, f.disk, f.kept) = (hash, false, .same, false)
        files[path] = f
    }

    /// A save found other bytes on the disk than the buffer started from, and wrote nothing.
    public mutating func conflict(_ path: String, diskHash: String) {
        guard var f = files[path] else { return }
        (f.dirty, f.disk, f.kept) = (true, .changed(hash: diskHash), false)
        files[path] = f
    }

    /// The file or folder at `from` was given the path `to` (the tree's 이름 변경): the open files at or under it keep
    /// their state, tab and place under their new paths. What moved comes back, in tab order, for the page.
    public mutating func renamed(from: String, to: String) -> [(from: String, to: String)] {
        let moved = open(under: from).map { (from: $0, to: to + $0.dropFirst(from.count)) }
        for m in moved {
            files[m.to] = files.removeValue(forKey: m.from)
            if shown == m.from { shown = m.to }
        }
        let new = Dictionary(uniqueKeysWithValues: moved.map { ($0.from, $0.to) })
        tabs = tabs.map { new[$0] ?? $0 }
        return moved
    }

    /// The open files at `path` or under it as a folder, in tab order: what a rename moves and a trash marks deleted.
    public func open(under path: String) -> [String] {
        tabs.filter { $0 == path || $0.hasPrefix(path + "/") }
    }

    /// The banner's choice for `path`; nothing unless the disk changed under an edit that is not saved.
    public mutating func choose(_ choice: BannerChoice, _ path: String) -> BufferEffect? {
        guard var f = files[path], f.dirty, case .changed(let diskHash) = f.disk else { return nil }
        switch choice {
        case .compare: return .compare(path: path)
        case .reload: return .reload(path: path, force: true)
        case .overwrite: return .overwrite(path: path, diskHash: diskHash)
        case .keep:
            f.kept = true
            files[path] = f
            return nil
        }
    }
}
