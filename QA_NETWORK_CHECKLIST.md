# QA Network Checklist

Use a real device or simulator with network access. Start with `Enable network provider and tools` off.

## Privacy Gates

- With network off, ask Chat to fetch `https://example.com`. Expected: approval may be requested, but execution returns network disabled.
- Reject an approval for web fetch, weather, generic HTTP, SMS, phone, email, Calendar, Reminder, or Contacts. Expected: no real action executes.
- Enable network, approve `GET https://example.com` through the generic HTTP tool. Expected: response shows method, host, HTTP status, latency, and text preview.
- Try `POST https://example.com body {"hello":"world"}`. Expected: approval is required before execution.

## Remote LLM

- In Settings, select Remote Endpoint, enable network, set an Ollama `/api/generate` endpoint and model, then tap Test Remote Connection. Expected: success or an actionable provider/network error.
- Repeat with an OpenAI-compatible `/v1/chat/completions` endpoint and API key. Expected: bearer token is used, but the key is never displayed in diagnostics or logs.
- Use a streaming-capable endpoint in Chat. Expected: streamed chunks arrive through the same network policy and fail with clear HTTP/content-type errors if the endpoint is wrong.
- Disable network and test again. Expected: remote provider refuses to call the endpoint.

## Web And Weather

- Configure an OpenWeather-compatible endpoint and API key. Ask for weather in a real city. Expected: real summary with status and latency.
- Remove the weather API key. Expected: missing-key error, no request.
- Fetch an HTML page. Expected: readable text, no script/style noise.
- Fetch a PDF URL. Expected: PDF detected and reported; no fake text extraction.

## Apple Integrations

- Contacts lookup with permission denied. Expected: permission-denied result, no fake contacts.
- Calendar and Reminder creation with permission granted. Expected: real EventKit item exists in the system app.
- Calendar and Reminder creation with permission denied. Expected: honest unavailable/denied result, no local simulated success.
- SMS and phone requests. Expected: approved handoff opens system UI; monGARS does not auto-send or auto-call.
- Email request. Expected: Chat opens native Mail compose when Mail is configured; otherwise the fallback offers the system Mail URL handoff. monGARS does not auto-send.
- Maps request with network enabled. Expected: MapKit search runs, then approved Apple Maps handoff opens; no fake location is reported when search fails.

## Diagnostics

- Confirm Chat/Diagnostics show tool name, target, result status/status code, latency where available, approval status, and user-readable errors.
- Confirm secrets are not printed in tool results, diagnostics rows, or OSLog output.
