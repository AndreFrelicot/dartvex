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

  void handleMutationResponse(MutationResponse response) {
    final pending = _pendingMutations[response.requestId];
    if (pending == null) {
      return;
    }

    if (pending.status == _RequestStatus.completedMutationAwaitingTransition) {
      return;
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
      return;
    }

    pending.result = response.result;
    pending.serverTs = response.ts;
    pending.logLines = response.logLines;
    if (response.ts == null) {
      pending.completer.complete(response.result);
      _pendingMutations.remove(response.requestId);
      return;
    }

    pending.status = _RequestStatus.completedMutationAwaitingTransition;
  }

  void handleActionResponse(ActionResponse response) {
    final pending = _pendingActions.remove(response.requestId);
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

  void resolveMutationsUpTo(String transitionTs) {
    final transitionValue = decodeTs(transitionTs);
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
      if (decodeTs(pendingTs) <= transitionValue) {
        pending.completer.complete(pending.result);
        completedIds.add(requestId);
      }
    });
    for (final requestId in completedIds) {
      _pendingMutations.remove(requestId);
    }
  }

  void handleDisconnect(String reason) {
    _failRequestedActions(
      'Connection lost while action was in flight: $reason',
    );
  }

  List<ClientMessage> prepareReconnect() {
    _failRequestedActions('Connection lost while action was in flight');
    final messagesByRequestId = <int, ClientMessage>{
      for (final entry in _pendingMutations.entries)
        entry.key: entry.value.message,
      for (final entry in _pendingActions.entries)
        if (entry.value.status == _RequestStatus.notSent)
          entry.key: entry.value.message,
    };
    final requestIds = messagesByRequestId.keys.toList(growable: false)..sort();
    return <ClientMessage>[
      for (final requestId in requestIds) messagesByRequestId[requestId]!,
    ];
  }

  bool get hasPendingRequests =>
      _pendingMutations.isNotEmpty || _pendingActions.isNotEmpty;

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
    }
  }
}
