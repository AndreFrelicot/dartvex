import 'package:dartvex/dartvex.dart';

import 'better_auth_client.dart';
import 'better_auth_exception.dart';
import 'better_auth_session.dart';

/// Auth provider that uses Better Auth (self-hosted in Convex)
/// via HTTP endpoints.
///
/// Implements [AuthProvider] so it can be used with
/// `ConvexClient.withAuth<BetterAuthSession>()`. Drive sign-in, restore and
/// sign-out through the wrapper (`authedClient.login()`,
/// `authedClient.loginFromCache()`, `authedClient.logout()`), not through the
/// raw [BetterAuthClient] session methods, so the Convex client and this
/// provider stay in sync.
///
/// ## Errors
///
/// - [loginFromCache] throws a [StateError] when there is no cached session
///   token (`'No cached Better Auth session.'`) or when Better Auth no longer
///   recognizes the session (`'Better Auth session expired.'`; the dead token
///   is then cleared). Treat both as "sign in again". Both errors implement
///   [AuthSessionEndedError], so a replacement `loginFromCache()` that fails
///   with them signs the Convex client out instead of keeping the previous
///   (same, now dead) session as authenticated.
/// - A [BetterAuthSessionExpiredException] means the Convex token endpoint
///   rejected the session; also "sign in again".
/// - Any other [BetterAuthException] with `retryable: true` (5xx, 429,
///   network errors, timeouts) is transient: keep the persisted token and
///   retry later.
class ConvexBetterAuthProvider implements AuthProvider<BetterAuthSession> {
  /// Creates a [ConvexBetterAuthProvider] using the given [client].
  ///
  /// Pass [initialSessionToken] to seed a Better Auth session token persisted
  /// from a previous run (the `sessionToken` of an earlier
  /// [BetterAuthSession]), so [loginFromCache] can restore the session across
  /// process restarts without re-entering credentials.
  ConvexBetterAuthProvider({required this.client, String? initialSessionToken})
      : _sessionToken = initialSessionToken;

  /// The [BetterAuthClient] used for HTTP communication with Better Auth.
  final BetterAuthClient client;

  BetterAuthSession? _cachedSession;
  String? _sessionToken;
  BetterAuthSession? _pendingLoginSession;
  String? _pendingLoginEmail;
  String? _pendingLoginPassword;

  /// Incremented whenever the provider's session is replaced or cleared
  /// (login, signUp, adoptSession, logout, definitive expiry). Async
  /// operations capture it before awaiting and drop their result when it
  /// changed, so a stale response can never resurrect an older session.
  int _sessionEpoch = 0;

  /// Set credentials before calling [login].
  ///
  /// Cleared by [logout].
  String? email;

  /// Password paired with [email] for future [login] calls.
  ///
  /// Cleared by [logout].
  String? password;

  @override

  /// Extracts the Convex JWT from a Better Auth session.
  String extractIdToken(BetterAuthSession authResult) => authResult.token;

  @override

  /// Signs in with the configured [email] and [password].
  ///
  /// Reuses the session created by [signUp] when the credentials still match,
  /// instead of signing in a second time.
  ///
  /// Throws a [BetterAuthException] when a newer [login], [signUp],
  /// [adoptSession] or [logout] started while the sign-in request was in
  /// flight; the superseded server session is signed out in the background.
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
    final pendingSession = _takePendingLoginSession(
      email: e,
      password: p,
    );
    if (pendingSession != null) {
      _commitSession(pendingSession);
      onIdToken(pendingSession.token);
      return pendingSession;
    }
    final epoch = ++_sessionEpoch;
    final session = await client.signIn(email: e, password: p);
    _commitIfCurrent(epoch, session, operation: 'login()');
    onIdToken(session.token);
    return session;
  }

  @override

  /// Restores a Better Auth session from the cached session token.
  ///
  /// Throws a [StateError] when there is no cached token or when Better Auth
  /// reports the session as expired (the dead token is cleared). Throws a
  /// retryable [BetterAuthException] when the session was replaced or
  /// cleared while the refresh was in flight; the stale result is discarded.
  Future<BetterAuthSession> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    final sessionToken = _sessionToken;
    if (sessionToken == null) {
      throw _SessionEndedStateError('No cached Better Auth session.');
    }
    final epoch = _sessionEpoch;
    final refreshed = await client.getSession(sessionToken: sessionToken);
    if (epoch != _sessionEpoch || _sessionToken != sessionToken) {
      throw const BetterAuthException(
        'Better Auth session changed while it was being restored; the stale '
        'result was discarded.',
        retryable: true,
      );
    }
    if (refreshed == null) {
      _clearSession();
      throw _SessionEndedStateError('Better Auth session expired.');
    }
    _clearPendingLoginSession();
    _cachedSession = refreshed;
    _sessionToken = refreshed.sessionToken;
    onIdToken(refreshed.token);
    return refreshed;
  }

  @override

  /// Signs out the current Better Auth session and clears cached state.
  ///
  /// Local state (session, pending sign-up session, [email] and [password])
  /// is cleared before the sign-out request is sent, so it is cleared even
  /// when that request fails, and a [login] started while the request is in
  /// flight is not wiped when it completes.
  Future<void> logout() async {
    final sessionToken = _sessionToken;
    _clearSession();
    email = null;
    password = null;
    if (sessionToken != null) {
      await client.signOut(sessionToken: sessionToken);
    }
  }

  /// Sign up a new user. Sets credentials for future [login] calls.
  ///
  /// This does not authenticate the Convex client. Call
  /// `authedClient.login()` afterwards; it reuses the session created here
  /// instead of signing in again. [onIdToken] is optional and only receives
  /// the new session's Convex JWT.
  ///
  /// Throws [BetterAuthEmailVerificationRequiredException] when the server
  /// requires email verification before the first sign-in.
  Future<BetterAuthSession> signUp({
    required String name,
    required String email,
    required String password,
    void Function(String? token)? onIdToken,
  }) async {
    final epoch = ++_sessionEpoch;
    final session = await client.signUp(
      name: name,
      email: email,
      password: password,
    );
    _commitIfCurrent(epoch, session, operation: 'signUp()');
    _pendingLoginSession = session;
    _pendingLoginEmail = email;
    _pendingLoginPassword = password;
    this.email = email;
    this.password = password;
    onIdToken?.call(session.token);
    return session;
  }

  /// Makes [session] the provider's current session, for sessions obtained
  /// outside [login] (for example from [BetterAuthClient.verifyMagicLink]).
  ///
  /// Then call `authedClient.loginFromCache()` to authenticate the Convex
  /// client with it. Persist `session.sessionToken` as usual.
  void adoptSession(BetterAuthSession session) {
    _commitSession(session);
  }

  /// The currently cached session, if any.
  BetterAuthSession? get cachedSession => _cachedSession;

  void _commitSession(BetterAuthSession session) {
    _sessionEpoch++;
    _clearPendingLoginSession();
    _cachedSession = session;
    _sessionToken = session.sessionToken;
  }

  void _commitIfCurrent(
    int epoch,
    BetterAuthSession session, {
    required String operation,
  }) {
    if (epoch != _sessionEpoch) {
      // A newer login/signUp/logout owns the provider now. Do not leave the
      // superseded server session alive.
      client
          .signOut(sessionToken: session.sessionToken)
          .then<void>((_) {}, onError: (Object _) {});
      throw BetterAuthException(
        'Better Auth $operation was superseded by a newer login, signUp or '
        'logout; its session was discarded.',
      );
    }
    _commitSession(session);
  }

  void _clearSession() {
    _sessionEpoch++;
    _cachedSession = null;
    _sessionToken = null;
    _clearPendingLoginSession();
  }

  BetterAuthSession? _takePendingLoginSession({
    required String email,
    required String password,
  }) {
    final session = _pendingLoginSession;
    if (session == null) {
      return null;
    }
    if (_pendingLoginEmail == email && _pendingLoginPassword == password) {
      _clearPendingLoginSession();
      return session;
    }
    _clearPendingLoginSession();
    return null;
  }

  void _clearPendingLoginSession() {
    _pendingLoginSession = null;
    _pendingLoginEmail = null;
    _pendingLoginPassword = null;
  }
}

/// The [StateError] thrown when the provider has no usable session; marked
/// as definitive for `ConvexClientWithAuth`.
final class _SessionEndedStateError extends StateError
    implements AuthSessionEndedError {
  _SessionEndedStateError(super.message);
}
