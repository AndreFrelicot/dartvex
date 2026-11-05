// Regression tests for the 2026-11 post-release review of AuthManager
// (findings F5, F43/C2, F45, F46, F48, F49, F136-F138, F141-F143, C0).
import 'dart:async';
import 'dart:convert';

import 'package:dartvex/src/auth/auth_manager.dart';
import 'package:dartvex/src/config.dart';
import 'package:dartvex/src/logging.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:test/test.dart';

const _expired = AuthError(
  error: 'Token expired',
  baseVersion: 0,
  authUpdateAttempted: true,
);

int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

String _jwt({required String subject, int? iat, required int exp}) {
  String encode(Map<String, Object?> json) =>
      base64UrlEncode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${encode(<String, Object?>{'alg': 'none'})}.'
      '${encode(<String, Object?>{
        'sub': subject,
        if (iat != null) 'iat': iat,
        'exp': exp,
      })}.';
}

class _Recorder {
  final List<String> events = <String>[];
  final List<bool> authStates = <bool>[];
  final List<DartvexLogEvent> logs = <DartvexLogEvent>[];

  Iterable<String> get sends => events.where((e) => e.startsWith('send:'));

  List<int> get scheduledDelaysMs => logs
      .where((log) => log.message == 'Auth refresh scheduled')
      .map((log) => log.data!['delayMs'] as int)
      .toList(growable: false);
}

AuthManager _manager(
  _Recorder recorder, {
  bool initialAuthTokenReuse = false,
  int refreshTokenLeewaySeconds = 10,
  int Function()? clientNowMillis,
  List<Duration> reauthFetchRetryDelays = const <Duration>[],
  void Function(bool)? onAuthState,
  Duration sendDelay = Duration.zero,
}) {
  return AuthManager(
    config: ConvexClientConfig(
      connectImmediately: false,
      initialAuthTokenReuse: initialAuthTokenReuse,
      refreshTokenLeewaySeconds: refreshTokenLeewaySeconds,
      logLevel: DartvexLogLevel.debug,
      logger: recorder.logs.add,
    ),
    sendAuth: (token) async {
      recorder.events.add('send:${token ?? 'null'}');
      if (sendDelay > Duration.zero) {
        await Future<void>.delayed(sendDelay);
      }
    },
    emitAuthState: (value) {
      recorder.authStates.add(value);
      onAuthState?.call(value);
    },
    pauseSocket: () async => recorder.events.add('pause'),
    resumeSocket: () async => recorder.events.add('resume'),
    stopSocket: () async => recorder.events.add('stop'),
    restartSocket: () async => recorder.events.add('restart'),
    clientNowMillis: clientNowMillis,
    reauthFetchRetryDelays: reauthFetchRetryDelays,
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

void main() {
  test(
      'a reauth sharing an in-flight forced fetch with the scheduled refresh '
      'keeps the session (F5)', () async {
    final recorder = _Recorder();
    final manager = _manager(recorder);
    final now = _nowSeconds();
    // Leeway >= lifetime: the refresh timer fires immediately.
    final t1 = _jwt(subject: 't1', iat: now, exp: now + 5);
    final t2 = _jwt(subject: 't2', iat: now, exp: now + 3600);
    final shared = Completer<String?>();
    var forcedCalls = 0;
    final authChanges = <bool>[];

    await manager.setAuthWithRefresh(
      fetchToken: ({required bool forceRefresh}) {
        if (!forceRefresh) {
          return Future<String?>.value(null);
        }
        forcedCalls += 1;
        // Like AuthTokenBridge: concurrent forced refreshes share one call.
        return forcedCalls == 1 ? Future<String?>.value(t1) : shared.future;
      },
      onAuthChange: authChanges.add,
    );
    manager.handleAuthConfirmed();
    await _until(() => forcedCalls == 2); // the scheduled refresh started

    final reauth = manager.handleAuthError(_expired, currentAuthVersion: 1);
    await _until(() => forcedCalls == 3);
    shared.complete(t2);
    await reauth;

    expect(manager.currentToken, t2);
    expect(recorder.sends, isNot(contains('send:null')));
    expect(recorder.sends.where((e) => e == 'send:$t2'), hasLength(1));
    expect(authChanges, <bool>[true]);
    expect(recorder.events.last, 'restart');
    await manager.stopRefreshing();
  });

  test('a reauth that gets back the rejected token still signs out (F5)',
      () async {
    final recorder = _Recorder();
    final manager = _manager(recorder);
    final token = _jwt(subject: 't', iat: 0, exp: 100);
    await manager.setAuthWithRefresh(
      fetchToken: ({required bool forceRefresh}) async => token,
    );
    manager.handleAuthConfirmed();
    recorder.events.clear();

    await manager.handleAuthError(_expired, currentAuthVersion: 1);
    expect(manager.currentToken, isNull);
    expect(recorder.sends, contains('send:null'));
  });

  test(
      "a replaced flow's pending confirmation is not credited to the new "
      'flow (F45)', () async {
    final recorder = _Recorder();
    final manager = _manager(recorder);
    await manager.setAuthWithRefresh(
      fetchToken: ({required bool forceRefresh}) async => 'token-a',
    );
    final pending = Completer<String?>();
    final changes = <bool>[];
    final second = manager.setAuthWithRefresh(
      fetchToken: ({required bool forceRefresh}) =>
          forceRefresh ? pending.future : Future<String?>.value(null),
      onAuthChange: changes.add,
    );
    await Future<void>.delayed(Duration.zero);

    // token-a's Transition arrives while the new flow is still fetching.
    manager.handleAuthConfirmed();
    expect(changes, isEmpty);
    expect(recorder.authStates, isEmpty);

    pending.complete('token-b');
    await second;
    manager.handleAuthConfirmed();
    expect(changes, <bool>[true]);
    await manager.stopRefreshing();
  });

  group('updateToken during the initial fetch (F46)', () {
    test('keeps the refresh flow cancellable through the returned handle',
        () async {
      final recorder = _Recorder();
      final manager = _manager(recorder);
      final cached = Completer<String?>();
      final handleFuture = manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) =>
            forceRefresh ? Future<String?>.value('fresh') : cached.future,
      );
      await Future<void>.delayed(Duration.zero);
      await manager.updateToken('pushed');
      cached.complete('cached');
      final handle = await handleFuture;

      // The pushed token stays; the late cached token is dropped.
      expect(manager.currentToken, 'pushed');
      expect(recorder.sends, isNot(contains('send:cached')));

      await handle.cancel();
      recorder.events.clear();
      // With the flow cancelled there is nothing to reauth with.
      await manager.handleAuthError(_expired, currentAuthVersion: 1);
      expect(recorder.events, isNot(contains('stop')));
    });

    test('a fetch failure after a push still returns the live handle',
        () async {
      final recorder = _Recorder();
      final manager = _manager(recorder);
      final cached = Completer<String?>();
      final handleFuture = manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) => cached.future,
      );
      await Future<void>.delayed(Duration.zero);
      await manager.updateToken('pushed');
      cached.completeError(StateError('network'));

      final handle = await handleFuture;
      expect(manager.currentToken, 'pushed');
      await handle.cancel();
    });
  });

  test(
      'clearAuth reports signed out before a newer setAuth can be confirmed '
      '(F48)', () async {
    final recorder = _Recorder();
    final manager =
        _manager(recorder, sendDelay: const Duration(milliseconds: 5));
    await manager.setAuth('t1');
    manager.handleAuthConfirmed();
    expect(recorder.authStates, <bool>[true]);

    final clearing = manager.clearAuth();
    final setting = manager.setAuth('t2');
    await Future.wait(<Future<void>>[clearing, setting]);
    manager.handleAuthConfirmed();

    expect(recorder.authStates, <bool>[true, false, true]);
    expect(manager.isAuthenticated, isTrue);
  });

  group('failure paths clear transport auth before notifying (F49)', () {
    test('a guest fallback installed by a listener is not overwritten',
        () async {
      final recorder = _Recorder();
      late final AuthManager manager;
      manager = _manager(
        recorder,
        onAuthState: (authenticated) {
          if (!authenticated) {
            unawaited(manager.setAuth('guest'));
          }
        },
      );
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async =>
            forceRefresh ? null : null,
      );

      expect(recorder.sends.toList(), <String>['send:null', 'send:guest']);
      expect(manager.currentToken, 'guest');
    });

    test('a throwing onAuthChange cannot leave the old token applied',
        () async {
      final recorder = _Recorder();
      final manager = _manager(recorder);
      var forced = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (!forceRefresh) {
            return 'cached';
          }
          forced += 1;
          return null; // session revoked elsewhere
        },
        onAuthChange: (authenticated) {
          if (!authenticated) {
            throw StateError('widget disposed');
          }
        },
      );
      manager.handleAuthConfirmed(); // starts the post-confirmation refetch
      await _until(() => forced == 1);
      await _until(() => recorder.sends.contains('send:null'));

      expect(manager.currentToken, isNull);
      expect(recorder.authStates.last, isFalse);
      expect(
        recorder.logs.map((log) => log.message),
        contains('onAuthChange callback threw'),
      );
    });
  });

  test(
      'a superseding auth call restarts a socket stopped by a hanging reauth '
      '(F136)', () async {
    final recorder = _Recorder();
    final manager = _manager(recorder);
    final hanging = Completer<String?>();
    var forced = 0;
    await manager.setAuthWithRefresh(
      fetchToken: ({required bool forceRefresh}) {
        if (!forceRefresh) {
          return Future<String?>.value('cached');
        }
        forced += 1;
        return hanging.future;
      },
    );
    recorder.events.clear();

    final reauth = manager.handleAuthError(_expired, currentAuthVersion: 1);
    await _until(() => forced == 1);
    expect(recorder.events, <String>['stop']);

    await manager.clearAuth();
    expect(recorder.events, contains('restart'));

    hanging.complete('late');
    await reauth;
    // The superseded reauth does not restart a second time.
    expect(recorder.events.where((e) => e == 'restart'), hasLength(1));
    expect(manager.currentToken, isNull);
  });

  test('handleAuthConfirmed survives a listener that clears auth (F138)',
      () async {
    final recorder = _Recorder();
    late final AuthManager manager;
    manager = _manager(recorder);
    final now = _nowSeconds();
    await manager.setAuthWithRefresh(
      fetchToken: ({required bool forceRefresh}) async => forceRefresh
          ? _jwt(subject: 'fresh', iat: now, exp: now + 3600)
          : null,
      onAuthChange: (authenticated) {
        if (authenticated) {
          unawaited(manager.clearAuth());
        }
      },
    );

    expect(() => manager.handleAuthConfirmed(), returnsNormally);
    expect(manager.currentToken, isNull);
    expect(recorder.scheduledDelaysMs, isEmpty);
  });

  test('isAuthenticated mirrors the published auth state (F141)', () async {
    final recorder = _Recorder();
    final manager = _manager(recorder);
    expect(manager.isAuthenticated, isFalse);
    await manager.setAuth('token');
    manager.handleAuthConfirmed();
    expect(manager.isAuthenticated, isTrue);
    await manager.clearAuth();
    expect(manager.isAuthenticated, isFalse);
  });

  group('reauth fetch errors (F142)', () {
    test('a transient failure is retried and keeps the session', () async {
      final recorder = _Recorder();
      final manager = _manager(
        recorder,
        reauthFetchRetryDelays: const <Duration>[Duration.zero],
      );
      var forced = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (!forceRefresh) {
            return 'cached';
          }
          forced += 1;
          if (forced == 1) {
            throw StateError('radio waking up');
          }
          return 'fresh';
        },
      );
      recorder.events.clear();

      await manager.handleAuthError(_expired, currentAuthVersion: 1);
      expect(manager.currentToken, 'fresh');
      expect(recorder.sends.toList(), <String>['send:fresh']);
    });

    test('persistent failures sign out after the retries', () async {
      final recorder = _Recorder();
      final manager = _manager(
        recorder,
        reauthFetchRetryDelays: const <Duration>[Duration.zero, Duration.zero],
      );
      var forced = 0;
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (!forceRefresh) {
            return 'cached';
          }
          forced += 1;
          throw StateError('session gone');
        },
      );

      await manager.handleAuthError(_expired, currentAuthVersion: 1);
      expect(forced, 3);
      expect(manager.currentToken, isNull);
      expect(recorder.sends, contains('send:null'));
    });
  });

  test('giving up logs the server reason with a config hint (F143)', () async {
    final recorder = _Recorder();
    final manager = _manager(recorder);
    await manager.setAuth('fixed');
    await manager.handleAuthError(
      const AuthError(
        error: 'No auth provider found matching the given token',
        baseVersion: 0,
        authUpdateAttempted: true,
      ),
      currentAuthVersion: 1,
    );

    final giveUp = recorder.logs.singleWhere(
      (log) => log.message.startsWith('Failed to authenticate'),
    );
    expect(giveUp.level, DartvexLogLevel.error);
    expect(giveUp.message, contains('No auth provider found'));
    expect(giveUp.message, contains('check your server auth config'));
    final received = recorder.logs.firstWhere(
      (log) => log.message == 'Auth error received from backend',
    );
    expect(received.data!['error'], contains('No auth provider found'));
  });

  group('refresh scheduling against clock skew (F43, C2)', () {
    test(
        'a fresh token schedules from its lifetime even if the device clock '
        'is far ahead', () async {
      final recorder = _Recorder();
      final manager = _manager(recorder);
      // Issued by a server whose clock is two hours behind this device: by
      // the device clock the token has already expired.
      final serverNow = _nowSeconds() - 7200;
      final fresh = _jwt(subject: 'f', iat: serverNow, exp: serverNow + 60);
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async =>
            forceRefresh ? fresh : null,
      );
      manager.handleAuthConfirmed();

      expect(recorder.scheduledDelaysMs, <int>[50000]);
      await manager.stopRefreshing();
    });

    test(
        'a pushed token schedules from the server-corrected remaining '
        'lifetime', () async {
      final recorder = _Recorder();
      const clientNowMs = 1000000 * 1000;
      final manager = _manager(recorder, clientNowMillis: () => clientNowMs);
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async =>
            forceRefresh ? 'unused' : null,
      );
      // Aged token: 1h lifetime, 100s left by the server's clock. The device
      // clock reads 30s ahead of the server (skew +30000ms).
      final pushed = _jwt(subject: 'p', iat: 1000000 - 3500, exp: 1000000 + 70);
      await manager.updateToken(pushed);
      manager.handleAuthConfirmed(clientClockSkew: 30000);

      expect(recorder.scheduledDelaysMs.last, 90000);
      await manager.stopRefreshing();
    });

    test('a pushed token without a skew estimate is floored', () async {
      final recorder = _Recorder();
      final manager = _manager(recorder);
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async =>
            forceRefresh ? 'unused' : null,
      );
      final now = _nowSeconds();
      // Already expired by the device clock.
      final pushed = _jwt(subject: 'p', iat: now - 3700, exp: now - 100);
      await manager.updateToken(pushed);
      manager.handleAuthConfirmed();

      expect(recorder.scheduledDelaysMs.last, 5000);
      await manager.stopRefreshing();
    });
  });

  group('initialAuthTokenReuse (C0)', () {
    Future<(int, _Recorder)> confirmCachedToken({
      required bool reuse,
      double? clientClockSkew,
    }) async {
      final recorder = _Recorder();
      const clientNowMs = 2000000 * 1000;
      final manager = _manager(
        recorder,
        initialAuthTokenReuse: reuse,
        clientNowMillis: () => clientNowMs,
      );
      var forced = 0;
      final cached =
          _jwt(subject: 'c', iat: 2000000 - 3000, exp: 2000000 + 600);
      await manager.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async {
          if (forceRefresh) {
            forced += 1;
            return _jwt(subject: 'f$forced', iat: 2000000, exp: 2003600);
          }
          return cached;
        },
      );
      manager.handleAuthConfirmed(clientClockSkew: clientClockSkew);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await manager.stopRefreshing();
      return (forced, recorder);
    }

    test('off by default: a confirmed cached token is refetched at once',
        () async {
      final (forced, recorder) =
          await confirmCachedToken(reuse: false, clientClockSkew: 0);
      expect(forced, 1);
      expect(recorder.scheduledDelaysMs, isEmpty);
    });

    test(
        'on: the cached token is kept and refreshed before it expires by the '
        "server's clock", () async {
      final (forced, recorder) =
          await confirmCachedToken(reuse: true, clientClockSkew: -20000);
      expect(forced, 0);
      // Server clock 20s ahead of the client: 580s left, minus 10s leeway.
      expect(recorder.scheduledDelaysMs, <int>[570000]);
    });

    test('on, but no skew reported: falls back to the immediate refetch',
        () async {
      final (forced, recorder) = await confirmCachedToken(reuse: true);
      expect(forced, 1);
      expect(recorder.scheduledDelaysMs, isEmpty);
    });
  });

  group('computeRefreshDelay', () {
    test('remainingLifetimeOnly uses exp - now alone', () {
      expect(
        AuthManager.computeRefreshDelay(
          iat: 0,
          exp: 1000,
          leewaySeconds: 10,
          nowMillis: 900 * 1000,
          remainingLifetimeOnly: true,
        ),
        const Duration(seconds: 90),
      );
    });

    test('minimumDelayMs floors the delay but never exceeds the lifetime', () {
      expect(
        AuthManager.computeRefreshDelay(
          iat: 0,
          exp: 1000,
          leewaySeconds: 10,
          nowMillis: 5000 * 1000,
          minimumDelayMs: 5000,
        ),
        const Duration(seconds: 5),
      );
      expect(
        AuthManager.computeRefreshDelay(
          iat: 0,
          exp: 12,
          leewaySeconds: 10,
          nowMillis: 5000 * 1000,
          minimumDelayMs: 5000,
        ),
        const Duration(seconds: 2),
      );
    });
  });
}
