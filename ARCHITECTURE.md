# ARCHITECTURE

## App Shell

`monGARS/App` owns startup, dependency injection, provider settings, diagnostics, and first-run welcome setup. `AppContainer` is the root dependency container and is injected into SwiftUI views.

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
- `RepoIndexRecord`
- `RepoSymbolRecord`

The app creates one welcome conversation when the store is empty. It does not create memory, document, or task records on behalf of the user.

Startup records whether SwiftData opened durable storage, recovered durable storage after quarantining an invalid store, or could only create an emergency ephemeral container. The emergency state exists only so the app can render an honest failure screen; Chat, memories, documents, goals, and tools are disabled because new user data cannot be stored durably.

## LLM Providers

`monGARS/LLM` defines `LLMProvider` plus concrete providers.

- `FoundationModelProvider` imports FoundationModels behind `canImport` and uses `LanguageModelSession` only inside iOS 26 availability checks.
- `MLXLocalProvider` imports MLX Swift LM packages behind `canImport`, loads the configured `LLMRegistry` model through Hugging Face integration, supports complete and streaming responses, blocks first-load model preparation while the Settings network toggle is off, and fails honestly when MLX is not linked or generation returns no user-visible text.
- `RemoteLLMProvider` posts only when remote mode and the network toggle are explicitly enabled in Settings. It supports OpenAI-compatible chat completions plus Ollama generate/chat payloads, optional bearer auth from Keychain, non-stream completion, and provider streaming through `NetworkClient` line streaming when the endpoint emits SSE or line-delimited JSON.

## Agent Runtime And Graph

`monGARS/AgentGraph` has two layers:

- `AgentRuntime` runs the autonomous loop used by Chat.
- `AgentGraph` keeps the compact graph API and also exposes `makeAutonomous` with nodes named `UnderstandIntent`, `RetrieveContext`, `Plan`, `SelectTool`, `ExecuteTool`, `ObserveResult`, `Reflect`, `Respond`, `AskUser`, and `SaveMemory`.

Runtime phases and graph nodes write SwiftData checkpoints and trace events. Runtime phase checkpoints include compact state data so paused runs can resume from the last durable phase. `AgentRuntime` buffers high-frequency telemetry in memory and flushes trace, checkpoint, and tool-call records at terminal states, approval suspension points, pause, and cancellation. `ContextBuilder` composes prompts from the user goal, conversation summary, memories, ranked document snippets, tool results, graph state, and system rules with phase-aware context pruning.

## Control Plane, Self-Model, And Approvals

`ToolRouter.routeDecision(input:)` adds a scored route-decision API on top of the existing registry. It returns the proposed tool, calibrated confidence, risk level, approval requirement, anchored lexical/schema evidence, and abstention reasons for low-confidence or ambiguous requests; target/action details come from `winner.tool.metadata(for:)` and are folded into the anchored justification when present.

`ApprovalTuple` and `ApprovalTupleHasher` bind high-risk actions to immutable metadata: tool name, target, normalized arguments, payload hash, risk level, expiration timestamp, session/run identifier, and user-visible diff. `ApprovalRequestRecord` persists those fields, and Goals renders the tuple metadata before approval. `ToolCallRecord` now stores a payload hash for audit replay.

`RepoSelfModelService` builds a deterministic repo symbol graph from source files and persists `RepoIndexRecord` plus `RepoSymbolRecord` nodes with repository name, commit hash, file path, module, symbol kind, parent symbol, line range, signature, and privacy level. The current parser is dependency-free and SwiftSyntax/SourceKit-ready: richer parsers can feed the same `RepoSourceFile`/`RepoSymbolNode` seam without changing storage or diagnostics consumers.

## Tools, Memory, Documents, Speech

Tools live in `monGARS/Tools` and are routed with simple intent heuristics plus the scored route-decision layer. Each capability declares a schema, risk level, approval requirement, and async execution method. Local operations include calculator, date/time, memory search/save/delete, document search/summarize, conversation search, diagnostics, and task create/update/complete. Privacy-gated integrations cover native Reminders and Calendar writes, Contacts lookup, weather lookup, SMS/phone/email handoffs, Apple Maps handoff, integrated webview navigation, approved web fetch, approved generic HTTP, and app-local file list/read/write/delete. Handoff tools prepare reviewed actions; they do not send messages, place calls, or write outside the app-owned agent workspace automatically. Email handoffs present `MFMailComposeViewController` from Chat when iOS can send mail and otherwise use the system Mail URL handoff. Maps lookup uses `MKLocalSearch` when available before preparing the Apple Maps URL. Calendar and Reminder tools succeed only through EventKit; denied permissions return honest errors instead of local-only success. Weather lookup uses a `WeatherService` abstraction that attempts WeatherKit when the SDK/entitlement path is available, then uses a user-configured OpenWeather-compatible secondary provider with the API key stored in Keychain. Weather lookup, Maps search, integrated webview navigation, web fetch, and generic remote HTTP are blocked unless Settings enables network provider and tools, and approval is still required before execution.

`NetworkClient` centralizes URLSession async/await calls with configurable timeout, bounded retries with backoff, HTTP status validation, content-type validation, response-size limits, line streaming for SSE/JSONL providers, latency metrics, cancellation propagation, and sanitized OSLog entries. HTTP/HTTPS validation blocks localhost, `.local`, link-local, and private LAN hosts by default; Settings Developer Mode is the explicit local-network escape hatch. No secret values are logged. Persisted tool-call diagnostics store target, status code, latency, error category, and payload-hash fields when available instead of relying only on output text parsing.

`DeveloperDiagnosticsRunner` lives in `monGARS/App` and powers the Settings > Developer report button. It invokes production tool implementations directly without any LLM provider, using temporary `monGARS E2E` inputs for mutating probes and respecting the Settings network toggle for network-capable tools. It reports registry coverage, approval-rejection coverage for high/destructive tools, network-off gating, private-host policy, invalid input paths, local HTML/text/PDF extraction, PDF import into SwiftData chunks, app/build metadata, configuration shape, Keychain round trip, framework availability, permission states, SwiftData model counts, and recent diagnostics. Reports are redacted before display/export and written under the app-owned `AgentFiles/Reports` directory. Reports produced anywhere except a physical iOS device are explicitly rejected as real on-device evidence. The runner is intentionally not an XCTest launcher; build and unit-test proof still comes from Xcode.

Memory and document services are SwiftData-backed service structs. Memory supports importance scoring, deduplication, source tracking, search, edit, delete, export, and forget-all. Documents are chunked at import time and retrieved with hybrid lexical + semantic ranking when Apple NaturalLanguage contextual embedding assets are available on the device. UTF-8 text, Markdown, and selectable-text PDFs are imported locally; PDF text extraction uses PDFKit and records page-numbered text.

Speech is exposed through `SpeechService`; the current implementation requests Apple Speech authorization, streams live dictation into the Chat composer, and reports denied/restricted/unavailable states cleanly.

## UI

`monGARS/Views` uses `NavigationSplitView` for a desktop-class iPad/iPhone layout:

- Chat with conversation list and streaming response updates.
- Expandable agent trace under assistant responses.
- Memory manager.
- Documents screen with file import and local keyword search.
- Goals screen with active/paused/completed/failed runs, tasks, pause/resume/stop, and approval tuple controls.
- Diagnostics screen showing provider status, timeline and graph visualizations, graph steps, checkpoints, and structured tool-call status, target, latency, approval, and error data.
- Settings screen for provider selection, provider capability flags, autonomy level, Network, Weather, Web, Documents/RAG, Apple Integrations, Developer local-network policy, one-button real-tool E2E report export, speech permission, and reset.
