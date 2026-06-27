# monGARS

monGARS is a native SwiftUI iOS app for a privacy-first AI assistant. It uses local SwiftData storage, an `LLMProvider` abstraction, a small LangGraph-style agent runtime, LangChain-style tools, local memories, document import, speech-ready service boundaries, and diagnostics.

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
- Test build succeeded on an isolated `monGARS Test iPhone` simulator.
- Actual simulator test execution stalled in Xcode before the test runner emitted output, so the verified checkpoint is test compilation rather than completed runtime execution.

## Project Structure

- `monGARS/App`: app entrypoint, dependency container, settings, diagnostics.
- `monGARS/Models`: SwiftData models.
- `monGARS/Persistence`: persistence helpers and local error types.
- `monGARS/LLM`: provider protocol and Foundation/mock/remote providers.
- `monGARS/AgentGraph`: graph state, nodes, edges, checkpoints, resume support.
- `monGARS/Tools`: tool protocol, registry, router, date/time, calculator, memory lookup, document summary.
- `monGARS/Memory`: memory service.
- `monGARS/Documents`: document import and keyword retrieval.
- `monGARS/Speech`: speech service abstraction and Apple Speech permission implementation.
- `monGARS/Views`: chat, conversations, settings, memories, documents, diagnostics.
- `Tests`: unit tests.

## Privacy Defaults

The default provider mode is Foundation Models with local mock fallback. Remote mode does not make network requests unless the user selects Remote Endpoint and enables the network toggle in Settings.

