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
}

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

  Future<Map<String, dynamic>> waitForAuthenticate(
    bool Function(Map<String, dynamic> message) where,
  ) async {
    bool matches(Map<String, dynamic> message) =>
        message['type'] == 'Authenticate' && where(message);
    await _waitUntil(() => sent.any(matches), reason: 'Authenticate message');
    return sent.lastWhere(matches);
  }

  /// Acknowledges the pending Authenticate by advancing the identity version.
  void confirmAuth() {
    _messages.add(
      jsonEncode({
        'type': 'Transition',
        'startVersion': {'querySet': 0, 'identity': 0, 'ts': 'AAAAAAAAAAA='},
        'endVersion': {'querySet': 0, 'identity': 1, 'ts': 'AQAAAAAAAAA='},
        'modifications': <Object>[],
      }),
    );
  }
}
