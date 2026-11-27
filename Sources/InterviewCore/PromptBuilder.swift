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
            system: systemPrompt(screen: false),
            messages: [PromptMessage(role: .user, content: userMessage(question: question, history: history))]
        )
    }

    /// Prompt for "analyze my screen": the screenshot is attached, the recent conversation gives context
    /// (the interviewer may have described the task out loud).
    public func buildScreen(history: [Turn], imageJPEG: Data) -> AnswerPrompt {
        var lines = ["Here is a screenshot of my screen. Help me with what it shows."]
        let recent = history.suffix(max(0, maxHistoryTurns))
        if !recent.isEmpty {
            lines.append("")
            lines.append("Recent conversation:")
            for turn in recent {
                lines.append("\(turn.speaker == .interviewer ? "Interviewer" : "Candidate"): \(turn.text)")
            }
        }
        return AnswerPrompt(
            system: systemPrompt(screen: true),
            messages: [PromptMessage(role: .user, content: lines.joined(separator: "\n"))],
            imageJPEG: imageJPEG
        )
    }

    private func systemPrompt(screen: Bool) -> String {
        var parts: [String] = ["You are a real-time assistant helping a candidate during a job interview."]
        if screen {
            parts.append("""
            The candidate shared a screenshot of their screen. Work out what it shows.
            - If it shows a programming task (live coding, a code sandbox, a task statement), reply with one or two sentences on the approach, \
            then a complete, working solution in a single fenced code block with a language tag. Use the language and framework visible on screen or named in the context below. \
            Add the time and space complexity in one line when it matters.
            - If it shows an error or code that does not work, name the cause and give the corrected code in a fenced code block.
            - If it shows a question or a quiz, answer it briefly.
            Do not invent details you cannot see.
            """)
        } else {
            parts.append("Reply with a concise bullet outline (3-5 short bullets) the candidate can glance at and say in their own words. Be specific and honest; do not invent experience that is not in the candidate's background.")
        }
        if let language, !language.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(screen ? "Write explanations in \(language); code stays code." : "Always answer in \(language).")
        } else {
            parts.append(screen ? "Write explanations in the language of the conversation; code stays code." : "Answer in the same language as the interviewer's question.")
        }
        let task = roleContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty {
            parts.append("What the candidate wants help with:\n\(task)")
        }
        let cv = resume.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cv.isEmpty {
            parts.append("About the candidate and their experience:\n\(String(cv.prefix(maxResumeCharacters)))")
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
