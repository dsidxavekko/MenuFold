// swift-tools-version: 6.2
import Foundation
import PackageDescription

// With only Command Line Tools selected, SwiftPM doesn't find the swift-testing macro plugin
// (it lives in host/plugins/testing). Point the test target at it; no effect under Xcode.
let cltDir = "/Library/Developer/CommandLineTools"
// DEVELOPER_DIR overrides xcode-select, so it wins over the symlink.
let selectedDeveloperDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
    ?? ""
let testingPluginDir = cltDir + "/usr/lib/swift/host/plugins/testing"
var testSettings: [SwiftSetting] = [.swiftLanguageMode(.v5)]
if selectedDeveloperDir.hasPrefix(cltDir), FileManager.default.fileExists(atPath: testingPluginDir) {
    testSettings.append(.unsafeFlags(["-plugin-path", testingPluginDir]))
}

let package = Package(
    name: "MenuFoldCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MenuFoldCore", targets: ["MenuFoldCore"])],
    targets: [
        .target(name: "MenuFoldCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "MenuFoldCoreTests", dependencies: ["MenuFoldCore"], swiftSettings: testSettings),
    ]
)
