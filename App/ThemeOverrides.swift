import AppKit
import SwiftUI

/// Explicit in-app overrides of two system accessibility switches (Settings → Вигляд). An override
/// can only turn a setting ON; with it off, the system setting alone decides.
///
/// Reading: in SwiftUI use `@Environment(\.menuFoldReduceMotion)` / `\.menuFoldIncreaseContrast`
/// (already combined with the system value, once `.themeOverrides()` is applied to the root view);
/// in AppKit code use `ThemeOverrides.reduceMotion` / `ThemeOverrides.increaseContrast`.
@MainActor
enum ThemeOverrides {
    /// System "Reduce motion" OR the in-app override.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || AppPreferences.shared.forcesReduceMotion
    }
    /// System "Increase contrast" OR the in-app override.
    static var increaseContrast: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast || AppPreferences.shared.forcesIncreaseContrast
    }
}

private struct MenuFoldReduceMotionKey: EnvironmentKey { static let defaultValue = false }
private struct MenuFoldContrastKey: EnvironmentKey { static let defaultValue = ColorSchemeContrast.standard }
private struct MenuFoldIncreaseContrastKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Effective contrast (system or in-app override); views compare it with `.increased`.
    var menuFoldContrast: ColorSchemeContrast {
        get { self[MenuFoldContrastKey.self] }
        set { self[MenuFoldContrastKey.self] = newValue }
    }
    /// Effective reduce-motion (system or in-app override). Injected by `.themeOverrides()`.
    var menuFoldReduceMotion: Bool {
        get { self[MenuFoldReduceMotionKey.self] }
        set { self[MenuFoldReduceMotionKey.self] = newValue }
    }
    /// Effective increase-contrast (system or in-app override). Injected by `.themeOverrides()`.
    var menuFoldIncreaseContrast: Bool {
        get { self[MenuFoldIncreaseContrastKey.self] }
        set { self[MenuFoldIncreaseContrastKey.self] = newValue }
    }
}

private struct ThemeOverridesModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorSchemeContrast) private var systemContrast
    // Observable: a Settings toggle re-renders at once.
    private let prefs = AppPreferences.shared

    func body(content: Content) -> some View {
        content
            .environment(\.menuFoldReduceMotion, systemReduceMotion || prefs.forcesReduceMotion)
            .environment(\.menuFoldIncreaseContrast, systemContrast == .increased || prefs.forcesIncreaseContrast)
            .environment(\.menuFoldContrast, (systemContrast == .increased || prefs.forcesIncreaseContrast) ? .increased : .standard)
    }
}

extension View {
    /// Injects the effective `menuFoldReduceMotion` / `menuFoldIncreaseContrast` values.
    func themeOverrides() -> some View { modifier(ThemeOverridesModifier()) }
}
