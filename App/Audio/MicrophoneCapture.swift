import AVFoundation
import AudioToolbox
import CoreAudio
import InterviewCore

/// Captures the user's microphone via AVAudioEngine and delivers 16 kHz mono Int16 PCM (ADR-001).
/// Survives input-device changes (e.g. plugging in headphones mid-call) by rebuilding the tap.
final class MicrophoneCapture: AudioSource, @unchecked Sendable {
    private let converter = PCMConverter()
    private let deviceUID: String
    private let lock = NSLock()
    private let restartQueue = DispatchQueue(label: "dev.interviewhelper.mic-restart")
    private var engine: AVAudioEngine?
    private var continuation: AsyncStream<PCMChunk>.Continuation?
    private var configObserver: NSObjectProtocol?

    /// - Parameter deviceUID: CoreAudio UID of the microphone to use; empty means the system default input.
    init(deviceUID: String = "") {
        self.deviceUID = deviceUID
    }

    /// Called if capture cannot continue (e.g. the input device disappeared and no other is available).
    var onUnexpectedStop: (@Sendable (Error) -> Void)?

    func start() async throws -> AsyncStream<PCMChunk> {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.microphonePermissionDenied
        }
        if isRunning() { throw AudioCaptureError.alreadyRunning }

        let newEngine = AVAudioEngine()
        let (audioStream, newContinuation) = AsyncStream.makeStream(of: PCMChunk.self, bufferingPolicy: .bufferingNewest(256))
        install(engine: newEngine, continuation: newContinuation)

        do {
            try startEngine(newEngine)
        } catch {
            teardown()
            throw error
        }

        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: nil
        ) { [weak self] _ in
            self?.restartQueue.async { self?.handleConfigurationChange() }
        }
        setObserver(observer)
        return audioStream
    }

    func stop() async {
        teardown()
    }

    // MARK: Engine

    /// Installs the tap for the engine's *current* input format and starts it.
    private func startEngine(_ engine: AVAudioEngine) throws {
        let input = engine.inputNode
        try selectDevice(on: input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw AudioCaptureError.noInputDevice }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let chunk = self.converter.convert(buffer) else { return }
            self.currentContinuation()?.yield(chunk)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.underlying(error)
        }
    }

    /// Points the engine's input at the chosen device. Must happen before reading the input format.
    private func selectDevice(on input: AVAudioInputNode) throws {
        guard !deviceUID.isEmpty else { return }
        guard var deviceID = AudioInputDevices.deviceID(forUID: deviceUID) else {
            throw AudioCaptureError.inputDeviceNotFound
        }
        guard let audioUnit = input.audioUnit else { throw AudioCaptureError.noInputDevice }
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioCaptureError.underlying(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
    }

    private func handleConfigurationChange() {
        guard let engine = currentEngine() else { return }   // already stopped
        engine.stop()
        do {
            try startEngine(engine)
        } catch {
            teardown()
            onUnexpectedStop?(error)
        }
    }

    // MARK: State (synchronous helpers keep NSLock out of async functions)

    private func isRunning() -> Bool { lock.withLock { engine != nil } }
    private func currentEngine() -> AVAudioEngine? { lock.withLock { engine } }
    private func currentContinuation() -> AsyncStream<PCMChunk>.Continuation? { lock.withLock { continuation } }

    private func install(engine: AVAudioEngine, continuation: AsyncStream<PCMChunk>.Continuation) {
        lock.withLock {
            self.engine = engine
            self.continuation = continuation
        }
    }

    private func setObserver(_ observer: NSObjectProtocol) {
        lock.withLock { configObserver = observer }
    }

    private func teardown() {
        let (engine, continuation, observer) = lock.withLock { () -> (AVAudioEngine?, AsyncStream<PCMChunk>.Continuation?, NSObjectProtocol?) in
            let state = (self.engine, self.continuation, self.configObserver)
            self.engine = nil
            self.continuation = nil
            self.configObserver = nil
            return state
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        continuation?.finish()
    }
}
