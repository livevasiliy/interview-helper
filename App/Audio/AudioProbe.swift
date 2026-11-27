import AppKit
import InterviewCore

/// Debug harness for the capture spikes (T7/T8): records from an `AudioSource` for a few
/// seconds, reports what arrived, and saves a WAV so you can hear exactly what the pipeline got.
@MainActor
final class AudioProbe {
    private var running = false

    func run(source: AudioSource, title: String, fileName: String, silenceHint: String, failureHint: String, seconds: Double = 5) async {
        guard !running else { return }
        running = true
        defer { running = false }

        var chunks = 0
        var pcm = Data()
        var peak: Float = 0
        var firstChunkLatency: Double?
        let started = Date()

        do {
            let stream = try await source.start()
            let stopper = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                await source.stop()
            }
            for await chunk in stream {
                if firstChunkLatency == nil { firstChunkLatency = Date().timeIntervalSince(started) }
                chunks += 1
                pcm.append(chunk.data)
                peak = max(peak, chunk.peakLevel)
            }
            stopper.cancel()
        } catch {
            await source.stop()
            show("\(title) failed", "\(error.localizedDescription)\n\n\(failureHint)")
            return
        }

        let frames = pcm.count / 2
        let audioSeconds = Double(frames) / 16_000
        var report = """
        Chunks: \(chunks)
        Audio received: \(String(format: "%.2f", audioSeconds)) s (expected ≈ \(Int(seconds)) s)
        Peak level: \(String(format: "%.3f", peak)) (0 = silence, 1 = full scale)
        First chunk after: \(firstChunkLatency.map { String(format: "%.2f s", $0) } ?? "never")
        """
        if chunks == 0 {
            report += "\n\nNo audio arrived. \(silenceHint)"
        } else if peak < 0.001 {
            report += "\n\nAudio arrived but it is silent. \(silenceHint)"
        }

        if !pcm.isEmpty {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            do {
                try WAV.data(pcm: pcm).write(to: url)
                report += "\n\nSaved: \(url.path)"
            } catch {
                report += "\n\nCould not save WAV: \(error.localizedDescription)"
            }
        }
        show(title, report)
    }

    private func show(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
