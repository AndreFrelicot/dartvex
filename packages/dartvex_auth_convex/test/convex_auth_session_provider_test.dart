import 'dart:async';

import 'package:dartvex_auth_convex/dartvex_auth_convex.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support.dart';

/// Runs [body] the way `ConvexClientWithAuth` runs a background refresh.
Future<T> asBackgroundRefresh<T>(Future<T> Function() body) =>
    runZoned(body, zoneValues: {#dartvex.authTokenRefresh: true});

void main() {
  late FakeConvexAuthServer server;
  late ConvexAuthHttpClient client;
  late List<ConvexAuthSession?> changes;
  late List<String?> pushed;

  ConvexAuthSessionProvider newProvider({ConvexAuthSession? initial}) =>
      ConvexAuthSessionProvider(
        client: client,
        initialSession: initial,
        onSessionChanged: changes.add,
      );

  void onIdToken(String? token) => pushed.add(token);

  setUp(() {
    server = FakeConvexAuthServer();
    client = ConvexAuthHttpClient(
      deploymentUrl: deploymentUrl,
      httpClient: server.httpClient,
    );
    changes = <ConvexAuthSession?>[];
    pushed = <String?>[];
    server.handlers['auth:signOut'] = (_) => null;
  });

  group('login', () {
    test('signs in with the sign-in request and reports the session', () async {
      server.handlers['auth:signInWithUsernamePassword'] = (_) => complete('a');
      final provider = newProvider()
        ..signIn = ConvexAuthSignIn.usernamePassword(
          username: 'alice',
          password: 'pw',
        );

      final session = await provider.login(onIdToken: onIdToken);

      expect(session.accessToken, 'jwt_a');
      expect(provider.extractIdToken(session), 'jwt_a');
      expect(provider.session, session);
      expect(provider.signIn, isNull);
      expect(changes, [session]);
      expect(pushed, ['jwt_a']);
      expect(server.calls.single.args, {'username': 'alice', 'password': 'pw'});
    });

    test('a userError is a ConvexAuthSignInException with its code', () async {
      server.handlers['auth:signInWithEmailPassword'] = (_) => {
            'status': 'error',
            'userError': {'error': 'RATE_LIMITED', 'retryAfterMs': 1500},
          };
      final provider = newProvider()
        ..signIn = ConvexAuthSignIn.emailPassword(
          email: 'a@example.com',
          password: 'pw',
        );

      await expectLater(
        provider.login(onIdToken: onIdToken),
        throwsA(isA<ConvexAuthSignInException>()
            .having((e) => e.code, 'code', 'RATE_LIMITED')
            .having((e) => e.retryAfter, 'retryAfter',
                const Duration(milliseconds: 1500))
            .having(
                (e) => e.function, 'function', 'auth:signInWithEmailPassword')),
      );
      expect(provider.session, isNull);
      expect(provider.signIn, isNull);
      expect(changes, isEmpty);
    });

    test('keeps the sign-in request after a retryable failure', () async {
      var attempts = 0;
      server.handlers['auth:signInAnonymously'] = (_) {
        attempts++;
        if (attempts == 1) {
          throw http.Response('unavailable', 503);
        }
        return complete('anon');
      };
      final provider = newProvider()
        ..signIn = const ConvexAuthSignIn.anonymous();

      await expectLater(
        provider.login(onIdToken: onIdToken),
        throwsA(isA<ConvexAuthException>()
            .having((e) => e.retryable, 'retryable', isTrue)),
      );
      expect(provider.signIn, isNotNull);

      final session = await provider.login(onIdToken: onIdToken);
      expect(session.userId, 'u1');
      expect(provider.signIn, isNull);
    });

    test('throws a StateError without a sign-in request', () {
      expect(
        () => newProvider().login(onIdToken: onIdToken),
        throwsStateError,
      );
    });

    test('an adopted session is used without calling the server', () async {
      final provider = newProvider();
      final adopted = ConvexAuthSession.fromJson(bundle('oauth'));
      provider.adoptSession(adopted);

      final session = await provider.login(onIdToken: onIdToken);

      expect(session, adopted);
      expect(server.calls, isEmpty);
      expect(changes, [adopted]);
    });

    test('a new login revokes the previous session', () async {
      server.handlers['auth:signInAnonymously'] = (_) => complete('second');
      final first = ConvexAuthSession.fromJson(bundle('first'));
      final provider = newProvider(initial: first)
        ..signIn = const ConvexAuthSignIn.anonymous();

      await provider.login(onIdToken: onIdToken);
      await waitUntil(() => server.callsTo('auth:signOut').isNotEmpty,
          reason: 'revocation of the previous session');

      expect(server.callsTo('auth:signOut').single.args,
          {'refreshToken': 'rt_first'});
    });

    test('a login superseded by logout revokes its session', () async {
      final gate = Completer<Object?>();
      server.handlers['auth:signInAnonymously'] = (_) => gate.future;
      final provider = newProvider()
        ..signIn = const ConvexAuthSignIn.anonymous();

      final login = provider.login(onIdToken: onIdToken);
      await waitUntil(() => server.calls.isNotEmpty, reason: 'sign-in call');
      await provider.logout();
      gate.complete(complete('late'));

      await expectLater(login, throwsA(isA<ConvexAuthException>()));
      expect(provider.session, isNull);
      await waitUntil(() => server.callsTo('auth:signOut').isNotEmpty,
          reason: 'revocation of the late session');
      expect(server.callsTo('auth:signOut').single.args,
          {'refreshToken': 'rt_late'});
      expect(pushed, isEmpty);
    });
  });

  group('loginFromCache', () {
    test('without a session throws ConvexAuthSessionEndedException', () async {
      await expectLater(
        newProvider().loginFromCache(onIdToken: onIdToken),
        throwsA(isA<ConvexAuthSessionEndedException>()),
      );
    });

    test('rotates the session and reports it', () async {
      server.handlers['auth:refreshSession'] = (call) {
        expect(call.args, {'refreshToken': 'rt_old'});
        return rotated('new');
      };
      final provider =
          newProvider(initial: ConvexAuthSession.fromJson(bundle('old')));

      final session = await provider.loginFromCache(onIdToken: onIdToken);

      expect(session.refreshToken, 'rt_new');
      expect(provider.session, session);
      expect(changes, [session]);
      expect(pushed, ['jwt_new']);
    });

    test('noSession clears the session', () async {
      server.handlers['auth:refreshSession'] = (_) => noSession;
      final provider =
          newProvider(initial: ConvexAuthSession.fromJson(bundle('old')));

      await expectLater(
        provider.loginFromCache(onIdToken: onIdToken),
        throwsA(isA<ConvexAuthSessionEndedException>()),
      );
      expect(provider.session, isNull);
      expect(changes, [null]);
    });

    test('concurrent refreshes share one request', () async {
      final gate = Completer<Object?>();
      server.handlers['auth:refreshSession'] = (_) => gate.future;
      final provider =
          newProvider(initial: ConvexAuthSession.fromJson(bundle('old')));

      final background = asBackgroundRefresh(
          () => provider.loginFromCache(onIdToken: onIdToken));
      final explicit = provider.loginFromCache(onIdToken: onIdToken);
      // The explicit restore supersedes the background refresh.
      final backgroundSuperseded = expectLater(
        background,
        throwsA(isA<ConvexAuthException>()
            .having((e) => e.retryable, 'retryable', isTrue)),
      );
      await waitUntil(() => server.calls.isNotEmpty, reason: 'refresh call');
      gate.complete(rotated('new'));

      expect((await explicit).refreshToken, 'rt_new');
      await backgroundSuperseded;
      expect(server.callsTo('auth:refreshSession'), hasLength(1));

      // The next refresh sends the rotated token.
      server.handlers['auth:refreshSession'] = (call) {
        expect(call.args, {'refreshToken': 'rt_new'});
        return rotated('newer');
      };
      final next = await asBackgroundRefresh(
          () => provider.loginFromCache(onIdToken: onIdToken));
      expect(next.refreshToken, 'rt_newer');
    });

    test('retries once right away after a lost response', () async {
      var attempts = 0;
      server.handlers['auth:refreshSession'] = (_) {
        attempts++;
        if (attempts == 1) {
          throw http.Response('bad gateway', 502);
        }
        return rotated('new');
      };
      final provider =
          newProvider(initial: ConvexAuthSession.fromJson(bundle('old')));

      final session = await provider.loginFromCache(onIdToken: onIdToken);

      expect(session.refreshToken, 'rt_new');
      expect(server.callsTo('auth:refreshSession'), hasLength(2));
    });

    test('a refresh finishing after logout revokes the rotated session',
        () async {
      final gate = Completer<Object?>();
      server.handlers['auth:refreshSession'] = (_) => gate.future;
      final provider =
          newProvider(initial: ConvexAuthSession.fromJson(bundle('old')));

      final refresh = asBackgroundRefresh(
          () => provider.loginFromCache(onIdToken: onIdToken));
      await waitUntil(() => server.calls.isNotEmpty, reason: 'refresh call');
      await provider.logout();
      gate.complete(rotated('orphan'));

      await expectLater(refresh, throwsA(isA<ConvexAuthException>()));
      expect(provider.session, isNull);
      await waitUntil(
        () => server
            .callsTo('auth:signOut')
            .any((call) => call.args['refreshToken'] == 'rt_orphan'),
        reason: 'revocation of the rotated session',
      );
      expect(changes, [null]);
    });

    test('a background refresh does not supersede a pending login', () async {
      final gate = Completer<Object?>();
      server.handlers['auth:signInAnonymously'] = (_) => gate.future;
      server.handlers['auth:refreshSession'] = (_) => rotated('refreshed');
      final provider =
          newProvider(initial: ConvexAuthSession.fromJson(bundle('old')))
            ..signIn = const ConvexAuthSignIn.anonymous();

      final login = provider.login(onIdToken: onIdToken);
      await waitUntil(() => server.calls.isNotEmpty, reason: 'sign-in call');
      await asBackgroundRefresh(
          () => provider.loginFromCache(onIdToken: onIdToken));
      gate.complete(complete('login'));

      expect((await login).refreshToken, 'rt_login');
      expect(provider.session?.refreshToken, 'rt_login');
    });

    test('an onSessionChanged error does not break the refresh', () async {
      server.handlers['auth:refreshSession'] = (_) => rotated('new');
      final errors = <Object>[];
      final provider = ConvexAuthSessionProvider(
        client: client,
        initialSession: ConvexAuthSession.fromJson(bundle('old')),
        onSessionChanged: (_) => throw StateError('disk full'),
      );

      final session = await runZonedGuarded(
        () => provider.loginFromCache(onIdToken: onIdToken),
        (error, _) => errors.add(error),
      );

      expect(session?.refreshToken, 'rt_new');
      expect(errors.single, isA<StateError>());
    });
  });

  group('logout', () {
    test('clears local state, then revokes the session', () async {
      final provider =
          newProvider(initial: ConvexAuthSession.fromJson(bundle('old')))
            ..signIn = const ConvexAuthSignIn.anonymous();

      await provider.logout();

      expect(provider.session, isNull);
      expect(provider.signIn, isNull);
      expect(changes, [null]);
      expect(server.callsTo('auth:signOut').single.args,
          {'refreshToken': 'rt_old'});
    });

    test('without a session does not call the server', () async {
      await newProvider().logout();
      expect(server.calls, isEmpty);
      expect(changes, isEmpty);
    });
  });
}
