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

  test('exports AuthTokenFetcher, the setAuthWithRefresh parameter type',
      () async {
    Future<String?> fetchImpl({required bool forceRefresh}) async =>
        forceRefresh ? 'fresh' : null;
    final AuthTokenFetcher fetcher = fetchImpl;

    expect(await fetcher(forceRefresh: true), 'fresh');
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

  test('exports logging types from the public barrel', () {
    void loggerImpl(DartvexLogEvent _) {}

    const event = DartvexLogEvent(
      level: DartvexLogLevel.info,
      message: 'hello',
      tag: 'test',
    );
    final DartvexLogger logger = loggerImpl;

    logger(event);

    expect(event.level, DartvexLogLevel.info);
    expect(event.tag, 'test');
  });

  test('exports convexInt64 helper from the public barrel', () {
    expect(convexInt64(7), BigInt.from(7));
    expect(jsonToConvex(convexToJson(convexInt64(7))), BigInt.from(7));
  });

  test('exports paginated query plumbing types from the public barrel', () {
    PageSubscriber? subscriber;
    PageInitialResultReader? initialResultReader;
    PageSubscription? subscription;

    expect(subscriber, isNull);
    expect(initialResultReader, isNull);
    expect(subscription, isNull);
  });

  test('exports stored query results and the commit-timestamp placeholder', () {
    const StoredQueryResult success = StoredQuerySuccess(
      value: 1,
      logLines: <String>[],
    );
    const StoredQueryResult loading = StoredQueryLoading();
    const StoredQueryResult error = StoredQueryError(
      message: 'boom',
      logLines: <String>[],
    );

    expect(success, isA<StoredQuerySuccess>());
    expect(loading, isA<StoredQueryLoading>());
    expect(error, isA<StoredQueryError>());
    expect(
      jsonToConvex(convexToJson(ConvexCommitTsPlaceholder.instance)),
      same(ConvexCommitTsPlaceholder.instance),
    );
    expect(convexToCanonicalJson(2.0), 2);
    expect(convexSyncApiVersion, isNotEmpty);
    expect(dartvexVersion, isNotEmpty);
  });
}
