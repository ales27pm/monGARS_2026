# ARCHITECTURE

## App Shell

`monGARS/App` owns startup, dependency injection, provider settings, diagnostics, and seed data. `AppContainer` is the root dependency container and is injected into SwiftUI views.

## Persistence

SwiftData models live in `monGARS/Models`:

- `Conversation`
- `ChatMessage`
- `MemoryRecord`
- `DocumentRecord`
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
- `RemoteLLMProvider` posts to an Ollama-style endpoint only when remote mode is explicitly enabled.

## Agent Runtime And Graph

`monGARS/AgentGraph` has two layers:

- `AgentRuntime` runs the autonomous loop used by Chat.
- `AgentGraph` keeps the compact graph API and also exposes `makeAutonomous` with nodes named `UnderstandIntent`, `RetrieveContext`, `Plan`, `SelectTool`, `ExecuteTool`, `ObserveResult`, `Reflect`, `Respond`, `AskUser`, and `SaveMemory`.

Runtime phases and graph nodes write SwiftData checkpoints and trace events. `ContextBuilder` composes prompts from the user goal, conversation summary, memories, documents, tool results, graph state, and system rules with a simple context budget.

## Tools, Memory, Documents, Speech

Tools live in `monGARS/Tools` and are routed with simple intent heuristics. Tools declare a schema, risk level, approval requirement, and async execution method. Local tools include calculator, date/time, memory search/save/delete, document search/summarize, conversation search, diagnostics, and task create/update/complete. A remote/network tool stub exists but is blocked by approval and remote defaults.

Memory and document services are SwiftData-backed service structs. Memory supports importance scoring, deduplication, source tracking, search, edit, delete, export, and forget-all.

Speech is exposed through `SpeechService`; the current implementation requests Apple Speech authorization and reports denied/restricted/unavailable states cleanly.

## UI

`monGARS/Views` uses `NavigationSplitView` for a desktop-class iPad/iPhone layout:

- Chat with conversation list and streaming response updates.
- Expandable agent trace under assistant responses.
- Memory manager.
- Documents screen with file import and local keyword search.
- Goals screen with active/paused/completed/failed runs, tasks, pause/resume/stop, and approve/reject controls.
- Diagnostics screen showing provider status, graph steps, checkpoints, and tool calls.
- Settings screen for provider selection, provider capability flags, autonomy level, and remote endpoint controls.
