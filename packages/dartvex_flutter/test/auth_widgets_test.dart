import 'package:dartvex/dartvex.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_auth_client.dart';

void main() {
  Widget wrap(Widget child) {
    return Directionality(textDirection: TextDirection.ltr, child: child);
  }

  String describeAuthState(AuthState<String> state) {
    return switch (state) {
      AuthLoading<String>() => 'loading',
      AuthAuthenticated<String>(:final userInfo) => 'auth:$userInfo',
      AuthUnauthenticated<String>() => 'signed-out',
    };
  }

  testWidgets('provider lookup works', (tester) async {
    final client = FakeAuthClient<String>(
      initialAuthState: const AuthUnauthenticated<String>(),
    );
    late ConvexAuthClient<String> resolved;

    await tester.pumpWidget(
      wrap(
        ConvexAuthProvider<String>(
          client: client,
          child: Builder(
            builder: (context) {
              resolved = ConvexAuthProvider.of<String>(context);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    expect(identical(resolved, client), isTrue);
  });

  testWidgets('ConvexAuthBuilder renders currentAuthState immediately', (
    tester,
  ) async {
    final client = FakeAuthClient<String>(
      initialAuthState: const AuthLoading<String>(),
    );

    await tester.pumpWidget(
      wrap(
        ConvexAuthProvider<String>(
          client: client,
          child: ConvexAuthBuilder<String>(
            builder: (context, state) => Text(describeAuthState(state)),
          ),
        ),
      ),
    );

    expect(find.text('loading'), findsOneWidget);
  });

  testWidgets('widget rebuilds on AuthLoading to AuthAuthenticated', (
    tester,
  ) async {
    final client = FakeAuthClient<String>(
      initialAuthState: const AuthLoading<String>(),
    );

    await tester.pumpWidget(
      wrap(
        ConvexAuthProvider<String>(
          client: client,
          child: ConvexAuthBuilder<String>(
            builder: (context, state) => Text(describeAuthState(state)),
          ),
        ),
      ),
    );

    client.emitAuthState(const AuthAuthenticated<String>('Alice'));
    await tester.pump();

    expect(find.text('auth:Alice'), findsOneWidget);
  });

  testWidgets('widget rebuilds on AuthAuthenticated to AuthUnauthenticated', (
    tester,
  ) async {
    final client = FakeAuthClient<String>(
      initialAuthState: const AuthAuthenticated<String>('Alice'),
    );

    await tester.pumpWidget(
      wrap(
        ConvexAuthProvider<String>(
          client: client,
          child: ConvexAuthBuilder<String>(
            builder: (context, state) => Text(describeAuthState(state)),
          ),
        ),
      ),
    );

    client.emitAuthState(const AuthUnauthenticated<String>());
    await tester.pump();

    expect(find.text('signed-out'), findsOneWidget);
  });

  testWidgets('missing provider throws a useful error', (tester) async {
    await tester.pumpWidget(
      wrap(
        Builder(
          builder: (context) {
            ConvexAuthProvider.of<String>(context);
            return const SizedBox();
          },
        ),
      ),
    );

    final exception = tester.takeException();
    expect(exception, isA<FlutterError>());
    expect(
      exception.toString(),
      contains('ConvexAuthProvider.of<String>() called with no matching'),
    );
  });

  testWidgets('explicit client parameter bypasses provider lookup correctly', (
    tester,
  ) async {
    final client = FakeAuthClient<String>(
      initialAuthState: const AuthAuthenticated<String>('Bob'),
    );

    await tester.pumpWidget(
      wrap(
        ConvexAuthBuilder<String>(
          client: client,
          builder: (context, state) => Text(describeAuthState(state)),
        ),
      ),
    );

    expect(find.text('auth:Bob'), findsOneWidget);
  });

  testWidgets('ConvexAuthProvider disposes owned clients', (tester) async {
    final client = FakeAuthClient<String>(
      initialAuthState: const AuthUnauthenticated<String>(),
    );

    await tester.pumpWidget(
      wrap(
        ConvexAuthProvider<String>(
          client: client,
          disposeClient: true,
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());

    expect(client.disposed, isTrue);
  });
}
