import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:another_tus_client/another_tus_client.dart';

/// Fake HTTP client that records the request and returns a canned response.
///
/// Can simulate a full TUS handshake by returning 201 + Location on POST,
/// 204 on PATCH, 204 on DELETE. Use [tusUploadUrl] to control what the
/// Location header points at; pass a relative URL to test URL resolution.
class _FakeClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  final List<String> deletedUrls = [];
  final int statusCode;
  final int responseBodyBytes;
  final Duration delay;
  final bool throwOnSend;

  /// Where the POST → 201 response should report the upload lives. Pass
  /// a full URL (e.g. `https://x.test/upload/abc`) or a relative path
  /// (e.g. `/upload/abc`) to exercise URL resolution.
  final String? tusUploadUrl;

  /// If true, the DELETE cleanup call will fail (simulates a server
  /// that doesn't support DELETE).
  final bool failDelete;

  _FakeClient({
    this.statusCode = 200,
    this.responseBodyBytes = 0,
    this.delay = Duration.zero,
    this.throwOnSend = false,
    this.tusUploadUrl,
    this.failDelete = false,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    if (throwOnSend) {
      throw Exception('network down');
    }
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }

    // Handle DELETE for cleanup.
    if (request.method == 'DELETE') {
      deletedUrls.add(request.url.toString());
      if (failDelete) {
        return http.StreamedResponse(
          Stream<List<int>>.value(Uint8List(0)),
          405, // Method Not Allowed
        );
      }
      return http.StreamedResponse(
        Stream<List<int>>.value(Uint8List(0)),
        204,
      );
    }

    // Handle POST for TUS upload creation. We default to returning 201 +
    // Location, but if the caller didn't ask for TUS behavior (tusUploadUrl
    // is null), we fall through to the generic response.
    if (request.method == 'POST' && tusUploadUrl != null) {
      return http.StreamedResponse(
        Stream<List<int>>.value(Uint8List(0)),
        201,
        headers: {'location': tusUploadUrl!},
        contentLength: 0,
      );
    }

    final body = Uint8List(responseBodyBytes);
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      statusCode,
      contentLength: body.length,
    );
  }
}

void main() {
  group('NoSpeedProbe', () {
    test('always returns null', () async {
      expect(await const NoSpeedProbe().measureUploadMbps(), isNull);
    });
  });

  group('DefaultSpeedProbe', () {
    test('returns null when endpoints list is empty', () async {
      final probe = DefaultSpeedProbe(
        config: SpeedProbeConfig(
          endpoints: const [],
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          perProbeTimeout: const Duration(seconds: 1),
          clientFactory: () => _FakeClient(),
        ),
      );
      expect(await probe.measureUploadMbps(), isNull);
    });

    test('computes mbps from a successful POST and echoes the body', () async {
      final fake = _FakeClient(
        statusCode: 200,
        responseBodyBytes: 1024, // echo back what we sent
        delay: const Duration(milliseconds: 100),
      );
      final probe = DefaultSpeedProbe(
        config: SpeedProbeConfig(
          endpoints: [Uri.parse('https://example.test/post')],
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => fake,
        ),
      );
      final mbps = await probe.measureUploadMbps();
      // 1024 bytes in 100ms = 10_240 bytes/s = 81_920 bits/s = 0.08192 Mbps.
      // The simulated delay is `Future.delayed(100ms)`, which on a busy CI
      // runner can land anywhere in [100ms, ~150ms]. We accept a wide band
      // to keep the test stable; the math itself is unit-tested in throttle.
      expect(mbps, isNotNull);
      expect(mbps!, greaterThan(0.05));
      expect(mbps, lessThan(0.15));
      expect(fake.requests, hasLength(1));
      expect(fake.requests.first.method, 'POST');
    });

    test('falls back to next endpoint when first fails', () async {
      final first = _FakeClient(throwOnSend: true);
      final second = _FakeClient(
        statusCode: 200,
        responseBodyBytes: 1024,
      );
      final probes = [first, second];
      final probe = DefaultSpeedProbe(
        config: SpeedProbeConfig(
          endpoints: [
            Uri.parse('https://broken.test/post'),
            Uri.parse('https://working.test/post'),
          ],
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          perProbeTimeout: const Duration(seconds: 1),
          clientFactory: () => probes.removeAt(0),
        ),
      );
      final mbps = await probe.measureUploadMbps();
      expect(mbps, isNotNull);
      expect(first.requests, hasLength(1));
      expect(second.requests, hasLength(1));
    });

    test('skips a slow probe (timeout) and tries the next', () async {
      final slow = _FakeClient(
        delay: const Duration(seconds: 2),
        responseBodyBytes: 1024,
      );
      final fast = _FakeClient(responseBodyBytes: 1024);
      final probes = [slow, fast];
      final probe = DefaultSpeedProbe(
        config: SpeedProbeConfig(
          endpoints: [
            Uri.parse('https://slow.test/post'),
            Uri.parse('https://fast.test/post'),
          ],
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          perProbeTimeout: const Duration(milliseconds: 100),
          clientFactory: () => probes.removeAt(0),
        ),
      );
      final mbps = await probe.measureUploadMbps();
      expect(mbps, isNotNull);
    });

    test('rejects an endpoint that did not echo back the body', () async {
      final bad = _FakeClient(
        statusCode: 200,
        responseBodyBytes: 10, // sent 1024, echoed only 10
      );
      final probe = DefaultSpeedProbe(
        config: SpeedProbeConfig(
          endpoints: [Uri.parse('https://broken.test/post')],
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          perProbeTimeout: const Duration(seconds: 1),
          clientFactory: () => bad,
        ),
      );
      expect(await probe.measureUploadMbps(), isNull);
    });

    test('rejects a non-2xx response', () async {
      final bad = _FakeClient(
        statusCode: 503,
        responseBodyBytes: 1024,
      );
      final probe = DefaultSpeedProbe(
        config: SpeedProbeConfig(
          endpoints: [Uri.parse('https://broken.test/post')],
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          perProbeTimeout: const Duration(seconds: 1),
          clientFactory: () => bad,
        ),
      );
      expect(await probe.measureUploadMbps(), isNull);
    });

    test('picks the best of N probes per endpoint', () async {
      // Simulate one slow + one fast measurement on the same endpoint.
      final slow = _FakeClient(
        responseBodyBytes: 1024,
        delay: const Duration(milliseconds: 200),
      );
      final fast = _FakeClient(
        responseBodyBytes: 1024,
        delay: const Duration(milliseconds: 20),
      );
      final probes = [slow, fast];
      final probe = DefaultSpeedProbe(
        config: SpeedProbeConfig(
          endpoints: [Uri.parse('https://example.test/post')],
          bytesPerProbe: 1024,
          probesPerEndpoint: 2,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => probes.removeAt(0),
        ),
      );
      final mbps = await probe.measureUploadMbps();
      // 1024 bytes / 20ms = 51_200 B/s = 0.4096 Mbps. We accept a wide
      // band because the 20ms probe is timing-sensitive on busy CI runners
      // (it can land anywhere in [20ms, ~80ms]). What we really care about
      // here is that the probe picks the *faster* of the two — the slow
      // 200ms one would have produced ~0.041 Mbps, so any result >0.1 Mbps
      // proves it picked the fast one.
      expect(mbps, isNotNull);
      expect(mbps!, greaterThan(0.1),
          reason: 'Should have picked the fast 20ms probe, not the slow 200ms one');
      expect(mbps, lessThan(0.6));
    });
  });

  group('kDefaultSpeedProbeEndpoints', () {
    test('contains the public echo fallbacks', () {
      expect(kDefaultSpeedProbeEndpoints, isNotEmpty);
      expect(
        kDefaultSpeedProbeEndpoints
            .map((u) => u.toString())
            .toList(),
        containsAll(<String>[
          'https://eu.httpbin.org/post',
          'https://postman-echo.com/post',
        ]),
      );
    });
  });

  group('TusServerSpeedProbe', () {
    test('measures mbps from a full POST/PATCH/DELETE cycle', () async {
      final fake = _FakeClient(
        statusCode: 204,
        tusUploadUrl: 'https://tus.test/upload/abc',
        delay: const Duration(milliseconds: 100),
      );
      final probe = TusServerSpeedProbe(
        config: TusServerProbeConfig(
          tusServerUrl: Uri.parse('https://tus.test/files/'),
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          warmup: false,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => fake,
        ),
      );
      final mbps = await probe.measureUploadMbps();
      // 1024 bytes / ~100ms should land somewhere in [0.05, 0.15] Mbps
      // (timing band, see DefaultSpeedProbe tests for the same logic).
      expect(mbps, isNotNull);
      expect(mbps!, greaterThan(0.05));
      expect(mbps, lessThan(0.2));
      // We expect exactly 2 requests on the measured probe: 1 POST + 1 PATCH.
      // (DELETE happens in the finally block, so it's a 3rd request.)
      final nonDelete = fake.requests
          .where((r) => r.method != 'DELETE')
          .toList();
      expect(nonDelete, hasLength(2));
      expect(nonDelete[0].method, 'POST');
      expect(nonDelete[1].method, 'PATCH');
      // Headers should include Tus-Resumable.
      expect(nonDelete[0].headers['Tus-Resumable'], equals('1.0.0'));
      expect(nonDelete[1].headers['Tus-Resumable'], equals('1.0.0'));
      // The PATCH MUST carry Upload-Offset: 0 — the upload was just
      // created, so the server expects byte 0. Sending no Upload-Offset
      // is a 400 ERR_INVALID_OFFSET on compliant servers.
      expect(nonDelete[1].headers['Upload-Offset'], equals('0'));
      // Cleanup was performed.
      expect(fake.deletedUrls, hasLength(1));
      expect(fake.deletedUrls.first, equals('https://tus.test/upload/abc'));
    });

    test('resolves a relative Location header against the base URL', () async {
      final fake = _FakeClient(
        statusCode: 204,
        tusUploadUrl: '/upload/relative-path',
      );
      final probe = TusServerSpeedProbe(
        config: TusServerProbeConfig(
          tusServerUrl: Uri.parse('https://tus.test/files/'),
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          warmup: false,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => fake,
        ),
      );
      await probe.measureUploadMbps();
      expect(fake.deletedUrls, hasLength(1));
      expect(
        fake.deletedUrls.first,
        equals('https://tus.test/upload/relative-path'),
      );
    });

    test('runs a warmup probe before the measured ones', () async {
      final fake = _FakeClient(
        statusCode: 204,
        tusUploadUrl: 'https://tus.test/upload/abc',
      );
      final probe = TusServerSpeedProbe(
        config: TusServerProbeConfig(
          tusServerUrl: Uri.parse('https://tus.test/files/'),
          bytesPerProbe: 1024,
          probesPerEndpoint: 2,
          warmup: true,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => fake,
        ),
      );
      await probe.measureUploadMbps();
      // 1 warmup (POST+PATCH+DELETE) + 2 measured (POST+PATCH+DELETE each)
      // = 3 POSTs, 3 PATCHes, 3 DELETEs.
      final methods = fake.requests.map((r) => r.method).toList();
      expect(
        methods.where((m) => m == 'POST').length,
        equals(3),
        reason: '1 warmup POST + 2 measured POSTs',
      );
      expect(
        methods.where((m) => m == 'PATCH').length,
        equals(3),
        reason: '1 warmup PATCH + 2 measured PATCHs',
      );
      expect(
        methods.where((m) => m == 'DELETE').length,
        equals(3),
        reason: '1 warmup DELETE + 2 measured DELETEs',
      );
    });

    test('returns null when POST returns non-201', () async {
      final fake = _FakeClient(statusCode: 500);
      final probe = TusServerSpeedProbe(
        config: TusServerProbeConfig(
          tusServerUrl: Uri.parse('https://tus.test/files/'),
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          warmup: false,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => fake,
        ),
      );
      expect(await probe.measureUploadMbps(), isNull);
    });

    test('returns null when Location header is missing', () async {
      // tusUploadUrl: null means POST returns 200 with no Location header.
      final fake = _FakeClient(statusCode: 200);
      final probe = TusServerSpeedProbe(
        config: TusServerProbeConfig(
          tusServerUrl: Uri.parse('https://tus.test/files/'),
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          warmup: false,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => fake,
        ),
      );
      expect(await probe.measureUploadMbps(), isNull);
    });

    test('returns null when PATCH returns non-204', () async {
      // We need POST to succeed (201 + Location) but PATCH to fail. The
      // _FakeClient only supports one canned response, so we make POST
      // succeed and PATCH fail by setting tusUploadUrl on POST and using
      // a client that always returns 204 on everything except we want
      // PATCH to fail — but our fake doesn't differentiate. Use a custom
      // anonymous client for this test.
      final failingPatchClient = _TusSelectiveFake(
        postStatus: 201,
        postLocation: 'https://tus.test/upload/abc',
        patchStatus: 500,
      );
      final probe = TusServerSpeedProbe(
        config: TusServerProbeConfig(
          tusServerUrl: Uri.parse('https://tus.test/files/'),
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          warmup: false,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => failingPatchClient,
        ),
      );
      expect(await probe.measureUploadMbps(), isNull);
    });

    test('continues to return measurement when DELETE fails', () async {
      final fake = _FakeClient(
        statusCode: 204,
        tusUploadUrl: 'https://tus.test/upload/abc',
        failDelete: true,
      );
      final probe = TusServerSpeedProbe(
        config: TusServerProbeConfig(
          tusServerUrl: Uri.parse('https://tus.test/files/'),
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          warmup: false,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => fake,
        ),
      );
      final mbps = await probe.measureUploadMbps();
      expect(mbps, isNotNull,
          reason: 'DELETE failure should not invalidate the measurement');
      // DELETE was still attempted.
      expect(fake.deletedUrls, hasLength(1));
    });

    test('falls back to fallback probe when all TUS probes fail', () async {
      // TUS server always returns 500 on POST.
      final tusClient = _FakeClient(statusCode: 500);
      // Fallback echoes back what we sent.
      final fallbackClient = _FakeClient(responseBodyBytes: 1024);
      final probe = TusServerSpeedProbe(
        config: TusServerProbeConfig(
          tusServerUrl: Uri.parse('https://tus.test/files/'),
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          warmup: false,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => tusClient,
          fallback: DefaultSpeedProbe(
            config: SpeedProbeConfig(
              endpoints: [Uri.parse('https://fallback.test/post')],
              bytesPerProbe: 1024,
              probesPerEndpoint: 1,
              perProbeTimeout: const Duration(seconds: 5),
              clientFactory: () => fallbackClient,
            ),
          ),
        ),
      );
      final mbps = await probe.measureUploadMbps();
      expect(mbps, isNotNull,
          reason: 'Should have fallen back to DefaultSpeedProbe');
      // The fallback should have made exactly 1 request (a POST to the
      // echo endpoint).
      final fallbackPosts = fallbackClient.requests
          .where((r) => r.method == 'POST')
          .toList();
      expect(fallbackPosts, hasLength(1));
    });

    test('sends TUS metadata header when configured', () async {
      final fake = _FakeClient(
        statusCode: 204,
        tusUploadUrl: 'https://tus.test/upload/abc',
      );
      final probe = TusServerSpeedProbe(
        config: TusServerProbeConfig(
          tusServerUrl: Uri.parse('https://tus.test/files/'),
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          warmup: false,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => fake,
          metadata: {'filename': 'probe.bin'},
        ),
      );
      await probe.measureUploadMbps();
      final post = fake.requests
          .where((r) => r.method == 'POST')
          .first;
      // TUS metadata: "filename <base64>" where base64 of "probe.bin" is
      // cHJvYmUuYmlu.
      expect(post.headers['Upload-Metadata'], contains('filename cHJvYmUuYmlu'));
    });

    test('forwards custom headers to all three requests', () async {
      final fake = _FakeClient(
        statusCode: 204,
        tusUploadUrl: 'https://tus.test/upload/abc',
      );
      final probe = TusServerSpeedProbe(
        config: TusServerProbeConfig(
          tusServerUrl: Uri.parse('https://tus.test/files/'),
          bytesPerProbe: 1024,
          probesPerEndpoint: 1,
          warmup: false,
          perProbeTimeout: const Duration(seconds: 5),
          clientFactory: () => fake,
          headers: {'Authorization': 'Bearer secret'},
        ),
      );
      await probe.measureUploadMbps();
      for (final r in fake.requests) {
        expect(r.headers['Authorization'], equals('Bearer secret'),
            reason: 'All three requests (POST/PATCH/DELETE) should carry auth');
      }
    });
  });

  group('FirstSuccessfulSpeedProbe', () {
    test('returns the first non-null measurement', () async {
      final probe = FirstSuccessfulSpeedProbe([
        const NoSpeedProbe(), // null
        const _FixedProbe(42.0), // 42 Mbps
        const _FixedProbe(99.0), // should NOT be reached
      ]);
      expect(await probe.measureUploadMbps(), equals(42.0));
    });

    test('returns null when every probe fails', () async {
      final probe = FirstSuccessfulSpeedProbe([
        const NoSpeedProbe(),
        const NoSpeedProbe(),
      ]);
      expect(await probe.measureUploadMbps(), isNull);
    });

    test('chains TusServerSpeedProbe with DefaultSpeedProbe fallback',
        () async {
      final tusClient = _FakeClient(statusCode: 500);
      final fallbackClient = _FakeClient(responseBodyBytes: 1024);
      final chain = FirstSuccessfulSpeedProbe([
        TusServerSpeedProbe(
          config: TusServerProbeConfig(
            tusServerUrl: Uri.parse('https://tus.test/files/'),
            bytesPerProbe: 1024,
            probesPerEndpoint: 1,
            warmup: false,
            perProbeTimeout: const Duration(seconds: 5),
            clientFactory: () => tusClient,
            // Note: no fallback on the TUS probe — the chain provides it.
          ),
        ),
        DefaultSpeedProbe(
          config: SpeedProbeConfig(
            endpoints: [Uri.parse('https://fallback.test/post')],
            bytesPerProbe: 1024,
            probesPerEndpoint: 1,
            perProbeTimeout: const Duration(seconds: 5),
            clientFactory: () => fallbackClient,
          ),
        ),
      ]);
      final mbps = await chain.measureUploadMbps();
      expect(mbps, isNotNull);
      expect(fallbackClient.requests, hasLength(1));
    });
  });
}

/// Helper probe that returns a hard-coded Mbps value, for chain tests.
class _FixedProbe implements SpeedProbe {
  final double mbps;
  const _FixedProbe(this.mbps);
  @override
  Future<double?> measureUploadMbps() async => mbps;
}

/// A _FakeClient variant that returns one status on POST and another on
/// PATCH. Used to simulate a server where the upload creation works but
/// the PATCH itself fails.
class _TusSelectiveFake extends http.BaseClient {
  final int postStatus;
  final String postLocation;
  final int patchStatus;

  _TusSelectiveFake({
    required this.postStatus,
    required this.postLocation,
    required this.patchStatus,
  });

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'POST') {
      return http.StreamedResponse(
        Stream<List<int>>.value(Uint8List(0)),
        postStatus,
        headers: {'location': postLocation},
      );
    }
    if (request.method == 'PATCH') {
      return http.StreamedResponse(
        Stream<List<int>>.value(Uint8List(0)),
        patchStatus,
      );
    }
    if (request.method == 'DELETE') {
      return http.StreamedResponse(
        Stream<List<int>>.value(Uint8List(0)),
        204,
      );
    }
    return http.StreamedResponse(
      Stream<List<int>>.value(Uint8List(0)),
      500,
    );
  }
}
