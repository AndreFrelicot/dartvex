// Regression tests for the 2026-11 post-release review of ConvexClientWithAuth
// and JWT parsing (findings F25/F47, F50, F51, F139, F140, F141, F145, F146,
// F227).
import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/auth/jwt_utils.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

typedef _AuthStates = List<AuthState<_Session>>;

Future<void> _until(bool Function() condition, {String? reason}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > const Duration(seconds: 3)) {
      fail('Timed out waiting for ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

class _Harness {
  _Harness() {
    client = ConvexClient(
      'https://demo.convex.cloud',
      config: ConvexClientConfig(
        adapterFactory: (_) => adapter,
        reconnectBackoff: const <Duration>[Duration.zero],
      ),
    );
    auth = client.withAuth<_Session>(provider);
    subscription = auth.authState.listen(states.add);
  }

  final _ConfirmingAdapter adapter = _ConfirmingAdapter();
  final _ScriptedProvider provider = _ScriptedProvider();
  late final ConvexClient client;
  late final ConvexClientWithAuth<_Session> auth;
  final _AuthStates states = <AuthState<_Session>>[];
  late final StreamSubscription<AuthState<_Session>> subscription;

  List<String?> get sentTokens => adapter.decodedSentMessages
      .where((message) => message['type'] == 'Authenticate')
      .map((message) => message['value'] as String?)
      .toList(growable: false);

  bool get isAuthenticatedState =>
      auth.currentAuthState is AuthAuthenticated<_Session>;

  void pushAuthError() {
    adapter.pushServerMessage(<String, dynamic>{
      'type': 'AuthError',
      'error': 'Token expired',
      'baseVersion': client.isAuthenticated ? adapter.confirmedIdentity - 1 : 0,
      'authUpdateAttempted': true,
    });
  }

  Future<void> close() async {
    await subscription.cancel();
    auth.dispose();
    await client.close();
  }
}

void main() {
  group('ConvexClientWithAuth token pushes and server-driven logout (F145)',
      () {
    test('a provider push of a rotated token reaches the client', () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.auth.login();
      await _until(() => h.isAuthenticatedState, reason: 'authenticated');

      h.provider.loginCallbacks.last('rotated-token');
      await _until(() => h.sentTokens.contains('rotated-token'));
      expect(h.auth.currentAuthToken, 'rotated-token');
      expect(h.client.currentAuthToken, 'rotated-token');
      expect(h.isAuthenticatedState, isTrue);
    });

    test('a provider push of null signs out', () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.auth.login();
      await _until(() => h.isAuthenticatedState);

      h.provider.loginCallbacks.last(null);
      await _until(
        () => h.auth.currentAuthState is AuthUnauthenticated<_Session>,
      );
      expect(h.client.currentAuthToken, isNull);
      expect(h.sentTokens.last, isNull);
    });

    test('a server rejection the provider cannot fix signs out', () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.auth.login();
      await _until(() => h.isAuthenticatedState && h.client.isAuthenticated);

      // The provider's refresh returns the very token the server rejects.
      h.pushAuthError();
      await _until(
        () => h.auth.currentAuthState is AuthUnauthenticated<_Session>,
        reason: 'unauthenticated after rejection',
      );
      expect(h.client.isAuthenticated, isFalse);
      expect(h.client.currentAuthToken, isNull);
    });
  });

  test("an old flow's failure during a new login does not cancel it (F51)",
      () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.auth.login();
    await _until(() => h.isAuthenticatedState && h.client.isAuthenticated);

    final gate = Completer<void>();
    h.provider
      ..loginGate = gate
      ..nextLogin = const _Session(user: 'bob', token: 'bob-token');
    final login = h.auth.login();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    // Alice's token is rejected and her reauth fails while Bob's login runs.
    h.provider.cachedOverride = const _Session(
      user: 'alice',
      token: 'login-token-1',
    );
    h.pushAuthError();
    await _until(() => !h.client.isAuthenticated);
    expect(h.auth.currentAuthState, isA<AuthLoading<_Session>>());
    h.provider.cachedOverride = null;

    gate.complete();
    final session = await login;
    expect(session.user, 'bob');
    await _until(() => h.isAuthenticatedState, reason: 'bob authenticated');
    expect(
      (h.auth.currentAuthState as AuthAuthenticated<_Session>).userInfo.user,
      'bob',
    );
    expect(h.client.currentAuthToken, 'bob-token');
  });

  test('a login started while logout is signing out is kept (F25, F47)',
      () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.auth.login();
    await _until(() => h.isAuthenticatedState);

    final signOut = Completer<void>();
    h.provider.logoutGate = signOut;
    final logout = h.auth.logout();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    h.provider.nextLogin = const _Session(user: 'bob', token: 'bob-token');
    final session = await h.auth.login();
    expect(session.user, 'bob');
    await _until(() => h.isAuthenticatedState, reason: 'bob authenticated');

    signOut.complete();
    await logout;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.isAuthenticatedState, isTrue);
    expect(h.client.currentAuthToken, 'bob-token');
  });

  test('logout still clears local state when the provider throws', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.auth.login();
    await _until(() => h.isAuthenticatedState);

    h.provider.logoutError = StateError('network');
    await expectLater(h.auth.logout(), throwsStateError);
    expect(h.auth.currentAuthState, isA<AuthUnauthenticated<_Session>>());
    expect(h.client.currentAuthToken, isNull);
  });

  test('loginFromCache from an authState listener works (F50)', () async {
    final h = _Harness();
    addTearDown(h.close);
    final errors = <Object>[];
    final restored = Completer<void>();
    final listener = h.auth.authState.listen((state) {
      if (state is AuthUnauthenticated<_Session> && !restored.isCompleted) {
        restored.complete();
        h.auth.loginFromCache().then((_) {}, onError: errors.add);
      }
    });
    addTearDown(listener.cancel);
    await h.auth.login();
    await _until(() => h.isAuthenticatedState);

    h.provider.cachedOverride = const _Session(
      user: 'alice',
      token: 'cached-token',
    );
    await h.auth.logout();
    await _until(() => h.isAuthenticatedState, reason: 'restored from cache');
    expect(h.client.currentAuthToken, 'cached-token');
    expect(errors, isEmpty);
    // Listeners saw the states in order.
    final kinds = h.states.map((state) => state.runtimeType.toString());
    expect(
      kinds
          .toList()
          .sublist(kinds.toList().lastIndexOf('AuthUnauthenticated<_Session>')),
      <String>[
        'AuthUnauthenticated<_Session>',
        'AuthLoading<_Session>',
        'AuthAuthenticated<_Session>',
      ],
    );
  });

  group('a failed login while signed in (F139)', () {
    test('keeps the existing session', () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.auth.login();
      await _until(() => h.isAuthenticatedState && h.client.isAuthenticated);
      final tokenBefore = h.client.currentAuthToken;

      h.provider.cacheError = StateError('network blip');
      await expectLater(h.auth.loginFromCache(), throwsStateError);

      expect(h.isAuthenticatedState, isTrue);
      expect(h.client.currentAuthToken, tokenBefore);
      expect(h.client.isAuthenticated, isTrue);
    });

    test('the kept session still reacts to provider pushes and failures',
        () async {
      final h = _Harness();
      addTearDown(h.close);
      await h.auth.login();
      await _until(() => h.isAuthenticatedState && h.client.isAuthenticated);

      h.provider.loginError = StateError('cancelled');
      await expectLater(h.auth.login(), throwsStateError);
      expect(h.isAuthenticatedState, isTrue);

      // The original flow's callbacks are live again.
      h.provider.loginCallbacks.first('rotated');
      await _until(() => h.client.currentAuthToken == 'rotated');
      h.provider.loginCallbacks.first(null);
      await _until(
        () => h.auth.currentAuthState is AuthUnauthenticated<_Session>,
      );
    });

    test('a failed first login still ends unauthenticated', () async {
      final h = _Harness();
      addTearDown(h.close);
      h.provider.loginError = StateError('cancelled');
      await expectLater(h.auth.login(), throwsStateError);
      expect(h.auth.currentAuthState, isA<AuthUnauthenticated<_Session>>());
    });
  });

  test(
      'a token pushed after the client closed is not an uncaught error '
      '(F140)', () async {
    final errors = <Object>[];
    await runZonedGuarded(() async {
      final h = _Harness();
      await h.auth.login();
      await _until(() => h.isAuthenticatedState);
      await h.client.close();

      h.provider.loginCallbacks.last('late-token');
      h.provider.loginCallbacks.last(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await h.subscription.cancel();
      h.auth.dispose();
    }, (error, stackTrace) => errors.add(error));
    expect(errors, isEmpty);
  });

  test(
      'background refreshes call loginFromCache marked as refreshes; an '
      'explicit loginFromCache is not marked', () async {
    final h = _Harness();
    addTearDown(h.close);
    await h.auth.login();
    // The client refetches a token through loginFromCache once the server
    // confirmed the login token.
    await _until(
      () => h.provider.cacheCallIsRefresh.isNotEmpty,
      reason: 'post-confirmation refresh',
    );
    expect(h.provider.cacheCallIsRefresh, everyElement(isTrue));

    final refreshes = h.provider.cacheCallIsRefresh.length;
    await h.auth.loginFromCache();
    expect(h.provider.cacheCallIsRefresh[refreshes], isFalse);
  });

  test('ConvexClient exposes isAuthenticated and currentAuthToken (F141, F146)',
      () async {
    final h = _Harness();
    addTearDown(h.close);
    expect(h.client.isAuthenticated, isFalse);
    expect(h.client.currentAuthToken, isNull);
    await h.auth.login();
    await _until(() => h.client.isAuthenticated);
    expect(h.client.currentAuthToken, 'login-token-1');
    expect(h.auth.currentAuthToken, 'login-token-1');
  });

  test('authTokenType other than User or Admin is rejected (F227)', () {
    for (final type in <String>['None', 'user', 'admin']) {
      expect(
        () => ConvexClient(
          'https://demo.convex.cloud',
          config: ConvexClientConfig(
            authTokenType: type,
            connectImmediately: false,
          ),
        ),
        throwsArgumentError,
        reason: type,
      );
    }
  });

  test('authTokenType Admin is still accepted for server-side use', () async {
    final client = ConvexClient(
      'https://demo.convex.cloud',
      config: const ConvexClientConfig(
        authTokenType: 'Admin',
        connectImmediately: false,
      ),
    );
    await client.close();
  });

  group('jwt claim parsing (F145)', () {
    String token(Object payload, {bool rawPayload = false}) {
      final body = rawPayload
          ? payload as String
          : base64UrlEncode(utf8.encode(jsonEncode(payload)))
              .replaceAll('=', '');
      return 'header.$body.signature';
    }

    test('reads numeric claims, coercing doubles', () {
      final jwt = token(<String, Object?>{'exp': 1700000000.9, 'iat': 17});
      expect(jwtExp(jwt), 1700000000);
      expect(jwtIat(jwt), 17);
    });

    test('missing or non-numeric claims read as null', () {
      final jwt = token(<String, Object?>{'exp': 'soon', 'iat': null});
      expect(jwtExp(jwt), isNull);
      expect(jwtIat(jwt), isNull);
      expect(jwtExp(token(<String, Object?>{})), isNull);
    });

    test('malformed tokens throw FormatException', () {
      expect(() => decodeJwtPayload('no-dots'), throwsFormatException);
      expect(
        () => decodeJwtPayload(token('!!!not-base64!!!', rawPayload: true)),
        throwsFormatException,
      );
      expect(
        () => decodeJwtPayload(
          token(base64UrlEncode(utf8.encode('[1,2]')), rawPayload: true),
        ),
        throwsFormatException,
      );
    });
  });
}

class _Session {
  const _Session({required this.user, required this.token});

  final String user;
  final String token;
}

class _ScriptedProvider implements AuthProvider<_Session> {
  /// `onIdToken` callbacks passed to [login] (the wrapper's flow callbacks).
  final List<void Function(String? token)> loginCallbacks =
      <void Function(String? token)>[];

  /// `onIdToken` callbacks passed to [loginFromCache].
  final List<void Function(String? token)> cacheCallbacks =
      <void Function(String? token)>[];

  /// For every [loginFromCache] call, whether it ran as a background token
  /// refresh (`Zone.current[#dartvex.authTokenRefresh] == true`).
  final List<bool> cacheCallIsRefresh = <bool>[];
  int _logins = 0;
  _Session? nextLogin;
  _Session? _session;
  _Session? cachedOverride;
  Completer<void>? loginGate;
  Completer<void>? logoutGate;
  Object? loginError;
  Object? cacheError;
  Object? logoutError;

  @override
  String extractIdToken(_Session authResult) => authResult.token;

  @override
  Future<_Session> login({
    required void Function(String? token) onIdToken,
  }) async {
    loginCallbacks.add(onIdToken);
    final gate = loginGate;
    loginGate = null;
    if (gate != null) {
      await gate.future;
    }
    final error = loginError;
    if (error != null) {
      loginError = null;
      throw error;
    }
    _logins += 1;
    final session =
        nextLogin ?? _Session(user: 'alice', token: 'login-token-$_logins');
    nextLogin = null;
    _session = session;
    return session;
  }

  @override
  Future<_Session> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    cacheCallIsRefresh.add(Zone.current[#dartvex.authTokenRefresh] == true);
    final error = cacheError;
    if (error != null) {
      cacheError = null;
      throw error;
    }
    final session = cachedOverride ?? _session;
    if (session == null) {
      throw StateError('no session');
    }
    cacheCallbacks.add(onIdToken);
    return session;
  }

  @override
  Future<void> logout() async {
    final gate = logoutGate;
    logoutGate = null;
    if (gate != null) {
      await gate.future;
    }
    _session = null;
    final error = logoutError;
    if (error != null) {
      logoutError = null;
      throw error;
    }
  }
}

/// Confirms every `Authenticate` with an identity-advancing Transition, as
/// the server does.
class _ConfirmingAdapter extends MockWebSocketAdapter {
  int _serverTs = 0;
  int confirmedIdentity = 0;

  @override
  void send(String message) {
    super.send(message);
    final decoded = jsonDecode(message) as Map<String, dynamic>;
    if (decoded['type'] == 'Connect') {
      // A new socket starts a fresh server session at the initial version.
      _serverTs = 0;
      return;
    }
    if (decoded['type'] != 'Authenticate') {
      return;
    }
    final baseVersion = decoded['baseVersion'] as int;
    final startTs = _serverTs;
    _serverTs += 1;
    confirmedIdentity = baseVersion + 1;
    pushServerMessage(
      Transition(
        startVersion: StateVersion(
          querySet: 0,
          identity: baseVersion,
          ts: encodeTs(startTs),
        ),
        endVersion: StateVersion(
          querySet: 0,
          identity: baseVersion + 1,
          ts: encodeTs(_serverTs),
        ),
        modifications: const <StateModification>[],
      ).toJson(),
    );
  }
}
