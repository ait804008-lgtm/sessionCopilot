import Foundation
import AppKit
import SwiftUI
import os

/// Orchestrates LLM calls: question answering, coding capture,
/// semantic question classification.
///
/// Extracted from `AppDelegate.handleQuestion()` and
/// `AppDelegate.handleCodingCapture()` as part of the controller split.
/// Owns no UI state — writes results to `OverlayViewModel` and persists
/// suggestions via `SessionEngine`.
@MainActor
public final class LlmOrchestrator {
    private let services: Services
    private weak var sessionLifecycle: SessionLifecycleController?
    private var regionCapture: RegionCapture?
    private var codingLanguage: String = "python"

    public init(services: Services, sessionLifecycle: SessionLifecycleController) {
        self.services = services
        self.sessionLifecycle = sessionLifecycle
    }

    // MARK: - Question handling (with semantic detection gate)

    /// Entry point for a detected question. If semantic detection is
    /// enabled, runs `LlmQuestionClassifier` first; on `isQuestion == true`,
    /// fires the LLM answer. Otherwise skips silently.
    public func handleQuestion(_ questionText: String) {
        let trimmed = questionText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        if services.settingsStore.settings.semanticDetectionEnabled {
            Task {
                let classification = await self.classifyQuestion(trimmed)
                await MainActor.run {
                    if classification.isQuestion {
                        Log.classifier.info("Question confirmed (confidence=\(classification.confidence, privacy: .public)) — firing LLM answer")
                        self.fireLlmAnswer(for: trimmed)
                    } else {
                        Log.classifier.info("Not a question — skipping LLM answer (rationale: \(classification.rationale ?? "none", privacy: .public))")
                    }
                }
            }
        } else {
            fireLlmAnswer(for: trimmed)
        }
    }

    /// Run the LLM question classifier on `text`. Returns `.assumedYes`
    /// if the classifier can't be constructed so the caller falls back
    /// to firing the LLM answer unconditionally.
    public func classifyQuestion(_ text: String) async -> QuestionClassification {
        let providerConfig = services.providerStore.defaultConfig() ?? ProviderConfig(
            provider: .deepseek,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            apiKeyRef: "com.sessioncopilot.deepseek-key",
            isDefault: true
        )
        let apiKey = (try? KeychainStore().load(key: providerConfig.apiKeyRef))
            ?? ProcessInfo.processInfo.environment["\(providerConfig.provider.rawValue.uppercased())_API_KEY"]

        guard let key = apiKey, !key.isEmpty else {
            Log.classifier.warning("No API key for classifier — assuming question (falling back to pre-feature behavior)")
            return .assumedYes
        }

        let client = LlmClientImpl()
        do {
            try client.configure(providerConfig, apiKey: key)
        } catch {
            Log.classifier.error("Failed to configure classifier client: \(error.localizedDescription, privacy: .public)")
            return .assumedYes
        }

        let transcript = services.viewModel.chatMessages
            .suffix(10)
            .map { "\($0.role == .user ? "You" : "Them"): \($0.text)" }
            .joined(separator: "\n")

        let classifier = LlmQuestionClassifier(
            client: client,
            model: providerConfig.model,
            promptLoader: PromptLoader()
        )
        return await classifier.classify(text, context: ["transcript": transcript])
    }

    /// Fire the LLM answer generation for `questionText`.
    public func fireLlmAnswer(for questionText: String) {
        let viewModel = services.viewModel
        viewModel.startAssistantResponse()
        viewModel.clearError()
        viewModel.setStreaming(true)

        Task {
            let client = LlmClientImpl()
            let providerConfig = services.providerStore.defaultConfig() ?? ProviderConfig(
                provider: .deepseek,
                baseURL: "https://api.deepseek.com",
                model: "deepseek-v4-flash",
                apiKeyRef: "com.sessioncopilot.deepseek-key",
                isDefault: true
            )
            let apiKey = (try? KeychainStore().load(key: providerConfig.apiKeyRef))
                ?? ProcessInfo.processInfo.environment["\(providerConfig.provider.rawValue.uppercased())_API_KEY"]

            guard let key = apiKey, !key.isEmpty else {
                await MainActor.run {
                    viewModel.finalizeAssistantResponse()
                    viewModel.setStreaming(false)
                    viewModel.setError("No API key for \(providerConfig.provider.rawValue.capitalized). Add it in Settings → Providers.")
                }
                return
            }

            do {
                try client.configure(providerConfig, apiKey: key)
                let prompt: String
                if let profile = sessionLifecycle?.selectedProfile {
                    let loader = PromptLoader()
                    let vars = ContextBuilder.buildVariables(
                        profile: profile,
                        chatMessages: viewModel.chatMessages,
                        questionText: questionText,
                        language: services.settingsStore.settings.sttLanguage
                    )
                    if let rendered = try? loader.loadAndRender("behavioral/answer_outline", variables: vars) {
                        prompt = rendered
                    } else {
                        prompt = ContextBuilder.behavioral(
                            profile: profile,
                            chatMessages: viewModel.chatMessages,
                            questionText: questionText,
                            language: services.settingsStore.settings.sttLanguage
                        )
                    }
                } else {
                    prompt = """
                    Interview question: "\(questionText)"

                    Give ONLY a concise answer outline in bullet points. No greetings, no examples, no narration.
                    Use STAR format if applicable.
                    End with 2-3 brief coach tips (one line each).
                    """
                }

                let request = LlmRequest(
                    model: services.settingsStore.settings.defaultModels[viewModel.sessionMode.defaultModelKey]
                        ?? providerConfig.model,
                    mode: .behavioral,
                    prompt: prompt,
                    maxTokens: 250
                )

                var fullResponse = ""
                for await token in client.streamCompletion(request) {
                    fullResponse += token.text
                    await MainActor.run {
                        viewModel.updateAssistantResponse(fullResponse)
                    }
                    if token.isDone { break }
                }
                if fullResponse.isEmpty {
                    viewModel.setError("LLM returned empty response")
                } else {
                    if let engine = sessionLifecycle?.sessionEngine,
                       let sid = engine.currentSessionId {
                        await engine.persistSuggestion(Suggestion(
                            sessionId: sid,
                            type: .answerOutline,
                            content: fullResponse,
                            metadata: ["model": providerConfig.model, "provider": providerConfig.provider.rawValue]
                        ))
                    }
                }
                viewModel.finalizeAssistantResponse()
                viewModel.setStreaming(false)
            } catch {
                await MainActor.run {
                    viewModel.finalizeAssistantResponse()
                    viewModel.setStreaming(false)
                    viewModel.setError("LLM error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Coding capture

    public func captureCodingProblem() {
        let viewModel = services.viewModel
        viewModel.show()
        Task { [weak self] in
            self?.regionCapture = RegionCapture()
            guard let imageBase64 = await self?.regionCapture?.captureRegion() else {
                return
            }
            await MainActor.run {
                viewModel.startAssistantResponse()
                viewModel.setStreaming(true)
            }
            await self?.handleCodingCapture(imageBase64: imageBase64)
        }
    }

    public func handleCodingCapture(imageBase64: String) async {
        let client = LlmClientImpl()
        let viewModel = services.viewModel

        let providerConfig = services.providerStore.defaultConfig() ?? ProviderConfig(
            provider: .deepseek,
            baseURL: "https://api.deepseek.com",
            model: "deepseek-v4-flash",
            apiKeyRef: "com.sessioncopilot.deepseek-key",
            isDefault: true
        )

        let apiKey = (try? KeychainStore().load(key: providerConfig.apiKeyRef))
            ?? ProcessInfo.processInfo.environment["\(providerConfig.provider.rawValue.uppercased())_API_KEY"]

        guard let key = apiKey, !key.isEmpty else {
            await MainActor.run {
                viewModel.finalizeAssistantResponse()
                viewModel.setStreaming(false)
                viewModel.setError("No API key for \(providerConfig.provider.rawValue.capitalized). Add it in Settings → Providers.")
            }
            return
        }

        do {
            try client.configure(providerConfig, apiKey: key)
            let loader = PromptLoader()
            let prompt: String
            let mode: LlmRequest.Mode

            switch viewModel.sessionMode {
            case .systemDesign:
                let vars = ContextBuilder.buildSystemDesignVariables(
                    problemText: "[Problem captured from screen — see image]"
                )
                prompt = (try? loader.loadAndRender("coding/system_design", variables: vars))
                    ?? "Analyze the system design problem shown in the image."
                mode = .coding
            case .coding:
                let vars = ContextBuilder.buildCodingVariables(
                    problemText: "[Problem captured from screen — see image]",
                    language: codingLanguage
                )
                prompt = (try? loader.loadAndRender("coding/approach", variables: vars))
                    ?? ContextBuilder.coding(problemText: "[Problem captured from screen — see image]", language: codingLanguage)
                mode = .coding
            default:
                let vars = ContextBuilder.buildCodingVariables(
                    problemText: "[Problem captured from screen — see image]",
                    language: codingLanguage
                )
                prompt = (try? loader.loadAndRender("coding/approach", variables: vars))
                    ?? ContextBuilder.coding(problemText: "[Problem captured from screen — see image]", language: codingLanguage)
                mode = .coding
            }

            let request = LlmRequest(
                model: providerConfig.model,
                mode: mode,
                prompt: prompt,
                imageBase64: imageBase64,
                maxTokens: 800
            )

            var fullResponse = ""
            for await token in client.streamCompletion(request) {
                fullResponse += token.text
                await MainActor.run {
                    viewModel.updateAssistantResponse(fullResponse)
                }
                if token.isDone { break }
            }

            await MainActor.run {
                if fullResponse.isEmpty {
                    viewModel.setError("LLM returned empty response")
                }
                viewModel.finalizeAssistantResponse()
                viewModel.setStreaming(false)
            }
        } catch {
            await MainActor.run {
                viewModel.finalizeAssistantResponse()
                viewModel.setStreaming(false)
                viewModel.setError("LLM error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Clipboard

    public func copyLastSuggestion() {
        let text = services.viewModel.lastAssistantResponse
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
