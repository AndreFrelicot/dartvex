import 'package:meta/meta.dart';

/// A millisecond clock that is anchored once to the wall clock and then advances
/// via a [Stopwatch].
///
/// Reading [nowMillis] returns the wall-clock epoch captured at construction
/// plus the time elapsed since, as measured by a [Stopwatch]. On native targets
/// the stopwatch is a high-resolution monotonic source, so the result never
/// jumps backwards when the device wall clock is corrected (NTP sync, manual
/// change, daylight-saving transitions), which keeps `Connect.clientTs` and
/// transition transit metrics meaningful as a measure of elapsed time and
/// server clock skew.
///
/// On the web `Stopwatch` is millisecond-resolution and not guaranteed strictly
/// monotonic, so the no-rewind property is best-effort there. These readings
/// feed only diagnostic metrics (transit time and clock-skew estimates), never
/// sync correctness. Using `Stopwatch` keeps this free of platform-specific
/// code and mirrors the intent of the official Convex client's monotonic clock
/// (`firstTime + performance.now()`), implemented per design decision D5.
class MonotonicClock {
  /// Creates a clock anchored to the current wall-clock epoch, advancing via a
  /// freshly started monotonic [Stopwatch].
  MonotonicClock()
      : this._(
          epochAnchorMillis: DateTime.now().millisecondsSinceEpoch,
          elapsedMillis: _startedStopwatchElapsed(),
        );

  /// Test seam: injects the [epochAnchorMillis] and the [elapsedMillis] source
  /// so tests can advance elapsed time deterministically and prove the reading
  /// is independent of the wall clock.
  @visibleForTesting
  MonotonicClock.fromSources({
    required int epochAnchorMillis,
    required int Function() elapsedMillis,
  }) : this._(
          epochAnchorMillis: epochAnchorMillis,
          elapsedMillis: elapsedMillis,
        );

  MonotonicClock._({
    required int epochAnchorMillis,
    required int Function() elapsedMillis,
  })  : _epochAnchorMillis = epochAnchorMillis,
        _elapsedMillis = elapsedMillis;

  final int _epochAnchorMillis;
  final int Function() _elapsedMillis;

  /// The current time in milliseconds since the Unix epoch.
  ///
  /// Guaranteed never to move backwards regardless of wall-clock corrections,
  /// because it is the fixed construction-time anchor plus monotonic elapsed
  /// time.
  int get nowMillis => _epochAnchorMillis + _elapsedMillis();

  static int Function() _startedStopwatchElapsed() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMilliseconds;
  }
}
