// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: type=lint, unused_element, unused_import, unused_local_variable

import '../runtime.dart';
import '../schema.dart';
import 'package:dartvex/dartvex.dart';

class EventsApi {
  const EventsApi(this._client);

  final ConvexFunctionCaller _client;

  Future<BigInt> dispatch([
    Map<String, dynamic> args = const <String, dynamic>{},
    OptimisticUpdate? optimisticUpdate,
  ]) async {
    final raw$ = await _client.mutate(
      'events:dispatch',
      args,
      optimisticUpdate,
    );
    return expectBigInt(raw$, label: 'DispatchResult');
  }

  Future<FieldResult> field() async {
    final raw$ = await _client.query('events:field', const <String, dynamic>{});
    return _decodeFieldResult(raw$);
  }

  TypedConvexSubscription<FieldResult> fieldSubscribe() {
    final subscription$ = _client.subscribe(
      'events:field',
      const <String, dynamic>{},
    );
    return TypedConvexSubscription<FieldResult>(
      subscription$,
      subscription$.stream.map(
        (event$) => typedQueryResult<FieldResult>(
          event$,
          (raw$) => _decodeFieldResult(raw$),
          'events:field',
        ),
      ),
    );
  }

  Future<LabelsResult> labels() async {
    final raw$ = await _client.query(
      'events:labels',
      const <String, dynamic>{},
    );
    return _decodeLabelsResult(raw$);
  }

  TypedConvexSubscription<LabelsResult> labelsSubscribe() {
    final subscription$ = _client.subscribe(
      'events:labels',
      const <String, dynamic>{},
    );
    return TypedConvexSubscription<LabelsResult>(
      subscription$,
      subscription$.stream.map(
        (event$) => typedQueryResult<LabelsResult>(
          event$,
          (raw$) => _decodeLabelsResult(raw$),
          'events:labels',
        ),
      ),
    );
  }

  Future<LatestResult> latest({
    required Map<String, double> scores,
    Optional<Map<String, String>> labels = const Optional.absent(),
  }) async {
    final raw$ = await _client.query(
      'events:latest',
      _encodeLatestArgs((scores: scores, labels: labels)),
    );
    return _decodeLatestResult(raw$);
  }

  TypedConvexSubscription<LatestResult> latestSubscribe({
    required Map<String, double> scores,
    Optional<Map<String, String>> labels = const Optional.absent(),
  }) {
    final subscription$ = _client.subscribe(
      'events:latest',
      _encodeLatestArgs((scores: scores, labels: labels)),
    );
    return TypedConvexSubscription<LatestResult>(
      subscription$,
      subscription$.stream.map(
        (event$) => typedQueryResult<LatestResult>(
          event$,
          (raw$) => _decodeLatestResult(raw$),
          'events:latest',
        ),
      ),
    );
  }

  Future<Null> resize({
    required ResizeArgsWidth width,
    Optional<BigInt> at = const Optional.absent(),
    OptimisticUpdate? optimisticUpdate,
  }) async {
    await _client.mutate(
      'events:resize',
      _encodeResizeArgs((width: width, at: at)),
      optimisticUpdate,
    );
    return null;
  }
}

enum FieldResult1Value2 {
  aValue('a'),
  bValue('b');

  const FieldResult1Value2(this.value);
  final Object? value;

  static FieldResult1Value2 fromJson(dynamic raw) {
    switch (raw) {
      case 'a':
        return FieldResult1Value2.aValue;
      case 'b':
        return FieldResult1Value2.bValue;
      default:
        throw FormatException('Expected one of a, b for FieldResult1Value2');
    }
  }
}

typedef FieldResult1 = ({String kind, FieldResult1Value2 value});

Map<String, dynamic> _encodeFieldResult1(FieldResult1 value$) {
  final (kind: kind, value: value) = value$;
  return <String, dynamic>{'kind': kind, 'value': value.value};
}

FieldResult1 _decodeFieldResult1(dynamic raw) {
  final map = expectMap(raw, label: 'FieldResult1');
  if (!map.containsKey('kind')) {
    throw FormatException('Missing required field "kind" for FieldResult1');
  }
  if (!map.containsKey('value')) {
    throw FormatException('Missing required field "value" for FieldResult1');
  }
  return (
    kind: expectLiteral<String>(
      map['kind'],
      'choice',
      label: 'FieldResult1Kind',
    ),
    value: FieldResult1Value2.fromJson(map['value']),
  );
}

typedef FieldResult2 = ({String kind, String value});

Map<String, dynamic> _encodeFieldResult2(FieldResult2 value$) {
  final (kind: kind, value: value) = value$;
  return <String, dynamic>{'kind': kind, 'value': value};
}

FieldResult2 _decodeFieldResult2(dynamic raw) {
  final map = expectMap(raw, label: 'FieldResult2');
  if (!map.containsKey('kind')) {
    throw FormatException('Missing required field "kind" for FieldResult2');
  }
  if (!map.containsKey('value')) {
    throw FormatException('Missing required field "value" for FieldResult2');
  }
  return (
    kind: expectLiteral<String>(map['kind'], 'text', label: 'FieldResult2Kind'),
    value: expectString(map['value'], label: 'FieldResult2Value'),
  );
}

sealed class FieldResult {
  const FieldResult();
}

class FieldResult1Value extends FieldResult {
  const FieldResult1Value(this.value);
  final FieldResult1 value;
}

class FieldResult2Value extends FieldResult {
  const FieldResult2Value(this.value);
  final FieldResult2 value;
}

dynamic _encodeFieldResult(FieldResult value) {
  switch (value) {
    case FieldResult1Value(value: final inner):
      return _encodeFieldResult1(inner);
    case FieldResult2Value(value: final inner):
      return _encodeFieldResult2(inner);
  }
}

FieldResult _decodeFieldResult(dynamic raw) {
  final errors = <String>[];
  try {
    return FieldResult1Value(_decodeFieldResult1(raw));
  } catch (e) {
    errors.add('FieldResult1Value: $e');
  }
  try {
    return FieldResult2Value(_decodeFieldResult2(raw));
  } catch (e) {
    errors.add('FieldResult2Value: $e');
  }
  throw FormatException(
    'Expected FieldResult but received ${describeType(raw)}.\n'
    'Tried: ${errors.join(", ")}',
  );
}

typedef LabelsResult2Value2 = ({double count});

Map<String, dynamic> _encodeLabelsResult2Value2(LabelsResult2Value2 value$) {
  final (count: count) = value$;
  return <String, dynamic>{'count': count};
}

LabelsResult2Value2 _decodeLabelsResult2Value2(dynamic raw) {
  final map = expectMap(raw, label: 'LabelsResult2Value2');
  if (!map.containsKey('count')) {
    throw FormatException(
      'Missing required field "count" for LabelsResult2Value2',
    );
  }
  return (count: expectDouble(map['count'], label: 'LabelsResult2Value2Count'));
}

sealed class LabelsResult {
  const LabelsResult();
}

class LabelsResult1Value extends LabelsResult {
  const LabelsResult1Value(this.value);
  final String value;
}

class LabelsResult2Value extends LabelsResult {
  const LabelsResult2Value(this.value);
  final Map<String, LabelsResult2Value2> value;
}

dynamic _encodeLabelsResult(LabelsResult value) {
  switch (value) {
    case LabelsResult1Value(value: final inner):
      return inner;
    case LabelsResult2Value(value: final inner):
      return inner.map(
        (key, value) => MapEntry(key, _encodeLabelsResult2Value2(value)),
      );
  }
}

LabelsResult _decodeLabelsResult(dynamic raw) {
  final errors = <String>[];
  try {
    return LabelsResult1Value(expectString(raw, label: 'LabelsResult1'));
  } catch (e) {
    errors.add('LabelsResult1Value: $e');
  }
  try {
    return LabelsResult2Value(
      expectMap(
        raw,
        label: 'LabelsResult2',
      ).map((key, value) => MapEntry(key, _decodeLabelsResult2Value2(value))),
    );
  } catch (e) {
    errors.add('LabelsResult2Value: $e');
  }
  throw FormatException(
    'Expected LabelsResult but received ${describeType(raw)}.\n'
    'Tried: ${errors.join(", ")}',
  );
}

typedef LatestResult = ({
  EventsId systemId,
  double systemCreationTime,
  String id,
  double creationTime,
  BigInt ts,
  String callback,
  dynamic payload,
  SystemStorageId fileId,
  StorageId storageId,
  String toStringValue,
});

Map<String, dynamic> _encodeLatestResult(LatestResult value$) {
  final (
    systemId: systemId,
    systemCreationTime: systemCreationTime,
    id: id,
    creationTime: creationTime,
    ts: ts,
    callback: callback,
    payload: payload,
    fileId: fileId,
    storageId: storageId,
    toStringValue: toStringValue,
  ) = value$;
  return <String, dynamic>{
    '_id': systemId.value,
    '_creationTime': systemCreationTime,
    'id': id,
    'creationTime': creationTime,
    'ts': ts,
    'callback': callback,
    'payload': payload,
    'fileId': fileId.value,
    'storageId': storageId.value,
    'toString': toStringValue,
  };
}

LatestResult _decodeLatestResult(dynamic raw) {
  final map = expectMap(raw, label: 'LatestResult');
  if (!map.containsKey('_id')) {
    throw FormatException('Missing required field "_id" for LatestResult');
  }
  if (!map.containsKey('_creationTime')) {
    throw FormatException(
      'Missing required field "_creationTime" for LatestResult',
    );
  }
  if (!map.containsKey('id')) {
    throw FormatException('Missing required field "id" for LatestResult');
  }
  if (!map.containsKey('creationTime')) {
    throw FormatException(
      'Missing required field "creationTime" for LatestResult',
    );
  }
  if (!map.containsKey('ts')) {
    throw FormatException('Missing required field "ts" for LatestResult');
  }
  if (!map.containsKey('callback')) {
    throw FormatException('Missing required field "callback" for LatestResult');
  }
  if (!map.containsKey('payload')) {
    throw FormatException('Missing required field "payload" for LatestResult');
  }
  if (!map.containsKey('fileId')) {
    throw FormatException('Missing required field "fileId" for LatestResult');
  }
  if (!map.containsKey('storageId')) {
    throw FormatException(
      'Missing required field "storageId" for LatestResult',
    );
  }
  if (!map.containsKey('toString')) {
    throw FormatException('Missing required field "toString" for LatestResult');
  }
  return (
    systemId: EventsId(expectString(map['_id'], label: 'LatestResultSystemId')),
    systemCreationTime: expectDouble(
      map['_creationTime'],
      label: 'LatestResultSystemCreationTime',
    ),
    id: expectString(map['id'], label: 'LatestResultId'),
    creationTime: expectDouble(
      map['creationTime'],
      label: 'LatestResultCreationTime',
    ),
    ts: expectBigInt(map['ts'], label: 'LatestResultTs'),
    callback: expectString(map['callback'], label: 'LatestResultCallback'),
    payload: map['payload'],
    fileId: SystemStorageId(
      expectString(map['fileId'], label: 'LatestResultFileId'),
    ),
    storageId: StorageId(
      expectString(map['storageId'], label: 'LatestResultStorageId'),
    ),
    toStringValue: expectString(map['toString'], label: 'LatestResultToString'),
  );
}

typedef LatestArgs = ({
  Map<String, double> scores,
  Optional<Map<String, String>> labels,
});

Map<String, dynamic> _encodeLatestArgs(LatestArgs value$) {
  final (scores: scores, labels: labels) = value$;
  return <String, dynamic>{
    'scores': scores.map((key, value) => MapEntry(key, value)),
    if (labels.isDefined)
      'labels': labels.value.map((key, value) => MapEntry(key, value)),
  };
}

LatestArgs _decodeLatestArgs(dynamic raw) {
  final map = expectMap(raw, label: 'LatestArgs');
  if (!map.containsKey('scores')) {
    throw FormatException('Missing required field "scores" for LatestArgs');
  }
  return (
    scores: expectMap(map['scores'], label: 'LatestArgsScores').map(
      (key, value) =>
          MapEntry(key, expectDouble(value, label: 'LatestArgsScoresValue')),
    ),
    labels: map.containsKey('labels')
        ? Optional.of(
            expectMap(map['labels'], label: 'LatestArgsLabels').map(
              (key, value) => MapEntry(
                key,
                expectString(value, label: 'LatestArgsLabelsValue'),
              ),
            ),
          )
        : const Optional.absent(),
  );
}

sealed class ResizeArgsWidth {
  const ResizeArgsWidth();
}

class ResizeArgsWidth1Value extends ResizeArgsWidth {
  const ResizeArgsWidth1Value(this.value);
  final String value;
}

class ResizeArgsWidth2Value extends ResizeArgsWidth {
  const ResizeArgsWidth2Value(this.value);
  final String value;
}

class ResizeArgsWidth3Value extends ResizeArgsWidth {
  const ResizeArgsWidth3Value(this.value);
  final double value;
}

dynamic _encodeResizeArgsWidth(ResizeArgsWidth value) {
  switch (value) {
    case ResizeArgsWidth1Value(value: final inner):
      return inner;
    case ResizeArgsWidth2Value(value: final inner):
      return inner;
    case ResizeArgsWidth3Value(value: final inner):
      return inner;
  }
}

ResizeArgsWidth _decodeResizeArgsWidth(dynamic raw) {
  final errors = <String>[];
  try {
    return ResizeArgsWidth1Value(
      expectLiteral<String>(raw, 'auto', label: 'ResizeArgsWidth1'),
    );
  } catch (e) {
    errors.add('ResizeArgsWidth1Value: $e');
  }
  try {
    return ResizeArgsWidth2Value(
      expectLiteral<String>(raw, 'none', label: 'ResizeArgsWidth2'),
    );
  } catch (e) {
    errors.add('ResizeArgsWidth2Value: $e');
  }
  try {
    return ResizeArgsWidth3Value(expectDouble(raw, label: 'ResizeArgsWidth3'));
  } catch (e) {
    errors.add('ResizeArgsWidth3Value: $e');
  }
  throw FormatException(
    'Expected ResizeArgsWidth but received ${describeType(raw)}.\n'
    'Tried: ${errors.join(", ")}',
  );
}

typedef ResizeArgs = ({ResizeArgsWidth width, Optional<BigInt> at});

Map<String, dynamic> _encodeResizeArgs(ResizeArgs value$) {
  final (width: width, at: at) = value$;
  return <String, dynamic>{
    'width': _encodeResizeArgsWidth(width),
    if (at.isDefined) 'at': at.value,
  };
}

ResizeArgs _decodeResizeArgs(dynamic raw) {
  final map = expectMap(raw, label: 'ResizeArgs');
  if (!map.containsKey('width')) {
    throw FormatException('Missing required field "width" for ResizeArgs');
  }
  return (
    width: _decodeResizeArgsWidth(map['width']),
    at: map.containsKey('at')
        ? Optional.of(expectBigInt(map['at'], label: 'ResizeArgsAt'))
        : const Optional.absent(),
  );
}
