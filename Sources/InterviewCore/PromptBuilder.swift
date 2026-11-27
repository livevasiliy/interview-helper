import Foundation

/// Builds the LLM prompt from the user's context and recent conversation.
public struct PromptBuilder: Sendable {
    public var resume: String
    public var roleContext: String
    /// e.g. "English", "Russian"; `nil` means answer in the language of the question.
    public var language: String?
    public var maxHistoryTurns: Int
    public var maxResumeCharacters: Int

    public init(
        resume: String = "",
        roleContext: String = "",
        language: String? = nil,
        maxHistoryTurns: Int = 6,
        maxResumeCharacters: Int = 6_000
    ) {
        self.resume = resume
        self.roleContext = roleContext
        self.language = language
        self.maxHistoryTurns = maxHistoryTurns
        self.maxResumeCharacters = maxResumeCharacters
    }

    public func build(question: String, history: [Turn]) -> AnswerPrompt {
        AnswerPrompt(
            system: systemPrompt(),
            messages: [PromptMessage(role: .user, content: userMessage(question: question, history: history))]
        )
    }

    private func systemPrompt() -> String {
        var parts: [String] = [
            "You are a real-time assistant helping a candidate during a job interview.",
            "Reply with a concise bullet outline (3-5 short bullets) the candidate can glance at and say in their own words. Be specific and honest; do not invent experience that is not in the candidate's background.",
        ]
        if let language, !language.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("Always answer in \(language).")
        } else {
            parts.append("Answer in the same language as the interviewer's question.")
        }
        let role = roleContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty {
            parts.append("Role / company context:\n\(role)")
        }
        let cv = resume.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cv.isEmpty {
            parts.append("Candidate background (resume):\n\(String(cv.prefix(maxResumeCharacters)))")
        }
        return parts.joined(separator: "\n\n")
    }

    private func userMessage(question: String, history: [Turn]) -> String {
        let recent = history.suffix(max(0, maxHistoryTurns))
        var lines: [String] = []
        if !recent.isEmpty {
            lines.append("Recent conversation:")
            for turn in recent {
                let who = turn.speaker == .interviewer ? "Interviewer" : "Candidate"
                lines.append("\(who): \(turn.text)")
            }
            lines.append("")
        }
        lines.append("Current question from the interviewer:")
        lines.append(question)
        return lines.joined(separator: "\n")
    }
}
