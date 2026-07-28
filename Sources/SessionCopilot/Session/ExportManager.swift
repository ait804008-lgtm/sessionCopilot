import Foundation

/// Scores a session's answers using an LLM.
public struct PostScorer {

    /// Score a completed session across competency dimensions.
    @MainActor
    public static func score(session: Session, using client: LlmClient) async throws -> [String: Int] {
        let prompt = buildScoringPrompt(session)
        let request = LlmRequest(
            model: "deepseek-chat",
            mode: .behavioral,
            prompt: prompt,
            maxTokens: 300
        )
        let response = try await client.complete(request)
        return parseScores(response)
    }

    private static func buildScoringPrompt(_ session: Session) -> String {
        let transcript = session.segments.map { "\($0.speaker == .mic ? "You" : "Them"): \($0.text)" }.joined(separator: "\n")

        return """
        Score the following interview answers on a scale of 1-5.

        ## Dimensions
        - Structure: Does the answer follow a clear structure (STAR)?
        - Specificity: Are there concrete examples and metrics?
        - Relevance: Does the answer directly address the question?
        - Delivery: Is the answer concise and clear?

        ## Transcript
        \(transcript)

        Return ONLY a JSON object: {"structure": N, "specificity": N, "relevance": N, "delivery": N}
        """
    }

    private static func parseScores(_ response: LlmResponse) -> [String: Int] {
        let content = response.sections.first?.content ?? ""
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return [:]
        }
        return json
    }
}

/// Manages session export to Markdown and JSON.
public struct ExportManager {

    /// Export a session to a user-chosen location.
    @MainActor
    public static func export(
        session: Session,
        store: SessionStore,
        format: ExportFormat,
        to directory: URL? = nil
    ) async throws -> URL {
        let exportedURL = try await store.exportSession(session.id, format: format)

        if let directory {
            let dest = directory.appendingPathComponent(exportedURL.lastPathComponent)
            try FileManager.default.copyItem(at: exportedURL, to: dest)
            return dest
        }

        return exportedURL
    }
}
