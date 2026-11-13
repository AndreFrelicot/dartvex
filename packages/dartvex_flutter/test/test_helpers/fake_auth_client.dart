import 'package:dartvex_flutter/dartvex_flutter.dart';

/// The public [FakeConvexAuthClient] behind the constructor these tests were
/// written against.
class FakeAuthClient<TUser> extends FakeConvexAuthClient<TUser> {
  FakeAuthClient({
    required AuthState<TUser> initialAuthState,
    TUser? loginResult,
    TUser? cachedLoginResult,
  }) : super(
         initialAuthState: initialAuthState,
         onLogin: loginResult == null ? null : () => loginResult,
         onLoginFromCache: cachedLoginResult == null
             ? null
             : () => cachedLoginResult,
       );

  void emitAuthState(AuthState<TUser> state) => emit(state);

  bool get disposed => isDisposed;
}
