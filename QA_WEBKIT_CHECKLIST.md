# QA WebKit Checklist

- Settings > Network off, request `open webview https://example.com`. Expected: blocked before navigation.
- Settings > Network on, approve `open webview https://example.com`. Expected: in-app WebKit view opens with visible domain, current URL, loading progress, and retry control.
- Navigate to an invalid HTTPS host. Expected: error state is visible and retry does not crash.
- Try unsafe schemes such as `javascript:`, `file:`, or `ftp:`. Expected: tool rejects them; no WebKit navigation.
- Tap any external handoff control if present. Expected: user approval/intent is clear before leaving the app.
