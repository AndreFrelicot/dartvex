import 'dart:convert';

import '../protocol/encoding.dart';
import '../protocol/messages.dart';
import '../values/json_codec.dart';

/// Captured client-side authentication credentials.
///
/// Retains the token type and value so the identity can be re-affirmed across
/// reconnects and resumes as an [Authenticate] message.
class AuthState {
  /// Creates an [AuthState] for the given [tokenType] and [value], optionally
  /// [impersonating] another identity (used only for `Admin` tokens).
  const AuthState({
    required this.tokenType,
    required this.value,
    this.impersonating,
  });

  /// The auth token type, e.g. `User`, `Admin`, or `None`.
  final String tokenType;

  /// The raw token value sent to the server, or `null` when there is none.
  final String? value;

  /// Identity attributes an `Admin` token is impersonating, if any.
  final Map<String, dynamic>? impersonating;

  /// Builds an [Authenticate] message for this auth state at [baseVersion].
  Authenticate toAuthenticate(int baseVersion) {
    return Authenticate(
      tokenType: tokenType,
      baseVersion: baseVersion,
      value: value,
      impersonating: impersonating,
    );
  }
}

/// The local record of a single active query subscription.
///
/// Tracks the wire [queryId], the query being run, and the set of subscribers
/// sharing it, so multiple callers of the same query coalesce onto one entry in
/// the query set.
class QuerySubscriptionState {
  /// Creates a [QuerySubscriptionState] for the query identified by [queryId].
  QuerySubscriptionState({
    required this.queryId,
    required this.udfPath,
    required this.args,
    required this.subscriberIds,
    this.journal,
  });

  /// The protocol query id assigned to this subscription.
  final int queryId;

  /// The canonicalized `module:function` path of the query UDF.
  final String udfPath;

  /// The arguments the query is invoked with.
  final Map<String, dynamic> args;

  /// The ids of all subscribers currently sharing this query.
  final Set<int> subscriberIds;

  /// The latest journal token reported by the server for this query, if any.
  String? journal;
}

/// The result of registering a new subscriber via [LocalSyncState.subscribe].
///
/// Carries the assigned ids plus any [ModifyQuerySet] that must be sent to the
/// server; [message] is `null` when the query was already active or the state
/// is paused.
class SubscriptionRegistration {
  /// Creates a [SubscriptionRegistration] describing a newly added subscriber.
  const SubscriptionRegistration({
    required this.subscriberId,
    required this.queryId,
    this.message,
  });

  /// The id assigned to the newly registered subscriber.
  final int subscriberId;

  /// The query id the subscriber is attached to.
  final int queryId;

  /// The query-set modification to send, or `null` if nothing must go out.
  final ModifyQuerySet? message;
}

/// The authoritative client-side mirror of the Convex sync protocol state.
///
/// Manages the local query set, identity, and version counters, producing the
/// [ClientMessage]s (ModifyQuerySet, Authenticate) that keep the server in sync
/// and tracking what remains outstanding across pauses and reconnects.
class LocalSyncState {
  int _nextQueryId = 0;
  int _nextSubscriberId = 0;

  /// The current query-set version; incremented for every emitted
  /// [ModifyQuerySet] and reset on reconnect.
  int querySetVersion = 0;

  /// The current identity version; incremented for every emitted
  /// [Authenticate] and reset on reconnect.
  int authVersion = 0;

  /// The highest server timestamp observed so far, or `null` if none yet.
  String? maxObservedTimestamp;
  AuthState? _authState;

  final Set<int> _outstandingQueriesOlderThanRestart = <int>{};
  bool _outstandingAuthOlderThanRestart = false;

  bool _paused = false;
  bool _pendingAuthModification = false;
  final Map<int, QuerySetOperation> _pendingQuerySetModifications =
      <int, QuerySetOperation>{};

  final Map<String, QuerySubscriptionState> _queriesByToken =
      <String, QuerySubscriptionState>{};
  final Map<int, String> _queryTokenByQueryId = <int, String>{};
  final Map<int, String> _queryTokenBySubscriberId = <int, String>{};

  /// The current captured auth state, or `null` when unauthenticated.
  AuthState? get authState => _authState;

  /// Whether an auth identity is currently set.
  bool get hasAuth => _authState != null;

  /// Whether the sync state is currently paused while auth is being resolved.
  ///
  /// While paused, query-set modifications are buffered instead of being
  /// emitted, and auth updates do not advance the identity version. They are
  /// replayed together by [resume]. See [pause].
  bool get isPaused => _paused;

  /// Whether every query and auth update that predates the most recent
  /// reconnect has been confirmed by the server.
  ///
  /// Returns `true` for a fresh state and once all queries re-issued by
  /// [prepareReconnect] have produced a result (or been unsubscribed) and any
  /// re-sent auth has been confirmed via [markAuthCompletion]. The sync layer
  /// uses this to decide when the connection has proven itself after a restart.
  bool hasSyncedPastLastReconnect() =>
      _outstandingQueriesOlderThanRestart.isEmpty &&
      !_outstandingAuthOlderThanRestart;

  /// Marks the auth re-sent by [prepareReconnect] as confirmed, clearing it
  /// from the work outstanding since the last reconnect.
  ///
  /// Called when an incoming transition advances the identity version, and when
  /// auth is cleared.
  void markAuthCompletion() {
    _outstandingAuthOlderThanRestart = false;
  }

  /// Whether [version] is the current identity version or newer.
  ///
  /// Used to discard auth-bearing server messages that reflect an auth version
  /// the client has already advanced past (a stale Transition or AuthError).
  /// Mirrors the official client's `isCurrentOrNewerAuthVersion`.
  bool isCurrentOrNewerAuthVersion(int version) => version >= authVersion;

  /// Returns the query token for an active queryId, or null if not found.
  String? tokenForQueryId(int queryId) => _queryTokenByQueryId[queryId];

  /// Returns the active queryId for a query [token], or null if not subscribed.
  ///
  /// Lets the optimistic overlay map a changed token back to the query whose
  /// subscribers must be notified.
  int? queryIdForToken(String token) => _queriesByToken[token]?.queryId;

  /// Registers a new subscriber for the query [udfPath] with [args].
  ///
  /// Coalesces onto an existing query when one matches the same token,
  /// otherwise assigns a fresh query id and produces an [Add] modification. The
  /// returned [SubscriptionRegistration] carries a [ModifyQuerySet] to send
  /// unless the query already existed or the state is paused.
  SubscriptionRegistration subscribe(
    String udfPath,
    Map<String, dynamic> args, {
    String? journal,
  }) {
    final canonicalPath = canonicalizeUdfPath(udfPath);
    final token = serializeQueryToken(canonicalPath, args);
    final existing = _queriesByToken[token];
    final subscriberId = _nextSubscriberId++;

    if (existing != null) {
      existing.subscriberIds.add(subscriberId);
      _queryTokenBySubscriberId[subscriberId] = token;
      return SubscriptionRegistration(
        subscriberId: subscriberId,
        queryId: existing.queryId,
      );
    }

    final queryId = _nextQueryId++;
    final state = QuerySubscriptionState(
      queryId: queryId,
      udfPath: canonicalPath,
      args: Map<String, dynamic>.from(args),
      subscriberIds: <int>{subscriberId},
      journal: journal,
    );
    _queriesByToken[token] = state;
    _queryTokenByQueryId[queryId] = token;
    _queryTokenBySubscriberId[subscriberId] = token;

    final add = Add(
      queryId: queryId,
      udfPath: canonicalPath,
      args: <dynamic>[Map<String, dynamic>.from(args)],
      journal: journal,
    );

    if (_paused) {
      // Buffer the modification and leave the query-set version untouched; it is
      // emitted as a single coalesced ModifyQuerySet by [resume].
      _pendingQuerySetModifications[queryId] = add;
      return SubscriptionRegistration(
        subscriberId: subscriberId,
        queryId: queryId,
      );
    }

    final baseVersion = querySetVersion;
    querySetVersion += 1;
    return SubscriptionRegistration(
      subscriberId: subscriberId,
      queryId: queryId,
      message: ModifyQuerySet(
        baseVersion: baseVersion,
        newVersion: querySetVersion,
        modifications: <QuerySetOperation>[add],
      ),
    );
  }

  /// Removes the subscriber [subscriberId] from its query.
  ///
  /// When the last subscriber of a query is removed, the query is dropped and a
  /// [ModifyQuerySet] containing a [Remove] is returned; otherwise (or while
  /// paused, or when the query is still shared) the result is `null`.
  ModifyQuerySet? unsubscribe(int subscriberId) {
    final token = _queryTokenBySubscriberId.remove(subscriberId);
    if (token == null) {
      return null;
    }
    final state = _queriesByToken[token];
    if (state == null) {
      return null;
    }
    state.subscriberIds.remove(subscriberId);
    if (state.subscriberIds.isNotEmpty) {
      return null;
    }
    _queriesByToken.remove(token);
    _queryTokenByQueryId.remove(state.queryId);
    // Unsubscribing a query that was outstanding since the last reconnect
    // resolves it: we no longer expect a result for it.
    _outstandingQueriesOlderThanRestart.remove(state.queryId);

    if (_paused) {
      // If this query's Add was buffered this pause cycle and never sent, drop
      // it; otherwise buffer a Remove. Either way nothing goes out until resume.
      if (_pendingQuerySetModifications.remove(state.queryId) == null) {
        _pendingQuerySetModifications[state.queryId] =
            Remove(queryId: state.queryId);
      }
      return null;
    }

    final baseVersion = querySetVersion;
    querySetVersion += 1;
    return ModifyQuerySet(
      baseVersion: baseVersion,
      newVersion: querySetVersion,
      modifications: <QuerySetOperation>[Remove(queryId: state.queryId)],
    );
  }

  /// Sets the auth identity to [tokenType]/[value] and returns the resulting
  /// [Authenticate] message.
  ///
  /// Advances the identity version unless paused, in which case the new version
  /// is only emitted by [resume]. Mirrors the official client's `setAuth`.
  Authenticate setAuth({required String tokenType, String? value}) {
    final hadAuth = _authState != null;
    restoreAuth(tokenType: tokenType, value: value);
    if (_authState == null) {
      // Clearing auth resolves any auth outstanding since the last reconnect.
      markAuthCompletion();
    }
    final baseVersion = authVersion;
    // While paused the auth is captured but not yet on the wire, so the identity
    // version is only advanced when [resume] actually emits the Authenticate.
    if (_paused) {
      _pendingAuthModification = _pendingAuthModification ||
          _authState != null ||
          hadAuth ||
          _outstandingAuthOlderThanRestart;
    } else {
      authVersion += 1;
    }
    return Authenticate(
      tokenType: tokenType,
      baseVersion: baseVersion,
      value: value,
    );
  }

  /// Pauses query-set and auth emission while auth is being resolved.
  ///
  /// New subscriptions buffer their modifications and auth updates hold the
  /// identity version steady until [resume] replays everything at once. Mirrors
  /// the official client's pause sub-state. See [isPaused].
  void pause() {
    _paused = true;
  }

  /// Replays everything buffered while paused and clears the paused state.
  ///
  /// Returns the coalesced query-set modification (if any subscriptions changed
  /// while paused) and an [Authenticate] for the current auth or explicit auth
  /// clear, each advancing its version. Both are `null` when there is nothing
  /// to send.
  /// Mirrors the official client's `resume`.
  (ModifyQuerySet?, Authenticate?) resume() {
    if (!_paused) {
      return (null, null);
    }
    ModifyQuerySet? querySet;
    if (_pendingQuerySetModifications.isNotEmpty) {
      final baseVersion = querySetVersion;
      querySetVersion += 1;
      querySet = ModifyQuerySet(
        baseVersion: baseVersion,
        newVersion: querySetVersion,
        modifications:
            _pendingQuerySetModifications.values.toList(growable: false),
      );
    }
    Authenticate? authenticate;
    final auth = _authState;
    if (_pendingAuthModification || auth != null) {
      final baseVersion = authVersion;
      authVersion += 1;
      authenticate = auth?.toAuthenticate(baseVersion) ??
          Authenticate(tokenType: 'None', baseVersion: baseVersion);
    }
    _paused = false;
    _pendingAuthModification = false;
    _pendingQuerySetModifications.clear();
    return (querySet, authenticate);
  }

  /// Sets an `Admin` auth token, optionally impersonating a user identity, and
  /// returns the resulting [Authenticate] message.
  ///
  /// Protocol-level support only: there is intentionally no client-facing admin
  /// API, since shipping an admin/deploy key in an app is a security hazard. The
  /// impersonation attributes survive a reconnect via [prepareReconnect]. While
  /// paused, the identity version is held until [resume], as with [setAuth].
  /// Mirrors the official client's `setAdminAuth`.
  Authenticate setAdminAuth({
    required String value,
    Map<String, dynamic>? impersonating,
  }) {
    _authState = AuthState(
      tokenType: 'Admin',
      value: value,
      impersonating: impersonating,
    );
    final baseVersion = authVersion;
    if (_paused) {
      _pendingAuthModification = true;
    } else {
      authVersion += 1;
    }
    return Authenticate(
      tokenType: 'Admin',
      baseVersion: baseVersion,
      value: value,
      impersonating: impersonating,
    );
  }

  /// Restores the captured auth state without emitting a message or advancing
  /// the identity version.
  ///
  /// A [tokenType] of `None` clears the auth state. Used internally by
  /// [setAuth] and to re-seat credentials.
  void restoreAuth({required String tokenType, String? value}) {
    _authState = tokenType == 'None'
        ? null
        : AuthState(tokenType: tokenType, value: value);
  }

  /// Records server timestamp [ts], advancing [maxObservedTimestamp] when it is
  /// newer than the highest seen so far.
  void observeTimestamp(String ts) {
    if (maxObservedTimestamp == null) {
      maxObservedTimestamp = ts;
      return;
    }
    if (_compareTs(ts, maxObservedTimestamp!) > 0) {
      maxObservedTimestamp = ts;
    }
  }

  /// Stores the latest [journal] token reported for the query [queryId].
  ///
  /// No-ops when [journal] is `null` or the query is no longer subscribed.
  void updateJournal(int queryId, String? journal) {
    if (journal == null) {
      return;
    }
    final token = _queryTokenByQueryId[queryId];
    if (token == null) {
      return;
    }
    final state = _queriesByToken[token];
    if (state == null) {
      return;
    }
    state.journal = journal;
  }

  /// Returns the ids of all subscribers attached to query [queryId], or an
  /// empty list when the query is not active.
  List<int> subscriberIdsForQuery(int queryId) {
    final token = _queryTokenByQueryId[queryId];
    if (token == null) {
      return const <int>[];
    }
    final state = _queriesByToken[token];
    if (state == null) {
      return const <int>[];
    }
    return state.subscriberIds.toList(growable: false);
  }

  /// Returns the query id the subscriber [subscriberId] is attached to, or
  /// `null` if the subscriber is unknown.
  int? queryIdForSubscriber(int subscriberId) {
    final token = _queryTokenBySubscriberId[subscriberId];
    if (token == null) {
      return null;
    }
    return _queriesByToken[token]?.queryId;
  }

  /// Returns the [QuerySubscriptionState] for query [queryId], or `null` if no
  /// such query is active.
  QuerySubscriptionState? queryStateForId(int queryId) {
    final token = _queryTokenByQueryId[queryId];
    if (token == null) {
      return null;
    }
    return _queriesByToken[token];
  }

  /// Applies the local bookkeeping for a server [transition].
  ///
  /// Records any query journals and clears queries that were outstanding since
  /// the last reconnect now that the server has reported on them (whether the
  /// query updated, failed, or was removed). See [hasSyncedPastLastReconnect].
  void transition(Transition transition) {
    for (final modification in transition.modifications) {
      _outstandingQueriesOlderThanRestart.remove(modification.queryId);
      switch (modification) {
        case QueryUpdated():
          updateJournal(modification.queryId, modification.journal);
        case QueryFailed():
          updateJournal(modification.queryId, modification.journal);
        case QueryRemoved():
          break;
      }
    }
  }

  /// Rebuilds the messages needed to restore this state on a fresh connection.
  ///
  /// Re-issued queries are recorded as outstanding until the server reports on
  /// them again, and re-sent auth is likewise recorded as outstanding, so
  /// [hasSyncedPastLastReconnect] stays `false` until the connection has fully
  /// re-synced.
  List<ClientMessage> prepareReconnect() {
    // A restart supersedes any pause: the full query set (and auth) is rebuilt
    // from scratch below, so the buffered modifications are discarded.
    _paused = false;
    _pendingQuerySetModifications.clear();
    _pendingAuthModification = false;
    querySetVersion = 0;
    authVersion = 0;
    _outstandingQueriesOlderThanRestart.clear();
    final messages = <ClientMessage>[];

    if (_authState != null) {
      messages.add(_authState!.toAuthenticate(authVersion));
      authVersion = 1;
      _outstandingAuthOlderThanRestart = true;
    } else {
      _outstandingAuthOlderThanRestart = false;
    }

    if (_queriesByToken.isEmpty) {
      return messages;
    }

    querySetVersion = 1;
    final modifications = <QuerySetOperation>[];
    for (final state in _queriesByToken.values) {
      modifications.add(
        Add(
          queryId: state.queryId,
          udfPath: state.udfPath,
          args: <dynamic>[Map<String, dynamic>.from(state.args)],
          journal: state.journal,
        ),
      );
      _outstandingQueriesOlderThanRestart.add(state.queryId);
    }
    messages.add(
      ModifyQuerySet(
        baseVersion: 0,
        newVersion: querySetVersion,
        modifications: modifications,
      ),
    );
    return messages;
  }

  /// Normalizes [udfPath] to the canonical `module:function` form.
  ///
  /// A path without a `:` defaults to the `default` export, and a trailing
  /// `.js` extension on the module is stripped, matching the server's UDF path
  /// canonicalization.
  static String canonicalizeUdfPath(String udfPath) {
    final parts = udfPath.split(':');
    late final String moduleName;
    late final String functionName;
    if (parts.length == 1) {
      moduleName = parts.first;
      functionName = 'default';
    } else {
      moduleName = parts.sublist(0, parts.length - 1).join(':');
      functionName = parts.last;
    }
    final normalizedModule = moduleName.endsWith('.js')
        ? moduleName.substring(0, moduleName.length - 3)
        : moduleName;
    return '$normalizedModule:$functionName';
  }

  /// Builds the stable query token that identifies a query by its canonical
  /// [udfPath] and JSON-encoded [args].
  ///
  /// Used as the key under which subscriptions to the same query are coalesced.
  static String serializeQueryToken(String udfPath, Map<String, dynamic> args) {
    final normalized = <String, dynamic>{
      'udfPath': udfPath,
      'args': convexToJson(args),
    };
    return jsonEncode(normalized);
  }

  int _compareTs(String left, String right) {
    return compareEncodedTs(left, right);
  }
}
