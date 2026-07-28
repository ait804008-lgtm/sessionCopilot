import Foundation
import Testing
@testable import SessionCopilot

// MARK: - Test SttClient that can emit segments on demand

@MainActor
final class TestSttClient: SttClient {
    let transcriptStream: AsyncStream<TranscriptSegment>
    private let continuation: AsyncStream<TranscriptSegment>.Continuation
    private var sessionId = UUID()

    init() {
        var c: AsyncStream<TranscriptSegment>.Continuation!
        transcriptStream = AsyncStream { c = $0 }
        continuation = c!
    }

    func emitSegment(_ text: String, isFinal: Bool, speaker: TranscriptSegment.Speaker = .unknown) {
        continuation.yield(TranscriptSegment(
            sessionId: sessionId,
            timestamp: Date(),
            speaker: speaker,
            text: text,
            isFinal: isFinal
        ))
    }

    func finishStream() {
        continuation.finish()
    }

    func configure(_ config: SttConfig) async throws {}
    func start() async throws {}
    func stop() async throws { continuation.finish() }
    func sendAudio(_ data: Data) async {}
}

// MARK: - SessionEngine Persistence Tests

@Suite("SessionEngine Persistence") @MainActor struct SessionEnginePersistenceTests {

    @Test("SessionEngine creates session on start")
    func createsSessionOnStart() async throws {
        let store = SessionStoreImpl()
        let capture = MockCaptureEngine()
        let stt = TestSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(
            captureEngine: capture, sttClient: stt,
            viewModel: vm, sessionStore: store
        )

        try await engine.startSession()

        let sessions = try await store.fetchSessions(limit: 10)
        #expect(sessions.count >= 1, "Session should be created on start")
        #expect(sessions.first?.status == .live)

        try await engine.stopSession()
    }

    @Test("SessionEngine persists only final transcript segments")
    func persistsFinalSegments() async throws {
        let store = SessionStoreImpl()
        let capture = MockCaptureEngine()
        let stt = TestSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(
            captureEngine: capture, sttClient: stt,
            viewModel: vm, sessionStore: store
        )

        try await engine.startSession()

        // Emit interim + final segments
        stt.emitSegment("interim text", isFinal: false)
        stt.emitSegment("final text", isFinal: true)

        // Give async tasks time to process
        try await Task.sleep(nanoseconds: 200_000_000)

        try await engine.stopSession()

        let sessions = try await store.fetchSessions(limit: 10)
        let session = sessions.first!
        #expect(session.segments.count == 1, "Only final segments should be persisted, got \(session.segments.count)")
        #expect(session.segments.first?.text == "final text")
    }

    @Test("SessionEngine sets status to done on stop")
    func setsStatusDoneOnStop() async throws {
        let store = SessionStoreImpl()
        let capture = MockCaptureEngine()
        let stt = TestSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(
            captureEngine: capture, sttClient: stt,
            viewModel: vm, sessionStore: store
        )

        try await engine.startSession()
        try await Task.sleep(nanoseconds: 50_000_000)

        try await engine.stopSession()

        let sessions = try await store.fetchSessions(limit: 10)
        let session = sessions.first!
        #expect(session.status == .done)
        #expect(session.endedAt != nil, "endedAt should be set on stop")
    }

    @Test("SessionEngine persists suggestions")
    func persistsSuggestions() async throws {
        let store = SessionStoreImpl()
        let capture = MockCaptureEngine()
        let stt = TestSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(
            captureEngine: capture, sttClient: stt,
            viewModel: vm, sessionStore: store
        )

        try await engine.startSession()
        try await Task.sleep(nanoseconds: 50_000_000)

        // Persist a suggestion (simulating what App.handleQuestion would do)
        await engine.persistSuggestion(Suggestion(
            sessionId: engine.currentSessionId!,
            type: .answerOutline,
            content: "## Outline\n- Test point"
        ))

        try await engine.stopSession()

        let sessions = try await store.fetchSessions(limit: 10)
        let session = sessions.first!
        #expect(session.suggestions.count == 1)
        #expect(session.suggestions.first?.content.contains("Test point") == true)
    }

    @Test("SessionEngine with nil store doesn't crash")
    func nilStoreSafe() async throws {
        let capture = MockCaptureEngine()
        let stt = TestSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(
            captureEngine: capture, sttClient: stt,
            viewModel: vm, sessionStore: nil
        )

        try await engine.startSession()
        stt.emitSegment("test", isFinal: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        try await engine.stopSession()
        // Should not crash
    }
}
