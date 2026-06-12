import '../values/json_codec.dart';
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
  /// Returns `null` when the query's value is Convex `null`, when the query is
  /// not in the client, when it is loading, or when it is in an error state.
  /// Use [clearQuery] rather than `setQuery(..., null)` when you need to
  /// explicitly show loading.
  dynamic getQuery(String name,
      [Map<String, dynamic> args = const <String, dynamic>{}]);

  /// Returns the args and value of every query named [name] currently in the
  /// client.
  ///
  /// Useful for updates that must inspect or rewrite many instances of a query
  /// at once (for example, every page of a paginated list). Each entry exposes
  /// [OptimisticQueryEntry.isLoading] to distinguish a loading/cleared query
  /// from a concrete Convex `null` value.
  List<OptimisticQueryEntry> getAllQueries(String name);

  /// Optimistically sets the result of the query [name] called with [args].
  ///
  /// [value] may be derived from [getQuery]. Passing `null` now means the real
  /// Convex `null` value. Use [clearQuery] to remove the query's value and show
  /// loading while the server recomputes it. The override lives only until the
  /// owning mutation completes, then it is rolled back.
  void setQuery(String name, Map<String, dynamic> args, Object? value);

  /// Optimistically clears the result of the query [name] called with [args].
  ///
  /// This is the Dart equivalent of the official JavaScript client's
  /// `setQuery(..., undefined)`: live subscribers see a loading event until the
  /// server sends a concrete success or error, or until the optimistic layer is
  /// rolled back.
  void clearQuery(String name, Map<String, dynamic> args);
}

/// One query returned by [OptimisticLocalStore.getAllQueries]: its [args] and
/// current [value], plus whether the query is currently loading.
class OptimisticQueryEntry {
  /// Creates an entry pairing a query's [args] with its current [value].
  const OptimisticQueryEntry({
    required this.args,
    required this.value,
    this.isLoading = false,
  });

  /// The arguments the query was subscribed with.
  final Map<String, dynamic> args;

  /// The query's current value. This can be `null` for either a concrete Convex
  /// `null` or for a loading query; check [isLoading] to distinguish them.
  final Object? value;

  /// Whether this entry currently represents a loading/cleared query.
  final bool isLoading;
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
            // Hand out a deep copy: for server-backed entries these are the
            // very args the sync layer re-encodes into every reconnect's
            // query-set replay, and a misbehaving update mutating the live
            // map would poison that replay (and detach the entry from its
            // token). The official client is immune by construction — it
            // re-parses args from the query token on each call.
            args: canonicalizeConvexArgs(query.args),
            value: _queryValue(query.result),
            isLoading: query.result == null,
          ),
        );
      }
    }
    return matches;
  }

  @override
  void setQuery(String name, Map<String, dynamic> args, Object? value) {
    _writeQuery(
      name,
      args,
      StoredQuerySuccess(value: value, logLines: const <String>[]),
    );
  }

  @override
  void clearQuery(String name, Map<String, dynamic> args) {
    _writeQuery(name, args, null);
  }

  void _writeQuery(
    String name,
    Map<String, dynamic> args,
    StoredQueryResult? result,
  ) {
    final canonicalPath = LocalSyncState.canonicalizeUdfPath(name);
    final token = LocalSyncState.serializeQueryToken(canonicalPath, args);
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
  final Set<String> _optimisticTokens = <String>{};

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
    final optimisticTokens = <String>{};
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
      optimisticTokens.addAll(store.modifiedQueries);
    }
    _optimisticUpdates
      ..clear()
      ..addAll(survivingUpdates);
    _optimisticTokens
      ..clear()
      ..addAll(optimisticTokens);

    // Shallow identity comparison: an unchanged server query keeps the same
    // StoredQueryResult instance across transitions, so only genuinely changed,
    // newly optimistic, or removed optimistic-only tokens are reported.
    final changedQueries = <String>[];
    final allTokens = <String>{
      ...oldQueryResults.keys,
      ..._queryResults.keys,
    };
    for (final token in allTokens) {
      final oldQuery = oldQueryResults[token];
      final newQuery = _queryResults[token];
      if (oldQuery == null ||
          newQuery == null ||
          !identical(oldQuery.result, newQuery.result)) {
        changedQueries.add(token);
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
    _optimisticTokens.addAll(store.modifiedQueries);
    return store.modifiedQueries;
  }

  /// The overlaid (server + optimistic) result for [token], including errors,
  /// or `null` if the token has no value (absent or loading).
  StoredQueryResult? rawResultForToken(String token) =>
      _queryResults[token]?.result;

  /// Whether [token] is present in the overlay as an explicit loading result.
  bool isLoadingForToken(String token) {
    final query = _queryResults[token];
    return query != null && query.result == null;
  }

  /// Whether any optimistic update is currently active.
  bool get hasActiveUpdates => _optimisticUpdates.isNotEmpty;

  /// Whether an active optimistic update has touched [token].
  bool hasOptimisticUpdateForToken(String token) =>
      _optimisticTokens.contains(token);
}
