import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

void main() {
  test('exports auth types from the public barrel', () {
    const state = AuthUnauthenticated<String>();
    AuthProvider<String>? provider;
    ConvexAuthClient<String>? authClient;
    ConvexClientWithAuth<String>? clientWithAuth;
    ConvexClient? client;
    final ConvexFunctionCaller? baseCaller = client;
    final ConvexFunctionCaller? authCaller = clientWithAuth;

    expect(state, isA<AuthState<String>>());
    expect(provider, isNull);
    expect(authClient, isNull);
    expect(clientWithAuth, isNull);
    expect(baseCaller, isNull);
    expect(authCaller, isNull);
  });

  test('exports TransitionMetrics from the public barrel', () {
    final metrics = TransitionMetrics(
      transitTimeMs: 150,
      messageSizeBytes: 5000000,
      bytesPerSecond: 33333333,
    );

    void callbackImpl(TransitionMetrics _) {}

    final TransitionMetricsCallback callback = callbackImpl;
    callback(metrics);

    expect(metrics.toString(), contains('150ms'));
    expect(metrics.toString(), contains('5.0MB'));
  });
}
