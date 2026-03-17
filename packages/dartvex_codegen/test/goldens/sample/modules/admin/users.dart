// GENERATED CODE - DO NOT MODIFY BY HAND.

import '../../runtime.dart';
import '../../schema.dart';
import 'package:dartvex/dartvex.dart';

class AdminUsersApi {
  const AdminUsersApi(this._client);

  final ConvexFunctionCaller _client;

  Future<SyncTypeResult> syncValue({
    required Map<String, SyncTypeArgsPayloadValue> payload,
    required SyncTypeArgsMode mode,
  }) async {
    final raw = await _client.action(
      'admin/users:sync',
      _encodeSyncTypeArgs((payload: payload, mode: mode)),
    );
    return _decodeSyncTypeResult(raw);
  }
}

typedef SyncTypeResult = ({bool success, BigInt count});

Map<String, dynamic> _encodeSyncTypeResult(SyncTypeResult value) {
  final (success: success, count: count) = value;
  return <String, dynamic>{'success': success, 'count': count};
}

SyncTypeResult _decodeSyncTypeResult(dynamic raw) {
  final map = expectMap(raw, label: 'SyncTypeResult');
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

Map<String, dynamic> _encodeSyncTypeArgs(SyncTypeArgs value) {
  final (payload: payload, mode: mode) = value;
  return <String, dynamic>{
    'payload': payload.map(
      (key, value) => MapEntry(key, _encodeSyncTypeArgsPayloadValue(value)),
    ),
    'mode': mode.value,
  };
}

SyncTypeArgs _decodeSyncTypeArgs(dynamic raw) {
  final map = expectMap(raw, label: 'SyncTypeArgs');
  return (
    payload: expectMap(map['payload'], label: 'SyncTypeArgsPayload').map(
      (key, value) => MapEntry(key, _decodeSyncTypeArgsPayloadValue(value)),
    ),
    mode: SyncTypeArgsMode.fromJson(map['mode']),
  );
}
