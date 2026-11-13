import Foundation

public enum FolderColor: String, Codable, CaseIterable, Sendable {
    case gray, blue, green, orange, red, purple, pink, yellow
}

/// Folder (single level). Manual folders hold bundle IDs, so apps survive reinstall.
/// Finder folders (`finderPath != nil`) are synthesized by GridModel from real subfolders of
/// /Applications, ~/Applications and /System/Applications/Utilities: their id is stable (derived
/// from the path), the name comes from Finder, and `appIDs` is computed (manual folders win).
public struct Folder: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var color: FolderColor
    /// Optional SF Symbol name shown on the folder tile instead of mini-icons.
    public var symbol: String?
    public var appIDs: [String]
    /// Absolute path of the Finder folder this mirrors; nil for manual folders.
    public var finderPath: String?
    public var isFinder: Bool { finderPath != nil }

    public init(id: UUID = UUID(), name: String, color: FolderColor = .gray, symbol: String? = nil, appIDs: [String], finderPath: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.symbol = symbol
        self.appIDs = appIDs
        self.finderPath = finderPath
    }
}

/// User style for a Finder folder (keyed by its path in `Layout.finderStyles`).
public struct FinderFolderStyle: Codable, Hashable, Sendable {
    public var color: FolderColor
    public var symbol: String?
    public init(color: FolderColor = .gray, symbol: String? = nil) {
        self.color = color
        self.symbol = symbol
    }

    private enum CodingKeys: String, CodingKey { case color, symbol }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A missing key is fine (older files); a present but unknown colour would silently reset
        // the user's choice, so it is treated as corruption by the caller.
        if c.contains(.color) { color = try c.decode(FolderColor.self, forKey: .color) } else { color = .gray }
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol)
    }
}

/// A category made by the user. Apps join it through `Layout.categoryOverrides` (bundle ID → `id`).
public struct CustomCategory: Identifiable, Codable, Hashable, Sendable {
    /// Always starts with `AppCategory.customPrefix`, so it never clashes with a system category.
    public let id: String
    public var name: String

    public init(id: String = AppCategory.customPrefix + UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }

    public var category: AppCategory { AppCategory(id: id, displayName: name) }
}

/// Everything persisted to layout.json.
public struct Layout: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var folders: [Folder]
    /// bundleID → category id (overrides Info.plist). May point at a `customCategories` id.
    public var categoryOverrides: [String: String]
    /// User-made categories, in creation order.
    public var customCategories: [CustomCategory]
    /// Category ids (system or custom) in the tab order the user set. Empty → default order.
    /// Ids missing from it (new categories) follow the listed ones, in default order.
    public var categoryOrder: [String]
    /// Bundle IDs hidden by the user.
    public var hidden: Set<String>
    /// Finder folder path → user style.
    public var finderStyles: [String: FinderFolderStyle]
    /// Finder folder paths the user dissolved (their apps show at the top level).
    public var ignoredFinderFolders: Set<String>
    /// Bundle IDs pulled out of their Finder folder to the top level.
    public var finderExclusions: Set<String>
    /// Bundle ID → Finder folder path the user dropped it into in MenuFold (files are not moved).
    /// Wins over the app's real location and over `finderExclusions`; manual folders still win over it.
    public var finderAdditions: [String: String]
    /// Bundle ID → file name of the user's icon in the icons folder (`LayoutStore.iconsDirectory`).
    /// Kept for uninstalled apps too, like folders, so the icon comes back on reinstall.
    public var customIcons: [String: String]
    /// Bundle IDs pinned by the user ("Закріплені" row on "Все"), in the user's order.
    /// Kept for uninstalled apps, like folders.
    public var pinned: [String]
    /// Manual order of the "Все" tab as `GridItem.id`s ("app:…" / "folder:…"); nil → alphabetical.
    /// Items missing from it (new apps, new folders) follow the listed ones alphabetically.
    public var manualOrder: [String]?

    public init(version: Int = Layout.currentVersion, folders: [Folder] = [], categoryOverrides: [String: String] = [:], hidden: Set<String> = [],
                finderStyles: [String: FinderFolderStyle] = [:], ignoredFinderFolders: Set<String> = [], finderExclusions: Set<String> = [],
                finderAdditions: [String: String] = [:], customCategories: [CustomCategory] = [],
                categoryOrder: [String] = [], customIcons: [String: String] = [:],
                pinned: [String] = [], manualOrder: [String]? = nil) {
        self.version = version
        self.folders = folders
        self.categoryOverrides = categoryOverrides
        self.hidden = hidden
        self.finderStyles = finderStyles
        self.ignoredFinderFolders = ignoredFinderFolders
        self.finderExclusions = finderExclusions
        self.finderAdditions = finderAdditions
        self.customCategories = customCategories
        self.categoryOrder = categoryOrder
        self.customIcons = customIcons
        self.pinned = pinned
        self.manualOrder = manualOrder
    }
}

// MARK: - Decoding
//
// Two levels of leniency, on purpose:
// - a MISSING key is normal (an older or newer file): the field keeps its default;
// - a key that is PRESENT but cannot be decoded is corruption: such a file is quarantined by
//   LayoutStore instead of being loaded partially and then saved back without the lost data.
//
// Lossy only where a per-element loss cannot be expressed as an error and is visibly repairable:
// duplicate folder ids (first one wins), duplicate ids inside `appIDs` (removed, order kept).

/// Thrown when a *present* value in layout.json does not have the expected shape.
private struct MalformedLayoutError: Error, CustomStringConvertible {
    let description: String
}

/// A value that is read only when its key is present; a present-but-wrong shape throws.
private func decodePresent<K: CodingKey, T: Decodable>(_ type: T.Type, _ c: KeyedDecodingContainer<K>,
                                                       _ key: K, default fallback: @autoclosure () -> T) throws -> T {
    guard c.contains(key) else { return fallback() }
    do { return try c.decode(T.self, forKey: key) } catch { throw MalformedLayoutError(description: "\(key.stringValue): \(error)") }
}

extension Folder {
    private enum CodingKeys: String, CodingKey { case id, name, color, symbol, appIDs, finderPath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // No id means the folder cannot be addressed by the UI (rename, style, dissolve): corrupt.
        if c.contains(.id) {
            do { id = try c.decode(UUID.self, forKey: .id) } catch { throw MalformedLayoutError(description: "folder id: \(error)") }
        } else {
            throw MalformedLayoutError(description: "folder without id")
        }
        name = try decodePresent(String.self, c, CodingKeys.name, default: L("Папка"))
        color = try decodePresent(FolderColor.self, c, CodingKeys.color, default: .gray)
        symbol = c.contains(.symbol) ? try c.decodeIfPresent(String.self, forKey: .symbol) : nil
        if c.contains(.appIDs) {
            var raw = try c.superDecoder(forKey: .appIDs).unkeyedContainer()
            var ids: [String] = []
            var seen = Set<String>()
            while !raw.isAtEnd {
                guard let id = try? raw.decode(String.self), !id.isEmpty else {
                    throw MalformedLayoutError(description: "folder \(self.id) has a non-string or empty appID")
                }
                if seen.insert(id).inserted { ids.append(id) }  // duplicate ids: keep the first
            }
            appIDs = ids
        } else {
            appIDs = []
        }
        finderPath = c.contains(.finderPath) ? try c.decodeIfPresent(String.self, forKey: .finderPath) : nil
    }
}

extension Layout {
    private enum CodingKeys: String, CodingKey { case version, folders, categoryOverrides, hidden, finderStyles, ignoredFinderFolders, finderExclusions, finderAdditions, customCategories, categoryOrder, customIcons, pinned, manualOrder }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try decodePresent(Int.self, c, CodingKeys.version, default: Layout.currentVersion)
        folders = try decodePresent([Folder].self, c, CodingKeys.folders, default: [])
        categoryOverrides = try decodePresent([String: String].self, c, CodingKeys.categoryOverrides, default: [:])
        hidden = try decodePresent(Set<String>.self, c, CodingKeys.hidden, default: [])
        finderStyles = try decodePresent([String: FinderFolderStyle].self, c, CodingKeys.finderStyles, default: [:])
        ignoredFinderFolders = try decodePresent(Set<String>.self, c, CodingKeys.ignoredFinderFolders, default: [])
        finderExclusions = try decodePresent(Set<String>.self, c, CodingKeys.finderExclusions, default: [])
        finderAdditions = try decodePresent([String: String].self, c, CodingKeys.finderAdditions, default: [:])
        customCategories = try decodePresent([CustomCategory].self, c, CodingKeys.customCategories, default: [])
        categoryOrder = try decodePresent([String].self, c, CodingKeys.categoryOrder, default: [])
        customIcons = try decodePresent([String: String].self, c, CodingKeys.customIcons, default: [:])
        pinned = try decodePresent([String].self, c, CodingKeys.pinned, default: [])
        manualOrder = try decodePresent([String]?.self, c, CodingKeys.manualOrder, default: nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(folders, forKey: .folders)
        try c.encode(categoryOverrides, forKey: .categoryOverrides)
        // Sorted for stable, diff-friendly output.
        try c.encode(hidden.sorted(), forKey: .hidden)
        try c.encode(finderStyles, forKey: .finderStyles)
        try c.encode(ignoredFinderFolders.sorted(), forKey: .ignoredFinderFolders)
        try c.encode(finderExclusions.sorted(), forKey: .finderExclusions)
        try c.encode(finderAdditions, forKey: .finderAdditions)
        try c.encode(customCategories, forKey: .customCategories)
        try c.encode(categoryOrder, forKey: .categoryOrder)
        try c.encode(customIcons, forKey: .customIcons)
        try c.encode(pinned, forKey: .pinned)
        try c.encodeIfPresent(manualOrder, forKey: .manualOrder)
    }
}

// MARK: - Load-time validation

extension Layout {
    /// Drops what can never be shown, so a hand-edited or merged file cannot break the grid
    /// (duplicate SwiftUI ids) or persist junk. Ids of the surviving folders are kept as they are.
    /// - Duplicate folder ids: the first folder with an id wins.
    /// - Manual folders need ≥2 apps (a folder of ≤1 is dissolved by the model), else they are dead.
    /// - `finderPath` must be absolute, without "."/".." components, and not the filesystem root.
    /// - Finder-folder keyed entries (`finderStyles`, `ignoredFinderFolders`) must be valid too,
    ///   since they are paths as well.
    /// - Custom categories need a `custom.` id and a name; overrides and `categoryOrder` entries for
    ///   unknown custom ids are dropped.
    /// - Custom icon file names must be plain names inside the icons folder (no path, no dot file).
    /// - `pinned` and `manualOrder` lose empty and repeated ids.
    func droppingInvalidFolders() -> Layout {
        var copy = self
        var seenIDs = Set<UUID>()
        copy.folders = folders.filter { folder in
            guard seenIDs.insert(folder.id).inserted else { return false }
            if let path = folder.finderPath {
                return Self.isValidFolderPath(path)
            }
            return Set(folder.appIDs).count >= 2
        }
        copy.finderStyles = finderStyles.filter { Self.isValidFolderPath($0.key) }
        copy.ignoredFinderFolders = ignoredFinderFolders.filter(Self.isValidFolderPath)
        copy.finderAdditions = finderAdditions.filter { Self.isValidFolderPath($0.value) }
        // Custom categories: a real `custom.` id, a non-blank name, first one with an id wins.
        var seenCategories = Set<String>()
        copy.customCategories = customCategories.filter { category in
            category.id.hasPrefix(AppCategory.customPrefix)
                && category.id.count > AppCategory.customPrefix.count
                && !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && seenCategories.insert(category.id).inserted
        }
        // An override pointing at a custom category that no longer exists would only fall back to
        // the automatic category anyway; drop it so it is not carried around forever.
        copy.categoryOverrides = categoryOverrides.filter { _, id in
            !id.hasPrefix(AppCategory.customPrefix) || seenCategories.contains(id)
        }
        // Tab order: no blanks, no repeats, no deleted custom categories.
        var seenOrder = Set<String>()
        copy.categoryOrder = categoryOrder.filter { id in
            !id.isEmpty
                && (!id.hasPrefix(AppCategory.customPrefix) || seenCategories.contains(id))
                && seenOrder.insert(id).inserted
        }
        copy.customIcons = customIcons.filter { !$0.key.isEmpty && Self.isValidIconFileName($0.value) }
        // Pinned apps and the manual "Все" order: no blanks, no repeats (a repeated id would give
        // the row or the grid two tiles with one SwiftUI id). Unknown ids are kept, like folders do.
        copy.pinned = Self.dedupedNonEmpty(pinned)
        copy.manualOrder = manualOrder.map(Self.dedupedNonEmpty)
        return copy
    }

    /// The non-empty strings of `ids`, first occurrence kept, order preserved.
    static func dedupedNonEmpty(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// A bare file name: no separators, not hidden, so it cannot point outside the icons folder.
    static func isValidIconFileName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains(":") && !name.hasPrefix(".")
    }

    /// Absolute path with no "." or ".." component and no trailing slash (other than "/" itself).
    static func isValidFolderPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.isEmpty else { return false }
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return false }
        return !components.contains { $0 == "." || $0 == ".." }
    }
}
