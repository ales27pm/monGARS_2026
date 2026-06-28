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
- Provide an autonomous loop with `AgentRuntime`, `AgentLoop`, `AgentPlanner`, `AgentExecutor`, `AgentObserver`, and `AgentReflector`.
- Provide a LangChain-style tool layer with schema/risk metadata, approval gates, and working local date/time, calculator, memory, document, conversation, diagnostics, and task tools.
- Provide a local memory manager with save, search, deduplication, importance scoring, source tracking, edit, delete, export, and forget-all service support.
- Provide text and Markdown document import through the iOS file picker, local persistence, and keyword retrieval.
- Provide context engineering through `ContextBuilder` with templates, local context composition, budget handling, truncation, and conversation summarization.
- Provide a speech-ready abstraction using Apple Speech authorization with graceful unavailable/denied states.
- Provide SwiftUI screens for chat, conversations, settings, memories, documents, goals/tasks, and diagnostics.
- Provide unit tests covering memory search/deduplication, memory-save versus memory-lookup routing, document-summary routing, tool routing, graph checkpoints/resume, autonomous runtime, approval gates, network-disabled behavior, context budget handling, provider fallback, and persistence models.

## Privacy Objective

The default app path makes no developer-backend network call. Remote provider mode requires the user to select the remote provider and enable the network toggle in Settings. Network-capable tools also require the Settings network toggle plus explicit user approval before they can run.

## Current Verification Objective

The current verified checkpoint is generic iPhoneOS arm64 compilation and unsigned Release archive with signing disabled, clean app/test compilation with `xcodebuild build-for-testing` against the explicit `monGARS Test iPhone` simulator UDID, manual launch on that iOS 26.3 simulator, and focused simulator execution of the autonomous demo test. The app shows a startup state and transitions to Chat. Full simulator test execution remains pending because local CoreSimulator/Xcode test workers shut the simulator down during broader runs.
