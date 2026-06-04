import 'package:dartvex/src/transport/monotonic_clock.dart';
import 'package:test/test.dart';

void main() {
  group('MonotonicClock', () {
    test('reads the anchor plus the elapsed source', () {
      var elapsed = 0;
      final clock = MonotonicClock.fromSources(
        epochAnchorMillis: 1000,
        elapsedMillis: () => elapsed,
      );

      expect(clock.nowMillis, 1000);
      elapsed = 250;
      expect(clock.nowMillis, 1250);
    });

    test('advances monotonically as elapsed time grows', () {
      var elapsed = 0;
      final clock = MonotonicClock.fromSources(
        epochAnchorMillis: 5000,
        elapsedMillis: () => elapsed,
      );

      var previous = clock.nowMillis;
      for (final next in <int>[1, 1, 5, 40, 41, 1000]) {
        elapsed = next;
        final now = clock.nowMillis;
        expect(now, greaterThanOrEqualTo(previous));
        previous = now;
      }
      expect(clock.nowMillis, 6000);
    });

    test('reading is independent of the wall clock moving backwards', () {
      // The anchor is captured once at construction; a wall clock that later
      // jumps backwards cannot pull the reading back, because the clock only
      // ever adds monotonic elapsed time to the fixed anchor.
      var elapsed = 100;
      final clock = MonotonicClock.fromSources(
        epochAnchorMillis: 2000,
        elapsedMillis: () => elapsed,
      );

      final before = clock.nowMillis; // 2100
      // Simulate time passing (the only thing that may change the reading).
      elapsed = 130;
      final after = clock.nowMillis; // 2130

      expect(before, 2100);
      expect(after, 2130);
      expect(after, greaterThan(before));
    });

    test('default clock is non-decreasing and near the wall clock', () {
      final wallBefore = DateTime.now().millisecondsSinceEpoch;
      final clock = MonotonicClock();
      final first = clock.nowMillis;
      final second = clock.nowMillis;
      final wallAfter = DateTime.now().millisecondsSinceEpoch;

      expect(second, greaterThanOrEqualTo(first));
      // Anchored to the wall clock at construction, so it sits within the window
      // the wall clock spanned around it (with a small slack for rounding).
      expect(first, greaterThanOrEqualTo(wallBefore - 1000));
      expect(first, lessThanOrEqualTo(wallAfter + 1000));
    });
  });
}
