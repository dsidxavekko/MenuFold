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
        color = (try? c.decode(FolderColor.self, forKey: .color)) ?? .gray
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
    }
}

/// Everything persisted to layout.json.
public struct Layout: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var folders: [Folder]
    /// bundleID → category id (overrides Info.plist).
    public var categoryOverrides: [String: String]
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

    public init(version: Int = Layout.currentVersion, folders: [Folder] = [], categoryOverrides: [String: String] = [:], hidden: Set<String> = [],
                finderStyles: [String: FinderFolderStyle] = [:], ignoredFinderFolders: Set<String> = [], finderExclusions: Set<String> = [],
                finderAdditions: [String: String] = [:]) {
        self.version = version
        self.folders = folders
        self.categoryOverrides = categoryOverrides
        self.hidden = hidden
        self.finderStyles = finderStyles
        self.ignoredFinderFolders = ignoredFinderFolders
        self.finderExclusions = finderExclusions
        self.finderAdditions = finderAdditions
    }
}

// Lenient decoding: missing keys fall back to defaults, so older/newer files load what they can.
extension Folder {
    private enum CodingKeys: String, CodingKey { case id, name, color, symbol, appIDs, finderPath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Папка"
        color = (try? c.decode(FolderColor.self, forKey: .color)) ?? .gray
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        appIDs = (try? c.decode([String].self, forKey: .appIDs)) ?? []
        finderPath = try? c.decodeIfPresent(String.self, forKey: .finderPath)
    }
}

extension Layout {
    private enum CodingKeys: String, CodingKey { case version, folders, categoryOverrides, hidden, finderStyles, ignoredFinderFolders, finderExclusions, finderAdditions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? Layout.currentVersion
        folders = (try? c.decode([LossyFolder].self, forKey: .folders))?.compactMap(\.folder) ?? []
        categoryOverrides = (try? c.decode([String: String].self, forKey: .categoryOverrides)) ?? [:]
        hidden = (try? c.decode(Set<String>.self, forKey: .hidden)) ?? []
        finderStyles = (try? c.decode([String: FinderFolderStyle].self, forKey: .finderStyles)) ?? [:]
        ignoredFinderFolders = (try? c.decode(Set<String>.self, forKey: .ignoredFinderFolders)) ?? []
        finderExclusions = (try? c.decode(Set<String>.self, forKey: .finderExclusions)) ?? []
        finderAdditions = (try? c.decode([String: String].self, forKey: .finderAdditions)) ?? [:]
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
    }
}

private struct LossyFolder: Decodable {
    let folder: Folder?
    init(from decoder: Decoder) throws { folder = try? Folder(from: decoder) }
}
