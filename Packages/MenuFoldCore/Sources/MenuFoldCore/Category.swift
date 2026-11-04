import Foundation

/// Automatic category, keyed by the `public.app-category.*` UTI (or "other").
public struct AppCategory: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public static let otherID = "other"
    /// Fallback for apps without a (known) category.
    public static let other = AppCategory(id: otherID, displayName: "Інше")

    /// Maps a raw UTI (e.g. "public.app-category.games") to a category; nil/unknown → `.other`.
    public static func from(raw: String?) -> AppCategory {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .other
        }
        if raw == otherID { return .other }
        if let name = displayNames[raw] { return AppCategory(id: raw, displayName: name) }
        // All game subcategories (public.app-category.action-games, …) collapse into "games".
        if raw.hasPrefix(prefix), raw.hasSuffix("-games") {
            return AppCategory(id: gamesID, displayName: displayNames[gamesID]!)
        }
        return .other
    }

    /// All known categories (Ukrainian display names), excluding `.other`.
    public static var known: [AppCategory] {
        orderedIDs.map { AppCategory(id: $0, displayName: displayNames[$0]!) }
    }

    private static let prefix = "public.app-category."
    static let gamesID = "public.app-category.games"

    private static let orderedIDs: [String] = [
        "public.app-category.business",
        "public.app-category.developer-tools",
        "public.app-category.education",
        "public.app-category.entertainment",
        "public.app-category.finance",
        "public.app-category.games",
        "public.app-category.graphics-design",
        "public.app-category.healthcare-fitness",
        "public.app-category.lifestyle",
        "public.app-category.medical",
        "public.app-category.music",
        "public.app-category.news",
        "public.app-category.photography",
        "public.app-category.productivity",
        "public.app-category.reference",
        "public.app-category.social-networking",
        "public.app-category.sports",
        "public.app-category.travel",
        "public.app-category.utilities",
        "public.app-category.video",
        "public.app-category.weather",
    ]

    private static let displayNames: [String: String] = [
        "public.app-category.business": "Бізнес",
        "public.app-category.developer-tools": "Розробка",
        "public.app-category.education": "Освіта",
        "public.app-category.entertainment": "Розваги",
        "public.app-category.finance": "Фінанси",
        "public.app-category.games": "Ігри",
        "public.app-category.graphics-design": "Графіка й дизайн",
        "public.app-category.healthcare-fitness": "Здоров'я та фітнес",
        "public.app-category.lifestyle": "Стиль життя",
        "public.app-category.medical": "Медицина",
        "public.app-category.music": "Музика",
        "public.app-category.news": "Новини",
        "public.app-category.photography": "Фото",
        "public.app-category.productivity": "Продуктивність",
        "public.app-category.reference": "Довідка",
        "public.app-category.social-networking": "Соцмережі",
        "public.app-category.sports": "Спорт",
        "public.app-category.travel": "Подорожі",
        "public.app-category.utilities": "Утиліти",
        "public.app-category.video": "Відео",
        "public.app-category.weather": "Погода",
    ]
}
