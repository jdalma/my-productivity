import Foundation

// MARK: - Time, in the string forms `--once` JSON writes and reads

/// `new Date(ms).toISOString()`: UTC, always three fraction digits.
func isoString(ms: Int64) -> String {
    let secs = ms >= 0 ? ms / 1000 : (ms - 999) / 1000
    let base = Date(timeIntervalSince1970: TimeInterval(secs)).formatted(.iso8601)
    return base.dropLast() + String(format: ".%03lldZ", ms - secs * 1000)
}

func isoString(_ date: Date) -> String {
    isoString(ms: Int64((date.timeIntervalSince1970 * 1000).rounded(.down)))
}

/// `Date.parse` for the ISO strings this tool reads and writes, in milliseconds; nil where JS gives NaN.
public func parseISO(_ s: String?) -> Double? {
    guard let s else { return nil }
    let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
        ?? (try? Date.ISO8601FormatStyle().parse(s))
    return date.map { $0.timeIntervalSince1970 * 1000 }
}

private let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/// `Thu Oct 29 21:15:20 2026` (ps `lstart`, Claude `procStart`) read in `zone` → ISO.
func ctimeISO(month: some StringProtocol, day: some StringProtocol, hour: some StringProtocol, minute: some StringProtocol,
              second: some StringProtocol, year: some StringProtocol, zone: TimeZone) -> String? {
    guard let m = months.firstIndex(of: String(month)) else { return nil }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = zone
    let parts = DateComponents(year: Int(year), month: m + 1, day: Int(day), hour: Int(hour), minute: Int(minute), second: Int(second))
    return cal.date(from: parts).map(isoString)
}

// MARK: - JS string semantics

extension String {
    /// JS `String.prototype.slice` over UTF-16 code units.
    func utf16Slice(_ from: Int, _ to: Int? = nil) -> String {
        let units = Array(utf16)
        let end = min(to ?? units.count, units.count)
        guard from < end else { return "" }
        return String(decoding: units[from..<end], as: UTF16.self)
    }

    /// JS `||` on strings: nil for ''.
    var nonEmpty: String? { isEmpty ? nil : self }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? { self?.nonEmpty }
}

// MARK: - External commands

struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String
}

struct CommandError: Error, CustomStringConvertible {
    var description: String
}

/// `PATH` plus the usual install dirs: a GUI app inherits launchd's PATH, which lacks Homebrew.
func searchDirs(_ path: String?) -> [String] {
    var seen = Set<String>()
    return ((path ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        .filter { !$0.isEmpty && seen.insert($0).inserted }
}

let searchPath = searchDirs(ProcessInfo.processInfo.environment["PATH"])

func resolveExecutable(_ name: String, in dirs: [String] = searchPath) -> String? {
    if name.contains("/") { return name }
    return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// What a child process runs with. Children get the same search dirs we use. Without any
/// locale (launchd gives none) tmux prints the tabs of a `-F` format as `_`, which breaks
/// every pane listing, so default to UTF-8.
func childEnvironment(base: [String: String], extra: [String: String]) -> [String: String] {
    var env = base
    env["PATH"] = searchDirs(base["PATH"]).joined(separator: ":")
    if ["LC_ALL", "LC_CTYPE", "LANG"].allSatisfy({ base[$0].nonEmpty == nil }) { env["LC_CTYPE"] = "UTF-8" }
    return env.merging(extra) { $1 }
}

/// The environment the app runs `my-team` with outside `runCommand` (T207 팀 종료): the search dirs on PATH, since
/// my-team is a `#!/usr/bin/env node` script and launchd gives a GUI app no Homebrew on PATH, and none of a worker's
/// variables, which would point my-team at that worker's team.
public func myTeamEnvironment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    childEnvironment(base: base, extra: [:]).filter { !taskBoardUnset.contains($0.key) }
}

/// Runs `argv` directly, never through a shell. A non-zero exit is a result, not a
/// throw; the caller decides what to do with the output. Throws only when
/// the program cannot be found or started.
/// `unset` names variables the child must not inherit.
/// `input` is what the child reads as its standard input, nothing without it; `cwd` is the folder it runs in.
/// `startKiller` starts the timeout's killer and `signal` sends its signals; tests start it late and record them.
func runCommand(_ argv: [String], timeout: TimeInterval, env: [String: String] = [:], unset: Set<String> = [],
                input: Data? = nil, cwd: String? = nil,
                startKiller: (@escaping @Sendable () -> Void) -> Void = { Thread(block: $0).start() },
                signal: @escaping @Sendable (pid_t, Int32) -> Void = { _ = kill($0, $1) }) throws -> CommandResult {
    guard let exe = resolveExecutable(argv[0]) else { throw CommandError(description: "\(argv[0]): not found") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = Array(argv.dropFirst())
    p.environment = childEnvironment(base: ProcessInfo.processInfo.environment, extra: env).filter { !unset.contains($0.key) }
    // stderr goes to a file so a chatty child can never fill a second pipe while we drain stdout
    let errURL = FileManager.default.temporaryDirectory.appending(path: "tower-\(UUID().uuidString).err")
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    defer { try? FileManager.default.removeItem(at: errURL) }
    let errFile = try FileHandle(forWritingTo: errURL)
    let out = Pipe()
    // from a file, like stderr: a pipe would need a writer beside the reader of stdout
    let inURL = FileManager.default.temporaryDirectory.appending(path: "tower-\(UUID().uuidString).in")
    defer { try? FileManager.default.removeItem(at: inURL) }
    if let input {
        try input.write(to: inURL)
        p.standardInput = try FileHandle(forReadingFrom: inURL)
    } else {
        p.standardInput = FileHandle.nullDevice
    }
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    p.standardOutput = out
    p.standardError = errFile
    // waitUntilExit spins the run loop and adds about 70 ms per child; the handler fires on exit.
    let exited = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
    p.terminationHandler = { _ in exited.signal(); ended.signal() }
    do {
        try p.run()
    } catch {
        try? errFile.close()
        throw CommandError(description: "\(argv[0]): \(error.localizedDescription)")
    }
    try? errFile.close()
    let pid = p.processIdentifier
    // The timeout waits on a thread of its own, not a GCD worker: with every worker blocked in a command (about
    // 64), a killer scheduled on a global queue ran only when one of them returned (T130: 0.5 s became 7 s).
    // The deadline is taken here, not in the thread: a thread that starts late must not lengthen it (R51 L1). A child
    // that ignores SIGTERM gets SIGKILL a second later, or this call would never return (R51 L3). Both waits are for
    // the child's own exit, not for its output to close: a grandchild may hold the output on after the child ended,
    // and a signal then would go to a pid that may be another process's by now (R55 L1).
    let deadline = DispatchTime.now() + timeout
    startKiller {
        guard ended.wait(timeout: deadline) == .timedOut else { return }
        signal(pid, SIGTERM)
        if ended.wait(timeout: .now() + killGrace) == .timedOut { signal(pid, SIGKILL) }
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    exited.wait()
    let err = (try? Data(contentsOf: errURL)) ?? Data()
    return CommandResult(status: p.terminationStatus,
                         stdout: String(decoding: data, as: UTF8.self),
                         stderr: String(decoding: err, as: UTF8.self))
}

/// How long a child has to end after SIGTERM before SIGKILL.
let killGrace: TimeInterval = 1

func warn(_ message: String) {
    FileHandle.standardError.write(Data("control-tower: \(message)\n".utf8))
}
