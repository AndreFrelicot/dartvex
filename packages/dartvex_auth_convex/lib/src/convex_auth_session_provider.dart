import 'dart:async';

import 'package:dartvex/dartvex.dart';

import 'convex_auth_exception.dart';
import 'convex_auth_http_client.dart';
import 'convex_auth_session.dart';
import 'convex_auth_sign_in.dart';

/// [AuthProvider] for Convex Auth (`@convex-dev/auth` v2) sessions.
///
/// Use it with `ConvexClient.withAuth<ConvexAuthSession>()` and drive sign-in,
/// restore and sign-out through the wrapper (`authedClient.login()`,
/// `authedClient.loginFromCache()`, `authedClient.logout()`), so the Convex
/// client and this provider stay in sync:
///
/// * **Sign in**: set [signIn] (for example
///   `ConvexAuthSignIn.usernamePassword(...)`), then call
///   `authedClient.login()`. For a session obtained some other way (an OAuth
///   deep link, a flow the app runs itself), call [adoptSession] instead of
///   setting [signIn].
/// * **Restore**: pass the persisted session as `initialSession`, then call
///   `authedClient.loginFromCache()`.
/// * **Persist**: the refresh token rotates on every refresh (about once a
///   minute with the default access-token lifetime). Save the session passed
///   to [onSessionChanged] every time, and delete it when it is `null`.
///
/// Sessions are refreshed through the `refreshSession` mutation and revoked
/// through `signOut`, both called over HTTP with [client]. Concurrent
/// refreshes of the same session share one request, so a rotated refresh
/// token is never sent again.
///
/// ## Errors
///
/// * [ConvexAuthSignInException]: the sign-in function rejected the request
///   (for example `INVALID_CREDENTIALS`); see its `code`.
/// * [ConvexAuthSessionEndedException]: there is no session to restore, or the
///   server reports it gone. Sign in again.
/// * Any other [ConvexAuthException] leaves the current session in place;
///   with `retryable: true` (network errors, timeouts, HTTP 5xx and 429)
///   retry later.
class ConvexAuthSessionProvider implements AuthProvider<ConvexAuthSession> {
  /// Creates a provider that calls the deployment through [client].
  ///
  /// [initialSession] seeds a session persisted from a previous run, so
  /// `loginFromCache()` can restore it. [refreshSessionFunction] and
  /// [signOutFunction] are the paths of the app's re-exported core mutations
  /// (`export const { signOut, refreshSession } = auth;` in `convex/auth.ts`
  /// by default).
  ConvexAuthSessionProvider({
    required this.client,
    ConvexAuthSession? initialSession,
    this.onSessionChanged,
    this.refreshSessionFunction = 'auth:refreshSession',
    this.signOutFunction = 'auth:signOut',
  }) : _session = initialSession;

  /// The HTTP client used to call the auth mutations.
  final ConvexAuthHttpClient client;

  /// Path of the app's `refreshSession` mutation.
  final String refreshSessionFunction;

  /// Path of the app's `signOut` mutation.
  final String signOutFunction;

  /// Called with the new session whenever it changes (sign-in, adoption,
  /// every refresh) and with `null` when it ends (logout, session gone).
  ///
  /// Persist the session here: a refresh token that was rotated away soon
  /// stops working. An error thrown by the callback is reported to the
  /// current zone and does not interrupt the auth flow.
  void Function(ConvexAuthSession? session)? onSessionChanged;

  /// The sign-in request [login] sends.
  ///
  /// Cleared once it has been sent, unless it failed with a retryable error
  /// (so `login()` can simply be called again), and by [logout].
  ConvexAuthSignIn? signIn;

  ConvexAuthSession? _session;

  /// Session handed over by [adoptSession], made current by the next [login].
  ConvexAuthSession? _adoptedSession;

  /// Incremented by every user-started change (login, adoptSession, explicit
  /// loginFromCache, logout, a session the server reports gone), but not by
  /// the rotation of the current session. Async operations capture it before
  /// awaiting and drop their result when it changed.
  int _epoch = 0;

  _InFlightRefresh? _refreshing;

  /// The current session, if any. Updated on every refresh.
  ConvexAuthSession? get session => _session;

  @override
  String extractIdToken(ConvexAuthSession authResult) => authResult.accessToken;

  @override

  /// Starts a session: the one staged by [adoptSession] if any, otherwise the
  /// result of the [signIn] request.
  ///
  /// The previous session, if a different one, is revoked on the server in
  /// the background.
  ///
  /// Throws a [StateError] when neither is set, a
  /// [ConvexAuthSignInException] when the sign-in function rejects the
  /// request, and a [ConvexAuthException] when a newer [login],
  /// [adoptSession], explicit `loginFromCache()` or [logout] started while the
  /// request was in flight (the superseded session is revoked). A background
  /// token refresh does not supersede it.
  Future<ConvexAuthSession> login({
    required void Function(String? token) onIdToken,
  }) async {
    final adopted = _adoptedSession;
    if (adopted != null) {
      _replaceSession(adopted);
      onIdToken(adopted.accessToken);
      return adopted;
    }
    final request = signIn;
    if (request == null) {
      throw StateError(
        'Set signIn (or call adoptSession) on ConvexAuthSessionProvider '
        'before login().',
      );
    }
    final epoch = ++_epoch;
    final Object? result;
    try {
      result = await client.mutation(request.function, request.args);
    } on ConvexAuthException catch (error) {
      if (!error.retryable && identical(signIn, request)) {
        signIn = null;
      }
      rethrow;
    }
    if (identical(signIn, request)) {
      signIn = null;
    }
    final session = _parseSignInResult(request.function, result);
    if (epoch != _epoch) {
      _revokeInBackground(session);
      throw const ConvexAuthException(
        'Convex Auth login() was superseded by a newer login, adoptSession, '
        'loginFromCache or logout; its session was revoked.',
      );
    }
    _replaceSession(session);
    onIdToken(session.accessToken);
    return session;
  }

  @override

  /// Refreshes the current session and returns it with a new access token.
  ///
  /// This is also the token refresh hook of `ConvexClientWithAuth`. An
  /// explicit call (for example `authedClient.loginFromCache()`) is a new
  /// user intent that supersedes a [login] still in flight; a background
  /// refresh (made in a zone where `Zone.current[#dartvex.authTokenRefresh]`
  /// is `true`) supersedes nothing.
  ///
  /// Throws a [ConvexAuthSessionEndedException] when there is no session or
  /// the server reports it gone (the session is then cleared and
  /// [onSessionChanged] receives `null`). Throws a retryable
  /// [ConvexAuthException] when the session was replaced or cleared while the
  /// refresh was in flight.
  Future<ConvexAuthSession> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    final isRefresh = Zone.current[#dartvex.authTokenRefresh] == true;
    final epoch = isRefresh ? _epoch : ++_epoch;
    final current = _session;
    if (current == null) {
      throw const ConvexAuthSessionEndedException('No Convex Auth session.');
    }
    final refreshed = await _refresh(current);
    if (epoch != _epoch || !identical(_session, refreshed)) {
      throw const ConvexAuthException(
        'Convex Auth session changed while it was being refreshed; the stale '
        'result was discarded.',
        retryable: true,
      );
    }
    onIdToken(refreshed.accessToken);
    return refreshed;
  }

  @override

  /// Clears the session locally, then revokes it on the server.
  ///
  /// Local state ([session], [signIn], an adopted session) is cleared before
  /// the request is sent, so it is cleared even when the request fails.
  Future<void> logout() async {
    final current = _session;
    _epoch++;
    signIn = null;
    _adoptedSession = null;
    _refreshing = null;
    _setSession(null);
    if (current != null) {
      await client.mutation(
        signOutFunction,
        <String, Object?>{'refreshToken': current.refreshToken},
      );
    }
  }

  /// Stages [session], obtained outside [login] (for example from an OAuth
  /// callback, or a sign-in mutation the app called itself), to become the
  /// provider's session on the next `authedClient.login()`.
  ///
  /// Like [login], this supersedes a [login] or explicit `loginFromCache()`
  /// that is still in flight.
  void adoptSession(ConvexAuthSession session) {
    _epoch++;
    _adoptedSession = session;
  }

  ConvexAuthSession _parseSignInResult(String function, Object? value) {
    if (value is Map) {
      switch (value['status']) {
        case 'complete':
          try {
            return ConvexAuthSession.fromJson(value['tokens']);
          } on FormatException catch (error) {
            throw ConvexAuthException(
              'Convex Auth sign-in with $function returned an invalid token '
              'bundle: ${error.message}',
            );
          }
        case 'error':
          throw ConvexAuthSignInException(function, value['userError']);
      }
    }
    throw ConvexAuthException(
      '$function did not return a Convex Auth sign-in result '
      '({status: "complete"} or {status: "error"}).',
    );
  }

  /// Refreshes [current], sharing the request with a refresh of the same
  /// refresh token that is already in flight.
  Future<ConvexAuthSession> _refresh(ConvexAuthSession current) {
    final inFlight = _refreshing;
    if (inFlight != null && inFlight.refreshToken == current.refreshToken) {
      return inFlight.future;
    }
    final future = _runRefresh(current);
    final entry = _InFlightRefresh(current.refreshToken, future);
    _refreshing = entry;
    future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_refreshing, entry)) {
        _refreshing = null;
      }
    });
    return future;
  }

  Future<ConvexAuthSession> _runRefresh(ConvexAuthSession current) async {
    final args = <String, Object?>{'refreshToken': current.refreshToken};
    Object? result;
    try {
      result = await client.mutation(refreshSessionFunction, args);
    } on ConvexAuthException catch (error) {
      if (!error.retryable) {
        rethrow;
      }
      // The server may have rotated the token before the response was lost.
      // It accepts an already redeemed token again for a few seconds, so
      // retrying right away recovers the session instead of dropping it.
      result = await client.mutation(refreshSessionFunction, args);
    }

    final kind = result is Map ? result['kind'] : null;
    if (kind == 'rotated') {
      final ConvexAuthSession next;
      try {
        next = ConvexAuthSession.fromJson((result as Map)['tokens']);
      } on FormatException catch (error) {
        throw ConvexAuthException(
          '$refreshSessionFunction returned an invalid token bundle: '
          '${error.message}',
        );
      }
      if (!identical(_session, current)) {
        // Logged out or replaced meanwhile: nobody owns this session.
        _revokeInBackground(next);
        throw const ConvexAuthException(
          'Convex Auth session changed while it was being refreshed; the '
          'stale result was discarded.',
          retryable: true,
        );
      }
      _setSession(next);
      return next;
    }
    if (kind == 'noSession') {
      if (identical(_session, current)) {
        _epoch++;
        _adoptedSession = null;
        _setSession(null);
        throw const ConvexAuthSessionEndedException(
          'Convex Auth session expired or was revoked.',
        );
      }
      throw const ConvexAuthException(
        'Convex Auth session changed while it was being refreshed; the stale '
        'result was discarded.',
        retryable: true,
      );
    }
    throw ConvexAuthException(
      '$refreshSessionFunction did not return a refresh result '
      '({kind: "rotated"} or {kind: "noSession"}).',
    );
  }

  /// Makes [next] the current session as a user-started change, revoking the
  /// previous session when it is a different one.
  void _replaceSession(ConvexAuthSession next) {
    final previous = _session;
    _epoch++;
    _adoptedSession = null;
    _refreshing = null;
    _setSession(next);
    if (previous != null && previous.refreshToken != next.refreshToken) {
      _revokeInBackground(previous);
    }
  }

  void _setSession(ConvexAuthSession? next) {
    if (identical(_session, next)) {
      return;
    }
    _session = next;
    final callback = onSessionChanged;
    if (callback == null) {
      return;
    }
    try {
      callback(next);
    } catch (error, stackTrace) {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }

  void _revokeInBackground(ConvexAuthSession session) {
    client.mutation(
      signOutFunction,
      <String, Object?>{'refreshToken': session.refreshToken},
    ).then<void>((_) {}, onError: (Object _) {});
  }
}

final class _InFlightRefresh {
  _InFlightRefresh(this.refreshToken, this.future);

  final String refreshToken;
  final Future<ConvexAuthSession> future;
}
