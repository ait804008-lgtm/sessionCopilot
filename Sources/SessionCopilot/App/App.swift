import AppKit
import SwiftUI
import Combine
import os

// MARK: - App Delegate
//
// Thin composition root. Owns:
//   - `Services` (shared stores: viewModel, settingsStore, etc.)
//   - `MenuBarController` (status item + menu)
//   - `HotkeyController` (global / local hotkeys)
//   - `WindowController` (preflight, settings, history, overlay panel)
//   - `SessionLifecycleController` (capture→STT→overlay pipeline)
//   - `LlmOrchestrator` (LLM calls + question classification)
//
// AppDelegate itself only contains:
//   - `applicationDidFinishLaunching` (wire controllers)
//   - `MenuBarControllerDelegate` (route menu actions)
//   - `HotkeyControllerDelegate` (route hotkey activations)
//   - Settings sync (Combine sink to propagate listenMode)
//   - Retention enforcement
//
// All real work lives in the controllers. AppDelegate is the seam.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var services: Services!
    private var menuBarController: MenuBarController!
    private var hotkeyController: HotkeyController!
    private var windowController: WindowController!
    private var sessionLifecycle: SessionLifecycleController!
    private var llmOrchestrator: LlmOrchestrator!

    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. Build shared services
        services = Services.makeDefault()

        // 2. Build controllers
        menuBarController = MenuBarController()
        hotkeyController = HotkeyController(settingsStore: services.settingsStore)
        windowController = WindowController(services: services)
        sessionLifecycle = SessionLifecycleController(services: services)
        llmOrchestrator = LlmOrchestrator(services: services, sessionLifecycle: sessionLifecycle)

        // 3. Wire delegates (menu → AppDelegate → controllers)
        menuBarController.delegate = self
        hotkeyController.delegate = self

        // 4. Wire inter-controller callbacks
        // Capture status → menu bar indicator
        sessionLifecycle.onCaptureStatusChange = { [weak self] status in
            self?.menuBarController.updateStatus(status)
        }
        // Question detected → LLM orchestrator
        sessionLifecycle.onQuestionDetected = { [weak self] questionText in
            self?.llmOrchestrator.handleQuestion(questionText)
        }
        // Overlay closed by user → stop capture
        windowController.onOverlayClose = { [weak self] in
            self?.stopCapture()
        }

        // 5. Register hotkeys
        hotkeyController.registerAll()

        // 6. Settings sync (overlay opacity ↔ persisted settings;
        //    listenMode changes → running SessionEngine)
        setupSettingsSync()

        // 7. Enforce retention on launch
        enforceRetention()

        // 8. Show Responsible Use on first launch
        if !OnboardingState.hasShownResponsibleUse {
            windowController.showResponsibleUse()
        }

        Log.app.info("SessionCopilot launched — controllers wired")
    }

    // MARK: - Settings Sync

    /// Bidirectional sync between `OverlayViewModel` and `SettingsStore`
    /// for opacity / click-through, plus listen-mode propagation to a
    /// running `SessionEngine`.
    private func setupSettingsSync() {
        services.viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.services.settingsStore.settings.opacity != self.services.viewModel.opacity {
                    self.services.settingsStore.settings.opacity = self.services.viewModel.opacity
                }
                if self.services.settingsStore.settings.clickThrough != self.services.viewModel.clickThrough {
                    self.services.settingsStore.settings.clickThrough = self.services.viewModel.clickThrough
                }
            }
            .store(in: &cancellables)

        services.settingsStore.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                self?.sessionLifecycle.updateListenMode(settings.listenMode)
            }
            .store(in: &cancellables)
    }

    // MARK: - Retention

    private func enforceRetention() {
        let retentionDays = services.settingsStore.settings.retentionDays
        Task {
            try? await services.sessionStore.deleteSessionsOlderThan(days: retentionDays)
        }
    }

    // MARK: - Session Lifecycle (delegate entry points)

    /// Show the overlay (or preflight if permissions missing).
    func showOverlay() {
        services.preflightVM.refresh()
        if services.preflightVM.allGranted {
            goLive()
        } else {
            windowController.showPreflight { [weak self] in
                self?.goLive()
            }
        }
    }

    /// Stop the current session and hide the overlay.
    func stopSession() {
        stopCapture()
        sessionLifecycle.selectedProfile = nil
        services.viewModel.endSession()
        services.viewModel.hide()
        windowController.syncOverlayVisibility()
    }

    private func goLive() {
        sessionLifecycle.selectedProfile = services.preflightVM.selectedProfile
        services.viewModel.goLive()
        services.viewModel.show()
        windowController.syncOverlayVisibility()
        sessionLifecycle.startCapture()
    }

    private func stopCapture() {
        sessionLifecycle.stopCapture()
    }
}

// MARK: - MenuBarControllerDelegate

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarDidRequestShowOverlay() {
        showOverlay()
    }

    func menuBarDidRequestStopSession() {
        stopSession()
    }

    func menuBarDidRequestOpenSettings() {
        windowController.openSettings()
    }

    func menuBarDidRequestOpenHistory() {
        windowController.openHistory()
    }

    func menuBarDidRequestCaptureCodingProblem() {
        services.viewModel.show()
        windowController.syncOverlayVisibility()
        llmOrchestrator.captureCodingProblem()
    }
}

// MARK: - HotkeyControllerDelegate

extension AppDelegate: HotkeyControllerDelegate {
    func hotkeyDidTriggerToggleOverlay() {
        services.viewModel.toggle()
        windowController.syncOverlayVisibility()
    }

    func hotkeyDidTriggerToggleSession() {
        if sessionLifecycle.sessionEngine != nil {
            stopSession()
        } else {
            showOverlay()
        }
    }

    func hotkeyDidTriggerCopyLastSuggestion() {
        llmOrchestrator.copyLastSuggestion()
    }

    func hotkeyDidTriggerCodingCapture() {
        services.viewModel.show()
        windowController.syncOverlayVisibility()
        llmOrchestrator.captureCodingProblem()
    }

    func hotkeyDidTriggerPTTDown() {
        guard services.settingsStore.settings.listenMode == "pushToTalk" else { return }
        sessionLifecycle.startListening()
    }

    func hotkeyDidTriggerPTTUp() {
        guard services.settingsStore.settings.listenMode == "pushToTalk" else { return }
        sessionLifecycle.triggerPTTAnswer()
    }
}

// MARK: - SwiftUI App

@main
struct SessionCopilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
