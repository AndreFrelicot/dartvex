import '../protocol/messages.dart';
import '../protocol/state_version.dart';

sealed class StoredQueryResult {
  const StoredQueryResult();
}

class StoredQuerySuccess extends StoredQueryResult {
  const StoredQuerySuccess({required this.value, required this.logLines});

  final Object? value;
  final List<String> logLines;
}

class StoredQueryError extends StoredQueryResult {
  const StoredQueryError({
    required this.message,
    required this.logLines,
    this.data,
  });

  final String message;
  final List<String> logLines;
  final Object? data;
}

class RemoteQueryDelta {
  const RemoteQueryDelta({
    required this.queryId,
    this.result,
    this.removed = false,
  });

  final int queryId;
  final StoredQueryResult? result;
  final bool removed;
}

class RemoteQuerySet {
  StateVersion _version = const StateVersion.initial();
  final Map<int, StoredQueryResult> _results = <int, StoredQueryResult>{};

  StateVersion get version => _version;

  StoredQueryResult? resultFor(int queryId) => _results[queryId];

  void reset() {
    _version = const StateVersion.initial();
    _results.clear();
  }

  List<RemoteQueryDelta> applyTransition(Transition transition) {
    if (!_version.isSameVersion(transition.startVersion)) {
      throw StateError(
        'Transition startVersion ${transition.startVersion.toJson()} '
        'does not match current version ${_version.toJson()}',
      );
    }

    final deltas = <RemoteQueryDelta>[];
    for (final modification in transition.modifications) {
      switch (modification) {
        case QueryUpdated():
          final result = StoredQuerySuccess(
            value: modification.value,
            logLines: modification.logLines,
          );
          _results[modification.queryId] = result;
          deltas.add(
            RemoteQueryDelta(queryId: modification.queryId, result: result),
          );
        case QueryFailed():
          final result = StoredQueryError(
            message: modification.errorMessage,
            data: modification.errorData,
            logLines: modification.logLines,
          );
          _results[modification.queryId] = result;
          deltas.add(
            RemoteQueryDelta(queryId: modification.queryId, result: result),
          );
        case QueryRemoved():
          _results.remove(modification.queryId);
          deltas.add(
            RemoteQueryDelta(queryId: modification.queryId, removed: true),
          );
      }
    }

    _version = transition.endVersion;
    return deltas;
  }
}
