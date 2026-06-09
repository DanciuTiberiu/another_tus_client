// Throttling support for TUS uploads.
//
// A token bucket paces the upload by delaying each PATCH chunk until the
// bucket has enough tokens. Tokens refill at the configured rate, and each
// chunk consumes one token per byte actually sent (capped to the chunk size).
//
// The bucket is application-layer pacing: it controls *when* we send chunks,
// not the kernel's send buffer. That's fine for TUS, which is request/response
// by design — the chunk loop is already a natural pacing point.

import 'dart:async';

/// Default fallback rate used by [ThrottleOptions.bandwidthFraction] when no
/// measured link speed is available. 512 KB/s is conservative enough to avoid
/// saturating a phone's cellular link on the first run, and can be overridden
/// per call via [BandwidthFractionThrottle.fallbackBytesPerSecond].
const int kDefaultThrottleFallbackBytesPerSecond = 512 * 1024;

/// Sealed configuration for throttling an upload.
///
/// Use the factory constructors to build a value:
///
/// ```dart
/// ThrottleOptions.none();
/// ThrottleOptions.bandwidthFraction(0.3);
/// ThrottleOptions.bytesPerSecond(2 * 1024 * 1024);
/// ```
sealed class ThrottleOptions {
  const ThrottleOptions();

  /// No throttling. The client behaves exactly as before this feature existed.
  const factory ThrottleOptions.none() = NoThrottle;

  /// Cap the upload to [fraction] of the measured link speed.
  ///
  /// E.g. `0.3` ≈ "use ~30% of the bandwidth". When the link speed has not
  /// been measured (e.g. `measureUploadSpeed` is false on `upload()`, or the
  /// speed test failed), the throttle falls back to
  /// [fallbackBytesPerSecond] (default [kDefaultThrottleFallbackBytesPerSecond]).
  const factory ThrottleOptions.bandwidthFraction(
    double fraction, {
    int? fallbackBytesPerSecond,
  }) = BandwidthFractionThrottle;

  /// Hard cap to [bytesPerSecond], regardless of measured link speed.
  const factory ThrottleOptions.bytesPerSecond(int bytesPerSecond) =
      BytesPerSecondThrottle;
}

/// Throttling is disabled.
final class NoThrottle implements ThrottleOptions {
  const NoThrottle();
}

/// Cap the upload to a fraction of the measured link speed.
final class BandwidthFractionThrottle implements ThrottleOptions {
  /// Fraction of the measured link speed to use, in `0.0..1.0`.
  ///
  /// Values outside `[0, 1]` are clamped to that range at resolve time.
  final double fraction;

  /// Absolute fallback rate used when no link speed has been measured.
  /// If null, defaults to [kDefaultThrottleFallbackBytesPerSecond].
  final int? fallbackBytesPerSecond;

  const BandwidthFractionThrottle(this.fraction, {this.fallbackBytesPerSecond});
}

/// Hard cap to an absolute bytes-per-second.
final class BytesPerSecondThrottle implements ThrottleOptions {
  final int bytesPerSecond;
  const BytesPerSecondThrottle(this.bytesPerSecond)
      : assert(bytesPerSecond > 0, 'bytesPerSecond must be > 0');
}

/// A token bucket that paces traffic at a fixed rate.
///
/// `capacity` is the maximum burst (one chunk by default).
/// Tokens refill continuously at `rateTokensPerSecond`.
/// `acquire(n)` returns a future that completes when `n` tokens are available.
class TokenBucket {
  final double rateTokensPerSecond;
  final double capacity;
  double _tokens;
  // Use a monotonic, microsecond-precision clock. DateTime.now() is
  // millisecond-resolution and can jump on wall-clock changes; Stopwatch
  // is monotonic and gives us microsecond ticks via elapsed.inMicroseconds.
  final Stopwatch _clock = Stopwatch()..start();
  Duration _lastElapsed = Duration.zero;

  TokenBucket._({
    required this.rateTokensPerSecond,
    required this.capacity,
    required double initialTokens,
  })  : assert(rateTokensPerSecond > 0, 'rate must be > 0'),
        assert(capacity > 0, 'capacity must be > 0'),
        _tokens = initialTokens;

  /// Build a bucket paced at [rateBytesPerSecond] bytes per second.
  factory TokenBucket.bytesPerSecond(int rateBytesPerSecond) {
    return TokenBucket._(
      rateTokensPerSecond: rateBytesPerSecond.toDouble(),
      capacity: 1.0, // unused when acquire uses exact byte counts
      initialTokens: 0.0,
    );
  }

  /// Wait until [bytes] tokens are available, then consume them.
  ///
  /// If the requested byte count exceeds the current token balance, sleeps
  /// just long enough to accrue the deficit. Returns the actual wait time.
  Future<Duration> acquire(int bytes) async {
    if (bytes <= 0) return Duration.zero;
    final wait = _refill(bytes);
    _tokens -= bytes;
    if (wait > Duration.zero) {
      await Future<void>.delayed(wait);
    }
    return wait;
  }

  /// Refill tokens based on elapsed time, then return how long the caller
  /// must wait before the requested [needed] tokens are available.
  Duration _refill(int needed) {
    final now = _clock.elapsed;
    final last = _lastElapsed;
    _lastElapsed = now;
    final elapsedSeconds = (now - last).inMicroseconds / 1e6;
    _tokens =
        (_tokens + elapsedSeconds * rateTokensPerSecond).clamp(0, capacity);
    if (_tokens >= needed) return Duration.zero;
    final deficit = needed - _tokens;
    final waitMicros = (deficit / rateTokensPerSecond * 1e6).ceil();
    return Duration(microseconds: waitMicros);
  }
}

/// Resolve a [ThrottleOptions] against a measured [uploadSpeed] (Mb/s) and
/// return a configured [TokenBucket], or `null` when throttling is disabled.
///
/// `uploadSpeed` is in megabits per second (matches [TusClientBase.uploadSpeed]).
/// Pass `null` if the speed was not measured.
TokenBucket? resolveThrottle(ThrottleOptions options, double? uploadSpeed) {
  return switch (options) {
    NoThrottle() => null,
    BytesPerSecondThrottle(:final bytesPerSecond) =>
      TokenBucket.bytesPerSecond(bytesPerSecond),
    BandwidthFractionThrottle(
      :final fraction,
      :final fallbackBytesPerSecond,
    ) =>
      () {
        // Guard against NaN/negative inputs — fall through to "no throttle".
        if (fraction.isNaN || fraction <= 0) return null;
        final clampedFraction = fraction.clamp(0.0, 1.0);
        if (uploadSpeed != null && uploadSpeed > 0) {
          // uploadSpeed is in megabits per second (Mbps). Convert to
          // bytes per second by dividing by 8 (8 bits per byte).
          // Note: dividing by 8 here is correct even though the value
          // is in *decimal* megabits (1 Mbps = 1_000_000 bits/s, not
          // 1_048_576). TUS servers and speed-test libraries report
          // speeds in decimal megabits.
          final rate = (uploadSpeed * 1000000 / 8 * clampedFraction).round();
          if (rate <= 0) return null; // fraction is ~0 → no-op
          return TokenBucket.bytesPerSecond(rate);
        }
        final fallback = fallbackBytesPerSecond ??
            kDefaultThrottleFallbackBytesPerSecond;
        if (fallback <= 0) return null;
        return TokenBucket.bytesPerSecond(fallback);
      }(),
  };
}
