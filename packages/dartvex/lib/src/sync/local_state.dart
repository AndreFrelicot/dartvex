import 'dart:convert';

import '../protocol/encoding.dart';
import '../protocol/messages.dart';
import '../values/json_codec.dart';

class AuthState {
  const AuthState({
    required this.tokenType,
    required this.value,
    this.impersonating,
  });

  final String tokenType;
  final String? value;

  /// Identity attributes an `Admin` token is impersonating, if any.
  final Map<String, dynamic>? impersonating;

  Authenticate toAuthenticate(int baseVersion) {
    return Authenticate(
      tokenType: tokenType,
      baseVersion: baseVersion,
      value: value,
      impersonating: impersonating,
    );
  }
}

class QuerySubscriptionState {
  QuerySubscriptionState({
    required this.queryId,
    required this.udfPath,
    required this.args,
    required this.subscriberIds,
    this.journal,
  });

  final int queryId;
  final String udfPath;
  final Map<String, dynamic> args;
  final Set<int> subscriberIds;
  String? journal;
}

class SubscriptionRegistration {
  const SubscriptionRegistration({
    required this.subscriberId,
    required this.queryId,
    this.message,
  });

  final int subscriberId;
  final int queryId;
  final ModifyQuerySet? message;
}

class LocalSyncState {
  int _nextQueryId = 0;
  int _nextSubscriberId = 0;
  int querySetVersion = 0;
  int authVersion = 0;
  String? maxObservedTimestamp;
  AuthState? _authState;

  final Set<int> _outstandingQueriesOlderThanRestart = <int>{};
  bool _outstandingAuthOlderThanRestart = false;

  bool _paused = false;
  final Map<int, QuerySetOperation> _pendingQuerySetModifications =
      <int, QuerySetOperation>{};

  final Map<String, QuerySubscriptionState> _queriesByToken =
      <String, QuerySubscriptionState>{};
  final Map<int, String> _queryTokenByQueryId = <int, String>{};
  final Map<int, String> _queryTokenBySubscriberId = <int, String>{};

  AuthState? get authState => _authState;

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

  Authenticate setAuth({required String tokenType, String? value}) {
    restoreAuth(tokenType: tokenType, value: value);
    if (_authState == null) {
      // Clearing auth resolves any auth outstanding since the last reconnect.
      markAuthCompletion();
    }
    final baseVersion = authVersion;
    // While paused the auth is captured but not yet on the wire, so the identity
    // version is only advanced when [resume] actually emits the Authenticate.
    if (!_paused) {
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
  /// while paused) and an [Authenticate] re-affirming the current auth (if any),
  /// each advancing its version. Both are `null` when there is nothing to send.
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
    if (auth != null) {
      final baseVersion = authVersion;
      authVersion += 1;
      authenticate = auth.toAuthenticate(baseVersion);
    }
    _paused = false;
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
    if (!_paused) {
      authVersion += 1;
    }
    return Authenticate(
      tokenType: 'Admin',
      baseVersion: baseVersion,
      value: value,
      impersonating: impersonating,
    );
  }

  void restoreAuth({required String tokenType, String? value}) {
    _authState = tokenType == 'None'
        ? null
        : AuthState(tokenType: tokenType, value: value);
  }

  void observeTimestamp(String ts) {
    if (maxObservedTimestamp == null) {
      maxObservedTimestamp = ts;
      return;
    }
    if (_compareTs(ts, maxObservedTimestamp!) > 0) {
      maxObservedTimestamp = ts;
    }
  }

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

  int? queryIdForSubscriber(int subscriberId) {
    final token = _queryTokenBySubscriberId[subscriberId];
    if (token == null) {
      return null;
    }
    return _queriesByToken[token]?.queryId;
  }

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
  /// [oldRemoteQueryResults] is the set of query ids that already held a remote
  /// result before the reconnect (captured before the remote query set is
  /// reset). Re-issued queries missing from that set are recorded as
  /// outstanding until the server reports on them again, and re-sent auth is
  /// likewise recorded as outstanding, so [hasSyncedPastLastReconnect] stays
  /// `false` until the connection has fully re-synced.
  List<ClientMessage> prepareReconnect(Set<int> oldRemoteQueryResults) {
    // A restart supersedes any pause: the full query set (and auth) is rebuilt
    // from scratch below, so the buffered modifications are discarded.
    _paused = false;
    _pendingQuerySetModifications.clear();
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
      if (!oldRemoteQueryResults.contains(state.queryId)) {
        _outstandingQueriesOlderThanRestart.add(state.queryId);
      }
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
