import Foundation

/// Streams answers from the Anthropic Messages API (ADR-002).
public struct AnthropicAnswerEngine: AnswerEngine, @unchecked Sendable {
    public static let apiVersion = "2023-06-01"

    public let apiKey: String
    public let model: String
    public let maxTokens: Int
    public let baseURL: URL
    private let session: URLSession

    public init(
        apiKey: String,
        model: String = AppSettings.defaultModel,
        maxTokens: Int = 700,
        baseURL: URL = URL(string: "https://api.anthropic.com")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.baseURL = baseURL
        self.session = session
    }

    func makeRequest(for prompt: AnswerPrompt) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "system": prompt.system,
            "messages": prompt.messages.map { ["role": $0.role.rawValue, "content": $0.content] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public func answer(for prompt: AnswerPrompt) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(for: prompt)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw ProviderError.connectionFailed("No HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 8_192 { break }
                        }
                        throw Self.error(status: http.statusCode, body: body)
                    }

                    var parser = AnthropicStreamParser()
                    for try await line in bytes.lines {
                        if let text = try parser.feed(line: line) {
                            continuation.yield(text)
                        }
                        if parser.isDone { break }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func error(status: Int, body: Data) -> ProviderError {
        ProviderError.fromHTTP(status: status, body: body)
    }
}

/// Parses Anthropic's server-sent events one line at a time. Only `data:` lines matter;
/// each carries a complete JSON object, so `event:` lines and blanks are ignored.
struct AnthropicStreamParser {
    private(set) var isDone = false

    private struct Event: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
        }
        struct APIError: Decodable {
            let type: String?
            let message: String?
        }
        let type: String?
        let delta: Delta?
        let error: APIError?
    }

    /// Returns a text delta if the line carries one.
    mutating func feed(line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            isDone = true
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data)
        else { return nil }

        switch event.type {
        case "content_block_delta":
            guard event.delta?.type == "text_delta", let text = event.delta?.text, !text.isEmpty else { return nil }
            return text
        case "message_stop":
            isDone = true
            return nil
        case "error":
            let kind = event.error?.type ?? "error"
            throw ProviderError.api("\(kind): \(event.error?.message ?? "unknown")")
        default:
            return nil   // message_start, ping, content_block_start/stop, message_delta
        }
    }
}
