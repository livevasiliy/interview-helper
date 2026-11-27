# ADR-002: Provider protocols and user-supplied API keys

**Status:** Accepted
**Date:** 2026-11-27
**Feature:** interview-helper
**Author:** 10x-Team (Architect + Staff Engineer)

## Context
Need streaming STT and an LLM without running a backend.

## Decision
Define `Transcriber` and `AnswerEngine` protocols (async streams). Ship one implementation each (STT: Deepgram streaming WebSocket; LLM: Anthropic Messages API streaming). Users enter their own keys, stored in Keychain. Transcripts/audio are not persisted by default.

## Alternatives Considered
| Alternative | Pros | Cons | Why Not |
|---|---|---|---|
| Own proxy backend | Hides keys, enables billing | Ops, cost, auth | Not needed for MVP |
| Local Whisper + local LLM | Private, free | Latency, answer quality | Possible later behind same protocols |
| Apple SFSpeech | No key | Limited streaming/accuracy, limits | Quality |

## Consequences
### Positive
No server; providers swappable; easy fakes for tests.
### Negative
Users bear API cost and setup; keys live on the client.
### Risks
Key leakage via logs; mitigate by never logging secrets.

## Dependencies
Depends on ADR-001 audio streams (PCM format conversion to provider format).
