import 'package:dartvex/dartvex.dart';
import 'package:dartvex_auth_convex/dartvex_auth_convex.dart';
import 'package:test/test.dart';

import 'support.dart';

/// Drives [ConvexAuthSessionProvider] through `ConvexClient.withAuth` with a
/// fake WebSocket and a mocked Convex HTTP API.
void main() {
  late FakeWebSocketAdapter adapter;
  late FakeConvexAuthServer server;
  late ConvexAuthHttpClient httpClient;
  late List<ConvexAuthSession?> persisted;
  late ConvexAuthSessionProvider provider;
  late ConvexClientWithAuth<ConvexAuthSession> authed;
  var refreshCount = 0;

  void build({ConvexAuthSession? initialSession}) {
    provider = ConvexAuthSessionProvider(
      client: httpClient,
      initialSession: initialSession,
      onSessionChanged: persisted.add,
    );
    final convex = ConvexClient(
      deploymentUrl,
      config: ConvexClientConfig(
        adapterFactory: (_) => adapter,
        reconnectBackoff: const <Duration>[Duration.zero],
      ),
    );
    authed = convex.withAuth<ConvexAuthSession>(provider, disposeClient: true);
  }

  setUp(() {
    adapter = FakeWebSocketAdapter();
    server = FakeConvexAuthServer();
    httpClient = ConvexAuthHttpClient(
      deploymentUrl: deploymentUrl,
      httpClient: server.httpClient,
    );
    persisted = <ConvexAuthSession?>[];
    refreshCount = 0;
    server.handlers['auth:signInWithUsernamePassword'] = (_) => complete('a');
    server.handlers['auth:refreshSession'] =
        (_) => rotated('r${++refreshCount}');
    server.handlers['auth:signOut'] = (_) => null;
  });

  tearDown(() => authed.dispose());

  test('login, refresh after confirmation, and logout', () async {
    build();
    provider.signIn = ConvexAuthSignIn.usernamePassword(
      username: 'alice',
      password: 'pw',
    );

    final session = await authed.login();
    expect(session.accessToken, 'jwt_a');
    final auth = await adapter.waitForAuthenticate(
      (message) => message['value'] == 'jwt_a',
    );
    expect(auth['tokenType'], 'User');

    // Once the server confirms the login token, the wrapper fetches a fresh
    // one through loginFromCache, which rotates the session.
    adapter.confirmAuth();
    await adapter.waitForAuthenticate(
      (message) => message['value'] == 'jwt_r1',
    );
    expect(server.callsTo('auth:refreshSession').single.args,
        {'refreshToken': 'rt_a'});
    expect(persisted.last?.refreshToken, 'rt_r1');

    adapter.confirmAuth();
    await waitUntil(
      () => authed.currentAuthState is AuthAuthenticated<ConvexAuthSession>,
      reason: 'authenticated state',
    );

    await authed.logout();

    expect(server.callsTo('auth:signOut').last.args, {'refreshToken': 'rt_r1'});
    expect(
        authed.currentAuthState, isA<AuthUnauthenticated<ConvexAuthSession>>());
    expect(provider.session, isNull);
    expect(persisted.last, isNull);
    await adapter.waitForAuthenticate(
      (message) => message['tokenType'] == 'None',
    );
  });

  test('restores a persisted session', () async {
    build(initialSession: ConvexAuthSession.fromJson(bundle('saved')));

    final session = await authed.loginFromCache();

    expect(session.refreshToken, 'rt_r1');
    expect(server.callsTo('auth:refreshSession').single.args,
        {'refreshToken': 'rt_saved'});
    await adapter.waitForAuthenticate(
      (message) => message['value'] == 'jwt_r1',
    );
  });

  test('a restore of a revoked session signs out', () async {
    server.handlers['auth:refreshSession'] = (_) => noSession;
    build(initialSession: ConvexAuthSession.fromJson(bundle('dead')));

    await expectLater(
      authed.loginFromCache(),
      throwsA(isA<ConvexAuthSessionEndedException>()),
    );
    expect(
        authed.currentAuthState, isA<AuthUnauthenticated<ConvexAuthSession>>());
    expect(persisted, [null]);
  });

  test('a rejected token is replaced through a refresh', () async {
    build();
    provider.signIn = ConvexAuthSignIn.usernamePassword(
      username: 'alice',
      password: 'pw',
    );
    await authed.login();
    await adapter.waitForAuthenticate(
      (message) => message['value'] == 'jwt_a',
    );

    final before = adapter.sentCount;
    adapter.sendAuthError();

    await adapter.waitForAuthenticate(
      (message) => message['value'] == 'jwt_r1',
      after: before,
    );
    expect(provider.session?.refreshToken, 'rt_r1');
  });
}
