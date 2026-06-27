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

The app seeds one welcome conversation, one memory, and one document when the store is empty.

## LLM Providers

`monGARS/LLM` defines `LLMProvider` plus concrete providers.

- `FoundationModelProvider` imports FoundationModels behind `canImport` and uses `LanguageModelSession` only inside iOS 26 availability checks.
- `MockLLMProvider` is deterministic and local, suitable for demos, tests, and older runtimes.
- `RemoteLLMProvider` posts to an Ollama-style endpoint only when remote mode is explicitly enabled.

## Agent Graph

`monGARS/AgentGraph/AgentGraph.swift` implements a compact graph runtime:

- `route` decides whether a tool should handle the message.
- `tool` executes the selected tool.
- `retrieve` pulls local document snippets.
- `respond` streams mock/provider output or returns tool output.

Each node writes a SwiftData checkpoint and emits diagnostics events for the UI.

## Tools, Memory, Documents, Speech

Tools live in `monGARS/Tools` and are routed with simple intent heuristics. Memory and document services are small SwiftData-backed service structs. Speech is exposed through `SpeechService`; the current implementation requests Apple Speech authorization and reports denied/restricted/unavailable states cleanly.

## UI

`monGARS/Views` uses `NavigationSplitView` for a desktop-class iPad/iPhone layout:

- Chat with conversation list and streaming response updates.
- Memory manager.
- Documents screen with file import and local keyword search.
- Diagnostics screen showing provider status, graph steps, checkpoints, and tool calls.
- Settings screen for provider selection and remote endpoint controls.

