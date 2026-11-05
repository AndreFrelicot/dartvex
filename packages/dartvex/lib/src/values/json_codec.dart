import 'dart:convert';
import 'dart:typed_data';

final BigInt _minInt64 = BigInt.parse('-9223372036854775808');
final BigInt _maxInt64 = BigInt.parse('9223372036854775807');
final BigInt _byteMask = BigInt.from(0xff);
const int _maxIdentifierLength = 1024;

/// Largest magnitude below which every Dart [int] is exactly representable as
/// a Convex `float64` (`2^53`).
const int _maxSafeInteger = 9007199254740992;

/// The placeholder for a mutation's commit timestamp (`db.vars.commitTs`).
///
/// Convex (since 1.43) lets a mutation write `ctx.db.vars.commitTs` into a
/// document field; the value resolves to an `int64` when the mutation commits.
/// Reading such a field back inside the writing mutation yields this
/// placeholder, and a mutation, action, or error payload that returns it is
/// serialized on the wire as `{"$commitTs": null}`. [jsonToConvex] decodes that
/// shape to [ConvexCommitTsPlaceholder.instance] and [convexToJson] encodes the
/// instance back, mirroring the official client's `CommitTsPlaceholder`.
///
/// The placeholder carries no numeric value: read the document again after the
/// mutation completes to get the resolved timestamp. Compare with
/// `identical(value, ConvexCommitTsPlaceholder.instance)` or
/// `value is ConvexCommitTsPlaceholder`.
final class ConvexCommitTsPlaceholder {
  const ConvexCommitTsPlaceholder._();

  /// The singleton placeholder value.
  static const ConvexCommitTsPlaceholder instance =
      ConvexCommitTsPlaceholder._();

  @override
  String toString() => '[unresolved commit timestamp]';
}

/// Creates an explicit Convex `int64` value for `v.int64()` arguments.
///
/// Plain Dart [int] values encode as JSON numbers (Convex `float64`) for
/// `v.number()` arguments, and must be exactly representable as a `float64`
/// (any value within ±2^53 is). Use this helper, or [BigInt.from], when the
/// Convex function expects `v.int64()` or the value needs full 64-bit
/// precision.
BigInt convexInt64(int value) {
  final int64 = BigInt.from(value);
  _checkInt64(int64);
  return int64;
}

/// Encodes Dart values into Convex's canonical JSON representation.
///
/// [BigInt], [Uint8List], special [double] values, and
/// [ConvexCommitTsPlaceholder.instance] are encoded with the tagged shapes
/// expected by the Convex sync protocol.
///
/// Throws an [ArgumentError] for values Convex cannot represent, including a
/// Dart [int] that is not exactly representable as a `float64` (beyond ±2^53
/// on the Dart VM) — pass such values as a [BigInt] (`v.int64()`) or a string
/// instead of letting the server silently round them.
dynamic convexToJson(dynamic value) {
  return _convexToJson(value);
}

/// Decodes Convex's canonical JSON representation into Dart values.
///
/// Convex `int64`, `bytes`, and special floating-point sentinels are converted
/// to [BigInt], [Uint8List], and [double] values respectively, and the
/// `{"$commitTs": null}` placeholder to [ConvexCommitTsPlaceholder.instance].
/// Object fields preserve the incoming map's iteration order.
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
      case r'$commitTs':
        if (entry.value != null) {
          throw FormatException('Malformed \$commitTs field', map);
        }
        return ConvexCommitTsPlaceholder.instance;
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
  for (final key in map.keys) {
    _validateObjectField(key);
    out[key] = jsonToConvex(map[key]);
  }
  return out;
}

/// Eagerly validates and deep-canonicalizes a Convex argument map.
///
/// Runs the full wire encoding ([convexToJson]) and decodes it back, so an
/// unsupported value throws here — synchronously at the call site, like the
/// official client's eager `convexToJson(args)` — rather than later inside the
/// transport send path, where it would tear down a healthy connection and be
/// replayed by every reconnect. The round-trip also deep-copies the map, so
/// caller-side mutation of nested values after the call cannot change what is
/// sent (or re-sent on reconnect).
Map<String, dynamic> canonicalizeConvexArgs(Map<String, dynamic> args) {
  return jsonToConvex(convexToJson(args)) as Map<String, dynamic>;
}

dynamic _convexToJson(dynamic value) {
  if (value == null || value is bool || value is String) {
    return value;
  }
  // Special doubles (NaN, ±Infinity, -0.0) must round-trip through the tagged
  // $float form. This is checked before the int branch because on the web a
  // value such as -0.0 also satisfies `is int`, which would otherwise drop the
  // sign and encode it as a plain `0`.
  if (value is double && _isSpecialDouble(value)) {
    return <String, String>{r'$float': _encodeFloat64(value)};
  }
  if (value is BigInt) {
    _checkInt64(value);
    return <String, String>{r'$integer': _encodeInt64(value)};
  }
  if (value is int) {
    _checkFloat64Representable(value);
    return value;
  }
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value;
  }
  if (value is Uint8List) {
    return <String, String>{r'$bytes': base64Encode(value)};
  }
  if (value is ConvexCommitTsPlaceholder) {
    return const <String, Object?>{r'$commitTs': null};
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

/// Rejects a Dart [int] that the server would silently round when parsing it as
/// a `float64`. On the web every [int] is already a double, so this never
/// throws there; on the VM it only throws beyond ±2^53 for values that have no
/// exact `float64` representation.
void _checkFloat64Representable(int value) {
  if (value <= _maxSafeInteger && value >= -_maxSafeInteger) {
    return;
  }
  if (BigInt.from(value.toDouble()) == BigInt.from(value)) {
    return;
  }
  throw ArgumentError.value(
    value,
    'value',
    'int $value cannot be represented exactly as a Convex float64 '
        '(v.number()). Pass it as a BigInt (convexInt64 / v.int64()) or as a '
        'string instead.',
  );
}

/// Encodes [value] like [convexToJson], then normalizes numbers so the result is
/// a stable, platform-independent key for query identity.
///
/// A Dart `int` and an integral `double` (for example `10` and `10.0`) are the
/// same Convex `float64` on the wire, but `jsonEncode` renders them differently
/// on the Dart VM (`10` vs `10.0`) and identically on the web. This helper maps
/// every finite integral `double` within ±2^53 to the equivalent `int`, so a
/// key built with `jsonEncode(convexToCanonicalJson(args))` identifies the same
/// query on every platform. Tagged values (`$integer`, `$float`, `$bytes`,
/// `$commitTs`) are left untouched. Use it only for keys, never for the wire
/// encoding.
dynamic convexToCanonicalJson(dynamic value) {
  return _normalizeNumbers(convexToJson(value));
}

dynamic _normalizeNumbers(dynamic json) {
  if (json is double) {
    if (json.isFinite &&
        json == json.truncateToDouble() &&
        json.abs() <= _maxSafeInteger) {
      return json.toInt();
    }
    return json;
  }
  if (json is List) {
    return json.map(_normalizeNumbers).toList(growable: false);
  }
  if (json is Map) {
    return <String, dynamic>{
      for (final entry in json.entries)
        entry.key as String: _normalizeNumbers(entry.value),
    };
  }
  return json;
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
  final decoded = byteData.getFloat64(0, Endian.little);
  if (!_isSpecialDouble(decoded)) {
    throw FormatException(
      'Float $decoded should be encoded as a number',
      encoded,
    );
  }
  return decoded;
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
  if (key.length > _maxIdentifierLength) {
    throw ArgumentError.value(
      key,
      'value',
      'Field name $key exceeds maximum field name length '
          '$_maxIdentifierLength.',
    );
  }
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
