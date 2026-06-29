# QA Network Checklist

Use a real device or simulator with network access. Start with `Enable network provider and tools` off.

## Privacy Gates

- With network off, ask Chat to fetch `https://example.com`. Expected: approval may be requested, but execution returns network disabled.
- Reject an approval for web fetch, weather, generic HTTP, SMS, phone, email, Calendar, Reminder, or Contacts. Expected: no real action executes.
- Enable network, approve `GET https://example.com` through the generic HTTP tool. Expected: response shows method, host, HTTP status, latency, and text preview.
- Try `POST https://example.com body {"hello":"world"}`. Expected: approval is required before execution.

## Remote LLM

- Remote LLM is paused for the native-tools pass. Do not add provider schemas while validating native tools.
- If existing Remote Endpoint mode is selected manually, disable network and test again. Expected: remote provider refuses to call the endpoint.

## Web And Weather

- Configure WeatherKit entitlement or an OpenWeather-compatible endpoint and API key. Ask for weather in a real city. Expected: real summary with provider and latency.
- Remove the weather API key on a build/device without WeatherKit entitlement. Expected: missing-key error, no invented weather.
- Fetch an HTML page. Expected: title, meta description/canonical URL when present, readable text, no script/style noise.
- Fetch a PDF URL with selectable text. Expected: PDFKit returns page-numbered text preview.

## Apple Integrations

- Contacts lookup with permission denied. Expected: permission-denied result, no invented contacts.
- Calendar and Reminder creation with permission granted. Expected: real EventKit item exists in the system app.
- Calendar and Reminder creation with permission denied. Expected: honest unavailable/denied result, no local-only success.
- SMS and phone requests. Expected: approved handoff opens system UI; monGARS does not auto-send or auto-call.
- Email request. Expected: Chat opens native Mail compose when Mail is configured; otherwise the handoff offers the system Mail URL handoff. monGARS does not auto-send.
- Maps request with network enabled. Expected: MapKit search runs, then approved Apple Maps handoff opens; no invented location is reported when search fails.

## Diagnostics

- Confirm Chat/Diagnostics show tool name, target, result status/status code, latency where available, approval status, and user-readable errors.
- Confirm secrets are not printed in tool results, diagnostics rows, or OSLog output.
