import 'dart:async';
import 'dart:convert';

import 'package:dartvex/src/auth/auth_manager.dart';
import 'package:dartvex/src/config.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:test/test.dart';

void main() {
  group('AuthManager', () {
    test('cached token confirmation force-refreshes immediately', () async {
      final sentTokens = <String?>[];
      final forceRefreshCalls = <bool>[];
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (token) async {
          sentTokens.add(token);
        },
        emitAuthState: (_) {},
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          forceRefreshCalls.add(forceRefresh);
          return _jwt(
            subject: forceRefresh ? 'fresh' : 'cached',
            issuedAt: forceRefresh ? nowSeconds + 1 : nowSeconds,
            expiresAt: forceRefresh ? nowSeconds + 7201 : nowSeconds + 7200,
          );
        },
      );
      manager.handleAuthConfirmed();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(forceRefreshCalls, <bool>[false, true]);
      expect(sentTokens, hasLength(2));
      expect(sentTokens.first, isNot(sentTokens.last));
      await manager.stopRefreshing();
    });

    test('cached token refresh does not resend identical auth token', () async {
      final sentTokens = <String?>[];
      final forceRefreshCalls = <bool>[];
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final token = _jwt(
        subject: 'same',
        issuedAt: nowSeconds,
        expiresAt: nowSeconds + 7200,
      );
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (token) async {
          sentTokens.add(token);
        },
        emitAuthState: (_) {},
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          forceRefreshCalls.add(forceRefresh);
          return token;
        },
      );
      manager.handleAuthConfirmed();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(forceRefreshCalls, <bool>[false, true]);
      expect(sentTokens, <String?>[token]);
      await manager.stopRefreshing();
    });

    test('scheduled refresh failures are caught instead of escaping the zone',
        () async {
      final zoneErrors = <Object>[];
      final forceRefreshCalls = <bool>[];
      await runZonedGuarded(() async {
        final manager = AuthManager(
          // Leeway wider than the cached token's 30s lifetime forces an
          // immediate scheduled refetch, which is the path under test.
          config: const ConvexClientConfig(
            connectImmediately: false,
            refreshTokenLeewaySeconds: 60,
          ),
          sendAuth: (_) async {},
          emitAuthState: (_) {},
        );

        await manager.setAuthWithRefresh(
          fetchToken: ({required bool forceRefresh}) async {
            forceRefreshCalls.add(forceRefresh);
            if (forceRefresh) {
              throw StateError('refresh failed');
            }
            return _jwt(subject: 'cached', issuedAt: 0, expiresAt: 30);
          },
        );
        manager.handleAuthConfirmed();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await manager.stopRefreshing();
      }, (error, _) {
        zoneErrors.add(error);
      });

      expect(forceRefreshCalls, <bool>[false, true]);
      expect(zoneErrors, isEmpty);
    });

    test('scheduled refresh returning no token clears the refresh flow',
        () async {
      final events = <String>[];
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final manager = AuthManager(
        config: const ConvexClientConfig(
          connectImmediately: false,
          refreshTokenLeewaySeconds: 60,
        ),
        sendAuth: (token) async => events.add('sendAuth:${token ?? 'null'}'),
        emitAuthState: (authenticated) =>
            events.add('authState:$authenticated'),
        stopSocket: () async => events.add('stop'),
        restartSocket: () async => events.add('restart'),
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          events.add('fetch:$forceRefresh');
          return forceRefresh
              ? null
              : _jwt(
                  subject: 'cached',
                  issuedAt: nowSeconds,
                  expiresAt: nowSeconds + 30,
                );
        },
      );
      manager.handleAuthConfirmed();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        events.where((event) => event.startsWith('fetch:')),
        <String>['fetch:false', 'fetch:true'],
      );
      expect(
        events.where((event) => event.startsWith('sendAuth:')).map(
            (event) => event == 'sendAuth:null' ? event : 'sendAuth:token'),
        <String>['sendAuth:token', 'sendAuth:null'],
      );
      expect(events, contains('authState:false'));
      events.clear();

      await manager.handleAuthError(
        const AuthError(
          error: 'expired',
          baseVersion: 0,
          authUpdateAttempted: true,
        ),
        currentAuthVersion: 1,
      );

      expect(events, <String>['authState:false', 'sendAuth:null']);
      await manager.stopRefreshing();
    });

    test('scheduled refresh requires issued-at and expiration claims',
        () async {
      final sentTokens = <String?>[];
      final forceRefreshCalls = <bool>[];
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (token) async {
          sentTokens.add(token);
        },
        emitAuthState: (_) {},
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          forceRefreshCalls.add(forceRefresh);
          if (!forceRefresh) {
            return null;
          }
          return _jwt(
            subject: 'fresh',
            issuedAt: null,
            expiresAt: nowSeconds + 1,
          );
        },
      );
      manager.handleAuthConfirmed();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(forceRefreshCalls, <bool>[false, true]);
      expect(sentTokens, hasLength(1));
      await manager.stopRefreshing();
    });

    test('auth rejection clears auth when forced refresh returns same token',
        () async {
      final events = <String>[];
      const token = 'same-token';
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (token) async => events.add('sendAuth:${token ?? 'null'}'),
        emitAuthState: (authenticated) =>
            events.add('authState:$authenticated'),
        stopSocket: () async => events.add('stop'),
        restartSocket: () async => events.add('restart'),
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          events.add('fetch:$forceRefresh');
          return token;
        },
      );
      events.clear();

      await manager.handleAuthError(
        const AuthError(
          error: 'expired',
          baseVersion: 0,
          authUpdateAttempted: true,
        ),
        currentAuthVersion: 1,
      );

      expect(manager.currentToken, isNull);
      expect(events, <String>[
        'stop',
        'fetch:true',
        'authState:false',
        'sendAuth:null',
        'restart',
      ]);
      await manager.stopRefreshing();
    });

    test('stale initial token fetch cannot resurrect auth after clear',
        () async {
      final sentTokens = <String?>[];
      final tokenCompleter = Completer<String?>();
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (token) async {
          sentTokens.add(token);
        },
        emitAuthState: (_) {},
      );

      final handleFuture = manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) => tokenCompleter.future,
      );
      await manager.clearAuth();
      tokenCompleter.complete('late-token');
      await handleFuture;

      expect(sentTokens, <String?>[null]);
    });

    test('non-update auth error is ignored while waiting for confirmation',
        () async {
      var fetchCount = 0;
      final sentTokens = <String?>[];
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (token) async {
          sentTokens.add(token);
        },
        emitAuthState: (_) {},
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          fetchCount += 1;
          return 'token';
        },
      );
      await manager.handleAuthError(
        const AuthError(
          error: 'expired',
          baseVersion: 0,
          authUpdateAttempted: false,
        ),
        currentAuthVersion: 1,
      );

      expect(fetchCount, 1);
      expect(sentTokens, <String?>['token']);
    });

    test('server confirmation without pending auth update is ignored',
        () async {
      final authStates = <bool>[];
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (_) async {},
        emitAuthState: authStates.add,
      );

      await manager.setAuth('token');
      manager.handleAuthConfirmed();
      expect(authStates, <bool>[true]);

      authStates.clear();
      manager.handleAuthConfirmed();

      expect(authStates, isEmpty);
      await manager.stopRefreshing();
    });

    test('persistent auth rejection eventually reports signed out', () async {
      var fetchCount = 0;
      final sentTokens = <String?>[];
      final authStates = <bool>[];
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (token) async {
          sentTokens.add(token);
        },
        emitAuthState: authStates.add,
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          fetchCount += 1;
          return forceRefresh ? 'fresh-$fetchCount' : 'cached-token';
        },
      );
      manager.handleAuthConfirmed();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      authStates.clear();

      for (var i = 0; i < 6 && !authStates.contains(false); i += 1) {
        await manager.handleAuthError(
          AuthError(
            error: 'token rejected $i',
            baseVersion: i,
            authUpdateAttempted: true,
          ),
          currentAuthVersion: i + 1,
        );
      }

      expect(authStates, contains(false));
      expect(sentTokens.last, isNull);
      expect(fetchCount, 4);
      await manager.stopRefreshing();
    });

    test('terminal auth rejection gives up and clears the token', () async {
      var fetchCount = 0;
      final authStates = <bool>[];
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (_) async {},
        emitAuthState: authStates.add,
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          fetchCount += 1;
          return forceRefresh ? 'fresh-$fetchCount' : 'cached-token';
        },
      );
      manager.handleAuthConfirmed();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      authStates.clear();

      for (var i = 0; i < 6 && !authStates.contains(false); i += 1) {
        await manager.handleAuthError(
          AuthError(
            error: 'token rejected $i',
            baseVersion: i,
            authUpdateAttempted: true,
          ),
          currentAuthVersion: i + 1,
        );
      }
      final terminalFetchCount = fetchCount;

      // After the give-up the dead token is cleared; a later AuthError must not
      // resurrect it with another fetch (the refresh flow stays disabled).
      await manager.handleAuthError(
        const AuthError(
          error: 'token rejected again',
          baseVersion: 99,
          authUpdateAttempted: true,
        ),
        currentAuthVersion: 100,
      );

      expect(authStates, contains(false));
      expect(terminalFetchCount, 4);
      expect(fetchCount, terminalFetchCount);
      expect(manager.currentToken, isNull);
      await manager.stopRefreshing();
    });
  });

  group('AuthManager.computeRefreshDelay', () {
    test('uses token lifetime while the token is fresh', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
      final delay = AuthManager.computeRefreshDelay(
        iat: 1000000,
        exp: 1001000,
        leewaySeconds: 2,
        now: now,
      );
      expect(delay, const Duration(milliseconds: 998000));
    });

    test('clamps iat-based delay to the token time remaining', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
      final delay = AuthManager.computeRefreshDelay(
        iat: 997000,
        exp: 1000600,
        leewaySeconds: 300,
        now: now,
      );
      expect(delay, const Duration(minutes: 5));
    });

    test('refreshes immediately when leeway exceeds the token lifetime', () {
      final delay = AuthManager.computeRefreshDelay(
        iat: 0,
        exp: 5,
        leewaySeconds: 10,
      );
      expect(delay, Duration.zero);
    });

    test('returns null for tokens too short-lived to refresh', () {
      expect(
        AuthManager.computeRefreshDelay(iat: 0, exp: 2, leewaySeconds: 2),
        isNull,
      );
      expect(
        AuthManager.computeRefreshDelay(iat: 100, exp: 101, leewaySeconds: 2),
        isNull,
      );
    });

    test('caps the delay at the 20-day maximum', () {
      final delay = AuthManager.computeRefreshDelay(
        iat: 0,
        exp: 1000000000,
        leewaySeconds: 2,
        now: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(delay, const Duration(days: 20));
    });

    test('returns null when iat is absent', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
      final delay = AuthManager.computeRefreshDelay(
        iat: null,
        exp: 1000100,
        leewaySeconds: 2,
        now: now,
      );
      expect(delay, isNull);
    });

    test('does not schedule expiring tokens without iat', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
      final delay = AuthManager.computeRefreshDelay(
        iat: null,
        exp: 999999,
        leewaySeconds: 2,
        now: now,
      );
      expect(delay, isNull);
    });
  });

  group('AuthManager socket gating', () {
    AuthManager managerRecording(
      List<String> events, {
      required AuthTokenFetcher fetchToken,
    }) {
      return AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (token) async => events.add('sendAuth:${token ?? 'null'}'),
        emitAuthState: (_) {},
        pauseSocket: () async => events.add('pause'),
        resumeSocket: () async => events.add('resume'),
        stopSocket: () async => events.add('stop'),
        restartSocket: () async => events.add('restart'),
      );
    }

    test('setAuthWithRefresh pauses around the initial token fetch', () async {
      final events = <String>[];
      final manager = managerRecording(
        events,
        fetchToken: ({required bool forceRefresh}) async => 'token-abc',
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          events.add('fetch:$forceRefresh');
          return 'token-abc';
        },
      );
      await manager.stopRefreshing();

      expect(
        events,
        <String>['pause', 'fetch:false', 'sendAuth:token-abc', 'resume'],
      );
    });

    test('setAuthWithRefresh force-refreshes when the cached token is missing',
        () async {
      final events = <String>[];
      final manager = managerRecording(
        events,
        fetchToken: ({required bool forceRefresh}) async => 'unused',
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          events.add('fetch:$forceRefresh');
          return forceRefresh ? 'fresh-token' : null;
        },
      );
      await manager.stopRefreshing();

      expect(
        events,
        <String>[
          'pause',
          'fetch:false',
          'fetch:true',
          'sendAuth:fresh-token',
          'resume'
        ],
      );
    });

    test('setAuthWithRefresh resumes and clears auth when initial fetch fails',
        () async {
      final events = <String>[];
      final manager = managerRecording(
        events,
        fetchToken: ({required bool forceRefresh}) async => 'unused',
      );

      await expectLater(
        manager.setAuthWithRefresh(
          fetchToken: ({required bool forceRefresh}) async {
            events.add('fetch:$forceRefresh');
            throw StateError('initial fetch failed');
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(
        events,
        <String>['pause', 'fetch:false', 'sendAuth:null', 'resume'],
      );
      expect(manager.currentToken, isNull);
      expect(manager.isRefreshing, isFalse);
    });

    test('reauth stops, fetches, authenticates, then restarts', () async {
      final events = <String>[];
      final manager = managerRecording(
        events,
        fetchToken: ({required bool forceRefresh}) async => 'unused',
      );

      var forceRefreshCount = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          events.add('fetch:$forceRefresh');
          if (!forceRefresh) {
            return 'cached-token';
          }
          forceRefreshCount += 1;
          return 'fresh-token-$forceRefreshCount';
        },
      );
      // Confirm the cached token so the manager is no longer awaiting it.
      manager.handleAuthConfirmed();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      events.clear();

      await manager.handleAuthError(
        const AuthError(
          error: 'token expired',
          baseVersion: 0,
          authUpdateAttempted: true,
        ),
        currentAuthVersion: 1,
      );
      await manager.stopRefreshing();

      expect(
        events,
        <String>['stop', 'fetch:true', 'sendAuth:fresh-token-2', 'restart'],
      );
    });

    test('reauth still restarts the socket when the token cannot be refreshed',
        () async {
      final events = <String>[];
      final manager = managerRecording(
        events,
        fetchToken: ({required bool forceRefresh}) async => 'unused',
      );

      var forceRefreshCount = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (!forceRefresh) {
            return null;
          }
          forceRefreshCount += 1;
          return forceRefreshCount == 1 ? 'initial-fresh-token' : null;
        },
      );
      manager.handleAuthConfirmed();
      events.clear();

      await manager.handleAuthError(
        const AuthError(
          error: 'token expired',
          baseVersion: 0,
          authUpdateAttempted: true,
        ),
        currentAuthVersion: 1,
      );
      await manager.stopRefreshing();

      // The socket is never left stopped, even when the refresh yields no token.
      expect(events, <String>['stop', 'sendAuth:null', 'restart']);
    });

    test('reauth clears auth and restarts the socket when refresh throws',
        () async {
      final events = <String>[];
      final manager = managerRecording(
        events,
        fetchToken: ({required bool forceRefresh}) async => 'unused',
      );

      var forceRefreshCount = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          events.add('fetch:$forceRefresh');
          if (!forceRefresh) {
            return null;
          }
          forceRefreshCount += 1;
          if (forceRefreshCount > 1) {
            throw StateError('refresh failed');
          }
          return 'initial-fresh-token';
        },
      );
      manager.handleAuthConfirmed();
      events.clear();

      await manager.handleAuthError(
        const AuthError(
          error: 'token expired',
          baseVersion: 0,
          authUpdateAttempted: true,
        ),
        currentAuthVersion: 1,
      );

      expect(
        events,
        <String>['stop', 'fetch:true', 'sendAuth:null', 'restart'],
      );
      expect(manager.currentToken, isNull);
      expect(manager.isRefreshing, isFalse);
    });
  });

  group('AuthManager isRefreshing', () {
    test('toggles true during reauth and false once confirmed', () async {
      final refreshing = <bool>[];
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (_) async {},
        emitAuthState: (_) {},
        stopSocket: () async {},
        restartSocket: () async {},
        onRefreshingChange: refreshing.add,
      );

      var forceRefreshCount = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async =>
            forceRefresh ? 'fresh-${++forceRefreshCount}' : null,
      );
      manager.handleAuthConfirmed();
      // The initial token fetch is not a "refresh".
      expect(manager.isRefreshing, isFalse);
      expect(refreshing, isEmpty);

      await manager.handleAuthError(
        const AuthError(
          error: 'expired',
          baseVersion: 0,
          authUpdateAttempted: true,
        ),
        currentAuthVersion: 1,
      );
      expect(manager.isRefreshing, isTrue);
      expect(refreshing, <bool>[true]);

      // A confirming transition for the fresh token ends the refresh.
      manager.handleAuthConfirmed();
      expect(manager.isRefreshing, isFalse);
      expect(refreshing, <bool>[true, false]);

      await manager.stopRefreshing();
    });

    test('reauth confirmation does not re-emit an authenticated state',
        () async {
      final authStates = <bool>[];
      final authChanges = <bool>[];
      final refreshing = <bool>[];
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (_) async {},
        emitAuthState: authStates.add,
        stopSocket: () async {},
        restartSocket: () async {},
        onRefreshingChange: refreshing.add,
      );

      var forceRefreshCount = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async =>
            forceRefresh ? 'fresh-${++forceRefreshCount}' : null,
        onAuthChange: authChanges.add,
      );
      manager.handleAuthConfirmed();
      expect(authStates, <bool>[true]);
      expect(authChanges, <bool>[true]);
      authStates.clear();
      authChanges.clear();

      await manager.handleAuthError(
        const AuthError(
          error: 'expired',
          baseVersion: 0,
          authUpdateAttempted: true,
        ),
        currentAuthVersion: 1,
      );
      manager.handleAuthConfirmed();

      expect(refreshing, <bool>[true, false]);
      expect(authStates, isEmpty);
      expect(authChanges, <bool>[true]);
      await manager.stopRefreshing();
    });

    test('returns to false when a reauth cannot fetch a token', () async {
      final refreshing = <bool>[];
      final manager = AuthManager(
        config: const ConvexClientConfig(connectImmediately: false),
        sendAuth: (_) async {},
        emitAuthState: (_) {},
        stopSocket: () async {},
        restartSocket: () async {},
        onRefreshingChange: refreshing.add,
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async =>
            forceRefresh ? null : 'cached',
      );
      manager.handleAuthConfirmed();

      await manager.handleAuthError(
        const AuthError(
          error: 'expired',
          baseVersion: 0,
          authUpdateAttempted: true,
        ),
        currentAuthVersion: 1,
      );

      expect(refreshing, <bool>[true, false]);
      expect(manager.isRefreshing, isFalse);
      await manager.stopRefreshing();
    });
  });
}

String _jwt({
  required String subject,
  required int? issuedAt,
  required int expiresAt,
}) {
  final header = base64UrlEncode(utf8.encode(jsonEncode(<String, dynamic>{
    'alg': 'none',
    'typ': 'JWT',
  }))).replaceAll('=', '');
  final payload = base64UrlEncode(utf8.encode(jsonEncode(<String, dynamic>{
    'sub': subject,
    if (issuedAt != null) 'iat': issuedAt,
    'exp': expiresAt,
  }))).replaceAll('=', '');
  return '$header.$payload.';
}
