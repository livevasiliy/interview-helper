import Foundation

/// Tries several answer engines in turn so a busy or unavailable model doesn't leave the user
/// without an answer (free tiers return HTTP 503/429 during demand spikes).
///
/// Only failures that happen before the first token are retried: once text has reached the
/// screen, switching model would duplicate or contradict it, so that error is reported as is.
/// A rejected API key is never retried, since every model would reject it too.
public struct FallbackAnswerEngine: AnswerEngine {
    public let engines: [AnswerEngine]
    private let names: [String]
    private let delay: TimeInterval

    /// - Parameters:
    ///   - engines: primary first, then backups.
    ///   - retryPrimary: try the primary once more before moving on (spikes are usually brief).
    ///   - delay: pause between attempts, in seconds.
    public init(engines: [AnswerEngine], names: [String]? = nil, retryPrimary: Bool = true, delay: TimeInterval = 0.6) {
        let labels = names ?? engines.indices.map { "engine \($0 + 1)" }
        if retryPrimary, let first = engines.first, let firstName = labels.first {
            self.engines = [first] + engines
            self.names = [firstName] + labels
        } else {
            self.engines = engines
            self.names = labels
        }
        self.delay = delay
    }

    public func answer(for prompt: AnswerPrompt) -> AsyncThrowingStream<String, Error> {
        let engines = engines
        let names = names
        let delay = delay
        return AsyncThrowingStream { continuation in
            let task = Task {
                var failures: [(name: String, error: Error)] = []
                for (index, engine) in engines.enumerated() {
                    if index > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                    }
                    if Task.isCancelled { continuation.finish(); return }

                    var yielded = false
                    do {
                        for try await token in engine.answer(for: prompt) {
                            yielded = true
                            continuation.yield(token)
                        }
                        continuation.finish()
                        return
                    } catch {
                        if Task.isCancelled { continuation.finish(); return }
                        failures.append((names[index], error))
                        if yielded || !Self.worthTryingAnother(after: error) {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                }
                continuation.finish(throwing: Self.report(failures))
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One line per model (latest failure of each), so the user can see why none of them worked.
    static func report(_ failures: [(name: String, error: Error)]) -> ProviderError {
        guard !failures.isEmpty else { return .connectionFailed("No answer engine is available") }
        var order: [String] = []
        var latest: [String: Error] = [:]
        for failure in failures {
            if latest[failure.name] == nil { order.append(failure.name) }
            latest[failure.name] = failure.error
        }
        let lines = order.map { name -> String in
            let reason: String
            switch latest[name] {
            case let ProviderError.http(status, message)?:
                reason = "HTTP \(status): \(message.prefix(110))"
            case let error?:
                reason = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            case nil:
                reason = "unknown"
            }
            return "\(name) → \(reason)"
        }
        return .allModelsFailed(lines.joined(separator: "\n"))
    }

    /// Transient or model-specific failures are worth another attempt; a bad key or a bad request is not.
    static func worthTryingAnother(after error: Error) -> Bool {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .unauthorized: return false
            case .http(let status, _): return status == 404 || status == 408 || status == 429 || status >= 500
            case .api, .connectionFailed: return true
            case .allModelsFailed: return false
            }
        }
        return error is URLError
    }
}
