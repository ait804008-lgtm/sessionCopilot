import Foundation
import Testing
@testable import SessionCopilot

// MARK: - Protocol conformance tests

// Mock implementations to verify protocol shapes compile
private final class MockCaptureEngine: CaptureEngine {
    var audioStream: AsyncStream<AudioBuffer> {
        AsyncStream { _ in }
    }
    var levelMeter: AsyncStream<Float> {
        AsyncStream { _ in }
    }
    var isSystemSpeaking: Bool { false }
    var isMicSpeaking: Bool { false }
    func start() async throws {}
    func stop() async throws {}
    func enableVAD() {}
    func disableVAD() {}
    func resetSilence() {}
}

private final class MockSttClient: SttClient {
    var transcriptStream: AsyncStream<TranscriptSegment> {
        AsyncStream { _ in }
    }
    func configure(_ config: SttConfig) async throws {}
    func start() async throws {}
    func stop() async throws {}
    func sendAudio(_ data: Data) async {}
}

private final class MockLlmClient: LlmClient {
    func streamCompletion(_ request: LlmRequest) -> AsyncStream<LlmToken> {
        AsyncStream { _ in }
    }
    func complete(_ request: LlmRequest) async throws -> LlmResponse {
        LlmResponse(sections: [], metadata: [:])
    }
}

private final class MockSessionStore: SessionStore {
    func createSession(_ session: Session) async throws -> Session { session }
    func appendSegment(_ segment: TranscriptSegment, to sessionId: UUID) async throws {}
    func appendSuggestion(_ suggestion: Suggestion, to sessionId: UUID) async throws {}
    func fetchSession(_ id: UUID) async throws -> Session? { nil }
    func fetchSessions(limit: Int) async throws -> [Session] { [] }
    func deleteSession(_ id: UUID) async throws {}
    func deleteSessions(_ ids: Set<UUID>) async throws {}
    func deleteAllSessions() async throws {}
    func exportSession(_ id: UUID, format: ExportFormat) async throws -> URL {
        URL(fileURLWithPath: "/tmp/test.md")
    }
}

// MARK: - Tests

@Test("CaptureEngine protocol can be mocked")
func captureEngineMockCompiles() {
    _ = MockCaptureEngine()
}

@Test("SttClient protocol can be mocked")
func sttClientMockCompiles() {
    _ = MockSttClient()
}

@Test("LlmClient protocol can be mocked")
func llmClientMockCompiles() {
    _ = MockLlmClient()
}

@Test("SessionStore protocol can be mocked")
func sessionStoreMockCompiles() async throws {
    _ = MockSessionStore()
}

@Test("ExportFormat enum has markdown and json")
func exportFormatEnum() {
    let formats: [ExportFormat] = [.markdown, .json]
    #expect(formats.count == 2)
    #expect(ExportFormat.markdown.rawValue == "markdown")
}

@Test("LlmToken struct works")
func llmTokenStruct() {
    let token = LlmToken(text: "Hello", isDone: false)
    #expect(token.text == "Hello")
    #expect(token.isDone == false)

    let done = LlmToken(text: "", isDone: true)
    #expect(done.isDone == true)
}
