import 'package:dartvex/dartvex.dart';

import 'better_auth_client.dart';
import 'better_auth_session.dart';

/// Auth provider that uses Better Auth (self-hosted in Convex)
/// via HTTP endpoints.
///
/// Implements [AuthProvider] so it can be used with
/// `ConvexClient.withAuth<BetterAuthSession>()`.
class ConvexBetterAuthProvider implements AuthProvider<BetterAuthSession> {
  /// Creates a [ConvexBetterAuthProvider] using the given [client].
  ConvexBetterAuthProvider({required this.client});

  /// The [BetterAuthClient] used for HTTP communication with Better Auth.
  final BetterAuthClient client;

  BetterAuthSession? _cachedSession;
  String? _sessionToken;

  /// Set credentials before calling [login].
  String? email;
  String? password;

  @override
  String extractIdToken(BetterAuthSession authResult) => authResult.token;

  @override
  Future<BetterAuthSession> login({
    required void Function(String? token) onIdToken,
  }) async {
    final e = email;
    final p = password;
    if (e == null || p == null) {
      throw StateError(
        'Set email and password on ConvexBetterAuthProvider before login().',
      );
    }
    final session = await client.signIn(email: e, password: p);
    _cachedSession = session;
    _sessionToken = session.sessionToken;
    onIdToken(session.token);
    return session;
  }

  @override
  Future<BetterAuthSession> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    final sessionToken = _sessionToken;
    if (sessionToken == null) {
      throw StateError('No cached Better Auth session.');
    }
    final refreshed = await client.getSession(sessionToken: sessionToken);
    if (refreshed == null) {
      throw StateError('Better Auth session expired.');
    }
    _cachedSession = refreshed;
    _sessionToken = refreshed.sessionToken;
    onIdToken(refreshed.token);
    return refreshed;
  }

  @override
  Future<void> logout() async {
    final sessionToken = _sessionToken;
    if (sessionToken != null) {
      await client.signOut(sessionToken: sessionToken);
    }
    _cachedSession = null;
    _sessionToken = null;
  }

  /// Sign up a new user. Sets credentials for future [login] calls.
  Future<BetterAuthSession> signUp({
    required String name,
    required String email,
    required String password,
    required void Function(String? token) onIdToken,
  }) async {
    final session = await client.signUp(
      name: name,
      email: email,
      password: password,
    );
    _cachedSession = session;
    _sessionToken = session.sessionToken;
    this.email = email;
    this.password = password;
    onIdToken(session.token);
    return session;
  }

  /// The currently cached session, if any.
  BetterAuthSession? get cachedSession => _cachedSession;
}
