import Foundation

/// Translates a UI string of the package. The keys are the Ukrainian texts, and the translations
/// live in the app's string catalog (`App/Localizable.xcstrings`), so add any new key there too.
/// Without a catalog (tests, previews of the package) the key itself comes back.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}
