import 'dart:async';

import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

void main() {
  group('ConvexClientWithAuth', () {
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    test('auth state transitions from loading to authenticated', () async {
      final adapter = MockWebSocketAdapter();
      final provider = FakeAuthProvider(
        loginSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'login-token',
        ),
        cachedSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'cached-token',
        ),
      );
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final authClient = client.withAuth<FakeAuthSession>(provider);
      final states = <AuthState<FakeAuthSession>>[];
      final subscription = authClient.authState.listen(states.add);

      final session = await authClient.login();
      await settle();

      final authMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Authenticate')
          .toList(growable: false);
      final lastAuthMessage = authMessages.last;

      expect(session.userInfo, 'alice');
      expect(states.first, isA<AuthLoading<FakeAuthSession>>());
      expect(states.last, isA<AuthAuthenticated<FakeAuthSession>>());
      expect(authClient.currentAuthState,
          isA<AuthAuthenticated<FakeAuthSession>>());
      expect(lastAuthMessage['value'], 'login-token');

      await subscription.cancel();
      authClient.dispose();
    });

    test('failed login returns to unauthenticated', () async {
      final adapter = MockWebSocketAdapter();
      final provider = FakeAuthProvider(
        loginSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'login-token',
        ),
        cachedSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'cached-token',
        ),
        throwOnLogin: true,
      );
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final authClient = client.withAuth<FakeAuthSession>(provider);
      final states = <AuthState<FakeAuthSession>>[];
      final subscription = authClient.authState.listen(states.add);

      await expectLater(authClient.login(), throwsStateError);
      await settle();

      expect(states.first, isA<AuthLoading<FakeAuthSession>>());
      expect(states.last, isA<AuthUnauthenticated<FakeAuthSession>>());
      expect(
        authClient.currentAuthState,
        isA<AuthUnauthenticated<FakeAuthSession>>(),
      );

      await subscription.cancel();
      authClient.dispose();
    });

    test('loginFromCache restores token without UI', () async {
      final adapter = MockWebSocketAdapter();
      final provider = FakeAuthProvider(
        loginSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'login-token',
        ),
        cachedSession: const FakeAuthSession(
          userInfo: 'cached-alice',
          token: 'cached-token',
        ),
      );
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final authClient = client.withAuth<FakeAuthSession>(provider);

      final session = await authClient.loginFromCache();
      await settle();

      final lastAuthMessage = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Authenticate')
          .last;

      expect(provider.loginCalls, 0);
      expect(provider.loginFromCacheCalls, 1);
      expect(session.userInfo, 'cached-alice');
      expect(lastAuthMessage['value'], 'cached-token');

      authClient.dispose();
    });

    test('logout clears auth state and sends none auth', () async {
      final adapter = MockWebSocketAdapter();
      final provider = FakeAuthProvider(
        loginSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'login-token',
        ),
        cachedSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'cached-token',
        ),
      );
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final authClient = client.withAuth<FakeAuthSession>(provider);

      await authClient.login();
      await settle();
      await authClient.logout();
      await settle();

      final lastAuthMessage = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Authenticate')
          .last;

      expect(provider.logoutCalls, 1);
      expect(lastAuthMessage['tokenType'], 'None');
      expect(
        authClient.currentAuthState,
        isA<AuthUnauthenticated<FakeAuthSession>>(),
      );

      authClient.dispose();
    });

    test('reconnect with provider auth forces one cached refresh', () async {
      final adapter = MockWebSocketAdapter();
      final provider = FakeAuthProvider(
        loginSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'login-token',
        ),
        cachedSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'refresh-token',
        ),
      );
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final authClient = client.withAuth<FakeAuthSession>(provider);

      await authClient.login();
      await settle();
      provider.resetCacheCounters();
      final sentMessageCountBeforeDisconnect =
          adapter.decodedSentMessages.length;

      adapter.disconnect();
      await settle();

      final authMessages = adapter.decodedSentMessages
          .skip(sentMessageCountBeforeDisconnect)
          .where((message) => message['type'] == 'Authenticate')
          .toList(growable: false);

      expect(provider.loginFromCacheCalls, 1);
      expect(authMessages, hasLength(1));
      expect(authMessages.last['value'], 'refresh-token');

      authClient.dispose();
    });

    test('reconnect failure moves wrapper back to unauthenticated', () async {
      final adapter = MockWebSocketAdapter();
      final provider = FakeAuthProvider(
        loginSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'login-token',
        ),
        cachedSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'refresh-token',
        ),
      );
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final authClient = client.withAuth<FakeAuthSession>(provider);
      final states = <AuthState<FakeAuthSession>>[];
      final subscription = authClient.authState.listen(states.add);

      await authClient.login();
      await settle();
      provider
        ..throwOnLoginFromCache = true
        ..resetCacheCounters();

      adapter.disconnect();
      await settle();

      expect(provider.loginFromCacheCalls, 1);
      expect(states.last, isA<AuthUnauthenticated<FakeAuthSession>>());
      expect(
        authClient.currentAuthState,
        isA<AuthUnauthenticated<FakeAuthSession>>(),
      );

      await subscription.cancel();
      authClient.dispose();
    });
  });
}

class FakeAuthSession {
  const FakeAuthSession({
    required this.userInfo,
    required this.token,
  });

  final String userInfo;
  final String token;
}

class FakeAuthProvider implements AuthProvider<FakeAuthSession> {
  FakeAuthProvider({
    required this.loginSession,
    required this.cachedSession,
    this.throwOnLogin = false,
    this.throwOnLoginFromCache = false,
  });

  final FakeAuthSession loginSession;
  final FakeAuthSession cachedSession;
  bool throwOnLogin;
  bool throwOnLoginFromCache;

  int loginCalls = 0;
  int loginFromCacheCalls = 0;
  int logoutCalls = 0;

  @override
  String extractIdToken(FakeAuthSession authResult) => authResult.token;

  @override
  Future<FakeAuthSession> login({
    required void Function(String? token) onIdToken,
  }) async {
    loginCalls += 1;
    if (throwOnLogin) {
      throw StateError('login failed');
    }
    onIdToken(loginSession.token);
    return loginSession;
  }

  @override
  Future<FakeAuthSession> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    loginFromCacheCalls += 1;
    if (throwOnLoginFromCache) {
      throw StateError('cached login failed');
    }
    onIdToken(cachedSession.token);
    return cachedSession;
  }

  @override
  Future<void> logout() async {
    logoutCalls += 1;
  }

  void resetCacheCounters() {
    loginFromCacheCalls = 0;
  }
}
