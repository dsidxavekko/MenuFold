import Testing
@testable import MenuFoldCore

@Suite struct FolderEmojiTests {
    @Test func acceptsSingleGraphemes() {
        for s in ["🔥", "❤️", "👨‍👩‍👧", "🇺🇦", "👍🏽", "1️⃣", " 🚀 "] {
            #expect(FolderEmoji.normalized(s) != nil, "\(s)")
        }
        #expect(FolderEmoji.symbol(for: "🔥") == "emoji:🔥")
    }

    @Test func rejectsOthers() {
        for s in ["", "a", "1", "#", "🔥🔥", "ab", "🔥a", "я"] {
            #expect(FolderEmoji.normalized(s) == nil, "\(s)")
        }
    }
}
