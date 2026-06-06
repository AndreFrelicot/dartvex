import 'dart:collection';
import 'dart:convert';

import 'package:dartvex/dartvex.dart';
import 'package:flutter/foundation.dart';

class DemoUserSession {
  const DemoUserSession({
    required this.token,
    required this.userId,
    required this.displayName,
    required this.issuedAt,
    required this.cacheRestoreCount,
    required this.tokenLabel,
  });

  final String token;
  final String userId;
  final String displayName;
  final DateTime issuedAt;
  final int cacheRestoreCount;
  final String tokenLabel;

  DemoUserSession copyWith({
    String? token,
    String? userId,
    String? displayName,
    DateTime? issuedAt,
    int? cacheRestoreCount,
    String? tokenLabel,
  }) {
    return DemoUserSession(
      token: token ?? this.token,
      userId: userId ?? this.userId,
      displayName: displayName ?? this.displayName,
      issuedAt: issuedAt ?? this.issuedAt,
      cacheRestoreCount: cacheRestoreCount ?? this.cacheRestoreCount,
      tokenLabel: tokenLabel ?? this.tokenLabel,
    );
  }
}

class DemoAuthProvider extends ChangeNotifier
    implements AuthProvider<DemoUserSession> {
  DemoAuthProvider({
    required String? preferredToken,
    required this.tokenLabel,
    DateTime Function()? now,
  }) : _preferredToken = preferredToken,
       _now = now ?? DateTime.now {
    _appendEvent(
      hasConfiguredToken
          ? 'Demo auth ready. Login uses $tokenLabel.'
          : 'Demo auth token missing. Set CONVEX_DEMO_AUTH_TOKEN.',
    );
  }

  final String? _preferredToken;
  final DateTime Function() _now;
  final String tokenLabel;
  final List<String> _eventLog = <String>[];

  DemoUserSession? _cachedSession;
  int _loginCalls = 0;
  int _loginFromCacheCalls = 0;
  int _logoutCalls = 0;

  DemoUserSession? get cachedSession => _cachedSession;
  bool get hasCachedSession => _cachedSession != null;
  bool get hasConfiguredToken => _preferredToken?.isNotEmpty ?? false;
  int get loginCalls => _loginCalls;
  int get loginFromCacheCalls => _loginFromCacheCalls;
  int get logoutCalls => _logoutCalls;
  UnmodifiableListView<String> get eventLog =>
      UnmodifiableListView<String>(_eventLog);

  @override
  String extractIdToken(DemoUserSession authResult) => authResult.token;

  @override
  Future<DemoUserSession> login({
    required void Function(String? token) onIdToken,
  }) async {
    _loginCalls += 1;
    final token = _preferredToken;
    if (token == null || token.isEmpty) {
      _appendEvent('login(): blocked because CONVEX_DEMO_AUTH_TOKEN is unset.');
      notifyListeners();
      throw StateError(
        'Demo auth token is not configured. Generate one with '
        '`cd example/convex-backend && npm run -s token` after setting '
        'DEMO_JWKS, then pass it with '
        '--dart-define=CONVEX_DEMO_AUTH_TOKEN=...',
      );
    }
    final session = DemoUserSession(
      token: token,
      userId: 'demo-user-1',
      displayName: 'Demo User',
      issuedAt: _now().toUtc(),
      cacheRestoreCount: 0,
      tokenLabel: tokenLabel,
    );
    _cachedSession = session;
    onIdToken(session.token);
    _appendEvent('login(): issued ${session.displayName} using $tokenLabel.');
    notifyListeners();
    return session;
  }

  @override
  Future<DemoUserSession> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    _loginFromCacheCalls += 1;
    final cachedSession = _cachedSession;
    if (cachedSession == null) {
      _appendEvent('loginFromCache(): no cached session available.');
      notifyListeners();
      throw StateError('No cached demo session available. Tap Login first.');
    }

    final refreshedSession = cachedSession.copyWith(
      issuedAt: _now().toUtc(),
      cacheRestoreCount: cachedSession.cacheRestoreCount + 1,
    );
    _cachedSession = refreshedSession;
    onIdToken(refreshedSession.token);
    _appendEvent(
      'loginFromCache(): restored cached session '
      '(refresh #${refreshedSession.cacheRestoreCount}).',
    );
    notifyListeners();
    return refreshedSession;
  }

  @override
  Future<void> logout() async {
    _logoutCalls += 1;
    _appendEvent('logout(): cleared active auth, cached session retained.');
    notifyListeners();
  }

  void recordUiEvent(String message) {
    _appendEvent(message);
    notifyListeners();
  }

  /// Builds a structurally valid but **expired** demo JWT and records the
  /// simulation in the event log.
  ///
  /// Handing this token to the live client (via `ConvexClient.updateAuthToken`)
  /// forces the backend to reject it, which exercises the genuine reauth path:
  /// the client stops the socket, fetches a fresh token through
  /// [loginFromCache] (which still returns the real cached session token), and
  /// replays it. The `ConvexAuthRefreshingBuilder` badge lights up for the
  /// duration. This is the only client-observable way to toggle that badge on
  /// demand — a fresh login uses the initial-fetch path and never sets it.
  String simulateExpiredToken() {
    _appendEvent('simulateExpiredToken(): handed the client an expired JWT.');
    notifyListeners();
    return _expiredDemoToken();
  }

  String _expiredDemoToken() {
    final nowSeconds = _now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final header = _base64UrlJson(<String, Object?>{
      'alg': 'HS256',
      'typ': 'JWT',
    });
    final payload = _base64UrlJson(<String, Object?>{
      'sub': 'demo-user-1',
      'iat': nowSeconds - 3600,
      'exp': nowSeconds - 60,
    });
    // The signature is deliberately bogus: a genuine server rejection is the
    // whole point, so the backend must refuse this token.
    return '$header.$payload.invalid-demo-signature';
  }

  String _base64UrlJson(Map<String, Object?> claims) {
    return base64Url
        .encode(utf8.encode(jsonEncode(claims)))
        .replaceAll('=', '');
  }

  void _appendEvent(String message) {
    final timestamp = _now().toUtc().toIso8601String().substring(11, 19);
    _eventLog.insert(0, '$timestamp  $message');
    if (_eventLog.length > 8) {
      _eventLog.removeRange(8, _eventLog.length);
    }
  }
}
