# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A native macOS menu-bar app (Swift, macOS 13+) that listens to a live interview, transcribes it, detects the interviewer's question and shows a suggested answer in a floating overlay. Speech-to-text is Deepgram; answers come from a pluggable LLM provider (Gemini free tier by default). There is no backend: the user supplies their own API keys, stored in the Keychain.

## Commands

```bash
swift test                                         # all unit tests (Core only; no Xcode project needed)
swift test --filter SessionControllerTests         # one test class
swift test --filter SessionControllerTests/testQuestionMarkProducesQuestionAndStreamedAnswer   # one test

xcodegen generate && xcodebuild -project InterviewHelper.xcodeproj -scheme InterviewHelper-macOS \
  -configuration Debug -derivedDataPath .build/xcode build    # build the app
open .build/xcode/Build/Products/Debug/InterviewHelper.app    # run it (NOT `open -n`: a 2nd copy cannot register the hotkeys)

.../InterviewHelper --render-overlay-preview=<dir>   # dev flag: PNGs of overlay + Setup window (light/dark), no permissions needed
.../InterviewHelper --diagnose-menubar               # dev flag: is the menu bar icon actually visible (notch)?
```

Build gotchas:
- **Always use scheme `InterviewHelper-macOS`.** The SwiftPM package also exposes a scheme called `InterviewHelper`; xcodebuild can silently pick it, build only the library and still print BUILD SUCCEEDED, leaving a stale app. Check the binary's mtime after a build.
- `InterviewHelper.xcodeproj` is generated from `project.yml` (XcodeGen, `brew install xcodegen`) and gitignored. Never hand-edit it.
- Signing is manual with the local "Apple Development" certificate so macOS keeps the Microphone / Screen Recording grants across rebuilds. The team id comes from a gitignored `Local.xcconfig` (`DEVELOPMENT_TEAM = <id>`); a fresh checkout must create it (`cp Local.xcconfig.example Local.xcconfig`, then fill in the team id). Ad-hoc signing makes macOS forget permissions on every rebuild.
- Live behaviour (permissions, audio capture, real providers, window/cursor behaviour) cannot be unit-tested; see "Verification" below.

## Building an installable app

```bash
scripts/build-release.sh    # -> dist/InterviewHelper.app (universal, Release) and dist/InterviewHelper-<version>.dmg
```

- The version comes from `MARKETING_VERSION` in `project.yml`. The script regenerates the project, builds Release for arm64 + x86_64, verifies the signature, warns if the debugger entitlement `get-task-allow` leaks into the build (Release sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`) and makes a DMG with an Applications shortcut. `dist/` is gitignored.
- It is signed with the **Apple Development** certificate: it runs on this Mac and on Macs registered to the team, but Gatekeeper rejects it elsewhere (not notarized). Sharing it with other people needs a Developer ID certificate and notarization.
- The app icon is generated from code: `swift scripts/make-icon.swift App/Assets.xcassets/AppIcon.appiconset` (a dark rounded square with a green waveform). Edit the script and rerun to change it.
- Do not run an installed copy and a `.build` copy at the same time: they share the bundle id and the second cannot register the global shortcuts.

## Architecture

Two targets, one rule: **everything testable lives in `InterviewCore` (SwiftPM library, `Sources/InterviewCore`); `App/` is a thin AppKit/SwiftUI shell** around system APIs. Tests only cover Core, using hand-written fakes (`FakeAudioSource`, `ControlledTranscriber`, `ScriptedEngine`, `FakePermissionsService`, `InMemorySecretStore`, a stubbed `URLProtocol`, a fake WebSocket).

Pipeline (one session, orchestrated by the `SessionController` actor):

```
SystemAudioCapture (ScreenCaptureKit, the interviewer)  ─┐
MicrophoneCapture  (AVAudioEngine, the user, optional)  ─┴─> PCMConverter → 16 kHz mono Int16 PCMChunk
   → Transcriber (DeepgramTranscriber, WebSocket, reconnect/backoff, one stream per speaker)
   → TranscriptSegment (interim + final)
   → QuestionDetector (interviewer finals only)  ──>  DetectedQuestion
   → PromptBuilder (resume, role, language, recent Turns) → AnswerEngine → streamed tokens
   → SessionEvent stream → SessionCoordinator (@MainActor, published UI state) → OverlayView
```

Key design points:
- **Protocols at every seam:** `AudioSource`, `Transcriber`, `AnswerEngine`, `WebSocketConnector`, `SecretStore`, `SettingsStore`, `PermissionsService`. Production types live in Core (Deepgram, Anthropic/OpenAI-compatible engines, Keychain) or App (ScreenCaptureKit, AVAudioEngine, permissions).
- **System audio is essential, the microphone is best-effort:** failure of the interviewer's audio or transcription fails the session; mic problems only emit `.warning`. A new question cancels the in-flight answer; stale deltas are dropped by question id.
- **`QuestionDetector` is a pure value type.** A "?" emits immediately; otherwise a sentence starting with a cue word (EN + RU, `QuestionDetector.cues`) emits after 0.7 s of silence. The controller bridges Deepgram's audio-clock timestamps to wall time before calling `flush(now:)`. `askNow()` (⌃⌥↩) bypasses the detector (interim + buffered speech, else re-answers the last turn).
- **Answer providers (`AnswerProvider`):** Gemini, Groq, OpenRouter, Ollama (all via `OpenAICompatibleAnswerEngine`, `/chat/completions` + SSE) and Anthropic (`AnthropicAnswerEngine`). `AnswerEngineFactory` wraps them in `FallbackAnswerEngine`: primary retried once, then the provider default and `fallbackModels`; only failures before the first token are retried; 401/403 and 400 are never retried; if everything fails, `ProviderError.allModelsFailed` lists one line per model. **Model ids rot quickly** (Gemini 2.5 was retired for new users): never hard-code from memory, keep them editable in Settings and verify against current docs.
- **Settings:** `AppSettings` (Codable, tolerant decoding with migrations, e.g. legacy free-text `language` → `InterviewLanguage`) in `UserDefaults`; secrets only in the Keychain (`SecretKey` slot per provider). `SetupState` computes what is still missing (permissions, the chosen provider's key, Deepgram key).
- **The overlay never activates the app** (`OverlayPanel`, `canBecomeKey = false`) so typing in the interview app keeps working. Consequences: the panel's own border shows no resize cursors, so `ResizeHandleView` implements resizing (geometry in tested `WindowResize`); hide-from-screen-sharing (`sharingType = .none`) is best effort and not reliable against ScreenCaptureKit-based apps.
- **App-only glue:** `SessionCoordinator` builds the real pipeline from settings/Keychain at each start and handles sleep/wake; `GlobalHotKey` (Carbon) registers the shortcuts defined once in `Shortcut` (⌃⌥Space start/stop, ⌃⌥↩ answer now, ⌃⌥O overlay, ⌃⌥, settings; ⌘, only works while the app is active, a global ⌘, would hijack every app); `StatusItemFactory` creates the menu bar icon and falls back to a Dock icon if a notch hides it.

## Localization (English + Russian, switchable at runtime)

- **Every user-visible string goes through `tr("English text")`** (`L10n.tr` in Core, a global `tr` helper in `App/Services/Localization.swift`). The English text is the key; Russian lives in `Sources/InterviewCore/Translations.swift`. A missing translation falls back to English. Use `%@` / `%ld` placeholders and keep them identical in the translation. SwiftUI: `Text(tr("…"))`, not `Text("…")` (a bare literal bypasses the table).
- `UILanguage` (Auto / Русский / English) is an `AppSettings` field; Auto follows the system language. `SetupViewModel` sets `L10n.language` when the setting changes; the menus are rebuilt (`AppDelegate.languageChanged`) and the overlay observes `OverlayAppearance.language`, so a switch applies immediately. `L10n.language` defaults to English so tests are deterministic.
- `LocalizationTests` scans the sources: every `tr("…")` literal must have a Russian entry, every entry must be used, placeholders must match. Add the Russian entry in the same change as the new string or the suite fails. Debug items and the audio-test dialogs are intentionally English-only.
- The *interview* language (speech recognition + answer language) is a separate setting (`InterviewLanguage`).

## Verification (what only a human can check)

Manual run list lives in `.10x/decisions/qa/interview-helper.md` (verified so far: mic + system audio → Deepgram → Gemini answer in Russian). Useful smoke test without a call: start a session, then `say -v Milena "Расскажите, что такое транзакция в базе данных?"` (system audio path). Still unverified there: latency (< 3 s target), hotkeys in practice, sleep/wake, English, Groq/OpenRouter/Ollama.

## Project process files

`.10x/` holds the team-process state (specs, ADRs, per-role decisions, `status.md`, `handoff.md`, security/privacy review). Read `.10x/decisions/sde/interview-helper.md` for the running implementation log and deviations. The folder is not a git repository yet.

## Privacy and policy notes to preserve

Audio goes to Deepgram; questions, history and the pasted resume go to the chosen answer provider (free tiers may use submitted data for training: don't send sensitive data; Ollama keeps answers local). Never log keys or transcript text. Using live AI help may violate an interviewer's or employer's rules; the app must not claim to be undetectable.
