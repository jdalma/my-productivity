import Foundation

/// Test data next to this file, read in place (excluded from the target in Package.swift).
let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

func fixture(_ name: String) throws -> String {
    try String(contentsOf: fixtures.appending(path: name), encoding: .utf8)
}

func fixtureData(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appending(path: name))
}

@testable import TowerCore

extension CollectDeps {
    /// Reads nothing outside the test; each test swaps in the sources it needs.
    static var stub: CollectDeps {
        CollectDeps(
            psSnapshot: { [] },
            loadTeams: { _ in [] },
            loadCodexSessions: { _ in [] },
            listPanes: { [] },
            listClients: { [] },
            loadClaudeSessions: { [] },
            capturePane: { _ in "" },
            lastMessages: { _, _ in LastMessages() },
            envOf: { _, _ in [:] }
        )
    }
}
