import Foundation

/// Streams answers from any OpenAI-compatible `/chat/completions` endpoint:
/// Google Gemini, Groq, OpenRouter, a local Ollama, and others (ADR-002).
public struct OpenAICompatibleAnswerEngine: AnswerEngine, @unchecked Sendable {
    public let baseURL: URL
    public let apiKey: String
    public let model: String
    public let maxTokens: Int
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, model: String, maxTokens: Int = 700, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.session = session
    }

    func makeRequest(for prompt: AnswerPrompt) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "authorization")
        }

        var messages: [[String: String]] = [["role": "system", "content": prompt.system]]
        messages += prompt.messages.map { ["role": $0.role.rawValue, "content": $0.content] }
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "max_tokens": maxTokens,
            "messages": messages,
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
                        throw ProviderError.connectionFailed(L10n.tr("No HTTP response"))
                    }
                    guard http.statusCode == 200 else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= 8_192 { break }
                        }
                        throw ProviderError.fromHTTP(status: http.statusCode, body: body)
                    }

                    var parser = OpenAIStreamParser()
                    for try await line in bytes.lines {
                        if let text = try parser.feed(line: line) {
                            continuation.yield(text)
                        }
                        if parser.isDone { break }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cannotConnectToHost && baseURL.host == "localhost" {
                    continuation.finish(throwing: ProviderError.connectionFailed(
                        L10n.tr("Ollama is not running. Start the Ollama app, then try again.")
                    ))
                } catch {
                    if Task.isCancelled { continuation.finish() } else { continuation.finish(throwing: error) }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Parses OpenAI-style server-sent events one line at a time.
struct OpenAIStreamParser {
    private(set) var isDone = false

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        struct APIError: Decodable {
            let message: String?
            let type: String?
        }
        let choices: [Choice]?
        let error: APIError?
    }

    mutating func feed(line: String) throws -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            isDone = true
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(Chunk.self, from: data)
        else { return nil }

        if let error = chunk.error {
            throw ProviderError.api(error.message ?? error.type ?? "unknown error")
        }
        guard let content = chunk.choices?.first?.delta?.content, !content.isEmpty else { return nil }
        return content
    }
}
