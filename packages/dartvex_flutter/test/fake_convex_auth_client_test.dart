import 'dart:async';

import 'package:dartvex/dartvex.dart' show QuerySuccess;
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Revoked extends StateError implements AuthSessionEndedError {
  _Revoked() : super('revoked');
}

void main() {
  group('FakeConvexAuthClient', () {
    test('login emits loading then authenticated and counts calls', () async {
      final auth = FakeConvexAuthClient<String>(onLogin: () => 'alice');
      final states = <AuthState<String>>[];
      auth.authState.listen(states.add);

      expect(await auth.login(), 'alice');

      expect(auth.loginCalls, 1);
      expect(states, [
        isA<AuthLoading<String>>(),
        isA<AuthAuthenticated<String>>().having(
          (s) => s.userInfo,
          'userInfo',
          'alice',
        ),
      ]);
      expect(auth.currentAuthState, isA<AuthAuthenticated<String>>());
    });

    test(
      'loginFromCache without a handler fails as a session-ended error',
      () async {
        final auth = FakeConvexAuthClient<String>();

        await expectLater(
          auth.loginFromCache(),
          throwsA(isA<AuthSessionEndedError>()),
        );
        expect(auth.loginFromCacheCalls, 1);
        expect(auth.currentAuthState, isA<AuthUnauthenticated<String>>());
      },
    );

    test('login without a handler throws a StateError', () async {
      final auth = FakeConvexAuthClient<String>();
      await expectLater(auth.login(), throwsStateError);
    });

    test('a transient failure keeps the previous session', () async {
      final auth = FakeConvexAuthClient<String>(
        initialAuthState: const AuthAuthenticated<String>('alice'),
        onLoginFromCache: () => throw TimeoutException('offline'),
      );

      await expectLater(
        auth.loginFromCache(),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        auth.currentAuthState,
        isA<AuthAuthenticated<String>>().having(
          (s) => s.userInfo,
          'userInfo',
          'alice',
        ),
      );
    });

    test('a session-ended failure signs out', () async {
      final auth = FakeConvexAuthClient<String>(
        initialAuthState: const AuthAuthenticated<String>('alice'),
        onLoginFromCache: () => throw _Revoked(),
      );

      await expectLater(auth.loginFromCache(), throwsA(isA<_Revoked>()));
      expect(auth.currentAuthState, isA<AuthUnauthenticated<String>>());
    });

    test(
      'logout and clearAuth sign out; a throwing onLogout is rethrown',
      () async {
        final auth = FakeConvexAuthClient<String>(
          initialAuthState: const AuthAuthenticated<String>('alice'),
          onLogout: () => throw StateError('network'),
        );

        await expectLater(auth.logout(), throwsStateError);
        expect(auth.logoutCalls, 1);
        expect(auth.currentAuthState, isA<AuthUnauthenticated<String>>());

        auth.emit(const AuthAuthenticated<String>('bob'));
        await auth.clearAuth();
        expect(auth.clearAuthCalls, 1);
        expect(auth.currentAuthState, isA<AuthUnauthenticated<String>>());
      },
    );

    test(
      'function calls and connection state go to the FakeConvexClient',
      () async {
        final convex =
            FakeConvexClient(
                initialConnectionState: ConvexConnectionState.connecting,
              )
              ..whenQuery('users:me', returns: {'name': 'Alice'})
              ..whenMutation('users:rename', returns: null);
        final auth = FakeConvexAuthClient<String>(client: convex);

        expect(await auth.query('users:me'), {'name': 'Alice'});
        await auth.mutate('users:rename', {'name': 'Bob'});
        expect(convex.mutationCalls.single.args, {'name': 'Bob'});
        expect(auth.currentConnectionState, ConvexConnectionState.connecting);

        final subscription = auth.subscribe('users:me');
        final first = await subscription.stream.first;
        expect(first, isA<QuerySuccess>());
        subscription.cancel();
      },
    );

    test('calls after dispose throw', () async {
      final auth = FakeConvexAuthClient<String>(onLogin: () => 'alice')
        ..dispose();
      expect(auth.isDisposed, isTrue);
      expect(auth.login, throwsA(isA<Exception>()));
    });

    testWidgets('drives ConvexAuthBuilder', (tester) async {
      final auth = FakeConvexAuthClient<String>(onLogin: () => 'alice');
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ConvexAuthProvider<String>(
            client: auth,
            child: ConvexAuthBuilder<String>(
              builder: (context, state) => Text(switch (state) {
                AuthAuthenticated<String>(:final userInfo) => userInfo,
                AuthLoading<String>() => 'loading',
                AuthUnauthenticated<String>() => 'signed out',
              }),
            ),
          ),
        ),
      );
      expect(find.text('signed out'), findsOneWidget);

      await auth.login();
      await tester.pump();
      expect(find.text('alice'), findsOneWidget);
    });
  });

  group('ConvexRuntimeWatch with FakeConvexClient', () {
    test(
      'decodes values, forwards errors, skips loading and cached seeds',
      () async {
        final convex = FakeConvexClient();
        final events = <Object>[];
        final listener = convex
            .watch<int>(
              'counters:get',
              const <String, dynamic>{},
              decode: (value) => (value as int) * 2,
              skipCached: true,
            )
            .listen(events.add, onError: events.add);
        await Future<void>.delayed(Duration.zero);

        convex
          ..emitSubscription('counters:get', 1, source: ConvexQuerySource.cache)
          ..emitSubscriptionLoading('counters:get')
          ..emitSubscription('counters:get', 2)
          ..emitSubscription(
            'counters:get',
            3,
            source: ConvexQuerySource.cache,
            hasPendingWrites: true,
          )
          ..emitSubscriptionError('counters:get', StateError('boom'));
        await Future<void>.delayed(Duration.zero);

        expect(events, [4, 6, isA<StateError>()]);
        await listener.cancel();
      },
    );

    test('cancelling the stream cancels the subscription', () async {
      final convex = FakeConvexClient()..whenQuery('a:b', returns: 1);
      expect(
        await convex.watch<int>('a:b', const <String, dynamic>{}).first,
        1,
      );
      // Emitting after the cancel reaches no subscription.
      expect(() => convex.emitSubscription('a:b', 2), returnsNormally);
    });
  });
}
