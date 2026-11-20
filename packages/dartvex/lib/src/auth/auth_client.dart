import '../client.dart';
import 'auth_state.dart';

/// Convex client interface extended with authentication lifecycle APIs.
abstract interface class ConvexAuthClient<TUser>
    implements ConvexFunctionCaller {
  /// Stream of authentication state changes.
  Stream<AuthState<TUser>> get authState;

  /// Latest authentication state.
  AuthState<TUser> get currentAuthState;

  /// Stream of connection state changes from the underlying client.
  Stream<ConnectionState> get connectionState;

  /// Current connection state of the underlying client.
  ConnectionState get currentConnectionState;

  /// Performs an interactive login flow.
  Future<TUser> login();

  /// Restores authentication from cached credentials.
  Future<TUser> loginFromCache();

  /// Logs out the current user and clears auth state.
  Future<void> logout();

  /// Continues signed out without calling the auth provider.
  ///
  /// Clears the client's auth and emits [AuthUnauthenticated], like [logout],
  /// but leaves the provider's session alone. Call it on startup when there is
  /// no session to restore: a client created with `expectAuth: true` holds
  /// every request until auth is decided, and this decides it. (A failed
  /// [loginFromCache] already does this.)
  Future<void> clearAuth();

  /// Releases resources held by the auth client.
  void dispose();
}
