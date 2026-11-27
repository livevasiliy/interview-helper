import Foundation

public enum WebSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// Minimal WebSocket surface the transcriber needs; lets tests run without a network.
public protocol WebSocketConnection: AnyObject, Sendable {
    func send(_ data: Data) async throws
    func send(_ text: String) async throws
    /// Throws when the connection fails or closes.
    func receive() async throws -> WebSocketMessage
    func close()
    /// HTTP status of a failed handshake (e.g. 401), if known.
    var failureStatusCode: Int? { get }
}

public protocol WebSocketConnector: Sendable {
    func connect(_ request: URLRequest) async throws -> WebSocketConnection
}

public final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func send(_ data: Data) async throws { try await task.send(.data(data)) }
    public func send(_ text: String) async throws { try await task.send(.string(text)) }

    public func receive() async throws -> WebSocketMessage {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .data(data)
        @unknown default: return .data(Data())
        }
    }

    public func close() { task.cancel(with: .normalClosure, reason: nil) }

    public var failureStatusCode: Int? { (task.response as? HTTPURLResponse)?.statusCode }
}

/// Production connector. The handshake runs lazily: failures show up on the first `receive()`.
public struct URLSessionWebSocketConnector: WebSocketConnector, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(_ request: URLRequest) async throws -> WebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}
