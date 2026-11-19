import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart' as convex;
import 'package:dartvex_auth2_convex/dartvex_auth2_convex.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import 'package:dartvex_flutter_demo/src/app.dart';
import 'package:dartvex_flutter_demo/src/core/unavailable_runtime_client.dart';
import 'package:dartvex_flutter_demo/src/features/auth/data/convex_auth_demo.dart';
import 'package:dartvex_flutter_demo/src/features/auth/presentation/convex_auth_panel.dart';

void main() {
  group('ConvexAuthSessionStore', () {
    test('counts the rotations of one session', () {
      final store = ConvexAuthSessionStore();
      var notifications = 0;
      store.addListener(() => notifications += 1);

      store.save(_session('a', session: 's1'));
      expect(store.rotationCount, 0);
      store.save(_session('b', session: 's1'));
      store.save(_session('c', session: 's1'));
      expect(store.rotationCount, 2);
      expect(store.session!.refreshToken, 'rt_c');
      expect(notifications, 3);

      // Another sign-in is another session, not a rotation.
      store.save(_session('d', session: 's2'));
      expect(store.rotationCount, 0);

      store.save(null);
      expect(store.session, isNull);
      expect(store.rotationCount, 0);
    });

    test('accepts a late save after dispose', () {
      final store = ConvexAuthSessionStore()..dispose();
      store.save(_session('a', session: 's1'));
      expect(store.session, isNotNull);
    });
  });

  group('describeConvexAuthError', () {
    test('maps the codes of the username/password method', () {
      String describe(Map<String, Object?> userError) =>
          describeConvexAuthError(
            ConvexAuthSignInException(
              ConvexAuthDemoFunctions.signIn,
              userError,
            ),
          );

      expect(
        describe(<String, Object?>{'error': 'INVALID_CREDENTIALS'}),
        'Wrong username or password.',
      );
      expect(
        describe(<String, Object?>{'error': 'USERNAME_TAKEN'}),
        'This username is already taken.',
      );
      expect(
        describe(<String, Object?>{
          'error': 'PASSWORD_TOO_SHORT',
          'minimumLength': 10,
        }),
        'The password is too short (10 characters at least).',
      );
      expect(
        describe(<String, Object?>{
          'error': 'RATE_LIMITED',
          'retryAfterMs': 29500,
        }),
        'Too many attempts. Try again in 30 s.',
      );
      expect(
        describe(<String, Object?>{'error': 'SOMETHING_NEW'}),
        'Sign-in rejected: SOMETHING_NEW.',
      );
    });

    test('does not quote the server for other failures', () {
      const error = ConvexAuthException(
        'Convex mutation convexAuth:signIn failed with HTTP 503.',
        retryable: true,
        serverMessage: 'secret detail',
      );
      final message = describeConvexAuthError(error);
      expect(message, contains('HTTP 503'));
      expect(message, endsWith('Try again.'));
      expect(message, isNot(contains('secret detail')));
    });
  });

  group('ConvexAuthPanel', () {
    testWidgets('signs up, shows the session, and signs out', (tester) async {
      final harness = _Harness((path, args) {
        if (path == ConvexAuthDemoFunctions.signUp) {
          return <String, Object?>{
            'status': 'complete',
            'tokens': _bundle('a', session: 's1'),
          };
        }
        return null;
      });
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build());

      expect(find.text('Convex Auth v2 Demo'), findsOneWidget);
      expect(find.text('Restore Session'), findsNothing);

      await tester.enterText(
        find.byKey(const ValueKey<String>('convex-auth-username')),
        ' ada ',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('convex-auth-password')),
        'correct horse battery',
      );
      await tester.tap(find.text('Sign Up'));
      await tester.pumpAndSettle();

      expect(harness.calls.single.path, ConvexAuthDemoFunctions.signUp);
      expect(harness.calls.single.args, <String, Object?>{
        'username': 'ada',
        'password': 'correct horse battery',
      });
      // The request is sent once and forgotten, with its password.
      expect(harness.provider.signIn, isNull);
      expect(find.text('Auth: Signed in'), findsOneWidget);
      expect(find.text('userId: user_1'), findsOneWidget);
      expect(find.text('sessionId: s1'), findsOneWidget);
      expect(find.text('Token rotations: 0'), findsOneWidget);
      expect(harness.store.session!.refreshToken, 'rt_a');

      // A refresh saves the rotated session: the panel follows the store.
      harness.store.save(_session('b', session: 's1'));
      await tester.pump();
      expect(find.text('Token rotations: 1'), findsOneWidget);

      await tester.tap(find.text('Sign Out'));
      await tester.pumpAndSettle();

      expect(harness.calls.last.path, ConvexAuthDemoFunctions.signOut);
      expect(harness.store.session, isNull);
      expect(find.text('Sign Up'), findsOneWidget);
      expect(find.text('Restore Session'), findsNothing);
    });

    testWidgets('shows the reason of a rejected sign-in', (tester) async {
      final harness = _Harness(
        (path, args) => <String, Object?>{
          'status': 'error',
          'userError': <String, Object?>{'error': 'INVALID_CREDENTIALS'},
        },
      );
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build());

      await tester.tap(find.text('Already have an account? Sign in'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey<String>('convex-auth-username')),
        'ada',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('convex-auth-password')),
        'wrong password',
      );
      await tester.tap(find.text('Sign In'));
      await tester.pumpAndSettle();

      expect(harness.calls.single.path, ConvexAuthDemoFunctions.signIn);
      expect(find.text('Wrong username or password.'), findsOneWidget);
      expect(find.text('Auth: Signed in'), findsNothing);
      expect(harness.store.session, isNull);
    });

    testWidgets('submitting twice from the keyboard sends one request', (
      tester,
    ) async {
      final gate = Completer<void>();
      final harness = _Harness((path, args) async {
        await gate.future;
        return <String, Object?>{
          'status': 'complete',
          'tokens': _bundle('a', session: 's1'),
        };
      });
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build());

      await tester.enterText(
        find.byKey(const ValueKey<String>('convex-auth-username')),
        'ada',
      );
      await tester.enterText(
        find.byKey(const ValueKey<String>('convex-auth-password')),
        'correct horse battery',
      );
      // The button is disabled while the request is in flight, but the
      // keyboard's submit action is not.
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      // Submitting drops the focus: go back to the field and submit again.
      await tester.showKeyboard(
        find.byKey(const ValueKey<String>('convex-auth-password')),
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(harness.calls, hasLength(1));

      gate.complete();
      await tester.pumpAndSettle();

      expect(harness.calls, hasLength(1));
      expect(find.text('Auth: Signed in'), findsOneWidget);
      expect(find.text('Token rotations: 0'), findsOneWidget);
    });

    testWidgets('offers to restore a saved session that is not live', (
      tester,
    ) async {
      final harness = _Harness((path, args) {
        if (path == ConvexAuthDemoFunctions.refreshSession) {
          expect(args['refreshToken'], 'rt_a');
          return <String, Object?>{
            'kind': 'rotated',
            'tokens': _bundle('b', session: 's1'),
          };
        }
        return null;
      }, initialSession: _session('a', session: 's1'));
      addTearDown(harness.dispose);
      await tester.pumpWidget(harness.build());

      await tester.tap(find.text('Restore Session'));
      await tester.pumpAndSettle();

      expect(harness.calls.single.path, ConvexAuthDemoFunctions.refreshSession);
      expect(find.text('Auth: Signed in'), findsOneWidget);
      expect(find.text('Token rotations: 1'), findsOneWidget);
      expect(harness.store.session!.refreshToken, 'rt_b');
    });

    testWidgets('setup panel lists the steps and the reason', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConvexAuthSetupPanel(error: 'Plain HTTP refused.'),
            ),
          ),
        ),
      );

      expect(find.text('Convex Auth Not Configured'), findsOneWidget);
      expect(find.text('Plain HTTP refused.'), findsOneWidget);
      expect(find.text('Install the backend'), findsOneWidget);
      expect(find.text('Set DEMO_JWKS (new deployment)'), findsOneWidget);
      expect(find.text('Deploy'), findsOneWidget);
      expect(find.text('Run the demo'), findsOneWidget);
    });
  });

  testWidgets('the app offers Convex Auth as a third auth mode', (
    tester,
  ) async {
    // A phone-sized window: the three modes must fit the selector.
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const DartvexDemoApp(deploymentUrlOverride: ''));
    await tester.tap(find.text('Auth').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Convex Auth'));
    await tester.pumpAndSettle();

    expect(find.text('Convex Auth Not Configured'), findsOneWidget);
    expect(find.textContaining('Convex Auth auth'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

/// An unsigned JWT whose `sub` is the server session id, like the access
/// tokens of Convex Auth.
String _jwt(String id, String session) {
  String encode(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${encode(<String, Object?>{'alg': 'none'})}.'
      '${encode(<String, Object?>{'sub': session, 'jti': id})}.sig';
}

Map<String, Object> _bundle(String id, {required String session}) =>
    <String, Object>{
      'accessToken': _jwt(id, session),
      'refreshToken': 'rt_$id',
      'refreshTokenExpiresAt': 1893456000000,
      'userId': 'user_1',
    };

ConvexAuthSession _session(String id, {required String session}) =>
    ConvexAuthSession.fromJson(_bundle(id, session: session));

typedef _Call = ({String path, Map<String, dynamic> args});

/// The panel with a real provider talking to a mocked Convex HTTP API, and an
/// auth client that drives the provider like `ConvexClientWithAuth` does.
class _Harness {
  _Harness(
    FutureOr<Object?> Function(String path, Map<String, dynamic> args)
    handler, {
    ConvexAuthSession? initialSession,
  }) {
    if (initialSession != null) {
      store.save(initialSession);
    }
    provider = ConvexAuthSessionProvider(
      client: ConvexAuthHttpClient(
        deploymentUrl: 'https://test-app.convex.cloud',
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final path = body['path'] as String;
          final args = (body['args'] as List<dynamic>).single;
          calls.add((path: path, args: args as Map<String, dynamic>));
          return http.Response(
            jsonEncode(<String, Object?>{
              'status': 'success',
              'value': await handler(path, args),
            }),
            200,
            headers: <String, String>{'content-type': 'application/json'},
          );
        }),
      ),
      initialSession: initialSession,
      onSessionChanged: store.save,
      refreshSessionFunction: ConvexAuthDemoFunctions.refreshSession,
      signOutFunction: ConvexAuthDemoFunctions.signOut,
    );
    authClient = _FakeConvexAuthClient(provider);
  }

  final ConvexAuthSessionStore store = ConvexAuthSessionStore();
  final List<_Call> calls = <_Call>[];
  late final ConvexAuthSessionProvider provider;
  late final _FakeConvexAuthClient authClient;

  Widget build() {
    return ConvexProvider(
      client: const UnavailableRuntimeClient(),
      child: ConvexAuthProvider<ConvexAuthSession>(
        client: authClient,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConvexAuthPanel(
                provider: provider,
                authClient: authClient,
                store: store,
              ),
            ),
          ),
        ),
      ),
    );
  }

  void dispose() {
    authClient.dispose();
    store.dispose();
  }
}

class _FakeConvexAuthClient
    implements convex.ConvexAuthClient<ConvexAuthSession> {
  _FakeConvexAuthClient(this._provider);

  final ConvexAuthSessionProvider _provider;

  final StreamController<convex.AuthState<ConvexAuthSession>> _states =
      StreamController<convex.AuthState<ConvexAuthSession>>.broadcast(
        sync: true,
      );

  convex.AuthState<ConvexAuthSession> _current =
      const convex.AuthUnauthenticated<ConvexAuthSession>();

  void _emit(convex.AuthState<ConvexAuthSession> state) {
    _current = state;
    if (!_states.isClosed) {
      _states.add(state);
    }
  }

  @override
  Stream<convex.AuthState<ConvexAuthSession>> get authState => _states.stream;

  @override
  convex.AuthState<ConvexAuthSession> get currentAuthState => _current;

  @override
  Future<ConvexAuthSession> login() async {
    final session = await _provider.login(onIdToken: (_) {});
    _emit(convex.AuthAuthenticated<ConvexAuthSession>(session));
    return session;
  }

  @override
  Future<ConvexAuthSession> loginFromCache() async {
    final session = await _provider.loginFromCache(onIdToken: (_) {});
    _emit(convex.AuthAuthenticated<ConvexAuthSession>(session));
    return session;
  }

  @override
  Future<void> logout() async {
    await _provider.logout();
    _emit(const convex.AuthUnauthenticated<ConvexAuthSession>());
  }

  @override
  Future<void> clearAuth() async {}

  @override
  void dispose() {
    unawaited(_states.close());
  }

  @override
  Stream<convex.ConnectionState> get connectionState => const Stream.empty();

  @override
  convex.ConnectionState get currentConnectionState =>
      convex.ConnectionState.disconnected;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
