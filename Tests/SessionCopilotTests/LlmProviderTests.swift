import Foundation
import Testing
@testable import SessionCopilot

// MARK: - LlmClientImpl Provider-Specific Request Building

@Suite("LlmClientImpl Request Building") @MainActor struct LlmClientRequestTests {

    @Test("Anthropic request uses /v1/messages endpoint")
    func anthropicURLEndpoint() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .anthropic,
            baseURL: "https://api.anthropic.com",
            model: "claude-sonnet-4-20250514",
            apiKeyRef: "test-anthropic-key"
        )
        try client.configure(config, apiKey: "test-key")

        let request = LlmRequest(model: "claude-sonnet-4-20250514", mode: .behavioral, prompt: "Test")
        let (urlRequest, _) = try LlmClientImpl.buildRequest(request, config: config, apiKey: "test-key", stream: true)

        let urlStr = urlRequest.url?.absoluteString ?? ""
        #expect(urlStr.contains("/v1/messages"), "Anthropic should use /v1/messages, got: \(urlStr)")
        #expect(!urlStr.contains("/v1/chat/completions"), "Anthropic should NOT use /v1/chat/completions")
    }

    @Test("Anthropic request has system as top-level field, not message role")
    func anthropicSystemField() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .anthropic,
            baseURL: "https://api.anthropic.com",
            model: "claude-sonnet-4-20250514",
            apiKeyRef: "test-anthropic-key"
        )
        try client.configure(config, apiKey: "test-key")

        let request = LlmRequest(model: "claude-sonnet-4-20250514", mode: .behavioral, prompt: "Test question")
        let (_, bodyData) = try LlmClientImpl.buildRequest(request, config: config, apiKey: "test-key", stream: true)

        let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] ?? [:]

        // Anthropic: system is a top-level string field
        #expect(body["system"] != nil, "Anthropic body should have top-level 'system' field")
        let system = body["system"] as? String
        #expect(system != nil && !system!.isEmpty, "system should be a non-empty string")

        // Messages should only contain user/assistant roles, not system
        let messages = body["messages"] as? [[String: Any]] ?? []
        for msg in messages {
            let role = msg["role"] as? String ?? ""
            #expect(role != "system", "Anthropic messages should not contain 'system' role, found: \(role)")
        }
    }

    @Test("OpenAI-compatible request uses /v1/chat/completions endpoint")
    func openaiCompatibleURLEndpoint() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .deepseek,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            apiKeyRef: "test-deepseek-key"
        )
        try client.configure(config, apiKey: "test-key")

        let request = LlmRequest(model: "deepseek-chat", mode: .behavioral, prompt: "Test")
        let (urlRequest, _) = try LlmClientImpl.buildRequest(request, config: config, apiKey: "test-key", stream: true)

        let urlStr = urlRequest.url?.absoluteString ?? ""
        #expect(urlStr.contains("/v1/chat/completions"), "OpenAI-compatible should use /v1/chat/completions, got: \(urlStr)")
    }

    @Test("OpenAI-compatible request has system as message role")
    func openaiCompatibleSystemRole() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .deepseek,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            apiKeyRef: "test-deepseek-key"
        )
        try client.configure(config, apiKey: "test-key")

        let request = LlmRequest(model: "deepseek-chat", mode: .behavioral, prompt: "Test question")
        let (_, bodyData) = try LlmClientImpl.buildRequest(request, config: config, apiKey: "test-key", stream: true)

        let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] ?? [:]

        // OpenAI: system is a message role
        #expect(body["system"] == nil, "OpenAI-compatible body should NOT have top-level 'system' field")
        let messages = body["messages"] as? [[String: Any]] ?? []
        let hasSystemRole = messages.contains { ($0["role"] as? String) == "system" }
        #expect(hasSystemRole, "OpenAI-compatible should have system as a message role")
    }

    @Test("Anthropic request has x-api-key header")
    func anthropicAuthHeader() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .anthropic,
            baseURL: "https://api.anthropic.com",
            model: "claude-sonnet-4-20250514",
            apiKeyRef: "test-anthropic-key"
        )
        try client.configure(config, apiKey: "test-key")

        let request = LlmRequest(model: "claude-sonnet-4-20250514", mode: .behavioral, prompt: "Test")
        let (urlRequest, _) = try LlmClientImpl.buildRequest(request, config: config, apiKey: "test-key", stream: true)

        #expect(urlRequest.value(forHTTPHeaderField: "x-api-key") != nil, "Anthropic should have x-api-key header")
        #expect(urlRequest.value(forHTTPHeaderField: "anthropic-version") != nil, "Anthropic should have anthropic-version header")
    }

    @Test("OpenAI-compatible request has Bearer auth")
    func openaiCompatibleAuthHeader() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .deepseek,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            apiKeyRef: "test-deepseek-key"
        )
        try client.configure(config, apiKey: "test-key")

        let request = LlmRequest(model: "deepseek-chat", mode: .behavioral, prompt: "Test")
        let (urlRequest, _) = try LlmClientImpl.buildRequest(request, config: config, apiKey: "test-key", stream: true)

        let auth = urlRequest.value(forHTTPHeaderField: "Authorization") ?? ""
        #expect(auth.hasPrefix("Bearer "), "OpenAI-compatible should have Bearer auth, got: \(auth)")
    }
}

// MARK: - LlmClientImpl Response Parsing

@Suite("LlmClientImpl Response Parsing") @MainActor struct LlmClientResponseTests {

    @Test("Anthropic non-streaming response parsed correctly")
    func anthropicResponseParsing() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .anthropic,
            baseURL: "https://api.anthropic.com",
            model: "claude-sonnet-4-20250514",
            apiKeyRef: "test-key"
        )
        try client.configure(config, apiKey: "test-key")

        // Simulate Anthropic non-streaming response
        let anthropicResponse: [String: Any] = [
            "content": [
                ["type": "text", "text": "## Outline\n- Point 1\n- Point 2\n\n## Coach Tips\n- Tip 1"]
            ],
            "model": "claude-sonnet-4-20250514"
        ]
        let data = try JSONSerialization.data(withJSONObject: anthropicResponse)

        let response = try LlmClientImpl.parseResponse(data, config: ProviderConfig(provider: .anthropic, baseURL: "", model: "", apiKeyRef: ""))

        #expect(response.sections.count >= 1)
        #expect(response.sections.contains { $0.title == "Outline" })
        #expect(response.sections.contains { $0.title == "Coach Tips" })
    }

    @Test("OpenAI non-streaming response parsed correctly (no regression)")
    func openaiResponseParsing() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .deepseek,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            apiKeyRef: "test-key"
        )
        try client.configure(config, apiKey: "test-key")

        // Simulate OpenAI-compatible response
        let openaiResponse: [String: Any] = [
            "choices": [
                ["message": ["role": "assistant", "content": "## Outline\n- Point 1"], "finish_reason": "stop"]
            ],
            "model": "deepseek-chat"
        ]
        let data = try JSONSerialization.data(withJSONObject: openaiResponse)

        let response = try LlmClientImpl.parseResponse(data, config: ProviderConfig(provider: .deepseek, baseURL: "", model: "", apiKeyRef: ""))

        #expect(response.sections.count >= 1)
        #expect(response.sections.contains { $0.title == "Outline" })
    }
}

// MARK: - LlmClientImpl Token Extraction

@Suite("LlmClientImpl Token Extraction") @MainActor struct LlmClientTokenTests {

    @Test("Anthropic streaming content_block_delta extracted")
    func anthropicStreamToken() throws {
        let client = LlmClientImpl()

        let event: [String: Any] = [
            "type": "content_block_delta",
            "delta": ["type": "text_delta", "text": "Hello"]
        ]

        let token = LlmClientImpl.extractToken(event, provider: .anthropic)
        #expect(token.text == "Hello")
        #expect(!token.isDone)
    }

    @Test("Anthropic message_stop signals done")
    func anthropicStreamDone() throws {
        let client = LlmClientImpl()

        let event: [String: Any] = [
            "type": "message_stop"
        ]

        let token = LlmClientImpl.extractToken(event, provider: .anthropic)
        #expect(token.isDone, "message_stop should signal done")
    }

    @Test("OpenAI streaming token extracted (no regression)")
    func openaiStreamToken() throws {
        let client = LlmClientImpl()

        let event: [String: Any] = [
            "choices": [["delta": ["content": "Hi"], "finish_reason": NSNull()]]
        ]

        let token = LlmClientImpl.extractToken(event, provider: .deepseek)
        #expect(token.text == "Hi")
        #expect(!token.isDone)
    }

    @Test("OpenAI finish_reason stop signals done (no regression)")
    func openaiStreamDone() throws {
        let client = LlmClientImpl()

        let event: [String: Any] = [
            "choices": [["delta": [:], "finish_reason": "stop"]]
        ]

        let token = LlmClientImpl.extractToken(event, provider: .deepseek)
        #expect(token.isDone)
    }
}

// MARK: - DeepgramSttClient Auth

@Suite("DeepgramSttClient Auth") @MainActor struct DeepgramAuthTests {

    @Test("SttConfig with apiKey stores it")
    func sttConfigWithApiKey() {
        let config = SttConfig(provider: .deepgram, model: "nova-3", language: "en", apiKey: "test-key-123")
        #expect(config.apiKey == "test-key-123")
    }

    @Test("SttConfig without apiKey defaults to nil")
    func sttConfigNoApiKey() {
        let config = SttConfig(provider: .deepgram, model: "nova-3")
        #expect(config.apiKey == nil)
    }
}
