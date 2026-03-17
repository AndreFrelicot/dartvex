import 'dart:async';

import '../exceptions.dart';
import '../protocol/encoding.dart';
import '../protocol/messages.dart';

class _PendingMutation {
  _PendingMutation({required this.udfPath, required this.completer});

  final String udfPath;
  final Completer<dynamic> completer;
  Object? result;
  Object? errorData;
  List<String> logLines = const <String>[];
  String? serverTs;
  String? errorMessage;
}

class _PendingAction {
  _PendingAction({required this.udfPath, required this.completer});

  final String udfPath;
  final Completer<dynamic> completer;
}

class RequestManager {
  final Map<int, _PendingMutation> _pendingMutations =
      <int, _PendingMutation>{};
  final Map<int, _PendingAction> _pendingActions = <int, _PendingAction>{};

  Future<dynamic> trackMutation(Mutation message) {
    final completer = Completer<dynamic>();
    _pendingMutations[message.requestId] = _PendingMutation(
      udfPath: message.udfPath,
      completer: completer,
    );
    return completer.future;
  }

  Future<dynamic> trackAction(Action message) {
    final completer = Completer<dynamic>();
    _pendingActions[message.requestId] = _PendingAction(
      udfPath: message.udfPath,
      completer: completer,
    );
    return completer.future;
  }

  void handleMutationResponse(MutationResponse response) {
    final pending = _pendingMutations[response.requestId];
    if (pending == null) {
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
    }
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

  void failAll(String message) {
    final error = ConvexException(message, retryable: true);
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

  bool get hasPendingRequests =>
      _pendingMutations.isNotEmpty || _pendingActions.isNotEmpty;
}
