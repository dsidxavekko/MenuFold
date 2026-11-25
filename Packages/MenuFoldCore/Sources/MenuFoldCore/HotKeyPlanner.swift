import Foundation

/// Bookkeeping of global shortcut registration, pure: given what is wanted and what is registered,
/// says what to unregister and in which order to register the rest, and hands out Carbon ids.
public enum HotKeyPlanner {
    public static let mainKey = "main"
    public static let mainID: UInt32 = 1

    /// Keys whose registration must be dropped: gone from `wanted` or with a different value.
    public static func staleKeys<V: Equatable>(wanted: [String: V], registered: [String: V]) -> [String] {
        registered.keys.filter { wanted[$0] != registered[$0] }.sorted()
    }

    /// Conflicts that no longer apply (the entry is gone or its combination changed).
    public static func staleConflicts<V: Equatable>(wanted: [String: V], conflicts: [String: V]) -> [String] {
        conflicts.keys.filter { wanted[$0] != conflicts[$0] }.sorted()
    }

    /// Whether `apply` has anything to do (always the first time, and while conflicts are retried).
    public static func needsApply<V: Equatable>(hasApplied: Bool, wanted: [String: V], registered: [String: V],
                                                 conflicts: [String: V]) -> Bool {
        !hasApplied || wanted != registered || !conflicts.isEmpty
    }

    /// Registration order: the main shortcut first (so it wins a clash), the rest by key.
    public static func registrationOrder(_ keys: [String]) -> [String] {
        keys.sorted { ($0 == mainKey ? "" : $0) < ($1 == mainKey ? "" : $1) }
    }

    /// The Carbon id for `key`: fixed for the main shortcut, otherwise one above the highest in use.
    public static func nextID(for key: String, usedIDs: some Collection<UInt32>) -> UInt32 {
        key == mainKey ? mainID : (usedIDs.max() ?? mainID) + 1
    }

    /// What a pressed id means.
    public enum Press: Equatable, Sendable { case main, clipboard, target(String), unknown }

    public static func press(id: UInt32, idToKey: [UInt32: String], clipboardKey: String) -> Press {
        if id == mainID { return .main }
        guard let key = idToKey[id] else { return .unknown }
        return key == clipboardKey ? .clipboard : .target(key)
    }
}
