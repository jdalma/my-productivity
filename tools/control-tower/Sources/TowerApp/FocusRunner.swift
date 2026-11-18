import Foundation
import TowerCore

struct CommandError: LocalizedError {
    let argv: [String]
    let output: String
    var errorDescription: String? { "\(argv.joined(separator: " ")) failed: \(output)" }
}

/// Runs a focus plan's argv arrays in order, without a shell. Stops at the
/// first failing command. Focus is the only thing the app ever does to a pane.
enum FocusRunner {
    /// Under `TOWER_DRY_RUN` each command is written to that file instead of run, and counts as done (T96).
    static func run(_ commands: [[String]], dryRun: String? = towerDryRun) async throws {
        for argv in commands {
            let argv = resolved(argv)
            if let dryRun {
                recordDryRun(shellCommandLine(argv), to: dryRun)
            } else {
                try await exec(argv)
            }
        }
    }

    /// No shell parses anything. A GUI app's PATH lacks Homebrew, so `tmux` is TowerCore's resolved path with the
    /// test instance's socket, if any; `open` lives in /usr/bin.
    static func resolved(_ argv: [String], tmux: [String] = towerTmux) -> [String] {
        argv[0] == "tmux" ? tmux + argv.dropFirst() : ["/usr/bin/\(argv[0])"] + argv.dropFirst()
    }

    private static func exec(_ argv: [String]) async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        // Drain stderr while the child runs: a full pipe (64 KB) would block it from exiting.
        let drained = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
        let status: Int32
        do {
            status = try await withCheckedThrowingContinuation { c in
                p.terminationHandler = { c.resume(returning: $0.terminationStatus) }
                do { try p.run() } catch { c.resume(throwing: error) }
            }
        } catch {
            try? err.fileHandleForWriting.close()  // never launched: end the drain
            throw error
        }
        let text = String(decoding: await drained.value, as: UTF8.self)
        guard status == 0 else {
            throw CommandError(argv: argv, output: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
