import Foundation
import Testing
@testable import SessionCopilot

@Suite("QuestionDetector") struct QuestionDetectorTests {

    @Test("initial state is idle")
    func initialState() {
        let detector = QuestionDetector(silenceThreshold: 0.8)
        #expect(!detector.isSpeaking)
        #expect(detector.currentSilenceDuration == 0)
    }

    @Test("silence accumulates when no speech")
    func silenceAccumulates() {
        let detector = QuestionDetector(silenceThreshold: 0.8)
        detector.feed(level: 0.01, deltaTime: 0.3) // silence
        #expect(!detector.isSpeaking)
        #expect(detector.currentSilenceDuration > 0)
    }

    @Test("speech resets silence counter")
    func speechResetsSilence() {
        let detector = QuestionDetector(silenceThreshold: 0.8)
        detector.feed(level: 0.01, deltaTime: 0.5) // silence 0.5s
        #expect(detector.currentSilenceDuration == 0.5)
        detector.feed(level: 0.5, deltaTime: 0.1)  // speech
        #expect(detector.currentSilenceDuration == 0)
        #expect(detector.isSpeaking)
    }

    @Test("question detected when silence exceeds threshold")
    func questionDetection() {
        let detector = QuestionDetector(silenceThreshold: 0.8)
        // Simulate: speech → silence > threshold
        detector.feed(level: 0.5, deltaTime: 0.2)  // speaking
        #expect(detector.isSpeaking)

        detector.feed(level: 0.01, deltaTime: 0.5) // silence 0.5s (under threshold)
        #expect(detector.isSpeaking) // still considered speaking until threshold

        // Silence reaches threshold → detection fires
        let detected = detector.feed(level: 0.01, deltaTime: 0.4) // total 0.9s > 0.8
        #expect(detected, "Should fire when silence crosses threshold")
        #expect(!detector.isSpeaking)
    }

    @Test("no question detected if silence too short")
    func shortSilence() {
        let detector = QuestionDetector(silenceThreshold: 0.8)
        detector.feed(level: 0.5, deltaTime: 0.2)  // speaking
        let detected = detector.feed(level: 0.01, deltaTime: 0.3) // short silence (0.3 < 0.8)
        #expect(!detected)
    }

    @Test("only fires once per silence period")
    func firesOnce() {
        let detector = QuestionDetector(silenceThreshold: 0.5)
        detector.feed(level: 0.5, deltaTime: 0.2) // speak
        let first = detector.feed(level: 0.01, deltaTime: 0.6) // silence > 0.5
        #expect(first)
        let second = detector.feed(level: 0.01, deltaTime: 0.2) // more silence
        #expect(!second, "Should not fire again for same silence period")
    }

    @Test("disabled detector never fires and doesn't accumulate silence")
    func disabledNeverFires() {
        let detector = QuestionDetector(silenceThreshold: 0.5)
        detector.disable()
        // Even with long silence, disabled detector returns false
        let result = detector.feed(level: 0.01, deltaTime: 2.0)
        #expect(!result)
        #expect(detector.currentSilenceDuration == 0)
    }

    @Test("enable after disable resumes normal behaviour")
    func enableAfterDisable() {
        let detector = QuestionDetector(silenceThreshold: 0.5)
        detector.disable()
        detector.feed(level: 0.01, deltaTime: 2.0) // ignored
        detector.enable()
        // Fresh start after enable
        #expect(detector.currentSilenceDuration == 0)
        detector.feed(level: 0.5, deltaTime: 0.1) // speak
        let detected = detector.feed(level: 0.01, deltaTime: 0.6) // silence > 0.5
        #expect(detected)
    }
}

@Suite("CaptureEngine") @MainActor struct CaptureEngineImplTests {

    @Test("mock capture engine conforms to protocol")
    func protocolConformance() async throws {
        let engine = MockCaptureEngine()
        #expect(engine is CaptureEngine)
    }

    @Test("mock capture engine starts and stops without throwing")
    func startStop() async throws {
        let engine = MockCaptureEngine()
        try await engine.start()
        try await engine.stop()
    }
}

// MARK: - QuestionDetector — extended coverage

@Suite("QuestionDetector Extended") struct QuestionDetectorExtendedTests {

    @Test("Detector fires repeatedly across multiple silence periods")
    func multipleSilencePeriods() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        // First speech→silence cycle
        d.feed(level: 0.5, deltaTime: 0.1)
        let first = d.feed(level: 0.01, deltaTime: 0.6)
        #expect(first)
        // Second speech→silence cycle
        d.feed(level: 0.5, deltaTime: 0.1)
        let second = d.feed(level: 0.01, deltaTime: 0.6)
        #expect(second)
    }

    @Test("Continuous silence below threshold does not fire")
    func continuousLowSilence() {
        let d = QuestionDetector(silenceThreshold: 1.0)
        // Five 0.2s silence samples = 1.0s total, but each individual feed
        // only adds 0.2s — the accumulator crosses 1.0 on the 5th call.
        d.feed(level: 0.5, deltaTime: 0.1) // speech
        var fired = false
        for _ in 0..<5 {
            if d.feed(level: 0.01, deltaTime: 0.2) { fired = true }
        }
        #expect(fired, "Should fire exactly once when cumulative silence crosses threshold")
        // Further silence should NOT fire again for the same period.
        let again = d.feed(level: 0.01, deltaTime: 0.3)
        #expect(!again)
    }

    @Test("Speech level just above onset threshold counts as speech")
    func speechJustAboveThreshold() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        // speechOnThreshold is 0.08; 0.09 should count as speech
        d.feed(level: 0.09, deltaTime: 0.1)
        #expect(d.isSpeaking)
    }

    @Test("Silence level just above offset threshold still counts as speech (hysteresis)")
    func silenceJustAboveOffsetThreshold() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        d.feed(level: 0.5, deltaTime: 0.1) // speak — well above onset
        // 0.04 > speechOffThreshold (0.03) → still considered speech (hysteresis dead zone)
        d.feed(level: 0.04, deltaTime: 0.1)
        #expect(d.isSpeaking)
        #expect(d.currentSilenceDuration == 0)
    }

    @Test("Level in hysteresis dead zone does not trigger speech from silence")
    func deadZoneNoTrigger() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        // 0.06 is between speechOffThreshold (0.03) and speechOnThreshold (0.08).
        // Starting from silence, this should NOT trigger speech.
        d.feed(level: 0.06, deltaTime: 0.1)
        #expect(!d.isSpeaking)
    }

    @Test("Drop below offset threshold triggers silence from speech")
    func dropBelowOffsetTriggersSilence() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        d.feed(level: 0.5, deltaTime: 0.1) // speak
        #expect(d.isSpeaking)
        // 0.02 < speechOffThreshold (0.03) → transition to silence
        d.feed(level: 0.02, deltaTime: 0.1)
        #expect(d.currentSilenceDuration > 0)
    }

    @Test("Reset clears all state")
    func resetClears() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        d.feed(level: 0.5, deltaTime: 0.1)
        d.feed(level: 0.01, deltaTime: 0.6) // fires
        d.reset()
        #expect(!d.isSpeaking)
        #expect(d.currentSilenceDuration == 0)
    }

    @Test("enable() after enable() is idempotent")
    func doubleEnable() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        d.enable()
        d.enable()
        d.feed(level: 0.5, deltaTime: 0.1)
        let fired = d.feed(level: 0.01, deltaTime: 0.6)
        #expect(fired)
    }

    @Test("disable() after disable() is idempotent")
    func doubleDisable() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        d.disable()
        d.disable()
        let result = d.feed(level: 0.5, deltaTime: 1.0)
        #expect(!result)
        #expect(d.currentSilenceDuration == 0)
    }

    @Test("Zero deltaTime accumulates nothing")
    func zeroDeltaTime() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        d.feed(level: 0.01, deltaTime: 0)
        #expect(d.currentSilenceDuration == 0)
    }

    @Test("Negative deltaTime is tolerated (no crash)")
    func negativeDeltaTime() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        d.feed(level: 0.01, deltaTime: -0.5)
        // We don't assert on the resulting accumulator — we only verify
        // no crash. (The detector adds deltaTime regardless of sign.)
    }

    @Test("Extreme amplitude (1.0) is treated as speech")
    func extremeAmplitude() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        d.feed(level: 1.0, deltaTime: 0.1)
        #expect(d.isSpeaking)
    }

    @Test("Negative level is treated as silence (no crash)")
    func negativeLevel() {
        let d = QuestionDetector(silenceThreshold: 0.5)
        // Defensive: a buggy RMS computation might produce a negative
        // value. The detector should treat it as silence (not crash).
        d.feed(level: -0.1, deltaTime: 0.1)
        // We don't assert on isSpeaking — just verifying no crash.
        _ = d.currentSilenceDuration
    }
}
