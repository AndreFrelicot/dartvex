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

  /// Sets a fixed auth [token] without a refresh callback.
  Future<void> setAuth(String? token) async {
    _log(
      DartvexLogLevel.info,
      token == null ? 'Auth cleared via setAuth' : 'Auth token set',
    );
    _cancelRefreshTimer();
    _fetchToken = null;
    _onAuthChange = null;
    _currentToken = token;
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
    _fetchToken = fetchToken;
    _onAuthChange = onAuthChange;
    final token = await fetchToken(forceRefresh: false);
    _currentToken = token;
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
    _fetchToken = null;
    _onAuthChange = null;
    _currentToken = null;
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
    final freshToken = await fetchToken(forceRefresh: true);
    _currentToken = freshToken;
    if (freshToken == null) {
      _log(DartvexLogLevel.warn, 'Reconnect auth refresh returned no token');
      _emit(false);
      return;
    }
    _scheduleRefresh(freshToken);
  }

  /// The most recently applied auth token, if any.
  String? get currentToken => _currentToken;

  /// Updates the current auth token and reschedules refresh if needed.
  Future<void> updateToken(String token) async {
    _log(DartvexLogLevel.info, 'Auth token updated');
    _currentToken = token;
    await sendAuth(token);
    if (_fetchToken != null) {
      _scheduleRefresh(token);
    }
  }

  /// Marks the current auth token as confirmed by the backend.
  void handleAuthConfirmed() {
    final isAuthenticated = _currentToken != null;
    _log(
      DartvexLogLevel.debug,
      isAuthenticated ? 'Auth confirmed' : 'Auth confirmed without token',
    );
    _emit(isAuthenticated);
    if (isAuthenticated && _fetchToken != null) {
      _scheduleRefresh(_currentToken!);
    }
  }

  /// Handles an [AuthError] reported by the backend.
  Future<void> handleAuthError(AuthError error) async {
    _log(
      DartvexLogLevel.warn,
      'Auth error received from backend',
      data: <String, Object?>{
        'authUpdateAttempted': error.authUpdateAttempted,
      },
    );
    final fetchToken = _fetchToken;
    if (fetchToken == null) {
      _currentToken = null;
      _emit(false);
      await sendAuth(null);
      return;
    }

    final freshToken = await fetchToken(forceRefresh: true);
    _currentToken = freshToken;
    await sendAuth(freshToken);
    if (freshToken == null) {
      _log(DartvexLogLevel.warn, 'Forced auth refresh returned no token');
      _emit(false);
      return;
    }

    if (error.authUpdateAttempted == true) {
      _scheduleRefresh(freshToken);
    }
  }

  /// Stops any active refresh flow without changing the current token.
  Future<void> stopRefreshing() async {
    _log(DartvexLogLevel.debug, 'Stopping auth refresh flow');
    _fetchToken = null;
    _onAuthChange = null;
    _cancelRefreshTimer();
  }

  void _scheduleRefresh(String token) {
    _cancelRefreshTimer();
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
    final lifetimeSeconds = exp - iat;
    final refreshDelay = Duration(
      seconds: lifetimeSeconds > 60 ? lifetimeSeconds - 60 : 0,
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
      final freshToken = await fetchToken(forceRefresh: false);
      _currentToken = freshToken;
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
    });
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
    Map<String, Object?>? data,
  }) {
    emitDartvexLog(
      configuredLevel: config.logLevel,
      logger: config.logger,
      eventLevel: level,
      message: message,
      tag: 'auth',
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
