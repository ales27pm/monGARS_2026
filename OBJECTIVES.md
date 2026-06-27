# OBJECTIVES

monGARS is a native SwiftUI iOS assistant prototype with production-shaped boundaries and working local behavior.

## Completed Objective

- Provide a privacy-first assistant that stores conversations, memories, document records, graph checkpoints, and settings locally.
- Use SwiftData for persistence.
- Use an `LLMProvider` abstraction with:
  - `FoundationModelProvider` for Apple Foundation Models when the current SDK/runtime supports it.
  - `MockLLMProvider` as the deterministic local fallback.
  - `RemoteLLMProvider` for user-configured endpoints, disabled unless the user explicitly enables it.
- Provide a LangGraph-inspired orchestration layer with `AgentState`, `AgentNode`, `AgentGraph`, conditional edges, checkpoint persistence, resume support, and partial response events.
- Provide a LangChain-style tool layer with working date/time, calculator, memory lookup, and document summary tools.
- Provide a local memory manager with save, search, and delete.
- Provide text and Markdown document import through the iOS file picker, local persistence, and keyword retrieval.
- Provide a speech-ready abstraction using Apple Speech authorization with graceful unavailable/denied states.
- Provide SwiftUI screens for chat, conversations, settings, memories, documents, and diagnostics.
- Provide unit tests covering memory search, tool routing, graph checkpoints/resume, and persistence models.

## Privacy Objective

The default app path makes no developer-backend network call. Remote provider mode requires the user to select the remote provider and enable the network toggle in Settings.

