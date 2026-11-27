# Handoff → QA (T13)
Done: T1–T12 code, 75 unit tests. Build with scheme **InterviewHelper-macOS** (see sde notes: the old scheme name could silently build the wrong target).
Nothing has run end to end yet. Manual run list, in order:
1. Menu → Setup & Settings…: allow Microphone + Screen Recording, restart the app, paste Anthropic + Deepgram keys.
2. Menu → Debug: Test Microphone / Test System Audio (play audio): expect ~5 s received, peak > 0.
3. ⌃⌥Space (or menu): overlay appears, "Listening". Play a video/call with a question; check transcript (toggle bubble button), question, streamed answer, time to first token (target < 3 s).
4. ⌃⌥O hides/shows; drag/resize and relaunch (position kept); try over a full-screen app and another Space.
5. Unplug/plug headphones mid-session; sleep/wake; revoke a permission; wrong API key (expect a clear failure message).
6. Check Deepgram `language=multi` with Russian, and the default Anthropic model id.
Then record results in decisions/qa/interview-helper.md and .10x/reviews/, and run the security review (keys in Keychain only, no transcript logging, hide-from-capture caveat).
