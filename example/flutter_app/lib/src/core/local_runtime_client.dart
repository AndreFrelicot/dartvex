import 'dart:async';

import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:dartvex_local/dartvex_local.dart';

class LocalConvexRuntimeClient implements ConvexRuntimeClient {
  LocalConvexRuntimeClient(this._client, {this.disposeClient = false}) {
    _connectionStateSubscription = _client.connectionState.listen((state) {
      _currentConnectionState = _mapConnectionState(state);
    });
  }

  final ConvexLocalClient _client;
  final bool disposeClient;
  late final StreamSubscription<LocalConnectionState>
  _connectionStateSubscription;
  ConvexConnectionState _currentConnectionState =
      ConvexConnectionState.connecting;
  bool _disposed = false;

  @override
  Stream<ConvexConnectionState> get connectionState =>
      _client.connectionState.map(_mapConnectionState);

  @override
  ConvexConnectionState get currentConnectionState => _currentConnectionState;

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
    if (disposeClient) {
      unawaited(_client.dispose());
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
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final result = await query(name, args);
    return result as T;
  }

  @override
  ConvexRuntimeSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _LocalRuntimeSubscription(_client.subscribe(name, args));
  }

  static ConvexConnectionState _mapConnectionState(LocalConnectionState state) {
    return switch (state) {
      LocalConnectionState.online => ConvexConnectionState.connected,
      LocalConnectionState.syncing => ConvexConnectionState.connecting,
      LocalConnectionState.offline => ConvexConnectionState.disconnected,
    };
  }
}

class _LocalRuntimeSubscription implements ConvexRuntimeSubscription {
  _LocalRuntimeSubscription(this._subscription)
    : _stream = _subscription.stream.map((event) {
        switch (event) {
          case LocalQuerySuccess(:final value):
            return ConvexRuntimeQuerySuccess(
              value,
              source: _mapSource(event.source),
              hasPendingWrites: event.hasPendingWrites,
            );
          case LocalQueryError(:final error):
            return ConvexRuntimeQueryError(
              error,
              source: _mapSource(event.source),
              hasPendingWrites: event.hasPendingWrites,
            );
        }
      });

  final LocalSubscription _subscription;
  final Stream<ConvexRuntimeQueryEvent> _stream;

  @override
  Stream<ConvexRuntimeQueryEvent> get stream => _stream;

  @override
  void cancel() {
    _subscription.cancel();
  }

  static ConvexQuerySource _mapSource(LocalQuerySource source) {
    return switch (source) {
      LocalQuerySource.remote => ConvexQuerySource.remote,
      LocalQuerySource.cache => ConvexQuerySource.cache,
      LocalQuerySource.unknown => ConvexQuerySource.unknown,
    };
  }
}
