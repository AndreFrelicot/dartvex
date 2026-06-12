import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dartvex/dartvex.dart';

/// A [ConnectivitySignal] backed by the `connectivity_plus` plugin.
///
/// Emits on [ConnectivitySignal.onRestored] when the device transitions from
/// offline to having a usable network interface, letting [ConvexClient] cancel
/// its reconnect backoff and reconnect immediately.
///
/// Wire it into the client configuration:
///
/// ```dart
/// final client = ConvexClient(
///   deploymentUrl,
///   config: ConvexClientConfig(
///     connectivitySignal: ConnectivityPlusSignal(),
///   ),
/// );
/// ```
class ConnectivityPlusSignal implements ConnectivitySignal {
  /// Creates a signal that listens to connectivity changes.
  ///
  /// [changes] defaults to `Connectivity().onConnectivityChanged` and can be
  /// overridden in tests.
  ConnectivityPlusSignal({Stream<List<ConnectivityResult>>? changes})
    : _changes = changes ?? Connectivity().onConnectivityChanged;

  final Stream<List<ConnectivityResult>> _changes;

  @override
  Stream<void> get onRestored {
    var online = false;
    return _changes
        .where((results) {
          final nowOnline = results.any(
            (result) => result != ConnectivityResult.none,
          );
          final restored = nowOnline && !online;
          online = nowOnline;
          return restored;
        })
        .map<void>((_) {});
  }
}
