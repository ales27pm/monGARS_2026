# monGARS

monGARS is a native SwiftUI iOS app for a privacy-first autonomous assistant. It uses local SwiftData storage, an `LLMProvider` abstraction, a LangGraph-style workflow layer, a working autonomous agent loop, LangChain-style tools, local memories, document import, speech-ready service boundaries, approval gates, goals/tasks, and diagnostics.

## Requirements

- Xcode 26.x or newer recommended.
- iOS deployment target: 18.0.
- Foundation Models are used only when the SDK/runtime exposes the needed API. The deterministic mock provider keeps the app buildable and functional elsewhere.

## Run

Open `monGARS.xcodeproj` in Xcode and run the `monGARS` scheme on an iOS Simulator or device.

Command-line build:

```sh
xcodebuild -project monGARS.xcodeproj -scheme monGARS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## Test

Compile app and unit tests:

```sh
xcodebuild build-for-testing -project monGARS.xcodeproj -scheme monGARS -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' CODE_SIGNING_ALLOWED=NO
```

Run tests:

```sh
xcodebuild test -project monGARS.xcodeproj -scheme monGARS -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' CODE_SIGNING_ALLOWED=NO
```

Current verification on this machine:

- App build succeeded for generic iOS Simulator.
- Test build succeeded for generic iOS Simulator.
- Actual simulator boot/test execution still stalls at CoreSimulator "Waiting on System App", so the verified checkpoint is app/test compilation rather than completed runtime execution.

## Project Structure

- `monGARS/App`: app entrypoint, dependency container, settings, diagnostics.
- `monGARS/Models`: SwiftData models.
- `monGARS/Persistence`: persistence helpers and local error types.
- `monGARS/LLM`: provider protocol and Foundation/mock/remote providers.
- `monGARS/AgentGraph`: graph state, autonomous runtime, planner, executor, observer, reflector, context builder, checkpoints, resume support.
- `monGARS/Tools`: schema/risk-aware tool protocol, registry, router, calculator, date/time, memory tools, document tools, conversation search, diagnostics, tasks, disabled remote stub.
- `monGARS/Memory`: scored, deduplicated, searchable, editable, exportable local memory service.
- `monGARS/Documents`: document import and keyword retrieval.
- `monGARS/Speech`: speech service abstraction and Apple Speech permission implementation.
- `monGARS/Views`: compact/regular root navigation, chat, settings, memories, documents, goals/tasks, diagnostics.
- `Tests`: unit tests.

## Privacy Defaults

The default provider mode is Foundation Models with local mock fallback. Remote mode does not make network requests unless the user selects Remote Endpoint and enables the network toggle in Settings.

## Autonomous Agent Loop

Chat requests now run through `AgentRuntime`:

1. understand intent
2. retrieve local context
3. plan
4. select and execute tools
5. observe results
6. reflect
7. respond
8. save durable memory when requested

Every run persists an `AgentRunRecord`, trace events, tool calls, and checkpoints. Risky/destructive/external actions create approval requests visible in Goals.
