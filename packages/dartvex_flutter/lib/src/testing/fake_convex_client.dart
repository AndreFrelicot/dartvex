import 'dart:async';

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
  }) : _currentConnectionState = initialConnectionState;

  final Map<String, dynamic Function(Map<String, dynamic>)> _queryHandlers =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, dynamic Function(Map<String, dynamic>)> _mutationHandlers =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, dynamic Function(Map<String, dynamic>)> _actionHandlers =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, StreamController<ConvexRuntimeQueryEvent>>
      _subscriptionControllers =
      <String, StreamController<ConvexRuntimeQueryEvent>>{};

  final StreamController<ConvexConnectionState> _connectionController =
      StreamController<ConvexConnectionState>.broadcast(sync: true);
  ConvexConnectionState _currentConnectionState;
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
    _subscriptionControllers[name]?.add(
      ConvexRuntimeQuerySuccess(value),
    );
  }

  /// Emit an error to a named subscription.
  void emitSubscriptionError(String name, Object error) {
    _subscriptionControllers[name]?.add(
      ConvexRuntimeQueryError(error),
    );
  }

  /// Update the fake connection state.
  void emitConnectionState(ConvexConnectionState state) {
    _currentConnectionState = state;
    _connectionController.add(state);
  }

  @override
  Stream<ConvexConnectionState> get connectionState =>
      _connectionController.stream;

  @override
  ConvexConnectionState get currentConnectionState => _currentConnectionState;

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final handler = _queryHandlers[name];
    if (handler == null) {
      throw StateError('No query handler registered for "$name"');
    }
    return handler(args);
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
    final controller =
        StreamController<ConvexRuntimeQueryEvent>.broadcast(sync: true);
    _subscriptionControllers[name] = controller;

    // Auto-emit initial value from handler if registered.
    // Scheduled as a microtask so the listener is attached first.
    final handler = _queryHandlers[name];
    if (handler != null) {
      scheduleMicrotask(() {
        if (!controller.isClosed) {
          controller.add(ConvexRuntimeQuerySuccess(handler(args)));
        }
      });
    }

    return FakeConvexSubscription(name, controller);
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final handler = _mutationHandlers[name];
    if (handler == null) {
      throw StateError('No mutation handler registered for "$name"');
    }
    return handler(args);
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
    return handler(args);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final controller in _subscriptionControllers.values) {
      unawaited(controller.close());
    }
    unawaited(_connectionController.close());
  }
}

/// A fake subscription returned by [FakeConvexClient.subscribe].
class FakeConvexSubscription implements ConvexRuntimeSubscription {
  /// Creates a fake subscription for the given query [name].
  FakeConvexSubscription(this.name, this._controller);

  /// The query name this subscription is for.
  final String name;
  final StreamController<ConvexRuntimeQueryEvent> _controller;
  bool _canceled = false;

  /// Whether this subscription has been canceled.
  bool get isCanceled => _canceled;

  @override
  Stream<ConvexRuntimeQueryEvent> get stream => _controller.stream;

  @override
  void cancel() {
    if (_canceled) return;
    _canceled = true;
    unawaited(_controller.close());
  }
}
