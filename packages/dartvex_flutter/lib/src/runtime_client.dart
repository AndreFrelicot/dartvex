import 'dart:async';

import 'package:dartvex/dartvex.dart' as convex;

import 'snapshot.dart';

/// Alias for the connection states emitted by the underlying Dartvex client.
typedef ConvexConnectionState = convex.ConnectionState;

/// Runtime interface consumed by Flutter widgets in this package.
abstract class ConvexRuntimeClient {
  /// Creates a runtime client abstraction.
  ConvexRuntimeClient();

  /// Executes a one-shot query.
  Future<dynamic> query(String name, [Map<String, dynamic> args = const {}]);

  /// Execute a one-shot query with a typed return value.
  Future<T> queryOnce<T>(String name, [Map<String, dynamic> args = const {}]);

  /// Subscribes to a reactive query.
  ConvexRuntimeSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const {},
  ]);

  /// Subscribes to a live, reactive paginated query.
  ///
  /// Returns a handle whose stream emits the gapless concatenation of every
  /// loaded page; call [ConvexRuntimePaginatedQuery.loadMore] to fetch the next
  /// page. See `ConvexClient.paginatedQuery`.
  ConvexRuntimePaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  });

  /// Executes a mutation, optionally with an [optimisticUpdate] that overlays
  /// query results locally until the mutation completes. See
  /// `ConvexClient.mutate`.
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const {},
    convex.OptimisticUpdate? optimisticUpdate,
  ]);

  /// Executes an action.
  Future<dynamic> action(String name, [Map<String, dynamic> args = const {}]);

  /// Broadcasts connection state changes.
  Stream<ConvexConnectionState> get connectionState;

  /// The current connection state.
  ConvexConnectionState get currentConnectionState;

  /// Broadcasts a rich connection status snapshot each time it changes.
  ///
  /// See `ConvexClient.connectionStatus`. Read [currentConnectionStatus] for the
  /// current value.
  Stream<convex.ConnectionStatus> get connectionStatus;

  /// The current rich connection status snapshot.
  ///
  /// See `ConvexClient.currentConnectionStatus`.
  convex.ConnectionStatus get currentConnectionStatus;

  /// Broadcasts whether the client is refreshing auth after a rejection.
  ///
  /// Emits `true` while a fresh token is fetched after a server `AuthError`
  /// and `false` once it is confirmed. See `ConvexClient.authRefreshing`.
  Stream<bool> get authRefreshing;

  /// Whether the client is currently refreshing auth after a rejection.
  bool get currentAuthRefreshing;

  /// Forces an immediate reconnect of the underlying connection.
  Future<void> reconnectNow(String reason);

  /// Releases any resources held by the runtime client.
  void dispose();
}

/// Handle for a runtime query subscription.
abstract class ConvexRuntimeSubscription {
  /// Stream of runtime query events.
  Stream<ConvexRuntimeQueryEvent> get stream;

  /// Cancels the subscription.
  void cancel();
}

/// Handle for a live, reactive paginated query consumed by Flutter widgets.
///
/// Mirrors the core `ConvexPaginatedQuery`: [stream] emits an aggregated
/// [convex.ConvexPaginatedResult] on every change, [current] is the latest
/// snapshot, and [loadMore] fetches the next page.
abstract class ConvexRuntimePaginatedQuery {
  /// Reactive stream of aggregated page results.
  Stream<convex.ConvexPaginatedResult> get stream;

  /// The latest aggregated snapshot, available synchronously.
  convex.ConvexPaginatedResult get current;

  /// Loads the next page, returning whether loading was actually started.
  ///
  /// [numItems] overrides the page size for the new page. See
  /// `ConvexPaginatedQuery.loadMore`.
  bool loadMore([int? numItems]);

  /// Cancels the query and releases its page subscriptions.
  void cancel();
}

/// Base class for events emitted by a [ConvexRuntimeSubscription].
sealed class ConvexRuntimeQueryEvent {
  /// Creates a runtime query event.
  const ConvexRuntimeQueryEvent({
    required this.source,
    required this.hasPendingWrites,
  });

  /// Where the query value or error originated.
  final ConvexQuerySource source;

  /// Whether there are pending optimistic writes affecting the query.
  final bool hasPendingWrites;
}

/// Runtime event containing a successful query value.
class ConvexRuntimeQuerySuccess extends ConvexRuntimeQueryEvent {
  /// Creates a successful query event.
  const ConvexRuntimeQuerySuccess(
    this.value, {
    this.logLines = const <String>[],
    super.source = ConvexQuerySource.remote,
    super.hasPendingWrites = false,
  });

  /// The returned query value.
  final dynamic value;

  /// Optional log lines attached to the result.
  final List<String> logLines;
}

/// Runtime event containing a query error.
class ConvexRuntimeQueryError extends ConvexRuntimeQueryEvent {
  /// Creates a failed query event.
  const ConvexRuntimeQueryError(
    this.error, {
    this.stackTrace,
    super.source = ConvexQuerySource.unknown,
    super.hasPendingWrites = false,
  });

  /// The reported error.
  final Object error;

  /// Optional stack trace associated with the error.
  final StackTrace? stackTrace;
}

/// Wraps a [convex.ConvexClient] as a [ConvexRuntimeClient].
class ConvexClientRuntime implements ConvexRuntimeClient {
  /// Creates a runtime adapter around [_client].
  ///
  /// When [disposeClient] is true, disposing this runtime also disposes the client.
  ConvexClientRuntime(this._client, {this.disposeClient = false})
      : _currentConnectionState = _client.currentConnectionState {
    _connectionStateSubscription = _client.connectionState.listen((state) {
      _currentConnectionState = state;
    });
  }

  final convex.ConvexClient _client;

  /// Whether disposing this runtime should also dispose the wrapped client.
  final bool disposeClient;
  late final StreamSubscription<ConvexConnectionState>
      _connectionStateSubscription;
  ConvexConnectionState _currentConnectionState;
  bool _disposed = false;

  @override

  /// Broadcasts connection state changes from the wrapped client.
  Stream<ConvexConnectionState> get connectionState => _client.connectionState;

  @override

  /// The current connection state observed from the wrapped client.
  ConvexConnectionState get currentConnectionState => _currentConnectionState;

  @override

  /// Broadcasts rich connection status changes from the wrapped client.
  Stream<convex.ConnectionStatus> get connectionStatus =>
      _client.connectionStatus;

  @override

  /// The current rich connection status observed from the wrapped client.
  convex.ConnectionStatus get currentConnectionStatus =>
      _client.currentConnectionStatus;

  @override

  /// Broadcasts auth-refreshing changes from the wrapped client.
  Stream<bool> get authRefreshing => _client.authRefreshing;

  @override

  /// Whether the wrapped client is currently refreshing auth.
  bool get currentAuthRefreshing => _client.isAuthRefreshing;

  @override

  /// Executes an action through the wrapped client.
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.action(name, args);
  }

  @override

  /// Forces an immediate reconnect through the wrapped client.
  Future<void> reconnectNow(String reason) => _client.reconnectNow(reason);

  @override

  /// Disposes subscriptions and optionally the wrapped client.
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

  /// Executes a mutation through the wrapped client.
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
    convex.OptimisticUpdate? optimisticUpdate,
  ]) {
    return _client.mutate(name, args, optimisticUpdate);
  }

  @override

  /// Executes a query through the wrapped client.
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.query(name, args);
  }

  @override

  /// Executes a typed one-shot query through the wrapped client.
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.queryOnce<T>(name, args);
  }

  @override

  /// Subscribes to a query through the wrapped client.
  ConvexRuntimeSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _ConvexClientRuntimeSubscription(_client.subscribe(name, args));
  }

  @override

  /// Subscribes to a paginated query through the wrapped client.
  ConvexRuntimePaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    return _ConvexClientRuntimePaginatedQuery(
      _client.paginatedQuery(name, args, pageSize: pageSize),
    );
  }
}

/// Adapts a core [convex.ConvexPaginatedQuery] to [ConvexRuntimePaginatedQuery].
class _ConvexClientRuntimePaginatedQuery
    implements ConvexRuntimePaginatedQuery {
  _ConvexClientRuntimePaginatedQuery(this._query);

  final convex.ConvexPaginatedQuery _query;

  @override
  Stream<convex.ConvexPaginatedResult> get stream => _query.stream;

  @override
  convex.ConvexPaginatedResult get current => _query.current;

  @override
  bool loadMore([int? numItems]) => _query.loadMore(numItems);

  @override
  void cancel() => _query.cancel();
}

class _ConvexClientRuntimeSubscription implements ConvexRuntimeSubscription {
  _ConvexClientRuntimeSubscription(this._subscription)
      : _stream = _subscription.stream.map((event) {
          switch (event) {
            case convex.QuerySuccess(:final value):
              return ConvexRuntimeQuerySuccess(value);
            case convex.QueryError(
                :final message,
                :final data,
                :final logLines
              ):
              return ConvexRuntimeQueryError(
                convex.ConvexException(
                  message,
                  data: data,
                  logLines: logLines,
                ),
              );
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
