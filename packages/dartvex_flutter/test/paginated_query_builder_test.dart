import 'dart:async';

import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_helpers/fake_runtime_client.dart';

void main() {
  Widget buildPaginated({
    required FakeRuntimeClient client,
    required void Function(List<Map<String, dynamic>>, PaginationStatus)
        onBuild,
    String query = 'items:list',
    Map<String, dynamic>? args,
    int pageSize = 2,
  }) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ConvexProvider(
        client: client,
        child: PaginatedQueryBuilder<Map<String, dynamic>>(
          query: query,
          args: args,
          pageSize: pageSize,
          fromJson: (json) => json,
          builder: (context, items, loadMore, status) {
            onBuild(items, status);
            return GestureDetector(
              onTap: loadMore,
              child: Text('status:$status items:${items.length}'),
            );
          },
        ),
      ),
    );
  }

  FakeRuntimeClient connectedClient() => FakeRuntimeClient(
        initialConnectionState: ConvexConnectionState.connected,
      );

  testWidgets('starts in loading state and opens one paginated query',
      (tester) async {
    final client = connectedClient();
    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (_, status) => capturedStatus = status,
      ),
    );

    expect(capturedStatus, PaginationStatus.loading);
    expect(client.paginatedQueryCalls, hasLength(1));
    expect(client.paginatedQueryCalls.single.name, 'items:list');
    expect(client.paginatedQueryCalls.single.pageSize, 2);
  });

  testWidgets('seeds the first build from a warm paginated result',
      (tester) async {
    final client = connectedClient();
    client.nextPaginatedInitialResult = const ConvexPaginatedResult(
      results: <dynamic>[
        <String, dynamic>{'id': 'warm'},
      ],
      status: ConvexPaginationStatus.canLoadMore,
      isDone: false,
    );
    List<Map<String, dynamic>>? capturedItems;
    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (items, status) {
          capturedItems = items;
          capturedStatus = status;
        },
      ),
    );

    expect(capturedItems, <Map<String, dynamic>>[
      <String, dynamic>{'id': 'warm'},
    ]);
    expect(capturedStatus, PaginationStatus.idle);
    expect(client.paginatedQueryCalls, hasLength(1));
  });

  testWidgets('renders the first page reactively', (tester) async {
    final client = connectedClient();
    List<Map<String, dynamic>>? capturedItems;
    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (items, status) {
          capturedItems = items;
          capturedStatus = status;
        },
      ),
    );

    client.paginatedQueryCalls.single.query.emitPage(
      <dynamic>[
        <String, dynamic>{'id': '1'},
        <String, dynamic>{'id': '2'},
      ],
      status: ConvexPaginationStatus.canLoadMore,
    );
    await tester.pump();

    expect(capturedItems, hasLength(2));
    expect(capturedStatus, PaginationStatus.idle);
  });

  testWidgets('loadMore requests the next page and updates reactively',
      (tester) async {
    final client = connectedClient();
    List<Map<String, dynamic>>? capturedItems;
    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (items, status) {
          capturedItems = items;
          capturedStatus = status;
        },
      ),
    );

    final query = client.paginatedQueryCalls.single.query;
    query.emitPage(
      <dynamic>[
        <String, dynamic>{'id': '1'},
      ],
      status: ConvexPaginationStatus.canLoadMore,
    );
    await tester.pump();
    expect(capturedItems, hasLength(1));
    expect(capturedStatus, PaginationStatus.idle);

    await tester.tap(find.byType(GestureDetector));
    await tester.pump();
    expect(query.loadMoreCount, 1);

    // The engine would append the next page; emit the aggregated result.
    query.emitPage(
      <dynamic>[
        <String, dynamic>{'id': '1'},
        <String, dynamic>{'id': '2'},
      ],
      status: ConvexPaginationStatus.exhausted,
      isDone: true,
    );
    await tester.pump();
    expect(capturedItems, hasLength(2));
    expect(capturedStatus, PaginationStatus.allLoaded);
  });

  testWidgets('shows allLoaded when the first page is exhausted',
      (tester) async {
    final client = connectedClient();
    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (_, status) => capturedStatus = status,
      ),
    );

    client.paginatedQueryCalls.single.query.emitPage(
      <dynamic>[
        <String, dynamic>{'id': '1'},
      ],
      status: ConvexPaginationStatus.exhausted,
      isDone: true,
    );
    await tester.pump();

    expect(capturedStatus, PaginationStatus.allLoaded);
  });

  testWidgets('maps the error status', (tester) async {
    final client = connectedClient();
    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (_, status) => capturedStatus = status,
      ),
    );

    client.paginatedQueryCalls.single.query.emitPage(
      <dynamic>[],
      status: ConvexPaginationStatus.error,
      error: StateError('boom'),
    );
    await tester.pump();

    expect(capturedStatus, PaginationStatus.error);
  });

  testWidgets('maps item decode failures to error status without throwing', (
    tester,
  ) async {
    final client = connectedClient();
    PaginationStatus? capturedStatus;

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ConvexProvider(
          client: client,
          child: PaginatedQueryBuilder<int>(
            query: 'items:list',
            fromJson: (_) => throw const FormatException('bad item'),
            builder: (context, items, loadMore, status) {
              capturedStatus = status;
              return Text('status:$status items:${items.length}');
            },
          ),
        ),
      ),
    );

    expect(
      () => client.paginatedQueryCalls.single.query.emitPage(
        <dynamic>[
          <String, dynamic>{'id': 'bad'},
        ],
        status: ConvexPaginationStatus.canLoadMore,
      ),
      returnsNormally,
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(capturedStatus, PaginationStatus.error);
  });

  testWidgets('updates a loaded page reactively without duplicates',
      (tester) async {
    final client = connectedClient();
    List<Map<String, dynamic>>? capturedItems;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        onBuild: (items, _) => capturedItems = items,
      ),
    );

    final query = client.paginatedQueryCalls.single.query;
    query.emitPage(
      <dynamic>[
        <String, dynamic>{'id': 'a'},
        <String, dynamic>{'id': 'b'},
      ],
      status: ConvexPaginationStatus.canLoadMore,
    );
    await tester.pump();
    expect(
      capturedItems!.map((item) => item['id']).toList(),
      <String>['a', 'b'],
    );

    // An insert into an already-loaded page flows through reactively.
    query.emitPage(
      <dynamic>[
        <String, dynamic>{'id': 'a'},
        <String, dynamic>{'id': 'x'},
        <String, dynamic>{'id': 'b'},
      ],
      status: ConvexPaginationStatus.canLoadMore,
    );
    await tester.pump();
    expect(
      capturedItems!.map((item) => item['id']).toList(),
      <String>['a', 'x', 'b'],
    );
  });

  testWidgets('resets the query when args change', (tester) async {
    final client = connectedClient();

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        args: const <String, dynamic>{'channel': 'a'},
        onBuild: (_, __) {},
      ),
    );
    expect(client.paginatedQueryCalls, hasLength(1));
    final firstQuery = client.paginatedQueryCalls.first.query;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        args: const <String, dynamic>{'channel': 'b'},
        onBuild: (_, __) {},
      ),
    );

    expect(client.paginatedQueryCalls, hasLength(2));
    expect(firstQuery.isCanceled, isTrue);
    expect(
      client.paginatedQueryCalls.last.args,
      const <String, dynamic>{'channel': 'b'},
    );
  });

  testWidgets('ignores stale page events from canceled queries',
      (tester) async {
    final client = _StalePaginatedRuntimeClient(
      initialConnectionState: ConvexConnectionState.connected,
    );
    addTearDown(() async {
      for (final query in client.stalePaginatedQueries) {
        await query.close();
      }
    });
    List<Map<String, dynamic>>? capturedItems;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        args: const <String, dynamic>{'channel': 'a'},
        onBuild: (items, _) => capturedItems = items,
      ),
    );
    final firstQuery = client.stalePaginatedQueries.single;

    await tester.pumpWidget(
      buildPaginated(
        client: client,
        args: const <String, dynamic>{'channel': 'b'},
        onBuild: (items, _) => capturedItems = items,
      ),
    );
    final secondQuery = client.stalePaginatedQueries.last;
    secondQuery.emitPage(
      <dynamic>[
        <String, dynamic>{'id': 'fresh'},
      ],
      status: ConvexPaginationStatus.canLoadMore,
    );
    await tester.pump();
    expect(capturedItems!.map((item) => item['id']).toList(), <String>[
      'fresh',
    ]);

    expect(firstQuery.isCanceled, isTrue);
    firstQuery.emitPage(
      <dynamic>[
        <String, dynamic>{'id': 'stale'},
      ],
      status: ConvexPaginationStatus.canLoadMore,
    );
    await tester.pump();

    expect(capturedItems!.map((item) => item['id']).toList(), <String>[
      'fresh',
    ]);
  });
}

class _StalePaginatedRuntimeClient extends FakeRuntimeClient {
  _StalePaginatedRuntimeClient({
    required super.initialConnectionState,
  });

  final List<_StaleRuntimePaginatedQuery> stalePaginatedQueries =
      <_StaleRuntimePaginatedQuery>[];

  @override
  ConvexRuntimePaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    final query = _StaleRuntimePaginatedQuery();
    stalePaginatedQueries.add(query);
    return query;
  }
}

class _StaleRuntimePaginatedQuery implements ConvexRuntimePaginatedQuery {
  final StreamController<ConvexPaginatedResult> _controller =
      StreamController<ConvexPaginatedResult>.broadcast(sync: true);
  ConvexPaginatedResult _current = const ConvexPaginatedResult(
    results: <dynamic>[],
    status: ConvexPaginationStatus.loadingFirstPage,
    isDone: false,
  );
  bool isCanceled = false;

  @override
  Stream<ConvexPaginatedResult> get stream => _controller.stream;

  @override
  ConvexPaginatedResult get current => _current;

  @override
  bool loadMore([int? numItems]) => true;

  @override
  void cancel() {
    isCanceled = true;
  }

  void emitPage(
    List<dynamic> results, {
    required ConvexPaginationStatus status,
  }) {
    _current = ConvexPaginatedResult(
      results: results,
      status: status,
      isDone: false,
    );
    _controller.add(_current);
  }

  Future<void> close() => _controller.close();
}
