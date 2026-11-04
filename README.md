# MenuFold

**MenuFold** is a native macOS SwiftUI & AppKit application that replaces the default Dock "Applications" stack with a polished, fast, and feature-rich app grid.

Pinned directly in your Dock like a normal app, clicking MenuFold opens a borderless panel centered on your screen, featuring:
- **Grid of all installed apps** with smooth scrolling and responsive layout.
- **Custom folders** created instantly via simple drag-and-drop (one level deep, with custom titles, colors, and SF symbols).
- **Automatic category tabs** to easily browse apps by type (e.g. Productivity, Games, Utilities, Social, etc.).
- **Instant search** that searches across all apps and inside folders simultaneously.
- **Finder folders integration**, automatically surfacing real subfolders of `/Applications` and `~/Applications` (such as Utilities).
- **Liquid Glass aesthetics** leveraging modern macOS visual effects (`NSGlassEffectView`) with smooth scale and blur animations.

MenuFold operates entirely independently without patching the Dock or any system process (no SIP changes required).

---

## System Requirements

- **macOS** 26+ (developed on macOS 27)
- **Xcode** (for building from source)
- **XcodeGen** (`brew install xcodegen`)

---

## Architecture & Structure

MenuFold is split into two layers:
1. **`Packages/MenuFoldCore`**: Pure Swift business logic package (App catalog scanning via Spotlight, app filtering rules, layout persistence, finder folders virtualization, and `@Observable` grid models). Fully unit-tested with Swift Testing.
2. **`App/`**: AppKit & SwiftUI presentation layer (`MenuFoldApp`, `PanelController`, window chrome, Liquid Glass glass layer, Dock geometry calculations, and views).

---

## Building and Running

### Building Logic & Running Tests (Command Line Tools)
```bash
cd Packages/MenuFoldCore
swift build
swift test
```

### Building & Running the App (Xcode required)
```bash
# Generate Xcode project and build into ./build
scripts/build.sh

# Build, terminate any running copy, and open the new one
scripts/build.sh run
```

---

## License

This project is licensed under the [MIT License](LICENSE).
