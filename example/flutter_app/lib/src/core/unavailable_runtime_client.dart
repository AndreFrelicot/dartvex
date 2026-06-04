import 'package:dartvex_flutter/dartvex_flutter.dart';

class UnavailableRuntimeClient implements ConvexRuntimeClient {
  const UnavailableRuntimeClient();

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return Future<dynamic>.error(_error());
  }

  @override
  Stream<ConvexConnectionState> get connectionState =>
      Stream<ConvexConnectionState>.value(ConvexConnectionState.disconnected);

  @override
  ConvexConnectionState get currentConnectionState =>
      ConvexConnectionState.disconnected;

  @override
  Stream<ConnectionStatus> get connectionStatus =>
      Stream<ConnectionStatus>.value(
        ConnectionStatus.fromState(ConvexConnectionState.disconnected),
      );

  @override
  ConnectionStatus get currentConnectionStatus =>
      ConnectionStatus.fromState(ConvexConnectionState.disconnected);

  @override
  Stream<bool> get authRefreshing => Stream<bool>.value(false);

  @override
  bool get currentAuthRefreshing => false;

  @override
  void dispose() {}

  @override
  ConvexRuntimePaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    throw _error();
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
    OptimisticUpdate? optimisticUpdate,
  ]) {
    return Future<dynamic>.error(_error());
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return Future<dynamic>.error(_error());
  }

  @override
  Future<void> reconnectNow(String reason) async {}

  @override
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return Future<T>.error(_error());
  }

  @override
  ConvexRuntimeSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return const _UnavailableRuntimeSubscription();
  }

  StateError _error() =>
      StateError('Convex demo is not configured. Set CONVEX_DEMO_URL first.');
}

class _UnavailableRuntimeSubscription implements ConvexRuntimeSubscription {
  const _UnavailableRuntimeSubscription();

  @override
  void cancel() {}

  @override
  Stream<ConvexRuntimeQueryEvent> get stream =>
      const Stream<ConvexRuntimeQueryEvent>.empty();
}
