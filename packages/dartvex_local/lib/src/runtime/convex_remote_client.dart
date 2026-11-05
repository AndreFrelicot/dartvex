import 'dart:async';

import 'package:dartvex/dartvex.dart';

import '../client.dart';

/// Adapts a [ConvexClient] into the [LocalRemoteClient] interface.
class ConvexRemoteClientAdapter implements LocalRemoteClient {
  /// Creates an adapter around [_client].
  ///
  /// When [disposeClient] is true, disposing the adapter also disposes the client.
  ConvexRemoteClientAdapter(this._client, {this.disposeClient = false})
    : _currentConnectionState = _mapConnectionState(
        _client.currentConnectionState,
      ) {
    _connectionStateSubscription = _client.connectionState.listen(
      (state) {
        if (_clientClosed) {
          return;
        }
        _currentConnectionState = _mapConnectionState(state);
        if (!_connectionStateController.isClosed) {
          _connectionStateController.add(_currentConnectionState);
        }
      },
      // The core closes its connection-state stream when it is closed or
      // disposed, without emitting a final state.
      onDone: _markClientClosed,
    );
  }

  final ConvexClient _client;

  /// Whether disposing this adapter should also dispose the wrapped client.
  final bool disposeClient;
  final StreamController<LocalRemoteConnectionState>
  _connectionStateController =
      StreamController<LocalRemoteConnectionState>.broadcast(sync: true);
  late final StreamSubscription<ConnectionState> _connectionStateSubscription;
  LocalRemoteConnectionState _currentConnectionState;
  bool _disposed = false;
  bool _clientClosed = false;

  /// Reports the wrapped client as permanently disconnected once it has been
  /// closed or disposed.
  ///
  /// The core client fails in-flight requests with a non-retryable
  /// "has been disposed" error and never emits a final connection state, so
  /// without this the local client would keep treating the remote as connected
  /// and classify those lifecycle failures as server rejections.
  void _markClientClosed() {
    if (_clientClosed) {
      return;
    }
    _clientClosed = true;
    _currentConnectionState = LocalRemoteConnectionState.disconnected;
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(_currentConnectionState);
    }
  }

  Future<dynamic> _observeLifecycle(Future<dynamic> Function() call) async {
    try {
      return await call();
    } catch (error) {
      if (isConvexClientClosedError(error)) {
        _markClientClosed();
      }
      rethrow;
    }
  }

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
    return _observeLifecycle(() => _client.action(name, args));
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
    return _observeLifecycle(() => _client.mutate(name, args));
  }

  @override
  /// Executes a remote query through the wrapped client.
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _observeLifecycle(() => _client.query(name, args));
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
      ConnectionState.fatalError => LocalRemoteConnectionState.disconnected,
    };
  }
}

class _ConvexRemoteSubscriptionAdapter implements LocalRemoteSubscription {
  _ConvexRemoteSubscriptionAdapter(this._subscription)
    : _stream = _tagInitialSeed(_subscription.stream);

  final ConvexSubscription _subscription;
  final Stream<LocalRemoteQueryEvent> _stream;

  @override
  Stream<LocalRemoteQueryEvent> get stream => _stream;

  @override
  void cancel() {
    _subscription.cancel();
  }

  /// Maps core results, marking the value the core delivers from its own
  /// local state when a listener attaches as a seed.
  ///
  /// The core emits that initial value from a microtask it schedules while the
  /// listener attaches, before any server update for the new subscription can
  /// arrive. A microtask scheduled right after attaching therefore runs after
  /// the seed, and closes the seed window.
  static Stream<LocalRemoteQueryEvent> _tagInitialSeed(
    Stream<QueryResult> source,
  ) {
    return Stream<LocalRemoteQueryEvent>.multi((controller) {
      var inSeedWindow = true;
      final subscription = source.listen(
        (event) => controller.addSync(_mapResult(event, isSeed: inSeedWindow)),
        onError: controller.addErrorSync,
        onDone: controller.closeSync,
      );
      scheduleMicrotask(() => inSeedWindow = false);
      controller
        ..onPause = subscription.pause
        ..onResume = subscription.resume
        ..onCancel = subscription.cancel;
    }, isBroadcast: source.isBroadcast);
  }

  static LocalRemoteQueryEvent _mapResult(
    QueryResult event, {
    required bool isSeed,
  }) {
    switch (event) {
      case QuerySuccess(:final value):
        return LocalRemoteQuerySuccess(value, isSeed: isSeed);
      case QueryLoading(:final hasPendingWrites):
        return LocalRemoteQueryLoading(hasPendingWrites: hasPendingWrites);
      case QueryError(:final message, :final data, :final logLines):
        return LocalRemoteQueryError(
          ConvexException(message, data: data, logLines: logLines),
        );
    }
  }
}

/// Whether [error] is the failure a closed or disposed [ConvexClient] reports
/// for in-flight and new requests.
///
/// Those failures are non-retryable [ConvexException]s, so they are told apart
/// from real server rejections by their message. Used to stop replay from
/// dropping queued mutations as conflicts when the remote client is closed.
bool isConvexClientClosedError(Object error) {
  if (error is! ConvexException || error.retryable) {
    return false;
  }
  final message = error.message;
  return message.startsWith('ConvexClient has been') &&
      (message.endsWith('disposed') || message.endsWith('closed'));
}
