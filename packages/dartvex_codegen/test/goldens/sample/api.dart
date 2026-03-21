// GENERATED CODE - DO NOT MODIFY BY HAND.

import './modules/admin.dart';
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
  MessagesApi get messages => MessagesApi(_client);

  Future<HealthResult> health() async {
    final raw = await _client.query('index:health', const <String, dynamic>{});
    return _decodeHealthResult(raw);
  }

  TypedConvexSubscription<HealthResult> healthSubscribe() {
    final subscription = _client.subscribe(
      'index:health',
      const <String, dynamic>{},
    );
    final typedStream = subscription.stream.map(
      (event) => switch (event) {
        QuerySuccess(:final value) => TypedQuerySuccess<HealthResult>(
          _decodeHealthResult(value),
        ),
        QueryError(:final message) => TypedQueryError<HealthResult>(message),
      },
    );
    return TypedConvexSubscription<HealthResult>(subscription, typedStream);
  }
}

typedef HealthResult = ({bool ok});

Map<String, dynamic> _encodeHealthResult(HealthResult value) {
  final (ok: ok) = value;
  return <String, dynamic>{'ok': ok};
}

HealthResult _decodeHealthResult(dynamic raw) {
  final map = expectMap(raw, label: 'HealthResult');
  return (ok: expectBool(map['ok'], label: 'HealthResultOk'));
}
