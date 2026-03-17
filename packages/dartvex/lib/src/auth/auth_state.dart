sealed class AuthState<TUser> {
  const AuthState();
}

final class AuthUnauthenticated<TUser> extends AuthState<TUser> {
  const AuthUnauthenticated();
}

final class AuthLoading<TUser> extends AuthState<TUser> {
  const AuthLoading();
}

final class AuthAuthenticated<TUser> extends AuthState<TUser> {
  const AuthAuthenticated(this.userInfo);

  final TUser userInfo;
}
