import 'dart:async';
import 'dart:collection';

import '../client.dart';
import '../exceptions.dart';
import '../logging.dart';
import '../sync/optimistic_updates.dart';
import '../sync/paginated_query.dart';
import 'auth_client.dart';
import 'auth_manager.dart';
import 'auth_provider.dart';
import 'auth_state.dart';
import 'auth_token_bridge.dart';

/// Ties the callbacks of one login flow to that flow.
///
/// Provider token pushes and base-client auth changes are honored only while
/// [generation] is the wrapper's current auth flow generation, so a stale flow
/// cannot tear down a newer one — except that the installed live session's
/// token pushes are still recorded while a replacement login is pending. The
/// generation is mutable so a flow that is kept after a failed replacement
/// login can be made current again.
final class _AuthFlowBinding {
  _AuthFlowBinding(this.generation);

  int generation;

  /// Whether the base client reported this flow's auth as failed, or the
  /// provider ended it (a `null` token push) while a replacement login was
  /// pending. Such a flow is never restored after that login fails.
  bool baseFlowFailed = false;
}

/// Wraps a [ConvexClient] with auth-provider-driven login and token refresh.
class ConvexClientWithAuth<TUser>
    implements ConvexAuthClient<TUser>, ConvexFunctionCaller, DartvexLogSource {
  /// Creates an authenticated client wrapper.
  ConvexClientWithAuth({
    required ConvexClient client,
    required AuthProvider<TUser> authProvider,
    this.disposeClient = false,
  })  : _client = client,
        _authProvider = authProvider;

  final ConvexClient _client;
  final AuthProvider<TUser> _authProvider;

  /// Whether disposing this wrapper should also dispose the wrapped client.
  final bool disposeClient;
  final StreamController<AuthState<TUser>> _authStateController =
      StreamController<AuthState<TUser>>.broadcast(sync: true);

  AuthState<TUser> _currentAuthState = AuthUnauthenticated<TUser>();
  AuthTokenBridge<TUser>? _authBridge;
  AuthHandle? _authHandle;

  /// Binding of the flow whose refresh handle is [_authHandle].
  _AuthFlowBinding? _installedBinding;
  AuthAuthenticated<TUser>? _pendingAuthenticatedState;
  int _authFlowGeneration = 0;
  bool _disposed = false;

  /// Re-entrancy guard for the synchronous [authState] controller: states
  /// emitted by a listener while a state is being delivered are queued and
  /// delivered in order afterwards (a re-entrant `add` on a sync broadcast
  /// controller throws).
  bool _dispatchingAuthState = false;
  final Queue<AuthState<TUser>> _queuedAuthStates = Queue<AuthState<TUser>>();

  @override

  /// Stream of authentication state changes.
  Stream<AuthState<TUser>> get authState => _authStateController.stream;

  @override

  /// Latest authentication state.
  AuthState<TUser> get currentAuthState => _currentAuthState;

  /// The Convex auth token the wrapped client currently sends, if any.
  ///
  /// Unlike the token inside [AuthAuthenticated.userInfo], which is captured
  /// at login, this reflects every background refresh — use it for Convex
  /// HTTP actions (`Authorization: Bearer <token>`).
  String? get currentAuthToken => _client.currentAuthToken;

  @override

  /// Stream of connection state changes from the wrapped client.
  Stream<ConnectionState> get connectionState => _client.connectionState;

  @override

  /// Current connection state of the wrapped client.
  ConnectionState get currentConnectionState => _client.currentConnectionState;

  @override

  /// Minimum log level inherited from the wrapped client.
  DartvexLogLevel get logLevel => _client.logLevel;

  @override

  /// Structured log sink inherited from the wrapped client.
  DartvexLogger? get logger => _client.logger;

  @override

  /// Executes an action through the wrapped client.
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _client.action(name, args);
  }

  @override

  /// Subscribes to a paginated query through the wrapped client.
  ConvexPaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    return _client.paginatedQuery(name, args, pageSize: pageSize);
  }

  @override

  /// Disposes auth state, refresh handling, and the wrapped client.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _authFlowGeneration += 1;
    _authBridge = null;
    _installedBinding = null;
    final handle = _authHandle;
    _authHandle = null;
    if (handle != null) {
      unawaited(handle.cancel());
    }
    if (disposeClient) {
      _client.dispose();
    }
    scheduleMicrotask(() {
      unawaited(_authStateController.close());
    });
  }

  @override

  /// Starts an interactive login flow with the configured auth provider.
  ///
  /// If the user is already signed in and the provider's login fails (or is
  /// cancelled), the existing session is kept and [currentAuthState] returns
  /// to its previous [AuthAuthenticated] value; the error is still rethrown.
  Future<TUser> login() {
    return _loginWithStrategy(
      (onIdToken) => _authProvider.login(onIdToken: onIdToken),
    );
  }

  @override

  /// Restores authentication from cached provider state.
  ///
  /// If the user is already signed in and the restore fails (for example on a
  /// network blip), the existing session is kept and [currentAuthState]
  /// returns to its previous [AuthAuthenticated] value; the error is still
  /// rethrown.
  Future<TUser> loginFromCache() {
    return _loginWithStrategy(
      (onIdToken) => _authProvider.loginFromCache(onIdToken: onIdToken),
    );
  }

  @override

  /// Logs out and clears auth state.
  ///
  /// The current flow is superseded as soon as this is called, before the
  /// provider's sign-out completes, so a [login] or [loginFromCache] started
  /// while the sign-out is in flight is not torn down by it. Local auth state
  /// is cleared even if the provider's sign-out throws (the error is
  /// rethrown).
  Future<void> logout() async {
    _assertNotDisposed();
    final generation = ++_authFlowGeneration;
    _authBridge = null;
    _pendingAuthenticatedState = null;
    _installedBinding = null;
    final handle = _authHandle;
    _authHandle = null;
    try {
      // Stop background refreshes (which call the provider) before signing
      // out; the token stays applied until the clear below.
      if (handle != null) {
        await handle.cancel();
      }
      await _authProvider.logout();
    } finally {
      if (_isCurrentAuthFlow(generation)) {
        await _client.clearAuth();
        if (_isCurrentAuthFlow(generation)) {
          _emitAuthState(AuthUnauthenticated<TUser>());
        }
      }
    }
  }

  @override

  /// Executes a mutation through the wrapped client, with an optional
  /// [optimisticUpdate]. See [ConvexClient.mutate].
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
    OptimisticUpdate? optimisticUpdate,
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
    final binding = _AuthFlowBinding(++_authFlowGeneration);
    final previousState = _currentAuthState;
    final previousBinding = _installedBinding;
    final previousHandle = _authHandle;
    void onIdToken(String? token) {
      _onIdTokenFor(binding, token);
    }

    var strategyCompleted = false;
    try {
      _emitAuthState(AuthLoading<TUser>());
      final authResult = await strategy(onIdToken);
      strategyCompleted = true;
      if (!_isCurrentAuthFlow(binding.generation)) {
        return authResult;
      }
      final token = _authProvider.extractIdToken(authResult);
      final bridge = AuthTokenBridge<TUser>(
        authProvider: _authProvider,
        initialToken: token,
      );
      final authenticatedState = AuthAuthenticated<TUser>(authResult);

      final handleToReplace = _authHandle;
      _authHandle = null;
      _installedBinding = null;
      if (handleToReplace != null) {
        await handleToReplace.cancel();
      }
      if (!_isCurrentAuthFlow(binding.generation)) {
        return authResult;
      }

      _authBridge = bridge;
      _pendingAuthenticatedState = authenticatedState;
      final authHandle = await _client.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) =>
            bridge.fetchToken(forceRefresh: forceRefresh),
        // Bound to this flow: a superseded flow's auth failure must not
        // cancel a newer login (or log out the session that replaced it).
        onAuthChange: (isAuthenticated) =>
            _handleBaseAuthStateChanged(binding, isAuthenticated),
      );
      if (!_isCurrentAuthFlow(binding.generation) ||
          !identical(_authBridge, bridge)) {
        await authHandle.cancel();
        return authResult;
      }
      _authHandle = authHandle;
      _installedBinding = binding;
      return authResult;
    } catch (_) {
      if (_isCurrentAuthFlow(binding.generation)) {
        if (!strategyCompleted &&
            _canKeepPreviousFlow(
              previousState,
              previousBinding,
              previousHandle,
            )) {
          // The provider failed before anything was replaced: keep the
          // healthy existing session instead of logging the user out over a
          // failed (or cancelled) re-login or cache restore.
          previousBinding!.generation = ++_authFlowGeneration;
          _emitAuthState(previousState);
        } else {
          final resetGeneration = ++_authFlowGeneration;
          final didReset = await _resetBaseAuth(generation: resetGeneration);
          if (didReset) {
            _emitAuthState(AuthUnauthenticated<TUser>());
          }
        }
      }
      rethrow;
    }
  }

  bool _canKeepPreviousFlow(
    AuthState<TUser> previousState,
    _AuthFlowBinding? previousBinding,
    AuthHandle? previousHandle,
  ) {
    return previousState is AuthAuthenticated<TUser> &&
        previousBinding != null &&
        previousHandle != null &&
        !previousBinding.baseFlowFailed &&
        identical(_installedBinding, previousBinding) &&
        identical(_authHandle, previousHandle);
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw const ConvexException('ConvexClientWithAuth has been disposed');
    }
  }

  void _emitAuthState(AuthState<TUser> state) {
    _currentAuthState = state;
    if (_authStateController.isClosed) {
      return;
    }
    if (_dispatchingAuthState) {
      _queuedAuthStates.add(state);
      return;
    }
    _dispatchingAuthState = true;
    try {
      _authStateController.add(state);
      while (_queuedAuthStates.isNotEmpty) {
        final next = _queuedAuthStates.removeFirst();
        if (_authStateController.isClosed) {
          _queuedAuthStates.clear();
          break;
        }
        _authStateController.add(next);
      }
    } finally {
      _dispatchingAuthState = false;
    }
  }

  void _handleBaseAuthStateChanged(
    _AuthFlowBinding binding,
    bool isAuthenticated,
  ) {
    if (!isAuthenticated) {
      binding.baseFlowFailed = true;
    }
    if (!_isCurrentAuthFlow(binding.generation)) {
      return;
    }
    if (!isAuthenticated) {
      _authFlowGeneration += 1;
      _authBridge = null;
      _pendingAuthenticatedState = null;
      _emitAuthState(AuthUnauthenticated<TUser>());
      return;
    }
    final pendingState = _pendingAuthenticatedState;
    if (pendingState != null) {
      _pendingAuthenticatedState = null;
      _emitAuthState(pendingState);
    }
  }

  bool _isCurrentAuthFlow(int generation) {
    return !_disposed && generation == _authFlowGeneration;
  }

  void _onIdTokenFor(_AuthFlowBinding binding, String? token) {
    unawaited(
      _handleTokenUpdate(binding, token).catchError(
        (Object error, StackTrace stackTrace) {
          // Unawaited: an error here (for example from a ConvexClient that was
          // closed while this wrapper lives on) would otherwise become an
          // uncaught zone error, which is isolate-fatal in pure Dart.
          emitDartvexLog(
            configuredLevel: logLevel,
            logger: logger,
            eventLevel: DartvexLogLevel.error,
            message: 'Failed to apply a token pushed by the auth provider',
            tag: 'auth',
            error: error,
            stackTrace: stackTrace,
          );
        },
      ),
    );
  }

  Future<void> _handleTokenUpdate(
    _AuthFlowBinding binding,
    String? token,
  ) async {
    if (!_acceptsTokenPushesFrom(binding)) {
      return;
    }
    if (!_isCurrentAuthFlow(binding.generation)) {
      // The live session, while a replacement login is pending.
      if (token == null) {
        // The provider ended the live session. The pending login stays in
        // charge (and replaces it on success), but a failed or cancelled
        // login must not restore this dead session as authenticated.
        binding.baseFlowFailed = true;
        return;
      }
      // A rotated token: the client keeps sending this session's token until
      // the replacement succeeds, and restores it if the replacement fails,
      // so apply it now like any other push for the live session.
    }
    if (token == null) {
      final resetGeneration = ++_authFlowGeneration;
      final didReset = await _resetBaseAuth(generation: resetGeneration);
      if (didReset) {
        _emitAuthState(AuthUnauthenticated<TUser>());
      }
      return;
    }

    final bridge = _authBridge;
    if (bridge == null) {
      return;
    }
    await bridge.updateToken(token);
    if (!_acceptsTokenPushesFrom(binding) || !identical(_authBridge, bridge)) {
      return;
    }
    await _client.updateAuthToken(token);
  }

  /// Whether provider token pushes of [binding]'s flow are honored: it is the
  /// current flow, or it is the installed live session while a replacement
  /// [login]/[loginFromCache] is still pending (that session is kept — with
  /// its latest token — if the replacement fails).
  bool _acceptsTokenPushesFrom(_AuthFlowBinding binding) {
    return _isCurrentAuthFlow(binding.generation) ||
        (!_disposed && identical(binding, _installedBinding));
  }

  Future<bool> _resetBaseAuth({int? generation}) async {
    _authBridge = null;
    _pendingAuthenticatedState = null;
    _installedBinding = null;
    final handle = _authHandle;
    _authHandle = null;
    if (handle != null) {
      await handle.cancel();
    }
    if (generation != null && !_isCurrentAuthFlow(generation)) {
      return false;
    }
    await _client.clearAuth();
    return true;
  }
}
