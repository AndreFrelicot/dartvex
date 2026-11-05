import 'package:dartvex/dartvex.dart'
    show AuthAuthenticated, AuthState, AuthUnauthenticated, ConvexException;
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_auth_client.dart';
import 'test_helpers/fake_runtime_client.dart';

Widget _app(Widget child) =>
    Directionality(textDirection: TextDirection.ltr, child: child);

FakeRuntimeClient _client([
  ConvexConnectionState state = ConvexConnectionState.connected,
]) => FakeRuntimeClient(initialConnectionState: state);

/// Calls [onBuild] from its own build, i.e. during the build phase.
class _CallDuringBuild extends StatelessWidget {
  const _CallDuringBuild(this.onBuild);

  final VoidCallback onBuild;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return const SizedBox();
  }
}

void main() {
  group('client swaps reset builder state (F86)', () {
    testWidgets('ConvexAuthBuilder re-seeds from the new auth client', (
      tester,
    ) async {
      final signedIn = FakeAuthClient<String>(
        initialAuthState: AuthAuthenticated<String>('alice'),
      );
      final signedOut = FakeAuthClient<String>(
        initialAuthState: AuthUnauthenticated<String>(),
      );
      Widget build(FakeAuthClient<String> client) => _app(
        ConvexAuthProvider<String>(
          client: client,
          child: ConvexAuthBuilder<String>(
            builder: (context, AuthState<String> state) => Text(
              state is AuthAuthenticated<String> ? state.userInfo : 'out',
            ),
          ),
        ),
      );

      await tester.pumpWidget(build(signedIn));
      expect(find.text('alice'), findsOneWidget);

      await tester.pumpWidget(build(signedOut));
      expect(find.text('out'), findsOneWidget);

      // The previous client's events no longer reach the widget.
      signedIn.emitAuthState(AuthAuthenticated<String>('mallory'));
      await tester.pump();
      expect(find.text('out'), findsOneWidget);

      signedOut.emitAuthState(AuthAuthenticated<String>('bob'));
      await tester.pump();
      expect(find.text('bob'), findsOneWidget);
    });

    testWidgets('connection, status and auth-refreshing builders re-seed', (
      tester,
    ) async {
      final first = _client()..emitAuthRefreshing(true);
      final second = _client(ConvexConnectionState.disconnected);
      Widget build(FakeRuntimeClient client) => _app(
        ConvexProvider(
          client: client,
          child: Column(
            children: [
              ConvexConnectionBuilder(
                builder: (context, state) => Text('state:${state.name}'),
              ),
              ConvexConnectionStatusBuilder(
                builder: (context, status) =>
                    Text('status:${status.state.name}'),
              ),
              ConvexAuthRefreshingBuilder(
                builder: (context, refreshing) =>
                    Text('refreshing:$refreshing'),
              ),
            ],
          ),
        ),
      );

      await tester.pumpWidget(build(first));
      expect(find.text('state:connected'), findsOneWidget);
      expect(find.text('status:connected'), findsOneWidget);
      expect(find.text('refreshing:true'), findsOneWidget);

      await tester.pumpWidget(build(second));
      expect(find.text('state:disconnected'), findsOneWidget);
      expect(find.text('status:disconnected'), findsOneWidget);
      expect(find.text('refreshing:false'), findsOneWidget);
    });
  });

  group('ConvexQuery client swap (F87)', () {
    testWidgets('drops the previous client data and never pairs it with the '
        'new client error', (tester) async {
      final first = _client();
      final second = _client();
      final snapshots = <ConvexQuerySnapshot<String>>[];
      Widget build(FakeRuntimeClient client) => _app(
        ConvexProvider(
          client: client,
          child: ConvexQuery<String>(
            query: 'messages:listMine',
            builder: (context, snapshot) {
              snapshots.add(snapshot);
              return const SizedBox();
            },
          ),
        ),
      );

      await tester.pumpWidget(build(first));
      first.subscribeCalls.single.subscription.emitSuccess('alice-data');
      await tester.pump();
      expect(snapshots.last.data, 'alice-data');

      await tester.pumpWidget(build(second));
      expect(snapshots.last.hasData, isFalse);
      expect(snapshots.last.data, isNull);
      expect(snapshots.last.isLoading, isTrue);

      second.subscribeCalls.single.subscription.emitError(
        const ConvexException('Unauthenticated'),
      );
      await tester.pump();
      expect(snapshots.last.hasError, isTrue);
      expect(snapshots.last.hasData, isFalse);
      expect(snapshots.last.data, isNull);
    });

    testWidgets('keeps the previous data while args change on one client', (
      tester,
    ) async {
      final client = _client();
      late ConvexQuerySnapshot<String> latest;
      Widget build(String channel) => _app(
        ConvexProvider(
          client: client,
          child: ConvexQuery<String>(
            query: 'messages:list',
            args: <String, dynamic>{'channel': channel},
            builder: (context, snapshot) {
              latest = snapshot;
              return const SizedBox();
            },
          ),
        ),
      );

      await tester.pumpWidget(build('a'));
      client.subscribeCalls.single.subscription.emitSuccess('a-data');
      await tester.pump();

      await tester.pumpWidget(build('b'));
      expect(latest.data, 'a-data');
      expect(latest.isRefreshing, isTrue);
    });
  });

  testWidgets('ConvexQuery renders a locally known result in its first frame '
      '(F91)', (tester) async {
    final client = _client()
      ..nextSubscriptionSeed = const ConvexRuntimeQuerySuccess('cached');
    final snapshots = <ConvexQuerySnapshot<String>>[];

    await tester.pumpWidget(
      _app(
        ConvexProvider(
          client: client,
          child: ConvexQuery<String>(
            query: 'messages:list',
            builder: (context, snapshot) {
              snapshots.add(snapshot);
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    expect(snapshots, hasLength(1));
    expect(snapshots.single.isLoading, isFalse);
    expect(snapshots.single.data, 'cached');
  });

  group('subscribe failures become error snapshots (F200)', () {
    testWidgets('ConvexQuery', (tester) async {
      final disposed = _client()
        ..subscribeError = const ConvexException(
          'ConvexClient has been disposed',
        );
      final healthy = _client();
      late ConvexQuerySnapshot<String> latest;
      Widget build(FakeRuntimeClient client) => _app(
        ConvexProvider(
          client: client,
          child: ConvexQuery<String>(
            query: 'messages:list',
            builder: (context, snapshot) {
              latest = snapshot;
              return const SizedBox();
            },
          ),
        ),
      );

      await tester.pumpWidget(build(disposed));
      expect(tester.takeException(), isNull);
      expect(latest.hasError, isTrue);
      expect(latest.error, isA<ConvexException>());

      await tester.pumpWidget(build(healthy));
      expect(healthy.subscribeCalls, hasLength(1));
      healthy.subscribeCalls.single.subscription.emitSuccess('ok');
      await tester.pump();
      expect(latest.data, 'ok');
      expect(latest.hasError, isFalse);
    });

    testWidgets('PaginatedQueryBuilder', (tester) async {
      final disposed = _client()
        ..paginatedQueryError = const ConvexException(
          'ConvexClient has been disposed',
        );
      Object? reportedError;

      await tester.pumpWidget(
        _app(
          ConvexProvider(
            client: disposed,
            child: PaginatedQueryBuilder<Map<String, dynamic>>(
              query: 'items:list',
              fromJson: (json) => json,
              builder: (context, items, loadMore, status) =>
                  Text('status:${status.name}'),
              errorBuilder: (context, error, items, retry) {
                reportedError = error;
                return const Text('error');
              },
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('error'), findsOneWidget);
      expect(reportedError, isA<ConvexException>());
    });
  });

  group('ConvexMutation executor after unmount (F88)', () {
    testWidgets('still sends the mutation and completes', (tester) async {
      final client = _client()..onMutate = (name, args) async => 'id-1';
      late ConvexRequestExecutor<String> mutate;

      await tester.pumpWidget(
        _app(
          ConvexProvider(
            client: client,
            child: ConvexMutation<String>(
              mutation: 'files:attach',
              builder: (context, executor, snapshot) {
                mutate = executor;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pumpWidget(_app(const SizedBox()));

      final result = await mutate(<String, dynamic>{'storageId': 's1'});

      expect(result, 'id-1');
      expect(client.mutateCalls.single.name, 'files:attach');
      expect(tester.takeException(), isNull);
    });

    testWidgets('ConvexAction behaves the same', (tester) async {
      final client = _client()..onAction = (name, args) async => 42;
      late ConvexRequestExecutor<int> run;

      await tester.pumpWidget(
        _app(
          ConvexProvider(
            client: client,
            child: ConvexAction<int>(
              action: 'jobs:start',
              builder: (context, executor, snapshot) {
                run = executor;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      await tester.pumpWidget(_app(const SizedBox()));

      expect(await run(), 42);
      expect(client.actionCalls, hasLength(1));
    });
  });

  group('decode failures are typed (F207)', () {
    testWidgets('ConvexQuery reports ConvexDecodeException', (tester) async {
      final client = _client();
      late ConvexQuerySnapshot<String> latest;

      await tester.pumpWidget(
        _app(
          ConvexProvider(
            client: client,
            child: ConvexQuery<String>(
              query: 'tasks:get',
              decode: (value) => value as String,
              builder: (context, snapshot) {
                latest = snapshot;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      client.subscribeCalls.single.subscription.emitSuccess(<String, int>{
        'id': 1,
      });
      await tester.pump();

      expect(latest.hasError, isTrue);
      final error = latest.error! as ConvexDecodeException;
      expect(error.error, isA<TypeError>());
      expect(error.value, <String, int>{'id': 1});
    });

    testWidgets('ConvexMutation tells a committed write apart from a '
        'rejection', (tester) async {
      final client = _client()
        ..onMutate = (name, args) async => <String, String>{'id': 'x'};
      late ConvexRequestExecutor<String> mutate;
      late ConvexRequestSnapshot<String> latest;

      await tester.pumpWidget(
        _app(
          ConvexProvider(
            client: client,
            child: ConvexMutation<String>(
              mutation: 'tasks:create',
              decode: (value) => value as String,
              builder: (context, executor, snapshot) {
                mutate = executor;
                latest = snapshot;
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      await expectLater(mutate(), throwsA(isA<ConvexDecodeException>()));
      await tester.pump();
      expect(latest.error, isA<ConvexDecodeException>());
    });
  });

  group('emissions during a build or layout pass (F90)', () {
    testWidgets('loadMore from an itemBuilder does not throw', (tester) async {
      final client = _client()
        ..onLoadMore = (query, numItems) {
          query.emitPage(
            query.current.results,
            status: ConvexPaginationStatus.loadingMore,
          );
        };
      PaginationStatus? status;

      await tester.pumpWidget(
        _app(
          ConvexProvider(
            client: client,
            child: PaginatedQueryBuilder<Map<String, dynamic>>(
              query: 'items:list',
              fromJson: (json) => json,
              builder: (context, items, loadMore, current) {
                status = current;
                return ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    if (index == items.length - 1 &&
                        current == PaginationStatus.idle) {
                      loadMore();
                    }
                    return Text('item $index');
                  },
                );
              },
            ),
          ),
        ),
      );
      client.paginatedQueryCalls.single.query.emitPage(<dynamic>[
        <String, dynamic>{'id': 1},
        <String, dynamic>{'id': 2},
      ], status: ConvexPaginationStatus.canLoadMore);
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(client.paginatedQueryCalls.single.query.loadMoreCount, 1);
      expect(status, PaginationStatus.loadingMore);
    });

    testWidgets('a connection change emitted by a descendant build does not '
        'throw', (tester) async {
      final client = _client(ConvexConnectionState.disconnected);
      var emitted = false;

      await tester.pumpWidget(
        _app(
          ConvexProvider(
            client: client,
            child: Column(
              children: [
                ConvexConnectionBuilder(
                  builder: (context, state) => Text('state:${state.name}'),
                ),
                // Like a lazy client starting because a descendant subscribed.
                _CallDuringBuild(() {
                  if (!emitted) {
                    emitted = true;
                    client.emitConnectionState(
                      ConvexConnectionState.connecting,
                    );
                  }
                }),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('state:connecting'), findsOneWidget);
    });
  });

  group('PaginatedQueryBuilder errors and decoding (F93, F213)', () {
    testWidgets('errorBuilder receives the page error and can retry', (
      tester,
    ) async {
      final client = _client();
      Object? received;

      await tester.pumpWidget(
        _app(
          ConvexProvider(
            client: client,
            child: PaginatedQueryBuilder<Map<String, dynamic>>(
              query: 'items:list',
              fromJson: (json) => json,
              builder: (context, items, loadMore, status) =>
                  Text('status:${status.name}'),
              errorBuilder: (context, error, items, retry) {
                received = error;
                return GestureDetector(
                  onTap: retry,
                  child: Text('error:${items.length}'),
                );
              },
            ),
          ),
        ),
      );
      client.paginatedQueryCalls.single.query.emitPage(
        <dynamic>[
          <String, dynamic>{'id': 1},
        ],
        status: ConvexPaginationStatus.error,
        error: const ConvexException('page failed'),
      );
      await tester.pump();

      expect(find.text('error:1'), findsOneWidget);
      expect(received, isA<ConvexException>());

      await tester.tap(find.text('error:1'));
      await tester.pump();
      expect(client.paginatedQueryCalls, hasLength(2));
      expect(client.paginatedQueryCalls.first.query.isCanceled, isTrue);
      expect(find.text('status:loading'), findsOneWidget);
    });

    testWidgets('unchanged items are not decoded again', (tester) async {
      final client = _client();
      var decodes = 0;
      List<int> latest = const <int>[];

      await tester.pumpWidget(
        _app(
          ConvexProvider(
            client: client,
            child: PaginatedQueryBuilder<int>(
              query: 'items:list',
              fromJson: _countingDecoder(() => decodes += 1),
              builder: (context, items, loadMore, status) {
                latest = items;
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      final first = <String, dynamic>{'id': 1};
      final query = client.paginatedQueryCalls.single.query;
      query.emitPage(<dynamic>[
        first,
      ], status: ConvexPaginationStatus.canLoadMore);
      await tester.pump();
      query.emitPage(<dynamic>[
        first,
        <String, dynamic>{'id': 2},
      ], status: ConvexPaginationStatus.canLoadMore);
      await tester.pump();

      expect(latest, <int>[1, 2]);
      expect(decodes, 2);
      expect(() => latest.add(3), throwsUnsupportedError);
    });
  });
}

int Function(Map<String, dynamic>) _countingDecoder(void Function() onDecode) {
  return (json) {
    onDecode();
    return json['id'] as int;
  };
}
