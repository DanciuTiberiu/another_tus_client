// Speed probe module: measures the device's upload throughput by POSTing a
// fixed-size buffer of bytes to a known-reliable echo endpoint, timing how
// long the server takes to accept the request body, and converting the
// observed bytes/second into megabits/second (matching the unit of
// [TusClientBase.uploadSpeed]).
//
// Why we don't use the popular speed-test services:
// - speedtest.net (Ookla): requires non-standard XML config, gzip-handling
//   is fragile, and EU IP ranges frequently get a GDPR consent interstitial
//   instead of the XML response, causing XmlParserException.
// - fast.com (Netflix): the public speedtest API was retired; api.fast.com
//   returns 404 for the legacy endpoints and the JS bundle is now just a
//   redirect to the marketing page.
// - flutter_internet_speed_test_pro: works but is iOS+Android-only (no web
//   or desktop), so we can't take a runtime dep on it from a cross-platform
//   package.
//
// We use plain `package:http` POSTs against stable public echo endpoints
// (eu.httpbin.org / postman-echo.com). These are not as geographically
// tuned as a real CDN speed test, but they:
// - work on every platform (web, mobile, desktop) because they use plain HTTP,
// - don't require an API key or geographic discovery step,
// - return the uploaded bytes back so we know the server actually accepted
//   the whole body (and not just an early ack),
// - are not blocked by EU GDPR consent flows.

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Default endpoints to probe, in priority order. The probe tries each one
/// in sequence and returns the best successful measurement.
///
/// Public, well-known echo services that accept arbitrary POST bodies.
/// Override via [SpeedProbeConfig.endpoints] if you want to test against
/// your own TUS server (which is the most accurate option — you're measuring
/// the actual link you'll be uploading to).
final List<Uri> kDefaultSpeedProbeEndpoints = [
  Uri.parse('https://eu.httpbin.org/post'),
  Uri.parse('https://postman-echo.com/post'),
];

/// Configuration for [DefaultSpeedProbe].
class SpeedProbeConfig {
  /// Endpoints to probe, in priority order. Defaults to
  /// [kDefaultSpeedProbeEndpoints].
  final List<Uri> endpoints;

  /// How many bytes to upload per probe. Bigger numbers give a more stable
  /// measurement but cost more bandwidth. Default 1 MB.
  final int bytesPerProbe;

  /// Hard upper bound on the duration of a single probe. If a probe takes
  /// longer than this we treat it as a failure and move to the next endpoint.
  final Duration perProbeTimeout;

  /// How many probes to run per endpoint, picking the best result.
  /// Default 2.
  final int probesPerEndpoint;

  /// HTTP client to use. Override for testing. Defaults to a fresh
  /// `http.Client()`.
  final http.Client Function()? clientFactory;

  SpeedProbeConfig({
    List<Uri>? endpoints,
    this.bytesPerProbe = 1024 * 1024,
    this.perProbeTimeout = const Duration(seconds: 30),
    this.probesPerEndpoint = 2,
    this.clientFactory,
  }) : endpoints = endpoints ?? kDefaultSpeedProbeEndpoints;
}

/// Abstract speed probe. Implement this if you want to plug in your own
/// measurement strategy (e.g. a CDN-specific probe, or a synthetic test
/// against your own TUS server's PATCH endpoint).
abstract class SpeedProbe {
  /// Measures the upload throughput and returns the result in **megabits
  /// per second** (matches the unit of [TusClientBase.uploadSpeed]).
  ///
  /// Returns `null` if the probe could not produce a measurement.
  Future<double?> measureUploadMbps();
}

/// Default speed probe. POSTs a buffer of [SpeedProbeConfig.bytesPerProbe]
/// bytes to each configured endpoint, times how long the server takes to
/// accept the body, and picks the best measurement across all attempts.
class DefaultSpeedProbe implements SpeedProbe {
  final SpeedProbeConfig config;

  DefaultSpeedProbe({SpeedProbeConfig? config})
      : config = config ?? SpeedProbeConfig();

  @override
  Future<double?> measureUploadMbps() async {
    if (config.endpoints.isEmpty) return null;

    double? bestMbps;
    for (final endpoint in config.endpoints) {
      for (int i = 0; i < config.probesPerEndpoint; i++) {
        final mbps = await _probeOnce(endpoint);
        if (mbps == null) continue;
        // Take the best measurement — the slowest one is usually just noise
        // (cold connection, server GC pause, etc.).
        if (bestMbps == null || mbps > bestMbps) bestMbps = mbps;
      }
      if (bestMbps != null) return bestMbps;
    }
    return bestMbps;
  }

  Future<double?> _probeOnce(Uri endpoint) async {
    final bytes = _buildPayload(config.bytesPerProbe);
    final client = (config.clientFactory ?? http.Client.new)();
    try {
      final sw = Stopwatch()..start();
      final response = await client
          .post(
            endpoint,
            body: bytes,
            headers: {'Content-Type': 'application/octet-stream'},
          )
          .timeout(config.perProbeTimeout);
      sw.stop();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      if (response.bodyBytes.length < bytes.length ~/ 2) {
        // Echo endpoint didn't echo back what we sent; treat as inconclusive.
        return null;
      }

      final seconds = sw.elapsedMicroseconds / 1e6;
      if (seconds <= 0) return null;
      // bytes/sec -> megabits/sec (× 8 / 1_000_000).
      return (bytes.length * 8 / seconds) / 1000000;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static Uint8List? _sharedBuffer;
  static Uint8List _buildPayload(int size) {
    // Reuse a single pre-randomized buffer across probes to avoid
    // allocating several megabytes per upload session. Buffer is grown
    // on demand but never shrunk.
    final existing = _sharedBuffer;
    if (existing != null && existing.length >= size) {
      return existing.sublist(0, size);
    }
    final rng = math.Random(0xCAFE);
    final fresh = Uint8List(size);
    for (int i = 0; i < size; i++) {
      fresh[i] = rng.nextInt(256);
    }
    _sharedBuffer = fresh;
    return fresh;
  }
}

/// A no-op probe that always returns `null`. Useful for tests, or for
/// callers who want to disable speed measurement explicitly.
class NoSpeedProbe implements SpeedProbe {
  const NoSpeedProbe();
  @override
  Future<double?> measureUploadMbps() async => null;
}

/// Configuration for [TusServerSpeedProbe].
class TusServerProbeConfig {
  /// The TUS server URL where uploads are normally created (the one you'd
  /// pass to `TusClient.upload(uri: ...)`). The probe will POST here to
  /// start a throwaway upload.
  final Uri tusServerUrl;

  /// Extra headers to send on every request (auth tokens, custom metadata,
  /// etc.). The probe adds `Tus-Resumable` itself; you don't need to.
  final Map<String, String>? headers;

  /// TUS metadata to send on the creation POST. The probe doesn't add any
  /// by default — pass `{'filename': 'probe.bin'}` if your server requires
  /// a filename to be present.
  final Map<String, String>? metadata;

  /// How many bytes to upload per probe. Default 1 MB.
  final int bytesPerProbe;

  /// Per-request timeout. Default 10 seconds (longer than [SpeedProbeConfig]
  /// because we're paying TLS+TCP+auth overhead against a real server).
  final Duration perProbeTimeout;

  /// How many *measured* probes to run. The warmup probe is in addition
  /// to this. Default 2.
  final int probesPerEndpoint;

  /// Whether to run a warmup probe before the measured ones. The warmup
  /// absorbs the cost of TLS handshake, TCP slow-start, and any auth
  /// latency, so the measured probes reflect steady-state throughput.
  /// Default `true`.
  final bool warmup;

  /// HTTP client to use. Override for testing. Defaults to a fresh
  /// `http.Client()`.
  final http.Client Function()? clientFactory;

  /// Optional fallback probe. If the TUS probe fails entirely (the
  /// server is unreachable, doesn't speak TUS, DELETE is unsupported, etc.),
  /// the fallback is consulted. Pass a [DefaultSpeedProbe] to fall back
  /// to public echo endpoints.
  final SpeedProbe? fallback;

  /// If true, the probe will try to DELETE the upload after the PATCH
  /// completes, to clean up the server-side storage. Set to false if your
  /// TUS server doesn't support DELETE (the spec recommends it, but not
  /// all implementations do).
  ///
  /// When DELETE fails, the measurement is still returned — the bytes
  /// are <2 MB and the server's own cleanup job will eventually GC them.
  final bool cleanupAfter;

  TusServerProbeConfig({
    required this.tusServerUrl,
    this.headers,
    this.metadata,
    this.bytesPerProbe = 1024 * 1024,
    this.perProbeTimeout = const Duration(seconds: 10),
    this.probesPerEndpoint = 2,
    this.warmup = true,
    this.clientFactory,
    this.fallback,
    this.cleanupAfter = true,
  });
}

/// Speed probe that measures throughput by performing a real TUS
/// upload-and-delete cycle against your own TUS server. This is the most
/// accurate measurement available because it includes the full real-world
/// cost: TLS handshake, TCP slow-start, your auth layer, the server's
/// request handling, and the network.
///
/// Protocol flow per probe:
///   1. POST `<tusServerUrl>` with `Tus-Resumable`, `Upload-Length: N`,
///      optional metadata. Receive 201 + `Location: <upload-url>`.
///   2. PATCH `<upload-url>` with N bytes of random data, time the
///      round-trip. Receive 204 + `Upload-Offset: N`.
///   3. DELETE `<upload-url>` to clean up. Best-effort: if it fails, the
///      measurement is still returned.
///
/// By default, runs 1 silent warmup probe (to absorb handshake/auth cost)
/// and 2 measured probes (best of N is kept). The warmup is configurable
/// via [TusServerProbeConfig.warmup].
///
/// If the entire TUS probe run fails (server unreachable, non-TUS
/// response, no Location header, etc.), and a [TusServerProbeConfig.fallback]
/// is configured, the fallback is consulted. This is the recommended
/// setup — public echo endpoints as the fallback of last resort.
class TusServerSpeedProbe implements SpeedProbe {
  final TusServerProbeConfig config;

  TusServerSpeedProbe({required this.config});

  @override
  Future<double?> measureUploadMbps() async {
    // Optional warmup: one silent PATCH to absorb TLS+TCP+auth cost.
    // We swallow any error here because warmup failure shouldn't fail
    // the whole measurement.
    if (config.warmup) {
      try {
        await _runOneProbe();
      } catch (_) {
        // Warmup failed; we'll still try the measured probes.
      }
    }

    double? bestMbps;
    for (int i = 0; i < config.probesPerEndpoint; i++) {
      final mbps = await _timeOneProbe();
      if (mbps == null) continue;
      if (bestMbps == null || mbps > bestMbps) bestMbps = mbps;
    }
    if (bestMbps != null) return bestMbps;

    // Everything failed — try the fallback if we have one.
    final fallback = config.fallback;
    if (fallback != null) {
      return await fallback.measureUploadMbps();
    }
    return null;
  }

  /// Runs a single full POST/PATCH/DELETE cycle and returns the Mbps
  /// measured during the PATCH. Used by the warmup path (return value
  /// discarded) and by [measureUploadMbps] for the measured runs.
  Future<double?> _timeOneProbe() async {
    String? uploadUrl;
    final client = (config.clientFactory ?? http.Client.new)();
    try {
      // Step 1: POST to create the upload. The server should respond with
      // 201 Created and a Location header pointing at the new upload URL.
      final createHeaders = <String, String>{
        'Tus-Resumable': '1.0.0',
        'Upload-Length': '${config.bytesPerProbe}',
        if (config.metadata != null && config.metadata!.isNotEmpty)
          'Upload-Metadata': _encodeMetadata(config.metadata!),
        if (config.headers != null) ...config.headers!,
      };

      final createResponse = await client
          .post(config.tusServerUrl, headers: createHeaders)
          .timeout(config.perProbeTimeout);

      if (createResponse.statusCode != 201) {
        return null;
      }
      final location = createResponse.headers['location'];
      if (location == null || location.isEmpty) {
        return null;
      }
      uploadUrl = _resolveUploadUrl(config.tusServerUrl, location);

      // Step 2: PATCH the upload URL with the probe bytes. Time this.
      final bytes = _buildPayload(config.bytesPerProbe);
      final patchHeaders = <String, String>{
        'Tus-Resumable': '1.0.0',
        'Upload-Offset': '0', // mandatory on every PATCH; we just created
                              // the upload so the server expects byte 0.
        'Content-Type': 'application/offset+octet-stream',
        if (config.headers != null) ...config.headers!,
      };

      final sw = Stopwatch()..start();
      final patchResponse = await client
          .patch(Uri.parse(uploadUrl), headers: patchHeaders, body: bytes)
          .timeout(config.perProbeTimeout);
      sw.stop();

      if (patchResponse.statusCode != 204) {
        return null;
      }
      final seconds = sw.elapsedMicroseconds / 1e6;
      if (seconds <= 0) return null;
      return (bytes.length * 8 / seconds) / 1000000;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    } finally {
      // Best-effort cleanup. We always try to DELETE so we don't leak
      // upload slots on the server. If the uploadUrl is null we never
      // got past POST, so there's nothing to clean up.
      if (config.cleanupAfter && uploadUrl != null) {
        try {
          await client
              .delete(Uri.parse(uploadUrl), headers: {
            'Tus-Resumable': '1.0.0',
            if (config.headers != null) ...config.headers!,
          })
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          // Cleanup failure is non-fatal — the server will GC eventually.
        }
      }
      client.close();
    }
  }

  /// Alias of [_timeOneProbe] for clarity at call sites.
  Future<void> _runOneProbe() async {
    await _timeOneProbe();
  }

  /// TUS metadata header format: `key1 base64(value1),key2 base64(value2)`.
  static String _encodeMetadata(Map<String, String> metadata) {
    return metadata.entries
        .map((e) => '${e.key} ${base64.encode(utf8.encode(e.value))}')
        .join(',');
  }

  /// Resolve a `Location` header (which may be relative) against the
  /// base URL used for the POST.
  static String _resolveUploadUrl(Uri base, String location) {
    if (location.startsWith('http://') || location.startsWith('https://')) {
      return location;
    }
    return base.resolve(location).toString();
  }

  // Shared payload buffer (same logic as DefaultSpeedProbe).
  static Uint8List? _sharedBuffer;
  static Uint8List _buildPayload(int size) {
    final existing = _sharedBuffer;
    if (existing != null && existing.length >= size) {
      return existing.sublist(0, size);
    }
    final rng = math.Random(0xCAFE);
    final fresh = Uint8List(size);
    for (int i = 0; i < size; i++) {
      fresh[i] = rng.nextInt(256);
    }
    _sharedBuffer = fresh;
    return fresh;
  }
}

/// Probe chain: tries each probe in order, returns the first non-null
/// measurement. Use this to compose a TUS-server probe with a public-echo
/// fallback:
///
/// ```dart
/// final probe = FirstSuccessfulSpeedProbe([
///   TusServerSpeedProbe(config: TusServerProbeConfig(
///     tusServerUrl: Uri.parse('https://tus.example.com/files/'),
///     fallback: DefaultSpeedProbe(),
///   )),
/// ]);
/// ```
class FirstSuccessfulSpeedProbe implements SpeedProbe {
  final List<SpeedProbe> probes;

  const FirstSuccessfulSpeedProbe(this.probes);

  @override
  Future<double?> measureUploadMbps() async {
    for (final probe in probes) {
      final mbps = await probe.measureUploadMbps();
      if (mbps != null) return mbps;
    }
    return null;
  }
}
