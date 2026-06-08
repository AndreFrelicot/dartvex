import 'dart:async';

import '../exceptions.dart';
import '../protocol/encoding.dart';
import '../protocol/messages.dart';

enum _RequestStatus {
  notSent,
  requested,
  completedMutationAwaitingTransition,
}

class _PendingMutation {
  _PendingMutation({
    required this.message,
    required this.completer,
    required this.status,
    required this.requestedAt,
  });

  final Mutation message;
  final Completer<dynamic> completer;
  _RequestStatus status;

  /// When the mutation was first tracked, used by
  /// [RequestManager.timeOfOldestInflightRequest].
  final DateTime requestedAt;
  Object? result;
  List<String> logLines = const <String>[];
  String? serverTs;
}

class _PendingAction {
  _PendingAction({
    required this.message,
    required this.completer,
    required this.status,
    required this.requestedAt,
  });

  final Action message;
  final Completer<dynamic> completer;
  _RequestStatus status;

  /// When the action was first tracked, used by
  /// [RequestManager.timeOfOldestInflightRequest].
  final DateTime requestedAt;
}

/// Minimal request metadata used to surface function log lines safely.
class RequestLogContext {
  /// Creates a request log context.
  const RequestLogContext({
    required this.requestType,
    required this.requestId,
    required this.name,
    this.componentPath,
  });

  /// Request kind: `mutation` or `action`.
  final String requestType;

  /// Wire request id.
  final int requestId;

  /// Convex function path.
  final String name;

  /// Optional component path for component-hosted functions.
  final String? componentPath;
}

/// Tracks in-flight mutation and action requests and resolves their futures
/// against the responses and read-your-writes transitions arriving over the
/// websocket.
///
/// Each request is completed when its [MutationResponse]/[ActionResponse] is
/// received, or — for mutations carrying a future ts — once the transition that
/// advances local state past that ts has been observed. Also drives reconnect
/// replay and exposes counters used to report sync health.
class RequestManager {
  final Map<int, _PendingMutation> _pendingMutations =
      <int, _PendingMutation>{};
  final Map<int, _PendingAction> _pendingActions = <int, _PendingAction>{};

  /// Request ids that were in flight when [prepareReconnect] was last called
  /// and have not yet been resolved. Backs [hasSyncedPastLastReconnect].
  final Set<int> _requestsOlderThanRestart = <int>{};

  /// Begins tracking [message] and returns a future that completes with the
  /// mutation's result (or an error on failure).
  ///
  /// Pass `sent: true` when the message has already been written to the
  /// websocket so it is recorded as already-requested rather than unsent;
  /// mutations are replayed on reconnect regardless of this flag.
  Future<dynamic> trackMutation(Mutation message, {bool sent = false}) {
    final completer = Completer<dynamic>();
    _pendingMutations[message.requestId] = _PendingMutation(
      message: message,
      completer: completer,
      status: sent ? _RequestStatus.requested : _RequestStatus.notSent,
      requestedAt: DateTime.now(),
    );
    return completer.future;
  }

  /// Begins tracking [message] and returns a future that completes with the
  /// action's result (or an error on failure).
  ///
  /// Pass `sent: true` when the message has already been written to the
  /// websocket; sent actions are not idempotent and are failed rather than
  /// replayed on reconnect.
  Future<dynamic> trackAction(Action message, {bool sent = false}) {
    final completer = Completer<dynamic>();
    _pendingActions[message.requestId] = _PendingAction(
      message: message,
      completer: completer,
      status: sent ? _RequestStatus.requested : _RequestStatus.notSent,
      requestedAt: DateTime.now(),
    );
    return completer.future;
  }

  /// Returns safe logging metadata for a pending mutation response, or `null`
  /// when the response's log lines should not be emitted.
  ///
  /// Mirrors the official client's `onResponse`, which skips function-log
  /// emission for responses it will not act on: those whose request is no
  /// longer tracked, and those whose mutation is already completed and only
  /// awaiting its read-your-writes transition. The latter happens when a
  /// reconnect replays such a mutation: the server re-sends the same response,
  /// and re-logging its lines would duplicate output the app already saw.
  RequestLogContext? mutationLogContext(int requestId) {
    final pending = _pendingMutations[requestId];
    if (pending == null ||
        pending.status == _RequestStatus.completedMutationAwaitingTransition) {
      return null;
    }
    return RequestLogContext(
      requestType: 'mutation',
      requestId: requestId,
      name: pending.message.udfPath,
      componentPath: pending.message.componentPath,
    );
  }

  /// Returns safe logging metadata for a pending action response.
  RequestLogContext? actionLogContext(int requestId) {
    final pending = _pendingActions[requestId];
    if (pending == null) {
      return null;
    }
    return RequestLogContext(
      requestType: 'action',
      requestId: requestId,
      name: pending.message.udfPath,
      componentPath: pending.message.componentPath,
    );
  }

  /// Stops tracking the mutation with [requestId] and completes its future with
  /// [error] if it has not already resolved.
  void cancelMutation(int requestId, Object error) {
    final pending = _pendingMutations.remove(requestId);
    _requestsOlderThanRestart.remove(requestId);
    if (pending == null || pending.completer.isCompleted) {
      return;
    }
    pending.completer.completeError(error);
  }

  /// Stops tracking the action with [requestId] and completes its future with
  /// [error] if it has not already resolved.
  void cancelAction(int requestId, Object error) {
    final pending = _pendingActions.remove(requestId);
    _requestsOlderThanRestart.remove(requestId);
    if (pending == null || pending.completer.isCompleted) {
      return;
    }
    pending.completer.completeError(error);
  }

  /// Marks the tracked mutations and actions in [messages] as sent over the
  /// websocket, transitioning them from unsent to requested.
  ///
  /// Non-request client messages (connect, query-set, auth, events) are ignored.
  void markSent(Iterable<ClientMessage> messages) {
    for (final message in messages) {
      switch (message) {
        case Mutation():
          final pending = _pendingMutations[message.requestId];
          if (pending != null && pending.status == _RequestStatus.notSent) {
            pending.status = _RequestStatus.requested;
          }
        case Action():
          final pending = _pendingActions[message.requestId];
          if (pending != null && pending.status == _RequestStatus.notSent) {
            pending.status = _RequestStatus.requested;
          }
        case Connect():
        case ModifyQuerySet():
        case Authenticate():
        case Event():
        case RequestMessage():
      }
    }
  }

  /// Applies a mutation [response] without an applied transition ts and returns
  /// the request ids whose optimistic update should now be dropped.
  ///
  /// Convenience wrapper around
  /// [handleMutationResponseWithAppliedTransition].
  List<int> handleMutationResponse(MutationResponse response) {
    return handleMutationResponseWithAppliedTransition(response);
  }

  /// Applies a mutation [response] and returns the request ids whose optimistic
  /// update should now be dropped.
  ///
  /// A layer drops the instant its mutation resolves: immediately on failure
  /// (rollback) or on a ts-less success, and — for read-your-writes — only once
  /// the transition carrying the mutation's ts has been observed. When the
  /// response's ts is still in the future the mutation is parked
  /// (`completedMutationAwaitingTransition`) with its layer intact, and the
  /// empty list is returned; [resolveMutationsUpTo] drops it later. If
  /// [appliedTransitionTs] already covers the response ts (the transition raced
  /// ahead of the response), it resolves and drops here instead.
  List<int> handleMutationResponseWithAppliedTransition(
    MutationResponse response, {
    String? appliedTransitionTs,
  }) {
    final pending = _pendingMutations[response.requestId];
    if (pending == null) {
      return const <int>[];
    }

    if (pending.status == _RequestStatus.completedMutationAwaitingTransition) {
      return const <int>[];
    }

    if (!response.success) {
      pending.completer.completeError(
        ConvexException(
          response.errorMessage ?? 'Mutation failed',
          data: response.errorData,
          logLines: response.logLines,
        ),
      );
      _pendingMutations.remove(response.requestId);
      _requestsOlderThanRestart.remove(response.requestId);
      return <int>[response.requestId];
    }

    pending.result = response.result;
    pending.serverTs = response.ts;
    pending.logLines = response.logLines;
    if (response.ts == null) {
      pending.completer.complete(response.result);
      _pendingMutations.remove(response.requestId);
      _requestsOlderThanRestart.remove(response.requestId);
      return <int>[response.requestId];
    }

    pending.status = _RequestStatus.completedMutationAwaitingTransition;
    if (appliedTransitionTs != null &&
        compareEncodedTs(response.ts!, appliedTransitionTs) <= 0) {
      pending.completer.complete(pending.result);
      _pendingMutations.remove(response.requestId);
      _requestsOlderThanRestart.remove(response.requestId);
      return <int>[response.requestId];
    }
    return const <int>[];
  }

  /// Applies an action [response], completing the matching tracked future with
  /// its result on success or a [ConvexException] on failure.
  void handleActionResponse(ActionResponse response) {
    final pending = _pendingActions.remove(response.requestId);
    _requestsOlderThanRestart.remove(response.requestId);
    if (pending == null) {
      return;
    }
    if (response.success) {
      pending.completer.complete(response.result);
      return;
    }
    pending.completer.completeError(
      ConvexException(
        response.errorMessage ?? 'Action failed',
        data: response.errorData,
        logLines: response.logLines,
      ),
    );
  }

  /// Resolves every parked mutation whose ts the transition has now reached and
  /// returns their request ids so their optimistic layers can be dropped.
  List<int> resolveMutationsUpTo(String transitionTs) {
    final completedIds = <int>[];
    _pendingMutations.forEach((requestId, pending) {
      if (pending.status !=
          _RequestStatus.completedMutationAwaitingTransition) {
        return;
      }
      final pendingTs = pending.serverTs;
      if (pendingTs == null) {
        return;
      }
      if (compareEncodedTs(pendingTs, transitionTs) <= 0) {
        pending.completer.complete(pending.result);
        completedIds.add(requestId);
      }
    });
    for (final requestId in completedIds) {
      _pendingMutations.remove(requestId);
      _requestsOlderThanRestart.remove(requestId);
    }
    return completedIds;
  }

  /// Fails any already-sent actions because the connection dropped for [reason];
  /// such actions are not idempotent and cannot be safely retried.
  void handleDisconnect(String reason) {
    _failRequestedActions(
      'Connection lost while action was in flight: $reason',
    );
  }

  /// Re-queues the requests to replay on a fresh connection and records them as
  /// outstanding since the restart.
  ///
  /// In-flight actions that were already sent are failed (they are not
  /// idempotent); every replayed request — all mutations plus unsent actions —
  /// is added to the set behind [hasSyncedPastLastReconnect] until its response
  /// or read-your-writes transition resolves it.
  List<ClientMessage> prepareReconnect() {
    _failRequestedActions('Connection lost while action was in flight');
    final messagesByRequestId = <int, ClientMessage>{
      for (final entry in _pendingMutations.entries)
        entry.key: entry.value.message,
      for (final entry in _pendingActions.entries)
        if (entry.value.status == _RequestStatus.notSent)
          entry.key: entry.value.message,
    };
    _requestsOlderThanRestart
      ..clear()
      ..addAll(messagesByRequestId.keys);
    final requestIds = messagesByRequestId.keys.toList(growable: false)..sort();
    return <ClientMessage>[
      for (final requestId in requestIds) messagesByRequestId[requestId]!,
    ];
  }

  /// Whether any mutation or action is still being tracked.
  bool get hasPendingRequests =>
      _pendingMutations.isNotEmpty || _pendingActions.isNotEmpty;

  /// Whether every request that predates the most recent reconnect has been
  /// resolved.
  ///
  /// Returns `true` when no request is still awaiting a server response (or
  /// read-your-writes transition) from before the last [prepareReconnect].
  bool hasSyncedPastLastReconnect() => _requestsOlderThanRestart.isEmpty;

  /// The number of mutations currently in flight.
  ///
  /// Includes mutations that have completed on the server but are awaiting the
  /// transition carrying their timestamp (read-your-writes), matching the
  /// official client which keeps such mutations counted until fully resolved.
  int get inflightMutations => _pendingMutations.length;

  /// The number of actions currently in flight.
  int get inflightActions => _pendingActions.length;

  /// Whether any mutation or action is currently in flight.
  bool get hasInflightRequests => hasPendingRequests;

  /// The time the oldest still-pending request was first tracked, or `null`
  /// when nothing is in flight.
  ///
  /// When every in-flight request is a mutation that has completed on the server
  /// and is only awaiting its read-your-writes transition, this matches the
  /// official client and returns the current time.
  DateTime? timeOfOldestInflightRequest() {
    DateTime? oldest;
    for (final pending in _pendingMutations.values) {
      if (pending.status ==
          _RequestStatus.completedMutationAwaitingTransition) {
        continue;
      }
      if (oldest == null || pending.requestedAt.isBefore(oldest)) {
        oldest = pending.requestedAt;
      }
    }
    for (final pending in _pendingActions.values) {
      if (oldest == null || pending.requestedAt.isBefore(oldest)) {
        oldest = pending.requestedAt;
      }
    }
    if (oldest == null && _pendingMutations.isNotEmpty) {
      return DateTime.now();
    }
    return oldest;
  }

  /// Fails every tracked mutation and action with [message] and clears all
  /// pending state, typically on a fatal client shutdown.
  void failAll(String message) {
    final error = ConvexException(message);
    for (final pending in _pendingMutations.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    for (final pending in _pendingActions.values) {
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
    _pendingMutations.clear();
    _pendingActions.clear();
    _requestsOlderThanRestart.clear();
  }

  void _failRequestedActions(String message) {
    final failedRequestIds = <int>[];
    for (final entry in _pendingActions.entries) {
      final pending = entry.value;
      if (pending.status != _RequestStatus.requested) {
        continue;
      }
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(
          ConvexException(message, retryable: true),
        );
      }
      failedRequestIds.add(entry.key);
    }
    for (final requestId in failedRequestIds) {
      _pendingActions.remove(requestId);
      _requestsOlderThanRestart.remove(requestId);
    }
  }
}
