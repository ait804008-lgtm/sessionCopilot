import Foundation
import Testing
@testable import SessionCopilot

// MARK: - QuestionClassification Tests

@Suite("QuestionClassification") struct QuestionClassificationTests {

    @Test("assumedYes is a question with high confidence")
    func assumedYes() {
        let c = QuestionClassification.assumedYes
        #expect(c.isQuestion)
        #expect(c.confidence == 1.0)
        #expect(c.rationale != nil)
    }

    @Test("assumedNo is not a question with zero confidence")
    func assumedNo() {
        let c = QuestionClassification.assumedNo
        #expect(!c.isQuestion)
        #expect(c.confidence == 0.0)
        #expect(c.rationale != nil)
    }

    @Test("Equality holds for same fields")
    func equality() {
        let a = QuestionClassification(isQuestion: true, confidence: 0.9, rationale: "test")
        let b = QuestionClassification(isQuestion: true, confidence: 0.9, rationale: "test")
        #expect(a == b)
    }

    @Test("Inequality for different isQuestion")
    func inequalityBool() {
        let a = QuestionClassification(isQuestion: true, confidence: 0.9)
        let b = QuestionClassification(isQuestion: false, confidence: 0.9)
        #expect(a != b)
    }

    @Test("Inequality for different confidence")
    func inequalityConfidence() {
        let a = QuestionClassification(isQuestion: true, confidence: 0.9)
        let b = QuestionClassification(isQuestion: true, confidence: 0.5)
        #expect(a != b)
    }

    @Test("Inequality for different rationale")
    func inequalityRationale() {
        let a = QuestionClassification(isQuestion: true, confidence: 0.9, rationale: "a")
        let b = QuestionClassification(isQuestion: true, confidence: 0.9, rationale: "b")
        #expect(a != b)
    }

    @Test("Codable round-trip preserves fields")
    func codableRoundTrip() throws {
        let original = QuestionClassification(isQuestion: true, confidence: 0.87, rationale: "test rationale")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QuestionClassification.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable round-trip with nil rationale")
    func codableNilRationale() throws {
        let original = QuestionClassification(isQuestion: false, confidence: 0.3, rationale: nil)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QuestionClassification.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - LlmQuestionClassifier Parsing Tests

@Suite("LlmQuestionClassifier Parsing") struct ClassifierParsingTests {

    @Test("Parses clean JSON with snake_case keys")
    func parsesCleanSnakeCase() {
        let response = LlmResponse(
            sections: [
                .init(title: "", content: #"{"is_question": true, "confidence": 0.95, "rationale": "starts with 'tell me about'}"#)
            ],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(c.isQuestion)
        #expect(abs(c.confidence - 0.95) < 0.001)
        #expect(c.rationale == "starts with 'tell me about'")
    }

    @Test("Parses JSON wrapped in markdown code fence")
    func parsesMarkdownFence() {
        let response = LlmResponse(
            sections: [
                .init(title: "", content: """
                ```json
                {"is_question": false, "confidence": 0.8, "rationale": "acknowledgment"}
                ```
                """)
            ],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(!c.isQuestion)
        #expect(abs(c.confidence - 0.8) < 0.001)
        #expect(c.rationale == "acknowledgment")
    }

    @Test("Parses camelCase keys (some models)")
    func parsesCamelCase() {
        let response = LlmResponse(
            sections: [
                .init(title: "", content: #"{"isQuestion": true, "confidence": 0.7}"#)
            ],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(c.isQuestion)
        #expect(abs(c.confidence - 0.7) < 0.001)
    }

    @Test("Parses integer confidence as Double")
    func parsesIntegerConfidence() {
        let response = LlmResponse(
            sections: [
                .init(title: "", content: #"{"is_question": true, "confidence": 1}"#)
            ],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(c.isQuestion)
        #expect(c.confidence == 1.0)
    }

    @Test("Parses string confidence as Double")
    func parsesStringConfidence() {
        let response = LlmResponse(
            sections: [
                .init(title: "", content: #"{"is_question": true, "confidence": "0.88"}"#)
            ],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(c.isQuestion)
        #expect(abs(c.confidence - 0.88) < 0.001)
    }

    @Test("Returns assumedNo on missing JSON object")
    func missingJSONObject() {
        let response = LlmResponse(
            sections: [.init(title: "", content: "no json here")],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(c == .assumedNo)
    }

    @Test("Returns assumedNo on malformed JSON")
    func malformedJSON() {
        let response = LlmResponse(
            sections: [.init(title: "", content: #"{"is_question": true"#)],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(c == .assumedNo)
    }

    @Test("Defaults confidence when missing")
    func defaultsConfidence() {
        let response = LlmResponse(
            sections: [.init(title: "", content: #"{"is_question": true}"#)],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(c.isQuestion)
        // Default for isQuestion=true is 0.7
        #expect(abs(c.confidence - 0.7) < 0.001)
    }

    @Test("Clamps confidence to 0.0-1.0 range")
    func clampsConfidence() {
        let response = LlmResponse(
            sections: [.init(title: "", content: #"{"is_question": true, "confidence": 1.5}"#)],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(c.confidence == 1.0)
    }

    @Test("Parses JSON embedded in prose")
    func parsesJSONInProse() {
        let response = LlmResponse(
            sections: [.init(title: "", content: #"Here is the classification: {"is_question": true, "confidence": 0.92, "rationale": "yes"} as requested."#)],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(c.isQuestion)
        #expect(abs(c.confidence - 0.92) < 0.001)
    }

    @Test("Parses JSON with nested braces in rationale")
    func parsesNestedBraces() {
        let response = LlmResponse(
            sections: [.init(title: "", content: #"{"is_question": false, "confidence": 0.6, "rationale": "object {nested} not a question"}"#)],
            metadata: [:]
        )
        let c = LlmQuestionClassifier.parseClassification(from: response)
        #expect(!c.isQuestion)
        #expect(c.rationale == "object {nested} not a question")
    }
}

// MARK: - JSON Object Extraction Tests

@Suite("JSON Object Extraction") struct JSONObjectExtractionTests {

    @Test("Extracts simple object")
    func simpleObject() {
        let s = #"{"a": 1}"#
        let result = LlmQuestionClassifier.extractFirstJSONObject(from: s)
        #expect(result == #"{"a": 1}"#)
    }

    @Test("Extracts object from prose")
    func objectInProse() {
        let s = #"result: {"a": 1} done"#
        let result = LlmQuestionClassifier.extractFirstJSONObject(from: s)
        #expect(result == #"{"a": 1}"#)
    }

    @Test("Extracts nested object")
    func nestedObject() {
        let s = #"{"outer": {"inner": 1}}"#
        let result = LlmQuestionClassifier.extractFirstJSONObject(from: s)
        #expect(result == #"{"outer": {"inner": 1}}"#)
    }

    @Test("Returns nil when no braces")
    func noBraces() {
        let result = LlmQuestionClassifier.extractFirstJSONObject(from: "no json here")
        #expect(result == nil)
    }

    @Test("Returns nil when unbalanced")
    func unbalanced() {
        let result = LlmQuestionClassifier.extractFirstJSONObject(from: #"{"a": 1"#)
        #expect(result == nil)
    }

    @Test("Ignores braces inside strings")
    func bracesInStrings() {
        let s = #"{"text": "has } brace"}"#
        let result = LlmQuestionClassifier.extractFirstJSONObject(from: s)
        #expect(result == s)
    }

    @Test("Ignores escaped quotes in strings")
    func escapedQuotes() {
        let s = #"{"text": "has \\" quote"}"#
        let result = LlmQuestionClassifier.extractFirstJSONObject(from: s)
        #expect(result == s)
    }

    @Test("Strips markdown fences")
    func stripsMarkdownFence() {
        let s = """
        ```json
        {"a": 1}
        ```
        """
        let result = LlmQuestionClassifier.extractFirstJSONObject(from: s)
        #expect(result == #"{"a": 1}"#)
    }
}

// MARK: - ContextBuilder.classification Tests

@Suite("ContextBuilder.classification") struct ContextBuilderClassificationTests {

    @Test("classification produces non-empty prompt")
    func nonEmptyPrompt() {
        let prompt = ContextBuilder.classification(text: "Tell me about yourself")
        #expect(!prompt.isEmpty)
    }

    @Test("classification includes the text")
    func includesText() {
        let prompt = ContextBuilder.classification(text: "Why did you leave?")
        #expect(prompt.contains("Why did you leave?"))
    }

    @Test("classification includes transcript when provided")
    func includesTranscript() {
        let prompt = ContextBuilder.classification(
            text: "yes",
            transcript: "You: hi\nThem: hello"
        )
        #expect(prompt.contains("You: hi"))
        #expect(prompt.contains("Them: hello"))
    }

    @Test("classification shows N/A when transcript empty")
    func emptyTranscriptShowsNA() {
        let prompt = ContextBuilder.classification(text: "test", transcript: "")
        #expect(prompt.contains("N/A"))
    }

    @Test("classification includes JSON instruction")
    func includesJSONInstruction() {
        let prompt = ContextBuilder.classification(text: "test")
        #expect(prompt.contains("is_question"))
        #expect(prompt.contains("confidence"))
        #expect(prompt.contains("rationale"))
    }

    @Test("buildClassificationVariables returns text and transcript")
    func buildVariables() {
        let vars = ContextBuilder.buildClassificationVariables(
            text: "hello",
            transcript: "You: hi"
        )
        #expect(vars["text"] == "hello")
        #expect(vars["transcript"] == "You: hi")
    }

    @Test("buildClassificationVariables defaults empty transcript to N/A")
    func buildVariablesEmptyTranscript() {
        let vars = ContextBuilder.buildClassificationVariables(text: "hello", transcript: "")
        #expect(vars["transcript"] == "N/A")
    }
}

// MARK: - QuestionClassifier Protocol Mock

@MainActor
final class MockQuestionClassifier: QuestionClassifier {
    var result: QuestionClassification
    var lastText: String?
    var lastContext: [String: String]?
    var callCount = 0

    init(result: QuestionClassification) {
        self.result = result
    }

    func classify(_ text: String, context: [String: String]) async -> QuestionClassification {
        callCount += 1
        lastText = text
        lastContext = context
        return result
    }
}

@Suite("MockQuestionClassifier") struct MockQuestionClassifierTests {

    @Test("Mock returns configured result")
    func returnsResult() async {
        let mock = MockQuestionClassifier(result: .assumedYes)
        let result = await mock.classify("test", context: [:])
        #expect(result == .assumedYes)
    }

    @Test("Mock records call arguments")
    func recordsArgs() async {
        let mock = MockQuestionClassifier(result: .assumedYes)
        _ = await mock.classify("hello world", context: ["transcript": "You: hi"])
        #expect(mock.lastText == "hello world")
        #expect(mock.lastContext?["transcript"] == "You: hi")
        #expect(mock.callCount == 1)
    }

    @Test("Mock call count increments on each call")
    func incrementsCount() async {
        let mock = MockQuestionClassifier(result: .assumedYes)
        _ = await mock.classify("a", context: [:])
        _ = await mock.classify("b", context: [:])
        _ = await mock.classify("c", context: [:])
        #expect(mock.callCount == 3)
    }
}
