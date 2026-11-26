import Observation
import TowerCore

/// What a worker row's line count is counted for (T58): its folder, and the start commit of its task in progress when
/// it has one. Workers sharing a folder share a count only with the same task base.
struct DiffKey: Hashable, Sendable {
    var folder: String
    var taskBase: String?
}

@MainActor @Observable
final class WorkerDiffTotals {
    private(set) var byKey: [DiffKey: DiffTotal] = [:]
    @ObservationIgnored var keys: Set<DiffKey> = [] {
        didSet { if !keys.isSubset(of: oldValue) { Task { await refresh() } } }
    }
    @ObservationIgnored private var reading = false
    @ObservationIgnored private let count: @Sendable (_ key: DiffKey, _ pins: [String: String]) -> DiffTotal?

    init(count: @escaping @Sendable (DiffKey, [String: String]) -> DiffTotal? = { diffTotal(at: $0.folder, pins: $1, taskBase: $0.taskBase) }) {
        self.count = count
    }

    func refresh() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        var asked: Set<DiffKey>
        repeat {
            asked = keys
            var next: [DiffKey: DiffTotal] = [:]
            if !asked.isEmpty {
                let pins = storedPins()
                next = await Task.detached { [count, asked] in
                    Dictionary(uniqueKeysWithValues: asked.compactMap { key in count(key, pins).map { (key, $0) } })
                }.value
            }
            if next != byKey { byKey = next }
        } while !keys.isSubset(of: asked)
    }
}
