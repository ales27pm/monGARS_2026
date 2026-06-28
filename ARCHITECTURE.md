# ARCHITECTURE

## App Shell

`monGARS/App` owns startup, dependency injection, provider settings, diagnostics, and seed data. `AppContainer` is the root dependency container and is injected into SwiftUI views.

## Persistence

SwiftData models live in `monGARS/Models`:

- `Conversation`
- `ChatMessage`
- `MemoryRecord`
- `DocumentRecord`
- `DocumentChunkRecord`
- `AgentCheckpointRecord`
- `AgentRunRecord`
- `AgentTraceRecord`
- `ToolCallRecord`
- `ApprovalRequestRecord`
- `AgentTaskRecord`

The app seeds one welcome conversation, one memory, one document, and one task when the store is empty.

## LLM Providers

`monGARS/LLM` defines `LLMProvider` plus concrete providers.

- `FoundationModelProvider` imports FoundationModels behind `canImport` and uses `LanguageModelSession` only inside iOS 26 availability checks.
- `MockLLMProvider` is deterministic and local, suitable for demos, tests, and older runtimes.
- `RemoteLLMProvider` posts only when remote mode and the network toggle are explicitly enabled in Settings. It supports OpenAI-compatible chat completions plus Ollama generate/chat payloads, optional bearer auth from Keychain, non-stream completion, and provider streaming through `NetworkClient` line streaming when the endpoint emits SSE or line-delimited JSON.

## Agent Runtime And Graph

`monGARS/AgentGraph` has two layers:

- `AgentRuntime` runs the autonomous loop used by Chat.
- `AgentGraph` keeps the compact graph API and also exposes `makeAutonomous` with nodes named `UnderstandIntent`, `RetrieveContext`, `Plan`, `SelectTool`, `ExecuteTool`, `ObserveResult`, `Reflect`, `Respond`, `AskUser`, and `SaveMemory`.

Runtime phases and graph nodes write SwiftData checkpoints and trace events. Runtime phase checkpoints include compact state data so paused runs can resume from the last durable phase. `AgentRuntime` buffers high-frequency telemetry in memory and flushes trace, checkpoint, and tool-call records at terminal states, approval suspension points, pause, and cancellation. `ContextBuilder` composes prompts from the user goal, conversation summary, memories, ranked document snippets, tool results, graph state, and system rules with phase-aware context pruning.

## Tools, Memory, Documents, Speech

Tools live in `monGARS/Tools` and are routed with simple intent heuristics. Tools declare a schema, risk level, approval requirement, and async execution method. Local tools include calculator, date/time, memory search/save/delete, document search/summarize, conversation search, diagnostics, and task create/update/complete. Privacy-gated tools cover native Reminders and Calendar writes, Contacts lookup, weather lookup, SMS/phone/email handoffs, Apple Maps handoff, integrated webview navigation, approved web fetch, approved generic HTTP, and app-local file list/read/write/delete. Handoff tools prepare reviewed actions; they do not send messages, place calls, or write outside the app-owned agent workspace automatically. Email handoffs present `MFMailComposeViewController` from Chat when iOS can send mail and fall back to the system Mail URL otherwise. Maps lookup uses `MKLocalSearch` when available before preparing the Apple Maps URL. Calendar and Reminder tools succeed only through EventKit; denied permissions return honest errors instead of local simulated success. Weather lookup uses a `WeatherService` abstraction that attempts WeatherKit when the SDK/entitlement path is available, then falls back to a user-configured OpenWeather-compatible endpoint with the API key stored in Keychain. Weather lookup, Maps search, integrated webview navigation, web fetch, and generic remote HTTP are blocked unless Settings enables network provider and tools, and approval is still required before execution.

`NetworkClient` centralizes URLSession async/await calls with configurable timeout, bounded retries with backoff, HTTP status validation, content-type validation, response-size limits, line streaming for SSE/JSONL providers, latency metrics, cancellation propagation, and sanitized OSLog entries. It accepts only HTTP/HTTPS URLs and blocks localhost, `.local`, link-local, and private LAN hosts by default; Settings Developer Mode is the explicit local-network escape hatch. No secret values are logged. Persisted tool-call diagnostics store target, status code, latency, and error category fields when available instead of relying only on output text parsing.

`DeveloperDiagnosticsRunner` lives in `monGARS/App` and powers the Settings > Developer report button. It invokes production tool implementations directly without `MockLLMProvider`, using temporary `monGARS E2E` inputs for mutating probes and respecting the Settings network toggle for network-capable tools. It also runs local runtime self-checks for app/build metadata, configuration shape, network policy, Keychain round trip, framework availability, permission states, SwiftData model counts, and recent diagnostics. Reports are redacted before display/export and written under the app-owned `AgentFiles/Reports` directory. The runner is intentionally not an XCTest launcher; build and unit-test proof still comes from Xcode.

Memory and document services are SwiftData-backed service structs. Memory supports importance scoring, deduplication, source tracking, search, edit, delete, export, and forget-all. Documents are chunked at import time and retrieved with deterministic hybrid lexical + semantic ranking when local Apple NaturalLanguage sentence embeddings are available; the Core ML provider seam remains for a future bundled `DocumentEmbedding` model. UTF-8 text, Markdown, and selectable-text PDFs are imported locally; PDF text extraction uses PDFKit and records page-numbered text.

Speech is exposed through `SpeechService`; the current implementation requests Apple Speech authorization, streams live dictation into the Chat composer, and reports denied/restricted/unavailable states cleanly.

## UI

`monGARS/Views` uses `NavigationSplitView` for a desktop-class iPad/iPhone layout:

- Chat with conversation list and streaming response updates.
- Expandable agent trace under assistant responses.
- Memory manager.
- Documents screen with file import and local keyword search.
- Goals screen with active/paused/completed/failed runs, tasks, pause/resume/stop, and approve/reject controls.
- Diagnostics screen showing provider status, timeline and graph visualizations, graph steps, checkpoints, and structured tool-call status, target, latency, approval, and error data.
- Settings screen for provider selection, provider capability flags, autonomy level, Network, Weather, Web, Documents/RAG, Apple Integrations, Developer local-network policy, one-button real-tool E2E report export, speech permission, and reset.
