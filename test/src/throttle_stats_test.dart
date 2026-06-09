// Unit tests for the per-chunk throttle-stats conversion math. These exist
// because the inline conversion in _updateEffectiveSpeedLog has been
// rewritten three times due to bits-vs-bytes and "bits/µs == Mbps" mistakes.
// The math is now factored out into a pure helper that we test directly.

import 'package:test/test.dart';
import 'package:another_tus_client/another_tus_client.dart';

void main() {
  group('ThrottleStats', () {
    test('wire Mbps is bytes*8 / elapsed_seconds / 1e6', () {
      // 18,874,368 bytes in 11,636,400 µs = 11.6364 s
      // bits = 150,994,944; bps = 12,977,300; Mbps = 12.98
      final stats = ThrottleStats.fromBytesAndMicros(
        bytes: 18874368,
        elapsedMicros: 11636400,
        throttledMicros: 3808300,
      );
      expect(stats.mbpsWire, closeTo(12.98, 0.05));
      expect(stats.mbpsEffective, isNotNull);
      // MB/s = Mbps / 8
      expect(stats.mbPerSecWire, closeTo(12.98 / 8, 0.01));
      expect(stats.mbPerSecEffective, isNotNull);
    });

    test('effective Mbps < wire Mbps when throttling is active', () {
      final stats = ThrottleStats.fromBytesAndMicros(
        bytes: 1000000,
        elapsedMicros: 1000000, // 1s
        throttledMicros: 500000, // 0.5s of that was throttle wait
      );
      // wire: 1 MB in 1s = 8 Mbps
      // effective: 1 MB in 1.5s = 5.33 Mbps
      expect(stats.mbpsWire, closeTo(8.0, 0.01));
      expect(stats.mbpsEffective, closeTo(8.0 / 1.5, 0.01));
      expect(stats.mbpsEffective, lessThan(stats.mbpsWire));
    });

    test('effective equals wire when no throttling is active', () {
      final stats = ThrottleStats.fromBytesAndMicros(
        bytes: 1000000,
        elapsedMicros: 1000000,
        throttledMicros: 0,
      );
      expect(stats.mbpsWire, closeTo(stats.mbpsEffective, 0.001));
      expect(stats.mbPerSecWire, closeTo(stats.mbPerSecEffective, 0.001));
    });

    test('handles 1 Gbps sustained throughput', () {
      // 125 MB in 1s = 1000 Mbps exactly.
      final stats = ThrottleStats.fromBytesAndMicros(
        bytes: 125000000,
        elapsedMicros: 1000000,
        throttledMicros: 0,
      );
      expect(stats.mbpsWire, closeTo(1000.0, 0.1));
      expect(stats.mbPerSecWire, closeTo(125.0, 0.01));
    });

    test('handles a single-chunk minimum (524288 bytes)', () {
      // 524288 bytes = 512 KB. At 4.70 MB/s cap, this chunk should
      // take ~111.6ms with throttle on localhost (where wire is ~free).
      final stats = ThrottleStats.fromBytesAndMicros(
        bytes: 524288,
        elapsedMicros: 111600, // ~111.6ms (mostly throttle wait)
        throttledMicros: 106400, // 106ms throttle
      );
      // wire: 524288 * 8 / 0.1116 = 37.6 Mbps
      // effective: 524288 * 8 / 0.1116 (no wait included here) — actually
      // effective is bytes * 8 / (elapsed + throttled) which would be
      // 524288 * 8 / 0.218 = 19.2 Mbps.
      expect(stats.mbpsWire, closeTo(37.6, 0.5));
      expect(stats.mbpsEffective, closeTo(19.2, 0.5));
    });
  });
}
