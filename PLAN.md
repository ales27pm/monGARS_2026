# PLAN

## Current Implementation Plan

1. Keep the first release local-first and reliable.
2. Treat Apple Foundation Models as the preferred local provider when iOS 26 runtime support is available.
3. Keep `MockLLMProvider` as the guaranteed build/test/demo provider.
4. Expand tool routing with explicit tests before adding more tools.
5. Keep the autonomous loop inspectable: every step writes trace, checkpoints, and tool-call evidence.
6. Keep provider and tool network behavior opt-in and visible in Settings, with localhost/private LAN blocked unless Developer Mode is explicitly enabled.
7. Keep Developer diagnostics available in-app as no-mock real-tool E2E probes plus redacted report export, separate from XCTest/build validation.
8. Add real streaming and transcription flows behind the existing provider/service protocols.
9. Keep Remote LLM paused for this native-tools pass; do not expand provider schemas until requested.

## Current Autonomous Flow

`AgentRuntime` runs: understand intent, retrieve context, plan, select tool, execute tool, observe, reflect, respond, and save memory. Risky tools create approval requests and stop the run until the user approves or rejects from Goals.

The demo request `summarize my imported document and remember the key points` is expected to route to `document_summary`, respond using imported document content, and save a durable memory during the save-memory phase.

## Verification Plan

- Build the app with:

```sh
xcodebuild build -project monGARS.xcodeproj -scheme monGARS -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
xcodebuild archive -project monGARS.xcodeproj -scheme monGARS -configuration Release -destination 'generic/platform=iOS' -archivePath /tmp/monGARS-Unsigned.xcarchive CODE_SIGNING_ALLOWED=NO
```

- Compile app and tests with:

```sh
xcodebuild build-for-testing -project monGARS.xcodeproj -scheme monGARS -destination 'id=<SIMULATOR_ID>'
```

- Run tests with:

```sh
xcodebuild test -project monGARS.xcodeproj -scheme monGARS -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' CODE_SIGNING_ALLOWED=NO
```

On this machine, `build-for-testing` and `test-without-building` succeeded against the explicit `monGARS Test iPhone` simulator. The latest full simulator run passed 48 Swift Testing tests after the native-tools pass.

For slow or intentionally skipped simulator launch cycles, use Settings > Developer > `Run Full Real Tool E2E & Export Report` on-device or in an already-running app. This invokes production tool implementations directly without `MockLLMProvider`, honors the network toggle, verifies every registered tool has a probe, and reports approval rejection gates, network-off gates, private-host policy, extraction/import checks, Keychain, framework availability, permissions, SwiftData counts, and recent diagnostics. It is complementary evidence, not a replacement for non-launching `xcodebuild` compilation.

## Current Known Gaps

- Previous signed archive export/upload succeeded for build `202606272226`; App Store Connect upload Delivery UUID `e7e929d4-aa14-4d3a-b3b2-4317c7f6c49b`. The current project build number is `202606280033`, so that upload is historical evidence rather than a current-build upload.
- Document summarization is deterministic and based on imported text excerpts, not semantic embeddings.
- Network-capable tools remain disabled until Settings enables network provider and tools, even after approval.
- WeatherKit still requires the Apple entitlement/provisioning path on device; otherwise weather uses the configured OpenWeather-compatible fallback.
