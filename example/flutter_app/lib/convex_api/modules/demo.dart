// GENERATED CODE - DO NOT MODIFY BY HAND.

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class DemoApi {
  const DemoApi(this._client);

  final ConvexFunctionCaller _client;

  Future<PingActionResult> pingAction({required String message}) async {
    final raw = await _client.action(
      'demo:pingAction',
      _encodePingActionArgs((message: message)),
    );
    return _decodePingActionResult(raw);
  }

  Future<RequireAuthEchoResult> requireAuthEcho({
    required String message,
  }) async {
    final raw = await _client.query(
      'demo:requireAuthEcho',
      _encodeRequireAuthEchoArgs((message: message)),
    );
    return _decodeRequireAuthEchoResult(raw);
  }

  TypedConvexSubscription<RequireAuthEchoResult> requireAuthEchoSubscribe({
    required String message,
  }) {
    final subscription = _client.subscribe(
      'demo:requireAuthEcho',
      _encodeRequireAuthEchoArgs((message: message)),
    );
    final typedStream = subscription.stream.map(
      (event) => switch (event) {
        QuerySuccess(:final value) => TypedQuerySuccess<RequireAuthEchoResult>(
          _decodeRequireAuthEchoResult(value),
        ),
        QueryError(:final message) => TypedQueryError<RequireAuthEchoResult>(
          message,
        ),
      },
    );
    return TypedConvexSubscription<RequireAuthEchoResult>(
      subscription,
      typedStream,
    );
  }

  Future<WhoAmIResult?> whoAmI() async {
    final raw = await _client.query('demo:whoAmI', const <String, dynamic>{});
    return raw == null ? null : _decodeWhoAmIResult(raw);
  }

  TypedConvexSubscription<WhoAmIResult?> whoAmISubscribe() {
    final subscription = _client.subscribe(
      'demo:whoAmI',
      const <String, dynamic>{},
    );
    final typedStream = subscription.stream.map(
      (event) => switch (event) {
        QuerySuccess(:final value) => TypedQuerySuccess<WhoAmIResult?>(
          value == null ? null : _decodeWhoAmIResult(value),
        ),
        QueryError(:final message) => TypedQueryError<WhoAmIResult?>(message),
      },
    );
    return TypedConvexSubscription<WhoAmIResult?>(subscription, typedStream);
  }
}

typedef PingActionResult = ({
  String echoedText,
  bool isAuthenticated,
  double receivedAt,
  String? viewerName,
});

Map<String, dynamic> _encodePingActionResult(PingActionResult value) {
  final (
    echoedText: echoedText,
    isAuthenticated: isAuthenticated,
    receivedAt: receivedAt,
    viewerName: viewerName,
  ) = value;
  return <String, dynamic>{
    'echoedText': echoedText,
    'isAuthenticated': isAuthenticated,
    'receivedAt': receivedAt,
    'viewerName': viewerName == null ? null : viewerName,
  };
}

PingActionResult _decodePingActionResult(dynamic raw) {
  final map = expectMap(raw, label: 'PingActionResult');
  return (
    echoedText: expectString(
      map['echoedText'],
      label: 'PingActionResultEchoedText',
    ),
    isAuthenticated: expectBool(
      map['isAuthenticated'],
      label: 'PingActionResultIsAuthenticated',
    ),
    receivedAt: expectDouble(
      map['receivedAt'],
      label: 'PingActionResultReceivedAt',
    ),
    viewerName: map['viewerName'] == null
        ? null
        : expectString(map['viewerName'], label: 'PingActionResultViewerName'),
  );
}

typedef PingActionArgs = ({String message});

Map<String, dynamic> _encodePingActionArgs(PingActionArgs value) {
  final (message: message) = value;
  return <String, dynamic>{'message': message};
}

PingActionArgs _decodePingActionArgs(dynamic raw) {
  final map = expectMap(raw, label: 'PingActionArgs');
  return (
    message: expectString(map['message'], label: 'PingActionArgsMessage'),
  );
}

typedef RequireAuthEchoResult = ({String message, String tokenIdentifier});

Map<String, dynamic> _encodeRequireAuthEchoResult(RequireAuthEchoResult value) {
  final (message: message, tokenIdentifier: tokenIdentifier) = value;
  return <String, dynamic>{
    'message': message,
    'tokenIdentifier': tokenIdentifier,
  };
}

RequireAuthEchoResult _decodeRequireAuthEchoResult(dynamic raw) {
  final map = expectMap(raw, label: 'RequireAuthEchoResult');
  return (
    message: expectString(
      map['message'],
      label: 'RequireAuthEchoResultMessage',
    ),
    tokenIdentifier: expectString(
      map['tokenIdentifier'],
      label: 'RequireAuthEchoResultTokenIdentifier',
    ),
  );
}

typedef RequireAuthEchoArgs = ({String message});

Map<String, dynamic> _encodeRequireAuthEchoArgs(RequireAuthEchoArgs value) {
  final (message: message) = value;
  return <String, dynamic>{'message': message};
}

RequireAuthEchoArgs _decodeRequireAuthEchoArgs(dynamic raw) {
  final map = expectMap(raw, label: 'RequireAuthEchoArgs');
  return (
    message: expectString(map['message'], label: 'RequireAuthEchoArgsMessage'),
  );
}

typedef WhoAmIResult = ({
  String? email,
  String issuer,
  String? name,
  String subject,
  String tokenIdentifier,
});

Map<String, dynamic> _encodeWhoAmIResult(WhoAmIResult value) {
  final (
    email: email,
    issuer: issuer,
    name: name,
    subject: subject,
    tokenIdentifier: tokenIdentifier,
  ) = value;
  return <String, dynamic>{
    'email': email == null ? null : email,
    'issuer': issuer,
    'name': name == null ? null : name,
    'subject': subject,
    'tokenIdentifier': tokenIdentifier,
  };
}

WhoAmIResult _decodeWhoAmIResult(dynamic raw) {
  final map = expectMap(raw, label: 'WhoAmIResult');
  return (
    email: map['email'] == null
        ? null
        : expectString(map['email'], label: 'WhoAmIResultEmail'),
    issuer: expectString(map['issuer'], label: 'WhoAmIResultIssuer'),
    name: map['name'] == null
        ? null
        : expectString(map['name'], label: 'WhoAmIResultName'),
    subject: expectString(map['subject'], label: 'WhoAmIResultSubject'),
    tokenIdentifier: expectString(
      map['tokenIdentifier'],
      label: 'WhoAmIResultTokenIdentifier',
    ),
  );
}
