import 'dart:async';

import 'auth/auth_manager.dart';
import 'auth/auth_provider.dart';
import 'auth/client_with_auth.dart';
import 'config.dart';
import 'exceptions.dart';
import 'logging.dart';
import 'protocol/messages.dart';
import 'sync/base_client.dart';
import 'sync/optimistic_updates.dart';
import 'sync/paginated_query.dart';
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

  /// The connection ended on an unrecoverable server error and will not
  /// reconnect.
  fatalError,
}

/// A rich, immutable snapshot of the client's connection to Convex.
///
/// Surfaces the live transport and request metrics behind a [ConvexClient],
/// mirroring the official client's `connectionState()`. The coarse [state] enum
/// remains available as a derived convenience; the extra fields drive loading,
/// retry, and "authenticating" indicators. Read the current snapshot from
/// [ConvexClient.currentConnectionStatus] and observe changes via
/// [ConvexClient.connectionStatus].
class ConnectionStatus {
  /// Creates a connection status snapshot.
  const ConnectionStatus({
    required this.state,
    required this.isWebSocketConnected,
    required this.isConnected,
    required this.hasEverConnected,
    required this.connectionCount,
    required this.connectionRetries,
    required this.inflightMutations,
    required this.inflightActions,
    required this.timeOfOldestInflightRequest,
    required this.hasSyncedPastLastReconnect,
  });

  /// Derives a best-effort snapshot from a coarse [ConnectionState] alone.
  ///
  /// Use this when only the coarse state is available (for example a custom or
  /// fake runtime client). Counts and inflight metrics default to zero; the
  /// connected/synced flags follow [state], and [hasEverConnected] is `true`
  /// only for the connected and reconnecting states.
  factory ConnectionStatus.fromState(ConnectionState state) {
    final isConnected = state == ConnectionState.connected;
    final hasEverConnected =
        isConnected || state == ConnectionState.reconnecting;
    return ConnectionStatus(
      state: state,
      isWebSocketConnected: isConnected,
      isConnected: isConnected,
      hasEverConnected: hasEverConnected,
      connectionCount: hasEverConnected ? 1 : 0,
      connectionRetries: 0,
      inflightMutations: 0,
      inflightActions: 0,
      timeOfOldestInflightRequest: null,
      hasSyncedPastLastReconnect: isConnected,
    );
  }

  /// The coarse connection state, derived for convenience.
  final ConnectionState state;

  /// Whether the underlying WebSocket is currently connected.
  final bool isWebSocketConnected;

  /// Whether the socket is connected and the client has caught up on all work
  /// that predated the most recent reconnect (connected *and* synced).
  final bool isConnected;

  /// Whether the client has ever reached a connected state.
  ///
  /// Once `true` it stays `true`, distinguishing "never connected yet" from
  /// "disconnected after a successful connection".
  final bool hasEverConnected;

  /// The number of times the client's WebSocket has opened successfully.
  ///
  /// The first successful open reports `1`. A high value signals trouble
  /// keeping a stable connection.
  final int connectionCount;

  /// The number of connection attempts since the last successful re-sync.
  final int connectionRetries;

  /// The number of mutations currently in flight.
  final int inflightMutations;

  /// The number of actions currently in flight.
  final int inflightActions;

  /// When the oldest still-pending request was issued, or `null` if none.
  final DateTime? timeOfOldestInflightRequest;

  /// Whether every query, auth update, and request that predated the most
  /// recent reconnect has been confirmed by the server.
  final bool hasSyncedPastLastReconnect;

  /// Whether any mutation or action is currently in flight.
  bool get hasInflightRequests => inflightMutations > 0 || inflightActions > 0;

  /// Whether the client is still catching up after a (re)connect.
  ///
  /// `true` until [hasSyncedPastLastReconnect] becomes `true`; use it to show a
  /// loading indicator while the first post-reconnect results arrive.
  bool get isLoading => !hasSyncedPastLastReconnect;

  @override
  bool operator ==(Object other) =>
      other is ConnectionStatus &&
      other.state == state &&
      other.isWebSocketConnected == isWebSocketConnected &&
      other.isConnected == isConnected &&
      other.hasEverConnected == hasEverConnected &&
      other.connectionCount == connectionCount &&
      other.connectionRetries == connectionRetries &&
      other.inflightMutations == inflightMutations &&
      other.inflightActions == inflightActions &&
      other.timeOfOldestInflightRequest == timeOfOldestInflightRequest &&
      other.hasSyncedPastLastReconnect == hasSyncedPastLastReconnect;

  @override
  int get hashCode => Object.hash(
        state,
        isWebSocketConnected,
        isConnected,
        hasEverConnected,
        connectionCount,
        connectionRetries,
        inflightMutations,
        inflightActions,
        timeOfOldestInflightRequest,
        hasSyncedPastLastReconnect,
      );

  @override
  String toString() => 'ConnectionStatus(state: ${state.name}, '
      'isWebSocketConnected: $isWebSocketConnected, '
      'isConnected: $isConnected, hasEverConnected: $hasEverConnected, '
      'connectionCount: $connectionCount, '
      'connectionRetries: $connectionRetries, '
      'inflightMutations: $inflightMutations, '
      'inflightActions: $inflightActions, '
      'timeOfOldestInflightRequest: $timeOfOldestInflightRequest, '
      'hasSyncedPastLastReconnect: $hasSyncedPastLastReconnect)';
}

/// Base class for query subscription results.
sealed class QueryResult {
  /// Creates a query result.
  const QueryResult();
}

/// Query result representing a successful value.
class QuerySuccess extends QueryResult {
  /// Creates a successful query result.
  const QuerySuccess(
    this.value, {
    this.logLines = const <String>[],
    this.hasPendingWrites = false,
  });

  /// Returned query value.
  final dynamic value;

  /// Optional log lines attached to the successful query result.
  final List<String> logLines;

  /// Whether optimistic writes are currently affecting this query result.
  final bool hasPendingWrites;
}

/// Query result representing an intentionally cleared/loading value.
class QueryLoading extends QueryResult {
  /// Creates a loading query result.
  const QueryLoading({this.hasPendingWrites = false});

  /// Whether optimistic writes are currently affecting this query result.
  final bool hasPendingWrites;
}

/// Query result representing an error.
class QueryError extends QueryResult {
  /// Creates a failed query result.
  const QueryError(
    this.message, {
    this.data,
    this.logLines = const <String>[],
  });

  /// Human-readable error message.
  final String message;

  /// Optional structured error payload from Convex.
  final Object? data;

  /// Optional log lines attached to the query failure.
  final List<String> logLines;
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
  ///
  /// If the transport is disconnected, the request is retained in memory and
  /// sent after reconnect. The future resolves after the server responds and a
  /// matching or later transition is observed. It is not persisted across
  /// process restarts or client disposal, and uses the auth state active when
  /// it is eventually sent.
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]);

  /// Executes an action.
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]);

  /// Subscribes to a live, reactive paginated query.
  ///
  /// [name] must be a Convex paginated query (one taking `paginationOpts` and
  /// returning a `PaginationResult`); [args] are its arguments excluding
  /// `paginationOpts`, and [pageSize] is the number of items per page. Cancel
  /// the returned query when done to release its page subscriptions.
  ConvexPaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  });
}

/// Main Dartvex client for communicating with a Convex deployment.
class ConvexClient implements ConvexFunctionCaller, DartvexLogSource {
  /// Creates a [ConvexClient] for [deploymentUrl].
  ConvexClient(
    String deploymentUrl, {
    ConvexClientConfig? config,
    TransitionMetricsCallback? onTransitionMetrics,
  })  : _deploymentUrl = _normalizeDeploymentUrl(deploymentUrl),
        _config = _normalizeConfig(config ?? const ConvexClientConfig()),
        _baseClient = BaseClient(),
        _connectionStateController =
            StreamController<ConnectionState>.broadcast(
          sync: true,
        ),
        _authStateController = StreamController<bool>.broadcast(sync: true),
        _authRefreshingController =
            StreamController<bool>.broadcast(sync: true),
        _connectionStatusController =
            StreamController<ConnectionStatus>.broadcast(sync: true),
        _subscriptionControllers = <int, StreamController<QueryResult>>{} {
    _wsManager = WebSocketManager(
      adapter: _config.adapterFactory?.call(_config.clientId) ??
          createDefaultWebSocketAdapter(_config.clientId),
      deploymentUrl: _deploymentUrl,
      apiVersion: _config.apiVersion,
      onConnected: _handleConnected,
      onResume: _baseClient.resume,
      onMessage: _handleServerMessage,
      onDisconnected: (reason) async {
        _baseClient.handleDisconnect(reason);
        _publishConnectionStatus();
      },
      onMessagesSent: _baseClient.markMessagesSent,
      onConnectionStateChanged: _handleConnectionStateChange,
      maxObservedTimestamp: () => _baseClient.maxObservedTimestamp,
      hasSyncedPastLastReconnect: () => _baseClient.hasSyncedPastLastReconnect,
      reconnectBackoff: _config.reconnectBackoff,
      inactivityTimeout: _config.inactivityTimeout,
      connectTimeout: _config.connectTimeout,
      initialBackoff: _config.initialBackoff,
      maxBackoff: _config.maxBackoff,
      backoffJitter: _config.backoffJitter,
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
      pauseSocket: () async {
        _wsManager.pause();
        _baseClient.pause();
      },
      resumeSocket: _resumeSocketForAuth,
      stopSocket: () => _wsManager.stop(),
      restartSocket: () => _wsManager.restart(),
      onRefreshingChange: (isRefreshing) {
        _currentAuthRefreshing = isRefreshing;
        if (!_authRefreshingController.isClosed) {
          _authRefreshingController.add(isRefreshing);
        }
      },
    );
    _connectivitySubscription = _config.connectivitySignal?.onRestored.listen(
      (_) => _wsManager.reconnectImmediatelyIfWaiting(),
    );
    if (_config.connectImmediately) {
      _currentConnectionState = ConnectionState.connecting;
    }
    _connectionStateController.add(_currentConnectionState);
    _authStateController.add(false);
    _authRefreshingController.add(false);
    if (_config.connectImmediately) {
      unawaited(_ensureStarted());
    }
  }

  final String _deploymentUrl;
  final ConvexClientConfig _config;
  final BaseClient _baseClient;
  late final WebSocketManager _wsManager;
  late final AuthManager _authManager;
  StreamSubscription<void>? _connectivitySubscription;
  final StreamController<ConnectionState> _connectionStateController;
  final StreamController<bool> _authStateController;
  final StreamController<bool> _authRefreshingController;
  final StreamController<ConnectionStatus> _connectionStatusController;
  final Map<int, StreamController<QueryResult>> _subscriptionControllers;
  ConnectionState _currentConnectionState = ConnectionState.disconnected;
  ConnectionStatus? _lastPublishedStatus;
  bool _currentAuthRefreshing = false;
  Future<void>? _startFuture;
  Future<void>? _closeFuture;
  bool _disposed = false;

  static String _normalizeDeploymentUrl(String deploymentUrl) {
    final uri = Uri.tryParse(deploymentUrl);
    if (uri == null ||
        uri.scheme.isEmpty ||
        uri.host.isEmpty ||
        !const <String>{'http', 'https', 'ws', 'wss'}.contains(uri.scheme)) {
      throw ArgumentError.value(
        deploymentUrl,
        'deploymentUrl',
        'must be an absolute Convex URL with http, https, ws, or wss scheme',
      );
    }
    if ((uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw ArgumentError.value(
        deploymentUrl,
        'deploymentUrl',
        'must be a Convex deployment origin without path, query, or fragment',
      );
    }
    return uri.replace(path: '', query: null, fragment: null).toString();
  }

  static ConvexClientConfig _normalizeConfig(ConvexClientConfig config) {
    _requireNonNegativeInt(
      config.refreshTokenLeewaySeconds,
      'config.refreshTokenLeewaySeconds',
    );
    _requirePositiveDuration(
      config.inactivityTimeout,
      'config.inactivityTimeout',
    );
    _requirePositiveDuration(config.connectTimeout, 'config.connectTimeout');
    _requireOptionalPositiveDuration(
      config.queryTimeout,
      'config.queryTimeout',
    );
    _requireOptionalPositiveDuration(
      config.mutationTimeout,
      'config.mutationTimeout',
    );
    _requireOptionalPositiveDuration(
      config.actionTimeout,
      'config.actionTimeout',
    );
    _requireNonNegativeDuration(
      config.initialBackoff,
      'config.initialBackoff',
    );
    _requireNonNegativeDuration(config.maxBackoff, 'config.maxBackoff');
    if (config.maxBackoff < config.initialBackoff) {
      throw ArgumentError.value(
        config.maxBackoff,
        'config.maxBackoff',
        'must be greater than or equal to config.initialBackoff',
      );
    }
    if (!config.backoffJitter.isFinite ||
        config.backoffJitter < 0 ||
        config.backoffJitter > 1) {
      throw ArgumentError.value(
        config.backoffJitter,
        'config.backoffJitter',
        'must be finite and between 0 and 1',
      );
    }
    final reconnectBackoff =
        List<Duration>.unmodifiable(config.reconnectBackoff);
    // An empty schedule selects the exponential backoff model; only the
    // explicit-override case needs validation here.
    for (final duration in reconnectBackoff) {
      if (duration.isNegative) {
        throw ArgumentError.value(
          duration,
          'config.reconnectBackoff',
          'must not contain negative durations',
        );
      }
    }
    return ConvexClientConfig(
      clientId: config.clientId,
      apiVersion: config.apiVersion,
      authTokenType: config.authTokenType,
      refreshTokenLeewaySeconds: config.refreshTokenLeewaySeconds,
      inactivityTimeout: config.inactivityTimeout,
      connectTimeout: config.connectTimeout,
      queryTimeout: config.queryTimeout,
      mutationTimeout: config.mutationTimeout,
      actionTimeout: config.actionTimeout,
      reconnectBackoff: reconnectBackoff,
      initialBackoff: config.initialBackoff,
      maxBackoff: config.maxBackoff,
      backoffJitter: config.backoffJitter,
      connectImmediately: config.connectImmediately,
      adapterFactory: config.adapterFactory,
      connectivitySignal: config.connectivitySignal,
      logLevel: config.logLevel,
      logger: config.logger,
    );
  }

  static void _requirePositiveDuration(Duration value, String name) {
    if (value <= Duration.zero) {
      throw ArgumentError.value(value, name, 'must be greater than zero');
    }
  }

  static void _requireOptionalPositiveDuration(Duration? value, String name) {
    if (value == null) {
      return;
    }
    _requirePositiveDuration(value, name);
  }

  static void _requireNonNegativeDuration(Duration value, String name) {
    if (value.isNegative) {
      throw ArgumentError.value(value, name, 'must not be negative');
    }
  }

  static void _requireNonNegativeInt(int value, String name) {
    if (value < 0) {
      throw ArgumentError.value(value, name, 'must not be negative');
    }
  }

  /// Broadcasts connection state changes.
  Stream<ConnectionState> get connectionState =>
      _connectionStateController.stream;

  /// Current connection state.
  ConnectionState get currentConnectionState => _currentConnectionState;

  /// A rich snapshot of the current connection status.
  ///
  /// Combines the coarse [currentConnectionState] with transport and request
  /// metrics (inflight counts, retries, sync progress). See [ConnectionStatus].
  ConnectionStatus get currentConnectionStatus => ConnectionStatus(
        state: _currentConnectionState,
        isWebSocketConnected: _wsManager.isConnected,
        isConnected:
            _wsManager.isConnected && _baseClient.hasSyncedPastLastReconnect,
        hasEverConnected: _wsManager.hasEverConnected,
        connectionCount: _wsManager.connectionCount,
        connectionRetries: _wsManager.connectionRetries,
        inflightMutations: _baseClient.inflightMutations,
        inflightActions: _baseClient.inflightActions,
        timeOfOldestInflightRequest: _baseClient.timeOfOldestInflightRequest,
        hasSyncedPastLastReconnect: _baseClient.hasSyncedPastLastReconnect,
      );

  /// Broadcasts a rich [ConnectionStatus] each time any field changes.
  ///
  /// Does not replay the latest value to new listeners; read
  /// [currentConnectionStatus] for the current snapshot. Mirrors the official
  /// client's `subscribeToConnectionState`.
  Stream<ConnectionStatus> get connectionStatus =>
      _connectionStatusController.stream;

  /// Broadcasts whether the backend currently considers the client authenticated.
  Stream<bool> get authState => _authStateController.stream;

  /// Broadcasts whether the client is currently refreshing auth after a
  /// rejection.
  ///
  /// Emits `true` when a server `AuthError` triggers a reauth — the socket is
  /// stopped while a fresh token is fetched — and `false` once that fresh token
  /// is confirmed (or the reauth gives up). Use it to show an "authenticating…"
  /// indicator without surfacing the brief disconnect. The current value is
  /// [isAuthRefreshing]. Mirrors the official client's `AuthRefreshing` signal.
  Stream<bool> get authRefreshing => _authRefreshingController.stream;

  /// Whether the client is currently refreshing auth after a rejection.
  ///
  /// The latest value emitted on [authRefreshing].
  bool get isAuthRefreshing => _currentAuthRefreshing;

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
    Object? closeError;
    StackTrace? closeStackTrace;
    Future<void> cancelQuerySubscription({
      Object? error,
      StackTrace? stackTrace,
    }) async {
      closeError = error;
      closeStackTrace = stackTrace;
      await streamSubscription.cancel();
      subscription.cancel();
    }

    streamSubscription = subscription.stream.listen(
      (event) {
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
          case QueryError(:final message, :final data, :final logLines):
            _log(
              DartvexLogLevel.error,
              'Query failed',
              data: <String, Object?>{
                ..._requestData(name, args),
                'errorMessage': message,
              },
            );
            completer.completeError(
              ConvexException(message, data: data, logLines: logLines),
            );
          case QueryLoading():
            // Keep waiting; one-shot queries resolve only on concrete success or
            // error, matching the official client's undefined/loading semantics.
            return;
        }
        unawaited(cancelQuerySubscription());
      },
      onError: (Object error, StackTrace stackTrace) {
        if (completer.isCompleted) {
          return;
        }
        completer.completeError(error, stackTrace);
      },
      onDone: () {
        if (completer.isCompleted) {
          return;
        }
        final error = closeError ??
            const ConvexException('ConvexClient has been disposed');
        final stackTrace = closeStackTrace;
        if (stackTrace == null) {
          completer.completeError(error);
        } else {
          completer.completeError(error, stackTrace);
        }
      },
    );
    final timeout = _config.queryTimeout;
    if (timeout == null) {
      return completer.future;
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        final error = TimeoutException(
          'Convex query "$name" timed out after $timeout',
          timeout,
        );
        unawaited(cancelQuerySubscription(error: error));
        throw error;
      },
    );
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
    late final StreamController<QueryResult> controller;
    controller = StreamController<QueryResult>.broadcast(
      sync: true,
      onListen: () {
        scheduleMicrotask(() {
          if (_baseClient.optimisticQueryIsLoading(name, args)) {
            if (!controller.isClosed) {
              controller.add(
                QueryLoading(
                  hasPendingWrites: _baseClient.hasOptimisticUpdateForQuery(
                    name,
                    args,
                  ),
                ),
              );
            }
            return;
          }
          final initial = _baseClient.optimisticResultForQuery(name, args) ??
              _baseClient.currentResultForQuery(registration.queryId) ??
              _baseClient.cachedResultForQuery(name, args);
          if (initial == null) {
            return;
          }
          if (!controller.isClosed) {
            controller.add(
              _toPublicQueryResult(
                initial,
                hasPendingWrites: _baseClient.hasOptimisticUpdateForQuery(
                  name,
                  args,
                ),
              ),
            );
          }
        });
      },
    );
    _subscriptionControllers[registration.subscriberId] = controller;

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
        if (_disposed) {
          await removed?.close();
          return;
        }
        _baseClient.unsubscribe(registration.subscriberId);
        await _flushOutgoing();
        await removed?.close();
      },
    );
  }

  @override

  /// Subscribes to a live, reactive paginated query.
  ///
  /// Returns a [ConvexPaginatedQuery] that loads the first page immediately and
  /// exposes the gapless concatenation of every loaded page as a reactive
  /// stream, plus a [ConvexPaginatedQuery.status], [ConvexPaginatedQuery.isDone]
  /// flag, and [ConvexPaginatedQuery.loadMore] to fetch the next page. [name]
  /// must be a Convex paginated query (one that takes `paginationOpts` and
  /// returns a `PaginationResult`); [args] are its arguments excluding
  /// `paginationOpts`, and [pageSize] is the number of items per page.
  ///
  /// Each page is an ordinary subscription, so loaded pages update reactively
  /// and stay gapless across reconnects via query journals. Cancel the returned
  /// query when done to release every page subscription.
  ConvexPaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    _assertNotDisposed();
    _log(
      DartvexLogLevel.debug,
      'Starting paginated query',
      data: _requestData(name, args),
    );
    return ConvexPaginatedQuery(
      subscribe: (pageName, pageArgs) =>
          _PageSubscriptionAdapter(subscribe(pageName, pageArgs)),
      readInitialResult: _baseClient.localResultForQuery,
      name: name,
      args: args,
      pageSize: pageSize,
    );
  }

  @override

  /// Executes a mutation.
  ///
  /// Pass [optimisticUpdate] to locally overlay query results the moment the
  /// mutation is sent; the overlay is replayed whenever fresh server data
  /// arrives while the mutation is pending and is rolled back automatically
  /// when the mutation completes (or fails). The update runs synchronously and
  /// must be pure — it can be replayed multiple times.
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
    OptimisticUpdate? optimisticUpdate,
  ]) async {
    _assertNotDisposed();
    _log(
      DartvexLogLevel.debug,
      'Starting mutation',
      data: _requestData(name, args),
    );
    try {
      final request = _baseClient.trackMutation(name, args);
      if (optimisticUpdate != null) {
        try {
          _dispatchOptimisticEvents(
            _baseClient.applyOptimisticUpdate(
                optimisticUpdate, request.requestId),
          );
        } catch (error, stackTrace) {
          unawaited(request.future.catchError((_) {}));
          _dispatchOptimisticEvents(
            _baseClient.cancelMutation(request.requestId, error),
          );
          _publishConnectionStatus();
          Error.throwWithStackTrace(error, stackTrace);
        }
      }
      _publishConnectionStatus();
      final future = _withOptionalTimeout(
        request.future,
        _config.mutationTimeout,
        'Mutation "$name"',
        onTimeout: (error) {
          _dispatchOptimisticEvents(
            _baseClient.cancelMutation(request.requestId, error),
          );
          _publishConnectionStatus();
        },
      );
      await _flushOutgoing();
      final result = await future;
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
        error: _safeLogError(error),
        stackTrace: stackTrace,
        data: _requestData(name, args),
      );
      rethrow;
    }
  }

  @override

  /// Executes an action.
  ///
  /// If the transport is disconnected before the action is sent, the request is
  /// retained in memory and sent after reconnect. If the action is already in
  /// flight when the connection is lost, the future fails because actions are
  /// not idempotent. It is not persisted across process restarts or client
  /// disposal, and uses the auth state active when it is eventually sent.
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertNotDisposed();
    _log(
      DartvexLogLevel.debug,
      'Starting action',
      data: _requestData(name, args),
    );
    try {
      final request = _baseClient.trackAction(name, args);
      _publishConnectionStatus();
      final future = _withOptionalTimeout(
        request.future,
        _config.actionTimeout,
        'Action "$name"',
        onTimeout: (error) {
          _baseClient.cancelAction(request.requestId, error);
          _publishConnectionStatus();
        },
      );
      await _flushOutgoing();
      final result = await future;
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
        error: _safeLogError(error),
        stackTrace: stackTrace,
        data: _requestData(name, args),
      );
      rethrow;
    }
  }

  Future<dynamic> _withOptionalTimeout(
    Future<dynamic> future,
    Duration? timeout,
    String operation, {
    void Function(TimeoutException error)? onTimeout,
  }) {
    if (timeout == null) {
      return future;
    }
    final completer = Completer<dynamic>();
    Timer? timer;
    timer = Timer(timeout, () {
      if (completer.isCompleted) {
        return;
      }
      final error = TimeoutException(
        '$operation timed out after ${timeout.inMilliseconds}ms',
        timeout,
      );
      onTimeout?.call(error);
      completer.completeError(error);
    });
    future.then(
      (value) {
        if (completer.isCompleted) {
          return;
        }
        timer?.cancel();
        completer.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (completer.isCompleted) {
          return;
        }
        timer?.cancel();
        completer.completeError(error, stackTrace);
      },
    );
    return completer.future;
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
    AuthProvider<TUser> authProvider, {
    bool disposeClient = false,
  }) {
    _assertNotDisposed();
    return ConvexClientWithAuth<TUser>(
      client: this,
      authProvider: authProvider,
      disposeClient: disposeClient,
    );
  }

  /// Forces a prompt reconnect of the WebSocket connection.
  ///
  /// Use this when the app resumes from background: the reconnect uses the short
  /// client-initiated backoff (a 100ms base, mirroring the official client)
  /// rather than the longer server-disconnect backoff, so it does not wait out a
  /// full server/network retry delay. If already connected, this closes and
  /// re-establishes the connection.
  Future<void> reconnectNow(String reason) {
    _assertNotDisposed();
    if (_startFuture == null) {
      return _ensureStarted();
    }
    return _wsManager.reconnectNow(reason);
  }

  /// Disposes subscriptions, auth management, and transport resources.
  void dispose() {
    unawaited(close());
  }

  /// Asynchronously closes subscriptions, auth management, and transport resources.
  Future<void> close() {
    final closeFuture = _closeFuture;
    if (closeFuture != null) {
      return closeFuture;
    }
    if (_disposed) {
      return Future<void>.value();
    }
    _disposed = true;
    _log(DartvexLogLevel.debug, 'Disposing client');
    _baseClient.failPendingRequests('ConvexClient has been disposed');
    final subscriptionControllers = _subscriptionControllers.values.toList();
    _subscriptionControllers.clear();
    _closeFuture = Future<void>(() async {
      for (final controller in subscriptionControllers) {
        await controller.close();
      }
      await _connectionStateController.close();
      await _authStateController.close();
      await _authRefreshingController.close();
      await _connectionStatusController.close();
      await _authManager.stopRefreshing();
      await _connectivitySubscription?.cancel();
      await _wsManager.dispose();
    });
    return _closeFuture!;
  }

  Future<void> _sendAuth(String? token) async {
    if (token == null) {
      _baseClient.clearAuth();
    } else {
      _baseClient.setAuth(tokenType: _config.authTokenType, token: token);
    }
    await _flushOutgoing();
  }

  Future<void> _ensureStarted() {
    _assertNotDisposed();
    final startFuture = _startFuture;
    if (startFuture != null) {
      return startFuture;
    }
    if (_currentConnectionState == ConnectionState.disconnected) {
      _emitConnectionState(ConnectionState.connecting);
    }
    return _startFuture = _wsManager.start();
  }

  // Matches the official client: a reconnect replays the cached auth token from
  // local state (via prepareReconnect) and never re-fetches it. Token freshness
  // is driven by the scheduled refresh timer and by server AuthErrors, so a
  // transient auth-provider failure during a reconnect cannot log the user out.
  List<ClientMessage> _handleConnected() {
    return _baseClient.prepareReconnect();
  }

  Future<void> _resumeSocketForAuth() async {
    if (_disposed) {
      // close() stops the refresh flow before disposing the transport; the
      // resume that releases a superseded flow's pause must not run a deferred
      // handshake on a socket that is about to be torn down.
      return;
    }
    await _wsManager.resume();
    // Safety net: if the socket was never actually paused (e.g. it had already
    // disconnected before the fetch finished), unpause and flush local state so
    // it cannot get stuck buffering.
    if (_baseClient.isPaused) {
      final messages = _baseClient.resume();
      if (messages.isNotEmpty) {
        await _wsManager.sendMessages(messages);
      }
    }
  }

  Future<List<ClientMessage>> _handleServerMessage(
    ServerMessage message,
  ) async {
    final result = _baseClient.receive(message);
    for (final event in result.events) {
      switch (event) {
        case QueryUpdateEvent():
          _emitToSubscribers(
            event.queryId,
            _toPublicQueryResult(
              event.result,
              hasPendingWrites: event.hasPendingWrites,
            ),
          );
        case QueryRemovedEvent():
          _emitToSubscribers(
            event.queryId,
            const QueryError('Query removed'),
          );
        case QueryLoadingEvent():
          _emitToSubscribers(
            event.queryId,
            QueryLoading(hasPendingWrites: event.hasPendingWrites),
          );
        case AuthConfirmedEvent():
          _authManager.handleAuthConfirmed();
        case AuthErrorEvent():
          await _authManager.handleAuthError(
            event.error,
            currentAuthVersion: _baseClient.authVersion,
          );
        case ReconnectRequiredEvent():
          await _wsManager.reconnectNow(event.reason);
        case FatalErrorEvent():
          _log(
            DartvexLogLevel.error,
            'Fatal server error; terminating connection',
            data: <String, Object?>{'error': event.error},
          );
          await _wsManager.terminate();
          _baseClient.failPendingRequests(event.error);
          _emitConnectionState(ConnectionState.fatalError);
        case FunctionLogEvent():
          _logFunctionOutput(event);
        case QueryLogEvent():
          _logQueryOutput(event);
      }
    }
    _publishConnectionStatus();
    // Route the messages receive() drained back through the re-queueing flush
    // instead of handing them to the transport directly: the transport drops
    // (returns a short prefix for) messages while the socket is paused for
    // auth or already disconnected, and this return path has no re-queue. A
    // tracked mutation drained here while paused would otherwise be lost
    // until the next reconnect replay and hang its caller in the meantime.
    if (!_disposed && result.outgoing.isNotEmpty) {
      _baseClient.requeueOutgoing(result.outgoing);
      await _flushOutgoing();
    }
    return const <ClientMessage>[];
  }

  QueryResult _toPublicQueryResult(
    StoredQueryResult result, {
    bool hasPendingWrites = false,
  }) {
    switch (result) {
      case StoredQuerySuccess():
        return QuerySuccess(
          result.value,
          logLines: result.logLines,
          hasPendingWrites: hasPendingWrites,
        );
      case StoredQueryLoading():
        return QueryLoading(hasPendingWrites: hasPendingWrites);
      case StoredQueryError():
        return QueryError(
          result.message,
          data: result.data,
          logLines: result.logLines,
        );
    }
  }

  void _emitToSubscribers(int queryId, QueryResult result) {
    for (final subscriberId in _baseClient.subscriberIdsForQuery(queryId)) {
      _subscriptionControllers[subscriberId]?.add(result);
    }
  }

  /// Delivers the query-update events produced by applying an optimistic update
  /// straight to the affected subscribers.
  void _dispatchOptimisticEvents(List<BaseClientEvent> events) {
    for (final event in events) {
      if (event is QueryUpdateEvent) {
        _emitToSubscribers(
          event.queryId,
          _toPublicQueryResult(
            event.result,
            hasPendingWrites: event.hasPendingWrites,
          ),
        );
      } else if (event is QueryRemovedEvent) {
        _emitToSubscribers(event.queryId, const QueryError('Query removed'));
      } else if (event is QueryLoadingEvent) {
        _emitToSubscribers(
          event.queryId,
          QueryLoading(hasPendingWrites: event.hasPendingWrites),
        );
      }
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
      _emitConnectionState(
        nextState,
      );
      return;
    }
    _emitConnectionState(ConnectionState.disconnected);
  }

  void _emitConnectionState(ConnectionState state) {
    if (_connectionStateController.isClosed) {
      return;
    }
    _currentConnectionState = state;
    _log(
      DartvexLogLevel.info,
      'Connection state changed',
      data: <String, Object?>{'state': state.name},
    );
    _connectionStateController.add(state);
    _publishConnectionStatus();
  }

  /// Emits a fresh [ConnectionStatus] on [connectionStatus] when it differs from
  /// the last published snapshot.
  ///
  /// Deduplicated by value so it can be called liberally from the request and
  /// connection lifecycle, mirroring the official client's
  /// `markConnectionStateDirty`.
  void _publishConnectionStatus() {
    if (_connectionStatusController.isClosed) {
      return;
    }
    final status = currentConnectionStatus;
    if (status == _lastPublishedStatus) {
      return;
    }
    _lastPublishedStatus = status;
    _connectionStatusController.add(status);
  }

  Future<void> _flushOutgoing() async {
    await _ensureStarted();
    if (!_wsManager.isConnected) {
      return;
    }
    final messages = _baseClient.drainOutgoing(assumeSent: false);
    if (messages.isEmpty) {
      return;
    }
    final sentMessages = await _wsManager.sendMessages(messages);
    if (sentMessages.length < messages.length) {
      _baseClient.requeueOutgoing(messages.skip(sentMessages.length));
    }
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw const ConvexException('ConvexClient has been disposed');
    }
  }

  Object _safeLogError(Object error) {
    if (error is ConvexException) {
      return ConvexException(error.message, retryable: error.retryable);
    }
    return error;
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

  void _logFunctionOutput(FunctionLogEvent event) {
    emitDartvexLog(
      configuredLevel: _config.logLevel,
      logger: _config.logger,
      eventLevel: DartvexLogLevel.info,
      message: event.line,
      tag: 'function',
      data: <String, Object?>{
        'requestType': event.requestType,
        'name': event.name,
        'requestId': event.requestId,
        if (event.componentPath != null) 'componentPath': event.componentPath,
      },
    );
  }

  void _logQueryOutput(QueryLogEvent event) {
    emitDartvexLog(
      configuredLevel: _config.logLevel,
      logger: _config.logger,
      eventLevel: DartvexLogLevel.info,
      message: event.line,
      tag: 'function',
      data: <String, Object?>{
        'requestType': 'query',
        'name': event.name,
        'queryId': event.queryId,
      },
    );
  }
}

/// Adapts a public [ConvexSubscription] to the sync layer's [PageSubscription]
/// so [ConvexPaginatedQuery] can consume a page without depending on the
/// public client types. Maps each [QueryResult] to its [StoredQueryResult].
class _PageSubscriptionAdapter implements PageSubscription {
  _PageSubscriptionAdapter(this._subscription)
      : _results = _subscription.stream.asyncExpand(_toStoredEvents);

  final ConvexSubscription _subscription;
  final Stream<StoredQueryResult> _results;

  @override
  Stream<StoredQueryResult> get results => _results;

  @override
  void cancel() => _subscription.cancel();

  static Stream<StoredQueryResult> _toStoredEvents(QueryResult result) {
    switch (result) {
      case QuerySuccess(:final value):
        return Stream<StoredQueryResult>.value(
          StoredQuerySuccess(value: value, logLines: const <String>[]),
        );
      case QueryLoading():
        return Stream<StoredQueryResult>.value(const StoredQueryLoading());
      case QueryError(:final message, :final data, :final logLines):
        return Stream<StoredQueryResult>.value(
          StoredQueryError(
            message: message,
            data: data,
            logLines: logLines,
          ),
        );
    }
  }
}
