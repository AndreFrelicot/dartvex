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
/// Convex paginated queries accept `paginationOpts` with `numItems` and
/// `cursor`, and return `{ page, continueCursor, isDone }`.
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
  final List<T> _items = <T>[];
  String? _cursor;
  bool _isDone = false;
  bool _isLoadingPage = false;
  PaginationStatus _status = PaginationStatus.loading;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadPage();
    });
  }

  @override
  void didUpdateWidget(covariant PaginatedQueryBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query || oldWidget.args != widget.args) {
      _reset();
      _loadPage();
    }
  }

  void _reset() {
    _items.clear();
    _cursor = null;
    _isDone = false;
    _isLoadingPage = false;
    _status = PaginationStatus.loading;
  }

  Future<void> _loadPage() async {
    if (_isLoadingPage || !mounted) return;
    _isLoadingPage = true;

    setState(() {
      _status = _items.isEmpty
          ? PaginationStatus.loading
          : PaginationStatus.loadingMore;
    });

    try {
      final client = widget.client ?? ConvexProvider.of(context);
      final result = await client.query(widget.query, <String, dynamic>{
        ...?widget.args,
        'paginationOpts': <String, dynamic>{
          'numItems': widget.pageSize,
          'cursor': _cursor,
        },
      }) as Map<String, dynamic>;

      if (!mounted) return;

      final page = (result['page'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(widget.fromJson)
          .toList();
      _isDone = result['isDone'] as bool? ?? true;
      if (!_isDone) {
        _cursor = result['continueCursor'] as String?;
      }

      setState(() {
        _items.addAll(page);
        _status = _isDone ? PaginationStatus.allLoaded : PaginationStatus.idle;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _status = PaginationStatus.error;
      });
    } finally {
      _isLoadingPage = false;
    }
  }

  void _loadMore() {
    if (_status == PaginationStatus.idle && !_isDone) {
      _loadPage();
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(
        context, List<T>.unmodifiable(_items), _loadMore, _status);
  }
}
