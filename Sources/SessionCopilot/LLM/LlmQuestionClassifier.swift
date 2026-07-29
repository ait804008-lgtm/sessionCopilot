import Foundation
import os

/// `QuestionClassifier` backed by the user's main LLM provider.
///
/// Uses `LlmClient.complete(_:)` (non-streaming) with a small
/// `maxTokens` budget to classify whether candidate text is a question.
///
/// Designed for graceful degradation:
/// - On any error (network, parse, malformed JSON), returns `.assumedNo`
///   so the caller skips the LLM answer. This prevents spurious LLM calls
///   on classifier failures — the safer default for cost and overlay
///   pollution.
/// - On empty text, returns `.assumedNo` immediately without an LLM call.
@MainActor
public final class LlmQuestionClassifier: QuestionClassifier {
    private let client: LlmClient
    private let model: String
    /// Optional prompt loader. If nil, uses `ContextBuilder.classification`
    /// inline prompt instead of a template file.
    private let promptLoader: PromptLoader?

    /// - Parameters:
    ///   - client: Configured LLM client. The caller is responsible for
    ///     calling `configure(_, apiKey:)` before this classifier is used.
    ///   - model: Model name to send in the `LlmRequest`. Should match
    ///     the user's configured provider model (e.g. "deepseek-v4-flash",
    ///     "gpt-4o-mini"). The classifier is cheap — a small/cheap model
    ///     is preferred.
    ///   - promptLoader: Optional `PromptLoader` for the
    ///     `classification/question.md` template. If nil, the inline
    ///     `ContextBuilder.classification` prompt is used.
    public init(
        client: LlmClient,
        model: String,
        promptLoader: PromptLoader? = nil
    ) {
        self.client = client
        self.model = model
        self.promptLoader = promptLoader
    }

    public func classify(_ text: String, context: [String: String]) async -> QuestionClassification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            Log.classifier.debug("Empty text — assuming not a question")
            return .assumedNo
        }

        // Build prompt: prefer template, fall back to inline.
        let prompt: String
        if let loader = promptLoader,
           let rendered = try? loader.loadAndRender(
               "classification/question",
               variables: ContextBuilder.buildClassificationVariables(
                   text: trimmed,
                   transcript: context["transcript"] ?? ""
               )
           ) {
            prompt = rendered
        } else {
            prompt = ContextBuilder.classification(
                text: trimmed,
                transcript: context["transcript"] ?? ""
            )
        }

        let request = LlmRequest(
            model: model,
            mode: .behavioral,  // reuse the behavioral system prompt; classification is mode-agnostic
            prompt: prompt,
            maxTokens: 80  // generous for a single-line JSON response
        )

        do {
            let response = try await client.complete(request)
            return Self.parseClassification(from: response)
        } catch {
            Log.classifier.error("Classification LLM call failed: \(error.localizedDescription, privacy: .public)")
            return .assumedNo
        }
    }

    /// Parse the LLM's JSON response into a `QuestionClassification`.
    /// Tolerates:
    /// - Markdown code fences ```json ... ```
    /// - Extra whitespace / newlines
    /// - Missing `rationale` field (defaults to nil)
    /// - `confidence` as Int (0 or 1) instead of Double
    /// - Snake_case keys (per the prompt) OR camelCase keys (some models)
    ///
    /// On any parse failure, returns `.assumedNo`.
    internal static func parseClassification(from response: LlmResponse) -> QuestionClassification {
        // The prompt asks for a single JSON object on one line. Some
        // providers wrap multi-section responses; concatenate all
        // section contents and search for the first `{...}` block.
        let raw = response.sections.map(\.content).joined(separator: "\n")
        guard let json = Self.extractFirstJSONObject(from: raw) else {
            Log.classifier.error("No JSON object found in response: \(raw.prefix(200), privacy: .public)")
            return .assumedNo
        }

        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Log.classifier.error("Failed to parse JSON: \(json.prefix(200), privacy: .public)")
            return .assumedNo
        }

        // Accept both snake_case (per prompt) and camelCase (some models).
        let isQuestion = (obj["is_question"] as? Bool)
            ?? (obj["isQuestion"] as? Bool)
            ?? (obj["question"] as? Bool)
            ?? false

        let confidence: Double
        if let d = obj["confidence"] as? Double {
            confidence = d
        } else if let i = obj["confidence"] as? Int {
            confidence = Double(i)
        } else if let s = obj["confidence"] as? String, let d = Double(s) {
            confidence = d
        } else {
            confidence = isQuestion ? 0.7 : 0.3  // default if missing
        }

        let rationale = (obj["rationale"] as? String) ?? (obj["reasoning"] as? String)

        return QuestionClassification(
            isQuestion: isQuestion,
            confidence: max(0.0, min(1.0, confidence)),
            rationale: rationale
        )
    }

    /// Extract the first `{...}` JSON object from a string. Handles
    /// markdown code fences and surrounding prose. Returns nil if no
    /// balanced braces are found.
    internal static func extractFirstJSONObject(from text: String) -> String? {
        // Strip markdown code fences if present.
        var cleaned = text
        if cleaned.contains("```") {
            // Remove all ``` lines and any language tag.
            let lines = cleaned.components(separatedBy: "\n")
            let stripped = lines.filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("```")
            }
            cleaned = stripped.joined(separator: "\n")
        }

        // Find the first balanced `{ ... }` span.
        guard let start = cleaned.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var idx = start
        while idx < cleaned.endIndex {
            let ch = cleaned[idx]
            if escape {
                escape = false
            } else if ch == "\\" {
                escape = true
            } else if ch == "\"" {
                inString.toggle()
            } else if !inString {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(cleaned[start...idx])
                    }
                }
            }
            idx = cleaned.index(after: idx)
        }
        return nil
    }
}
