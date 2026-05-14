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
          config: const ConvexClientConfig(connectImmediately: false),
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
