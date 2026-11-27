import Foundation

public enum Speaker: String, Sendable, Equatable {
    case interviewer
    case me
}

/// A chunk of 16 kHz mono Int16 PCM audio (see ADR-001).
public struct PCMChunk: Sendable, Equatable {
    public let data: Data
    public let sampleRate: Int

    public init(data: Data, sampleRate: Int = 16_000) {
        self.data = data
        self.sampleRate = sampleRate
    }
}

public struct TranscriptSegment: Sendable, Equatable {
    public let speaker: Speaker
    public let text: String
    public let isFinal: Bool
    /// Seconds since session start.
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speaker: Speaker, text: String, isFinal: Bool, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.text = text
        self.isFinal = isFinal
        self.start = start
        self.end = end
    }
}

/// One finished utterance in the conversation history.
public struct Turn: Sendable, Equatable {
    public let speaker: Speaker
    public let text: String

    public init(speaker: Speaker, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

public struct DetectedQuestion: Sendable, Equatable {
    public let text: String
    public init(text: String) { self.text = text }
}

public extension PCMChunk {
    /// Number of Int16 mono frames.
    var frameCount: Int { data.count / MemoryLayout<Int16>.size }

    var duration: TimeInterval { Double(frameCount) / Double(sampleRate) }

    /// Peak amplitude, 0...1. Handy for level meters and "is there any sound" checks.
    var peakLevel: Float {
        var peak: Int32 = 0
        data.withUnsafeBytes { raw in
            for sample in raw.bindMemory(to: Int16.self) {
                peak = max(peak, abs(Int32(sample)))
            }
        }
        return Float(peak) / Float(Int16.max)
    }
}
