import AppKit
import Carbon.HIToolbox

/// The global shortcut from `AppPreferences.hotKey` that toggles the panel from any app.
///
/// Carbon's `RegisterEventHotKey` is used on purpose: it is the one global-shortcut API that needs no
/// Accessibility or Input Monitoring permission (an `NSEvent` global monitor would need both, and
/// could not swallow the key). The hot key event reaches the application event target even while
/// another app is active.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// Called on the main actor when the shortcut is pressed.
    var onPress: (() -> Void)?

    /// 'MnFd': tags our hot key so the handler ignores anyone else's on the same target.
    nonisolated static let signature: OSType = 0x4D6E_4664

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered: HotKey?
    private var observer: NSObjectProtocol?
    private var recordingObserver: NSObjectProtocol?
    /// True while Settings records a new shortcut: the current one must be free to press there.
    private var isRecording = false

    private init() {}

    /// Installs the event handler, registers the current shortcut and follows preference changes.
    func start() {
        installHandlerIfNeeded()
        apply()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .menuFoldPreferencesChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.apply() }
        }
        // The recorder posts `true` when it starts listening and `false` when it is done: a
        // registered hot key would swallow the very combination the user is trying to record.
        recordingObserver = NotificationCenter.default.addObserver(
            forName: .menuFoldHotKeyRecording, object: nil, queue: .main
        ) { [weak self] note in
            let recording = note.object as? Bool ?? false
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRecording = recording
                if recording { self.unregister() } else { self.apply() }
            }
        }
    }

    /// Releases the shortcut (before a relaunch, so the new copy can register it).
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let recordingObserver { NotificationCenter.default.removeObserver(recordingObserver) }
        recordingObserver = nil
        isRecording = false
        unregister()
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HotKeyManager.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon calls this on the main thread; hop explicitly so the actor checker agrees.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyManager.shared.onPress?() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        if status != noErr { NSLog("%@", "MenuFold: InstallEventHandler failed (\(status))") }
    }

    /// Re-registers only when the shortcut really changed (preferences post for every switch).
    private func apply() {
        guard !isRecording else { return }
        let wanted = AppPreferences.shared.hotKey
        guard wanted != registered || (wanted != nil && hotKeyRef == nil) else { return }
        unregister()
        guard let wanted else { return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(wanted.keyCode, wanted.carbonModifiers, id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeyRef = ref
            registered = wanted
        } else {
            // Typically `eventHotKeyExistsErr`: another app owns this combination.
            NSLog("%@", "MenuFold: could not register the hot key \(wanted.displayString) (\(status))")
            registered = wanted
        }
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
    }
}
