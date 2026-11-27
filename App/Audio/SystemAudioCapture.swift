import AVFoundation
import CoreMedia
import InterviewCore
import ScreenCaptureKit

enum AudioCaptureError: Error, LocalizedError {
    case permissionDenied
    case microphonePermissionDenied
    case noInputDevice
    case inputDeviceNotFound
    case noDisplay
    case alreadyRunning
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Screen Recording permission is not granted."
        case .microphonePermissionDenied: return "Microphone permission is not granted."
        case .noInputDevice: return "No microphone input device is available."
        case .inputDeviceNotFound: return "The microphone chosen in Settings is not connected. Pick another one or reconnect it."
        case .noDisplay: return "No display found to attach the audio capture to."
        case .alreadyRunning: return "System audio capture is already running."
        case .underlying(let error): return error.localizedDescription
        }
    }
}

/// Captures everything the Mac is playing (the interviewer's voice from Zoom/Meet/Teams)
/// via ScreenCaptureKit and delivers it as 16 kHz mono Int16 PCM (ADR-001).
/// Video is requested at the minimum size/rate and discarded; only audio is used.
final class SystemAudioCapture: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.interviewhelper.system-audio")
    private let converter = PCMConverter()
    private let lock = NSLock()
    private var stream: SCStream?
    private var continuation: AsyncStream<PCMChunk>.Continuation?

    /// Called if macOS stops the stream on its own (permission revoked, display change, ...).
    var onUnexpectedStop: (@Sendable (Error) -> Void)?

    func start() async throws -> AsyncStream<PCMChunk> {
        if isRunning() { throw AudioCaptureError.alreadyRunning }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }
        guard let display = content.displays.first else { throw AudioCaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true   // never transcribe our own sounds
        config.sampleRate = 48_000
        config.channelCount = 2
        // Video is mandatory for an SCStream; make it as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            // Registering a screen output (and ignoring frames) avoids log spam about dropped video.
            try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        } catch {
            throw AudioCaptureError.underlying(error)
        }

        let (audioStream, newContinuation) = AsyncStream.makeStream(of: PCMChunk.self, bufferingPolicy: .bufferingNewest(256))

        install(stream: newStream, continuation: newContinuation)

        do {
            try await newStream.startCapture()
        } catch {
            _ = takeState()
            newContinuation.finish()
            throw Self.map(error)
        }
        return audioStream
    }

    func stop() async {
        let (s, c) = takeState()
        try? await s?.stopCapture()
        c?.finish()
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let pcm = sampleBuffer.makePCMBuffer(),
              let chunk = converter.convert(pcm)
        else { return }

        currentContinuation()?.yield(chunk)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let (_, c) = takeState()
        c?.finish()
        onUnexpectedStop?(Self.map(error))
    }

    // MARK: State (synchronous helpers keep NSLock out of async functions)

    private func isRunning() -> Bool {
        lock.withLock { stream != nil }
    }

    private func install(stream: SCStream, continuation: AsyncStream<PCMChunk>.Continuation) {
        lock.withLock {
            self.stream = stream
            self.continuation = continuation
        }
    }

    private func currentContinuation() -> AsyncStream<PCMChunk>.Continuation? {
        lock.withLock { continuation }
    }

    private func takeState() -> (SCStream?, AsyncStream<PCMChunk>.Continuation?) {
        lock.withLock {
            let state = (stream, continuation)
            stream = nil
            continuation = nil
            return state
        }
    }

    private static func map(_ error: Error) -> AudioCaptureError {
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain, ns.code == SCStreamError.userDeclined.rawValue {
            return .permissionDenied
        }
        return .underlying(error)
    }
}

extension CMSampleBuffer {
    /// Copies the audio payload of a sample buffer into an `AVAudioPCMBuffer` (any layout ScreenCaptureKit uses).
    func makePCMBuffer() -> AVAudioPCMBuffer? {
        guard let description = formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return nil }

        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return nil }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
