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

  /// Session created by [signIn] or [signUp] for [_pendingLoginEmail], made
  /// current by the next [login] or explicit [loginFromCache]. Until then
  /// the current session, if any, stays the one background refreshes serve.
  BetterAuthSession? _pendingLoginSession;
  String? _pendingLoginEmail;

  /// Session handed over by [adoptSession], made current by the next
  /// successful explicit [loginFromCache].
  BetterAuthSession? _adoptedSession;

  /// Incremented by every user-started call (login, signIn, signUp,
  /// adoptSession, an explicit loginFromCache, logout). Those operations
  /// capture it before awaiting and drop their result when it changed, so a
  /// stale response can never resurrect an older session.
  ///
  /// A background token refresh neither reads nor changes it: it is tied to
  /// the session token it refreshes, so it cannot cancel a sign-in in
  /// flight, even when it finds the current session expired.
  int _sessionEpoch = 0;

  /// Email of the account [login] signs in. Set by [signIn] and [signUp];
  /// set it yourself, with [password], only for the staged-credentials flow.
  ///
  /// Cleared by [logout].
  String? email;

  /// Password paired with [email] for the next [login] call.
  ///
  /// Prefer [signIn], which takes the password as an argument and never
  /// stores it. This field is the older flow, where [login] itself sends the
  /// credentials: [login] clears it once it has signed in, and after a
  /// failure that retrying cannot fix (wrong credentials, a superseded
  /// sign-in). Only a retryable failure (network, 5xx, …) keeps it, so the
  /// same `login()` can be retried. Set it again before every [login]. Also
  /// cleared by [logout], and by [signIn] and [signUp], which start a new
  /// sign-in of their own.
  String? password;

  @override

  /// Extracts the Convex JWT from a Better Auth session.
  String extractIdToken(BetterAuthSession authResult) => authResult.token;

  @override

  /// Makes the session created by [signIn] or [signUp] the provider's
  /// session, or signs in with the staged [email] and [password].
  ///
  /// The session of [signIn] / [signUp] is reused, without another request,
  /// when [email] is still theirs and no [password] was staged since. Staging
  /// a [password] is a new sign-in: that session is signed out in the
  /// background and the staged credentials are sent.
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
    final pendingSession = _takePendingLoginSession(email: e, password: p);
    if (pendingSession != null) {
      _commitSession(pendingSession);
      onIdToken(pendingSession.token);
      return pendingSession;
    }
    if (e == null || p == null) {
      throw StateError(
        'Call signIn(email:, password:) or signUp(...) on '
        'ConvexBetterAuthProvider before login() (or set email and password).',
      );
    }
    final epoch = ++_sessionEpoch;
    _adoptedSession = null;
    final BetterAuthSession session;
    try {
      session = await client.signIn(email: e, password: p);
      _commitIfCurrent(epoch, session, operation: 'login()');
    } catch (error) {
      if (error is! BetterAuthException || !error.retryable) {
        _forgetPassword(p);
      }
      rethrow;
    }
    _forgetPassword(p);
    onIdToken(session.token);
    return session;
  }

  /// Clears [password] unless the app already set a different one for a
  /// newer [login].
  void _forgetPassword(String used) {
    if (password == used) {
      password = null;
    }
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
    // A session staged by adoptSession, signIn or signUp. A background
    // refresh never touches it: it keeps serving the current session.
    final staged = isRefresh ? null : (_adoptedSession ?? _pendingLoginSession);
    final sessionToken = staged?.sessionToken ?? _sessionToken;
    // An explicit restore supersedes older work even when there is no token.
    final epoch = isRefresh ? null : ++_sessionEpoch;
    if (sessionToken == null) {
      throw _SessionEndedStateError('No cached Better Auth session.');
    }
    // Whether this restores a staged session while another one is current:
    // that session must survive the staged one being rejected.
    final current = _sessionToken;
    final replacesCurrent =
        staged != null && current != null && current != sessionToken;
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
    // An explicit restore is dropped when a newer user-started call began.
    // A restore of the current session, explicit or in the background, is
    // dropped when that session is no longer the current one.
    if ((epoch != null && epoch != _sessionEpoch) ||
        (staged == null && _sessionToken != sessionToken)) {
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
        final kind = identical(staged, _adoptedSession) ? 'adopted' : 'staged';
        _adoptedSession = null;
        _clearPendingLoginSession();
        throw BetterAuthException(
          'The $kind Better Auth session is no longer valid'
          '${rejection == null ? '' : ' (${rejection.message})'}; the current '
          'session was kept.',
        );
      }
      if (isRefresh) {
        // Only the current session ended. A sign-in in flight and a session
        // staged for the next login() are another session: keep them.
        _cachedSession = null;
        _sessionToken = null;
      } else {
        _clearSession();
      }
      throw _SessionEndedStateError('Better Auth session expired.');
    }
    if (staged != null) {
      _adoptedSession = null;
      _clearPendingLoginSession();
    }
    _cachedSession = refreshed;
    _sessionToken = refreshed.sessionToken;
    onIdToken(refreshed.token);
    return refreshed;
  }

  @override

  /// Signs out the current Better Auth session and clears cached state.
  ///
  /// Local state (session, [email] and [password]) is cleared before the
  /// sign-out request is sent, so it is cleared even when that request fails,
  /// and a [login] started while the request is in flight is not wiped when
  /// it completes. A session that [signIn] or [signUp] created and no [login]
  /// used yet is signed out too.
  Future<void> logout() async {
    final sessionToken = _sessionToken;
    final staged = _pendingLoginSession?.sessionToken;
    _clearSession();
    email = null;
    password = null;
    if (sessionToken == null) {
      // Only a session staged by signIn or signUp: it is the one to end.
      if (staged != null) {
        await client.signOut(sessionToken: staged);
      }
      return;
    }
    if (staged != null && staged != sessionToken) {
      _signOutInBackground(staged);
    }
    await client.signOut(sessionToken: sessionToken);
  }

  /// Signs in with [email] and [password] without keeping the password.
  ///
  /// This does not authenticate the Convex client, and does not change the
  /// provider's current session either: the new session is only staged. Call
  /// `authedClient.login()` afterwards: it makes the session created here the
  /// provider's session (and [cachedSession]) without another request. Until
  /// then, a session the client is already signed in with stays the one its
  /// background token refreshes serve, so the client never runs as the new
  /// account before `login()`. [onIdToken] is optional and only receives the
  /// new session's Convex JWT.
  ///
  /// The password is sent once and not stored: when the request fails, call
  /// `signIn` again with the credentials (for a retryable
  /// [BetterAuthException], the same ones).
  ///
  /// Like [login], this supersedes a [login], [signUp] or explicit
  /// [loginFromCache] that is still in flight, and throws a
  /// [BetterAuthException] when a newer one superseded it.
  Future<BetterAuthSession> signIn({
    required String email,
    required String password,
    void Function(String? token)? onIdToken,
  }) async {
    final epoch = _startStagedSignIn();
    final session = await client.signIn(email: email, password: password);
    _stageIfCurrent(epoch, session, email, operation: 'signIn()');
    onIdToken?.call(session.token);
    return session;
  }

  /// Signs up a new user without keeping the password.
  ///
  /// Like [signIn], this only stages the new session: it does not
  /// authenticate the Convex client or replace the provider's current
  /// session. Call `authedClient.login()` afterwards; it reuses the session
  /// created here instead of signing in again. [onIdToken] is optional and
  /// only receives the new session's Convex JWT.
  ///
  /// Throws [BetterAuthEmailVerificationRequiredException] when the server
  /// requires email verification before the first sign-in.
  Future<BetterAuthSession> signUp({
    required String name,
    required String email,
    required String password,
    void Function(String? token)? onIdToken,
  }) async {
    final epoch = _startStagedSignIn();
    final session = await client.signUp(
      name: name,
      email: email,
      password: password,
    );
    _stageIfCurrent(epoch, session, email, operation: 'signUp()');
    onIdToken?.call(session.token);
    return session;
  }

  /// Starts a [signIn] or [signUp]: a new user intent, which supersedes the
  /// ones in flight and replaces whatever was staged for [login].
  ///
  /// The staged [password] of the older flow is dropped: it belongs to an
  /// earlier attempt, maybe for another account, and must never be sent with
  /// the email of this one.
  int _startStagedSignIn() {
    final epoch = ++_sessionEpoch;
    _adoptedSession = null;
    _discardPendingLoginSession();
    password = null;
    return epoch;
  }

  /// Stages [session], created for [email] by [signIn] or [signUp], for the
  /// next [login], unless a newer user-started call superseded that request.
  void _stageIfCurrent(
    int epoch,
    BetterAuthSession session,
    String email, {
    required String operation,
  }) {
    if (epoch != _sessionEpoch) {
      _signOutInBackground(session.sessionToken);
      throw BetterAuthException(
        'Better Auth $operation was superseded by a newer login, signUp, '
        'adoptSession, loginFromCache or logout; its session was discarded.',
      );
    }
    _pendingLoginSession = session;
    _pendingLoginEmail = email;
    this.email = email;
  }

  /// Drops the session staged by [signIn] or [signUp] and signs it out in
  /// the background: nobody else holds it.
  ///
  /// It is not signed out when it is the current session or [keep], the
  /// session token the caller is handing over at the same time: signing out
  /// a token ends its session for whoever holds it.
  void _discardPendingLoginSession({String? keep}) {
    final staged = _pendingLoginSession?.sessionToken;
    _clearPendingLoginSession();
    if (staged != null && staged != _sessionToken && staged != keep) {
      _signOutInBackground(staged);
    }
  }

  void _signOutInBackground(String sessionToken) {
    client
        .signOut(sessionToken: sessionToken)
        .then<void>((_) {}, onError: (Object _) {});
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
    // The app may adopt the very session signIn() or signUp() returned.
    _discardPendingLoginSession(keep: session.sessionToken);
    _adoptedSession = session;
  }

  /// The currently cached session, if any.
  ///
  /// A session staged by [adoptSession] appears here only once
  /// `loginFromCache()` restored it, and one created by [signIn] or [signUp]
  /// only once `login()` made it current.
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
      _signOutInBackground(session.sessionToken);
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

  /// The session staged by [signIn] or [signUp], when [login] should use it:
  /// [email] is still the one it was created for and no [password] was staged
  /// for a new sign-in. Otherwise the staged session is signed out.
  BetterAuthSession? _takePendingLoginSession({
    required String? email,
    required String? password,
  }) {
    final session = _pendingLoginSession;
    if (_pendingLoginEmail == email && password == null) {
      _clearPendingLoginSession();
      return session;
    }
    _discardPendingLoginSession();
    return null;
  }

  void _clearPendingLoginSession() {
    _pendingLoginSession = null;
    _pendingLoginEmail = null;
  }
}

/// The [StateError] thrown when the provider has no usable session; marked
/// as definitive for `ConvexClientWithAuth`.
final class _SessionEndedStateError extends StateError
    implements AuthSessionEndedError {
  _SessionEndedStateError(super.message);
}
