# QA WeatherKit Checklist

- Confirm the app target has the WeatherKit capability and provisioning profile includes the entitlement if WeatherKit is intended for release.
- With Network off, approve `weather in Montreal`. Expected: blocked with network-disabled result.
- With Network on and WeatherKit entitlement active, approve `weather in Montreal`. Expected: real condition, temperature, humidity, wind, provider `WeatherKit`, and latency.
- Without WeatherKit entitlement but with OpenWeather-compatible endpoint/key configured, approve `weather in Montreal`. Expected: real secondary weather result with provider `OpenWeather-compatible`.
- Remove the secondary provider API key and retry on a build/device without WeatherKit entitlement. Expected: missing-key error, no invented weather.
- Test invalid location text. Expected: geocoding or service error that names the location.
