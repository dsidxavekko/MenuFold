import Testing
@testable import MenuFoldCore

@Suite struct QuickActionTests {
    @Test func notRunningHidesProcessActions() {
        #expect(QuickAction.available(isRunning: false)
            == [.showPackageContents, .revealInFinder, .copyPath, .copyBundleID])
    }

    @Test func runningOffersEverythingInOrder() {
        #expect(QuickAction.available(isRunning: true) == QuickAction.allCases)
        #expect(QuickAction.available(isRunning: true).first == .quit)
    }
}
