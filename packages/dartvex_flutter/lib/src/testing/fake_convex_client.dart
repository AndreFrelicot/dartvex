import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dartvex/dartvex.dart'
    show
        ConnectionStatus,
        ConvexException,
        ConvexFunctionCaller,
        ConvexPaginatedQuery,
        ConvexPaginatedResult,
        ConvexPaginationStatus,
        ConvexSubscription,
        OptimisticUpdate,
        QueryError,
        QueryLoading,
        QueryResult,
        QuerySuccess;

import '../args.dart';
import '../runtime_client.dart';
import '../snapshot.dart';

/// A fake implementation of [ConvexRuntimeClient] for testing Flutter apps
/// without a real Convex backend.
///
/// ```dart
/// final client = FakeConvexClient()
///   ..whenQuery('messages:list', returns: [mockMessage1, mockMessage2])
///   ..whenMutation('messages:send', returns: {'id': 'xxx'});
///
/// // Use with ConvexProvider in widget tests:
/// await tester.pumpWidget(
///   ConvexProvider(client: client, child: MyApp()),
/// );
/// ```
///
/// Fidelity notes — where this fake intentionally differs from the real
/// client:
///
/// * A new subscription receives its handler's value (from [whenQuery] /
///   [whenQueryWith]) one microtask after it is created, not a value pushed
///   earlier with [emitSubscription]. A throwing handler delivers a
///   [ConvexRuntimeQueryError] event.
/// * [emitSubscription], [emitSubscriptionError], [emitSubscriptionLoading]
///   and [emitPaginated] reach **every** live subscription with that query
///   name unless you pass `args:`, in which case only subscriptions whose
///   arguments are deeply equal receive the event. The real client keys
///   subscriptions by name *and* arguments, so pass `args:` whenever a test
///   mounts the same query with different arguments.
/// * Optimistic updates are recorded ([mutationCalls]) but not applied.
/// * After [dispose], every call throws (or rejects with) the same
///   `ConvexException('ConvexClient has been disposed')` as the real client,
///   and emissions are ignored.
/// * `ConvexProvider.of(context).functionCaller` (for generated `ConvexApi`
///   bindings or `ConvexStorage`) is backed by the same handlers; its
///   `paginatedQuery` is unsupported.
class FakeConvexClient
    implements ConvexRuntimeClient, ConvexFunctionCallerSource {
  /// Creates a fake client with an optional initial connection state.
  FakeConvexClient({
    ConvexConnectionState initialConnectionState =
        ConvexConnectionState.connected,
  }) : _currentConnectionState = initialConnectionState,
       _currentConnectionStatus = ConnectionStatus.fromState(
         initialConnectionState,
       );

  static const DeepCollectionEquality _argsEquality = DeepCollectionEquality();

  final Map<String, dynamic Function(Map<String, dynamic>)> _queryHandlers =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, dynamic Function(Map<String, dynamic>)> _mutationHandlers =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, dynamic Function(Map<String, dynamic>)> _actionHandlers =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, List<FakeConvexSubscription>> _subscriptions =
      <String, List<FakeConvexSubscription>>{};
  final Map<String, List<FakeConvexPaginatedQuery>> _paginatedQueries =
      <String, List<FakeConvexPaginatedQuery>>{};

  final StreamController<ConvexConnectionState> _connectionController =
      StreamController<ConvexConnectionState>.broadcast(sync: true);
  final StreamController<ConnectionStatus> _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast(sync: true);
  final StreamController<bool> _authRefreshingController =
      StreamController<bool>.broadcast(sync: true);
  ConvexConnectionState _currentConnectionState;
  ConnectionStatus _currentConnectionStatus;
  bool _currentAuthRefreshing = false;
  bool _disposed = false;

  /// Every one-shot query call, in order (including `queryOnce`).
  final List<FakeConvexCall> queryCalls = <FakeConvexCall>[];

  /// Every mutation call, in order, with its optimistic update.
  final List<FakeConvexCall> mutationCalls = <FakeConvexCall>[];

  /// Every action call, in order.
  final List<FakeConvexCall> actionCalls = <FakeConvexCall>[];

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Register a mock query handler that returns a static value.
  void whenQuery(String name, {required dynamic returns}) {
    _queryHandlers[name] = (_) => returns;
  }

  /// Register a dynamic mock query handler.
  void whenQueryWith(
    String name,
    dynamic Function(Map<String, dynamic> args) handler,
  ) {
    _queryHandlers[name] = handler;
  }

  /// Register a mock mutation handler that returns a static value.
  void whenMutation(String name, {required dynamic returns}) {
    _mutationHandlers[name] = (_) => returns;
  }

  /// Register a dynamic mock mutation handler.
  void whenMutationWith(
    String name,
    dynamic Function(Map<String, dynamic> args) handler,
  ) {
    _mutationHandlers[name] = handler;
  }

  /// Register a mock action handler that returns a static value.
  void whenAction(String name, {required dynamic returns}) {
    _actionHandlers[name] = (_) => returns;
  }

  /// Register a dynamic mock action handler.
  void whenActionWith(
    String name,
    dynamic Function(Map<String, dynamic> args) handler,
  ) {
    _actionHandlers[name] = handler;
  }

  /// Emit a success value to the subscriptions of [name].
  ///
  /// Reaches every subscription with that name, or only those whose arguments
  /// deeply equal [args] when given. [source] and [hasPendingWrites] set the
  /// event metadata (for example `source: ConvexQuerySource.cache,
  /// hasPendingWrites: true` for an optimistic value).
  void emitSubscription(
    String name,
    dynamic value, {
    Map<String, dynamic>? args,
    ConvexQuerySource source = ConvexQuerySource.remote,
    bool hasPendingWrites = false,
  }) {
    _emit(
      name,
      args,
      ConvexRuntimeQuerySuccess(
        value,
        source: source,
        hasPendingWrites: hasPendingWrites,
      ),
    );
  }

  /// Emit an error to the subscriptions of [name] (filtered by [args] when
  /// given).
  void emitSubscriptionError(
    String name,
    Object error, {
    Map<String, dynamic>? args,
  }) {
    _emit(name, args, ConvexRuntimeQueryError(error));
  }

  /// Emit a loading event — what the real client sends when an optimistic
  /// update clears a query — to the subscriptions of [name] (filtered by
  /// [args] when given).
  void emitSubscriptionLoading(
    String name, {
    Map<String, dynamic>? args,
    bool hasPendingWrites = true,
  }) {
    _emit(
      name,
      args,
      ConvexRuntimeQueryLoading(hasPendingWrites: hasPendingWrites),
    );
  }

  void _emit(
    String name,
    Map<String, dynamic>? args,
    ConvexRuntimeQueryEvent event,
  ) {
    if (_disposed) {
      return;
    }
    final filter = args == null ? null : snapshotConvexArgs(args);
    for (final subscription in List<FakeConvexSubscription>.of(
      _subscriptions[name] ?? const <FakeConvexSubscription>[],
    )) {
      if (filter != null && !_argsEquality.equals(subscription.args, filter)) {
        continue;
      }
      subscription.emit(event);
    }
  }

  /// Emit an aggregated paginated result to the paginated queries of [name]
  /// (filtered by [args] when given).
  void emitPaginated(
    String name, {
    required List<dynamic> results,
    ConvexPaginationStatus status = ConvexPaginationStatus.canLoadMore,
    bool isDone = false,
    Object? error,
    Map<String, dynamic>? args,
  }) {
    if (_disposed) {
      return;
    }
    final result = ConvexPaginatedResult(
      results: results,
      status: status,
      isDone: isDone,
      error: error,
    );
    final filter = args == null ? null : snapshotConvexArgs(args);
    for (final query in List<FakeConvexPaginatedQuery>.of(
      _paginatedQueries[name] ?? const <FakeConvexPaginatedQuery>[],
    )) {
      if (query.isCanceled) {
        continue;
      }
      if (filter != null && !_argsEquality.equals(query.args, filter)) {
        continue;
      }
      query.emit(result);
    }
  }

  /// Update the fake connection state.
  ///
  /// Also updates the rich [currentConnectionStatus] with a snapshot derived
  /// from [state]; use [emitConnectionStatus] to drive the rich status with full
  /// inflight/retry detail.
  void emitConnectionState(ConvexConnectionState state) {
    if (_disposed) {
      return;
    }
    _currentConnectionState = state;
    if (!_connectionController.isClosed) {
      _connectionController.add(state);
    }
    _currentConnectionStatus = ConnectionStatus.fromState(state);
    if (!_connectionStatusController.isClosed) {
      _connectionStatusController.add(_currentConnectionStatus);
    }
  }

  /// Update the fake rich connection status, also syncing the coarse state.
  void emitConnectionStatus(ConnectionStatus status) {
    if (_disposed) {
      return;
    }
    final previousState = _currentConnectionState;
    _currentConnectionStatus = status;
    _currentConnectionState = status.state;
    if (status.state != previousState && !_connectionController.isClosed) {
      _connectionController.add(status.state);
    }
    if (!_connectionStatusController.isClosed) {
      _connectionStatusController.add(status);
    }
  }

  /// Update the fake auth-refreshing state.
  void emitAuthRefreshing(bool isRefreshing) {
    if (_disposed) {
      return;
    }
    _currentAuthRefreshing = isRefreshing;
    if (!_authRefreshingController.isClosed) {
      _authRefreshingController.add(isRefreshing);
    }
  }

  @override
  Stream<ConvexConnectionState> get connectionState =>
      _connectionController.stream;

  @override
  ConvexConnectionState get currentConnectionState => _currentConnectionState;

  @override
  Stream<ConnectionStatus> get connectionStatus =>
      _connectionStatusController.stream;

  @override
  ConnectionStatus get currentConnectionStatus => _currentConnectionStatus;

  @override
  Stream<bool> get authRefreshing => _authRefreshingController.stream;

  @override
  bool get currentAuthRefreshing => _currentAuthRefreshing;

  @override
  ConvexFunctionCaller get convexFunctionCaller => _FakeFunctionCaller(this);

  void _assertNotDisposed() {
    if (_disposed) {
      throw const ConvexException('ConvexClient has been disposed');
    }
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertNotDisposed();
    final snapshot = snapshotConvexArgs(args);
    queryCalls.add(FakeConvexCall(name, snapshot));
    final handler = _queryHandlers[name];
    if (handler == null) {
      throw StateError('No query handler registered for "$name"');
    }
    return handler(snapshot);
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
    _assertNotDisposed();
    final normalizedArgs = snapshotConvexArgs(args);
    final controller = StreamController<ConvexRuntimeQueryEvent>.broadcast(
      sync: true,
    );
    late final FakeConvexSubscription subscription;
    subscription = FakeConvexSubscription(
      name,
      controller,
      args: normalizedArgs,
      onCancel: () => _removeSubscription(name, subscription),
    );
    _subscriptions
        .putIfAbsent(name, () => <FakeConvexSubscription>[])
        .add(subscription);

    // Auto-emit initial value from handler if registered.
    // Scheduled as a microtask so the listener is attached first.
    final handler = _queryHandlers[name];
    if (handler != null) {
      scheduleMicrotask(() {
        if (controller.isClosed) {
          return;
        }
        final ConvexRuntimeQueryEvent event;
        try {
          event = ConvexRuntimeQuerySuccess(handler(normalizedArgs));
        } catch (error, stackTrace) {
          // A throwing handler simulates a failing query: deliver it the way
          // the real runtime does, as an error event.
          controller.add(
            ConvexRuntimeQueryError(error, stackTrace: stackTrace),
          );
          return;
        }
        controller.add(event);
      });
    }

    return subscription;
  }

  @override
  ConvexRuntimePaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    _assertNotDisposed();
    late final FakeConvexPaginatedQuery query;
    query = FakeConvexPaginatedQuery(
      name: name,
      pageSize: pageSize,
      args: snapshotConvexArgs(args),
      onCancel: () => _removePaginatedQuery(name, query),
    );
    _paginatedQueries
        .putIfAbsent(name, () => <FakeConvexPaginatedQuery>[])
        .add(query);
    return query;
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
    OptimisticUpdate? optimisticUpdate,
  ]) async {
    _assertNotDisposed();
    final snapshot = snapshotConvexArgs(args);
    // This fake has no query overlay, so [optimisticUpdate] is not applied;
    // it is recorded in [mutationCalls] so tests can assert on it.
    mutationCalls.add(
      FakeConvexCall(name, snapshot, optimisticUpdate: optimisticUpdate),
    );
    final handler = _mutationHandlers[name];
    if (handler == null) {
      throw StateError('No mutation handler registered for "$name"');
    }
    return handler(snapshot);
  }

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertNotDisposed();
    final snapshot = snapshotConvexArgs(args);
    actionCalls.add(FakeConvexCall(name, snapshot));
    final handler = _actionHandlers[name];
    if (handler == null) {
      throw StateError('No action handler registered for "$name"');
    }
    return handler(snapshot);
  }

  @override
  Future<void> reconnectNow(String reason) {
    // Like the real client: a disposed client throws synchronously.
    _assertNotDisposed();
    return Future<void>.value();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // close() delivers the done event synchronously (sync controllers), and a
    // done listener may cancel a subscription, which mutates these
    // collections — iterate snapshots.
    for (final subscriptions in List<List<FakeConvexSubscription>>.of(
      _subscriptions.values,
    )) {
      for (final subscription in List<FakeConvexSubscription>.of(
        subscriptions,
      )) {
        subscription.close();
      }
    }
    for (final queries in List<List<FakeConvexPaginatedQuery>>.of(
      _paginatedQueries.values,
    )) {
      for (final query in List<FakeConvexPaginatedQuery>.of(queries)) {
        query.cancel();
      }
    }
    unawaited(_connectionController.close());
    unawaited(_connectionStatusController.close());
    unawaited(_authRefreshingController.close());
  }

  void _removeSubscription(String name, FakeConvexSubscription subscription) {
    final subscriptions = _subscriptions[name];
    if (subscriptions == null) {
      return;
    }
    subscriptions.remove(subscription);
    if (subscriptions.isEmpty) {
      _subscriptions.remove(name);
    }
  }

  void _removePaginatedQuery(String name, FakeConvexPaginatedQuery query) {
    final queries = _paginatedQueries[name];
    if (queries == null) {
      return;
    }
    queries.remove(query);
    if (queries.isEmpty) {
      _paginatedQueries.remove(name);
    }
  }
}

/// A call recorded by [FakeConvexClient].
class FakeConvexCall {
  /// Creates a recorded call.
  const FakeConvexCall(this.name, this.args, {this.optimisticUpdate});

  /// The function name.
  final String name;

  /// A deep copy of the arguments, as the function received them.
  final Map<String, dynamic> args;

  /// The optimistic update passed to a mutation, if any.
  final OptimisticUpdate? optimisticUpdate;

  @override
  String toString() => 'FakeConvexCall($name, $args)';
}

/// A fake paginated query returned by [FakeConvexClient.paginatedQuery].
///
/// Drive it from a test with [FakeConvexClient.emitPaginated] (or [emit]); it
/// records how many times [loadMore] was called via [loadMoreCount] and the
/// last requested page size via [lastLoadMoreNumItems].
class FakeConvexPaginatedQuery implements ConvexRuntimePaginatedQuery {
  /// Creates a fake paginated query for [name] with the given [pageSize].
  FakeConvexPaginatedQuery({
    required this.name,
    required this.pageSize,
    this.args = const <String, dynamic>{},
    void Function()? onCancel,
  }) : _onCancel = onCancel;

  /// The query name this paginated query is for.
  final String name;

  /// The configured page size.
  final int pageSize;

  /// The arguments the query was started with (excluding pagination options).
  final Map<String, dynamic> args;

  final StreamController<ConvexPaginatedResult> _controller =
      StreamController<ConvexPaginatedResult>.broadcast(sync: true);
  ConvexPaginatedResult _current = const ConvexPaginatedResult(
    results: <dynamic>[],
    status: ConvexPaginationStatus.loadingFirstPage,
    isDone: false,
  );

  /// The number of times [loadMore] has been called.
  int loadMoreCount = 0;

  /// The `numItems` override of the last [loadMore] call.
  int? lastLoadMoreNumItems;

  /// Whether this query has been canceled.
  bool isCanceled = false;

  final void Function()? _onCancel;

  @override
  Stream<ConvexPaginatedResult> get stream => _controller.stream;

  @override
  ConvexPaginatedResult get current => _current;

  /// Records the call. Returns `true` only while more pages can be loaded
  /// ([ConvexPaginationStatus.canLoadMore]), like the real engine.
  @override
  bool loadMore([int? numItems]) {
    loadMoreCount += 1;
    lastLoadMoreNumItems = numItems;
    return !isCanceled && _current.status == ConvexPaginationStatus.canLoadMore;
  }

  @override
  void cancel() {
    if (isCanceled) return;
    isCanceled = true;
    _onCancel?.call();
    unawaited(_controller.close());
  }

  /// Pushes an aggregated [result] to listeners and updates [current].
  void emit(ConvexPaginatedResult result) {
    _current = result;
    if (!_controller.isClosed) {
      _controller.add(result);
    }
  }
}

/// A fake subscription returned by [FakeConvexClient.subscribe].
class FakeConvexSubscription implements ConvexRuntimeSubscription {
  /// Creates a fake subscription for the given query [name].
  FakeConvexSubscription(
    this.name,
    this._controller, {
    this.args = const <String, dynamic>{},
    void Function()? onCancel,
  }) : _onCancel = onCancel;

  /// The query name this subscription is for.
  final String name;

  /// The arguments the subscription was created with.
  final Map<String, dynamic> args;

  final StreamController<ConvexRuntimeQueryEvent> _controller;
  final void Function()? _onCancel;
  bool _canceled = false;

  /// Whether this subscription has been canceled.
  bool get isCanceled => _canceled;

  @override
  Stream<ConvexRuntimeQueryEvent> get stream => _controller.stream;

  /// Delivers [event] to listeners unless the subscription is closed.
  void emit(ConvexRuntimeQueryEvent event) {
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  /// Closes the stream without unregistering (used on client dispose).
  void close() {
    unawaited(_controller.close());
  }

  @override
  void cancel() {
    if (_canceled) return;
    _canceled = true;
    _onCancel?.call();
    unawaited(_controller.close());
  }
}

/// [ConvexFunctionCaller] view of a [FakeConvexClient], backed by its
/// handlers (what `ConvexProvider.of(context).functionCaller` returns).
class _FakeFunctionCaller implements ConvexFunctionCaller {
  _FakeFunctionCaller(this._client);

  final FakeConvexClient _client;

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) => _client.query(name, args);

  @override
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) => _client.queryOnce<T>(name, args);

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
    OptimisticUpdate? optimisticUpdate,
  ]) => _client.mutate(name, args, optimisticUpdate);

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) => _client.action(name, args);

  @override
  ConvexSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final subscription = _client.subscribe(name, args);
    return ConvexSubscription(
      stream: subscription.stream.map<QueryResult>(
        (event) => switch (event) {
          ConvexRuntimeQuerySuccess(:final value, :final logLines) =>
            QuerySuccess(
              value,
              logLines: logLines,
              hasPendingWrites: event.hasPendingWrites,
            ),
          ConvexRuntimeQueryLoading() => QueryLoading(
            hasPendingWrites: event.hasPendingWrites,
          ),
          ConvexRuntimeQueryError(:final error) => QueryError(
            error is ConvexException ? error.message : error.toString(),
            data: error is ConvexException ? error.data : null,
          ),
        },
      ),
      onCancel: () async => subscription.cancel(),
    );
  }

  @override
  ConvexPaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    throw UnsupportedError(
      'FakeConvexClient.functionCaller does not support paginatedQuery; '
      'use FakeConvexClient.paginatedQuery (PaginatedQueryBuilder) instead.',
    );
  }
}
