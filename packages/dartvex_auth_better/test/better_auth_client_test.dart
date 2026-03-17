import 'dart:convert';

import 'package:dartvex_auth_better/dartvex_auth_better.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('BetterAuthClient', () {
    const baseUrl = 'https://test-app.convex.cloud';
    // ignore: unused_local_variable
    const siteUrl = 'https://test-app.convex.site';

    /// Builds a [MockClient] that responds to Better Auth endpoints.
    ///
    /// [signUpResponse] / [signInResponse] — JSON body for sign-up/sign-in.
    /// [sessionToken] — value returned in the `set-auth-token` header.
    /// [convexToken] — JWT returned from `/api/auth/convex/token`.
    /// [getSessionResponse] — JSON body for get-session.
    MockClient buildMock({
      Map<String, dynamic>? signUpResponse,
      Map<String, dynamic>? signInResponse,
      String sessionToken = 'ses_mock_token',
      String convexToken = 'jwt_convex_mock',
      Map<String, dynamic>? getSessionResponse,
      int? signOutStatus,
    }) {
      return MockClient((request) async {
        final path = request.url.path;

        // POST /api/auth/sign-up/email
        if (path == '/api/auth/sign-up/email' && request.method == 'POST') {
          return http.Response(
            jsonEncode(signUpResponse ?? _defaultSignUpResponse),
            200,
            headers: {'set-auth-token': sessionToken},
          );
        }

        // POST /api/auth/sign-in/email
        if (path == '/api/auth/sign-in/email' && request.method == 'POST') {
          return http.Response(
            jsonEncode(signInResponse ?? _defaultSignInResponse),
            200,
            headers: {'set-auth-token': sessionToken},
          );
        }

        // GET /api/auth/convex/token
        if (path == '/api/auth/convex/token' && request.method == 'GET') {
          expect(
            request.headers['Authorization'],
            'Bearer $sessionToken',
          );
          return http.Response(
            jsonEncode({'token': convexToken}),
            200,
          );
        }

        // POST /api/auth/sign-out
        if (path == '/api/auth/sign-out' && request.method == 'POST') {
          return http.Response('', signOutStatus ?? 200);
        }

        // GET /api/auth/get-session
        if (path == '/api/auth/get-session' && request.method == 'GET') {
          if (getSessionResponse != null) {
            return http.Response(jsonEncode(getSessionResponse), 200);
          }
          return http.Response('Unauthorized', 401);
        }

        return http.Response('Not found', 404);
      });
    }

    test('signUp sends correct request and parses session', () async {
      final mock = buildMock(
        sessionToken: 'ses_signup_tok',
        convexToken: 'jwt_signup',
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.signUp(
        name: 'Alice',
        email: 'alice@example.com',
        password: 'password123',
      );

      expect(session.token, 'jwt_signup');
      expect(session.userId, 'user_123');
      expect(session.email, 'alice@example.com');
      expect(session.name, 'Alice');
    });

    test('signIn sends correct request and parses session', () async {
      final mock = buildMock(
        sessionToken: 'ses_signin_tok',
        convexToken: 'jwt_signin',
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.signIn(
        email: 'alice@example.com',
        password: 'password123',
      );

      expect(session.token, 'jwt_signin');
      expect(session.userId, 'user_123');
      expect(session.email, 'alice@example.com');
    });

    test('signOut sends bearer token', () async {
      String? capturedAuth;
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/sign-out') {
          capturedAuth = request.headers['Authorization'];
          return http.Response('', 200);
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await client.signOut(sessionToken: 'ses_logout');
      expect(capturedAuth, 'Bearer ses_logout');
    });

    test('getSession returns session when valid', () async {
      final mock = buildMock(
        sessionToken: 'ses_valid',
        convexToken: 'jwt_refreshed',
        getSessionResponse: {
          'session': {'id': 's1', 'userId': 'user_123'},
          'user': {
            'id': 'user_123',
            'email': 'alice@example.com',
            'name': 'Alice',
          },
        },
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.getSession(sessionToken: 'ses_valid');
      expect(session, isNotNull);
      expect(session!.token, 'jwt_refreshed');
      expect(session.userId, 'user_123');
      expect(session.email, 'alice@example.com');
      expect(session.name, 'Alice');
    });

    test('getSession returns null when unauthorized', () async {
      final mock = buildMock(); // no getSessionResponse → 401
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.getSession(sessionToken: 'ses_expired');
      expect(session, isNull);
    });

    test('converts .convex.cloud to .convex.site for HTTP requests', () async {
      final requestedHosts = <String>[];
      final mock = MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.path == '/api/auth/sign-in/email') {
          return http.Response(
            jsonEncode(_defaultSignInResponse),
            200,
            headers: {'set-auth-token': 'tok'},
          );
        }
        if (request.url.path == '/api/auth/convex/token') {
          return http.Response(jsonEncode({'token': 'jwt'}), 200);
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await client.signIn(email: 'a@b.com', password: 'p');
      expect(requestedHosts, everyElement('test-app.convex.site'));
    });

    test('throws when sign-in returns non-200', () async {
      final mock = MockClient((request) async {
        return http.Response('{"error":"invalid"}', 401);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      expect(
        () => client.signIn(email: 'a@b.com', password: 'bad'),
        throwsA(isA<StateError>()),
      );
    });

    test('throws when set-auth-token header is missing', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode(_defaultSignInResponse),
          200,
          // no set-auth-token header
        );
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      expect(
        () => client.signIn(email: 'a@b.com', password: 'p'),
        throwsA(isA<StateError>()),
      );
    });

    test('preserves baseUrl when not .convex.cloud', () async {
      final requestedHosts = <String>[];
      final mock = MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.path == '/api/auth/sign-in/email') {
          return http.Response(
            jsonEncode(_defaultSignInResponse),
            200,
            headers: {'set-auth-token': 'tok'},
          );
        }
        if (request.url.path == '/api/auth/convex/token') {
          return http.Response(jsonEncode({'token': 'jwt'}), 200);
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(
        baseUrl: 'https://localhost:3210',
        httpClient: mock,
      );

      await client.signIn(email: 'a@b.com', password: 'p');
      expect(requestedHosts, everyElement('localhost'));
    });

    test('close does not throw when using injected client', () {
      final mock = MockClient((request) async => http.Response('', 200));
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      // Should not close the injected client.
      client.close();
    });
  });

  group('BetterAuthSession', () {
    test('value equality', () {
      const a = BetterAuthSession(
        sessionToken: 'sess_test',
        token: 'jwt',
        userId: 'u1',
        email: 'a@b.com',
        name: 'Alice',
      );
      const b = BetterAuthSession(
        sessionToken: 'sess_test',
        token: 'jwt',
        userId: 'u1',
        email: 'a@b.com',
        name: 'Alice',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('inequality on different token', () {
      const a = BetterAuthSession(
        sessionToken: 'sess_test',
        token: 'jwt1',
        userId: 'u1',
        email: 'a@b.com',
      );
      const b = BetterAuthSession(
        sessionToken: 'sess_test',
        token: 'jwt2',
        userId: 'u1',
        email: 'a@b.com',
      );
      expect(a, isNot(equals(b)));
    });
  });
}

const _defaultSignUpResponse = {
  'user': {
    'id': 'user_123',
    'email': 'alice@example.com',
    'name': 'Alice',
  },
  'session': {
    'id': 'ses_123',
    'userId': 'user_123',
  },
};

const _defaultSignInResponse = {
  'user': {
    'id': 'user_123',
    'email': 'alice@example.com',
    'name': 'Alice',
  },
  'session': {
    'id': 'ses_123',
    'userId': 'user_123',
  },
};
