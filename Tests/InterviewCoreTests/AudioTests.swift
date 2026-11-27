import AVFoundation
import XCTest
@testable import InterviewCore

final class PCMConverterTests: XCTestCase {
    /// Sine wave buffer in an arbitrary format (float32, non-interleaved).
    private func sine(sampleRate: Double, channels: AVAudioChannelCount, frames: Int,
                      amplitude: Float = 0.5, frequency: Double = 440, phaseOffset: Int = 0) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(channels) {
            let p = buffer.floatChannelData![ch]
            for i in 0..<frames {
                p[i] = amplitude * Float(sin(2 * .pi * frequency * Double(i + phaseOffset) / sampleRate))
            }
        }
        return buffer
    }

    func testStereo48kBecomesMono16k() throws {
        // ScreenCaptureKit delivers roughly 10-20 ms buffers; 1024 frames ≈ 21 ms.
        let chunk = try XCTUnwrap(PCMConverter().convert(sine(sampleRate: 48_000, channels: 2, frames: 1_024)))
        XCTAssertEqual(chunk.sampleRate, 16_000)
        XCTAssertEqual(Double(chunk.frameCount), 1_024.0 / 3, accuracy: 20)
        XCTAssertEqual(chunk.data.count, chunk.frameCount * 2)
        XCTAssertEqual(chunk.peakLevel, 0.5, accuracy: 0.1, "amplitude must survive downmix + resample")
    }

    func testSilenceHasZeroPeak() throws {
        let chunk = try XCTUnwrap(PCMConverter().convert(sine(sampleRate: 44_100, channels: 1, frames: 4_410, amplitude: 0)))
        XCTAssertEqual(chunk.peakLevel, 0, accuracy: 0.001)
    }

    func testAlready16kMonoPassesThrough() throws {
        let chunk = try XCTUnwrap(PCMConverter().convert(sine(sampleRate: 16_000, channels: 1, frames: 1_600)))
        XCTAssertEqual(chunk.frameCount, 1_600, accuracy: 20)
    }

    func testStreamingKeepsTotalLengthAcrossChunks() {
        let converter = PCMConverter()
        var total = 0
        for i in 0..<60 {
            if let chunk = converter.convert(sine(sampleRate: 48_000, channels: 2, frames: 1_024, phaseOffset: i * 1_024)) {
                total += chunk.frameCount
            }
        }
        // 61 440 input frames → 20 480 output. The resampler holds back a constant
        // handful of frames (latency), it must not drop audio cumulatively.
        XCTAssertEqual(Double(total), 20_480, accuracy: 20)
    }

    func testInputFormatChangeMidStream() throws {
        let converter = PCMConverter()
        XCTAssertNotNil(converter.convert(sine(sampleRate: 48_000, channels: 2, frames: 1_024)))
        let second = try XCTUnwrap(converter.convert(sine(sampleRate: 44_100, channels: 1, frames: 1_024)))
        XCTAssertEqual(Double(second.frameCount), 1_024 * 16_000.0 / 44_100, accuracy: 20)
    }

    func testEmptyBufferReturnsNil() {
        XCTAssertNil(PCMConverter().convert(sine(sampleRate: 48_000, channels: 2, frames: 0)))
    }
}

final class PCMChunkAndWAVTests: XCTestCase {
    private func int16Data(_ samples: [Int16]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    func testDurationAndPeak() {
        let chunk = PCMChunk(data: int16Data([0, 1000, -16384, 200]))
        XCTAssertEqual(chunk.frameCount, 4)
        XCTAssertEqual(chunk.duration, 4.0 / 16_000, accuracy: 1e-9)
        XCTAssertEqual(chunk.peakLevel, 0.5, accuracy: 0.001)
    }

    func testPeakOfMinInt16DoesNotOverflow() {
        XCTAssertEqual(PCMChunk(data: int16Data([Int16.min])).peakLevel, 1.0, accuracy: 0.01)
    }

    func testWAVHeader() {
        let pcm = int16Data([1, 2, 3, 4])
        let wav = WAV.data(pcm: pcm)
        XCTAssertEqual(wav.count, 44 + pcm.count)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: wav[36..<40], as: UTF8.self), "data")
        func u32(_ at: Int) -> UInt32 { wav[at..<at + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        XCTAssertEqual(u32(4), UInt32(36 + pcm.count))
        XCTAssertEqual(u32(24), 16_000)           // sample rate
        XCTAssertEqual(u32(28), 32_000)           // byte rate
        XCTAssertEqual(u32(40), UInt32(pcm.count))
    }

    func testFakeAudioSource() async throws {
        let c = PCMChunk(data: int16Data([1, 2]))
        var got = 0
        for await _ in try await FakeAudioSource(chunks: [c, c, c]).start() { got += 1 }
        XCTAssertEqual(got, 3)
    }
}
