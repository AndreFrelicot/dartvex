import 'dart:async';

import '../exceptions.dart';
import '../values/json_codec.dart';
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
    this.hasPendingWrites = false,
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

  /// Whether optimistic writes currently affect any loaded page in [results]
  /// (for example an optimistically inserted item that the server has not
  /// confirmed yet). Mirrors `QuerySuccess.hasPendingWrites`.
  final bool hasPendingWrites;
}

/// Opens a live subscription to a single page query.
///
/// Plumbing for [ConvexPaginatedQuery] (exported, together with
/// [StoredQueryResult] and its subclasses, so fakes and custom sources can back
/// a paginated query without importing Dartvex internals): it calls this once per page (and once
/// per split half) with the same udf path and the page's args (including
/// `paginationOpts`). `ConvexClient` supplies an implementation backed by a
/// normal query subscription, so every page flows through the same sync,
/// optimistic-overlay, and reconnect machinery as any other query.
typedef PageSubscriber = PageSubscription Function(
  String name,
  Map<String, dynamic> args,
);

/// Reads the current local result for a page query, if one is already known.
typedef PageInitialResultReader = StoredQueryResult? Function(
  String name,
  Map<String, dynamic> args,
);

/// A live subscription to one page query consumed by [ConvexPaginatedQuery].
///
/// Internal plumbing produced by a [PageSubscriber]. [results] emits the
/// page's [StoredQueryResult] each time it changes, including local loading
/// markers from optimistic clears; [cancel] tears the subscription down.
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
  /// query function, [args] are the query arguments (without `paginationOpts`;
  /// a `paginationOpts` entry in [args] is replaced by the one each page
  /// sends), and [pageSize] is the number of items requested per page.
  ///
  /// [readInitialResult], when given, seeds a page synchronously with an
  /// already known local result (for example the warm cache of an earlier
  /// subscription), so a remounted list does not flash a loading state. A
  /// seeded page is *provisional* until its live subscription delivers a
  /// result: [loadMore] does not chain the next page from a provisional
  /// page's cursor, because a stale cursor could leave a permanent gap or
  /// duplicate items.
  ///
  /// Throws an [ArgumentError] when [pageSize] is less than 1.
  ConvexPaginatedQuery({
    required PageSubscriber subscribe,
    PageInitialResultReader? readInitialResult,
    required String name,
    required Map<String, dynamic> args,
    int pageSize = 20,
  })  : _subscribe = subscribe,
        _readInitialResult = readInitialResult,
        _name = name,
        _args = canonicalizeConvexArgs(args),
        _pageSize = _checkNumItems(pageSize, 'pageSize') {
    _current = const ConvexPaginatedResult(
      results: <dynamic>[],
      status: ConvexPaginationStatus.loadingFirstPage,
      isDone: false,
    );
    _addPage(cursor: null, numItems: _pageSize);
  }

  final PageSubscriber _subscribe;
  final PageInitialResultReader? _readInitialResult;
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

  // Re-entrancy guard for the synchronous broadcast controller: a snapshot
  // produced while a snapshot is being delivered (loadMore()/reset() called
  // from a stream listener) is delivered right after the outer delivery
  // returns, and a cancel() from a listener closes the stream once it unwinds.
  bool _delivering = false;
  bool _pendingDelivery = false;
  bool _closeAfterDelivery = false;

  // Incremented by every [reset]; lets a reset notice that a listener started
  // a newer one during its synchronous delivery.
  int _resetGeneration = 0;

  /// `paginationOpts.id` of the current generation, set after a [reset] so the
  /// restarted pages get fresh query tokens (and journals) instead of
  /// re-attaching to a subscription that still holds an invalid cursor.
  int? _paginationId;
  static int _nextPaginationId = 1;

  static int _checkNumItems(int value, String name) {
    if (value < 1) {
      throw ArgumentError.value(value, name, 'must be at least 1');
    }
    return value;
  }

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
  /// Returns `false` (a no-op) when the query is disposed (or its client was
  /// closed), the aggregate is in an error state, the last page is still
  /// loading (concurrent loads are not allowed), the last page only holds a
  /// provisional seed that its live subscription has not confirmed yet, or the
  /// query is already exhausted. [numItems] overrides the page size for the
  /// new page and must be at least 1.
  ///
  /// Safe to call from a [stream] listener.
  bool loadMore([int? numItems]) {
    if (numItems != null) {
      _checkNumItems(numItems, 'numItems');
    }
    if (_disposed || _pages.isEmpty) {
      return false;
    }
    if (_current.status == ConvexPaginationStatus.error) {
      return false;
    }
    final last = _pages.last;
    final data = last.data;
    if (data == null) {
      // The last page is still loading (or errored); don't stack page loads.
      return false;
    }
    if (last.provisional) {
      // Seeded from a possibly stale local result: wait for the live result
      // before chaining from its continueCursor.
      return false;
    }
    if (data.isDone) {
      return false;
    }
    try {
      _addPage(cursor: data.continueCursor, numItems: numItems ?? _pageSize);
    } on ConvexException {
      // The client was closed: the page subscription cannot be opened.
      return false;
    }
    _emit();
    return true;
  }

  /// Restarts pagination from the first page.
  ///
  /// Disposes every page and in-progress split, then reloads the first page
  /// with fresh query subscriptions (tagged with a new `paginationOpts.id`, as
  /// the official client does, so they cannot re-attach to stale cursors or
  /// journals). Called automatically when a loaded page fails with an
  /// `InvalidCursor` error — typically after a deploy changed the paginated
  /// query's index or filter. A no-op once cancelled. Safe to call from a
  /// [stream] listener.
  void reset() {
    if (_disposed) {
      return;
    }
    final generation = ++_resetGeneration;
    _paginationId = _nextPaginationId++;
    _disposePagesAndSplits();
    _current = const ConvexPaginatedResult(
      results: <dynamic>[],
      status: ConvexPaginationStatus.loadingFirstPage,
      isDone: false,
    );
    _deliver();
    // Delivery is synchronous: a listener may have cancelled the query, or
    // started a newer reset, while the loading state was being delivered.
    // Opening a page now would leak a live subscription (or duplicate the
    // newer reset's first page).
    if (_disposed || generation != _resetGeneration) {
      return;
    }
    try {
      _addPage(cursor: null, numItems: _pageSize);
    } on ConvexException catch (error) {
      _current = ConvexPaginatedResult(
        results: const <dynamic>[],
        status: ConvexPaginationStatus.error,
        isDone: false,
        error: error,
      );
      _deliver();
    }
  }

  /// Cancels every page subscription and closes the result stream.
  ///
  /// Safe to call from a [stream] listener: the stream then closes as soon as
  /// the current delivery returns.
  void cancel() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _disposePagesAndSplits();
    if (_delivering) {
      _closeAfterDelivery = true;
    } else {
      unawaited(_controller.close());
    }
  }

  void _disposePagesAndSplits() {
    for (final page in _pages) {
      page.dispose();
    }
    for (final split in _splits) {
      split.first.dispose();
      split.second.dispose();
    }
    _pages.clear();
    _splits.clear();
  }

  void _addPage({required String? cursor, required int numItems}) {
    final page = _openPage(cursor: cursor, numItems: numItems);
    _pages.add(page);
    _consumeInitialResult(page);
  }

  void _consumeInitialResult(_Page page) {
    final initial = page.initialResult;
    if (initial != null) {
      page.initialResult = null;
      page.provisional = true;
      page.seed = initial;
      _onPageResult(page, initial, fromSeed: true);
    }
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
      if (_paginationId != null) 'id': _paginationId,
    };
    final pageArgs = <String, dynamic>{
      ..._args,
      'paginationOpts': paginationOpts,
    };
    final subscription = _subscribe(_name, pageArgs);
    final page = _Page(
      startCursor: cursor,
      subscription: subscription,
      initialResult: _readInitialResult?.call(_name, pageArgs),
    );
    page.streamSub = subscription.results.listen(
      (result) => _onPageResult(page, result),
      onError: (Object error, StackTrace stackTrace) {
        _onPageStreamError(page, error);
      },
      onDone: () => _onPageStreamDone(page),
    );
    return page;
  }

  /// A page stream only completes on its own when the client closed it (our
  /// own teardown cancels the listener first): the query is terminal, so
  /// report the error, then close the stream instead of freezing.
  void _onPageStreamDone(_Page page) {
    if (_disposed) {
      return;
    }
    page.data = null;
    page.error = const ConvexException('ConvexClient has been disposed');
    if (!_pages.contains(page)) {
      // A split half: surface the terminal error on the aggregate anyway.
      for (final active in _pages) {
        active.data = null;
        active.error = page.error;
      }
    }
    _emit();
    cancel();
  }

  void _onPageStreamError(_Page page, Object error) {
    if (_disposed) {
      return;
    }
    _cancelSplitsForOriginal(page);
    page.data = null;
    page.error = error;
    _reconcileSplits();
    _emit();
  }

  void _onPageResult(
    _Page page,
    StoredQueryResult result, {
    bool fromSeed = false,
  }) {
    if (_disposed) {
      return;
    }
    if (!fromSeed) {
      final seed = page.seed;
      page.seed = null;
      page.provisional = false;
      if (seed != null && _isSameResult(seed, result)) {
        // The live subscription confirmed the seeded value (for example the
        // result of an identical active subscription): nothing changed, only
        // cursor chaining is now allowed.
        return;
      }
    }
    if (result is StoredQueryError &&
        _isInvalidCursor(result) &&
        _pages.contains(page) &&
        (page.startCursor != null || page.hadSuccess)) {
      // The page's cursor or journal no longer matches the database query
      // (typically after a deploy changed its index or filter): restart
      // pagination instead of pinning the list to an error. Mirrors the
      // official usePaginatedQuery. A brand-new first page that fails this
      // way is surfaced as an error instead, so a reset cannot loop.
      reset();
      return;
    }
    final parsedSuccess =
        result is StoredQuerySuccess ? _parsePage(result.value) : null;
    if (!_splitsStillValid(page, parsedSuccess)) {
      _cancelSplitsForOriginal(page);
    }
    switch (result) {
      case StoredQuerySuccess(:final hasPendingWrites):
        final parsed = parsedSuccess;
        if (parsed == null) {
          page.data = null;
          page.error = const ConvexException(
            'Invalid paginated query result: expected a PaginationResult '
            'object with page, isDone, and continueCursor fields',
          );
        } else {
          page.data = parsed..hasPendingWrites = hasPendingWrites;
          page.error = null;
          page.hadSuccess = true;
          // A fresh successful result clears any prior split failure so an
          // oversized page can be re-split once its data settles again.
          page.splitFailed = false;
        }
      case StoredQueryLoading():
        page.data = null;
        page.error = null;
      case StoredQueryError(:final message, :final data, :final logLines):
        page.data = null;
        page.error = ConvexException(message, data: data, logLines: logLines);
    }
    _reconcileSplits();
    _emit();
  }

  /// An in-progress split of [page] stays valid while the page keeps the range
  /// it had when the split started: the halves are bounded by the page's start
  /// cursor, the split cursor, and that end cursor, so they still cover the
  /// page gaplessly. Cancelling it on every reactive update would let a busy
  /// page churn subscriptions and never finish splitting. Mirrors the official
  /// client, which keeps an ongoing split until both halves load.
  bool _splitsStillValid(_Page page, _PageData? parsed) {
    for (final split in _splits) {
      if (split.original != page) {
        continue;
      }
      if (parsed == null || parsed.continueCursor != split.endCursor) {
        return false;
      }
    }
    return true;
  }

  static bool _isSameResult(StoredQueryResult a, StoredQueryResult b) {
    if (a is StoredQuerySuccess && b is StoredQuerySuccess) {
      return identical(a.value, b.value) &&
          a.hasPendingWrites == b.hasPendingWrites;
    }
    if (a is StoredQueryError && b is StoredQueryError) {
      return a.message == b.message && identical(a.data, b.data);
    }
    return a is StoredQueryLoading && b is StoredQueryLoading;
  }

  static bool _isInvalidCursor(StoredQueryError error) {
    if (error.message.contains('InvalidCursor')) {
      return true;
    }
    final data = error.data;
    return data is Map && data['paginationError'] == 'InvalidCursor';
  }

  void _cancelSplitsForOriginal(_Page page) {
    final staleSplits = _splits
        .where((split) => split.original == page)
        .toList(growable: false);
    for (final split in staleSplits) {
      split.first.dispose();
      split.second.dispose();
      _splits.remove(split);
    }
  }

  void _reconcileSplits() {
    // A split is only an internal optimization to keep page queries small; the
    // original page covers the same range. If either half fails, tear both
    // halves down and fall back to the original (un-split) page instead of
    // surfacing an error, and mark it so the split is not retried until the
    // original produces a fresh successful result.
    final failed = _splits
        .where(
            (split) => split.first.error != null || split.second.error != null)
        .toList(growable: false);
    for (final split in failed) {
      split.original.splitFailed = true;
      split.first.dispose();
      split.second.dispose();
      _splits.remove(split);
    }

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
      if (page.error != null || page.splitFailed) {
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
      final split = _Split(
        original: page,
        first: first,
        second: second,
        endCursor: data.continueCursor,
      );
      _splits.add(split);
      _consumeInitialResult(first);
      if (_splits.contains(split)) {
        _consumeInitialResult(second);
      }
    }
  }

  void _emit() {
    if (_disposed) {
      return;
    }
    final results = <dynamic>[];
    var hasLoading = false;
    var lastPageIsDone = false;
    var hasPendingWrites = false;
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
      hasPendingWrites = hasPendingWrites || data.hasPendingWrites;
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

    final previous = _current;
    if (previous.status == status &&
        identical(previous.error, firstError) &&
        previous.hasPendingWrites == hasPendingWrites &&
        _sameItems(previous.results, results)) {
      // Nothing visible changed (a split half loaded while its sibling is
      // still loading, a split swapped in the same items, a duplicate seed):
      // skip the emission so listeners do not rebuild every item.
      return;
    }
    _current = ConvexPaginatedResult(
      results: List<dynamic>.unmodifiable(results),
      status: status,
      isDone: status == ConvexPaginationStatus.exhausted,
      error: firstError,
      hasPendingWrites: hasPendingWrites,
    );
    _deliver();
  }

  static bool _sameItems(List<dynamic> a, List<dynamic> b) {
    if (a.length != b.length) {
      return false;
    }
    for (var index = 0; index < a.length; index += 1) {
      if (!identical(a[index], b[index])) {
        return false;
      }
    }
    return true;
  }

  /// Delivers [_current] on the synchronous broadcast controller, deferring a
  /// re-entrant delivery until the outer one returns (see [_delivering]).
  void _deliver() {
    if (_delivering) {
      _pendingDelivery = true;
      return;
    }
    _delivering = true;
    try {
      do {
        _pendingDelivery = false;
        if (!_controller.isClosed) {
          _controller.add(_current);
        }
      } while (_pendingDelivery && !_disposed);
    } finally {
      _delivering = false;
    }
    if (_closeAfterDelivery) {
      _closeAfterDelivery = false;
      unawaited(_controller.close());
    }
  }

  static _PageData? _parsePage(Object? value) {
    if (value is! Map) {
      return null;
    }
    final map = value.cast<String, dynamic>();
    final page = map['page'];
    final isDone = map['isDone'];
    final continueCursor = map['continueCursor'];
    final splitCursor = map['splitCursor'];
    final pageStatus = map['pageStatus'];
    if (page is! List ||
        isDone is! bool ||
        continueCursor is! String ||
        (splitCursor != null && splitCursor is! String) ||
        (pageStatus != null && pageStatus is! String)) {
      return null;
    }
    return _PageData(
      page: List<dynamic>.from(page),
      continueCursor: continueCursor,
      isDone: isDone,
      splitCursor: splitCursor,
      pageStatus: pageStatus,
    );
  }
}

/// One active or being-split page subscription and its latest parsed result.
class _Page {
  _Page({
    required this.startCursor,
    required this.subscription,
    this.initialResult,
  });

  /// The cursor this page starts at (`null` for the first page).
  final String? startCursor;
  final PageSubscription subscription;
  StoredQueryResult? initialResult;
  late final StreamSubscription<StoredQueryResult> streamSub;

  /// The latest successful page result, or `null` while loading or errored.
  _PageData? data;

  /// The latest error, or `null` while loading or successful.
  Object? error;

  /// Whether [data] came from a local seed that the page's live subscription
  /// has not confirmed yet; [ConvexPaginatedQuery.loadMore] does not chain
  /// from a provisional page's cursor.
  bool provisional = false;

  /// The consumed seed, kept until the first live result so an identical
  /// re-delivery of it can be recognized and skipped.
  StoredQueryResult? seed;

  /// Whether this page ever produced a successful result.
  bool hadSuccess = false;

  /// Set when an attempt to split this page failed. Suppresses immediate
  /// re-splitting until the page produces a fresh successful result, so a
  /// transient split-half failure falls back to this (un-split) page instead
  /// of looping or pinning the whole query to an error.
  bool splitFailed = false;

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
  final String continueCursor;
  final bool isDone;
  final String? splitCursor;
  final String? pageStatus;
  bool hasPendingWrites = false;
}

/// An in-progress split of [original] into [first] and [second] halves.
class _Split {
  _Split({
    required this.original,
    required this.first,
    required this.second,
    required this.endCursor,
  });

  final _Page original;
  final _Page first;
  final _Page second;

  /// The original page's continueCursor when the split started; the second
  /// half is bounded by it.
  final String endCursor;
}
