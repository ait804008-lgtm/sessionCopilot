import Foundation
import Testing
@testable import SessionCopilot

// MARK: - Coding Context Builder Tests

@Suite("ContextBuilder Coding Variables") struct ContextBuilderCodingTests {

    @Test("buildCodingVariables produces all required keys")
    func producesAllKeys() {
        let vars = ContextBuilder.buildCodingVariables(
            problemText: "Reverse a linked list",
            language: "python"
        )
        #expect(vars["problem"] != nil)
        #expect(vars["language"] != nil)
    }

    @Test("buildCodingVariables includes problem text")
    func includesProblem() {
        let vars = ContextBuilder.buildCodingVariables(
            problemText: "Two sum problem",
            language: "go"
        )
        #expect(vars["problem"] == "Two sum problem")
    }

    @Test("buildCodingVariables includes language")
    func includesLanguage() {
        let vars = ContextBuilder.buildCodingVariables(
            problemText: "Test",
            language: "typescript"
        )
        #expect(vars["language"] == "typescript")
    }

    @Test("buildCodingVariables + PromptLoader renders coding template")
    func buildAndRenderCodingTemplate() throws {
        let vars = ContextBuilder.buildCodingVariables(
            problemText: "Reverse a linked list",
            language: "python"
        )
        let loader = PromptLoader()
        let rendered = try loader.loadAndRender("coding/approach", variables: vars)

        #expect(rendered.contains("Reverse a linked list"))
        #expect(rendered.contains("python"))
        #expect(!rendered.contains("{{problem}}"))
        #expect(!rendered.contains("{{language}}"))
    }
}

// MARK: - LlmClientImpl Vision Request Tests

@Suite("LlmClientImpl Vision Request") @MainActor struct LlmClientVisionTests {

    @Test("buildVisionRequest includes image_url for OpenAI-compatible")
    func openaiVisionRequestHasImage() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .openai,
            baseURL: "https://api.openai.com",
            model: "gpt-4o",
            apiKeyRef: "test-openai-key"
        )
        try client.configure(config, apiKey: "test-key")

        let request = LlmRequest(
            model: "gpt-4o",
            mode: .coding,
            prompt: "Analyze this problem",
            imageBase64: "iVBORw0KGgo=",
            maxTokens: 500
        )

        let (urlRequest, bodyData) = try LlmClientImpl.buildRequest(request, config: config, apiKey: "test-key", stream: false)

        let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? []

        // The user message should have content as an array (multimodal)
        let userMessage = messages.first { ($0["role"] as? String) == "user" }
        let content = userMessage?["content"]

        // For OpenAI-compatible, content should be an array with text + image_url
        #expect(content is [Any], "Vision request content should be an array for OpenAI-compatible")
        let contentArray = content as? [[String: Any]] ?? []
        #expect(contentArray.contains { $0["type"] as? String == "image_url" }, "Should have image_url type")
        #expect(contentArray.contains { $0["type"] as? String == "text" }, "Should have text type")
    }

    @Test("buildVisionRequest includes image for Anthropic")
    func anthropicVisionRequestHasImage() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .anthropic,
            baseURL: "https://api.anthropic.com",
            model: "claude-sonnet-4-20250514",
            apiKeyRef: "test-anthropic-key"
        )
        try client.configure(config, apiKey: "test-key")

        let request = LlmRequest(
            model: "claude-sonnet-4-20250514",
            mode: .coding,
            prompt: "Analyze this problem",
            imageBase64: "iVBORw0KGgo=",
            maxTokens: 500
        )

        let (_, bodyData) = try LlmClientImpl.buildRequest(request, config: config, apiKey: "test-key", stream: false)

        let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? []
        let userMessage = messages.first { ($0["role"] as? String) == "user" }
        let content = userMessage?["content"]

        // For Anthropic, content should be an array with text + image source
        #expect(content is [Any], "Vision request content should be an array for Anthropic")
        let contentArray = content as? [[String: Any]] ?? []
        #expect(contentArray.contains { $0["type"] as? String == "image" }, "Should have image type for Anthropic")
        #expect(contentArray.contains { $0["type"] as? String == "text" }, "Should have text type")
    }

    @Test("buildRequest without image uses plain string content (no regression)")
    func noImageUsesStringContent() throws {
        let client = LlmClientImpl()
        let config = ProviderConfig(
            provider: .deepseek,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-chat",
            apiKeyRef: "test-key"
        )
        try client.configure(config, apiKey: "test-key")

        let request = LlmRequest(
            model: "deepseek-chat",
            mode: .behavioral,
            prompt: "Test question",
            maxTokens: 250
        )

        let (_, bodyData) = try LlmClientImpl.buildRequest(request, config: config, apiKey: "test-key", stream: false)

        let body = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? []
        let userMessage = messages.first { ($0["role"] as? String) == "user" }
        let content = userMessage?["content"]

        // Without image, content should be a plain string
        #expect(content is String, "Non-vision request should use string content")
    }
}
