/// Adapter interface used by [ConvexClient.withAuth] for external auth systems.
abstract class AuthProvider<TUser> {
  /// Creates an auth provider.
  AuthProvider();

  /// Performs an interactive login flow and reports token updates through [onIdToken].
  Future<TUser> login({required void Function(String? token) onIdToken});

  /// Restores a cached session and reports token updates through [onIdToken].
  Future<TUser> loginFromCache({
    required void Function(String? token) onIdToken,
  });

  /// Logs out the current user.
  Future<void> logout();

  /// Extracts the Convex ID token from an auth result.
  String extractIdToken(TUser authResult);
}
