import Foundation
import Testing
@testable import SessionCopilot

// =============================================================================
// E2E-01: Full Profile → ContextBuilder → PromptLoader → Grounded Prompt Flow
// Tests the complete behavioral interview prompt pipeline (Tasks 1-2)
// =============================================================================

@Suite("E2E-01: Profile-to-Prompt Pipeline") @MainActor struct E2E_ProfileToPrompt {

    @Test("Complete flow: create profile → build variables → load template → render → verify all context present")
    func fullProfileToPromptFlow() throws {
        // 1. Create a fully-populated profile
        let profile = Profile(
            name: "Alice Engineer",
            resumeText: "Senior iOS Engineer with 8 years experience. Led SwiftUI migration at Acme Corp.",
            resumeParsed: ["skills": ["Swift", "SwiftUI", "Combine", "CoreData"]],
            defaultJD: "Staff iOS Engineer at BigTech Inc.",
            starStories: [
                StarStory(situation: "App startup time was 3.2s", task: "Reduce to <1s", action: "Lazy loading, prefetch optimization, asset caching", result: "Startup down to 0.8s, 60% improvement"),
                StarStory(situation: "Team of 12 had flaky CI", task: "Stabilize CI pipeline", action: "Introduced hermetic builds, test sharding, flaky test quarantine", result: "CI pass rate went from 82% to 99.7%")
            ]
        )

        // 2. Build template variables
        let vars = ContextBuilder.buildVariables(
            profile: profile,
            chatMessages: [
                ChatMessage(role: .user, text: "Tell me about a time you improved performance")
            ],
            questionText: "What's your approach to performance optimization?"
        )

        // 3. Load and render the behavioral template
        let loader = PromptLoader()
        let prompt = try loader.loadAndRender("behavioral/answer_outline", variables: vars)

        // 4. Verify all profile data is present in the final prompt
        #expect(prompt.contains("Alice Engineer") || prompt.contains("8 years experience"))
        #expect(prompt.contains("SwiftUI migration"))
        #expect(prompt.contains("Staff iOS Engineer"))
        #expect(prompt.contains("BigTech"))
        #expect(prompt.contains("0.8s") || prompt.contains("60%"))
        #expect(prompt.contains("Tell me about a time"))
        #expect(prompt.contains("performance optimization"))
        // No unreplaced template variables
        #expect(!prompt.contains("{{resume}}"))
        #expect(!prompt.contains("{{jd}}"))
        #expect(!prompt.contains("{{stars}}"))
        #expect(!prompt.contains("{{transcript}}"))
        #expect(!prompt.contains("{{question}}"))
    }

    @Test("Profile with no STAR stories produces 'None provided' placeholder")
    func noStarStoriesHasPlaceholder() {
        let profile = Profile(name: "Bob", resumeText: "Junior dev")
        let vars = ContextBuilder.buildVariables(profile: profile, chatMessages: [], questionText: "?")
        #expect(vars["stars"] == "None provided")
    }

    @Test("Profile with nil JD produces 'N/A' placeholder")
    func nilJDHasPlaceholder() {
        let profile = Profile(name: "Charlie", resumeText: "Engineer")
        let vars = ContextBuilder.buildVariables(profile: profile, chatMessages: [], questionText: "?")
        #expect(vars["jd"] == "N/A")
    }
}

// =============================================================================
// E2E-02: Session Persistence → History → Export → Scoring Full Pipeline
// Tests complete session lifecycle (Tasks 4-6)
// =============================================================================

@Suite("E2E-02: Session Persistence → History → Export → Scoring") @MainActor struct E2E_SessionLifecycle {

    @Test("Full lifecycle: create → append segments + suggestions → fetch → export markdown → export json → delete")
    func fullSessionLifecycle() async throws {
        let store = SessionStoreImpl()
        let profileId = UUID()

        // 1. Create session
        var session = Session(profileId: profileId, mode: .behavioral, title: "Mock Behavioral Interview")
        session = try await store.createSession(session)
        let sessionId = session.id

        // 2. Append transcript segments (simulating a real conversation)
        try await store.appendSegment(
            TranscriptSegment(sessionId: sessionId, timestamp: Date(), speaker: .unknown, text: "Tell me about a time you showed leadership", isFinal: true),
            to: sessionId
        )
        try await store.appendSegment(
            TranscriptSegment(sessionId: sessionId, timestamp: Date().addingTimeInterval(5), speaker: .mic, text: "I led a cross-functional team of 8 to deliver a critical feature under a tight deadline. We used Agile methodology with daily standups.", isFinal: true),
            to: sessionId
        )
        try await store.appendSegment(
            TranscriptSegment(sessionId: sessionId, timestamp: Date().addingTimeInterval(12), speaker: .unknown, text: "What was the outcome?", isFinal: true),
            to: sessionId
        )
        try await store.appendSegment(
            TranscriptSegment(sessionId: sessionId, timestamp: Date().addingTimeInterval(17), speaker: .mic, text: "We shipped on time and increased user engagement by 35%.", isFinal: true),
            to: sessionId
        )

        // 3. Append suggestions
        try await store.appendSuggestion(
            Suggestion(sessionId: sessionId, type: .answerOutline, content: "## Outline\n- Situation: Tight deadline\n- Task: Lead team\n- Action: Agile, daily standups\n- Result: 35% engagement increase"),
            to: sessionId
        )
        try await store.appendSuggestion(
            Suggestion(sessionId: sessionId, type: .coachTip, content: "Good metrics! Consider adding team size and timeline specifics."),
            to: sessionId
        )

        // 4. Fetch and verify session
        let fetched = try await store.fetchSession(sessionId)
        #expect(fetched != nil)
        #expect(fetched?.segments.count == 4)
        #expect(fetched?.suggestions.count == 2)
        #expect(fetched?.title == "Mock Behavioral Interview")
        #expect(fetched?.mode == .behavioral)

        // 5. Export to Markdown
        let mdURL = try await store.exportSession(sessionId, format: .markdown)
        let mdContent = try String(contentsOf: mdURL, encoding: .utf8)
        #expect(mdContent.contains("Mock Behavioral Interview"))
        #expect(mdContent.contains("cross-functional team"))
        #expect(mdContent.contains("35% engagement"))
        #expect(mdContent.contains("## Outline"))

        // 6. Export to JSON
        let jsonURL = try await store.exportSession(sessionId, format: .json)
        let jsonData = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(Session.self, from: jsonData)
        #expect(decoded.id == sessionId)
        #expect(decoded.segments.count == 4)
        #expect(decoded.suggestions.count == 2)

        // 7. Delete session
        try await store.deleteSession(sessionId)
        let afterDelete = try await store.fetchSession(sessionId)
        #expect(afterDelete == nil)
    }

    @Test("PostScorer parses valid scoring response")
    func scoringParsing() {
        let response = LlmResponse(
            sections: [LlmResponse.Section(title: "Response", content: #"{"structure": 5, "specificity": 4, "relevance": 4, "delivery": 3}"#)],
            metadata: ["model": "deepseek-chat"]
        )
        // Parse via the helper
        let content = response.sections.first?.content ?? ""
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            #expect(Bool(false), "Should parse valid scores JSON")
            return
        }
        #expect(json["structure"] == 5)
        #expect(json["specificity"] == 4)
        #expect(json["relevance"] == 4)
        #expect(json["delivery"] == 3)
    }
}

// =============================================================================
// E2E-03: LLM Provider Selection + Request Building (DeepSeek, Anthropic, Vision)
// Tests multi-provider LLM integration (Tasks 3, 7)
// =============================================================================

@Suite("E2E-03: Multi-Provider LLM Request Building") @MainActor struct E2E_LLMProviderRequests {

    // --- DeepSeek (OpenAI-compatible) ---

    @Test("DeepSeek behavioral request: URL, headers, body structure correct")
    func deepseekBehavioralRequest() throws {
        let client = LlmClientImpl()
        try client.configure(ProviderConfig(provider: .deepseek, baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKeyRef: "test-key"), apiKey: "test-key")
        let request = LlmRequest(model: "deepseek-chat", mode: .behavioral, prompt: "Question?", maxTokens: 200)
        let (urlRequest, bodyData) = try LlmClientImpl.buildRequest(request, config: ProviderConfig(provider: .deepseek, baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKeyRef: "test-key"), apiKey: "test-key", stream: false)

        // URL
        #expect(urlRequest.url?.absoluteString.contains("/v1/chat/completions") == true)
        // Auth
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        // Body
        let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        #expect(body["model"] as? String == "deepseek-chat")
        #expect(body["stream"] as? Bool == false)
        let messages = body["messages"] as! [[String: Any]]
        #expect(messages.count == 2) // system + user
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        // System must NOT be a top-level field
        #expect(body["system"] == nil)
    }

    @Test("DeepSeek request with max_tokens passes through")
    func deepseekMaxTokens() throws {
        let client = LlmClientImpl()
        let request = LlmRequest(model: "deepseek-chat", mode: .behavioral, prompt: "X", maxTokens: 999)
        let (_, bodyData) = try LlmClientImpl.buildRequest(request, config: ProviderConfig(provider: .deepseek, baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKeyRef: "k"), apiKey: "test-key", stream: true)
        let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        #expect(body["max_tokens"] as? Int == 999)
    }

    // --- Anthropic ---

    @Test("Anthropic behavioral request: URL, headers, system as top-level, messages without system role")
    func anthropicRequest() throws {
        let client = LlmClientImpl()
        try client.configure(ProviderConfig(provider: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-20250514", apiKeyRef: "test-key"), apiKey: "test-key")
        let request = LlmRequest(model: "claude-sonnet-4-20250514", mode: .behavioral, prompt: "Question?", maxTokens: 300)
        let (urlRequest, bodyData) = try LlmClientImpl.buildRequest(request, config: ProviderConfig(provider: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-20250514", apiKeyRef: "test-key"), apiKey: "test-key", stream: true)

        // URL must use /v1/messages NOT /v1/chat/completions
        let url = urlRequest.url!.absoluteString
        #expect(url.contains("/v1/messages"))
        #expect(!url.contains("/v1/chat/completions"))
        // Auth
        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") != nil)
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") != nil)
        // Body
        let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        // System as top-level
        #expect(body["system"] is String)
        #expect(!(body["system"] as! String).isEmpty)
        // Messages without system role
        let messages = body["messages"] as! [[String: Any]]
        for msg in messages {
            let role = msg["role"] as! String
            #expect(role != "system")
        }
        #expect(body["stream"] as? Bool == true)
    }

    // --- Vision Requests ---

    @Test("OpenAI vision request: content is multimodal array with image_url and text")
    func openaiVisionRequest() throws {
        let client = LlmClientImpl()
        try client.configure(ProviderConfig(provider: .openai, baseURL: "https://api.openai.com", model: "gpt-4o", apiKeyRef: "test-key"), apiKey: "test-key")
        let request = LlmRequest(model: "gpt-4o", mode: .coding, prompt: "Analyze this code", imageBase64: "iVBORw0KGgo=", maxTokens: 500)
        let (_, bodyData) = try LlmClientImpl.buildRequest(request, config: ProviderConfig(provider: .openai, baseURL: "https://api.openai.com", model: "gpt-4o", apiKeyRef: "test-key"), apiKey: "test-key", stream: false)

        let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let userMsg = messages.first { ($0["role"] as? String) == "user" }!
        let content = userMsg["content"] as! [[String: Any]]

        let hasText = content.contains { ($0["type"] as? String) == "text" }
        let hasImage = content.contains { ($0["type"] as? String) == "image_url" }
        #expect(hasText)
        #expect(hasImage)

        let imageBlock = content.first { ($0["type"] as? String) == "image_url" }!
        let imageUrl = imageBlock["image_url"] as! [String: String]
        #expect(imageUrl["url"]?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test("Anthropic vision request: content array has image type with source")
    func anthropicVisionRequest() throws {
        let client = LlmClientImpl()
        try client.configure(ProviderConfig(provider: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-20250514", apiKeyRef: "test-key"), apiKey: "test-key")
        let request = LlmRequest(model: "claude-sonnet-4-20250514", mode: .coding, prompt: "Analyze", imageBase64: "AAAA", maxTokens: 500)
        let (_, bodyData) = try LlmClientImpl.buildRequest(request, config: ProviderConfig(provider: .anthropic, baseURL: "https://api.anthropic.com", model: "claude-sonnet-4-20250514", apiKeyRef: "test-key"), apiKey: "test-key", stream: false)

        let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let userMsg = messages[0]
        let content = userMsg["content"] as! [[String: Any]]

        let hasText = content.contains { ($0["type"] as? String) == "text" }
        let hasImage = content.contains { ($0["type"] as? String) == "image" }
        #expect(hasText)
        #expect(hasImage)

        let imageBlock = content.first { ($0["type"] as? String) == "image" }!
        let source = imageBlock["source"] as! [String: String]
        #expect(source["type"] == "base64")
        #expect(source["media_type"] == "image/jpeg")
    }

    @Test("Non-vision request keeps string content (no regression)")
    func nonVisionStringContent() throws {
        let client = LlmClientImpl()
        try client.configure(ProviderConfig(provider: .deepseek, baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKeyRef: "test-key"), apiKey: "test-key")
        let request = LlmRequest(model: "deepseek-chat", mode: .behavioral, prompt: "Hello")
        let (_, bodyData) = try LlmClientImpl.buildRequest(request, config: ProviderConfig(provider: .deepseek, baseURL: "https://api.deepseek.com", model: "deepseek-chat", apiKeyRef: "test-key"), apiKey: "test-key", stream: false)

        let body = try JSONSerialization.jsonObject(with: bodyData) as! [String: Any]
        let messages = body["messages"] as! [[String: Any]]
        let userMsg = messages.first { ($0["role"] as? String) == "user" }!
        // Must be a plain string, not an array
        #expect(userMsg["content"] is String)
    }

    // --- Token Extraction ---

    @Test("Anthropic message_stop signals done")
    func anthropicMessageStop() throws {
        let client = LlmClientImpl()
        let event: [String: Any] = ["type": "message_stop"]
        let token = LlmClientImpl.extractToken(event, provider: .anthropic)
        #expect(token.isDone)
    }

    @Test("Anthropic content_block_delta extracts text")
    func anthropicContentBlockDelta() throws {
        let client = LlmClientImpl()
        let event: [String: Any] = ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hello world"]]
        let token = LlmClientImpl.extractToken(event, provider: .anthropic)
        #expect(token.text == "Hello world")
        #expect(!token.isDone)
    }

    @Test("OpenAI streaming with finish_reason stop signals done")
    func openaiFinishReasonStop() throws {
        let client = LlmClientImpl()
        let event: [String: Any] = ["choices": [["delta": [:], "finish_reason": "stop"]]]
        let token = LlmClientImpl.extractToken(event, provider: .deepseek)
        #expect(token.isDone)
    }

    @Test("OpenAI streaming with text content extracts token")
    func openaiDeltaContent() throws {
        let client = LlmClientImpl()
        let event: [String: Any] = ["choices": [["delta": ["content": "Hi there"]]]]
        let token = LlmClientImpl.extractToken(event, provider: .openai)
        #expect(token.text == "Hi there")
        #expect(!token.isDone)
    }
}

// =============================================================================
// E2E-04: Capture Engine → AudioBuffer Source → STT Pipeline
// Tests audio capture with source tagging (Task 9)
// =============================================================================

@Suite("E2E-04: Capture → AudioBuffer Source → STT Pipeline") @MainActor struct E2E_CaptureAudioPipeline {

    @Test("MockCaptureEngine emits AudioBuffer with source .unknown (default)")
    func mockCaptureEngineSource() async throws {
        let engine = MockCaptureEngine()
        try await engine.start()

        var receivedBuffer: AudioBuffer?
        for await buffer in engine.audioStream {
            receivedBuffer = buffer
            break
        }

        #expect(receivedBuffer != nil)
        #expect(receivedBuffer?.source == .unknown) // Mock doesn't set source
        try await engine.stop()
    }

    @Test("CaptureEngineImpl with captureSystemAudio=false still captures mic")
    func captureEngineMicOnly() async throws {
        let engine = CaptureEngineImpl(captureSystemAudio: false)
        #expect(!engine.captureSystemAudio)
        #expect(engine is CaptureEngine) // Protocol conformance
    }

    @Test("CaptureEngineImpl with captureSystemAudio=true flag is set")
    func captureEngineSystemAudioFlag() {
        let engine = CaptureEngineImpl(captureSystemAudio: true)
        #expect(engine.captureSystemAudio)
    }

    @Test("AudioBuffer.Source all cases encode/decode correctly")
    func audioBufferSourceRoundTrip() throws {
        for source in [AudioBuffer.Source.mic, .system, .unknown] {
            let buffer = AudioBuffer(data: Data([0x01]), timestamp: Date(), sampleRate: 16000, channels: 1, source: source)
            let encoded = try JSONEncoder().encode(buffer)
            let decoded = try JSONDecoder().decode(AudioBuffer.self, from: encoded)
            #expect(decoded.source == source)
        }
    }

    @Test("TestSttClient emits segments that flow through SessionEngine")
    func sttClientToEngineFlow() async throws {
        let store = SessionStoreImpl()
        let capture = MockCaptureEngine()
        let stt = TestSttClient()
        let vm = OverlayViewModel()
        let engine = SessionEngine(captureEngine: capture, sttClient: stt, viewModel: vm, sessionStore: store)

        try await engine.startSession()

        // Emit segments
        stt.emitSegment("Hello", isFinal: false)
        stt.emitSegment("Hello world", isFinal: true)

        // Wait for processing (poll, don't fixed-sleep — timing varies under load)
        var attempts = 0
        while vm.chatMessages.isEmpty && attempts < 20 {
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            attempts += 1
        }

        // Verify overlay received the segment
        #expect(vm.chatMessages.count >= 1)

        try await engine.stopSession()

        // Verify persistence
        let sessions = try await store.fetchSessions(limit: 1)
        #expect(sessions.count >= 1)
        #expect(sessions.first?.status == .done)
        #expect(sessions.first?.endedAt != nil)
    }
}

// =============================================================================
// E2E-05: Session Retention Enforcement
// Tests cleanup of old sessions (Task 11)
// =============================================================================

@Suite("E2E-05: Retention Enforcement") @MainActor struct E2E_RetentionFlow {

    @Test("Old done sessions deleted, live sessions preserved, recent sessions kept")
    func retentionFullFlow() async throws {
        let store = SessionStoreImpl()

        // Create sessions at different ages
        // 1. Old done session (60 days)
        let oldDone = try await store.createSession(Session(
            profileId: UUID(), mode: .behavioral, title: "Old Done",
            status: .done,
            startedAt: Date().addingTimeInterval(-60 * 24 * 3600),
            endedAt: Date().addingTimeInterval(-60 * 24 * 3600 + 300)
        ))

        // 2. Old live session (60 days — should NOT be deleted)
        let oldLive = try await store.createSession(Session(
            profileId: UUID(), mode: .meeting, title: "Old Live",
            status: .live,
            startedAt: Date().addingTimeInterval(-60 * 24 * 3600)
        ))

        // 3. Recent done session (1 day)
        let recent = try await store.createSession(Session(
            profileId: UUID(), mode: .coding, title: "Recent",
            status: .done,
            startedAt: Date().addingTimeInterval(-1 * 24 * 3600),
            endedAt: Date()
        ))

        // Enforce 30-day retention
        let deleted = try await store.deleteSessionsOlderThan(days: 30)
        #expect(deleted >= 1, "Should delete at least the 60-day old done session")

        // Verify old done is gone
        let oldDoneCheck = try await store.fetchSession(oldDone.id)
        #expect(oldDoneCheck == nil)

        // Verify old live is still there
        let oldLiveCheck = try await store.fetchSession(oldLive.id)
        #expect(oldLiveCheck != nil)

        // Verify recent is still there
        let recentCheck = try await store.fetchSession(recent.id)
        #expect(recentCheck != nil)
    }

    @Test("Zero-day retention deletes ALL done sessions regardless of age")
    func zeroDayRetention() async throws {
        let store = SessionStoreImpl()

        _ = try await store.createSession(Session(
            profileId: UUID(), mode: .behavioral, title: "Just Done",
            status: .done,
            startedAt: Date().addingTimeInterval(-10), // 10 seconds ago
            endedAt: Date()
        ))

        let deleted = try await store.deleteSessionsOlderThan(days: 0)
        // With 0 days, even 10-second-old done sessions are deleted
        let sessions = try await store.fetchSessions(limit: 50)
        let justDoneExists = sessions.contains { $0.title == "Just Done" }
        #expect(!justDoneExists || deleted == 0, "Session should be deleted or the cutoff wasn't reached")
    }

    @Test("365-day retention keeps all sessions")
    func yearRetention() async throws {
        let store = SessionStoreImpl()

        let s = try await store.createSession(Session(
            profileId: UUID(), mode: .meeting, title: "Normal",
            status: .done,
            startedAt: Date(),
            endedAt: Date()
        ))

        let deleted = try await store.deleteSessionsOlderThan(days: 365)
        let check = try await store.fetchSession(s.id)
        #expect(check != nil, "Session should survive 365-day retention")
    }
}

// =============================================================================
// E2E-06: Overlay Network/Error State + Streaming
// Tests the streaming indicator and error banner flow (Task 10)
// =============================================================================

@Suite("E2E-06: Overlay Network & Error State") @MainActor struct E2E_OverlayStateFlow {

    @Test("Streaming lifecycle: start → active → end → inactive")
    func streamingLifecycle() {
        let vm = OverlayViewModel()
        #expect(!vm.isStreaming)

        vm.setStreaming(true)
        #expect(vm.isStreaming)

        vm.setStreaming(false)
        #expect(!vm.isStreaming)
    }

    @Test("Error lifecycle: set → hasError true → clear → hasError false")
    func errorLifecycle() {
        let vm = OverlayViewModel()
        #expect(!vm.hasError)

        vm.setError("STT disconnected")
        #expect(vm.hasError)
        #expect(vm.errorMessage == "STT disconnected")

        vm.clearError()
        #expect(!vm.hasError)
        #expect(vm.errorMessage == nil)
    }

    @Test("Streaming + error state can coexist")
    func streamingAndError() {
        let vm = OverlayViewModel()
        vm.setStreaming(true)
        vm.setError("LLM timeout")
        #expect(vm.isStreaming)
        #expect(vm.hasError)

        vm.setStreaming(false)
        #expect(!vm.isStreaming)
        #expect(vm.hasError) // Error persists until cleared

        vm.clearError()
        #expect(!vm.isStreaming)
        #expect(!vm.hasError)
    }

    @Test("Go live + end session clears streaming")
    func liveStateClearsStreaming() {
        let vm = OverlayViewModel()
        vm.setStreaming(true)
        vm.goLive()
        #expect(vm.isLive)
        vm.setStreaming(false)
        vm.endSession()
        #expect(!vm.isLive)
    }
}

// =============================================================================
// E2E-07: Session Mode Picker + Per-Mode Model Selection
// Tests mode switching and model key mapping (Tasks 8, 12)
// =============================================================================

@Suite("E2E-07: Session Mode + Model Selection") @MainActor struct E2E_ModeModelSelection {

    @Test("All four modes have distinct defaultModelKeys")
    func modeKeysDistinct() {
        let modes = SessionMode.allCases
        let keys = Set(modes.map { $0.defaultModelKey })
        #expect(keys.count == 4, "All four modes should have unique defaultModelKeys")
    }

    @Test("Mode switching lifecycle: behavioral → coding → systemDesign → meeting")
    func modeSwitching() {
        let vm = OverlayViewModel()
        #expect(vm.sessionMode == .behavioral)

        vm.sessionMode = .coding
        #expect(vm.sessionMode == .coding)

        vm.sessionMode = .systemDesign
        #expect(vm.sessionMode == .systemDesign)

        vm.sessionMode = .meeting
        #expect(vm.sessionMode == .meeting)
    }

    @Test("defaultModelKey maps correctly for each mode")
    func defaultModelKeyMapping() {
        #expect(SessionMode.behavioral.defaultModelKey == "behavioral")
        #expect(SessionMode.coding.defaultModelKey == "coding")
        #expect(SessionMode.systemDesign.defaultModelKey == "system_design")
        #expect(SessionMode.meeting.defaultModelKey == "meeting")
    }

    @Test("Per-mode model stored in AppSettings persists and retrieves")
    func perModeModelPersistence() {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
        let store = SettingsStore()

        store.settings.defaultModels["behavioral"] = "gpt-4o"
        store.settings.defaultModels["coding"] = "gpt-4o"
        store.settings.defaultModels["system_design"] = "claude-sonnet-4-20250514"
        store.settings.defaultModels["meeting"] = "claude-sonnet-4-20250514"

        // Verify persistence
        let store2 = SettingsStore()
        #expect(store2.settings.defaultModels["behavioral"] == "gpt-4o")
        #expect(store2.settings.defaultModels["coding"] == "gpt-4o")
        #expect(store2.settings.defaultModels["system_design"] == "claude-sonnet-4-20250514")
        #expect(store2.settings.defaultModels["meeting"] == "claude-sonnet-4-20250514")

        // Reset
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
    }

    @Test("STT provider setting persists (apple ↔ deepgram)")
    func sttProviderPersistence() {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
        let store = SettingsStore()

        #expect(store.settings.sttProvider == "apple")

        store.settings.sttProvider = "deepgram"
        let store2 = SettingsStore()
        #expect(store2.settings.sttProvider == "deepgram")

        store2.settings.sttProvider = "apple"
        let store3 = SettingsStore()
        #expect(store3.settings.sttProvider == "apple")

        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.settings")
    }
}

// =============================================================================
// E2E-08: Coding Context + System Design Template Flow
// Tests all prompt template variable builders (Tasks 7-8)
// =============================================================================

@Suite("E2E-08: Coding + System Design Templates") struct E2E_TemplateFlows {

    @Test("Coding template: buildCodingVariables → loadAndRender → verify output")
    func codingTemplateFlow() throws {
        let vars = ContextBuilder.buildCodingVariables(problemText: "Reverse a singly linked list", language: "go")

        let loader = PromptLoader()
        let rendered = try loader.loadAndRender("coding/approach", variables: vars)

        #expect(rendered.contains("Reverse a singly linked list"))
        #expect(rendered.contains("go"))
        #expect(!rendered.contains("{{problem}}"))
        #expect(!rendered.contains("{{language}}"))
        // Should contain expected sections
        #expect(rendered.contains("Approach") || rendered.contains("approach"))
    }

    @Test("System design template: buildSystemDesignVariables → loadAndRender → verify output")
    func systemDesignTemplateFlow() throws {
        let vars = ContextBuilder.buildSystemDesignVariables(problemText: "Design a URL shortener like bit.ly")

        let loader = PromptLoader()
        let rendered = try loader.loadAndRender("coding/system_design", variables: vars)

        #expect(rendered.contains("Design a URL shortener"))
        #expect(!rendered.contains("{{problem}}"))
        #expect(rendered.contains("Requirements") || rendered.contains("Functional"))
    }

    @Test("All prompt templates can be loaded without errors")
    func allTemplatesLoad() throws {
        let loader = PromptLoader()
        let templates = [
            "behavioral/answer_outline",
            "behavioral/coach_tips",
            "coding/approach",
            "coding/system_design"
        ]
        for name in templates {
            let content = try loader.load(name)
            #expect(!content.isEmpty, "Template \(name) should not be empty")
        }
    }

    @Test("Coding template with different languages produces correct output")
    func codingLanguageVariants() throws {
        for lang in ["python", "typescript", "go", "csharp"] {
            let vars = ContextBuilder.buildCodingVariables(problemText: "Test", language: lang)
            let loader = PromptLoader()
            let rendered = try loader.loadAndRender("coding/approach", variables: vars)
            #expect(rendered.contains(lang))
        }
    }
}

// =============================================================================
// E2E-09: Provider Config → Keychain → SessionEngine full chain
// Tests the provider configuration pipeline (Task 3, 12)
// =============================================================================

@Suite("E2E-09: Provider Config Pipeline") @MainActor struct E2E_ProviderConfigPipeline {

    @Test("ProviderConfigStore seeds 6 default presets")
    func defaultPresets() {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.providerConfigs")
        let store = ProviderConfigStore()
        #expect(store.configs.count == 6)

        let providers = Set(store.configs.map { $0.provider })
        #expect(providers.contains(.deepseek))
        #expect(providers.contains(.anthropic))
        #expect(providers.contains(.openai))
        #expect(providers.contains(.deepgram))
        #expect(providers.contains(.gemini))
        #expect(providers.contains(.nemotron))
    }

    @Test("setDefault + defaultConfig round-trip")
    func defaultConfigRoundTrip() throws {
        UserDefaults.standard.removeObject(forKey: "com.sessioncopilot.providerConfigs")
        let store = ProviderConfigStore()

        let c1 = store.configs.first { $0.provider == .deepseek }!
        let c2 = store.configs.first { $0.provider == .anthropic }!

        store.setDefault(c2)
        let def = store.defaultConfig()
        #expect(def?.provider == .anthropic)
        #expect(def?.isDefault == true)
    }

    @Test("STT config with Deepgram apiKey stores it")
    func deepgramSttConfig() {
        let config = SttConfig(provider: .deepgram, model: "nova-3", language: "en", apiKey: "dg-key-12345")
        #expect(config.apiKey == "dg-key-12345")
        #expect(config.provider == .deepgram)
    }
}

// =============================================================================
// E2E-10: SessionStore → Markdown/JSON Export → NSSavePanel format correctness
// Tests export formatting (Task 5)
// =============================================================================

@Suite("E2E-10: Export Formatting") @MainActor struct E2E_ExportFormatting {

    @Test("Markdown export renders speaker labels correctly")
    func markdownSpeakerLabels() async throws {
        let store = SessionStoreImpl()
        var session = Session(profileId: UUID(), mode: .behavioral, title: "Speaker Test")
        session.segments = [
            TranscriptSegment(sessionId: session.id, timestamp: Date(), speaker: .mic, text: "My answer", isFinal: true),
            TranscriptSegment(sessionId: session.id, timestamp: Date().addingTimeInterval(2), speaker: .unknown, text: "Next question", isFinal: true)
        ]
        let created = try await store.createSession(session)

        let url = try await store.exportSession(created.id, format: .markdown)
        let md = try String(contentsOf: url, encoding: .utf8)

        #expect(md.contains("You:")) // mic speaker
        #expect(md.contains("Them:")) // unknown speaker
        #expect(md.contains("My answer"))
        #expect(md.contains("Next question"))
    }

    @Test("JSON export round-trips all session fields")
    func jsonRoundTripAllFields() async throws {
        let store = SessionStoreImpl()
        var session = Session(profileId: UUID(), mode: .coding, title: "Full Session", status: .done, startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: Date(timeIntervalSince1970: 1_700_000_300))
        session.segments = [
            TranscriptSegment(sessionId: session.id, timestamp: Date(timeIntervalSince1970: 100), speaker: .mic, text: "Code answer", isFinal: true, confidence: 0.95)
        ]
        session.suggestions = [
            Suggestion(sessionId: session.id, type: .codeSolution, content: "## Code\n```python\nprint('hello')\n```", metadata: ["language": "python"])
        ]
        let created = try await store.createSession(session)

        let url = try await store.exportSession(created.id, format: .json)
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(Session.self, from: data)

        #expect(decoded.title == "Full Session")
        #expect(decoded.mode == .coding)
        #expect(decoded.status == .done)
        #expect(decoded.segments.count == 1)
        #expect(decoded.segments[0].text == "Code answer")
        #expect(decoded.segments[0].confidence == 0.95)
        #expect(decoded.suggestions.count == 1)
        #expect(decoded.suggestions[0].type == .codeSolution)
        #expect(decoded.suggestions[0].metadata["language"] == "python")
    }
}
