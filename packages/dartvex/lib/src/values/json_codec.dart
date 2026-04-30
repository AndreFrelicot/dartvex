import 'dart:convert';
import 'dart:typed_data';

final BigInt _minInt64 = BigInt.from(-0x8000000000000000);
final BigInt _maxInt64 = BigInt.from(0x7fffffffffffffff);
final BigInt _byteMask = BigInt.from(0xff);

/// Creates an explicit Convex `int64` value for `v.int64()` arguments.
///
/// Plain Dart [int] values encode as JSON numbers for `v.number()` arguments.
/// Use this helper, or [BigInt.from], when the Convex function expects
/// `v.int64()`.
BigInt convexInt64(int value) {
  final int64 = BigInt.from(value);
  _checkInt64(int64);
  return int64;
}

dynamic convexToJson(dynamic value) {
  return _convexToJson(value);
}

dynamic jsonToConvex(dynamic value) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (value is List) {
    return value.map(jsonToConvex).toList(growable: false);
  }
  if (value is! Map) {
    throw ArgumentError.value(
      value,
      'value',
      '${value.runtimeType} is not a supported Convex JSON value',
    );
  }

  final map = value.map<String, dynamic>(
    (key, item) => MapEntry(key.toString(), item),
  );
  if (map.length == 1) {
    final entry = map.entries.single;
    switch (entry.key) {
      case r'$bytes':
        final encoded = entry.value;
        if (encoded is! String) {
          throw FormatException('Malformed \$bytes field', map);
        }
        return Uint8List.fromList(base64Decode(encoded));
      case r'$integer':
        final encoded = entry.value;
        if (encoded is! String) {
          throw FormatException('Malformed \$integer field', map);
        }
        return _decodeInt64(encoded);
      case r'$float':
        final encoded = entry.value;
        if (encoded is! String) {
          throw FormatException('Malformed \$float field', map);
        }
        return _decodeFloat64(encoded);
      case r'$set':
        throw FormatException(
          'Received a Set which is no longer supported as a Convex type.',
          map,
        );
      case r'$map':
        throw FormatException(
          'Received a Map which is no longer supported as a Convex type.',
          map,
        );
    }
  }

  final out = <String, dynamic>{};
  final sortedKeys = map.keys.toList()..sort();
  for (final key in sortedKeys) {
    _validateObjectField(key);
    out[key] = jsonToConvex(map[key]);
  }
  return out;
}

dynamic _convexToJson(dynamic value) {
  if (value == null || value is bool || value is String) {
    return value;
  }
  if (value is BigInt) {
    _checkInt64(value);
    return <String, String>{r'$integer': _encodeInt64(value)};
  }
  if (value is int) {
    return value;
  }
  if (value is double) {
    if (_isSpecialDouble(value)) {
      return <String, String>{r'$float': _encodeFloat64(value)};
    }
    return value;
  }
  if (value is num) {
    return value;
  }
  if (value is Uint8List) {
    return <String, String>{r'$bytes': base64Encode(value)};
  }
  if (value is List) {
    return value.map(_convexToJson).toList(growable: false);
  }
  if (value is Set) {
    throw ArgumentError.value(
      value,
      'value',
      'Set is not a supported Convex type.',
    );
  }
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort(
        (left, right) => left.key.toString().compareTo(right.key.toString()),
      );
    final out = <String, dynamic>{};
    for (final entry in entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError.value(
          key,
          'value',
          'Convex object keys must be strings.',
        );
      }
      _validateObjectField(key);
      out[key] = _convexToJson(entry.value);
    }
    return out;
  }
  throw ArgumentError.value(
    value,
    'value',
    '${value.runtimeType} is not a supported Convex type.',
  );
}

void _checkInt64(BigInt value) {
  if (value < _minInt64 || value > _maxInt64) {
    throw ArgumentError.value(
      value,
      'value',
      'BigInt $value does not fit into a signed 64-bit integer.',
    );
  }
}

String _encodeFloat64(double value) {
  final bytes = ByteData(8)..setFloat64(0, value, Endian.little);
  return base64Encode(bytes.buffer.asUint8List());
}

String _encodeInt64(BigInt value) {
  final bytes = Uint8List(8);
  final normalized = value.toUnsigned(64);
  for (var index = 0; index < 8; index += 1) {
    bytes[index] = ((normalized >> (index * 8)) & _byteMask).toInt();
  }
  return base64Encode(bytes);
}

double _decodeFloat64(String encoded) {
  final bytes = base64Decode(encoded);
  if (bytes.length != 8) {
    throw FormatException(
      'Received ${bytes.length} bytes, expected 8 for \$float',
      encoded,
    );
  }
  final byteData = ByteData.sublistView(bytes);
  return byteData.getFloat64(0, Endian.little);
}

BigInt _decodeInt64(String encoded) {
  final bytes = base64Decode(encoded);
  if (bytes.length != 8) {
    throw FormatException(
      'Received ${bytes.length} bytes, expected 8 for \$integer',
      encoded,
    );
  }
  var value = BigInt.zero;
  for (var index = 0; index < bytes.length; index += 1) {
    value |= BigInt.from(bytes[index]) << (index * 8);
  }
  return value.toSigned(64);
}

bool _isSpecialDouble(double value) {
  return value.isNaN || value.isInfinite || (value == 0.0 && value.isNegative);
}

void _validateObjectField(String key) {
  if (key.startsWith(r'$')) {
    throw ArgumentError.value(
      key,
      'value',
      "Field name $key starts with '\$', which is reserved.",
    );
  }
  for (var index = 0; index < key.length; index += 1) {
    final codeUnit = key.codeUnitAt(index);
    if (codeUnit < 32 || codeUnit >= 127) {
      throw ArgumentError.value(
        key,
        'value',
        'Field name $key contains invalid characters.',
      );
    }
  }
}
