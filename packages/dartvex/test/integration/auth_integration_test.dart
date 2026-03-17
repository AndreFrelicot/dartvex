// Integration tests for the typed auth lifecycle against a real Convex
// deployment.
//
// These tests are skipped unless the required environment variables are set:
//
//   CONVEX_DEPLOYMENT_URL  – e.g. https://your-deployment.convex.cloud
//   CONVEX_TEST_AUTH_TOKEN – a valid JWT accepted by the deployment's auth
//                           config (generate with:
//                           cd demo/convex-backend &&
//                           node scripts/generate-demo-jwt.mjs)
//
// The tests exercise ConvexClientWithAuth<T> against the demo backend
// functions demo:whoAmI (authenticated query) and demo:requireAuthEcho
// (throws when unauthenticated).

import 'dart:async';
import 'dart:io';

import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

/// Minimal user info returned by the test auth provider.
class TestUserInfo {
  const TestUserInfo({required this.token});

  final String token;
}

/// Auth provider backed by a static JWT from the environment.
///
/// [login] and [loginFromCache] both return the same token — the distinction
/// is that [loginFromCache] increments a separate counter so tests can assert
/// which path was taken.
class TestAuthProvider implements AuthProvider<TestUserInfo> {
  TestAuthProvider(this._token);

  final String _token;

  int loginCalls = 0;
  int loginFromCacheCalls = 0;
  int logoutCalls = 0;

  @override
  String extractIdToken(TestUserInfo authResult) => authResult.token;

  @override
  Future<TestUserInfo> login({
    required void Function(String? token) onIdToken,
  }) async {
    loginCalls += 1;
    final info = TestUserInfo(token: _token);
    onIdToken(_token);
    return info;
  }

  @override
  Future<TestUserInfo> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    loginFromCacheCalls += 1;
    final info = TestUserInfo(token: _token);
    onIdToken(_token);
    return info;
  }

  @override
  Future<void> logout() async {
    logoutCalls += 1;
  }
}

void main() {
  final deploymentUrl = Platform.environment['CONVEX_DEPLOYMENT_URL'];
  final authToken = Platform.environment['CONVEX_TEST_AUTH_TOKEN'];

  final skip = deploymentUrl == null || authToken == null
      ? 'Set CONVEX_DEPLOYMENT_URL and CONVEX_TEST_AUTH_TOKEN to run auth '
          'integration tests. Generate a token with:\n'
          '  cd demo/convex-backend && node scripts/generate-demo-jwt.mjs'
      : false;

  group('Auth integration', skip: skip, () {
    late ConvexClient baseClient;
    late ConvexClientWithAuth<TestUserInfo> authClient;
    late TestAuthProvider provider;

    setUp(() {
      provider = TestAuthProvider(authToken!);
      baseClient = ConvexClient(deploymentUrl!);
      authClient = baseClient.withAuth<TestUserInfo>(provider);
    });

    tearDown(() {
      authClient.dispose();
    });

    Future<void> waitForConnection() async {
      if (baseClient.currentConnectionState == ConnectionState.connected) {
        return;
      }
      await baseClient.connectionState.firstWhere(
        (state) => state == ConnectionState.connected,
      );
    }

    test('login enables authenticated query access', () async {
      await waitForConnection();

      final session = await authClient.login();
      expect(session.token, authToken);
      expect(provider.loginCalls, 1);
      expect(
        authClient.currentAuthState,
        isA<AuthAuthenticated<TestUserInfo>>(),
      );

      // Wait for auth to be confirmed by the server.
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // demo:whoAmI returns the authenticated user's identity.
      final identity = await authClient.query('demo:whoAmI');
      expect(identity, isNotNull);
      expect(identity, isA<Map<String, dynamic>>());

      final identityMap = identity as Map<String, dynamic>;
      expect(identityMap['tokenIdentifier'], isNotNull);
    });

    test('loginFromCache restores session without interactive login', () async {
      await waitForConnection();

      // First establish a session via login.
      await authClient.login();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Dispose and create a fresh client + provider to simulate app restart.
      authClient.dispose();

      final freshProvider = TestAuthProvider(authToken!);
      // Pre-seed the "cache" by calling login once (simulates a prior session).
      await freshProvider.login(onIdToken: (_) {});
      freshProvider.loginCalls = 0; // Reset so we can track loginFromCache.

      final freshBase = ConvexClient(deploymentUrl!);
      final freshAuth = freshBase.withAuth<TestUserInfo>(freshProvider);

      addTearDown(freshAuth.dispose);

      await freshBase.connectionState.firstWhere(
        (state) => state == ConnectionState.connected,
      );

      final session = await freshAuth.loginFromCache();
      expect(freshProvider.loginCalls, 0);
      expect(freshProvider.loginFromCacheCalls, 1);
      expect(session.token, authToken);

      await Future<void>.delayed(const Duration(milliseconds: 500));

      final identity = await freshAuth.query('demo:whoAmI');
      expect(identity, isNotNull);
    });

    test('logout clears authenticated access', () async {
      await waitForConnection();

      await authClient.login();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Confirm authenticated access works.
      final identityBefore = await authClient.query('demo:whoAmI');
      expect(identityBefore, isNotNull);

      // Logout.
      await authClient.logout();
      expect(provider.logoutCalls, 1);
      expect(
        authClient.currentAuthState,
        isA<AuthUnauthenticated<TestUserInfo>>(),
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));

      // After logout, whoAmI should return null (unauthenticated).
      final identityAfter = await authClient.query('demo:whoAmI');
      expect(identityAfter, isNull);
    });

    test('auth state stream emits correct lifecycle transitions', () async {
      await waitForConnection();

      final states = <AuthState<TestUserInfo>>[];
      final subscription = authClient.authState.listen(states.add);
      addTearDown(subscription.cancel);

      // Login.
      await authClient.login();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // Logout.
      await authClient.logout();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(states.length, greaterThanOrEqualTo(3));
      expect(states[0], isA<AuthLoading<TestUserInfo>>());
      expect(states[1], isA<AuthAuthenticated<TestUserInfo>>());
      expect(states[2], isA<AuthUnauthenticated<TestUserInfo>>());
    });

    test('requireAuthEcho succeeds when authenticated, fails otherwise',
        () async {
      await waitForConnection();

      await authClient.login();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      // Authenticated call should succeed.
      final result = await authClient.query(
        'demo:requireAuthEcho',
        <String, dynamic>{'message': 'hello from integration test'},
      );
      expect(result, isNotNull);
      final resultMap = result as Map<String, dynamic>;
      expect(resultMap['echo'], 'hello from integration test');

      // Logout and try again — should fail.
      await authClient.logout();
      await Future<void>.delayed(const Duration(milliseconds: 500));

      await expectLater(
        authClient.query(
          'demo:requireAuthEcho',
          <String, dynamic>{'message': 'should fail'},
        ),
        throwsA(isA<ConvexException>()),
      );
    });
  });
}
