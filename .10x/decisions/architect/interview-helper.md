# Architect — interview-helper
See ADR-001, ADR-002 and the spec.
**Components:** AudioCapture, Transcriber, QuestionDetector, AnswerEngine, OverlayPanel, SessionController (orchestrator, owns lifecycle), Settings/Keychain, Permissions.
**Boundaries:** Only AudioCapture touches system audio APIs; providers sit behind protocols; SessionController is the only component wiring them together.
**Data flow:** AudioCapture(mic, system) → Transcriber → segments → QuestionDetector → AnswerEngine → OverlayPanel.
**Failure modes:** permission revoked mid-session (stop + prompt); STT socket drop (reconnect with backoff, keep capturing); LLM error (show retry, never block capture); rate limit (notice); sleep/wake (restart streams).
**Latency budget:** end-of-speech detect ≤ 700 ms, LLM first token ≤ 2 s.
