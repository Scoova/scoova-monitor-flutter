# Changelog

## 1.4.0

Initial public release of the Scoova Monitor Flutter SDK.

- Crash reporting — `FlutterError`, isolate, and `PlatformDispatcher` errors
- Analytics events and screen tracking (navigator observer)
- Performance metrics — cold start and frame-rate sampling
- Battery monitoring
- Structured logging with tagged loggers
- Privacy: user IDs are SHA-256 hashed on-device before sending;
  no device location is collected
- GDPR / CCPA `clearLocalUserData()` helper
