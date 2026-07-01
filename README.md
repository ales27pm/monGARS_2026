# monGARS

monGARS is a native SwiftUI iOS app for a privacy-first autonomous assistant. It uses local SwiftData storage, an `LLMProvider` abstraction, a LangGraph-style workflow layer, a working autonomous agent loop, LangChain-style tools, local memories, document import, speech-ready service boundaries, approval gates, goals/tasks, diagnostics, a scored tool-routing control plane, immutable approval tuples, and a repo self-model symbol graph.

## Requirements

- Xcode 26.x or newer recommended.
- iOS deployment target: 18.0.
- Foundation Models are used only when the SDK/runtime exposes the needed API. Unsupported runtimes return an honest unavailable error.
- MLX Local mode uses the checked-in MLX Swift LM packages for on-device local inference. First model load may download the configured Hugging Face model files and is blocked unless the Settings network toggle is enabled; after the model files are cached, inference can restart from the local Hugging Face cache.
- Command-line MLX builds require Xcode's Metal Toolchain component and trusted package macros. On fresh machines, run `xcodebuild -downloadComponent MetalToolchain`; non-interactive CI uses `ci_scripts/ci_post_clone.sh` to skip macro fingerprint prompts only when CI/Xcode Cloud environment variables are present.

## Run

Open `monGARS.xcodeproj` in Xcode and run the `monGARS` scheme on an iOS Simulator or device.

Command-line build:

```sh
xcodebuild build-for-testing -project monGARS.xcodeproj -scheme monGARS -destination 'id=<SIMULATOR_ID>' -skipMacroValidation
xcodebuild build -project monGARS.xcodeproj -scheme monGARS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -skipMacroValidation
xcodebuild archive -project monGARS.xcodeproj -scheme monGARS -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/monGARS-Unsigned.xcarchive CODE_SIGNING_ALLOWED=NO -skipMacroValidation
```

## Test

Compile app and unit tests:

```sh
xcodebuild build-for-testing -project monGARS.xcodeproj -scheme monGARS -destination 'id=<SIMULATOR_ID>' -skipMacroValidation
```

Run tests:

```sh
xcodebuild test-without-building -project monGARS.xcodeproj -scheme monGARS -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' CODE_SIGNING_ALLOWED=NO -skipMacroValidation
```

Current verification on this machine:

- App and test compilation succeeded with `build-for-testing` against the explicit `monGARS Test iPhone` simulator UDID. A shared `monGARS` scheme is checked in so Xcode no longer relies on auto-generated scheme settings for CLI builds.
- Generic iPhoneOS arm64 compilation succeeded with signing disabled, validating the iOS 18 device build path independently of simulator execution.
- Unsigned Release archive succeeded at `/tmp/monGARS-Unsigned.xcarchive`; the archive contains `monGARS.app`, dSYMs, bundle id `app.27pm.monGARS`, version `1.0`, and build `202606271944`.
- Current project build number in `CURRENT_PROJECT_VERSION` is `20260629050400`.
- Manual simulator launch succeeded on the `monGARS Test iPhone` iOS 26.3 simulator. The app shows a visible startup state, then transitions to Chat.
- Full simulator execution succeeded with `xcodebuild test-without-building` against `monGARS Test iPhone` after `build-for-testing`; 48 Swift Testing tests passed.

## Demo Flow

1. Open Settings and use Foundation Models on supported on-device runtimes, MLX Local with a configured Hugging Face model id, or configure an approved remote endpoint explicitly.
2. Keep `Enable network provider and tools` off unless testing remote/web behavior intentionally.
3. Import a UTF-8 text, Markdown, or selectable-text PDF document from Documents.
4. In Chat, ask: `summarize my imported document and remember the key points`.
5. Confirm the assistant summarizes imported document content, saves a durable memory, and shows agent trace rows under the assistant response.
6. Inspect, edit, export, delete, or forget memories from Memories.
7. For device-side QA without waiting on XCTest launch, open Settings > Developer and run `Run Real Tool E2E & Export Report`.

## Project Structure

- `monGARS/App`: app entrypoint, dependency container, settings, diagnostics.
- `monGARS/Models`: SwiftData models.
- `monGARS/Persistence`: persistence helpers and local error types.
- `monGARS/LLM`: provider protocol plus Foundation Models, MLX Local, and remote providers.
- `monGARS/Networking`: centralized URLSession client, retry/timeout policy, status/content-type validation, line streaming, and network configuration helpers.
- `monGARS/Security`: Keychain-backed secret storage plus immutable approval tuple hashing.
- `monGARS/SelfModel`: repo-aware symbol graph indexing and SwiftData persistence for the operational self-model.
- `monGARS/AgentGraph`: graph state, autonomous runtime, planner, executor, observer, reflector, context builder, checkpoints, resume support.
- `monGARS/Tools`: schema/risk-aware tool protocol, registry, scored router with abstention, local tools, native Apple permission tools, web/weather fetch, handoff tools, and approved generic HTTP.
- `monGARS/Memory`: scored, deduplicated, searchable, editable, exportable local memory service.
- `monGARS/Documents`: document import, PDFKit text extraction, chunking, and keyword retrieval.
- `monGARS/Speech`: speech service abstraction and Apple Speech permission implementation.
- `monGARS/Views`: compact/regular root navigation, chat, settings, memories, documents, goals/tasks, diagnostics.
- `Tests`: unit tests.

## Privacy Defaults

The default provider mode is Foundation Models. MLX Local is an explicit local provider choice. Its first model load is blocked unless the user enables the Settings network toggle, because Hugging Face model preparation can fetch files. Remote mode does not make provider network requests unless the user selects Remote Endpoint and enables the network toggle in Settings. Network-capable tools, including weather lookup, Maps search, web fetch, integrated web navigation, and generic remote HTTP, remain disabled unless the same Settings toggle is enabled, and still require approval before running. Localhost, `.local`, and private LAN hosts are blocked by the central `NetworkClient` unless Developer Mode is enabled in Settings. API keys are stored in Keychain, not UserDefaults.

If SwiftData cannot open durable storage after store quarantine/retry, monGARS renders a storage-unavailable screen and disables user workflows. It does not continue Chat, memory, document, goal, or tool actions against non-durable user data.

## Agentic Control Plane

The control plane now exposes three production-shaped primitives:

- `ToolRouter.routeDecision(input:)` returns a scored `ToolRouteDecision` with `tool`, `toolName`, confidence, risk level, approval requirement, anchored evidence, ambiguity detection, and confidence-based abstention. Target/action details are read from the selected tool’s metadata and folded into the anchored justification when available.
- `ApprovalTuple` and the expanded `ApprovalRequestRecord` persist `tool_name`, `target`, `normalized_arguments`, `payload_hash`, `risk_level`, `expires_at`, `session_id`, and `user_visible_diff`. Goals renders these tuple fields and blocks expired approvals from the UI.
- `RepoSelfModelService` builds and persists a hierarchical repo symbol graph with module/type/function/property nodes, commit hashes, file paths, line ranges, signatures, parent symbols, and privacy levels. The parser is deterministic and keeps a SwiftSyntax/SourceKit-ready seam for a future richer backend without changing the SwiftData records.

## Developer Real Tool E2E

Settings > Developer includes `Run Full Real Tool E2E & Export Report`. The button invokes production tool implementations directly without any LLM provider, using temporary `monGARS E2E` inputs where mutation is required. It covers every registered tool, approval rejection gates, network-off blocks, invalid input handling, local memory/documents/conversations/tasks, PDF document import/search, sandboxed files, handoffs, Apple permission-backed tools, network-gated tools, private-host policy, HTML/text/PDF extraction, diagnostics redaction, Keychain round trip, framework availability, SwiftData counts, and recent redacted diagnostics. It writes a text report under the app-owned `AgentFiles/Reports` directory and exposes it through the system share sheet. Reports produced anywhere except a physical iOS device include `Report acceptance: rejected` and a `physical_device_required` failure. It does not run XCTest inside the app; use non-launching `xcodebuild build-for-testing` for compiler proof when simulator launch is slow or intentionally skipped.

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
- Latest signed archive export/upload succeeded for build `20260629050400`; App Store Connect upload Delivery UUID `d2e0f7ca-abb1-445d-b617-466c286d6784`.
- Foundation Models are available only on supported SDK/runtime combinations; unsupported runtimes return an honest unavailable error.
- MLX Local requires the MLX Swift LM package graph, Xcode's Metal Toolchain, macro trust or `-skipMacroValidation`, enough device storage for model files, and a model id compatible with `LLMRegistry`.
- Document retrieval uses local hybrid lexical + NaturalLanguage contextual embedding ranking when Apple embedding assets are available on the device.
- Calendar and Reminder parsing is intentionally conservative. If EventKit access is denied or unavailable, the app returns a real permission/unavailable result instead of recording a local-only success.
- WeatherKit requires the Apple WeatherKit entitlement and valid provisioning on device. Without it, weather lookup uses the configured OpenWeather-compatible secondary provider and Keychain-stored API key.
- Web fetch extracts title, meta description, canonical URL, and readable text from HTML; plain text and JSON previews are bounded; PDF downloads use PDFKit text extraction when selectable text is present.
- Remote provider support covers OpenAI-compatible chat completions and Ollama generate/chat payloads. Other provider-specific schemas may require an adapter.
