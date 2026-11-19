import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart' show AuthSessionEndedError;
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
          // Better Auth answers an expired or unknown session with 200 null.
          return http.Response('null', 200);
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

    group('password lifetime', () {
      MockClient signInAnswering(http.Response Function() answer) =>
          MockClient((request) async {
            if (request.url.path == '/api/auth/sign-in/email') {
              return answer();
            }
            return http.Response('{}', 404);
          });

      test('login forgets the password once signed in', () async {
        final client =
            BetterAuthClient(baseUrl: baseUrl, httpClient: buildMock());
        final provider = ConvexBetterAuthProvider(client: client)
          ..email = 'alice@example.com'
          ..password = 'password123';

        await provider.login(onIdToken: (_) {});

        expect(provider.password, isNull);
        expect(provider.email, 'alice@example.com');
      });

      test('signUp never stores the password', () async {
        final client =
            BetterAuthClient(baseUrl: baseUrl, httpClient: buildMock());
        final provider = ConvexBetterAuthProvider(client: client);

        await provider.signUp(
          name: 'Alice',
          email: 'alice@example.com',
          password: 'password123',
        );
        expect(provider.password, isNull);

        await provider.login(onIdToken: (_) {});
        expect(provider.password, isNull);
      });

      test('signUp clears the same password staged before it', () async {
        final requests = <String>[];
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: buildMock(
            onRequest: (request) => requests.add(request.url.path),
          ),
        );
        final provider = ConvexBetterAuthProvider(client: client)
          ..email = 'alice@example.com'
          ..password = 'password123';

        final signedUp = await provider.signUp(
          name: 'Alice',
          email: 'alice@example.com',
          password: 'password123',
        );
        expect(provider.password, isNull);

        // Nothing is staged any more, so login() reuses the sign-up session.
        final session = await provider.login(onIdToken: (_) {});
        expect(session, same(signedUp));
        expect(requests, isNot(contains('/api/auth/sign-in/email')));
      });

      test('signIn never stores the password', () async {
        final requests = <String>[];
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: buildMock(
            convexToken: 'jwt_signin',
            onRequest: (request) => requests.add(request.url.path),
          ),
        );
        final provider = ConvexBetterAuthProvider(client: client);

        String? signInToken;
        final signedIn = await provider.signIn(
          email: 'alice@example.com',
          password: 'password123',
          onIdToken: (token) => signInToken = token,
        );

        expect(provider.password, isNull);
        expect(provider.email, 'alice@example.com');
        expect(signInToken, 'jwt_signin');
        // Staged only: it becomes the provider's session with login().
        expect(provider.cachedSession, isNull);

        // login() hands the same session over without another sign-in.
        String? loginToken;
        final session = await provider.login(
          onIdToken: (token) => loginToken = token,
        );
        expect(session, same(signedIn));
        expect(provider.cachedSession, same(signedIn));
        expect(loginToken, 'jwt_signin');
        expect(
          requests.where((path) => path == '/api/auth/sign-in/email'),
          hasLength(1),
        );
      });

      test('a failed signIn stages nothing', () async {
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: signInAnswering(
            () => http.Response(
              jsonEncode({'message': 'Invalid email or password'}),
              401,
            ),
          ),
        );
        final provider = ConvexBetterAuthProvider(client: client);

        await expectLater(
          provider.signIn(email: 'alice@example.com', password: 'wrong'),
          throwsA(isA<BetterAuthException>()),
        );

        expect(provider.password, isNull);
        expect(provider.cachedSession, isNull);
        await expectLater(
          provider.login(onIdToken: (_) {}),
          throwsStateError,
        );
      });

      test('a password staged after signIn is a new sign-in', () async {
        final requests = <String>[];
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: buildMock(
            onRequest: (request) => requests.add(request.url.path),
          ),
        );
        final provider = ConvexBetterAuthProvider(client: client);

        final first = await provider.signIn(
          email: 'alice@example.com',
          password: 'password123',
        );
        provider.password = 'password456';
        final second = await provider.login(onIdToken: (_) {});

        expect(second, isNot(same(first)));
        expect(provider.password, isNull);
        expect(
          requests.where((path) => path == '/api/auth/sign-in/email'),
          hasLength(2),
        );
      });

      test('the signIn session is used once', () async {
        final client =
            BetterAuthClient(baseUrl: baseUrl, httpClient: buildMock());
        final provider = ConvexBetterAuthProvider(client: client);

        await provider.signIn(
          email: 'alice@example.com',
          password: 'password123',
        );
        await provider.login(onIdToken: (_) {});

        await expectLater(
          provider.login(onIdToken: (_) {}),
          throwsStateError,
        );
      });

      test('a rejected sign-in forgets the password', () async {
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: signInAnswering(
            () => http.Response('{"message":"Invalid password"}', 401),
          ),
        );
        final provider = ConvexBetterAuthProvider(client: client)
          ..email = 'alice@example.com'
          ..password = 'wrong';

        await expectLater(
          provider.login(onIdToken: (_) {}),
          throwsA(isA<BetterAuthException>()
              .having((e) => e.retryable, 'retryable', isFalse)),
        );
        expect(provider.password, isNull);
      });

      test('a retryable failure keeps the password for a retry', () async {
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: signInAnswering(() => http.Response('busy', 503)),
        );
        final provider = ConvexBetterAuthProvider(client: client)
          ..email = 'alice@example.com'
          ..password = 'password123';

        await expectLater(
          provider.login(onIdToken: (_) {}),
          throwsA(isA<BetterAuthException>()
              .having((e) => e.retryable, 'retryable', isTrue)),
        );
        expect(provider.password, 'password123');
      });

      test('a password set for a newer login is not cleared', () async {
        final gate = Completer<void>();
        final inner = buildMock();
        final gated = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: MockClient((request) async {
            if (request.url.path == '/api/auth/sign-in/email') {
              await gate.future;
            }
            final copy = http.Request(request.method, request.url)
              ..headers.addAll(request.headers)
              ..bodyBytes = request.bodyBytes;
            return http.Response.fromStream(await inner.send(copy));
          }),
        );
        final provider = ConvexBetterAuthProvider(client: gated)
          ..email = 'alice@example.com'
          ..password = 'first';

        final first = provider.login(onIdToken: (_) {});
        await Future<void>.delayed(Duration.zero);
        provider.password = 'second';
        gate.complete();
        await first;

        expect(provider.password, 'second');
      });
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
          contains('signIn(email:, password:)'),
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
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('No cached'))
            .having((e) => e, 'error', isA<AuthSessionEndedError>())),
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
              .having((error) => error is AuthSessionEndedError,
                  'is AuthSessionEndedError', isFalse)
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
              .having((error) => error is AuthSessionEndedError,
                  'is AuthSessionEndedError', isFalse)
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
      // Now the mock will return 200 `null` for get-session.

      await expectLater(
        () => provider.loginFromCache(onIdToken: (_) {}),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('expired'))
            // Definitive: a replacement restore signs the client out.
            .having((e) => e, 'error', isA<AuthSessionEndedError>())),
      );
      // The dead session is cleared so it is not retried.
      expect(provider.cachedSession, isNull);
      await expectLater(
        () => provider.loginFromCache(onIdToken: (_) {}),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('No cached'))
            .having((e) => e, 'error', isA<AuthSessionEndedError>())),
      );
    });

    test('loginFromCache throws StateError when get-session returns 401',
        () async {
      final mock = buildMock(getSessionStatus: 401, getSessionBody: '');
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(
        client: client,
        initialSessionToken: 'ses_persisted',
      );

      await expectLater(
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

    test('signUp registers and keeps the email, not the password', () async {
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
      expect(provider.password, isNull);
      // Staged only: it becomes the provider's session with login().
      expect(provider.cachedSession, isNull);
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

    test('signUp does not require onIdToken', () async {
      final client =
          BetterAuthClient(baseUrl: baseUrl, httpClient: buildMock());
      final provider = ConvexBetterAuthProvider(client: client);

      final session = await provider.signUp(
        name: 'Alice',
        email: 'alice@example.com',
        password: 'password123',
      );

      expect(provider.cachedSession, isNull);
      expect(await provider.login(onIdToken: (_) {}), same(session));
      expect(provider.cachedSession, same(session));
    });

    test('logout clears email and password', () async {
      final client =
          BetterAuthClient(baseUrl: baseUrl, httpClient: buildMock());
      final provider = ConvexBetterAuthProvider(client: client);
      provider.email = 'alice@example.com';
      provider.password = 'password123';
      await provider.login(onIdToken: (_) {});

      await provider.logout();

      expect(provider.email, isNull);
      expect(provider.password, isNull);
      await expectLater(
        () => provider.login(onIdToken: (_) {}),
        throwsA(isA<StateError>()),
      );
    });

    test('adoptSession lets loginFromCache restore a magic-link session',
        () async {
      final sessionRequests = <String?>[];
      final mock = buildMock(
        convexToken: 'jwt_adopted',
        onRequest: (request) {
          if (request.url.path == '/api/auth/get-session') {
            sessionRequests.add(request.headers['Authorization']);
          }
        },
      );
      final client = BetterAuthClient(baseUrl: baseUrl, httpClient: mock);
      final provider = ConvexBetterAuthProvider(client: client);

      provider.adoptSession(
        const BetterAuthSession(
          token: 'jwt_magic',
          sessionToken: 'ses_magic',
          userId: 'u1',
          email: 'alice@example.com',
        ),
      );
      // Staged only: it becomes the current session once restored.
      expect(provider.cachedSession, isNull);

      final session = await provider.loginFromCache(onIdToken: (_) {});

      expect(sessionRequests, ['Bearer ses_magic']);
      expect(session.token, 'jwt_adopted');
      expect(provider.cachedSession?.sessionToken, 'ses_magic');
    });

    group('session races', () {
      /// Mock whose get-session and sign-in/sign-out responses can be held
      /// back with completers, keyed by the bearer/email they serve.
      ({
        MockClient mock,
        Map<String, Completer<void>> getSessionGates,
        Map<String, Completer<void>> signInGates,
        Map<String, int> signInStatus,
        List<Map<String, dynamic>> signIns,
        Map<String, int> getSessionStatus,
        List<String> signedOut,
      }) gatedMock({Completer<void>? signOutGate}) {
        final signInStatus = <String, int>{};
        final signIns = <Map<String, dynamic>>[];
        final getSessionStatus = <String, int>{};
        final getSessionGates = <String, Completer<void>>{};
        final signInGates = <String, Completer<void>>{};
        final signedOut = <String>[];
        final mock = MockClient((request) async {
          final path = request.url.path;
          final auth = request.headers['Authorization'] ?? '';
          final bearer = auth.startsWith('Bearer ') ? auth.substring(7) : '';
          if (path == '/api/auth/sign-up/email') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final email = body['email'] as String;
            return http.Response(
              jsonEncode({
                'user': {'id': email, 'email': email},
                'session': {'id': 's', 'userId': email},
              }),
              200,
              headers: {'set-auth-token': 'ses_$email'},
            );
          }
          if (path == '/api/auth/sign-in/email') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            final email = body['email'] as String;
            signIns.add(body);
            await signInGates[email]?.future;
            final status = signInStatus[email];
            if (status != null) {
              return http.Response('{"message":"unavailable"}', status);
            }
            return http.Response(
              jsonEncode({
                'user': {'id': email, 'email': email},
                'session': {'id': 's', 'userId': email},
              }),
              200,
              headers: {'set-auth-token': 'ses_$email'},
            );
          }
          if (path == '/api/auth/get-session') {
            await getSessionGates[bearer]?.future;
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
            return http.Response(jsonEncode({'token': 'jwt_$bearer'}), 200);
          }
          if (path == '/api/auth/sign-out') {
            await signOutGate?.future;
            signedOut.add(bearer);
            return http.Response(jsonEncode({'success': true}), 200);
          }
          return http.Response('Not found', 404);
        });
        return (
          mock: mock,
          getSessionGates: getSessionGates,
          signInGates: signInGates,
          signInStatus: signInStatus,
          signIns: signIns,
          getSessionStatus: getSessionStatus,
          signedOut: signedOut,
        );
      }

      /// Runs [body] the way `ConvexClientWithAuth` runs its background token
      /// refreshes.
      Future<T> asRefresh<T>(Future<T> Function() body) => runZoned(
            body,
            zoneValues: const <Object?, Object?>{
              #dartvex.authTokenRefresh: true,
            },
          );

      Future<ConvexBetterAuthProvider> signedInAsA(MockClient mock) async {
        final provider = ConvexBetterAuthProvider(
          client: BetterAuthClient(baseUrl: baseUrl, httpClient: mock),
        );
        provider
          ..email = 'a'
          ..password = 'pw';
        await provider.login(onIdToken: (_) {});
        return provider;
      }

      test('an explicit loginFromCache supersedes a pending login', () async {
        final setup = gatedMock();
        final provider = await signedInAsA(setup.mock);
        final gate = setup.signInGates['b'] = Completer<void>();
        provider
          ..email = 'b'
          ..password = 'pw';
        String? reported;
        final login = provider.login(onIdToken: (token) => reported = token);

        final restored = await provider.loginFromCache(onIdToken: (_) {});
        expect(restored.sessionToken, 'ses_a');
        gate.complete();

        await expectLater(
          login,
          throwsA(isA<BetterAuthException>()
              .having((e) => e.message, 'message', contains('superseded'))),
        );
        expect(reported, isNull);
        expect(provider.cachedSession?.sessionToken, 'ses_a');
        final refreshed = await asRefresh(
          () => provider.loginFromCache(onIdToken: (_) {}),
        );
        expect(refreshed.token, 'jwt_ses_a');
        await pumpEventQueue();
        expect(setup.signedOut, ['ses_b']);
      });

      test('a background refresh does not supersede a pending login', () async {
        final setup = gatedMock();
        final provider = await signedInAsA(setup.mock);
        final gate = setup.signInGates['b'] = Completer<void>();
        provider
          ..email = 'b'
          ..password = 'pw';
        final login = provider.login(onIdToken: (_) {});

        final refreshed = await asRefresh(
          () => provider.loginFromCache(onIdToken: (_) {}),
        );
        expect(refreshed.token, 'jwt_ses_a');
        gate.complete();

        final session = await login;
        expect(session.sessionToken, 'ses_b');
        expect(provider.cachedSession, same(session));
        await pumpEventQueue();
        expect(setup.signedOut, isEmpty);
      });

      test(
          'signIn for another account leaves the current session in place '
          'until login()', () async {
        final setup = gatedMock();
        final provider = await signedInAsA(setup.mock);

        final staged = await provider.signIn(email: 'b', password: 'pw-b');
        expect(staged.sessionToken, 'ses_b');
        // The client is still signed in as A: the provider must not switch
        // under it.
        expect(provider.cachedSession?.sessionToken, 'ses_a');

        // A background refresh serves A's token, not B's...
        String? refreshedToken;
        final refreshed = await asRefresh(
          () => provider.loginFromCache(
            onIdToken: (token) => refreshedToken = token,
          ),
        );
        expect(refreshed.sessionToken, 'ses_a');
        expect(refreshedToken, 'jwt_ses_a');
        expect(provider.cachedSession?.sessionToken, 'ses_a');

        // ...and leaves B staged: login() hands it over without credentials.
        String? loginToken;
        final session = await provider.login(
          onIdToken: (token) => loginToken = token,
        );
        expect(session, same(staged));
        expect(loginToken, 'jwt_ses_b');
        expect(provider.cachedSession, same(staged));
        expect(setup.signIns.map((body) => body['email']), ['a', 'b']);
        await pumpEventQueue();
        expect(setup.signedOut, isEmpty);
      });

      test('signUp for another account is staged the same way', () async {
        final setup = gatedMock();
        final provider = await signedInAsA(setup.mock);

        final staged = await provider.signUp(
          name: 'B',
          email: 'b',
          password: 'pw-b',
        );
        expect(provider.cachedSession?.sessionToken, 'ses_a');
        final refreshed = await asRefresh(
          () => provider.loginFromCache(onIdToken: (_) {}),
        );
        expect(refreshed.sessionToken, 'ses_a');

        expect(await provider.login(onIdToken: (_) {}), same(staged));
        expect(provider.cachedSession, same(staged));
      });

      test('the current session expiring keeps a staged sign-in', () async {
        final setup = gatedMock();
        final provider = await signedInAsA(setup.mock);
        final staged = await provider.signIn(email: 'b', password: 'pw-b');

        // A ends on the server: the background refresh reports it...
        setup.getSessionStatus['ses_a'] = 401;
        await expectLater(
          asRefresh(() => provider.loginFromCache(onIdToken: (_) {})),
          throwsA(isA<AuthSessionEndedError>()),
        );
        expect(provider.cachedSession, isNull);

        // ...and B, which is another session, is still there for login().
        expect(await provider.login(onIdToken: (_) {}), same(staged));
        expect(provider.cachedSession, same(staged));
        await pumpEventQueue();
        expect(setup.signedOut, isEmpty);
      });

      test('the current session expiring does not cancel a login in flight',
          () async {
        final setup = gatedMock();
        final provider = await signedInAsA(setup.mock);
        final gate = setup.signInGates['b'] = Completer<void>();
        provider
          ..email = 'b'
          ..password = 'pw';
        final login = provider.login(onIdToken: (_) {});

        setup.getSessionStatus['ses_a'] = 401;
        await expectLater(
          asRefresh(() => provider.loginFromCache(onIdToken: (_) {})),
          throwsA(isA<AuthSessionEndedError>()),
        );
        gate.complete();

        final session = await login;
        expect(session.sessionToken, 'ses_b');
        expect(provider.cachedSession, same(session));
        await pumpEventQueue();
        expect(setup.signedOut, isEmpty);
      });

      test(
          'a password kept after a retryable failure is never sent with '
          'another account', () async {
        final setup = gatedMock();
        final provider = ConvexBetterAuthProvider(
          client: BetterAuthClient(baseUrl: baseUrl, httpClient: setup.mock),
        );
        setup.signInStatus['a'] = 503;
        provider
          ..email = 'a'
          ..password = 'pw-a';
        await expectLater(
          provider.login(onIdToken: (_) {}),
          throwsA(isA<BetterAuthException>()
              .having((e) => e.retryable, 'retryable', isTrue)),
        );
        // Kept, so the same login() can be retried.
        expect(provider.password, 'pw-a');

        // The app signs in to another account instead.
        final staged = await provider.signIn(email: 'b', password: 'pw-b');
        expect(provider.password, isNull);
        expect(await provider.login(onIdToken: (_) {}), same(staged));
        expect(setup.signIns, [
          {'email': 'a', 'password': 'pw-a'},
          {'email': 'b', 'password': 'pw-b'},
        ]);
      });

      test('a staged session nobody uses is signed out', () async {
        final setup = gatedMock();
        final provider = await signedInAsA(setup.mock);

        // Replaced by a newer signIn.
        await provider.signIn(email: 'b', password: 'pw');
        final kept = await provider.signIn(email: 'c', password: 'pw');
        await pumpEventQueue();
        expect(setup.signedOut, ['ses_b']);

        // Dropped by credentials staged for login().
        provider
          ..email = 'd'
          ..password = 'pw';
        final session = await provider.login(onIdToken: (_) {});
        expect(session.sessionToken, 'ses_d');
        expect(session, isNot(same(kept)));
        await pumpEventQueue();
        expect(setup.signedOut, ['ses_b', 'ses_c']);

        // Dropped by logout, with the current session.
        await provider.signIn(email: 'e', password: 'pw');
        await provider.logout();
        await pumpEventQueue();
        expect(
            setup.signedOut,
            unorderedEquals(
              <String>['ses_b', 'ses_c', 'ses_d', 'ses_e'],
            ));
        expect(provider.cachedSession, isNull);
        await expectLater(
          provider.login(onIdToken: (_) {}),
          throwsStateError,
        );
      });

      test('logout without a current session ends the staged one', () async {
        final setup = gatedMock();
        final provider = ConvexBetterAuthProvider(
          client: BetterAuthClient(baseUrl: baseUrl, httpClient: setup.mock),
        );
        await provider.signIn(email: 'b', password: 'pw');

        await provider.logout();

        expect(setup.signedOut, ['ses_b']);
      });

      test('an explicit loginFromCache makes a staged sign-in current',
          () async {
        final setup = gatedMock();
        final provider = await signedInAsA(setup.mock);
        await provider.signIn(email: 'b', password: 'pw');

        final restored = await provider.loginFromCache(onIdToken: (_) {});

        expect(restored.sessionToken, 'ses_b');
        expect(provider.cachedSession?.sessionToken, 'ses_b');
        final next = await asRefresh(
          () => provider.loginFromCache(onIdToken: (_) {}),
        );
        expect(next.sessionToken, 'ses_b');
      });

      test(
          'adoptSession stages the session until an explicit loginFromCache '
          'restores it', () async {
        final setup = gatedMock();
        final provider = await signedInAsA(setup.mock);
        const adopted = BetterAuthSession(
          token: 'jwt_magic',
          sessionToken: 'ses_b',
          userId: 'b',
          email: 'b',
        );
        provider.adoptSession(adopted);
        expect(provider.cachedSession?.sessionToken, 'ses_a');

        setup.getSessionStatus['ses_b'] = 503;
        await expectLater(
          provider.loginFromCache(onIdToken: (_) {}),
          throwsA(isA<BetterAuthException>()
              .having((e) => e.retryable, 'retryable', isTrue)),
        );
        expect(provider.cachedSession?.sessionToken, 'ses_a');
        // Background refreshes keep serving the current session.
        final refreshed = await asRefresh(
          () => provider.loginFromCache(onIdToken: (_) {}),
        );
        expect(refreshed.token, 'jwt_ses_a');
        expect(provider.cachedSession?.sessionToken, 'ses_a');

        // The adopted session stays staged for a retry.
        setup.getSessionStatus.remove('ses_b');
        final restored = await provider.loginFromCache(onIdToken: (_) {});
        expect(restored.sessionToken, 'ses_b');
        expect(provider.cachedSession?.sessionToken, 'ses_b');
        final next = await asRefresh(
          () => provider.loginFromCache(onIdToken: (_) {}),
        );
        expect(next.token, 'jwt_ses_b');
      });

      test(
          'a rejected adopted session keeps the current session and is not '
          'a session-ended error', () async {
        final setup = gatedMock();
        final provider = await signedInAsA(setup.mock);
        provider.adoptSession(
          const BetterAuthSession(
            token: 'jwt_magic',
            sessionToken: 'ses_b',
            userId: 'b',
            email: 'b',
          ),
        );
        setup.getSessionStatus['ses_b'] = 401;

        await expectLater(
          provider.loginFromCache(onIdToken: (_) {}),
          throwsA(isA<BetterAuthException>().having(
            (e) => e is AuthSessionEndedError,
            'is AuthSessionEndedError',
            isFalse,
          )),
        );
        expect(provider.cachedSession?.sessionToken, 'ses_a');
        // The dead staged session was dropped: the next restore is A's.
        final restored = await provider.loginFromCache(onIdToken: (_) {});
        expect(restored.sessionToken, 'ses_a');
      });

      test('a stale loginFromCache cannot overwrite a newer login', () async {
        final setup = gatedMock();
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: setup.mock,
        );
        final provider = ConvexBetterAuthProvider(client: client);
        provider.email = 'a';
        provider.password = 'pw';
        await provider.login(onIdToken: (_) {});
        expect(provider.cachedSession?.sessionToken, 'ses_a');

        // A's refresh is held in flight while the user switches to B.
        final gate = setup.getSessionGates['ses_a'] = Completer<void>();
        String? staleToken;
        final staleRefresh = provider.loginFromCache(
          onIdToken: (token) => staleToken = token,
        );
        provider.email = 'b';
        provider.password = 'pw';
        await provider.login(onIdToken: (_) {});
        gate.complete();

        await expectLater(
          staleRefresh,
          throwsA(
            isA<BetterAuthException>()
                .having((error) => error.retryable, 'retryable', isTrue)
                .having((error) => error is AuthSessionEndedError,
                    'is AuthSessionEndedError', isFalse),
          ),
        );
        expect(staleToken, isNull);
        expect(provider.cachedSession?.sessionToken, 'ses_b');
        final refreshed = await provider.loginFromCache(onIdToken: (_) {});
        expect(refreshed.token, 'jwt_ses_b');
      });

      test('a stale loginFromCache cannot resurrect a logged-out session',
          () async {
        final setup = gatedMock();
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: setup.mock,
        );
        final provider = ConvexBetterAuthProvider(
          client: client,
          initialSessionToken: 'ses_a',
        );

        final gate = setup.getSessionGates['ses_a'] = Completer<void>();
        final staleRefresh = provider.loginFromCache(onIdToken: (_) {});
        await provider.logout();
        gate.complete();

        await expectLater(staleRefresh, throwsA(isA<BetterAuthException>()));
        expect(provider.cachedSession, isNull);
        await expectLater(
          () => provider.loginFromCache(onIdToken: (_) {}),
          throwsA(isA<StateError>()),
        );
      });

      test('a login started during sign-out is not wiped by it', () async {
        final signOutGate = Completer<void>();
        final setup = gatedMock(signOutGate: signOutGate);
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: setup.mock,
        );
        final provider = ConvexBetterAuthProvider(
          client: client,
          initialSessionToken: 'ses_a',
        );

        final logout = provider.logout();
        provider.email = 'b';
        provider.password = 'pw';
        final session = await provider.login(onIdToken: (_) {});
        signOutGate.complete();
        await logout;

        expect(setup.signedOut, ['ses_a']);
        expect(provider.cachedSession, same(session));
        expect(provider.cachedSession?.sessionToken, 'ses_b');
        expect(provider.email, 'b');
      });

      test('logout supersedes an in-flight login and revokes its session',
          () async {
        final setup = gatedMock();
        final client = BetterAuthClient(
          baseUrl: baseUrl,
          httpClient: setup.mock,
        );
        final provider = ConvexBetterAuthProvider(client: client);
        provider.email = 'a';
        provider.password = 'pw';

        final gate = setup.signInGates['a'] = Completer<void>();
        String? reported;
        final login = provider.login(onIdToken: (token) => reported = token);
        await provider.logout();
        gate.complete();

        await expectLater(login, throwsA(isA<BetterAuthException>()));
        expect(reported, isNull);
        expect(provider.cachedSession, isNull);
        await pumpEventQueue();
        expect(setup.signedOut, ['ses_a']);
      });
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
