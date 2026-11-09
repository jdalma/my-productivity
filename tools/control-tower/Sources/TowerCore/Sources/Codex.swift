import Foundation

struct CodexRecord: Decodable, Hashable {
    var pid: Int
    var ppid: Int
    var cwd: String
    var startedAt: String?
    var transcript: String?
    var threadId: String?
    var status: Status
    var since: String?
    var title: String
    var termProgram: String?
}

private let tailBytes = 300_000

private func argv(_ args: String) -> [Substring] {
    args.split(whereSeparator: \.isWhitespace)
}

private func isCodexBin(_ r: PsRow) -> Bool {
    argv(r.args).first.map { ($0.split(separator: "/").last ?? "") == "codex" } ?? false
}

private func isAppServer(_ r: PsRow) -> Bool {
    " \(r.args)".contains(" app-server")
}

private func isRollout(_ path: String) -> Bool {
    path.contains(#/\/sessions\/.*rollout-.*\.jsonl$/#)
}

/// Interactive codex TUIs. argv[0] basename must be `codex`: the npm launcher is
/// `node …/bin/codex` (argv[0] = node) and its native child is `…/bin/codex`, so
/// this keeps exactly the child. app-server daemons, `codex exec` one-shots and
/// anything spawned under `selfPid` are dropped.
func pickCandidates(_ rows: [PsRow], selfPid: Int) -> [PsRow] {
    rows.filter { r in
        guard isCodexBin(r), !isAppServer(r) else { return false }
        // ponytail: first non-flag token; `codex -m x exec` slips through, add flag-value skipping if it shows up
        if argv(r.args).dropFirst().first(where: { !$0.hasPrefix("-") }) == "exec" { return false }
        return r.pid != selfPid && !isDescendant(r.pid, of: selfPid, in: rows)
    }
}

struct OpenFiles: Equatable {
    var cwd: String?
    var paths: [String]
}

private func pathString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// cwd and the paths of open vnode fds, or nil when the pid is gone or not ours (as lsof omits it).
func openFiles(_ pid: Int) -> OpenFiles? {
    let p = Int32(pid)
    var vpi = proc_vnodepathinfo()
    let vpiSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(p, PROC_PIDVNODEPATHINFO, 0, &vpi, vpiSize) == vpiSize else { return nil }
    let fdSize = MemoryLayout<proc_fdinfo>.stride
    let bytes = proc_pidinfo(p, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return OpenFiles(cwd: pathString(vpi.pvi_cdir.vip_path), paths: []) }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 8)
    let got = proc_pidinfo(p, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * fdSize))
    let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    let paths = fds.prefix(max(0, Int(got)) / fdSize).compactMap { fd -> String? in
        guard fd.proc_fdtype == PROX_FDTYPE_VNODE else { return nil }
        var info = vnode_fdinfowithpath()
        guard proc_pidfdinfo(p, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize else { return nil }
        return pathString(info.pvip.vip_path)
    }
    return OpenFiles(cwd: pathString(vpi.pvi_cdir.vip_path), paths: paths)
}

/// The last task_started vs task_complete/turn_aborted in a rollout tail.
func classifyRollout(_ tail: String) -> (status: Status, since: String?) {
    let started = tail.range(of: #""type":"task_started""#, options: .backwards)
    // an interrupted turn (Esc) ends with turn_aborted instead of task_complete
    let complete = [#""type":"task_complete""#, #""type":"turn_aborted""#]
        .compactMap { tail.range(of: $0, options: .backwards) }
        .max { $0.lowerBound < $1.lowerBound }
    guard let at = [started, complete].compactMap({ $0?.lowerBound }).max() else { return (.unknown, nil) }
    let lineStart = tail[..<at].lastIndex(of: "\n").map { tail.index(after: $0) } ?? tail.startIndex
    let lineEnd = tail[at...].firstIndex(of: "\n") ?? tail.endIndex
    let ts = tail[lineStart..<lineEnd].firstMatch(of: #/"timestamp":"([^"]+)"/#).map { String($0.1) }
    let finished = (complete?.lowerBound).map { c in started.map { c > $0.lowerBound } ?? true } ?? false
    return (finished ? .wait : .busy, ts)
}

/// The rollout's first line is `session_meta`; its payload carries id, cwd, timestamp.
private func readHead(_ path: String) -> [String: Any]? {
    guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
    defer { try? fh.close() }
    var line = Data()
    while line.count < 4 << 20, let chunk = try? fh.read(upToCount: 64 * 1024), !chunk.isEmpty {
        if let nl = chunk.firstIndex(of: 10) {
            line.append(chunk[..<nl])
            break
        }
        line.append(chunk)
    }
    let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    return json?["payload"] as? [String: Any]
}

func readTail(_ path: String, bytes: Int) -> String {
    guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? fh.close() }
    guard let size = try? fh.seekToEnd() else { return "" }
    let len = min(Int(size), bytes)
    guard (try? fh.seek(toOffset: size - UInt64(len))) != nil, let data = try? fh.read(upToCount: len) else { return "" }
    return String(decoding: data, as: UTF8.self)
}

private func mtime(_ path: String) -> Double {
    let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    return date?.timeIntervalSince1970 ?? 0
}

func loadTitles(codexHome: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: "\(codexHome)/session_index.jsonl", encoding: .utf8) else { return [:] }
    var titles: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let j = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = j["id"] as? String, !id.isEmpty else { continue }
        titles[id] = j["thread_name"] as? String ?? "" // later lines win
    }
    return titles
}

func loadCodexSessions(
    rows: [PsRow],
    codexHome: String = "\(homeDir)/.codex",
    selfPid: Int = Int(ProcessInfo.processInfo.processIdentifier)
) -> [CodexRecord] {
    let tuis = pickCandidates(rows, selfPid: selfPid)
    if tuis.isEmpty { return [] }
    let daemons = rows.filter { isCodexBin($0) && isAppServer($0) }
    let open = Dictionary(uniqueKeysWithValues: (tuis + daemons).compactMap { r in openFiles(r.pid).map { (r.pid, $0) } })
    let rollouts = { (pid: Int) in (open[pid]?.paths ?? []).filter(isRollout) }

    var metas: [String: [String: Any]?] = [:]
    let meta = { (p: String) -> [String: Any]? in
        if let m = metas[p] { return m }
        let m = readHead(p)
        metas[p] = m
        return m
    }

    let own = Dictionary(tuis.map { ($0.pid, rollouts($0.pid)) }, uniquingKeysWith: { $1 })
    let claimed = Set(own.values.filter { $0.count == 1 }.flatMap { $0 })
    var seen = Set<String>()
    let daemonPool = daemons.flatMap { rollouts($0.pid) }.filter { seen.insert($0).inserted && !claimed.contains($0) }

    let titles = loadTitles(codexHome: codexHome)
    return tuis.map { t in
        let mine = own[t.pid] ?? []
        var cwd = open[t.pid]?.cwd
        let transcript: String?
        if mine.count == 1 {
            transcript = mine[0]
        } else {
            let pool = (mine.isEmpty ? daemonPool : mine).filter { p in cwd != nil && meta(p)?["cwd"] as? String == cwd }
            // max(by:) keeps the first of equal mtimes
            transcript = pool.max { mtime($0) < mtime($1) }
        }
        let m = transcript.flatMap(meta)
        cwd = cwd ?? m?["cwd"] as? String ?? ""
        let threadId = m?["id"] as? String
        let (status, since) = transcript.map { classifyRollout(readTail($0, bytes: tailBytes)) } ?? (.unknown, nil)
        return CodexRecord(
            pid: t.pid,
            ppid: t.ppid,
            cwd: cwd ?? "",
            startedAt: m?["timestamp"] as? String ?? t.lstart,
            transcript: transcript,
            threadId: threadId,
            status: status,
            since: since,
            title: threadId.flatMap { titles[$0] }.nonEmpty ?? "",
            termProgram: envOf(pid: t.pid, keys: ["TERM_PROGRAM"])["TERM_PROGRAM"]
        )
    }
}
