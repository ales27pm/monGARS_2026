# ROADMAP

## Near Term

- Add editable conversation titles and message retry/regenerate controls.
- Add share-sheet export for memory/document exports.
- Add UI tests once simulator execution is stable on the target machine.
- Add UI-level automation around the existing Developer real-tool E2E report once simulator/device launch is stable on the target machine.

## Mid Term

- Add richer natural-language date and recurrence parsing for approved reminder and calendar tools.
- Add export/import for local memories and documents.
- Add per-conversation provider overrides.
- Add a bundled `DocumentEmbedding` Core ML model as an optional custom upgrade to the current local NaturalLanguage semantic ranking.

## Later

- Support remote provider authentication profiles.
- Add App Intents for privacy-safe shortcuts.
- Add model availability diagnostics for Foundation Models-capable devices.
- Add CI using `build-for-testing` and simulator smoke tests.

## Recently Completed

- Added continuation-backed inline approval suspension in `AgentRuntime`.
- Added routing coverage for memory-save intents and document-summary intents.
- Added richer document retrieval with chunk ranking and highlighted matches.
- Added local NaturalLanguage-backed semantic document embeddings with hybrid lexical/vector retrieval.
- Added live speech dictation into the Chat composer through `SpeechService`.
- Added timeline and graph visualizations for the Diagnostics screen.
- Added privacy-gated tools for native reminders/calendar with local fallback, Contacts lookup, weather, messages, phone, email, maps, integrated webview navigation, web fetch, and app-local file actions.
- Added Settings-gated network access for remote provider calls and network-capable tools.
- Added WeatherService with WeatherKit-first behavior and an OpenWeather-compatible Keychain-backed fallback.
- Added PDFKit extraction for web fetch and document import.
- Added default private-LAN/localhost blocking with explicit Developer Mode opt-in.
- Added structured HTML extraction for title, description, canonical URL, and readable text.
- Added Settings > Developer one-button real-tool E2E report export with no-mock tool probes, redaction, Keychain/network-policy checks, permission state, SwiftData counts, and recent diagnostics.
- Added memory edit/export/forget-all UI in Memories.
