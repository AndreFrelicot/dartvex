import 'dart:async';

import 'package:dartvex_flutter/dartvex_flutter.dart';

class FakeRuntimeClient implements ConvexRuntimeClient {
  FakeRuntimeClient({
    ConvexConnectionState initialConnectionState =
        ConvexConnectionState.connecting,
  })  : _currentConnectionState = initialConnectionState,
        _currentConnectionStatus =
            ConnectionStatus.fromState(initialConnectionState);

  final List<FakeRequestCall> queryCalls = <FakeRequestCall>[];
  final List<FakeSubscriptionCall> subscribeCalls = <FakeSubscriptionCall>[];
  final List<FakeRequestCall> mutateCalls = <FakeRequestCall>[];
  final List<FakeRequestCall> actionCalls = <FakeRequestCall>[];
  final List<FakePaginatedQueryCall> paginatedQueryCalls =
      <FakePaginatedQueryCall>[];
  final StreamController<ConvexConnectionState> _connectionController =
      StreamController<ConvexConnectionState>.broadcast(sync: true);
  final StreamController<ConnectionStatus> _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast(sync: true);
  final StreamController<bool> _authRefreshingController =
      StreamController<bool>.broadcast(sync: true);
  bool _currentAuthRefreshing = false;

  Future<dynamic> Function(String name, Map<String, dynamic> args)? onQuery;
  Future<dynamic> Function(String name, Map<String, dynamic> args)? onMutate;
  Future<dynamic> Function(String name, Map<String, dynamic> args)? onAction;
  ConvexPaginatedResult? nextPaginatedInitialResult;

  ConvexConnectionState _currentConnectionState;
  ConnectionStatus _currentConnectionStatus;
  bool disposed = false;

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

  void emitAuthRefreshing(bool isRefreshing) {
    _currentAuthRefreshing = isRefreshing;
    _authRefreshingController.add(isRefreshing);
  }

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final call = FakeRequestCall(name, Map<String, dynamic>.from(args));
    actionCalls.add(call);
    final handler = onAction;
    if (handler == null) {
      return Future<dynamic>.value(null);
    }
    return handler(name, args);
  }

  final List<String> reconnectNowCalls = <String>[];

  /// When set, [reconnectNow] throws this synchronously, mirroring the real
  /// client's disposed assertion (which throws before returning a future).
  Object? reconnectNowSyncError;

  @override
  Future<void> reconnectNow(String reason) {
    final error = reconnectNowSyncError;
    if (error != null) {
      throw error;
    }
    reconnectNowCalls.add(reason);
    return Future<void>.value();
  }

  @override
  void dispose() {
    if (disposed) {
      return;
    }
    disposed = true;
    for (final call in subscribeCalls) {
      call.subscription.cancel();
    }
    for (final call in paginatedQueryCalls) {
      call.query.cancel();
    }
    unawaited(_connectionController.close());
    unawaited(_connectionStatusController.close());
    unawaited(_authRefreshingController.close());
  }

  void emitConnectionState(ConvexConnectionState state) {
    _currentConnectionState = state;
    _connectionController.add(state);
    _currentConnectionStatus = ConnectionStatus.fromState(state);
    if (!_connectionStatusController.isClosed) {
      _connectionStatusController.add(_currentConnectionStatus);
    }
  }

  void emitConnectionStatus(ConnectionStatus status) {
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

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
    OptimisticUpdate? optimisticUpdate,
  ]) {
    final call = FakeRequestCall(
      name,
      Map<String, dynamic>.from(args),
      optimisticUpdate: optimisticUpdate,
    );
    mutateCalls.add(call);
    final handler = onMutate;
    if (handler == null) {
      return Future<dynamic>.value(null);
    }
    return handler(name, args);
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final call = FakeRequestCall(name, Map<String, dynamic>.from(args));
    queryCalls.add(call);
    final handler = onQuery;
    if (handler == null) {
      return Future<dynamic>.value(null);
    }
    return handler(name, args);
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
    final subscription = FakeRuntimeSubscription(
      name,
      Map<String, dynamic>.from(args),
    );
    subscribeCalls.add(
      FakeSubscriptionCall(name, Map<String, dynamic>.from(args), subscription),
    );
    return subscription;
  }

  @override
  ConvexRuntimePaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    final query = FakeRuntimePaginatedQuery(
      name,
      Map<String, dynamic>.from(args),
      pageSize,
      initial: nextPaginatedInitialResult,
    );
    nextPaginatedInitialResult = null;
    paginatedQueryCalls.add(
      FakePaginatedQueryCall(
        name,
        Map<String, dynamic>.from(args),
        pageSize,
        query,
      ),
    );
    return query;
  }
}

class FakeRequestCall {
  const FakeRequestCall(this.name, this.args, {this.optimisticUpdate});

  final String name;
  final Map<String, dynamic> args;

  /// The optimistic update passed to a `mutate` call, if any.
  final OptimisticUpdate? optimisticUpdate;
}

class FakeSubscriptionCall extends FakeRequestCall {
  const FakeSubscriptionCall(super.name, super.args, this.subscription);

  final FakeRuntimeSubscription subscription;
}

class FakePaginatedQueryCall {
  const FakePaginatedQueryCall(
    this.name,
    this.args,
    this.pageSize,
    this.query,
  );

  final String name;
  final Map<String, dynamic> args;
  final int pageSize;
  final FakeRuntimePaginatedQuery query;
}

class FakeRuntimePaginatedQuery implements ConvexRuntimePaginatedQuery {
  FakeRuntimePaginatedQuery(
    this.name,
    this.args,
    this.pageSize, {
    ConvexPaginatedResult? initial,
  }) : _current = initial ??
            const ConvexPaginatedResult(
              results: <dynamic>[],
              status: ConvexPaginationStatus.loadingFirstPage,
              isDone: false,
            );

  final String name;
  final Map<String, dynamic> args;
  final int pageSize;
  final StreamController<ConvexPaginatedResult> _controller =
      StreamController<ConvexPaginatedResult>.broadcast(sync: true);
  ConvexPaginatedResult _current;
  int loadMoreCount = 0;
  int? lastLoadMoreNumItems;
  bool isCanceled = false;

  @override
  Stream<ConvexPaginatedResult> get stream => _controller.stream;

  @override
  ConvexPaginatedResult get current => _current;

  @override
  bool loadMore([int? numItems]) {
    loadMoreCount += 1;
    lastLoadMoreNumItems = numItems;
    return true;
  }

  @override
  void cancel() {
    if (isCanceled) {
      return;
    }
    isCanceled = true;
    unawaited(_controller.close());
  }

  void emit(ConvexPaginatedResult result) {
    _current = result;
    if (!_controller.isClosed) {
      _controller.add(result);
    }
  }

  void emitStreamError(Object error) {
    if (!_controller.isClosed) {
      _controller.addError(error, StackTrace.current);
    }
  }

  void emitPage(
    List<dynamic> results, {
    required ConvexPaginationStatus status,
    bool isDone = false,
    Object? error,
  }) {
    emit(
      ConvexPaginatedResult(
        results: results,
        status: status,
        isDone: isDone,
        error: error,
      ),
    );
  }
}

class FakeRuntimeSubscription implements ConvexRuntimeSubscription {
  FakeRuntimeSubscription(this.name, this.args);

  final String name;
  final Map<String, dynamic> args;
  final StreamController<ConvexRuntimeQueryEvent> _controller =
      StreamController<ConvexRuntimeQueryEvent>.broadcast(sync: true);
  bool isCanceled = false;

  @override
  Stream<ConvexRuntimeQueryEvent> get stream => _controller.stream;

  void emitStreamError(Object error) {
    if (!isCanceled) {
      _controller.addError(error, StackTrace.current);
    }
  }

  void emitError(
    Object error, {
    StackTrace? stackTrace,
    ConvexQuerySource source = ConvexQuerySource.unknown,
    bool hasPendingWrites = false,
  }) {
    if (isCanceled) {
      return;
    }
    _controller.add(
      ConvexRuntimeQueryError(
        error,
        stackTrace: stackTrace,
        source: source,
        hasPendingWrites: hasPendingWrites,
      ),
    );
  }

  void emitSuccess(
    dynamic value, {
    List<String> logLines = const <String>[],
    ConvexQuerySource source = ConvexQuerySource.remote,
    bool hasPendingWrites = false,
  }) {
    if (isCanceled) {
      return;
    }
    _controller.add(
      ConvexRuntimeQuerySuccess(
        value,
        logLines: logLines,
        source: source,
        hasPendingWrites: hasPendingWrites,
      ),
    );
  }

  void emitLoading({
    ConvexQuerySource source = ConvexQuerySource.cache,
    bool hasPendingWrites = false,
  }) {
    if (isCanceled) {
      return;
    }
    _controller.add(
      ConvexRuntimeQueryLoading(
        source: source,
        hasPendingWrites: hasPendingWrites,
      ),
    );
  }

  @override
  void cancel() {
    if (isCanceled) {
      return;
    }
    isCanceled = true;
    unawaited(_controller.close());
  }
}
