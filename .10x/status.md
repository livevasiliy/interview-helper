# Status
- Phases 0–3: COMPLETE.
- Phase 4 Implementation: IN PROGRESS.
- Not a git repo; state files and code not committed.

## Tasks
- T1 scaffold: DONE (SwiftPM core + XcodeGen app project; builds)
- T2 protocols/models/fakes: DONE
- T3 QuestionDetector + tests: DONE
- T4 PromptBuilder + tests: DONE
- T5 Keychain + Settings: DONE
- T6 Permissions + onboarding: DONE (smoke-launched; needs manual visual check)
- T8 system audio capture: SPIKE CODE-COMPLETE; converter tested; real capture needs manual run (menu: Debug: Test System Audio)
- T7 mic capture: CODE-COMPLETE; real capture needs manual run (menu: Debug: Test Microphone)
- T9 Deepgram transcriber: DONE (fake-socket tests; live API unverified)
- T10 Anthropic answer engine: DONE (stub-URLProtocol tests; live API unverified)
- T11 SessionController + hotkey + sleep/wake: DONE (unit-tested; no overlay yet, so output is not visible)
- T12 Overlay: DONE (offscreen renders reviewed light/dark; live window behavior unverified; hide-from-capture is best effort)
- T13 QA: IN PROGRESS — first full end-to-end success on a real Mac (see decisions/qa/interview-helper.md); latency and several manual checks remain; security/privacy self-review written to reviews/2026-11-27-security-review.md
- Verification: `swift build` OK, `swift test` 126/126 pass; xcodebuild BUILD SUCCEEDED
