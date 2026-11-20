// Transient token fetch failures keep the session and are retried (0.4.1).
//
// Found on a device with dartvex_auth2_convex: a refresh that failed while the
// network was down was never retried, and a reauth gave up after its short
// retries and signed the user out, although the session was still valid.
import 'dart:async';
import 'dart:convert';

import 'package:dartvex/src/auth/auth_manager.dart';
import 'package:dartvex/src/auth/auth_provider.dart';
import 'package:dartvex/src/config.dart';
import 'package:dartvex/src/exceptions.dart';
import 'package:dartvex/src/logging.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

const _expired = AuthError(
  error: 'Convex token identity expired',
  baseVersion: 0,
  authUpdateAttempted: true,
);

const _offline = ConvexException('network down', retryable: true);

int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

String _jwt({required String subject, required int iat, required int exp}) {
  String encode(Map<String, Object?> json) =>
      base64UrlEncode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${encode(<String, Object?>{'alg': 'none'})}.'
      '${encode(<String, Object?>{'sub': subject, 'iat': iat, 'exp': exp})}.';
}

class _SessionEnded extends ConvexException implements AuthSessionEndedError {
  const _SessionEnded() : super('session revoked', retryable: true);
}

class _Recorder {
  final List<String> events = <String>[];
  final List<bool> authStates = <bool>[];
  final List<bool> refreshing = <bool>[];
  final List<DartvexLogEvent> logs = <DartvexLogEvent>[];

  Iterable<String> get sends => events.where((e) => e.startsWith('send:'));
}

AuthManager _manager(
  _Recorder recorder, {
  List<Duration> reauthFetchRetryDelays = const <Duration>[],
  List<Duration> transientRefreshRetryDelays = const <Duration>[Duration.zero],
  int refreshTokenLeewaySeconds = 10,
}) {
  return AuthManager(
    config: ConvexClientConfig(
      connectImmediately: false,
      refreshTokenLeewaySeconds: refreshTokenLeewaySeconds,
      logLevel: DartvexLogLevel.debug,
      logger: recorder.logs.add,
    ),
    sendAuth: (token) async => recorder.events.add('send:${token ?? 'null'}'),
    emitAuthState: recorder.authStates.add,
    pauseSocket: () async => recorder.events.add('pause'),
    resumeSocket: () async => recorder.events.add('resume'),
    stopSocket: () async => recorder.events.add('stop'),
    restartSocket: () async => recorder.events.add('restart'),
    onRefreshingChange: recorder.refreshing.add,
    reauthFetchRetryDelays: reauthFetchRetryDelays,
    transientRefreshRetryDelays: transientRefreshRetryDelays,
  );
}

Future<void> _until(bool Function() condition) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > const Duration(seconds: 2)) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// Signs in with a cached token the server confirmed, so later forced fetches
/// are the ones under test.
Future<void> _signedIn(
  AuthManager manager,
  _Recorder recorder,
  Future<String?> Function() forcedFetch,
) async {
  await manager.setAuthWithRefresh(
    fetchToken: ({required bool forceRefresh}) =>
        forceRefresh ? forcedFetch() : Future<String?>.value('cached'),
  );
  recorder.events.clear();
}

void main() {
  group('isTransientFetchError', () {
    test('accepts retryable Convex errors, timeouts and http errors', () {
      expect(AuthManager.isTransientFetchError(_offline), isTrue);
      expect(
        AuthManager.isTransientFetchError(TimeoutException('slow')),
        isTrue,
      );
      expect(
        AuthManager.isTransientFetchError(http.ClientException('no route')),
        isTrue,
      );
    });

    test('rejects ended sessions, non-retryable and unknown errors', () {
      expect(AuthManager.isTransientFetchError(const _SessionEnded()), isFalse);
      expect(
        AuthManager.isTransientFetchError(const ConvexException('bad config')),
        isFalse,
      );
      expect(AuthManager.isTransientFetchError(StateError('bug')), isFalse);
    });
  });

  group('reauth', () {
    test('keeps the session through a transient outage, then recovers',
        () async {
      final recorder = _Recorder();
      final manager = _manager(
        recorder,
        reauthFetchRetryDelays: const <Duration>[Duration.zero],
      );
      var forced = 0;
      await _signedIn(manager, recorder, () async {
        forced += 1;
        if (forced <= 5) {
          throw _offline;
        }
        return 'fresh';
      });

      await manager.handleAuthError(_expired, currentAuthVersion: 1);

      expect(forced, 6);
      expect(manager.currentToken, 'fresh');
      expect(recorder.sends.toList(), <String>['send:fresh']);
      expect(recorder.authStates, isNot(contains(false)));
      expect(recorder.events.first, 'stop');
      expect(recorder.events.last, 'restart');
      // Still refreshing until the server confirms the fresh token.
      expect(manager.isRefreshing, isTrue);
      manager.handleAuthConfirmed();
      expect(manager.isRefreshing, isFalse);
      await manager.stopRefreshing();
    });

    test('a non-retryable error still signs out after the short retries',
        () async {
      final recorder = _Recorder();
      final manager = _manager(
        recorder,
        reauthFetchRetryDelays: const <Duration>[Duration.zero],
      );
      var forced = 0;
      await _signedIn(manager, recorder, () async {
        forced += 1;
        throw const ConvexException('missing function');
      });

      await manager.handleAuthError(_expired, currentAuthVersion: 1);

      expect(forced, 2);
      expect(manager.currentToken, isNull);
      expect(recorder.sends, contains('send:null'));
      expect(recorder.authStates.last, isFalse);
    });

    test('an ended session reported during the outage signs out', () async {
      final recorder = _Recorder();
      final manager = _manager(recorder);
      var forced = 0;
      await _signedIn(manager, recorder, () async {
        forced += 1;
        if (forced <= 3) {
          throw _offline;
        }
        throw const _SessionEnded();
      });

      await manager.handleAuthError(_expired, currentAuthVersion: 1);

      expect(forced, 4);
      expect(manager.currentToken, isNull);
      expect(recorder.sends, contains('send:null'));
      expect(manager.isRefreshing, isFalse);
    });

    test('retryRefreshNow ends the backoff early', () async {
      final recorder = _Recorder();
      final manager = _manager(
        recorder,
        transientRefreshRetryDelays: const <Duration>[Duration(hours: 1)],
      );
      var forced = 0;
      var online = false;
      await _signedIn(manager, recorder, () async {
        forced += 1;
        if (!online) {
          throw _offline;
        }
        return 'fresh';
      });

      final reauth = manager.handleAuthError(_expired, currentAuthVersion: 1);
      await _until(() => forced == 1);
      online = true;
      manager.retryRefreshNow();
      await reauth.timeout(const Duration(seconds: 2));

      expect(forced, 2);
      expect(manager.currentToken, 'fresh');
      await manager.stopRefreshing();
    });

    test('clearAuth during the backoff ends the reauth without fetching again',
        () async {
      final recorder = _Recorder();
      final manager = _manager(
        recorder,
        transientRefreshRetryDelays: const <Duration>[Duration(hours: 1)],
      );
      var forced = 0;
      await _signedIn(manager, recorder, () async {
        forced += 1;
        throw _offline;
      });

      final reauth = manager.handleAuthError(_expired, currentAuthVersion: 1);
      await _until(() => forced == 1);
      await manager.clearAuth();
      await reauth.timeout(const Duration(seconds: 2));

      expect(forced, 1);
      expect(manager.currentToken, isNull);
      expect(manager.isRefreshing, isFalse);
      // clearAuth restarted the socket the reauth had stopped.
      expect(recorder.events.where((e) => e == 'restart'), hasLength(1));
      manager.retryRefreshNow(); // nothing pending: no effect
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(forced, 1);
    });

    test('an empty transient schedule keeps the previous behavior', () async {
      final recorder = _Recorder();
      final manager = _manager(
        recorder,
        reauthFetchRetryDelays: const <Duration>[Duration.zero],
        transientRefreshRetryDelays: const <Duration>[],
      );
      var forced = 0;
      await _signedIn(manager, recorder, () async {
        forced += 1;
        throw _offline;
      });

      await manager.handleAuthError(_expired, currentAuthVersion: 1);

      expect(forced, 2);
      expect(manager.currentToken, isNull);
    });
  });

  group('background refresh', () {
    test('a transient failure of the scheduled refresh is retried', () async {
      final recorder = _Recorder();
      final manager = _manager(recorder);
      final now = _nowSeconds();
      // Leeway >= lifetime: the scheduled refresh fires at once.
      final t1 = _jwt(subject: 't1', iat: now, exp: now + 5);
      final t2 = _jwt(subject: 't2', iat: now, exp: now + 3600);
      var forced = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (!forceRefresh) {
            return null;
          }
          forced += 1;
          if (forced == 1) {
            return t1;
          }
          if (forced <= 4) {
            throw _offline;
          }
          return t2;
        },
      );
      manager.handleAuthConfirmed();

      await _until(() => manager.currentToken == t2);
      expect(forced, 5);
      expect(recorder.sends, isNot(contains('send:null')));
      expect(recorder.authStates, isNot(contains(false)));
      expect(
        recorder.logs.where(
          (log) => log.message == 'Scheduled auth refresh failed; retrying',
        ),
        hasLength(3),
      );
      await manager.stopRefreshing();
    });

    test('the refetch after a cached confirmation is retried too', () async {
      final recorder = _Recorder();
      final manager = _manager(recorder);
      final now = _nowSeconds();
      final fresh = _jwt(subject: 'fresh', iat: now, exp: now + 3600);
      var forced = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (!forceRefresh) {
            return _jwt(subject: 'cached', iat: now, exp: now + 3600);
          }
          forced += 1;
          if (forced <= 2) {
            throw _offline;
          }
          return fresh;
        },
      );
      manager.handleAuthConfirmed();

      await _until(() => manager.currentToken == fresh);
      expect(forced, 3);
      await manager.stopRefreshing();
    });

    test('retryRefreshNow runs a pending background retry at once', () async {
      final recorder = _Recorder();
      final manager = _manager(
        recorder,
        transientRefreshRetryDelays: const <Duration>[Duration(hours: 1)],
      );
      final now = _nowSeconds();
      final t1 = _jwt(subject: 't1', iat: now, exp: now + 5);
      final t2 = _jwt(subject: 't2', iat: now, exp: now + 3600);
      var forced = 0;
      var online = false;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (!forceRefresh) {
            return null;
          }
          forced += 1;
          if (forced == 1) {
            return t1;
          }
          if (!online) {
            throw _offline;
          }
          return t2;
        },
      );
      manager.handleAuthConfirmed();
      await _until(() => forced == 2);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(manager.currentToken, t1);

      online = true;
      manager.retryRefreshNow();
      await _until(() => manager.currentToken == t2);
      expect(forced, 3);
      await manager.stopRefreshing();
    });

    test('stopRefreshing drops a pending background retry', () async {
      final recorder = _Recorder();
      final manager = _manager(
        recorder,
        transientRefreshRetryDelays: const <Duration>[Duration(hours: 1)],
      );
      final now = _nowSeconds();
      final t1 = _jwt(subject: 't1', iat: now, exp: now + 5);
      var forced = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (!forceRefresh) {
            return null;
          }
          forced += 1;
          if (forced == 1) {
            return t1;
          }
          throw _offline;
        },
      );
      manager.handleAuthConfirmed();
      await _until(() => forced == 2);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await manager.stopRefreshing();
      manager.retryRefreshNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forced, 2);
    });

    test('a non-transient failure is not retried', () async {
      final recorder = _Recorder();
      final manager = _manager(recorder);
      final now = _nowSeconds();
      final t1 = _jwt(subject: 't1', iat: now, exp: now + 5);
      var forced = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (!forceRefresh) {
            return null;
          }
          forced += 1;
          if (forced == 1) {
            return t1;
          }
          throw StateError('bug');
        },
      );
      manager.handleAuthConfirmed();
      await _until(() => forced == 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(forced, 2);
      expect(manager.currentToken, t1);
      expect(recorder.sends, isNot(contains('send:null')));
      await manager.stopRefreshing();
    });
  });
}
