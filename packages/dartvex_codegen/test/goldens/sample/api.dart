// GENERATED CODE - DO NOT MODIFY BY HAND.

import './modules/admin.dart';
import './modules/kv.dart';
import './modules/messages.dart';
import './runtime.dart';
import './schema.dart';
import 'package:dartvex/dartvex.dart';

export 'runtime.dart';
export 'schema.dart';

class ConvexApi {
  const ConvexApi(this._client);

  final ConvexFunctionCaller _client;

  AdminApi get admin => AdminApi(_client);
  KvApi get kv => KvApi(_client);
  MessagesApi get messages => MessagesApi(_client);

  Future<HealthResult> health() async {
    final raw$ = await _client.query('index:health', const <String, dynamic>{});
    return _decodeHealthResult(raw$);
  }

  TypedConvexSubscription<HealthResult> healthSubscribe() {
    final subscription$ = _client.subscribe(
      'index:health',
      const <String, dynamic>{},
    );
    final typedStream$ = subscription$.stream.map((event) {
      switch (event) {
        case QuerySuccess(:final value):
          return TypedQuerySuccess<HealthResult>(_decodeHealthResult(value));
        case QueryLoading(:final hasPendingWrites):
          return TypedQueryLoading<HealthResult>(
            hasPendingWrites: hasPendingWrites,
          );
        case QueryError(:final message, :final data, :final logLines):
          return TypedQueryError<HealthResult>(
            message,
            data: data,
            logLines: logLines,
          );
      }
    });
    return TypedConvexSubscription<HealthResult>(subscription$, typedStream$);
  }
}

typedef HealthResult = ({bool ok});

Map<String, dynamic> _encodeHealthResult(HealthResult value$) {
  final (ok: ok) = value$;
  return <String, dynamic>{'ok': ok};
}

HealthResult _decodeHealthResult(dynamic raw) {
  final map = expectMap(raw, label: 'HealthResult');
  if (!map.containsKey('ok')) {
    throw FormatException('Missing required field "ok" for HealthResult');
  }
  return (ok: expectBool(map['ok'], label: 'HealthResultOk'));
}
