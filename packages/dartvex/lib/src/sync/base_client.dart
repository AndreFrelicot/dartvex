import 'dart:async';
import 'dart:collection';

import '../protocol/messages.dart';
import 'local_state.dart';
import 'optimistic_updates.dart';
import 'remote_query_set.dart';
import 'request_manager.dart';

/// Base type for the side effects [BaseClient] surfaces while processing
/// incoming [ServerMessage]s and client actions.
sealed class BaseClientEvent {
  /// Const base constructor for [BaseClientEvent] subtypes.
  const BaseClientEvent();
}

/// Emitted when a query's result changes and its subscribers must be notified.
class QueryUpdateEvent extends BaseClientEvent {
  /// Creates a [QueryUpdateEvent] for [queryId] carrying its new [result].
  const QueryUpdateEvent({required this.queryId, required this.result});

  /// Identifier of the query whose value changed.
  final int queryId;

  /// The new stored result (server value with any optimistic overlay applied).
  final StoredQueryResult result;
}

/// Emitted when a query is removed from the active query set.
class QueryRemovedEvent extends BaseClientEvent {
  /// Creates a [QueryRemovedEvent] for the query identified by [queryId].
  const QueryRemovedEvent({required this.queryId});

  /// Identifier of the query that was removed.
  final int queryId;
}

/// Emitted when the server confirms an authentication state transition.
class AuthConfirmedEvent extends BaseClientEvent {
  /// Creates an [AuthConfirmedEvent] reporting the confirmed auth state.
  const AuthConfirmedEvent({required this.isAuthenticated});

  /// Whether the client is authenticated after the confirmed transition.
  final bool isAuthenticated;
}

/// Emitted when the server rejects the client's authentication token.
class AuthErrorEvent extends BaseClientEvent {
  /// Creates an [AuthErrorEvent] wrapping the server-sent [error].
  const AuthErrorEvent({required this.error});

  /// The auth-error message received from the server.
  final AuthError error;
}

/// Emitted when the sync layer detects state that requires a reconnect.
class ReconnectRequiredEvent extends BaseClientEvent {
  /// Creates a [ReconnectRequiredEvent] describing why a reconnect is needed.
  const ReconnectRequiredEvent({required this.reason});

  /// Human-readable explanation of why a reconnect is required.
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

/// The outcome of [BaseClient.receive]: events to surface and messages to send.
class BaseClientReceiveResult {
  /// Creates a receive result with the given [events] and [outgoing] messages.
  const BaseClientReceiveResult({
    this.events = const <BaseClientEvent>[],
    this.outgoing = const <ClientMessage>[],
  });

  /// Events produced while processing the received message.
  final List<BaseClientEvent> events;

  /// Client messages that should be sent over the websocket as a result.
  final List<ClientMessage> outgoing;
}

/// A request (mutation or action) tracked by the [RequestManager], pairing its
/// wire request id with the future that resolves to the server response.
class TrackedRequest {
  /// Creates a [TrackedRequest] for [requestId] resolving via [future].
  const TrackedRequest({required this.requestId, required this.future});

  /// The wire request id assigned to this request.
  final int requestId;

  /// Future that completes with the request's result or error.
  final Future<dynamic> future;
}

/// Transport-agnostic core of the Convex sync protocol.
///
/// Owns the [LocalSyncState] (query subscriptions and auth), the
/// [RemoteQuerySet] (authoritative server results), the [RequestManager]
/// (in-flight mutations/actions), and the optimistic overlay. It turns
/// caller actions into outgoing [ClientMessage]s and folds incoming
/// [ServerMessage]s into events, leaving the actual socket I/O to its host.
class BaseClient {
  /// Creates a [BaseClient], optionally injecting collaborators for testing.
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

  /// The local sync state tracking query subscriptions and auth.
  LocalSyncState get localState => _localState;

  /// The highest server timestamp observed so far, or `null` before any
  /// timestamp has been observed (from a transition or a successful mutation
  /// response).
  String? get maxObservedTimestamp => _localState.maxObservedTimestamp;

  /// The current auth version, incremented for every emitted [Authenticate]
  /// message and reset on reconnect.
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

  /// Subscribes to the query [udfPath] with [args], queuing the resulting
  /// query-set update for sending and returning its [SubscriptionRegistration].
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

  /// Removes the subscriber [subscriberId], queuing a query-set update when this
  /// drops the last subscriber for its query.
  void unsubscribe(int subscriberId) {
    final message = _localState.unsubscribe(subscriberId);
    if (message != null) {
      _outgoing.add(message);
    }
  }

  /// Enqueues a [Mutation] for [udfPath] with [args] and returns a
  /// [TrackedRequest] whose future resolves with the server response.
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

  /// Runs the mutation [udfPath] with [args] and returns its result future.
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

  /// Enqueues an [Action] for [udfPath] with [args] and returns a
  /// [TrackedRequest] whose future resolves with the server response.
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

  /// Runs the action [udfPath] with [args] and returns its result future.
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

  /// Cancels the in-flight action [requestId], failing its future with [error]
  /// and dropping any still-queued request message for it.
  void cancelAction(int requestId, Object error) {
    _removeOutgoingRequest(requestId, isMutation: false);
    _requestManager.cancelAction(requestId, error);
  }

  /// Sets the auth token of [tokenType] to [token], clearing the result cache
  /// and queuing an [Authenticate] message unless emission is paused.
  void setAuth({required String tokenType, String? token}) {
    _resultCacheByToken.clear();
    final message = _localState.setAuth(tokenType: tokenType, value: token);
    // While paused the auth is captured in local state and replayed by [resume];
    // queuing it here would let it leak out before the socket resumes.
    if (!_localState.isPaused) {
      _outgoing.add(message);
    }
  }

  /// Clears the auth token, resetting to the unauthenticated identity and
  /// queuing the change unless emission is paused.
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

  /// Restores the auth token of [tokenType] to [token] without emitting a new
  /// [Authenticate] message, used to re-seed local state after a refresh.
  void restoreAuth({required String tokenType, String? token}) {
    _localState.restoreAuth(tokenType: tokenType, value: token);
  }

  /// Handles a socket disconnect for [reason], dropping queued outgoing
  /// messages, failing already-sent in-flight actions (non-idempotent, not
  /// retryable), and leaving in-flight mutations pending for replay on
  /// reconnect.
  void handleDisconnect(String reason) {
    _outgoing.clear();
    _requestManager.handleDisconnect(reason);
  }

  /// Fails every pending request with [message] and clears the outgoing queue.
  void failPendingRequests(String message) {
    _outgoing.clear();
    _requestManager.failAll(message);
  }

  /// Resets remote state for a reconnect and returns the messages that re-sync
  /// the query set, auth, and in-flight requests on the new connection.
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

  /// Returns the current authoritative server result for [queryId], or `null`
  /// when the query has no remote result yet.
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

  /// Returns the ids of all subscribers currently attached to [queryId].
  List<int> subscriberIdsForQuery(int queryId) {
    return _localState.subscriberIdsForQuery(queryId);
  }

  /// Returns the query id that [subscriberId] is attached to, or `null` when the
  /// subscriber is unknown.
  int? queryIdForSubscriber(int subscriberId) {
    return _localState.queryIdForSubscriber(subscriberId);
  }

  /// Returns and clears the queued outgoing messages; when [assumeSent] is true
  /// the request manager marks them as sent so they are not requeued.
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

  /// Marks [messages] as sent in the request manager so they are not retried.
  void markMessagesSent(Iterable<ClientMessage> messages) {
    _requestManager.markSent(messages);
  }

  /// Pushes [messages] back to the front of the outgoing queue, preserving their
  /// original order so they are drained before any later-enqueued messages.
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

  /// Folds an incoming [ServerMessage] into local state, returning the resulting
  /// events to surface and any messages to send in a [BaseClientReceiveResult].
  ///
  /// Handles transitions (query deltas, timestamps, resolved mutations, and auth
  /// confirmation), mutation/action responses, pings, auth and fatal errors, and
  /// requests a reconnect on an unexpected [TransitionChunk] or applied-state
  /// error.
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
