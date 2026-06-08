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

    test('forgotPassword uses official request-password-reset endpoint',
        () async {
      Uri? requestedUri;
      Map<String, dynamic>? requestedBody;
      final mock = MockClient((request) async {
        requestedUri = request.url;
        requestedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'status': true}), 200);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await client.forgotPassword(
        email: 'alice@example.com',
        redirectTo: 'myapp://reset-password',
      );

      expect(requestedUri!.path, '/api/auth/request-password-reset');
      expect(requestedBody, {
        'email': 'alice@example.com',
        'redirectTo': 'myapp://reset-password',
      });
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

    test('getSession throws retryable exception on server errors', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/get-session') {
          return http.Response(
            jsonEncode({'message': 'temporary outage'}),
            503,
          );
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await expectLater(
        () => client.getSession(sessionToken: 'ses_valid'),
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
    });

    test('getSession throws retryable exception when Convex token fails',
        () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/get-session') {
          return http.Response(
            jsonEncode({
              'session': {'id': 's1', 'userId': 'user_123'},
              'user': {
                'id': 'user_123',
                'email': 'alice@example.com',
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/auth/convex/token') {
          return http.Response(
            jsonEncode({'message': 'token service unavailable'}),
            503,
          );
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await expectLater(
        () => client.getSession(sessionToken: 'ses_valid'),
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
    });

    test('getSession returns null when session or user is not an object',
        () async {
      final mock = buildMock(
        sessionToken: 'ses_valid',
        getSessionResponse: {
          'session': 'not-an-object',
          'user': <String, dynamic>{'id': 'user_123'},
        },
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      // A malformed nested field must surface as null, not a raw TypeError.
      final session = await client.getSession(sessionToken: 'ses_valid');
      expect(session, isNull);
    });

    test('getSession tolerates malformed user scalar fields', () async {
      final mock = buildMock(
        sessionToken: 'ses_valid',
        convexToken: 'jwt_refreshed',
        getSessionResponse: {
          'session': {'id': 's1', 'userId': 'user_123'},
          'user': {
            'id': 123,
            'email': false,
            'name': <String>['Alice'],
          },
        },
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.getSession(sessionToken: 'ses_valid');

      expect(session, isNotNull);
      expect(session!.token, 'jwt_refreshed');
      expect(session.userId, '');
      expect(session.email, '');
      expect(session.name, isNull);
    });

    test('throws typed exception when getSession 200 body is not an object',
        () async {
      for (final body in <String>[jsonEncode('OK'), '']) {
        final mock = MockClient((request) async {
          if (request.url.path == '/api/auth/get-session') {
            return http.Response(body, 200);
          }
          return http.Response('Not found', 404);
        });
        final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

        await expectLater(
          () => client.getSession(sessionToken: 'ses_valid'),
          throwsA(isA<BetterAuthException>()),
        );
      }
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

    test('normalizes trailing slash baseUrl', () async {
      final requestedUris = <Uri>[];
      final mock = MockClient((request) async {
        requestedUris.add(request.url);
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
        baseUrl: 'https://test-app.convex.cloud/',
        httpClient: mock,
      );

      await client.signIn(email: 'a@b.com', password: 'p');

      expect(
        requestedUris.map((uri) => uri.toString()),
        everyElement(startsWith('https://test-app.convex.site/api/auth/')),
      );
    });

    test('rejects baseUrl with path query or fragment', () {
      for (final baseUrl in <String>[
        'https://test-app.convex.cloud/api/auth',
        'https://test-app.convex.cloud?token=secret',
        'https://test-app.convex.cloud#fragment',
      ]) {
        expect(
          () => BetterAuthClient(baseUrl: baseUrl),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.name,
              'name',
              'baseUrl',
            ),
          ),
        );
      }
    });

    test('throws when sign-in returns non-200', () async {
      final mock = MockClient((request) async {
        return http.Response('{"error":"invalid"}', 401);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      expect(
        () => client.signIn(email: 'a@b.com', password: 'bad'),
        throwsA(isA<BetterAuthException>()),
      );
    });

    test('throws when sign-in returns 200 with error body', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'code': 'INVALID_CREDENTIALS',
            'error': 'invalid_credentials',
          }),
          200,
          headers: {'set-auth-token': 'tok'},
        );
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      expect(
        () => client.signIn(email: 'a@b.com', password: 'bad'),
        throwsA(isA<BetterAuthException>()),
      );
    });

    test('allows successful 200 body with informational fields', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/sign-in/email') {
          return http.Response(
            jsonEncode({
              ..._defaultSignInResponse,
              'message': 'Signed in',
              'error': 'none',
            }),
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

      final session = await client.signIn(email: 'a@b.com', password: 'p');

      expect(session.token, 'jwt');
      expect(session.userId, 'user_123');
    });

    test('signIn tolerates malformed user scalar fields', () async {
      final mock = buildMock(
        sessionToken: 'ses_valid',
        convexToken: 'jwt_refreshed',
        signInResponse: {
          'user': {
            'id': 123,
            'email': false,
            'name': <String>['Alice'],
          },
          'session': {'id': 'ses_123', 'userId': 'user_123'},
        },
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.signIn(
        email: 'alice@example.com',
        password: 'password123',
      );

      expect(session.token, 'jwt_refreshed');
      expect(session.userId, '');
      expect(session.email, 'alice@example.com');
      expect(session.name, isNull);
    });

    test('throws typed exception when sign-in 200 body is not an object',
        () async {
      for (final body in <String>[jsonEncode('OK'), '']) {
        final mock = MockClient((request) async {
          if (request.url.path == '/api/auth/sign-in/email') {
            return http.Response(
              body,
              200,
              headers: {'set-auth-token': 'tok'},
            );
          }
          return http.Response('Not found', 404);
        });
        final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

        await expectLater(
          () => client.signIn(email: 'a@b.com', password: 'p'),
          throwsA(isA<BetterAuthException>()),
        );
      }
    });

    test('uses JSON token when set-auth-token header is missing', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/sign-in/email') {
          return http.Response(
            jsonEncode({
              ..._defaultSignInResponse,
              'token': 'ses_body_tok',
            }),
            200,
          );
        }
        if (request.url.path == '/api/auth/convex/token') {
          expect(request.headers['Authorization'], 'Bearer ses_body_tok');
          return http.Response(jsonEncode({'token': 'jwt_body'}), 200);
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.signIn(email: 'a@b.com', password: 'p');

      expect(session.sessionToken, 'ses_body_tok');
      expect(session.token, 'jwt_body');
    });

    test('throws when no session token is available', () async {
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
        throwsA(
          isA<BetterAuthException>()
              .having(
                (error) => error.message,
                'message',
                contains('Access-Control-Expose-Headers: set-auth-token'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('JSON token'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('Set-Cookie'),
              ),
        ),
      );
    });

    test('throws typed exception when Convex token body has no string token',
        () async {
      for (final tokenBody in <String>[
        jsonEncode(<String, dynamic>{}),
        jsonEncode({'token': null}),
        jsonEncode({'token': 42}),
        jsonEncode('OK'),
        '',
      ]) {
        final mock = MockClient((request) async {
          if (request.url.path == '/api/auth/sign-in/email') {
            return http.Response(
              jsonEncode(_defaultSignInResponse),
              200,
              headers: {'set-auth-token': 'tok'},
            );
          }
          if (request.url.path == '/api/auth/convex/token') {
            return http.Response(tokenBody, 200);
          }
          return http.Response('Not found', 404);
        });
        final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

        await expectLater(
          () => client.signIn(email: 'a@b.com', password: 'p'),
          throwsA(isA<BetterAuthSessionExpiredException>()),
        );
      }
    });

    test('extracts cookies when Expires contains a comma', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/sign-in/email') {
          return http.Response(
            jsonEncode(_defaultSignInResponse),
            200,
            headers: {
              'set-cookie':
                  'better-auth.session_token=ses_cookie; Expires=Wed, 09 Jun 2027 10:18:14 GMT; Path=/, better-auth.convex_jwt=jwt_cookie; Path=/',
            },
          );
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.signIn(email: 'a@b.com', password: 'p');

      expect(session.sessionToken, 'ses_cookie');
      expect(session.token, 'jwt_cookie');
    });

    test('throws typed exception when magic-link 200 body is not an object',
        () async {
      for (final body in <String>[jsonEncode(<Object?>[]), '']) {
        final mock = MockClient((request) async {
          if (request.url.path == '/api/auth/magic-link/verify') {
            return http.Response(
              body,
              200,
              headers: {'set-auth-token': 'tok'},
            );
          }
          return http.Response('Not found', 404);
        });
        final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

        await expectLater(
          () => client.verifyMagicLink(token: 'magic-token'),
          throwsA(isA<BetterAuthException>()),
        );
      }
    });

    test('verifyMagicLink uses JSON token when header is missing', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/magic-link/verify') {
          return http.Response(
            jsonEncode({
              ..._defaultSignInResponse,
              'token': 'ses_magic_body',
            }),
            200,
          );
        }
        if (request.url.path == '/api/auth/convex/token') {
          expect(request.headers['Authorization'], 'Bearer ses_magic_body');
          return http.Response(jsonEncode({'token': 'jwt_magic'}), 200);
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.verifyMagicLink(token: 'magic-token');

      expect(session.sessionToken, 'ses_magic_body');
      expect(session.token, 'jwt_magic');
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
