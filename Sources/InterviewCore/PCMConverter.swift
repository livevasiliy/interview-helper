import AVFoundation
import Foundation

/// Converts any captured audio buffer to the pipeline format (ADR-001):
/// 16 kHz, mono, interleaved Int16. Stateful so resampling stays continuous
/// across chunks; if the input format changes mid-stream it rebuilds itself.
public final class PCMConverter: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    public static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: true
    )!

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    public init() {}

    public func convert(_ input: AVAudioPCMBuffer) -> PCMChunk? {
        lock.lock()
        defer { lock.unlock() }

        guard input.frameLength > 0 else { return nil }

        if converter == nil || inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: Self.outputFormat)
            inputFormat = input.format
        }
        guard let converter else { return nil }

        let ratio = Self.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return input
        }

        guard status != .error, error == nil, output.frameLength > 0,
              let channel = output.int16ChannelData
        else { return nil }

        return PCMChunk(data: Data(bytes: channel[0], count: Int(output.frameLength) * MemoryLayout<Int16>.size))
    }
}
