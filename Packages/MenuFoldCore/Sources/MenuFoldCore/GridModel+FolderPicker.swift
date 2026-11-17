import Foundation

/// "Створити папку з…": a way to make a folder without dragging (VoiceOver, keyboard, menus).
/// `folderPickerSourceID` is the app the picker was opened for; choosing another app runs the
/// same `createFolder(dropping:onto:)` a drag-drop of app-on-app does.
extension GridModel {
    /// The picker is only offered where folder-making drops are: "Все", empty query, no open folder.
    public var canOfferFolderPicker: Bool {
        tab == .all && query.isEmpty && openFolderID == nil
    }

    /// Opens the picker for an app; false when the app is unknown or the context doesn't allow it.
    @discardableResult
    public func beginFolderPicker(for appID: String) -> Bool {
        guard canOfferFolderPicker, apps.contains(where: { $0.id == appID }) else { return false }
        folderPickerSourceID = appID
        return true
    }

    public func cancelFolderPicker() { folderPickerSourceID = nil }

    /// Other visible apps, matching `search` (empty = all, alphabetical; otherwise ranked).
    public func folderPickerCandidates(search: String = "") -> [AppEntry] {
        guard let source = folderPickerSourceID else { return [] }
        let others = visibleApps.filter { $0.id != source }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return others.sorted {
                let r = $0.name.localizedStandardCompare($1.name)
                return r == .orderedSame ? $0.id < $1.id : r == .orderedAscending
            }
        }
        return others.compactMap { app -> (AppEntry, Double)? in
            let best = [app.name, app.alternateName].compactMap { $0 }
                .compactMap { SearchMatcher.score($0, query: q) }.max()
            return best.map { (app, $0) }
        }
        .sorted { $0.1 == $1.1 ? $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending : $0.1 > $1.1 }
        .map(\.0)
    }

    /// Creates the folder with the picked app and closes the picker. Returns the folder id (nil if rejected).
    @discardableResult
    public func completeFolderPicker(with otherID: String) -> UUID? {
        guard let source = folderPickerSourceID else { return nil }
        folderPickerSourceID = nil
        // Like dropping the picked app onto the source tile: the folder takes the source's place.
        return createFolder(dropping: otherID, onto: source)
    }
}
