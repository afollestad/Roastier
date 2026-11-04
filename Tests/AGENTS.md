## Tests

These instructions cover unit tests under `Tests/`.

- Use Swift Testing (`@Test`, `#expect`), not XCTest.
- Use the fakes in `Tests/CaffeinateKitTests/Fakes.swift` and `Tests/CaffeinateKitTests/Updates/UpdateFakes.swift`, and a throwaway `UserDefaults(suiteName:)`; never create real power assertions or login items, or reach the network.
- Await `AwakeController.expiryTask` instead of sleeping to observe expiry, using `FakeClock.sleep(for:)`; a sleep that leaves the clock still never expires.
