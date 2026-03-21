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

  /// Releases resources held by the auth client.
  void dispose();
}
