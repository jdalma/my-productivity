import Observation
import TowerCore

@MainActor @Observable
final class WorkerDiffTotals {
    private(set) var byFolder: [String: DiffTotal] = [:]
    @ObservationIgnored var folders: Set<String> = [] {
        didSet { if !folders.isSubset(of: oldValue) { Task { await refresh() } } }
    }
    @ObservationIgnored private var reading = false
    @ObservationIgnored private let count: @Sendable (_ folder: String, _ pins: [String: String]) -> DiffTotal?

    init(count: @escaping @Sendable (String, [String: String]) -> DiffTotal? = { diffTotal(at: $0, pins: $1) }) {
        self.count = count
    }

    func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        var asked: Set<String>
        repeat {
            asked = folders
            var next: [String: DiffTotal] = [:]
            if !asked.isEmpty {
                let pins = storedPins()
                next = await Task.detached { [count, asked] in
                    Dictionary(uniqueKeysWithValues: asked.compactMap { folder in count(folder, pins).map { (folder, $0) } })
                }.value
            }
            if next != byFolder { byFolder = next }
        } while !folders.isSubset(of: asked)
    }
}
