import 'dart:async';

import 'package:dartvex/dartvex.dart' as convex;

import 'snapshot.dart';

typedef ConvexConnectionState = convex.ConnectionState;

abstract class ConvexRuntimeClient {
  Future<dynamic> query(String name, [Map<String, dynamic> args = const {}]);

  /// Execute a one-shot query with a typed return value.
  Future<T> queryOnce<T>(String name, [Map<String, dynamic> args = const {}]);

  ConvexRuntimeSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const {},
  ]);
  Future<dynamic> mutate(String name, [Map<String, dynamic> args = const {}]);
  Future<dynamic> action(String name, [Map<String, dynamic> args = const {}]);
  Stream<ConvexConnectionState> get connectionState;
  ConvexConnectionState get currentConnectionState;
  void dispose();
}

abstract class ConvexRuntimeSubscription {
  Stream<ConvexRuntimeQueryEvent> get stream;
  void cancel();
}

sealed class ConvexRuntimeQueryEvent {
  const ConvexRuntimeQueryEvent({
    required this.source,
    required this.hasPendingWrites,
  });

  final ConvexQuerySource source;
  final bool hasPendingWrites;
}

class ConvexRuntimeQuerySuccess extends ConvexRuntimeQueryEvent {
  const ConvexRuntimeQuerySuccess(
    this.value, {
    this.logLines = const <String>[],
    super.source = ConvexQuerySource.remote,
    super.hasPendingWrites = false,
  });

  final dynamic value;
  final List<String> logLines;
}

class ConvexRuntimeQueryError extends ConvexRuntimeQueryEvent {
  const ConvexRuntimeQueryError(
    this.error, {
    this.stackTrace,
    super.source = ConvexQuerySource.unknown,
    super.hasPendingWrites = false,
  });

  final Object error;
  final StackTrace? stackTrace;
}

class ConvexClientRuntime implements ConvexRuntimeClient {
  ConvexClientRuntime(this._client, {this.disposeClient = false}) {
    _connectionStateSubscription = _client.connectionState.listen((state) {
      _currentConnectionState = state;
    });
  }

  final convex.ConvexClient _client;
  final bool disposeClient;
  late final StreamSubscription<ConvexConnectionState>
      _connectionStateSubscription;
  ConvexConnectionState _currentConnectionState =
      ConvexConnectionState.connecting;
  bool _disposed = false;

  @override
  Stream<ConvexConnectionState> get connectionState => _client.connectionState;

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
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.queryOnce<T>(name, args);
  }

  @override
  ConvexRuntimeSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _ConvexClientRuntimeSubscription(_client.subscribe(name, args));
  }
}

class _ConvexClientRuntimeSubscription implements ConvexRuntimeSubscription {
  _ConvexClientRuntimeSubscription(this._subscription)
      : _stream = _subscription.stream.map((event) {
          switch (event) {
            case convex.QuerySuccess(:final value):
              return ConvexRuntimeQuerySuccess(value);
            case convex.QueryError(:final message):
              return ConvexRuntimeQueryError(convex.ConvexException(message));
          }
        });

  final convex.ConvexSubscription _subscription;
  final Stream<ConvexRuntimeQueryEvent> _stream;

  @override
  Stream<ConvexRuntimeQueryEvent> get stream => _stream;

  @override
  void cancel() {
    _subscription.cancel();
  }
}
