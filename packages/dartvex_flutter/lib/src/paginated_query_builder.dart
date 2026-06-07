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
/// page's cursor; changing [query], [args], [pageSize], [fromJson], or [client]
/// resets the query.
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

  List<T> _items = const <Never>[];
  PaginationStatus _status = PaginationStatus.loading;

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
        oldWidget.fromJson != widget.fromJson ||
        _client != client ||
        !_deepEquality.equals(oldWidget.args, widget.args)) {
      _client = client;
      _start();
    }
  }

  void _start() {
    _subscription?.cancel();
    _query?.cancel();
    final query = _client!.paginatedQuery(
      widget.query,
      <String, dynamic>{...?widget.args},
      pageSize: widget.pageSize,
    );
    _query = query;
    // Seed synchronously from the current snapshot (a build is already pending
    // from this lifecycle callback), then update reactively from the stream.
    final initial = query.current;
    try {
      _items = _mapItems(initial);
      _status = _mapStatus(initial.status);
    } catch (_) {
      _items = const <Never>[];
      _status = PaginationStatus.error;
    }
    _subscription = query.stream.listen(_apply);
  }

  void _apply(convex.ConvexPaginatedResult result) {
    if (!mounted) {
      return;
    }
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

  void _loadMore() {
    // The core engine ignores the call while a page is loading or once the
    // query is exhausted, so this is always safe to invoke.
    _query?.loadMore();
  }

  @override
  void dispose() {
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
