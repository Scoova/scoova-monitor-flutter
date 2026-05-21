# Changelog

All notable changes to this SDK are documented here. This package follows
[Semantic Versioning](https://semver.org/) and the
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## 1.5.0 — 2026-05-21

### Added
- **Continuous battery sampling** — periodic 60s emit of `battery/level` and
  `battery/is_charging` performance metrics. Matches iOS/Android
  BatteryTracker behaviour.
- **Rooted / jailbroken detection** via file-existence probes (no new
  permissions). Mirrors the Android + iOS native SDKs.
- **Screen resolution + orientation** captured via
  `PlatformDispatcher.views.first.physicalSize`.
- **Free disk space** on Android via `df -P` on the documents directory.
- **Install date** persisted to a SharedPreferences-equivalent file on
  first init; mirrors iOS UserDefaults + Android
  `firstInstallTime`.
- `trackCustomMetric(name, value, unit:)` public API — parity with iOS,
  Android, React Native, and Web SDKs.

### Changed
- SDK version reported as `1.5.0` in every event payload.

## 1.4.0

Initial public release.
