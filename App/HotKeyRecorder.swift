import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A Settings control that records a global shortcut.
///
/// Click it, then press the combination: the next key down (in this app, while the Settings window
/// stays key) becomes the shortcut. A shortcut needs at least one of ⌘⌥⌃, except F1–F12, which may
/// stand alone; anything else beeps and keeps recording, and so do the standard app commands
/// (⌘Q, ⌘W, ⌘C, …), which would otherwise stop working in every app. Esc cancels and ⌫ clears the shortcut
/// (both without modifiers). A local `NSEvent` monitor is used rather than SwiftUI key handling
/// because only the monitor sees ⌘-combinations before the menu bar acts on them.
struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey?

    @State private var session = HotKeyRecordingSession()

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if session.isRecording {
                    session.stop()
                } else {
                    session.start { hotKey = $0 }
                }
            } label: {
                Text(label)
                    .monospacedDigit()
                    .frame(minWidth: 150)
            }
            .buttonStyle(.glass)
            .tint(session.isRecording ? .accentColor : nil)
            .accessibilityHint(Text("Натисніть, а потім натисніть сполучення клавіш"))

            if hotKey != nil, !session.isRecording {
                Button {
                    hotKey = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(Text("Прибрати сполучення"))
                .accessibilityLabel(Text("Прибрати сполучення"))
            }
        }
        .onDisappear { session.stop() }
    }

    private var label: String {
        if session.isRecording { return String(localized: "Натисніть сполучення…") }
        return hotKey?.displayString ?? String(localized: "Не задано")
    }
}

/// Owns the key monitor of one recording, so it is removed however the recording ends (a key,
/// a second click, the window losing key status or the view going away).
@MainActor
@Observable
final class HotKeyRecordingSession {
    private(set) var isRecording = false

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var resignObserver: NSObjectProtocol?

    /// `commit` receives the new shortcut, or nil when the user cleared it with ⌫.
    func start(commit: @escaping (HotKey?) -> Void) {
        stop()
        // `HotKeyManager` unregisters the current shortcut meanwhile; Carbon would grab it first.
        NotificationCenter.default.post(name: .menuFoldHotKeyRecording, object: true)
        // Recording belongs to the window it started in; a key pressed elsewhere is not ours.
        let window = NSApp.keyWindow
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only a Bool crosses the isolation boundary (NSEvent is not Sendable).
            let outcome = Self.interpret(event)
            let isOurs = event.window === window
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isRecording, isOurs else { return false }
                switch outcome {
                case .cancel:
                    self.stop()
                case .clear:
                    commit(nil)
                    self.stop()
                case .record(let key):
                    commit(key)
                    self.stop()
                case .reject:
                    NSSound.beep()
                }
                return true
            }
            return consumed ? nil : event
        }
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop() }
            }
        }
    }

    /// Ends the recording however it ended (key, click, resign, view gone). Posts the "stopped"
    /// notification only once per recording, so `HotKeyManager` re-registers exactly once.
    func stop() {
        let wasRecording = isRecording
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if wasRecording {
            NotificationCenter.default.post(name: .menuFoldHotKeyRecording, object: false)
        }
    }

    private enum Outcome {
        case cancel, clear, reject
        case record(HotKey)
    }

    private nonisolated static let functionKeys: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]

    /// ⌘ + these keys are the standard commands of every Mac app (quit, close, hide, minimize,
    /// app switcher, Spotlight, clipboard, undo, select all); a global shortcut would steal them.
    private nonisolated static let reservedCommandKeys: Set<Int> = [
        kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_H, kVK_ANSI_M, kVK_Tab, kVK_Space,
        kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_A,
    ]

    private nonisolated static func interpret(_ event: NSEvent) -> Outcome {
        let code = Int(event.keyCode)
        let modifiers = carbonModifiers(event.modifierFlags)
        let hasRequiredModifier = modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        if modifiers == 0 {
            if code == kVK_Escape { return .cancel }
            if code == kVK_Delete || code == kVK_ForwardDelete { return .clear }
        }
        guard hasRequiredModifier || functionKeys.contains(code) else { return .reject }
        if modifiers == UInt32(cmdKey), reservedCommandKeys.contains(code) { return .reject }
        return .record(HotKey(keyCode: UInt32(code), carbonModifiers: modifiers))
    }

    /// Cocoa modifier flags → Carbon modifier mask, as `RegisterEventHotKey` expects.
    nonisolated static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }
}

#Preview {
    @Previewable @State var key: HotKey? = HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
    HotKeyRecorder(hotKey: $key)
        .padding()
}
