// GENERATED CODE - DO NOT MODIFY BY HAND.
// ignore_for_file: type=lint, unused_element, unused_import, unused_local_variable

import '../../runtime.dart';
import '../../schema.dart';
import 'package:dartvex/dartvex.dart';

class AdminUsersApi {
  const AdminUsersApi(this._client);

  final ConvexFunctionCaller _client;

  Future<DiagnoseResult> diagnose({required DiagnoseArgsLevel level}) async {
    final raw$ = await _client.query(
      'admin/users:diagnose',
      _encodeDiagnoseArgs((level: level)),
    );
    return _decodeDiagnoseResult(raw$);
  }

  TypedConvexSubscription<DiagnoseResult> diagnoseSubscribe({
    required DiagnoseArgsLevel level,
  }) {
    final subscription$ = _client.subscribe(
      'admin/users:diagnose',
      _encodeDiagnoseArgs((level: level)),
    );
    final typedStream$ = subscription$.stream.map((event) {
      switch (event) {
        case QuerySuccess(:final value):
          return TypedQuerySuccess<DiagnoseResult>(
            _decodeDiagnoseResult(value),
          );
        case QueryLoading(:final hasPendingWrites):
          return TypedQueryLoading<DiagnoseResult>(
            hasPendingWrites: hasPendingWrites,
          );
        case QueryError(:final message, :final data, :final logLines):
          return TypedQueryError<DiagnoseResult>(
            message,
            data: data,
            logLines: logLines,
          );
      }
    });
    return TypedConvexSubscription<DiagnoseResult>(subscription$, typedStream$);
  }

  Future<SyncTypeResult> syncValue({
    required Map<String, SyncTypeArgsPayloadValue> payload,
    required SyncTypeArgsMode mode,
  }) async {
    final raw$ = await _client.action(
      'admin/users:sync',
      _encodeSyncTypeArgs((payload: payload, mode: mode)),
    );
    return _decodeSyncTypeResult(raw$);
  }
}

typedef DiagnoseResult = ({dynamic future, dynamic bigLiteral});

Map<String, dynamic> _encodeDiagnoseResult(DiagnoseResult value$) {
  final (future: future, bigLiteral: bigLiteral) = value$;
  return <String, dynamic>{'future': future, 'bigLiteral': bigLiteral};
}

DiagnoseResult _decodeDiagnoseResult(dynamic raw) {
  final map = expectMap(raw, label: 'DiagnoseResult');
  if (!map.containsKey('future')) {
    throw FormatException('Missing required field "future" for DiagnoseResult');
  }
  if (!map.containsKey('bigLiteral')) {
    throw FormatException(
      'Missing required field "bigLiteral" for DiagnoseResult',
    );
  }
  return (future: map['future'], bigLiteral: map['bigLiteral']);
}

enum DiagnoseArgsLevel {
  v1Value(1.0),
  v2Value(2.0),
  v3Value(3.0);

  const DiagnoseArgsLevel(this.value);
  final Object? value;

  static DiagnoseArgsLevel fromJson(dynamic raw) {
    switch (raw) {
      case 1.0:
        return DiagnoseArgsLevel.v1Value;
      case 2.0:
        return DiagnoseArgsLevel.v2Value;
      case 3.0:
        return DiagnoseArgsLevel.v3Value;
      default:
        throw FormatException('Expected one of 1, 2, 3 for DiagnoseArgsLevel');
    }
  }
}

typedef DiagnoseArgs = ({DiagnoseArgsLevel level});

Map<String, dynamic> _encodeDiagnoseArgs(DiagnoseArgs value$) {
  final (level: level) = value$;
  return <String, dynamic>{'level': level.value};
}

DiagnoseArgs _decodeDiagnoseArgs(dynamic raw) {
  final map = expectMap(raw, label: 'DiagnoseArgs');
  if (!map.containsKey('level')) {
    throw FormatException('Missing required field "level" for DiagnoseArgs');
  }
  return (level: DiagnoseArgsLevel.fromJson(map['level']));
}

typedef SyncTypeResult = ({bool success, BigInt count});

Map<String, dynamic> _encodeSyncTypeResult(SyncTypeResult value$) {
  final (success: success, count: count) = value$;
  return <String, dynamic>{'success': success, 'count': count};
}

SyncTypeResult _decodeSyncTypeResult(dynamic raw) {
  final map = expectMap(raw, label: 'SyncTypeResult');
  if (!map.containsKey('success')) {
    throw FormatException(
      'Missing required field "success" for SyncTypeResult',
    );
  }
  if (!map.containsKey('count')) {
    throw FormatException('Missing required field "count" for SyncTypeResult');
  }
  return (
    success: expectBool(map['success'], label: 'SyncTypeResultSuccess'),
    count: expectBigInt(map['count'], label: 'SyncTypeResultCount'),
  );
}

sealed class SyncTypeArgsPayloadValue {
  const SyncTypeArgsPayloadValue();
}

class SyncTypeArgsPayloadValue1Value extends SyncTypeArgsPayloadValue {
  const SyncTypeArgsPayloadValue1Value(this.value);
  final double value;
}

class SyncTypeArgsPayloadValue2Value extends SyncTypeArgsPayloadValue {
  const SyncTypeArgsPayloadValue2Value(this.value);
  final String value;
}

dynamic _encodeSyncTypeArgsPayloadValue(SyncTypeArgsPayloadValue value) {
  switch (value) {
    case SyncTypeArgsPayloadValue1Value(value: final inner):
      return inner;
    case SyncTypeArgsPayloadValue2Value(value: final inner):
      return inner;
  }
}

SyncTypeArgsPayloadValue _decodeSyncTypeArgsPayloadValue(dynamic raw) {
  final errors = <String>[];
  try {
    return SyncTypeArgsPayloadValue1Value(
      expectDouble(raw, label: 'SyncTypeArgsPayloadValue1'),
    );
  } catch (e) {
    errors.add('SyncTypeArgsPayloadValue1Value: $e');
  }
  try {
    return SyncTypeArgsPayloadValue2Value(
      expectString(raw, label: 'SyncTypeArgsPayloadValue2'),
    );
  } catch (e) {
    errors.add('SyncTypeArgsPayloadValue2Value: $e');
  }
  throw FormatException(
    'Expected SyncTypeArgsPayloadValue but received ${describeType(raw)}.\n'
    'Tried: ${errors.join(", ")}',
  );
}

enum SyncTypeArgsMode {
  fullValue('full'),
  deltaValue('delta');

  const SyncTypeArgsMode(this.value);
  final Object? value;

  static SyncTypeArgsMode fromJson(dynamic raw) {
    switch (raw) {
      case 'full':
        return SyncTypeArgsMode.fullValue;
      case 'delta':
        return SyncTypeArgsMode.deltaValue;
      default:
        throw FormatException(
          'Expected one of full, delta for SyncTypeArgsMode',
        );
    }
  }
}

typedef SyncTypeArgs = ({
  Map<String, SyncTypeArgsPayloadValue> payload,
  SyncTypeArgsMode mode,
});

Map<String, dynamic> _encodeSyncTypeArgs(SyncTypeArgs value$) {
  final (payload: payload, mode: mode) = value$;
  return <String, dynamic>{
    'payload': payload.map(
      (key, value) => MapEntry(key, _encodeSyncTypeArgsPayloadValue(value)),
    ),
    'mode': mode.value,
  };
}

SyncTypeArgs _decodeSyncTypeArgs(dynamic raw) {
  final map = expectMap(raw, label: 'SyncTypeArgs');
  if (!map.containsKey('payload')) {
    throw FormatException('Missing required field "payload" for SyncTypeArgs');
  }
  if (!map.containsKey('mode')) {
    throw FormatException('Missing required field "mode" for SyncTypeArgs');
  }
  return (
    payload: expectMap(map['payload'], label: 'SyncTypeArgsPayload').map(
      (key, value) => MapEntry(key, _decodeSyncTypeArgsPayloadValue(value)),
    ),
    mode: SyncTypeArgsMode.fromJson(map['mode']),
  );
}
