import Foundation

/// Adaptive search ranking: remembers which app the user launched after typing a query, so the
/// same query puts it first next time. Lives in its own file (`search-choices.json`, next to
/// `usage.json` in the default folder), never in `layout.json`, so it is not synced or undone.
public struct SearchChoices: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Bundle ID → how many times it was launched from this query.
        public var apps: [String: Int]
        public var lastUsed: Date
    }

    /// Folded query → entry.
    public var entries: [String: Entry]

    /// At most this many queries are kept (the least recently used go first).
    public static let maxQueries = 300
    /// Shorter queries say too little to learn from.
    public static let minQueryLength = 2
    /// Largest fine-score bonus a remembered choice gives (stays inside the match tier).
    public static let maxBonus = 12.0

    public init(entries: [String: Entry] = [:]) { self.entries = entries }

    static func key(_ query: String) -> String {
        SearchMatcher.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Records that `appID` was launched after typing `query`. Ignores short queries.
    public mutating func record(query: String, appID: String, at date: Date) {
        let k = Self.key(query)
        guard k.count >= Self.minQueryLength else { return }
        var entry = entries[k] ?? Entry(apps: [:], lastUsed: date)
        entry.apps[appID, default: 0] += 1
        entry.lastUsed = date
        entries[k] = entry
        if entries.count > Self.maxQueries {
            let oldest = entries.sorted { $0.value.lastUsed < $1.value.lastUsed }
                .prefix(entries.count - Self.maxQueries).map(\.key)
            for key in oldest { entries[key] = nil }
        }
    }

    /// Ranking bonus for `appID` under an already folded `query`: launches from this exact query
    /// count fully, launches from longer queries that start with it count half.
    func bonus(forFoldedQuery query: String, appID: String) -> Double {
        guard query.count >= Self.minQueryLength, !entries.isEmpty else { return 0 }
        var count = Double(entries[query]?.apps[appID] ?? 0)
        for (key, entry) in entries where key != query && key.hasPrefix(query) {
            count += 0.5 * Double(entry.apps[appID] ?? 0)
        }
        return min(count, 3) * (Self.maxBonus / 3)
    }

    public mutating func removeApp(_ appID: String) {
        for k in entries.keys { entries[k]?.apps[appID] = nil }
        entries = entries.filter { !$0.value.apps.isEmpty }
    }
}

/// Loads/saves `SearchChoices` (atomic writes; a missing or unreadable file gives empty choices).
public final class SearchChoiceStore: @unchecked Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    public func load() -> SearchChoices {
        guard let data = try? Data(contentsOf: fileURL),
              let choices = try? JSONDecoder().decode(SearchChoices.self, from: data) else { return SearchChoices() }
        return choices
    }

    public func save(_ choices: SearchChoices) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(choices).write(to: fileURL, options: .atomic)
    }
}
