/// Base class for authentication state exposed by [ConvexAuthClient].
sealed class AuthState<TUser> {
  /// Creates an auth state.
  const AuthState();
}

/// Authentication state for a signed-out user.
final class AuthUnauthenticated<TUser> extends AuthState<TUser> {
  /// Creates an unauthenticated state.
  const AuthUnauthenticated();
}

/// Authentication state used while an interactive login or cache restore is in
/// progress.
///
/// Background token refreshes keep the current auth state and are exposed
/// separately through `ConvexClient.authRefreshing`.
final class AuthLoading<TUser> extends AuthState<TUser> {
  /// Creates a loading auth state.
  const AuthLoading();
}

/// Authentication state for a signed-in user.
final class AuthAuthenticated<TUser> extends AuthState<TUser> {
  /// Creates an authenticated state with [userInfo].
  const AuthAuthenticated(this.userInfo);

  /// Auth-provider-specific user information.
  ///
  /// A snapshot taken when the login completed: background token refreshes do
  /// not emit a new [AuthAuthenticated], so any Convex token inside it is the
  /// login-time token and expires. Read `ConvexClientWithAuth.currentAuthToken`
  /// (or `ConvexClient.currentAuthToken`) for the token currently in use.
  final TUser userInfo;
}
