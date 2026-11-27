# Security and privacy review — interview-helper (self-review, not an external audit)

## Secrets
- API keys (Deepgram, chosen answer provider) are stored only in the macOS Keychain (`kSecAttrAccessibleWhenUnlocked`, service `dev.interviewhelper.app`). They are never written to settings, logs or source. The Team ID lives in a gitignored `Local.xcconfig`.
- Keys are sent only to their own provider over HTTPS (Ollama: localhost, plain HTTP). The WebSocket to Deepgram is `wss://`.
- The app is not sandboxed (chosen for the MVP); it runs with hardened-runtime entitlement for audio input only.

## Privacy: where the interview content goes (tell the user)
- **Audio** (interviewer via system audio, and the user's microphone) is streamed to **Deepgram**.
- **Transcribed questions, recent conversation, and the pasted resume / role text** are sent to the **chosen answer provider** (Gemini by default). On free tiers, providers commonly reserve the right to use submitted content to improve their products (Google documents this for unpaid Gemini API use). Do not put sensitive personal data in the Resume field when using a free cloud provider; **Ollama keeps everything on the Mac** (answers only; speech still goes to Deepgram).
- Nothing is persisted by the app except settings and the saved window position. Transcript text is not logged. Debug audio tests write a WAV into the temp folder (`interview-helper-*.wav`); delete them if sensitive.

## Hide-from-capture
- `NSWindow.sharingType = .none` is best effort and documented as unreliable against ScreenCaptureKit-based capture on recent macOS, so concealment from a call app is **not guaranteed**. The setting is off by default and says so. The app makes no claim of being undetectable.

## Misuse / policy
- Real-time AI help may break an interviewer's or employer's rules. The Settings text tells the user to follow them. This remains the user's responsibility.

## Findings
- No credentials in code, logs or the repository. No network listeners. Input validation: provider and WebSocket messages are parsed defensively (malformed JSON ignored); errors never echo keys.
- Open item: keys are readable by any process running as the user via the Keychain only after the user approves access; the first launch after changing the signing identity triggers that prompt (expected).
