# Scoova Monitor — Flutter SDK

Crash reporting, analytics, performance, and battery monitoring for
Flutter 3.0+ apps on iOS and Android.

## Install

Add to `pubspec.yaml`:

```yaml
dependencies:
  scoova_monitor: ^1.4.0
```

Then:

```bash
flutter pub get
```

## Usage

Initialize before `runApp`:

```dart
import 'package:flutter/material.dart';
import 'package:scoova_monitor/scoova_monitor.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ScoovaMonitor.init('sm_your_api_key');
  runApp(const MyApp());
}
```

To capture zone errors as well, wrap `runApp` in `runZonedGuarded`:

```dart
import 'dart:async';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ScoovaMonitor.init('sm_your_api_key');

  runZonedGuarded(() {
    runApp(const MyApp());
  }, (error, stack) {
    // Already captured by ScoovaMonitor's PlatformDispatcher.onError hook,
    // but you can rethrow or log here if you want a second handler.
  });
}
```

## Configuration

```dart
await ScoovaMonitor.init(
  'sm_your_api_key',
  endpoint: 'https://monitor.scoo-va.info',   // self-hosted? change this
);
```

The Flutter SDK does not collect approximate location and does not probe
for third-party SDKs — see
[the documentation](https://monitor.scoo-va.info/docs) for
the full collection inventory.

## API

### Identify the user

```dart
ScoovaMonitor.setUserId('user_123');
```

The user ID is hashed before it leaves the device. Without `setUserId`
the SDK falls back to an anonymous installation ID.

### Track events

```dart
ScoovaMonitor.trackEvent('checkout_started', data: {
  'plan': 'annual',
  'amount': '29.99',
});
```

### Track screens

```dart
ScoovaMonitor.trackScreen('ProductDetail');
```

Or wire the navigator observer into your `MaterialApp` for automatic
screen tracking:

```dart
MaterialApp(
  navigatorObservers: [ScoovaMonitor.routeObserver],
  // …
)
```

### Capture errors

`FlutterError.onError`, isolate errors, and `PlatformDispatcher.onError`
are captured automatically.

For non-fatal errors:

```dart
try {
  await riskyWork();
} catch (e, stack) {
  ScoovaMonitor.captureError(e, stack);
}
```

### Breadcrumbs

```dart
ScoovaMonitor.addBreadcrumb('Started photo upload', 'media');
```

### Tagged loggers

```dart
final log = ScoovaMonitor.logger('payment');
log.info('Started checkout', data: {'amount': '29.99'});
log.error('Card declined', data: {'code': 'card_declined'});
```

### Right-to-erasure (GDPR / CCPA)

```dart
await ScoovaMonitor.clearLocalUserData();
```

Wipes the on-disk event/log/metric queues, the pending crash file,
breadcrumbs, the anonymous installation ID, the session counter, and the
user ID. Pair with a server-side `DELETE /v1/ingest/me/{userId}`.

### Manual flush

```dart
await ScoovaMonitor.flush();
```

The SDK auto-flushes every 5 minutes, on lifecycle pause, and when the
batch threshold is hit — manual flush is rarely needed.

## Symbolication

The SDK captures **Dart** errors, so their stack traces are already
readable in the dashboard — **unless** you ship a release built with
`--obfuscate`, which scrambles the symbols.

If you obfuscate, build with `--split-debug-info` so Flutter writes the
per-ABI `*.symbols` files, then upload them. The dashboard de-obfuscates
incoming crash traces for that app version automatically.

```bash
# build with obfuscation — Flutter writes app.<platform>-<arch>.symbols
flutter build appbundle --obfuscate --split-debug-info=build/symbols

# upload the symbols (the script ships in this repo, under scripts/)
node scripts/scoova-upload-flutter-symbols.js \
    --api-key sm_your_api_key \
    --version 1.4.0 \
    --build 42 \
    --dir build/symbols
```

Run the upload step right after each release build (wire it into your CI
or release script). It needs Node on the build machine. If you don't use
`--obfuscate`, you can skip this entirely.

## License

[Apache 2.0](LICENSE).
