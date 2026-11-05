import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dartvex/dartvex.dart' as convex;
import 'package:flutter/widgets.dart';

import 'args.dart';
import 'provider.dart';
import 'runtime_client.dart';
import 'safe_rebuild.dart';
import 'snapshot.dart';

/// Status of a paginated query.
enum PaginationStatus {
  /// Loading the first page.
  loading,

  /// Idle — data loaded, more pages available.
  idle,

  /// Loading additional pages.
  loadingMore,

  /// All pages have been loaded.
  allLoaded,

  /// An error occurred.
  error,
}

/// Builder callback for [PaginatedQueryBuilder].
typedef PaginatedQueryWidgetBuilder<T> =
    Widget Function(
      BuildContext context,
      List<T> items,
      VoidCallback loadMore,
      PaginationStatus status,
    );

/// Builder used by [PaginatedQueryBuilder.errorBuilder] when the query fails.
///
/// [error] is the server or transport error of the failing page, or a
/// [ConvexDecodeException] when an item could not be decoded. [items] are the
/// items decoded before the failure, and [retry] restarts the query from the
/// first page.
typedef PaginatedQueryErrorWidgetBuilder<T> =
    Widget Function(
      BuildContext context,
      Object error,
      List<T> items,
      VoidCallback retry,
    );

/// Widget that manages cursor-based pagination with Convex.
///
/// Backed by the core reactive pagination engine (`ConvexClient.paginatedQuery`)
/// via [ConvexRuntimeClient.paginatedQuery]: each page is a live query
/// subscription, so loaded pages update reactively as their data changes and
/// stay gapless at page boundaries. `loadMore` extends the list using the last
/// page's cursor; changing [query], [args], [pageSize], or [client] resets the
/// query, while changing [fromJson] re-maps the already-loaded items in place
/// (so an inline closure is safe — parent rebuilds do not reset pagination —
/// but it re-decodes every loaded item on each parent rebuild; prefer a stable
/// reference such as `Message.fromJson` when the parent rebuilds often).
///
/// Items whose raw value did not change between emissions are not decoded
/// again. When the query fails, [errorBuilder] (if provided) receives the
/// error object; decode failures are also reported to
/// [FlutterError.reportError]. `loadMore` may be called from anywhere,
/// including an `itemBuilder` during layout.
///
/// ```dart
/// PaginatedQueryBuilder<Message>(
///   query: 'messages:list',
///   pageSize: 20,
///   fromJson: Message.fromJson,
///   builder: (context, items, loadMore, status) {
///     return ListView.builder(
///       itemCount: items.length + (status == PaginationStatus.allLoaded ? 0 : 1),
///       itemBuilder: (_, i) => i < items.length
///         ? MessageTile(items[i])
///         : TextButton(onPressed: loadMore, child: Text('Load more')),
///     );
///   },
///   errorBuilder: (context, error, items, retry) => TextButton(
///     onPressed: retry,
///     child: Text('Failed: $error — tap to retry'),
///   ),
/// )
/// ```
class PaginatedQueryBuilder<T> extends StatefulWidget {
  /// Creates a paginated query builder.
  const PaginatedQueryBuilder({
    super.key,
    required this.query,
    required this.builder,
    required this.fromJson,
    this.args,
    this.pageSize = 20,
    this.client,
    this.errorBuilder,
  });

  /// The paginated Convex query function name.
  final String query;

  /// Additional arguments merged with `paginationOpts`.
  final Map<String, dynamic>? args;

  /// Number of items per page.
  final int pageSize;

  /// Builder function receiving the accumulated items and controls.
  final PaginatedQueryWidgetBuilder<T> builder;

  /// Deserializer for individual items.
  ///
  /// A throwing deserializer (or a page item that is not a JSON object) puts
  /// the builder in [PaginationStatus.error] with a [ConvexDecodeException].
  final T Function(Map<String, dynamic>) fromJson;

  /// Optional runtime client override. If omitted, uses [ConvexProvider.of].
  final ConvexRuntimeClient? client;

  /// Optional builder used instead of [builder] while the status is
  /// [PaginationStatus.error], with the error object and a retry callback.
  /// Without it, [builder] receives [PaginationStatus.error].
  final PaginatedQueryErrorWidgetBuilder<T>? errorBuilder;

  @override
  State<PaginatedQueryBuilder<T>> createState() =>
      _PaginatedQueryBuilderState<T>();
}

class _PaginatedQueryBuilderState<T> extends State<PaginatedQueryBuilder<T>>
    with ConvexSafeRebuild<PaginatedQueryBuilder<T>> {
  static const DeepCollectionEquality _deepEquality = DeepCollectionEquality();

  ConvexRuntimeClient? _client;
  ConvexRuntimePaginatedQuery? _query;
  StreamSubscription<convex.ConvexPaginatedResult>? _subscription;
  Map<String, dynamic>? _subscribedArgs;
  int _queryGeneration = 0;

  List<T> _items = List<T>.unmodifiable(const <Never>[]);
  PaginationStatus _status = PaginationStatus.loading;
  Object? _error;
  convex.ConvexPaginatedResult? _lastResult;

  /// Decoded items keyed by their raw map instance. The core reuses the item
  /// maps of unchanged pages, so an emission only decodes what changed.
  /// Replaced whenever [PaginatedQueryBuilder.fromJson] changes.
  Expando<_Decoded<T>> _decodedItems = Expando<_Decoded<T>>();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = widget.client ?? ConvexProvider.of(context);
    if (_client != client || _query == null) {
      _client = client;
      _start();
    }
  }

  @override
  void didUpdateWidget(covariant PaginatedQueryBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final client = widget.client ?? ConvexProvider.of(context);
    if (oldWidget.query != widget.query ||
        oldWidget.pageSize != widget.pageSize ||
        _client != client ||
        !_deepEquality.equals(
          _subscribedArgs,
          widget.args ?? const <String, dynamic>{},
        )) {
      _client = client;
      _start();
    } else if (oldWidget.fromJson != widget.fromJson) {
      // The item mapper is not part of the query identity — an inline closure
      // differs on every parent rebuild, and restarting would drop every
      // loaded page. Re-map the current result in place instead; a rebuild is
      // already scheduled, so plain assignment is enough.
      _decodedItems = Expando<_Decoded<T>>();
      final result = _lastResult;
      if (result != null) {
        _applyResult(result);
      }
    }
  }

  /// (Re)starts the query. Called from lifecycle callbacks (always followed
  /// by a build) or inside [applyAndRebuild], so state is assigned directly.
  void _start() {
    final generation = ++_queryGeneration;
    _subscription?.cancel();
    _subscription = null;
    _query?.cancel();
    _query = null;
    _lastResult = null;
    _error = null;
    _decodedItems = Expando<_Decoded<T>>();
    final ConvexRuntimePaginatedQuery query;
    try {
      final argsSnapshot = snapshotConvexArgs(widget.args);
      _subscribedArgs = argsSnapshot;
      query = _client!.paginatedQuery(
        widget.query,
        argsSnapshot,
        pageSize: widget.pageSize,
      );
    } catch (error) {
      // A disposed client throws synchronously; show the error state instead
      // of an ErrorWidget. With no query, the next dependency or client change
      // (or the error builder's retry) tries again.
      _items = List<T>.unmodifiable(const <Never>[]);
      _status = PaginationStatus.error;
      _error = error;
      return;
    }
    _query = query;
    // Seed synchronously from the current snapshot (a build is already pending
    // from this lifecycle callback), then update reactively from the stream.
    _items = List<T>.unmodifiable(const <Never>[]);
    _applyResult(query.current);
    _subscription = query.stream.listen(
      (result) {
        if (generation != _queryGeneration || !mounted) {
          return;
        }
        // Synchronous core stream: loadMore() from an itemBuilder emits during
        // layout, so the rebuild may be deferred to after the frame.
        applyAndRebuild(() => _applyResult(result));
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _queryGeneration || !mounted) {
          return;
        }
        applyAndRebuild(() {
          _lastResult = convex.ConvexPaginatedResult(
            results: _lastResult?.results ?? const <dynamic>[],
            status: convex.ConvexPaginationStatus.error,
            isDone: false,
            error: error,
          );
          _status = PaginationStatus.error;
          _error = error;
        });
      },
    );
  }

  /// Maps [result] into the items, status and error. A decode failure keeps
  /// the current items, switches to the error status, and is reported.
  void _applyResult(convex.ConvexPaginatedResult result) {
    _lastResult = result;
    try {
      _items = _mapItems(result);
      _status = _mapStatus(result.status);
      _error = _status == PaginationStatus.error
          ? (result.error ??
                StateError(
                  'Paginated query "${widget.query}" '
                  'failed',
                ))
          : null;
    } on ConvexDecodeException catch (error) {
      _status = PaginationStatus.error;
      _error = error;
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error.error,
          stack: error.stackTrace,
          library: 'dartvex_flutter',
          context: ErrorDescription(
            'while decoding an item of PaginatedQueryBuilder '
            '"${widget.query}"',
          ),
        ),
      );
    }
  }

  List<T> _mapItems(convex.ConvexPaginatedResult result) {
    final decodedItems = _decodedItems;
    final fromJson = widget.fromJson;
    final items = <T>[];
    for (final item in result.results) {
      final memoizable = item is Map;
      if (memoizable) {
        final cached = decodedItems[item];
        if (cached != null) {
          items.add(cached.value);
          continue;
        }
      }
      final T decoded;
      try {
        decoded = fromJson(item as Map<String, dynamic>);
      } catch (error, stackTrace) {
        throw ConvexDecodeException(error, stackTrace, value: item);
      }
      if (memoizable) {
        decodedItems[item] = _Decoded<T>(decoded);
      }
      items.add(decoded);
    }
    return List<T>.unmodifiable(items);
  }

  static PaginationStatus _mapStatus(convex.ConvexPaginationStatus status) {
    switch (status) {
      case convex.ConvexPaginationStatus.loadingFirstPage:
        return PaginationStatus.loading;
      case convex.ConvexPaginationStatus.loadingMore:
        return PaginationStatus.loadingMore;
      case convex.ConvexPaginationStatus.canLoadMore:
        return PaginationStatus.idle;
      case convex.ConvexPaginationStatus.exhausted:
        return PaginationStatus.allLoaded;
      case convex.ConvexPaginationStatus.error:
        return PaginationStatus.error;
    }
  }

  void _loadMore() {
    // The core engine ignores the call while a page is loading or once the
    // query is exhausted. It emits synchronously — possibly during a build or
    // layout pass, when an itemBuilder calls loadMore for the last row — and
    // the stream listener defers its rebuild in that case.
    _query?.loadMore();
  }

  void _retry() {
    if (_client == null) {
      return;
    }
    applyAndRebuild(_start);
  }

  @override
  void dispose() {
    _queryGeneration += 1;
    _subscription?.cancel();
    _query?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final errorBuilder = widget.errorBuilder;
    final error = _error;
    if (errorBuilder != null &&
        _status == PaginationStatus.error &&
        error != null) {
      return errorBuilder(context, error, _items, _retry);
    }
    return widget.builder(context, _items, _loadMore, _status);
  }
}

/// Wraps a decoded item so a nullable `T` can be memoized in an [Expando].
class _Decoded<T> {
  const _Decoded(this.value);

  final T value;
}
