import AppKit
import SwiftUI
import Combine

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlayPanel: OverlayPanel?
    private var hotkeyManager: HotkeyManager?
    private nonisolated(unsafe) var preflightWindow: NSWindow?
    private nonisolated(unsafe) var settingsWindow: NSWindow?
    private nonisolated(unsafe) var responsibleUseWindow: NSWindow?
    private nonisolated(unsafe) var historyWindow: NSWindow?

    let viewModel = OverlayViewModel()
    let profileStore = ProfileStore()
    let preflightVM: PreflightViewModel
    let settingsStore = SettingsStore()
    let providerStore = ProviderConfigStore()
    let sessionStore = SessionStoreImpl()
    var sessionEngine: SessionEngine?
    var selectedProfile: Profile?
    private var cancellables = Set<AnyCancellable>()
    private var pendingStopTask: Task<Void, Never>?

    override init() {
        self.preflightVM = PreflightViewModel(profileStore: profileStore)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupHotkey()
        setupSettingsSync()
        enforceRetention()

        // Show Responsible Use on first launch
        if !OnboardingState.hasShownResponsibleUse {
            showResponsibleUse()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "rectangle.and.text.magnifyingglass",
                accessibilityDescription: "SessionCopilot"
            )
        }

        let menu = NSMenu()
        let overlayItem = NSMenuItem(title: "Show Overlay", action: #selector(showOverlay), keyEquivalent: "o")
        overlayItem.target = self
        menu.addItem(overlayItem)
        let stopItem = NSMenuItem(title: "Stop Session", action: #selector(stopSession), keyEquivalent: "s")
        stopItem.target = self
        menu.addItem(stopItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let historyItem = NSMenuItem(title: "Session History...", action: #selector(openHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)
        let captureItem = NSMenuItem(title: "Capture Coding Problem", action: #selector(captureCodingProblem), keyEquivalent: "a")
        captureItem.target = self
        menu.addItem(captureItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager = HotkeyManager()
        // Show/Hide overlay
        _ = hotkeyManager?.register(key: "o", modifiers: [.command, .shift]) { [weak self] in
            self?.viewModel.toggle()
            self?.syncOverlayVisibility()
        }
        // Start/Stop session
        _ = hotkeyManager?.register(key: "s", modifiers: [.command, .shift]) { [weak self] in
            self?.toggleSession()
        }
        // Copy last suggestion
        _ = hotkeyManager?.register(key: "c", modifiers: [.command, .shift]) { [weak self] in
            self?.copyLastSuggestion()
        }
        // Region capture for coding assist
        _ = hotkeyManager?.register(key: "a", modifiers: [.command, .shift]) { [weak self] in
            self?.captureCodingProblem()
        }
        // Push-to-talk: works in BOTH modes.
        // PTT hotkey is only active in push-to-talk mode.
        // In auto mode, questions are detected automatically — PTT is disabled.
        let pttKey = parsePTTKey(settingsStore.settings.hotkeys.pushToTalk)
        _ = hotkeyManager?.registerPTT(key: pttKey, modifiers: [.control, .shift], onDown: { [weak self] in
            guard let self, self.settingsStore.settings.listenMode == "pushToTalk" else { return }
            self.sessionEngine?.startListening()
        }, onUp: { [weak self] in
            guard let self, self.settingsStore.settings.listenMode == "pushToTalk" else { return }
            self.sessionEngine?.triggerPTTAnswer()
        })
    }

    /// Parse push-to-talk key from hotkey string like "opt+shift+space" → " ".
    /// Maps friendly names ("space", "return", "tab") to their NSEvent character equivalents.
    private func parsePTTKey(_ hotkey: String) -> String {
        let parts = hotkey.split(separator: "+")
        // Last component is the key character; middle components are modifiers (opt/shift/cmd/ctrl)
        let raw = parts.last.map(String.init) ?? "space"
        // Map friendly names to the character NSEvent produces
        switch raw.lowercased() {
        case "space": return " "
        case "return", "enter": return "\r"
        case "tab": return "\t"
        case "escape", "esc": return "\u{1b}"
        case "delete", "backspace": return "\u{7f}"
        default: return raw
        }
    }

    // MARK: - Overlay

    @objc private func showOverlay() {
        preflightVM.refresh()
        if preflightVM.allGranted {
            goLive()
        } else {
            showPreflight()
        }
    }

    @objc private func stopSession() {
        stopCapture()
        selectedProfile = nil
        viewModel.endSession()
        viewModel.hide()
        syncOverlayVisibility()
    }

    private func syncOverlayVisibility() {
        if viewModel.isVisible {
            preflightWindow?.close()
            preflightWindow = nil

            // Pull initial values from persisted settings
            viewModel.opacity = settingsStore.settings.opacity
            viewModel.clickThrough = settingsStore.settings.clickThrough

            if overlayPanel == nil {
                overlayPanel = OverlayPanel(viewModel: viewModel)
                overlayPanel?.onPanelClose = { [weak self] in
                    self?.stopCapture()
                }
            }
            overlayPanel?.alphaValue = viewModel.opacity
            overlayPanel?.ignoresMouseEvents = viewModel.clickThrough
            overlayPanel?.makeKeyAndOrderFront(nil)
        } else {
            overlayPanel?.close()
            overlayPanel = nil
        }
    }

    private func goLive() {
        // Capture the selected profile before starting
        selectedProfile = preflightVM.selectedProfile

        viewModel.goLive()
        viewModel.show()
        syncOverlayVisibility()
        startCapture()
    }

    private func startCapture() {
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
        let stt: SttClient
        let sttProvider = settingsStore.settings.sttProvider
        let sttLanguage = settingsStore.settings.sttLanguage

        if sttProvider == "deepgram",
           let deepgramConfig = providerStore.defaultConfig(for: .deepgram),
           let apiKey = providerStore.getKey(for: deepgramConfig) {
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
            viewModel: viewModel,
            sessionStore: sessionStore
        )
        engine.listenMode = settingsStore.settings.listenMode
        sessionEngine = engine

        // Wire question detection → answer generation
        engine.onQuestionDetected = { [weak self] questionText in
            self?.handleQuestion(questionText)
        }

        // In push-to-talk mode, disable VAD before starting — user presses hotkey to enable.
        // Must happen synchronously BEFORE startSession() so the detector is off when
        // audio starts flowing; avoids a race with the async Task.
        if settingsStore.settings.listenMode == "pushToTalk" {
            capture.disableVAD()
        }

        Task {
            if let appleStt = stt as? AppleSttClient {
                try? await appleStt.configure(SttConfig(provider: .nemo, model: "apple-on-device", language: sttLanguage))
            }
            try? await engine.startSession()
        }
    }

    private func handleQuestion(_ questionText: String) {
        let trimmed = questionText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        viewModel.startAssistantResponse()
        viewModel.clearError()
        viewModel.setStreaming(true)

        Task {
            let client = LlmClientImpl()

            // Use user's default provider config from ProviderConfigStore
            let providerConfig = providerStore.defaultConfig() ?? ProviderConfig(
                provider: .deepseek,
                baseURL: "https://api.deepseek.com",
                model: "deepseek-v4-flash",
                apiKeyRef: "com.sessioncopilot.deepseek-key",
                isDefault: true
            )

            // Load API key from Keychain or env
            let apiKey = (try? KeychainStore().load(key: providerConfig.apiKeyRef))
                ?? ProcessInfo.processInfo.environment["\(providerConfig.provider.rawValue.uppercased())_API_KEY"]

            guard let key = apiKey, !key.isEmpty else {
                await MainActor.run {
                    self.viewModel.finalizeAssistantResponse()
                    self.viewModel.setStreaming(false)
                    self.viewModel.setError("No API key for \(providerConfig.provider.rawValue.capitalized). Add it in Settings → Providers.")
                }
                return
            }

            do {
                try client.configure(providerConfig, apiKey: key)

                // Build prompt: grounded in profile template if available, fallback to bare question
                let prompt: String
                if let profile = selectedProfile {
                    // Load template and inject profile context via ContextBuilder
                    let loader = PromptLoader()
                    let vars = ContextBuilder.buildVariables(
                        profile: profile,
                        chatMessages: viewModel.chatMessages,
                        questionText: questionText,
                        language: settingsStore.settings.sttLanguage
                    )
                    // If template loads successfully, use it; otherwise fall back to ContextBuilder's inline prompt
                    if let rendered = try? loader.loadAndRender("behavioral/answer_outline", variables: vars) {
                        prompt = rendered
                    } else {
                        prompt = ContextBuilder.behavioral(
                            profile: profile,
                            chatMessages: viewModel.chatMessages,
                            questionText: questionText,
                            language: settingsStore.settings.sttLanguage
                        )
                    }
                } else {
                    prompt = """
                    Interview question: "\(questionText)"

                    Give ONLY a concise answer outline in bullet points. No greetings, no examples, no narration.
                    Use STAR format if applicable.
                    End with 2-3 brief coach tips (one line each).
                    """
                }

                let request = LlmRequest(
                    model: settingsStore.settings.defaultModels[viewModel.sessionMode.defaultModelKey]
                        ?? providerConfig.model,
                    mode: .behavioral,
                    prompt: prompt,
                    maxTokens: 250
                )

                var fullResponse = ""
                for await token in client.streamCompletion(request) {
                    fullResponse += token.text
                    await MainActor.run {
                        self.viewModel.updateAssistantResponse(fullResponse)
                    }
                    if token.isDone { break }
                }
                if fullResponse.isEmpty {
                    self.viewModel.setError("LLM returned empty response")
                } else {
                    // Persist the completed suggestion
                    if let engine = self.sessionEngine, let sid = engine.currentSessionId {
                        await engine.persistSuggestion(Suggestion(
                            sessionId: sid,
                            type: .answerOutline,
                            content: fullResponse,
                            metadata: ["model": providerConfig.model, "provider": providerConfig.provider.rawValue]
                        ))
                    }
                }
                self.viewModel.finalizeAssistantResponse()
                self.viewModel.setStreaming(false)
            } catch {
                await MainActor.run {
                    self.viewModel.finalizeAssistantResponse()
                    self.viewModel.setStreaming(false)
                    self.viewModel.setError("LLM error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopCapture() {
        // Capture engine reference and nil immediately so re-open works
        // even before the async stop completes
        let engine = sessionEngine
        sessionEngine = nil
        pendingStopTask?.cancel()
        pendingStopTask = Task { [weak self] in
            try? await engine?.stopSession()
            await MainActor.run {
                self?.pendingStopTask = nil
            }
        }
    }

    // MARK: - Hotkey Actions

    private func toggleSession() {
        if sessionEngine != nil {
            // Session is running → stop
            stopCapture()
            selectedProfile = nil
            viewModel.endSession()
            viewModel.hide()
            syncOverlayVisibility()
        } else {
            // No session → start (show overlay/preflight)
            showOverlay()
        }
    }

    private func copyLastSuggestion() {
        let text = viewModel.lastAssistantResponse
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Settings Sync

    /// Sync overlay opacity/clickThrough changes back to persisted settings.
    private func setupSettingsSync() {
        viewModel.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                // Only update if values actually changed to avoid save loops
                if self.settingsStore.settings.opacity != self.viewModel.opacity {
                    self.settingsStore.settings.opacity = self.viewModel.opacity
                }
                if self.settingsStore.settings.clickThrough != self.viewModel.clickThrough {
                    self.settingsStore.settings.clickThrough = self.viewModel.clickThrough
                }
            }
            .store(in: &cancellables)

        // Propagate listenMode changes from Settings → running engine
        settingsStore.$settings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] settings in
                self?.sessionEngine?.updateListenMode(settings.listenMode)
            }
            .store(in: &cancellables)
    }

    // MARK: - Retention

    private func enforceRetention() {
        let retentionDays = settingsStore.settings.retentionDays
        Task {
            try? await sessionStore.deleteSessionsOlderThan(days: retentionDays)
        }
    }

    // MARK: - Coding Assist

    private var regionCapture: RegionCapture?
    private var codingLanguage: String = "python"

    @objc private func captureCodingProblem() {
        showOverlay()
        viewModel.show()
        syncOverlayVisibility()

        Task {
            regionCapture = RegionCapture()
            guard let imageBase64 = await regionCapture?.captureRegion() else {
                return
            }

            await MainActor.run {
                self.viewModel.startAssistantResponse()
                self.viewModel.setStreaming(true)
            }

            await handleCodingCapture(imageBase64: imageBase64)
        }
    }

    private func handleCodingCapture(imageBase64: String) async {
        let client = LlmClientImpl()

        let providerConfig = providerStore.defaultConfig() ?? ProviderConfig(
            provider: .deepseek,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            apiKeyRef: "com.sessioncopilot.deepseek-key",
            isDefault: true
        )

        let apiKey = (try? KeychainStore().load(key: providerConfig.apiKeyRef))
            ?? ProcessInfo.processInfo.environment["\(providerConfig.provider.rawValue.uppercased())_API_KEY"]

        guard let key = apiKey, !key.isEmpty else {
            await MainActor.run {
                self.viewModel.finalizeAssistantResponse()
                self.viewModel.setStreaming(false)
                self.viewModel.setError("No API key for \(providerConfig.provider.rawValue.capitalized). Add it in Settings → Providers.")
            }
            return
        }

        do {
            try client.configure(providerConfig, apiKey: key)

            // Load prompt template based on mode
            let loader = PromptLoader()
            let prompt: String
            let mode: LlmRequest.Mode

            switch viewModel.sessionMode {
            case .systemDesign:
                let vars = ContextBuilder.buildSystemDesignVariables(
                    problemText: "[Problem captured from screen — see image]"
                )
                prompt = (try? loader.loadAndRender("coding/system_design", variables: vars))
                    ?? "Analyze the system design problem shown in the image."
                mode = .coding  // No .systemDesign in LlmRequest.Mode, use .coding

            case .coding:
                let vars = ContextBuilder.buildCodingVariables(
                    problemText: "[Problem captured from screen — see image]",
                    language: codingLanguage
                )
                prompt = (try? loader.loadAndRender("coding/approach", variables: vars))
                    ?? ContextBuilder.coding(problemText: "[Problem captured from screen — see image]", language: codingLanguage)
                mode = .coding

            default:
                // For behavioral/meeting, still use coding prompt with image
                let vars = ContextBuilder.buildCodingVariables(
                    problemText: "[Problem captured from screen — see image]",
                    language: codingLanguage
                )
                prompt = (try? loader.loadAndRender("coding/approach", variables: vars))
                    ?? ContextBuilder.coding(problemText: "[Problem captured from screen — see image]", language: codingLanguage)
                mode = .coding
            }

            let request = LlmRequest(
                model: providerConfig.model,
                mode: mode,
                prompt: prompt,
                imageBase64: imageBase64,
                maxTokens: 800
            )

            var fullResponse = ""
            for await token in client.streamCompletion(request) {
                fullResponse += token.text
                await MainActor.run {
                    self.viewModel.updateAssistantResponse(fullResponse)
                }
                if token.isDone { break }
            }

            await MainActor.run {
                if fullResponse.isEmpty {
                    self.viewModel.setError("LLM returned empty response")
                }
                self.viewModel.finalizeAssistantResponse()
                self.viewModel.setStreaming(false)
            }
        } catch {
            await MainActor.run {
                self.viewModel.finalizeAssistantResponse()
                self.viewModel.setStreaming(false)
                self.viewModel.setError("LLM error: \(error.localizedDescription)")
            }
        }
    }

    private func showPreflight() {
        let vm = preflightVM // capture strongly
        var timer: Timer?

        let preflightView = PreflightView(viewModel: vm) { [weak self] in
            timer?.invalidate() // stop polling before any window changes
            self?.goLive()
        }
        let hostingView = NSHostingView(rootView: preflightView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 450),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SessionCopilot — Preflight"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        observeWindowClose(window) { [weak self] in
            self?.preflightWindow = nil
        }
        window.makeKeyAndOrderFront(nil)
        preflightWindow = window

        // Poll permissions
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak vm] _ in
            Task { @MainActor [weak vm] in
                vm?.refresh()
            }
        }
    }

    // MARK: - Responsible Use

    private func showResponsibleUse() {
        let view = ResponsibleUseView { [weak self] in
            self?.responsibleUseWindow?.close()
            self?.responsibleUseWindow = nil
        }
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to SessionCopilot"
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        observeWindowClose(window) { [weak self] in
            self?.responsibleUseWindow = nil
        }
        window.makeKeyAndOrderFront(nil)
        responsibleUseWindow = window
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(settingsStore: settingsStore, providerStore: providerStore, profileStore: profileStore)
            let hostingView = NSHostingView(rootView: settingsView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SessionCopilot Settings"
            window.contentView = hostingView
            window.center()
            window.isReleasedWhenClosed = false
            observeWindowClose(window) { [weak self] in
                self?.settingsWindow = nil
            }
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Session History

    @objc private func openHistory() {
        if historyWindow == nil {
            let historyView = SessionHistoryView(store: sessionStore)
            let hostingView = NSHostingView(rootView: historyView)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 550, height: 400),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Session History"
            window.contentView = hostingView
            window.center()
            window.isReleasedWhenClosed = false
            observeWindowClose(window) { [weak self] in
                self?.historyWindow = nil
            }
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window lifecycle

    /// Register for NSWindowWillCloseNotification to nil out the reference.
    /// Prevents zombie window crashes when calling makeKeyAndOrderFront after close.
    private func observeWindowClose(_ window: NSWindow, handler: @escaping @Sendable () -> Void) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            handler()
        }
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
