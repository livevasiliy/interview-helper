# EM — interview-helper task plan (each ≤ half a day)
1. Scaffold: SwiftPM `InterviewCore` + Xcode app target (menu-bar app, LSUIElement); `swift test` works.
2. Protocols + models (`Transcriber`, `AnswerEngine`, `TranscriptSegment`, `Speaker`) + fakes.
3. QuestionDetector with fixture tests.
4. Prompt builder (resume/context + recent turns) with tests.
5. Keychain store + Settings UI (keys, model, language, hide-from-capture toggle).
6. Permissions service + onboarding view.
7. Mic capture (AVAudioEngine) → 16 kHz PCM stream.
8. System audio capture (ScreenCaptureKit) → PCM stream.
9. Deepgram streaming Transcriber (WebSocket, reconnect/backoff).
10. Anthropic streaming AnswerEngine (SSE).
11. SessionController wiring + global hotkey.
12. OverlayPanel UI (live transcript + streamed answer), hide-from-capture toggle.
13. Manual QA matrix (Zoom/Meet/Teams, full-screen, sleep/wake) + latency measurement.
**Sequence:** 1→2→(3,4 parallel)→5,6→7,8→9,10→11→12→13. **Biggest risk:** task 8 (ScreenCaptureKit audio) — spike early.
