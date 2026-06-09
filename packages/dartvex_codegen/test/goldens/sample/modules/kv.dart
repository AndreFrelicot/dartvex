// GENERATED CODE - DO NOT MODIFY BY HAND.

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class KvApi {
  const KvApi(this._client);

  final ConvexFunctionCaller _client;

  Future<bool> setValue({
    required String key,
    required String value,
    Optional<bool> raw = const Optional.absent(),
  }) async {
    final raw$ = await _client.mutate(
      'kv:set',
      _encodeSetTypeArgs((key: key, value: value, raw: raw)),
    );
    return expectBool(raw$, label: 'SetTypeResult');
  }

  Future<Null> watch({required String subscription}) async {
    await _client.query(
      'kv:watch',
      _encodeWatchArgs((subscription: subscription)),
    );
    return null;
  }

  TypedConvexSubscription<Null> watchSubscribe({required String subscription}) {
    final subscription$ = _client.subscribe(
      'kv:watch',
      _encodeWatchArgs((subscription: subscription)),
    );
    final typedStream$ = subscription$.stream.map((event) {
      switch (event) {
        case QuerySuccess(:final value):
          return TypedQuerySuccess<Null>(null);
        case QueryLoading(:final hasPendingWrites):
          return TypedQueryLoading<Null>(hasPendingWrites: hasPendingWrites);
        case QueryError(:final message, :final data, :final logLines):
          return TypedQueryError<Null>(message, data: data, logLines: logLines);
      }
    });
    return TypedConvexSubscription<Null>(subscription$, typedStream$);
  }
}

typedef SetTypeArgs = ({String key, String value, Optional<bool> raw});

Map<String, dynamic> _encodeSetTypeArgs(SetTypeArgs value$) {
  final (key: key, value: value, raw: raw) = value$;
  return <String, dynamic>{
    'key': key,
    'value': value,
    if (raw.isDefined) 'raw': raw.value,
  };
}

SetTypeArgs _decodeSetTypeArgs(dynamic raw) {
  final map = expectMap(raw, label: 'SetTypeArgs');
  if (!map.containsKey('key')) {
    throw FormatException('Missing required field "key" for SetTypeArgs');
  }
  if (!map.containsKey('value')) {
    throw FormatException('Missing required field "value" for SetTypeArgs');
  }
  return (
    key: expectString(map['key'], label: 'SetTypeArgsKey'),
    value: expectString(map['value'], label: 'SetTypeArgsValue'),
    raw: map.containsKey('raw')
        ? Optional.of(expectBool(map['raw'], label: 'SetTypeArgsRaw'))
        : const Optional.absent(),
  );
}

typedef WatchArgs = ({String subscription});

Map<String, dynamic> _encodeWatchArgs(WatchArgs value$) {
  final (subscription: subscription) = value$;
  return <String, dynamic>{'subscription': subscription};
}

WatchArgs _decodeWatchArgs(dynamic raw) {
  final map = expectMap(raw, label: 'WatchArgs');
  if (!map.containsKey('subscription')) {
    throw FormatException(
      'Missing required field "subscription" for WatchArgs',
    );
  }
  return (
    subscription: expectString(
      map['subscription'],
      label: 'WatchArgsSubscription',
    ),
  );
}
