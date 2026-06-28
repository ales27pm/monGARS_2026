# QA MapKit Checklist

- With Network off, approve `map nearest coffee shop`. Expected: blocked with network-disabled result.
- With Network on, approve `map nearest coffee shop`. Expected: `MKLocalSearch` result when available, place name/address/coordinate-derived Apple Maps handoff.
- Search for a nonsense query. Expected: no-results or MapKit error plus honest Apple Maps search URL, no fake result.
- Open the prepared Apple Maps handoff. Expected: Apple Maps receives the same reviewed target.
