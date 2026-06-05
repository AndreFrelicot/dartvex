import 'dart:async';

import '../exceptions.dart';
import 'remote_query_set.dart';

/// Status of a reactive paginated query.
///
/// Mirrors the official Convex client's pagination status, with an extra
/// [error] state: where the official client throws when a page query fails,
/// dartvex surfaces page results through a stream, so a failed page is reported
/// as [error] instead of thrown.
enum ConvexPaginationStatus {
  /// No page has produced a result yet; the first page is still loading.
  loadingFirstPage,

  /// At least one page is loaded and another page is currently loading
  /// (typically right after [ConvexPaginatedQuery.loadMore]).
  loadingMore,

  /// All loaded pages are settled and the last page reports more data is
  /// available — call [ConvexPaginatedQuery.loadMore] to fetch it.
  canLoadMore,

  /// Every page is loaded and the last page reports the query is exhausted.
  exhausted,

  /// At least one active page failed; see [ConvexPaginatedResult.error].
  error,
}

/// Immutable snapshot of a paginated query at one point in time.
///
/// Emitted on [ConvexPaginatedQuery.stream] and available synchronously via
/// [ConvexPaginatedQuery.current]. [results] is the gapless concatenation of
/// every loaded page's items, in page order.
class ConvexPaginatedResult {
  /// Creates a paginated result snapshot.
  const ConvexPaginatedResult({
    required this.results,
    required this.status,
    required this.isDone,
    this.error,
  });

  /// The concatenated items of every loaded page, in order.
  final List<dynamic> results;

  /// The current pagination status.
  final ConvexPaginationStatus status;

  /// Whether the query is fully loaded (equivalent to
  /// `status == ConvexPaginationStatus.exhausted`).
  final bool isDone;

  /// The error from the first failed page when [status] is
  /// [ConvexPaginationStatus.error]; otherwise `null`.
  final Object? error;
}

/// Opens a live subscription to a single page query.
///
/// Internal plumbing: [ConvexPaginatedQuery] calls this once per page (and once
/// per split half) with the same udf path and the page's args (including
/// `paginationOpts`). `ConvexClient` supplies an implementation backed by a
/// normal query subscription, so every page flows through the same sync,
/// optimistic-overlay, and reconnect machinery as any other query.
typedef PageSubscriber = PageSubscription Function(
  String name,
  Map<String, dynamic> args,
);

/// A live subscription to one page query consumed by [ConvexPaginatedQuery].
///
/// Internal plumbing produced by a [PageSubscriber]. [results] emits the
/// page's [StoredQueryResult] each time it changes; [cancel] tears the
/// subscription down.
abstract interface class PageSubscription {
  /// The live results for this page (success values carry the raw
  /// `PaginationResult` map).
  Stream<StoredQueryResult> get results;

  /// Cancels the underlying page subscription.
  void cancel();
}

/// A live, reactive paginated query: a growing, gapless list of page
/// subscriptions exposed as a single aggregated, reactive result.
///
/// Each page is an ordinary query subscription to the same function with
/// `paginationOpts: {numItems, cursor}` in its args (the first page uses
/// `cursor: null`); the next page is chained from the previous page's
/// `continueCursor`. Because each page is a normal subscription, loaded pages
/// update reactively when their underlying data changes, and the server keeps
/// page boundaries stable across reconnects via the query journals dartvex
/// already stores — so there are no gaps or duplicates at page boundaries.
///
/// Pages whose result reports a `splitCursor` (with `pageStatus`
/// `SplitRecommended`/`SplitRequired`, or once a page grows past twice the page
/// size) are transparently re-split into two bounded page subscriptions and
/// swapped in atomically once both halves have loaded, keeping each page query
/// a manageable size without ever exposing a gap or duplicate.
///
/// Mirrors the official client's `PaginatedQueryClient`. Obtain one from
/// `ConvexClient.paginatedQuery` and [cancel] it when done.
class ConvexPaginatedQuery {
  /// Creates a paginated query that loads its first page immediately.
  ///
  /// [subscribe] opens a live subscription per page, [name] is the paginated
  /// query function, [args] are the query arguments (without `paginationOpts`),
  /// and [pageSize] is the number of items requested per page.
  ConvexPaginatedQuery({
    required PageSubscriber subscribe,
    required String name,
    required Map<String, dynamic> args,
    int pageSize = 20,
  })  : _subscribe = subscribe,
        _name = name,
        _args = Map<String, dynamic>.from(args),
        _pageSize = pageSize {
    _current = const ConvexPaginatedResult(
      results: <dynamic>[],
      status: ConvexPaginationStatus.loadingFirstPage,
      isDone: false,
    );
    _addPage(cursor: null, numItems: _pageSize);
  }

  final PageSubscriber _subscribe;
  final String _name;
  final Map<String, dynamic> _args;
  final int _pageSize;

  final StreamController<ConvexPaginatedResult> _controller =
      StreamController<ConvexPaginatedResult>.broadcast(sync: true);

  // Active pages, in result order; their items make up a gapless sequence.
  final List<_Page> _pages = <_Page>[];
  // Pages being split: the original stays active until both halves have loaded.
  final List<_Split> _splits = <_Split>[];

  late ConvexPaginatedResult _current;
  bool _disposed = false;

  /// The reactive stream of aggregated results, one per change.
  ///
  /// A broadcast stream that does not replay; read [current] for the latest
  /// snapshot when first listening.
  Stream<ConvexPaginatedResult> get stream => _controller.stream;

  /// The latest aggregated snapshot, available synchronously.
  ConvexPaginatedResult get current => _current;

  /// The current pagination status (shorthand for `current.status`).
  ConvexPaginationStatus get status => _current.status;

  /// Whether the query is fully loaded (shorthand for `current.isDone`).
  bool get isDone => _current.isDone;

  /// Loads the next page, returning whether loading was actually started.
  ///
  /// Returns `false` (a no-op) when the query is disposed, the last page is
  /// still loading (concurrent loads are not allowed), or the query is already
  /// exhausted. [numItems] overrides the page size for the new page.
  bool loadMore([int? numItems]) {
    if (_disposed || _pages.isEmpty) {
      return false;
    }
    final data = _pages.last.data;
    if (data == null) {
      // The last page is still loading (or errored); don't stack page loads.
      return false;
    }
    if (data.isDone) {
      return false;
    }
    _addPage(cursor: data.continueCursor, numItems: numItems ?? _pageSize);
    _emit();
    return true;
  }

  /// Cancels every page subscription and closes the result stream.
  void cancel() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final page in _pages) {
      page.dispose();
    }
    for (final split in _splits) {
      split.first.dispose();
      split.second.dispose();
    }
    _pages.clear();
    _splits.clear();
    unawaited(_controller.close());
  }

  void _addPage({required String? cursor, required int numItems}) {
    _pages.add(_openPage(cursor: cursor, numItems: numItems));
  }

  _Page _openPage({
    required String? cursor,
    required int numItems,
    bool bounded = false,
    String? endCursor,
  }) {
    final paginationOpts = <String, dynamic>{
      'numItems': numItems,
      'cursor': cursor,
      // A split half is bounded by an explicit endCursor (which may be null,
      // meaning "to the end"); a normal page omits it entirely.
      if (bounded) 'endCursor': endCursor,
    };
    final pageArgs = <String, dynamic>{
      ..._args,
      'paginationOpts': paginationOpts,
    };
    final subscription = _subscribe(_name, pageArgs);
    final page = _Page(startCursor: cursor, subscription: subscription);
    page.streamSub = subscription.results.listen(
      (result) => _onPageResult(page, result),
    );
    return page;
  }

  void _onPageResult(_Page page, StoredQueryResult result) {
    if (_disposed) {
      return;
    }
    switch (result) {
      case StoredQuerySuccess(:final value):
        final parsed = _parsePage(value);
        if (parsed == null) {
          page.data = null;
          page.error = const ConvexException(
            'Invalid paginated query result: expected a PaginationResult '
            'object with page and isDone fields',
          );
        } else {
          page.data = parsed;
          page.error = null;
        }
      case StoredQueryError(:final message, :final data, :final logLines):
        page.data = null;
        page.error = ConvexException(message, data: data, logLines: logLines);
    }
    _reconcileSplits();
    _emit();
  }

  void _reconcileSplits() {
    // Complete any split whose two halves have both loaded a result: swap the
    // original page out for the two halves atomically so the aggregated result
    // never shows a gap or duplicate mid-split.
    final completed = _splits
        .where((split) => split.first.data != null && split.second.data != null)
        .toList(growable: false);
    for (final split in completed) {
      final index = _pages.indexOf(split.original);
      if (index != -1) {
        _pages
            .replaceRange(index, index + 1, <_Page>[split.first, split.second]);
        split.original.dispose();
      } else {
        // The original is no longer active (e.g. the query was reset); discard
        // the half subscriptions instead of promoting them.
        split.first.dispose();
        split.second.dispose();
      }
      _splits.remove(split);
    }

    // Start splits for active pages the server recommends splitting, or that
    // have grown past twice the page size.
    for (final page in List<_Page>.of(_pages)) {
      if (_splits.any((split) => split.original == page)) {
        continue;
      }
      final data = page.data;
      if (data == null) {
        continue;
      }
      final splitCursor = data.splitCursor;
      if (splitCursor == null) {
        continue;
      }
      final shouldSplit = data.pageStatus == 'SplitRecommended' ||
          data.pageStatus == 'SplitRequired' ||
          data.page.length > _pageSize * 2;
      if (!shouldSplit) {
        continue;
      }
      // The first half keeps the page's own start cursor (correct for any page,
      // not just the first) and ends at the split cursor; the second half runs
      // from the split cursor to the page's original end.
      final first = _openPage(
        cursor: page.startCursor,
        numItems: _pageSize,
        bounded: true,
        endCursor: splitCursor,
      );
      final second = _openPage(
        cursor: splitCursor,
        numItems: _pageSize,
        bounded: true,
        endCursor: data.continueCursor,
      );
      _splits.add(_Split(original: page, first: first, second: second));
    }
  }

  void _emit() {
    if (_disposed) {
      return;
    }
    final results = <dynamic>[];
    var hasLoading = false;
    var lastPageIsDone = false;
    Object? firstError;
    for (final page in _pages) {
      if (page.error != null) {
        firstError = page.error;
        break;
      }
      final data = page.data;
      if (data == null) {
        // Stop at the first not-yet-loaded page so the aggregated result stays a
        // gapless prefix: concatenating later, already-loaded pages here would
        // expose a hole where this page's items belong.
        hasLoading = true;
        break;
      }
      results.addAll(data.page);
      lastPageIsDone = data.isDone;
    }

    final ConvexPaginationStatus status;
    if (firstError != null) {
      status = ConvexPaginationStatus.error;
    } else if (hasLoading) {
      status = results.isEmpty
          ? ConvexPaginationStatus.loadingFirstPage
          : ConvexPaginationStatus.loadingMore;
    } else if (lastPageIsDone) {
      status = ConvexPaginationStatus.exhausted;
    } else {
      status = ConvexPaginationStatus.canLoadMore;
    }

    _current = ConvexPaginatedResult(
      results: List<dynamic>.unmodifiable(results),
      status: status,
      isDone: status == ConvexPaginationStatus.exhausted,
      error: firstError,
    );
    if (!_controller.isClosed) {
      _controller.add(_current);
    }
  }

  static _PageData? _parsePage(Object? value) {
    if (value is! Map) {
      return null;
    }
    final map = value.cast<String, dynamic>();
    final page = map['page'];
    final isDone = map['isDone'];
    if (page is! List || isDone is! bool) {
      return null;
    }
    return _PageData(
      page: List<dynamic>.from(page),
      continueCursor: map['continueCursor'] as String?,
      isDone: isDone,
      splitCursor: map['splitCursor'] as String?,
      pageStatus: map['pageStatus'] as String?,
    );
  }
}

/// One active or being-split page subscription and its latest parsed result.
class _Page {
  _Page({required this.startCursor, required this.subscription});

  /// The cursor this page starts at (`null` for the first page).
  final String? startCursor;
  final PageSubscription subscription;
  late final StreamSubscription<StoredQueryResult> streamSub;

  /// The latest successful page result, or `null` while loading or errored.
  _PageData? data;

  /// The latest error, or `null` while loading or successful.
  Object? error;

  void dispose() {
    streamSub.cancel();
    subscription.cancel();
  }
}

/// The parsed fields of a successful `PaginationResult` page.
class _PageData {
  _PageData({
    required this.page,
    required this.continueCursor,
    required this.isDone,
    required this.splitCursor,
    required this.pageStatus,
  });

  final List<dynamic> page;
  final String? continueCursor;
  final bool isDone;
  final String? splitCursor;
  final String? pageStatus;
}

/// An in-progress split of [original] into [first] and [second] halves.
class _Split {
  _Split({required this.original, required this.first, required this.second});

  final _Page original;
  final _Page first;
  final _Page second;
}
