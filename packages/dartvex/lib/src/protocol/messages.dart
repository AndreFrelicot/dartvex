import 'state_version.dart';
import '../values/json_codec.dart';

/// Base type for every JSON-serializable Convex websocket protocol message.
sealed class JsonMessage {
  /// Const base constructor for protocol messages.
  const JsonMessage();

  /// Serializes this message to its wire-format JSON map.
  Map<String, dynamic> toJson();
}

/// Base type for messages sent from the client to the Convex sync server.
sealed class ClientMessage extends JsonMessage {
  /// Const base constructor for client messages.
  const ClientMessage();

  /// Deserializes a [ClientMessage] from JSON based on its `type` field.
  factory ClientMessage.fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'Connect':
        return Connect.fromJson(json);
      case 'ModifyQuerySet':
        return ModifyQuerySet.fromJson(json);
      case 'Mutation':
        return Mutation.fromJson(json);
      case 'Action':
        return Action.fromJson(json);
      case 'Authenticate':
        return Authenticate.fromJson(json);
      case 'Event':
        return Event.fromJson(json);
    }
    throw FormatException('Unknown client message type: ${json['type']}', json);
  }
}

/// Base type for messages sent from the Convex sync server to the client.
sealed class ServerMessage extends JsonMessage {
  /// Const base constructor for server messages.
  const ServerMessage();

  /// Deserializes a [ServerMessage] from JSON based on its `type` field.
  factory ServerMessage.fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'Transition':
        return Transition.fromJson(json);
      case 'TransitionChunk':
        return TransitionChunk.fromJson(json);
      case 'MutationResponse':
        return MutationResponse.fromJson(json);
      case 'ActionResponse':
        return ActionResponse.fromJson(json);
      case 'Ping':
        return const Ping();
      case 'AuthError':
        return AuthError.fromJson(json);
      case 'FatalError':
        return FatalError.fromJson(json);
    }
    throw FormatException('Unknown server message type: ${json['type']}', json);
  }
}

/// Base type for a single add/remove operation within a query-set modification.
sealed class QuerySetOperation extends JsonMessage {
  /// Const base constructor for query-set operations.
  const QuerySetOperation();

  /// Deserializes a [QuerySetOperation] from JSON based on its `type` field.
  factory QuerySetOperation.fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'Add':
        return Add.fromJson(json);
      case 'Remove':
        return Remove.fromJson(json);
    }
    throw FormatException(
      'Unknown query set operation type: ${json['type']}',
      json,
    );
  }
}

/// Initial handshake message establishing a new websocket session.
class Connect extends ClientMessage {
  /// Creates a [Connect] handshake message.
  const Connect({
    required this.sessionId,
    required this.connectionCount,
    required this.lastCloseReason,
    this.maxObservedTimestamp,
    this.clientTs = 0,
  });

  /// Stable identifier for the client session across reconnects.
  final String sessionId;

  /// Number of times this session has (re)connected so far.
  final int connectionCount;

  /// Reason the previous connection closed, if any.
  final String? lastCloseReason;

  /// Highest server timestamp the client has observed, used to resume sync.
  final String? maxObservedTimestamp;

  /// Client-side wall-clock timestamp used for clock-skew estimation.
  final int clientTs;

  /// Deserializes a [Connect] from JSON.
  factory Connect.fromJson(Map<String, dynamic> json) {
    return Connect(
      sessionId: json['sessionId'] as String,
      connectionCount: json['connectionCount'] as int,
      lastCloseReason: json['lastCloseReason'] as String?,
      maxObservedTimestamp: json['maxObservedTimestamp'] as String?,
      clientTs: (json['clientTs'] as int?) ?? 0,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'Connect',
      'sessionId': sessionId,
      'connectionCount': connectionCount,
      'lastCloseReason': lastCloseReason,
      'maxObservedTimestamp': maxObservedTimestamp,
      'clientTs': clientTs,
    };
  }
}

/// Request to add and/or remove queries from the active query set.
class ModifyQuerySet extends ClientMessage {
  /// Creates a [ModifyQuerySet] request.
  const ModifyQuerySet({
    required this.baseVersion,
    required this.newVersion,
    required this.modifications,
  });

  /// Query-set version this modification is applied on top of.
  final int baseVersion;

  /// Resulting query-set version after applying [modifications].
  final int newVersion;

  /// Ordered list of add/remove operations to apply to the query set.
  final List<QuerySetOperation> modifications;

  /// Deserializes a [ModifyQuerySet] from JSON.
  factory ModifyQuerySet.fromJson(Map<String, dynamic> json) {
    return ModifyQuerySet(
      baseVersion: json['baseVersion'] as int,
      newVersion: json['newVersion'] as int,
      modifications: (json['modifications'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map(QuerySetOperation.fromJson)
          .toList(),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'ModifyQuerySet',
      'baseVersion': baseVersion,
      'newVersion': newVersion,
      'modifications': modifications.map((op) => op.toJson()).toList(),
    };
  }
}

/// Query-set operation that subscribes to a new query.
class Add extends QuerySetOperation {
  /// Creates an [Add] query subscription operation.
  const Add({
    required this.queryId,
    required this.udfPath,
    required this.args,
    this.journal,
    this.componentPath,
  });

  /// Client-assigned identifier for the subscribed query.
  final int queryId;

  /// Path of the query UDF to subscribe to.
  final String udfPath;

  /// Convex-encoded argument values passed to the query.
  final List<dynamic> args;

  /// Optional journal cursor used to resume paginated query state.
  final String? journal;

  /// Optional component path for queries hosted in a component.
  final String? componentPath;

  /// Deserializes an [Add] from JSON.
  factory Add.fromJson(Map<String, dynamic> json) {
    return Add(
      queryId: json['queryId'] as int,
      udfPath: json['udfPath'] as String,
      args: (json['args'] as List<dynamic>)
          .map(jsonToConvex)
          .toList(growable: false),
      journal: json['journal'] as String?,
      componentPath: json['componentPath'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'Add',
      'queryId': queryId,
      'udfPath': udfPath,
      'args': args.map(convexToJson).toList(growable: false),
      'journal': journal,
      if (componentPath != null) 'componentPath': componentPath,
    };
  }
}

/// Query-set operation that unsubscribes from an existing query.
class Remove extends QuerySetOperation {
  /// Creates a [Remove] unsubscribe operation.
  const Remove({required this.queryId});

  /// Identifier of the query to unsubscribe from.
  final int queryId;

  /// Deserializes a [Remove] from JSON.
  factory Remove.fromJson(Map<String, dynamic> json) {
    return Remove(queryId: json['queryId'] as int);
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'type': 'Remove', 'queryId': queryId};
  }
}

/// Base type for client requests that invoke a UDF and expect a response.
abstract class RequestMessage extends ClientMessage {
  /// Const base constructor for request messages.
  const RequestMessage({
    required this.requestId,
    required this.udfPath,
    required this.args,
    this.componentPath,
  });

  /// Client-assigned identifier used to correlate the response.
  final int requestId;

  /// Path of the UDF to invoke.
  final String udfPath;

  /// Convex-encoded argument values passed to the UDF.
  final List<dynamic> args;

  /// Optional component path for UDFs hosted in a component.
  final String? componentPath;
}

/// Client request that runs a mutation UDF.
class Mutation extends RequestMessage {
  /// Creates a [Mutation] request.
  const Mutation({
    required super.requestId,
    required super.udfPath,
    required super.args,
    super.componentPath,
  });

  /// Deserializes a [Mutation] from JSON.
  factory Mutation.fromJson(Map<String, dynamic> json) {
    return Mutation(
      requestId: json['requestId'] as int,
      udfPath: json['udfPath'] as String,
      args: (json['args'] as List<dynamic>)
          .map(jsonToConvex)
          .toList(growable: false),
      componentPath: json['componentPath'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'Mutation',
      'requestId': requestId,
      'udfPath': udfPath,
      'args': args.map(convexToJson).toList(growable: false),
      if (componentPath != null) 'componentPath': componentPath,
    };
  }
}

/// Client request that runs an action UDF.
class Action extends RequestMessage {
  /// Creates an [Action] request.
  const Action({
    required super.requestId,
    required super.udfPath,
    required super.args,
    super.componentPath,
  });

  /// Deserializes an [Action] from JSON.
  factory Action.fromJson(Map<String, dynamic> json) {
    return Action(
      requestId: json['requestId'] as int,
      udfPath: json['udfPath'] as String,
      args: (json['args'] as List<dynamic>)
          .map(jsonToConvex)
          .toList(growable: false),
      componentPath: json['componentPath'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'Action',
      'requestId': requestId,
      'udfPath': udfPath,
      'args': args.map(convexToJson).toList(growable: false),
      if (componentPath != null) 'componentPath': componentPath,
    };
  }
}

/// Client request that updates the authentication token for the session.
class Authenticate extends ClientMessage {
  /// Creates an [Authenticate] request.
  const Authenticate({
    required this.tokenType,
    required this.baseVersion,
    this.value,
    this.impersonating,
  });

  /// Kind of auth token being supplied (for example `User`).
  final String tokenType;

  /// Identity version this authentication update is applied on top of.
  final int baseVersion;

  /// The auth token value, or null to clear authentication.
  final String? value;

  /// Optional admin impersonation payload.
  final Map<String, dynamic>? impersonating;

  /// Deserializes an [Authenticate] from JSON.
  factory Authenticate.fromJson(Map<String, dynamic> json) {
    final impersonating = json['impersonating'];
    return Authenticate(
      tokenType: json['tokenType'] as String,
      baseVersion: json['baseVersion'] as int,
      value: json['value'] as String?,
      impersonating:
          impersonating is Map ? impersonating.cast<String, dynamic>() : null,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'Authenticate',
      'tokenType': tokenType,
      'baseVersion': baseVersion,
      if (value != null) 'value': value,
      if (impersonating != null) 'impersonating': impersonating,
    };
  }
}

/// Client message reporting a named analytics/diagnostic event.
class Event extends ClientMessage {
  /// Creates an [Event] message.
  const Event({required this.eventType, this.event});

  /// Name identifying the kind of event.
  final String eventType;

  /// Optional Convex-encoded payload carried with the event.
  final Object? event;

  /// Deserializes an [Event] from JSON.
  factory Event.fromJson(Map<String, dynamic> json) {
    return Event(
      eventType: json['eventType'] as String,
      event: json.containsKey('event') ? jsonToConvex(json['event']) : null,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'Event',
      'eventType': eventType,
      'event': convexToJson(event),
    };
  }
}

/// Base type for a per-query change carried inside a [Transition].
sealed class StateModification extends JsonMessage {
  /// Const base constructor for state modifications.
  const StateModification();

  /// Identifier of the query this modification applies to.
  int get queryId;

  /// Deserializes a [StateModification] from JSON based on its `type` field.
  factory StateModification.fromJson(Map<String, dynamic> json) {
    switch (json['type']) {
      case 'QueryUpdated':
        return QueryUpdated.fromJson(json);
      case 'QueryFailed':
        return QueryFailed.fromJson(json);
      case 'QueryRemoved':
        return QueryRemoved.fromJson(json);
    }
    throw FormatException(
      'Unknown state modification type: ${json['type']}',
      json,
    );
  }
}

/// State modification reporting a query's new successful result.
class QueryUpdated extends StateModification {
  /// Creates a [QueryUpdated] modification.
  const QueryUpdated({
    required this.queryId,
    required this.value,
    this.logLines = const <String>[],
    this.journal,
  });

  @override
  final int queryId;

  /// Convex-encoded new result value for the query.
  final Object? value;

  /// Log lines emitted while computing the query result.
  final List<String> logLines;

  /// Updated journal cursor for paginated query state, if any.
  final String? journal;

  /// Deserializes a [QueryUpdated] from JSON.
  factory QueryUpdated.fromJson(Map<String, dynamic> json) {
    return QueryUpdated(
      queryId: json['queryId'] as int,
      value: jsonToConvex(json['value']),
      logLines: (json['logLines'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
      journal: json['journal'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'QueryUpdated',
      'queryId': queryId,
      'value': convexToJson(value),
      'logLines': logLines,
      'journal': journal,
    };
  }
}

/// State modification reporting that a query threw an error.
class QueryFailed extends StateModification {
  /// Creates a [QueryFailed] modification.
  const QueryFailed({
    required this.queryId,
    required this.errorMessage,
    this.errorData,
    this.logLines = const <String>[],
    this.journal,
  });

  @override
  final int queryId;

  /// Human-readable error message describing the failure.
  final String errorMessage;

  /// Optional Convex-encoded structured error payload.
  final Object? errorData;

  /// Log lines emitted before the query failed.
  final List<String> logLines;

  /// Updated journal cursor for paginated query state, if any.
  final String? journal;

  /// Deserializes a [QueryFailed] from JSON.
  factory QueryFailed.fromJson(Map<String, dynamic> json) {
    return QueryFailed(
      queryId: json['queryId'] as int,
      errorMessage: json['errorMessage'] as String,
      errorData: json.containsKey('errorData')
          ? jsonToConvex(json['errorData'])
          : null,
      logLines: (json['logLines'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
      journal: json['journal'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'QueryFailed',
      'queryId': queryId,
      'errorMessage': errorMessage,
      'errorData': convexToJson(errorData),
      'logLines': logLines,
      'journal': journal,
    };
  }
}

/// State modification reporting that a query was removed from the query set.
class QueryRemoved extends StateModification {
  /// Creates a [QueryRemoved] modification.
  const QueryRemoved({required this.queryId});

  @override
  final int queryId;

  /// Deserializes a [QueryRemoved] from JSON.
  factory QueryRemoved.fromJson(Map<String, dynamic> json) {
    return QueryRemoved(queryId: json['queryId'] as int);
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'type': 'QueryRemoved', 'queryId': queryId};
  }
}

/// Server message advancing local sync state from one version to the next.
class Transition extends ServerMessage {
  /// Creates a [Transition] message.
  const Transition({
    required this.startVersion,
    required this.endVersion,
    required this.modifications,
    this.clientClockSkew,
    this.serverTs,
  });

  /// Version the client must currently be at to apply this transition.
  final StateVersion startVersion;

  /// Version the client reaches after applying this transition.
  final StateVersion endVersion;

  /// Per-query modifications to apply during this transition.
  final List<StateModification> modifications;

  /// Estimated clock skew between client and server, in milliseconds.
  final double? clientClockSkew;

  /// Server wall-clock timestamp at which this transition was produced.
  final double? serverTs;

  /// Deserializes a [Transition] from JSON.
  factory Transition.fromJson(Map<String, dynamic> json) {
    return Transition(
      startVersion: StateVersion.fromJson(
        (json['startVersion'] as Map<dynamic, dynamic>).cast<String, dynamic>(),
      ),
      endVersion: StateVersion.fromJson(
        (json['endVersion'] as Map<dynamic, dynamic>).cast<String, dynamic>(),
      ),
      modifications: (json['modifications'] as List<dynamic>)
          .map(
            (item) => StateModification.fromJson(
              (item as Map).cast<String, dynamic>(),
            ),
          )
          .toList(),
      clientClockSkew: (json['clientClockSkew'] as num?)?.toDouble(),
      serverTs: (json['serverTs'] as num?)?.toDouble(),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'Transition',
      'startVersion': startVersion.toJson(),
      'endVersion': endVersion.toJson(),
      'modifications': modifications.map((item) => item.toJson()).toList(),
      if (clientClockSkew != null) 'clientClockSkew': clientClockSkew,
      if (serverTs != null) 'serverTs': serverTs,
    };
  }
}

/// One fragment of a large [Transition] split across multiple websocket frames.
class TransitionChunk extends ServerMessage {
  /// Creates a [TransitionChunk] message.
  const TransitionChunk({
    required this.chunk,
    required this.partNumber,
    required this.totalParts,
    required this.transitionId,
  });

  /// Encoded fragment of the serialized transition payload.
  final String chunk;

  /// Zero-based index of this fragment within the full transition.
  final int partNumber;

  /// Total number of fragments that make up the transition.
  final int totalParts;

  /// Identifier grouping all fragments of the same transition.
  final String transitionId;

  /// Deserializes a [TransitionChunk] from JSON.
  factory TransitionChunk.fromJson(Map<String, dynamic> json) {
    return TransitionChunk(
      chunk: json['chunk'] as String,
      partNumber: json['partNumber'] as int,
      totalParts: json['totalParts'] as int,
      transitionId: json['transitionId'] as String,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'TransitionChunk',
      'chunk': chunk,
      'partNumber': partNumber,
      'totalParts': totalParts,
      'transitionId': transitionId,
    };
  }
}

/// Base type for server responses to a mutation or action request.
sealed class ResponseMessage extends ServerMessage {
  /// Const base constructor for response messages.
  const ResponseMessage({
    required this.requestId,
    required this.success,
    this.result,
    this.errorMessage,
    this.errorData,
    this.logLines = const <String>[],
  });

  /// Identifier correlating this response with its originating request.
  final int requestId;

  /// Whether the request completed successfully.
  final bool success;

  /// Convex-encoded result value when the request succeeded.
  final Object? result;

  /// Human-readable error message when the request failed.
  final String? errorMessage;

  /// Optional Convex-encoded structured error payload.
  final Object? errorData;

  /// Log lines emitted while handling the request.
  final List<String> logLines;
}

/// Server response to a [Mutation] request.
class MutationResponse extends ResponseMessage {
  /// Creates a [MutationResponse].
  const MutationResponse({
    required super.requestId,
    required super.success,
    super.result,
    super.errorMessage,
    super.errorData,
    super.logLines,
    this.ts,
  });

  /// Server timestamp at which the mutation committed, if successful.
  final String? ts;

  /// Deserializes a [MutationResponse] from JSON.
  factory MutationResponse.fromJson(Map<String, dynamic> json) {
    final success = json['success'] as bool;
    return MutationResponse(
      requestId: json['requestId'] as int,
      success: success,
      result: success && json.containsKey('result')
          ? jsonToConvex(json['result'])
          : null,
      errorMessage: success ? null : _readErrorMessage(json),
      errorData: json.containsKey('errorData')
          ? jsonToConvex(json['errorData'])
          : null,
      logLines: (json['logLines'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
      ts: json['ts'] as String?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'MutationResponse',
      'requestId': requestId,
      'success': success,
      'result': success ? convexToJson(result) : errorMessage,
      if (ts != null) 'ts': ts,
      if (errorData != null) 'errorData': convexToJson(errorData),
      'logLines': logLines,
    };
  }
}

/// Server response to an [Action] request.
class ActionResponse extends ResponseMessage {
  /// Creates an [ActionResponse].
  const ActionResponse({
    required super.requestId,
    required super.success,
    super.result,
    super.errorMessage,
    super.errorData,
    super.logLines,
  });

  /// Deserializes an [ActionResponse] from JSON.
  factory ActionResponse.fromJson(Map<String, dynamic> json) {
    final success = json['success'] as bool;
    return ActionResponse(
      requestId: json['requestId'] as int,
      success: success,
      result: success && json.containsKey('result')
          ? jsonToConvex(json['result'])
          : null,
      errorMessage: success ? null : _readErrorMessage(json),
      errorData: json.containsKey('errorData')
          ? jsonToConvex(json['errorData'])
          : null,
      logLines: (json['logLines'] as List<dynamic>? ?? const <dynamic>[])
          .cast<String>(),
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'ActionResponse',
      'requestId': requestId,
      'success': success,
      'result': success ? convexToJson(result) : errorMessage,
      if (errorData != null) 'errorData': convexToJson(errorData),
      'logLines': logLines,
    };
  }
}

String? _readErrorMessage(Map<String, dynamic> json) {
  final errorMessage = json['errorMessage'];
  if (errorMessage is String) {
    return errorMessage;
  }
  final result = json['result'];
  if (result is String) {
    return result;
  }
  return null;
}

/// Server keep-alive message that requires no client action.
class Ping extends ServerMessage {
  /// Creates a [Ping] message.
  const Ping();

  @override
  Map<String, dynamic> toJson() => const <String, dynamic>{'type': 'Ping'};
}

/// Server message reporting that authentication failed or was rejected.
class AuthError extends ServerMessage {
  /// Creates an [AuthError] message.
  const AuthError({
    required this.error,
    required this.baseVersion,
    this.authUpdateAttempted,
  });

  /// Human-readable description of the authentication error.
  final String error;

  /// Identity version associated with the rejected authentication.
  final int baseVersion;

  /// Whether the server attempted to apply an auth update before failing.
  final bool? authUpdateAttempted;

  /// Deserializes an [AuthError] from JSON.
  factory AuthError.fromJson(Map<String, dynamic> json) {
    return AuthError(
      error: json['error'] as String,
      baseVersion: json['baseVersion'] as int,
      authUpdateAttempted: json['authUpdateAttempted'] as bool?,
    );
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'type': 'AuthError',
      'error': error,
      'baseVersion': baseVersion,
      if (authUpdateAttempted != null)
        'authUpdateAttempted': authUpdateAttempted,
    };
  }
}

/// Server message reporting an unrecoverable error that ends the connection.
class FatalError extends ServerMessage {
  /// Creates a [FatalError] message.
  const FatalError({required this.error});

  /// Human-readable description of the fatal error.
  final String error;

  /// Deserializes a [FatalError] from JSON.
  factory FatalError.fromJson(Map<String, dynamic> json) {
    return FatalError(error: json['error'] as String);
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'type': 'FatalError', 'error': error};
  }
}
