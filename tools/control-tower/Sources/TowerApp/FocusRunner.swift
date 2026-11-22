import Foundation
import os
import TowerCore

struct CommandError: LocalizedError {
    let argv: [String]
    let output: String
    var status: Int32 = 0
    var errorDescription: String? { "\(argv.joined(separator: " ")) failed: \(output)" }
}

/// Runs a focus plan's argv arrays in order, without a shell. Stops at the
/// first failing command. Focus is the only thing the app ever does to a pane.
enum FocusRunner {
    /// Under `TOWER_DRY_RUN` each command is written to that file instead of run, and counts as done (T96).
    /// `env` replaces the app's environment for the commands (my-team's, `myTeamEnvironment`); nil keeps it.
    /// A command still running after `timeout` seconds is sent SIGTERM and counts as failed.
    static func run(_ commands: [[String]], env: [String: String]? = nil, timeout: TimeInterval? = nil,
                    dryRun: String? = towerDryRun) async throws {
        for argv in commands {
            let argv = resolved(argv)
            if let dryRun {
                recordDryRun(shellCommandLine(argv), to: dryRun)
            } else {
                try await exec(argv, env: env, timeout: timeout)
            }
        }
    }

    /// No shell parses anything. A GUI app's PATH lacks Homebrew, so `tmux` is TowerCore's resolved path with the
    /// test instance's socket, if any; `open` lives in /usr/bin; an absolute path (my-team's) is run as it is.
    static func resolved(_ argv: [String], tmux: [String] = towerTmux) -> [String] {
        if argv[0].hasPrefix("/") { return argv }
        return argv[0] == "tmux" ? tmux + argv.dropFirst() : ["/usr/bin/\(argv[0])"] + argv.dropFirst()
    }

    private static func exec(_ argv: [String], env: [String: String]?, timeout: TimeInterval?) async throws {
        let p = Process()
        if let env { p.environment = env }
        p.executableURL = URL(fileURLWithPath: argv[0])
        p.arguments = Array(argv.dropFirst())
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        // Drain stderr while the child runs: a full pipe (64 KB) would block it from exiting.
        let drained = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
        let status: Int32
        // the pid, not the Process, goes to the timer; `ended` under the lock keeps it from signalling a reused pid
        let state = OSAllocatedUnfairLock(initialState: (ended: false, timedOut: false))
        let exited = DispatchSemaphore(value: 0)
        do {
            status = try await withCheckedThrowingContinuation { c in
                p.terminationHandler = { ended in
                    state.withLock { $0.ended = true }
                    exited.signal()
                    c.resume(returning: ended.terminationStatus)
                }
                do { try p.run() } catch { c.resume(throwing: error); return }
                guard let timeout else { return }
                let pid = p.processIdentifier
                // On a thread of its own, as runCommand's (T130): a timer on a global queue fired only once a GCD
                // worker came back, so with all of them blocked a 1 s timeout took 27 s (T223).
                let deadline = DispatchTime.now() + timeout
                Thread {
                    guard exited.wait(timeout: deadline) == .timedOut else { return }
                    state.withLock { s in
                        guard !s.ended else { return }
                        s.timedOut = true
                        kill(pid, SIGTERM)
                    }
                }.start()
            }
        } catch {
            try? err.fileHandleForWriting.close()  // never launched: end the drain
            throw error
        }
        let text = String(decoding: await drained.value, as: UTF8.self)
        if let timeout, state.withLock({ $0.timedOut }) {
            throw CommandError(argv: argv, output: "\(Int(timeout))초 안에 끝나지 않아 멈췄습니다.", status: status)
        }
        guard status == 0 else {
            throw CommandError(argv: argv, output: text.trimmingCharacters(in: .whitespacesAndNewlines), status: status)
        }
    }
}
