import AppKit
import os

/// Owns `HotkeyManager` and registers all global / local hotkeys.
///
/// Extracted from `AppDelegate.setupHotkey()` as part of the controller
/// split. Forwards hotkey activations to its delegate (typically
/// `AppDelegate`) which routes them to the appropriate controller.
@MainActor
public final class HotkeyController {
    private let hotkeyManager = HotkeyManager()
    public weak var delegate: HotkeyControllerDelegate?

    private let settingsStore: SettingsStore

    public init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Register all hotkeys. Should be called once from
    /// `applicationDidFinishLaunching`.
    public func registerAll() {
        // Show/Hide overlay
        _ = hotkeyManager.register(key: "o", modifiers: [.command, .shift]) { [weak self] in
            self?.delegate?.hotkeyDidTriggerToggleOverlay()
        }
        // Start/Stop session
        _ = hotkeyManager.register(key: "s", modifiers: [.command, .shift]) { [weak self] in
            self?.delegate?.hotkeyDidTriggerToggleSession()
        }
        // Copy last suggestion
        _ = hotkeyManager.register(key: "c", modifiers: [.command, .shift]) { [weak self] in
            self?.delegate?.hotkeyDidTriggerCopyLastSuggestion()
        }
        // Region capture for coding assist
        _ = hotkeyManager.register(key: "a", modifiers: [.command, .shift]) { [weak self] in
            self?.delegate?.hotkeyDidTriggerCodingCapture()
        }
        // Push-to-talk: works in BOTH modes.
        // PTT hotkey is only active in push-to-talk mode.
        // In auto mode, questions are detected automatically — PTT is disabled.
        let pttKey = parsePTTKey(settingsStore.settings.hotkeys.pushToTalk)
        _ = hotkeyManager.registerPTT(
            key: pttKey,
            modifiers: [.control, .shift],
            onDown: { [weak self] in
                self?.delegate?.hotkeyDidTriggerPTTDown()
            },
            onUp: { [weak self] in
                self?.delegate?.hotkeyDidTriggerPTTUp()
            }
        )

        Log.hotkey.info("Registered all hotkeys")
    }

    /// Parse push-to-talk key from hotkey string like "opt+shift+space" → " ".
    /// Maps friendly names ("space", "return", "tab") to their NSEvent character equivalents.
    /// Kept here (rather than in `HotkeyManager`) because it depends on
    /// `AppSettings.Hotkeys.pushToTalk` string format.
    private func parsePTTKey(_ hotkey: String) -> String {
        let parts = hotkey.split(separator: "+")
        let raw = parts.last.map(String.init) ?? "space"
        switch raw.lowercased() {
        case "space": return " "
        case "return", "enter": return "\r"
        case "tab": return "\t"
        case "escape", "esc": return "\u{1b}"
        case "delete", "backspace": return "\u{7f}"
        default: return raw
        }
    }
}

@MainActor
public protocol HotkeyControllerDelegate: AnyObject {
    func hotkeyDidTriggerToggleOverlay()
    func hotkeyDidTriggerToggleSession()
    func hotkeyDidTriggerCopyLastSuggestion()
    func hotkeyDidTriggerCodingCapture()
    func hotkeyDidTriggerPTTDown()
    func hotkeyDidTriggerPTTUp()
}
