import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Rebuild helper for states driven by the core's synchronous streams.
///
/// Dartvex streams are `broadcast(sync: true)`: an event is delivered inside
/// the call that caused it. When that call happens during a build or layout
/// pass — `loadMore()` from a `ListView.itemBuilder`, a lazy client that
/// connects because a descendant subscribed in `didChangeDependencies`,
/// `loginFromCache()` from a descendant's `initState` — a listener that is an
/// ancestor of the element being built cannot call `setState` (Flutter throws
/// "setState() or markNeedsBuild() called during build").
///
/// [applyAndRebuild] applies the state change immediately and rebuilds right
/// away when that is legal, or right after the current frame otherwise. The
/// deferred rebuild reads the latest fields, so out-of-order delivery cannot
/// resurrect a stale value.
mixin ConvexSafeRebuild<W extends StatefulWidget> on State<W> {
  bool _rebuildScheduled = false;

  /// Runs [update] and rebuilds this state, deferring the rebuild to a
  /// post-frame callback while a frame is building or laying out.
  ///
  /// No-op once the state is unmounted.
  void applyAndRebuild(VoidCallback update) {
    if (!mounted) {
      return;
    }
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      setState(update);
      return;
    }
    update();
    if (_rebuildScheduled) {
      return;
    }
    _rebuildScheduled = true;
    binding.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (mounted) {
        setState(() {});
      }
    });
  }
}
