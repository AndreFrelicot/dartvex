/// A Convex Auth session: the token bundle minted by `@convex-dev/auth` when a
/// sign-in completes or a session is refreshed.
///
/// Persist it with [toJson] after every change (see
/// `ConvexAuthSessionProvider.onSessionChanged`): the refresh token rotates on
/// every refresh, and an old one stops working.
class ConvexAuthSession {
  /// Creates a session from its tokens.
  const ConvexAuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.refreshTokenExpiresAt,
    required this.userId,
  });

  /// Parses a token bundle as returned by Convex Auth
  /// (`{accessToken, refreshToken, refreshTokenExpiresAt, userId}`), or as
  /// written by [toJson].
  ///
  /// Throws a [FormatException] when a field is missing or has the wrong type.
  factory ConvexAuthSession.fromJson(Object? json) {
    if (json is! Map) {
      throw FormatException('Convex Auth token bundle must be an object.');
    }
    final accessToken = json['accessToken'];
    final refreshToken = json['refreshToken'];
    final expiresAt = json['refreshTokenExpiresAt'];
    final userId = json['userId'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const FormatException(
        'Convex Auth token bundle has no accessToken.',
      );
    }
    if (refreshToken is! String || refreshToken.isEmpty) {
      throw const FormatException(
        'Convex Auth token bundle has no refreshToken.',
      );
    }
    if (expiresAt is! num || !expiresAt.isFinite) {
      throw const FormatException(
        'Convex Auth token bundle has no numeric refreshTokenExpiresAt.',
      );
    }
    if (userId is! String || userId.isEmpty) {
      throw const FormatException('Convex Auth token bundle has no userId.');
    }
    return ConvexAuthSession(
      accessToken: accessToken,
      refreshToken: refreshToken,
      refreshTokenExpiresAt: DateTime.fromMillisecondsSinceEpoch(
        expiresAt.toInt(),
        isUtc: true,
      ),
      userId: userId,
    );
  }

  /// The Convex JWT sent to the deployment. Short-lived (one minute by
  /// default); the client refreshes it before it expires.
  final String accessToken;

  /// The token exchanged for a new session by the `refreshSession` mutation.
  /// Single use: each refresh returns a new one.
  final String refreshToken;

  /// When [refreshToken] stops being accepted, as reported by the server.
  ///
  /// Informational: the server decides whether a session is still alive, so
  /// the provider does not compare it with the device clock.
  final DateTime refreshTokenExpiresAt;

  /// The app's user id (an `Id<"users">` of the app's users table).
  final String userId;

  /// The token bundle as JSON, in the shape [ConvexAuthSession.fromJson]
  /// reads (and Convex Auth returns).
  ///
  /// Contains the refresh token: store it in secure storage.
  Map<String, Object> toJson() => <String, Object>{
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'refreshTokenExpiresAt': refreshTokenExpiresAt.millisecondsSinceEpoch,
        'userId': userId,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConvexAuthSession &&
          accessToken == other.accessToken &&
          refreshToken == other.refreshToken &&
          refreshTokenExpiresAt == other.refreshTokenExpiresAt &&
          userId == other.userId;

  @override
  int get hashCode =>
      Object.hash(accessToken, refreshToken, refreshTokenExpiresAt, userId);

  /// Omits the tokens, so a session can be logged safely.
  @override
  String toString() => 'ConvexAuthSession(userId: $userId, '
      'refreshTokenExpiresAt: ${refreshTokenExpiresAt.toIso8601String()})';
}
