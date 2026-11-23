import AppKit
import Carbon.HIToolbox
import MenuFoldCore
import Observation

/// The global shortcut from `AppPreferences.hotKey` that toggles the panel from any app.
///
/// Carbon's `RegisterEventHotKey` is used on purpose: it is the one global-shortcut API that needs no
/// Accessibility or Input Monitoring permission (an `NSEvent` global monitor would need both, and
/// could not swallow the key). The hot key event reaches the application event target even while
/// another app is active.
@MainActor
@Observable
final class HotKeyManager {
    static let shared = HotKeyManager()

    /// Called on the main actor when the shortcut is pressed.
    @ObservationIgnored var onPress: (() -> Void)?

    /// 'MnFd': tags our hot key so the handler ignores anyone else's on the same target.
    nonisolated static let signature: OSType = 0x4D6E_4664

    /// Id of the main (panel) shortcut of the main shortcut; per-app/folder ones count up from 2.
    private static let mainID: UInt32 = 1

    @ObservationIgnored private var handlerRef: EventHandlerRef?
    /// What is registered right now: the main shortcut under `mainKey`, the rest under their
    /// `AppHotkey` keys ("app:…" / "folder:…").
    @ObservationIgnored private var registered: [String: HotKey] = [:]
    @ObservationIgnored private var refs: [UInt32: EventHotKeyRef] = [:]
    @ObservationIgnored private var idToKey: [UInt32: String] = [:]
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var recordingObserver: NSObjectProtocol?
    /// True while Settings records a new shortcut: the current ones must be free to press there.
    @ObservationIgnored private var isRecording = false
    @ObservationIgnored private var hasApplied = false

    static let mainKey = "main"
    /// Key of the clipboard shortcut in `registered`, `conflicts` and the Settings list. It can never
    /// clash with a layout entry, whose keys are "app:…" / "folder:…".
    static let clipboardKey = "clipboard"

    /// Called on the main actor when a per-app or per-folder shortcut is pressed (the `AppHotkey` key).
    @ObservationIgnored var onTargetPress: ((String) -> Void)?
    /// Called when `AppPreferences.clipboardHotKey` is pressed.
    @ObservationIgnored var onClipboardPress: (() -> Void)?

    /// Shortcuts that macOS refused (`eventHotKeyExistsErr`: another app owns the combination),
    /// by key. Settings shows them; the entry stays stored and is retried when anything changes.
    private(set) var conflicts: [String: HotKey] = [:]

    /// The model whose `Layout.appHotkeys` are registered; changes are followed live.
    @ObservationIgnored var model: GridModel? {
        didSet { observeModel() }
    }

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

    /// Releases the shortcuts (before a relaunch, so the new copy can register them).
    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let recordingObserver { NotificationCenter.default.removeObserver(recordingObserver) }
        recordingObserver = nil
        isRecording = false
        unregister()
    }

    private func observeModel() {
        guard let model else { return }
        withObservationTracking {
            _ = model.layout.appHotkeys
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.model === model else { return }
                self.apply()
                self.observeModel()
            }
        }
        apply()
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
            let pressed = id.id
            // Carbon calls this on the main thread; hop explicitly so the actor checker agrees.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyManager.shared.pressed(pressed) }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        if status != noErr { NSLog("%@", "MenuFold: InstallEventHandler failed (\(status))") }
    }

    private func pressed(_ id: UInt32) {
        if id == Self.mainID { onPress?(); return }
        guard let key = idToKey[id] else { return }
        // The clipboard shortcut has its own handler; every other key here belongs to a layout entry.
        if key == Self.clipboardKey { onClipboardPress?(); return }
        onTargetPress?(key)
    }

    /// The shortcuts that should be registered now.
    private var wanted: [String: HotKey] {
        var all: [String: HotKey] = [:]
        for (key, value) in model?.layout.appHotkeys ?? [:] {
            all[key] = HotKey(keyCode: value.keyCode, carbonModifiers: value.modifiers)
        }
        if let main = AppPreferences.shared.hotKey { all[Self.mainKey] = main }
        if let clipboard = AppPreferences.shared.clipboardHotKey { all[Self.clipboardKey] = clipboard }
        return all
    }

    /// Applies only the difference between what is registered and what is wanted (preferences post for
    /// every switch), so unchanged shortcuts are never dropped, not even for a moment. Conflicting
    /// ones are retried on every call.
    private func apply() {
        guard !isRecording else { return }
        let wanted = wanted
        guard !hasApplied || wanted != registered || !conflicts.isEmpty else { return }
        hasApplied = true
        // Drop what is gone or changed.
        for (id, key) in idToKey where wanted[key] != registered[key] {
            if let ref = refs[id] { UnregisterEventHotKey(ref) }
            refs[id] = nil
            idToKey[id] = nil
        }
        for key in Array(conflicts.keys) where wanted[key] != conflicts[key] { conflicts[key] = nil }
        registered = registered.filter { wanted[$0.key] == $0.value }
        // The main shortcut first, so it wins a clash with a per-app one stored by hand.
        for (key, hotKey) in wanted.sorted(by: { ($0.key == Self.mainKey ? "" : $0.key) < ($1.key == Self.mainKey ? "" : $1.key) }) {
            if registered[key] != nil { continue }
            let id: UInt32
            if key == Self.mainKey {
                id = Self.mainID
            } else {
                id = (idToKey.keys.max() ?? Self.mainID) + 1
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonModifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[id] = ref
                idToKey[id] = key
                registered[key] = hotKey
                conflicts[key] = nil
            } else {
                // Typically `eventHotKeyExistsErr`: another app owns this combination.
                if conflicts[key] == nil {
                    NSLog("%@", "MenuFold: could not register the hot key \(hotKey.displayString) for \(key) (\(status))")
                }
                conflicts[key] = hotKey
            }
        }
    }

    private func unregister() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        idToKey = [:]
        registered = [:]
        conflicts = [:]
        hasApplied = false
    }
}

extension HotKey {
    init(_ hotkey: AppHotkey) { self.init(keyCode: hotkey.keyCode, carbonModifiers: hotkey.modifiers) }
    var stored: AppHotkey { AppHotkey(keyCode: keyCode, modifiers: carbonModifiers) }
}

extension AppDelegate {
    /// A per-app or per-folder shortcut was pressed (`Layout.appHotkeys` key). An app is launched
    /// (or brought forward) right away; a folder opens in the panel.
    func handleHotkey(key: String) {
        noteExternalCommand()
        if key.hasPrefix("app:") {
            launchApp(id: String(key.dropFirst(4)))
        } else if key.hasPrefix("folder:"), let id = UUID(uuidString: String(key.dropFirst(7))) {
            showPanel(folderID: id)
        }
    }
}
