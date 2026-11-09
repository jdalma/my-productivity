import Foundation

struct PsRow: Decodable, Hashable {
    var pid: Int
    var ppid: Int
    var args = ""
    var lstart: String?
    /// The process has a controlling terminal. Not in fixtures: they predate it.
    var hasTTY = false

    init(pid: Int, ppid: Int, args: String = "", lstart: String? = nil, hasTTY: Bool = false) {
        self.pid = pid
        self.ppid = ppid
        self.args = args
        self.lstart = lstart
        self.hasTTY = hasTTY
    }

    enum CodingKeys: String, CodingKey { case pid, ppid, args, lstart }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int.self, forKey: .pid)
        ppid = try c.decode(Int.self, forKey: .ppid)
        args = try c.decodeIfPresent(String.self, forKey: .args) ?? ""
        lstart = try c.decodeIfPresent(String.self, forKey: .lstart)
    }
}

/// A process's argv and initial environment, from the `KERN_PROCARGS2` buffer:
/// `argc` (int32), exec path, NUL padding, argv[0..<argc], env strings, an empty
/// string, then the kernel's own `apple[]` strings, which are not environment.
struct ProcArgs: Equatable {
    var argv: [String]
    var env: [String: String]
}

func parseProcArgs(_ buf: [UInt8]) -> ProcArgs? {
    guard buf.count >= 4 else { return nil }
    let argc = buf[0..<4].withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
    let strings = buf[4...].split(separator: 0, omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
    guard let first = strings.dropFirst().firstIndex(where: { !$0.isEmpty }) else { return ProcArgs(argv: [], env: [:]) }
    let argv = Array(strings[first...].prefix(argc))
    var env: [String: String] = [:]
    for e in strings[(first + argv.count)...].prefix(while: { !$0.isEmpty }) {
        guard let eq = e.firstIndex(of: "=") else { continue }
        let key = String(e[..<eq])
        if env[key] == nil { env[key] = String(e[e.index(after: eq)...]) } // getenv returns the first
    }
    return ProcArgs(argv: argv, env: env)
}

/// nil when the pid is gone or not ours to read (EPERM/EINVAL).
func procArgs(_ pid: Int) -> ProcArgs? {
    var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var argMax = 0, argMaxSize = MemoryLayout<Int>.size
    guard sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) == 0 else { return nil }
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
    var buf = [UInt8](repeating: 0, count: argMax)
    var size = argMax
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    return parseProcArgs(Array(buf.prefix(size)))
}

private func kinfoProcs() -> [kinfo_proc] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    let stride = MemoryLayout<kinfo_proc>.stride
    // ENOMEM: more processes started between sizing and reading than the slack covers; size again once
    for _ in 0..<2 {
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
        size = procs.count * stride
        if sysctl(&mib, 3, &procs, &size, nil, 0) == 0 { return Array(procs.prefix(size / stride)) }
        if errno != ENOMEM { return [] }
    }
    return []
}

/// Every process from one `KERN_PROC_ALL` read; args from `KERN_PROCARGS2`, empty when unreadable.
/// Sorted as ps sorts by default, controlling tty then pid: codex candidates, loose order
/// and which process claims a worker pane all follow row order.
func psSnapshot() -> [PsRow] {
    kinfoProcs()
        .sorted { ($0.kp_eproc.e_tdev, $0.kp_proc.p_pid) < ($1.kp_eproc.e_tdev, $1.kp_proc.p_pid) }
        .map { k in
            let pid = Int(k.kp_proc.p_pid)
            return PsRow(
                pid: pid,
                ppid: Int(k.kp_eproc.e_ppid),
                args: procArgs(pid)?.argv.joined(separator: " ") ?? "",
                lstart: isoString(ms: Int64(k.kp_proc.p_un.__p_starttime.tv_sec) * 1000),
                hasTTY: k.kp_eproc.e_tdev != -1  // NODEV
            )
        }
}

func envOf(pid: Int, keys: [String]) -> [String: String] {
    guard let env = procArgs(pid)?.env else { return [:] }
    return env.filter { keys.contains($0.key) }
}

/// Ancestor pids of `pid`, nearest first. Stops at 0/1 or after 40 hops.
func ancestors(of pid: Int, in rows: [PsRow]) -> [Int] {
    let parent = Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { $1 })
    var out: [Int] = []
    var cur = parent[pid]
    while let p = cur, p > 1, out.count < 40 {
        out.append(p)
        cur = parent[p]
    }
    return out
}

func isDescendant(_ pid: Int, of ancestor: Int, in rows: [PsRow]) -> Bool {
    ancestors(of: pid, in: rows).contains(ancestor)
}
