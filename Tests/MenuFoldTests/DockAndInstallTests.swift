import AppKit
import Testing
@testable import MenuFold

/// The Dock band of `DockGeometry.isNearDock(_:screenFrame:visibleFrame:orientation:dockBand:)`, the
/// pure overload. It takes rects only, so every case below is a fixed screen: no real Dock, screen
/// or window list is consulted (the CGWindowList probe lives in the `@MainActor` overload).
///
/// The band along the chosen edge is `min(max(visible-frame inset, dockBand), maxDockSize)` thick and
/// counts up to `dockProximity` past it, inclusively: `distance <= thickness + proximity`. That is why
/// the boundary tests below sit exactly on `inset + dockProximity` (true) and 0.5 pt beyond (false),
/// and why an inner point is always false.
@MainActor
@Suite("DockGeometry dock band")
struct DockGeometryBandTests {
    /// 1440 × 900 at the origin, i.e. the primary display in this suite.
    private let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)

    /// Every distance used here is an integer or a half, so these comparisons are exact.
    private let slack = DockGeometry.dockProximity

    private func near(_ point: NSPoint, visible: NSRect, orientation: DockGeometry.Orientation,
                      band: CGFloat = 0, frame screenFrame: NSRect? = nil) -> Bool {
        DockGeometry.isNearDock(point, screenFrame: screenFrame ?? screen, visibleFrame: visible,
                                orientation: orientation, dockBand: band)
    }

    @Test func bottomDockCoversTheInsetPlusSlack() {
        // A classic 80 pt Dock: visibleFrame is the screen minus that strip.
        let visible = NSRect(x: 0, y: 80, width: 1440, height: 820)
        #expect(near(NSPoint(x: 700, y: 10), visible: visible, orientation: .bottom))
        #expect(near(NSPoint(x: 700, y: 80), visible: visible, orientation: .bottom))
        // The last point that still counts, then the first that does not.
        #expect(near(NSPoint(x: 700, y: 80 + slack), visible: visible, orientation: .bottom))
        #expect(!near(NSPoint(x: 700, y: 80 + slack + 0.5), visible: visible, orientation: .bottom))
        #expect(!near(NSPoint(x: 700, y: 97), visible: visible, orientation: .bottom))
        // Centre of the screen: never the Dock.
        #expect(!near(NSPoint(x: 700, y: 450), visible: visible, orientation: .bottom))
    }

    @Test func leftDockCoversTheInsetPlusSlack() {
        let visible = NSRect(x: 72, y: 0, width: 1368, height: 900)
        #expect(near(NSPoint(x: 5, y: 450), visible: visible, orientation: .left))
        #expect(near(NSPoint(x: 72 + slack, y: 450), visible: visible, orientation: .left))
        #expect(!near(NSPoint(x: 72 + slack + 0.5, y: 450), visible: visible, orientation: .left))
        #expect(!near(NSPoint(x: 720, y: 450), visible: visible, orientation: .left))
    }

    @Test func rightDockIsMeasuredFromTheRightEdge() {
        // Same 72 pt Dock, reserved on the right instead: visibleFrame keeps 1368 pt of width.
        let visible = NSRect(x: 0, y: 0, width: 1368, height: 900)
        #expect(near(NSPoint(x: 1430, y: 450), visible: visible, orientation: .right))
        #expect(near(NSPoint(x: 1368 - slack, y: 450), visible: visible, orientation: .right))
        #expect(!near(NSPoint(x: 1368 - slack - 0.5, y: 450), visible: visible, orientation: .right))
        #expect(!near(NSPoint(x: 700, y: 450), visible: visible, orientation: .right))
    }

    @Test func orientationDecidesWhichEdgeCounts() {
        // A left-side Dock reserves the left strip; the bottom rule must not see it as its own band.
        let left = NSRect(x: 72, y: 0, width: 1368, height: 900)
        #expect(near(NSPoint(x: 5, y: 450), visible: left, orientation: .left))
        #expect(!near(NSPoint(x: 5, y: 450), visible: left, orientation: .bottom))
        // And a bottom Dock's strip does not arm the side rules.
        let bottom = NSRect(x: 0, y: 80, width: 1440, height: 820)
        #expect(near(NSPoint(x: 700, y: 10), visible: bottom, orientation: .bottom))
        #expect(!near(NSPoint(x: 700, y: 10), visible: bottom, orientation: .left))
        #expect(!near(NSPoint(x: 700, y: 10), visible: bottom, orientation: .right))
    }

    @Test func autoHideUsesTheTileSizeBand() {
        // Auto-hide: visibleFrame equals the frame, so the inset is 0 and only `dockBand` is left.
        #expect(near(NSPoint(x: 700, y: 60), visible: screen, orientation: .bottom, band: 72))
        #expect(near(NSPoint(x: 700, y: 72 + slack), visible: screen, orientation: .bottom, band: 72))
        #expect(!near(NSPoint(x: 700, y: 72 + slack + 0.5), visible: screen, orientation: .bottom, band: 72))
        #expect(!near(NSPoint(x: 700, y: 500), visible: screen, orientation: .bottom, band: 72))
        // A magnified Dock is reported with a larger band; the side rules use it the same way.
        #expect(near(NSPoint(x: 136 + slack, y: 450), visible: screen, orientation: .left, band: 136))
        #expect(!near(NSPoint(x: 136 + slack + 0.5, y: 450), visible: screen, orientation: .left, band: 136))
    }

    @Test func thickerOfInsetAndBandWins() {
        // The two are not summed: a taller reserved Dock beats a small tile-size band.
        let visible = NSRect(x: 0, y: 100, width: 1440, height: 800)
        #expect(near(NSPoint(x: 700, y: 100 + slack), visible: visible, orientation: .bottom, band: 20))
        #expect(!near(NSPoint(x: 700, y: 100 + slack + 0.5), visible: visible, orientation: .bottom, band: 20))
        // …and a magnified band beats a Dock that reserves nothing.
        #expect(near(NSPoint(x: 700, y: 120 + slack), visible: screen, orientation: .bottom, band: 120))
        #expect(!near(NSPoint(x: 700, y: 120 + slack + 0.5), visible: screen, orientation: .bottom, band: 120))
    }

    @Test func hostileBandIsClampedToTheMaximumDockSize() {
        // `com.apple.dock` is user-writable: a huge finite value must not turn the screen into one big
        // Dock area.
        let limit = DockGeometry.maxDockSize + slack
        for band in [CGFloat(1e9), .greatestFiniteMagnitude] {
            #expect(near(NSPoint(x: 700, y: limit), visible: screen, orientation: .bottom, band: band))
            #expect(!near(NSPoint(x: 700, y: limit + 0.5), visible: screen, orientation: .bottom, band: band))
            #expect(!near(NSPoint(x: 700, y: 500), visible: screen, orientation: .bottom, band: band))
        }
        // An infinite value is not clamped: it is dropped as unusable, leaving the reserved inset.
        #expect(near(NSPoint(x: 700, y: slack), visible: screen, orientation: .bottom, band: .infinity))
        #expect(!near(NSPoint(x: 700, y: slack + 0.5), visible: screen, orientation: .bottom, band: .infinity))
    }

    @Test func hostileInsetIsClampedToTheMaximumDockSize() {
        // A nonsense visibleFrame far above the screen: the inset it implies is clamped, not trusted.
        let visible = NSRect(x: 0, y: 5000, width: 1440, height: 900)
        let limit = DockGeometry.maxDockSize + slack
        #expect(near(NSPoint(x: 700, y: limit), visible: visible, orientation: .bottom))
        #expect(!near(NSPoint(x: 700, y: limit + 0.5), visible: visible, orientation: .bottom))
    }

    @Test func nonFiniteValuesFallBackToTheOtherMeasurement() {
        // Only the proximity slack is left when the chosen measurement is unusable.
        let below = NSRect(x: 0, y: -20, width: 1440, height: 920)  // a negative inset
        #expect(near(NSPoint(x: 700, y: slack), visible: below, orientation: .bottom))
        #expect(!near(NSPoint(x: 700, y: slack + 0.5), visible: below, orientation: .bottom))
        #expect(!near(NSPoint(x: 700, y: 40), visible: below, orientation: .bottom))

        let notANumber = NSRect(x: 0, y: CGFloat.nan, width: 1440, height: 900)
        #expect(near(NSPoint(x: 700, y: 44 + slack), visible: notANumber, orientation: .bottom, band: 44))
        #expect(!near(NSPoint(x: 700, y: 44 + slack + 0.5), visible: notANumber, orientation: .bottom, band: 44))

        // A NaN band is dropped, so the reserved inset still decides on its own.
        let reserved = NSRect(x: 0, y: 72, width: 1440, height: 828)
        #expect(near(NSPoint(x: 700, y: 72 + slack), visible: reserved, orientation: .bottom, band: CGFloat.nan))
        #expect(!near(NSPoint(x: 700, y: 72 + slack + 0.5), visible: reserved, orientation: .bottom, band: CGFloat.nan))
    }

    @Test func screenWithNegativeOrigin() {
        // A second display to the left of the primary one: frames start at a negative x.
        let second = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let bottom = NSRect(x: -1440, y: 70, width: 1440, height: 830)
        #expect(near(NSPoint(x: -720, y: 40), visible: bottom, orientation: .bottom, frame: second))
        #expect(near(NSPoint(x: -720, y: 70 + slack), visible: bottom, orientation: .bottom, frame: second))
        #expect(!near(NSPoint(x: -720, y: 70 + slack + 0.5), visible: bottom, orientation: .bottom, frame: second))
        #expect(!near(NSPoint(x: -720, y: 450), visible: bottom, orientation: .bottom, frame: second))

        // Left Dock on that display: distances grow away from screenFrame.minX, which is negative.
        let left = NSRect(x: -1368, y: 0, width: 1368, height: 900)
        #expect(near(NSPoint(x: -1400, y: 450), visible: left, orientation: .left, frame: second))
        #expect(near(NSPoint(x: -1440 + 72 + slack, y: 450), visible: left, orientation: .left, frame: second))
        #expect(!near(NSPoint(x: -1440 + 72 + slack + 0.5, y: 450), visible: left, orientation: .left, frame: second))
        #expect(!near(NSPoint(x: -720, y: 450), visible: left, orientation: .left, frame: second))

        // Right Dock on that display: the right edge of the screen is x == 0, so the band is measured
        // from 0 backwards — the case a minX-based formula would get wrong.
        let right = NSRect(x: -1440, y: 0, width: 1368, height: 900)  // maxX == -72
        #expect(near(NSPoint(x: -40, y: 450), visible: right, orientation: .right, frame: second))
        #expect(near(NSPoint(x: -72 - slack + 0.5, y: 450), visible: right, orientation: .right, frame: second))
        #expect(!near(NSPoint(x: -72 - slack - 0.5, y: 450), visible: right, orientation: .right, frame: second))
        #expect(!near(NSPoint(x: -400, y: 450), visible: right, orientation: .right, frame: second))
    }

    @Test func rectangleToleranceIsInclusive() {
        let rect = NSRect(x: -100, y: 20, width: 200, height: 100)
        #expect(DockGeometry.contains(rect, NSPoint(x: -100, y: 20), tolerance: 0))
        #expect(DockGeometry.contains(rect, NSPoint(x: 100, y: 120), tolerance: 0))
        #expect(!DockGeometry.contains(rect, NSPoint(x: 101, y: 20), tolerance: 0))
        #expect(DockGeometry.contains(rect, NSPoint(x: 101, y: 20), tolerance: 1))
        #expect(!DockGeometry.contains(rect, NSPoint(x: 101.5, y: 20), tolerance: 1))
        #expect(DockGeometry.contains(rect, NSPoint(x: -101, y: 120), tolerance: 1))
        #expect(!DockGeometry.contains(rect, NSPoint(x: 0, y: 18.5), tolerance: 1))
        #expect(DockGeometry.contains(rect, NSPoint(x: 0, y: 18.5), tolerance: 2))
    }
}

/// Placement of the panel, also pure: `panelFrame` takes the screen rects, so a second display and a
/// screen smaller than the panel can be checked without a real display attached.
@MainActor
@Suite("DockGeometry panel frame")
struct DockGeometryPanelFrameTests {
    @Test func panelIsCenteredOnAScreenWithNegativeOrigin() {
        let frame = NSRect(x: -1728, y: 0, width: 1728, height: 1117)
        let visible = NSRect(x: -1728, y: 70, width: 1728, height: 1047)
        let panel = DockGeometry.panelFrame(size: NSSize(width: 844, height: 577), anchor: .zero,
                                            screenFrame: frame, visibleFrame: visible, orientation: .bottom)
        #expect(panel.midX == visible.midX && panel.midY == visible.midY)
        #expect(panel.minX < 0)
    }

    @Test func panelKeepsTheGapFromTheDockEdge() {
        let frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let visible = NSRect(x: 0, y: 80, width: 1000, height: 720)
        // A panel that only just fits vertically sits `gap` above the reserved Dock strip.
        let panel = DockGeometry.panelFrame(size: NSSize(width: 1000 - 2 * DockGeometry.gap,
                                                         height: 720 - 2 * DockGeometry.gap),
                                            anchor: .zero, screenFrame: frame, visibleFrame: visible,
                                            orientation: .bottom)
        #expect(panel.minY == visible.minY + DockGeometry.gap)
        #expect(panel.minX == visible.minX + DockGeometry.gap)
        #expect(panel.maxY == visible.maxY - DockGeometry.gap)
    }

    @Test func oversizedPanelPinsToTheLowEdgeOfANegativeScreen() {
        let frame = NSRect(x: -1440, y: 0, width: 1440, height: 900)
        let visible = NSRect(x: -1440, y: 70, width: 1440, height: 830)
        let panel = DockGeometry.panelFrame(size: NSSize(width: 1430, height: 900), anchor: .zero,
                                            screenFrame: frame, visibleFrame: visible, orientation: .bottom)
        // Wider than visibleFrame minus the two gaps: clamp has no room, so it keeps the low edge.
        #expect(panel.minX == visible.minX + DockGeometry.gap)
        #expect(panel.minY == visible.minY + DockGeometry.gap)
    }

    @Test func orientationAndBandDoNotMoveThePanel() {
        // Kept in the signature for callers; the panel is centered whatever the Dock does.
        let visible = NSRect(x: 0, y: 80, width: 1440, height: 820)
        let size = NSSize(width: 600, height: 400)
        let bottom = DockGeometry.panelFrame(size: size, anchor: .zero, screenFrame: visible,
                                             visibleFrame: visible, orientation: .bottom, dockBand: 0)
        let left = DockGeometry.panelFrame(size: size, anchor: .zero, screenFrame: visible,
                                           visibleFrame: visible, orientation: .left, dockBand: 96)
        #expect(bottom == left)
    }
}

/// The location rules of `InstallLocation`: which of the three answers a launch gets, where the copy
/// goes and which volume may be detached. The UI (two `NSAlert`s, the copy, `xcodebuild`-style
/// launching) is not touched here; those paths need a mounted image and user input.
@MainActor
@Suite("InstallLocation")
struct InstallLocationTests {
    @Test func copyInApplicationsSaysNothing() {
        #expect(InstallLocation.advice(forBundleAt: "/Applications/MenuFold.app", isWritableOnVolume: true)
                == .nothing)
        #expect(InstallLocation.advice(forBundleAt: "/Applications/MenuFold.app", isWritableOnVolume: false)
                == .nothing)
    }

    @Test func readOnlyDiskImageOffersTheMove() {
        #expect(InstallLocation.advice(forBundleAt: "/Volumes/MenuFold/MenuFold.app", isWritableOnVolume: false)
                == .offerMove)
        #expect(InstallLocation.advice(forBundleAt: "/Volumes/MenuFold 0.9.0/MenuFold.app", isWritableOnVolume: false)
                == .offerMove)
    }

    @Test func writableVolumeUnderVolumesSaysNothing() {
        // An external drive the user installed into on purpose: no offer, no copy, no eject.
        #expect(InstallLocation.advice(forBundleAt: "/Volumes/Backup/MenuFold.app", isWritableOnVolume: true)
                == .nothing)
    }

    @Test func translocatedCopyOnlyExplains() {
        let translocated = "/private/var/folders/6k/xy2/T/AppTranslocation/3F1A9C74-2B6E-4C1D-8A55-1E0B7D2C9F40/d/MenuFold.app"
        #expect(InstallLocation.advice(forBundleAt: translocated, isWritableOnVolume: false)
                == .explainTranslocation)
        // Running it from a translocated copy is not a disk image, so no copy is offered.
        #expect(InstallLocation.advice(forBundleAt: translocated, isWritableOnVolume: true)
                == .explainTranslocation)
    }

    @Test func diskImageRuleComesBeforeTranslocation() {
        // Both symptoms at once can only be a Mounted image: copying is the useful thing to offer.
        #expect(InstallLocation.advice(forBundleAt: "/Volumes/MenuFold/AppTranslocation/MenuFold.app",
                                       isWritableOnVolume: false) == .offerMove)
    }

    @Test func lookalikePathsAreNotTreatedAsDownloads() {
        // Downloads, Desktop and a folder merely named like the system one need no alert at all;
        // macOS has either translocated the app (covered above) or the user moved it already.
        #expect(InstallLocation.advice(forBundleAt: "/Users/me/Downloads/MenuFold.app", isWritableOnVolume: true)
                == .nothing)
        #expect(InstallLocation.advice(forBundleAt: "/Users/me/Volumes/MenuFold.app", isWritableOnVolume: false)
                == .nothing)
        #expect(InstallLocation.advice(forBundleAt: "/Users/me/MyAppTranslocation/MenuFold.app", isWritableOnVolume: false)
                == .nothing)
        #expect(InstallLocation.advice(forBundleAt: "", isWritableOnVolume: false) == .nothing)
    }

    @Test func answerDoesNotDependOnTheNumberOfAsks() {
        // There is no "already offered" flag: the rule is a pure function of the path, and it stops
        // asking by itself once the app really is in /Applications.
        let dmg = "/Volumes/MenuFold/MenuFold.app"
        #expect(InstallLocation.advice(forBundleAt: dmg, isWritableOnVolume: false)
                == InstallLocation.advice(forBundleAt: dmg, isWritableOnVolume: false))
        let moved = InstallLocation.installDestination(for: URL(fileURLWithPath: dmg, isDirectory: true))
        #expect(InstallLocation.advice(forBundleAt: moved.path, isWritableOnVolume: true) == .nothing)
    }

    @Test func destinationKeepsTheBundleName() {
        let shipped = URL(fileURLWithPath: "/Volumes/MenuFold/MenuFold.app", isDirectory: true)
        let destination = InstallLocation.installDestination(for: shipped)
        #expect(destination.lastPathComponent == "MenuFold.app")
        #expect(destination.deletingLastPathComponent().path == "/Applications")
        #expect(destination.hasDirectoryPath)
        // A renamed copy would be updated by Sparkle as a different app, so the name travels along.
        let renamed = URL(fileURLWithPath: "/Volumes/MenuFold/MenuFold 0.9.0.app", isDirectory: true)
        #expect(InstallLocation.installDestination(for: renamed).path == "/Applications/MenuFold 0.9.0.app")
    }

    @Test func volumeRootIsFoundForABundleInsideIt() {
        #expect(InstallLocation.volumeRoot(ofBundleAt: "/Volumes/MenuFold/MenuFold.app") == "/Volumes/MenuFold")
        #expect(InstallLocation.volumeRoot(ofBundleAt: "/Volumes/My Disk/MenuFold.app") == "/Volumes/My Disk")
        #expect(InstallLocation.volumeRoot(ofBundleAt: "/Volumes/MenuFold/deep/MenuFold.app") == "/Volumes/MenuFold")
    }

    @Test func volumeRootIsNilOutsideAVolume() {
        // Nothing outside /Volumes may reach `hdiutil detach`: it would detach a real disk.
        #expect(InstallLocation.volumeRoot(ofBundleAt: "/Applications/MenuFold.app") == nil)
        #expect(InstallLocation.volumeRoot(ofBundleAt: "/Users/me/Downloads/MenuFold.app") == nil)
        #expect(InstallLocation.volumeRoot(ofBundleAt: "/Volumes") == nil)
        #expect(InstallLocation.volumeRoot(ofBundleAt: "") == nil)
        // "/Volumes" merely appearing deeper in the path is not a volume root.
        #expect(InstallLocation.volumeRoot(ofBundleAt: "/Users/me/Volumes/MenuFold.app") == nil)
    }
}
