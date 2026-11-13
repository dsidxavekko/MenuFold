import AppKit
import Carbon.HIToolbox
import MenuFoldCore
import Observation

// CONTRACT (shared by the Shell, Views and Settings agents). Add properties only with care; the
// existing names and types are fixed.

/// A global keyboard shortcut: a virtual key code (`kVK_*`) and Carbon modifier flags (`cmdKey`,
/// `optionKey`, `controlKey`, `shiftKey`). Registered with `RegisterEventHotKey` (no permissions).
struct HotKey: Codable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// "⌥Space", "⌃⌘M" … for Settings and menus.
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + HotKey.keyName(keyCode)
    }

    /// Name of a virtual key for display.
    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_F1: return "F1"; case kVK_F2: return "F2"; case kVK_F3: return "F3"; case kVK_F4: return "F4"
        case kVK_F5: return "F5"; case kVK_F6: return "F6"; case kVK_F7: return "F7"; case kVK_F8: return "F8"
        case kVK_F9: return "F9"; case kVK_F10: return "F10"; case kVK_F11: return "F11"; case kVK_F12: return "F12"
        case kVK_LeftArrow: return "←"; case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"; case kVK_DownArrow: return "↓"
        default:
            // The key's character on the US layout (Carbon key codes are layout-independent).
            let qwerty: [Int: String] = [
                kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
                kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
                kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
                kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
                kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
                kVK_ANSI_Z: "Z", kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
                kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8",
                kVK_ANSI_9: "9", kVK_ANSI_Grave: "`", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
                kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Semicolon: ";",
            ]
            return qwerty[Int(code)] ?? "#\(code)"
        }
    }
}

extension Notification.Name {
    /// Posted by `AppPreferences` after any change; the shell re-applies the hotkey, menu bar icon, …
    static let menuFoldPreferencesChanged = Notification.Name("MenuFoldPreferencesChanged")
    /// Posted by `HotKeyRecorder` when it starts (`object` = true) or stops (false) recording, so
    /// `HotKeyManager` can unregister the current shortcut meanwhile (Carbon would grab it first).
    static let menuFoldHotKeyRecording = Notification.Name("MenuFoldHotKeyRecording")
}

/// App-level preferences in UserDefaults, observable so views refresh. Model switches
/// (`showsFrequent`, `showsRunningTab`, …) are copied into `GridModel` by `AppDelegate`.
@MainActor
@Observable
final class AppPreferences {
    static let shared = AppPreferences()

    private let defaults = UserDefaults.standard

    /// Global shortcut that toggles the panel; nil = none (default).
    var hotKey: HotKey? {
        didSet { saveCodable(hotKey, "hotKey"); changed() }
    }
    /// Shows an icon in the menu bar that toggles the panel (default off).
    var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: "showsMenuBarIcon"); changed() }
    }
    /// Apps launch in the background and the panel stays open (→ `GridModel.keepsPanelOpenAfterLaunch`).
    var keepsPanelOpenAfterLaunch: Bool {
        didSet { defaults.set(keepsPanelOpenAfterLaunch, forKey: "keepsPanelOpenAfterLaunch"); changed() }
    }
    /// The panel reopens on the last tab (→ `GridModel.rememberLastTab`).
    var rememberLastTab: Bool {
        didSet { defaults.set(rememberLastTab, forKey: "rememberLastTab"); changed() }
    }
    /// Shows the "Недавні" tab (→ `GridModel.showsRecentTab`, default on).
    var showsRecentTab: Bool {
        didSet { defaults.set(showsRecentTab, forKey: "showsRecentTab"); changed() }
    }
    /// Shows the "Закріплені" row (→ `GridModel.showsPinned`, default on).
    var showsPinned: Bool {
        didSet { defaults.set(showsPinned, forKey: "showsPinned"); changed() }
    }
    /// Shows count badges on folder tiles (default on).
    var showsFolderCounts: Bool {
        didSet { defaults.set(showsFolderCounts, forKey: "showsFolderCounts"); changed() }
    }
    /// Shows the dot on apps installed recently (default on).
    var showsNewAppDots: Bool {
        didSet { defaults.set(showsNewAppDots, forKey: "showsNewAppDots"); changed() }
    }
    /// Grid columns of the panel, `columnRange` (default 7, like the system Apps launcher).
    var columns: Int {
        didSet { defaults.set(columns, forKey: "gridColumns"); changed() }
    }
    /// Visible grid rows (sets the panel height), `rowRange` (default 4).
    var rows: Int {
        didSet { defaults.set(rows, forKey: "gridRows"); changed() }
    }
    /// The first-run hint card was dismissed.
    var hasSeenFirstRunHint: Bool {
        didSet { defaults.set(hasSeenFirstRunHint, forKey: "hasSeenFirstRunHint") }
    }
    /// MenuFold's own data folder holding layout.json and Icons/; nil = the default
    /// ~/Library/Application Support/MenuFold. It is always a dedicated folder ("…/MenuFold"), never
    /// the folder the user picked itself (e.g. the iCloud Drive root): Settings resolves the pick
    /// with `DataFolderMigration.dedicatedFolder(for:)`, so MenuFold never writes, cleans up or
    /// quarantines files among the user's own. Applied on the next launch: the running store keeps
    /// its folder, so Settings restarts the app right after changing it.
    var dataDirectory: URL? {
        didSet { defaults.set(dataDirectory?.path, forKey: "dataDirectory"); changed() }
    }

    static let columnRange = 5...10
    static let rowRange = 3...7

    /// layout.json inside `dataDirectory`, or the default location: the file the *next* launch
    /// uses. What this session really uses is `GridModel.layoutFileURL`; show and reveal that one.
    var layoutFileURL: URL {
        dataDirectory?.appendingPathComponent("layout.json") ?? LayoutStore.defaultURL
    }

    private init() {
        hotKey = Self.loadCodable(HotKey.self, "hotKey", defaults)
        showsMenuBarIcon = defaults.object(forKey: "showsMenuBarIcon") as? Bool ?? false
        keepsPanelOpenAfterLaunch = defaults.object(forKey: "keepsPanelOpenAfterLaunch") as? Bool ?? false
        rememberLastTab = defaults.object(forKey: "rememberLastTab") as? Bool ?? false
        showsRecentTab = defaults.object(forKey: "showsRecentTab") as? Bool ?? true
        showsPinned = defaults.object(forKey: "showsPinned") as? Bool ?? true
        showsFolderCounts = defaults.object(forKey: "showsFolderCounts") as? Bool ?? true
        showsNewAppDots = defaults.object(forKey: "showsNewAppDots") as? Bool ?? true
        let c = defaults.object(forKey: "gridColumns") as? Int ?? 7
        columns = min(max(c, Self.columnRange.lowerBound), Self.columnRange.upperBound)
        let r = defaults.object(forKey: "gridRows") as? Int ?? 4
        rows = min(max(r, Self.rowRange.lowerBound), Self.rowRange.upperBound)
        hasSeenFirstRunHint = defaults.bool(forKey: "hasSeenFirstRunHint")
        dataDirectory = defaults.string(forKey: "dataDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func changed() {
        NotificationCenter.default.post(name: .menuFoldPreferencesChanged, object: nil)
    }

    private func saveCodable<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func loadCodable<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

