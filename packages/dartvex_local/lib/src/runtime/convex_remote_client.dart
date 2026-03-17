import 'dart:async';

import 'package:dartvex/dartvex.dart';

import '../client.dart';

class ConvexRemoteClientAdapter implements LocalRemoteClient {
  ConvexRemoteClientAdapter(this._client, {this.disposeClient = false}) {
    _connectionStateSubscription = _client.connectionState.listen((state) {
      _currentConnectionState = _mapConnectionState(state);
      if (!_connectionStateController.isClosed) {
        _connectionStateController.add(_currentConnectionState);
      }
    });
  }

  final ConvexClient _client;
  final bool disposeClient;
  final StreamController<LocalRemoteConnectionState>
      _connectionStateController =
      StreamController<LocalRemoteConnectionState>.broadcast(sync: true);
  late final StreamSubscription<ConnectionState> _connectionStateSubscription;
  LocalRemoteConnectionState _currentConnectionState =
      LocalRemoteConnectionState.connecting;
  bool _disposed = false;

  @override
  Stream<LocalRemoteConnectionState> get connectionState =>
      _connectionStateController.stream;

  @override
  LocalRemoteConnectionState get currentConnectionState =>
      _currentConnectionState;

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.action(name, args);
  }

  @override
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
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.mutate(name, args);
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.query(name, args);
  }

  @override
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
