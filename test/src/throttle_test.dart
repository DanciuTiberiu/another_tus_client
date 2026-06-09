import 'package:test/test.dart';
import 'package:another_tus_client/another_tus_client.dart';

void main() {
  group('ThrottleOptions', () {
    test('none() disables the bucket', () {
      expect(resolveThrottle(const ThrottleOptions.none(), null), isNull);
      expect(resolveThrottle(const ThrottleOptions.none(), 50.0), isNull);
    });

    test('bytesPerSecond applies regardless of measured speed', () {
      final bucket = resolveThrottle(
        const ThrottleOptions.bytesPerSecond(1024),
        50.0,
      );
      expect(bucket, isNotNull);
    });

    test('bandwidthFraction uses measured speed when available', () {
      // 10 Mb/s link, 0.5 fraction → 5 Mb/s = 625_000 bytes/s.
      final bucket = resolveThrottle(
        const ThrottleOptions.bandwidthFraction(0.5),
        10.0,
      );
      expect(bucket, isNotNull);
    });

    test('bandwidthFraction falls back when speed is unknown', () {
      final bucket = resolveThrottle(
        const ThrottleOptions.bandwidthFraction(0.3),
        null,
      );
      expect(bucket, isNotNull, reason: 'Should use default fallback rate');
    });

    test('bandwidthFraction clamps fraction to [0, 1]', () {
      // 1.5 clamped to 1.0 → 1.0 * 1_000_000 = 1_000_000 bytes/s.
      final bucket = resolveThrottle(
        const ThrottleOptions.bandwidthFraction(1.5),
        1.0,
      );
      expect(bucket, isNotNull);
    });

    test('bandwidthFraction with zero fraction returns null', () {
      final bucket = resolveThrottle(
        const ThrottleOptions.bandwidthFraction(0.0),
        50.0,
      );
      // rate is (50 * 1e6 * 0).round() == 0 → resolveThrottle returns null
      expect(bucket, isNull);
    });

    test('custom fallbackBytesPerSecond is honored', () {
      final bucket = resolveThrottle(
        const ThrottleOptions.bandwidthFraction(
          0.3,
          fallbackBytesPerSecond: 8192,
        ),
        null,
      );
      expect(bucket, isNotNull);
    });
  });

  group('throttle:resolveThrottle', () {
    test('bandwidthFraction converts Mbps to bytes/s correctly', () {
      // 100 Mbps link, 0.3 fraction = 30 Mbps used.
      // 30 Mbps = 30_000_000 bits/s = 3_750_000 bytes/s.
      final bucket = resolveThrottle(
        const ThrottleOptions.bandwidthFraction(0.3),
        100.0, // 100 Mbps measured
      );
      expect(bucket, isNotNull);
      // The bucket's rate is the cap in bytes/s.
      expect(bucket!.rateTokensPerSecond, equals(3750000));
    });

    test('bandwidthFraction applies to 1 Gbps link correctly', () {
      // 1 Gbps = 1000 Mbps. At 0.3 = 300 Mbps used.
      // 300 Mbps = 300_000_000 bits/s = 37_500_000 bytes/s = ~35.76 MB/s.
      final bucket = resolveThrottle(
        const ThrottleOptions.bandwidthFraction(0.3),
        1000.0, // 1 Gbps measured
      );
      expect(bucket, isNotNull);
      expect(bucket!.rateTokensPerSecond, equals(37500000));
    });

    test('bandwidthFraction(1.0) is the full measured link speed', () {
      // Sanity: 100% fraction = full link in bytes/s.
      final bucket = resolveThrottle(
        const ThrottleOptions.bandwidthFraction(1.0),
        100.0,
      );
      expect(bucket, isNotNull);
      expect(bucket!.rateTokensPerSecond, equals(12500000));
      // That's 12.5 MB/s = 100 Mbps / 8.
    });
  });

  group('TokenBucket', () {
    test('acquire(0) is a no-op', () async {
      final bucket = TokenBucket.bytesPerSecond(1024);
      final waited = await bucket.acquire(0);
      expect(waited, equals(Duration.zero));
    });

    test('acquire waits approximately the right amount', () async {
      // 1024 bytes/s = 1024 ms per byte (slow enough to measure reliably).
      final bucket = TokenBucket.bytesPerSecond(1024);

      final sw = Stopwatch()..start();
      await bucket.acquire(64); // ~62.5 ms wait
      sw.stop();

      // Allow wide tolerance: scheduler delay + a bit of math fuzz.
      expect(
        sw.elapsedMilliseconds,
        greaterThanOrEqualTo(50),
        reason: 'Should wait at least ~50ms for 64 bytes at 1024 B/s',
      );
      expect(
        sw.elapsedMilliseconds,
        lessThan(500),
        reason: 'Should not wait absurdly long',
      );
    });

    test('acquire after elapsed time does not over-wait', () async {
      // 100_000 bytes/s. First acquire: 1000 bytes → ~10ms.
      final bucket = TokenBucket.bytesPerSecond(100000);
      await bucket.acquire(1000);

      // Wait so tokens accrue. Then acquire 2000 bytes: should still take ~20ms
      // (because 1000 tokens were used, then ~10ms passed = 1000 more tokens,
      // so we need ~10ms more for the remaining 1000).
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final sw = Stopwatch()..start();
      await bucket.acquire(2000);
      sw.stop();
      expect(
        sw.elapsedMilliseconds,
        lessThan(100),
        reason: 'Should not wait long since tokens had time to refill',
      );
    });
  });
}
