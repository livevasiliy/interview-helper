import InterviewCore

/// Short names for the translation lookup used throughout the app's UI code.
/// Source text is English and doubles as the key; see `L10n` and `Translations` in InterviewCore.
func tr(_ key: String) -> String { L10n.tr(key) }

func tr(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L10n.tr(key), arguments: arguments)
}
