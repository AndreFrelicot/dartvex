import 'dart:async';

import 'package:dartvex/dartvex.dart' as convex;
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dartvex_flutter_demo/src/core/unavailable_runtime_client.dart';
import 'package:dartvex_flutter_demo/src/features/auth/data/auth_mode.dart';
import 'package:dartvex_flutter_demo/src/features/auth/data/demo_auth_provider.dart';
import 'package:dartvex_flutter_demo/src/features/auth/presentation/auth_panel.dart';
import 'package:dartvex_flutter_demo/src/features/auth/presentation/clerk_auth_panel.dart';

void main() {
  group('Auth mode switching', () {
    testWidgets('app starts in Demo mode by default', (tester) async {
      await tester.pumpWidget(
        const ConvexFlutterDemoAppForTest(deploymentUrl: ''),
      );

      // Mode selector should be visible with Demo selected.
      expect(find.text('Demo Provider'), findsOneWidget);
      expect(find.text('Clerk'), findsOneWidget);

      // Demo auth panel content should be shown.
      expect(find.text('Provider-backed Auth Demo'), findsOneWidget);
    });

    testWidgets('switching to Clerk mode without config shows setup panel', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ConvexFlutterDemoAppForTest(deploymentUrl: ''),
      );

      // Switch to Clerk mode.
      await tester.tap(find.text('Clerk'));
      await tester.pumpAndSettle();

      // Should show setup instructions, not the Clerk auth panel.
      expect(find.text('Clerk Not Configured'), findsOneWidget);
      expect(find.textContaining('CLERK_PUBLISHABLE_KEY'), findsWidgets);
      expect(find.text('Provider-backed Auth Demo'), findsNothing);
    });

    testWidgets('switching back to Demo mode restores Demo panel', (
      tester,
    ) async {
      await tester.pumpWidget(
        const ConvexFlutterDemoAppForTest(deploymentUrl: ''),
      );

      // Switch to Clerk.
      await tester.tap(find.text('Clerk'));
      await tester.pumpAndSettle();
      expect(find.text('Clerk Not Configured'), findsOneWidget);

      // Switch back to Demo.
      await tester.tap(find.text('Demo Provider'));
      await tester.pumpAndSettle();
      expect(find.text('Provider-backed Auth Demo'), findsOneWidget);
      expect(find.text('Clerk Not Configured'), findsNothing);
    });

    testWidgets('ClerkSetupPanel shows all checklist steps', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const SingleChildScrollView(child: ClerkSetupPanel()),
          ),
        ),
      );

      expect(find.text('Create a Clerk application'), findsOneWidget);
      expect(find.text('Get your publishable key'), findsOneWidget);
      expect(find.text('Configure Convex JWT template'), findsOneWidget);
      expect(find.text('Run with --dart-define'), findsOneWidget);
    });

    testWidgets('Demo mode auth panel still wires all buttons', (tester) async {
      final demoAuthProvider = DemoAuthProvider(
        preferredToken: 'demo-token',
        tokenLabel: 'test token',
      );
      final authClient = _FakeDemoAuthClient(
        const convex.AuthUnauthenticated<DemoUserSession>(),
      );

      var loginCalls = 0;
      var logoutCalls = 0;

      await tester.pumpWidget(
        ConvexProvider(
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
                    authStatus: null,
                    onLogin: () async {
                      loginCalls += 1;
                    },
                    onLoginFromCache: () async {},
                    onLogout: () async {
                      logoutCalls += 1;
                    },
                    onForceReconnect: () async {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Login'));
      await tester.pump();
      expect(loginCalls, 1);

      await tester.tap(find.text('Logout'));
      await tester.pump();
      expect(logoutCalls, 1);
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal test harness that renders the Auth tab with mode switching.
// No ConvexClient is created — the auth panels operate without a backend.
// ---------------------------------------------------------------------------

class ConvexFlutterDemoAppForTest extends StatefulWidget {
  const ConvexFlutterDemoAppForTest({super.key, required this.deploymentUrl});

  final String deploymentUrl;

  @override
  State<ConvexFlutterDemoAppForTest> createState() =>
      _ConvexFlutterDemoAppForTestState();
}

class _ConvexFlutterDemoAppForTestState
    extends State<ConvexFlutterDemoAppForTest> {
  AuthMode _authMode = AuthMode.demo;

  late final DemoAuthProvider _demoAuthProvider = DemoAuthProvider(
    preferredToken: 'test-token',
    tokenLabel: 'test token',
  );

  final _fakeAuthClient = _FakeDemoAuthClient(
    const convex.AuthUnauthenticated<DemoUserSession>(),
  );

  @override
  Widget build(BuildContext context) {
    Widget authPanel;
    if (_authMode == AuthMode.clerk) {
      // Clerk not configured (no publishable key in test).
      authPanel = const ClerkSetupPanel();
    } else {
      authPanel = AuthPanel(
        api: null,
        authClient: _fakeAuthClient,
        demoAuthProvider: _demoAuthProvider,
        authStatus: null,
        onLogin: () async {},
        onLoginFromCache: () async {},
        onLogout: () async {},
        onForceReconnect: () async {},
      );
    }

    return ConvexProvider(
      client: const UnavailableRuntimeClient(),
      child: ConvexAuthProvider<DemoUserSession>(
        client: _fakeAuthClient,
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  _AuthModeSelectorForTest(
                    mode: _authMode,
                    onChanged: (mode) => setState(() => _authMode = mode),
                  ),
                  authPanel,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthModeSelectorForTest extends StatelessWidget {
  const _AuthModeSelectorForTest({required this.mode, required this.onChanged});

  final AuthMode mode;
  final ValueChanged<AuthMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<AuthMode>(
      segments: const <ButtonSegment<AuthMode>>[
        ButtonSegment<AuthMode>(
          value: AuthMode.demo,
          label: Text('Demo Provider'),
          icon: Icon(Icons.science_outlined),
        ),
        ButtonSegment<AuthMode>(
          value: AuthMode.clerk,
          label: Text('Clerk'),
          icon: Icon(Icons.key_off_outlined),
        ),
      ],
      selected: <AuthMode>{mode},
      onSelectionChanged: (selected) => onChanged(selected.first),
    );
  }
}

class _FakeDemoAuthClient implements convex.ConvexAuthClient<DemoUserSession> {
  _FakeDemoAuthClient(this._currentAuthState);

  final StreamController<convex.AuthState<DemoUserSession>>
  _authStateController =
      StreamController<convex.AuthState<DemoUserSession>>.broadcast(sync: true);

  final convex.AuthState<DemoUserSession> _currentAuthState;

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
