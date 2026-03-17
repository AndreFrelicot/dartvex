import '../client.dart';
import 'auth_state.dart';

abstract interface class ConvexAuthClient<TUser>
    implements ConvexFunctionCaller {
  Stream<AuthState<TUser>> get authState;
  AuthState<TUser> get currentAuthState;

  Stream<ConnectionState> get connectionState;
  ConnectionState get currentConnectionState;

  Future<TUser> login();
  Future<TUser> loginFromCache();
  Future<void> logout();

  void dispose();
}
