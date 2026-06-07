import 'package:dartvex/src/auth/auth_provider.dart';
import 'package:dartvex/src/auth/auth_token_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('AuthTokenBridge', () {
    test('fetchToken without forceRefresh returns the cached token', () async {
      final bridge = AuthTokenBridge<String>(
        authProvider: _FakeProvider(),
        onIdToken: (_) {},
        initialToken: 'cached',
      );
      expect(await bridge.fetchToken(forceRefresh: false), 'cached');
    });

    test('a throwing loginFromCache propagates and keeps the cached token',
        () async {
      final provider = _FakeProvider()..refreshError = StateError('blip');
      final bridge = AuthTokenBridge<String>(
        authProvider: provider,
        onIdToken: (_) {},
        initialToken: 'cached',
      );

      // A transient provider failure must surface as an error (so the auth
      // manager can keep the session on a scheduled refresh) rather than be
      // collapsed to a null token that reads as a definitive logout.
      await expectLater(
        bridge.fetchToken(forceRefresh: true),
        throwsA(isA<StateError>()),
      );

      // The still-valid cached token must survive the transient failure.
      expect(await bridge.fetchToken(forceRefresh: false), 'cached');
    });

    test('a successful refresh updates the cached token', () async {
      final provider = _FakeProvider()..refreshedToken = 'fresh';
      final bridge = AuthTokenBridge<String>(
        authProvider: provider,
        onIdToken: (_) {},
        initialToken: 'cached',
      );

      expect(await bridge.fetchToken(forceRefresh: true), 'fresh');
      expect(await bridge.fetchToken(forceRefresh: false), 'fresh');
    });

    test('concurrent force refreshes share one in-flight provider call',
        () async {
      final provider = _FakeProvider()..refreshedToken = 'fresh';
      final bridge = AuthTokenBridge<String>(
        authProvider: provider,
        onIdToken: (_) {},
        initialToken: 'cached',
      );

      final results = await Future.wait<String?>(<Future<String?>>[
        bridge.fetchToken(forceRefresh: true),
        bridge.fetchToken(forceRefresh: true),
      ]);

      expect(results, <String?>['fresh', 'fresh']);
      expect(provider.refreshCount, 1);
    });
  });
}

class _FakeProvider extends AuthProvider<String> {
  String refreshedToken = 'refreshed';
  Object? refreshError;
  int refreshCount = 0;

  @override
  String extractIdToken(String authResult) => authResult;

  @override
  Future<String> login({
    required void Function(String? token) onIdToken,
  }) async {
    return 'login';
  }

  @override
  Future<String> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async {
    refreshCount += 1;
    final error = refreshError;
    if (error != null) {
      throw error;
    }
    onIdToken(refreshedToken);
    return refreshedToken;
  }

  @override
  Future<void> logout() async {}
}
