import Foundation

/// Where over a tile a drag currently is.
public enum DropZone: Equatable, Sendable {
    /// Insert the dragged item before (left of) the tile.
    case before
    /// Folder drop (make a folder / add to the folder).
    case center
    /// Insert the dragged item after (right of) the tile.
    case after
}

/// Pure decisions behind the tile drop delegate (App/Views/TileDrop.swift), kept free of AppKit.
public enum DropRules {
    /// Share of the tile's width on each side that means "insert here" instead of "make a folder".
    public static let edgeFraction: Double = 0.22

    /// The zone for a pointer at `x` in a tile `width` wide. With `allowsReorder == false` only the
    /// center exists; with `allowsCenter == false` the nearer edge wins.
    public static func zone(x: Double, width: Double, allowsCenter: Bool, allowsReorder: Bool) -> DropZone? {
        guard width > 0 else { return allowsCenter ? .center : nil }
        if allowsReorder {
            let edge = width * edgeFraction
            if x < edge { return .before }
            if x > width - edge { return .after }
            if !allowsCenter { return x < width / 2 ? .before : .after }
        }
        return allowsCenter ? .center : nil
    }

    /// What dropping an app on a tile in `zone` should do.
    public enum AppAction: Equatable, Sendable {
        case center
        case reorder(after: Bool)
    }

    /// The action for a dropped app, or nil when the drop must be refused (unknown app, zone not
    /// allowed here, app not movable).
    public static func appAction(zone: DropZone, isKnownApp: Bool, allowsCenter: Bool,
                                 allowsReorder: Bool, canReorder: Bool) -> AppAction? {
        guard isKnownApp else { return nil }
        switch zone {
        case .center:
            return allowsCenter ? .center : nil
        case .before, .after:
            return allowsReorder && canReorder ? .reorder(after: zone == .after) : nil
        }
    }

    /// Zone for a dragged folder: reorder only, never onto itself.
    public static func folderZone(x: Double, width: Double, allowsReorder: Bool, canReorderFolders: Bool,
                                  isSelf: Bool) -> DropZone? {
        let ok = allowsReorder && canReorderFolders && !isSelf
        return zone(x: x, width: width, allowsCenter: false, allowsReorder: ok)
    }

    /// Zone for a dragged app. `canReorder == nil` means the id is unknown (foreign pasteboard):
    /// reorder stays possible and is re-validated at drop time.
    public static func appZone(x: Double, width: Double, allowsCenter: Bool, allowsReorder: Bool,
                               canReorder: Bool?) -> DropZone? {
        let reorder = allowsReorder && (canReorder ?? true)
        return zone(x: x, width: width, allowsCenter: allowsCenter, allowsReorder: reorder)
    }

    /// What a drag carries, as far as the drop target cares.
    public enum Payload: Equatable, Sendable { case app, folder, file, none }

    /// `validateDrop`: whether the tile takes this payload at all.
    public static func accepts(_ payload: Payload, allowsCenter: Bool, allowsReorder: Bool,
                               canReorderFolders: Bool, supportsFiles: Bool) -> Bool {
        switch payload {
        case .app: return allowsCenter || allowsReorder
        case .folder: return allowsReorder && canReorderFolders
        case .file: return supportsFiles
        case .none: return false
        }
    }

    /// Payload from the pasteboard's declared kinds; app wins over folder wins over file.
    public static func payload(hasApp: Bool, hasFolder: Bool, hasFile: Bool) -> Payload {
        if hasApp { return .app }
        if hasFolder { return .folder }
        if hasFile { return .file }
        return .none
    }

    // MARK: Files opened with an app

    /// At most this many files are checked (and opened) per drop.
    public static let maxFiles = 20

    /// Extensions of files that run code when opened: never opened by a drop.
    public static let executableExtensions: Set<String> = [
        "command", "terminal", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "scpt", "scptd", "applescript",
        "workflow", "action", "app", "pkg", "mpkg", "jar", "py", "pl", "rb", "tool", "osax", "dmg",
    ]

    public static func isExecutableExtension(_ ext: String) -> Bool {
        executableExtensions.contains(ext.lowercased())
    }

    /// The count rule of "open these files with this app".
    public static func isAcceptableFileCount(_ count: Int) -> Bool { count > 0 && count <= maxFiles }
}

/// Which operations a tile drag offers, by where it goes.
public enum DragMask: Equatable, Sendable {
    case none
    case withinApp          // move + generic
    case outsideLink        // link only
    case outsideDock        // link + generic (pinning)

    public static func forOutside(overDock: Bool) -> DragMask { overDock ? .outsideDock : .outsideLink }
}
