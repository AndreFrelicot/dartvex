import 'dart:async';

import 'package:dartvex/dartvex.dart';

class FakeAuthClient<TUser> implements ConvexAuthClient<TUser> {
  FakeAuthClient({
    required AuthState<TUser> initialAuthState,
    this.loginResult,
    this.cachedLoginResult,
  }) : _currentAuthState = initialAuthState;

  final TUser? loginResult;
  final TUser? cachedLoginResult;
  final StreamController<AuthState<TUser>> _authStateController =
      StreamController<AuthState<TUser>>.broadcast(sync: true);

  AuthState<TUser> _currentAuthState;
  ConnectionState _currentConnectionState = ConnectionState.connecting;
  bool disposed = false;

  void emitAuthState(AuthState<TUser> state) {
    _currentAuthState = state;
    _authStateController.add(state);
  }

  void emitConnectionState(ConnectionState state) {
    _currentConnectionState = state;
  }

  @override
  Stream<AuthState<TUser>> get authState => _authStateController.stream;

  @override
  AuthState<TUser> get currentAuthState => _currentAuthState;

  @override
  Stream<ConnectionState> get connectionState => const Stream.empty();

  @override
  ConnectionState get currentConnectionState => _currentConnectionState;

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    throw UnimplementedError();
  }

  @override
  void dispose() {
    if (disposed) {
      return;
    }
    disposed = true;
    unawaited(_authStateController.close());
  }

  @override
  Future<TUser> login() async {
    final result = loginResult;
    if (result == null) {
      throw StateError('No loginResult configured');
    }
    emitAuthState(AuthAuthenticated<TUser>(result));
    return result;
  }

  @override
  Future<TUser> loginFromCache() async {
    final result = cachedLoginResult;
    if (result == null) {
      throw StateError('No cachedLoginResult configured');
    }
    emitAuthState(AuthAuthenticated<TUser>(result));
    return result;
  }

  @override
  Future<void> logout() async {
    emitAuthState(AuthUnauthenticated<TUser>());
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    throw UnimplementedError();
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
    throw UnimplementedError();
  }
}
