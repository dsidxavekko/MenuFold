import Foundation

// Keyboard quick actions for the selected tile (⌘D, ⌥+arrows, ⌥Return, ⇧Return, ⌘I).

extension GridModel {
    /// ⌘D: pins the selected app, or unpins it when it is pinned. False when no app is selected.
    @discardableResult
    public func togglePinOnSelection() -> Bool {
        guard let app = selectedApp else { return false }
        if isPinned(app.id) { unpin(app.id) } else { pin(app.id) }
        return true
    }

    /// ⌥+arrow: moves the selected tile in the manual order of "Все" (switching it to manual order),
    /// or a selected tile of the "Закріплені" row one step left/right. `columns` is the grid's column
    /// count. The selection follows the tile. False when the selection can't be moved that way
    /// (other tab, a search, an open folder, a "Часті" tile, the edge of the grid).
    @discardableResult
    public func moveSelectedTile(_ direction: MoveDirection, columns: Int) -> Bool {
        guard openFolderID == nil, let id = selectedItemID else { return false }
        if id.hasPrefix("pinned:") {
            guard direction == .left || direction == .right else { return false }
            let appID = String(id.dropFirst("pinned:".count))
            let before = layout.pinned
            movePinned(appID, by: direction == .left ? -1 : 1)
            return layout.pinned != before
        }
        guard tab == .all, query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.hasPrefix("app:") || id.hasPrefix("folder:"), columns > 0 else { return false }
        let ids = items(tab: .all, query: "").map(\.id)
        guard let index = ids.firstIndex(of: id) else { return false }
        let step: Int
        switch direction {
        case .left: step = -1
        case .right: step = 1
        case .up: step = -columns
        case .down: step = columns
        }
        var target = index + step
        // Up/down past the last row's end still goes to the very end; past the start, to the start.
        if direction == .down, target >= ids.count, index < ids.count - 1 { target = ids.count - 1 }
        if direction == .up, target < 0, index > 0 { target = 0 }
        guard ids.indices.contains(target), target != index else { return false }
        moveItem(id, relativeTo: ids[target], after: target > index)
        selectedItemID = id
        return true
    }

    /// ⌥Return: starts a new instance of the selected app. False when no app is selected.
    @discardableResult
    public func launchNewInstanceOfSelection() -> Bool {
        guard let app = selectedApp else { return false }
        launch(app, newInstance: true)
        return true
    }

    /// ⇧Return: shows the selected app in Finder. False when no app is selected.
    @discardableResult
    public func revealSelectionInFinder() -> Bool {
        // A file result has no app behind it; ⌘R means the same thing for both ("show it in Finder").
        if let file = selectedFile {
            revealFile(file)
            return true
        }
        guard let app = selectedApp else { return false }
        revealInFinder(app)
        return true
    }

    /// ⌘I: opens the info card for the selected app. False when no app is selected.
    @discardableResult
    public func showInfoForSelection() -> Bool {
        guard let app = selectedApp else { return false }
        infoAppID = app.id
        return true
    }
}
