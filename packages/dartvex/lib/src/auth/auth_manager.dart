import 'dart:async';

import '../config.dart';
import '../protocol/messages.dart';
import 'jwt_utils.dart';

abstract interface class AuthHandle {
  Future<void> cancel();
}

typedef SendAuthCallback = Future<void> Function(String? token);
typedef AuthStateEmitter = void Function(bool isAuthenticated);
typedef AuthTokenFetcher = Future<String?> Function(
    {required bool forceRefresh});

class AuthManager {
  AuthManager({
    required this.config,
    required this.sendAuth,
    required this.emitAuthState,
  });

  final ConvexClientConfig config;
  final SendAuthCallback sendAuth;
  final AuthStateEmitter emitAuthState;

  AuthTokenFetcher? _fetchToken;
  void Function(bool)? _onAuthChange;
  Timer? _refreshTimer;
  String? _currentToken;

  Future<void> setAuth(String? token) async {
    _cancelRefreshTimer();
    _fetchToken = null;
    _onAuthChange = null;
    _currentToken = token;
    await sendAuth(token);
    if (token == null) {
      _emit(false);
    }
  }

  Future<AuthHandle> setAuthWithRefresh({
    required AuthTokenFetcher fetchToken,
    void Function(bool)? onAuthChange,
  }) async {
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

  Future<void> clearAuth() async {
    _cancelRefreshTimer();
    _fetchToken = null;
    _onAuthChange = null;
    _currentToken = null;
    await sendAuth(null);
    _emit(false);
  }

  Future<void> refreshAuthForReconnect() async {
    final fetchToken = _fetchToken;
    if (fetchToken == null) {
      return;
    }
    final freshToken = await fetchToken(forceRefresh: true);
    _currentToken = freshToken;
    if (freshToken == null) {
      _emit(false);
      return;
    }
    _scheduleRefresh(freshToken);
  }

  String? get currentToken => _currentToken;

  Future<void> updateToken(String token) async {
    _currentToken = token;
    await sendAuth(token);
    if (_fetchToken != null) {
      _scheduleRefresh(token);
    }
  }

  void handleAuthConfirmed() {
    final isAuthenticated = _currentToken != null;
    _emit(isAuthenticated);
    if (isAuthenticated && _fetchToken != null) {
      _scheduleRefresh(_currentToken!);
    }
  }

  Future<void> handleAuthError(AuthError error) async {
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
      _emit(false);
      return;
    }

    if (error.authUpdateAttempted == true) {
      _scheduleRefresh(freshToken);
    }
  }

  Future<void> stopRefreshing() async {
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
      return;
    }
    if (exp == null || iat == null) {
      return;
    }
    final lifetimeSeconds = exp - iat;
    final refreshDelay = Duration(
      seconds: lifetimeSeconds > 60 ? lifetimeSeconds - 60 : 0,
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
        _emit(false);
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
}

class _RefreshAuthHandle implements AuthHandle {
  _RefreshAuthHandle(this._manager);

  final AuthManager _manager;

  @override
  Future<void> cancel() {
    return _manager.stopRefreshing();
  }
}
