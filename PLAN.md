# PLAN

## Current Implementation Plan

1. Keep the first release local-first and reliable.
2. Treat Apple Foundation Models as the preferred local provider when iOS 26 runtime support is available.
3. Keep `MockLLMProvider` as the guaranteed build/test/demo provider.
4. Expand tool routing with explicit tests before adding more tools.
5. Keep the autonomous loop inspectable: every step writes trace, checkpoints, and tool-call evidence.
6. Keep network behavior opt-in and visible in Settings.
7. Add real streaming and transcription flows behind the existing provider/service protocols.

## Current Autonomous Flow

`AgentRuntime` runs: understand intent, retrieve context, plan, select tool, execute tool, observe, reflect, respond, and save memory. Risky tools create approval requests and stop the run until the user approves or rejects from Goals.

## Verification Plan

- Build the app with:

```sh
xcodebuild -project monGARS.xcodeproj -scheme monGARS -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

- Compile app and tests with:

```sh
xcodebuild build-for-testing -project monGARS.xcodeproj -scheme monGARS -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' CODE_SIGNING_ALLOWED=NO
```

- Run tests with:

```sh
xcodebuild test -project monGARS.xcodeproj -scheme monGARS -destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' CODE_SIGNING_ALLOWED=NO
```

On this machine, app and test compilation succeeded. Simulator boot/test execution stalls in CoreSimulator before test runner output; see README for the exact status.
