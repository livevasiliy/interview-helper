# Senior Engineer — interview-helper approach notes
- T3 QuestionDetector: debounce interviewer final segments (~700 ms silence); question if it ends with "?" or starts with cues ("tell me", "describe", "walk me through", "explain"); merge multi-segment questions. Pure function over segments → easy fixtures.
- T7/T8: convert to 16 kHz mono Int16 with AVAudioConverter; one shared PCM chunk type.
- T9: one WebSocket per speaker stream; keep-alive; reconnect with exponential backoff; partials separate from finals.
- T10: SSE streaming; cancel in-flight request when a new question arrives; cap tokens; system prompt asks for a concise bullet outline in the interview language.
- T11: SessionController is an actor; cancel on stop; handle sleep/wake notifications.
- T12: `NSPanel` `.nonactivatingPanel`, `.floating` level, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`; `sharingType` driven by setting.
- Tricky: Screen Recording permission detection (`CGPreflightScreenCaptureAccess`) and relaunch after grant.
