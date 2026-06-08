import 'dart:async';
import 'package:collection/collection.dart';
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

/// Remote query event indicating a query is temporarily loading.
class LocalRemoteQueryLoading extends LocalRemoteQueryEvent {
  /// Creates a loading remote query event.
  const LocalRemoteQueryLoading({this.hasPendingWrites = false});

  /// Whether optimistic writes are currently pending for the remote query.
  final bool hasPendingWrites;
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
  const LocalQueryEvent({required this.source, required this.hasPendingWrites});

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
  }) : _stream = stream,
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
  ///
  /// Use [clearErrorMessage] to intentionally set [errorMessage] back to null;
  /// a nullable named parameter cannot distinguish "not passed" from null.
  PendingMutation copyWith({
    PendingMutationStatus? status,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    if (clearErrorMessage && errorMessage != null) {
      throw ArgumentError.value(
        errorMessage,
        'errorMessage',
        'Cannot provide an error message while clearing it.',
      );
    }

    return PendingMutation(
      id: id,
      mutationName: mutationName,
      args: args,
      optimisticData: optimisticData,
      createdAt: createdAt,
      status: status ?? this.status,
      errorMessage: clearErrorMessage
          ? null
          : errorMessage ?? this.errorMessage,
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
  const LocalQueryDescriptor(
    this.name, [
    this.args = const <String, dynamic>{},
  ]);

  /// Canonical query name.
  final String name;

  /// Query arguments used for caching and subscriptions.
  final Map<String, dynamic> args;

  /// Deterministic key used to index cache and subscription state.
  String get key => serializeQueryKey(name, args);

  /// Serializes this descriptor into JSON.
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'name': name, 'args': canonicalizeJsonValue(args)};
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
  const LocalMutationPatch({required this.target, required this.apply});

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
    this.queryCachePolicy = QueryCachePolicy.unbounded,
    this.mutationHandlers = const <LocalMutationHandler>[],
    this.initialNetworkMode = LocalNetworkMode.auto,
    this.refreshQueryTimeout = const Duration(seconds: 5),
    this.disposeRemoteClient = false,
    this.logLevel = DartvexLogLevel.off,
    this.logger,
  });

  /// Storage used for cached query results.
  final CacheStorage cacheStorage;

  /// Storage used for queued offline mutations.
  final QueueStorage queueStorage;

  /// Codec used for cache and queue persistence.
  final ValueCodec valueCodec;

  /// Policy used to expire or prune locally cached query results.
  ///
  /// Expired entries are always ignored when read. Entry-count pruning requires
  /// a cache storage implementation that supports maintenance hooks, such as
  /// the built-in SQLite store.
  final QueryCachePolicy queryCachePolicy;

  /// Mutation handlers that generate optimistic patches.
  final List<LocalMutationHandler> mutationHandlers;

  /// Initial network mode applied when the client opens.
  final LocalNetworkMode initialNetworkMode;

  /// Maximum time spent waiting for a remote cache refresh after replay.
  final Duration refreshQueryTimeout;

  /// Whether the caller-supplied remote client should be disposed automatically.
  ///
  /// With [ConvexLocalClient.open], this controls whether the wrapped
  /// [ConvexClient] is disposed when the local client closes. The internal
  /// adapter is always disposed so remote subscriptions are released. With
  /// [ConvexLocalClient.openWithRemote], this controls whether the supplied
  /// [LocalRemoteClient] is disposed when the local client closes.
  final bool disposeRemoteClient;

  /// Minimum log level emitted by Dartvex Local internals.
  final DartvexLogLevel logLevel;

  /// Optional structured log sink.
  final DartvexLogger? logger;
}

/// Offline-first client that layers cache and mutation replay onto Dartvex.
class ConvexLocalClient {
  ConvexLocalClient._(
    this._remoteClient,
    this._config,
    this._queryCache,
    this._mutationQueue,
    this._disposeRemoteClient,
  ) : _networkMode = _config.initialNetworkMode,
      _currentConnectionState = LocalConnectionState.online,
      _lastRemoteConnectionState = _remoteClient.currentConnectionState;

  /// Opens a local client backed by a [ConvexClient].
  static Future<ConvexLocalClient> open({
    required ConvexClient client,
    required LocalClientConfig config,
  }) {
    return _openWithRemote(
      remoteClient: ConvexRemoteClientAdapter(
        client,
        disposeClient: config.disposeRemoteClient,
      ),
      config: config,
      disposeRemoteClient: true,
    );
  }

  /// Opens a local client with a custom [LocalRemoteClient] implementation.
  static Future<ConvexLocalClient> openWithRemote({
    required LocalRemoteClient remoteClient,
    required LocalClientConfig config,
  }) {
    return _openWithRemote(
      remoteClient: remoteClient,
      config: config,
      disposeRemoteClient: config.disposeRemoteClient,
    );
  }

  static Future<ConvexLocalClient> _openWithRemote({
    required LocalRemoteClient remoteClient,
    required LocalClientConfig config,
    required bool disposeRemoteClient,
  }) async {
    final queryCache = QueryCache(
      storage: config.cacheStorage,
      codec: config.valueCodec,
      policy: config.queryCachePolicy,
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
      disposeRemoteClient,
    );
    await client._initialize();
    return client;
  }

  final LocalRemoteClient _remoteClient;
  final LocalClientConfig _config;
  final QueryCache _queryCache;
  final MutationQueue _mutationQueue;
  final bool _disposeRemoteClient;

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

  // Serializes mutate() calls so concurrent mutations are applied in FIFO call
  // order and cannot race the "send directly while the queue is empty" fast
  // path into committing out of order.
  Future<void> _mutateChain = Future<void>.value();

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
    _runDetached(_startReplayIfPossible(), 'replay');
  }

  /// Executes a query, falling back to cache when possible.
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertNotDisposed();
    final descriptor = LocalQueryDescriptor(
      name,
      Map<String, dynamic>.from(args),
    );
    if (_networkMode == LocalNetworkMode.offline) {
      final cached = await _queryCache.read(name, args);
      if (cached != null) {
        return cached.value;
      }
      throw StateError('No cached value available for $name while offline');
    }

    try {
      final value = await _remoteClient.query(descriptor.name, descriptor.args);
      return _writeRemoteSnapshotAndRebasePending(descriptor, value);
    } on ConvexException catch (error) {
      if (!error.retryable) {
        rethrow;
      }
      final cached = await _queryCache.read(name, args);
      if (cached != null) {
        return cached.value;
      }
      rethrow;
    } catch (error) {
      if (!_shouldQueueRemoteFailure(error)) {
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
    final descriptor = LocalQueryDescriptor(
      name,
      Map<String, dynamic>.from(args),
    );
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

    _runDetached(_seedSubscriptionFromCache(state), 'seed');
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
  ///
  /// Queued mutations are replayed at least once. If a connection fails after
  /// the backend commits a mutation but before the client observes the result,
  /// replay may call the mutation again. Design queued Convex mutations to be
  /// idempotent when the operation can have external side effects.
  ///
  /// Calls are serialized in FIFO order: a mutation does not start until the
  /// previous one has settled (sent directly or queued). This keeps concurrent
  /// mutations from racing the empty-queue fast path and committing out of
  /// order; mutations awaited sequentially are unaffected.
  Future<LocalMutationResult> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    _assertNotDisposed();
    final result = _mutateChain.then((_) => _mutateInternal(name, args));
    // Keep the chain alive across failures without leaking a prior call's error
    // to the next caller.
    _mutateChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<LocalMutationResult> _mutateInternal(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertNotDisposed();
    final normalizedArgs = Map<String, dynamic>.from(args);
    if (_networkMode == LocalNetworkMode.auto &&
        _lastRemoteConnectionState == LocalRemoteConnectionState.connected &&
        _pendingMutations.isEmpty &&
        !_isSyncing &&
        _replayRetryTimer == null) {
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
              '${error.message}',
        );
      } catch (error) {
        if (!_shouldQueueRemoteFailure(error)) {
          _log('mutate', '$name — non-Convex error: $error');
          return LocalMutationFailed(error);
        }
        _log('mutate', '$name — remote unavailable, falling through to queue');
      }
    } else if (_networkMode == LocalNetworkMode.auto &&
        _lastRemoteConnectionState == LocalRemoteConnectionState.connected) {
      _log(
        'mutate',
        '$name — queueing behind replay work '
            '(remote=$_lastRemoteConnectionState '
            'syncing=$_isSyncing pending=${_pendingMutations.length})',
      );
    } else if (_networkMode == LocalNetworkMode.auto) {
      _log('mutate', '$name — remote not connected, queueing immediately');
    }

    _log('mutate', '$name — queueing (mode=$_networkMode)');
    final context = LocalMutationContext(
      operationId: _nextOperationId(),
      queuedAt: DateTime.now().toUtc(),
    );
    final patches = _buildPatches(name, normalizedArgs, context);
    final snapshots = await _snapshotOptimisticPatchTargets(patches);
    final optimisticData = _optimisticMetadata(context, patches, snapshots);
    final pendingMutation = await _mutationQueue.enqueue(
      mutationName: name,
      args: normalizedArgs,
      optimisticData: optimisticData,
      createdAt: context.queuedAt,
    );

    try {
      await _applyOptimisticPatches(patches, snapshots: snapshots);
    } catch (_) {
      await _mutationQueue.remove(pendingMutation.id);
      rethrow;
    }
    _pendingMutations = await _mutationQueue.loadAll();
    _rebuildPendingWriteCounts();
    _pendingMutationsController.add(currentPendingMutations);
    _emitPendingWriteUpdatesForTargets(patches);
    _updateConnectionState();

    _log(
      'mutate',
      '$name — queued as id=${pendingMutation.id} '
          '(total pending=${_pendingMutations.length})',
    );
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
          '(pending=${_pendingMutations.length})',
    );
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
    // Snapshot the query states: emitting below can synchronously cancel a
    // subscription, which removes its query state, mutating `_queryStates`
    // mid-iteration.
    for (final queryState in _queryStates.values.toList(growable: false)) {
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
    // Yield before closing. cancel() may be invoked synchronously from a
    // listener while this controller is still dispatching its event, and
    // closing a synchronous broadcast controller mid-dispatch throws
    // "Cannot fire new event". The microtask resumes once the dispatch unwinds.
    await Future<void>.value();
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
    if (state.hasRemoteEvent) {
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
          '(mode=$_networkMode syncing=$_isSyncing)',
    );
    _lastRemoteConnectionState = state;
    if (_networkMode == LocalNetworkMode.auto &&
        state == LocalRemoteConnectionState.connected) {
      _replayRetryCount = 0;
      _resumeRemoteSubscriptions();
      _runDetached(_startReplayIfPossible(), 'replay');
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
        _runDetached(
          _handleRemoteQueryEvent(queryState, event),
          'remote-query',
        );
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
        _markRemoteEventSeen(queryState);
        await _writeRemoteSnapshotAndRebasePending(
          queryState.descriptor,
          value,
          emit: true,
        );
      case LocalRemoteQueryError(:final error):
        _markRemoteEventSeen(queryState);
        _emitToQueryKey(
          queryState.descriptor.key,
          LocalQueryError(
            error,
            source: LocalQuerySource.unknown,
            hasPendingWrites: _hasPendingWrites(queryState.descriptor.key),
          ),
        );
      case LocalRemoteQueryLoading():
        return;
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
    // Snapshot: a synchronous cancel triggered by the emit below mutates
    // `_queryStates` while we iterate it.
    for (final queryState in _queryStates.values.toList(growable: false)) {
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
        _lastRemoteConnectionState != LocalRemoteConnectionState.connected ||
        _pendingMutations.isEmpty) {
      _log(
        'replay:skip',
        'disposed=$_disposed mode=$_networkMode '
            'syncing=$_isSyncing remote=$_lastRemoteConnectionState '
            'pending=${_pendingMutations.length}',
      );
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
      final failedLocalIds = await _mutationQueue.loadFailedLocalIds();
      var iteration = 0;
      while (!_disposed &&
          _pendingMutations.isNotEmpty &&
          _networkMode == LocalNetworkMode.auto) {
        iteration++;
        final mutation = _pendingMutations.first;
        _log(
          'replay:mutation',
          '[$iteration] id=${mutation.id} '
              '${mutation.mutationName} — marking replaying',
        );
        await _mutationQueue.markStatus(
          mutation.id,
          PendingMutationStatus.replaying,
        );
        _pendingMutations = await _mutationQueue.loadAll();
        _pendingMutationsController.add(currentPendingMutations);

        // Remap any local IDs in args to server IDs.
        final remappedArgs =
            _remapIds(mutation.args, idRemaps) as Map<String, dynamic>;
        final unresolvedLocalIds = _unresolvedLocalIds(
          remappedArgs,
          idRemaps,
          _knownGeneratedLocalIds(
            _pendingMutations,
            failedLocalIds,
            beforeMutationId: mutation.id,
          ),
        );
        if (unresolvedLocalIds.isNotEmpty) {
          final error = StateError(
            'Cannot replay ${mutation.mutationName} with unresolved local '
            'ID(s): ${unresolvedLocalIds.join(', ')}',
          );
          _log('replay:unresolved-local-id', '[$iteration] ${error.message}');
          final failedLocalId = await _dropFailedMutation(mutation, error);
          if (failedLocalId != null) {
            failedLocalIds.add(failedLocalId);
          }
          continue;
        }
        if (!const DeepCollectionEquality().equals(
          remappedArgs,
          mutation.args,
        )) {
          _log('replay:remap', '[$iteration] remapped args');
          await _mutationQueue.updateArgs(mutation.id, remappedArgs);
        }

        try {
          _log('replay:mutate', '[$iteration] calling _remoteClient.mutate…');
          final result = await _remoteClient.mutate(
            mutation.mutationName,
            remappedArgs,
          );
          if (_disposed) {
            _log('replay:disposed', '[$iteration] stopping after mutate');
            break;
          }
          _log('replay:mutate-ok', '[$iteration] remote mutate succeeded');

          // Capture ID mapping: if this mutation produced a local operationId
          // and the server returned the real document ID, record it.
          final operationId = mutation.optimisticData?['operationId'];
          final serverId = _extractServerId(result);
          if (operationId is String &&
              _isGeneratedLocalId(operationId) &&
              serverId != null) {
            idRemaps[operationId] = serverId;
            await _mutationQueue.saveIdRemap(operationId, serverId);
            _log('replay:id-remap', '[$iteration] $operationId → $serverId');
          }

          await _mutationQueue.remove(mutation.id);
          _pendingMutations = await _mutationQueue.loadAll();
          _rebuildPendingWriteCounts();
          _pendingMutationsController.add(currentPendingMutations);
          // Fire-and-forget: the widget tree subscriptions already receive
          // live Transition updates, so blocking the replay loop for a cache
          // refresh is unnecessary; the widget tree subscriptions already get
          // live updates through the normal Transition flow.
          _runDetached(_refreshTargetsFromMutation(mutation), 'refresh');
          _replayRetryCount = 0;
        } on ConvexException catch (error) {
          if (_disposed) {
            _log('replay:disposed', '[$iteration] stopping after error');
            break;
          }
          _log(
            'replay:convex-error',
            '[$iteration] ${error.message} '
                '(retryable=${error.retryable})',
          );
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
          final failedLocalId = await _dropFailedMutation(mutation, error);
          if (failedLocalId != null) {
            failedLocalIds.add(failedLocalId);
          }
        } catch (error, stack) {
          if (_disposed) {
            _log('replay:disposed', '[$iteration] stopping after error');
            break;
          }
          _log('replay:error', '[$iteration] $error\n$stack');
          if (_shouldQueueRemoteFailure(error)) {
            await _mutationQueue.markStatus(
              mutation.id,
              PendingMutationStatus.pending,
              errorMessage: error.toString(),
            );
            _pendingMutations = await _mutationQueue.loadAll();
            _pendingMutationsController.add(currentPendingMutations);
            hitRetryableError = true;
            break;
          }
          final failedLocalId = await _dropFailedMutation(mutation, error);
          if (failedLocalId != null) {
            failedLocalIds.add(failedLocalId);
          }
        }
      }
      // Clean up remap table when the queue is fully drained.
      if (!_disposed && _pendingMutations.isEmpty) {
        if (idRemaps.isNotEmpty) {
          await _mutationQueue.clearIdRemaps();
        }
        if (failedLocalIds.isNotEmpty) {
          await _mutationQueue.clearFailedLocalIds();
        }
      }
      _log(
        'replay:end',
        'loop finished — ${_pendingMutations.length} '
            'remaining, hitRetryable=$hitRetryableError',
      );
    } finally {
      _isSyncing = false;
      if (!_disposed) {
        _updateConnectionState();
      }
      if (!_disposed && hitRetryableError) {
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
          'in ${delay.inSeconds}s',
    );
    _replayRetryTimer = Timer(delay, () {
      _replayRetryTimer = null;
      if (!_disposed && _networkMode == LocalNetworkMode.auto) {
        _log('replay:retry', 'retry timer fired, starting replay');
        _runDetached(_startReplayIfPossible(), 'replay');
      }
    });
  }

  static Duration _replayRetryDelay(int attempt) {
    // Exponential backoff: 1s, 2s, 4s, 8s, capped at 15s. The exponent is
    // clamped before shifting so the backoff stays monotonic and never wraps
    // (web uses 32-bit left shifts, which would wrap past ~32 retries).
    final exponent = attempt.clamp(0, 4);
    final seconds = 1 << exponent;
    return Duration(seconds: seconds.clamp(1, 15));
  }

  Future<String?> _dropFailedMutation(
    PendingMutation mutation,
    Object error,
  ) async {
    final failedLocalId = _generatedOperationId(mutation);
    if (failedLocalId != null) {
      await _mutationQueue.saveFailedLocalId(failedLocalId);
    }
    await _mutationQueue.remove(mutation.id);
    _pendingMutations = await _mutationQueue.loadAll();
    _rebuildPendingWriteCounts();
    await _restoreMutationRollback(mutation);
    _pendingMutationsController.add(currentPendingMutations);
    try {
      onConflict?.call(
        LocalMutationConflict(
          mutationName: mutation.mutationName,
          args: mutation.args,
          error: error,
          queuedAt: mutation.createdAt,
        ),
      );
    } catch (callbackError, stackTrace) {
      _log('replay:on-conflict-error', '$callbackError\n$stackTrace');
    }
    await _refreshTargetsFromMutation(mutation);
    return failedLocalId;
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
          '${targets.map((t) => t.name).join(', ')}',
    );
    for (final target in targets) {
      try {
        _log('refresh:query', 'querying ${target.name}…');
        final value = await _remoteQueryOnce(
          target,
          timeout: _config.refreshQueryTimeout,
        );
        _log('refresh:query-ok', '${target.name} returned');
        await _writeRemoteSnapshotAndRebasePending(target, value, emit: true);
      } catch (error) {
        _log('refresh:query-error', '${target.name}: $error');
      }
    }
    _log('refresh:done', '${mutation.mutationName} targets refreshed');
  }

  void _markRemoteEventSeen(_LocalQueryState queryState) {
    for (final subscriptionId in queryState.subscriberIds) {
      _subscriptionStates[subscriptionId]?.hasRemoteEvent = true;
    }
  }

  Future<dynamic> _writeRemoteSnapshotAndRebasePending(
    LocalQueryDescriptor target,
    dynamic value, {
    bool emit = false,
  }) async {
    await _queryCache.write(name: target.name, args: target.args, value: value);
    final effectiveValue = await _rebasePendingOptimisticPatchesForTarget(
      target,
      baseValue: value,
    );
    if (emit) {
      _emitToQueryKey(
        target.key,
        LocalQuerySuccess(
          effectiveValue,
          source: LocalQuerySource.remote,
          hasPendingWrites: _hasPendingWrites(target.key),
        ),
      );
    }
    return effectiveValue;
  }

  Future<dynamic> _rebasePendingOptimisticPatchesForTarget(
    LocalQueryDescriptor target, {
    required dynamic baseValue,
  }) async {
    if (!_hasPendingWrites(target.key) || _pendingMutations.isEmpty) {
      return baseValue;
    }

    var currentValue = baseValue;
    var updatedMutationMetadata = false;
    for (final pendingMutation in _pendingMutations) {
      final optimisticData = pendingMutation.optimisticData;
      final operationId = optimisticData?['operationId'];
      if (optimisticData == null || operationId is! String) {
        continue;
      }
      final context = LocalMutationContext(
        operationId: operationId,
        queuedAt: pendingMutation.createdAt,
      );
      final patches =
          _buildPatches(
                pendingMutation.mutationName,
                pendingMutation.args,
                context,
              )
              .where((patch) => patch.target.key == target.key)
              .toList(growable: false);
      if (patches.isEmpty) {
        continue;
      }

      await _mutationQueue.updateOptimisticData(
        pendingMutation.id,
        _replaceRollbackSnapshot(optimisticData, target, value: currentValue),
      );
      updatedMutationMetadata = true;

      try {
        var nextValue = currentValue;
        for (final patch in patches) {
          nextValue = patch.apply(nextValue);
        }
        currentValue = nextValue;
      } catch (error, stackTrace) {
        _log('remote:optimistic-rebase-error', '$error\n$stackTrace');
      }
    }

    await _queryCache.write(
      name: target.name,
      args: target.args,
      value: currentValue,
    );
    if (updatedMutationMetadata) {
      _pendingMutations = await _mutationQueue.loadAll();
      _rebuildPendingWriteCounts();
    }
    return currentValue;
  }

  Future<dynamic> _remoteQueryOnce(
    LocalQueryDescriptor target, {
    required Duration timeout,
  }) {
    final completer = Completer<dynamic>();
    final subscription = _remoteClient.subscribe(target.name, target.args);
    StreamSubscription<LocalRemoteQueryEvent>? eventSubscription;
    Timer? timer;

    void cleanup() {
      timer?.cancel();
      unawaited(eventSubscription?.cancel());
      subscription.cancel();
    }

    void completeError(Object error, [StackTrace? stackTrace]) {
      if (completer.isCompleted) {
        return;
      }
      cleanup();
      if (stackTrace == null) {
        completer.completeError(error);
      } else {
        completer.completeError(error, stackTrace);
      }
    }

    timer = Timer(timeout, () {
      completeError(
        TimeoutException(
          'Remote query "${target.name}" timed out after '
          '${timeout.inMilliseconds}ms',
          timeout,
        ),
      );
    });
    eventSubscription = subscription.stream.listen((event) {
      if (completer.isCompleted) {
        return;
      }
      switch (event) {
        case LocalRemoteQuerySuccess(:final value):
          cleanup();
          completer.complete(value);
        case LocalRemoteQueryError(:final error):
          completeError(error);
        case LocalRemoteQueryLoading():
          break;
      }
    }, onError: completeError);

    return completer.future;
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

  Future<List<_CacheSnapshot>> _snapshotOptimisticPatchTargets(
    List<LocalMutationPatch> patches,
  ) async {
    final snapshots = <String, _CacheSnapshot>{};
    for (final patch in patches) {
      final key = patch.target.key;
      if (snapshots.containsKey(key)) {
        continue;
      }
      snapshots[key] = _CacheSnapshot(
        target: patch.target,
        entry: await _queryCache.read(patch.target.name, patch.target.args),
      );
    }
    return snapshots.values.toList(growable: false);
  }

  Future<void> _applyOptimisticPatches(
    List<LocalMutationPatch> patches, {
    Iterable<_CacheSnapshot>? snapshots,
  }) async {
    final snapshotByKey = <String, _CacheSnapshot>{
      for (final snapshot in snapshots ?? const <_CacheSnapshot>[])
        snapshot.target.key: snapshot,
    };
    final workingValues = <String, dynamic>{};
    final updates = <String, _CacheUpdate>{};
    try {
      for (final patch in patches) {
        final key = patch.target.key;
        snapshotByKey[key] ??= _CacheSnapshot(
          target: patch.target,
          entry: await _queryCache.read(patch.target.name, patch.target.args),
        );
        final currentValue = workingValues.containsKey(key)
            ? workingValues[key]
            : snapshotByKey[key]?.entry?.value;
        final nextValue = patch.apply(currentValue);
        workingValues[key] = nextValue;
        updates[key] = _CacheUpdate(target: patch.target, value: nextValue);
      }
      for (final update in updates.values) {
        await _queryCache.write(
          name: update.target.name,
          args: update.target.args,
          value: update.value,
        );
      }
    } catch (_) {
      await _restoreOptimisticPatchSnapshots(snapshotByKey.values);
      rethrow;
    }
  }

  Future<void> _restoreOptimisticPatchSnapshots(
    Iterable<_CacheSnapshot> snapshots,
  ) async {
    for (final snapshot in snapshots) {
      final entry = snapshot.entry;
      if (entry == null) {
        await _config.cacheStorage.deleteCacheEntry(snapshot.target.key);
        continue;
      }
      await _queryCache.write(
        name: snapshot.target.name,
        args: snapshot.target.args,
        value: entry.value,
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
      _runDetached(_emitCachedSnapshot(queryState.descriptor), 'cache-emit');
    }
  }

  Future<void> _restoreMutationRollback(PendingMutation mutation) async {
    final snapshots = _rollbackSnapshotsFromMutation(mutation);
    if (snapshots.isEmpty) {
      return;
    }
    try {
      await _restoreOptimisticPatchSnapshots(snapshots);
    } catch (error, stackTrace) {
      _log('replay:rollback-error', '$error\n$stackTrace');
      return;
    }
    final restoredKeys = snapshots
        .map((snapshot) => snapshot.target.key)
        .toSet();
    final reappliedPatches = await _reapplyPendingOptimisticPatchesForTargets(
      restoredKeys,
    );
    final reappliedKeys = reappliedPatches
        .map((patch) => patch.target.key)
        .toSet();
    for (final snapshot in snapshots) {
      if (!reappliedKeys.contains(snapshot.target.key)) {
        _emitRestoredSnapshot(snapshot);
      }
    }
    _emitPendingWriteUpdatesForTargets(reappliedPatches);
  }

  Future<List<LocalMutationPatch>> _reapplyPendingOptimisticPatchesForTargets(
    Set<String> targetKeys,
  ) async {
    if (targetKeys.isEmpty || _pendingMutations.isEmpty) {
      return const <LocalMutationPatch>[];
    }
    final reapplied = <LocalMutationPatch>[];
    var rebasedRollbackMetadata = false;
    for (final pendingMutation in _pendingMutations) {
      final operationId = pendingMutation.optimisticData?['operationId'];
      if (operationId is! String) {
        continue;
      }
      final context = LocalMutationContext(
        operationId: operationId,
        queuedAt: pendingMutation.createdAt,
      );
      final patches =
          _buildPatches(
                pendingMutation.mutationName,
                pendingMutation.args,
                context,
              )
              .where((patch) => targetKeys.contains(patch.target.key))
              .toList(growable: false);
      if (patches.isEmpty) {
        continue;
      }
      // The restored baseline no longer contains the just-dropped mutation, so
      // re-snapshot this surviving mutation's rollback for the restored targets
      // to the current (pre-patch) cache value. Without this, a later rollback
      // of this mutation would restore a baseline that still includes the
      // already-dropped one. The post-drop network refresh does the same
      // rebase, but it is best-effort and may fail.
      if (await _rebaseRollbackSnapshotsForPatches(pendingMutation, patches)) {
        rebasedRollbackMetadata = true;
      }
      try {
        await _applyOptimisticPatches(patches);
        reapplied.addAll(patches);
      } catch (error, stackTrace) {
        _log('replay:rollback-reapply-error', '$error\n$stackTrace');
      }
    }
    if (rebasedRollbackMetadata) {
      _pendingMutations = await _mutationQueue.loadAll();
      _rebuildPendingWriteCounts();
    }
    return reapplied;
  }

  /// Re-snapshots [mutation]'s persisted rollback baseline for every distinct
  /// target in [patches] to the current cache value, returning whether the
  /// metadata was rewritten.
  ///
  /// Used while reapplying surviving optimistic writes after an older mutation
  /// is rolled back, so a later rollback of [mutation] restores the
  /// post-rollback baseline rather than one that still includes the dropped
  /// mutation.
  Future<bool> _rebaseRollbackSnapshotsForPatches(
    PendingMutation mutation,
    List<LocalMutationPatch> patches,
  ) async {
    final optimisticData = mutation.optimisticData;
    if (optimisticData == null) {
      return false;
    }
    var updated = optimisticData;
    final seenKeys = <String>{};
    for (final patch in patches) {
      final target = patch.target;
      if (!seenKeys.add(target.key)) {
        continue;
      }
      final entry = await _queryCache.read(target.name, target.args);
      updated = _withRollbackSnapshot(
        updated,
        _CacheSnapshot(target: target, entry: entry),
      );
    }
    if (identical(updated, optimisticData)) {
      return false;
    }
    await _mutationQueue.updateOptimisticData(mutation.id, updated);
    return true;
  }

  void _emitRestoredSnapshot(_CacheSnapshot snapshot) {
    final key = snapshot.target.key;
    final entry = snapshot.entry;
    if (entry == null) {
      _emitToQueryKey(
        key,
        LocalQueryError(
          StateError(
            'No cached query value remains after rolling back failed mutation',
          ),
          source: LocalQuerySource.cache,
          hasPendingWrites: _hasPendingWrites(key),
        ),
      );
      return;
    }
    _emitToQueryKey(
      key,
      LocalQuerySuccess(
        entry.value,
        source: LocalQuerySource.cache,
        hasPendingWrites: _hasPendingWrites(key),
      ),
    );
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
    Iterable<_CacheSnapshot> rollbackSnapshots,
  ) {
    return <String, dynamic>{
      'operationId': context.operationId,
      'targets': patches
          .map((patch) => patch.target.toJson())
          .toList(growable: false),
      'rollback': rollbackSnapshots
          .map(_cacheSnapshotToJson)
          .toList(growable: false),
    };
  }

  Map<String, dynamic> _cacheSnapshotToJson(_CacheSnapshot snapshot) {
    final entry = snapshot.entry;
    return <String, dynamic>{
      'target': snapshot.target.toJson(),
      'hasEntry': entry != null,
      if (entry != null) 'value': entry.value,
    };
  }

  Map<String, dynamic> _replaceRollbackSnapshot(
    Map<String, dynamic> optimisticData,
    LocalQueryDescriptor target, {
    required dynamic value,
  }) {
    return _withRollbackSnapshot(
      optimisticData,
      _CacheSnapshot(
        target: target,
        entry: CachedQueryEntry(
          key: target.key,
          queryName: target.name,
          args: target.args,
          value: value,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
      ),
    );
  }

  /// Replaces (or appends) the persisted rollback snapshot for
  /// [snapshot.target] inside [optimisticData], leaving every other target's
  /// snapshot untouched. A null [snapshot.entry] is preserved as an absent
  /// baseline (`hasEntry: false`), matching the enqueue-time snapshot format.
  Map<String, dynamic> _withRollbackSnapshot(
    Map<String, dynamic> optimisticData,
    _CacheSnapshot snapshot,
  ) {
    final replacement = _cacheSnapshotToJson(snapshot);
    final rawRollback = optimisticData['rollback'];
    final rollback = rawRollback is List
        ? rawRollback.toList(growable: true)
        : <dynamic>[];
    var replaced = false;
    for (var index = 0; index < rollback.length; index++) {
      final rawSnapshot = rollback[index];
      if (rawSnapshot is! Map) {
        continue;
      }
      final rawTarget = rawSnapshot['target'];
      if (rawTarget is! Map) {
        continue;
      }
      final snapshotTarget = LocalQueryDescriptor.fromJson(
        rawTarget.cast<String, dynamic>(),
      );
      if (snapshotTarget.key == snapshot.target.key) {
        rollback[index] = replacement;
        replaced = true;
      }
    }
    if (!replaced) {
      rollback.add(replacement);
    }
    return <String, dynamic>{...optimisticData, 'rollback': rollback};
  }

  Iterable<LocalQueryDescriptor> _targetsFromMutation(
    PendingMutation mutation,
  ) {
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
        .map(
          (entry) =>
              LocalQueryDescriptor.fromJson(entry.cast<String, dynamic>()),
        )
        .toList(growable: false);
  }

  List<_CacheSnapshot> _rollbackSnapshotsFromMutation(
    PendingMutation mutation,
  ) {
    final optimisticData = mutation.optimisticData;
    if (optimisticData == null) {
      return const <_CacheSnapshot>[];
    }
    final rollback = optimisticData['rollback'];
    if (rollback is! List) {
      return const <_CacheSnapshot>[];
    }
    final snapshots = <_CacheSnapshot>[];
    for (final rawSnapshot in rollback.whereType<Map>()) {
      final rawTarget = rawSnapshot['target'];
      if (rawTarget is! Map) {
        continue;
      }
      final target = LocalQueryDescriptor.fromJson(
        rawTarget.cast<String, dynamic>(),
      );
      final hasEntry = rawSnapshot['hasEntry'] == true;
      snapshots.add(
        _CacheSnapshot(
          target: target,
          entry: hasEntry
              ? CachedQueryEntry(
                  key: target.key,
                  queryName: target.name,
                  args: target.args,
                  value: rawSnapshot['value'],
                  updatedAt: DateTime.fromMillisecondsSinceEpoch(
                    0,
                    isUtc: true,
                  ),
                )
              : null,
        ),
      );
    }
    return snapshots;
  }

  void _rebuildPendingWriteCounts() {
    _pendingWritesByQueryKey.clear();
    for (final mutation in _pendingMutations) {
      for (final target in _targetsFromMutation(mutation)) {
        _pendingWritesByQueryKey.update(
          target.key,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }
  }

  bool _hasPendingWrites(String queryKey) {
    return (_pendingWritesByQueryKey[queryKey] ?? 0) > 0;
  }

  bool _shouldQueueRemoteFailure(Object error) {
    if (error is TimeoutException) {
      return true;
    }
    return _lastRemoteConnectionState != LocalRemoteConnectionState.connected;
  }

  void _emitToQueryKey(String queryKey, LocalQueryEvent event) {
    final queryState = _queryStates[queryKey];
    if (queryState == null) {
      return;
    }
    // Iterate a snapshot: the controllers are synchronous broadcast streams, so
    // a listener that cancels (or re-subscribes the same query) while receiving
    // this event would mutate `subscriberIds` mid-iteration and throw a
    // ConcurrentModificationError. Cancelled subscribers are skipped via the
    // `_subscriptionStates` lookup below.
    for (final subscriptionId in queryState.subscriberIds.toList(
      growable: false,
    )) {
      _subscriptionStates[subscriptionId]?.controller.add(event);
    }
  }

  String _nextOperationId() {
    _operationCounter += 1;
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return 'local-$micros-$_operationCounter';
  }

  static String? _generatedOperationId(PendingMutation mutation) {
    final operationId = mutation.optimisticData?['operationId'];
    if (operationId is String && _isGeneratedLocalId(operationId)) {
      return operationId;
    }
    return null;
  }

  static Set<String> _knownGeneratedLocalIds(
    Iterable<PendingMutation> mutations,
    Set<String> failedLocalIds, {
    required int beforeMutationId,
  }) {
    final ids = <String>{...failedLocalIds};
    for (final mutation in mutations) {
      if (mutation.id >= beforeMutationId) {
        continue;
      }
      final operationId = _generatedOperationId(mutation);
      if (operationId != null) {
        ids.add(operationId);
      }
    }
    return ids;
  }

  static String? _extractServerId(dynamic result) {
    if (result is String && result.isNotEmpty) {
      return result;
    }
    if (result is Map) {
      final id = result['_id'];
      if (id is String && id.isNotEmpty) {
        return id;
      }
      final fallbackId = result['id'];
      if (fallbackId is String && fallbackId.isNotEmpty) {
        return fallbackId;
      }
    }
    return null;
  }

  void _updateConnectionState() {
    final nextState = switch (_networkMode) {
      LocalNetworkMode.offline => LocalConnectionState.offline,
      LocalNetworkMode.auto =>
        _isSyncing
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
    if (value is Map) {
      // Remap both keys and values: an offline mutation can reference a
      // freshly-created local ID as an object key (e.g. a per-document map),
      // not only as a value. A key that is a resolved local ID is rewritten to
      // its server ID; any other key passes through unchanged.
      return <String, dynamic>{
        for (final entry in value.entries)
          (idMap[entry.key.toString()] ?? entry.key.toString()): _remapIds(
            entry.value,
            idMap,
          ),
      };
    }
    if (value is List) return value.map((i) => _remapIds(i, idMap)).toList();
    return value;
  }

  static final RegExp _generatedLocalIdPattern = RegExp(r'^local-\d+-\d+$');

  static bool _isGeneratedLocalId(String value) =>
      _generatedLocalIdPattern.hasMatch(value);

  static List<String> _unresolvedLocalIds(
    dynamic value,
    Map<String, String> idMap,
    Set<String> knownLocalIds,
  ) {
    final ids = <String>{};

    void visit(dynamic item) {
      if (item is String) {
        if (knownLocalIds.contains(item) && !idMap.containsKey(item)) {
          ids.add(item);
        }
        return;
      }
      if (item is Map) {
        // Keys can carry local IDs too (see _remapIds), so an unresolved local
        // ID used as a key must also block replay of the dependent mutation.
        for (final entry in item.entries) {
          visit(entry.key);
          visit(entry.value);
        }
        return;
      }
      if (item is Iterable) {
        for (final entry in item) {
          visit(entry);
        }
      }
    }

    visit(value);
    return ids.toList(growable: false);
  }

  void _log(String tag, String message) {
    final logger = _config.logger;
    if (logger == null || _config.logLevel == DartvexLogLevel.off) {
      return;
    }
    if (DartvexLogLevel.debug.index > _config.logLevel.index) {
      return;
    }
    logger(
      DartvexLogEvent(
        level: DartvexLogLevel.debug,
        message: message,
        tag: 'local.$tag',
      ),
    );
  }

  void _runDetached(Future<void> future, String tag) {
    unawaited(
      future.catchError((Object error, StackTrace stackTrace) {
        if (_disposed) {
          return;
        }
        _log('$tag:error', '$error\n$stackTrace');
      }),
    );
  }

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

    // Materialize before closing: closing a controller can synchronously run a
    // listener's onDone that cancels its subscription, mutating
    // `_subscriptionStates` while this lazy view is still being iterated.
    final controllers = _subscriptionStates.values
        .map((state) => state.controller)
        .toList(growable: false);
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

    if (_disposeRemoteClient) {
      _remoteClient.dispose();
    }
  }
}

class _LocalQueryState {
  _LocalQueryState(this.descriptor);

  final LocalQueryDescriptor descriptor;
  final Set<int> subscriberIds = <int>{};
  LocalRemoteSubscription? remoteSubscription;
  StreamSubscription<LocalRemoteQueryEvent>? remoteEventSubscription;
}

class _CacheSnapshot {
  const _CacheSnapshot({required this.target, required this.entry});

  final LocalQueryDescriptor target;
  final CachedQueryEntry? entry;
}

class _CacheUpdate {
  const _CacheUpdate({required this.target, required this.value});

  final LocalQueryDescriptor target;
  final dynamic value;
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
  bool hasRemoteEvent = false;
}
