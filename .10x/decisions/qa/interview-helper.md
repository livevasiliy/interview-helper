# QA — interview-helper

## Verified on a real Mac session (user-run, screenshots)
| Area | Result |
|---|---|
| Permissions flow (mic + Screen Recording, dev-signed build) | OK: "Everything is set up." persists across rebuilds |
| Microphone → Deepgram, Russian (`language=multi`) | OK: "Расскажи, что такое транзакция." transcribed under "You" |
| **System audio → Deepgram → question detection → Gemini → streamed answer** (`say -v Milena …` through speakers) | **OK end to end**: Russian answer in 4 bullets (ACID, atomic commit/rollback, integrity) rendered in the overlay |
| Overlay: appears on session start, bullets with hanging indent, large text, hotkey hint line | OK |
| Failure reporting | OK: HTTP 503 (demand spike) and HTTP 404 (retired model) surfaced readably in the overlay |
| Gemini free tier (key from AI Studio, default `gemini-3.5-flash-lite`) | OK, answered after the model-list fix |

## Found and fixed during the run
1. Missing Deepgram key → Setup window opened with no explanation → now an explicit "still missing" banner.
2. Mic speech was never treated as a question → opt-in "answer questions I say into the microphone".
3. Gemini 503 + retired backup models (2.5 family closed to new users) → retry/backup chain with current models; per-model failure report.
4. Build gotcha (duplicate scheme name) → target renamed `InterviewHelper-macOS`.

## Observations still to check
- The overlay's question read "что такое транзакция в базе данных?": the leading word "Расскажите," from the spoken phrase is missing. Open the transcript (bubble icon) to see whether Deepgram dropped it or the detector split it (a lone cue word followed by a >0.7 s pause emits as its own question and gets superseded). If split: require ≥ 3 words for the silence rule. Not changed yet (no evidence).
- Time from end of question to first answer text was not measured (target < 3 s). With the retry chain a busy model can add several seconds.

## Not yet exercised
- ⌃⌥Space / ⌃⌥↩ / ⌃⌥O hotkeys in practice (only the menu and session start via hotkey were seen working), drag/resize/position memory, full-screen apps and Spaces.
- Headphone plug/unplug and sleep/wake mid-session; revoking a permission mid-session; wrong API key message.
- English interview language, explicit `ru`/`en` Deepgram codes, Groq/OpenRouter/Ollama providers, the microphone device picker with a non-default device.
- Real interview apps (Zoom/Meet/Teams) as the audio source; echo with speakers (mic also hears the interviewer).

## Quality gates
- Unit tests: 119 pass (repeated runs, no flakes). Offscreen UI renders reviewed in light and dark.
