# PM — interview-helper
**User:** job seeker in video interviews on macOS (Zoom/Meet/Teams) who wants real-time answer suggestions.
**MVP user stories**
1. As a user, I grant Mic + Screen Recording permissions via guided onboarding.
2. As a user, I enter my API keys once; they are stored securely.
3. As a user, I upload/paste my resume and role context to personalize answers.
4. As a user, I press a hotkey to start/stop a session.
5. As a user, I see a live transcript, labeled interviewer vs me.
6. As a user, when the interviewer finishes a question, I see a concise streamed answer outline within ~3 s.
7. As a user, I toggle the overlay with a hotkey and optionally hide it from screen capture.
**Success criteria:** question-end → first token < 3 s median; transcript word accuracy acceptable on clear audio; no crash in a 60-min session; setup < 5 min.
**Out of scope:** Windows, accounts/billing, question bank, resume analysis, mock interviews, local models.
