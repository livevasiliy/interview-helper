import Foundation

/// A dotted version such as "0.3.0" or "v1.2" (a leading "v" is ignored). Compared numerically,
/// so 0.10.0 is newer than 0.9.0.
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        // Drop a pre-release or build suffix ("1.0.0-beta.1", "1.0.0+5"): only releases are offered.
        let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? ""
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        parts = numbers.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0
            let b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// The newest published release, as far as the updater cares.
public struct ReleaseInfo: Equatable, Sendable {
    public let tag: String
    public let version: AppVersion
    public let pageURL: URL
    public let notes: String

    public init(tag: String, version: AppVersion, pageURL: URL, notes: String) {
        self.tag = tag
        self.version = version
        self.pageURL = pageURL
        self.notes = notes
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case http(Int)
    case malformed

    public var errorDescription: String? {
        switch self {
        case .http(403), .http(429): return L10n.tr("GitHub is limiting requests right now. Try again later.")
        case .http(let code): return L10n.tr("The update server answered with an error (HTTP %ld).", code)
        case .malformed: return L10n.tr("The update server sent an unexpected answer.")
        }
    }
}

/// Asks GitHub for the latest release of this app. No account, no token, nothing about the user is sent:
/// one anonymous GET to the public releases API.
public struct UpdateChecker: Sendable {
    public static let defaultRepository = "livevasiliy/interview-helper"

    public var repository: String
    public var session: URLSession

    public init(repository: String = UpdateChecker.defaultRepository, session: URLSession = .shared) {
        self.repository = repository
        self.session = session
    }

    var endpoint: URL { URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    /// The latest release, or nil when it is not newer than `current`. Drafts and pre-releases are
    /// never returned by the "latest" endpoint.
    public func newerRelease(than current: String) async throws -> ReleaseInfo? {
        guard let currentVersion = AppVersion(current) else { throw UpdateError.malformed }
        let release = try await latest()
        return release.version > currentVersion ? release : nil
    }

    public func latest() async throws -> ReleaseInfo {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("InterviewHelper-update-check", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.http(http.statusCode) }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> ReleaseInfo {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.draft != true, payload.prerelease != true,
              let version = AppVersion(payload.tag_name),
              let url = URL(string: payload.html_url), url.scheme == "https"
        else { throw UpdateError.malformed }
        return ReleaseInfo(tag: payload.tag_name, version: version, pageURL: url, notes: payload.body ?? "")
    }
}
