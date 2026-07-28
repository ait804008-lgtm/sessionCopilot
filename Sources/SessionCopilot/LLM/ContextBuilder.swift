import Foundation

/// Builds context for LLM prompts from profile, JD, and transcript.
public struct ContextBuilder: Sendable {

    /// Build prompt context for a behavioral interview answer.
    public static func behavioral(
        profile: Profile,
        chatMessages: [ChatMessage],
        questionText: String,
        language: String = "en"
    ) -> String {
        let recentTranscript = chatMessages.suffix(10).map { msg in
            "\(msg.role == .user ? "You" : "Them"): \(msg.text)"
        }.joined(separator: "\n")

        return """
        ## Candidate Profile
        Resume: \(profile.resumeText)
        Skills: \(profile.resumeParsed["skills"]?.joined(separator: ", ") ?? "N/A")
        STAR Stories:
        \(profile.starStories.map { "- \($0.situation) → \($0.action) → \($0.result)" }.joined(separator: "\n"))

        ## Job Description
        \(profile.defaultJD ?? "N/A")

        ## Recent Conversation
        \(recentTranscript)

        ## Question
        \(questionText)

        ## Instructions
        Provide a structured answer outline using STAR format, grounded ONLY in the candidate's profile above.
        Also provide coaching tips (pacing, specificity, STAR completeness) as a separate section.
        **Respond in \(language).**
        Format your response as:

        ## Outline
        (STAR-format points)

        ## Coach Tips
        (actionable tips)

        ## Follow-ups
        (suggested follow-up questions the interviewer might ask)
        """
    }

    /// Build a dictionary of template variables for use with PromptLoader.
    /// Produces: resume, jd, transcript, stars, question, language
    public static func buildVariables(
        profile: Profile,
        chatMessages: [ChatMessage],
        questionText: String,
        language: String = "en"
    ) -> [String: String] {
        let recentTranscript = chatMessages.suffix(10).map { msg in
            "\(msg.role == .user ? "You" : "Them"): \(msg.text)"
        }.joined(separator: "\n")

        let starsText = profile.starStories.isEmpty
            ? "None provided"
            : profile.starStories.map { "- \($0.situation) → \($0.action) → \($0.result)" }.joined(separator: "\n")

        return [
            "resume": profile.resumeText,
            "jd": profile.defaultJD ?? "N/A",
            "transcript": recentTranscript,
            "stars": starsText,
            "question": questionText,
            "language": language
        ]
    }

    /// Build a dictionary of template variables for coding problems.
    /// Produces: problem, language
    public static func buildCodingVariables(
        problemText: String,
        language: String = "python"
    ) -> [String: String] {
        return [
            "problem": problemText,
            "language": language
        ]
    }

    /// Build a dictionary of template variables for system design problems.
    /// Produces: problem
    public static func buildSystemDesignVariables(
        problemText: String
    ) -> [String: String] {
        return ["problem": problemText]
    }

    /// Build prompt context for coding problems.
    public static func coding(
        problemText: String,
        language: String = "python"
    ) -> String {
        return """
        ## Problem
        \(problemText)

        ## Instructions
        Provide:
        ## Approach
        (step-by-step solution strategy)

        ## Complexity
        - Time: O(?)
        - Space: O(?)

        ## Edge Cases
        (list edge cases to consider)

        ## Code (\(language))
        ```\(language)
        (the solution)
        ```
        """
    }
}
