import Foundation
import Testing
@testable import SessionCopilot

@Suite("PromptLoader") struct PromptLoaderTests {

    @Test("renders template variables")
    func render() {
        let loader = PromptLoader()
        let result = loader.render("Hello {{name}}!", variables: ["name": "World"])
        #expect(result == "Hello World!")
    }

    @Test("renders multiple variables")
    func renderMultiple() {
        let loader = PromptLoader()
        let result = loader.render("{{greeting}} {{name}}", variables: ["greeting": "Hi", "name": "There"])
        #expect(result == "Hi There")
    }

    @Test("leaves unknown variables unchanged")
    func unknownVariables() {
        let loader = PromptLoader()
        let result = loader.render("Hello {{missing}}", variables: [:])
        #expect(result == "Hello {{missing}}")
    }
}

@Suite("ContextBuilder") struct ContextBuilderTests {

    @Test("behavioral context includes profile and transcript")
    func behavioralContext() {
        let profile = Profile(name: "Test", resumeText: "5 years Swift", defaultJD: "iOS Developer")
        let segments = [
            TranscriptSegment(sessionId: UUID(), timestamp: Date(), speaker: .mic, text: "I led the migration", isFinal: true),
            TranscriptSegment(sessionId: UUID(), timestamp: Date(), speaker: .unknown, text: "Tell me about a challenge", isFinal: true)
        ]

        let context = ContextBuilder.behavioral(
            profile: profile,
            chatMessages: segments.map { ChatMessage(role: .user, text: $0.text) },
            questionText: "What's your biggest challenge?"
        )

        #expect(context.contains("5 years Swift"))
        #expect(context.contains("iOS Developer"))
        #expect(context.contains("I led the migration"))
        #expect(context.contains("biggest challenge"))
        #expect(context.contains("## Outline"))
        #expect(context.contains("## Coach Tips"))
    }

    @Test("coding context includes language and sections")
    func codingContext() {
        let context = ContextBuilder.coding(problemText: "Reverse a linked list", language: "go")
        #expect(context.contains("Reverse a linked list"))
        #expect(context.contains("## Approach"))
        #expect(context.contains("## Complexity"))
        #expect(context.contains("## Code (go)"))
    }
}

@Suite("LlmClientImpl") @MainActor struct LlmClientImplTests {

    @Test("conforms to LlmClient protocol")
    func conforms() {
        let client = LlmClientImpl()
        #expect(client is LlmClient)
    }
}
