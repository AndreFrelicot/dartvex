import 'dart:async';
import 'package:dartvex/dartvex.dart';

import 'cache/cache_storage.dart';
import 'cache/query_cache.dart';
import 'offline/mutation_queue.dart';
import 'offline/queue_storage.dart';
import 'query_key.dart';
import 'runtime/convex_remote_client.dart';
import 'value_codec.dart';

/// Controls whether the local client may reach the remote backend.
enum LocalNetworkMode {
  /// Use the remote backend when available and replay queued mutations.
  auto,

  /// Force the client to use only local cache and queue state.
  offline,
}

/// High-level connectivity state exposed by [ConvexLocalClient].
enum LocalConnectionState {
  /// The client is online and serving remote traffic normally.
  online,

  /// The client is fully offline.
  offline,

  /// The client is replaying queued mutations to catch up with the backend.
  syncing,
}

/// Indicates where a query result originated.
enum LocalQuerySource {
  /// The value came from the remote backend.
  remote,

  /// The value came from the local cache.
  cache,

  /// The source could not be determined.
  unknown,
}

/// Status of a mutation stored in the offline replay queue.
enum PendingMutationStatus {
  /// The mutation is waiting to be replayed.
  pending,

  /// The mutation is currently being replayed.
  replaying,
}

/// Converts [PendingMutationStatus] values to and from their wire names.
extension PendingMutationStatusName on PendingMutationStatus {
  /// The persisted wire representation for this status.
  String get wireName => switch (this) {
        PendingMutationStatus.pending => 'pending',
        PendingMutationStatus.replaying => 'replaying',
      };

  /// Parses a persisted wire [value] into a status.
  static PendingMutationStatus fromWireName(String value) {
    return switch (value) {
      'pending' => PendingMutationStatus.pending,
      'replaying' => PendingMutationStatus.replaying,
      _ => PendingMutationStatus.pending,
    };
  }
}

/// Connection state exposed by a [LocalRemoteClient].
enum LocalRemoteConnectionState {
  /// The remote connection is established.
  connected,

  /// The remote client is connecting or reconnecting.
  connecting,

  /// The remote client is disconnected.
  disconnected,
}

/// Base class for events emitted by a [LocalRemoteSubscription].
sealed class LocalRemoteQueryEvent {
  /// Creates a remote query event.
  const LocalRemoteQueryEvent();
}

/// Remote query event containing a successful result value.
class LocalRemoteQuerySuccess extends LocalRemoteQueryEvent {
  /// Creates a successful remote query event.
  const LocalRemoteQuerySuccess(this.value);

  /// The returned query value.
  final dynamic value;
}

/// Remote query event containing a query error.
class LocalRemoteQueryError extends LocalRemoteQueryEvent {
  /// Creates a failed remote query event.
  const LocalRemoteQueryError(this.error);

  /// The reported error.
  final Object error;
}

/// Handle for a subscription maintained by a [LocalRemoteClient].
abstract class LocalRemoteSubscription {
  /// Creates a remote subscription handle.
  LocalRemoteSubscription();

  /// Stream of remote query events.
  Stream<LocalRemoteQueryEvent> get stream;

  /// Cancels the remote subscription.
  void cancel();
}

/// Remote client abstraction used by [ConvexLocalClient].
abstract class LocalRemoteClient {
  /// Creates a remote client abstraction.
  LocalRemoteClient();

  /// Executes a query against the remote backend.
  Future<dynamic> query(String name, [Map<String, dynamic> args = const {}]);

  /// Subscribes to a remote query.
  LocalRemoteSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const {},
  ]);

  /// Executes a mutation against the remote backend.
  Future<dynamic> mutate(String name, [Map<String, dynamic> args = const {}]);

  /// Executes an action against the remote backend.
  Future<dynamic> action(String name, [Map<String, dynamic> args = const {}]);

  /// Broadcasts remote connection state changes.
  Stream<LocalRemoteConnectionState> get connectionState;

  /// The current connection state of the remote client.
  LocalRemoteConnectionState get currentConnectionState;

  /// Releases resources held by the remote client.
  void dispose();
}

/// Base class for events emitted by a [LocalSubscription].
sealed class LocalQueryEvent {
  /// Creates a local query event.
  const LocalQueryEvent({
    required this.source,
    required this.hasPendingWrites,
  });

  /// Where the value or error originated.
  final LocalQuerySource source;

  /// Whether optimistic writes are currently pending for the query.
  final bool hasPendingWrites;
}

/// Local query event containing a successful result value.
class LocalQuerySuccess extends LocalQueryEvent {
  /// Creates a successful query event.
  const LocalQuerySuccess(
    this.value, {
    required super.source,
    required super.hasPendingWrites,
  });

  /// The returned query value.
  final dynamic value;
}

/// Local query event containing an error.
class LocalQueryError extends LocalQueryEvent {
  /// Creates a failed query event.
  const LocalQueryError(
    this.error, {
    required super.source,
    required super.hasPendingWrites,
  });

  /// The reported error.
  final Object error;
}

/// Handle for a subscription created by [ConvexLocalClient.subscribe].
class LocalSubscription {
  /// Creates a local subscription wrapper.
  LocalSubscription({
    required Stream<LocalQueryEvent> stream,
    required Future<void> Function() onCancel,
  })  : _stream = stream,
        _onCancel = onCancel;

  final Stream<LocalQueryEvent> _stream;
  final Future<void> Function() _onCancel;

  /// The stream of local query events.
  Stream<LocalQueryEvent> get stream => _stream;

  /// Cancels the subscription asynchronously.
  void cancel() {
    unawaited(_onCancel());
  }
}

/// Base class for mutation results returned by [ConvexLocalClient.mutate].
sealed class LocalMutationResult {
  /// Creates a mutation result.
  const LocalMutationResult();
}

/// Mutation result produced when the mutation succeeds immediately.
class LocalMutationSuccess extends LocalMutationResult {
  /// Creates an immediate mutation success result.
  const LocalMutationSuccess(this.value);

  /// The returned mutation value.
  final dynamic value;
}

/// Mutation result produced when the mutation is queued offline.
class LocalMutationQueued extends LocalMutationResult {
  /// Creates a queued mutation result.
  const LocalMutationQueued({
    required this.queuePosition,
    required this.pendingMutation,
  });

  /// The 1-based position of the queued mutation.
  final int queuePosition;

  /// The queued mutation metadata.
  final PendingMutation pendingMutation;
}

/// Mutation result produced when the mutation fails and cannot be queued.
class LocalMutationFailed extends LocalMutationResult {
  /// Creates a failed mutation result.
  const LocalMutationFailed(this.error);

  /// The reported error.
  final Object error;
}

/// Metadata for a mutation currently stored in the replay queue.
class PendingMutation {
  /// Creates a pending mutation entry.
  const PendingMutation({
    required this.id,
    required this.mutationName,
    required this.args,
    required this.createdAt,
    required this.status,
    this.optimisticData,
    this.errorMessage,
  });

  /// Storage-assigned identifier for the mutation.
  final int id;

  /// Canonical mutation name to replay remotely.
  final String mutationName;

  /// Decoded mutation arguments.
  final Map<String, dynamic> args;

  /// Optional optimistic metadata used to refresh affected queries.
  final Map<String, dynamic>? optimisticData;

  /// UTC time when the mutation was originally queued.
  final DateTime createdAt;

  /// Current replay status for the mutation.
  final PendingMutationStatus status;

  /// Optional replay failure message.
  final String? errorMessage;

  /// Returns a copy with selected queue fields replaced.
  PendingMutation copyWith({
    PendingMutationStatus? status,
    String? errorMessage,
  }) {
    return PendingMutation(
      id: id,
      mutationName: mutationName,
      args: args,
      optimisticData: optimisticData,
      createdAt: createdAt,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}

/// Conflict reported when a queued mutation fails permanently during replay.
class LocalMutationConflict {
  /// Creates a mutation conflict payload.
  const LocalMutationConflict({
    required this.mutationName,
    required this.args,
    required this.error,
    required this.queuedAt,
  });

  /// Canonical mutation name that failed.
  final String mutationName;

  /// Decoded mutation arguments.
  final Map<String, dynamic> args;

  /// The replay failure that caused the conflict.
  final Object error;

  /// UTC time when the mutation was originally queued.
  final DateTime queuedAt;
}

/// Canonical identifier for a query plus its arguments.
class LocalQueryDescriptor {
  /// Creates a local query descriptor.
  const LocalQueryDescriptor(this.name,
      [this.args = const <String, dynamic>{}]);

  /// Canonical query name.
  final String name;

  /// Query arguments used for caching and subscriptions.
  final Map<String, dynamic> args;

  /// Deterministic key used to index cache and subscription state.
  String get key => serializeQueryKey(name, args);

  /// Serializes this descriptor into JSON.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'args': canonicalizeJsonValue(args),
    };
  }

  /// Reconstructs a descriptor from serialized JSON.
  static LocalQueryDescriptor fromJson(Map<String, dynamic> json) {
    final rawArgs = json['args'];
    return LocalQueryDescriptor(
      json['name'] as String,
      rawArgs is Map
          ? rawArgs.cast<String, dynamic>()
          : const <String, dynamic>{},
    );
  }
}

/// Metadata describing a queued optimistic mutation operation.
class LocalMutationContext {
  /// Creates a mutation context.
  const LocalMutationContext({
    required this.operationId,
    required this.queuedAt,
  });

  /// Unique local operation identifier.
  final String operationId;

  /// UTC time when the mutation was queued.
  final DateTime queuedAt;
}

/// Optimistic patch to apply to a cached query result.
class LocalMutationPatch {
  /// Creates an optimistic cache patch.
  const LocalMutationPatch({
    required this.target,
    required this.apply,
  });

  /// The query targeted by the patch.
  final LocalQueryDescriptor target;

  /// Function that produces the patched value from the current cached value.
  final dynamic Function(dynamic currentValue) apply;
}

/// Strategy for generating optimistic patches for a mutation.
abstract class LocalMutationHandler {
  /// Creates a mutation handler.
  const LocalMutationHandler();

  /// Name of the mutation handled by this strategy.
  String get mutationName;

  /// Builds optimistic patches for [args] and the current [context].
  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  );
}

/// Configuration for constructing a [ConvexLocalClient].
class LocalClientConfig {
  /// Creates a local client configuration.
  const LocalClientConfig({
    required this.cacheStorage,
    required this.queueStorage,
    this.valueCodec = const JsonValueCodec(),
    this.mutationHandlers = const <LocalMutationHandler>[],
    this.initialNetworkMode = LocalNetworkMode.auto,
    this.disposeRemoteClient = false,
  });

  /// Storage used for cached query results.
  final CacheStorage cacheStorage;

  /// Storage used for queued offline mutations.
  final QueueStorage queueStorage;

  /// Codec used for cache and queue persistence.
  final ValueCodec valueCodec;

  /// Mutation handlers that generate optimistic patches.
  final List<LocalMutationHandler> mutationHandlers;

  /// Initial network mode applied when the client opens.
  final LocalNetworkMode initialNetworkMode;

  /// Whether a wrapped remote client should be disposed automatically.
  final bool disposeRemoteClient;
}

/// Offline-first client that layers cache and mutation replay onto Dartvex.
class ConvexLocalClient {
  ConvexLocalClient._(
    this._remoteClient,
    this._config,
    this._queryCache,
    this._mutationQueue,
  )   : _networkMode = _config.initialNetworkMode,
        _currentConnectionState = LocalConnectionState.online,
        _lastRemoteConnectionState = _remoteClient.currentConnectionState;

  /// Opens a local client backed by a [ConvexClient].
  static Future<ConvexLocalClient> open({
    required ConvexClient client,
    required LocalClientConfig config,
  }) {
    return openWithRemote(
      remoteClient: ConvexRemoteClientAdapter(
        client,
        disposeClient: config.disposeRemoteClient,
      ),
      config: config,
    );
  }

  /// Opens a local client with a custom [LocalRemoteClient] implementation.
  static Future<ConvexLocalClient> openWithRemote({
    required LocalRemoteClient remoteClient,
    required LocalClientConfig config,
  }) async {
    final queryCache = QueryCache(
      storage: config.cacheStorage,
      codec: config.valueCodec,
    );
    final mutationQueue = MutationQueue(
      storage: config.queueStorage,
      codec: config.valueCodec,
    );
    final client = ConvexLocalClient._(
      remoteClient,
      config,
      queryCache,
      mutationQueue,
    );
    await client._initialize();
    return client;
  }

  final LocalRemoteClient _remoteClient;
  final LocalClientConfig _config;
  final QueryCache _queryCache;
  final MutationQueue _mutationQueue;

  final StreamController<LocalConnectionState> _connectionStateController =
      StreamController<LocalConnectionState>.broadcast(sync: true);
  final StreamController<LocalNetworkMode> _networkModeController =
      StreamController<LocalNetworkMode>.broadcast(sync: true);
  final StreamController<List<PendingMutation>> _pendingMutationsController =
      StreamController<List<PendingMutation>>.broadcast(sync: true);

  final Map<String, LocalMutationHandler> _mutationHandlersByName =
      <String, LocalMutationHandler>{};
  final Map<String, _LocalQueryState> _queryStates =
      <String, _LocalQueryState>{};
  final Map<int, _LocalSubscriptionState> _subscriptionStates =
      <int, _LocalSubscriptionState>{};
  final Map<String, int> _pendingWritesByQueryKey = <String, int>{};

  late final StreamSubscription<LocalRemoteConnectionState>
      _remoteConnectionSubscription;

  LocalNetworkMode _networkMode;
  LocalConnectionState _currentConnectionState;
  LocalRemoteConnectionState _lastRemoteConnectionState;
  List<PendingMutation> _pendingMutations = const <PendingMutation>[];
  bool _isSyncing = false;
  bool _disposed = false;
  Timer? _replayRetryTimer;
  int _replayRetryCount = 0;
  int _nextSubscriptionId = 0;
  int _operationCounter = 0;

  /// Callback invoked when replay drops a permanently failed queued mutation.
  void Function(LocalMutationConflict conflict)? onConflict;

  /// Broadcasts high-level connectivity state changes.
  Stream<LocalConnectionState> get connectionState =>
      _connectionStateController.stream;

  /// Broadcasts [LocalNetworkMode] changes.
  Stream<LocalNetworkMode> get networkModeStream =>
      _networkModeController.stream;

  /// Broadcasts the current ordered list of queued mutations.
  Stream<List<PendingMutation>> get pendingMutations =>
      _pendingMutationsController.stream;

  /// The current high-level connectivity state.
  LocalConnectionState get currentConnectionState => _currentConnectionState;

  /// The current network mode.
  LocalNetworkMode get currentNetworkMode => _networkMode;

  /// Snapshot of the currently queued mutations.
  List<PendingMutation> get currentPendingMutations =>
      List<PendingMutation>.unmodifiable(_pendingMutations);

  Future<void> _initialize() async {
    for (final handler in _config.mutationHandlers) {
      _mutationHandlersByName[handler.mutationName] = handler;
    }

    _pendingMutations = await _mutationQueue.loadAll();
    _rebuildPendingWriteCounts();
    _remoteConnectionSubscription = _remoteClient.connectionState.listen(
      _handleRemoteConnectionState,
    );

    _networkModeController.add(_networkMode);
    _pendingMutationsController.add(currentPendingMutations);
    _updateConnectionState();
    unawaited(_startReplayIfPossible());
  }

  /// Executes a query, falling back to cache when possible.
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertNotDisposed();
    if (_networkMode == LocalNetworkMode.offline) {
      final cached = await _queryCache.read(name, args);
      if (cached != null) {
        return cached.value;
      }
      throw StateError('No cached value available for $name while offline');
    }

    try {
      final value = await _remoteClient.query(name, args);
      await _queryCache.write(name: name, args: args, value: value);
      return value;
    } on ConvexException catch (error) {
      if (!error.retryable) {
        rethrow;
      }
      final cached = await _queryCache.read(name, args);
      if (cached != null) {
        return cached.value;
      }
      rethrow;
    }
  }

  /// Subscribes to a query with cache seeding and optional remote updates.
  LocalSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    _assertNotDisposed();
    final descriptor =
        LocalQueryDescriptor(name, Map<String, dynamic>.from(args));
    final subscriptionId = _nextSubscriptionId++;
    final state = _LocalSubscriptionState(
      id: subscriptionId,
      descriptor: descriptor,
      controller: StreamController<LocalQueryEvent>.broadcast(sync: true),
    );
    _subscriptionStates[subscriptionId] = state;
    final queryState = _queryStates.putIfAbsent(
      descriptor.key,
      () => _LocalQueryState(descriptor),
    );
    queryState.subscriberIds.add(subscriptionId);

    unawaited(_seedSubscriptionFromCache(state));
    if (_networkMode == LocalNetworkMode.auto) {
      _ensureRemoteSubscription(queryState);
    }

    return LocalSubscription(
      stream: state.controller.stream,
      onCancel: () async {
        await _cancelSubscription(subscriptionId);
      },
    );
  }

  /// Executes a mutation immediately or queues it for offline replay.
  Future<LocalMutationResult> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertNotDisposed();
    final normalizedArgs = Map<String, dynamic>.from(args);
    if (_networkMode == LocalNetworkMode.auto) {
      _log('mutate', '$name — mode=auto, trying remote first');
      try {
        final value = await _remoteClient.mutate(name, normalizedArgs);
        _log('mutate', '$name — remote succeeded');
        return LocalMutationSuccess(value);
      } on ConvexException catch (error) {
        if (!error.retryable) {
          _log('mutate', '$name — non-retryable: ${error.message}');
          return LocalMutationFailed(error);
        }
        _log(
            'mutate',
            '$name — retryable error, falling through to queue: '
                '${error.message}');
      } catch (error) {
        _log('mutate', '$name — non-Convex error: $error');
        return LocalMutationFailed(error);
      }
    }

    _log('mutate', '$name — queueing (mode=$_networkMode)');
    final context = LocalMutationContext(
      operationId: _nextOperationId(),
      queuedAt: DateTime.now().toUtc(),
    );
    final patches = _buildPatches(name, normalizedArgs, context);
    final optimisticData = _optimisticMetadata(context, patches);
    final pendingMutation = await _mutationQueue.enqueue(
      mutationName: name,
      args: normalizedArgs,
      optimisticData: optimisticData,
      createdAt: context.queuedAt,
    );

    await _applyOptimisticPatches(patches);
    _pendingMutations = await _mutationQueue.loadAll();
    _rebuildPendingWriteCounts();
    _pendingMutationsController.add(currentPendingMutations);
    _emitPendingWriteUpdatesForTargets(patches);
    _updateConnectionState();

    _log(
        'mutate',
        '$name — queued as id=${pendingMutation.id} '
            '(total pending=${_pendingMutations.length})');
    return LocalMutationQueued(
      queuePosition: _pendingMutations.length,
      pendingMutation: pendingMutation,
    );
  }

  /// Executes an action against the remote backend.
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertNotDisposed();
    if (_networkMode == LocalNetworkMode.offline) {
      throw const ConvexException(
        'Actions are unavailable while forced offline',
      );
    }
    return _remoteClient.action(name, args);
  }

  /// Updates the active network mode.
  Future<void> setNetworkMode(LocalNetworkMode mode) async {
    _assertNotDisposed();
    if (_networkMode == mode) {
      return;
    }
    _log(
        'mode',
        '$_networkMode → $mode '
            '(pending=${_pendingMutations.length})');
    _networkMode = mode;
    _networkModeController.add(mode);
    if (mode == LocalNetworkMode.offline) {
      _replayRetryTimer?.cancel();
      _replayRetryTimer = null;
      _replayRetryCount = 0;
      await _suspendRemoteSubscriptions();
      await _emitCachedSnapshotsForActiveQueries();
    } else {
      _resumeRemoteSubscriptions();
      _log('mode', 'subscriptions resumed, starting replay…');
      await _startReplayIfPossible();
    }
    _updateConnectionState();
  }

  /// Clears all locally cached query results.
  Future<void> clearCache() async {
    _assertNotDisposed();
    await _queryCache.clear();
  }

  /// Clears the offline mutation queue and resets pending write state.
  Future<void> clearQueue() async {
    _assertNotDisposed();
    await _mutationQueue.clear();
    _pendingMutations = const <PendingMutation>[];
    _pendingWritesByQueryKey.clear();
    _pendingMutationsController.add(currentPendingMutations);
    for (final queryState in _queryStates.values) {
      final cached = await _queryCache.read(
        queryState.descriptor.name,
        queryState.descriptor.args,
      );
      if (cached != null) {
        _emitToQueryKey(
          queryState.descriptor.key,
          LocalQuerySuccess(
            cached.value,
            source: LocalQuerySource.cache,
            hasPendingWrites: false,
          ),
        );
      }
    }
    _updateConnectionState();
  }

  Future<void> _cancelSubscription(int subscriptionId) async {
    final state = _subscriptionStates.remove(subscriptionId);
    if (state == null) {
      return;
    }
    final queryState = _queryStates[state.descriptor.key];
    if (queryState != null) {
      queryState.subscriberIds.remove(subscriptionId);
      if (queryState.subscriberIds.isEmpty) {
        await _detachRemoteSubscription(queryState);
        _queryStates.remove(queryState.descriptor.key);
      }
    }
    await state.controller.close();
  }

  Future<void> _seedSubscriptionFromCache(_LocalSubscriptionState state) async {
    final cached = await _queryCache.read(
      state.descriptor.name,
      state.descriptor.args,
    );
    if (_disposed || !_subscriptionStates.containsKey(state.id)) {
      return;
    }
    if (cached != null) {
      state.controller.add(
        LocalQuerySuccess(
          cached.value,
          source: LocalQuerySource.cache,
          hasPendingWrites: _hasPendingWrites(state.descriptor.key),
        ),
      );
      return;
    }
    if (_networkMode == LocalNetworkMode.offline) {
      state.controller.add(
        LocalQueryError(
          StateError(
            'No cached value available for ${state.descriptor.name} while offline',
          ),
          source: LocalQuerySource.cache,
          hasPendingWrites: _hasPendingWrites(state.descriptor.key),
        ),
      );
    }
  }

  void _handleRemoteConnectionState(LocalRemoteConnectionState state) {
    _log(
        'remote-conn',
        '$_lastRemoteConnectionState → $state '
            '(mode=$_networkMode syncing=$_isSyncing)');
    _lastRemoteConnectionState = state;
    if (_networkMode == LocalNetworkMode.auto &&
        state == LocalRemoteConnectionState.connected) {
      _replayRetryCount = 0;
      _resumeRemoteSubscriptions();
      unawaited(_startReplayIfPossible());
    }
    _updateConnectionState();
  }

  void _ensureRemoteSubscription(_LocalQueryState queryState) {
    if (_networkMode == LocalNetworkMode.offline ||
        queryState.remoteSubscription != null) {
      return;
    }
    final subscription = _remoteClient.subscribe(
      queryState.descriptor.name,
      queryState.descriptor.args,
    );
    queryState.remoteSubscription = subscription;
    queryState.remoteEventSubscription = subscription.stream.listen(
      (event) {
        unawaited(_handleRemoteQueryEvent(queryState, event));
      },
      onError: (Object error, StackTrace stackTrace) {
        _emitToQueryKey(
          queryState.descriptor.key,
          LocalQueryError(
            error,
            source: LocalQuerySource.unknown,
            hasPendingWrites: _hasPendingWrites(queryState.descriptor.key),
          ),
        );
      },
    );
  }

  Future<void> _handleRemoteQueryEvent(
    _LocalQueryState queryState,
    LocalRemoteQueryEvent event,
  ) async {
    switch (event) {
      case LocalRemoteQuerySuccess(:final value):
        await _queryCache.write(
          name: queryState.descriptor.name,
          args: queryState.descriptor.args,
          value: value,
        );
        _emitToQueryKey(
          queryState.descriptor.key,
          LocalQuerySuccess(
            value,
            source: LocalQuerySource.remote,
            hasPendingWrites: _hasPendingWrites(queryState.descriptor.key),
          ),
        );
      case LocalRemoteQueryError(:final error):
        _emitToQueryKey(
          queryState.descriptor.key,
          LocalQueryError(
            error,
            source: LocalQuerySource.unknown,
            hasPendingWrites: _hasPendingWrites(queryState.descriptor.key),
          ),
        );
    }
  }

  Future<void> _detachRemoteSubscription(_LocalQueryState queryState) async {
    unawaited(queryState.remoteEventSubscription?.cancel());
    queryState.remoteEventSubscription = null;
    queryState.remoteSubscription?.cancel();
    queryState.remoteSubscription = null;
  }

  Future<void> _suspendRemoteSubscriptions() async {
    for (final queryState in _queryStates.values) {
      await _detachRemoteSubscription(queryState);
    }
  }

  void _resumeRemoteSubscriptions() {
    for (final queryState in _queryStates.values) {
      _ensureRemoteSubscription(queryState);
    }
  }

  Future<void> _emitCachedSnapshotsForActiveQueries() async {
    for (final queryState in _queryStates.values) {
      final cached = await _queryCache.read(
        queryState.descriptor.name,
        queryState.descriptor.args,
      );
      if (cached == null) {
        continue;
      }
      _emitToQueryKey(
        queryState.descriptor.key,
        LocalQuerySuccess(
          cached.value,
          source: LocalQuerySource.cache,
          hasPendingWrites: _hasPendingWrites(queryState.descriptor.key),
        ),
      );
    }
  }

  Future<void> _startReplayIfPossible() async {
    if (_disposed ||
        _networkMode == LocalNetworkMode.offline ||
        _isSyncing ||
        _pendingMutations.isEmpty) {
      _log(
          'replay:skip',
          'disposed=$_disposed mode=$_networkMode '
              'syncing=$_isSyncing pending=${_pendingMutations.length}');
      _updateConnectionState();
      return;
    }

    _replayRetryTimer?.cancel();
    _replayRetryTimer = null;
    _isSyncing = true;
    _updateConnectionState();
    var hitRetryableError = false;
    _log('replay:start', '${_pendingMutations.length} mutations to replay');
    try {
      // Recover any ID remaps persisted from a prior crash.
      final idRemaps = await _mutationQueue.loadIdRemaps();
      var iteration = 0;
      while (_pendingMutations.isNotEmpty &&
          _networkMode == LocalNetworkMode.auto) {
        iteration++;
        final mutation = _pendingMutations.first;
        _log(
            'replay:mutation',
            '[$iteration] id=${mutation.id} '
                '${mutation.mutationName} — marking replaying');
        await _mutationQueue.markStatus(
          mutation.id,
          PendingMutationStatus.replaying,
        );
        _pendingMutations = await _mutationQueue.loadAll();
        _pendingMutationsController.add(currentPendingMutations);

        // Remap any local IDs in args to server IDs.
        final remappedArgs =
            _remapIds(mutation.args, idRemaps) as Map<String, dynamic>;
        if (!identical(remappedArgs, mutation.args)) {
          _log('replay:remap', '[$iteration] remapped args');
          await _mutationQueue.updateArgs(mutation.id, remappedArgs);
        }

        try {
          _log('replay:mutate', '[$iteration] calling _remoteClient.mutate…');
          final result = await _remoteClient.mutate(
            mutation.mutationName,
            remappedArgs,
          );
          _log('replay:mutate-ok', '[$iteration] remote mutate succeeded');

          // Capture ID mapping: if this mutation produced a local operationId
          // and the server returned a string (the real document ID), record it.
          final operationId = mutation.optimisticData?['operationId'];
          if (operationId is String &&
              operationId.startsWith('local-') &&
              result is String) {
            idRemaps[operationId] = result;
            await _mutationQueue.saveIdRemap(operationId, result);
            _log('replay:id-remap', '[$iteration] $operationId → $result');
          }

          await _mutationQueue.remove(mutation.id);
          _pendingMutations = await _mutationQueue.loadAll();
          _rebuildPendingWriteCounts();
          _pendingMutationsController.add(currentPendingMutations);
          // Fire-and-forget: the widget tree subscriptions already receive
          // live Transition updates, so blocking the replay loop for a cache
          // refresh is unnecessary (and the underlying query() can hang due
          // to a broadcast-stream race in ConvexClient).
          unawaited(_refreshTargetsFromMutation(mutation));
          _replayRetryCount = 0;
        } on ConvexException catch (error) {
          _log(
              'replay:convex-error',
              '[$iteration] ${error.message} '
                  '(retryable=${error.retryable})');
          if (error.retryable) {
            await _mutationQueue.markStatus(
              mutation.id,
              PendingMutationStatus.pending,
              errorMessage: error.message,
            );
            _pendingMutations = await _mutationQueue.loadAll();
            _pendingMutationsController.add(currentPendingMutations);
            hitRetryableError = true;
            break;
          }
          await _dropFailedMutation(mutation, error);
        } catch (error, stack) {
          _log('replay:error', '[$iteration] $error\n$stack');
          await _dropFailedMutation(mutation, error);
        }
      }
      // Clean up remap table when the queue is fully drained.
      if (_pendingMutations.isEmpty && idRemaps.isNotEmpty) {
        await _mutationQueue.clearIdRemaps();
      }
      _log(
          'replay:end',
          'loop finished — ${_pendingMutations.length} '
              'remaining, hitRetryable=$hitRetryableError');
    } finally {
      _isSyncing = false;
      _updateConnectionState();
      if (hitRetryableError) {
        _scheduleReplayRetry();
      }
    }
  }

  void _scheduleReplayRetry() {
    _replayRetryTimer?.cancel();
    final delay = _replayRetryDelay(_replayRetryCount);
    _replayRetryCount++;
    _log(
        'replay:retry',
        'scheduling retry #$_replayRetryCount '
            'in ${delay.inSeconds}s');
    _replayRetryTimer = Timer(delay, () {
      _replayRetryTimer = null;
      if (!_disposed && _networkMode == LocalNetworkMode.auto) {
        _log('replay:retry', 'retry timer fired, starting replay');
        unawaited(_startReplayIfPossible());
      }
    });
  }

  static Duration _replayRetryDelay(int attempt) {
    // Exponential backoff: 1s, 2s, 4s, 8s, capped at 15s.
    final seconds = 1 << attempt;
    return Duration(seconds: seconds.clamp(1, 15));
  }

  Future<void> _dropFailedMutation(
    PendingMutation mutation,
    Object error,
  ) async {
    await _mutationQueue.remove(mutation.id);
    _pendingMutations = await _mutationQueue.loadAll();
    _rebuildPendingWriteCounts();
    _pendingMutationsController.add(currentPendingMutations);
    onConflict?.call(
      LocalMutationConflict(
        mutationName: mutation.mutationName,
        args: mutation.args,
        error: error,
        queuedAt: mutation.createdAt,
      ),
    );
    await _refreshTargetsFromMutation(mutation);
  }

  Future<void> _refreshTargetsFromMutation(PendingMutation mutation) async {
    if (_networkMode == LocalNetworkMode.offline) {
      return;
    }
    final targets = _targetsFromMutation(mutation).toList();
    _log(
        'refresh:start',
        '${mutation.mutationName} — '
            '${targets.length} target(s): '
            '${targets.map((t) => t.name).join(', ')}');
    for (final target in targets) {
      try {
        _log('refresh:query', 'querying ${target.name}…');
        // Timeout guards against ConvexClient.query() hanging when the
        // broadcast stream already emitted the cached result before the
        // listener was attached. The subscription from the widget tree
        // will still receive the live update via the normal Transition flow.
        final value = await _remoteClient
            .query(target.name, target.args)
            .timeout(const Duration(seconds: 5));
        _log('refresh:query-ok', '${target.name} returned');
        await _queryCache.write(
            name: target.name, args: target.args, value: value);
        _emitToQueryKey(
          target.key,
          LocalQuerySuccess(
            value,
            source: LocalQuerySource.remote,
            hasPendingWrites: _hasPendingWrites(target.key),
          ),
        );
      } catch (error) {
        _log('refresh:query-error', '${target.name}: $error');
      }
    }
    _log('refresh:done', '${mutation.mutationName} targets refreshed');
  }

  List<LocalMutationPatch> _buildPatches(
    String mutationName,
    Map<String, dynamic> args,
    LocalMutationContext context,
  ) {
    final handler = _mutationHandlersByName[mutationName];
    if (handler == null) {
      return const <LocalMutationPatch>[];
    }
    return handler.buildPatches(args, context);
  }

  Future<void> _applyOptimisticPatches(List<LocalMutationPatch> patches) async {
    for (final patch in patches) {
      final cached = await _queryCache.read(
        patch.target.name,
        patch.target.args,
      );
      final nextValue = patch.apply(cached?.value);
      await _queryCache.write(
        name: patch.target.name,
        args: patch.target.args,
        value: nextValue,
      );
    }
  }

  void _emitPendingWriteUpdatesForTargets(List<LocalMutationPatch> patches) {
    final keys = patches.map((patch) => patch.target.key).toSet();
    for (final key in keys) {
      final queryState = _queryStates[key];
      if (queryState == null) {
        continue;
      }
      unawaited(_emitCachedSnapshot(queryState.descriptor));
    }
  }

  Future<void> _emitCachedSnapshot(LocalQueryDescriptor descriptor) async {
    final cached = await _queryCache.read(descriptor.name, descriptor.args);
    if (cached == null) {
      return;
    }
    _emitToQueryKey(
      descriptor.key,
      LocalQuerySuccess(
        cached.value,
        source: LocalQuerySource.cache,
        hasPendingWrites: _hasPendingWrites(descriptor.key),
      ),
    );
  }

  Map<String, dynamic> _optimisticMetadata(
    LocalMutationContext context,
    List<LocalMutationPatch> patches,
  ) {
    return <String, dynamic>{
      'operationId': context.operationId,
      'targets':
          patches.map((patch) => patch.target.toJson()).toList(growable: false),
    };
  }

  Iterable<LocalQueryDescriptor> _targetsFromMutation(
      PendingMutation mutation) {
    final optimisticData = mutation.optimisticData;
    if (optimisticData == null) {
      return const <LocalQueryDescriptor>[];
    }
    final targets = optimisticData['targets'];
    if (targets is! List) {
      return const <LocalQueryDescriptor>[];
    }
    return targets
        .whereType<Map>()
        .map((entry) =>
            LocalQueryDescriptor.fromJson(entry.cast<String, dynamic>()))
        .toList(growable: false);
  }

  void _rebuildPendingWriteCounts() {
    _pendingWritesByQueryKey.clear();
    for (final mutation in _pendingMutations) {
      for (final target in _targetsFromMutation(mutation)) {
        _pendingWritesByQueryKey.update(target.key, (count) => count + 1,
            ifAbsent: () => 1);
      }
    }
  }

  bool _hasPendingWrites(String queryKey) {
    return (_pendingWritesByQueryKey[queryKey] ?? 0) > 0;
  }

  void _emitToQueryKey(String queryKey, LocalQueryEvent event) {
    final queryState = _queryStates[queryKey];
    if (queryState == null) {
      return;
    }
    for (final subscriptionId in queryState.subscriberIds) {
      _subscriptionStates[subscriptionId]?.controller.add(event);
    }
  }

  String _nextOperationId() {
    _operationCounter += 1;
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'local-$micros-$_operationCounter';
  }

  void _updateConnectionState() {
    final nextState = switch (_networkMode) {
      LocalNetworkMode.offline => LocalConnectionState.offline,
      LocalNetworkMode.auto => _isSyncing
          ? LocalConnectionState.syncing
          : _lastRemoteConnectionState ==
                  LocalRemoteConnectionState.disconnected
              ? LocalConnectionState.offline
              : LocalConnectionState.online,
    };

    if (_currentConnectionState != nextState) {
      _currentConnectionState = nextState;
      if (!_connectionStateController.isClosed) {
        _connectionStateController.add(nextState);
      }
    }
  }

  static dynamic _remapIds(dynamic value, Map<String, String> idMap) {
    if (idMap.isEmpty) return value;
    if (value is String) return idMap[value] ?? value;
    if (value is Map<String, dynamic>) {
      return {for (final e in value.entries) e.key: _remapIds(e.value, idMap)};
    }
    if (value is List) return value.map((i) => _remapIds(i, idMap)).toList();
    return value;
  }

  // ignore: avoid_print
  static void _log(String tag, String msg) => print('[ConvexLocal:$tag] $msg');

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('ConvexLocalClient has been disposed');
    }
  }

  /// Disposes subscriptions, storage, and the remote client.
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _replayRetryTimer?.cancel();
    _replayRetryTimer = null;
    await _suspendRemoteSubscriptions();
    await _remoteConnectionSubscription.cancel();
    await _connectionStateController.close();
    await _networkModeController.close();
    await _pendingMutationsController.close();

    final controllers =
        _subscriptionStates.values.map((state) => state.controller);
    for (final controller in controllers) {
      await controller.close();
    }
    _subscriptionStates.clear();
    _queryStates.clear();

    if (identical(_config.cacheStorage, _config.queueStorage)) {
      await _config.cacheStorage.close();
    } else {
      await _config.cacheStorage.close();
      await _config.queueStorage.close();
    }

    _remoteClient.dispose();
  }
}

class _LocalQueryState {
  _LocalQueryState(this.descriptor);

  final LocalQueryDescriptor descriptor;
  final Set<int> subscriberIds = <int>{};
  LocalRemoteSubscription? remoteSubscription;
  StreamSubscription<LocalRemoteQueryEvent>? remoteEventSubscription;
}

class _LocalSubscriptionState {
  _LocalSubscriptionState({
    required this.id,
    required this.descriptor,
    required this.controller,
  });

  final int id;
  final LocalQueryDescriptor descriptor;
  final StreamController<LocalQueryEvent> controller;
}
