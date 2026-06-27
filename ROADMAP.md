# ROADMAP

## Near Term

- Add editable conversation titles and message retry/regenerate controls.
- Add richer memory editor UI for edit/export/forget-all service operations.
- Add UI tests once simulator execution is stable on the target machine.

## Mid Term

- Add richer natural-language date and recurrence parsing for approved reminder and calendar tools.
- Add export/import for local memories and documents.
- Add per-conversation provider overrides.
- Add a bundled `DocumentEmbedding` Core ML model and enable semantic ranking through the existing embedding provider seam.

## Later

- Support remote provider authentication profiles.
- Add App Intents for privacy-safe shortcuts.
- Add model availability diagnostics for Foundation Models-capable devices.
- Add CI using `build-for-testing` and simulator smoke tests.

## Recently Completed

- Added continuation-backed inline approval suspension in `AgentRuntime`.
- Added richer document retrieval with chunk ranking and highlighted matches.
- Added live speech dictation into the Chat composer through `SpeechService`.
- Added timeline and graph visualizations for the Diagnostics screen.
- Added privacy-gated tools for native reminders/calendar with local fallback, Contacts lookup, weather, messages, phone, email, maps, integrated webview navigation, web fetch, and app-local file actions.
