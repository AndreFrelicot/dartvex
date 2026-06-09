// GENERATED CODE - DO NOT MODIFY BY HAND.

import '../runtime.dart';
import '../schema.dart';
import 'dart:typed_data';
import 'package:dartvex/dartvex.dart';

class TestingApi {
  const TestingApi(this._client);

  final ConvexFunctionCaller _client;

  Future<EchoValuesResult> echoValues({
    required Uint8List bytesValue,
    required BigInt intValue,
  }) async {
    final raw = await _client.action(
      'testing:echoValues',
      _encodeEchoValuesArgs((bytesValue: bytesValue, intValue: intValue)),
    );
    return _decodeEchoValuesResult(raw);
  }

  Future<SpecialValuesSnapshotResult> specialValuesSnapshot() async {
    final raw = await _client.query(
      'testing:specialValuesSnapshot',
      const <String, dynamic>{},
    );
    return _decodeSpecialValuesSnapshotResult(raw);
  }

  TypedConvexSubscription<SpecialValuesSnapshotResult>
  specialValuesSnapshotSubscribe() {
    final subscription = _client.subscribe(
      'testing:specialValuesSnapshot',
      const <String, dynamic>{},
    );
    final typedStream = subscription.stream.map((event) {
      switch (event) {
        case QuerySuccess(:final value):
          return TypedQuerySuccess<SpecialValuesSnapshotResult>(
            _decodeSpecialValuesSnapshotResult(value),
          );
        case QueryLoading(:final hasPendingWrites):
          return TypedQueryLoading<SpecialValuesSnapshotResult>(
            hasPendingWrites: hasPendingWrites,
          );
        case QueryError(:final message, :final data, :final logLines):
          return TypedQueryError<SpecialValuesSnapshotResult>(
            message,
            data: data,
            logLines: logLines,
          );
      }
    });
    return TypedConvexSubscription<SpecialValuesSnapshotResult>(
      subscription,
      typedStream,
    );
  }
}

typedef EchoValuesResult = ({
  double bytesLength,
  Uint8List bytesValue,
  BigInt intPlusOne,
  BigInt intValue,
});

Map<String, dynamic> _encodeEchoValuesResult(EchoValuesResult value) {
  final (
    bytesLength: bytesLength,
    bytesValue: bytesValue,
    intPlusOne: intPlusOne,
    intValue: intValue,
  ) = value;
  return <String, dynamic>{
    'bytesLength': bytesLength,
    'bytesValue': bytesValue,
    'intPlusOne': intPlusOne,
    'intValue': intValue,
  };
}

EchoValuesResult _decodeEchoValuesResult(dynamic raw) {
  final map = expectMap(raw, label: 'EchoValuesResult');
  if (!map.containsKey('bytesLength')) {
    throw FormatException(
      'Missing required field "bytesLength" for EchoValuesResult',
    );
  }
  if (!map.containsKey('bytesValue')) {
    throw FormatException(
      'Missing required field "bytesValue" for EchoValuesResult',
    );
  }
  if (!map.containsKey('intPlusOne')) {
    throw FormatException(
      'Missing required field "intPlusOne" for EchoValuesResult',
    );
  }
  if (!map.containsKey('intValue')) {
    throw FormatException(
      'Missing required field "intValue" for EchoValuesResult',
    );
  }
  return (
    bytesLength: expectDouble(
      map['bytesLength'],
      label: 'EchoValuesResultBytesLength',
    ),
    bytesValue: expectBytes(
      map['bytesValue'],
      label: 'EchoValuesResultBytesValue',
    ),
    intPlusOne: expectBigInt(
      map['intPlusOne'],
      label: 'EchoValuesResultIntPlusOne',
    ),
    intValue: expectBigInt(map['intValue'], label: 'EchoValuesResultIntValue'),
  );
}

typedef EchoValuesArgs = ({Uint8List bytesValue, BigInt intValue});

Map<String, dynamic> _encodeEchoValuesArgs(EchoValuesArgs value) {
  final (bytesValue: bytesValue, intValue: intValue) = value;
  return <String, dynamic>{'bytesValue': bytesValue, 'intValue': intValue};
}

EchoValuesArgs _decodeEchoValuesArgs(dynamic raw) {
  final map = expectMap(raw, label: 'EchoValuesArgs');
  if (!map.containsKey('bytesValue')) {
    throw FormatException(
      'Missing required field "bytesValue" for EchoValuesArgs',
    );
  }
  if (!map.containsKey('intValue')) {
    throw FormatException(
      'Missing required field "intValue" for EchoValuesArgs',
    );
  }
  return (
    bytesValue: expectBytes(
      map['bytesValue'],
      label: 'EchoValuesArgsBytesValue',
    ),
    intValue: expectBigInt(map['intValue'], label: 'EchoValuesArgsIntValue'),
  );
}

typedef SpecialValuesSnapshotResult = ({
  BigInt largeNegative,
  BigInt largePositive,
  Uint8List sampleBytes,
  BigInt zero,
});

Map<String, dynamic> _encodeSpecialValuesSnapshotResult(
  SpecialValuesSnapshotResult value,
) {
  final (
    largeNegative: largeNegative,
    largePositive: largePositive,
    sampleBytes: sampleBytes,
    zero: zero,
  ) = value;
  return <String, dynamic>{
    'largeNegative': largeNegative,
    'largePositive': largePositive,
    'sampleBytes': sampleBytes,
    'zero': zero,
  };
}

SpecialValuesSnapshotResult _decodeSpecialValuesSnapshotResult(dynamic raw) {
  final map = expectMap(raw, label: 'SpecialValuesSnapshotResult');
  if (!map.containsKey('largeNegative')) {
    throw FormatException(
      'Missing required field "largeNegative" for SpecialValuesSnapshotResult',
    );
  }
  if (!map.containsKey('largePositive')) {
    throw FormatException(
      'Missing required field "largePositive" for SpecialValuesSnapshotResult',
    );
  }
  if (!map.containsKey('sampleBytes')) {
    throw FormatException(
      'Missing required field "sampleBytes" for SpecialValuesSnapshotResult',
    );
  }
  if (!map.containsKey('zero')) {
    throw FormatException(
      'Missing required field "zero" for SpecialValuesSnapshotResult',
    );
  }
  return (
    largeNegative: expectBigInt(
      map['largeNegative'],
      label: 'SpecialValuesSnapshotResultLargeNegative',
    ),
    largePositive: expectBigInt(
      map['largePositive'],
      label: 'SpecialValuesSnapshotResultLargePositive',
    ),
    sampleBytes: expectBytes(
      map['sampleBytes'],
      label: 'SpecialValuesSnapshotResultSampleBytes',
    ),
    zero: expectBigInt(map['zero'], label: 'SpecialValuesSnapshotResultZero'),
  );
}
