import Foundation

/// Implementation of LlmClient supporting DeepSeek, Anthropic, and OpenAI-compatible APIs.
@MainActor
public final class LlmClientImpl: LlmClient {
    private var config: ProviderConfig?
    private var apiKey: String?
    private let session = URLSession(configuration: .default)

    public init() {}

    /// Configure with a provider config and API key.
    public func configure(_ config: ProviderConfig, apiKey: String) throws {
        self.config = config
        self.apiKey = apiKey
    }

    // MARK: - Streaming

    public func streamCompletion(_ request: LlmRequest) -> AsyncStream<LlmToken> {
        // ponytail: capture everything @MainActor before crossing into AsyncStream.
        // The inner Task may not inherit @MainActor, so we pass values explicitly.
        let config = self.config
        let apiKey = self.apiKey
        let session = self.session

        return AsyncStream { continuation in
            Task {
                guard let config, let apiKey else {
                    continuation.yield(LlmToken(text: "[Error: Client not configured. Add an API key in Settings → Providers.]", isDone: true))
                    continuation.finish()
                    return
                }
                do {
                    try await Self.performStreamRequest(
                        request,
                        config: config,
                        apiKey: apiKey,
                        session: session,
                        continuation: continuation
                    )
                } catch {
                    continuation.yield(LlmToken(text: "[Error: \(error.localizedDescription)]", isDone: true))
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Non-streaming

    public func complete(_ request: LlmRequest) async throws -> LlmResponse {
        guard let config, let apiKey else { throw LlmError.notConfigured }

        let (urlRequest, body) = try Self.buildRequest(request, config: config, apiKey: apiKey)
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw LlmError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return try Self.parseResponse(data, config: config)
    }

    // MARK: - Private

    private static func performStreamRequest(
        _ request: LlmRequest,
        config: ProviderConfig,
        apiKey: String,
        session: URLSession,
        continuation: AsyncStream<LlmToken>.Continuation
    ) async throws {
        let (urlRequest, _) = try Self.buildRequest(request, config: config, apiKey: apiKey, stream: true)

        let (bytes, response) = try await session.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw LlmError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        var buffer = ""
        for try await line in bytes.lines {
            // SSE format: "data: {...}" or "data: [DONE]"
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))

            if jsonStr == "[DONE]" {
                continuation.yield(LlmToken(text: "", isDone: true))
                return
            }

            guard let jsonData = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            let token = Self.extractToken(obj, provider: config.provider)
            continuation.yield(token)
        }

        continuation.yield(LlmToken(text: "", isDone: true))
    }

    /// Build the HTTP request for the configured provider.
    /// Internal for testing.
    static func buildRequest(_ request: LlmRequest, config: ProviderConfig, apiKey: String, stream: Bool = false) throws -> (URLRequest, Data) {

        // Anthropic uses /v1/messages; OpenAI-compatible uses /v1/chat/completions
        let endpoint = config.provider == .anthropic ? "/v1/messages" : "/v1/chat/completions"
        let url = URL(string: "\(config.baseURL)\(endpoint)")!

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch config.provider {
        case .anthropic:
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        default:
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let systemPrompt: String
        switch request.mode {
        case .behavioral:
            systemPrompt = "You output only concise answer outlines. No greetings, no examples, no narration. Bullet points only."
        case .coding:
            systemPrompt = "You are a coding interview assistant. Provide approach, complexity, and code."
        case .meeting:
            systemPrompt = "You are a meeting assistant providing structured notes and action items."
        case .technicalVerbal:
            systemPrompt = "You are a technical interview copilot providing clear explanations with trade-offs."
        }

        let body: [String: Any]

        switch config.provider {
        case .anthropic:
            // Anthropic: system is a top-level field, messages are user/assistant only
            let userMessage: [String: Any]
            if let imageBase64 = request.imageBase64 {
                // Multimodal: text + image
                userMessage = [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": request.prompt],
                        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": imageBase64]]
                    ]
                ]
            } else {
                userMessage = ["role": "user", "content": request.prompt]
            }
            body = [
                "model": config.model,
                "system": systemPrompt,
                "messages": [userMessage],
                "max_tokens": request.maxTokens,
                "stream": stream
            ]
        case .deepseek:
            // DeepSeek: OpenAI-compatible with thinking disabled (v4 defaults to reasoning mode)
            let userMessage: [String: Any]
            if let imageBase64 = request.imageBase64 {
                userMessage = [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": request.prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageBase64)"]]
                    ]
                ]
            } else {
                userMessage = ["role": "user", "content": request.prompt]
            }
            body = [
                "model": config.model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    userMessage
                ],
                "max_tokens": request.maxTokens,
                "stream": stream,
                "thinking": ["type": "disabled"]
            ]
        default:
            // OpenAI-compatible: system is a message role
            let userMessage: [String: Any]
            if let imageBase64 = request.imageBase64 {
                // Multimodal: text + image_url
                userMessage = [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": request.prompt],
                        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(imageBase64)"]]
                    ]
                ]
            } else {
                userMessage = ["role": "user", "content": request.prompt]
            }
            body = [
                "model": config.model,
                "messages": [
                    ["role": "system", "content": systemPrompt],
                    userMessage
                ],
                "max_tokens": request.maxTokens,
                "stream": stream
            ]
        }

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        urlRequest.httpBody = bodyData

        return (urlRequest, bodyData)
    }

    /// Extract a token from an SSE event.
    /// Internal for testing.
    static func extractToken(_ obj: [String: Any], provider: ProviderConfig.Provider) -> LlmToken {
        // OpenAI-compatible format (DeepSeek, OpenAI, Nemotron, custom)
        if let choices = obj["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any] {
            let content = delta["content"] as? String
                ?? delta["reasoning_content"] as? String
                ?? ""
            let finishReason = choices.first?["finish_reason"] as? String
            return LlmToken(text: content, isDone: finishReason == "stop")
        }

        // Anthropic streaming format
        if let type = obj["type"] as? String {
            if type == "content_block_delta",
               let delta = obj["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                return LlmToken(text: text, isDone: false)
            }
            if type == "message_stop" {
                return LlmToken(text: "", isDone: true)
            }
        }

        return LlmToken(text: "", isDone: false)
    }

    /// Parse a non-streaming HTTP response.
    /// Internal for testing.
    static func parseResponse(_ data: Data, config: ProviderConfig) throws -> LlmResponse {
        let provider = config.provider
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        let content: String

        switch provider {
        case .anthropic:
            // Anthropic: content is an array of blocks with type+text
            if let contentBlocks = json["content"] as? [[String: Any]] {
                content = contentBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                content = ""
            }
        default:
            // OpenAI-compatible: content is in choices[0].message.content
            if let choices = json["choices"] as? [[String: Any]],
               let message = choices.first?["message"] as? [String: Any],
               let text = message["content"] as? String {
                content = text
            } else {
                content = ""
            }
        }

        // Parse sections from markdown
        var sections: [LlmResponse.Section] = []
        var currentTitle = "Response"
        var currentContent = ""

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if !currentContent.isEmpty {
                    sections.append(LlmResponse.Section(title: currentTitle, content: currentContent.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                currentTitle = String(line.dropFirst(3))
                currentContent = ""
            } else {
                currentContent += line + "\n"
            }
        }
        if !currentContent.isEmpty {
            sections.append(LlmResponse.Section(title: currentTitle, content: currentContent.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return LlmResponse(sections: sections, metadata: [
            "model": config.model,
            "provider": config.provider.rawValue
        ])
    }
}

enum LlmError: LocalizedError {
    case notConfigured
    case httpError(Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Client not configured. Add your API key in Settings → Providers."
        case .httpError(let code):
            switch code {
            case 401: return "HTTP 401 Unauthorized — your API key is invalid. Check it in Settings → Providers."
            case 403: return "HTTP 403 Forbidden — your API key may not have access to this model."
            case 429: return "HTTP 429 Too Many Requests — rate limited. Wait and try again."
            case 500...599: return "HTTP \(code) — server error on the provider side. Try again later."
            default: return "HTTP \(code) — unexpected response from the provider."
            }
        }
    }
}
