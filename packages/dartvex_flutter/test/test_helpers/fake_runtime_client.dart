import 'dart:async';

import 'package:dartvex_flutter/dartvex_flutter.dart';

class FakeRuntimeClient implements ConvexRuntimeClient {
  FakeRuntimeClient({
    ConvexConnectionState initialConnectionState =
        ConvexConnectionState.connecting,
  }) : _currentConnectionState = initialConnectionState;

  final List<FakeRequestCall> queryCalls = <FakeRequestCall>[];
  final List<FakeSubscriptionCall> subscribeCalls = <FakeSubscriptionCall>[];
  final List<FakeRequestCall> mutateCalls = <FakeRequestCall>[];
  final List<FakeRequestCall> actionCalls = <FakeRequestCall>[];
  final StreamController<ConvexConnectionState> _connectionController =
      StreamController<ConvexConnectionState>.broadcast(sync: true);

  Future<dynamic> Function(String name, Map<String, dynamic> args)? onQuery;
  Future<dynamic> Function(String name, Map<String, dynamic> args)? onMutate;
  Future<dynamic> Function(String name, Map<String, dynamic> args)? onAction;

  ConvexConnectionState _currentConnectionState;
  bool disposed = false;

  @override
  Stream<ConvexConnectionState> get connectionState =>
      _connectionController.stream;

  @override
  ConvexConnectionState get currentConnectionState => _currentConnectionState;

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

  @override
  void dispose() {
    if (disposed) {
      return;
    }
    disposed = true;
    for (final call in subscribeCalls) {
      call.subscription.cancel();
    }
    unawaited(_connectionController.close());
  }

  void emitConnectionState(ConvexConnectionState state) {
    _currentConnectionState = state;
    _connectionController.add(state);
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final call = FakeRequestCall(name, Map<String, dynamic>.from(args));
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
}

class FakeRequestCall {
  const FakeRequestCall(this.name, this.args);

  final String name;
  final Map<String, dynamic> args;
}

class FakeSubscriptionCall extends FakeRequestCall {
  const FakeSubscriptionCall(super.name, super.args, this.subscription);

  final FakeRuntimeSubscription subscription;
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

  @override
  void cancel() {
    if (isCanceled) {
      return;
    }
    isCanceled = true;
    unawaited(_controller.close());
  }
}
