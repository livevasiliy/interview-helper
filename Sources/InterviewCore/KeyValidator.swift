import Foundation

/// The outcome of looking at an API key before it is saved.
public enum KeyCheck: Equatable, Sendable {
    /// The provider accepted the key.
    case valid
    /// The provider answered that the key is wrong. Do not save it.
    case rejected(String)
    /// Could not be verified (offline, provider down, rate limit). The key is plausible, so it is saved.
    case unverified(String)
}

/// Checks API keys in two steps: a local format check (pasted whitespace, quotes, a wrong key in the wrong
/// field), then one cheap authenticated request to the key's own provider. The key goes nowhere else.
public struct KeyValidator: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    // MARK: Local checks

    /// Cleans what people paste: surrounding whitespace and quotes, a `Bearer ` prefix, `KEY=` copied from an .env line.
    public static func normalize(_ raw: String) -> String {
        var key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let equals = key.firstIndex(of: "="), key[..<equals].allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber }), equals != key.startIndex {
            key = String(key[key.index(after: equals)...])
        }
        for prefix in ["Bearer ", "bearer ", "Token ", "token "] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
        }
        key = key.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`").union(.whitespacesAndNewlines))
        return key
    }

    public static let minimumLength = 8

    /// A problem that makes the key unusable as typed (nothing is sent anywhere).
    public static func formatProblem(_ key: String, for slot: SecretKey) -> String? {
        if key.isEmpty { return L10n.tr("Paste the key first.") }
        if key.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return L10n.tr("The key contains spaces or line breaks. Paste only the key itself.")
        }
        if key.unicodeScalars.contains(where: { !$0.isASCII }) {
            return L10n.tr("The key contains characters that are not allowed. Copy it again from the provider's page.")
        }
        if key.count < minimumLength { return L10n.tr("The key is too short.") }
        return nil
    }

    /// A hint that the key may belong to another service. Providers change formats, so this never blocks saving.
    public static func formatWarning(_ key: String, for slot: SecretKey) -> String? {
        let name: String
        let expected: String
        switch slot {
        case .geminiAPIKey: name = "Google Gemini"; expected = "AIza"
        case .groqAPIKey: name = "Groq"; expected = "gsk_"
        case .openRouterAPIKey: name = "OpenRouter"; expected = "sk-or-"
        case .anthropicAPIKey: name = "Anthropic"; expected = "sk-ant-"
        case .openAIAPIKey:
            guard key.hasPrefix("sk-ant-") || key.hasPrefix("sk-or-") || key.hasPrefix("gsk_") || key.hasPrefix("AIza") else { return nil }
            return L10n.tr("This looks like a key for another service, not OpenAI (they start with sk-).")
        case .deepgramAPIKey:
            guard key.hasPrefix("sk-") || key.hasPrefix("gsk_") || key.hasPrefix("AIza") else { return nil }
            return L10n.tr("This looks like a key for another service, not Deepgram.")
        }
        return key.hasPrefix(expected) ? nil : L10n.tr("This does not look like a %@ key (they usually start with %@).", name, expected)
    }

    // MARK: Provider check

    func request(for slot: SecretKey, key: String) -> URLRequest {
        let url: String
        var headers: [String: String] = [:]
        switch slot {
        case .geminiAPIKey:
            url = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"
            headers["x-goog-api-key"] = key
        case .groqAPIKey:
            url = "https://api.groq.com/openai/v1/models"
            headers["Authorization"] = "Bearer \(key)"
        case .openAIAPIKey:
            url = "https://api.openai.com/v1/models"
            headers["Authorization"] = "Bearer \(key)"
        case .openRouterAPIKey:
            url = "https://openrouter.ai/api/v1/auth/key"   // /models is public; this one needs a valid key
            headers["Authorization"] = "Bearer \(key)"
        case .anthropicAPIKey:
            url = "https://api.anthropic.com/v1/models?limit=1"
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2023-06-01"
        case .deepgramAPIKey:
            url = "https://api.deepgram.com/v1/projects"
            headers["Authorization"] = "Token \(key)"
        }
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 12
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    public func check(_ key: String, for slot: SecretKey) async -> KeyCheck {
        let providerName = Self.providerName(slot)
        do {
            let (_, response) = try await session.data(for: request(for: slot, key: key))
            guard let http = response as? HTTPURLResponse else {
                return .unverified(L10n.tr("Could not verify the key right now. It was saved; you will see an error when it is used if it is wrong."))
            }
            switch http.statusCode {
            case 200..<300:
                return .valid
            case 401, 403:
                return .rejected(L10n.tr("%@ did not accept this key. Check that you copied all of it.", providerName))
            case 400 where slot == .geminiAPIKey:
                return .rejected(L10n.tr("%@ did not accept this key. Check that you copied all of it.", providerName))
            default:
                return .unverified(L10n.tr("Could not verify the key right now (HTTP %ld). It was saved; you will see an error when it is used if it is wrong.", http.statusCode))
            }
        } catch {
            return .unverified(L10n.tr("Could not reach %@ to verify the key. It was saved; you will see an error when it is used if it is wrong.", providerName))
        }
    }

    public static func providerName(_ slot: SecretKey) -> String {
        switch slot {
        case .geminiAPIKey: return "Google Gemini"
        case .groqAPIKey: return "Groq"
        case .openRouterAPIKey: return "OpenRouter"
        case .openAIAPIKey: return "OpenAI"
        case .anthropicAPIKey: return "Anthropic"
        case .deepgramAPIKey: return "Deepgram"
        }
    }
}
