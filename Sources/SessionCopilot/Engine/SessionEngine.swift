import Foundation
import os

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
    /// Subscribes to captureEngine.audioStream and writes PCM to
    /// `audioRecorder`. Nil when audio recording is disabled or
    /// the session hasn't started yet.
    private var recordingTask: Task<Void, Never>?
    /// Active recorder for the current session. Nil when not recording.
    private var audioRecorder: AudioRecorder?
    /// Whether audio recording is enabled for this session. Set from
    /// `AppSettings.audioRecordingEnabled` at `startSession()` time.
    private var audioRecordingEnabled: Bool = false

    // Callbacks
    public var onQuestionDetected: ((String) -> Void)?

    /// "auto" = level meter controls speech indicator; "pushToTalk" = PTT hotkey controls it.
    public var listenMode: String = "auto"

    /// True while the push-to-talk hotkey is physically held down.
    /// Suppresses auto question-detection in auto mode.
    private var isPTTKeyHeld = false

    /// Rolling buffer of all STT transcript text. Continuously updated.
    private var transcriptBuffer: String = ""

    /// Snapshot of `transcriptBuffer` taken at system-silent transition,
    /// with a 0.5s grace period for STT to catch up. Used as the question
    /// text when the detector fires.
    private var pendingQuestionText: String = ""

    /// Timestamp when system audio first went silent. Used to allow a
    /// grace period where pendingQuestionText can still be updated by
    /// late-arriving STT transcripts.
    private var systemSilentSince: Date?

    /// Whether system audio was active on the last level meter sample.
    private var wasSystemSpeaking = false

    /// The question text that was last sent to the LLM.
    private var lastFiredQuestionText: String = ""

    /// True when a batch STT flush has been triggered and we're waiting
    /// for the transcript to arrive through `transcriptStream`. When the
    /// next `isFinal` segment arrives, it fires the LLM.
    private var pendingBatchQuestion = false

    // MARK: - Init

    public init(
        captureEngine: CaptureEngine,
        sttClient: SttClient,
        viewModel: OverlayViewModel,
        sessionStore: SessionStore? = nil,
        audioRecordingEnabled: Bool = true
    ) {
        self.captureEngine = captureEngine
        self.sttClient = sttClient
        self.viewModel = viewModel
        self.sessionStore = sessionStore
        self.audioRecordingEnabled = audioRecordingEnabled
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

            // Start audio recording if enabled and we have a session ID.
            if audioRecordingEnabled {
                startAudioRecording(sessionId: created.id, store: store)
            }
        }

        transcriptBuffer = ""
        pendingQuestionText = ""
        systemSilentSince = nil
        wasSystemSpeaking = false
        lastFiredQuestionText = ""
        pendingBatchQuestion = false
        Log.session.info("Session starting — listenMode=\(self.listenMode, privacy: .public), stt=\(type(of: self.sttClient))")
        try await captureEngine.start()
        try await sttClient.start()

        // Route audio from capture to STT and to the audio recorder.
        // IMPORTANT: AsyncStream does NOT broadcast — multiple iterators
        // divide elements between them. We use a single for-await loop
        // to fan out each buffer to both consumers.
        // In PTT mode, only send audio while the key is held — no
        // transcription during silence.
        captureTask = Task { [weak self] in
            guard let self else { return }
            let recorder = self.audioRecorder  // capture reference once
            for await buffer in self.captureEngine.audioStream {
                if self.listenMode == "pushToTalk" && !self.isPTTKeyHeld { continue }
                await self.sttClient.sendAudio(buffer.data)
                if self.audioRecordingEnabled {
                    recorder?.append(buffer.data)
                }
            }
        }

        // Monitor level meter for speech detection visual feedback.
        // Also snapshots the transcript buffer when system audio transitions
        // to silent — this captures the interviewer's question before the
        // candidate starts answering and fills the buffer with their voice.
        //
        // Debounce: the indicator must hold its state for at least 0.4s
        // before toggling. Without this, ambient noise hovering near the
        // 0.08 threshold causes rapid flickering between Listening/Live.
        //
        // In PTT mode, only update indicator while the PTT key is held.
        Task { [weak self] in
            guard let self else { return }
            var lastIndicatorChange = Date.distantPast
            let indicatorMinHold: TimeInterval = 0.4
            for await level in self.captureEngine.levelMeter {
                let isSpeaking = level > 0.08
                await MainActor.run {
                    // Detect system active→silent transition.
                    let systemActive = self.captureEngine.isSystemSpeaking
                    if self.wasSystemSpeaking && !systemActive {
                        self.pendingQuestionText = self.transcriptBuffer
                        self.systemSilentSince = Date()
                    }
                    self.wasSystemSpeaking = systemActive

                    if self.listenMode == "pushToTalk" {
                        if self.isPTTKeyHeld && isSpeaking {
                            self.viewModel.setDetectingSpeech(true)
                        }
                    } else {
                        let now = Date()
                        if now.timeIntervalSince(lastIndicatorChange) >= indicatorMinHold {
                            self.viewModel.setDetectingSpeech(isSpeaking)
                            lastIndicatorChange = now
                        }
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
                // Always accumulate the latest transcript into the rolling buffer.
                if !segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.transcriptBuffer = segment.text
                    // Also update pendingQuestionText during the 0.5s grace
                    // period after system audio goes silent. SFSpeechRecognizer
                    // delivers transcripts asynchronously — the real question
                    // text often arrives after the audio has already stopped.
                    if let silentSince = self.systemSilentSince,
                       Date().timeIntervalSince(silentSince) < 0.5 {
                        self.pendingQuestionText = segment.text
                    }
                }
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

                // Phase B for batch STT: when a final transcript arrives
                // after a silence-triggered flush, fire the LLM.
                if self.pendingBatchQuestion, segment.isFinal,
                   !segment.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    self.pendingBatchQuestion = false
                    self.viewModel.setTranscribing(false)
                    let questionText = segment.text.trimmingCharacters(in: .whitespaces)
                    Log.session.info("Batch transcript arrived — \"\(questionText.prefix(60), privacy: .public)\"")
                    guard questionText != self.lastFiredQuestionText else {
                        Log.session.debug("Duplicate batch transcript, skipping LLM")
                        continue
                    }
                    self.lastFiredQuestionText = questionText
                    self.persistQuestion(questionText)
                    self.onQuestionDetected?(questionText)
                    Log.session.info("LLM fired for batch question")
                }

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

        // Route question detection — for streaming STT (Apple), fire the LLM
        // immediately. For batch STT (Deepgram), trigger a flush and defer the
        // LLM fire to when the transcript arrives through transcriptStream.
        // In PTT mode, only triggerPTTAnswer() drives question detection.
        // In auto mode, suppressed while the PTT key is held.
        if let capture = captureEngine as? CaptureEngineImpl {
            capture.onQuestionDetected = { [weak self] in
                guard let self, self.listenMode != "pushToTalk", !self.isPTTKeyHeld else { return }

                Log.session.debug("Question detected — sttType=\(type(of: self.sttClient)), buffer=\"\(self.transcriptBuffer.prefix(40))\", pendingBatch=\(self.pendingBatchQuestion)")

                // Clear pending state from previous cycle.
                self.pendingQuestionText = ""
                self.transcriptBuffer = ""
                self.systemSilentSince = nil

                if self.sttClient is DeepgramSttClient {
                    // Batch mode: trigger flush, LLM fires when transcript arrives.
                    Log.session.info("Triggering batch flush")
                    self.viewModel.setTranscribing(true)
                    self.pendingBatchQuestion = true
                    Task { await (self.sttClient as? DeepgramSttClient)?.triggerFlush() }
                } else {
                    // Streaming mode (Apple STT): fire LLM immediately with
                    // whatever is in the transcript buffer or chat messages.
                    var questionText = self.pendingQuestionText.trimmingCharacters(in: .whitespaces)
                    if questionText.isEmpty {
                        questionText = self.transcriptBuffer.trimmingCharacters(in: .whitespaces)
                    }
                    if questionText.isEmpty {
                        questionText = self.viewModel.chatMessages
                            .last(where: { $0.role == .user })?.text
                            .trimmingCharacters(in: .whitespaces) ?? ""
                    }
                    guard !questionText.isEmpty else {
                        Log.session.debug("No question text available, skipping")
                        return
                    }
                    guard questionText != self.lastFiredQuestionText else {
                        Log.session.debug("Duplicate question text, skipping")
                        return
                    }

                    self.lastFiredQuestionText = questionText
                    self.persistQuestion(questionText)
                    self.onQuestionDetected?(questionText)

                    // Reset the recognizer so the next question starts
                    // fresh — otherwise the request accumulates across
                    // utterances and can deduplicate or return stale text.
                    if let appleStt = self.sttClient as? AppleSttClient {
                        appleStt.restartRecognition()
                    }
                }
            }
        }
    }

    public func stopSession() async throws {
        // Stop capture first — no more audio
        captureTask?.cancel()
        recordingTask?.cancel()
        recordingTask = nil
        try await captureEngine.stop()

        // Stop STT — this finishes the transcript stream
        try await sttClient.stop()

        // Wait for STT task to finish processing any remaining buffered segments
        if let task = sttTask {
            await task.value
        }

        questionTask?.cancel()

        // Close the audio recorder and persist the path on the session.
        if let recorder = audioRecorder {
            try? recorder.close()
            audioRecorder = nil
        }

        // Mark session as done
        if let store = sessionStore, let sid = currentSessionId {
            if var session = try await store.fetchSession(sid) {
                session.status = .done
                session.endedAt = Date()
                // Attach the audio file path so SessionDetailView can
                // find the WAV for playback. The relative filename is
                // stable across app launches (resolved against
                // AudioStorage.directory at playback time).
                if audioRecordingEnabled, session.audioFilePath == nil {
                    session.audioFilePath = AudioStorage().relativeFilename(forSessionId: sid)
                }
                // SessionStore doesn't have an update method, so we delete and recreate
                try await store.deleteSession(sid)
                _ = try await store.createSession(session)
            }
        }
        currentSessionId = nil

        viewModel.endSession()
    }

    // MARK: - Audio Recording

    /// Open an `AudioRecorder` for the session and persist its relative
    /// path on the stored `Session`. Called from `startSession()` when
    /// `audioRecordingEnabled` is true.
    private func startAudioRecording(sessionId: UUID, store: SessionStore) {
        let storage = AudioStorage()
        do {
            try storage.ensureDirectory()
            let url = storage.url(forSessionId: sessionId)
            let recorder = try AudioRecorder(fileURL: url)
            recorder.startRecording()
            audioRecorder = recorder

            // Persist the relative filename on the session immediately
            // so that if the app crashes mid-session, the file is still
            // discoverable in SessionDetailView (even though the session
            // won't be marked .done, the audio is recoverable).
            Task { [weak self] in
                guard let self else { return }
                if var session = try? await store.fetchSession(sessionId) {
                    session.audioFilePath = storage.relativeFilename(forSessionId: sessionId)
                    try? await store.deleteSession(sessionId)
                    _ = try? await store.createSession(session)
                }
            }
        } catch {
            Log.recording.error("Failed to start audio recording: \(error.localizedDescription, privacy: .public)")
            audioRecorder = nil
        }
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

        if let deepgramStt = sttClient as? DeepgramSttClient {
            // Batch mode: trigger flush, LLM fires when transcript arrives.
            viewModel.setTranscribing(true)
            pendingBatchQuestion = true
            transcriptBuffer = ""
            Task { await deepgramStt.triggerFlush() }
        } else {
            // Streaming mode: use transcript buffer immediately.
            let questionText = transcriptBuffer.trimmingCharacters(in: .whitespaces)
            transcriptBuffer = ""
            if !questionText.isEmpty {
                persistQuestion(questionText)
                onQuestionDetected?(questionText)
            }
            if let appleStt = sttClient as? AppleSttClient {
                appleStt.restartRecognition()
            }
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
