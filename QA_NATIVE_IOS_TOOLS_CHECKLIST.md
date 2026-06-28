# QA Native iOS Tools Checklist

Use a real device for permission and handoff checks where possible. Keep Settings > Network off for the first pass.

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
