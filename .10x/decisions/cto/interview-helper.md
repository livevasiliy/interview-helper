# CTO — interview-helper
**Verdict:** Build (personal/small-product tool). Buy/use-existing alternatives exist (Ghost GPT and similar), but the goal is own implementation.
**Tech direction:** Native Swift/SwiftUI, macOS 13+ (ScreenCaptureKit audio capture requires 13+). Cloud STT + LLM via user-supplied keys; no backend, so no ops/billing burden.
**Strategic risks:**
- Ethical/ToS: using live AI help may violate an interviewer's or employer's rules. Mitigation: capture-hiding is opt-in, with a rules notice; no marketing of concealment.
- Provider dependence: mitigated by Transcriber/AnswerEngine protocols.
- Screen Recording permission friction on macOS.
**Opportunity cost:** MVP kept narrow (live assistant only).
