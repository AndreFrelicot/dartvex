import 'dart:collection';

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
    required String preferredToken,
    required this.tokenLabel,
    DateTime Function()? now,
  }) : _preferredToken = preferredToken,
       _now = now ?? DateTime.now {
    _appendEvent('Demo auth ready. Login uses $tokenLabel.');
  }

  final String _preferredToken;
  final DateTime Function() _now;
  final String tokenLabel;
  final List<String> _eventLog = <String>[];

  DemoUserSession? _cachedSession;
  int _loginCalls = 0;
  int _loginFromCacheCalls = 0;
  int _logoutCalls = 0;

  DemoUserSession? get cachedSession => _cachedSession;
  bool get hasCachedSession => _cachedSession != null;
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
    final session = DemoUserSession(
      token: _preferredToken,
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

  void _appendEvent(String message) {
    final timestamp = _now().toUtc().toIso8601String().substring(11, 19);
    _eventLog.insert(0, '$timestamp  $message');
    if (_eventLog.length > 8) {
      _eventLog.removeRange(8, _eventLog.length);
    }
  }
}
