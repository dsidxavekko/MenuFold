import Foundation

/// A named view of the launcher ("Робота", "Дім", "Ігри"): a filter on top of the global layout.
/// Folders, categories and the manual order stay shared; a profile only narrows what shows.
public struct Profile: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var name: String
    /// Apps hidden in this profile, in addition to `Layout.hidden`.
    public var hidden: Set<String>
    /// Apps pinned in this profile only: they follow `Layout.pinned` in the "Закріплені" row.
    public var pinned: [String]
    /// Category ids (system, custom or smart) shown. nil = all. Apps of other categories, and the
    /// tabs of those categories, are left out while the profile is active.
    public var visibleCategories: Set<String>?

    public init(id: String = UUID().uuidString, name: String, hidden: Set<String> = [], pinned: [String] = [],
                visibleCategories: Set<String>? = nil) {
        self.id = id
        self.name = name
        self.hidden = hidden
        self.pinned = pinned
        self.visibleCategories = visibleCategories
    }

    private enum CodingKeys: String, CodingKey { case id, name, hidden, pinned, visibleCategories }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        hidden = try c.decodeIfPresent(Set<String>.self, forKey: .hidden) ?? []
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        visibleCategories = try c.decodeIfPresent(Set<String>.self, forKey: .visibleCategories)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(hidden.sorted(), forKey: .hidden)
        try c.encode(pinned, forKey: .pinned)
        try c.encodeIfPresent(visibleCategories.map { $0.sorted() }, forKey: .visibleCategories)
    }
}

extension Layout {
    /// Profiles with an id and a name, first of a repeated id wins; an unknown active id becomes nil.
    func validProfiles() -> [Profile] {
        var seen = Set<String>()
        return profiles.filter {
            !$0.id.isEmpty && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted
        }.map { p in
            var p = p
            p.pinned = Layout.dedupedNonEmpty(p.pinned)
            return p
        }
    }

    /// This layout with the active profile of `current` (an undo/redo entry must not switch profile).
    func keepingActiveProfile(of current: Layout) -> Layout {
        var copy = self
        copy.activeProfileID = profiles.contains { $0.id == current.activeProfileID } ? current.activeProfileID : nil
        return copy
    }
}

extension GridModel {
    public var profiles: [Profile] { layout.profiles }
    /// Names of the profiles, in creation order (for menus, URLs and Shortcuts).
    public var profileNames: [String] { layout.profiles.map(\.name) }
    public var activeProfile: Profile? { layout.profiles.first { $0.id == layout.activeProfileID } }
    public var activeProfileID: String? { activeProfile?.id }

    /// Switches profile (nil = no profile, everything shows). NOT an undo step: it is a mode, not an
    /// edit, so ⌘Z never flips it (undo/redo keep the current profile). An unknown id is ignored.
    /// The tab, selection and open folder are re-validated for the new filter.
    public func setActiveProfile(_ id: String?) {
        if let id, !layout.profiles.contains(where: { $0.id == id }) { return }
        guard layout.activeProfileID != id else { return }
        var l = layout
        l.activeProfileID = id
        let was = isRestoringUndo
        isRestoringUndo = true
        commit(l)
        isRestoringUndo = was
        closeOpenFolderIfGone()
    }

    /// Switches to the profile with this name (case-insensitive, trimmed). An empty name, or a
    /// name that is not a profile, switches nothing and returns false. Use `setActiveProfile(nil)`
    /// to leave profiles.
    @discardableResult
    public func setActiveProfile(named name: String) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty,
              let p = layout.profiles.first(where: { $0.name.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
        else { return false }
        setActiveProfile(p.id)
        return true
    }

    /// Creates a profile (a repeated name gets a number). Not activated.
    @discardableResult
    public func createProfile(named name: String, hidden: Set<String> = [], pinned: [String] = [],
                              visibleCategories: Set<String>? = nil) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? L("Новий профіль") : trimmed
        let taken = Set(layout.profiles.map { $0.name.lowercased() })
        var final = base
        var n = 2
        while taken.contains(final.lowercased()) { final = "\(base) \(n)"; n += 1 }
        let p = Profile(name: final, hidden: hidden, pinned: Layout.dedupedNonEmpty(pinned), visibleCategories: visibleCategories)
        var l = layout
        l.profiles.append(p)
        commit(l)
        return p
    }

    /// Replaces the profile with the same id (blank name or unknown id: ignored). An undoable edit.
    public func updateProfile(_ profile: Profile) {
        var p = profile
        p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
        p.pinned = Layout.dedupedNonEmpty(p.pinned)
        guard !p.name.isEmpty, let idx = layout.profiles.firstIndex(where: { $0.id == p.id }) else { return }
        var l = layout
        l.profiles[idx] = p
        commit(l)
        closeOpenFolderIfGone()
    }

    public func deleteProfile(id: String) {
        guard layout.profiles.contains(where: { $0.id == id }) else { return }
        var l = layout
        l.profiles.removeAll { $0.id == id }
        if l.activeProfileID == id { l.activeProfileID = nil }
        commit(l)
        closeOpenFolderIfGone()
    }

    /// True when the active profile lets this app show.
    func profileAllows(_ app: AppEntry) -> Bool {
        guard let p = activeProfile else { return true }
        if p.hidden.contains(app.id) { return false }
        if let cats = p.visibleCategories, !cats.contains(category(of: app).id) { return false }
        return true
    }

    /// True when the active profile lets the category's tab show.
    func profileAllows(category: AppCategory) -> Bool {
        guard let cats = activeProfile?.visibleCategories else { return true }
        return cats.contains(category.id)
    }

    /// Pinned ids as the row shows them: the global pins, then the active profile's own.
    var effectivePinnedIDs: [String] {
        guard let p = activeProfile, !p.pinned.isEmpty else { return layout.pinned }
        let have = Set(layout.pinned)
        return layout.pinned + p.pinned.filter { !have.contains($0) }
    }
}
