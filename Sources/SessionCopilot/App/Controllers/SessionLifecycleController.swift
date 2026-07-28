import Foundation
import os

/// Owns the `SessionEngine` lifecycle: creation, start, stop, and
/// coordination of the pending-stop task that prevents re-entrancy
/// when the user rapidly toggles the session.
///
/// Extracted from `AppDelegate.startCapture()` / `stopCapture()` /
/// `toggleSession()` as part of the controller split. The actual
/// LLM-answer orchestration lives in `LlmOrchestrator`; this controller
/// only wires up the capture→STT→overlay pipeline.
@MainActor
public final class SessionLifecycleController {
    private let services: Services
    public private(set) var sessionEngine: SessionEngine?
    public var selectedProfile: Profile?
    private var pendingStopTask: Task<Void, Never>?

    /// Called when a new question is detected (post-classification if
    /// semantic detection is enabled). Wired to `LlmOrchestrator.handleQuestion`.
    public var onQuestionDetected: ((String) -> Void)?

    /// Called when the capture engine's high-level status changes.
    /// Wired to `MenuBarController.updateStatus`.
    public var onCaptureStatusChange: ((CaptureStatus) -> Void)?

    public init(services: Services) {
        self.services = services
    }

    // MARK: - Lifecycle

    public func startCapture() {
        guard sessionEngine == nil else { return }

        // If a previous stop is still in progress (e.g. SFSpeechRecognizer not released),
        // defer the new engine creation until the stop completes
        if let task = pendingStopTask {
            Task { [weak self] in
                await task.value
                await MainActor.run {
                    self?.startCapture() // retry after stop completes
                }
            }
            return
        }

        let capture = CaptureEngineImpl(captureSystemAudio: true)
        // Subscribe to status changes → menu bar indicator.
        capture.onStatusChange = { [weak self] status in
            self?.onCaptureStatusChange?(status)
        }

        let stt: SttClient
        let sttProvider = services.settingsStore.settings.sttProvider
        let sttLanguage = services.settingsStore.settings.sttLanguage

        if sttProvider == "deepgram",
           let deepgramConfig = services.providerStore.defaultConfig(for: .deepgram),
           let apiKey = services.providerStore.getKey(for: deepgramConfig) {
            let deepgramStt = DeepgramSttClient()
            Task {
                try? await deepgramStt.configure(SttConfig(
                    provider: .deepgram,
                    model: deepgramConfig.model,
                    language: sttLanguage,
                    apiKey: apiKey
                ))
            }
            stt = deepgramStt
        } else {
            stt = AppleSttClient()
        }

        let engine = SessionEngine(
            captureEngine: capture,
            sttClient: stt,
            viewModel: services.viewModel,
            sessionStore: services.sessionStore,
            audioRecordingEnabled: services.settingsStore.settings.audioRecordingEnabled
        )
        engine.listenMode = services.settingsStore.settings.listenMode
        sessionEngine = engine

        // Wire question detection → answer generation (via orchestrator)
        engine.onQuestionDetected = { [weak self] questionText in
            self?.onQuestionDetected?(questionText)
        }

        // In push-to-talk mode, disable VAD before starting — user presses hotkey to enable.
        if services.settingsStore.settings.listenMode == "pushToTalk" {
            capture.disableVAD()
        }

        Task {
            if let appleStt = stt as? AppleSttClient {
                try? await appleStt.configure(SttConfig(provider: .nemo, model: "apple-on-device", language: sttLanguage))
            }
            try? await engine.startSession()
        }
    }

    public func stopCapture() {
        let engine = sessionEngine
        sessionEngine = nil
        pendingStopTask?.cancel()
        pendingStopTask = Task { [weak self] in
            try? await engine?.stopSession()
            await MainActor.run {
                self?.pendingStopTask = nil
                self?.onCaptureStatusChange?(.idle)
            }
        }
    }

    public func toggleSession(onStart: () -> Void, onStop: () -> Void) {
        if sessionEngine != nil {
            onStop()
        } else {
            onStart()
        }
    }

    // MARK: - Push-to-talk pass-through

    public func startListening() {
        sessionEngine?.startListening()
    }

    public func triggerPTTAnswer() {
        sessionEngine?.triggerPTTAnswer()
    }

    public func stopListening() {
        sessionEngine?.stopListening()
    }

    // MARK: - Settings sync

    public func updateListenMode(_ mode: String) {
        sessionEngine?.updateListenMode(mode)
    }
}
