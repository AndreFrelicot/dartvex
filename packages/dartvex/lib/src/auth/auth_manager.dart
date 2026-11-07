import 'dart:async';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../config.dart';
import '../logging.dart';
import '../protocol/messages.dart';
import 'jwt_utils.dart';

/// Handle returned by [AuthManager.setAuthWithRefresh] to stop token refreshes.
abstract interface class AuthHandle {
  /// Cancels any active refresh flow.
  Future<void> cancel();
}

/// Sends an auth token update to the active transport.
///
/// Implementations must apply the change to local auth state synchronously,
/// before their first `await` (the returned future only covers flushing it to
/// the server): the manager relies on this to clear or replace transport auth
/// before it notifies listeners.
typedef SendAuthCallback = Future<void> Function(String? token);

/// Emits whether the backend currently considers the client authenticated.
typedef AuthStateEmitter = void Function(bool isAuthenticated);

/// Fetches an auth token, optionally forcing a refresh.
///
/// With `forceRefresh: false` the fetcher may return a cached token. With
/// `forceRefresh: true` it must bypass any cache and return a newly issued
/// token (or `null` when the user no longer has a session); it is used for the
/// scheduled refresh, the refetch after a cached token is confirmed, and the
/// reauth after the server rejects a token.
typedef AuthTokenFetcher = Future<String?> Function(
    {required bool forceRefresh});

/// Where the token awaiting server confirmation came from.
///
/// * [fixed]: [AuthManager.setAuth] (no refresh flow).
/// * [cached]: the refresh flow's `forceRefresh: false` fetch.
/// * [fresh]: a `forceRefresh: true` fetch — its whole `exp - iat` lifetime
///   lies ahead.
/// * [pushed]: [AuthManager.updateToken] — an externally supplied token of
///   unknown age.
enum _AuthConfirmationSource { none, fixed, cached, fresh, pushed }

/// Coordinates auth token updates and refresh scheduling for [ConvexClient].
class AuthManager {
  /// Creates an auth manager.
  ///
  /// The optional socket callbacks let the manager gate the transport so
  /// queries and mutations cannot race ahead of a pending auth: [pauseSocket]/
  /// [resumeSocket] bracket the initial token fetch, and [stopSocket]/
  /// [restartSocket] bracket a reauth so a fresh token is replayed on a clean
  /// connection. When omitted (e.g. in unit tests), token updates are simply
  /// sent without gating.
  ///
  /// [clientNowMillis] reads the clock that stamps `Connect.clientTs`; it is
  /// combined with a Transition's `clientClockSkew` to estimate the server's
  /// current time. Defaults to the device wall clock.
  /// [reauthFetchRetryDelays] spaces the retries of a token fetch that throws
  /// during a reauth; an empty list gives up after the first failure.
  AuthManager({
    required this.config,
    required this.sendAuth,
    required this.emitAuthState,
    Future<void> Function()? pauseSocket,
    Future<void> Function()? resumeSocket,
    Future<void> Function()? stopSocket,
    Future<void> Function()? restartSocket,
    void Function(bool isRefreshing)? onRefreshingChange,
    int Function()? clientNowMillis,
    List<Duration> reauthFetchRetryDelays = defaultReauthFetchRetryDelays,
  })  : _pauseSocket = pauseSocket,
        _resumeSocket = resumeSocket,
        _stopSocket = stopSocket,
        _restartSocket = restartSocket,
        _onRefreshingChange = onRefreshingChange,
        _clientNowMillis = clientNowMillis,
        _reauthFetchRetryDelays =
            List<Duration>.unmodifiable(reauthFetchRetryDelays);

  /// Delays between the attempts of a reauth token fetch that throws.
  ///
  /// A provider that throws during a reauth (for example on the first request
  /// after a mobile radio wakes up) is retried this many times before the user
  /// is signed out, so a transient failure does not end a still-valid session.
  static const List<Duration> defaultReauthFetchRetryDelays = <Duration>[
    Duration(milliseconds: 500),
    Duration(seconds: 2),
  ];

  /// Client configuration used for logging and token metadata.
  final ConvexClientConfig config;

  /// Callback that forwards auth token updates to Convex.
  final SendAuthCallback sendAuth;

  /// Callback that publishes public auth state changes.
  final AuthStateEmitter emitAuthState;

  final Future<void> Function()? _pauseSocket;
  final Future<void> Function()? _resumeSocket;
  final Future<void> Function()? _stopSocket;
  final Future<void> Function()? _restartSocket;
  final void Function(bool isRefreshing)? _onRefreshingChange;
  final int Function()? _clientNowMillis;
  final List<Duration> _reauthFetchRetryDelays;

  bool _isRefreshing = false;

  AuthTokenFetcher? _fetchToken;
  void Function(bool)? _onAuthChange;
  Timer? _refreshTimer;
  String? _currentToken;
  int _authGeneration = 0;

  /// Identity of the current *refresh flow*, advanced only when the flow
  /// itself is replaced or destroyed ([setAuthWithRefresh], [setAuth],
  /// [clearAuth], [stopRefreshing]) — NOT by [updateToken], which bumps
  /// [_authGeneration] to supersede an in-flight fetch but keeps the flow
  /// (and its [AuthHandle]) alive. Handles bind to this id so a token update
  /// pushed mid-flow cannot silently orphan the caller's handle, while a
  /// handle from a genuinely replaced flow still cannot tear down its
  /// successor.
  int _flowId = 0;

  /// Sequence number of the latest forced token fetch, like the official
  /// client's `configVersion`. Each forced fetch takes a number; the scheduled
  /// refresh and the post-confirmation refetch discard their result when a
  /// newer fetch has started meanwhile, so a concurrent reauth's result is the
  /// one that is applied.
  int _tokenFetchSequence = 0;

  /// Identity of the reauth that stopped the socket, or `null` when the socket
  /// is not stopped for a reauth. The reauth restarts the socket when it
  /// finishes; an entry point that supersedes it restarts it right away, so a
  /// slow or hanging token fetch cannot keep the connection down.
  Object? _socketStoppedByReauth;

  /// Whether `onAuthChange(true)` has been delivered for the current flow, so
  /// later confirmations within the flow (refreshes) do not repeat it.
  bool _authChangeTrueDelivered = false;
  int _tokenConfirmationAttempts = 0;
  bool _backendAuthenticated = false;
  bool _awaitingConfirmation = false;
  bool _emitAuthenticatedOnConfirmation = false;
  _AuthConfirmationSource _pendingConfirmationSource =
      _AuthConfirmationSource.none;

  static const int _maxTokenConfirmationAttempts = 2;

  /// Upper bound on the refresh delay, mirroring the official client's 20-day
  /// cap (`setTimeout` uses a 32-bit integer and overflows beyond ~24 days).
  static const int _maximumRefreshDelayMs = 20 * 24 * 60 * 60 * 1000;

  /// Minimum token lifetime (`exp - iat`) required to schedule a refresh. A
  /// token that lives this briefly is treated as not worth refreshing.
  static const int _minimumTokenValiditySeconds = 2;

  /// Floor for the refresh delay of a pushed token when no server clock-skew
  /// estimate is available, so a device clock running ahead cannot turn
  /// pushed tokens into back-to-back immediate refreshes.
  static const int _minimumPushedRefreshDelayMs = 5000;

  /// Sets a fixed auth [token] without a refresh callback.
  Future<void> setAuth(String? token) async {
    _log(
      DartvexLogLevel.info,
      token == null ? 'Auth cleared via setAuth' : 'Auth token set',
    );
    _cancelRefreshTimer();
    _setRefreshing(false);
    final generation = ++_authGeneration;
    _flowId += 1;
    _fetchToken = null;
    _onAuthChange = null;
    _authChangeTrueDelivered = false;
    _currentToken = token;
    _expectConfirmationForToken(token);
    // sendAuth applies the change to the transport synchronously; the signed
    // out state is then reported right away instead of after the flush, so a
    // newer auth call made meanwhile cannot be overwritten by it.
    final send = sendAuth(token);
    if (token == null) {
      _publish(false);
    }
    await send;
    await _releaseSocketForReplacedFlow(generation);
  }

  /// Configures an auth refresh flow driven by [fetchToken].
  Future<AuthHandle> setAuthWithRefresh({
    required AuthTokenFetcher fetchToken,
    void Function(bool)? onAuthChange,
  }) async {
    _log(DartvexLogLevel.debug, 'Configuring auth refresh flow');
    _cancelRefreshTimer();
    // Mirrors the official setConfig()'s resetAuthState(): confirmations and
    // errors for the superseded flow's token must not be credited to this one.
    _clearPendingConfirmation();
    _setRefreshing(false);
    final generation = ++_authGeneration;
    final flowId = ++_flowId;
    _fetchToken = fetchToken;
    _onAuthChange = onAuthChange;
    _authChangeTrueDelivered = false;
    // Pause the socket so queries/mutations cannot be sent ahead of the initial
    // token while it is being fetched; resume once the token has been applied.
    await _invokePauseSocket();
    // A reauth of the replaced flow may have stopped the socket; bring it back
    // (it opens paused and defers its handshake to the resume below) instead
    // of waiting for that reauth's possibly slow fetch.
    if (_socketStoppedByReauth != null) {
      _socketStoppedByReauth = null;
      unawaited(_restartSocketSafely());
    }
    bool flowReplaced() =>
        flowId != _flowId || !identical(fetchToken, _fetchToken);
    var shouldResumeSocket = false;
    try {
      var token = await fetchToken(forceRefresh: false);
      var confirmationSource = _AuthConfirmationSource.cached;
      if (flowReplaced()) {
        // A newer auth flow superseded this one; it now owns the socket gating.
        return _StaleAuthHandle();
      }
      if (generation != _authGeneration) {
        // updateToken pushed a token into this flow while the fetch ran; it
        // already applied that newer token, so drop the fetched one but keep
        // the flow — and the caller's handle to it — alive.
        _log(
          DartvexLogLevel.debug,
          'Auth token pushed during the initial fetch; keeping the pushed token',
        );
        shouldResumeSocket = true;
        return _RefreshAuthHandle(this, flowId);
      }
      if (token == null) {
        _log(
          DartvexLogLevel.debug,
          'Cached auth token unavailable; forcing initial refresh',
        );
        token = await fetchToken(forceRefresh: true);
        confirmationSource = _AuthConfirmationSource.fresh;
        if (flowReplaced()) {
          return _StaleAuthHandle();
        }
        if (generation != _authGeneration) {
          _log(
            DartvexLogLevel.debug,
            'Auth token pushed during the initial refresh; keeping the pushed '
            'token',
          );
          shouldResumeSocket = true;
          return _RefreshAuthHandle(this, flowId);
        }
      }
      shouldResumeSocket = true;
      _currentToken = token;
      _expectConfirmationForToken(token, source: confirmationSource);
      if (token == null) {
        await _failAuthFlow();
      } else {
        await sendAuth(token);
      }
      return _RefreshAuthHandle(this, flowId);
    } catch (error, stackTrace) {
      if (flowReplaced()) {
        rethrow;
      }
      shouldResumeSocket = true;
      if (generation != _authGeneration) {
        // The flow is alive with a token pushed by updateToken; this failed
        // fetch is moot, so hand back the live flow's handle.
        _log(
          DartvexLogLevel.warn,
          'Initial auth token fetch failed after a token was pushed; keeping '
          'the pushed token',
          error: error,
          stackTrace: stackTrace,
        );
        return _RefreshAuthHandle(this, flowId);
      }
      _log(
        DartvexLogLevel.error,
        'Initial auth token fetch failed',
        error: error,
        stackTrace: stackTrace,
      );
      await _failAuthFlow();
      rethrow;
    } finally {
      if (shouldResumeSocket) {
        await _invokeResumeSocket();
      }
    }
  }

  /// Clears the current auth token and refresh flow.
  Future<void> clearAuth() async {
    _log(DartvexLogLevel.info, 'Auth cleared');
    _cancelRefreshTimer();
    _setRefreshing(false);
    final generation = ++_authGeneration;
    _flowId += 1;
    _fetchToken = null;
    _onAuthChange = null;
    _authChangeTrueDelivered = false;
    _currentToken = null;
    _clearPendingConfirmation();
    // Report the signed-out state as soon as the transport auth is cleared
    // (synchronously, by sendAuth's prefix), not after the flush: a newer auth
    // call made while the flush is pending must not be overwritten by it.
    final send = sendAuth(null);
    _publish(false);
    await send;
    await _releaseSocketForReplacedFlow(generation);
  }

  /// The most recently applied auth token, if any.
  ///
  /// This is the token the client sends to the server (it may still be awaiting
  /// confirmation). It changes on every refresh.
  String? get currentToken => _currentToken;

  /// Whether the backend currently considers the client authenticated.
  ///
  /// The latest value published through the auth state emitter: `true` once a
  /// token has been confirmed by the server, `false` after auth is cleared or
  /// fails.
  bool get isAuthenticated => _backendAuthenticated;

  /// Whether the manager is actively recovering auth after a server rejection.
  ///
  /// `true` from the moment a reauth begins (the socket is stopped while a fresh
  /// token is fetched) until that fresh token is confirmed by a server
  /// transition. Surfaced as a stream by `ConvexClient.authRefreshing`. Mirrors
  /// the semantics of the official client's `onRefreshChange`/`AuthRefreshing`.
  bool get isRefreshing => _isRefreshing;

  /// Updates the current auth token and reschedules refresh if needed.
  ///
  /// The token is treated as being of unknown age: once confirmed, its refresh
  /// is scheduled from its remaining lifetime as estimated against the
  /// server's clock (see [computeRefreshDelay]).
  Future<void> updateToken(String token) async {
    _log(DartvexLogLevel.info, 'Auth token updated');
    _cancelRefreshTimer();
    final generation = ++_authGeneration;
    _currentToken = token;
    _expectConfirmationForToken(
      token,
      source: _AuthConfirmationSource.pushed,
    );
    await sendAuth(token);
    await _releaseSocketForReplacedFlow(generation);
  }

  /// Marks the current auth token as confirmed by the backend.
  ///
  /// [clientClockSkew] is the confirming Transition's server-computed skew
  /// (`Connect.clientTs` minus the server's receive time, in milliseconds),
  /// used to estimate the server's current time when scheduling the refresh of
  /// a token whose age is unknown.
  void handleAuthConfirmed({double? clientClockSkew}) {
    if (!_awaitingConfirmation) {
      _log(
        DartvexLogLevel.debug,
        'Ignoring auth confirmation without a pending auth update',
      );
      return;
    }
    final isAuthenticated = _currentToken != null;
    _log(
      DartvexLogLevel.debug,
      isAuthenticated ? 'Auth confirmed' : 'Auth confirmed without token',
    );
    final shouldEmitAuthenticated = _emitAuthenticatedOnConfirmation;
    final confirmationSource = _pendingConfirmationSource;
    final fetchToken = _fetchToken;
    final generation = _authGeneration;
    _clearPendingConfirmation();
    // A confirming transition completes any in-progress reauth refresh.
    _setRefreshing(false);
    if (!isAuthenticated) {
      _emit(false);
      return;
    }
    if (shouldEmitAuthenticated) {
      _emit(true);
    } else {
      _backendAuthenticated = true;
      // Like the official client, report authentication to the flow once —
      // not again on every refresh confirmation within the same flow.
      final onAuthChange = _onAuthChange;
      if (onAuthChange != null && !_authChangeTrueDelivered) {
        _authChangeTrueDelivered = true;
        _invokeOnAuthChange(onAuthChange, true);
      }
    }
    // The listeners above may have replaced or cleared the flow re-entrantly
    // (e.g. a clearAuth() from an authState listener); only schedule follow-up
    // work for the flow that was confirmed.
    if (fetchToken == null || !_isCurrentFlow(generation, fetchToken)) {
      return;
    }
    final token = _currentToken;
    if (token == null) {
      return;
    }
    switch (confirmationSource) {
      case _AuthConfirmationSource.cached:
        if (config.initialAuthTokenReuse && clientClockSkew != null) {
          // Opt-in: reuse the confirmed cached token and refresh it before it
          // expires, judged against the server's clock, instead of fetching a
          // replacement right away (which makes the server re-run every
          // authenticated query).
          _scheduleRefresh(
            token,
            nowMillis: _estimatedServerNowMillis(clientClockSkew),
            remainingLifetimeOnly: true,
          );
        } else {
          unawaited(
            _refetchTokenAfterCachedConfirmation(generation, fetchToken),
          );
        }
      case _AuthConfirmationSource.fresh:
        // A freshly issued token's whole `exp - iat` lifetime lies ahead, so
        // no clock is consulted (as in the official client).
        _scheduleRefresh(token);
      case _AuthConfirmationSource.pushed:
        // A pushed token may be aged: bound the delay by its remaining
        // lifetime, judged against the server's clock when the server has
        // reported a skew, otherwise against the device clock with a floor.
        _scheduleRefresh(
          token,
          nowMillis: clientClockSkew == null
              ? DateTime.now().millisecondsSinceEpoch
              : _estimatedServerNowMillis(clientClockSkew),
          minimumDelayMs:
              clientClockSkew == null ? _minimumPushedRefreshDelayMs : 0,
        );
      case _AuthConfirmationSource.none:
      case _AuthConfirmationSource.fixed:
        break;
    }
  }

  /// Handles an [AuthError] reported by the backend.
  Future<void> handleAuthError(
    AuthError error, {
    required int currentAuthVersion,
  }) async {
    _log(
      DartvexLogLevel.warn,
      'Auth error received from backend',
      data: <String, Object?>{
        'error': error.error,
        'authUpdateAttempted': error.authUpdateAttempted,
        'baseVersion': error.baseVersion,
        'currentAuthVersion': currentAuthVersion,
      },
    );
    if (error.authUpdateAttempted == false && _awaitingConfirmation) {
      _log(
        DartvexLogLevel.debug,
        'Ignoring auth error unrelated to current auth update',
      );
      return;
    }
    // Versioned AuthErrors report the previous version (the server did not
    // advance), hence the `+ 1`. This is the AuthError counterpart of
    // LocalSyncState.isCurrentOrNewerAuthVersion (which guards the Transition
    // path): ignore the error if the client already moved to a newer auth.
    if (error.baseVersion + 1 < currentAuthVersion) {
      _log(DartvexLogLevel.debug, 'Ignoring stale auth error');
      return;
    }
    final fetchToken = _fetchToken;
    if (fetchToken == null) {
      _logAuthRejected(error);
      await _failAuthFlow();
      return;
    }
    // Mirror the official client: only a rejected *fresh* token counts toward
    // the give-up budget (official tracks this in the
    // `waitingForServerConfirmationOfFreshToken` state). A rejected cached token
    // — or an error arriving outside a pending fresh confirmation — is "free":
    // it transitions to a fresh fetch without consuming a retry, so a single
    // cached-token rejection never shortens the fresh-token retry budget. The
    // budget therefore stays bounded (each fresh rejection increments; the
    // counter only reaches the cap via fresh rejections), with no infinite loop.
    final isFreshConfirmation =
        _pendingConfirmationSource == _AuthConfirmationSource.fresh ||
            _pendingConfirmationSource == _AuthConfirmationSource.pushed;
    if (isFreshConfirmation &&
        _tokenConfirmationAttempts >= _maxTokenConfirmationAttempts) {
      _logAuthRejected(error);
      await _failAuthFlow();
      return;
    }
    if (isFreshConfirmation) {
      _tokenConfirmationAttempts += 1;
    }

    final generation = _authGeneration;
    // The token the server rejected: the reauth fails only if the refresh
    // cannot produce a different one. Compared against this snapshot rather
    // than against whatever is current when the fetch returns, because a
    // concurrent forced fetch may legitimately have applied the same fresh
    // token in the meantime.
    final rejectedToken = _currentToken;
    // The scheduled refresh would race the reauth's own forced fetch.
    _cancelRefreshTimer();
    // Stop the socket so in-flight messages cannot retry with the stale token,
    // fetch a fresh one, then restart so it is replayed on a clean connection.
    _setRefreshing(true);
    final stopOwner = Object();
    _socketStoppedByReauth = stopOwner;
    try {
      await _invokeStopSocket();
    } catch (error, stackTrace) {
      _log(
        DartvexLogLevel.error,
        'Failed to stop socket for auth refresh',
        error: error,
        stackTrace: stackTrace,
      );
    }
    try {
      final freshToken = await _fetchTokenForReauth(fetchToken, generation);
      if (_isCurrentFlow(generation, fetchToken)) {
        if (freshToken == null || freshToken == rejectedToken) {
          _log(
            DartvexLogLevel.warn,
            freshToken == null
                ? 'Forced auth refresh returned no token'
                : 'Forced auth refresh returned the rejected token',
          );
          // The refresh could not produce a usable token; the reauth is over.
          _logAuthRejected(error);
          await _failAuthFlow();
        } else if (freshToken == _currentToken) {
          // A concurrent forced fetch already applied this fresh token and is
          // awaiting its confirmation; nothing more to send.
          _log(
            DartvexLogLevel.debug,
            'Forced auth refresh returned the token a concurrent refresh '
            'already applied',
          );
        } else {
          _currentToken = freshToken;
          _expectConfirmationForToken(
            freshToken,
            resetAttempts: false,
            source: _AuthConfirmationSource.fresh,
          );
          await sendAuth(freshToken);
        }
      }
    } catch (fetchError, stackTrace) {
      if (_isCurrentFlow(generation, fetchToken)) {
        _log(
          DartvexLogLevel.error,
          'Forced auth refresh failed',
          error: fetchError,
          stackTrace: stackTrace,
        );
        _logAuthRejected(error);
        await _failAuthFlow();
      }
    } finally {
      // Restart unless an entry point that superseded this reauth already did
      // (and a newer reauth may own the stop now). The restart replays
      // whatever auth local state currently holds.
      if (identical(_socketStoppedByReauth, stopOwner)) {
        _socketStoppedByReauth = null;
        await _restartSocketSafely();
      }
    }
  }

  /// Fetches a fresh token for a reauth, retrying a throwing fetch per
  /// [_reauthFetchRetryDelays] while the flow stays current.
  ///
  /// Returns `null` without calling [fetchToken] once the flow was superseded
  /// (e.g. by a logout while the socket stop was still closing): the provider's
  /// refresh hook must not run for a session the app already ended. The caller
  /// ignores the result of a superseded flow.
  Future<String?> _fetchTokenForReauth(
    AuthTokenFetcher fetchToken,
    int generation,
  ) async {
    var attempt = 0;
    while (true) {
      if (!_isCurrentFlow(generation, fetchToken)) {
        _log(
          DartvexLogLevel.debug,
          'Auth refresh superseded before its token fetch; skipping it',
        );
        return null;
      }
      // Invalidate any concurrent scheduled refresh or post-confirmation
      // refetch: the reauth's result is the one to apply.
      ++_tokenFetchSequence;
      try {
        return await fetchToken(forceRefresh: true);
      } catch (error, stackTrace) {
        if (attempt >= _reauthFetchRetryDelays.length ||
            !_isCurrentFlow(generation, fetchToken)) {
          rethrow;
        }
        final delay = _reauthFetchRetryDelays[attempt];
        attempt += 1;
        _log(
          DartvexLogLevel.warn,
          'Forced auth refresh failed; retrying',
          error: error,
          stackTrace: stackTrace,
          data: <String, Object?>{
            'attempt': attempt,
            'delayMs': delay.inMilliseconds,
          },
        );
        await Future<void>.delayed(delay);
        if (!_isCurrentFlow(generation, fetchToken)) {
          rethrow;
        }
      }
    }
  }

  void _logAuthRejected(AuthError error) {
    _log(
      DartvexLogLevel.error,
      'Failed to authenticate: "${error.error}", check your server auth config',
      data: <String, Object?>{'error': error.error},
    );
  }

  /// Stops any active refresh flow without changing the current token.
  Future<void> stopRefreshing() async {
    _log(DartvexLogLevel.debug, 'Stopping auth refresh flow');
    final generation = ++_authGeneration;
    _flowId += 1;
    _fetchToken = null;
    _onAuthChange = null;
    _authChangeTrueDelivered = false;
    _clearPendingConfirmation();
    _cancelRefreshTimer();
    _setRefreshing(false);
    await _releaseSocketForReplacedFlow(generation);
  }

  /// Releases socket gating that the auth flow this caller just replaced may
  /// have left behind.
  ///
  /// [setAuthWithRefresh] pauses the socket for its initial token fetch and
  /// deliberately skips its own resume when superseded mid-fetch — from that
  /// moment the superseder owns the socket gating. Likewise a reauth stops the
  /// socket and only restarts it once its token fetch returns. A superseding
  /// [setAuthWithRefresh] handles both itself, but the other entry points
  /// ([setAuth], [clearAuth], [updateToken], [stopRefreshing]) must restart a
  /// socket stopped by a replaced reauth and release an inherited pause, or the
  /// connection would stay down (until a possibly hanging fetch returns) or
  /// buffer its handshake and queries forever. Guarded by [generation]: when
  /// an even newer flow has started by the time the caller gets here, that
  /// flow owns the gating and nothing is released. Resuming an unpaused socket
  /// is a no-op.
  Future<void> _releaseSocketForReplacedFlow(int generation) async {
    if (generation != _authGeneration) {
      return;
    }
    if (_socketStoppedByReauth != null) {
      _socketStoppedByReauth = null;
      await _restartSocketSafely();
      if (generation != _authGeneration) {
        return;
      }
    }
    await _invokeResumeSocket();
  }

  Future<void> _restartSocketSafely() async {
    try {
      await _invokeRestartSocket();
    } catch (error, stackTrace) {
      _log(
        DartvexLogLevel.error,
        'Failed to restart socket after auth refresh',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Computes when to proactively refresh a token.
  ///
  /// The delay is the token's lifetime ahead minus [leewaySeconds], capped at
  /// the official 20-day maximum and clamped to zero (refresh immediately) when
  /// the leeway meets or exceeds it. Returns `null` (do not schedule) when `iat`
  /// is absent (the lifetime is unknown) or the token lives `<= 2s`.
  ///
  /// What "lifetime ahead" means depends on the token's provenance:
  ///
  /// * [nowMillis] `null` — a freshly issued token: its full `exp - iat`
  ///   lifetime, with no clock consulted (official client behavior). A device
  ///   clock that runs fast or slow therefore cannot shift the schedule.
  /// * [nowMillis] set — a token of unknown age: the full lifetime, bounded by
  ///   the remaining lifetime `exp - nowMillis`, so an aged token cannot
  ///   schedule its refresh after it expires. Pass the server's estimated time
  ///   (the monotonic client clock minus a Transition's `clientClockSkew`)
  ///   when available.
  /// * [remainingLifetimeOnly] — a reused cached token: the remaining lifetime
  ///   `exp - nowMillis` alone (official `initialAuthTokenReuse` behavior).
  ///
  /// [minimumDelayMs] floors the result (never above the full-lifetime delay).
  @visibleForTesting
  static Duration? computeRefreshDelay({
    required int? iat,
    required int exp,
    required int leewaySeconds,
    int? nowMillis,
    bool remainingLifetimeOnly = false,
    int minimumDelayMs = 0,
  }) {
    if (iat == null) {
      return null;
    }
    final tokenValiditySeconds = exp - iat;
    if (tokenValiditySeconds <= _minimumTokenValiditySeconds) {
      return null;
    }
    final lifetimeDelayMs = (tokenValiditySeconds - leewaySeconds) * 1000;
    var delayMs = lifetimeDelayMs;
    if (nowMillis != null) {
      final remainingDelayMs = exp * 1000 - nowMillis - leewaySeconds * 1000;
      if (remainingLifetimeOnly || remainingDelayMs < delayMs) {
        delayMs = remainingDelayMs;
      }
    }
    final floorMs = math.min(minimumDelayMs, math.max(lifetimeDelayMs, 0));
    if (delayMs < floorMs) {
      delayMs = floorMs;
    }
    if (delayMs < 0) {
      delayMs = 0;
    }
    if (delayMs > _maximumRefreshDelayMs) {
      delayMs = _maximumRefreshDelayMs;
    }
    return Duration(milliseconds: delayMs);
  }

  int _estimatedServerNowMillis(double clientClockSkew) {
    final clientNow =
        _clientNowMillis?.call() ?? DateTime.now().millisecondsSinceEpoch;
    return (clientNow - clientClockSkew).round();
  }

  void _scheduleRefresh(
    String token, {
    int? nowMillis,
    bool remainingLifetimeOnly = false,
    int minimumDelayMs = 0,
  }) {
    _cancelRefreshTimer();
    final generation = _authGeneration;
    int? exp;
    int? iat;
    try {
      exp = jwtExp(token);
      iat = jwtIat(token);
    } on FormatException {
      _log(
        DartvexLogLevel.warn,
        'Skipping auth refresh scheduling because token timestamps are invalid',
      );
      return;
    }
    if (exp == null) {
      _log(
        DartvexLogLevel.warn,
        'Skipping auth refresh scheduling because token expiration is missing',
      );
      return;
    }
    final refreshDelay = computeRefreshDelay(
      iat: iat,
      exp: exp,
      leewaySeconds: config.refreshTokenLeewaySeconds,
      nowMillis: nowMillis,
      remainingLifetimeOnly: remainingLifetimeOnly,
      minimumDelayMs: minimumDelayMs,
    );
    if (refreshDelay == null) {
      _log(
        DartvexLogLevel.warn,
        'Skipping auth refresh scheduling because the token does not live '
        'long enough to refresh',
      );
      return;
    }
    _log(
      DartvexLogLevel.debug,
      'Auth refresh scheduled',
      data: <String, Object?>{'delayMs': refreshDelay.inMilliseconds},
    );
    _refreshTimer = Timer(refreshDelay, () async {
      final fetchToken = _fetchToken;
      if (fetchToken == null || !_isCurrentFlow(generation, fetchToken)) {
        return;
      }
      final sequence = ++_tokenFetchSequence;
      try {
        final freshToken = await fetchToken(forceRefresh: true);
        if (!_isCurrentFlow(generation, fetchToken) ||
            sequence != _tokenFetchSequence) {
          return;
        }
        if (freshToken == null) {
          _log(
            DartvexLogLevel.warn,
            'Scheduled auth refresh returned no token',
          );
          await _failAuthFlow();
        } else if (_isNewAuth(freshToken)) {
          _currentToken = freshToken;
          _expectConfirmationForToken(
            freshToken,
            source: _AuthConfirmationSource.fresh,
          );
          await sendAuth(freshToken);
          _log(DartvexLogLevel.debug, 'Scheduled auth refresh succeeded');
        } else {
          _log(
            DartvexLogLevel.debug,
            'Scheduled auth refresh returned the current token',
          );
        }
      } catch (error, stackTrace) {
        if (!_isCurrentFlow(generation, fetchToken)) {
          return;
        }
        _log(
          DartvexLogLevel.error,
          'Scheduled auth refresh failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
    });
  }

  bool _isCurrentFlow(int generation, AuthTokenFetcher fetchToken) {
    return generation == _authGeneration && identical(fetchToken, _fetchToken);
  }

  bool _isNewAuth(String token) => _currentToken != token;

  Future<void> _refetchTokenAfterCachedConfirmation(
    int generation,
    AuthTokenFetcher fetchToken,
  ) async {
    final sequence = ++_tokenFetchSequence;
    try {
      final freshToken = await fetchToken(forceRefresh: true);
      if (!_isCurrentFlow(generation, fetchToken) ||
          sequence != _tokenFetchSequence) {
        return;
      }
      if (freshToken == null) {
        _log(
          DartvexLogLevel.warn,
          'Cached auth confirmation refresh returned no token',
        );
        await _failAuthFlow();
        return;
      }
      if (!_isNewAuth(freshToken)) {
        _log(
          DartvexLogLevel.debug,
          'Cached auth confirmation refresh returned the current token',
        );
        return;
      }
      _currentToken = freshToken;
      _expectConfirmationForToken(
        freshToken,
        source: _AuthConfirmationSource.fresh,
      );
      await sendAuth(freshToken);
    } catch (error, stackTrace) {
      if (!_isCurrentFlow(generation, fetchToken)) {
        return;
      }
      _log(
        DartvexLogLevel.error,
        'Cached auth confirmation refresh failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _clearFailedAuthFlow() {
    _cancelRefreshTimer();
    _fetchToken = null;
    _onAuthChange = null;
    _authChangeTrueDelivered = false;
    _currentToken = null;
    _clearPendingConfirmation();
    _setRefreshing(false);
  }

  /// Ends a failed refresh flow: clears it and the transport auth, then reports
  /// the client as unauthenticated.
  ///
  /// The transport auth is cleared (by sendAuth's synchronous prefix) *before*
  /// listeners run, as in the official client, so a listener that installs new
  /// auth (say, a guest token) is not overwritten afterwards, and a throwing
  /// listener cannot skip the clear.
  Future<void> _failAuthFlow() async {
    final onAuthChange = _onAuthChange;
    _clearFailedAuthFlow();
    final send = sendAuth(null);
    _publish(false, onAuthChange: onAuthChange);
    await send;
  }

  void _expectConfirmationForToken(
    String? token, {
    bool resetAttempts = true,
    _AuthConfirmationSource source = _AuthConfirmationSource.fixed,
  }) {
    _awaitingConfirmation = token != null;
    _pendingConfirmationSource =
        token == null ? _AuthConfirmationSource.none : source;
    if (resetAttempts) {
      _tokenConfirmationAttempts = 0;
    }
    _emitAuthenticatedOnConfirmation = token != null && !_backendAuthenticated;
  }

  void _clearPendingConfirmation() {
    _awaitingConfirmation = false;
    _tokenConfirmationAttempts = 0;
    _emitAuthenticatedOnConfirmation = false;
    _pendingConfirmationSource = _AuthConfirmationSource.none;
  }

  Future<void> _invokePauseSocket() async {
    final pause = _pauseSocket;
    if (pause != null) {
      await pause();
    }
  }

  Future<void> _invokeResumeSocket() async {
    final resume = _resumeSocket;
    if (resume != null) {
      await resume();
    }
  }

  Future<void> _invokeStopSocket() async {
    final stop = _stopSocket;
    if (stop != null) {
      await stop();
    }
  }

  Future<void> _invokeRestartSocket() async {
    final restart = _restartSocket;
    if (restart != null) {
      await restart();
    }
  }

  void _emit(bool isAuthenticated) {
    _publish(isAuthenticated, onAuthChange: _onAuthChange);
  }

  /// Records and reports the backend auth state.
  ///
  /// Listener exceptions are logged and contained: they run inside auth state
  /// transitions and server message handling, which must complete regardless.
  void _publish(bool isAuthenticated, {void Function(bool)? onAuthChange}) {
    _backendAuthenticated = isAuthenticated;
    try {
      emitAuthState(isAuthenticated);
    } catch (error, stackTrace) {
      _log(
        DartvexLogLevel.error,
        'Auth state listener threw',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (onAuthChange != null) {
      if (identical(onAuthChange, _onAuthChange)) {
        _authChangeTrueDelivered = isAuthenticated;
      }
      _invokeOnAuthChange(onAuthChange, isAuthenticated);
    }
  }

  void _invokeOnAuthChange(void Function(bool) onAuthChange, bool value) {
    try {
      onAuthChange(value);
    } catch (error, stackTrace) {
      _log(
        DartvexLogLevel.error,
        'onAuthChange callback threw',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _setRefreshing(bool value) {
    if (_isRefreshing == value) {
      return;
    }
    _isRefreshing = value;
    _onRefreshingChange?.call(value);
  }

  void _cancelRefreshTimer() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
  }

  void _log(
    DartvexLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) {
    emitDartvexLog(
      configuredLevel: config.logLevel,
      logger: config.logger,
      eventLevel: level,
      message: message,
      tag: 'auth',
      error: error,
      stackTrace: stackTrace,
      data: data,
    );
  }
}

class _RefreshAuthHandle implements AuthHandle {
  _RefreshAuthHandle(this._manager, this._flowId);

  final AuthManager _manager;
  final int _flowId;

  @override
  Future<void> cancel() {
    // A handle from a replaced flow must not tear down its successor, so the
    // handle binds to the flow id — which, unlike the auth generation, is NOT
    // advanced by updateToken: a token pushed into a live flow keeps the
    // caller's handle cancellable instead of silently orphaning it (leaving
    // the scheduled refresh running after, say, a wrapper dispose).
    if (_manager._flowId != _flowId) {
      return Future<void>.value();
    }
    return _manager.stopRefreshing();
  }
}

class _StaleAuthHandle implements AuthHandle {
  @override
  Future<void> cancel() async {}
}
