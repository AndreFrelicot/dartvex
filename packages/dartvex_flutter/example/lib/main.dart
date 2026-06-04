import 'dart:async';

import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  late final DemoRuntimeClient _client;

  @override
  void initState() {
    super.initState();
    _client = DemoRuntimeClient()
      ..emitConnectionState(ConvexConnectionState.connected);
  }

  @override
  void dispose() {
    _client.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConvexProvider(
      client: _client,
      child: MaterialApp(
        title: 'dartvex_flutter example',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF0B7285),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFF7F4EC),
        ),
        home: const ExampleHomePage(),
      ),
    );
  }
}

class ExampleHomePage extends StatefulWidget {
  const ExampleHomePage({super.key});

  @override
  State<ExampleHomePage> createState() => _ExampleHomePageState();
}

class _ExampleHomePageState extends State<ExampleHomePage> {
  // The message currently being sent, shared between the mutation args and the
  // optimistic update (the OptimisticUpdate typedef carries no args of its own).
  String _composedText = '';
  bool _failNextSend = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('dartvex_flutter'),
        backgroundColor: Colors.transparent,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[Color(0xFFF7F4EC), Color(0xFFE5F4F1)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: <Widget>[
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.82),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        child: ConvexConnectionIndicator(
                          connectedBuilder: (context) =>
                              const Text('Connected'),
                          connectingBuilder: (context) =>
                              const Text('Connecting'),
                          disconnectedBuilder: (context) =>
                              const Text('Disconnected'),
                        ),
                      ),
                    ),
                    // Shown only while the client is recovering auth after a
                    // rejection. Backed by ConvexClient.authRefreshing.
                    const AuthRefreshingBadge(),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Realtime messages',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'This example uses an in-memory runtime client to demonstrate '
                'the widget API. Swap it with ConvexClientRuntime in a real app.',
              ),
              const SizedBox(height: 16),
              const RealtimeInternalsPanel(),
              const SizedBox(height: 16),
              SizedBox(
                height: 240,
                child: ConvexQuery<List<String>>(
                  query: 'messages:list',
                  decode: (value) => List<String>.from(value as List<dynamic>),
                  builder: (context, snapshot) {
                    if (snapshot.isLoading) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return Center(child: Text(snapshot.error.toString()));
                    }
                    final messages = snapshot.data ?? const <String>[];
                    return ListView.separated(
                      itemCount: messages.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        return DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.84),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text(messages[index]),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              // Toggle to make the next send fail, demonstrating that the
              // optimistic message is rolled back when the mutation fails.
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Fail next send (demo rollback)'),
                value: _failNextSend,
                onChanged: (value) {
                  setState(() => _failNextSend = value);
                  final client = ConvexProvider.of(context);
                  if (client is DemoRuntimeClient) {
                    client.failNextMutation = value;
                  }
                },
              ),
              ConvexMutation<String>(
                mutation: 'messages:send',
                // Appends the pending message to messages:list instantly; the
                // overlay is rolled back automatically if the send fails.
                optimisticUpdate: (store) {
                  final current =
                      (store.getQuery('messages:list') as List<dynamic>?)
                          ?.cast<String>() ??
                      const <String>[];
                  store.setQuery(
                    'messages:list',
                    const <String, dynamic>{},
                    <String>[_composedText, ...current],
                  );
                },
                builder: (context, mutate, snapshot) {
                  return FilledButton(
                    onPressed: snapshot.isLoading
                        ? null
                        : () {
                            _composedText =
                                'Message sent at '
                                '${DateTime.now().toIso8601String()}';
                            mutate(<String, dynamic>{'text': _composedText});
                          },
                    child: Text(
                      snapshot.isLoading ? 'Sending...' : 'Send a demo message',
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  final client = ConvexProvider.of(context);
                  if (client is DemoRuntimeClient) {
                    unawaited(client.simulateAuthRefresh());
                  }
                },
                child: const Text('Simulate auth refresh'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () {
                  final client = ConvexProvider.of(context);
                  if (client is DemoRuntimeClient) {
                    unawaited(client.simulateReconnect());
                  }
                },
                child: const Text('Simulate reconnect'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PaginatedHistoryPage(),
                  ),
                ),
                child: const Text('Open paginated history'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A page demonstrating live, reactive pagination with [PaginatedQueryBuilder].
///
/// The list loads pages on demand via "Load more" and updates reactively: the
/// "Add entry" button prepends a backlog entry, which appears at the top of the
/// already-loaded first page without a manual reload.
class PaginatedHistoryPage extends StatelessWidget {
  /// Creates the paginated history demo page.
  const PaginatedHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paginated history')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          final client = ConvexProvider.of(context);
          if (client is DemoRuntimeClient) {
            client.addHistoryEntry(
              'Live entry at ${DateTime.now().toIso8601String()}',
            );
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('Add entry'),
      ),
      body: PaginatedQueryBuilder<String>(
        query: 'messages:history',
        pageSize: 8,
        fromJson: (json) => json['text'] as String,
        builder: (context, items, loadMore, status) {
          if (status == PaginationStatus.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (status == PaginationStatus.error) {
            return const Center(child: Text('Failed to load history'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: items.length + 1,
            itemBuilder: (context, index) {
              if (index < items.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(items[index]),
                );
              }
              switch (status) {
                case PaginationStatus.allLoaded:
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: Text('— end of history —')),
                  );
                case PaginationStatus.loadingMore:
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: CircularProgressIndicator()),
                  );
                case PaginationStatus.loading:
                case PaginationStatus.idle:
                case PaginationStatus.error:
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Center(
                      child: OutlinedButton(
                        onPressed: loadMore,
                        child: const Text('Load more'),
                      ),
                    ),
                  );
              }
            },
          );
        },
      ),
    );
  }
}

/// A chip shown only while the client is refreshing auth after a rejection.
///
/// Demonstrates [ConvexAuthRefreshingBuilder] driven by
/// `ConvexClient.authRefreshing`.
class AuthRefreshingBadge extends StatelessWidget {
  /// Creates an [AuthRefreshingBadge].
  const AuthRefreshingBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return ConvexAuthRefreshingBuilder(
      builder: (context, isRefreshing) {
        if (!isRefreshing) {
          return const SizedBox.shrink();
        }
        return DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFFFF3CD),
            borderRadius: BorderRadius.circular(999),
          ),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Authenticating…'),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A collapsible "Realtime internals" panel surfacing the live connection and
/// auth state, driven by [ConvexConnectionStatusBuilder] and
/// [ConvexAuthRefreshingBuilder] (the WS4b rich connection status).
class RealtimeInternalsPanel extends StatelessWidget {
  /// Creates a [RealtimeInternalsPanel].
  const RealtimeInternalsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.82),
      borderRadius: BorderRadius.circular(16),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          title: const Text(
            'Realtime internals',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: const Text('Live connection + auth state'),
          children: <Widget>[
            ConvexConnectionStatusBuilder(
              builder: (context, status) {
                return Column(
                  children: <Widget>[
                    _InternalsRow('State', status.state.name),
                    _InternalsRow(
                      'WebSocket connected',
                      '${status.isWebSocketConnected}',
                    ),
                    _InternalsRow('Synced', '${status.isConnected}'),
                    _InternalsRow('Loading', '${status.isLoading}'),
                    _InternalsRow(
                      'Has ever connected',
                      '${status.hasEverConnected}',
                    ),
                    _InternalsRow(
                      'Connection count',
                      '${status.connectionCount}',
                    ),
                    _InternalsRow(
                      'Reconnect retries',
                      '${status.connectionRetries}',
                    ),
                    _InternalsRow(
                      'Inflight mutations',
                      '${status.inflightMutations}',
                    ),
                    _InternalsRow(
                      'Inflight actions',
                      '${status.inflightActions}',
                    ),
                    _InternalsRow(
                      'Oldest inflight',
                      status.timeOfOldestInflightRequest?.toIso8601String() ??
                          '—',
                    ),
                  ],
                );
              },
            ),
            ConvexAuthRefreshingBuilder(
              builder: (context, isRefreshing) =>
                  _InternalsRow('Auth refreshing', '$isRefreshing'),
            ),
          ],
        ),
      ),
    );
  }
}

class _InternalsRow extends StatelessWidget {
  const _InternalsRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Text(label, style: const TextStyle(color: Color(0xFF55636B))),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class DemoRuntimeClient implements ConvexRuntimeClient {
  DemoRuntimeClient()
    : _connectionController = StreamController<ConvexConnectionState>.broadcast(
        sync: true,
      ) {
    _messages = <String>[
      'Welcome to dartvex_flutter.',
      'This list updates through the shared runtime interface.',
    ];
  }

  final StreamController<ConvexConnectionState> _connectionController;
  final StreamController<bool> _authRefreshingController =
      StreamController<bool>.broadcast(sync: true);
  final List<DemoRuntimeSubscription> _subscriptions =
      <DemoRuntimeSubscription>[];
  final List<DemoPaginatedQuery> _paginatedQueries = <DemoPaginatedQuery>[];
  late List<String> _messages;
  // A longer, paginated backlog rendered by the live paginated history page.
  late List<Map<String, dynamic>> _history =
      List<Map<String, dynamic>>.generate(
        24,
        (index) => <String, dynamic>{
          'id': index,
          'text': 'History message #${24 - index}',
        },
      );
  ConvexConnectionState _currentConnectionState =
      ConvexConnectionState.connecting;
  ConnectionStatus _currentConnectionStatus = ConnectionStatus.fromState(
    ConvexConnectionState.connecting,
  );
  final StreamController<ConnectionStatus> _connectionStatusController =
      StreamController<ConnectionStatus>.broadcast(sync: true);
  // Simulated transport metrics so the "Realtime internals" panel has something
  // to show; a real ConvexClient reports these for real.
  int _connectionCount = 1;
  int _connectionRetries = 0;
  int _inflightMutations = 0;
  // The demo never issues actions, so this stays zero; a real ConvexClient
  // reports actual inflight actions here.
  final int _inflightActions = 0;
  bool _hasEverConnected = false;
  DateTime? _oldestInflight;
  bool _currentAuthRefreshing = false;
  bool _disposed = false;

  /// The number of backlog entries available to paginate through.
  int get historyLength => _history.length;

  /// The first [count] backlog entries, newest first.
  List<Map<String, dynamic>> historySlice(int count) =>
      _history.take(count).toList(growable: false);

  /// When `true`, the next [mutate] call fails after showing its optimistic
  /// update, so the example can demonstrate rollback.
  bool failNextMutation = false;

  @override
  Stream<ConvexConnectionState> get connectionState =>
      _connectionController.stream;

  @override
  ConvexConnectionState get currentConnectionState => _currentConnectionState;

  @override
  Stream<ConnectionStatus> get connectionStatus =>
      _connectionStatusController.stream;

  @override
  ConnectionStatus get currentConnectionStatus => _currentConnectionStatus;

  @override
  Stream<bool> get authRefreshing => _authRefreshingController.stream;

  @override
  bool get currentAuthRefreshing => _currentAuthRefreshing;

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    return 'Action "$name" completed';
  }

  @override
  Future<void> reconnectNow(String reason) async {}

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    for (final query in List<DemoPaginatedQuery>.of(_paginatedQueries)) {
      query.cancel();
    }
    unawaited(_connectionController.close());
    unawaited(_connectionStatusController.close());
    unawaited(_authRefreshingController.close());
  }

  void emitConnectionState(ConvexConnectionState state) {
    _currentConnectionState = state;
    if (state == ConvexConnectionState.connected) {
      _hasEverConnected = true;
    }
    _connectionController.add(state);
    _publishStatus();
  }

  /// Rebuilds and broadcasts the rich [ConnectionStatus] from the demo's
  /// simulated transport metrics.
  void _publishStatus() {
    final connected =
        _currentConnectionState == ConvexConnectionState.connected;
    final inflight = _inflightMutations + _inflightActions;
    _currentConnectionStatus = ConnectionStatus(
      state: _currentConnectionState,
      isWebSocketConnected: connected,
      isConnected: connected && inflight == 0,
      hasEverConnected: _hasEverConnected,
      connectionCount: _connectionCount,
      connectionRetries: _connectionRetries,
      inflightMutations: _inflightMutations,
      inflightActions: _inflightActions,
      timeOfOldestInflightRequest: inflight > 0 ? _oldestInflight : null,
      hasSyncedPastLastReconnect: connected,
    );
    if (!_connectionStatusController.isClosed) {
      _connectionStatusController.add(_currentConnectionStatus);
    }
  }

  /// Simulates a reconnect cycle: the connection drops to reconnecting (the
  /// retry counter ticks up), then re-establishes (the connection count grows),
  /// the way a real reconnect would, so the internals panel updates live.
  Future<void> simulateReconnect() async {
    _connectionRetries += 1;
    emitConnectionState(ConvexConnectionState.reconnecting);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (_disposed) {
      return;
    }
    _connectionRetries = 0;
    _connectionCount += 1;
    emitConnectionState(ConvexConnectionState.connected);
  }

  void emitAuthRefreshing(bool isRefreshing) {
    _currentAuthRefreshing = isRefreshing;
    _authRefreshingController.add(isRefreshing);
  }

  /// Simulates the client recovering auth after a server rejection: it flips to
  /// "refreshing" briefly, the way a real reauth (stop socket, refetch token,
  /// restart) would, then settles back.
  Future<void> simulateAuthRefresh() async {
    emitAuthRefreshing(true);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (_disposed) {
      return;
    }
    emitAuthRefreshing(false);
  }

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
    OptimisticUpdate? optimisticUpdate,
  ]) async {
    _inflightMutations += 1;
    _oldestInflight ??= DateTime.now();
    _publishStatus();
    try {
      // A real ConvexClient overlays the optimistic update internally; this
      // in-memory demo runs it against a snapshot of the current results to
      // show the pending message instantly, then commits or rolls back.
      final committed = List<String>.from(_messages);
      if (optimisticUpdate != null) {
        final store = _DemoOptimisticStore(<String, Object?>{
          'messages:list': List<String>.from(_messages),
        });
        optimisticUpdate(store);
        final optimistic =
            (store.getQuery('messages:list') as List<dynamic>?)
                ?.cast<String>() ??
            committed;
        _emitToAll(
          optimistic,
          source: ConvexQuerySource.cache,
          hasPendingWrites: true,
        );
      }

      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (_disposed) {
        return null;
      }

      if (failNextMutation) {
        failNextMutation = false;
        // Roll back to the authoritative server state and fail the mutation.
        _emitToAll(
          committed,
          source: ConvexQuerySource.remote,
          hasPendingWrites: false,
        );
        throw StateError(
          'Simulated send failure — optimistic message rolled back',
        );
      }

      final text = args['text'] as String? ?? 'Untitled message';
      _messages = <String>[text, ...committed];
      _emitToAll(
        List<String>.from(_messages),
        source: ConvexQuerySource.remote,
        hasPendingWrites: false,
      );
      return text;
    } finally {
      _inflightMutations -= 1;
      if (_inflightMutations == 0 && _inflightActions == 0) {
        _oldestInflight = null;
      }
      _publishStatus();
    }
  }

  void _emitToAll(
    List<String> value, {
    required ConvexQuerySource source,
    required bool hasPendingWrites,
  }) {
    for (final subscription in _subscriptions) {
      subscription.emit(
        value,
        source: source,
        hasPendingWrites: hasPendingWrites,
      );
    }
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    return List<String>.from(_messages);
  }

  @override
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final result = await query(name, args);
    return result as T;
  }

  @override
  ConvexRuntimeSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final subscription = DemoRuntimeSubscription();
    _subscriptions.add(subscription);
    scheduleMicrotask(() {
      if (!subscription.isCanceled) {
        subscription.emit(List<String>.from(_messages));
      }
    });
    return subscription;
  }

  @override
  ConvexRuntimePaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    // A real ConvexClient runs an actual paginated query; this demo paginates
    // the in-memory backlog so the page list updates live as entries arrive.
    final query = DemoPaginatedQuery(this, pageSize);
    _paginatedQueries.add(query);
    return query;
  }

  /// Removes a finished paginated query from the live set.
  void unregisterPaginatedQuery(DemoPaginatedQuery query) {
    _paginatedQueries.remove(query);
  }

  /// Prepends a backlog entry (newest first), reactively growing every live
  /// paginated query's first page so the new message appears at the top.
  void addHistoryEntry(String text) {
    _history = <Map<String, dynamic>>[
      <String, dynamic>{'id': _history.length, 'text': text},
      ..._history,
    ];
    for (final query in List<DemoPaginatedQuery>.of(_paginatedQueries)) {
      query.onHistoryChanged();
    }
  }
}

class DemoRuntimeSubscription implements ConvexRuntimeSubscription {
  final StreamController<ConvexRuntimeQueryEvent> _controller =
      StreamController<ConvexRuntimeQueryEvent>.broadcast(sync: true);
  bool isCanceled = false;

  @override
  Stream<ConvexRuntimeQueryEvent> get stream => _controller.stream;

  @override
  void cancel() {
    if (isCanceled) {
      return;
    }
    isCanceled = true;
    unawaited(_controller.close());
  }

  void emit(
    dynamic value, {
    ConvexQuerySource source = ConvexQuerySource.remote,
    bool hasPendingWrites = false,
  }) {
    if (isCanceled) {
      return;
    }
    _controller.add(
      ConvexRuntimeQuerySuccess(
        value,
        source: source,
        hasPendingWrites: hasPendingWrites,
      ),
    );
  }
}

/// An in-memory, reactive paginated query over [DemoRuntimeClient]'s backlog.
///
/// Loads the first page after a short delay, grows by [pageSize] on
/// [loadMore], and re-emits when the backlog changes so the page list stays
/// live — the in-memory stand-in for the core reactive pagination engine.
class DemoPaginatedQuery implements ConvexRuntimePaginatedQuery {
  /// Creates a paginated view of [_client]'s backlog with the given [pageSize].
  DemoPaginatedQuery(this._client, this.pageSize) {
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (isCanceled) {
        return;
      }
      _loaded = pageSize;
      _refresh();
    });
  }

  final DemoRuntimeClient _client;

  /// Items requested per page.
  final int pageSize;

  final StreamController<ConvexPaginatedResult> _controller =
      StreamController<ConvexPaginatedResult>.broadcast(sync: true);
  ConvexPaginatedResult _current = const ConvexPaginatedResult(
    results: <dynamic>[],
    status: ConvexPaginationStatus.loadingFirstPage,
    isDone: false,
  );
  int _loaded = 0;
  bool _loadingMore = false;

  /// Whether this query has been canceled.
  bool isCanceled = false;

  @override
  Stream<ConvexPaginatedResult> get stream => _controller.stream;

  @override
  ConvexPaginatedResult get current => _current;

  @override
  bool loadMore([int? numItems]) {
    if (isCanceled || _loadingMore || _loaded >= _client.historyLength) {
      return false;
    }
    _loadingMore = true;
    _emit(_current.results, ConvexPaginationStatus.loadingMore, isDone: false);
    Future<void>.delayed(const Duration(milliseconds: 350), () {
      if (isCanceled) {
        return;
      }
      _loaded = (_loaded + (numItems ?? pageSize)).clamp(
        0,
        _client.historyLength,
      );
      _loadingMore = false;
      _refresh();
    });
    return true;
  }

  /// Grows the window by one and re-emits so a freshly prepended entry shows.
  void onHistoryChanged() {
    if (isCanceled || _loaded == 0) {
      return;
    }
    _loaded = (_loaded + 1).clamp(0, _client.historyLength);
    _refresh();
  }

  void _refresh() {
    final isDone = _loaded >= _client.historyLength;
    _emit(
      _client.historySlice(_loaded),
      isDone
          ? ConvexPaginationStatus.exhausted
          : ConvexPaginationStatus.canLoadMore,
      isDone: isDone,
    );
  }

  void _emit(
    List<dynamic> results,
    ConvexPaginationStatus status, {
    required bool isDone,
  }) {
    _current = ConvexPaginatedResult(
      results: results,
      status: status,
      isDone: isDone,
    );
    if (!_controller.isClosed) {
      _controller.add(_current);
    }
  }

  @override
  void cancel() {
    if (isCanceled) {
      return;
    }
    isCanceled = true;
    _client.unregisterPaginatedQuery(this);
    unawaited(_controller.close());
  }
}

/// A minimal in-memory [OptimisticLocalStore] for the demo runtime client.
///
/// A real [ConvexClient] applies optimistic updates against its live query
/// cache; this stand-in just holds the one query the example renders so the
/// update can be run and read back.
class _DemoOptimisticStore implements OptimisticLocalStore {
  _DemoOptimisticStore(this._values);

  final Map<String, Object?> _values;

  @override
  dynamic getQuery(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    return _values[name];
  }

  @override
  List<OptimisticQueryEntry> getAllQueries(String name) {
    final value = _values[name];
    if (value == null) {
      return const <OptimisticQueryEntry>[];
    }
    return <OptimisticQueryEntry>[
      OptimisticQueryEntry(args: const <String, dynamic>{}, value: value),
    ];
  }

  @override
  void setQuery(String name, Map<String, dynamic> args, Object? value) {
    _values[name] = value;
  }
}
