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

    /// Build a dictionary of template variables for question classification.
    /// Produces: text, transcript
    ///
    /// Used by `LlmQuestionClassifier` to populate the
    /// `prompts/classification/question.md` template.
    public static func buildClassificationVariables(
        text: String,
        transcript: String = ""
    ) -> [String: String] {
        return [
            "text": text,
            "transcript": transcript.isEmpty ? "N/A" : transcript
        ]
    }

    /// Build prompt context for question classification.
    /// Inline fallback when the `classification/question.md` template
    /// is unavailable. Returns JSON the classifier parses.
    public static func classification(
        text: String,
        transcript: String = ""
    ) -> String {
        let transcriptSection = transcript.isEmpty
            ? "N/A"
            : transcript
        return """
        You are a classification engine. Determine whether the candidate text below is a question directed at the candidate by an interviewer.

        ## Recent Transcript
        \(transcriptSection)

        ## Candidate Text
        \(text)

        ## Classification Criteria
        - "is_question": true if the text asks the candidate to respond (e.g. "tell me about", "how would you", "what's the difference", "walk me through").
        - "is_question": false if the text is the candidate's own thinking-out-loud, an acknowledgment ("yeah", "ok", "makes sense"), or a statement.
        - Use the recent transcript to disambiguate: short acknowledgments after a question are NOT questions.

        Respond with ONLY a JSON object on a single line, no markdown fences:
        {"is_question": true|false, "confidence": 0.0-1.0, "rationale": "short explanation"}
        """
    }
}
