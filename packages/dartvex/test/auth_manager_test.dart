import 'dart:async';
import 'dart:convert';

import 'package:dartvex/src/auth/auth_manager.dart';
import 'package:dartvex/src/config.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:test/test.dart';

void main() {
  group('AuthManager', () {
    test('scheduled refresh force-refreshes token after confirmation',
        () async {
      final sentTokens = <String?>[];
      final forceRefreshCalls = <bool>[];
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final manager = AuthManager(
        // Leeway wider than the cached token's lifetime forces an immediate
        // refetch under the exp-iat schedule, so the test stays fast.
        config: const ConvexClientConfig(
          connectImmediately: false,
          refreshTokenLeewaySeconds: 7200,
        ),
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
            issuedAt: forceRefresh ? nowSeconds + 1 : nowSeconds - 3600,
            expiresAt: forceRefresh ? nowSeconds + 3601 : nowSeconds + 1,
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

    test('scheduled refresh only requires token expiration', () async {
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
            issuedAt: forceRefresh ? nowSeconds + 1 : null,
            expiresAt: forceRefresh ? nowSeconds + 3601 : nowSeconds + 1,
          );
        },
      );
      manager.handleAuthConfirmed();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(forceRefreshCalls, <bool>[false, true]);
      expect(sentTokens, hasLength(2));
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
  });

  group('AuthManager.computeRefreshDelay', () {
    test('derives the delay from token lifetime, not the wall clock', () {
      // Two tokens with the same lifetime but wildly different absolute
      // timestamps must schedule identically: the wall clock is never read.
      final near = AuthManager.computeRefreshDelay(
        iat: 1000,
        exp: 2000,
        leewaySeconds: 2,
      );
      final far = AuthManager.computeRefreshDelay(
        iat: 5000000000,
        exp: 5000001000,
        leewaySeconds: 2,
      );
      expect(near, const Duration(milliseconds: 998000));
      expect(near, far);
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
      );
      expect(delay, const Duration(days: 20));
    });

    test('falls back to the wall clock when iat is absent', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
      final delay = AuthManager.computeRefreshDelay(
        iat: null,
        exp: 1000100,
        leewaySeconds: 2,
        now: now,
      );
      expect(delay, const Duration(milliseconds: 98000));
    });

    test('wall-clock fallback clamps to zero for an expiring token', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1000000 * 1000);
      final delay = AuthManager.computeRefreshDelay(
        iat: null,
        exp: 999999,
        leewaySeconds: 2,
        now: now,
      );
      expect(delay, Duration.zero);
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

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          events.add('fetch:$forceRefresh');
          return forceRefresh ? 'fresh-token' : 'cached-token';
        },
      );
      // Confirm the cached token so the manager is no longer awaiting it.
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

      expect(
        events,
        <String>['stop', 'fetch:true', 'sendAuth:fresh-token', 'restart'],
      );
    });

    test('reauth still restarts the socket when the token cannot be refreshed',
        () async {
      final events = <String>[];
      final manager = managerRecording(
        events,
        fetchToken: ({required bool forceRefresh}) async => 'unused',
      );

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          return forceRefresh ? null : 'cached-token';
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

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          events.add('fetch:$forceRefresh');
          if (forceRefresh) {
            throw StateError('refresh failed');
          }
          return 'cached-token';
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

      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async =>
            forceRefresh ? 'fresh' : 'cached',
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
