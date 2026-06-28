# QA Native iOS Tools Checklist

Use a real device for permission and handoff checks where possible. Keep Settings > Network off for the first pass.

## Developer Full Real Tool E2E Report

- Open Settings > Developer and tap `Run Full Real Tool E2E & Export Report`. Expected: report is generated under app-owned `AgentFiles/Reports`, can be shared, and includes app/build metadata, network policy, Keychain, framework availability, permission states, SwiftData counts, recent diagnostics, and direct production-tool E2E probes.
- Inspect Real Tool E2E. Expected: `Tool coverage: 24/24 registry tools`, no `Missing registry tool probes`, and no `FAIL` lines.
- Confirm negative-path probes are present. Expected: approval rejection, network-off blocks, invalid input handling, unsafe web scheme block, private-host block, and diagnostics redaction self-check are all `PASS`.
- Confirm local extraction/import probes are present. Expected: HTML extraction, plain text/JSON preview, PDFKit extraction, and PDF document import/search are all `PASS`.
- Inspect the report. Expected: no API keys, tokens, email addresses, phone numbers, SMS/email bodies, or contact dumps appear in clear text.
- Confirm the report states that no `MockLLMProvider` is used and that in-app E2E is not XCTest execution. Expected: Xcode build/test evidence remains separate.

## Privacy Gates

- With Network off, run weather, maps, web fetch, webview, and remote HTTP requests. Expected: blocked result with a clear network-disabled message and no request.
- Reject approval for SMS, phone, email, calendar, reminders, contacts, maps, webview, web fetch, and local file write/delete. Expected: no execution and no persisted tool call.
- Approve each tool once. Expected: the result records tool name, target/provider where applicable, approval state, status/latency when available, and clear failure category on errors.

## Apple Integrations

- SMS with a valid phone number. Expected: Messages handoff is prepared only; no send occurs.
- Phone with a valid phone number. Expected: `tel://` handoff is prepared only; no call occurs until the system UI confirms.
- Email with Mail configured. Expected: native compose sheet opens; fallback is `mailto:` when Mail cannot send.
- Calendar event creation after granting access. Expected: EventKit creates a real event.
- Reminder creation after granting access. Expected: EventKit creates a real reminder.
- Contacts search after granting access. Expected: limited fields for matching contacts only, no full dump.

## Files

- List, write, read, and delete a file in `AgentFiles`. Expected: all operations remain inside app Application Support.
- Try `../escape.txt` and nested paths. Expected: rejected filename, no outside file write.
