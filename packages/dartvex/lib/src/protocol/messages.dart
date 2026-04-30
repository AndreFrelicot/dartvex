import 'state_version.dart';
import '../values/json_codec.dart';

sealed class JsonMessage {
  const JsonMessage();

  Map<String, dynamic> toJson();
}

sealed class ClientMessage extends JsonMessage {
  const ClientMessage();

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

sealed class ServerMessage extends JsonMessage {
  const ServerMessage();

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

sealed class QuerySetOperation extends JsonMessage {
  const QuerySetOperation();

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

class Connect extends ClientMessage {
  const Connect({
    required this.sessionId,
    required this.connectionCount,
    required this.lastCloseReason,
    this.maxObservedTimestamp,
    this.clientTs = 0,
  });

  final String sessionId;
  final int connectionCount;
  final String? lastCloseReason;
  final String? maxObservedTimestamp;
  final int clientTs;

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

class ModifyQuerySet extends ClientMessage {
  const ModifyQuerySet({
    required this.baseVersion,
    required this.newVersion,
    required this.modifications,
  });

  final int baseVersion;
  final int newVersion;
  final List<QuerySetOperation> modifications;

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

class Add extends QuerySetOperation {
  const Add({
    required this.queryId,
    required this.udfPath,
    required this.args,
    this.journal,
    this.componentPath,
  });

  final int queryId;
  final String udfPath;
  final List<dynamic> args;
  final String? journal;
  final String? componentPath;

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

class Remove extends QuerySetOperation {
  const Remove({required this.queryId});

  final int queryId;

  factory Remove.fromJson(Map<String, dynamic> json) {
    return Remove(queryId: json['queryId'] as int);
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'type': 'Remove', 'queryId': queryId};
  }
}

abstract class RequestMessage extends ClientMessage {
  const RequestMessage({
    required this.requestId,
    required this.udfPath,
    required this.args,
    this.componentPath,
  });

  final int requestId;
  final String udfPath;
  final List<dynamic> args;
  final String? componentPath;
}

class Mutation extends RequestMessage {
  const Mutation({
    required super.requestId,
    required super.udfPath,
    required super.args,
    super.componentPath,
  });

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

class Action extends RequestMessage {
  const Action({
    required super.requestId,
    required super.udfPath,
    required super.args,
    super.componentPath,
  });

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

class Authenticate extends ClientMessage {
  const Authenticate({
    required this.tokenType,
    required this.baseVersion,
    this.value,
    this.impersonating,
  });

  final String tokenType;
  final int baseVersion;
  final String? value;
  final Map<String, dynamic>? impersonating;

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

class Event extends ClientMessage {
  const Event({required this.eventType, this.event});

  final String eventType;
  final Object? event;

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

sealed class StateModification extends JsonMessage {
  const StateModification();

  int get queryId;

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

class QueryUpdated extends StateModification {
  const QueryUpdated({
    required this.queryId,
    required this.value,
    this.logLines = const <String>[],
    this.journal,
  });

  @override
  final int queryId;
  final Object? value;
  final List<String> logLines;
  final String? journal;

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

class QueryFailed extends StateModification {
  const QueryFailed({
    required this.queryId,
    required this.errorMessage,
    this.errorData,
    this.logLines = const <String>[],
    this.journal,
  });

  @override
  final int queryId;
  final String errorMessage;
  final Object? errorData;
  final List<String> logLines;
  final String? journal;

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

class QueryRemoved extends StateModification {
  const QueryRemoved({required this.queryId});

  @override
  final int queryId;

  factory QueryRemoved.fromJson(Map<String, dynamic> json) {
    return QueryRemoved(queryId: json['queryId'] as int);
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'type': 'QueryRemoved', 'queryId': queryId};
  }
}

class Transition extends ServerMessage {
  const Transition({
    required this.startVersion,
    required this.endVersion,
    required this.modifications,
    this.clientClockSkew,
    this.serverTs,
  });

  final StateVersion startVersion;
  final StateVersion endVersion;
  final List<StateModification> modifications;
  final double? clientClockSkew;
  final double? serverTs;

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

class TransitionChunk extends ServerMessage {
  const TransitionChunk({
    required this.chunk,
    required this.partNumber,
    required this.totalParts,
    required this.transitionId,
  });

  final String chunk;
  final int partNumber;
  final int totalParts;
  final String transitionId;

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

sealed class ResponseMessage extends ServerMessage {
  const ResponseMessage({
    required this.requestId,
    required this.success,
    this.result,
    this.errorMessage,
    this.errorData,
    this.logLines = const <String>[],
  });

  final int requestId;
  final bool success;
  final Object? result;
  final String? errorMessage;
  final Object? errorData;
  final List<String> logLines;
}

class MutationResponse extends ResponseMessage {
  const MutationResponse({
    required super.requestId,
    required super.success,
    super.result,
    super.errorMessage,
    super.errorData,
    super.logLines,
    this.ts,
  });

  final String? ts;

  factory MutationResponse.fromJson(Map<String, dynamic> json) {
    final success = json['success'] as bool;
    return MutationResponse(
      requestId: json['requestId'] as int,
      success: success,
      result: success && json.containsKey('result')
          ? jsonToConvex(json['result'])
          : null,
      errorMessage: success
          ? null
          : (json['errorMessage'] as String? ?? json['result'] as String?),
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

class ActionResponse extends ResponseMessage {
  const ActionResponse({
    required super.requestId,
    required super.success,
    super.result,
    super.errorMessage,
    super.errorData,
    super.logLines,
  });

  factory ActionResponse.fromJson(Map<String, dynamic> json) {
    final success = json['success'] as bool;
    return ActionResponse(
      requestId: json['requestId'] as int,
      success: success,
      result: success && json.containsKey('result')
          ? jsonToConvex(json['result'])
          : null,
      errorMessage: success
          ? null
          : (json['errorMessage'] as String? ?? json['result'] as String?),
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

class Ping extends ServerMessage {
  const Ping();

  @override
  Map<String, dynamic> toJson() => const <String, dynamic>{'type': 'Ping'};
}

class AuthError extends ServerMessage {
  const AuthError({
    required this.error,
    required this.baseVersion,
    this.authUpdateAttempted,
  });

  final String error;
  final int baseVersion;
  final bool? authUpdateAttempted;

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

class FatalError extends ServerMessage {
  const FatalError({required this.error});

  final String error;

  factory FatalError.fromJson(Map<String, dynamic> json) {
    return FatalError(error: json['error'] as String);
  }

  @override
  Map<String, dynamic> toJson() {
    return <String, dynamic>{'type': 'FatalError', 'error': error};
  }
}
