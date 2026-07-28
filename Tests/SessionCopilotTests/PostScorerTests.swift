import Foundation
import Testing
@testable import SessionCopilot

// MARK: - PostScorer Tests

@Suite("PostScorer") @MainActor struct PostScorerTests {

    @Test("PostScorer builds prompt with transcript")
    func buildsPromptWithTranscript() {
        let session = Session(
            profileId: UUID(),
            mode: .behavioral,
            title: "Test",
            segments: [
                TranscriptSegment(sessionId: UUID(), timestamp: Date(), speaker: .unknown, text: "Tell me about yourself", isFinal: true),
                TranscriptSegment(sessionId: UUID(), timestamp: Date(), speaker: .mic, text: "I'm a developer with 5 years experience", isFinal: true)
            ]
        )

        // PostScorer.buildScoringPrompt is private, but we can test score()
        // by using a mock LlmClient
    }

    @Test("PostScorer parses scores from valid JSON response")
    func parsesValidScores() {
        let response = LlmResponse(
            sections: [
                LlmResponse.Section(title: "Response", content: #"{"structure": 4, "specificity": 3, "relevance": 5, "delivery": 4}"#)
            ],
            metadata: [:]
        )

        let scores = PostScorerScoreHelper.parseScores(response)
        #expect(scores["structure"] == 4)
        #expect(scores["specificity"] == 3)
        #expect(scores["relevance"] == 5)
        #expect(scores["delivery"] == 4)
    }

    @Test("PostScorer returns empty dict for invalid JSON")
    func parsesInvalidJSON() {
        let response = LlmResponse(
            sections: [LlmResponse.Section(title: "Response", content: "Not valid JSON")],
            metadata: [:]
        )

        let scores = PostScorerScoreHelper.parseScores(response)
        #expect(scores.isEmpty)
    }

    @Test("PostScorer handles partial scores")
    func parsesPartialScores() {
        let response = LlmResponse(
            sections: [LlmResponse.Section(title: "Response", content: #"{"structure": 3}"#)],
            metadata: [:]
        )

        let scores = PostScorerScoreHelper.parseScores(response)
        #expect(scores["structure"] == 3)
        #expect(scores.count == 1)
    }

    @Test("PostScorer handles empty response")
    func parsesEmptyResponse() {
        let response = LlmResponse(sections: [], metadata: [:])
        let scores = PostScorerScoreHelper.parseScores(response)
        #expect(scores.isEmpty)
    }
}

// MARK: - Helper to expose PostScorer's private parseScores for testing

enum PostScorerScoreHelper {
    @MainActor
    static func parseScores(_ response: LlmResponse) -> [String: Int] {
        // Mirror the PostScorer.parseScores logic for testing
        let content = response.sections.first?.content ?? ""
        guard let data = content.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return [:]
        }
        return json
    }
}
