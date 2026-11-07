import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

/// Regression tests from the 0.3.0 post-release review of the transport and
/// auth layers: a slow reauth stop overlapping a restart, the detached
/// AuthError handling, the reauth fetch after logout, and live-session token
/// pushes during a pending re-login.
void main() {
  group('reauth socket stop', () {
    test(
        'connection state stays connected when a superseding auth call '
        'restarts the socket while the reauth stop() is still closing',
        () async {
      final adapter = _SlowCloseAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      addTearDown(() async {
        adapter.closeGate?.complete();
        await client.close();
      });

      await client.setAuthWithRefresh(
        fetchToken: ({required bool forceRefresh}) async =>
            forceRefresh ? 'fresh' : 'cached',
      );
      await _until(() => adapter.isConnected, reason: 'initial connect');
      await _until(
        () => client.currentConnectionState == ConnectionState.connected,
      );

      // The server rejects the token; the reauth stops the socket, whose
      // close handshake is slow.
      adapter.closeGate = Completer<void>();
      adapter.push(<String, dynamic>{
        'type': 'AuthError',
        'error': 'Token expired',
        'baseVersion': 0,
        'authUpdateAttempted': true,
      });
      await _until(() => !adapter.isConnected, reason: 'reauth stop');

      // The provider pushes a rotated token meanwhile: updateToken supersedes
      // the reauth and restarts the socket right away.
      await client.updateAuthToken('pushed');
      await _until(
        () => adapter.isConnected && adapter.connects == 2,
        reason: 'restart',
      );
      await _until(
        () => client.currentConnectionState == ConnectionState.connected,
        reason: 'connected after restart',
      );

      // The old socket's close handshake finally completes.
      final gate = adapter.closeGate!;
      adapter.closeGate = null;
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(adapter.isConnected, isTrue);
      expect(client.currentConnectionState, ConnectionState.connected);
    });
  });

  group('detached AuthError handling', () {
    test('an AuthError handled right after close() raises no uncaught error',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await client.setAuth('fixed-token');
      await _until(() => adapter.isConnected);

      final uncaught = <Object>[];
      await runZonedGuarded(() async {
        // The server rejects the fixed token; the app closes the client in
        // the same tick (e.g. a screen being torn down).
        adapter.pushServerMessage(<String, dynamic>{
          'type': 'AuthError',
          'error': 'Token expired',
          'baseVersion': 0,
          'authUpdateAttempted': true,
        });
        await client.close();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }, (error, stack) => uncaught.add(error));

      expect(uncaught, isEmpty);
    });
  });

  group('reauth superseded by logout', () {
    test('logout during a reauth stop does not call the provider refresh hook',
        () async {
      final adapter = _SlowCloseConfirmingAdapter();
      final provider = _ScriptedProvider();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      final auth = client.withAuth<_Session>(provider);
      addTearDown(() async {
        adapter.closeGate?.complete();
        auth.dispose();
        await client.close();
      });

      await auth.login();
      await _until(() => client.isAuthenticated, reason: 'confirmed');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      adapter.closeGate = Completer<void>();
      adapter.pushServerMessage(<String, dynamic>{
        'type': 'AuthError',
        'error': 'Token expired',
        'baseVersion': adapter.confirmedIdentity - 1,
        'authUpdateAttempted': true,
      });
      await _until(() => client.isAuthRefreshing, reason: 'reauth started');

      final callsBeforeLogout = provider.cacheCalls;
      final logout = auth.logout();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final gate = adapter.closeGate!;
      adapter.closeGate = null;
      gate.complete();
      await logout;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(auth.currentAuthState, isA<AuthUnauthenticated<_Session>>());
      expect(provider.cacheCalls, callsBeforeLogout,
          reason: 'loginFromCache was invoked after logout() superseded the '
              'reauth');
    });
  });

  group('live-session token pushes during a failing re-login', () {
    late _ConfirmingAdapter adapter;
    late _ScriptedProvider provider;
    late ConvexClient client;
    late ConvexClientWithAuth<_Session> auth;

    setUp(() async {
      adapter = _ConfirmingAdapter();
      provider = _ScriptedProvider();
      client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      auth = client.withAuth<_Session>(provider);
      addTearDown(() async {
        auth.dispose();
        await client.close();
      });
      await auth.login();
      await _until(() => auth.currentAuthState is AuthAuthenticated<_Session>);
    });

    /// Starts a re-login (e.g. an account-switch dialog) that fails once
    /// [gate] is released, then lets the live session's provider push [token]
    /// while it is pending.
    Future<void> failReloginAfterLivePush(String? token) async {
      final gate = Completer<void>();
      provider.loginGate = gate;
      provider.loginError = StateError('user cancelled');
      final relogin = auth.login();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      provider.loginCallbacks.first(token);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      gate.complete();
      await expectLater(relogin, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    test('a null push signs out instead of restoring the dead session',
        () async {
      await failReloginAfterLivePush(null);

      expect(auth.currentAuthState, isA<AuthUnauthenticated<_Session>>());
      expect(client.currentAuthToken, isNull);
    });

    test('a rotated token is applied to the session that is kept', () async {
      await failReloginAfterLivePush('rotated-token');

      expect(auth.currentAuthState, isA<AuthAuthenticated<_Session>>());
      expect(client.currentAuthToken, 'rotated-token');
    });
  });

  group('identity races between flows', () {
    late _ConfirmingAdapter adapter;
    late _IdentityProvider provider;
    late ConvexClient client;
    late ConvexClientWithAuth<_Session> auth;

    setUp(() async {
      adapter = _ConfirmingAdapter();
      provider = _IdentityProvider();
      client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      auth = client.withAuth<_Session>(provider);
      addTearDown(() async {
        auth.dispose();
        await client.close();
      });
      await auth.login();
      await _until(() => auth.currentAuthState is AuthAuthenticated<_Session>);
      expect(client.currentAuthToken, 'alice-token-1');
    });

    test('a login started while logout() is pending keeps its own session',
        () async {
      provider.nextUser = 'bob';
      final logout = auth.logout();
      final login = auth.login();
      await logout;
      await login;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(provider.revoked, <String>['alice'],
          reason: 'logout() revoked the session of the login that followed');
      final state = auth.currentAuthState;
      expect(state, isA<AuthAuthenticated<_Session>>());
      expect((state as AuthAuthenticated<_Session>).userInfo.user, 'bob');
      expect(client.currentAuthToken, 'bob-token-2');
    });

    test(
        'a token pushed by a pending login is not applied to the live '
        'session, which is restored intact when that login fails', () async {
      provider
        ..nextUser = 'bob'
        ..pushDuringLogin = true
        ..loginGate = Completer<void>()
        ..loginError = StateError('user cancelled');
      final gate = provider.loginGate!;
      final relogin = auth.login();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(client.currentAuthToken, 'alice-token-1',
          reason: "bob's token was sent while alice's session was installed");

      gate.complete();
      await expectLater(relogin, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      final state = auth.currentAuthState;
      expect(state, isA<AuthAuthenticated<_Session>>());
      expect((state as AuthAuthenticated<_Session>).userInfo.user, 'alice');
      expect(client.currentAuthToken, 'alice-token-1');
    });

    test(
        'a restore that reports the session as ended signs out instead of '
        'keeping the previous session', () async {
      provider.cacheError = _SessionEnded('session expired');

      await expectLater(
        auth.loginFromCache(),
        throwsA(isA<AuthSessionEndedError>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(auth.currentAuthState, isA<AuthUnauthenticated<_Session>>());
      expect(client.currentAuthToken, isNull);
    });

    test('a restore failing with a transient error keeps the session',
        () async {
      provider.cacheError = StateError('offline');

      await expectLater(auth.loginFromCache(), throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(auth.currentAuthState, isA<AuthAuthenticated<_Session>>());
      expect(client.currentAuthToken, 'alice-token-1');
    });
  });
}

Future<void> _until(bool Function() condition, {String? reason}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > const Duration(seconds: 3)) {
      fail('Timed out waiting for ${reason ?? 'condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// Adapter whose close() detaches the socket right away (like the native
/// adapter, which nulls `_socket` before awaiting `socket.close()`), but only
/// completes once [closeGate] is released — a close handshake on a slow link.
class _SlowCloseAdapter implements WebSocketAdapter {
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closes =
      StreamController<WebSocketCloseEvent>.broadcast();
  bool _connected = false;
  Completer<void>? closeGate;
  int connects = 0;

  @override
  Future<void> connect(String url) async {
    connects += 1;
    _connected = true;
  }

  @override
  void send(String message) {
    if (!_connected) {
      throw StateError('closed');
    }
  }

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<WebSocketCloseEvent> get closeEvents => _closes.stream;

  void push(Map<String, dynamic> message) => _messages.add(jsonEncode(message));

  @override
  Future<void> close() async {
    if (!_connected) {
      return;
    }
    _connected = false;
    final gate = closeGate;
    if (gate != null) {
      await gate.future;
    }
    _closes.add(const WebSocketCloseEvent(code: 1000));
  }

  @override
  bool get isConnected => _connected;
}

class _Session {
  const _Session({required this.user, required this.token});

  final String user;
  final String token;
}

class _ScriptedProvider implements AuthProvider<_Session> {
  /// `onIdToken` callbacks passed to [login] (the wrapper's flow callbacks).
  final List<void Function(String? token)> loginCallbacks =
      <void Function(String? token)>[];
  int _logins = 0;
  int cacheCalls = 0;
  _Session? _session;
  Completer<void>? loginGate;
  Object? loginError;

  @override
  String extractIdToken(_Session authResult) => authResult.token;

  @override
  Future<_Session> login({
    required void Function(String? token) onIdToken,
  }) async {
    loginCallbacks.add(onIdToken);
    final gate = loginGate;
    loginGate = null;
    if (gate != null) {
      await gate.future;
    }
    final error = loginError;
    if (error != null) {
      loginError = null;
      throw error;
    }
    _logins += 1;
    final session = _Session(user: 'alice', token: 'login-token-$_logins');
    _session = session;
    return session;
  }

  @override
  Future<_Session> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    cacheCalls += 1;
    final session = _session;
    if (session == null) {
      throw StateError('no session');
    }
    return session;
  }

  @override
  Future<void> logout() async {
    _session = null;
  }
}

/// Confirms every `Authenticate` with an identity-advancing Transition, as
/// the server does.
class _ConfirmingAdapter extends MockWebSocketAdapter {
  int _serverTs = 0;
  int confirmedIdentity = 0;

  @override
  void send(String message) {
    super.send(message);
    final decoded = jsonDecode(message) as Map<String, dynamic>;
    if (decoded['type'] == 'Connect') {
      // A new socket starts a fresh server session at the initial version.
      _serverTs = 0;
      return;
    }
    if (decoded['type'] != 'Authenticate') {
      return;
    }
    final baseVersion = decoded['baseVersion'] as int;
    final startTs = _serverTs;
    _serverTs += 1;
    confirmedIdentity = baseVersion + 1;
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

/// A [_ConfirmingAdapter] whose close() only completes once [closeGate] is
/// released.
class _SlowCloseConfirmingAdapter extends _ConfirmingAdapter {
  Completer<void>? closeGate;

  @override
  Future<void> close() async {
    final gate = closeGate;
    await super.close();
    if (gate != null) {
      await gate.future;
    }
  }
}

final class _SessionEnded extends StateError implements AuthSessionEndedError {
  _SessionEnded(super.message);
}

/// Provider whose sessions belong to [nextUser]. Like Better Auth, it adopts
/// the new session as soon as login() is called and reads the session to
/// revoke when logout() is called.
class _IdentityProvider implements AuthProvider<_Session> {
  String nextUser = 'alice';
  _Session? session;
  final List<String> revoked = <String>[];
  int _logins = 0;
  bool pushDuringLogin = false;
  Completer<void>? loginGate;
  Object? loginError;
  Object? cacheError;

  @override
  String extractIdToken(_Session authResult) => authResult.token;

  @override
  Future<_Session> login({
    required void Function(String? token) onIdToken,
  }) async {
    _logins += 1;
    final next = _Session(user: nextUser, token: '$nextUser-token-$_logins');
    session = next;
    if (pushDuringLogin) {
      onIdToken(next.token);
    }
    final gate = loginGate;
    loginGate = null;
    if (gate != null) {
      await gate.future;
    }
    final error = loginError;
    if (error != null) {
      loginError = null;
      throw error;
    }
    return next;
  }

  @override
  Future<_Session> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    final error = cacheError;
    if (error != null) {
      cacheError = null;
      throw error;
    }
    final current = session;
    if (current == null) {
      throw _SessionEnded('no session');
    }
    return current;
  }

  @override
  Future<void> logout() async {
    final current = session;
    session = null;
    if (current != null) {
      await Future<void>.delayed(Duration.zero);
      revoked.add(current.user);
    }
  }
}
