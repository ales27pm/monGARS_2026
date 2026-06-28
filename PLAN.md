# PLAN

## Current Implementation Plan

1. Keep the first release local-first and reliable.
2. Treat Apple Foundation Models as the preferred local provider when iOS 26 runtime support is available.
3. Keep `MockLLMProvider` as the guaranteed build/test/demo provider.
4. Expand tool routing with explicit tests before adding more tools.
5. Keep the autonomous loop inspectable: every step writes trace, checkpoints, and tool-call evidence.
6. Keep provider and tool network behavior opt-in and visible in Settings.
7. Add real streaming and transcription flows behind the existing provider/service protocols.

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

On this machine, the generic iPhoneOS arm64 build and unsigned Release archive succeeded with signing disabled, and app/test compilation succeeded against the explicit `monGARS Test iPhone` simulator UDID after adding a shared Xcode scheme. Manual simulator launch reached the Chat screen. Focused simulator execution of the autonomous demo test succeeded. Full and multi-test simulator execution remain unstable because CoreSimulator shuts the device down and Xcode reports `** BUILD INTERRUPTED **`; see README for the exact status.

## Current Known Gaps

- Full XCTest execution needs a healthier CoreSimulator/Xcode test-runner path; focused simulator tests can pass.
- Signed archive export/upload succeeded for build `202606272226`; App Store Connect upload Delivery UUID `e7e929d4-aa14-4d3a-b3b2-4317c7f6c49b`.
- Document summarization is deterministic and based on imported text excerpts, not semantic embeddings.
- Network-capable tools remain disabled until Settings enables network provider and tools, even after approval.
