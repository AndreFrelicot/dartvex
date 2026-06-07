import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

void main() {
  group('ConvexClientWithAuth', () {
    Future<void> waitUntil(
      bool Function() condition, {
      required String reason,
      Duration timeout = const Duration(seconds: 2),
    }) async {
      final stopwatch = Stopwatch()..start();
      while (!condition()) {
        if (stopwatch.elapsed >= timeout) {
          fail('Timed out waiting for $reason');
        }
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    Iterable<Map<String, dynamic>> authMessages(
      MockWebSocketAdapter adapter, {
      int skip = 0,
    }) {
      return adapter.decodedSentMessages
          .skip(skip)
          .where((message) => message['type'] == 'Authenticate');
    }

    Future<Map<String, dynamic>> waitForAuthMessage(
      MockWebSocketAdapter adapter, {
      int skip = 0,
      bool Function(Map<String, dynamic> message)? where,
      String reason = 'auth message',
    }) async {
      bool matches(Map<String, dynamic> message) {
        return where == null || where(message);
      }

      await waitUntil(
        () => authMessages(adapter, skip: skip).any(matches),
        reason: reason,
      );
      return authMessages(adapter, skip: skip).firstWhere(matches);
    }

    void confirmAuth(MockWebSocketAdapter adapter) {
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 1, ts: encodeTs(1)),
          modifications: const <StateModification>[],
        ).toJson(),
      );
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
      final lastAuthMessage = await waitForAuthMessage(adapter);

      expect(session.userInfo, 'alice');
      expect(states.first, isA<AuthLoading<FakeAuthSession>>());
      expect(states.last, isA<AuthLoading<FakeAuthSession>>());
      expect(authClient.currentAuthState, isA<AuthLoading<FakeAuthSession>>());
      confirmAuth(adapter);
      await waitUntil(
        () => states.lastOrNull is AuthAuthenticated<FakeAuthSession>,
        reason: 'authenticated state',
      );
      expect(states.last, isA<AuthAuthenticated<FakeAuthSession>>());
      expect(authClient.currentAuthState,
          isA<AuthAuthenticated<FakeAuthSession>>());
      expect(lastAuthMessage['value'], 'login-token');

      await subscription.cancel();
      authClient.dispose();
    });

    test('fast auth confirmation during login still publishes authenticated',
        () async {
      final adapter = _ImmediateAuthConfirmingAdapter();
      final provider = FakeAuthProvider(
        loginSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'login-token',
        ),
        cachedSession: const FakeAuthSession(
          userInfo: 'alice',
          token: 'login-token',
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
      await waitUntil(
        () => authClient.currentAuthState is AuthAuthenticated<FakeAuthSession>,
        reason: 'authenticated state after immediate confirmation',
      );

      expect(session.userInfo, 'alice');
      expect(states.first, isA<AuthLoading<FakeAuthSession>>());
      expect(states.last, isA<AuthAuthenticated<FakeAuthSession>>());
      expect(adapter.confirmedAuthMessages, 1);

      await subscription.cancel();
      authClient.dispose();
    });

    test('superseded login cannot overwrite a newer auth flow', () async {
      final adapter = _ImmediateAuthConfirmingAdapter();
      final provider = _ControllableAuthProvider();
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

      final firstLogin = authClient.login();
      await waitUntil(
        () => provider.loginCalls == 1,
        reason: 'first login callback capture',
      );
      final firstCallback = provider.loginCallbacks.single;

      final secondLogin = authClient.login();
      await waitUntil(
        () => provider.loginCalls == 2,
        reason: 'second login callback capture',
      );

      provider.completeLogin(
        1,
        const FakeAuthSession(userInfo: 'new-user', token: 'new-token'),
      );
      await secondLogin;
      await waitForAuthMessage(
        adapter,
        where: (message) => message['value'] == 'new-token',
        reason: 'new auth token',
      );
      await waitUntil(
        () => authClient.currentAuthState is AuthAuthenticated<FakeAuthSession>,
        reason: 'new login authenticated',
      );

      firstCallback('old-token');
      provider.completeLogin(
        0,
        const FakeAuthSession(userInfo: 'old-user', token: 'old-token'),
      );
      await firstLogin;
      await pumpEventQueue();

      expect(
        authMessages(adapter)
            .where((message) => message['value'] == 'old-token'),
        isEmpty,
      );
      final authenticated =
          authClient.currentAuthState as AuthAuthenticated<FakeAuthSession>;
      expect(authenticated.userInfo.userInfo, 'new-user');

      await subscription.cancel();
      authClient.dispose();
    });

    test('stale token clear cannot cancel a newer login', () async {
      final adapter = _ImmediateAuthConfirmingAdapter();
      final provider = _ControllableAuthProvider();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final authClient = client.withAuth<FakeAuthSession>(provider);
      final subscription = authClient.authState.listen((_) {});

      final firstLogin = authClient.login();
      await waitUntil(
        () => provider.loginCalls == 1,
        reason: 'first login callback capture',
      );
      final firstCallback = provider.loginCallbacks.single;
      provider.completeLogin(
        0,
        const FakeAuthSession(userInfo: 'old-user', token: 'old-token'),
      );
      await firstLogin;
      await waitUntil(
        () => authClient.currentAuthState is AuthAuthenticated<FakeAuthSession>,
        reason: 'first login authenticated',
      );

      final messagesBeforeClear = adapter.decodedSentMessages.length;
      firstCallback(null);
      final secondLogin = authClient.login();
      await waitUntil(
        () => provider.loginCalls == 2,
        reason: 'second login callback capture',
      );
      provider.completeLogin(
        1,
        const FakeAuthSession(userInfo: 'new-user', token: 'new-token'),
      );
      await secondLogin;
      await waitForAuthMessage(
        adapter,
        skip: messagesBeforeClear,
        where: (message) => message['value'] == 'new-token',
        reason: 'new auth token after stale clear',
      );
      await waitUntil(
        () => authClient.currentAuthState is AuthAuthenticated<FakeAuthSession>,
        reason: 'second login authenticated after stale clear',
      );

      final staleClearMessages =
          authMessages(adapter, skip: messagesBeforeClear)
              .where((message) => message['tokenType'] == 'None');
      expect(staleClearMessages, isEmpty);
      final authenticated =
          authClient.currentAuthState as AuthAuthenticated<FakeAuthSession>;
      expect(authenticated.userInfo.userInfo, 'new-user');

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
      await waitUntil(
        () => states.lastOrNull is AuthUnauthenticated<FakeAuthSession>,
        reason: 'unauthenticated state after failed login',
      );

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
      final lastAuthMessage = await waitForAuthMessage(adapter);

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
      await waitForAuthMessage(
        adapter,
        where: (message) => message['value'] == 'login-token',
        reason: 'initial auth message',
      );
      await authClient.logout();
      final lastAuthMessage = await waitForAuthMessage(
        adapter,
        where: (message) => message['tokenType'] == 'None',
        reason: 'logout auth reset',
      );

      expect(provider.logoutCalls, 1);
      expect(lastAuthMessage['tokenType'], 'None');
      expect(
        authClient.currentAuthState,
        isA<AuthUnauthenticated<FakeAuthSession>>(),
      );

      authClient.dispose();
    });

    test('logout clears local auth even when the provider logout fails',
        () async {
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
      await waitForAuthMessage(
        adapter,
        where: (message) => message['value'] == 'login-token',
        reason: 'initial auth message',
      );
      provider.throwOnLogout = true;

      await expectLater(authClient.logout(), throwsStateError);
      final resetMessage = await waitForAuthMessage(
        adapter,
        where: (message) => message['tokenType'] == 'None',
        reason: 'logout auth reset after provider failure',
      );

      expect(provider.logoutCalls, 1);
      expect(resetMessage['tokenType'], 'None');
      expect(
        authClient.currentAuthState,
        isA<AuthUnauthenticated<FakeAuthSession>>(),
      );

      authClient.dispose();
    });

    test('reconnect replays the cached token without calling the provider',
        () async {
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
      await waitForAuthMessage(
        adapter,
        where: (message) => message['value'] == 'login-token',
        reason: 'initial auth message',
      );
      provider.resetCacheCounters();
      final sentMessageCountBeforeDisconnect =
          adapter.decodedSentMessages.length;

      adapter.disconnect();
      // The official client never re-fetches auth on reconnect; it replays the
      // cached token from local state. So the provider is not called and the
      // original token is re-sent verbatim.
      final replayedAuthMessage = await waitForAuthMessage(
        adapter,
        skip: sentMessageCountBeforeDisconnect,
        where: (message) => message['value'] == 'login-token',
        reason: 'replayed auth message',
      );
      final authMessagesAfterDisconnect =
          authMessages(adapter, skip: sentMessageCountBeforeDisconnect)
              .toList(growable: false);

      expect(provider.loginFromCacheCalls, 0);
      expect(authMessagesAfterDisconnect, hasLength(1));
      expect(replayedAuthMessage['value'], 'login-token');

      authClient.dispose();
    });

    test('reconnect stays authenticated even if the provider would fail',
        () async {
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
      await waitForAuthMessage(
        adapter,
        where: (message) => message['value'] == 'login-token',
        reason: 'initial auth message',
      );
      // Confirm the cached token: the wrapper becomes authenticated and the
      // post-confirmation refetch settles the active token to the refresh token.
      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 0, identity: 1, ts: encodeTs(1)),
          modifications: const <StateModification>[],
        ).toJson(),
      );
      await waitForAuthMessage(
        adapter,
        where: (message) => message['value'] == 'refresh-token',
        reason: 'settled token after confirmation',
      );
      await waitUntil(
        () => authClient.currentAuthState is AuthAuthenticated<FakeAuthSession>,
        reason: 'authenticated after confirmation',
      );
      provider
        ..throwOnLoginFromCache = true
        ..resetCacheCounters();
      final sentMessageCountBeforeDisconnect =
          adapter.decodedSentMessages.length;
      states.clear();

      adapter.disconnect();
      // A reconnect replays the active token from local state without touching
      // the provider, so a provider that would throw on refresh cannot silently
      // log the user out.
      final replayedAuthMessage = await waitForAuthMessage(
        adapter,
        skip: sentMessageCountBeforeDisconnect,
        where: (message) => message['value'] == 'refresh-token',
        reason: 'replayed auth message',
      );

      expect(provider.loginFromCacheCalls, 0);
      expect(replayedAuthMessage['value'], 'refresh-token');
      expect(
        states.whereType<AuthUnauthenticated<FakeAuthSession>>(),
        isEmpty,
        reason: 'reconnect must not move the wrapper to unauthenticated',
      );
      expect(
        authClient.currentAuthState,
        isA<AuthAuthenticated<FakeAuthSession>>(),
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
    this.throwOnLogout = false,
  });

  final FakeAuthSession loginSession;
  final FakeAuthSession cachedSession;
  bool throwOnLogin;
  bool throwOnLoginFromCache;
  bool throwOnLogout;

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
    if (throwOnLogout) {
      throw StateError('logout failed');
    }
  }

  void resetCacheCounters() {
    loginFromCacheCalls = 0;
  }
}

class _ControllableAuthProvider implements AuthProvider<FakeAuthSession> {
  final List<void Function(String? token)> loginCallbacks =
      <void Function(String? token)>[];
  final List<Completer<FakeAuthSession>> _loginCompleters =
      <Completer<FakeAuthSession>>[];
  FakeAuthSession? _cachedSession;

  int loginCalls = 0;

  @override
  String extractIdToken(FakeAuthSession authResult) => authResult.token;

  @override
  Future<FakeAuthSession> login({
    required void Function(String? token) onIdToken,
  }) {
    loginCalls += 1;
    loginCallbacks.add(onIdToken);
    final completer = Completer<FakeAuthSession>();
    _loginCompleters.add(completer);
    return completer.future;
  }

  void completeLogin(int index, FakeAuthSession session) {
    _cachedSession = session;
    loginCallbacks[index](session.token);
    _loginCompleters[index].complete(session);
  }

  @override
  Future<FakeAuthSession> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    final session = _cachedSession;
    if (session == null) {
      throw StateError('cache is empty');
    }
    onIdToken(session.token);
    return session;
  }

  @override
  Future<void> logout() async {}
}

class _ImmediateAuthConfirmingAdapter extends MockWebSocketAdapter {
  int confirmedAuthMessages = 0;
  int _serverTs = 0;

  @override
  void send(String message) {
    super.send(message);
    final decoded = jsonDecode(message) as Map<String, dynamic>;
    if (decoded['type'] != 'Authenticate' || decoded['tokenType'] == 'None') {
      return;
    }
    confirmedAuthMessages += 1;
    final baseVersion = decoded['baseVersion'] as int;
    final startTs = _serverTs;
    _serverTs += 1;
    pushServerMessage(
      Transition(
        startVersion: StateVersion(
          querySet: 0,
          identity: baseVersion,
          ts: encodeTs(startTs),
        ),
        endVersion: StateVersion(
          querySet: 0,
          identity: baseVersion + 1,
          ts: encodeTs(_serverTs),
        ),
        modifications: const <StateModification>[],
      ).toJson(),
    );
  }
}
