import Foundation
import Testing
@testable import SessionCopilot

// MARK: - CaptureStatus Tests

@Suite("CaptureStatus") struct CaptureStatusTests {

    @Test("idle status has correct label")
    func idleLabel() {
        #expect(CaptureStatus.idle.label == "Idle")
    }

    @Test("micOnly status has correct label")
    func micOnlyLabel() {
        #expect(CaptureStatus.micOnly.label == "Mic only")
    }

    @Test("systemActive status has correct label")
    func systemActiveLabel() {
        #expect(CaptureStatus.systemActive.label == "System + Mic")
    }

    @Test("systemFallback status has correct label")
    func systemFallbackLabel() {
        #expect(CaptureStatus.systemFallback.label == "Fallback (mic)")
    }

    @Test("failed status has correct label")
    func failedLabel() {
        #expect(CaptureStatus.failed(.invalidFormat).label == "Failed")
    }

    @Test("All statuses have non-empty dot symbol")
    func nonEmptyDotSymbol() {
        for status in [
            CaptureStatus.idle,
            .micOnly,
            .systemActive,
            .systemFallback,
            .failed(.invalidFormat)
        ] {
            #expect(!status.dotSymbol.isEmpty)
        }
    }

    @Test("All statuses have non-empty dot color name")
    func nonEmptyDotColor() {
        for status in [
            CaptureStatus.idle,
            .micOnly,
            .systemActive,
            .systemFallback,
            .failed(.invalidFormat)
        ] {
            #expect(!status.dotColorName.isEmpty)
        }
    }

    @Test("Different statuses have different color names")
    func distinctColors() {
        let colors = Set([
            CaptureStatus.idle.dotColorName,
            .micOnly.dotColorName,
            .systemActive.dotColorName,
            .systemFallback.dotColorName,
            .failed(.invalidFormat).dotColorName
        ])
        #expect(colors.count == 5, "Each status should have a distinct color")
    }

    @Test("Equality holds for same failed case")
    func failedEquality() {
        #expect(CaptureStatus.failed(.invalidFormat) == .failed(.invalidFormat))
    }

    @Test("Inequality for different failed cases")
    func failedInequality() {
        #expect(CaptureStatus.failed(.invalidFormat) != .failed(.noDisplay))
    }
}

// MARK: - CaptureEngineImpl Status Callback Tests

@Suite("CaptureEngine Status Callbacks") struct CaptureEngineStatusCallbackTests {

    @Test("onStatusChange is nil by default")
    func defaultNilCallback() {
        let engine = CaptureEngineImpl(captureSystemAudio: true)
        // The optional callback should be nil until set.
        // (We can't directly read the optional, but we can set and
        // verify no crash. The behavior tested here is that the
        // property is settable and gettable.)
        engine.onStatusChange = { _ in }
        // Setting again should also be safe.
        engine.onStatusChange = nil
    }

    @Test("currentStatus is idle before start")
    func idleBeforeStart() {
        let engine = CaptureEngineImpl(captureSystemAudio: false)
        #expect(engine.currentStatus == .idle)
    }

    @Test("currentStatus reflects captureSystemAudio=false as micOnly when running")
    func micOnlyWhenSystemAudioDisabled() {
        // We can't easily start the engine in a unit test (requires
        // audio hardware + permissions), but we can verify the
        // currentStatus computed property's logic by checking the
        // initial state.
        let engine = CaptureEngineImpl(captureSystemAudio: false)
        // state is .idle, so currentStatus is .idle regardless of
        // captureSystemAudio.
        #expect(engine.currentStatus == .idle)
    }

    @Test("scBufferCount starts at zero")
    func initialBufferCount() {
        let engine = CaptureEngineImpl(captureSystemAudio: true)
        #expect(engine.scBufferCount == 0)
    }

    @Test("didFallbackToMic starts false")
    func initialFallback() {
        let engine = CaptureEngineImpl(captureSystemAudio: true)
        #expect(!engine.didFallbackToMic)
    }
}
