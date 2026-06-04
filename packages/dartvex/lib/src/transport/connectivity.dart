/// Platform-agnostic signal that the device has regained network connectivity.
///
/// The core [ConvexClient] stays free of any platform networking dependency.
/// Supply an implementation (for example a `connectivity_plus`-backed one from
/// `dartvex_flutter`) via [ConvexClientConfig.connectivitySignal] to have the
/// client reconnect immediately when the network returns instead of waiting out
/// the reconnect backoff.
abstract interface class ConnectivitySignal {
  /// Emits each time the device transitions from offline to having a usable
  /// network interface.
  ///
  /// Implementations should emit only on the offline→online edge, not for every
  /// connectivity change, and should not emit while already online.
  Stream<void> get onRestored;
}
