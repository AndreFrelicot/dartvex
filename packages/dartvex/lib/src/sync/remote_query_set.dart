import '../protocol/messages.dart';
import '../protocol/state_version.dart';

/// The locally stored outcome of a remote query subscription.
///
/// Either a [StoredQuerySuccess] carrying the query value or a
/// [StoredQueryError] describing why the query function failed on the server.
sealed class StoredQueryResult {
  /// Creates a [StoredQueryResult].
  const StoredQueryResult();
}

/// A successfully evaluated remote query result.
class StoredQuerySuccess extends StoredQueryResult {
  /// Creates a [StoredQuerySuccess] from a query [value] and its [logLines].
  const StoredQuerySuccess({required this.value, required this.logLines});

  /// The deserialized value returned by the query function.
  final Object? value;

  /// Log lines emitted by the query function during evaluation.
  final List<String> logLines;
}

/// A remote query result representing a server-side query function failure.
class StoredQueryError extends StoredQueryResult {
  /// Creates a [StoredQueryError] from an error [message], its [logLines], and
  /// optional structured error [data].
  const StoredQueryError({
    required this.message,
    required this.logLines,
    this.data,
  });

  /// The human-readable error message reported by the server.
  final String message;

  /// Log lines emitted by the query function before it failed.
  final List<String> logLines;

  /// Optional structured error data attached by the server, if any.
  final Object? data;
}

/// A single change to a query result produced by applying a server transition.
class RemoteQueryDelta {
  /// Creates a [RemoteQueryDelta] for [queryId], optionally carrying a new
  /// [result] or marking the query as [removed].
  const RemoteQueryDelta({
    required this.queryId,
    this.result,
    this.removed = false,
  });

  /// The id of the query affected by this delta.
  final int queryId;

  /// The updated result for the query, or `null` when the query was removed.
  final StoredQueryResult? result;

  /// Whether the query was removed from the remote query set.
  final bool removed;
}

/// Tracks the authoritative remote query results and the current
/// [StateVersion] received from the server over the websocket transport.
class RemoteQuerySet {
  StateVersion _version = const StateVersion.initial();
  final Map<int, StoredQueryResult> _results = <int, StoredQueryResult>{};

  /// The current server state version reflected by these stored results.
  StateVersion get version => _version;

  /// Returns the stored result for [queryId], or `null` if none is held.
  StoredQueryResult? resultFor(int queryId) => _results[queryId];

  /// The set of query ids that currently hold a remote result.
  ///
  /// Captured before [reset] during a reconnect so the sync layer can tell
  /// which re-issued queries already have data and which are still outstanding
  /// (see `LocalSyncState.prepareReconnect`).
  Set<int> get resultQueryIds => _results.keys.toSet();

  /// Clears all stored results and resets the version to its initial value,
  /// used when re-establishing the websocket connection.
  void reset() {
    _version = const StateVersion.initial();
    _results.clear();
  }

  /// Applies a server [Transition] to the stored results, advancing the
  /// version and returning the [RemoteQueryDelta]s describing each change.
  ///
  /// Throws a [StateError] if the transition's `startVersion` does not match
  /// the currently tracked [version].
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
