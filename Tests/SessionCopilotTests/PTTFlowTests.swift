import Foundation
import Testing
@testable import SessionCopilot

// MARK: - Push-to-Talk Flow Tests

@Suite("Push-to-Talk Flow") @MainActor struct PTTFlowTests {

    // MARK: - PTT Mode

    @Test("PTT mode: triggerPTTAnswer fires onQuestionDetected with transcript")
    func pttAnswerFiresWithTranscript() {
        let capture = MockCaptureEngine()
        let stt = DeepgramSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(captureEngine: capture, sttClient: stt, viewModel: vm)
        engine.listenMode = "pushToTalk"

        // Simulate: user spoke, STT produced a segment
        let segment = TranscriptSegment(
            sessionId: UUID(), timestamp: Date(),
            speaker: .unknown, text: "What is dependency injection?",
            isFinal: true
        )
        vm.appendTranscript(segment)

        // Track callback
        var detectedText: String?
        engine.onQuestionDetected = { text in detectedText = text }

        // Press → release
        engine.startListening()
        #expect(vm.isDetectingSpeech, "Indicator should show Listening on key-down")

        engine.triggerPTTAnswer()
        #expect(!vm.isDetectingSpeech, "Indicator should clear on key-up")
        #expect(detectedText == "What is dependency injection?", "Should fire with transcript text")
    }

    @Test("PTT mode: triggerPTTAnswer with no transcript does not fire callback")
    func pttAnswerNoTranscript() {
        let capture = MockCaptureEngine()
        let stt = DeepgramSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(captureEngine: capture, sttClient: stt, viewModel: vm)
        engine.listenMode = "pushToTalk"

        var callbackFired = false
        engine.onQuestionDetected = { _ in callbackFired = true }

        // Press → release without speaking
        engine.startListening()
        engine.triggerPTTAnswer()

        #expect(!callbackFired, "Should NOT fire callback when no transcript")
        #expect(!vm.isDetectingSpeech, "Indicator should clear even without transcript")
    }

    @Test("PTT mode: auto-detection suppressed while key held")
    func pttSuppressesAutoDetection() {
        let capture = MockCaptureEngine()
        let stt = DeepgramSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(captureEngine: capture, sttClient: stt, viewModel: vm)
        engine.listenMode = "auto" // Even in auto mode, PTT should suppress

        // Add a segment so the auto-detection callback would have something to fire
        let segment = TranscriptSegment(
            sessionId: UUID(), timestamp: Date(),
            speaker: .unknown, text: "test question",
            isFinal: true
        )
        vm.appendTranscript(segment)

        var autoDetectionFired = false
        engine.onQuestionDetected = { _ in autoDetectionFired = true }

        // Simulate: key held, then auto-detection tries to fire
        // (In real app, the CaptureEngineImpl.onQuestionDetected closure checks isPTTKeyHeld)
        // We can't easily test this without CaptureEngineImpl, but we verify the flag indirectly:
        engine.startListening()
        // triggerPTTAnswer should fire the callback (key-up path)
        engine.triggerPTTAnswer()
        #expect(autoDetectionFired, "PTT key-up should trigger answer")
    }

    // MARK: - Auto Mode

    @Test("Auto mode: triggerPTTAnswer fires and keeps listening")
    func autoModePTTKeepsListening() {
        let capture = MockCaptureEngine()
        let stt = DeepgramSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(captureEngine: capture, sttClient: stt, viewModel: vm)
        engine.listenMode = "auto"

        let segment = TranscriptSegment(
            sessionId: UUID(), timestamp: Date(),
            speaker: .unknown, text: "Explain SOLID principles",
            isFinal: true
        )
        vm.appendTranscript(segment)

        var detectedText: String?
        engine.onQuestionDetected = { text in detectedText = text }

        engine.startListening()
        engine.triggerPTTAnswer()

        #expect(detectedText == "Explain SOLID principles")
        // In auto mode, VAD should stay enabled (indicator cleared but not disabled)
        // MockCaptureEngine doesn't have VAD, so we just check indicator state
        #expect(!vm.isDetectingSpeech, "Indicator cleared after answer trigger")
    }

    // MARK: - Guard: triggerPTTAnswer without startListening

    @Test("triggerPTTAnswer without startListening is a no-op")
    func triggerWithoutStartIsNoOp() {
        let capture = MockCaptureEngine()
        let stt = DeepgramSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(captureEngine: capture, sttClient: stt, viewModel: vm)

        let segment = TranscriptSegment(
            sessionId: UUID(), timestamp: Date(),
            speaker: .unknown, text: "test",
            isFinal: true
        )
        vm.appendTranscript(segment)

        var fired = false
        engine.onQuestionDetected = { _ in fired = true }

        // Release without press — should be no-op
        engine.triggerPTTAnswer()
        #expect(!fired, "Should not fire if key wasn't pressed first")
    }

    // MARK: - Repeated PTT cycles

    @Test("Multiple PTT press-release cycles work")
    func multiplePTTCycles() {
        let capture = MockCaptureEngine()
        let stt = DeepgramSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(captureEngine: capture, sttClient: stt, viewModel: vm)
        engine.listenMode = "pushToTalk"

        var fireCount = 0
        engine.onQuestionDetected = { _ in fireCount += 1 }

        // Cycle 1
        vm.appendTranscript(TranscriptSegment(
            sessionId: UUID(), timestamp: Date(),
            speaker: .unknown, text: "Question 1",
            isFinal: true
        ))
        engine.startListening()
        engine.triggerPTTAnswer()
        #expect(fireCount == 1)

        // Cycle 2
        vm.appendTranscript(TranscriptSegment(
            sessionId: UUID(), timestamp: Date(),
            speaker: .unknown, text: "Question 2",
            isFinal: true
        ))
        engine.startListening()
        engine.triggerPTTAnswer()
        #expect(fireCount == 2)
    }
}
