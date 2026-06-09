// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: type=lint, unused_element, unused_import, unused_local_variable

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class KvApi {
  const KvApi(this._client);

  final ConvexFunctionCaller _client;

  Future<Null> link({
    Optional<UsersId?> target = const Optional.absent(),
    Optional<List<String>?> tags = const Optional.absent(),
  }) async {
    await _client.mutate(
      'kv:link',
      _encodeLinkArgs((target: target, tags: tags)),
    );
    return null;
  }

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

typedef LinkArgs = ({Optional<UsersId?> target, Optional<List<String>?> tags});

Map<String, dynamic> _encodeLinkArgs(LinkArgs value$) {
  final (target: target, tags: tags) = value$;
  return <String, dynamic>{
    if (target.isDefined)
      'target': switch (target.value) {
        null => null,
        final v$ => v$.value,
      },
    if (tags.isDefined)
      'tags': switch (tags.value) {
        null => null,
        final v$ => v$.map((item) => item).toList(),
      },
  };
}

LinkArgs _decodeLinkArgs(dynamic raw) {
  final map = expectMap(raw, label: 'LinkArgs');
  return (
    target: map.containsKey('target')
        ? Optional.of(
            map['target'] == null
                ? null
                : UsersId(expectString(map['target'], label: 'LinkArgsTarget')),
          )
        : const Optional.absent(),
    tags: map.containsKey('tags')
        ? Optional.of(
            map['tags'] == null
                ? null
                : expectList(map['tags'], label: 'LinkArgsTags')
                      .map(
                        (item) => expectString(item, label: 'LinkArgsTagsItem'),
                      )
                      .toList(),
          )
        : const Optional.absent(),
  );
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
