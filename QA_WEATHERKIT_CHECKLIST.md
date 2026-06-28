# QA WeatherKit Checklist

- Confirm the app target has the WeatherKit capability and provisioning profile includes the entitlement if WeatherKit is intended for release.
- With Network off, approve `weather in Montreal`. Expected: blocked with network-disabled result.
- With Network on and WeatherKit entitlement active, approve `weather in Montreal`. Expected: real condition, temperature, humidity, wind, provider `WeatherKit`, and latency.
- Without WeatherKit entitlement but with OpenWeather-compatible endpoint/key configured, approve `weather in Montreal`. Expected: real fallback weather result with provider `OpenWeather-compatible`.
- Remove the fallback API key and retry on a build/device without WeatherKit entitlement. Expected: missing-key error, no fake weather.
- Test invalid location text. Expected: geocoding or service error that names the location.
