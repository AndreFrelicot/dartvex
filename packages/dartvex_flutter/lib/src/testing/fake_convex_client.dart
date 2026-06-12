import 'dart:async';

import 'package:dartvex/dartvex.dart'
    show
        ConnectionStatus,
        ConvexPaginatedResult,
        ConvexPaginationStatus,
        OptimisticUpdate,
        convexToJson,
        jsonToConvex;

import '../runtime_client.dart';

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
class FakeConvexClient implements ConvexRuntimeClient {
  /// Creates a fake client with an optional initial connection state.
  FakeConvexClient({
    ConvexConnectionState initialConnectionState =
        ConvexConnectionState.connected,
  }) : _currentConnectionState = initialConnectionState,
       _currentConnectionStatus = ConnectionStatus.fromState(
         initialConnectionState,
       );

  final Map<String, dynamic Function(Map<String, dynamic>)> _queryHandlers =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, dynamic Function(Map<String, dynamic>)> _mutationHandlers =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, dynamic Function(Map<String, dynamic>)> _actionHandlers =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, List<StreamController<ConvexRuntimeQueryEvent>>>
  _subscriptionControllers =
      <String, List<StreamController<ConvexRuntimeQueryEvent>>>{};
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

  /// Emit a success value to a named subscription.
  void emitSubscription(String name, dynamic value) {
    for (final controller in List<StreamController<ConvexRuntimeQueryEvent>>.of(
      _subscriptionControllers[name] ??
          const <StreamController<ConvexRuntimeQueryEvent>>[],
    )) {
      if (!controller.isClosed) {
        controller.add(ConvexRuntimeQuerySuccess(value));
      }
    }
  }

  /// Emit an error to a named subscription.
  void emitSubscriptionError(String name, Object error) {
    for (final controller in List<StreamController<ConvexRuntimeQueryEvent>>.of(
      _subscriptionControllers[name] ??
          const <StreamController<ConvexRuntimeQueryEvent>>[],
    )) {
      if (!controller.isClosed) {
        controller.add(ConvexRuntimeQueryError(error));
      }
    }
  }

  /// Emit an aggregated paginated result to the named paginated query.
  void emitPaginated(
    String name, {
    required List<dynamic> results,
    ConvexPaginationStatus status = ConvexPaginationStatus.canLoadMore,
    bool isDone = false,
  }) {
    final result = ConvexPaginatedResult(
      results: results,
      status: status,
      isDone: isDone,
    );
    for (final query in List<FakeConvexPaginatedQuery>.of(
      _paginatedQueries[name] ?? const <FakeConvexPaginatedQuery>[],
    )) {
      if (!query.isCanceled) {
        query.emit(result);
      }
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
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final handler = _queryHandlers[name];
    if (handler == null) {
      throw StateError('No query handler registered for "$name"');
    }
    return handler(_snapshotArgs(args));
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
    final normalizedArgs = _snapshotArgs(args);
    final controller = StreamController<ConvexRuntimeQueryEvent>.broadcast(
      sync: true,
    );
    _subscriptionControllers
        .putIfAbsent(name, () => <StreamController<ConvexRuntimeQueryEvent>>[])
        .add(controller);

    // Auto-emit initial value from handler if registered.
    // Scheduled as a microtask so the listener is attached first.
    final handler = _queryHandlers[name];
    if (handler != null) {
      scheduleMicrotask(() {
        if (!controller.isClosed) {
          controller.add(ConvexRuntimeQuerySuccess(handler(normalizedArgs)));
        }
      });
    }

    return FakeConvexSubscription(
      name,
      controller,
      onCancel: () => _removeSubscriptionController(name, controller),
    );
  }

  @override
  ConvexRuntimePaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    late final FakeConvexPaginatedQuery query;
    query = FakeConvexPaginatedQuery(
      name: name,
      pageSize: pageSize,
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
    // This fake has no query overlay, so [optimisticUpdate] is accepted for API
    // compatibility but not applied; assert on it via a custom handler if a test
    // needs to observe it.
    final handler = _mutationHandlers[name];
    if (handler == null) {
      throw StateError('No mutation handler registered for "$name"');
    }
    return handler(_snapshotArgs(args));
  }

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final handler = _actionHandlers[name];
    if (handler == null) {
      throw StateError('No action handler registered for "$name"');
    }
    return handler(_snapshotArgs(args));
  }

  @override
  Future<void> reconnectNow(String reason) async {}

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    // close() delivers the done event synchronously (sync controllers), and a
    // done listener may cancel a subscription, which mutates these
    // collections — iterate snapshots, like the paginated branch below.
    for (final controllers
        in List<List<StreamController<ConvexRuntimeQueryEvent>>>.of(
          _subscriptionControllers.values,
        )) {
      for (final controller
          in List<StreamController<ConvexRuntimeQueryEvent>>.of(controllers)) {
        unawaited(controller.close());
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

  void _removeSubscriptionController(
    String name,
    StreamController<ConvexRuntimeQueryEvent> controller,
  ) {
    final controllers = _subscriptionControllers[name];
    if (controllers == null) {
      return;
    }
    controllers.remove(controller);
    if (controllers.isEmpty) {
      _subscriptionControllers.remove(name);
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

  Map<String, dynamic> _snapshotArgs(Map<String, dynamic> args) {
    return jsonToConvex(convexToJson(args)) as Map<String, dynamic>;
  }
}

/// A fake paginated query returned by [FakeConvexClient.paginatedQuery].
///
/// Drive it from a test with [FakeConvexClient.emitPaginated]; it records how
/// many times [loadMore] was called via [loadMoreCount].
class FakeConvexPaginatedQuery implements ConvexRuntimePaginatedQuery {
  /// Creates a fake paginated query for [name] with the given [pageSize].
  FakeConvexPaginatedQuery({
    required this.name,
    required this.pageSize,
    void Function()? onCancel,
  }) : _onCancel = onCancel;

  /// The query name this paginated query is for.
  final String name;

  /// The configured page size.
  final int pageSize;

  final StreamController<ConvexPaginatedResult> _controller =
      StreamController<ConvexPaginatedResult>.broadcast(sync: true);
  ConvexPaginatedResult _current = const ConvexPaginatedResult(
    results: <dynamic>[],
    status: ConvexPaginationStatus.loadingFirstPage,
    isDone: false,
  );

  /// The number of times [loadMore] has been called.
  int loadMoreCount = 0;

  /// Whether this query has been canceled.
  bool isCanceled = false;

  final void Function()? _onCancel;

  @override
  Stream<ConvexPaginatedResult> get stream => _controller.stream;

  @override
  ConvexPaginatedResult get current => _current;

  @override
  bool loadMore([int? numItems]) {
    loadMoreCount += 1;
    return true;
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
    void Function()? onCancel,
  }) : _onCancel = onCancel;

  /// The query name this subscription is for.
  final String name;
  final StreamController<ConvexRuntimeQueryEvent> _controller;
  final void Function()? _onCancel;
  bool _canceled = false;

  /// Whether this subscription has been canceled.
  bool get isCanceled => _canceled;

  @override
  Stream<ConvexRuntimeQueryEvent> get stream => _controller.stream;

  @override
  void cancel() {
    if (_canceled) return;
    _canceled = true;
    _onCancel?.call();
    unawaited(_controller.close());
  }
}
