import Foundation
import Testing
@testable import SessionCopilot

// MARK: - Model Serialization Tests

@Test("AudioBuffer is Codable and Sendable")
func audioBufferCodable() async throws {
    let buffer = AudioBuffer(
        data: Data([0x01, 0x02, 0x03]),
        timestamp: Date(timeIntervalSince1970: 1_000_000),
        sampleRate: 16_000,
        channels: 1
    )
    let encoded = try JSONEncoder().encode(buffer)
    let decoded = try JSONDecoder().decode(AudioBuffer.self, from: encoded)
    #expect(decoded.sampleRate == 16_000)
    #expect(decoded.channels == 1)
}

@Test("TranscriptSegment is Codable and has correct fields")
func transcriptSegmentCodable() async throws {
    let segment = TranscriptSegment(
        id: UUID(),
        sessionId: UUID(),
        timestamp: Date(),
        speaker: .mic,
        text: "Hello world",
        isFinal: true,
        confidence: 0.98
    )
    let encoded = try JSONEncoder().encode(segment)
    let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: encoded)
    #expect(decoded.speaker == .mic)
    #expect(decoded.text == "Hello world")
    #expect(decoded.isFinal == true)
    #expect(decoded.confidence == 0.98)
}

@Test("TranscriptSegment speaker enum round-trips")
func speakerEnumRoundTrip() async throws {
    let json = #"{"id":"00000000-0000-0000-0000-000000000001","sessionId":"00000000-0000-0000-0000-000000000002","timestamp":1000000,"speaker":"system","text":"test","isFinal":true}"#
    let decoded = try JSONDecoder().decode(TranscriptSegment.self, from: Data(json.utf8))
    #expect(decoded.speaker == .system)
}

// MARK: - Session Tests

@Test("Session has correct fields and status enum")
func sessionModel() async throws {
    let session = Session(
        id: UUID(),
        profileId: UUID(),
        mode: .behavioral,
        title: "Mock Interview",
        status: .preflight,
        startedAt: Date(),
        segments: [],
        suggestions: []
    )
    #expect(session.mode == .behavioral)
    #expect(session.status == .preflight)
    #expect(session.title == "Mock Interview")
    #expect(session.endedAt == nil)
}

@Test("Session status enum has all required states")
func sessionStatusEnum() {
    let states: [Session.Status] = [.preflight, .live, .paused, .done]
    #expect(states.count == 4)
    #expect(Session.Status.preflight.rawValue == "preflight")
    #expect(Session.Status.live.rawValue == "live")
}

// MARK: - Profile Tests

@Test("Profile model encodes and decodes")
func profileCodable() async throws {
    let profile = Profile(
        id: UUID(),
        name: "Test User",
        resumeText: "Senior Engineer",
        resumeParsed: ["skills": ["Swift", "Go"]],
        defaultJD: "Looking for staff engineer",
        starStories: [],
        createdAt: Date(),
        updatedAt: Date()
    )
    let encoded = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(Profile.self, from: encoded)
    #expect(decoded.name == "Test User")
    #expect(decoded.resumeText == "Senior Engineer")
}

// MARK: - StarStory Tests

@Test("StarStory has all STAR fields")
func starStoryModel() async throws {
    let story = StarStory(
        id: UUID(),
        situation: "Legacy auth was slow",
        task: "Migrate to OAuth2",
        action: "Implemented PKCE flow",
        result: "Auth latency dropped 80%",
        tags: ["security", "performance"]
    )
    #expect(story.tags.contains("security"))
    #expect(story.action.contains("PKCE"))
}

// MARK: - ProviderConfig Tests

@Test("ProviderConfig supports all provider types")
func providerConfigProviders() async throws {
    let providers: [ProviderConfig.Provider] = [
        .deepseek, .anthropic, .openai, .nemotron, .deepgram, .gemini, .custom
    ]
    #expect(providers.count == 7)
}

@Test("ProviderConfig encodes and decodes")
func providerConfigCodable() async throws {
    let config = ProviderConfig(
        id: UUID(),
        provider: .deepseek,
        baseURL: "https://api.deepseek.com",
        model: "deepseek-chat",
        apiKeyRef: "com.sessioncopilot.deepseek-key",
        isDefault: true
    )
    let encoded = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(ProviderConfig.self, from: encoded)
    #expect(decoded.provider == .deepseek)
    #expect(decoded.baseURL == "https://api.deepseek.com")
    #expect(decoded.isDefault == true)
}

// MARK: - Suggestion Tests

@Test("Suggestion type enum has all variants")
func suggestionTypeEnum() {
    let types: [Suggestion.SuggestionType] = [
        .answerOutline, .coachTip, .followUp, .codeSolution
    ]
    #expect(types.count == 4)
}

@Test("Suggestion encodes and decodes")
func suggestionCodable() async throws {
    let suggestion = Suggestion(
        id: UUID(),
        sessionId: UUID(),
        segmentId: UUID(),
        timestamp: Date(),
        type: .answerOutline,
        content: "## Outline\n- Start with STAR",
        metadata: ["model": "deepseek-chat", "tokens": "150"]
    )
    let encoded = try JSONEncoder().encode(suggestion)
    let decoded = try JSONDecoder().decode(Suggestion.self, from: encoded)
    #expect(decoded.type == .answerOutline)
    #expect(decoded.content.contains("STAR"))
}

// MARK: - AppSettings Tests

@Test("AppSettings encodes and decodes")
func settingsCodable() async throws {
    let hotkeys = AppSettings.Hotkeys(
        showHide: "cmd+shift+o",
        startStop: "cmd+shift+s",
        regionCapture: "cmd+shift+a",
        copyLast: "cmd+shift+c"
    )
    let settings = AppSettings(
        hotkeys: hotkeys,
        opacity: 0.8,
        clickThrough: false,
        retentionDays: 30,
        defaultModels: ["behavioral": "deepseek-chat"],
        exportPath: "/Users/test/exports"
    )
    let encoded = try JSONEncoder().encode(settings)
    let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
    #expect(decoded.opacity == 0.8)
    #expect(decoded.retentionDays == 30)
    #expect(decoded.hotkeys.showHide == "cmd+shift+o")
}

// MARK: - SttConfig Tests

@Test("SttConfig encodes and decodes")
func sttConfigCodable() async throws {
    let config = SttConfig(
        provider: .deepgram,
        model: "nova-3",
        language: "en",
        interimResults: true
    )
    let encoded = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(SttConfig.self, from: encoded)
    #expect(decoded.provider == .deepgram)
    #expect(decoded.language == "en")
    #expect(decoded.interimResults == true)
}

// MARK: - LlmRequest Tests

@Test("LlmRequest encodes and decodes")
func llmRequestCodable() async throws {
    let request = LlmRequest(
        model: "deepseek-chat",
        mode: .behavioral,
        prompt: "Answer the following interview question",
        context: ["transcript": "Tell me about yourself", "resume": "..."],
        maxTokens: 500
    )
    let encoded = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(LlmRequest.self, from: encoded)
    #expect(decoded.model == "deepseek-chat")
    #expect(decoded.mode == .behavioral)
    #expect(decoded.maxTokens == 500)
}

// MARK: - LlmResponse Tests

@Test("LlmResponse encodes and decodes with sections")
func llmResponseCodable() async throws {
    let response = LlmResponse(
        sections: [
            LlmResponse.Section(title: "Outline", content: "STAR format answer"),
            LlmResponse.Section(title: "Coach Tips", content: "Add metrics"),
        ],
        metadata: ["model": "deepseek-chat", "latencyMs": "800"]
    )
    let encoded = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(LlmResponse.self, from: encoded)
    #expect(decoded.sections.count == 2)
    #expect(decoded.sections[0].title == "Outline")
}
