# ADR-001: Native Swift app with ScreenCaptureKit + AVAudioEngine capture

**Status:** Accepted
**Date:** 2026-11-27
**Feature:** interview-helper
**Author:** 10x-Team (Architect + Staff Engineer)

## Context
Need low-latency capture of both interviewer audio (system output) and user mic on macOS, plus an always-on-top non-focus-stealing overlay.

## Decision
Native Swift/SwiftUI + AppKit. System audio via ScreenCaptureKit (`SCStream` audio-only config); mic via AVAudioEngine. Two independent streams tagged by speaker; no diarization needed. Overlay is a non-activating `NSPanel` hosting SwiftUI. Minimum macOS 13.

## Alternatives Considered
| Alternative | Pros | Cons | Why Not |
|---|---|---|---|
| Tauri/Electron | Cross-platform | Weak system-audio and overlay support, heavier | macOS-only MVP |
| Virtual audio driver (BlackHole) | Works on older macOS | User must install/route driver | Poor setup UX |
| Mic-only capture | No Screen Recording permission | Misses interviewer unless on speakers; echo | Fails core use case |

## Consequences
### Positive
Best native fit, small footprint, speaker labeling for free.
### Negative
macOS-only; needs Screen Recording permission; ScreenCaptureKit API quirks.
### Risks
Permission UX and OS-version changes; mitigate with onboarding and permission-state checks.

## Dependencies
Constrains a later Windows port (separate codebase).
