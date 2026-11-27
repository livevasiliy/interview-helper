# Staff Engineer — interview-helper
Greenfield; conventions:
- Swift Package for core logic (`InterviewCore`: detector, prompts, protocols, fakes) tested with `swift test`; thin Xcode app target for UI/system APIs.
- Swift concurrency (async/await, AsyncStream); no Combine in new code.
- Logging via `os.Logger`; never log keys, audio, or transcript text at default level.
- Secrets only in Keychain; no keys in UserDefaults or source.
- SwiftUI for views; AppKit only for NSPanel/status item.
