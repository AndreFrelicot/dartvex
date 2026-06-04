import 'dart:async';

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
typedef SendAuthCallback = Future<void> Function(String? token);

/// Emits whether the backend currently considers the client authenticated.
typedef AuthStateEmitter = void Function(bool isAuthenticated);

/// Fetches an auth token, optionally forcing a refresh.
typedef AuthTokenFetcher = Future<String?> Function(
    {required bool forceRefresh});

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
  AuthManager({
    required this.config,
    required this.sendAuth,
    required this.emitAuthState,
    Future<void> Function()? pauseSocket,
    Future<void> Function()? resumeSocket,
    Future<void> Function()? stopSocket,
    Future<void> Function()? restartSocket,
    void Function(bool isRefreshing)? onRefreshingChange,
  })  : _pauseSocket = pauseSocket,
        _resumeSocket = resumeSocket,
        _stopSocket = stopSocket,
        _restartSocket = restartSocket,
        _onRefreshingChange = onRefreshingChange;

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

  bool _isRefreshing = false;

  AuthTokenFetcher? _fetchToken;
  void Function(bool)? _onAuthChange;
  Timer? _refreshTimer;
  String? _currentToken;
  int _authGeneration = 0;
  int _tokenConfirmationAttempts = 0;
  bool _awaitingConfirmation = false;

  static const int _maxTokenConfirmationAttempts = 3;

  /// Upper bound on the refresh delay, mirroring the official client's 20-day
  /// cap (`setTimeout` uses a 32-bit integer and overflows beyond ~24 days).
  static const int _maximumRefreshDelayMs = 20 * 24 * 60 * 60 * 1000;

  /// Minimum token lifetime (`exp - iat`) required to schedule a refresh. A
  /// token that lives this briefly is treated as not worth refreshing.
  static const int _minimumTokenValiditySeconds = 2;

  /// Sets a fixed auth [token] without a refresh callback.
  Future<void> setAuth(String? token) async {
    _log(
      DartvexLogLevel.info,
      token == null ? 'Auth cleared via setAuth' : 'Auth token set',
    );
    _cancelRefreshTimer();
    _setRefreshing(false);
    _authGeneration += 1;
    _fetchToken = null;
    _onAuthChange = null;
    _currentToken = token;
    _awaitingConfirmation = token != null;
    _tokenConfirmationAttempts = 0;
    await sendAuth(token);
    if (token == null) {
      _emit(false);
    }
  }

  /// Configures an auth refresh flow driven by [fetchToken].
  Future<AuthHandle> setAuthWithRefresh({
    required AuthTokenFetcher fetchToken,
    void Function(bool)? onAuthChange,
  }) async {
    _log(DartvexLogLevel.debug, 'Configuring auth refresh flow');
    _cancelRefreshTimer();
    final generation = ++_authGeneration;
    _fetchToken = fetchToken;
    _onAuthChange = onAuthChange;
    // Pause the socket so queries/mutations cannot be sent ahead of the initial
    // token while it is being fetched; resume once the token has been applied.
    await _invokePauseSocket();
    final token = await fetchToken(forceRefresh: false);
    if (!_isCurrentFlow(generation, fetchToken)) {
      // A newer auth flow superseded this one; it now owns the socket gating.
      return _StaleAuthHandle();
    }
    _currentToken = token;
    _awaitingConfirmation = token != null;
    _tokenConfirmationAttempts = 0;
    await sendAuth(token);
    if (token == null) {
      _emit(false);
    }
    await _invokeResumeSocket();
    return _RefreshAuthHandle(this);
  }

  /// Clears the current auth token and refresh flow.
  Future<void> clearAuth() async {
    _log(DartvexLogLevel.info, 'Auth cleared');
    _cancelRefreshTimer();
    _setRefreshing(false);
    _authGeneration += 1;
    _fetchToken = null;
    _onAuthChange = null;
    _currentToken = null;
    _awaitingConfirmation = false;
    _tokenConfirmationAttempts = 0;
    await sendAuth(null);
    _emit(false);
  }

  /// Refreshes auth before replaying subscriptions after reconnect.
  Future<void> refreshAuthForReconnect() async {
    final fetchToken = _fetchToken;
    if (fetchToken == null) {
      return;
    }
    _log(DartvexLogLevel.debug, 'Refreshing auth token for reconnect');
    final generation = _authGeneration;
    final freshToken = await fetchToken(forceRefresh: true);
    if (!_isCurrentFlow(generation, fetchToken)) {
      return;
    }
    _currentToken = freshToken;
    _awaitingConfirmation = freshToken != null;
    _tokenConfirmationAttempts = 0;
    if (freshToken == null) {
      _log(DartvexLogLevel.warn, 'Reconnect auth refresh returned no token');
      _emit(false);
    }
  }

  /// The most recently applied auth token, if any.
  String? get currentToken => _currentToken;

  /// Whether the manager is actively recovering auth after a server rejection.
  ///
  /// `true` from the moment a reauth begins (the socket is stopped while a fresh
  /// token is fetched) until that fresh token is confirmed by a server
  /// transition. Surfaced as a stream by `ConvexClient.authRefreshing`. Mirrors
  /// the semantics of the official client's `onRefreshChange`/`AuthRefreshing`.
  bool get isRefreshing => _isRefreshing;

  /// Updates the current auth token and reschedules refresh if needed.
  Future<void> updateToken(String token) async {
    _log(DartvexLogLevel.info, 'Auth token updated');
    _cancelRefreshTimer();
    _authGeneration += 1;
    _currentToken = token;
    _awaitingConfirmation = true;
    _tokenConfirmationAttempts = 0;
    await sendAuth(token);
  }

  /// Marks the current auth token as confirmed by the backend.
  void handleAuthConfirmed() {
    final isAuthenticated = _currentToken != null;
    _log(
      DartvexLogLevel.debug,
      isAuthenticated ? 'Auth confirmed' : 'Auth confirmed without token',
    );
    _awaitingConfirmation = false;
    _tokenConfirmationAttempts = 0;
    // A confirming transition completes any in-progress reauth refresh.
    _setRefreshing(false);
    _emit(isAuthenticated);
    if (isAuthenticated && _fetchToken != null) {
      _scheduleRefresh(_currentToken!);
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
      _currentToken = null;
      _awaitingConfirmation = false;
      _tokenConfirmationAttempts = 0;
      _setRefreshing(false);
      _emit(false);
      await sendAuth(null);
      return;
    }
    if (_awaitingConfirmation &&
        _tokenConfirmationAttempts >= _maxTokenConfirmationAttempts) {
      _log(DartvexLogLevel.error, 'Auth confirmation retries exhausted');
      _currentToken = null;
      _awaitingConfirmation = false;
      _setRefreshing(false);
      _emit(false);
      await sendAuth(null);
      return;
    }
    if (_awaitingConfirmation) {
      _tokenConfirmationAttempts += 1;
    }

    final generation = _authGeneration;
    // Stop the socket so in-flight messages cannot retry with the stale token,
    // fetch a fresh one, then restart so it is replayed on a clean connection.
    _setRefreshing(true);
    await _invokeStopSocket();
    final freshToken = await fetchToken(forceRefresh: true);
    if (_isCurrentFlow(generation, fetchToken)) {
      _currentToken = freshToken;
      _awaitingConfirmation = freshToken != null;
      await sendAuth(freshToken);
      if (freshToken == null) {
        _log(DartvexLogLevel.warn, 'Forced auth refresh returned no token');
        // The refresh could not produce a token; the reauth is over.
        _setRefreshing(false);
        _emit(false);
      }
    }
    // Always restart, even on a superseded flow, so the socket is never left
    // stopped; the restart replays whatever auth local state currently holds.
    await _invokeRestartSocket();
  }

  /// Stops any active refresh flow without changing the current token.
  Future<void> stopRefreshing() async {
    _log(DartvexLogLevel.debug, 'Stopping auth refresh flow');
    _authGeneration += 1;
    _fetchToken = null;
    _onAuthChange = null;
    _awaitingConfirmation = false;
    _tokenConfirmationAttempts = 0;
    _cancelRefreshTimer();
    _setRefreshing(false);
  }

  /// Computes when to proactively refresh a token, immune to device clock skew.
  ///
  /// When the token carries an `iat` claim the delay is derived from the
  /// token's own lifetime (`exp - iat`) minus [leewaySeconds] — the wall clock
  /// is never consulted, so a skewed device clock cannot mis-schedule the
  /// refresh. The result is capped at the official 20-day maximum, clamped to
  /// zero (refresh immediately) when the leeway meets or exceeds the lifetime,
  /// and `null` (do not schedule) for tokens that live `<= 2s`.
  ///
  /// When `iat` is absent the lifetime is unknown, so the computation falls
  /// back to the wall clock (`exp - now - leewaySeconds`); this is the only
  /// clock-dependent path and is used solely for tokens that omit `iat`.
  /// [now] overrides the wall clock for testing.
  @visibleForTesting
  static Duration? computeRefreshDelay({
    required int? iat,
    required int exp,
    required int leewaySeconds,
    DateTime? now,
  }) {
    if (iat != null) {
      final tokenValiditySeconds = exp - iat;
      if (tokenValiditySeconds <= _minimumTokenValiditySeconds) {
        return null;
      }
      var delayMs = (tokenValiditySeconds - leewaySeconds) * 1000;
      if (delayMs < 0) {
        delayMs = 0;
      }
      if (delayMs > _maximumRefreshDelayMs) {
        delayMs = _maximumRefreshDelayMs;
      }
      return Duration(milliseconds: delayMs);
    }
    final nowSeconds = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    var delaySeconds = exp - nowSeconds - leewaySeconds;
    if (delaySeconds < 0) {
      delaySeconds = 0;
    }
    var delayMs = delaySeconds * 1000;
    if (delayMs > _maximumRefreshDelayMs) {
      delayMs = _maximumRefreshDelayMs;
    }
    return Duration(milliseconds: delayMs);
  }

  void _scheduleRefresh(String token) {
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
      if (fetchToken == null) {
        return;
      }
      try {
        final freshToken = await fetchToken(forceRefresh: true);
        if (!_isCurrentFlow(generation, fetchToken)) {
          return;
        }
        _currentToken = freshToken;
        _awaitingConfirmation = freshToken != null;
        await sendAuth(freshToken);
        if (freshToken == null) {
          _log(
            DartvexLogLevel.warn,
            'Scheduled auth refresh returned no token',
          );
          _emit(false);
        } else {
          _log(DartvexLogLevel.debug, 'Scheduled auth refresh succeeded');
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
    emitAuthState(isAuthenticated);
    _onAuthChange?.call(isAuthenticated);
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
  _RefreshAuthHandle(this._manager);

  final AuthManager _manager;

  @override
  Future<void> cancel() {
    return _manager.stopRefreshing();
  }
}

class _StaleAuthHandle implements AuthHandle {
  @override
  Future<void> cancel() async {}
}
