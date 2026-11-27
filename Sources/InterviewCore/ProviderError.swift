import Foundation

/// Errors shared by the cloud providers (STT and LLM).
public enum ProviderError: Error, Equatable, LocalizedError {
    /// The API key was rejected (HTTP 401/403).
    case unauthorized
    case http(status: Int, message: String)
    /// The provider reported an error inside an otherwise successful stream.
    case api(String)
    case connectionFailed(String)
    /// Every model that was tried failed; the text lists why, model by model.
    case allModelsFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized: return L10n.tr("The API key was rejected. Check it in Settings.")
        case .http(let status, let message): return L10n.tr("Request failed (HTTP %ld): %@", status, message)
        case .api(let message): return L10n.tr("Provider error: %@", message)
        case .connectionFailed(let message): return L10n.tr("Connection failed: %@", message)
        case .allModelsFailed(let details): return L10n.tr("No model could answer. %@", details)
        }
    }
}

extension ProviderError {
    /// Maps a non-200 HTTP response to a readable error. Handles `{"error":{"message":...}}`
    /// (and the array form Google uses), falling back to the start of the body.
    static func fromHTTP(status: Int, body: Data) -> ProviderError {
        if status == 401 || status == 403 { return .unauthorized }

        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        let decoder = JSONDecoder()
        let message = (try? decoder.decode(Envelope.self, from: body))?.error?.message
            ?? (try? decoder.decode([Envelope].self, from: body))?.first?.error?.message
            ?? String(decoding: body.prefix(300), as: UTF8.self)
        return .http(status: status, message: message)
    }
}
