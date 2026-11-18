import Foundation

struct UsageRowKey: Hashable, Codable {
    // ponytail: in a time zone that is not a whole number of hours from UTC, a day's edge falls inside a row and
    // the row counts for the day its start is in. Store by the minute if that is ever worth it.
    var hour: Int
    var session: String
    var model: String
    var kind: UsageKind
}

struct UsageRow: Hashable {
    var tokens = UsageTokens()
    var rewrittenCache = 0
    var rewrittenResponses = 0
    var last = 0
}

struct UsageCompactionKey: Hashable {
    var hour: Int
    var session: String
}

let usageStoreVersion = 1

struct StoredUsageState: Codable {
    var version: Int
    var computedAt: Int
    /// Not in a state written before this key was.
    var since: Int?
}

struct StoredUsageDay: Codable {
    struct Row: Codable {
        var hour: Int
        var session: String
        var model: String
        var kind: UsageKind
        var output: Int
        var cacheRead: Int
        var cacheCreation: Int
        var input: Int
        var responses: Int
        var rewrittenCache: Int
        var rewrittenResponses: Int
        var last: Int
    }

    struct Compaction: Codable {
        var hour: Int
        var session: String
        var count: Int
    }

    var version: Int
    var day: String
    var rows: [Row]
    var compactions: [Compaction]
    var projects: [String: String]
}

func usageDayName(_ day: Int) -> String {
    Date(timeIntervalSince1970: Double(day) * 86400).formatted(.iso8601.year().month().day().dateSeparator(.dash))
}

struct UsageStore {
    var dir: String

    private func read<T: Decodable>(_ name: String) -> T? {
        FileManager.default.contents(atPath: "\(dir)/\(name)").flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func write(_ value: some Encodable, _ name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? encoder.encode(value).write(to: URL(fileURLWithPath: "\(dir)/\(name)"), options: .atomic)
    }

    func state() -> StoredUsageState? {
        (read("state.json") as StoredUsageState?).flatMap { $0.version == usageStoreVersion ? $0 : nil }
    }

    func days() -> [StoredUsageDay] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasSuffix(".json") && $0 != "state.json" }
            .compactMap { read($0) as StoredUsageDay? }
            .filter { $0.version == usageStoreVersion }
    }

    func save(_ day: StoredUsageDay) {
        struct Version: Decodable { var version: Int }
        if let there: Version = read("\(day.day).json"), there.version != usageStoreVersion { return }
        write(day, "\(day.day).json")
    }

    func save(_ state: StoredUsageState) {
        if let there: StoredUsageState = read("state.json"), there.version != usageStoreVersion { return }
        write(state, "state.json")
    }
}
