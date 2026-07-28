import Foundation

/// Orchestrates the capture → STT → overlay pipeline.
/// Owns a CaptureEngine and an SttClient, routing data between them.
/// Optionally persists sessions, segments, and suggestions to a SessionStore.
@MainActor
public final class SessionEngine {
    public let captureEngine: CaptureEngine
    public let sttClient: SttClient
    public let viewModel: OverlayViewModel
    public let sessionStore: SessionStore?

    /// The ID of the currently active session (nil when not running).
    public private(set) var currentSessionId: UUID?

    private var captureTask: Task<Void, Never>?
    private var sttTask: Task<Void, Never>?
    private var questionTask: Task<Void, Never>?

    // Callbacks
    public var onQuestionDetected: ((String) -> Void)?

    /// "auto" = level meter controls speech indicator; "pushToTalk" = PTT hotkey controls it.
    public var listenMode: String = "auto"

    /// True while the push-to-talk hotkey is physically held down.
    /// Suppresses auto question-detection in auto mode.
    private var isPTTKeyHeld = false

    // MARK: - Init

    public init(
        captureEngine: CaptureEngine,
        sttClient: SttClient,
        viewModel: OverlayViewModel,
        sessionStore: SessionStore? = nil
    ) {
        self.captureEngine = captureEngine
        self.sttClient = sttClient
        self.viewModel = viewModel
        self.sessionStore = sessionStore
    }

    // MARK: - Lifecycle

    public func startSession() async throws {
        viewModel.goLive()
        viewModel.show()

        // Create and persist session if store is available
        if let store = sessionStore {
            let session = Session(
                profileId: UUID(),  // App delegates set this before calling
                mode: .behavioral,
                status: .live
            )
            let created = try await store.createSession(session)
            currentSessionId = created.id
        }

        try await captureEngine.start()
        try await sttClient.start()

        // Route audio from capture to STT.
        // In PTT mode, only send audio while the key is held — no transcription during silence.
        captureTask = Task { [weak self] in
            guard let self else { return }
            for await buffer in self.captureEngine.audioStream {
                if self.listenMode == "pushToTalk" && !self.isPTTKeyHeld { continue }
                await self.sttClient.sendAudio(buffer.data)
            }
        }

        // Monitor level meter for speech detection visual feedback.
        // In PTT mode, only update indicator while the PTT key is held.
        // After release, stopListening() clears it and ambient noise won't re-enable.
        Task { [weak self] in
            guard let self else { return }
            for await level in self.captureEngine.levelMeter {
                let isSpeaking = level > 0.05
                await MainActor.run {
                    if self.listenMode == "pushToTalk" {
                        if self.isPTTKeyHeld && isSpeaking {
                            self.viewModel.setDetectingSpeech(true)
                        }
                    } else {
                        self.viewModel.setDetectingSpeech(isSpeaking)
                    }
                }
            }
        }

        // Route transcripts from STT to overlay + persist final segments.
        // Heuristic speaker tagging: system-active → interviewer, mic-active → candidate.
        sttTask = Task { [weak self] in
            guard let self else { return }
            for await segment in self.sttClient.transcriptStream {
                let speaker = self.resolveSpeaker()
                let tagged = TranscriptSegment(
                    id: segment.id,
                    sessionId: segment.sessionId,
                    timestamp: segment.timestamp,
                    speaker: speaker,
                    text: segment.text,
                    isFinal: segment.isFinal,
                    confidence: segment.confidence
                )
                self.viewModel.appendTranscript(tagged)

                // Persist only final segments to avoid excessive writes
                if segment.isFinal, let store = self.sessionStore, let sid = self.currentSessionId {
                    let segmentToStore = TranscriptSegment(
                        id: tagged.id,
                        sessionId: sid,
                        timestamp: tagged.timestamp,
                        speaker: tagged.speaker,
                        text: tagged.text,
                        isFinal: tagged.isFinal,
                        confidence: tagged.confidence
                    )
                    try? await store.appendSegment(segmentToStore, to: sid)
                }
            }
        }

        // Route question detection — restart STT so next utterance starts fresh.
        // In PTT mode, only triggerPTTAnswer() drives question detection.
        // In auto mode, suppressed while the PTT key is held; key-up triggers answer directly.
        // Mic tap feeds the detector; gate ensures only system-side silence fires.
        if let capture = captureEngine as? CaptureEngineImpl {
            capture.onQuestionDetected = { [weak self] in
                fputs("[DEBUG-b4e1] SessionEngine — listenMode: \(self?.listenMode ?? "nil")\n", stderr)
                guard let self, self.listenMode != "pushToTalk", !self.isPTTKeyHeld else {
                    fputs("[DEBUG-b4e1] SessionEngine BAILED\n", stderr)
                    return
                }
                if let lastUser = self.viewModel.chatMessages.last(where: { $0.role == .user }) {
                    fputs("[DEBUG-b4e1] SessionEngine — found lastUser, firing LLM\n", stderr)
                    // Persist question as a segment before LLM answers.
                    // SFSpeechRecognizer rarely emits isFinal during continuous dictation,
                    // and restartRecognition() cancels the old task before a final result arrives.
                    self.persistQuestion(lastUser.text)
                    self.onQuestionDetected?(lastUser.text)
                } else {
                    fputs("[DEBUG-b4e1] SessionEngine — NO lastUser\n", stderr)
                }
                if let appleStt = self.sttClient as? AppleSttClient {
                    appleStt.restartRecognition()
                }
            }
        }
    }

    public func stopSession() async throws {
        // Stop capture first — no more audio
        captureTask?.cancel()
        try await captureEngine.stop()

        // Stop STT — this finishes the transcript stream
        try await sttClient.stop()

        // Wait for STT task to finish processing any remaining buffered segments
        if let task = sttTask {
            await task.value
        }

        questionTask?.cancel()

        // Mark session as done
        if let store = sessionStore, let sid = currentSessionId {
            if var session = try await store.fetchSession(sid) {
                session.status = .done
                session.endedAt = Date()
                // SessionStore doesn't have an update method, so we delete and recreate
                try await store.deleteSession(sid)
                _ = try await store.createSession(session)
            }
        }
        currentSessionId = nil

        viewModel.endSession()
    }

    // MARK: - Push-to-Talk

    /// Key-down: enable VAD, suppress auto-detection, show listening indicator.
    public func startListening() {
        isPTTKeyHeld = true
        captureEngine.enableVAD()
        viewModel.setDetectingSpeech(true)
    }

    /// Key-up: capture transcript, trigger answer, clean up state.
    public func triggerPTTAnswer() {
        guard isPTTKeyHeld else { return }
        isPTTKeyHeld = false
        // Persist question + trigger answer with current transcript
        if let lastUser = viewModel.chatMessages.last(where: { $0.role == .user }) {
            persistQuestion(lastUser.text)
            onQuestionDetected?(lastUser.text)
        }
        if let appleStt = sttClient as? AppleSttClient {
            appleStt.restartRecognition()
        }
        // Clean up — only called in PTT mode (hotkey gated in AppDelegate)
        stopListening()
    }

    /// Disable VAD and clear listening indicator.
    public func stopListening() {
        isPTTKeyHeld = false
        captureEngine.disableVAD()
        viewModel.setDetectingSpeech(false)
    }

    /// Propagate listenMode change from settings to a running engine.
    /// - Parameter mode: "auto" or "pushToTalk"
    public func updateListenMode(_ mode: String) {
        guard mode != listenMode else { return }
        listenMode = mode
        if mode == "pushToTalk" {
            captureEngine.disableVAD()
        } else {
            captureEngine.enableVAD()
        }
    }

    // MARK: - Speaker Attribution

    /// Resolve the current speaker based on which audio source is active.
    /// System active → interviewer (.system). Mic active → candidate (.mic).
    /// Both active → prefer system. Neither → unknown.
    private func resolveSpeaker() -> TranscriptSegment.Speaker {
        if captureEngine.isSystemSpeaking {
            return .system
        } else if captureEngine.isMicSpeaking {
            return .mic
        }
        return .unknown
    }

    // MARK: - Question Persistence

    /// Persist a question text as a final transcript segment.
    /// Needed because SFSpeechRecognizer rarely emits isFinal during continuous dictation,
    /// and restartRecognition() cancels the task before a final result arrives.
    private func persistQuestion(_ text: String) {
        guard let store = sessionStore, let sid = currentSessionId else { return }
        let segment = TranscriptSegment(
            sessionId: sid,
            timestamp: Date(),
            speaker: .mic,
            text: text,
            isFinal: true
        )
        Task {
            try? await store.appendSegment(segment, to: sid)
        }
    }

    // MARK: - Suggestion Persistence

    /// Persist a suggestion to the session store.
    /// Called by App.handleQuestion after LLM completion.
    public func persistSuggestion(_ suggestion: Suggestion) async {
        guard let store = sessionStore, let sid = currentSessionId else { return }
        let suggestionToStore = Suggestion(
            id: suggestion.id,
            sessionId: sid,
            segmentId: suggestion.segmentId,
            timestamp: suggestion.timestamp,
            type: suggestion.type,
            content: suggestion.content,
            metadata: suggestion.metadata
        )
        try? await store.appendSuggestion(suggestionToStore, to: sid)
    }
}
