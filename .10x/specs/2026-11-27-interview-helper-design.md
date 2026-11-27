# Interview Helper (macOS) — Design

**Date:** 2026-11-27
**Status:** Awaiting user review
**Reference product:** Ghost GPT (ghostgpt.tech) — "AI for passing job interviews", desktop app. Feature list not fully verified (site renders features via JS); this spec is based on user decisions, not a copy of that product.

## Goal
A native macOS menu-bar app that listens to a live interview, transcribes it, detects questions, and shows concise suggested answers in a floating overlay.

## Decisions (from brainstorming)
| Topic | Decision |
|---|---|
| MVP scope | Live assistant (practice/prep, question bank, resume analysis are out of MVP) |
| Stack | Native Swift/SwiftUI + AppKit, macOS only |
| AI backend | Cloud APIs with the user's own keys (streaming STT + LLM); no own backend |
| Overlay capture | Normal window by default; opt-in toggle for `NSWindow.sharingType = .none`, with a settings note to follow the interview's rules |

## Architecture
- **AudioCapture** — ScreenCaptureKit (system audio = interviewer) + AVAudioEngine (mic = user); streams tagged by speaker.
- **Transcriber** (protocol) — streaming cloud STT; emits partial/final segments. Provider swappable.
- **QuestionDetector** — pause + question heuristic over interviewer segments; emits "question complete".
- **AnswerEngine** (protocol) — builds prompt from question, resume/context, recent turns; streams a short answer outline from an LLM.
- **OverlayPanel** — non-activating floating `NSPanel`, always on top, global hotkey show/hide.
- **Settings** — API keys in Keychain; model, language, resume/context upload; capture-hiding toggle.
- **Permissions** — Screen Recording and Microphone, with a first-run onboarding flow.

## Data flow
Audio → Transcriber → segments → QuestionDetector → AnswerEngine → OverlayPanel. No audio or transcripts persisted by default.

## Error handling
Missing permission/key → onboarding prompt. STT or LLM network failure → inline overlay status with retry; app never blocks audio capture on LLM errors. Rate limits → backoff and visible notice.

## Testing
Unit tests for QuestionDetector and prompt building with fixture transcripts; protocol fakes for Transcriber/AnswerEngine; manual test matrix for permissions and overlay behavior (full-screen apps, Zoom/Meet/Teams).

## Out of scope (MVP)
Windows, accounts/billing, own backend, question bank, resume analysis, mock interviews, local models.

## Open risks
- ScreenCaptureKit audio needs Screen Recording permission, which has awkward UX.
- End-to-end latency target (question end → first answer token) to be measured; aim for under 3 s.
