import 'dart:convert';

import 'package:dartvex_auth_better/dartvex_auth_better.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('ConvexBetterAuthProvider', () {
    const baseUrl = 'https://test-app.convex.cloud';

    /// Builds a mock HTTP client that handles sign-in, sign-up, sign-out,
    /// get-session, and convex/token endpoints.
    MockClient buildMock({
      String sessionToken = 'ses_mock',
      String convexToken = 'jwt_mock',
      bool sessionValid = true,
      int? getSessionStatus,
      Object? getSessionBody,
      int signOutStatus = 200,
      void Function(http.Request request)? onRequest,
    }) {
      return MockClient((request) async {
        onRequest?.call(request);
        final path = request.url.path;

        if (path == '/api/auth/sign-in/email' && request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'user': {
                'id': 'u1',
                'email': body['email'],
                'name': 'Test User',
              },
              'session': {'id': 's1', 'userId': 'u1'},
            }),
            200,
            headers: {'set-auth-token': sessionToken},
          );
        }

        if (path == '/api/auth/sign-up/email' && request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'user': {
                'id': 'u1',
                'email': body['email'],
                'name': body['name'],
              },
              'session': {'id': 's1', 'userId': 'u1'},
            }),
            200,
            headers: {'set-auth-token': sessionToken},
          );
        }

        if (path == '/api/auth/convex/token' && request.method == 'GET') {
          return http.Response(
            jsonEncode({'token': convexToken}),
            200,
          );
        }

        if (path == '/api/auth/sign-out' && request.method == 'POST') {
          return http.Response('', signOutStatus);
        }

        if (path == '/api/auth/get-session' && request.method == 'GET') {
          final status = getSessionStatus;
          if (status != null) {
            final body = getSessionBody;
            return http.Response(
              body is String ? body : jsonEncode(body ?? {}),
              status,
            );
          }
          if (sessionValid) {
            return http.Response(
              jsonEncode({
                'session': {'id': 's1', 'userId': 'u1'},
                'user': {
                  'id': 'u1',
                  'email': 'alice@example.com',
                  'name': 'Alice',
                },
              }),
              200,
            );
          }
          return http.Response('Unauthorized', 401);
        }

        return http.Response('Not found', 404);
      });
    }

    test('login calls signIn and invokes onIdToken', () async {
      final mock = buildMock(convexToken: 'jwt_login');
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      provider.email = 'alice@example.com';
      provider.password = 'password123';

      String? receivedToken;
      final session = await provider.login(
        onIdToken: (token) => receivedToken = token,
      );

      expect(session.token, 'jwt_login');
      expect(session.email, 'alice@example.com');
      expect(receivedToken, 'jwt_login');
      expect(provider.cachedSession, isNotNull);
    });

    test('login throws when credentials not set', () async {
      final mock = buildMock();
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      expect(
        () => provider.login(onIdToken: (_) {}),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('Set email and password'),
        )),
      );
    });

    test('loginFromCache refreshes session', () async {
      final mock = buildMock(convexToken: 'jwt_refreshed');
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      // First login to populate cache.
      provider.email = 'alice@example.com';
      provider.password = 'password123';
      await provider.login(onIdToken: (_) {});

      String? refreshedToken;
      final session = await provider.loginFromCache(
        onIdToken: (token) => refreshedToken = token,
      );

      expect(session.token, 'jwt_refreshed');
      expect(refreshedToken, 'jwt_refreshed');
    });

    test('loginFromCache throws when no cached session', () async {
      final mock = buildMock();
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      expect(
        () => provider.loginFromCache(onIdToken: (_) {}),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('No cached'),
        )),
      );
    });

    test(
        'loginFromCache restores a session seeded via initialSessionToken '
        'without a prior login in this process', () async {
      final sessionRequests = <String?>[];
      final mock = buildMock(
        convexToken: 'jwt_restored',
        onRequest: (request) {
          if (request.url.path == '/api/auth/get-session') {
            sessionRequests.add(request.headers['Authorization']);
          }
        },
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(
        client: client,
        initialSessionToken: 'ses_persisted',
      );

      String? restoredToken;
      final session = await provider.loginFromCache(
        onIdToken: (token) => restoredToken = token,
      );

      expect(sessionRequests, ['Bearer ses_persisted']);
      expect(session.token, 'jwt_restored');
      expect(restoredToken, 'jwt_restored');
      expect(provider.cachedSession, same(session));
    });

    test('loginFromCache propagates server errors and keeps cached session',
        () async {
      final mock = buildMock(
        convexToken: 'jwt_login',
        getSessionStatus: 503,
        getSessionBody: {'message': 'temporary outage'},
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      provider.email = 'alice@example.com';
      provider.password = 'password123';
      final originalSession = await provider.login(onIdToken: (_) {});

      await expectLater(
        () => provider.loginFromCache(onIdToken: (_) {}),
        throwsA(
          isA<BetterAuthException>()
              .having((error) => error.retryable, 'retryable', isTrue)
              .having(
                (error) => error.message,
                'message',
                contains('temporary outage'),
              ),
        ),
      );
      expect(provider.cachedSession, same(originalSession));
    });

    test('loginFromCache keeps cached session when Convex token refresh fails',
        () async {
      var tokenRequests = 0;
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/sign-in/email') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'user': {
                'id': 'u1',
                'email': body['email'],
                'name': 'Test User',
              },
              'session': {'id': 's1', 'userId': 'u1'},
            }),
            200,
            headers: {'set-auth-token': 'ses_mock'},
          );
        }
        if (request.url.path == '/api/auth/get-session') {
          return http.Response(
            jsonEncode({
              'session': {'id': 's1', 'userId': 'u1'},
              'user': {
                'id': 'u1',
                'email': 'alice@example.com',
                'name': 'Alice',
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/auth/convex/token') {
          tokenRequests += 1;
          if (tokenRequests == 1) {
            return http.Response(jsonEncode({'token': 'jwt_login'}), 200);
          }
          return http.Response(
            jsonEncode({'message': 'token service unavailable'}),
            503,
          );
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      provider.email = 'alice@example.com';
      provider.password = 'password123';
      final originalSession = await provider.login(onIdToken: (_) {});

      await expectLater(
        () => provider.loginFromCache(onIdToken: (_) {}),
        throwsA(
          isA<BetterAuthException>()
              .having((error) => error.retryable, 'retryable', isTrue)
              .having(
                (error) => error.message,
                'message',
                contains('token service unavailable'),
              ),
        ),
      );
      expect(provider.cachedSession, same(originalSession));
    });

    test('loginFromCache throws when session expired', () async {
      final mock = buildMock(sessionValid: false);
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      // Manually set a session token so loginFromCache attempts refresh.
      provider.email = 'alice@example.com';
      provider.password = 'password123';
      // Login first to get a cached session token.
      await provider.login(onIdToken: (_) {});
      // Now the mock will return 401 for get-session.

      expect(
        () => provider.loginFromCache(onIdToken: (_) {}),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('expired'),
        )),
      );
    });

    test('logout clears cached session', () async {
      final mock = buildMock();
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      provider.email = 'alice@example.com';
      provider.password = 'password123';
      await provider.login(onIdToken: (_) {});
      expect(provider.cachedSession, isNotNull);

      await provider.logout();
      expect(provider.cachedSession, isNull);
    });

    test('logout clears cached session when sign-out fails', () async {
      final mock = buildMock(signOutStatus: 500);
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      provider.email = 'alice@example.com';
      provider.password = 'password123';
      await provider.login(onIdToken: (_) {});
      expect(provider.cachedSession, isNotNull);

      await expectLater(provider.logout(), throwsA(isA<BetterAuthException>()));
      expect(provider.cachedSession, isNull);
      await expectLater(
        provider.loginFromCache(onIdToken: (_) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('logout is safe when no session exists', () async {
      final mock = buildMock();
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      // Should not throw.
      await provider.logout();
      expect(provider.cachedSession, isNull);
    });

    test('signUp registers and caches credentials', () async {
      final mock = buildMock(convexToken: 'jwt_signup');
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      String? receivedToken;
      final session = await provider.signUp(
        name: 'Alice',
        email: 'alice@example.com',
        password: 'password123',
        onIdToken: (token) => receivedToken = token,
      );

      expect(session.token, 'jwt_signup');
      expect(session.name, 'Alice');
      expect(receivedToken, 'jwt_signup');
      expect(provider.email, 'alice@example.com');
      expect(provider.password, 'password123');
      expect(provider.cachedSession, isNotNull);
    });

    test('login reuses session created by signUp', () async {
      final requests = <String>[];
      final mock = buildMock(
        convexToken: 'jwt_signup',
        onRequest: (request) {
          requests.add('${request.method} ${request.url.path}');
        },
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      final signUpSession = await provider.signUp(
        name: 'Alice',
        email: 'alice@example.com',
        password: 'password123',
        onIdToken: (_) {},
      );

      String? receivedToken;
      final loginSession = await provider.login(
        onIdToken: (token) => receivedToken = token,
      );

      expect(loginSession, same(signUpSession));
      expect(receivedToken, 'jwt_signup');
      expect(
        requests.where((request) => request == 'POST /api/auth/sign-up/email'),
        hasLength(1),
      );
      expect(
        requests.where((request) => request == 'POST /api/auth/sign-in/email'),
        isEmpty,
      );
    });

    test('login ignores signUp session when credentials change', () async {
      final requests = <String>[];
      final mock = buildMock(
        convexToken: 'jwt_login',
        onRequest: (request) {
          requests.add('${request.method} ${request.url.path}');
        },
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      await provider.signUp(
        name: 'Alice',
        email: 'alice@example.com',
        password: 'password123',
        onIdToken: (_) {},
      );
      provider.email = 'bob@example.com';
      provider.password = 'different123';

      String? receivedToken;
      final session = await provider.login(
        onIdToken: (token) => receivedToken = token,
      );

      expect(session.email, 'bob@example.com');
      expect(receivedToken, 'jwt_login');
      expect(
        requests.where((request) => request == 'POST /api/auth/sign-in/email'),
        hasLength(1),
      );
    });

    test('extractIdToken returns the JWT', () {
      final mock = buildMock();
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      const session = BetterAuthSession(
        sessionToken: 'sess_test',
        token: 'jwt_abc',
        userId: 'u1',
        email: 'a@b.com',
      );
      expect(provider.extractIdToken(session), 'jwt_abc');
    });
  });
}
