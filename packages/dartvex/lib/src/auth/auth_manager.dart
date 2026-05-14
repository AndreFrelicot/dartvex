import 'dart:async';

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
  AuthManager({
    required this.config,
    required this.sendAuth,
    required this.emitAuthState,
  });

  /// Client configuration used for logging and token metadata.
  final ConvexClientConfig config;

  /// Callback that forwards auth token updates to Convex.
  final SendAuthCallback sendAuth;

  /// Callback that publishes public auth state changes.
  final AuthStateEmitter emitAuthState;

  AuthTokenFetcher? _fetchToken;
  void Function(bool)? _onAuthChange;
  Timer? _refreshTimer;
  String? _currentToken;
  int _authGeneration = 0;
  int _tokenConfirmationAttempts = 0;
  bool _awaitingConfirmation = false;

  static const int _maxTokenConfirmationAttempts = 3;

  /// Sets a fixed auth [token] without a refresh callback.
  Future<void> setAuth(String? token) async {
    _log(
      DartvexLogLevel.info,
      token == null ? 'Auth cleared via setAuth' : 'Auth token set',
    );
    _cancelRefreshTimer();
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
    final token = await fetchToken(forceRefresh: false);
    if (!_isCurrentFlow(generation, fetchToken)) {
      return _StaleAuthHandle();
    }
    _currentToken = token;
    _awaitingConfirmation = token != null;
    _tokenConfirmationAttempts = 0;
    await sendAuth(token);
    if (token == null) {
      _emit(false);
    }
    return _RefreshAuthHandle(this);
  }

  /// Clears the current auth token and refresh flow.
  Future<void> clearAuth() async {
    _log(DartvexLogLevel.info, 'Auth cleared');
    _cancelRefreshTimer();
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
    if (error.baseVersion + 1 < currentAuthVersion) {
      _log(DartvexLogLevel.debug, 'Ignoring stale auth error');
      return;
    }
    final fetchToken = _fetchToken;
    if (fetchToken == null) {
      _currentToken = null;
      _awaitingConfirmation = false;
      _tokenConfirmationAttempts = 0;
      _emit(false);
      await sendAuth(null);
      return;
    }
    if (_awaitingConfirmation &&
        _tokenConfirmationAttempts >= _maxTokenConfirmationAttempts) {
      _log(DartvexLogLevel.error, 'Auth confirmation retries exhausted');
      _currentToken = null;
      _awaitingConfirmation = false;
      _emit(false);
      await sendAuth(null);
      return;
    }
    if (_awaitingConfirmation) {
      _tokenConfirmationAttempts += 1;
    }

    final generation = _authGeneration;
    final freshToken = await fetchToken(forceRefresh: true);
    if (!_isCurrentFlow(generation, fetchToken)) {
      return;
    }
    _currentToken = freshToken;
    _awaitingConfirmation = freshToken != null;
    await sendAuth(freshToken);
    if (freshToken == null) {
      _log(DartvexLogLevel.warn, 'Forced auth refresh returned no token');
      _emit(false);
    }
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
    if (exp == null || iat == null) {
      _log(
        DartvexLogLevel.warn,
        'Skipping auth refresh scheduling because token timestamps are missing',
      );
      return;
    }
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final secondsUntilRefresh = exp - nowSeconds - 60;
    final refreshDelay = Duration(
      seconds: secondsUntilRefresh > 0 ? secondsUntilRefresh : 0,
    );
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

  void _emit(bool isAuthenticated) {
    emitAuthState(isAuthenticated);
    _onAuthChange?.call(isAuthenticated);
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
