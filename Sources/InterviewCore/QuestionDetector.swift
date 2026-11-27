import Foundation

/// Decides when the interviewer has finished asking a question.
///
/// Feed it transcript segments in order. A question is emitted when buffered
/// interviewer speech ends with "?" (immediately), or when it contains an
/// interrogative/imperative cue and `silenceThreshold` seconds have passed
/// without more interviewer speech. Pure value type: no timers, so it is
/// deterministic under test. The caller should also call `flush(now:)`
/// periodically (e.g. every 200 ms) to apply the silence rule.
public struct QuestionDetector: Sendable {
    public var silenceThreshold: TimeInterval

    private var buffer: [String] = []
    private var lastEnd: TimeInterval = 0

    public init(silenceThreshold: TimeInterval = 0.7) {
        self.silenceThreshold = silenceThreshold
    }

    /// Interviewer speech heard so far that has not been turned into a question yet.
    public var pendingText: String? {
        buffer.isEmpty ? nil : buffer.joined(separator: " ")
    }

    /// Hands back the pending speech whatever it contains and clears it (used by "answer now").
    public mutating func takePending() -> String? {
        let text = pendingText
        buffer.removeAll()
        return text
    }

    /// Ingest a segment; returns a question if one completed as a result.
    public mutating func ingest(_ segment: TranscriptSegment) -> DetectedQuestion? {
        // Only finals from the interviewer carry questions. Partials are ignored.
        guard segment.isFinal else { return nil }

        if segment.speaker == .me {
            // The candidate is answering; whatever was buffered is stale.
            buffer.removeAll()
            return nil
        }

        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // A long gap before this segment closes out the previous utterance first.
        var emitted: DetectedQuestion?
        if !buffer.isEmpty, segment.start - lastEnd >= silenceThreshold {
            emitted = evaluateAndClear(requireCue: true)
        }

        buffer.append(text)
        lastEnd = segment.end

        if text.hasSuffix("?") || text.hasSuffix("？") {
            let question = evaluateAndClear(requireCue: false)
            return emitted ?? question
        }
        return emitted
    }

    /// Apply the silence rule at wall-clock `now` (session seconds).
    public mutating func flush(now: TimeInterval) -> DetectedQuestion? {
        guard !buffer.isEmpty, now - lastEnd >= silenceThreshold else { return nil }
        return evaluateAndClear(requireCue: true)
    }

    private mutating func evaluateAndClear(requireCue: Bool) -> DetectedQuestion? {
        let text = buffer.joined(separator: " ")
        buffer.removeAll()
        guard !requireCue || Self.containsCue(text) else { return nil }
        return DetectedQuestion(text: text)
    }

    // MARK: - Cue matching

    private static let cues: [String] = [
        // English
        "tell me", "describe", "walk me through", "explain", "what", "how", "why",
        "when", "where", "which", "who", "can you", "could you", "would you",
        "do you", "did you", "have you", "are you", "is there", "give me an example",
        // Russian
        "расскажите", "расскажи", "опишите", "объясните", "объясни", "почему",
        "как", "что", "какой", "какая", "какие", "зачем", "когда", "где",
        "приведите пример", "можете", "можешь", "есть ли",
    ]

    /// True if any sentence starts with a cue word/phrase (on a word boundary).
    static func containsCue(_ text: String) -> Bool {
        let sentences = text
            .lowercased()
            .components(separatedBy: CharacterSet(charactersIn: ".!?;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for sentence in sentences {
            for cue in cues where sentence.hasPrefix(cue) {
                let rest = sentence.dropFirst(cue.count)
                if rest.isEmpty { return true }
                if let next = rest.first, !next.isLetter && !next.isNumber { return true }
            }
        }
        return false
    }
}
