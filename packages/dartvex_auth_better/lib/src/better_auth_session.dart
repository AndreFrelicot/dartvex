/// Session information returned by Better Auth.
///
/// Contains the Convex JWT for WebSocket authentication, the Better Auth
/// session token for refresh/validation, and basic user information.
class BetterAuthSession {
  /// Creates a [BetterAuthSession] with the given credentials and user info.
  const BetterAuthSession({
    required this.token,
    required this.sessionToken,
    required this.userId,
    required this.email,
    this.name,
  });

  /// JWT for Convex WebSocket authentication.
  final String token;

  /// Better Auth session token (used for session refresh/validation).
  final String sessionToken;

  /// Better Auth user ID.
  final String userId;

  /// User email address.
  final String email;

  /// User display name.
  final String? name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BetterAuthSession &&
          token == other.token &&
          sessionToken == other.sessionToken &&
          userId == other.userId &&
          email == other.email &&
          name == other.name;

  @override
  int get hashCode => Object.hash(token, sessionToken, userId, email, name);
}
