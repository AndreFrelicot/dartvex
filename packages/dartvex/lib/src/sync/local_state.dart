import 'dart:convert';

import '../protocol/messages.dart';
import '../values/json_codec.dart';

class AuthState {
  const AuthState({required this.tokenType, required this.value});

  final String tokenType;
  final String? value;

  Authenticate toAuthenticate(int baseVersion) {
    return Authenticate(
      tokenType: tokenType,
      baseVersion: baseVersion,
      value: value,
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

  final Map<String, QuerySubscriptionState> _queriesByToken =
      <String, QuerySubscriptionState>{};
  final Map<int, String> _queryTokenByQueryId = <int, String>{};
  final Map<int, String> _queryTokenBySubscriberId = <int, String>{};

  AuthState? get authState => _authState;

  bool get hasAuth => _authState != null;

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

    final baseVersion = querySetVersion;
    querySetVersion += 1;
    return SubscriptionRegistration(
      subscriberId: subscriberId,
      queryId: queryId,
      message: ModifyQuerySet(
        baseVersion: baseVersion,
        newVersion: querySetVersion,
        modifications: <QuerySetOperation>[
          Add(
            queryId: queryId,
            udfPath: canonicalPath,
            args: <dynamic>[Map<String, dynamic>.from(args)],
            journal: journal,
          ),
        ],
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
    final baseVersion = authVersion;
    authVersion += 1;
    return Authenticate(
      tokenType: tokenType,
      baseVersion: baseVersion,
      value: value,
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

  List<ClientMessage> prepareReconnect() {
    querySetVersion = 0;
    authVersion = 0;
    final messages = <ClientMessage>[];

    if (_authState != null) {
      messages.add(_authState!.toAuthenticate(authVersion));
      authVersion = 1;
    }

    if (_queriesByToken.isEmpty) {
      return messages;
    }

    querySetVersion = 1;
    messages.add(
      ModifyQuerySet(
        baseVersion: 0,
        newVersion: querySetVersion,
        modifications: _queriesByToken.values
            .map(
              (state) => Add(
                queryId: state.queryId,
                udfPath: state.udfPath,
                args: <dynamic>[Map<String, dynamic>.from(state.args)],
                journal: state.journal,
              ),
            )
            .toList(growable: false),
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
    final leftBytes = base64Decode(left);
    final rightBytes = base64Decode(right);
    for (var index = leftBytes.length - 1; index >= 0; index -= 1) {
      final difference = leftBytes[index] - rightBytes[index];
      if (difference != 0) {
        return difference;
      }
    }
    return 0;
  }
}
