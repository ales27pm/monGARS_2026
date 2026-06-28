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
xcodebuild build-for-testing -project monGARS.xcodeproj -scheme monGARS -destination 'id=<SIMULATOR_ID>'
xcodebuild build -project monGARS.xcodeproj -scheme monGARS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild archive -project monGARS.xcodeproj -scheme monGARS -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/monGARS-Unsigned.xcarchive CODE_SIGNING_ALLOWED=NO
```

## Test

Compile app and unit tests:

```sh
xcodebuild build-for-testing -project monGARS.xcodeproj -scheme monGARS -destination 'id=<SIMULATOR_ID>'
```

Run tests:

```sh
xcodebuild test -project monGARS.xcodeproj -scheme monGARS -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' CODE_SIGNING_ALLOWED=NO
```

Current verification on this machine:

- App and test compilation succeeded with `build-for-testing` against the explicit `monGARS Test iPhone` simulator UDID. A shared `monGARS` scheme is checked in so Xcode no longer relies on auto-generated scheme settings for CLI builds.
- Generic iPhoneOS arm64 compilation succeeded with signing disabled, validating the iOS 18 device build path independently of simulator execution.
- Unsigned Release archive succeeded at `/tmp/monGARS-Unsigned.xcarchive`; the archive contains `monGARS.app`, dSYMs, bundle id `app.27pm.monGARS`, version `1.0`, and build `202606271944`.
- Manual simulator launch succeeded on the `monGARS Test iPhone` iOS 26.3 simulator. The app shows a visible startup state, then transitions to Chat.
- Focused simulator execution of `autonomousRuntimeCompletesAndPersistsTrace` succeeded with `xcodebuild test-without-building`, proving the core document-summary plus memory-save runtime path in XCTest.
- Full and multi-test simulator execution remain unreliable on this machine: after long waits, CoreSimulator shuts the device down and Xcode reports `** BUILD INTERRUPTED **`. A fresh iOS 18.6 simulator also stalled during first-boot LaunchServices migration.

## Demo Flow

1. Open Settings and use `Mock Local` or Foundation Models with mock fallback for local-only behavior.
2. Keep `Enable network provider and tools` off unless testing remote/web behavior intentionally.
3. Import a UTF-8 text or Markdown document from Documents.
4. In Chat, ask: `summarize my imported document and remember the key points`.
5. Confirm the assistant summarizes imported document content, saves a durable memory, and shows agent trace rows under the assistant response.
6. Inspect, edit, export, delete, or forget memories from Memories.

## Project Structure

- `monGARS/App`: app entrypoint, dependency container, settings, diagnostics.
- `monGARS/Models`: SwiftData models.
- `monGARS/Persistence`: persistence helpers and local error types.
- `monGARS/LLM`: provider protocol and Foundation/mock/remote providers.
- `monGARS/Networking`: centralized URLSession client, retry/timeout policy, status/content-type validation, line streaming, and network configuration helpers.
- `monGARS/Security`: Keychain-backed secret storage.
- `monGARS/AgentGraph`: graph state, autonomous runtime, planner, executor, observer, reflector, context builder, checkpoints, resume support.
- `monGARS/Tools`: schema/risk-aware tool protocol, registry, router, local tools, native Apple permission tools, web/weather fetch, handoff tools, and approved generic HTTP.
- `monGARS/Memory`: scored, deduplicated, searchable, editable, exportable local memory service.
- `monGARS/Documents`: document import and keyword retrieval.
- `monGARS/Speech`: speech service abstraction and Apple Speech permission implementation.
- `monGARS/Views`: compact/regular root navigation, chat, settings, memories, documents, goals/tasks, diagnostics.
- `Tests`: unit tests.

## Privacy Defaults

The default provider mode is Foundation Models with local fallback. Remote mode does not make provider network requests unless the user selects Remote Endpoint and enables the network toggle in Settings. Network-capable tools, including weather lookup, Maps search, web fetch, integrated web navigation, and generic remote HTTP, remain disabled unless the same Settings toggle is enabled, and still require approval before running. API keys are stored in Keychain, not UserDefaults.

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

## Remaining Limitations

- Full XCTest execution currently passes on the `monGARS Test iPhone` simulator when run without rebuilding after `build-for-testing`.
- Signed archive export/upload succeeded for build `202606272226`; App Store Connect upload Delivery UUID `e7e929d4-aa14-4d3a-b3b2-4317c7f6c49b`.
- Foundation Models are available only on supported SDK/runtime combinations; older iOS 18 runtimes use the deterministic local fallback.
- Document retrieval is lexical today. The Core ML embedding provider reports unavailable until a `DocumentEmbedding` model is bundled and wired.
- Calendar and Reminder parsing is intentionally conservative. If EventKit access is denied or unavailable, the app returns a real permission/unavailable result instead of recording a simulated success.
- Web fetch extracts text from HTML/plain text/JSON. PDF downloads are detected and reported, but PDF text extraction is not implemented in this build.
- Remote provider support covers OpenAI-compatible chat completions and Ollama generate/chat payloads. Other provider-specific schemas may require an adapter.
