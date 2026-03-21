import 'dart:async';

import 'auth/auth_manager.dart';
import 'auth/auth_provider.dart';
import 'auth/client_with_auth.dart';
import 'config.dart';
import 'exceptions.dart';
import 'logging.dart';
import 'protocol/messages.dart';
import 'sync/base_client.dart';
import 'sync/remote_query_set.dart';
import 'transport/ws_factory.dart';
import 'transport/ws_manager.dart';

/// High-level connection state exposed by [ConvexClient].
enum ConnectionState {
  /// The initial connection attempt is in progress.
  connecting,

  /// The WebSocket connection is established.
  connected,

  /// The client is reconnecting after a disconnect.
  reconnecting,

  /// The client is disconnected.
  disconnected,
}

/// Base class for query subscription results.
sealed class QueryResult {
  /// Creates a query result.
  const QueryResult();
}

/// Query result representing a successful value.
class QuerySuccess extends QueryResult {
  /// Creates a successful query result.
  const QuerySuccess(this.value);

  /// Returned query value.
  final dynamic value;
}

/// Query result representing an error.
class QueryError extends QueryResult {
  /// Creates a failed query result.
  const QueryError(this.message);

  /// Human-readable error message.
  final String message;
}

/// Handle for a live Convex query subscription.
class ConvexSubscription {
  /// Creates a query subscription wrapper.
  ConvexSubscription({
    required Stream<QueryResult> stream,
    required Future<void> Function() onCancel,
  })  : _stream = stream,
        _onCancel = onCancel;

  final Stream<QueryResult> _stream;
  final Future<void> Function() _onCancel;

  /// Stream of live query results.
  Stream<QueryResult> get stream => _stream;

  /// Cancels the subscription asynchronously.
  void cancel() {
    unawaited(_onCancel());
  }
}

/// Interface for calling Convex queries, mutations, and actions.
abstract interface class ConvexFunctionCaller {
  /// Executes a query and resolves with its first successful value.
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

  /// Subscribes to a reactive query.
  ConvexSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]);

  /// Executes a mutation.
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]);

  /// Executes an action.
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]);
}

/// Main Dartvex client for communicating with a Convex deployment.
class ConvexClient implements ConvexFunctionCaller, DartvexLogSource {
  /// Creates a [ConvexClient] for [deploymentUrl].
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
      logLevel: _config.logLevel,
      logger: _config.logger,
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

  /// Broadcasts connection state changes.
  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  /// Current connection state.
  ConnectionState get currentConnectionState => _currentConnectionState;

  /// Broadcasts whether the backend currently considers the client authenticated.
  Stream<bool> get authState => _authStateController.stream;

  @override

  /// Minimum log level configured for this client.
  DartvexLogLevel get logLevel => _config.logLevel;

  @override

  /// Structured log sink configured for this client.
  DartvexLogger? get logger => _config.logger;

  @override

  /// Executes a one-shot query by subscribing until the first result arrives.
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _log(
      DartvexLogLevel.debug,
      'Starting query',
      data: _requestData(name, args),
    );
    final subscription = subscribe(name, args);
    final completer = Completer<dynamic>();
    late final StreamSubscription<QueryResult> streamSubscription;
    streamSubscription = subscription.stream.listen((event) {
      if (completer.isCompleted) {
        return;
      }
      switch (event) {
        case QuerySuccess(:final value):
          _log(
            DartvexLogLevel.debug,
            'Query succeeded',
            data: <String, Object?>{
              ..._requestData(name, args),
              'resultType': value.runtimeType.toString(),
            },
          );
          completer.complete(value);
        case QueryError(:final message):
          _log(
            DartvexLogLevel.error,
            'Query failed',
            data: <String, Object?>{
              ..._requestData(name, args),
              'errorMessage': message,
            },
          );
          completer.completeError(ConvexException(message));
      }
      unawaited(streamSubscription.cancel());
      subscription.cancel();
    });
    return completer.future;
  }

  @override

  /// Executes a typed one-shot query.
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final result = await query(name, args);
    return result as T;
  }

  @override

  /// Subscribes to a live query.
  ConvexSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    _assertNotDisposed();
    _log(
      DartvexLogLevel.debug,
      'Subscribing query',
      data: _requestData(name, args),
    );
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
        _log(
          DartvexLogLevel.debug,
          'Unsubscribing query',
          data: _requestData(name, args),
        );
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

  /// Executes a mutation.
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertConnectedForRequest('mutation');
    _log(
      DartvexLogLevel.debug,
      'Starting mutation',
      data: _requestData(name, args),
    );
    try {
      final result = _baseClient.mutate(name, args);
      await _flushOutgoing();
      _log(
        DartvexLogLevel.debug,
        'Mutation succeeded',
        data: <String, Object?>{
          ..._requestData(name, args),
          'resultType': result.runtimeType.toString(),
        },
      );
      return result;
    } catch (error, stackTrace) {
      _log(
        DartvexLogLevel.error,
        'Mutation failed',
        error: error,
        stackTrace: stackTrace,
        data: _requestData(name, args),
      );
      rethrow;
    }
  }

  @override

  /// Executes an action.
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertConnectedForRequest('action');
    _log(
      DartvexLogLevel.debug,
      'Starting action',
      data: _requestData(name, args),
    );
    try {
      final result = _baseClient.action(name, args);
      await _flushOutgoing();
      _log(
        DartvexLogLevel.debug,
        'Action succeeded',
        data: <String, Object?>{
          ..._requestData(name, args),
          'resultType': result.runtimeType.toString(),
        },
      );
      return result;
    } catch (error, stackTrace) {
      _log(
        DartvexLogLevel.error,
        'Action failed',
        error: error,
        stackTrace: stackTrace,
        data: _requestData(name, args),
      );
      rethrow;
    }
  }

  /// Applies a fixed auth token to the client.
  Future<void> setAuth(String? token) {
    _assertNotDisposed();
    _log(
      DartvexLogLevel.info,
      token == null ? 'Clearing auth token' : 'Setting auth token',
    );
    return _authManager.setAuth(token);
  }

  /// Configures automatic auth refresh driven by [fetchToken].
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

  /// Clears auth state and token refresh handling.
  Future<void> clearAuth() {
    _assertNotDisposed();
    _log(DartvexLogLevel.info, 'Clearing auth state');
    return _authManager.clearAuth();
  }

  /// Updates the current auth token without recreating the refresh flow.
  Future<void> updateAuthToken(String token) {
    _assertNotDisposed();
    _log(DartvexLogLevel.info, 'Updating auth token');
    return _authManager.updateToken(token);
  }

  /// Returns an auth-aware wrapper around this client.
  ConvexClientWithAuth<TUser> withAuth<TUser>(
      AuthProvider<TUser> authProvider) {
    _assertNotDisposed();
    return ConvexClientWithAuth<TUser>(
      client: this,
      authProvider: authProvider,
    );
  }

  /// Disposes subscriptions, auth management, and transport resources.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _log(DartvexLogLevel.debug, 'Disposing client');
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
    _log(
      DartvexLogLevel.info,
      'Connection state changed',
      data: <String, Object?>{'state': state.name},
    );
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

  Map<String, Object?> _requestData(
    String name,
    Map<String, dynamic> args,
  ) {
    return <String, Object?>{
      'name': name,
      'argCount': args.length,
      if (args.isNotEmpty) 'argKeys': args.keys.toList(growable: false),
    };
  }

  void _log(
    DartvexLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) {
    emitDartvexLog(
      configuredLevel: _config.logLevel,
      logger: _config.logger,
      eventLevel: level,
      message: message,
      tag: 'client',
      error: error,
      stackTrace: stackTrace,
      data: data,
    );
  }
}
