import 'dart:async';

import 'package:dartvex/dartvex.dart';

import '../client.dart';

/// Adapts a [ConvexClient] into the [LocalRemoteClient] interface.
class ConvexRemoteClientAdapter implements LocalRemoteClient {
  /// Creates an adapter around [_client].
  ///
  /// When [disposeClient] is true, disposing the adapter also disposes the client.
  ConvexRemoteClientAdapter(this._client, {this.disposeClient = false}) {
    _connectionStateSubscription = _client.connectionState.listen((state) {
      _currentConnectionState = _mapConnectionState(state);
      if (!_connectionStateController.isClosed) {
        _connectionStateController.add(_currentConnectionState);
      }
    });
  }

  final ConvexClient _client;

  /// Whether disposing this adapter should also dispose the wrapped client.
  final bool disposeClient;
  final StreamController<LocalRemoteConnectionState>
      _connectionStateController =
      StreamController<LocalRemoteConnectionState>.broadcast(sync: true);
  late final StreamSubscription<ConnectionState> _connectionStateSubscription;
  LocalRemoteConnectionState _currentConnectionState =
      LocalRemoteConnectionState.connecting;
  bool _disposed = false;

  @override

  /// Broadcasts mapped remote connection states from the wrapped [ConvexClient].
  Stream<LocalRemoteConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override

  /// The current remote connection state.
  LocalRemoteConnectionState get currentConnectionState =>
      _currentConnectionState;

  @override

  /// Executes a remote action through the wrapped client.
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.action(name, args);
  }

  @override

  /// Disposes subscriptions and optionally disposes the wrapped client.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_connectionStateSubscription.cancel());
    unawaited(_connectionStateController.close());
    if (disposeClient) {
      _client.dispose();
    }
  }

  @override

  /// Executes a remote mutation through the wrapped client.
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.mutate(name, args);
  }

  @override

  /// Executes a remote query through the wrapped client.
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.query(name, args);
  }

  @override

  /// Subscribes to a remote query through the wrapped client.
  LocalRemoteSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _ConvexRemoteSubscriptionAdapter(_client.subscribe(name, args));
  }

  static LocalRemoteConnectionState _mapConnectionState(ConnectionState state) {
    return switch (state) {
      ConnectionState.connected => LocalRemoteConnectionState.connected,
      ConnectionState.connecting => LocalRemoteConnectionState.connecting,
      ConnectionState.reconnecting => LocalRemoteConnectionState.connecting,
      ConnectionState.disconnected => LocalRemoteConnectionState.disconnected,
    };
  }
}

class _ConvexRemoteSubscriptionAdapter implements LocalRemoteSubscription {
  _ConvexRemoteSubscriptionAdapter(this._subscription)
      : _stream = _subscription.stream.map((event) {
          switch (event) {
            case QuerySuccess(:final value):
              return LocalRemoteQuerySuccess(value);
            case QueryError(:final message):
              return LocalRemoteQueryError(ConvexException(message));
          }
        });

  final ConvexSubscription _subscription;
  final Stream<LocalRemoteQueryEvent> _stream;

  @override
  Stream<LocalRemoteQueryEvent> get stream => _stream;

  @override
  void cancel() {
    _subscription.cancel();
  }
}
