import 'dart:async';

import 'auth/auth_manager.dart';
import 'auth/auth_provider.dart';
import 'auth/client_with_auth.dart';
import 'config.dart';
import 'exceptions.dart';
import 'protocol/messages.dart';
import 'sync/base_client.dart';
import 'sync/remote_query_set.dart';
import 'transport/ws_factory.dart';
import 'transport/ws_manager.dart';

enum ConnectionState { connecting, connected, reconnecting, disconnected }

sealed class QueryResult {
  const QueryResult();
}

class QuerySuccess extends QueryResult {
  const QuerySuccess(this.value);

  final dynamic value;
}

class QueryError extends QueryResult {
  const QueryError(this.message);

  final String message;
}

class ConvexSubscription {
  ConvexSubscription({
    required Stream<QueryResult> stream,
    required Future<void> Function() onCancel,
  })  : _stream = stream,
        _onCancel = onCancel;

  final Stream<QueryResult> _stream;
  final Future<void> Function() _onCancel;

  Stream<QueryResult> get stream => _stream;

  void cancel() {
    unawaited(_onCancel());
  }
}

abstract interface class ConvexFunctionCaller {
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]);

  /// Execute a one-shot query with a typed return value.
  ///
  /// Subscribes, waits for the first result, then unsubscribes.
  /// Useful for splash screen data, prefetching, or non-reactive reads.
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]);

  ConvexSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]);

  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]);

  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]);
}

class ConvexClient implements ConvexFunctionCaller {
  ConvexClient(
    String deploymentUrl, {
    ConvexClientConfig? config,
    TransitionMetricsCallback? onTransitionMetrics,
  })  : _deploymentUrl = deploymentUrl,
        _config = config ?? const ConvexClientConfig(),
        _baseClient = BaseClient(),
        _connectionStateController =
            StreamController<ConnectionState>.broadcast(
          sync: true,
        ),
        _authStateController = StreamController<bool>.broadcast(sync: true),
        _subscriptionControllers = <int, StreamController<QueryResult>>{},
        _currentConnectionState = ConnectionState.connecting {
    _wsManager = WebSocketManager(
      adapter: _config.adapterFactory?.call(_config.clientId) ??
          createDefaultWebSocketAdapter(_config.clientId),
      deploymentUrl: _deploymentUrl,
      apiVersion: _config.apiVersion,
      onConnected: _handleConnected,
      onMessage: _handleServerMessage,
      onDisconnected: (reason) async {
        _baseClient.handleDisconnect(reason);
      },
      onConnectionStateChanged: _handleConnectionStateChange,
      maxObservedTimestamp: () => _baseClient.maxObservedTimestamp,
      reconnectBackoff: _config.reconnectBackoff,
      inactivityTimeout: _config.inactivityTimeout,
      onTransitionMetrics: onTransitionMetrics,
    );
    _authManager = AuthManager(
      config: _config,
      sendAuth: _sendAuth,
      emitAuthState: (isAuthenticated) {
        if (!_authStateController.isClosed) {
          _authStateController.add(isAuthenticated);
        }
      },
    );
    _connectionStateController.add(_currentConnectionState);
    _authStateController.add(false);
    unawaited(_wsManager.start());
  }

  final String _deploymentUrl;
  final ConvexClientConfig _config;
  final BaseClient _baseClient;
  late final WebSocketManager _wsManager;
  late final AuthManager _authManager;
  final StreamController<ConnectionState> _connectionStateController;
  final StreamController<bool> _authStateController;
  final Map<int, StreamController<QueryResult>> _subscriptionControllers;
  ConnectionState _currentConnectionState;
  bool _refreshAuthOnNextConnect = false;
  bool _disposed = false;

  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  ConnectionState get currentConnectionState => _currentConnectionState;

  Stream<bool> get authState => _authStateController.stream;

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final subscription = subscribe(name, args);
    final completer = Completer<dynamic>();
    late final StreamSubscription<QueryResult> streamSubscription;
    streamSubscription = subscription.stream.listen((event) {
      if (completer.isCompleted) {
        return;
      }
      switch (event) {
        case QuerySuccess(:final value):
          completer.complete(value);
        case QueryError(:final message):
          completer.completeError(ConvexException(message));
      }
      unawaited(streamSubscription.cancel());
      subscription.cancel();
    });
    return completer.future;
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
  ConvexSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    _assertNotDisposed();
    final registration = _baseClient.subscribe(name, args);
    final controller = StreamController<QueryResult>.broadcast(sync: true);
    _subscriptionControllers[registration.subscriberId] = controller;

    final current = _baseClient.currentResultForQuery(registration.queryId) ??
        _baseClient.cachedResultForQuery(name, args);
    if (current != null) {
      scheduleMicrotask(() {
        if (!controller.isClosed) {
          controller.add(_toPublicQueryResult(current));
        }
      });
    }

    unawaited(_flushOutgoing());

    return ConvexSubscription(
      stream: controller.stream,
      onCancel: () async {
        final removed = _subscriptionControllers.remove(
          registration.subscriberId,
        );
        _baseClient.unsubscribe(registration.subscriberId);
        await _flushOutgoing();
        await removed?.close();
      },
    );
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertConnectedForRequest('mutation');
    final result = _baseClient.mutate(name, args);
    await _flushOutgoing();
    return result;
  }

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertConnectedForRequest('action');
    final result = _baseClient.action(name, args);
    await _flushOutgoing();
    return result;
  }

  Future<void> setAuth(String? token) {
    _assertNotDisposed();
    return _authManager.setAuth(token);
  }

  Future<AuthHandle> setAuthWithRefresh({
    required AuthTokenFetcher fetchToken,
    void Function(bool)? onAuthChange,
  }) {
    _assertNotDisposed();
    return _authManager.setAuthWithRefresh(
      fetchToken: fetchToken,
      onAuthChange: onAuthChange,
    );
  }

  Future<void> clearAuth() {
    _assertNotDisposed();
    return _authManager.clearAuth();
  }

  Future<void> updateAuthToken(String token) {
    _assertNotDisposed();
    return _authManager.updateToken(token);
  }

  ConvexClientWithAuth<TUser> withAuth<TUser>(
      AuthProvider<TUser> authProvider) {
    _assertNotDisposed();
    return ConvexClientWithAuth<TUser>(
      client: this,
      authProvider: authProvider,
    );
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final subscriptionControllers = _subscriptionControllers.values.toList();
    _subscriptionControllers.clear();
    scheduleMicrotask(() async {
      for (final controller in subscriptionControllers) {
        await controller.close();
      }
      await _connectionStateController.close();
      await _authStateController.close();
    });
    unawaited(_authManager.stopRefreshing());
    unawaited(_wsManager.dispose());
  }

  Future<void> _sendAuth(String? token) async {
    if (token == null) {
      _baseClient.clearAuth();
    } else {
      _baseClient.setAuth(tokenType: _config.authTokenType, token: token);
    }
    await _flushOutgoing();
  }

  Future<List<ClientMessage>> _handleConnected() async {
    if (_refreshAuthOnNextConnect) {
      _refreshAuthOnNextConnect = false;
      await _authManager.refreshAuthForReconnect();
      final token = _authManager.currentToken;
      if (token == null) {
        _baseClient.restoreAuth(tokenType: 'None');
      } else {
        _baseClient.restoreAuth(tokenType: _config.authTokenType, token: token);
      }
    }
    return _baseClient.prepareReconnect();
  }

  Future<List<ClientMessage>> _handleServerMessage(
    ServerMessage message,
  ) async {
    final result = _baseClient.receive(message);
    for (final event in result.events) {
      switch (event) {
        case QueryUpdateEvent():
          for (final subscriberId in _baseClient.subscriberIdsForQuery(
            event.queryId,
          )) {
            _subscriptionControllers[subscriberId]?.add(
              _toPublicQueryResult(event.result),
            );
          }
        case QueryRemovedEvent():
          for (final subscriberId in _baseClient.subscriberIdsForQuery(
            event.queryId,
          )) {
            _subscriptionControllers[subscriberId]?.add(
              const QueryError('Query removed'),
            );
          }
        case AuthConfirmedEvent():
          _authManager.handleAuthConfirmed();
        case AuthErrorEvent():
          await _authManager.handleAuthError(event.error);
        case ReconnectRequiredEvent():
          await _wsManager.reconnectNow(event.reason);
      }
    }
    return result.outgoing;
  }

  QueryResult _toPublicQueryResult(StoredQueryResult result) {
    switch (result) {
      case StoredQuerySuccess():
        return QuerySuccess(result.value);
      case StoredQueryError():
        return QueryError(result.message);
    }
  }

  void _handleConnectionStateChange(bool connected, bool reconnecting) {
    if (_connectionStateController.isClosed) {
      return;
    }
    if (connected) {
      _emitConnectionState(ConnectionState.connected);
      return;
    }
    if (reconnecting) {
      final nextState = _currentConnectionState == ConnectionState.connecting
          ? ConnectionState.connecting
          : ConnectionState.reconnecting;
      _refreshAuthOnNextConnect = nextState == ConnectionState.reconnecting;
      _emitConnectionState(
        nextState,
      );
      return;
    }
    _emitConnectionState(ConnectionState.disconnected);
  }

  void _emitConnectionState(ConnectionState state) {
    _currentConnectionState = state;
    _connectionStateController.add(state);
  }

  Future<void> _flushOutgoing() {
    return _wsManager.sendMessages(_baseClient.drainOutgoing());
  }

  void _assertConnectedForRequest(String label) {
    _assertNotDisposed();
    if (!_wsManager.isConnected) {
      throw ConvexException(
        'Cannot send $label while disconnected',
        retryable: true,
      );
    }
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw const ConvexException('ConvexClient has been disposed');
    }
  }
}
