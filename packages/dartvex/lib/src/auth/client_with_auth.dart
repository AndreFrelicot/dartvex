import 'dart:async';

import '../client.dart';
import '../exceptions.dart';
import '../logging.dart';
import 'auth_client.dart';
import 'auth_manager.dart';
import 'auth_provider.dart';
import 'auth_state.dart';
import 'auth_token_bridge.dart';

class ConvexClientWithAuth<TUser>
    implements ConvexAuthClient<TUser>, ConvexFunctionCaller, DartvexLogSource {
  ConvexClientWithAuth({
    required ConvexClient client,
    required AuthProvider<TUser> authProvider,
  })  : _client = client,
        _authProvider = authProvider;

  final ConvexClient _client;
  final AuthProvider<TUser> _authProvider;
  final StreamController<AuthState<TUser>> _authStateController =
      StreamController<AuthState<TUser>>.broadcast(sync: true);

  AuthState<TUser> _currentAuthState = AuthUnauthenticated<TUser>();
  AuthTokenBridge<TUser>? _authBridge;
  AuthHandle? _authHandle;
  bool _disposed = false;

  @override
  Stream<AuthState<TUser>> get authState => _authStateController.stream;

  @override
  AuthState<TUser> get currentAuthState => _currentAuthState;

  @override
  Stream<ConnectionState> get connectionState => _client.connectionState;

  @override
  ConnectionState get currentConnectionState => _client.currentConnectionState;

  @override
  DartvexLogLevel get logLevel => _client.logLevel;

  @override
  DartvexLogger? get logger => _client.logger;

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.action(name, args);
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _authBridge = null;
    final handle = _authHandle;
    _authHandle = null;
    if (handle != null) {
      unawaited(handle.cancel());
    }
    _client.dispose();
    unawaited(_authStateController.close());
  }

  @override
  Future<TUser> login() {
    return _loginWithStrategy(
      (onIdToken) => _authProvider.login(onIdToken: onIdToken),
    );
  }

  @override
  Future<TUser> loginFromCache() {
    return _loginWithStrategy(
      (onIdToken) => _authProvider.loginFromCache(onIdToken: onIdToken),
    );
  }

  @override
  Future<void> logout() async {
    _assertNotDisposed();
    await _authProvider.logout();
    await _resetBaseAuth();
    _emitAuthState(AuthUnauthenticated<TUser>());
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.mutate(name, args);
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.query(name, args);
  }

  @override
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.queryOnce<T>(name, args);
  }

  @override
  ConvexSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.subscribe(name, args);
  }

  Future<TUser> _loginWithStrategy(
    Future<TUser> Function(void Function(String? token) onIdToken) strategy,
  ) async {
    _assertNotDisposed();
    _emitAuthState(AuthLoading<TUser>());

    try {
      final authResult = await strategy(_onIdToken);
      final token = _authProvider.extractIdToken(authResult);
      final bridge = AuthTokenBridge<TUser>(
        authProvider: _authProvider,
        onIdToken: _onIdToken,
        initialToken: token,
      );

      final previousHandle = _authHandle;
      _authHandle = null;
      if (previousHandle != null) {
        await previousHandle.cancel();
      }

      _authBridge = bridge;
      _authHandle = await _client.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) =>
            bridge.fetchToken(forceRefresh: forceRefresh),
        onAuthChange: _handleBaseAuthStateChanged,
      );
      _emitAuthState(AuthAuthenticated<TUser>(authResult));
      return authResult;
    } catch (_) {
      await _resetBaseAuth();
      _emitAuthState(AuthUnauthenticated<TUser>());
      rethrow;
    }
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw const ConvexException('ConvexClientWithAuth has been disposed');
    }
  }

  void _emitAuthState(AuthState<TUser> state) {
    _currentAuthState = state;
    if (!_authStateController.isClosed) {
      _authStateController.add(state);
    }
  }

  void _handleBaseAuthStateChanged(bool isAuthenticated) {
    if (!isAuthenticated) {
      _authBridge = null;
      _emitAuthState(AuthUnauthenticated<TUser>());
    }
  }

  void _onIdToken(String? token) {
    unawaited(_handleTokenUpdate(token));
  }

  Future<void> _handleTokenUpdate(String? token) async {
    if (token == null) {
      await _resetBaseAuth();
      _emitAuthState(AuthUnauthenticated<TUser>());
      return;
    }

    final bridge = _authBridge;
    if (bridge == null) {
      return;
    }
    await bridge.updateToken(token);
    await _client.updateAuthToken(token);
  }

  Future<void> _resetBaseAuth() async {
    _authBridge = null;
    final handle = _authHandle;
    _authHandle = null;
    if (handle != null) {
      await handle.cancel();
    }
    await _client.clearAuth();
  }
}
