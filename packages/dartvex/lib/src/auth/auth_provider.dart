/// Adapter interface used by [ConvexClient.withAuth] for external auth systems.
///
/// ## Contract used by `ConvexClientWithAuth`
///
/// * [login] and [loginFromCache] start a session and return its result;
///   [extractIdToken] reads the Convex JWT from that result.
/// * [loginFromCache] doubles as the **token refresh hook**: the wrapper calls
///   it whenever it needs a newly issued token — for the scheduled refresh
///   shortly before the current token expires, right after the server
///   confirms the login-time token, and when the server rejects a token. It
///   must therefore bypass any token cache and return a freshly issued JWT for
///   the current session; returning the same cached JWT again prevents the
///   refresh, and once that JWT expires the user is signed out.
/// * To report that the session is gone (revoked, signed out elsewhere),
///   throw from [loginFromCache]. A throw during a background refresh is
///   treated as transient (logged; the session is kept until the server
///   rejects the token); a throw while recovering from a server rejection is
///   retried briefly and then signs the user out.
/// * The `onIdToken` callback passed to [login] / [loginFromCache] may be
///   invoked later to push a rotated token (or `null` to sign out) for the
///   session that call started.
abstract class AuthProvider<TUser> {
  /// Creates an auth provider.
  AuthProvider();

  /// Performs an interactive login flow and reports token updates through [onIdToken].
  Future<TUser> login({required void Function(String? token) onIdToken});

  /// Restores a cached session and reports token updates through [onIdToken].
  ///
  /// Also used as the token refresh hook: it must return a freshly issued
  /// Convex token for the current session (not a cached one), and throw when
  /// there is no session. See the class documentation.
  Future<TUser> loginFromCache({
    required void Function(String? token) onIdToken,
  });

  /// Logs out the current user.
  Future<void> logout();

  /// Extracts the Convex ID token from an auth result.
  String extractIdToken(TUser authResult);
}
