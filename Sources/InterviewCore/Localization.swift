import Foundation

/// A language the interface can actually be shown in.
public enum AppLanguage: String, Sendable {
    case english
    case russian
}

/// The user's choice for the interface language. `auto` follows the system's preferred language.
public enum UILanguage: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case russian
    case english

    public var id: String { rawValue }

    /// Shown in the picker. Each language is named in itself so it is recognisable whatever the current language is.
    public var displayName: String {
        switch self {
        case .auto: return L10n.tr("Auto (system)")
        case .russian: return "Русский"
        case .english: return "English"
        }
    }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        switch self {
        case .russian: return .russian
        case .english: return .english
        case .auto:
            let first = preferredLanguages.first?.lowercased() ?? ""
            return first.hasPrefix("ru") ? .russian : .english
        }
    }
}

/// Runtime-switchable text lookup. Source text is English and doubles as the key: `tr("Save")` returns
/// the Russian translation when Russian is active and the English text otherwise (also when a
/// translation is missing, so a forgotten string degrades to English instead of showing a blank).
public enum L10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: AppLanguage = .english

    /// Defaults to English so unit tests and tools are deterministic; the app sets it from the user's setting.
    public static var language: AppLanguage {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    public static func tr(_ key: String) -> String {
        switch language {
        case .english: return key
        case .russian: return Translations.russian[key] ?? key
        }
    }

    /// `printf`-style formatting; translations must keep the same placeholders as their English key.
    public static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: tr(key), arguments: arguments)
    }
}
