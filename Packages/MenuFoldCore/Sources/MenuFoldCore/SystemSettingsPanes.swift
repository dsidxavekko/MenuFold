import Foundation

/// One System Settings pane offered in search ("Bluetooth", "Дисплеї", …).
public struct SystemSettingsPane: Identifiable, Hashable, Sendable {
    /// Stable id, e.g. "com.apple.BluetoothSettings".
    public let id: String
    /// Localized title (through `L(_:)`).
    public let name: String
    /// SF Symbol shown on the result tile.
    public let symbol: String
    /// `x-apple.systempreferences:` URL that opens the pane.
    public let url: URL

    public init(id: String, name: String, symbol: String, url: URL) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.url = url
    }
}

extension SystemSettingsPane {
    /// A catalog row: the pane plus what search matches besides its localized name.
    struct Entry {
        let pane: SystemSettingsPane
        /// English name and extra keywords (both languages), so "wifi" or "екран" find a pane
        /// whatever MenuFold's UI language is.
        let keywords: [String]

        var searchTexts: [String] { [pane.name] + keywords }
    }

    /// Common panes of System Settings (macOS 13+ extension ids, the ones `x-apple.systempreferences:`
    /// opens directly). Built on access, so `L(_:)` follows the current UI language.
    static var catalog: [Entry] {
        [
            entry("com.apple.wifi-settings-extension", "Wi-Fi", "wifi", ["Wi-Fi", "WiFi", "wireless", "бездротова мережа", "вайфай"]),
            entry("com.apple.BluetoothSettings", "Bluetooth", "dot.radiowaves.left.and.right", ["Bluetooth", "блютуз", "навушники"]),
            entry("com.apple.Network-Settings.extension", L("Мережа"), "network", ["Network", "Ethernet", "proxy", "DNS", "мережа"]),
            entry("com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension", "VPN", "lock.shield", ["VPN"]),
            entry("com.apple.Notifications-Settings.extension", L("Сповіщення"), "bell.badge", ["Notifications", "alerts"]),
            entry("com.apple.Sound-Settings.extension", L("Звук"), "speaker.wave.2", ["Sound", "volume", "audio", "гучність", "мікрофон", "microphone"]),
            entry("com.apple.Focus-Settings.extension", L("Зосередження"), "moon", ["Focus", "Do Not Disturb", "не турбувати"]),
            entry("com.apple.Screen-Time-Settings.extension", L("Екранний час"), "hourglass", ["Screen Time", "parental"]),
            entry("com.apple.systempreferences.GeneralSettings", L("Загальні"), "gearshape", ["General"]),
            entry("com.apple.SystemProfiler.AboutExtension", L("Про цей Mac"), "info.circle", ["About", "About This Mac", "serial", "version", "версія"]),
            entry("com.apple.Software-Update-Settings.extension", L("Оновлення ПЗ"), "arrow.triangle.2.circlepath", ["Software Update", "update", "upgrade", "оновлення"]),
            entry("com.apple.settings.Storage", L("Сховище"), "internaldrive", ["Storage", "disk space", "диск", "пам'ять"]),
            entry("com.apple.AirDrop-Handoff-Settings.extension", L("AirDrop і Handoff"), "airplayaudio", ["AirDrop", "Handoff", "AirPlay"]),
            entry("com.apple.LoginItems-Settings.extension", L("Обʼєкти входу"), "person.badge.key", ["Login Items", "startup", "автозапуск", "extensions", "розширення"]),
            entry("com.apple.Localization-Settings.extension", L("Мова й регіон"), "globe", ["Language & Region", "language", "region", "мова"]),
            entry("com.apple.Date-Time-Settings.extension", L("Дата й час"), "clock", ["Date & Time", "time zone", "clock", "годинник"]),
            entry("com.apple.Sharing-Settings.extension", L("Спільний доступ"), "square.and.arrow.up", ["Sharing", "file sharing", "screen sharing", "remote", "hostname"]),
            entry("com.apple.Time-Machine-Settings.extension", "Time Machine", "clock.arrow.circlepath", ["Time Machine", "backup", "резервне копіювання"]),
            entry("com.apple.Transfer-Reset-Settings.extension", L("Перенесення або скидання"), "arrow.counterclockwise", ["Transfer or Reset", "reset", "erase", "скинути"]),
            entry("com.apple.Startup-Disk-Settings.extension", L("Завантажувальний диск"), "externaldrive", ["Startup Disk", "boot"]),
            entry("com.apple.Appearance-Settings.extension", L("Вигляд"), "circle.lefthalf.filled", ["Appearance", "dark mode", "темний режим", "accent", "акцент"]),
            entry("com.apple.Accessibility-Settings.extension", L("Доступність"), "accessibility", ["Accessibility", "VoiceOver", "zoom", "спеціальні можливості"]),
            entry("com.apple.ControlCenter-Settings.extension", L("Центр керування"), "switch.2", ["Control Center", "menu bar", "рядок меню"]),
            entry("com.apple.Siri-Settings.extension", "Siri", "mic", ["Siri", "Apple Intelligence"]),
            entry("com.apple.Spotlight-Settings.extension", "Spotlight", "magnifyingglass", ["Spotlight", "search", "пошук"]),
            entry("com.apple.settings.PrivacySecurity.extension", L("Приватність і безпека"), "hand.raised", ["Privacy & Security", "privacy", "security", "permissions", "FileVault", "дозволи", "конфіденційність"]),
            entry("com.apple.Desktop-Settings.extension", L("Робочий стіл і Dock"), "dock.rectangle", ["Desktop & Dock", "Dock", "Mission Control", "Stage Manager", "hot corners", "активні кути"]),
            entry("com.apple.Displays-Settings.extension", L("Дисплеї"), "display", ["Displays", "monitor", "resolution", "Night Shift", "екран", "монітор", "роздільна здатність"]),
            entry("com.apple.Wallpaper-Settings.extension", L("Шпалери"), "photo", ["Wallpaper", "background", "фон"]),
            entry("com.apple.ScreenSaver-Settings.extension", L("Заставка"), "sparkles.tv", ["Screen Saver"]),
            entry("com.apple.Battery-Settings.extension", L("Акумулятор"), "battery.100", ["Battery", "energy", "power", "батарея", "енергія", "живлення"]),
            entry("com.apple.Lock-Screen-Settings.extension", L("Замкнений екран"), "lock.display", ["Lock Screen", "sleep", "сон"]),
            entry("com.apple.Touch-ID-Settings.extension", L("Touch ID і пароль"), "touchid", ["Touch ID & Password", "fingerprint", "password", "відбиток"]),
            entry("com.apple.Users-Groups-Settings.extension", L("Користувачі й групи"), "person.2", ["Users & Groups", "accounts", "guest", "користувач"]),
            entry("com.apple.Passwords-Settings.extension", L("Паролі"), "key", ["Passwords", "passkeys"]),
            entry("com.apple.Internet-Accounts-Settings.extension", L("Облікові записи інтернету"), "at", ["Internet Accounts", "mail accounts", "Google", "пошта"]),
            entry("com.apple.Game-Center-Settings.extension", "Game Center", "gamecontroller", ["Game Center"]),
            entry("com.apple.Game-Controller-Settings.extension", L("Ігрові контролери"), "gamecontroller.fill", ["Game Controllers", "gamepad", "геймпад"]),
            entry("com.apple.WalletSettingsExtension", L("Wallet і Apple Pay"), "wallet.pass", ["Wallet & Apple Pay", "Apple Pay", "cards", "картки"]),
            entry("com.apple.Family-Settings.extension", L("Родина"), "person.3", ["Family", "Family Sharing", "сімʼя"]),
            entry("com.apple.systempreferences.AppleIDSettings", L("Обліковий запис Apple"), "person.crop.circle", ["Apple Account", "Apple ID", "iCloud"]),
            entry("com.apple.Keyboard-Settings.extension", L("Клавіатура"), "keyboard", ["Keyboard", "shortcuts", "input sources", "dictation", "скорочення", "диктування"]),
            entry("com.apple.Mouse-Settings.extension", L("Миша"), "computermouse", ["Mouse", "scroll", "мишка"]),
            entry("com.apple.Trackpad-Settings.extension", L("Трекпад"), "rectangle.and.hand.point.up.left", ["Trackpad", "gestures", "жести"]),
            entry("com.apple.Print-Scanner-Settings.extension", L("Принтери й сканери"), "printer", ["Printers & Scanners", "printer", "scanner", "принтер"]),
        ]
    }

    private static func entry(_ id: String, _ name: String, _ symbol: String, _ keywords: [String]) -> Entry {
        // Every id is a plain reverse-DNS string, so the URL always parses.
        let url = URL(string: "x-apple.systempreferences:" + id)!
        return Entry(pane: SystemSettingsPane(id: id, name: name, symbol: symbol, url: url), keywords: keywords)
    }
}
