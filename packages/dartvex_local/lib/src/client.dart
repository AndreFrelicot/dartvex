import 'dart:async';
import 'package:dartvex/dartvex.dart';

import 'cache/cache_storage.dart';
import 'cache/query_cache.dart';
import 'offline/mutation_queue.dart';
import 'offline/queue_storage.dart';
import 'query_key.dart';
import 'runtime/convex_remote_client.dart';
import 'value_codec.dart';

enum LocalNetworkMode { auto, offline }

enum LocalConnectionState { online, offline, syncing }

enum LocalQuerySource { remote, cache, unknown }

enum PendingMutationStatus { pending, replaying }

extension PendingMutationStatusName on PendingMutationStatus {
  String get wireName => switch (this) {
        PendingMutationStatus.pending => 'pending',
        PendingMutationStatus.replaying => 'replaying',
      };

  static PendingMutationStatus fromWireName(String value) {
    return switch (value) {
      'pending' => PendingMutationStatus.pending,
      'replaying' => PendingMutationStatus.replaying,
      _ => PendingMutationStatus.pending,
    };
  }
}

enum LocalRemoteConnectionState { connected, connecting, disconnected }

sealed class LocalRemoteQueryEvent {
  const LocalRemoteQueryEvent();
}

class LocalRemoteQuerySuccess extends LocalRemoteQueryEvent {
  const LocalRemoteQuerySuccess(this.value);

  final dynamic value;
}

class LocalRemoteQueryError extends LocalRemoteQueryEvent {
  const LocalRemoteQueryError(this.error);

  final Object error;
}

abstract class LocalRemoteSubscription {
  Stream<LocalRemoteQueryEvent> get stream;

  void cancel();
}

abstract class LocalRemoteClient {
  Future<dynamic> query(String name, [Map<String, dynamic> args = const {}]);

  LocalRemoteSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const {},
  ]);

  Future<dynamic> mutate(String name, [Map<String, dynamic> args = const {}]);

  Future<dynamic> action(String name, [Map<String, dynamic> args = const {}]);

  Stream<LocalRemoteConnectionState> get connectionState;

  LocalRemoteConnectionState get currentConnectionState;

  void dispose();
}

sealed class LocalQueryEvent {
  const LocalQueryEvent({
    required this.source,
    required this.hasPendingWrites,
  });

  final LocalQuerySource source;
  final bool hasPendingWrites;
}

class LocalQuerySuccess extends LocalQueryEvent {
  const LocalQuerySuccess(
    this.value, {
    required super.source,
    required super.hasPendingWrites,
  });

  final dynamic value;
}

class LocalQueryError extends LocalQueryEvent {
  const LocalQueryError(
    this.error, {
    required super.source,
    required super.hasPendingWrites,
  });

  final Object error;
}

class LocalSubscription {
  LocalSubscription({
    required Stream<LocalQueryEvent> stream,
    required Future<void> Function() onCancel,
  })  : _stream = stream,
        _onCancel = onCancel;

  final Stream<LocalQueryEvent> _stream;
  final Future<void> Function() _onCancel;

  Stream<LocalQueryEvent> get stream => _stream;

  void cancel() {
    unawaited(_onCancel());
  }
}

sealed class LocalMutationResult {
  const LocalMutationResult();
}

class LocalMutationSuccess extends LocalMutationResult {
  const LocalMutationSuccess(this.value);

  final dynamic value;
}

class LocalMutationQueued extends LocalMutationResult {
  const LocalMutationQueued({
    required this.queuePosition,
    required this.pendingMutation,
  });

  final int queuePosition;
  final PendingMutation pendingMutation;
}

class LocalMutationFailed extends LocalMutationResult {
  const LocalMutationFailed(this.error);

  final Object error;
}

class PendingMutation {
  const PendingMutation({
    required this.id,
    required this.mutationName,
    required this.args,
    required this.createdAt,
    required this.status,
    this.optimisticData,
    this.errorMessage,
  });

  final int id;
  final String mutationName;
  final Map<String, dynamic> args;
  final Map<String, dynamic>? optimisticData;
  final DateTime createdAt;
  final PendingMutationStatus status;
  final String? errorMessage;

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

class LocalMutationConflict {
  const LocalMutationConflict({
    required this.mutationName,
    required this.args,
    required this.error,
    required this.queuedAt,
  });

  final String mutationName;
  final Map<String, dynamic> args;
  final Object error;
  final DateTime queuedAt;
}

class LocalQueryDescriptor {
  const LocalQueryDescriptor(this.name,
      [this.args = const <String, dynamic>{}]);

  final String name;
  final Map<String, dynamic> args;

  String get key => serializeQueryKey(name, args);

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'args': canonicalizeJsonValue(args),
    };
  }

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

class LocalMutationContext {
  const LocalMutationContext({
    required this.operationId,
    required this.queuedAt,
  });

  final String operationId;
  final DateTime queuedAt;
}

class LocalMutationPatch {
  const LocalMutationPatch({
    required this.target,
    required this.apply,
  });

  final LocalQueryDescriptor target;
  final dynamic Function(dynamic currentValue) apply;
}

abstract class LocalMutationHandler {
  const LocalMutationHandler();

  String get mutationName;

  List<LocalMutationPatch> buildPatches(
    Map<String, dynamic> args,
    LocalMutationContext context,
  );
}

class LocalClientConfig {
  const LocalClientConfig({
    required this.cacheStorage,
    required this.queueStorage,
    this.valueCodec = const JsonValueCodec(),
    this.mutationHandlers = const <LocalMutationHandler>[],
    this.initialNetworkMode = LocalNetworkMode.auto,
    this.disposeRemoteClient = false,
  });

  final CacheStorage cacheStorage;
  final QueueStorage queueStorage;
  final ValueCodec valueCodec;
  final List<LocalMutationHandler> mutationHandlers;
  final LocalNetworkMode initialNetworkMode;
  final bool disposeRemoteClient;
}

class ConvexLocalClient {
  ConvexLocalClient._(
    this._remoteClient,
    this._config,
    this._queryCache,
    this._mutationQueue,
  )   : _networkMode = _config.initialNetworkMode,
        _currentConnectionState = LocalConnectionState.online,
        _lastRemoteConnectionState = _remoteClient.currentConnectionState;

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

  void Function(LocalMutationConflict conflict)? onConflict;

  Stream<LocalConnectionState> get connectionState =>
      _connectionStateController.stream;

  Stream<LocalNetworkMode> get networkModeStream =>
      _networkModeController.stream;

  Stream<List<PendingMutation>> get pendingMutations =>
      _pendingMutationsController.stream;

  LocalConnectionState get currentConnectionState => _currentConnectionState;

  LocalNetworkMode get currentNetworkMode => _networkMode;

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

  Future<void> clearCache() async {
    _assertNotDisposed();
    await _queryCache.clear();
  }

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
