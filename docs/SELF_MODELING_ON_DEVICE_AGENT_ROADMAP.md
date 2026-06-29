# Self-Modeling On-Device Agent Roadmap

## Goal

Make monGARS able to maintain an explicit, local model of what it can do, what state it is in, what evidence supports that state, and what limits should shape the next agent run.

The self-model is not a personality layer. It is an inspectable runtime artifact that helps the agent answer questions like:

- Which provider is active, available, and allowed by Settings?
- Which tools are registered, gated, recently failing, or unavailable on this device?
- Which user memories, imported documents, tasks, and previous run outcomes are relevant to the current request?
- Which privacy, approval, network, storage, and physical-device constraints are currently active?
- Which claims can be supported by persisted evidence, and which claims must be phrased as unknown or unverified?

## Current Baseline

The repo already has the right building blocks:

- `AgentRuntime` persists `AgentRunRecord`, `AgentTraceRecord`, `ToolCallRecord`, and `AgentCheckpointRecord`.
- `AgentLoopState` captures the current phase, plan, selected tool, retrieved context, observations, reflection, and final response.
- `ContextBuilder` composes prompts from the goal, conversation summary, local memories, ranked documents, tool results, graph state, and phase rules.
- `ToolRegistry` exposes tool schemas, risk levels, approval requirements, and production executors.
- `MemoryService` stores deduplicated local memories with source, scope, importance, tags, edit, delete, export, and forget-all support.
- `DocumentService` chunks local documents and can use on-device NaturalLanguage contextual embeddings when available.
- `DeveloperDiagnosticsRunner` produces a redacted in-app report with provider, Settings, permission, SwiftData, tool E2E, network policy, Keychain, framework, and recent-diagnostics evidence.
- `DiagnosticsView` and `GoalsView` expose run traces, checkpoints, tool calls, active runs, tasks, and approvals to the user.

The missing layer is a first-class self-model that normalizes those surfaces into a durable, queryable, promptable snapshot with strict evidence rules.

## Design Principles

- Local first: build, store, retrieve, and display the self-model in SwiftData unless the user explicitly enables remote mode.
- Evidence bound: every self-claim that can affect behavior must point to current state, persisted records, diagnostics output, or an explicit unknown state.
- User inspectable: the user must be able to see and reset the self-model from Settings or Diagnostics.
- Privacy preserving: no hidden upload, no secret persistence in the self-model, and no contact/message/body leakage into diagnostics or memories.
- Permission honest: unavailable Foundation Models, denied Apple permissions, disabled network tools, and non-physical-device evidence must remain visible as constraints.
- Phase aware: the runtime should retrieve only the self-model slices relevant to the current phase instead of dumping an unbounded biography into every prompt.
- Degradable: the app should still answer without a complete self-model, but it must label missing evidence rather than inventing capability status.

## Target Self-Model Shape

Add a normalized local snapshot that can be rebuilt deterministically from app state:

- `SelfModelSnapshot`
  - build, app version, runtime platform, physical-device acceptance status
  - storage state and whether user workflows are allowed
  - selected provider, provider availability, streaming support, remote-network status
  - active privacy constraints: network toggle, Developer Mode, Apple integration toggles, approval policy
  - capability summary by tool name, risk, schema, network need, approval need, last known outcome, last error category
  - memory/document/task counts and freshness windows
  - recent run health: active, paused, waiting-for-approval, failed, completed, timed-out, cancelled
  - recent evidence pointers into trace, checkpoint, tool-call, approval, and diagnostics records
  - generated summary text safe for `ContextBuilder`

- `SelfModelEvidencePointer`
  - source type: run, trace, checkpoint, tool call, approval, diagnostic report, setting, permission, provider status, model availability
  - source id or stable label
  - created date
  - redacted summary
  - confidence: observed, inferred, stale, unavailable, unknown

Do not store raw secrets, message bodies from handoff tools, contact details, full prompts, or complete diagnostic reports in the self-model. Store bounded redacted summaries and pointers.

## Milestones

### M0 - Baseline Contract

Document and test what the app can already prove.

Deliverables:

- A self-model requirements document, this file.
- A small inventory test that asserts current model types include runs, traces, checkpoints, tool calls, approvals, tasks, memories, documents, and settings.
- A diagnostics test that verifies reports contain physical-device acceptance, provider status, Settings gates, tool coverage, SwiftData counts, and recent diagnostics without secrets.

Acceptance evidence:

- `xcodebuild build-for-testing` passes.
- Unit tests prove the current evidence surfaces exist and are redacted.
- The roadmap remains honest that no first-class self-model snapshot exists yet.

### M1 - Capability And Constraint Inventory

Create a deterministic builder that converts current app state into a self-model snapshot.

Implementation path:

- Add `SelfModelService` under a new `monGARS/SelfModel` module.
- Read from `AppContainer`, `SettingsStore`, `LLMProvider.status`, `ToolRegistry`, SwiftData counts, recent `AgentRunRecord`, recent `ToolCallRecord`, and platform/framework probes.
- Use `DiagnosticsRedactor` for every persisted or displayed text field.
- Keep provider and permission probes bounded and side-effect free.
- Add a `diagnostics` or `self_model` local tool action that returns a concise self-model summary.

Acceptance evidence:

- Tests build a snapshot in an in-memory container and assert provider, storage, tool registry, Settings, and SwiftData counts are represented.
- Tests prove disabled network tools and private-LAN policy appear as constraints.
- Tests prove secrets and message bodies are redacted from every text field.
- Diagnostics output includes a self-model section with snapshot freshness and source counts.

### M2 - Evidence-Aware Context Retrieval

Make `ContextBuilder` retrieve relevant self-model slices for each phase.

Implementation path:

- Add a `SelfModelContext` value with small phase-specific sections.
- Include capability and constraint summaries during `plan`, `selectTool`, `executeTool`, and `reflect`.
- Include recent failure patterns during `selectTool` and `executeTool`.
- Include run-state and approval constraints during `askUser`, pause, resume, and cancellation flows.
- Keep memory and document retrieval separate from self-model retrieval so user facts do not mix with capability claims.

Acceptance evidence:

- Tests prove execute-tool context includes selected tool schema, approval/network constraints, and relevant recent tool outcome, while excluding unrelated document bulk.
- Tests prove response context can cite unknown provider/tool availability as unknown instead of claiming success.
- Tests prove self-model context remains within budget and preserves final instructions during truncation.

### M3 - Reflection To Self-Model Updates

Let completed runs update the self-model with observed outcomes without turning every reflection into durable memory.

Implementation path:

- At terminal run states, summarize run outcome into redacted evidence pointers.
- Track tool health from `ToolCallRecord` outcome, latency, status code, target class, and error category.
- Track provider health from status checks, generation errors, streaming behavior, and unavailable states.
- Track recurring planner/routing issues only when backed by traces or tests.
- Keep user-facing memories in `MemoryRecord`; keep app-capability observations in self-model records.

Acceptance evidence:

- Tests prove a successful tool run updates tool health.
- Tests prove a failed or unavailable tool run updates the matching constraint without writing a user memory.
- Tests prove deleting or forgetting user memories does not erase app self-model health records, while resetting diagnostics can clear self-model health.

### M4 - User Inspection And Reset

Expose the self-model without creating a marketing or hidden automation surface.

Implementation path:

- Add a Diagnostics section showing current provider, storage, network/approval constraints, tool health, recent run health, and snapshot age.
- Add Settings controls to rebuild the self-model and clear self-model health history.
- Add export text alongside Developer diagnostics, with the same physical-device evidence acceptance rule.
- Keep any "why did the agent do this?" views tied to trace and tool-call evidence, not generated rationalization alone.

Acceptance evidence:

- UI state renders empty, stale, fresh, and reset states.
- Export is redacted and bounded.
- Non-physical-device exports are useful for debugging but marked as rejected for real on-device evidence.

### M5 - Planning Feedback Loop

Use the self-model to improve agent behavior while preserving explicit approval and privacy gates.

Implementation path:

- During planning, prefer available local tools over unavailable or recently failing paths.
- During tool selection, route around disabled network tools unless the user explicitly asks to enable or configure them.
- During response, explain unavailable capabilities with evidence-backed constraints.
- During save-memory, avoid saving self-diagnostics as user memories.
- During resume, load the last checkpoint plus the current self-model constraints so the resumed run does not ignore changed Settings or permissions.

Acceptance evidence:

- Tests prove disabled-network requests do not route into remote fetch execution.
- Tests prove a recently unavailable tool produces a constrained plan and an honest response.
- Tests prove approval-required tools still pause and resume through the existing approval flow.
- Tests prove resumed runs reconcile old checkpoints with current Settings constraints.

### M6 - On-Device Evaluation Loop

Close the roadmap with device-backed evidence rather than simulator-only confidence.

Implementation path:

- Extend `DeveloperDiagnosticsRunner` with a self-model probe suite.
- Add probes for snapshot creation, redaction, tool-health update, provider status, Settings constraints, physical-device acceptance, and reset/export.
- Keep XCTest/build verification separate from in-app diagnostics.
- Require physical-device report acceptance before treating self-model behavior as real on-device evidence.

Acceptance evidence:

- `build-for-testing` passes for app and tests.
- Full test run passes where simulator execution is stable.
- On a physical iOS device, Settings > Developer report includes a passing self-model section and `Report acceptance: accepted`.
- The exported report does not contain secrets, message bodies, contact details, private LAN targets beyond redacted class labels, or raw provider credentials.

## Verification Matrix

| Capability | Current proof source | Future proof source |
| --- | --- | --- |
| Runs and phase state | `AgentRunRecord`, `AgentLoopState`, checkpoints | Self-model run-health section with evidence pointers |
| Tool registry | `ToolRegistry.defaultRegistry` and tests | Snapshot capability inventory |
| Tool health | `ToolCallRecord` and diagnostics report | Snapshot tool-health rollups |
| Provider status | Settings provider status checks | Snapshot provider capability and last status evidence |
| Network/privacy gates | `SettingsStore`, `NetworkClient`, tool tests | Snapshot constraint inventory |
| User memory | `MemoryService`, `MemoryRecord` | Kept separate from self-model health records |
| Documents/RAG | `DocumentService`, chunks, embeddings status | Snapshot document capability and freshness summary |
| Approval flow | `ApprovalRequestRecord`, Goals UI, runtime tests | Snapshot active approval constraints |
| On-device acceptance | Developer diagnostics physical-device gate | Self-model diagnostics physical-device gate |

## Non-Goals

- Do not create a cloud identity or server-side profile for the agent.
- Do not store hidden chain-of-thought, raw provider prompts, or raw tool payloads.
- Do not bypass approval gates because the self-model says a tool is usually safe.
- Do not treat simulator diagnostics as accepted on-device evidence.
- Do not merge user memories with app self-diagnostics.
- Do not make remote provider calls just to refresh the self-model unless the user has explicitly enabled remote mode and requested the action.

## First Implementation Slice

The smallest useful implementation after this roadmap is:

1. Add `SelfModelService` with an in-memory `buildSnapshot(...)` API and pure data structs.
2. Feed it `SettingsStore`, `ToolRegistry`, provider status, storage state, SwiftData counts, and recent run/tool records.
3. Add tests for snapshot contents, redaction, disabled-network constraints, and no user-memory writes.
4. Add a Diagnostics report section that prints the snapshot summary.
5. Only after that, thread `SelfModelContext` into `ContextBuilder`.

This order keeps the self-model inspectable and testable before it starts influencing autonomous behavior.
