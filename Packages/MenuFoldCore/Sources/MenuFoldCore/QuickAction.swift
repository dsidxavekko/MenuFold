import Foundation

/// An action of the Tab quick-action list on a selected app tile. Titles and execution live in
/// the app layer; this is the pure availability logic.
public enum QuickAction: String, CaseIterable, Sendable, Equatable {
    case quit, hide, restart, showPackageContents, revealInFinder, copyPath, copyBundleID

    /// Only meaningful while the app is running.
    public var requiresRunning: Bool {
        switch self {
        case .quit, .hide, .restart: true
        default: false
        }
    }

    /// The actions offered for an app, in display order.
    public static func available(isRunning: Bool) -> [QuickAction] {
        allCases.filter { isRunning || !$0.requiresRunning }
    }
}
