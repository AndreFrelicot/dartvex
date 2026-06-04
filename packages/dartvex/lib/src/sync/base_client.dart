import 'dart:async';
import 'dart:collection';

import '../protocol/messages.dart';
import 'local_state.dart';
import 'optimistic_updates.dart';
import 'remote_query_set.dart';
import 'request_manager.dart';

sealed class BaseClientEvent {
  const BaseClientEvent();
}

class QueryUpdateEvent extends BaseClientEvent {
  const QueryUpdateEvent({required this.queryId, required this.result});

  final int queryId;
  final StoredQueryResult result;
}

class QueryRemovedEvent extends BaseClientEvent {
  const QueryRemovedEvent({required this.queryId});

  final int queryId;
}

class AuthConfirmedEvent extends BaseClientEvent {
  const AuthConfirmedEvent({required this.isAuthenticated});

  final bool isAuthenticated;
}

class AuthErrorEvent extends BaseClientEvent {
  const AuthErrorEvent({required this.error});

  final AuthError error;
}

class ReconnectRequiredEvent extends BaseClientEvent {
  const ReconnectRequiredEvent({required this.reason});

  final String reason;
}

/// Emitted when the server reports an unrecoverable [FatalError].
///
/// The connection must be terminated without reconnecting; [error] describes
/// the failure so it can be surfaced to the caller.
class FatalErrorEvent extends BaseClientEvent {
  /// Creates a fatal-error event carrying the server-provided [error].
  const FatalErrorEvent({required this.error});

  /// Human-readable description of the unrecoverable server error.
  final String error;
}

class BaseClientReceiveResult {
  const BaseClientReceiveResult({
    this.events = const <BaseClientEvent>[],
    this.outgoing = const <ClientMessage>[],
  });

  final List<BaseClientEvent> events;
  final List<ClientMessage> outgoing;
}

class TrackedRequest {
  const TrackedRequest({required this.requestId, required this.future});

  final int requestId;
  final Future<dynamic> future;
}

class BaseClient {
  BaseClient({
    LocalSyncState? localState,
    RemoteQuerySet? remoteQuerySet,
    RequestManager? requestManager,
  })  : _localState = localState ?? LocalSyncState(),
        _remoteQuerySet = remoteQuerySet ?? RemoteQuerySet(),
        _requestManager = requestManager ?? RequestManager();

  final LocalSyncState _localState;
  final RemoteQuerySet _remoteQuerySet;
  final RequestManager _requestManager;
  final OptimisticQueryResults _optimistic = OptimisticQueryResults();
  final Queue<ClientMessage> _outgoing = Queue<ClientMessage>();

  int _nextRequestId = 0;

  LocalSyncState get localState => _localState;

  String? get maxObservedTimestamp => _localState.maxObservedTimestamp;

  int get authVersion => _localState.authVersion;

  /// Whether the client has fully re-synced after the most recent reconnect.
  ///
  /// Combines the local query/auth tracking with the request tracking: it is
  /// `true` only once every query, auth update, and request that predated the
  /// last [prepareReconnect] has been confirmed by the server.
  ///
  /// This is package-internal plumbing — it is intentionally not surfaced on
  /// the public `ConvexClient` API (rich connection state is a later
  /// workstream) — consumed by the reconnect and auth layers to decide when a
  /// connection has proven itself.
  ///
  /// Note: the official Convex JS client combines these two signals with `||`,
  /// reporting "synced" as soon as either side is clear, so a query-only client
  /// appears synced before its first post-reconnect result. dartvex uses `&&`
  /// so the flag reflects *all* outstanding work, matching the documented
  /// intent of the signal.
  bool get hasSyncedPastLastReconnect =>
      _localState.hasSyncedPastLastReconnect() &&
      _requestManager.hasSyncedPastLastReconnect();

  /// The number of mutations currently in flight. See [RequestManager].
  int get inflightMutations => _requestManager.inflightMutations;

  /// The number of actions currently in flight. See [RequestManager].
  int get inflightActions => _requestManager.inflightActions;

  /// Whether any mutation or action is currently in flight.
  bool get hasInflightRequests => _requestManager.hasInflightRequests;

  /// The time the oldest still-pending request was issued, or `null` when
  /// nothing is in flight. See [RequestManager.timeOfOldestInflightRequest].
  DateTime? get timeOfOldestInflightRequest =>
      _requestManager.timeOfOldestInflightRequest();

  final Map<String, StoredQueryResult> _resultCacheByToken =
      <String, StoredQueryResult>{};

  SubscriptionRegistration subscribe(
    String udfPath,
    Map<String, dynamic> args,
  ) {
    final registration = _localState.subscribe(udfPath, args);
    final message = registration.message;
    if (message != null) {
      _outgoing.add(message);
    }
    return registration;
  }

  void unsubscribe(int subscriberId) {
    final message = _localState.unsubscribe(subscriberId);
    if (message != null) {
      _outgoing.add(message);
    }
  }

  TrackedRequest trackMutation(String udfPath, Map<String, dynamic> args) {
    final message = Mutation(
      requestId: _nextRequestId++,
      udfPath: LocalSyncState.canonicalizeUdfPath(udfPath),
      args: <dynamic>[Map<String, dynamic>.from(args)],
    );
    _outgoing.add(message);
    return TrackedRequest(
      requestId: message.requestId,
      future: _requestManager.trackMutation(message),
    );
  }

  Future<dynamic> mutate(String udfPath, Map<String, dynamic> args) {
    return trackMutation(udfPath, args).future;
  }

  /// Applies an optimistic [update] tagged with the mutation's [requestId] and
  /// returns the query-update events for the subscribers it affects.
  ///
  /// Call this synchronously right after [trackMutation] with the same request
  /// id, so the overlay layer is rolled back when that mutation completes.
  List<BaseClientEvent> applyOptimisticUpdate(
    OptimisticUpdate update,
    int requestId,
  ) {
    return _eventsForChangedTokens(
      _optimistic.applyOptimisticUpdate(update, requestId),
    );
  }

  TrackedRequest trackAction(String udfPath, Map<String, dynamic> args) {
    final message = Action(
      requestId: _nextRequestId++,
      udfPath: LocalSyncState.canonicalizeUdfPath(udfPath),
      args: <dynamic>[Map<String, dynamic>.from(args)],
    );
    _outgoing.add(message);
    return TrackedRequest(
      requestId: message.requestId,
      future: _requestManager.trackAction(message),
    );
  }

  Future<dynamic> action(String udfPath, Map<String, dynamic> args) {
    return trackAction(udfPath, args).future;
  }

  /// Cancels an in-flight mutation, rolling back its optimistic layer.
  ///
  /// Returns the query-update events for the rollback (empty when the mutation
  /// had no optimistic update). The server may still have processed the
  /// mutation, in which case a later transition re-applies its authoritative
  /// result.
  List<BaseClientEvent> cancelMutation(int requestId, Object error) {
    _removeOutgoingRequest(requestId, isMutation: true);
    _requestManager.cancelMutation(requestId, error);
    if (!_optimistic.hasActiveUpdates) {
      return const <BaseClientEvent>[];
    }
    return _emitOverlayChanges(<int>[requestId]);
  }

  void cancelAction(int requestId, Object error) {
    _removeOutgoingRequest(requestId, isMutation: false);
    _requestManager.cancelAction(requestId, error);
  }

  void setAuth({required String tokenType, String? token}) {
    _resultCacheByToken.clear();
    final message = _localState.setAuth(tokenType: tokenType, value: token);
    // While paused the auth is captured in local state and replayed by [resume];
    // queuing it here would let it leak out before the socket resumes.
    if (!_localState.isPaused) {
      _outgoing.add(message);
    }
  }

  void clearAuth() {
    _resultCacheByToken.clear();
    final message = _localState.setAuth(tokenType: 'None');
    if (!_localState.isPaused) {
      _outgoing.add(message);
    }
  }

  /// Whether query-set and auth emission is currently paused. See [pause].
  bool get isPaused => _localState.isPaused;

  /// Pauses query-set and auth emission while auth is being resolved.
  ///
  /// New subscriptions and auth updates are buffered in [localState] instead of
  /// being enqueued for sending, and are replayed together by [resume].
  void pause() {
    _localState.pause();
  }

  /// Replays everything buffered while paused, returning the messages to send.
  ///
  /// The resume query-set delta and re-affirmed auth are queued ahead of any
  /// request enqueued while paused, then the full outgoing queue is drained.
  List<ClientMessage> resume() {
    final (querySet, authenticate) = _localState.resume();
    final resumeMessages = <ClientMessage>[
      if (querySet != null) querySet,
      if (authenticate != null) authenticate,
    ];
    if (resumeMessages.isNotEmpty) {
      requeueOutgoing(resumeMessages);
    }
    return drainOutgoing(assumeSent: false);
  }

  void restoreAuth({required String tokenType, String? token}) {
    _localState.restoreAuth(tokenType: tokenType, value: token);
  }

  void handleDisconnect(String reason) {
    _outgoing.clear();
    _requestManager.handleDisconnect(reason);
  }

  void failPendingRequests(String message) {
    _outgoing.clear();
    _requestManager.failAll(message);
  }

  List<ClientMessage> prepareReconnect() {
    _outgoing.clear();
    // Capture which queries already have a remote result before we throw the
    // remote query set away, so the local state only marks the queries that
    // still need a fresh result as outstanding since this restart.
    final oldRemoteQueryResults = _remoteQuerySet.resultQueryIds;
    _remoteQuerySet.reset();
    _outgoing.addAll(_localState.prepareReconnect(oldRemoteQueryResults));
    _outgoing.addAll(_requestManager.prepareReconnect());
    return drainOutgoing(assumeSent: false);
  }

  StoredQueryResult? currentResultForQuery(int queryId) {
    return _remoteQuerySet.resultFor(queryId);
  }

  /// Returns the last known result for a query identified by its canonical
  /// udf path and arguments, even after the query has been unsubscribed.
  StoredQueryResult? cachedResultForQuery(
    String udfPath,
    Map<String, dynamic> args,
  ) {
    final token = LocalSyncState.serializeQueryToken(
      LocalSyncState.canonicalizeUdfPath(udfPath),
      args,
    );
    return _resultCacheByToken[token];
  }

  /// Returns the overlaid (server + active optimistic edits) result for a query
  /// identified by its udf path and arguments, or null if it currently has no
  /// value.
  ///
  /// Lets a fresh subscription emit an optimistic value already set for the
  /// query before the server has reported on it.
  StoredQueryResult? optimisticResultForQuery(
    String udfPath,
    Map<String, dynamic> args,
  ) {
    final token = LocalSyncState.serializeQueryToken(
      LocalSyncState.canonicalizeUdfPath(udfPath),
      args,
    );
    return _optimistic.rawResultForToken(token);
  }

  List<int> subscriberIdsForQuery(int queryId) {
    return _localState.subscriberIdsForQuery(queryId);
  }

  int? queryIdForSubscriber(int subscriberId) {
    return _localState.queryIdForSubscriber(subscriberId);
  }

  List<ClientMessage> drainOutgoing({bool assumeSent = true}) {
    final messages = List<ClientMessage>.from(_outgoing);
    _outgoing.clear();
    if (assumeSent) {
      _requestManager.markSent(messages);
    }
    return messages;
  }

  void _removeOutgoingRequest(int requestId, {required bool isMutation}) {
    _outgoing.removeWhere((message) {
      if (message is Mutation) {
        return isMutation && message.requestId == requestId;
      }
      if (message is Action) {
        return !isMutation && message.requestId == requestId;
      }
      return false;
    });
  }

  void markMessagesSent(Iterable<ClientMessage> messages) {
    _requestManager.markSent(messages);
  }

  void requeueOutgoing(Iterable<ClientMessage> messages) {
    final queuedMessages = messages.toList(growable: false);
    for (final message in queuedMessages.reversed) {
      _outgoing.addFirst(message);
    }
  }

  /// Builds the server-side query results for the optimistic overlay: every
  /// subscribed query that currently holds a remote result, keyed by token.
  Map<String, OverlayServerQuery> _buildServerResults() {
    final serverResults = <String, OverlayServerQuery>{};
    for (final queryId in _remoteQuerySet.resultQueryIds) {
      final token = _localState.tokenForQueryId(queryId);
      if (token == null) {
        continue;
      }
      final state = _localState.queryStateForId(queryId);
      if (state == null) {
        continue;
      }
      serverResults[token] = (
        result: _remoteQuerySet.resultFor(queryId),
        udfPath: state.udfPath,
        args: state.args,
      );
    }
    return serverResults;
  }

  /// Re-bases the overlay on the current server results, dropping the layers of
  /// [droppedRequestIds], and returns events for queries whose value changed.
  List<BaseClientEvent> _emitOverlayChanges(Iterable<int> droppedRequestIds) {
    final changedTokens = _optimistic.ingestQueryResultsFromServer(
      _buildServerResults(),
      droppedRequestIds.toSet(),
    );
    return _eventsForChangedTokens(changedTokens);
  }

  /// Maps changed overlay [tokens] to query-update events for their subscribers.
  ///
  /// Tokens with no live subscription (an optimistic-only value) and tokens
  /// whose overlaid result is "loading" (null) emit nothing: dartvex's query
  /// stream has no loading state, so such queries keep their last value until a
  /// concrete result lands.
  List<BaseClientEvent> _eventsForChangedTokens(List<String> tokens) {
    final events = <BaseClientEvent>[];
    for (final token in tokens) {
      final queryId = _localState.queryIdForToken(token);
      if (queryId == null) {
        continue;
      }
      final result = _optimistic.rawResultForToken(token);
      if (result != null) {
        events.add(QueryUpdateEvent(queryId: queryId, result: result));
      }
    }
    return events;
  }

  BaseClientReceiveResult receive(ServerMessage message) {
    final events = <BaseClientEvent>[];
    switch (message) {
      case Transition():
        try {
          final deltas = _remoteQuerySet.applyTransition(message);
          _localState.observeTimestamp(message.endVersion.ts);
          _localState.transition(message);
          final completedRequestIds =
              _requestManager.resolveMutationsUpTo(message.endVersion.ts);
          for (final delta in deltas) {
            if (delta.removed) {
              events.add(QueryRemovedEvent(queryId: delta.queryId));
            } else if (delta.result != null) {
              final token = _localState.tokenForQueryId(delta.queryId);
              if (token != null) {
                _resultCacheByToken[token] = delta.result!;
              }
            }
          }
          // Emit query value changes through the optimistic overlay: the fresh
          // server results are re-based, the layers of mutations this transition
          // completed are dropped, and any still-pending optimistic edits are
          // replayed on top — atomically, so a resolved mutation's optimistic
          // value is replaced by its authoritative server value without flicker.
          events.addAll(_emitOverlayChanges(completedRequestIds));
          // Treat the transition as an auth confirmation only when it advances
          // the identity version and is not stale — i.e. the client has not
          // already moved on to a newer auth version. Mirrors the official
          // onTransition guard and prevents a superseded token from being
          // reported as confirmed.
          if (message.endVersion.identity > message.startVersion.identity &&
              _localState
                  .isCurrentOrNewerAuthVersion(message.endVersion.identity)) {
            _localState.markAuthCompletion();
            events.add(
              AuthConfirmedEvent(isAuthenticated: _localState.hasAuth),
            );
          }
        } on StateError catch (error) {
          events.add(ReconnectRequiredEvent(reason: '$error'));
        }
      case MutationResponse():
        if (message.success && message.ts != null) {
          _localState.observeTimestamp(message.ts!);
        }
        final droppedRequestIds =
            _requestManager.handleMutationResponseWithAppliedTransition(
          message,
          appliedTransitionTs: _remoteQuerySet.version.ts,
        );
        // A mutation that resolved here (failure rollback, ts-less success, or a
        // success whose transition already landed) drops its optimistic layer
        // now; a parked read-your-writes success keeps its layer until its
        // transition arrives.
        if (droppedRequestIds.isNotEmpty) {
          events.addAll(_emitOverlayChanges(droppedRequestIds));
        }
      case ActionResponse():
        _requestManager.handleActionResponse(message);
      case Ping():
        break;
      case AuthError():
        events.add(AuthErrorEvent(error: message));
      case FatalError():
        events.add(FatalErrorEvent(error: message.error));
      case TransitionChunk():
        events.add(
          const ReconnectRequiredEvent(
            reason: 'Unexpected TransitionChunk reached sync layer',
          ),
        );
    }

    final outgoing = List<ClientMessage>.from(_outgoing);
    _outgoing.clear();
    return BaseClientReceiveResult(events: events, outgoing: outgoing);
  }
}
