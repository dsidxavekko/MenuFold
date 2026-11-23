import AppKit
import MenuFoldCore
import SwiftUI
import Testing
@testable import MenuFold

/// Layout checks of the panel's cards in every language of the catalog. A card is rendered as the
/// panel hosts it, with the language set through `\.locale` (that localizes every `Text`, `Button`
/// and `Label` literal), and measured: a long German or Turkish line must not make it taller than
/// the panel or push the buttons out. Strings that travel as a `String` (`String(localized:)`)
/// follow the process language, not `\.locale`, so they are not covered here.
///
/// Set `TEST_RUNNER_MENUFOLD_SNAPSHOT_DIR=/some/dir` (xcodebuild forwards the variable without the
/// `TEST_RUNNER_` prefix) to also write one PNG per card and language there, for a visual look.
@MainActor
@Suite("Localized layout")
struct LocalizedLayoutTests {
    /// The source language plus every language of Localizable.xcstrings.
    /// `nonisolated`: the `@Test(arguments:)` macro reads it from outside the main actor.
    nonisolated static let languages = ["uk", "en", "de", "pl", "fr", "es", "it", "pt-BR", "ja", "zh-Hans", "tr"]

    /// Room the panel leaves for a card: its height minus the margins the root view keeps.
    private static var maxCardHeight: CGFloat { GridMetrics.panelHeight - 2 * 16 }

    private func size<V: View>(of view: V, language: String, width: CGFloat) -> CGSize {
        let host = NSHostingController(rootView: localized(view, language))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
    }

    private func localized<V: View>(_ view: V, _ language: String) -> some View {
        view
            .environment(\.locale, Locale(identifier: language))
            .environment(\.layoutDirection, .leftToRight)
            .themeOverrides()
    }

    private func snapshot<V: View>(_ view: V, name: String, language: String) {
        guard let dir = ProcessInfo.processInfo.environment["MENUFOLD_SNAPSHOT_DIR"] else { return }
        let renderer = ImageRenderer(content: localized(view, language).background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        let folder = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? png.write(to: folder.appendingPathComponent("\(name)-\(language).png"))
    }

    @Test(arguments: LocalizedLayoutTests.languages)
    func shortcutsCardFitsThePanel(language: String) {
        let model = GridModel.preview
        let card = ShortcutsHelpCard(model: model)
        snapshot(card, name: "shortcuts", language: language)
        let fitted = size(of: card, language: language, width: ShortcutsHelpCard.width)
        #expect(fitted.height <= Self.maxCardHeight, "\(language): \(fitted.height) pt > \(Self.maxCardHeight)")
        #expect(fitted.width <= GridMetrics.panelWidth)
    }

    @Test(arguments: LocalizedLayoutTests.languages)
    func firstRunHintStaysCompact(language: String) {
        let card = FirstRunHintCard(dismiss: {})
        snapshot(card, name: "first-run-hint", language: language)
        let width = GridMetrics.panelWidth - 2 * 28
        let fitted = size(of: card, language: language, width: width)
        // It floats over the bottom rows; more than a third of the panel would hide the grid.
        #expect(fitted.height <= GridMetrics.panelHeight / 3, "\(language): \(fitted.height) pt")
    }

    @Test(arguments: LocalizedLayoutTests.languages)
    func trashCardFitsThePanel(language: String) throws {
        let model = GridModel.preview
        let app = try #require(model.apps.first)
        let card = TrashConfirmationCard(app: app, model: model)
        snapshot(card, name: "trash", language: language)
        let fitted = size(of: card, language: language, width: GridMetrics.panelWidth)
        #expect(fitted.height <= Self.maxCardHeight, "\(language): \(fitted.height) pt")
        #expect(fitted.width <= GridMetrics.panelWidth)
    }

    /// The list above covers every language the app ships (a language added to the catalog without
    /// a layout check fails here).
    @Test func languageListMatchesTheApp() {
        let shipped = Set(Bundle.main.localizations).subtracting(["Base"])
        #expect(shipped == Set(Self.languages))
    }
}
