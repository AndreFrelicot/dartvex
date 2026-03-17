import 'dart:async';

import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dartvex/dartvex.dart' as convex;

import 'package:dartvex_flutter_demo/src/core/unavailable_runtime_client.dart';
import 'package:dartvex_flutter_demo/src/features/auth/data/demo_auth_provider.dart';
import 'package:dartvex_flutter_demo/src/features/auth/presentation/auth_panel.dart';

void main() {
  Widget buildHarness({
    required FakeDemoAuthClient authClient,
    required DemoAuthProvider demoAuthProvider,
    required Future<void> Function() onLogin,
    required Future<void> Function() onLoginFromCache,
    required Future<void> Function() onLogout,
    required Future<void> Function() onForceReconnect,
    String? authStatus,
  }) {
    return ConvexProvider(
      client: const UnavailableRuntimeClient(),
      child: ConvexAuthProvider<DemoUserSession>(
        client: authClient,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AuthPanel(
                api: null,
                authClient: authClient,
                demoAuthProvider: demoAuthProvider,
                authStatus: authStatus,
                onLogin: onLogin,
                onLoginFromCache: onLoginFromCache,
                onLogout: onLogout,
                onForceReconnect: onForceReconnect,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('AuthPanel renders auth state labels and reacts to updates', (
    tester,
  ) async {
    final demoAuthProvider = DemoAuthProvider(
      preferredToken: 'demo-token',
      tokenLabel: 'test token',
    );
    final authClient = FakeDemoAuthClient(
      const convex.AuthUnauthenticated<DemoUserSession>(),
    );

    await tester.pumpWidget(
      buildHarness(
        authClient: authClient,
        demoAuthProvider: demoAuthProvider,
        onLogin: () async {},
        onLoginFromCache: () async {},
        onLogout: () async {},
        onForceReconnect: () async {},
      ),
    );

    expect(find.text('Auth: Signed out'), findsOneWidget);
    expect(find.text('Connection: disconnected'), findsOneWidget);

    authClient.emit(
      convex.AuthAuthenticated<DemoUserSession>(
        DemoUserSession(
          token: 'demo-token',
          userId: 'demo-user-1',
          displayName: 'Demo User',
          issuedAt: DateTime.utc(2026, 3, 13),
          cacheRestoreCount: 1,
          tokenLabel: 'test token',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Auth: Authenticated'), findsOneWidget);
    expect(find.text('Authenticated session'), findsOneWidget);
    expect(find.textContaining('cache refresh count: 1'), findsOneWidget);
  });

  testWidgets('AuthPanel wires login and reconnect actions', (tester) async {
    final demoAuthProvider = DemoAuthProvider(
      preferredToken: 'demo-token',
      tokenLabel: 'test token',
    );
    final authClient = FakeDemoAuthClient(
      convex.AuthAuthenticated<DemoUserSession>(
        DemoUserSession(
          token: 'demo-token',
          userId: 'demo-user-1',
          displayName: 'Demo User',
          issuedAt: DateTime.utc(2026, 3, 13),
          cacheRestoreCount: 0,
          tokenLabel: 'test token',
        ),
      ),
    );
    var loginCalls = 0;
    var cacheCalls = 0;
    var logoutCalls = 0;
    var reconnectCalls = 0;

    await tester.pumpWidget(
      buildHarness(
        authClient: authClient,
        demoAuthProvider: demoAuthProvider,
        authStatus: 'Forced reconnect requested.',
        onLogin: () async {
          loginCalls += 1;
        },
        onLoginFromCache: () async {
          cacheCalls += 1;
        },
        onLogout: () async {
          logoutCalls += 1;
        },
        onForceReconnect: () async {
          reconnectCalls += 1;
        },
      ),
    );

    await tester.tap(find.text('Login'));
    await tester.pump();
    await tester.tap(find.text('Login From Cache'));
    await tester.pump();
    await tester.tap(find.text('Logout'));
    await tester.pump();
    await tester.tap(find.text('Force Reconnect'));
    await tester.pump();

    expect(loginCalls, 1);
    expect(cacheCalls, 1);
    expect(logoutCalls, 1);
    expect(reconnectCalls, 1);
    expect(find.text('Forced reconnect requested.'), findsOneWidget);
  });
}

class FakeDemoAuthClient implements convex.ConvexAuthClient<DemoUserSession> {
  FakeDemoAuthClient(this._currentAuthState);

  final StreamController<convex.AuthState<DemoUserSession>>
  _authStateController =
      StreamController<convex.AuthState<DemoUserSession>>.broadcast(sync: true);

  convex.AuthState<DemoUserSession> _currentAuthState;

  void emit(convex.AuthState<DemoUserSession> state) {
    _currentAuthState = state;
    _authStateController.add(state);
  }

  @override
  Stream<convex.AuthState<DemoUserSession>> get authState =>
      _authStateController.stream;

  @override
  convex.AuthState<DemoUserSession> get currentAuthState => _currentAuthState;

  @override
  Stream<convex.ConnectionState> get connectionState => const Stream.empty();

  @override
  convex.ConnectionState get currentConnectionState =>
      convex.ConnectionState.disconnected;

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async => throw UnimplementedError();

  @override
  void dispose() {
    unawaited(_authStateController.close());
  }

  @override
  Future<DemoUserSession> login() async => throw UnimplementedError();

  @override
  Future<DemoUserSession> loginFromCache() async => throw UnimplementedError();

  @override
  Future<void> logout() async {}

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async => throw UnimplementedError();

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async => throw UnimplementedError();

  @override
  convex.ConvexSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) => throw UnimplementedError();
}
