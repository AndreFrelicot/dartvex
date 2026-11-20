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
///   to [onSessionChanged] every time, and delete it when it is `null`. The
///   callback may be asynchronous: saves run one at a time, in order, and a
///   new session is only handed to the Convex client once it has been saved.
///
/// Sessions are refreshed through the `refreshSession` mutation and revoked
/// through `signOut`, both called over HTTP with [client]. Concurrent
/// refreshes of the same session share one request.
///
/// One provider owns a stored session. Two providers (two browser tabs, two
/// isolates) that share the same storage are not coordinated: each rotates
/// the refresh token on its own, and a token two rotations old makes the
/// server end the session. Give each its own session, or let a single one
/// refresh.
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
    this.onBackgroundError,
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
  /// Persist the session here, and return the future of the write when the
  /// storage is asynchronous. Calls never overlap: each one starts after the
  /// previous one finished, in the order of the changes, so an older write
  /// cannot land after a newer one (or after the removal of a logout).
  /// [login], a refresh and [logout] wait for their save before they
  /// complete, so a storage that never answers blocks them: bound your
  /// writes with a timeout.
  ///
  /// An error thrown by the callback does not interrupt the auth flow. It is
  /// passed to [onBackgroundError], or reported to the current zone when
  /// that is not set: the stored session is then out of date, and a restart
  /// may restore a refresh token the server no longer accepts. The provider
  /// calls the callback again at the next change of the session. The one
  /// exception is [logout], which throws the error of a removal that failed
  /// and retries the removal when it is called again.
  FutureOr<void> Function(ConvexAuthSession? session)? onSessionChanged;

  /// Called with failures the provider cannot report to a caller: an error
  /// thrown by [onSessionChanged], and a failed background revocation of a
  /// session nobody uses any more (it may then still be alive on the
  /// server, until it expires).
  ///
  /// The errors of the adapter are [ConvexAuthException]s, which carry no
  /// token.
  void Function(Object error, StackTrace stackTrace)? onBackgroundError;

  /// Tail of the queue of [onSessionChanged] calls.
  Future<void> _saves = Future<void>.value();

  /// Completes, never with an error, once every [onSessionChanged] call
  /// queued so far has finished. Await it before the app exits, or in tests.
  Future<void> get sessionSaved => _saves;

  /// The sign-in request [login] sends.
  ///
  /// Cleared once it has been sent, unless it failed with a retryable error
  /// (so `login()` can simply be called again), and by [logout].
  ConvexAuthSignIn? signIn;

  ConvexAuthSession? _session;

  /// Session handed over by [adoptSession], made current by the next [login].
  ConvexAuthSession? _adoptedSession;

  /// Incremented by every user-started change (login, adoptSession, explicit
  /// loginFromCache, logout). Those operations capture it before awaiting
  /// and drop their result when it changed.
  ///
  /// What happens to the current session in the background (a rotation, the
  /// server reporting it gone) neither reads nor changes it: a background
  /// refresh is tied to the session it refreshes, so the end of that session
  /// cannot cancel a sign-in to another one that is still in flight.
  int _epoch = 0;

  /// The latest queued [onSessionChanged] call, the one that writes
  /// [_session]; `null` when [_session] was never handed to the callback.
  ///
  /// When it failed, the app's storage does not hold [_session]: the next
  /// change (or [logout]) writes it again even when the session itself is
  /// unchanged. Until then, callers that ask for the same value share this
  /// write: a [logout] that finds the removal already queued by the provider
  /// waits for it and reports its result.
  _SaveOutcome? _lastSave;

  /// The [logout] that is still running, shared by the calls that find
  /// nothing more to sign out. Forgotten when a session is installed: what
  /// happens to that session is not part of this logout.
  Future<void>? _loggingOut;

  _InFlightRefresh? _refreshing;

  /// The current session, if any. Updated on every refresh.
  ConvexAuthSession? get session => _session;

  @override
  String extractIdToken(ConvexAuthSession authResult) => authResult.accessToken;

  @override

  /// Starts a session: the one staged by [adoptSession] if any, otherwise the
  /// result of the [signIn] request.
  ///
  /// The previous session is revoked on the server in the background when it
  /// is a different server session (see [ConvexAuthSession.sessionId]), not
  /// when the new bundle is a later rotation of the same one.
  ///
  /// Throws a [StateError] when neither is set, a
  /// [ConvexAuthSignInException] when the sign-in function rejects the
  /// request, and a [ConvexAuthException] when a newer [login],
  /// [adoptSession], explicit `loginFromCache()` or [logout] started while the
  /// request or the save of its session was in flight (a session created by
  /// the superseded sign-in is revoked). A background token refresh does not
  /// supersede it.
  Future<ConvexAuthSession> login({
    required void Function(String? token) onIdToken,
  }) async {
    final adopted = _adoptedSession;
    if (adopted != null) {
      await _install(adopted);
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
    await _install(session);
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
    final epoch = isRefresh ? null : ++_epoch;
    final current = _session;
    if (current == null) {
      throw const ConvexAuthSessionEndedException('No Convex Auth session.');
    }
    final refreshed = await _refresh(current);
    // An explicit restore is dropped when a newer user-started call began;
    // any restore is dropped when its session is no longer the current one.
    if ((epoch != null && epoch != _epoch) || !identical(_session, refreshed)) {
      throw const ConvexAuthException(
        'Convex Auth session changed while it was being refreshed; the stale '
        'result was discarded.',
        retryable: true,
      );
    }
    onIdToken(refreshed.accessToken);
    return refreshed;
  }

  /// Clears the session locally, then revokes it on the server.
  ///
  /// Local state ([session], [signIn], an adopted session) is cleared before
  /// the request is sent, so it is cleared even when the request fails. The
  /// future completes once [onSessionChanged] finished removing the stored
  /// session, whether the request succeeded or threw. A session staged by
  /// [adoptSession] and not installed yet is revoked too, in the background.
  ///
  /// Throws the [ConvexAuthException] of the sign-out request when it failed
  /// (the session may then still be alive on the server, until it expires:
  /// the request may also have been processed before its answer was lost).
  /// When the request went through but [onSessionChanged] threw while
  /// removing the stored session, throws that error instead of passing it
  /// to [onBackgroundError]: the session is still in the app's storage, and
  /// a restart would restore it. In both cases the removal stays owed: call
  /// `logout()` again to retry it (nothing is sent to the server then).
  ///
  /// A call made while another `logout()` is still running, with no session
  /// installed since, joins it: nothing is left for it to sign out, so it
  /// completes with the same result, the error of the sign-out request
  /// included.
  @override
  Future<void> logout() {
    final current = _session;
    final staged = _adoptedSession;
    _epoch++;
    signIn = null;
    _adoptedSession = null;
    _refreshing = null;
    // The sign-out of the current session ends every bundle of that
    // session; a staged bundle with another refresh token may be another
    // session, and nobody would end it.
    if (staged != null && staged.refreshToken != current?.refreshToken) {
      _revokeInBackground(staged);
    }
    final running = _loggingOut;
    if (current == null && running != null) {
      return running;
    }
    late final Future<void> operation;
    operation = _signOut(current).whenComplete(() {
      if (identical(_loggingOut, operation)) {
        _loggingOut = null;
      }
    });
    return _loggingOut = operation;
  }

  /// Removes the stored session and revokes [current] on the server.
  Future<void> _signOut(ConvexAuthSession? current) async {
    // The provider may have queued this removal already, when the server
    // reported the session gone: this call waits for that write and reports
    // its result.
    final saved = _setSession(null, reportedByCaller: true);
    final removal = _lastSave;
    try {
      if (current != null) {
        await client.mutation(
          signOutFunction,
          <String, Object?>{'refreshToken': current.refreshToken},
        );
      }
    } catch (_) {
      // The caller gets the error of the request; the failed removal, if
      // any, goes where failed saves go.
      await saved;
      final error = removal?.error;
      if (error != null) {
        _reportBackgroundError(error, removal!.stackTrace!, isSave: true);
      }
      rethrow;
    }
    await saved;
    final error = removal?.error;
    if (error != null) {
      Error.throwWithStackTrace(error, removal!.stackTrace!);
    }
  }

  /// Stages [session], obtained outside [login] (for example from an OAuth
  /// callback, or a sign-in mutation the app called itself), to become the
  /// provider's session on the next `authedClient.login()`.
  ///
  /// The provider owns a staged session: one that is replaced by another
  /// `adoptSession` before `login()` installed it is revoked on the server in
  /// the background, unless it is the same server session as the new one or
  /// as the current session.
  ///
  /// Like [login], this supersedes a [login] or explicit `loginFromCache()`
  /// that is still in flight.
  void adoptSession(ConvexAuthSession session) {
    final abandoned = _adoptedSession;
    _epoch++;
    _adoptedSession = session;
    if (abandoned != null && !identical(abandoned, session)) {
      _revokeIfOrphan(abandoned, kept: <ConvexAuthSession?>[session, _session]);
    }
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
      // A redeemed token is accepted again as long as no token issued from
      // it was redeemed, so retrying recovers the session instead of
      // dropping it.
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
      final replacement = _session;
      if (!identical(replacement, current)) {
        // Logged out or replaced meanwhile: nobody uses this bundle. After a
        // logout it is revoked again in case the sign-out request failed;
        // after a replacement, only when it is not the session now in use.
        if (replacement == null) {
          _revokeInBackground(next);
        } else {
          _revokeIfOrphan(
            next,
            kept: <ConvexAuthSession?>[replacement, _adoptedSession],
          );
        }
        throw const ConvexAuthException(
          'Convex Auth session changed while it was being refreshed; the '
          'stale result was discarded.',
          retryable: true,
        );
      }
      // The rotated refresh token is saved before the new access token is
      // used: the previous one is of no use after the next rotation.
      await _setSession(next);
      return next;
    }
    if (kind == 'noSession') {
      if (identical(_session, current)) {
        // Only this session ended: a login() to another one that is still
        // in flight goes on (the epoch is left alone).
        // A staged bundle of the session that just ended is gone with it;
        // one of another session stays staged for the next login().
        final staged = _adoptedSession;
        if (staged != null && !_isDifferentSession(staged, current)) {
          _adoptedSession = null;
        }
        await _setSession(null);
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

  /// Makes [next] the current session as a user-started change and waits
  /// for its save. The previous session is revoked when it is another server
  /// session.
  ///
  /// Throws when a newer login, adoptSession, loginFromCache or logout
  /// started while the session was being saved.
  Future<void> _install(ConvexAuthSession next) async {
    final previous = _session;
    final epoch = ++_epoch;
    _adoptedSession = null;
    _refreshing = null;
    final saved = _setSession(next);
    if (previous != null && !identical(previous, next)) {
      _revokeIfOrphan(previous, kept: <ConvexAuthSession?>[next]);
    }
    await saved;
    if (epoch != _epoch) {
      throw const ConvexAuthException(
        'Convex Auth login() was superseded by a newer login, adoptSession, '
        'loginFromCache or logout while its session was being saved.',
      );
    }
    if (_session == null) {
      // No user-started call cleared it: a refresh found it gone already.
      throw const ConvexAuthSessionEndedException(
        'The new Convex Auth session ended while it was being saved.',
      );
    }
  }

  /// Makes [next] the session and queues its save. The returned future
  /// completes, never with an error, once that save and the ones queued
  /// before it are done.
  ///
  /// An unchanged session is saved again when the last save failed, so the
  /// storage is not left out of date. A failed save is passed to
  /// [onBackgroundError], unless [reportedByCaller]: the caller then reads
  /// the failure from [_lastSave] and reports it itself.
  Future<void> _setSession(
    ConvexAuthSession? next, {
    bool reportedByCaller = false,
  }) {
    if (identical(_session, next) && _lastSave?.error == null) {
      // The write of this value is queued, running or done. A caller that
      // reports its failure takes it over from the background handler.
      if (reportedByCaller) {
        _lastSave?.reportedByCaller = true;
      }
      return _saves;
    }
    _session = next;
    if (next != null) {
      // A logout still running ended an earlier session. A later logout()
      // is about this one: it must not join that operation.
      _loggingOut = null;
    }
    final callback = onSessionChanged;
    if (callback == null) {
      _lastSave = null;
      return _saves;
    }
    final outcome =
        _lastSave = _SaveOutcome()..reportedByCaller = reportedByCaller;
    return _saves = _saves.then((_) async {
      try {
        await callback(next);
      } catch (error, stackTrace) {
        outcome
          ..error = error
          ..stackTrace = stackTrace;
        if (!outcome.reportedByCaller) {
          _reportBackgroundError(error, stackTrace, isSave: true);
        }
      }
    });
  }

  /// Whether [a] and [b] are known to belong to two server sessions. Bundles
  /// whose session cannot be read are never treated as different: revoking
  /// one could end the session of the other, because the server ends a
  /// session for any refresh token it issued for it.
  static bool _isDifferentSession(ConvexAuthSession a, ConvexAuthSession b) {
    final first = a.sessionId;
    final second = b.sessionId;
    return first != null && second != null && first != second;
  }

  /// Revokes [candidate] in the background unless it is, or may be, the same
  /// server session as one of [kept].
  void _revokeIfOrphan(
    ConvexAuthSession candidate, {
    required Iterable<ConvexAuthSession?> kept,
  }) {
    for (final session in kept) {
      if (session != null && !_isDifferentSession(candidate, session)) {
        return;
      }
    }
    _revokeInBackground(candidate);
  }

  void _revokeInBackground(ConvexAuthSession session) {
    client.mutation(
      signOutFunction,
      <String, Object?>{'refreshToken': session.refreshToken},
    ).then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) =>
          _reportBackgroundError(error, stackTrace, isSave: false),
    );
  }

  void _reportBackgroundError(
    Object error,
    StackTrace stackTrace, {
    required bool isSave,
  }) {
    final handler = onBackgroundError;
    if (handler == null) {
      // A failed save leaves the stored session out of date: never silent.
      // A failed revocation only leaves a session nobody holds to expire.
      if (isSave) {
        Zone.current.handleUncaughtError(error, stackTrace);
      }
      return;
    }
    try {
      handler(error, stackTrace);
    } catch (handlerError, handlerStackTrace) {
      Zone.current.handleUncaughtError(handlerError, handlerStackTrace);
    }
  }
}

/// The failure, if any, of one [ConvexAuthSessionProvider.onSessionChanged]
/// call.
final class _SaveOutcome {
  Object? error;
  StackTrace? stackTrace;

  /// Whether a caller (logout) throws the failure itself, instead of it
  /// going to the background handler.
  bool reportedByCaller = false;
}

final class _InFlightRefresh {
  _InFlightRefresh(this.refreshToken, this.future);

  final String refreshToken;
  final Future<ConvexAuthSession> future;
}
