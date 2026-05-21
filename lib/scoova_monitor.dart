/// Scoova Monitor SDK for Flutter
///
/// Usage:
/// ```dart
/// void main() {
///   ScoovaMonitor.init('sm_your_api_key');
///   runApp(MyApp());
/// }
/// ```
library scoova_monitor;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show FrameTiming;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:battery_plus/battery_plus.dart';

const _sdkVersion = '1.5.1';
const _httpTimeout = Duration(seconds: 10);
const _flushInterval = Duration(minutes: 5); // radio-friendly default; flush is also triggered by batch size, AppLifecycleState.paused, and crashes (which use a separate immediate path)
const _batchSize = 50;
const _maxQueueSize = 1000;
const _failureBackoffThreshold = 3;

class ScoovaMonitor {
  static String _apiKey = '';
  static String _bundleId = '';
  static String _endpoint = 'https://monitor.scoo-va.info';
  static bool _initialized = false;
  static String? _userId;
  // Anonymous installation ID — persists across app launches, resets on
  // uninstall. Used as the default user_id so DAU/MAU/retention work even
  // when the host never calls setUserId. "" until _resolveAnonId() returns.
  static String _anonId = '';
  static String _sessionId = '';
  // Monotonic session counter — 1st, 2nd, 3rd launch ever. Persisted to a file
  // alongside the anon ID. Stamped on every event so the server can compute
  // session frequency, retention buckets, etc.
  static int _sessionNumber = 0;
  static final _DiskQueue _eventQueue = _DiskQueue('events');
  static final _DiskQueue _logQueue = _DiskQueue('logs');
  static final _DiskQueue _metricQueue = _DiskQueue('metrics');
  static final List<Map<String, String>> _breadcrumbs = [];
  // ignore: unused_field
  static Timer? _flushTimer; // retained to keep periodic timer alive
  static Map<String, dynamic>? _deviceInfo;
  static int _consecutiveFailures = 0;
  static bool _flushing = false;

  // Captured at the very top of init() so trackAppStart can measure
  // SDK-init-to-first-frame as a real duration. The previous bug sent
  // DateTime.now().millisecondsSinceEpoch.toDouble() which is the
  // absolute Unix epoch (~1.78 trillion ms) instead of a duration.
  static final Stopwatch _initStopwatch = Stopwatch();

  /// Initialize the SDK. Call as early as possible.
  static Future<void> init(String apiKey, {String? endpoint}) async {
    if (_initialized) return;
    if (!_initStopwatch.isRunning) _initStopwatch.start();
    _apiKey = apiKey;
    if (endpoint != null) _endpoint = endpoint;
    _initialized = true;
    _sessionId = _uuid();

    // Resolve / generate the anonymous installation ID so every event has a
    // non-null user_id even if the host never calls setUserId.
    _anonId = await _resolveAnonId();
    _sessionNumber = await _incrementAndPersistSessionNumber();

    // Collect device info + bundle ID
    final pkgInfo = await PackageInfo.fromPlatform();
    _bundleId = pkgInfo.packageName;
    _deviceInfo = await _collectDevice();

    // Flutter error handler
    FlutterError.onError = (details) {
      _reportCrash(
        details.exceptionAsString(),
        details.stack?.toString() ?? '',
        true,
      );
    };

    // Isolate errors
    Isolate.current.addErrorListener(RawReceivePort((pair) {
      final error = pair[0];
      final stack = pair[1];
      _reportCrash(error.toString(), stack?.toString() ?? '', true);
    }).sendPort);

    // Zone errors (wrap runApp)
    PlatformDispatcher.instance.onError = (error, stack) {
      _reportCrash(error.toString(), stack.toString(), true);
      return true;
    };

    // Lifecycle observer
    WidgetsBinding.instance.addObserver(_LifecycleObserver());

    // Track startup once the first frame has rendered. Uses the
    // _initStopwatch captured at the top of init() — measures
    // SDK-init-to-first-frame, not absolute epoch time. This is the
    // closest we can get to "real cold start" without a method-channel
    // trip to native Process.getStartUptimeMillis.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ms = _initStopwatch.elapsedMilliseconds.toDouble();
      _initStopwatch.stop();
      // Floor at 1ms so a 0-ms first frame doesn't get treated as a
      // missing data point on the dashboard's percentile chart.
      trackMetric('app_start', 'cold_start',
          ms < 1 ? 1.0 : ms, 'ms');
    });

    // Periodic flush — drains disk-queued items including any leftover from prior session
    _flushTimer = Timer.periodic(_flushInterval, (_) => flush());

    // Send pending crash, if any
    _sendPendingCrashes();

    // Continuous frame_rate sampling. WidgetsBinding hands us
    // FrameTimings (build + raster duration) for every rendered frame.
    // We accumulate over a 5s window and emit fps + dropped_frames_percent
    // as performance_metrics — same shape Android's AutoTracker uses.
    _startFrameRateSampling();

    // ANR / main-isolate hang detector — a watchdog isolate observes
    // heartbeats from the main isolate. If a pulse is missed for >5s the
    // watchdog POSTs an ANR row directly to /v1/ingest/crashes, since the
    // main isolate is by definition unable to do that work itself.
    // Skipped in debug because debugger pauses look identical to hangs.
    if (!kDebugMode) {
      unawaited(_startHangWatchdog());
    }

    // Continuous battery sampling — matches iOS/Android BatteryTracker.
    // Polls every 60s and stamps battery_level + is_charging as
    // performance metrics so the dashboard can chart drain over a session.
    _startBatterySampling();

    trackEvent('session_start', data: {'session_id': _sessionId});
    debugPrint('[ScoovaMonitor] Flutter SDK $_sdkVersion initialized');

    // Kick off an immediate flush so any events left over from the previous
    // session (failed POSTs persisted to disk) make it to the server.
    unawaited(flush());

    // The Flutter SDK does not auto-detect install attribution — pure
    // Dart can't read the Play Install Referrer or the Apple AdServices
    // token. Rather than fabricate a source, we report nothing: the
    // install honestly buckets as "direct" until the host calls
    // setInstallSource() with data from its own attribution wiring.
  }

  /// Report install attribution for this install.
  ///
  /// The Flutter SDK can't auto-detect the install source from pure
  /// Dart, so this is a manual hook. Call it once, early, with data
  /// from your own attribution wiring — e.g. the `play_install_referrer`
  /// package on Android or `AAAttribution` (AdServices) on iOS. [source]
  /// is a short channel name ("google_ads", "facebook", "organic", ...);
  /// [campaign] is optional. If you never call it the install reports no
  /// source and buckets as "direct" in the dashboard.
  static void setInstallSource(String source, {String? campaign}) {
    if (!_initialized || source.isEmpty) return;
    trackEvent('install_info', data: {
      'install_source': source,
      'install_campaign': campaign ?? '',
      'session_number': _sessionNumber.toString(),
    });
  }

  /// Track a custom event
  static void trackEvent(String name, {Map<String, String>? data}) {
    if (!_initialized) return;
    final item = {
      'eventName': name,
      'eventData': _PrivacyGuard.sanitizeData(data),
      'userId': _PrivacyGuard.hashUserId(_userId),
      'sessionId': _sessionId,
      if (_sessionNumber > 0) 'sessionNumber': _sessionNumber,
      'device': _deviceInfo,
      'timestamp': DateTime.now().toIso8601String(),
    };
    unawaited(_eventQueue.append(jsonEncode(item)));
    _eventQueue.markAdded();
    if (_eventQueue.appendCount >= _batchSize) {
      _eventQueue.appendCount = 0;
      unawaited(flush());
    }
  }

  /// Set user ID (hashed before sending).
  ///
  /// Side-effect: when an anonymous install identifies for the first
  /// time, fire one /v1/ingest/identify so the server merges the anon
  /// profile into the real one. Without this, the same human shows up
  /// as two rows in user_profiles (anon + real) and gets counted twice
  /// in DAU/MAU/cohort retention. Best-effort and idempotent.
  static void setUserId(String userId) {
    final previous = _userId;
    _userId = userId;
    if (userId.isEmpty) return;
    if (_anonId.isEmpty) return;
    final hashed = _PrivacyGuard.hashUserId(userId);
    if (_lastIdentifiedAs == hashed) return;
    if (previous == userId && _identifySent) return;
    unawaited(_fireIdentify(_anonId, hashed));
  }

  static bool _identifySent = false;
  static String? _lastIdentifiedAs;

  static Future<void> _fireIdentify(String anonId, String hashedUserId) async {
    try {
      final resp = await http.post(
        Uri.parse('$_endpoint/v1/ingest/identify'),
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': _apiKey,
          'X-Bundle-Id': _bundleId,
        },
        body: '{"anonId":"$anonId","userId":"$hashedUserId"}',
      ).timeout(const Duration(seconds: 5));
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        _identifySent = true;
        _lastIdentifiedAs = hashedUserId;
      }
    } catch (_) { /* best-effort */ }
  }

  /// Get a tagged logger
  static ScoovaLogger logger(String tag) => ScoovaLogger._(tag);

  /// Log with level and tag
  static void log(String tag, String level, String message,
      {Map<String, String>? data}) {
    if (!_initialized) return;
    final item = {
      'level': level,
      'tag': tag,
      'message': _PrivacyGuard.sanitizeMessage(message),
      'data': _PrivacyGuard.sanitizeData(data),
      'userId': _PrivacyGuard.hashUserId(_userId),
      'sessionId': _sessionId,
      'timestamp': DateTime.now().toIso8601String(),
    };
    unawaited(_logQueue.append(jsonEncode(item)));
    _logQueue.markAdded();
    addBreadcrumb('[$level] [$tag] $message', 'log');
    if (_logQueue.appendCount >= _batchSize) {
      _logQueue.appendCount = 0;
      unawaited(flush());
    }
  }

  /// Track a screen view
  static void trackScreen(String name) {
    trackEvent('screen_view', data: {'screen_name': name});
    addBreadcrumb('Screen: $name', 'navigation');
  }

  /// `NavigatorObserver` for automatic screen tracking. Add to
  /// `MaterialApp.navigatorObservers` so route pushes/pops emit
  /// `screen_view` events without per-screen calls:
  ///
  /// ```dart
  /// MaterialApp(
  ///   navigatorObservers: [ScoovaMonitor.routeObserver],
  ///   ...
  /// )
  /// ```
  ///
  /// Names come from the route's `settings.name` (set when you call
  /// `Navigator.pushNamed` or use a named-routes table). Unnamed routes
  /// fall back to the runtime type of the route's content widget.
  static final NavigatorObserver routeObserver = _ScoovaRouteObserver();

  // ───────── Frame rate sampling ─────────

  static int _frameWindowFrames = 0;
  static int _frameWindowJanky = 0; // frames slower than 16.67ms (60fps target)
  static DateTime? _frameWindowStart;
  static const Duration _frameWindowDuration = Duration(seconds: 5);

  static void _startFrameRateSampling() {
    _frameWindowStart = DateTime.now();
    WidgetsBinding.instance.addTimingsCallback(_onFrameTimings);
  }

  /// Receives FrameTiming for each rendered frame. Computes a 5s
  /// rolling window so the metric fires often enough to populate the
  /// dashboard while staying cheap. Auto-paused when the engine isn't
  /// rendering (background) — `addTimingsCallback` simply doesn't fire.
  static void _onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _frameWindowFrames++;
      // Total frame budget on a 60Hz screen is ~16.67ms. Anything over
      // 17ms is a "jank" frame. We don't try to detect 120Hz here —
      // ProMotion devices that consistently hit 120 will just look like
      // "no janks", which is the right call for a coarse signal.
      final totalUs = t.totalSpan.inMicroseconds;
      if (totalUs > 17000) _frameWindowJanky++;
    }

    final now = DateTime.now();
    final start = _frameWindowStart ?? now;
    if (now.difference(start) < _frameWindowDuration) return;

    final elapsedSec = now.difference(start).inMilliseconds / 1000.0;
    if (_frameWindowFrames > 0 && elapsedSec > 0) {
      final fps = _frameWindowFrames / elapsedSec;
      final droppedPct = _frameWindowFrames > 0
          ? (_frameWindowJanky * 100.0 / _frameWindowFrames)
          : 0.0;
      // Floor to 60fps target — a 120Hz device hitting full refresh
      // would otherwise ship 120fps and confuse the dashboard's
      // "<60fps means jank" baseline. We can ungate this once the
      // dashboard shows target fps explicitly.
      trackMetric('frame_rate', 'fps', fps.clamp(0, 120).toDouble(), 'fps');
      trackMetric('frame_rate', 'dropped_frames_percent',
                  droppedPct.clamp(0, 100).toDouble(), 'percent');
    }
    _frameWindowFrames = 0;
    _frameWindowJanky = 0;
    _frameWindowStart = now;
  }

  /// Capture a non-fatal error
  static void captureError(dynamic error, StackTrace? stack) {
    _reportCrash(error.toString(), stack?.toString() ?? '', false);
  }

  // ─── ANR Watchdog ───
  static SendPort? _hangWatchdogPort;
  // ignore: unused_field
  static Timer? _heartbeatTimer; // retained to keep periodic timer alive

  static Future<void> _startHangWatchdog() async {
    final mainPort = ReceivePort();
    try {
      await Isolate.spawn(_hangWatchdogEntrypoint, {
        'mainPort': mainPort.sendPort,
        'apiKey': _apiKey,
        'endpoint': _endpoint,
        'sessionId': _sessionId,
        'userId': _PrivacyGuard.hashUserId(_userId ?? _anonId),
        'sdkVersion': _sdkVersion,
        'thresholdMs': 5000,
      });
    } catch (_) {
      mainPort.close();
      return;
    }
    _hangWatchdogPort = await mainPort.first as SendPort;
    // 1s pulse — gives 5s threshold a comfortable 5x margin so brief jank
    // doesn't false-positive.
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _hangWatchdogPort?.send('pulse');
    });
  }

  static void _hangWatchdogEntrypoint(Map<String, dynamic> cfg) {
    final mainPort = cfg['mainPort'] as SendPort;
    final apiKey = cfg['apiKey'] as String;
    final endpoint = cfg['endpoint'] as String;
    final sessionId = cfg['sessionId'] as String;
    final userId = cfg['userId'] as String;
    final sdkVersion = cfg['sdkVersion'] as String;
    final thresholdMs = cfg['thresholdMs'] as int;

    final inbox = ReceivePort();
    mainPort.send(inbox.sendPort);

    var lastPulse = DateTime.now();
    var inCooldown = false;
    inbox.listen((_) {
      lastPulse = DateTime.now();
      inCooldown = false;
    });

    Timer.periodic(const Duration(seconds: 1), (_) async {
      if (inCooldown) return;
      final gapMs = DateTime.now().difference(lastPulse).inMilliseconds;
      if (gapMs < thresholdMs) return;

      inCooldown = true; // 30s cooldown — matches Android ANR detector
      Timer(const Duration(seconds: 30), () => inCooldown = false);

      final payload = {
        'exceptionType': 'ANR (Main Isolate Hang)',
        'message': 'Flutter main isolate blocked for >${gapMs}ms',
        'stackTrace': '(Flutter watchdog runs in a background isolate and '
            'cannot reach across the isolate boundary to dump the main '
            'stack. Check device logcat / Console.app around this timestamp '
            'for the symbolicated trace.)',
        'isFatal': false,
        'sessionId': sessionId,
        'userId': userId,
        'sdkVersion': sdkVersion,
        'timestamp': DateTime.now().toIso8601String(),
      };
      try {
        await http
            .post(
              Uri.parse('$endpoint/v1/ingest/crashes'),
              headers: {
                'Content-Type': 'application/json',
                'X-API-Key': apiKey,
                'X-Bundle-Id': _bundleId,
              },
              body: jsonEncode(payload),
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        /* watchdog has no disk-replay path; the next hang will retry */
      }
    });
  }

  /// Add breadcrumb
  static void addBreadcrumb(String message, String category) {
    if (_breadcrumbs.length >= 50) _breadcrumbs.removeAt(0);
    _breadcrumbs.add({
      'message': message,
      'category': category,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  static Timer? _batterySampleTimer;

  static void _startBatterySampling() {
    if (_batterySampleTimer != null) return;
    final battery = Battery();
    Future<void> sample() async {
      try {
        final lvl = await battery.batteryLevel;
        if (lvl >= 0) {
          trackMetric('battery', 'level', lvl.toDouble(), 'percent');
        }
        final state = await battery.batteryState;
        final charging = state == BatteryState.charging || state == BatteryState.full;
        trackMetric('battery', 'is_charging', charging ? 1.0 : 0.0, 'bool');
      } catch (_) { /* never let the sampler crash the app */ }
    }
    unawaited(sample());
    _batterySampleTimer = Timer.periodic(const Duration(seconds: 60), (_) => sample());
  }

  /// Track a custom metric — arbitrary name + numeric value + unit.
  /// Mirrors iOS + Android + React Native `trackCustomMetric` so a Flutter
  /// app can emit the same metric stream native apps do.
  static void trackCustomMetric(String name, double value, {String unit = 'count'}) {
    if (!_initialized) return;
    trackMetric('custom', name, value, unit);
  }

  /// Track performance metric
  static void trackMetric(String type, String name, double value, String unit) {
    if (!_initialized && type != 'app_start') return;
    final item = {
      'metricType': type,
      'metricName': name,
      'value': value,
      'unit': unit,
      'sessionId': _sessionId,
      'timestamp': DateTime.now().toIso8601String(),
      // Distinguishes Flutter cold-start (~700ms) from native iOS/
      // Android (~200-400ms) so the dashboard can keep baselines
      // comparable.
      'framework': 'flutter',
      // Same device shape as trackEvent so the dashboard's per-(osName,
      // framework) breakdown can bucket Flutter-on-iOS vs Flutter-on-
      // Android correctly. If the full device collection hasn't finished
      // yet (rare race when app_start fires faster than PackageInfo /
      // device_info_plus resolves), fall back to the platform name —
      // we always know whether we're on iOS / Android even when the
      // detailed collection is still pending.
      'device': (_deviceInfo != null && _deviceInfo!.isNotEmpty)
          ? _deviceInfo
          : {'osName': Platform.isIOS ? 'iOS' : Platform.isAndroid ? 'Android' : 'unknown'},
    };
    unawaited(_metricQueue.append(jsonEncode(item)));
    _metricQueue.markAdded();
    if (_metricQueue.appendCount >= _batchSize) {
      _metricQueue.appendCount = 0;
      unawaited(flush());
    }
  }

  /// Flush all queued data. Items that fail to POST are left on disk
  /// for the next attempt. Idempotent if invoked while a flush is in progress.
  static Future<void> flush() async {
    if (!_initialized || _flushing) return;
    // Global backoff: if the network has been failing repeatedly, skip this
    // flush cycle so we don't hammer the server with retries.
    if (_consecutiveFailures >= _failureBackoffThreshold) {
      // Allow one probe per cycle to detect recovery.
      _consecutiveFailures--;
      return;
    }
    _flushing = true;
    try {
      await _flushOne(_eventQueue, '/v1/ingest/events/batch', 'events');
      await _flushOne(_logQueue, '/v1/ingest/logs/batch', 'logs');
      await _flushOne(_metricQueue, '/v1/ingest/metrics/batch', 'metrics');
    } finally {
      _flushing = false;
    }
  }

  /// Wipe every piece of telemetry the SDK has buffered or persisted on this
  /// device. Call this when the host app's user invokes "delete my account" —
  /// pairs with the server-side `DELETE /v1/ingest/me/{userId}` to satisfy
  /// GDPR Article 17 / CCPA "right to be forgotten" end-to-end.
  ///
  /// What this clears:
  ///   - the on-disk event / metric / log queues
  ///   - the pending crash file (if any)
  ///   - breadcrumbs accumulated this session
  ///   - the anonymous installation ID (a fresh one is generated immediately)
  ///   - the persisted session counter
  ///   - the user_id set via setUserId()
  ///
  /// Does NOT contact the server. The host app should also call your server's
  /// GDPR delete endpoint with the user_id you previously sent.
  static Future<void> clearLocalUserData() async {
    if (!_initialized) return;
    // Best-effort wipe — never throw and block the host's delete-account flow.
    try { await _eventQueue.clear(); } catch (_) {}
    try { await _logQueue.clear(); } catch (_) {}
    try { await _metricQueue.clear(); } catch (_) {}
    try {
      final dir = await getApplicationDocumentsDirectory();
      final crash = File('${dir.path}/scoova_pending_crash.json');
      if (await crash.exists()) await crash.delete();
      final anon = File('${dir.path}/scoova_anon_id');
      if (await anon.exists()) await anon.delete();
      final session = File('${dir.path}/scoova_session_number');
      if (await session.exists()) await session.delete();
    } catch (_) {}
    _userId = null;
    _breadcrumbs.clear();
    // Regenerate a fresh anon ID immediately so subsequent events still have
    // a non-null user_id. Persisted on next call to _resolveAnonId path.
    _anonId = 'anon_${_uuid()}';
    _sessionNumber = 0;
    debugPrint('[ScoovaMonitor] Local user data cleared');
  }

  // ─── Private ───

  static Future<void> _flushOne(
      _DiskQueue q, String path, String wrapKey) async {
    final batch = await q.take(_batchSize);
    if (batch.isEmpty) return;
    final items = <Map<String, dynamic>>[];
    for (final s in batch) {
      try {
        items.add(jsonDecode(s) as Map<String, dynamic>);
      } catch (_) {
        // skip malformed line
      }
    }
    if (items.isEmpty) return;
    try {
      final ok = await _post(path, {wrapKey: items});
      if (ok) {
        _consecutiveFailures = 0;
      } else {
        // Re-queue for next attempt
        await q.appendAll(batch);
        _consecutiveFailures++;
      }
    } catch (_) {
      await q.appendAll(batch);
      _consecutiveFailures++;
    }
  }

  static void _reportCrash(String error, String stackTrace, bool isFatal) {
    final crumbs = _breadcrumbs.isNotEmpty
        ? '\n\n--- Breadcrumbs ---\n${_breadcrumbs.map((b) => '[${b['timestamp']}] [${b['category']}] ${b['message']}').join('\n')}'
        : '';

    final payload = {
      'exceptionType': error.split(':').first.trim(),
      'message': _PrivacyGuard.sanitizeMessage(error),
      'stackTrace': _PrivacyGuard.sanitizeStackTrace('$stackTrace$crumbs'),
      'isFatal': isFatal,
      'device': _deviceInfo,
      'userId': _PrivacyGuard.hashUserId(_userId),
      'sessionId': _sessionId,
      'timestamp': DateTime.now().toIso8601String(),
    };

    // Save FIRST, post second. Two reasons:
    //   1. _post is async; the previous code returned before the post
    //      completed, and if the app exited (XCUITest tear-down,
    //      activity destroy, etc.) the request was dropped — handled
    //      crashes silently never reached the server.
    //   2. With save-first, even if the post completes successfully we
    //      delete the disk copy in the success branch. Failure / kill
    //      leaves the file for next-launch flush via _sendPendingCrashes.
    unawaited(_savePendingCrash(payload).then((_) async {
      try {
        final ok = await _post('/v1/ingest/crashes', payload);
        if (ok) {
          // Posted successfully — clear the disk copy so we don't
          // re-send the same crash on next launch.
          try {
            final dir = await getApplicationDocumentsDirectory();
            final file = File('${dir.path}/scoova_pending_crash.json');
            if (await file.exists()) await file.delete();
          } catch (_) { /* best-effort */ }
        }
      } catch (_) { /* leave on disk for next-launch flush */ }
    }));
  }

  static Future<void> _savePendingCrash(Map<String, dynamic> payload) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/scoova_pending_crash.json');
      await file.writeAsString(jsonEncode(payload));
    } catch (_) {}
  }

  static Future<void> _sendPendingCrashes() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/scoova_pending_crash.json');
      if (await file.exists()) {
        final json = await file.readAsString();
        final ok = await _post('/v1/ingest/crashes', jsonDecode(json));
        if (ok) await file.delete();
      }
    } catch (_) {}
  }

  /// Resolve / generate the anonymous installation ID. Persisted in a small
  /// file under the app's documents directory so it survives app launches but
  /// resets on uninstall (which is the correct behaviour — uninstall = new
  /// install = new anonymous user, matching how Apple/Google reset advertising
  /// IDs).
  static Future<String> _resolveAnonId() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/scoova_anon_id');
      if (await file.exists()) {
        final existing = (await file.readAsString()).trim();
        if (existing.startsWith('anon_')) return existing;
      }
      final fresh = 'anon_${_uuid()}';
      await file.writeAsString(fresh);
      return fresh;
    } catch (_) {
      // No filesystem access — fall back to a per-launch UUID. Counts as a
      // new user per session, but at least DAU isn't zero.
      return 'anon_${_uuid()}';
    }
  }

  /// Read the persisted session counter, increment it, write it back, and
  /// return the new value. Best-effort: if filesystem access fails we just
  /// return 1 so events still carry a usable sessionNumber.
  static Future<int> _incrementAndPersistSessionNumber() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/scoova_session_number');
      var n = 0;
      if (await file.exists()) {
        n = int.tryParse((await file.readAsString()).trim()) ?? 0;
      }
      n += 1;
      await file.writeAsString(n.toString());
      return n;
    } catch (_) {
      return 1;
    }
  }

  static Future<Map<String, dynamic>> _collectDevice() async {
    final deviceInfo = DeviceInfoPlugin();
    final packageInfo = await PackageInfo.fromPlatform();

    String manufacturer = 'Unknown', model = 'Unknown', osVersion = '';
    int? osApiLevel;
    String? cpuArch;
    int? totalRam, freeRam;

    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      manufacturer = info.manufacturer;
      model = info.model;
      osVersion = info.version.release;
      osApiLevel = info.version.sdkInt;
      cpuArch = info.supportedAbis.isNotEmpty ? info.supportedAbis.first : null;
    } else if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;
      manufacturer = 'Apple';
      model = info.utsname.machine;
      osVersion = info.systemVersion;
      cpuArch = info.utsname.machine.startsWith('arm64') ? 'arm64' : null;
    }

    // Rooted / jailbroken — check for known marker paths. Mirrors the
    // Android + iOS native SDK detection. No permissions required, just
    // existence checks. Returns false if every probe is clean.
    bool? jailbroken;
    try {
      final probes = Platform.isAndroid
          ? const [
              '/system/app/Superuser.apk', '/sbin/su', '/system/bin/su',
              '/system/xbin/su', '/data/local/xbin/su', '/data/local/bin/su',
            ]
          : Platform.isIOS
              ? const [
                  '/Applications/Cydia.app',
                  '/Library/MobileSubstrate/MobileSubstrate.dylib',
                  '/bin/bash', '/usr/sbin/sshd', '/etc/apt',
                  '/private/var/lib/apt/',
                ]
              : const <String>[];
      jailbroken = probes.any((p) => File(p).existsSync());
    } catch (_) {
      jailbroken = null;
    }

    // Screen resolution + orientation — pulled from the platform dispatcher.
    // Works pre-runApp() because we run after WidgetsFlutterBinding.ensureInitialized().
    String? screenResolution;
    String? orientation;
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final size = view.physicalSize;
      screenResolution = '${size.width.toInt()}x${size.height.toInt()}';
      orientation = size.height >= size.width ? 'portrait' : 'landscape';
    } catch (_) {}

    // Free disk — Android can read /data partition stats, iOS via the
    // documents directory's free-size attribute. Best-effort, no
    // permissions.
    int? freeDisk;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final stat = await dir.stat();
      // Dart doesn't expose a portable disk-free; the stat type only
      // gives file size. We use Process on Android for a quick read.
      if (Platform.isAndroid) {
        final r = await Process.run('df', ['-P', dir.path]);
        if (r.exitCode == 0) {
          final lines = (r.stdout as String).split('\n');
          if (lines.length > 1) {
            final cols = lines[1].split(RegExp(r'\s+'));
            if (cols.length >= 4) {
              final freeKb = int.tryParse(cols[3]);
              if (freeKb != null) freeDisk = freeKb * 1024;
            }
          }
        }
      }
      // Suppress unused warning for non-Android.
      stat.size;
    } catch (_) {}

    // Thermal state — read via WidgetsBinding.instance.platformDispatcher.
    // PlatformDispatcher doesn't expose it; we ship null for now and let
    // the host pass it via setCustomMetric if they wire native-side.
    // (Same posture as our Android SDK's permissionless behaviour.)

    // First-launch flag + install-date — persisted alongside the anon ID.
    final installDateMs = await _ensureInstallDate();

    // Best-effort total/free RAM via /proc/meminfo on Android, ProcessInfo on iOS.
    // Both are optional — wrapped in try/catch so SDK never throws on fetch.
    try {
      if (Platform.isAndroid) {
        final mem = await File('/proc/meminfo').readAsString();
        final totalKb = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(mem)?.group(1);
        final freeKb = RegExp(r'MemAvailable:\s+(\d+)\s+kB').firstMatch(mem)?.group(1);
        if (totalKb != null) totalRam = int.parse(totalKb) * 1024;
        if (freeKb != null) freeRam = int.parse(freeKb) * 1024;
      }
    } catch (_) {}

    // Network type via connectivity_plus
    String? networkType;
    String? networkGen;
    try {
      // connectivity_plus 6.x returns List<ConnectivityResult>
      final List<ConnectivityResult> conn = await Connectivity().checkConnectivity();
      final first = conn.isNotEmpty ? conn.first : ConnectivityResult.none;
      switch (first) {
        case ConnectivityResult.wifi:        networkType = 'wifi'; break;
        case ConnectivityResult.ethernet:    networkType = 'ethernet'; break;
        case ConnectivityResult.mobile:      networkType = 'cellular'; networkGen = '4G'; break;
        case ConnectivityResult.bluetooth:   networkType = 'bluetooth'; break;
        case ConnectivityResult.vpn:         networkType = 'vpn'; break;
        case ConnectivityResult.none:        networkType = 'none'; break;
        default: networkType = 'unknown';
      }
    } catch (_) {}

    // Battery level + charging via battery_plus
    int? batteryLevelPct;
    bool? isCharging;
    try {
      final battery = Battery();
      batteryLevelPct = await battery.batteryLevel;
      final state = await battery.batteryState;
      isCharging = state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {}

    final localeStr = Platform.localeName;
    final country = localeStr.contains('_') ? localeStr.split('_').last : null;
    final timezone = DateTime.now().timeZoneName;

    final m = <String, dynamic>{
      'manufacturer': manufacturer,
      'model': model,
      'osName': Platform.isAndroid ? 'Android' : 'iOS',
      'osVersion': osVersion,
      'appVersion': packageInfo.version,
      'buildNumber': packageInfo.buildNumber,
      'locale': localeStr,
      'framework': 'flutter',
      'sdkVersion': _sdkVersion,
    };
    if (osApiLevel != null) m['osApiLevel'] = osApiLevel;
    if (cpuArch != null) m['cpuArch'] = cpuArch;
    if (country != null && country.isNotEmpty) m['country'] = country;
    if (timezone.isNotEmpty) m['timezone'] = timezone;
    if (networkType != null) m['networkType'] = networkType;
    if (networkGen != null) m['networkGeneration'] = networkGen;
    if (totalRam != null) m['ramTotal'] = totalRam; // bytes — Long? server-side
    if (freeRam != null) m['ramFree'] = freeRam;
    if (batteryLevelPct != null) m['batteryLevel'] = batteryLevelPct.toDouble() / 100.0; // 0.0–1.0
    if (isCharging != null) m['isCharging'] = isCharging;
    if (jailbroken != null) m['jailbroken'] = jailbroken;
    if (screenResolution != null) m['screenResolution'] = screenResolution;
    if (orientation != null) m['orientation'] = orientation;
    if (freeDisk != null) m['diskFree'] = freeDisk;
    m['installDate'] = installDateMs;
    return m;
  }

  /// First-run timestamp persisted alongside the anonymous ID. Returned in
  /// ms-since-epoch so it matches Android's getPackageInfo().firstInstallTime
  /// and iOS's getInstallDate().
  static Future<int> _ensureInstallDate() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/scoova_install_date');
      if (await file.exists()) {
        final raw = await file.readAsString();
        final n = int.tryParse(raw.trim());
        if (n != null) return n;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      await file.writeAsString(now.toString());
      return now;
    } catch (_) {
      return DateTime.now().millisecondsSinceEpoch;
    }
  }

  /// Returns true on 2xx, false otherwise. Throws on network error.
  static Future<bool> _post(String path, dynamic body) async {
    try {
      final resp = await http.post(
        Uri.parse('$_endpoint$path'),
        headers: {
          'Content-Type': 'application/json',
          'X-API-Key': _apiKey,
          'X-Bundle-Id': _bundleId,
        },
        body: jsonEncode(body),
      ).timeout(_httpTimeout);
      if (resp.statusCode >= 200 && resp.statusCode < 300) return true;
      // Treat 4xx as permanent failure (drop) — re-queueing won't help.
      // Treat 5xx as transient — caller will re-queue.
      if (resp.statusCode >= 400 && resp.statusCode < 500) {
        debugPrint(
            '[ScoovaMonitor] POST $path 4xx (dropped): ${resp.statusCode}');
        return true; // pretend success so caller drops
      }
      debugPrint(
          '[ScoovaMonitor] POST $path failed: ${resp.statusCode}');
      return false;
    } on TimeoutException {
      debugPrint('[ScoovaMonitor] POST $path timed out');
      return false;
    } catch (e) {
      debugPrint('[ScoovaMonitor] POST $path error: $e');
      return false;
    }
  }

  static String _uuid() => '${_hex(8)}-${_hex(4)}-4${_hex(3)}-${_hex(4)}-${_hex(12)}';
  static String _hex(int len) {
    final r = List.generate(
        len, (_) => (DateTime.now().microsecond % 16).toRadixString(16));
    return r.join();
  }
}

// ─── PrivacyGuard ─── parity with Android/iOS PrivacyGuard
class _PrivacyGuard {
  static const _hashPrefix = 'h_';

  static final _emailRe =
      RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}');
  static final _phoneRe = RegExp(r'\+?[0-9]{7,15}');
  static final _ipRe = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}\b');
  static final _jwtRe = RegExp(r'eyJ[a-zA-Z0-9_-]{10,}\.[a-zA-Z0-9_-]{10,}');
  static final _uuidRe = RegExp(
      r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}');
  static final _ccRe = RegExp(r'\b(?:\d{4}[- ]?){3}\d{4}\b');

  static const _piiKeys = [
    'email', 'mail', 'phone', 'tel', 'mobile', 'name', 'username',
    'user_name', 'first_name', 'last_name', 'address', 'ssn', 'password',
    'token', 'secret', 'api_key', 'credit_card', 'card_number',
  ];
  // Keys whose substring would otherwise hit _piiKeys but which are clearly
  // safe (e.g. "screen_name" matches "name" but is just a route label, not
  // user data). Treat as exact-match exemptions before substring scanning.
  static const _piiKeyAllowlist = [
    'screen_name', 'previous_screen', 'screen', 'route', 'route_name',
    'next_screen', 'event_name', 'tag_name', 'class_name', 'package_name',
    'session_id', 'session_number', 'view_name',
  ];

  /// Returns the user_id we stamp on each event. If the host called
  /// setUserId, returns the SHA256-hashed value (h_<hash>). Otherwise
  /// returns the anonymous installation ID (anon_<uuid>) so DAU/MAU and
  /// retention always have something distinct to count.
  static String hashUserId(String? id) {
    if (id != null && id.isNotEmpty) return _hashPrefix + _sha256(id);
    return ScoovaMonitor._anonId;
  }

  static String sanitizeMessage(String message) {
    var s = message;
    s = s.replaceAllMapped(
        _emailRe, (m) => '[hashed_email:${_sha256(m.group(0)!).substring(0, 8)}]');
    s = s.replaceAll(_ccRe, '[redacted_card]');
    s = s.replaceAll(_jwtRe, '[hashed_token]');
    return s;
  }

  static String sanitizeStackTrace(String trace) {
    var s = trace;
    s = s.replaceAll(RegExp(r'/Users/[^/]+/'), '/Users/****/');
    s = s.replaceAll(RegExp(r'/home/[^/]+/'), '/home/****/');
    s = s.replaceAllMapped(
        _emailRe, (m) => _hashPrefix + _sha256(m.group(0)!).substring(0, 12));
    s = s.replaceAllMapped(
        _ipRe, (m) => _hashPrefix + _sha256(m.group(0)!).substring(0, 8));
    s = s.replaceAll(_jwtRe, '[hashed_token]');
    return s;
  }

  static Map<String, String>? sanitizeData(Map<String, String>? data) {
    if (data == null) return null;
    return data.map((k, v) => MapEntry(k, _sanitizeValue(k, v)));
  }

  static String _sanitizeValue(String key, String value) {
    final keyLower = key.toLowerCase();
    if (_piiKeyAllowlist.contains(keyLower)) {
      return value;
    }
    if (_piiKeys.any((p) => keyLower.contains(p))) {
      return _hashPrefix + _sha256(value).substring(0, 16);
    }
    if (_emailRe.hasMatch(value)) {
      return _hashPrefix + _sha256(value).substring(0, 16);
    }
    if (_ccRe.hasMatch(value)) {
      return '[redacted]';
    }
    if (_jwtRe.hasMatch(value)) {
      return _hashPrefix + _sha256(value).substring(0, 16);
    }
    if (_uuidRe.hasMatch(value)) {
      return _hashPrefix + _sha256(value).substring(0, 16);
    }
    final trimmed = value.trim();
    if (trimmed.length >= 7 && trimmed.length <= 16 &&
        _phoneRe.hasMatch(trimmed) &&
        RegExp(r'^[\+\d\s\-\.]+$').hasMatch(trimmed)) {
      return _hashPrefix + _sha256(value).substring(0, 16);
    }
    return value;
  }

  static String _sha256(String input) {
    return sha256.convert(utf8.encode(input)).toString();
  }
}

// ─── Disk-backed queue ─── parity with Android/iOS DiskQueue
class _DiskQueue {
  final String name;
  final int maxSize = _maxQueueSize;
  File? _cachedFile;
  // Counter the SDK uses to know when to auto-flush at batchSize.
  // It's intentionally a separate counter (not a queue size) — we don't pay
  // for an async size() check on every append.
  int appendCount = 0;

  // Serialization chain: every mutating op gets queued onto this future so
  // concurrent append() / take() / appendAll() can't clobber each other's
  // writes (each op reads the file, mutates, then writes the whole file —
  // without serialization, last-writer-wins would lose data).
  Future<void> _chain = Future.value();

  _DiskQueue(this.name);

  void markAdded() => appendCount++;

  Future<R> _serial<R>(Future<R> Function() op) {
    final completer = Completer<R>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<File> _file() async {
    if (_cachedFile != null) return _cachedFile!;
    final dir = await getApplicationDocumentsDirectory();
    _cachedFile = File('${dir.path}/scoova_queue_$name.jsonl');
    return _cachedFile!;
  }

  Future<List<String>> _readLines() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final content = await f.readAsString();
      return content.split('\n').where((l) => l.isNotEmpty).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _writeLines(List<String> lines) async {
    try {
      final f = await _file();
      await f.writeAsString(lines.join('\n'));
    } catch (_) {}
  }

  Future<void> append(String json) => _serial(() async {
    final lines = await _readLines();
    lines.add(json);
    while (lines.length > maxSize) {
      lines.removeAt(0);
    }
    await _writeLines(lines);
  });

  Future<void> appendAll(List<String> jsons) => _serial(() async {
    if (jsons.isEmpty) return;
    final lines = await _readLines();
    lines.addAll(jsons);
    while (lines.length > maxSize) {
      lines.removeAt(0);
    }
    await _writeLines(lines);
  });

  /// Destructively read up to [count] items from the queue head.
  /// Caller is responsible for re-queueing on failure (via [appendAll]).
  Future<List<String>> take(int count) => _serial(() async {
    final lines = await _readLines();
    if (lines.isEmpty) return <String>[];
    final batch = lines.take(count).toList();
    final remaining = lines.skip(count).toList();
    await _writeLines(remaining);
    return batch;
  });

  /// Wipe the queue file. Used by clearLocalUserData().
  Future<void> clear() => _serial(() async {
    appendCount = 0;
    try {
      final f = await _file();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  });
}

/// Tagged logger
class ScoovaLogger {
  final String _tag;
  ScoovaLogger._(this._tag);

  void debug(String msg, {Map<String, String>? data}) =>
      ScoovaMonitor.log(_tag, 'debug', msg, data: data);
  void info(String msg, {Map<String, String>? data}) =>
      ScoovaMonitor.log(_tag, 'info', msg, data: data);
  void warning(String msg, {Map<String, String>? data}) =>
      ScoovaMonitor.log(_tag, 'warning', msg, data: data);
  void error(String msg, {Map<String, String>? data}) =>
      ScoovaMonitor.log(_tag, 'error', msg, data: data);
}

/// `NavigatorObserver` implementation behind `ScoovaMonitor.routeObserver`.
/// Emits `screen_view` events on push/pop/replace using the route's
/// settings.name when present, falling back to the runtime type of
/// the wrapped widget.
class _ScoovaRouteObserver extends NavigatorObserver {
  String _routeName(Route<dynamic>? route) {
    if (route == null) return 'unknown';
    final n = route.settings.name;
    if (n != null && n.isNotEmpty) return n;
    // Best-effort: ModalRoute holds a builder that returns the screen
    // widget — its runtimeType is a stable name.
    if (route is PageRoute) return route.settings.name ?? route.runtimeType.toString();
    return route.runtimeType.toString();
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    ScoovaMonitor.trackScreen(_routeName(route));
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) ScoovaMonitor.trackScreen(_routeName(newRoute));
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // After pop, the user is now seeing previousRoute. Emit it as the
    // active screen so dashboards reflect what's actually on screen.
    if (previousRoute != null) ScoovaMonitor.trackScreen(_routeName(previousRoute));
  }
}

/// Lifecycle observer
class _LifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        ScoovaMonitor.addBreadcrumb('App resumed', 'lifecycle');
        ScoovaMonitor.trackEvent('session_start',
            data: {'session_id': ScoovaMonitor._sessionId});
        break;
      case AppLifecycleState.paused:
        ScoovaMonitor.addBreadcrumb('App paused', 'lifecycle');
        // Best-effort flush; queues are already on disk so a kill mid-flush
        // won't lose data.
        ScoovaMonitor.flush();
        break;
      default:
        break;
    }
  }
}
