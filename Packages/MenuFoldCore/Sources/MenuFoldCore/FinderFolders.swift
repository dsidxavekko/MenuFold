import Foundation
import CryptoKit

/// Pure helpers for Finder folders: real subfolders of /Applications, ~/Applications and
/// /System/Applications/Utilities that MenuFold mirrors as read-only folders.
public enum FinderFolders {
    static let dataVolumePrefix = "/System/Volumes/Data"
    static let systemUtilities = "/System/Applications/Utilities"

    /// Top-level Finder folder that contains the app, or nil when the app sits directly in an
    /// applications root (or outside the supported roots).
    /// `/Applications/Робота/Dev/X.app` → `/Applications/Робота`;
    /// `/System/Applications/Utilities/Terminal.app` → `/System/Applications/Utilities`.
    public static func key(forAppPath appPath: String, homeDirectory: String) -> String? {
        let path = normalize(appPath)
        let home = normalize(homeDirectory)

        if path.hasPrefix(systemUtilities + "/") {
            return systemUtilities
        }
        let roots = (home.isEmpty || home == "/") ? ["/Applications"] : [home + "/Applications", "/Applications"]
        for root in roots {
            guard path.hasPrefix(root + "/") else { continue }
            let rest = path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: true)
            // Need at least <subfolder>/<App>.app; a bundle as the first component isn't a folder.
            guard rest.count >= 2, let first = rest.first, !isBundle(first) else { return nil }
            return root + "/" + first
        }
        return nil
    }

    /// Deterministic folder id: first 16 bytes of SHA-256(path), with UUID v5-style version/variant bits.
    public static func folderID(forPath path: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(path.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Localized Finder name (e.g. "Утиліти" for /System/Applications/Utilities).
    public static func displayName(atPath path: String) -> String {
        FileManager.default.displayName(atPath: path)
    }

    static func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix(dataVolumePrefix + "/") { p.removeFirst(dataVolumePrefix.count) }
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func isBundle(_ component: Substring) -> Bool {
        let lower = component.lowercased()
        return [".app", ".framework", ".bundle", ".xpc", ".appex", ".plugin"].contains { lower.hasSuffix($0) }
    }
}
