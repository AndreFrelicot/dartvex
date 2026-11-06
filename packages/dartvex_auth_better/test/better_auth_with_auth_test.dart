import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex_auth_better/dartvex_auth_better.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Drives [ConvexBetterAuthProvider] through `ConvexClient.withAuth` with a
/// fake WebSocket and a mocked Better Auth server.
void main() {
  group('ConvexBetterAuthProvider with ConvexClientWithAuth', () {
    const deploymentUrl = 'https://test-app.convex.cloud';

    late _FakeWebSocketAdapter adapter;
    late List<String> httpRequests;
    late ConvexClient convex;
    late ConvexBetterAuthProvider provider;
    late ConvexClientWithAuth<BetterAuthSession> authed;
    var sessionValid = true;
    var tokenCounter = 0;

    setUp(() {
      adapter = _FakeWebSocketAdapter();
      httpRequests = <String>[];
      sessionValid = true;
      tokenCounter = 0;
      final mock = MockClient((request) async {
        final path = request.url.path;
        final auth = request.headers['Authorization'];
        httpRequests
            .add('${request.method} $path${auth == null ? '' : ' $auth'}');
        if (path == '/api/auth/sign-in/email') {
          return http.Response(
            jsonEncode({
              'user': {'id': 'u1', 'email': 'alice@example.com'},
              'session': {'id': 's1', 'userId': 'u1'},
            }),
            200,
            headers: {
              'set-auth-token': 'ses_alice',
              // @convex-dev/better-auth 0.13 expires the JWT cookie here.
              'set-cookie': 'better-auth.convex_jwt=; Max-Age=0; Path=/',
            },
          );
        }
        if (path == '/api/auth/get-session') {
          if (!sessionValid) {
            return http.Response('null', 200);
          }
          return http.Response(
            jsonEncode({
              'session': {'id': 's1', 'userId': 'u1'},
              'user': {'id': 'u1', 'email': 'alice@example.com'},
            }),
            200,
          );
        }
        if (path == '/api/auth/convex/token') {
          tokenCounter += 1;
          return http.Response(jsonEncode({'token': 'jwt_$tokenCounter'}), 200);
        }
        if (path == '/api/auth/sign-out') {
          return http.Response(jsonEncode({'success': true}), 200);
        }
        return http.Response('Not found', 404);
      });
      convex = ConvexClient(
        deploymentUrl,
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      provider = ConvexBetterAuthProvider(
        client: BetterAuthClient(baseUrl: deploymentUrl, httpClient: mock),
      );
      authed = convex.withAuth<BetterAuthSession>(provider);
    });

    tearDown(() {
      authed.dispose();
    });

    test('login sends the fetched Convex JWT and logout clears everything',
        () async {
      provider.email = 'alice@example.com';
      provider.password = 'pw';

      final session = await authed.login();
      expect(session.token, 'jwt_1');
      final auth = await adapter.waitForAuthenticate(
        (message) => message['value'] == 'jwt_1',
      );
      expect(auth['tokenType'], 'User');

      adapter.confirmAuth();
      await _waitUntil(
        () => authed.currentAuthState is AuthAuthenticated<BetterAuthSession>,
        reason: 'authenticated state',
      );

      await authed.logout();

      expect(
          httpRequests, contains('POST /api/auth/sign-out Bearer ses_alice'));
      expect(authed.currentAuthState,
          isA<AuthUnauthenticated<BetterAuthSession>>());
      expect(provider.cachedSession, isNull);
      expect(provider.email, isNull);
      expect(provider.password, isNull);
      await adapter.waitForAuthenticate(
        (message) => message['tokenType'] == 'None',
      );
    });

    test('loginFromCache with an expired persisted session throws StateError',
        () async {
      sessionValid = false;
      provider = ConvexBetterAuthProvider(
        client: provider.client,
        initialSessionToken: 'ses_dead',
      );
      authed.dispose();
      convex = ConvexClient(
        deploymentUrl,
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      authed = convex.withAuth<BetterAuthSession>(provider);

      await expectLater(
        authed.loginFromCache(),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('expired')),
        ),
      );
      expect(authed.currentAuthState,
          isA<AuthUnauthenticated<BetterAuthSession>>());
      expect(provider.cachedSession, isNull);
      expect(
        httpRequests.where((request) => request.contains('/convex/token')),
        isEmpty,
      );
    });

    test('loginFromCache restores an adopted session', () async {
      provider.adoptSession(
        const BetterAuthSession(
          token: 'jwt_magic',
          sessionToken: 'ses_magic',
          userId: 'u1',
          email: 'alice@example.com',
        ),
      );

      final session = await authed.loginFromCache();

      expect(session.sessionToken, 'ses_magic');
      expect(httpRequests.first, 'GET /api/auth/get-session Bearer ses_magic');
      await adapter.waitForAuthenticate(
        (message) => message['value'] == session.token,
      );
    });
  });

  group('identity races against a gated Better Auth server', () {
    const deploymentUrl = 'https://test-app.convex.cloud';

    late _FakeWebSocketAdapter adapter;
    late _GatedBetterAuthServer server;
    late ConvexBetterAuthProvider provider;
    late ConvexClientWithAuth<BetterAuthSession> authed;

    setUp(() {
      adapter = _FakeWebSocketAdapter();
      server = _GatedBetterAuthServer();
      final convex = ConvexClient(
        deploymentUrl,
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      provider = ConvexBetterAuthProvider(
        client: BetterAuthClient(
          baseUrl: deploymentUrl,
          httpClient: server.mock,
        ),
      );
      authed = convex.withAuth<BetterAuthSession>(provider);
    });

    tearDown(() {
      authed.dispose();
    });

    String? authenticatedSessionToken() {
      final state = authed.currentAuthState;
      return state is AuthAuthenticated<BetterAuthSession>
          ? state.userInfo.sessionToken
          : null;
    }

    /// Signs in as `a` and lets the client confirm the login token and the
    /// refreshed token fetched right after that confirmation.
    Future<void> signInA() async {
      provider
        ..email = 'a'
        ..password = 'pw';
      await authed.login();
      await adapter.waitForAuthenticate((m) => _isJwtOf(m['value'], 'ses_a'));
      adapter.confirmAuth();
      await _waitUntil(
        () => authenticatedSessionToken() == 'ses_a',
        reason: 'A authenticated',
      );
      // The client refetches a token through loginFromCache once the server
      // confirmed the login token; let that refresh settle.
      await _waitUntil(
        () => server.requests.contains('GET /api/auth/get-session ses_a'),
        reason: 'post-confirmation refresh',
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      adapter.confirmAuth();
      await pumpEventQueue();
    }

    /// Makes the server reject the current token and returns the token the
    /// client authenticates with after its background refresh.
    Future<String?> refreshedToken() async {
      final before =
          adapter.sent.where((m) => m['type'] == 'Authenticate').length;
      adapter.sendAuthError();
      await _waitUntil(
        () =>
            adapter.sent.where((m) => m['type'] == 'Authenticate').length >
            before,
        reason: 'Authenticate after the refresh',
      );
      return adapter.sent.lastWhere((m) => m['type'] == 'Authenticate')['value']
          as String?;
    }

    test(
        'an explicit loginFromCache started after a pending login wins on '
        'both sides', () async {
      await signInA();
      final gate = server.signInGates['b'] = Completer<void>();
      provider
        ..email = 'b'
        ..password = 'pw';
      final loginB = authed.login();
      final mark = adapter.sentCount;
      final restored = await authed.loginFromCache();
      expect(restored.sessionToken, 'ses_a');
      gate.complete();

      await expectLater(
        loginB,
        throwsA(isA<BetterAuthException>().having(
          (e) => e.message,
          'message',
          contains('superseded'),
        )),
      );
      expect(provider.cachedSession?.sessionToken, 'ses_a');
      await adapter.waitForAuthenticate(
        (m) => _isJwtOf(m['value'], 'ses_a'),
        after: mark,
      );
      adapter.confirmAuth();
      await _waitUntil(
        () => authenticatedSessionToken() == 'ses_a',
        reason: 'A authenticated again',
      );

      expect(await refreshedToken(), _jwtOf('ses_a'));
      expect(authed.currentAuthToken, _jwtOf('ses_a'));
      expect(authenticatedSessionToken(), 'ses_a');
      expect(server.requests, contains('POST /api/auth/sign-out ses_b'));
    });

    test('a background refresh does not cancel a pending login', () async {
      await signInA();
      final gate = server.signInGates['b'] = Completer<void>();
      provider
        ..email = 'b'
        ..password = 'pw';
      final loginB = authed.login();
      await _waitUntil(
        () => server.requests.contains('POST /api/auth/sign-in/email b'),
        reason: 'sign-in of b in flight',
      );

      // A's token is rejected while B's sign-in is pending: the client
      // refreshes A through the provider's loginFromCache.
      final getSessionsBefore =
          server.requests.where((r) => r.contains('get-session ses_a')).length;
      expect(await refreshedToken(), _jwtOf('ses_a'));
      expect(
        server.requests.where((r) => r.contains('get-session ses_a')).length,
        greaterThan(getSessionsBefore),
      );
      adapter.confirmAuth();

      final mark = adapter.sentCount;
      gate.complete();
      final session = await loginB;
      expect(session.sessionToken, 'ses_b');
      expect(provider.cachedSession?.sessionToken, 'ses_b');
      await adapter.waitForAuthenticate(
        (m) => _isJwtOf(m['value'], 'ses_b'),
        after: mark,
      );
      adapter.confirmAuth();
      await _waitUntil(
        () => authenticatedSessionToken() == 'ses_b',
        reason: 'B authenticated',
      );
      expect(server.requests, isNot(contains('POST /api/auth/sign-out ses_b')));
    });

    test(
        'a transient failure restoring an adopted session keeps the current '
        'session on both sides', () async {
      await signInA();
      provider.adoptSession(
        const BetterAuthSession(
          token: 'jwt_magic',
          sessionToken: 'ses_b',
          userId: 'b',
          email: 'b',
        ),
      );
      server.getSessionStatus['ses_b'] = 503;

      await expectLater(
        authed.loginFromCache(),
        throwsA(isA<BetterAuthException>()
            .having((e) => e.retryable, 'retryable', isTrue)),
      );
      expect(authenticatedSessionToken(), 'ses_a');
      expect(provider.cachedSession?.sessionToken, 'ses_a');

      server.getSessionStatus.remove('ses_b');
      expect(await refreshedToken(), _jwtOf('ses_a'));
      expect(authed.currentAuthToken, _jwtOf('ses_a'));

      // The adopted session stays staged: retrying the restore adopts it.
      final adopted = await authed.loginFromCache();
      expect(adopted.sessionToken, 'ses_b');
      expect(provider.cachedSession?.sessionToken, 'ses_b');
      await adapter.waitForAuthenticate((m) => _isJwtOf(m['value'], 'ses_b'));
    });

    for (final variant in <String, http.Response Function()>{
      '401': () => http.Response('', 401),
      '200 {}': () => http.Response('{}', 200),
      '200 HTML': () => http.Response('<html>proxy</html>', 200),
    }.entries) {
      test(
          'a login whose new session gets a Convex token ${variant.key} keeps '
          'the healthy session', () async {
        await signInA();
        server.tokenResponses['ses_b'] = variant.value;
        provider
          ..email = 'b'
          ..password = 'pw';

        await expectLater(
          authed.login(),
          throwsA(isA<BetterAuthException>().having(
            (e) => e is AuthSessionEndedError,
            'is AuthSessionEndedError',
            isFalse,
          )),
        );
        expect(authenticatedSessionToken(), 'ses_a');
        expect(provider.cachedSession?.sessionToken, 'ses_a');
        await pumpEventQueue();
        expect(server.requests, contains('POST /api/auth/sign-out ses_b'));
        expect(await refreshedToken(), _jwtOf('ses_a'));
      });
    }

    for (final variant in <String, http.Response Function()>{
      '200 {}': () => http.Response('{}', 200),
      '200 HTML': () => http.Response('<html>proxy</html>', 200),
      '200 empty token': () => http.Response('{"token":""}', 200),
    }.entries) {
      test(
          'a restore that gets a Convex token ${variant.key} keeps the '
          'healthy session', () async {
        await signInA();
        server.tokenResponses['ses_a'] = variant.value;

        await expectLater(
          authed.loginFromCache(),
          throwsA(isA<BetterAuthException>().having(
            (e) => e is AuthSessionEndedError,
            'is AuthSessionEndedError',
            isFalse,
          )),
        );
        expect(authenticatedSessionToken(), 'ses_a');
      });
    }

    test('a restore whose Convex token is rejected (401) signs out', () async {
      await signInA();
      server.tokenResponses['ses_a'] = () => http.Response('', 401);

      await expectLater(
        authed.loginFromCache(),
        throwsA(isA<BetterAuthSessionExpiredException>()),
      );
      expect(authed.currentAuthState,
          isA<AuthUnauthenticated<BetterAuthSession>>());
    });
  });
}

/// Better Auth server mock whose sign-in, get-session and token responses can
/// be held back or overridden per user / session token.
class _GatedBetterAuthServer {
  final Map<String, Completer<void>> signInGates = <String, Completer<void>>{};
  final Map<String, int> getSessionStatus = <String, int>{};
  final Map<String, http.Response Function()> tokenResponses =
      <String, http.Response Function()>{};

  /// `METHOD path bearer` for session requests, `METHOD path email` for
  /// sign-in.
  final List<String> requests = <String>[];

  final Map<String, int> _issued = <String, int>{};

  late final MockClient mock = MockClient((request) async {
    final path = request.url.path;
    final auth = request.headers['Authorization'] ?? '';
    final bearer = auth.startsWith('Bearer ') ? auth.substring(7) : '';
    if (path == '/api/auth/sign-in/email') {
      final email = (jsonDecode(request.body) as Map)['email'] as String;
      requests.add('${request.method} $path $email');
      await signInGates[email]?.future;
      return http.Response(
        jsonEncode({
          'user': {'id': email, 'email': email},
          'session': {'id': 's', 'userId': email},
        }),
        200,
        headers: {'set-auth-token': 'ses_$email'},
      );
    }
    requests.add('${request.method} $path $bearer');
    if (path == '/api/auth/get-session') {
      final status = getSessionStatus[bearer];
      if (status != null) {
        return http.Response('{"message":"unavailable"}', status);
      }
      return http.Response(
        jsonEncode({
          'session': {'id': 's', 'userId': bearer},
          'user': {'id': bearer, 'email': bearer},
        }),
        200,
      );
    }
    if (path == '/api/auth/convex/token') {
      final custom = tokenResponses[bearer];
      if (custom != null) {
        return custom();
      }
      // A fresh JWT on every fetch (`jwt_<session>_<n>`): the client rejects a
      // refresh that returns the token the server just refused.
      final n = _issued[bearer] = (_issued[bearer] ?? 0) + 1;
      return http.Response(jsonEncode({'token': 'jwt_${bearer}_$n'}), 200);
    }
    if (path == '/api/auth/sign-out') {
      return http.Response(jsonEncode({'success': true}), 200);
    }
    return http.Response('Not found', 404);
  });
}

/// Whether [value] is a JWT the gated server issued for [sessionToken].
bool _isJwtOf(Object? value, String sessionToken) =>
    value is String && value.startsWith('jwt_${sessionToken}_');

/// Matches a JWT the gated server issued for [sessionToken].
Matcher _jwtOf(String sessionToken) => startsWith('jwt_${sessionToken}_');

Future<void> _waitUntil(
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 2),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed >= timeout) {
      fail('Timed out waiting for $reason');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// Minimal in-memory [WebSocketAdapter] recording client messages.
class _FakeWebSocketAdapter implements WebSocketAdapter {
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeEvents =
      StreamController<WebSocketCloseEvent>.broadcast();
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
  bool _connected = false;

  @override
  Future<void> connect(String url) async {
    _connected = true;
    _ts = 0;
  }

  @override
  void send(String message) {
    if (!_connected) {
      throw StateError('Fake socket is disconnected');
    }
    sent.add(jsonDecode(message) as Map<String, dynamic>);
  }

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<WebSocketCloseEvent> get closeEvents => _closeEvents.stream;

  @override
  Future<void> close() async {
    if (!_connected) {
      return;
    }
    _connected = false;
    _closeEvents.add(WebSocketCloseEvent());
  }

  @override
  bool get isConnected => _connected;

  /// Number of messages sent so far; pass it as `after` to
  /// [waitForAuthenticate] to wait for a later Authenticate only.
  int get sentCount => sent.length;

  Future<Map<String, dynamic>> waitForAuthenticate(
    bool Function(Map<String, dynamic> message) where, {
    int after = 0,
  }) async {
    bool matches(Map<String, dynamic> message) =>
        message['type'] == 'Authenticate' && where(message);
    await _waitUntil(
      () => sent.skip(after).any(matches),
      reason: 'Authenticate message',
    );
    return sent.skip(after).lastWhere(matches);
  }

  int _ts = 0;

  String _encodeTs(int value) {
    final bytes = List<int>.filled(8, 0);
    var remaining = value;
    for (var i = 0; i < 8; i++) {
      bytes[i] = remaining & 0xff;
      remaining >>= 8;
    }
    return base64.encode(bytes);
  }

  int get _lastAuthBaseVersion => sent.lastWhere(
      (message) => message['type'] == 'Authenticate')['baseVersion'] as int;

  /// Acknowledges the last Authenticate by advancing the identity version.
  void confirmAuth() {
    final base = _lastAuthBaseVersion;
    _messages.add(
      jsonEncode({
        'type': 'Transition',
        'startVersion': {
          'querySet': 0,
          'identity': base,
          'ts': _encodeTs(_ts),
        },
        'endVersion': {
          'querySet': 0,
          'identity': base + 1,
          'ts': _encodeTs(++_ts),
        },
        'modifications': <Object>[],
      }),
    );
  }

  /// Rejects the last Authenticate, which makes the client fetch a fresh
  /// token through the provider's loginFromCache (a background refresh).
  void sendAuthError() {
    _messages.add(
      jsonEncode({
        'type': 'AuthError',
        'error': 'token rejected',
        'baseVersion': _lastAuthBaseVersion,
        'authUpdateAttempted': true,
      }),
    );
  }
}
