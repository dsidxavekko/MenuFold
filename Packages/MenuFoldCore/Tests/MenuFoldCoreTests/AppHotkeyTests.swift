import Foundation
import Testing
@testable import MenuFoldCore

@MainActor
@Suite struct AppHotkeyTests {
    @Test func roundTripAndMissingKey() throws {
        var l = Layout()
        l.appHotkeys[AppHotkey.key(appID: "com.a")] = AppHotkey(keyCode: 12, modifiers: 256)
        let back = try JSONDecoder().decode(Layout.self, from: JSONEncoder().encode(l))
        #expect(back.appHotkeys == l.appHotkeys)
        let old = try JSONDecoder().decode(Layout.self, from: Data("{\"version\":1}".utf8))
        #expect(old.appHotkeys.isEmpty)
    }

    @Test func validationDropsDuplicatesAndJunk() {
        let k = AppHotkey(keyCode: 1, modifiers: 256)
        var l = Layout()
        l.appHotkeys = ["app:a": k, "app:b": k, "bogus": AppHotkey(keyCode: 3, modifiers: 256), "app:": AppHotkey(keyCode: 4, modifiers: 256)]
        let v = l.droppingInvalidFolders()
        #expect(v.appHotkeys.keys.sorted() == ["app:a"])
    }

    @Test func settingMovesCombination() {
        let model = GridModel.preview
        let k = AppHotkey(keyCode: 5, modifiers: 256)
        model.setHotkey(k, forApp: "com.a")
        model.setHotkey(k, forApp: "com.b")
        #expect(model.hotkey(forApp: "com.a") == nil)
        #expect(model.hotkey(forApp: "com.b") == k)
        model.setHotkey(nil, forApp: "com.b")
        #expect(model.layout.appHotkeys.isEmpty)
    }
}
