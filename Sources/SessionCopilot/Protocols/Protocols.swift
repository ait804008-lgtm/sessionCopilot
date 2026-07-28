import Foundation

// MARK: - Capture Engine

public protocol CaptureEngine: AnyObject, Sendable {
    var audioStream: AsyncStream<AudioBuffer> { get }
    var levelMeter: AsyncStream<Float> { get }
    var isSystemSpeaking: Bool { get }
    var isMicSpeaking: Bool { get }

    func start() async throws
    func stop() async throws
    func enableVAD()
    func disableVAD()
    func resetSilence()
}

// MARK: - STT Client

public protocol SttClient: AnyObject, Sendable {
    var transcriptStream: AsyncStream<TranscriptSegment> { get }

    func configure(_ config: SttConfig) async throws
    func start() async throws
    func stop() async throws
    func sendAudio(_ data: Data) async
}

// MARK: - LLM Client

@MainActor
public protocol LlmClient: AnyObject {
    func streamCompletion(_ request: LlmRequest) -> AsyncStream<LlmToken>
    func complete(_ request: LlmRequest) async throws -> LlmResponse
}

// MARK: - Session Store

@MainActor
public protocol SessionStore: AnyObject {
    func createSession(_ session: Session) async throws -> Session
    func appendSegment(_ segment: TranscriptSegment, to sessionId: UUID) async throws
    func appendSuggestion(_ suggestion: Suggestion, to sessionId: UUID) async throws
    func fetchSession(_ id: UUID) async throws -> Session?
    func fetchSessions(limit: Int) async throws -> [Session]
    func deleteSession(_ id: UUID) async throws
    func deleteSessions(_ ids: Set<UUID>) async throws
    func deleteAllSessions() async throws
    func exportSession(_ id: UUID, format: ExportFormat) async throws -> URL
}

// MARK: - Session Store
