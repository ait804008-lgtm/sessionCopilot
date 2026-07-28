import AppKit

/// Manages global hotkey registration via NSEvent monitoring.
/// ponytail: NSEvent monitors instead of Carbon hotkeys — simpler API, no C bridging.
final class HotkeyManager {
    private var monitors: [Any] = []

    /// Register a global hotkey combo. Returns true if permissions allow.
    /// - Parameters:
    ///   - key: Single character key (e.g., "o")
    ///   - modifiers: Modifier flags (e.g., [.command, .shift])
    ///   - action: Closure to invoke when hotkey is pressed
    func register(key: String, modifiers: NSEvent.ModifierFlags, action: @escaping @MainActor () -> Void) -> Bool {
        let requiredMask = modifiers
        let requiredKey = key.lowercased()

        // Global monitor (works when app is not focused — requires Accessibility)
        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: requiredMask) else { return }
            guard event.charactersIgnoringModifiers?.lowercased() == requiredKey else { return }
            Task { @MainActor in action() }
        }
        monitors.append(global)

        // Local monitor (works when app is focused)
        let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: requiredMask) else { return event }
            guard event.charactersIgnoringModifiers?.lowercased() == requiredKey else { return event }
            Task { @MainActor in action() }
            return nil // consume the event
        }
        monitors.append(local)

        return true
    }

    /// Register a push-to-talk hotkey: fires onDown when pressed, onUp when released.
    /// Skips key-repeat events so onDown fires exactly once per press.
    /// Key-up does NOT check modifiers — user may release Ctrl/Shift before Space.
    func registerPTT(key: String, modifiers: NSEvent.ModifierFlags, onDown: @escaping @MainActor () -> Void, onUp: @escaping @MainActor () -> Void) -> Bool {
        let requiredMask = modifiers
        let requiredKey = key.lowercased()

        // --- Key DOWN: check modifiers (isSuperset, not ==) + key character ---
        let globalDown = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: requiredMask) else { return }
            guard event.charactersIgnoringModifiers?.lowercased() == requiredKey else { return }
            Task { @MainActor in onDown() }
        }
        monitors.append(globalDown)

        let localDown = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return event }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSuperset(of: requiredMask) else { return event }
            guard event.charactersIgnoringModifiers?.lowercased() == requiredKey else { return event }
            Task { @MainActor in onDown() }
            return nil
        }
        monitors.append(localDown)

        // --- Key UP: check ONLY key character, NOT modifiers ---
        // The user may release Ctrl/Shift before releasing Space.
        // The key character is enough to identify the release.
        let globalUp = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { event in
            guard event.charactersIgnoringModifiers?.lowercased() == requiredKey else { return }
            Task { @MainActor in onUp() }
        }
        monitors.append(globalUp)

        let localUp = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            guard event.charactersIgnoringModifiers?.lowercased() == requiredKey else { return event }
            Task { @MainActor in onUp() }
            return nil
        }
        monitors.append(localUp)

        return true
    }

    func unregister() {
        for m in monitors {
            NSEvent.removeMonitor(m)
        }
        monitors.removeAll()
    }

    deinit { unregister() }
}
