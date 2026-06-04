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
  });

  final Mutation message;
  final Completer<dynamic> completer;
  _RequestStatus status;
  Object? result;
  List<String> logLines = const <String>[];
  String? serverTs;
}

class _PendingAction {
  _PendingAction({
    required this.message,
    required this.completer,
    required this.status,
  });

  final Action message;
  final Completer<dynamic> completer;
  _RequestStatus status;
}

class RequestManager {
  final Map<int, _PendingMutation> _pendingMutations =
      <int, _PendingMutation>{};
  final Map<int, _PendingAction> _pendingActions = <int, _PendingAction>{};

  /// Request ids that were in flight when [prepareReconnect] was last called
  /// and have not yet been resolved. Backs [hasSyncedPastLastReconnect].
  final Set<int> _requestsOlderThanRestart = <int>{};

  Future<dynamic> trackMutation(Mutation message, {bool sent = false}) {
    final completer = Completer<dynamic>();
    _pendingMutations[message.requestId] = _PendingMutation(
      message: message,
      completer: completer,
      status: sent ? _RequestStatus.requested : _RequestStatus.notSent,
    );
    return completer.future;
  }

  Future<dynamic> trackAction(Action message, {bool sent = false}) {
    final completer = Completer<dynamic>();
    _pendingActions[message.requestId] = _PendingAction(
      message: message,
      completer: completer,
      status: sent ? _RequestStatus.requested : _RequestStatus.notSent,
    );
    return completer.future;
  }

  void cancelMutation(int requestId, Object error) {
    final pending = _pendingMutations.remove(requestId);
    _requestsOlderThanRestart.remove(requestId);
    if (pending == null || pending.completer.isCompleted) {
      return;
    }
    pending.completer.completeError(error);
  }

  void cancelAction(int requestId, Object error) {
    final pending = _pendingActions.remove(requestId);
    _requestsOlderThanRestart.remove(requestId);
    if (pending == null || pending.completer.isCompleted) {
      return;
    }
    pending.completer.completeError(error);
  }

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

  bool get hasPendingRequests =>
      _pendingMutations.isNotEmpty || _pendingActions.isNotEmpty;

  /// Whether every request that predates the most recent reconnect has been
  /// resolved.
  ///
  /// Returns `true` when no request is still awaiting a server response (or
  /// read-your-writes transition) from before the last [prepareReconnect].
  bool hasSyncedPastLastReconnect() => _requestsOlderThanRestart.isEmpty;

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
