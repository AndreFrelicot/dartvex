import 'dart:async';

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
///   rejected the session (HTTP 401/403); also "sign in again".
/// - Any other [BetterAuthException] leaves the persisted token valid: with
///   `retryable: true` (5xx, 429, network and TLS errors, timeouts, a non-JSON
///   token response) retry later. This includes a [login] whose new session
///   the Convex token endpoint rejected, and a rejected [adoptSession]
///   session while another session is current: the session the app already
///   had is kept.
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

  /// Session handed over by [adoptSession], made current by the next
  /// successful explicit [loginFromCache].
  BetterAuthSession? _adoptedSession;

  /// Incremented whenever the provider's session is replaced, staged or
  /// cleared, and by every user-started call (login, signUp, adoptSession,
  /// an explicit loginFromCache, logout, definitive expiry). Async
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
  /// [adoptSession], explicit [loginFromCache] or [logout] started while the
  /// sign-in request was in flight; the superseded server session is signed
  /// out in the background. (A background token refresh does not supersede
  /// it.)
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
    _adoptedSession = null;
    final session = await client.signIn(email: e, password: p);
    _commitIfCurrent(epoch, session, operation: 'login()');
    onIdToken(session.token);
    return session;
  }

  @override

  /// Restores a Better Auth session from the cached session token, or
  /// finishes an [adoptSession].
  ///
  /// An explicit call (for example `authedClient.loginFromCache()`) is a new
  /// user intent: a [login], [signUp] or [loginFromCache] still in flight is
  /// superseded by it, so a sign-in that completes later can no longer replace
  /// the restored session. A background token refresh of the wrapper (a call
  /// made in a zone where `Zone.current[#dartvex.authTokenRefresh]` is
  /// `true`) only refreshes the current session and supersedes nothing.
  ///
  /// When a session staged by [adoptSession] is waiting, an explicit call
  /// restores that session and makes it current only once Better Auth
  /// confirmed it; a background refresh keeps refreshing the current session.
  ///
  /// Throws a [StateError] when there is no cached token or when Better Auth
  /// reports the session as expired (the dead token is cleared). Throws a
  /// [BetterAuthException] when Better Auth rejects a staged adopted session
  /// while another session is current (that session is kept). Throws a
  /// retryable [BetterAuthException] when the session was replaced or
  /// cleared while the refresh was in flight; the stale result is discarded.
  Future<BetterAuthSession> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    final isRefresh = Zone.current[#dartvex.authTokenRefresh] == true;
    final adopted = isRefresh ? null : _adoptedSession;
    final sessionToken = adopted?.sessionToken ?? _sessionToken;
    // An explicit restore supersedes older work even when there is no token.
    final epoch = isRefresh ? _sessionEpoch : ++_sessionEpoch;
    if (sessionToken == null) {
      throw _SessionEndedStateError('No cached Better Auth session.');
    }
    // Whether this restores a staged session while another one is current:
    // that session must survive the staged one being rejected.
    final current = _sessionToken;
    final replacesCurrent =
        adopted != null && current != null && current != sessionToken;
    BetterAuthSession? refreshed;
    BetterAuthSessionExpiredException? rejection;
    try {
      refreshed = await client.getSession(sessionToken: sessionToken);
    } on BetterAuthSessionExpiredException catch (error) {
      if (!replacesCurrent) {
        rethrow;
      }
      rejection = error;
    }
    // Every change of the current or staged session bumps the epoch, except
    // a background refresh, which only re-commits the same session token.
    if (epoch != _sessionEpoch ||
        (adopted == null && _sessionToken != sessionToken)) {
      throw const BetterAuthException(
        'Better Auth session changed while it was being restored; the stale '
        'result was discarded.',
        retryable: true,
      );
    }
    if (refreshed == null) {
      if (replacesCurrent) {
        // Only the staged session is gone; it never was the current one, so
        // this is not an AuthSessionEndedError.
        _adoptedSession = null;
        throw BetterAuthException(
          'The adopted Better Auth session is no longer valid'
          '${rejection == null ? '' : ' (${rejection.message})'}; the current '
          'session was kept.',
        );
      }
      _clearSession();
      throw _SessionEndedStateError('Better Auth session expired.');
    }
    if (adopted != null) {
      _adoptedSession = null;
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
    _adoptedSession = null;
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

  /// Stages [session], obtained outside [login] (for example from
  /// [BetterAuthClient.verifyMagicLink]), to become the provider's session.
  ///
  /// Then call `authedClient.loginFromCache()` to authenticate the Convex
  /// client with it: the staged session becomes the current one (and
  /// [cachedSession]) only when that restore succeeds. Until then — and if
  /// the restore fails — the current session is kept, so background token
  /// refreshes keep serving it. After a transient failure the session stays
  /// staged and the next `loginFromCache()` retries it; a [login], [signUp],
  /// [logout] or another [adoptSession] discards it. Persist
  /// `session.sessionToken` once the restore succeeded.
  ///
  /// Like [login], this supersedes a [login], [signUp] or explicit
  /// [loginFromCache] that is still in flight.
  void adoptSession(BetterAuthSession session) {
    _sessionEpoch++;
    _clearPendingLoginSession();
    _adoptedSession = session;
  }

  /// The currently cached session, if any.
  ///
  /// A session staged by [adoptSession] appears here only once
  /// `loginFromCache()` restored it.
  BetterAuthSession? get cachedSession => _cachedSession;

  void _commitSession(BetterAuthSession session) {
    _sessionEpoch++;
    _clearPendingLoginSession();
    _adoptedSession = null;
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
        'Better Auth $operation was superseded by a newer login, signUp, '
        'adoptSession, loginFromCache or logout; its session was discarded.',
      );
    }
    _commitSession(session);
  }

  void _clearSession() {
    _sessionEpoch++;
    _cachedSession = null;
    _sessionToken = null;
    _adoptedSession = null;
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
