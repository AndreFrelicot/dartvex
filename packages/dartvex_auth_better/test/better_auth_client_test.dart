import 'dart:async';
import 'dart:convert';

import 'package:dartvex_auth_better/dartvex_auth_better.dart';
import 'package:dartvex_auth_better/src/better_auth_client.dart'
    show followMagicLinkRedirects;
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
          // Better Auth answers a missing or expired session with 200 `null`.
          return http.Response('null', 200);
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

    test('getSession returns null for Better Auth 200 null (no session)',
        () async {
      final mock = buildMock(); // no getSessionResponse → 200 `null`
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.getSession(sessionToken: 'ses_expired');
      expect(session, isNull);
    });

    test('getSession returns null when unauthorized', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/get-session') {
          return http.Response('Unauthorized', 401);
        }
        return http.Response('Not found', 404);
      });
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
      for (final body in <String>[jsonEncode('OK'), '', '[]']) {
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
                  'better-auth.session_token=ses_cookie; Expires=Tue, 09 Jun 2099 10:18:14 GMT; Path=/, better-auth.convex_jwt=jwt_cookie; Path=/',
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

  group('BetterAuthClient cookies (@convex-dev/better-auth 0.12.7+)', () {
    const baseUrl = 'https://test-app.convex.cloud';

    /// Mock answering [authPath] with [setCookie] and the session token in
    /// the `set-auth-token` header, and /convex/token with `jwt_endpoint`.
    MockClient cookieMock({
      required String authPath,
      required String setCookie,
      String? setAuthToken = 'ses_header',
      Map<String, dynamic> body = _defaultSignInResponse,
      List<String>? tokenRequests,
    }) {
      return MockClient((request) async {
        if (request.url.path == authPath) {
          return http.Response(
            jsonEncode(body),
            200,
            headers: {
              'set-cookie': setCookie,
              if (setAuthToken != null) 'set-auth-token': setAuthToken,
            },
          );
        }
        if (request.url.path == '/api/auth/convex/token') {
          tokenRequests?.add(request.headers['Authorization'] ?? '');
          return http.Response(jsonEncode({'token': 'jwt_endpoint'}), 200);
        }
        return http.Response('Not found', 404);
      });
    }

    // What better-call emits for ctx.setCookie(convex_jwt, "", {maxAge: 0})
    // next to the bearer plugin's session cookie on sign-in/sign-up.
    const clearedJwtCookie =
        '__Secure-better-auth.session_token=ses_cookie.sig; Max-Age=604800; '
        'Path=/; HttpOnly; Secure; SameSite=Lax, '
        '__Secure-better-auth.convex_jwt=; Max-Age=0; Path=/; HttpOnly; '
        'Secure; SameSite=Lax';

    test('signIn ignores an expired convex_jwt cookie and fetches the token',
        () async {
      final tokenRequests = <String>[];
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        httpClient: cookieMock(
          authPath: '/api/auth/sign-in/email',
          setCookie: clearedJwtCookie,
          tokenRequests: tokenRequests,
        ),
      );

      final session = await client.signIn(email: 'a@b.com', password: 'p');

      expect(session.token, 'jwt_endpoint');
      expect(session.sessionToken, 'ses_header');
      expect(tokenRequests, ['Bearer ses_header']);
    });

    test('signUp ignores an expired convex_jwt cookie and fetches the token',
        () async {
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        httpClient: cookieMock(
          authPath: '/api/auth/sign-up/email',
          setCookie: clearedJwtCookie,
          body: _defaultSignUpResponse,
        ),
      );

      final session = await client.signUp(
        name: 'Alice',
        email: 'alice@example.com',
        password: 'p',
      );

      expect(session.token, 'jwt_endpoint');
    });

    test('verifyMagicLink ignores an expired convex_jwt cookie', () async {
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        httpClient: cookieMock(
          authPath: '/api/auth/magic-link/verify',
          setCookie: clearedJwtCookie,
          body: {..._defaultSignInResponse, 'token': 'ses_magic'},
          setAuthToken: null,
        ),
      );

      final session = await client.verifyMagicLink(token: 'magic-token');

      expect(session.sessionToken, 'ses_magic');
      expect(session.token, 'jwt_endpoint');
    });

    test('treats empty, past-Expires and negative Max-Age cookies as absent',
        () async {
      for (final cookie in <String>[
        'better-auth.convex_jwt=; Path=/; HttpOnly',
        'better-auth.convex_jwt=stale; Path=/; '
            'Expires=Thu, 01 Jan 1970 00:00:00 GMT',
        'better-auth.convex_jwt=stale; Max-Age=-1; Path=/',
        // Max-Age wins over a future Expires (RFC 6265 §5.3).
        'better-auth.convex_jwt=stale; Max-Age=0; '
            'Expires=Tue, 09 Jun 2099 10:18:14 GMT',
      ]) {
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: cookieMock(
            authPath: '/api/auth/sign-in/email',
            setCookie: cookie,
          ),
        );

        final session = await client.signIn(email: 'a@b.com', password: 'p');

        expect(session.token, 'jwt_endpoint', reason: cookie);
      }
    });

    test('the last occurrence of a cookie wins', () async {
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        httpClient: cookieMock(
          authPath: '/api/auth/sign-in/email',
          setCookie: 'better-auth.convex_jwt=jwt_old; Max-Age=900; Path=/, '
              'better-auth.convex_jwt=; Max-Age=0; Path=/',
        ),
      );

      final session = await client.signIn(email: 'a@b.com', password: 'p');

      expect(session.token, 'jwt_endpoint');
    });

    test('uses a live __Secure- prefixed convex_jwt cookie', () async {
      final tokenRequests = <String>[];
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        httpClient: cookieMock(
          authPath: '/api/auth/sign-in/email',
          setCookie: '__Secure-better-auth.convex_jwt=jwt_cookie; '
              'Max-Age=900; Path=/; HttpOnly; Secure; SameSite=Lax',
          tokenRequests: tokenRequests,
        ),
      );

      final session = await client.signIn(email: 'a@b.com', password: 'p');

      expect(session.token, 'jwt_cookie');
      expect(tokenRequests, isEmpty);
    });

    test('verifyMagicLink uses a live convex_jwt cookie', () async {
      final tokenRequests = <String>[];
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        httpClient: cookieMock(
          authPath: '/api/auth/magic-link/verify',
          setCookie: 'better-auth.convex_jwt=jwt_magic_cookie; Max-Age=900',
          tokenRequests: tokenRequests,
        ),
      );

      final session = await client.verifyMagicLink(token: 'magic-token');

      expect(session.token, 'jwt_magic_cookie');
      expect(session.sessionToken, 'ses_header');
      expect(tokenRequests, isEmpty);
    });

    test('an expired session cookie is not used as the session token',
        () async {
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        httpClient: cookieMock(
          authPath: '/api/auth/sign-in/email',
          setCookie: 'better-auth.session_token=; Max-Age=0; Path=/, '
              'better-auth.convex_jwt=jwt_cookie; Max-Age=900; Path=/',
          setAuthToken: null,
        ),
      );

      await expectLater(
        () => client.signIn(email: 'a@b.com', password: 'p'),
        throwsA(
          isA<BetterAuthException>().having(
            (error) => error.message,
            'message',
            contains('did not return a session token'),
          ),
        ),
      );
    });

    test('getSession uses the convex_jwt cookie from get-session', () async {
      final tokenRequests = <String>[];
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/get-session') {
          return http.Response(
            jsonEncode({
              'session': {'id': 's1', 'userId': 'user_123'},
              'user': {'id': 'user_123', 'email': 'alice@example.com'},
            }),
            200,
            headers: {
              'set-cookie': '__Secure-better-auth.convex_jwt=jwt_refresh; '
                  'Max-Age=900; Path=/; HttpOnly; Secure; SameSite=Lax',
            },
          );
        }
        if (request.url.path == '/api/auth/convex/token') {
          tokenRequests.add('token');
          return http.Response(jsonEncode({'token': 'jwt_endpoint'}), 200);
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      final session = await client.getSession(sessionToken: 'ses_valid');

      expect(session!.token, 'jwt_refresh');
      expect(session.sessionToken, 'ses_valid');
      expect(tokenRequests, isEmpty);
    });
  });

  group('BetterAuthClient non-session outcomes', () {
    const baseUrl = 'https://test-app.convex.cloud';

    test('signUp surfaces email verification required (token: null)', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/sign-up/email') {
          return http.Response(
            jsonEncode({
              'token': null,
              'user': {'id': 'user_123', 'email': 'alice@example.com'},
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await expectLater(
        () => client.signUp(
          name: 'Alice',
          email: 'alice@example.com',
          password: 'p',
        ),
        throwsA(
          isA<BetterAuthEmailVerificationRequiredException>()
              .having((error) => error.user?['id'], 'user.id', 'user_123')
              .having((error) => error.retryable, 'retryable', isFalse)
              .having(
                (error) => error.message,
                'message',
                isNot(contains('bearer()')),
              ),
        ),
      );
    });

    test('signIn surfaces two-factor redirect', () async {
      final mock = MockClient((request) async {
        if (request.url.path == '/api/auth/sign-in/email') {
          return http.Response(
            jsonEncode({
              'twoFactorRedirect': true,
              'twoFactorMethods': ['totp', 'otp'],
            }),
            200,
            headers: {
              // better-auth 1.6 left the deleted session's cookie first.
              'set-cookie': 'better-auth.session_token=deleted.sig; '
                  'Max-Age=604800; Path=/, '
                  'better-auth.session_token=; Max-Age=0; Path=/',
            },
          );
        }
        return http.Response('Not found', 404);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await expectLater(
        () => client.signIn(email: 'a@b.com', password: 'p'),
        throwsA(
          isA<BetterAuthTwoFactorRequiredException>().having(
            (error) => error.twoFactorMethods,
            'twoFactorMethods',
            ['totp', 'otp'],
          ),
        ),
      );
    });
  });

  group('BetterAuthClient errors', () {
    const baseUrl = 'https://test-app.convex.cloud';

    test('non-200 errors keep the Better Auth code and body as data', () async {
      final mock = MockClient((request) async {
        return http.Response(
          jsonEncode({
            'code': 'EMAIL_NOT_VERIFIED',
            'message': 'Email not verified',
          }),
          403,
        );
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await expectLater(
        () => client.signIn(email: 'a@b.com', password: 'p'),
        throwsA(
          isA<BetterAuthException>()
              .having((error) => error.code, 'code', 'EMAIL_NOT_VERIFIED')
              .having((error) => error.data, 'data', isA<Map>())
              .having((error) => error.retryable, 'retryable', isFalse)
              .having(
                (error) => error.message,
                'message',
                contains('Email not verified'),
              ),
        ),
      );
    });

    test('5xx and 429 responses are retryable on every endpoint', () async {
      for (final status in <int>[429, 500, 503]) {
        final mock = MockClient(
          (request) async => http.Response(
            jsonEncode({'code': 'X', 'message': 'busy'}),
            status,
          ),
        );
        final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

        final calls = <String, Future<Object?> Function()>{
          'signIn': () => client.signIn(email: 'a@b.com', password: 'p'),
          'signOut': () => client.signOut(sessionToken: 'ses'),
          'getSession': () => client.getSession(sessionToken: 'ses'),
          'verifyMagicLink': () => client.verifyMagicLink(token: 't'),
        };
        for (final entry in calls.entries) {
          await expectLater(
            entry.value(),
            throwsA(
              isA<BetterAuthException>()
                  .having((error) => error.retryable, 'retryable', isTrue)
                  .having((error) => error.code, 'code', 'X'),
            ),
            reason: '${entry.key} $status',
          );
        }
      }
    });

    test('network errors become retryable BetterAuthExceptions', () async {
      final mock = MockClient((request) async {
        throw http.ClientException('Connection refused', request.url);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await expectLater(
        () => client.getSession(sessionToken: 'ses'),
        throwsA(
          isA<BetterAuthException>()
              .having((error) => error.retryable, 'retryable', isTrue)
              .having(
                (error) => error.message,
                'message',
                contains('Connection refused'),
              ),
        ),
      );
    });

    test('network error messages do not leak query tokens', () async {
      final mock = MockClient((request) async {
        throw http.ClientException('Connection reset', request.url);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await expectLater(
        () => client.verifyMagicLink(token: 'secret-magic-token'),
        throwsA(
          isA<BetterAuthException>().having(
            (error) => error.toString(),
            'toString',
            isNot(contains('secret-magic-token')),
          ),
        ),
      );
    });

    test('requests time out with a retryable exception', () async {
      final never = Completer<http.Response>();
      final mock = MockClient((request) => never.future);
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        httpClient: mock,
        requestTimeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        () => client.getSession(sessionToken: 'ses'),
        throwsA(
          isA<BetterAuthException>()
              .having((error) => error.retryable, 'retryable', isTrue)
              .having(
                (error) => error.message,
                'message',
                contains('timed out'),
              ),
        ),
      );
    });

    test('verifyMagicLink does not follow the error redirect', () async {
      bool? followRedirects;
      final mock = MockClient((request) async {
        followRedirects = request.followRedirects;
        return http.Response(
          '',
          302,
          headers: {
            'location': 'https://test-app.convex.site/?error=EXPIRED_TOKEN',
          },
        );
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await expectLater(
        () => client.verifyMagicLink(token: 'used-token'),
        throwsA(
          isA<BetterAuthException>()
              .having((error) => error.code, 'code', 'EXPIRED_TOKEN')
              .having((error) => error.retryable, 'retryable', isFalse)
              .having(
                (error) => error.message,
                'message',
                isNot(contains('used-token')),
              ),
        ),
      );
      expect(followRedirects, isFalse);
    });

    test(
        'verifyMagicLink follows the redirect in browsers and reads the code '
        'from the final URL', () async {
      final previous = followMagicLinkRedirects;
      followMagicLinkRedirects = true;
      addTearDown(() => followMagicLinkRedirects = previous);
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        httpClient: _BrowserLikeClient(
          Uri.parse('https://test-app.convex.site/?error=EXPIRED_TOKEN'),
        ),
      );

      await expectLater(
        () => client.verifyMagicLink(token: 'used-token'),
        throwsA(
          isA<BetterAuthException>()
              .having((error) => error.code, 'code', 'EXPIRED_TOKEN')
              .having((error) => error.retryable, 'retryable', isFalse),
        ),
      );
    });

    test('a timed-out request is aborted, not left running', () async {
      final stalling = _StallingClient();
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        httpClient: stalling,
        requestTimeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        () => client.signIn(email: 'a@b.com', password: 'p'),
        throwsA(
          isA<BetterAuthException>().having(
            (error) => error.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
      expect(await stalling.aborted.future, isTrue);
    });

    test('signOut non-200 throws', () async {
      final mock = MockClient(
        (request) async => http.Response(
          jsonEncode({'code': 'FAILED_TO_GET_SESSION', 'message': 'nope'}),
          400,
        ),
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await expectLater(
        () => client.signOut(sessionToken: 'ses'),
        throwsA(
          isA<BetterAuthException>()
              .having((error) => error.code, 'code', 'FAILED_TO_GET_SESSION'),
        ),
      );
    });

    test('200 error body detail formatting', () async {
      final cases = <Map<String, dynamic>, String>{
        {'code': 'C', 'error': 'E', 'message': 'M'}: 'failed: E: M',
        {'code': 'C', 'error': 'E'}: 'failed: E',
        {'code': 'C', 'message': 'M'}: 'failed: M',
        {'code': 'C'}: 'failed: C',
      };
      for (final entry in cases.entries) {
        final mock = MockClient(
          (request) async => http.Response(jsonEncode(entry.key), 200),
        );
        final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

        await expectLater(
          () => client.forgotPassword(email: 'a@b.com'),
          throwsA(
            isA<BetterAuthException>()
                .having(
                    (error) => error.message, 'message', endsWith(entry.value))
                .having((error) => error.code, 'code', 'C'),
          ),
        );
      }
    });

    test('toString names the Better Auth type and code', () {
      const error = BetterAuthException(
        'Better Auth request to /api/auth/sign-in/email failed (status 401)',
        data: {'code': 'INVALID_EMAIL_OR_PASSWORD'},
      );
      expect(error.toString(), startsWith('BetterAuthException('));
      expect(error.toString(), contains('code: INVALID_EMAIL_OR_PASSWORD'));
      expect(
        const BetterAuthSessionExpiredException('x').toString(),
        startsWith('BetterAuthSessionExpiredException('),
      );
      expect(
        const BetterAuthTwoFactorRequiredException('x').toString(),
        startsWith('BetterAuthTwoFactorRequiredException('),
      );
      expect(
        const BetterAuthEmailVerificationRequiredException('x').toString(),
        startsWith('BetterAuthEmailVerificationRequiredException('),
      );
    });
  });

  group('BetterAuthClient endpoints', () {
    const baseUrl = 'https://test-app.convex.cloud';

    test('sendMagicLink and resetPassword send the expected bodies', () async {
      final requests = <String, Map<String, dynamic>>{};
      final mock = MockClient((request) async {
        requests[request.url.path] =
            jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'status': true}), 200);
      });
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);

      await client.sendMagicLink(
        email: 'a@b.com',
        callbackURL: 'https://app.example/welcome',
      );
      await client.resetPassword(token: 'reset-tok', newPassword: 'new-pass');

      expect(requests['/api/auth/sign-in/magic-link'], {
        'email': 'a@b.com',
        'callbackURL': 'https://app.example/welcome',
      });
      expect(requests['/api/auth/reset-password'], {
        'token': 'reset-tok',
        'newPassword': 'new-pass',
      });
    });

    test('siteUrl overrides the derived HTTP-actions origin', () async {
      final requested = <Uri>[];
      final mock = MockClient((request) async {
        requested.add(request.url);
        if (request.url.path == '/api/auth/sign-in/email') {
          return http.Response(
            jsonEncode(_defaultSignInResponse),
            200,
            headers: {'set-auth-token': 'tok'},
          );
        }
        return http.Response(jsonEncode({'token': 'jwt'}), 200);
      });
      final client = BetterAuthClient(
        baseUrl: 'http://127.0.0.1:3210',
        siteUrl: 'http://127.0.0.1:3211/',
        httpClient: mock,
      );

      await client.signIn(email: 'a@b.com', password: 'p');

      expect(client.siteUrl, 'http://127.0.0.1:3211');
      expect(
        requested.map((uri) => uri.toString()),
        everyElement(startsWith('http://127.0.0.1:3211/api/auth/')),
      );
    });

    test('siteUrl supports custom domains', () {
      final client = BetterAuthClient(
        baseUrl: 'https://api.example.com',
        siteUrl: 'https://auth.example.com',
        httpClient: MockClient((request) async => http.Response('', 200)),
      );
      expect(client.baseUrl, 'https://api.example.com');
      expect(client.siteUrl, 'https://auth.example.com');
    });

    test('rejects siteUrl with a path', () {
      expect(
        () => BetterAuthClient(
          baseUrl: baseUrl,
          siteUrl: 'https://test-app.convex.site/api/auth',
        ),
        throwsA(
          isA<ArgumentError>().having((error) => error.name, 'name', 'siteUrl'),
        ),
      );
    });

    test('basePath changes every endpoint path', () async {
      final paths = <String>[];
      final mock = MockClient((request) async {
        paths.add(request.url.path);
        if (request.url.path == '/auth/sign-in/email') {
          return http.Response(
            jsonEncode(_defaultSignInResponse),
            200,
            headers: {'set-auth-token': 'tok'},
          );
        }
        if (request.url.path == '/auth/get-session') {
          return http.Response('null', 200);
        }
        return http.Response(jsonEncode({'token': 'jwt'}), 200);
      });
      final client = BetterAuthClient(
        baseUrl: baseUrl,
        basePath: '/auth/',
        httpClient: mock,
      );

      await client.signIn(email: 'a@b.com', password: 'p');
      await client.getSession(sessionToken: 'tok');
      await client.signOut(sessionToken: 'tok');

      expect(client.basePath, '/auth');
      expect(paths, [
        '/auth/sign-in/email',
        '/auth/convex/token',
        '/auth/get-session',
        '/auth/sign-out',
      ]);
    });

    test('rejects an invalid basePath', () {
      for (final basePath in <String>['api/auth', '/api?x=1', '/a/../b']) {
        expect(
          () => BetterAuthClient(baseUrl: baseUrl, basePath: basePath),
          throwsA(
            isA<ArgumentError>()
                .having((error) => error.name, 'name', 'basePath'),
          ),
          reason: basePath,
        );
      }
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

/// Mimics package:http's BrowserClient: a request that does not follow
/// redirects fails (fetch `redirect: 'error'`), and a followed redirect
/// reports the final URL.
class _BrowserLikeClient extends http.BaseClient {
  _BrowserLikeClient(this.finalUrl);

  final Uri finalUrl;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!request.followRedirects) {
      throw http.ClientException('Redirect was blocked', request.url);
    }
    return _ResponseWithUrl(
      Stream<List<int>>.value(utf8.encode('<html></html>')),
      200,
      url: finalUrl,
      request: request,
    );
  }
}

/// Never answers; records whether the request was aborted.
class _StallingClient extends http.BaseClient {
  final Completer<bool> aborted = Completer<bool>();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    final response = Completer<http.StreamedResponse>();
    if (request is http.Abortable) {
      request.abortTrigger?.then((_) {
        if (!aborted.isCompleted) {
          aborted.complete(true);
        }
        response.completeError(http.RequestAbortedException(request.url));
      });
    }
    Timer(const Duration(seconds: 1), () {
      if (!aborted.isCompleted) {
        aborted.complete(false);
      }
    });
    return response.future;
  }
}

class _ResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _ResponseWithUrl(
    super.stream,
    super.statusCode, {
    required this.url,
    super.request,
  });

  @override
  final Uri url;
}
