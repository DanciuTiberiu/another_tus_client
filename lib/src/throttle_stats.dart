// Pure value type holding the per-chunk throttle throughput numbers.
// Exposed as a top-level type so it can be unit-tested without instantiating
// a TusClient.
//
// The math here is the same as the inline calculation in
// `_updateEffectiveSpeedLog` in client.dart. Keeping it as a separate
// function gives us a single testable target for the bits-vs-bytes math,
// which has been rewritten multiple times.

class ThrottleStats {
  /// Total bytes successfully sent under throttle (cumulative within
  /// the current upload session, not per-chunk).
  final int bytes;

  /// Wall-clock time elapsed since the first throttled chunk, in
  /// microseconds. Excludes time spent waiting in the token bucket.
  final int elapsedMicros;

  /// Time spent waiting in the token bucket across all chunks so far.
  final int throttledMicros;

  /// Effective wire throughput: bits per second if every byte were
  /// delivered without throttle delay. Computed as
  /// `bytes * 8 / (elapsedMicros * 1e-6) / 1e6`.
  final double mbpsWire;

  /// Throughput as seen by the user, including throttle waits.
  /// `bytes * 8 / ((elapsedMicros + throttledMicros) * 1e-6) / 1e6`.
  final double mbpsEffective;

  /// Same as [mbpsWire] but in megabytes per second (= mbpsWire / 8).
  final double mbPerSecWire;

  /// Same as [mbpsEffective] but in megabytes per second.
  final double mbPerSecEffective;

  const ThrottleStats({
    required this.bytes,
    required this.elapsedMicros,
    required this.throttledMicros,
    required this.mbpsWire,
    required this.mbpsEffective,
    required this.mbPerSecWire,
    required this.mbPerSecEffective,
  });

  /// Factory that does the conversion from raw byte/microsecond counts.
  /// The microsecond → second conversion uses `* 1e-6` to keep the math
  /// in `double` space (avoiding integer-overflow risk on huge uploads).
  factory ThrottleStats.fromBytesAndMicros({
    required int bytes,
    required int elapsedMicros,
    required int throttledMicros,
  }) {
    final bpsWire = (bytes * 8) / (elapsedMicros * 1e-6);
    final bpsEffective = (bytes * 8) / ((elapsedMicros + throttledMicros) * 1e-6);
    return ThrottleStats(
      bytes: bytes,
      elapsedMicros: elapsedMicros,
      throttledMicros: throttledMicros,
      mbpsWire: bpsWire / 1e6,
      mbpsEffective: bpsEffective / 1e6,
      mbPerSecWire: bpsWire / 8 / 1e6,
      mbPerSecEffective: bpsEffective / 8 / 1e6,
    );
  }
}
