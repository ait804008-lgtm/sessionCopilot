import Foundation
import Testing
@testable import SessionCopilot

// MARK: - PromptLoader + ContextBuilder Template Integration Tests

@Suite("Prompt Template Integration") struct PromptTemplateTests {

    @Test("answer_outline template contains expected variables")
    func templateHasVariables() throws {
        let loader = PromptLoader()
        let template = try loader.load("behavioral/answer_outline")
        #expect(template.contains("{{resume}}"), "Template should have {{resume}} variable")
        #expect(template.contains("{{jd}}"), "Template should have {{jd}} variable")
        #expect(template.contains("{{transcript}}"), "Template should have {{transcript}} variable")
        #expect(template.contains("{{stars}}"), "Template should have {{stars}} variable")
        #expect(template.contains("{{question}}"), "Template should have {{question}} variable")
    }

    @Test("rendered answer_outline contains profile data and no unreplaced variables")
    func renderedTemplateContainsProfile() throws {
        let loader = PromptLoader()
        let rendered = try loader.loadAndRender("behavioral/answer_outline", variables: [
            "resume": "5 years Swift, iOS at Apple",
            "jd": "Senior iOS Engineer",
            "transcript": "Tell me about a challenge",
            "stars": "Legacy migration → OAuth2 → 80% latency reduction",
            "question": "What's your biggest challenge?"
        ])
        #expect(rendered.contains("5 years Swift"))
        #expect(rendered.contains("Senior iOS Engineer"))
        #expect(rendered.contains("Tell me about a challenge"))
        #expect(rendered.contains("OAuth2"))
        #expect(rendered.contains("What's your biggest challenge?"))
        // No unreplaced variables should remain
        #expect(!rendered.contains("{{resume}}"))
        #expect(!rendered.contains("{{jd}}"))
        #expect(!rendered.contains("{{transcript}}"))
        #expect(!rendered.contains("{{stars}}"))
        #expect(!rendered.contains("{{question}}"))
    }
}

// MARK: - ContextBuilder.buildVariables Tests

@Suite("ContextBuilder.buildVariables") struct ContextBuilderVariablesTests {

    @Test("buildVariables produces all required keys")
    func producesAllKeys() {
        let profile = Profile(name: "Test", resumeText: "Resume", defaultJD: "JD")
        let msgs: [ChatMessage] = []
        let vars = ContextBuilder.buildVariables(
            profile: profile,
            chatMessages: msgs,
            questionText: "Question?"
        )
        #expect(vars["resume"] != nil)
        #expect(vars["jd"] != nil)
        #expect(vars["transcript"] != nil)
        #expect(vars["stars"] != nil)
        #expect(vars["question"] != nil)
    }

    @Test("buildVariables includes resume text")
    func includesResume() {
        let profile = Profile(name: "Test", resumeText: "5 years Swift experience")
        let vars = ContextBuilder.buildVariables(
            profile: profile,
            chatMessages: [],
            questionText: "Question?"
        )
        #expect(vars["resume"] == "5 years Swift experience")
    }

    @Test("buildVariables includes JD when present")
    func includesJD() {
        let profile = Profile(name: "Test", resumeText: "Resume", defaultJD: "Senior iOS Engineer")
        let vars = ContextBuilder.buildVariables(
            profile: profile,
            chatMessages: [],
            questionText: "Question?"
        )
        #expect(vars["jd"] == "Senior iOS Engineer")
    }

    @Test("buildVariables uses N/A when JD is nil")
    func jdNilIsNA() {
        let profile = Profile(name: "Test", resumeText: "Resume")
        let vars = ContextBuilder.buildVariables(
            profile: profile,
            chatMessages: [],
            questionText: "Question?"
        )
        #expect(vars["jd"] == "N/A")
    }

    @Test("buildVariables includes STAR stories")
    func includesStars() {
        let profile = Profile(
            name: "Test",
            resumeText: "Resume",
            starStories: [
                StarStory(situation: "Legacy auth slow", task: "Migrate", action: "PKCE flow", result: "80% faster")
            ]
        )
        let vars = ContextBuilder.buildVariables(
            profile: profile,
            chatMessages: [],
            questionText: "Question?"
        )
        #expect(vars["stars"]?.contains("Legacy auth slow") == true)
        #expect(vars["stars"]?.contains("PKCE flow") == true)
    }

    @Test("buildVariables uses placeholder when no STAR stories")
    func noStarsPlaceholder() {
        let profile = Profile(name: "Test", resumeText: "Resume")
        let vars = ContextBuilder.buildVariables(
            profile: profile,
            chatMessages: [],
            questionText: "Question?"
        )
        #expect(vars["stars"] == "None provided")
    }

    @Test("buildVariables includes recent transcript")
    func includesTranscript() {
        let msgs = [
            ChatMessage(role: .user, text: "I led the migration"),
            ChatMessage(role: .user, text: "Tell me about a challenge")
        ]
        let vars = ContextBuilder.buildVariables(
            profile: Profile(name: "Test", resumeText: "Resume"),
            chatMessages: msgs,
            questionText: "Question?"
        )
        #expect(vars["transcript"]?.contains("I led the migration") == true)
        #expect(vars["transcript"]?.contains("Tell me about a challenge") == true)
    }

    @Test("buildVariables includes question")
    func includesQuestion() {
        let vars = ContextBuilder.buildVariables(
            profile: Profile(name: "Test", resumeText: "Resume"),
            chatMessages: [],
            questionText: "What's your biggest challenge?"
        )
        #expect(vars["question"] == "What's your biggest challenge?")
    }

    @Test("buildVariables + PromptLoader produces grounded prompt")
    func buildAndRenderTemplate() throws {
        let profile = Profile(
            name: "Test",
            resumeText: "5 years Swift, iOS at Apple",
            defaultJD: "Senior iOS Engineer",
            starStories: [
                StarStory(situation: "Legacy auth", task: "Migrate", action: "PKCE", result: "80% faster")
            ]
        )
        let msgs = [
            ChatMessage(role: .user, text: "Tell me about yourself")
        ]

        let vars = ContextBuilder.buildVariables(
            profile: profile,
            chatMessages: msgs,
            questionText: "What's your biggest challenge?"
        )

        let loader = PromptLoader()
        let rendered = try loader.loadAndRender("behavioral/answer_outline", variables: vars)

        #expect(rendered.contains("5 years Swift"))
        #expect(rendered.contains("Senior iOS Engineer"))
        #expect(rendered.contains("Legacy auth"))
        #expect(rendered.contains("Tell me about yourself"))
        #expect(rendered.contains("What's your biggest challenge?"))
        #expect(!rendered.contains("{{"))
    }
}
