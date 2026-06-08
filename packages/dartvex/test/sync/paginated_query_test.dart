import 'dart:async';

import 'package:dartvex/src/exceptions.dart';
import 'package:dartvex/src/sync/paginated_query.dart';
import 'package:dartvex/src/sync/remote_query_set.dart';
import 'package:test/test.dart';

/// A controllable fake page subscription for driving the coordinator.
class _FakePage implements PageSubscription {
  _FakePage(this.args);

  final Map<String, dynamic> args;
  final StreamController<StoredQueryResult> _controller =
      StreamController<StoredQueryResult>.broadcast(sync: true);
  bool canceled = false;

  Map<String, dynamic> get paginationOpts =>
      args['paginationOpts'] as Map<String, dynamic>;
  int get numItems => paginationOpts['numItems'] as int;
  String? get cursor => paginationOpts['cursor'] as String?;
  bool get hasEndCursor => paginationOpts.containsKey('endCursor');
  String? get endCursor => paginationOpts['endCursor'] as String?;

  @override
  Stream<StoredQueryResult> get results => _controller.stream;

  @override
  void cancel() {
    canceled = true;
    scheduleMicrotask(() {
      unawaited(_controller.close());
    });
  }

  void emitPage(
    List<dynamic> page, {
    required String? continueCursor,
    required bool isDone,
    String? splitCursor,
    String? pageStatus,
  }) {
    _controller.add(
      StoredQuerySuccess(
        value: <String, dynamic>{
          'page': page,
          'continueCursor': continueCursor,
          'isDone': isDone,
          'splitCursor': splitCursor,
          'pageStatus': pageStatus,
        },
        logLines: const <String>[],
      ),
    );
  }

  void emitError(String message) {
    _controller.add(
      StoredQueryError(message: message, logLines: const <String>[]),
    );
  }

  void emitLoading() {
    _controller.add(const StoredQueryLoading());
  }
}

class _FakeSource {
  final List<_FakePage> pages = <_FakePage>[];

  PageSubscription subscribe(String name, Map<String, dynamic> args) {
    final page = _FakePage(args);
    pages.add(page);
    return page;
  }
}

StoredQuerySuccess _pageSuccess(
  List<dynamic> page, {
  required String? continueCursor,
  required bool isDone,
  String? splitCursor,
  String? pageStatus,
}) {
  return StoredQuerySuccess(
    value: <String, dynamic>{
      'page': page,
      'continueCursor': continueCursor,
      'isDone': isDone,
      'splitCursor': splitCursor,
      'pageStatus': pageStatus,
    },
    logLines: const <String>[],
  );
}

void main() {
  group('ConvexPaginatedQuery', () {
    test('loads the first page with cursor null and aggregates results', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{'channel': 'general'},
        pageSize: 3,
      );

      expect(query.status, ConvexPaginationStatus.loadingFirstPage);
      expect(query.current.results, isEmpty);
      expect(source.pages, hasLength(1));
      expect(source.pages[0].cursor, isNull);
      expect(source.pages[0].numItems, 3);
      expect(source.pages[0].hasEndCursor, isFalse);
      expect(source.pages[0].args['channel'], 'general');

      source.pages[0].emitPage(
        <dynamic>['a', 'b', 'c'],
        continueCursor: 'X',
        isDone: false,
      );

      expect(query.current.results, <dynamic>['a', 'b', 'c']);
      expect(query.status, ConvexPaginationStatus.canLoadMore);
      expect(query.isDone, isFalse);

      query.cancel();
    });

    test('seeds the first page synchronously from a warm result', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        readInitialResult: (name, args) {
          expect(name, 'messages:list');
          expect(args['paginationOpts'], const <String, dynamic>{
            'numItems': 3,
            'cursor': null,
          });
          return StoredQuerySuccess(
            value: const <String, dynamic>{
              'page': <String>['warm'],
              'continueCursor': 'C',
              'isDone': false,
            },
            logLines: const <String>[],
          );
        },
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );

      expect(query.current.results, <dynamic>['warm']);
      expect(query.status, ConvexPaginationStatus.canLoadMore);
      expect(source.pages, hasLength(1));

      query.cancel();
    });

    test('loadMore chains the next page via the continueCursor', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );
      source.pages[0].emitPage(<dynamic>['a', 'b', 'c'],
          continueCursor: 'X', isDone: false);

      expect(query.loadMore(), isTrue);
      // A second concurrent loadMore while the page is still loading is a no-op.
      expect(query.loadMore(), isFalse);
      expect(query.status, ConvexPaginationStatus.loadingMore);
      expect(source.pages, hasLength(2));
      expect(source.pages[1].cursor, 'X');
      expect(source.pages[1].numItems, 3);

      source.pages[1].emitPage(<dynamic>['d', 'e', 'f'],
          continueCursor: 'Y', isDone: false);

      expect(query.current.results, <dynamic>['a', 'b', 'c', 'd', 'e', 'f']);
      expect(query.status, ConvexPaginationStatus.canLoadMore);

      query.cancel();
    });

    test('loadMore honors an explicit numItems override', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );
      source.pages[0]
          .emitPage(<dynamic>['a'], continueCursor: 'X', isDone: false);

      query.loadMore(10);

      expect(source.pages[1].numItems, 10);
      expect(source.pages[1].cursor, 'X');

      query.cancel();
    });

    test('an earlier page updates reactively without gaps or dupes', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );
      source.pages[0].emitPage(<dynamic>['a', 'b', 'c'],
          continueCursor: 'X', isDone: false);
      query.loadMore();
      source.pages[1].emitPage(<dynamic>['d', 'e', 'f'],
          continueCursor: 'Y', isDone: false);
      expect(query.current.results, <dynamic>['a', 'b', 'c', 'd', 'e', 'f']);

      // Insert into the first page; its continueCursor stays stable (the server
      // pins the boundary via the journal), so the second page still aligns.
      source.pages[0].emitPage(
        <dynamic>['a', 'b', 'bb', 'c'],
        continueCursor: 'X',
        isDone: false,
      );
      expect(
        query.current.results,
        <dynamic>['a', 'b', 'bb', 'c', 'd', 'e', 'f'],
      );

      // Delete from the first page.
      source.pages[0]
          .emitPage(<dynamic>['a', 'c'], continueCursor: 'X', isDone: false);
      expect(query.current.results, <dynamic>['a', 'c', 'd', 'e', 'f']);

      query.cancel();
    });

    test('returns a loaded page to loading when it receives loading', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );
      source.pages[0].emitPage(
        <dynamic>['a', 'b', 'c'],
        continueCursor: 'X',
        isDone: false,
      );
      expect(query.current.results, <dynamic>['a', 'b', 'c']);
      expect(query.status, ConvexPaginationStatus.canLoadMore);

      source.pages[0].emitLoading();

      expect(query.current.results, isEmpty);
      expect(query.status, ConvexPaginationStatus.loadingFirstPage);

      query.cancel();
    });

    test('reports exhausted and refuses loadMore once the last page isDone',
        () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );
      source.pages[0]
          .emitPage(<dynamic>['a', 'b'], continueCursor: 'X', isDone: true);

      expect(query.status, ConvexPaginationStatus.exhausted);
      expect(query.isDone, isTrue);
      expect(query.loadMore(), isFalse);
      expect(source.pages, hasLength(1));

      query.cancel();
    });

    test('emits each aggregated change on the stream', () async {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );
      final statuses = <ConvexPaginationStatus>[];
      query.stream.listen((result) => statuses.add(result.status));

      source.pages[0]
          .emitPage(<dynamic>['a'], continueCursor: 'X', isDone: false);
      query.loadMore();
      source.pages[1]
          .emitPage(<dynamic>['b'], continueCursor: 'Y', isDone: true);
      await Future<void>.delayed(Duration.zero);

      expect(
        statuses,
        <ConvexPaginationStatus>[
          ConvexPaginationStatus.canLoadMore,
          ConvexPaginationStatus.loadingMore,
          ConvexPaginationStatus.exhausted,
        ],
      );

      query.cancel();
    });

    test('surfaces a failed page as an error status', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );

      source.pages[0].emitError('boom');

      expect(query.status, ConvexPaginationStatus.error);
      expect(query.current.error, isA<ConvexException>());
      expect((query.current.error! as ConvexException).message, 'boom');

      query.cancel();
    });

    test('rejects missing continueCursor when more pages are available', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );

      source.pages[0].emitPage(
        <dynamic>['a', 'b', 'c'],
        continueCursor: null,
        isDone: false,
      );

      expect(query.status, ConvexPaginationStatus.error);
      expect(query.current.error, isA<ConvexException>());
      expect(
        (query.current.error! as ConvexException).message,
        contains('continueCursor'),
      );
      expect(query.loadMore(), isFalse);
      expect(source.pages, hasLength(1));

      query.cancel();
    });

    test('loadMore is a no-op while an earlier page is errored', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );
      source.pages[0]
          .emitPage(<dynamic>['a'], continueCursor: 'X', isDone: false);
      expect(query.loadMore(), isTrue);
      source.pages[1]
          .emitPage(<dynamic>['b'], continueCursor: 'Y', isDone: false);

      source.pages[0].emitError('boom');

      expect(query.status, ConvexPaginationStatus.error);
      expect(query.loadMore(), isFalse);
      expect(source.pages, hasLength(2));

      query.cancel();
    });

    test('re-splits a page on SplitRecommended and swaps in both halves', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );

      // First page comes back oversized with a split recommendation.
      source.pages[0].emitPage(
        <dynamic>['a', 'b', 'ba', 'bb', 'c'],
        continueCursor: 'C',
        isDone: false,
        splitCursor: 'S',
        pageStatus: 'SplitRecommended',
      );

      // The original page still serves data while the split loads — no gap.
      expect(query.current.results, <dynamic>['a', 'b', 'ba', 'bb', 'c']);
      expect(query.status, ConvexPaginationStatus.canLoadMore);

      // Two bounded half-page subscriptions were opened.
      expect(source.pages, hasLength(3));
      final firstHalf = source.pages[1];
      final secondHalf = source.pages[2];
      expect(firstHalf.cursor, isNull);
      expect(firstHalf.hasEndCursor, isTrue);
      expect(firstHalf.endCursor, 'S');
      expect(secondHalf.cursor, 'S');
      expect(secondHalf.endCursor, 'C');

      firstHalf
          .emitPage(<dynamic>['a', 'b'], continueCursor: 'S', isDone: false);
      // After only one half loads, the original is still active (still no dupes).
      expect(query.current.results, <dynamic>['a', 'b', 'ba', 'bb', 'c']);
      expect(source.pages[0].canceled, isFalse);

      secondHalf.emitPage(
        <dynamic>['ba', 'bb', 'c'],
        continueCursor: 'C',
        isDone: false,
      );

      // Both halves loaded: the original is swapped out atomically, gaplessly.
      expect(query.current.results, <dynamic>['a', 'b', 'ba', 'bb', 'c']);
      expect(query.status, ConvexPaginationStatus.canLoadMore);
      expect(source.pages[0].canceled, isTrue);

      query.cancel();
    });

    test('a non-first page split starts its first half at the page cursor', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );

      // First page loads normally and reports more data is available.
      source.pages[0]
          .emitPage(<dynamic>['a', 'b', 'c'], continueCursor: 'C1', isDone: false);
      expect(query.loadMore(), isTrue);

      // The second page begins at the first page's continueCursor.
      expect(source.pages, hasLength(2));
      final secondPage = source.pages[1];
      expect(secondPage.cursor, 'C1');

      // It comes back oversized with a split recommendation.
      secondPage.emitPage(
        <dynamic>['d', 'e', 'de', 'ee', 'f'],
        continueCursor: 'C2',
        isDone: false,
        splitCursor: 'S2',
        pageStatus: 'SplitRecommended',
      );

      // The first split half must start at the page's OWN start cursor ('C1'),
      // not null. The official client hardcodes `cursor: null`, which is only
      // correct for the first page; for a later page that would re-read from the
      // beginning and overlap every earlier page. dartvex keeps the page's start
      // cursor so the two halves cover exactly the original page's range.
      expect(source.pages, hasLength(4));
      final firstHalf = source.pages[2];
      final secondHalf = source.pages[3];
      expect(firstHalf.cursor, 'C1');
      expect(firstHalf.endCursor, 'S2');
      expect(secondHalf.cursor, 'S2');
      expect(secondHalf.endCursor, 'C2');

      // No gap or duplicate while the split loads, or after it swaps in.
      const aggregated = <dynamic>['a', 'b', 'c', 'd', 'e', 'de', 'ee', 'f'];
      expect(query.current.results, aggregated);
      firstHalf.emitPage(<dynamic>['d', 'e'], continueCursor: 'S2', isDone: false);
      secondHalf
          .emitPage(<dynamic>['de', 'ee', 'f'], continueCursor: 'C2', isDone: false);
      expect(query.current.results, aggregated);
      expect(secondPage.canceled, isTrue);

      query.cancel();
    });

    test('seeds split halves synchronously from warm results', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        readInitialResult: (name, args) {
          final paginationOpts = args['paginationOpts'] as Map<String, dynamic>;
          if (paginationOpts['cursor'] == null &&
              paginationOpts['endCursor'] == 'S') {
            return _pageSuccess(
              <dynamic>['a', 'b'],
              continueCursor: 'S',
              isDone: false,
            );
          }
          if (paginationOpts['cursor'] == 'S' &&
              paginationOpts['endCursor'] == 'C') {
            return _pageSuccess(
              <dynamic>['ba', 'bb', 'c'],
              continueCursor: 'C',
              isDone: false,
            );
          }
          return null;
        },
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );

      source.pages[0].emitPage(
        <dynamic>['a', 'b', 'ba', 'bb', 'c'],
        continueCursor: 'C',
        isDone: false,
        splitCursor: 'S',
        pageStatus: 'SplitRecommended',
      );

      expect(query.current.results, <dynamic>['a', 'b', 'ba', 'bb', 'c']);
      expect(query.status, ConvexPaginationStatus.canLoadMore);
      expect(source.pages, hasLength(3));
      expect(source.pages[0].canceled, isTrue);

      query.cancel();
    });

    test('cleans up split halves and falls back to the un-split page', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );

      source.pages[0].emitPage(
        <dynamic>['a', 'b', 'ba', 'bb', 'c'],
        continueCursor: 'C',
        isDone: false,
        splitCursor: 'S',
        pageStatus: 'SplitRecommended',
      );

      expect(source.pages, hasLength(3));
      final firstHalf = source.pages[1];
      final secondHalf = source.pages[2];

      firstHalf
          .emitPage(<dynamic>['a', 'b'], continueCursor: 'S', isDone: false);
      secondHalf.emitError('split failed');

      // A failed split is only a lost optimization: both halves are torn down
      // and the query falls back to the original un-split page (which covers the
      // same range) instead of surfacing an error.
      expect(query.status, ConvexPaginationStatus.canLoadMore);
      expect(query.current.error, isNull);
      expect(query.current.results, <dynamic>['a', 'b', 'ba', 'bb', 'c']);
      expect(firstHalf.canceled, isTrue);
      expect(secondHalf.canceled, isTrue);
      expect(source.pages[0].canceled, isFalse);

      // The split is not retried until the original emits a fresh result.
      expect(source.pages, hasLength(3));

      // A fresh result for the original page re-opens the split.
      source.pages[0].emitPage(
        <dynamic>['a', 'b', 'ba', 'bb', 'c'],
        continueCursor: 'C',
        isDone: false,
        splitCursor: 'S',
        pageStatus: 'SplitRecommended',
      );
      expect(source.pages, hasLength(5));

      query.cancel();
      expect(source.pages.every((page) => page.canceled), isTrue);
    });

    test('cancels in-flight split halves when original page becomes loading',
        () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );

      source.pages[0].emitPage(
        <dynamic>['a', 'b', 'ba', 'bb', 'c'],
        continueCursor: 'C',
        isDone: false,
        splitCursor: 'S',
        pageStatus: 'SplitRecommended',
      );

      expect(source.pages, hasLength(3));
      final firstHalf = source.pages[1];
      final secondHalf = source.pages[2];
      firstHalf
          .emitPage(<dynamic>['a', 'b'], continueCursor: 'S', isDone: false);

      source.pages[0].emitLoading();

      expect(firstHalf.canceled, isTrue);
      expect(secondHalf.canceled, isTrue);
      expect(query.current.results, isEmpty);
      expect(query.status, ConvexPaginationStatus.loadingFirstPage);

      secondHalf.emitPage(
        <dynamic>['ba', 'bb', 'c'],
        continueCursor: 'C',
        isDone: false,
      );
      expect(query.current.results, isEmpty);
      expect(query.status, ConvexPaginationStatus.loadingFirstPage);

      query.cancel();
    });

    test('cancels in-flight split halves when original page changes', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );

      source.pages[0].emitPage(
        <dynamic>['a', 'b', 'ba', 'bb', 'c'],
        continueCursor: 'C',
        isDone: false,
        splitCursor: 'S',
        pageStatus: 'SplitRecommended',
      );

      expect(source.pages, hasLength(3));
      final firstHalf = source.pages[1];
      final secondHalf = source.pages[2];

      source.pages[0].emitPage(
        <dynamic>['fresh'],
        continueCursor: 'F',
        isDone: false,
      );

      expect(firstHalf.canceled, isTrue);
      expect(secondHalf.canceled, isTrue);
      expect(query.current.results, <dynamic>['fresh']);
      expect(query.status, ConvexPaginationStatus.canLoadMore);

      firstHalf
          .emitPage(<dynamic>['stale-a'], continueCursor: 'S', isDone: false);
      secondHalf
          .emitPage(<dynamic>['stale-b'], continueCursor: 'C', isDone: false);
      expect(query.current.results, <dynamic>['fresh']);

      query.cancel();
    });

    test('cancel tears down every page subscription and closes the stream', () {
      final source = _FakeSource();
      final query = ConvexPaginatedQuery(
        subscribe: source.subscribe,
        name: 'messages:list',
        args: const <String, dynamic>{},
        pageSize: 3,
      );
      source.pages[0]
          .emitPage(<dynamic>['a'], continueCursor: 'X', isDone: false);
      query.loadMore();

      query.cancel();

      expect(source.pages.every((page) => page.canceled), isTrue);
      expect(query.loadMore(), isFalse);
    });
  });
}
