import 'dart:async';
import 'dart:collection';

import '../protocol/messages.dart';
import 'local_state.dart';
import 'remote_query_set.dart';
import 'request_manager.dart';

sealed class BaseClientEvent {
  const BaseClientEvent();
}

class QueryUpdateEvent extends BaseClientEvent {
  const QueryUpdateEvent({required this.queryId, required this.result});

  final int queryId;
  final StoredQueryResult result;
}

class QueryRemovedEvent extends BaseClientEvent {
  const QueryRemovedEvent({required this.queryId});

  final int queryId;
}

class AuthConfirmedEvent extends BaseClientEvent {
  const AuthConfirmedEvent({required this.isAuthenticated});

  final bool isAuthenticated;
}

class AuthErrorEvent extends BaseClientEvent {
  const AuthErrorEvent({required this.error});

  final AuthError error;
}

class ReconnectRequiredEvent extends BaseClientEvent {
  const ReconnectRequiredEvent({required this.reason});

  final String reason;
}

class BaseClientReceiveResult {
  const BaseClientReceiveResult({
    this.events = const <BaseClientEvent>[],
    this.outgoing = const <ClientMessage>[],
  });

  final List<BaseClientEvent> events;
  final List<ClientMessage> outgoing;
}

class BaseClient {
  BaseClient({
    LocalSyncState? localState,
    RemoteQuerySet? remoteQuerySet,
    RequestManager? requestManager,
  })  : _localState = localState ?? LocalSyncState(),
        _remoteQuerySet = remoteQuerySet ?? RemoteQuerySet(),
        _requestManager = requestManager ?? RequestManager();

  final LocalSyncState _localState;
  final RemoteQuerySet _remoteQuerySet;
  final RequestManager _requestManager;
  final Queue<ClientMessage> _outgoing = Queue<ClientMessage>();

  int _nextRequestId = 0;

  LocalSyncState get localState => _localState;

  String? get maxObservedTimestamp => _localState.maxObservedTimestamp;

  final Map<String, StoredQueryResult> _resultCacheByToken =
      <String, StoredQueryResult>{};

  SubscriptionRegistration subscribe(
    String udfPath,
    Map<String, dynamic> args,
  ) {
    final registration = _localState.subscribe(udfPath, args);
    final message = registration.message;
    if (message != null) {
      _outgoing.add(message);
    }
    return registration;
  }

  void unsubscribe(int subscriberId) {
    final message = _localState.unsubscribe(subscriberId);
    if (message != null) {
      _outgoing.add(message);
    }
  }

  Future<dynamic> mutate(String udfPath, Map<String, dynamic> args) {
    final message = Mutation(
      requestId: _nextRequestId++,
      udfPath: LocalSyncState.canonicalizeUdfPath(udfPath),
      args: <dynamic>[Map<String, dynamic>.from(args)],
    );
    _outgoing.add(message);
    return _requestManager.trackMutation(message);
  }

  Future<dynamic> action(String udfPath, Map<String, dynamic> args) {
    final message = Action(
      requestId: _nextRequestId++,
      udfPath: LocalSyncState.canonicalizeUdfPath(udfPath),
      args: <dynamic>[Map<String, dynamic>.from(args)],
    );
    _outgoing.add(message);
    return _requestManager.trackAction(message);
  }

  void setAuth({required String tokenType, String? token}) {
    _outgoing.add(_localState.setAuth(tokenType: tokenType, value: token));
  }

  void clearAuth() {
    _outgoing.add(_localState.setAuth(tokenType: 'None'));
  }

  void restoreAuth({required String tokenType, String? token}) {
    _localState.restoreAuth(tokenType: tokenType, value: token);
  }

  void handleDisconnect(String reason) {
    _outgoing.clear();
    _requestManager.handleDisconnect(reason);
  }

  void failPendingRequests(String message) {
    _outgoing.clear();
    _requestManager.failAll(message);
  }

  List<ClientMessage> prepareReconnect() {
    _outgoing.clear();
    _remoteQuerySet.reset();
    _outgoing.addAll(_localState.prepareReconnect());
    _outgoing.addAll(_requestManager.prepareReconnect());
    return drainOutgoing(assumeSent: false);
  }

  StoredQueryResult? currentResultForQuery(int queryId) {
    return _remoteQuerySet.resultFor(queryId);
  }

  /// Returns the last known result for a query identified by its canonical
  /// udf path and arguments, even after the query has been unsubscribed.
  StoredQueryResult? cachedResultForQuery(
    String udfPath,
    Map<String, dynamic> args,
  ) {
    final token = LocalSyncState.serializeQueryToken(
      LocalSyncState.canonicalizeUdfPath(udfPath),
      args,
    );
    return _resultCacheByToken[token];
  }

  List<int> subscriberIdsForQuery(int queryId) {
    return _localState.subscriberIdsForQuery(queryId);
  }

  int? queryIdForSubscriber(int subscriberId) {
    return _localState.queryIdForSubscriber(subscriberId);
  }

  List<ClientMessage> drainOutgoing({bool assumeSent = true}) {
    final messages = List<ClientMessage>.from(_outgoing);
    _outgoing.clear();
    if (assumeSent) {
      _requestManager.markSent(messages);
    }
    return messages;
  }

  void markMessagesSent(Iterable<ClientMessage> messages) {
    _requestManager.markSent(messages);
  }

  void requeueOutgoing(Iterable<ClientMessage> messages) {
    final queuedMessages = messages.toList(growable: false);
    for (final message in queuedMessages.reversed) {
      _outgoing.addFirst(message);
    }
  }

  BaseClientReceiveResult receive(ServerMessage message) {
    final events = <BaseClientEvent>[];
    switch (message) {
      case Transition():
        try {
          final deltas = _remoteQuerySet.applyTransition(message);
          _localState.observeTimestamp(message.endVersion.ts);
          for (final modification in message.modifications) {
            switch (modification) {
              case QueryUpdated():
                _localState.updateJournal(
                  modification.queryId,
                  modification.journal,
                );
              case QueryFailed():
                _localState.updateJournal(
                  modification.queryId,
                  modification.journal,
                );
              case QueryRemoved():
            }
          }
          _requestManager.resolveMutationsUpTo(message.endVersion.ts);
          for (final delta in deltas) {
            if (delta.removed) {
              events.add(QueryRemovedEvent(queryId: delta.queryId));
            } else if (delta.result != null) {
              final token = _localState.tokenForQueryId(delta.queryId);
              if (token != null) {
                _resultCacheByToken[token] = delta.result!;
              }
              events.add(
                QueryUpdateEvent(queryId: delta.queryId, result: delta.result!),
              );
            }
          }
          if (message.endVersion.identity > message.startVersion.identity) {
            events.add(
              AuthConfirmedEvent(isAuthenticated: _localState.hasAuth),
            );
          }
        } on StateError catch (error) {
          events.add(ReconnectRequiredEvent(reason: '$error'));
        }
      case MutationResponse():
        if (message.success && message.ts != null) {
          _localState.observeTimestamp(message.ts!);
        }
        _requestManager.handleMutationResponse(message);
      case ActionResponse():
        _requestManager.handleActionResponse(message);
      case Ping():
        _outgoing.add(const Event(eventType: 'Pong', event: null));
      case AuthError():
        events.add(AuthErrorEvent(error: message));
      case FatalError():
        events.add(ReconnectRequiredEvent(reason: message.error));
      case TransitionChunk():
        events.add(
          const ReconnectRequiredEvent(
            reason: 'Unexpected TransitionChunk reached sync layer',
          ),
        );
    }

    final outgoing = List<ClientMessage>.from(_outgoing);
    _outgoing.clear();
    return BaseClientReceiveResult(events: events, outgoing: outgoing);
  }
}
