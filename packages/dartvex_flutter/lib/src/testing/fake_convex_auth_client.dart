import 'dart:async';

import 'package:dartvex/dartvex.dart'
    show
        AuthAuthenticated,
        AuthLoading,
        AuthSessionEndedError,
        AuthState,
        AuthUnauthenticated,
        ConnectionState,
        ConvexAuthClient,
        ConvexException,
        ConvexFunctionCaller,
        ConvexPaginatedQuery,
        ConvexSubscription,
        OptimisticUpdate;

import 'fake_convex_client.dart';

/// A fake [ConvexAuthClient] for testing auth flows without a backend or an
/// auth provider.
///
/// Script the outcome of each auth call with [onLogin], [onLoginFromCache]
/// and [onLogout], or push a state directly with [emit]. Every call is counted
/// ([loginCalls], [loginFromCacheCalls], [logoutCalls], [clearAuthCalls]).
/// Function calls (`query`, `mutate`, `subscribe`, …) and the connection
/// state go to [client], a [FakeConvexClient] whose handlers you set as usual
/// (`paginatedQuery` is unsupported here; use the [FakeConvexClient] through
/// `ConvexProvider` for `PaginatedQueryBuilder`).
///
/// ```dart
/// final convex = FakeConvexClient()..whenQuery('users:me', returns: me);
/// final auth = FakeConvexAuthClient<Session>(client: convex)
///   ..onLoginFromCache = () => session;
///
/// await tester.pumpWidget(
///   ConvexProvider(
///     client: convex,
///     child: ConvexAuthProvider<Session>(client: auth, child: MyApp()),
///   ),
/// );
/// ```
///
/// Like `ConvexClientWithAuth`, [login] and [loginFromCache] emit
/// [AuthLoading] and then [AuthAuthenticated]. When they throw, the previous
/// [AuthAuthenticated] state is restored, except for an error implementing
/// [AuthSessionEndedError], which ends in [AuthUnauthenticated]. [logout] and
/// [clearAuth] always end in [AuthUnauthenticated] (a throwing [onLogout] is
/// rethrown afterwards).
class FakeConvexAuthClient<TUser> implements ConvexAuthClient<TUser> {
  /// Creates a fake auth client in [initialAuthState] (signed out by
  /// default), backed by [client] (a new [FakeConvexClient] by default).
  FakeConvexAuthClient({
    AuthState<TUser>? initialAuthState,
    FakeConvexClient? client,
    this.onLogin,
    this.onLoginFromCache,
    this.onLogout,
  }) : client = client ?? FakeConvexClient(),
       _currentAuthState = initialAuthState ?? AuthUnauthenticated<TUser>();

  /// Fake backing function calls and the connection state.
  final FakeConvexClient client;

  /// Result of [login]: return the signed-in user or throw. When unset,
  /// [login] throws a [StateError].
  FutureOr<TUser> Function()? onLogin;

  /// Result of [loginFromCache]: return the restored user or throw. When
  /// unset, [loginFromCache] fails like a provider with no stored session
  /// (an error implementing [AuthSessionEndedError]).
  FutureOr<TUser> Function()? onLoginFromCache;

  /// Called by [logout] (a no-op when unset); a throw is rethrown after the
  /// state became [AuthUnauthenticated].
  FutureOr<void> Function()? onLogout;

  /// Number of [login] calls.
  int loginCalls = 0;

  /// Number of [loginFromCache] calls.
  int loginFromCacheCalls = 0;

  /// Number of [logout] calls.
  int logoutCalls = 0;

  /// Number of [clearAuth] calls.
  int clearAuthCalls = 0;

  final StreamController<AuthState<TUser>> _authStateController =
      StreamController<AuthState<TUser>>.broadcast(sync: true);
  AuthState<TUser> _currentAuthState;
  bool _disposed = false;

  /// Whether [dispose] was called.
  bool get isDisposed => _disposed;

  /// Sets [currentAuthState] and emits [state] on [authState].
  void emit(AuthState<TUser> state) {
    _currentAuthState = state;
    if (!_authStateController.isClosed) {
      _authStateController.add(state);
    }
  }

  @override
  Stream<AuthState<TUser>> get authState => _authStateController.stream;

  @override
  AuthState<TUser> get currentAuthState => _currentAuthState;

  @override
  Stream<ConnectionState> get connectionState => client.connectionState;

  @override
  ConnectionState get currentConnectionState => client.currentConnectionState;

  @override
  Future<TUser> login() {
    loginCalls++;
    return _signIn(
      onLogin ??
          () => throw StateError('FakeConvexAuthClient.onLogin is not set.'),
    );
  }

  @override
  Future<TUser> loginFromCache() {
    loginFromCacheCalls++;
    return _signIn(
      onLoginFromCache ??
          () => throw _NoCachedSession(
            'FakeConvexAuthClient has no cached session '
            '(onLoginFromCache is not set).',
          ),
    );
  }

  Future<TUser> _signIn(FutureOr<TUser> Function() attempt) async {
    _assertNotDisposed();
    final previous = _currentAuthState;
    emit(AuthLoading<TUser>());
    try {
      final user = await attempt();
      emit(AuthAuthenticated<TUser>(user));
      return user;
    } catch (error) {
      emit(
        previous is AuthAuthenticated<TUser> && error is! AuthSessionEndedError
            ? previous
            : AuthUnauthenticated<TUser>(),
      );
      rethrow;
    }
  }

  @override
  Future<void> logout() async {
    _assertNotDisposed();
    logoutCalls++;
    try {
      await onLogout?.call();
    } finally {
      emit(AuthUnauthenticated<TUser>());
    }
  }

  @override
  Future<void> clearAuth() async {
    _assertNotDisposed();
    clearAuthCalls++;
    emit(AuthUnauthenticated<TUser>());
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_authStateController.close());
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw const ConvexException('ConvexClientWithAuth has been disposed');
    }
  }

  ConvexFunctionCaller get _functions => client.convexFunctionCaller;

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) => _functions.query(name, args);

  @override
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) => _functions.queryOnce<T>(name, args);

  @override
  ConvexSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) => _functions.subscribe(name, args);

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
    OptimisticUpdate? optimisticUpdate,
  ]) => _functions.mutate(name, args, optimisticUpdate);

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) => _functions.action(name, args);

  @override
  ConvexPaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) => _functions.paginatedQuery(name, args, pageSize: pageSize);
}

final class _NoCachedSession extends StateError
    implements AuthSessionEndedError {
  _NoCachedSession(super.message);
}
