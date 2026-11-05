import 'dart:async';
import 'dart:typed_data';

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
  /// The remote connection is established and remote traffic is served
  /// normally.
  online,

  /// The client is offline: either forced offline with
  /// [LocalNetworkMode.offline], or the remote is not connected (still
  /// connecting, reconnecting, or disconnected). Mutations issued in this
  /// state are queued.
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
  const LocalRemoteQuerySuccess(this.value, {this.isSeed = false});

  /// The returned query value.
  final dynamic value;

  /// Whether the remote client delivered this value from its own local state
  /// when the subscription started, instead of as a server result received
  /// after subscribing.
  ///
  /// Such a seed (for example the core client's last known value for a query
  /// that was unsubscribed earlier) can predate recent writes. The local
  /// client does not treat seeds as confirmation of a just-replayed mutation.
  /// Custom [LocalRemoteClient] implementations may leave this `false`.
  final bool isSeed;
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
///
/// When the remote becomes permanently unusable (closed or disposed), an
/// implementation should report [LocalRemoteConnectionState.disconnected]
/// before failing pending calls, so replay keeps the queued mutations instead
/// of treating those failures as server rejections.
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

/// Mutation result produced when a mutation sent directly (not queued) fails.
///
/// This covers non-retryable remote errors on the online fast path, and a
/// direct send that failed after it stopped blocking later calls (see
/// [ConvexLocalClient.mutate]). Local failures while queueing (a throwing
/// [LocalMutationHandler] or patch, or a storage/codec error) are thrown from
/// [ConvexLocalClient.mutate] instead. Queued mutations that the server later
/// rejects are reported through [ConvexLocalClient.onConflict].
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
    this.pendingMutationId,
    this.operationId,
  });

  /// Storage identifier of the dropped queue entry; matches
  /// [PendingMutation.id] of the [LocalMutationQueued.pendingMutation] that
  /// [ConvexLocalClient.mutate] returned.
  final int? pendingMutationId;

  /// Local operation identifier of the dropped mutation; matches
  /// [LocalMutationContext.operationId] passed to its handler.
  final String? operationId;

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
    this.onConflict,
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
  ///
  /// Handlers are matched by canonical mutation name (`messages.js:send` and
  /// `messages:send` are the same mutation). Several handlers may be registered
  /// for one mutation, for example one per affected query; their patches are
  /// applied in registration order.
  ///
  /// Patches only apply when a mutation is queued (offline, behind queued
  /// mutations, or after a retryable failure). A mutation sent directly while
  /// online is not patched locally; use the core client's optimistic updates
  /// for instant feedback on that path.
  final List<LocalMutationHandler> mutationHandlers;

  /// Initial network mode applied when the client opens.
  final LocalNetworkMode initialNetworkMode;

  /// Maximum time spent waiting for a one-shot remote result when the local
  /// client cannot rely on an established connection.
  ///
  /// Bounds the cache refresh after replay and [ConvexLocalClient.query] calls
  /// made while the remote is not connected and nothing is cached.
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

  /// Initial value of [ConvexLocalClient.onConflict].
  ///
  /// Pass the callback here rather than assigning it after
  /// [ConvexLocalClient.open] returns: replay can start while the client
  /// opens, and a conflict reported before the callback is set is not
  /// delivered.
  final void Function(LocalMutationConflict conflict)? onConflict;
}

/// Offline-first client that layers cache and mutation replay onto Dartvex.
///
/// ## Identity
///
/// The query cache and the mutation queue are not scoped to a signed-in user:
/// cache keys are the query name and arguments, and queued mutations are
/// replayed with whatever auth the remote client has when they are sent.
/// Apps that support sign-out or switching accounts on one device should:
///
/// * apply auth to the [ConvexClient] (for example `login` or
///   `loginFromCache`) before, or right after, calling [open], so replay does
///   not run unauthenticated once the socket connects; and
/// * call [reset] on an explicit sign-out or user switch, so the next user
///   neither sees the previous user's cached results nor replays their queued
///   mutations.
///
/// The client deliberately does not clear anything on its own when the auth
/// state changes: a transient token-refresh failure must not discard the
/// user's offline work.
class ConvexLocalClient {
  ConvexLocalClient._(
    this._remoteClient,
    this._config,
    this._queryCache,
    this._mutationQueue,
    this._disposeRemoteClient,
  ) : _networkMode = _config.initialNetworkMode,
      _currentConnectionState = LocalConnectionState.online,
      _lastRemoteConnectionState = _remoteClient.currentConnectionState,
      onConflict = _config.onConflict;

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

  final Map<String, List<LocalMutationHandler>> _mutationHandlersByName =
      <String, List<LocalMutationHandler>>{};
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

  // Local-to-server document ID mappings recorded by replay. They are kept
  // after the queue drains (cached optimistic documents and app state can
  // still hold the local IDs) and applied to direct sends as well as replay;
  // clearQueue() and reset() discard them.
  Map<String, String> _idRemaps = <String, String>{};

  // Settles when the direct (fast path) mutation currently in flight settles.
  // Replay waits for it so later queued mutations still commit after it.
  Future<void>? _directInFlight;

  // Releases the FIFO mutate chain held by the direct mutation in flight. It
  // is completed early when the remote stops being connected or the client is
  // forced offline: the core client keeps (and replays) that request, so
  // later mutate() calls must not wait for the reconnect to be queued.
  Completer<void>? _directChainRelease;

  // Results of replayed mutations that the server committed but whose local
  // queue bookkeeping failed (storage error). Replay retries the bookkeeping
  // for these entries instead of sending them again.
  final Map<int, Object?> _committedReplayResults = <int, Object?>{};

  // Serializes mutate() calls so concurrent mutations are applied in FIFO call
  // order and cannot race the "send directly while the queue is empty" fast
  // path into committing out of order. A direct send releases the chain early
  // when it is detached (see _directChainRelease).
  Future<void> _mutateChain = Future<void>.value();

  // Serializes setNetworkMode() transitions: the offline transition suspends
  // remote subscriptions across several microtasks, and an immediately
  // following auto transition used to interleave with that loop —
  // re-attaching some queries mid-suspension while the rest were detached
  // after the resume, leaving them unsubscribed in auto mode.
  Future<void> _networkModeChain = Future<void>.value();

  // Serializes write-rebase sequences per query key: a remote snapshot write
  // and its pending-patch rebase span several awaits, and two rapid remote
  // events for the same query used to interleave those spans — when the
  // rebase iterations diverged (a replay removing a pending mutation
  // mid-flight), the older event's final write could land after the newer
  // one's, leaving a stale rebased value in the cache and as the subscribers'
  // latest emission until the next remote event. Remote error emissions, the
  // optimistic snapshot/apply of a queued mutation, rollbacks and cached
  // snapshot emissions join the same per-key chains (see _runOnKeyChains).
  // Entries are removed once their chain drains, so one-shot query() keys do
  // not accumulate.
  final Map<String, Future<void>> _snapshotChainsByKey =
      <String, Future<void>>{};

  /// Callback invoked when replay drops a permanently failed queued mutation.
  ///
  /// Initialized from [LocalClientConfig.onConflict]. Replay can start while
  /// the client opens, so set the callback through the config to receive
  /// conflicts reported before [open] returns.
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
      _mutationHandlersByName
          .putIfAbsent(
            canonicalizeQueryName(handler.mutationName),
            () => <LocalMutationHandler>[],
          )
          .add(handler);
    }

    _pendingMutations = await _mutationQueue.loadAll();
    // A crash or dispose in the middle of replay leaves the row it was sending
    // marked as replaying; nothing is replaying it now.
    final staleReplaying = _pendingMutations
        .where((mutation) => mutation.status == PendingMutationStatus.replaying)
        .toList(growable: false);
    for (final mutation in staleReplaying) {
      await _mutationQueue.markStatus(
        mutation.id,
        PendingMutationStatus.pending,
        errorMessage: mutation.errorMessage,
      );
    }
    if (staleReplaying.isNotEmpty) {
      _pendingMutations = await _mutationQueue.loadAll();
    }
    _idRemaps = await _mutationQueue.loadIdRemaps();
    _rebuildPendingWriteCounts();
    // The connection state captured in the constructor can be stale: a
    // transition during the storage loads above was broadcast before this
    // client listened.
    _lastRemoteConnectionState = _remoteClient.currentConnectionState;
    _remoteConnectionSubscription = _remoteClient.connectionState.listen(
      _handleRemoteConnectionState,
      onError: _handleRemoteConnectionError,
    );

    _networkModeController.add(_networkMode);
    _pendingMutationsController.add(currentPendingMutations);
    _updateConnectionState();
    _runDetached(_startReplayIfPossible(), 'replay');
  }

  /// Executes a query, falling back to cache when possible.
  ///
  /// When forced offline, only the cache is read. In auto mode:
  ///
  /// * while the remote is connected, the remote result is returned (and
  ///   cached); a retryable remote failure falls back to the cache;
  /// * while the remote is not connected, a cached value is returned right
  ///   away; without one, the remote result is awaited for at most
  ///   [LocalClientConfig.refreshQueryTimeout] before a [TimeoutException] is
  ///   thrown.
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    _assertNotDisposed();
    final descriptor = LocalQueryDescriptor(name, _snapshotArgs(args));
    if (_networkMode == LocalNetworkMode.offline) {
      final cached = await _queryCache.read(descriptor.name, descriptor.args);
      if (cached != null) {
        return cached.value;
      }
      throw StateError('No cached value available for $name while offline');
    }

    if (_lastRemoteConnectionState != LocalRemoteConnectionState.connected) {
      return _queryWhileDisconnected(descriptor);
    }

    try {
      final value = await _remoteClient.query(descriptor.name, descriptor.args);
      return await _writeRemoteSnapshotAndRebasePending(descriptor, value);
    } on ConvexException catch (error) {
      if (!error.retryable) {
        rethrow;
      }
      final cached = await _queryCache.read(descriptor.name, descriptor.args);
      if (cached != null) {
        return cached.value;
      }
      rethrow;
    } catch (error) {
      if (!_shouldQueueRemoteFailure(error)) {
        rethrow;
      }
      final cached = await _queryCache.read(descriptor.name, descriptor.args);
      if (cached != null) {
        return cached.value;
      }
      rethrow;
    }
  }

  Future<dynamic> _queryWhileDisconnected(
    LocalQueryDescriptor descriptor,
  ) async {
    final cached = await _queryCache.read(descriptor.name, descriptor.args);
    if (cached != null) {
      return cached.value;
    }
    // A one-shot query on a disconnected core client waits for the server
    // without bound. Use a cancellable subscription so the wait is bounded and
    // the remote subscription is released on timeout.
    final dynamic value;
    try {
      value = await _remoteQueryOnce(
        descriptor,
        timeout: _config.refreshQueryTimeout,
        acceptSeed: true,
      );
    } on TimeoutException {
      final late = await _queryCache.read(descriptor.name, descriptor.args);
      if (late != null) {
        return late.value;
      }
      rethrow;
    }
    return _writeRemoteSnapshotAndRebasePending(descriptor, value);
  }

  /// Subscribes to a query with cache seeding and optional remote updates.
  LocalSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    _assertNotDisposed();
    final descriptor = LocalQueryDescriptor(name, _snapshotArgs(args));
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
  /// In auto mode, with the remote connected and nothing queued, the mutation
  /// is sent directly and resolves with [LocalMutationSuccess], or
  /// [LocalMutationFailed] for a non-retryable remote error. Otherwise (forced
  /// offline, remote not connected, queued mutations still pending, or a
  /// retryable failure of the direct send) it is persisted to the queue, its
  /// [LocalMutationHandler] patches are applied to the cache, and it resolves
  /// with [LocalMutationQueued]. Handler patches are not applied to mutations
  /// sent directly.
  ///
  /// Throws (instead of returning [LocalMutationFailed]) when queueing fails
  /// locally: a handler or patch that throws, or a storage or codec error. The
  /// mutation is then not queued.
  ///
  /// Queued mutations are replayed at least once. If a connection fails after
  /// the backend commits a mutation but before the client observes the result,
  /// replay may call the mutation again. Design queued Convex mutations to be
  /// idempotent when the operation can have external side effects.
  ///
  /// Calls are serialized in FIFO order: a mutation does not start until the
  /// previous one has settled (sent directly or queued). This keeps concurrent
  /// mutations from racing the empty-queue fast path and committing out of
  /// order; mutations awaited sequentially are unaffected. A direct send that
  /// is still in flight when the remote disconnects (or the client is forced
  /// offline) stops blocking later calls, which are queued instead; the remote
  /// client keeps and resends that request, and replay waits for it before
  /// sending the queue. If such a detached send then fails with a retryable
  /// error, it resolves with [LocalMutationFailed] rather than being queued
  /// behind later mutations.
  Future<LocalMutationResult> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    _assertNotDisposed();
    final normalizedArgs = _snapshotArgs(args);
    final chainRelease = Completer<void>();
    final result = _mutateChain.then(
      (_) => _mutateInternal(name, normalizedArgs, chainRelease),
    );
    // Keep the chain alive across failures without leaking a prior call's error
    // to the next caller. The chain is released when this call settles, or
    // earlier when its direct send is detached (see _directChainRelease).
    unawaited(
      result.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
        if (!chainRelease.isCompleted) {
          chainRelease.complete();
        }
      }),
    );
    _mutateChain = chainRelease.future;
    return result;
  }

  Future<LocalMutationResult> _mutateInternal(
    String name,
    Map<String, dynamic> normalizedArgs,
    Completer<void> chainRelease,
  ) async {
    _assertNotDisposed();
    var queuedAfterRetryableFailure = false;
    if (_networkMode == LocalNetworkMode.auto &&
        _lastRemoteConnectionState == LocalRemoteConnectionState.connected &&
        _pendingMutations.isEmpty &&
        !_isSyncing &&
        _replayRetryTimer == null &&
        _directInFlight == null) {
      _log('mutate', '$name — mode=auto, trying remote first');
      final Map<String, dynamic> remoteArgs;
      try {
        // A local ID whose producer already synced must be sent as its server
        // ID, exactly as replay would.
        remoteArgs =
            _remapIds(normalizedArgs, _idRemaps) as Map<String, dynamic>;
      } on _LocalIdRemapCollision catch (error) {
        return LocalMutationFailed(error);
      }
      final direct = await _sendDirect(name, remoteArgs, chainRelease);
      if (direct != null) {
        return direct;
      }
      queuedAfterRetryableFailure = true;
    } else if (_networkMode == LocalNetworkMode.auto &&
        _lastRemoteConnectionState == LocalRemoteConnectionState.connected) {
      _log(
        'mutate',
        '$name — queueing behind replay work '
            '(remote=$_lastRemoteConnectionState '
            'syncing=$_isSyncing pending=${_pendingMutations.length} '
            'direct=${_directInFlight != null})',
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
    // Serialized with remote snapshot writes for the same keys, so a remote
    // write cannot land between the snapshot read and the patched write.
    final pendingMutation = await _runOnKeyChains(
      patches.map((patch) => patch.target.key),
      () async {
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
        return pendingMutation;
      },
    );
    if (!_disposed) {
      _pendingMutationsController.add(currentPendingMutations);
      _emitPendingWriteUpdatesForTargets(patches);
      _updateConnectionState();
      _ensureReplayScheduled(
        afterRetryableFailure: queuedAfterRetryableFailure,
      );
    }

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

  /// Sends [name] directly while holding the mutate chain.
  ///
  /// Returns the final result, or null when the mutation should fall through
  /// to the queue (a retryable failure while the chain is still held).
  Future<LocalMutationResult?> _sendDirect(
    String name,
    Map<String, dynamic> args,
    Completer<void> chainRelease,
  ) async {
    final Future<dynamic> remote;
    try {
      remote = _remoteClient.mutate(name, args);
    } catch (error) {
      return _directFailure(name, error, chainRelease);
    }
    final settled = remote.then<void>((_) {}, onError: (Object _) {});
    _directInFlight = settled;
    _directChainRelease = chainRelease;
    try {
      final value = await remote;
      _log('mutate', '$name — remote succeeded');
      return LocalMutationSuccess(value);
    } catch (error) {
      return _directFailure(name, error, chainRelease);
    } finally {
      if (identical(_directInFlight, settled)) {
        _directInFlight = null;
      }
      if (identical(_directChainRelease, chainRelease)) {
        _directChainRelease = null;
      }
    }
  }

  LocalMutationResult? _directFailure(
    String name,
    Object error,
    Completer<void> chainRelease,
  ) {
    final queueable = error is ConvexException
        ? error.retryable
        : _shouldQueueRemoteFailure(error);
    if (!queueable) {
      _log('mutate', '$name — not queueable: $error');
      return LocalMutationFailed(error);
    }
    if (chainRelease.isCompleted) {
      // Later mutate() calls may already be queued; queueing this one now
      // would replay it after them.
      _log('mutate', '$name — detached direct send failed: $error');
      return LocalMutationFailed(error);
    }
    _log('mutate', '$name — retryable failure, falling through to queue');
    return null;
  }

  /// Releases the mutate chain held by a direct send that is still in flight.
  void _detachDirectMutation() {
    final release = _directChainRelease;
    if (release != null && !release.isCompleted) {
      _log('mutate', 'detaching in-flight direct mutation from the chain');
      release.complete();
    }
  }

  /// Makes sure a mutation just queued in auto mode while connected is sent;
  /// otherwise nothing would replay it until the next reconnect.
  void _ensureReplayScheduled({required bool afterRetryableFailure}) {
    if (_networkMode != LocalNetworkMode.auto ||
        _lastRemoteConnectionState != LocalRemoteConnectionState.connected ||
        _isSyncing ||
        _replayRetryTimer != null) {
      return;
    }
    if (afterRetryableFailure) {
      // The direct send just failed; back off before replaying it.
      _scheduleReplayRetry();
    } else {
      _runDetached(_startReplayIfPossible(), 'replay');
    }
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
    final normalizedArgs = _snapshotArgs(args);
    return _remoteClient.action(name, normalizedArgs);
  }

  /// Updates the active network mode.
  Future<void> setNetworkMode(LocalNetworkMode mode) {
    _assertNotDisposed();
    final result = _networkModeChain.then((_) => _setNetworkModeInternal(mode));
    // Keep the chain alive across failures without leaking a prior call's
    // error to the next caller.
    _networkModeChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _setNetworkModeInternal(LocalNetworkMode mode) async {
    // Re-checked here (not only in the public entry): both can change while
    // this transition waits its turn on the chain, and emitting on the
    // closed-after-dispose controller would throw.
    if (_disposed || _networkMode == mode) {
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
      _detachDirectMutation();
      _replayRetryTimer?.cancel();
      _replayRetryTimer = null;
      _replayRetryCount = 0;
      await _suspendRemoteSubscriptions();
      await _emitCachedSnapshotsForActiveQueries();
    } else {
      _resumeRemoteSubscriptions();
      _log('mode', 'subscriptions resumed, starting replay…');
      // Not awaited: replay can block on a mutation that the remote keeps
      // pending until it reconnects, and awaiting it here would hold the mode
      // chain, so a later switch to offline could not take effect (or stop
      // the replay loop) until then.
      _runDetached(_startReplayIfPossible(), 'replay');
    }
    _updateConnectionState();
  }

  /// Clears all locally cached query results.
  ///
  /// Queued mutations keep their pending writes, but their rollback baselines
  /// are cleared too: a later [clearQueue] or replay conflict removes the
  /// affected cache entries instead of writing the cleared values back.
  ///
  /// To discard everything for the current user (for example on sign-out),
  /// use [reset].
  Future<void> clearCache() async {
    _assertNotDisposed();
    await _queryCache.clear();
    await _neutralizeRollbackBaselines();
  }

  /// Rewrites every queued mutation's persisted rollback snapshots as absent
  /// baselines, so cleared cache values cannot be restored from them.
  Future<void> _neutralizeRollbackBaselines() async {
    var updated = false;
    for (final mutation in _pendingMutations) {
      final optimisticData = mutation.optimisticData;
      if (optimisticData == null) {
        continue;
      }
      var neutralized = optimisticData;
      for (final snapshot in _rollbackSnapshotsFromMutation(mutation)) {
        if (snapshot.entry == null) {
          continue;
        }
        neutralized = _withRollbackSnapshot(
          neutralized,
          _CacheSnapshot(target: snapshot.target, entry: null),
        );
      }
      if (identical(neutralized, optimisticData)) {
        continue;
      }
      if (_disposed) {
        return;
      }
      await _mutationQueue.updateOptimisticData(mutation.id, neutralized);
      updated = true;
    }
    if (updated && !_disposed) {
      _pendingMutations = await _mutationQueue.loadAll();
      _rebuildPendingWriteCounts();
    }
  }

  /// Discards all local state: queued mutations (rolling back their
  /// optimistic patches), recorded ID remaps, and the query cache.
  ///
  /// Call this on an explicit sign-out or user switch, so cached results and
  /// queued mutations of one user are not shown to, or replayed for, the
  /// next. It runs [clearQueue] and then [clearCache]; the client is not
  /// reset automatically when the auth state changes.
  Future<void> reset() async {
    _assertNotDisposed();
    await clearQueue();
    if (_disposed) {
      return;
    }
    await clearCache();
    // Forget what live queries last emitted: it belongs to the previous user
    // and must not seed new subscribers or serve as an optimistic base.
    for (final queryState in _queryStates.values) {
      queryState
        ..lastEvent = null
        ..hasRemoteEvent = false;
    }
  }

  /// Clears the offline mutation queue and resets pending write state.
  ///
  /// The discarded mutations' optimistic patches are rolled back as well:
  /// every affected cached query is restored to its oldest pending rollback
  /// baseline (the last server-confirmed value), so the cache no longer
  /// presents writes that will never be sent as authoritative data. Recorded
  /// local-to-server ID remaps are discarded too.
  Future<void> clearQueue() async {
    _assertNotDisposed();
    // Capture the pre-optimistic baseline per target before discarding the
    // queue: the oldest pending mutation's rollback snapshot for a target is
    // the last server-confirmed value (snapshots are rebased on every remote
    // write and on every drop).
    final baselinesByKey = <String, _CacheSnapshot>{};
    for (final mutation in _pendingMutations) {
      for (final snapshot in _rollbackSnapshotsFromMutation(mutation)) {
        baselinesByKey.putIfAbsent(snapshot.target.key, () => snapshot);
      }
    }
    await _mutationQueue.clear();
    _pendingMutations = const <PendingMutation>[];
    _pendingWritesByQueryKey.clear();
    _idRemaps = <String, String>{};
    _committedReplayResults.clear();
    _pendingMutationsController.add(currentPendingMutations);
    if (baselinesByKey.isNotEmpty) {
      try {
        await _runOnKeyChains(
          baselinesByKey.keys,
          () => _restoreOptimisticPatchSnapshots(baselinesByKey.values),
        );
      } catch (error, stackTrace) {
        _log(
          'clear-queue:rollback-error',
          '$error\n$stackTrace',
          level: DartvexLogLevel.warn,
        );
      }
    }
    // Snapshot the query states: emitting below can synchronously cancel a
    // subscription, which removes its query state, mutating `_queryStates`
    // mid-iteration.
    for (final queryState in _queryStates.values.toList(growable: false)) {
      // Re-checked around every await: a dispose() racing this loop closes
      // the storage and the subscription controllers mid-iteration.
      if (_disposed) {
        return;
      }
      final cached = await _queryCache.read(
        queryState.descriptor.name,
        queryState.descriptor.args,
      );
      if (_disposed) {
        return;
      }
      if (cached != null) {
        _emitToQueryKey(
          queryState.descriptor.key,
          LocalQuerySuccess(
            cached.value,
            source: LocalQuerySource.cache,
            hasPendingWrites: false,
          ),
        );
      } else if (baselinesByKey.containsKey(queryState.descriptor.key)) {
        // The rollback deleted an optimistic-only cache entry; tell its
        // subscribers the value is gone instead of leaving the stale
        // optimistic emission as their latest event.
        _emitToQueryKey(
          queryState.descriptor.key,
          LocalQueryError(
            StateError(
              'No cached query value remains after clearing queued mutations',
            ),
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
        // Removed before detaching (which yields): a subscribe() for the same
        // query in that gap must create a fresh state with its own remote
        // subscription, not join this one and then lose it.
        _queryStates.remove(queryState.descriptor.key);
        await _detachRemoteSubscription(queryState);
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
    final key = state.descriptor.key;
    // Other subscribers to this query may already have received remote
    // events that the shared remote subscription will not repeat: an error
    // (never cached), or a value whose cache entry has since expired, been
    // pruned, or been cleared. Replay the latest event to this subscriber.
    final queryState = _queryStates[key];
    final lastEvent = queryState?.lastEvent;
    if (queryState != null &&
        queryState.hasRemoteEvent &&
        lastEvent != null &&
        (cached == null || lastEvent is LocalQueryError)) {
      state.hasRemoteEvent = true;
      state.controller.add(switch (lastEvent) {
        LocalQuerySuccess(:final value, :final source) => LocalQuerySuccess(
          value,
          source: source,
          hasPendingWrites: _hasPendingWrites(key),
        ),
        LocalQueryError(:final error, :final source) => LocalQueryError(
          error,
          source: source,
          hasPendingWrites: _hasPendingWrites(key),
        ),
      });
      return;
    }
    if (cached != null) {
      state.controller.add(
        LocalQuerySuccess(
          cached.value,
          source: LocalQuerySource.cache,
          hasPendingWrites: _hasPendingWrites(key),
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
          hasPendingWrites: _hasPendingWrites(key),
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
    if (state != LocalRemoteConnectionState.connected) {
      _detachDirectMutation();
    }
    if (_networkMode == LocalNetworkMode.auto &&
        state == LocalRemoteConnectionState.connected) {
      _replayRetryCount = 0;
      _resumeRemoteSubscriptions();
      _runDetached(_startReplayIfPossible(), 'replay');
    }
    _updateConnectionState();
  }

  void _handleRemoteConnectionError(Object error, StackTrace stackTrace) {
    _log('remote-conn:error', '$error\n$stackTrace');
    _lastRemoteConnectionState = LocalRemoteConnectionState.disconnected;
    _detachDirectMutation();
    _updateConnectionState();
  }

  /// Marks the remote as unusable after it reported a closed-client failure,
  /// so replay and the direct path stop until it reports `connected` again.
  void _markRemoteUnavailable() {
    if (_lastRemoteConnectionState == LocalRemoteConnectionState.disconnected) {
      return;
    }
    _lastRemoteConnectionState = LocalRemoteConnectionState.disconnected;
    _detachDirectMutation();
    _updateConnectionState();
  }

  void _ensureRemoteSubscription(_LocalQueryState queryState) {
    if (_networkMode == LocalNetworkMode.offline ||
        queryState.remoteSubscription != null) {
      return;
    }
    final LocalRemoteSubscription subscription;
    try {
      subscription = _remoteClient.subscribe(
        queryState.descriptor.name,
        queryState.descriptor.args,
      );
    } catch (error, stackTrace) {
      _log('remote-subscribe:error', '$error\n$stackTrace');
      _runDetached(
        _emitRemoteSubscribeError(queryState, error),
        'remote-subscribe',
      );
      return;
    }
    queryState.remoteSubscription = subscription;
    queryState.remoteEventSubscription = subscription.stream.listen(
      (event) {
        _runDetached(
          _handleRemoteQueryEvent(queryState, event),
          'remote-query',
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        _runDetached(_emitRemoteQueryError(queryState, error), 'remote-query');
      },
    );
  }

  Future<void> _emitRemoteSubscribeError(
    _LocalQueryState queryState,
    Object error,
  ) async {
    await Future<void>.value();
    if (_disposed ||
        !identical(_queryStates[queryState.descriptor.key], queryState)) {
      return;
    }
    _emitToQueryKey(
      queryState.descriptor.key,
      LocalQueryError(
        error,
        source: LocalQuerySource.unknown,
        hasPendingWrites: _hasPendingWrites(queryState.descriptor.key),
      ),
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
        await _emitRemoteQueryError(queryState, error);
      case LocalRemoteQueryLoading():
        return;
    }
  }

  /// Emits a remote query error after any in-flight snapshot write for the
  /// same query, so an older success cannot be emitted after it.
  Future<void> _emitRemoteQueryError(
    _LocalQueryState queryState,
    Object error,
  ) {
    // Marked synchronously: a cache seed that resolves while the emission
    // waits its turn must not overwrite the error.
    _markRemoteEventSeen(queryState);
    final key = queryState.descriptor.key;
    return _runOnKeyChains(<String>[key], () async {
      if (_disposed) {
        return;
      }
      _emitToQueryKey(
        key,
        LocalQueryError(
          error,
          source: LocalQuerySource.unknown,
          hasPendingWrites: _hasPendingWrites(key),
        ),
      );
    });
  }

  Future<void> _detachRemoteSubscription(_LocalQueryState queryState) async {
    unawaited(queryState.remoteEventSubscription?.cancel());
    queryState.remoteEventSubscription = null;
    queryState.remoteSubscription?.cancel();
    queryState.remoteSubscription = null;
  }

  Future<void> _suspendRemoteSubscriptions() async {
    // Snapshot: each detach awaits (a microtask), and an in-flight
    // subscription cancel that drops a query's last subscriber removes its
    // entry from `_queryStates` in that window, which would throw a
    // ConcurrentModificationError out of dispose()/setNetworkMode(offline).
    for (final queryState in _queryStates.values.toList(growable: false)) {
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
      // Re-checked around every await: a dispose() racing this loop closes
      // the storage and the subscription controllers mid-iteration.
      if (_disposed) {
        return;
      }
      final cached = await _queryCache.read(
        queryState.descriptor.name,
        queryState.descriptor.args,
      );
      if (_disposed) {
        return;
      }
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
    var scheduleRetry = false;
    // Post-replay cache refreshes, coalesced to one per distinct target and
    // run once the loop ends instead of once per replayed mutation.
    final refreshTargets = <String, LocalQueryDescriptor>{};
    _log('replay:start', '${_pendingMutations.length} mutations to replay');
    try {
      // A direct mutation still in flight was issued before everything in the
      // queue; let it settle first so call order is kept.
      final direct = _directInFlight;
      if (direct != null) {
        _log('replay:wait-direct', 'waiting for in-flight direct mutation');
        await direct;
      }
      // Recover any ID remaps persisted from a prior crash.
      final idRemaps = _idRemaps = await _mutationQueue.loadIdRemaps();
      final failedLocalIds = await _mutationQueue.loadFailedLocalIds();
      var iteration = 0;
      while (!_disposed &&
          _pendingMutations.isNotEmpty &&
          _networkMode == LocalNetworkMode.auto &&
          _lastRemoteConnectionState == LocalRemoteConnectionState.connected) {
        iteration++;
        final mutation = _pendingMutations.first;
        final Object? result;
        if (_committedReplayResults.containsKey(mutation.id)) {
          // The server already committed this mutation; only its local
          // bookkeeping failed. Do not send it again.
          _log(
            'replay:mutation',
            '[$iteration] id=${mutation.id} already committed, '
                'retrying local bookkeeping',
          );
          result = _committedReplayResults[mutation.id];
        } else {
          _log(
            'replay:mutation',
            '[$iteration] id=${mutation.id} '
                '${mutation.mutationName} — marking replaying',
          );
          await _mutationQueue.markStatus(
            mutation.id,
            PendingMutationStatus.replaying,
          );
          _updatePendingMutationInMemory(
            mutation.id,
            (current) =>
                current.copyWith(status: PendingMutationStatus.replaying),
          );
          _pendingMutationsController.add(currentPendingMutations);

          // Remap any local IDs in args to server IDs.
          late final Map<String, dynamic> remappedArgs;
          try {
            remappedArgs =
                _remapIds(mutation.args, idRemaps) as Map<String, dynamic>;
          } on _LocalIdRemapCollision catch (error) {
            _log('replay:id-remap-collision', '[$iteration] ${error.message}');
            final failedLocalId = await _dropFailedMutation(mutation, error);
            if (failedLocalId != null) {
              failedLocalIds.add(failedLocalId);
            }
            continue;
          }
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
            result = await _remoteClient.mutate(
              mutation.mutationName,
              remappedArgs,
            );
          } catch (error, stack) {
            if (_disposed) {
              _log('replay:disposed', '[$iteration] stopping after error');
              break;
            }
            _log('replay:error', '[$iteration] $error\n$stack');
            if (isConvexClientClosedError(error)) {
              // The remote client was closed or disposed: this is not a
              // server rejection, and every later send would fail the same
              // way. Keep the queue and stop until the remote reconnects.
              _markRemoteUnavailable();
            }
            final queueable = error is ConvexException && error.retryable;
            if (queueable ||
                isConvexClientClosedError(error) ||
                _shouldQueueRemoteFailure(error)) {
              await _mutationQueue.markStatus(
                mutation.id,
                PendingMutationStatus.pending,
                errorMessage: error is ConvexException
                    ? error.message
                    : error.toString(),
              );
              _pendingMutations = await _mutationQueue.loadAll();
              _pendingMutationsController.add(currentPendingMutations);
              scheduleRetry = true;
              break;
            }
            final failedLocalId = await _dropFailedMutation(mutation, error);
            if (failedLocalId != null) {
              failedLocalIds.add(failedLocalId);
            }
            continue;
          }
          if (_disposed) {
            _log('replay:disposed', '[$iteration] stopping after mutate');
            break;
          }
          _log('replay:mutate-ok', '[$iteration] remote mutate succeeded');
        }

        // The server committed the mutation. Local bookkeeping failures from
        // here on must never roll it back, report a conflict, or re-send it.
        _committedReplayResults[mutation.id] = result;
        try {
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
        } catch (error, stack) {
          if (_disposed) {
            break;
          }
          _log(
            'replay:post-commit-storage-error',
            '[$iteration] $error\n$stack',
            level: DartvexLogLevel.warn,
          );
          scheduleRetry = true;
          break;
        }
        _committedReplayResults.remove(mutation.id);
        if (_disposed) {
          break;
        }
        _removePendingMutationInMemory(mutation.id);
        _rebuildPendingWriteCounts();
        _pendingMutationsController.add(currentPendingMutations);
        for (final target in _targetsFromMutation(mutation)) {
          refreshTargets[target.key] = target;
        }
        _replayRetryCount = 0;
      }
      // Failed local IDs only matter while dependents may still be queued.
      // ID remaps are kept: cached documents and app state can still carry
      // the local IDs (see _idRemaps).
      if (!_disposed &&
          _pendingMutations.isEmpty &&
          failedLocalIds.isNotEmpty) {
        await _mutationQueue.clearFailedLocalIds();
      }
      _log(
        'replay:end',
        'loop finished — ${_pendingMutations.length} '
            'remaining, retry=$scheduleRetry',
      );
    } catch (error, stackTrace) {
      // A storage failure outside the per-mutation handling (or inside it,
      // while recording a failure) must not stall the queue until the next
      // reconnect: retry with backoff.
      if (!_disposed) {
        _log(
          'replay:unexpected-error',
          '$error\n$stackTrace',
          level: DartvexLogLevel.warn,
        );
        scheduleRetry = true;
      }
    } finally {
      _isSyncing = false;
      if (!_disposed) {
        _updateConnectionState();
      }
      if (!_disposed && scheduleRetry) {
        _scheduleReplayRetry();
      }
      if (!_disposed && refreshTargets.isNotEmpty) {
        // Fire-and-forget: live subscriptions already receive server updates;
        // this refresh rewrites targets without the replayed patches, and
        // covers targets nothing is subscribed to.
        _runDetached(_refreshTargets(refreshTargets.values), 'refresh');
      }
    }
  }

  /// Replaces the in-memory queue entry [id] with [update] applied, without
  /// reloading and decoding the whole persisted queue.
  void _updatePendingMutationInMemory(
    int id,
    PendingMutation Function(PendingMutation current) update,
  ) {
    _pendingMutations = <PendingMutation>[
      for (final mutation in _pendingMutations)
        mutation.id == id ? update(mutation) : mutation,
    ];
  }

  void _removePendingMutationInMemory(int id) {
    _pendingMutations = _pendingMutations
        .where((mutation) => mutation.id != id)
        .toList(growable: false);
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
    PendingMutation capturedMutation,
    Object error,
  ) async {
    // Use the current entry: remote snapshots that arrived while the mutation
    // was in flight rebased its persisted rollback baseline.
    final mutation =
        _pendingMutations.firstWhereOrNull(
          (pending) => pending.id == capturedMutation.id,
        ) ??
        capturedMutation;
    final failedLocalId = _generatedOperationId(mutation);
    if (failedLocalId != null) {
      await _mutationQueue.saveFailedLocalId(failedLocalId);
    }
    final rollbackKeys = _rollbackSnapshotsFromMutation(
      mutation,
    ).map((snapshot) => snapshot.target.key);
    await _runOnKeyChains(rollbackKeys, () async {
      await _mutationQueue.remove(mutation.id);
      _pendingMutations = await _mutationQueue.loadAll();
      _rebuildPendingWriteCounts();
      await _restoreMutationRollback(mutation);
    });
    _pendingMutationsController.add(currentPendingMutations);
    try {
      onConflict?.call(
        LocalMutationConflict(
          mutationName: mutation.mutationName,
          args: mutation.args,
          error: error,
          queuedAt: mutation.createdAt,
          pendingMutationId: mutation.id,
          operationId: mutation.optimisticData?['operationId'] as String?,
        ),
      );
    } catch (callbackError, stackTrace) {
      _log('replay:on-conflict-error', '$callbackError\n$stackTrace');
    }
    await _refreshTargets(_targetsFromMutation(mutation));
    return failedLocalId;
  }

  Future<void> _refreshTargets(Iterable<LocalQueryDescriptor> targets) async {
    final targetList = targets.toList(growable: false);
    if (_networkMode == LocalNetworkMode.offline || targetList.isEmpty) {
      return;
    }
    _log(
      'refresh:start',
      '${targetList.length} target(s): '
          '${targetList.map((t) => t.name).join(', ')}',
    );
    for (final target in targetList) {
      if (_disposed) {
        return;
      }
      try {
        _log('refresh:query', 'querying ${target.name}…');
        // A seed from the remote client's local state can predate the
        // mutation just replayed, unless the query is live (the remote then
        // holds the current server value for it).
        final value = await _remoteQueryOnce(
          target,
          timeout: _config.refreshQueryTimeout,
          acceptSeed: _queryStates[target.key]?.remoteSubscription != null,
        );
        _log('refresh:query-ok', '${target.name} returned');
        await _writeRemoteSnapshotAndRebasePending(target, value, emit: true);
      } catch (error) {
        _log('refresh:query-error', '${target.name}: $error');
      }
    }
    _log('refresh:done', 'targets refreshed');
  }

  void _markRemoteEventSeen(_LocalQueryState queryState) {
    queryState.hasRemoteEvent = true;
    for (final subscriptionId in queryState.subscriberIds) {
      _subscriptionStates[subscriptionId]?.hasRemoteEvent = true;
    }
  }

  /// Runs [body] once every in-flight operation on any of [keys] has
  /// finished, and makes later operations on those keys wait for it.
  ///
  /// Serializes read-modify-write sequences and emissions per query key: a
  /// remote snapshot write and its pending-patch rebase span several awaits,
  /// as do the optimistic snapshot/apply of a queued mutation and a rollback.
  /// Interleaving two of them for the same key could leave a stale value in
  /// the cache or as the subscribers' latest emission. Must not be nested for
  /// the same key (the inner call would wait for the outer one).
  Future<T> _runOnKeyChains<T>(
    Iterable<String> keys,
    Future<T> Function() body,
  ) {
    final keySet = keys.toSet();
    if (keySet.isEmpty) {
      return body();
    }
    final previous = <Future<void>>[
      for (final key in keySet) ?_snapshotChainsByKey[key],
    ];
    final Future<void> ready = switch (previous.length) {
      0 => Future<void>.value(),
      1 => previous.single,
      _ => Future.wait(previous),
    };
    final result = ready.then((_) => body());
    // Keep the chain alive across failures without leaking a prior call's
    // error to the next caller.
    final guard = result.then<void>((_) {}, onError: (Object _) {});
    for (final key in keySet) {
      _snapshotChainsByKey[key] = guard;
    }
    unawaited(
      guard.whenComplete(() {
        for (final key in keySet) {
          if (identical(_snapshotChainsByKey[key], guard)) {
            _snapshotChainsByKey.remove(key);
          }
        }
      }),
    );
    return result;
  }

  Future<dynamic> _writeRemoteSnapshotAndRebasePending(
    LocalQueryDescriptor target,
    dynamic value, {
    bool emit = false,
  }) {
    return _runOnKeyChains(
      <String>[target.key],
      () => _writeRemoteSnapshotAndRebasePendingNow(target, value, emit: emit),
    );
  }

  Future<dynamic> _writeRemoteSnapshotAndRebasePendingNow(
    LocalQueryDescriptor target,
    dynamic value, {
    required bool emit,
  }) async {
    dynamic effectiveValue;
    try {
      await _queryCache.write(
        name: target.name,
        args: target.args,
        value: value,
      );
      effectiveValue = await _rebasePendingOptimisticPatchesForTarget(
        target,
        baseValue: value,
      );
    } catch (error, stackTrace) {
      // The cache is best-effort on the remote path: a storage or codec
      // failure must not swallow a value the server delivered.
      _log(
        'cache:write-error',
        '${target.name}: $error\n$stackTrace',
        level: DartvexLogLevel.warn,
      );
      effectiveValue = _applyPendingPatchesInMemory(target, value);
    }
    if (emit && !_disposed) {
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

  /// Applies the pending mutations' patches for [target] on top of
  /// [baseValue] without touching storage.
  dynamic _applyPendingPatchesInMemory(
    LocalQueryDescriptor target,
    dynamic baseValue,
  ) {
    if (!_hasPendingWrites(target.key)) {
      return baseValue;
    }
    var currentValue = baseValue;
    for (final pendingMutation in _pendingMutations) {
      final operationId = pendingMutation.optimisticData?['operationId'];
      if (operationId is! String) {
        continue;
      }
      final context = LocalMutationContext(
        operationId: operationId,
        queuedAt: pendingMutation.createdAt,
      );
      try {
        for (final patch in _buildPatches(
          pendingMutation.mutationName,
          pendingMutation.args,
          context,
        )) {
          if (patch.target.key == target.key) {
            currentValue = patch.apply(currentValue);
          }
        }
      } catch (error, stackTrace) {
        _log('remote:optimistic-rebase-error', '$error\n$stackTrace');
      }
    }
    return currentValue;
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
    required bool acceptSeed,
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
        case LocalRemoteQuerySuccess(:final value, :final isSeed):
          if (isSeed && !acceptSeed) {
            // Wait for the server's result for the new subscription.
            break;
          }
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
    final handlers =
        _mutationHandlersByName[canonicalizeQueryName(mutationName)];
    if (handlers == null) {
      return const <LocalMutationPatch>[];
    }
    if (handlers.length == 1) {
      return handlers.single.buildPatches(args, context);
    }
    return <LocalMutationPatch>[
      for (final handler in handlers) ...handler.buildPatches(args, context),
    ];
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
      final entry =
          await _queryCache.read(patch.target.name, patch.target.args) ??
          _lastEmittedEntry(patch.target);
      snapshots[key] = _CacheSnapshot(target: patch.target, entry: entry);
    }
    return snapshots.values.toList(growable: false);
  }

  /// The value a live query last emitted, as a cache entry, when its cache
  /// entry is gone (expired or pruned by the cache policy, or cleared) while
  /// subscribers still show it. Used as the base for new optimistic patches,
  /// which would otherwise replace the whole value.
  CachedQueryEntry? _lastEmittedEntry(LocalQueryDescriptor target) {
    final lastEvent = _queryStates[target.key]?.lastEvent;
    if (lastEvent is! LocalQuerySuccess) {
      return null;
    }
    return CachedQueryEntry(
      key: target.key,
      queryName: target.name,
      args: target.args,
      value: lastEvent.value,
      updatedAt: DateTime.now().toUtc(),
    );
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
      _runDetached(
        _runOnKeyChains(<String>[
          key,
        ], () => _emitCachedSnapshot(queryState.descriptor)),
        'cache-emit',
      );
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
    if (_disposed) {
      return;
    }
    final cached = await _queryCache.read(descriptor.name, descriptor.args);
    if (cached == null || _disposed) {
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
    queryState.lastEvent = event;
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

  /// Deep-snapshots caller-provided args so later caller-side mutation cannot
  /// change the query key, the cache identity, or what replay sends.
  ///
  /// A [LocalQueryDescriptor]'s key is recomputed from its stored args on
  /// every use; a shallow copy shares nested values with the caller, so
  /// mutating one of those after subscribing made the key diverge and
  /// orphaned the query state (leaking its remote subscription). Mirrors the
  /// core client's eager canonicalization; unsupported values throw here,
  /// synchronously, exactly as they previously did when the key was first
  /// serialized.
  static Map<String, dynamic> _snapshotArgs(Map<String, dynamic> args) {
    return jsonToConvex(convexToJson(args)) as Map<String, dynamic>;
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
            // Only an established connection counts as online: the direct
            // send path and replay both require it, so a connecting or
            // reconnecting remote behaves as offline (mutations are queued).
            : _lastRemoteConnectionState == LocalRemoteConnectionState.connected
            ? LocalConnectionState.online
            : LocalConnectionState.offline,
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
    // Convex bytes are a List too; rebuilding one as a List<dynamic> of ints
    // would be sent as a number array instead of bytes.
    if (value is Uint8List) return value;
    if (value is Map) {
      // Remap both keys and values: an offline mutation can reference a
      // freshly-created local ID as an object key (e.g. a per-document map),
      // not only as a value. A key that is a resolved local ID is rewritten to
      // its server ID; any other key passes through unchanged.
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        final rawKey = entry.key.toString();
        final remappedKey = idMap[rawKey] ?? rawKey;
        if (result.containsKey(remappedKey)) {
          throw _LocalIdRemapCollision(remappedKey);
        }
        result[remappedKey] = _remapIds(entry.value, idMap);
      }
      return result;
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
      if (item is Iterable && item is! Uint8List) {
        for (final entry in item) {
          visit(entry);
        }
      }
    }

    visit(value);
    return ids.toList(growable: false);
  }

  void _log(
    String tag,
    String message, {
    DartvexLogLevel level = DartvexLogLevel.debug,
  }) {
    final logger = _config.logger;
    if (logger == null || _config.logLevel == DartvexLogLevel.off) {
      return;
    }
    if (level.index > _config.logLevel.index) {
      return;
    }
    logger(DartvexLogEvent(level: level, message: message, tag: 'local.$tag'));
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

  /// Disposes subscriptions and closes the configured storage.
  ///
  /// The cache and queue storage passed in [LocalClientConfig] are always
  /// closed, even when the caller created them. The remote client is only
  /// disposed when [LocalClientConfig.disposeRemoteClient] is true (with
  /// [open], the internal adapter is always released, but the wrapped
  /// [ConvexClient] is left running by default). A direct mutation still in
  /// flight keeps its future pending until the remote client settles it.
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
    // Clear the maps before closing, mirroring ConvexClient.close(): an
    // in-flight emission loop (setNetworkMode(offline) or clearQueue racing
    // this dispose) resumes between two controller closes, and a populated map
    // would route its event into a just-closed controller — throwing "Cannot
    // add new events after calling close" out of the caller's future.
    _subscriptionStates.clear();
    _queryStates.clear();
    for (final controller in controllers) {
      await controller.close();
    }

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

class _LocalIdRemapCollision implements Exception {
  const _LocalIdRemapCollision(this.key);

  final String key;

  String get message =>
      'ID remap collision for key "$key"; refusing to replay mutation with '
      'ambiguous map entries.';

  @override
  String toString() => message;
}

class _LocalQueryState {
  _LocalQueryState(this.descriptor);

  final LocalQueryDescriptor descriptor;
  final Set<int> subscriberIds = <int>{};
  LocalRemoteSubscription? remoteSubscription;
  StreamSubscription<LocalRemoteQueryEvent>? remoteEventSubscription;

  /// Latest event emitted to this query's subscribers.
  LocalQueryEvent? lastEvent;

  /// Whether a remote event (success or error) has been received for this
  /// query.
  bool hasRemoteEvent = false;
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
