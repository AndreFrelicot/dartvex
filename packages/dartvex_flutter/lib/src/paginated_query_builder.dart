import 'dart:async';

import 'package:collection/collection.dart';
import 'package:dartvex/dartvex.dart' as convex;
import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';

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
typedef PaginatedQueryWidgetBuilder<T> = Widget Function(
  BuildContext context,
  List<T> items,
  VoidCallback loadMore,
  PaginationStatus status,
);

/// Widget that manages cursor-based pagination with Convex.
///
/// Backed by the core reactive pagination engine (`ConvexClient.paginatedQuery`)
/// via [ConvexRuntimeClient.paginatedQuery]: each page is a live query
/// subscription, so loaded pages update reactively as their data changes and
/// stay gapless at page boundaries. `loadMore` extends the list using the last
/// page's cursor; changing [query], [args], [pageSize], or [client] resets the
/// query, while changing [fromJson] re-maps the already-loaded items in place
/// (so an inline closure is safe — parent rebuilds do not reset pagination).
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
  final T Function(Map<String, dynamic>) fromJson;

  /// Optional runtime client override. If omitted, uses [ConvexProvider.of].
  final ConvexRuntimeClient? client;

  @override
  State<PaginatedQueryBuilder<T>> createState() =>
      _PaginatedQueryBuilderState<T>();
}

class _PaginatedQueryBuilderState<T> extends State<PaginatedQueryBuilder<T>> {
  static const DeepCollectionEquality _deepEquality = DeepCollectionEquality();

  ConvexRuntimeClient? _client;
  ConvexRuntimePaginatedQuery? _query;
  StreamSubscription<convex.ConvexPaginatedResult>? _subscription;
  Map<String, dynamic>? _subscribedArgs;
  int _queryGeneration = 0;

  List<T> _items = const <Never>[];
  PaginationStatus _status = PaginationStatus.loading;
  convex.ConvexPaginatedResult? _lastResult;

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
      final result = _lastResult;
      if (result != null) {
        try {
          _items = _mapItems(result);
          _status = _mapStatus(result.status);
        } catch (_) {
          _status = PaginationStatus.error;
        }
      }
    }
  }

  void _start() {
    final generation = ++_queryGeneration;
    _subscription?.cancel();
    _query?.cancel();
    final argsSnapshot = _snapshotArgs(widget.args);
    _subscribedArgs = argsSnapshot;
    final query = _client!.paginatedQuery(
      widget.query,
      argsSnapshot,
      pageSize: widget.pageSize,
    );
    _query = query;
    // Seed synchronously from the current snapshot (a build is already pending
    // from this lifecycle callback), then update reactively from the stream.
    final initial = query.current;
    _lastResult = initial;
    try {
      _items = _mapItems(initial);
      _status = _mapStatus(initial.status);
    } catch (_) {
      _items = const <Never>[];
      _status = PaginationStatus.error;
    }
    _subscription = query.stream.listen((result) {
      if (generation != _queryGeneration) {
        return;
      }
      _apply(result);
    }, onError: (Object error, StackTrace stackTrace) {
      if (generation != _queryGeneration || !mounted) {
        return;
      }
      _lastResult = convex.ConvexPaginatedResult(
        results: _lastResult?.results ?? const <dynamic>[],
        status: convex.ConvexPaginationStatus.error,
        isDone: false,
        error: error,
      );
      setState(() {
        _status = PaginationStatus.error;
      });
    });
  }

  void _apply(convex.ConvexPaginatedResult result) {
    if (!mounted) {
      return;
    }
    _lastResult = result;
    late final List<T> items;
    late final PaginationStatus status;
    try {
      items = _mapItems(result);
      status = _mapStatus(result.status);
    } catch (_) {
      items = _items;
      status = PaginationStatus.error;
    }
    setState(() {
      _items = items;
      _status = status;
    });
  }

  List<T> _mapItems(convex.ConvexPaginatedResult result) {
    return result.results
        .map((item) => widget.fromJson(item as Map<String, dynamic>))
        .toList(growable: false);
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

  Map<String, dynamic> _snapshotArgs(Map<String, dynamic>? args) {
    return convex.jsonToConvex(
      convex.convexToJson(args ?? const <String, dynamic>{}),
    ) as Map<String, dynamic>;
  }

  void _loadMore() {
    // The core engine ignores the call while a page is loading or once the
    // query is exhausted, so this is always safe to invoke.
    _query?.loadMore();
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
    return widget.builder(
      context,
      List<T>.unmodifiable(_items),
      _loadMore,
      _status,
    );
  }
}
