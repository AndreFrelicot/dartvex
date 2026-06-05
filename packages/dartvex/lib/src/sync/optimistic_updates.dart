import 'local_state.dart';
import 'remote_query_set.dart';

/// A view of the query results currently in the client, for use within an
/// [OptimisticUpdate].
///
/// An update reads the current (server + previously-applied-optimistic) results
/// with [getQuery]/[getAllQueries] and overlays new values with [setQuery]. The
/// overlay is recomputed from scratch every time the server sends fresh results,
/// so an update may run many times — keep it pure and synchronous.
///
/// Query results must be treated as immutable: always build new collections
/// rather than mutating the values returned by [getQuery]/[getAllQueries], or
/// you risk corrupting the client's cache.
abstract interface class OptimisticLocalStore {
  /// Returns the current result of the query [name] called with [args].
  ///
  /// Returns `null` when the query is not in the client or is loading (or is in
  /// an error state — errors are reported as loading so an update never crashes
  /// on a single failed query).
  dynamic getQuery(String name,
      [Map<String, dynamic> args = const <String, dynamic>{}]);

  /// Returns the args and value of every query named [name] currently in the
  /// client.
  ///
  /// Useful for updates that must inspect or rewrite many instances of a query
  /// at once (for example, every page of a paginated list). Each entry's value
  /// is `null` when that query is loading.
  List<OptimisticQueryEntry> getAllQueries(String name);

  /// Optimistically sets the result of the query [name] called with [args].
  ///
  /// [value] may be derived from [getQuery]; pass `null` to remove the query's
  /// value (showing it as loading) while the server recomputes it. The override
  /// lives only until the owning mutation completes, then it is rolled back.
  void setQuery(String name, Map<String, dynamic> args, Object? value);
}

/// One query returned by [OptimisticLocalStore.getAllQueries]: its [args] and
/// current [value] (`null` while loading).
class OptimisticQueryEntry {
  /// Creates an entry pairing a query's [args] with its current [value].
  const OptimisticQueryEntry({required this.args, required this.value});

  /// The arguments the query was subscribed with.
  final Map<String, dynamic> args;

  /// The query's current value, or `null` if it is loading.
  final Object? value;
}

/// A temporary, local edit to query results applied while a mutation is in
/// flight.
///
/// Runs synchronously when the mutation is sent and is rolled back once the
/// mutation completes. It can be replayed multiple times (whenever the client
/// receives fresh server data while the mutation is pending), so it must be a
/// pure function of the store and any values it closes over.
typedef OptimisticUpdate = void Function(OptimisticLocalStore store);

/// A single query's server result plus the metadata needed to overlay it.
///
/// Internal plumbing: the sync layer builds one per subscribed query with a
/// remote result and feeds the map into
/// [OptimisticQueryResults.ingestQueryResultsFromServer].
typedef OverlayServerQuery = ({
  StoredQueryResult? result,
  String udfPath,
  Map<String, dynamic> args,
});

class _OptimisticLocalStoreImpl implements OptimisticLocalStore {
  _OptimisticLocalStoreImpl(this._queryResults);

  // A live reference to the overlay's result map; setQuery edits it in place.
  final Map<String, OverlayServerQuery> _queryResults;

  /// Tokens touched by this run, in order, so the caller can notify subscribers.
  final List<String> modifiedQueries = <String>[];

  @override
  dynamic getQuery(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final token = LocalSyncState.serializeQueryToken(
      LocalSyncState.canonicalizeUdfPath(name),
      args,
    );
    final query = _queryResults[token];
    if (query == null) {
      return null;
    }
    return _queryValue(query.result);
  }

  @override
  List<OptimisticQueryEntry> getAllQueries(String name) {
    final canonicalPath = LocalSyncState.canonicalizeUdfPath(name);
    final matches = <OptimisticQueryEntry>[];
    for (final query in _queryResults.values) {
      if (query.udfPath == canonicalPath) {
        matches.add(
          OptimisticQueryEntry(
            args: query.args,
            value: _queryValue(query.result),
          ),
        );
      }
    }
    return matches;
  }

  @override
  void setQuery(String name, Map<String, dynamic> args, Object? value) {
    final canonicalPath = LocalSyncState.canonicalizeUdfPath(name);
    final token = LocalSyncState.serializeQueryToken(canonicalPath, args);
    final StoredQueryResult? result = value == null
        ? null
        : StoredQuerySuccess(value: value, logLines: const <String>[]);
    _queryResults[token] = (
      result: result,
      udfPath: canonicalPath,
      args: Map<String, dynamic>.from(args),
    );
    modifiedQueries.add(token);
  }

  // Unwraps a stored result to the value an update should see: errors and
  // loading both surface as `null` so an update never throws mid-replay.
  static Object? _queryValue(StoredQueryResult? result) {
    if (result is StoredQuerySuccess) {
      return result.value;
    }
    return null;
  }
}

/// The effective view of all query results: the latest server results with
/// every active optimistic update replayed on top.
///
/// Internal to the sync layer. The base client keeps one instance, feeds it the
/// server results on each transition via [ingestQueryResultsFromServer], and
/// layers in-flight mutations' edits via [applyOptimisticUpdate]. Each layer is
/// tagged with its mutation's request id and dropped once that mutation
/// completes.
class OptimisticQueryResults {
  Map<String, OverlayServerQuery> _queryResults =
      <String, OverlayServerQuery>{};
  final List<({OptimisticUpdate update, int mutationId})> _optimisticUpdates =
      <({OptimisticUpdate update, int mutationId})>[];

  /// Rebuilds the overlay from fresh [serverQueryResults], dropping the layers
  /// of mutations in [optimisticUpdatesToDrop], and replaying the rest on top.
  ///
  /// Returns the tokens whose effective result changed (by identity), so the
  /// caller can notify exactly the affected subscribers.
  List<String> ingestQueryResultsFromServer(
    Map<String, OverlayServerQuery> serverQueryResults,
    Set<int> optimisticUpdatesToDrop,
  ) {
    _optimisticUpdates.removeWhere(
      (entry) => optimisticUpdatesToDrop.contains(entry.mutationId),
    );

    final oldQueryResults = _queryResults;
    _queryResults = Map<String, OverlayServerQuery>.from(serverQueryResults);
    final survivingUpdates = <({OptimisticUpdate update, int mutationId})>[];
    for (final entry in _optimisticUpdates) {
      final candidateResults =
          Map<String, OverlayServerQuery>.from(_queryResults);
      final store = _OptimisticLocalStoreImpl(candidateResults);
      try {
        entry.update(store);
      } catch (_) {
        continue;
      }
      _queryResults = candidateResults;
      survivingUpdates.add(entry);
    }
    _optimisticUpdates
      ..clear()
      ..addAll(survivingUpdates);

    // Shallow identity comparison: an unchanged server query keeps the same
    // StoredQueryResult instance across transitions, so only genuinely changed
    // (or newly optimistic) tokens are reported.
    final changedQueries = <String>[];
    for (final entry in _queryResults.entries) {
      final oldQuery = oldQueryResults[entry.key];
      if (oldQuery == null || !identical(oldQuery.result, entry.value.result)) {
        changedQueries.add(entry.key);
      }
    }
    return changedQueries;
  }

  /// Adds an optimistic [update] tagged with its mutation's [mutationId] and
  /// applies it on top of the current overlay.
  ///
  /// Returns the tokens the update touched so the caller can notify subscribers.
  List<String> applyOptimisticUpdate(OptimisticUpdate update, int mutationId) {
    final candidateResults =
        Map<String, OverlayServerQuery>.from(_queryResults);
    final store = _OptimisticLocalStoreImpl(candidateResults);
    update(store);
    _queryResults = candidateResults;
    _optimisticUpdates.add((update: update, mutationId: mutationId));
    return store.modifiedQueries;
  }

  /// The overlaid (server + optimistic) result for [token], including errors,
  /// or `null` if the token has no value (absent or loading).
  StoredQueryResult? rawResultForToken(String token) =>
      _queryResults[token]?.result;

  /// Whether any optimistic update is currently active.
  bool get hasActiveUpdates => _optimisticUpdates.isNotEmpty;
}
