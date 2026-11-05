import 'dart:convert';

import 'package:dartvex/dartvex.dart' show convexToJson, jsonToConvex;

/// Encodes cached values and queued mutations for local persistence.
abstract class ValueCodec {
  /// Creates a value codec.
  const ValueCodec();

  /// Encodes a JSON-like [value] for storage.
  String encode(dynamic value);

  /// Decodes a stored value payload.
  dynamic decode(String value);

  /// Decodes a stored JSON object payload.
  Map<String, dynamic> decodeMap(String value);
}

/// Default [ValueCodec] that uses canonicalized JSON encoding.
///
/// Values are encoded with the core Convex JSON codec, so `int64`, `bytes`
/// and special floating-point values round-trip. The Convex commit-timestamp
/// placeholder (`{"$commitTs": null}`, sent since Convex 1.43 for documents
/// that read back `db.vars.commitTs` before commit) also round-trips: when the
/// core codec decodes it into a dedicated value, that value is kept; otherwise
/// it is preserved as the raw `{"$commitTs": null}` map.
class JsonValueCodec implements ValueCodec {
  /// Creates a JSON value codec.
  const JsonValueCodec();

  @override
  /// Decodes a JSON payload into a Dart value.
  dynamic decode(String value) {
    return _decodeJson(jsonDecode(value));
  }

  @override
  /// Decodes a JSON object payload into a mutable map.
  Map<String, dynamic> decodeMap(String value) {
    final decoded = _decodeJson(jsonDecode(value));
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.cast<String, dynamic>();
    }
    throw FormatException('Expected JSON object, got ${decoded.runtimeType}');
  }

  @override
  /// Encodes a value after canonicalizing JSON map ordering.
  String encode(dynamic value) {
    return jsonEncode(_encodeValue(value));
  }
}

const String _commitTsKey = r'$commitTs';

bool _isCommitTsPlaceholderJson(Object? value) {
  return value is Map &&
      value.length == 1 &&
      value.containsKey(_commitTsKey) &&
      value[_commitTsKey] == null;
}

bool _containsCommitTsPlaceholder(Object? value) {
  if (_isCommitTsPlaceholderJson(value)) {
    return true;
  }
  if (value is Map) {
    return value.values.any(_containsCommitTsPlaceholder);
  }
  if (value is List) {
    return value.any(_containsCommitTsPlaceholder);
  }
  return false;
}

/// Decodes stored JSON with the core codec, preserving `{"$commitTs": null}`.
///
/// Subtrees without the placeholder go straight through [jsonToConvex], so
/// their decoding (including field-name validation) is unchanged.
dynamic _decodeJson(Object? json) {
  if (!_containsCommitTsPlaceholder(json)) {
    return jsonToConvex(json);
  }
  if (_isCommitTsPlaceholderJson(json)) {
    return _decodeCommitTsPlaceholder();
  }
  if (json is List) {
    return json.map(_decodeJson).toList(growable: false);
  }
  final map = json! as Map;
  // Validate the field names through the core codec, as the placeholder-free
  // path does: a reserved or malformed name next to a placeholder (including
  // a `$commitTs` key with siblings) is rejected, not passed through.
  jsonToConvex(<String, dynamic>{
    for (final key in map.keys) key.toString(): null,
  });
  return <String, dynamic>{
    for (final entry in map.entries)
      entry.key.toString(): _decodeJson(entry.value),
  };
}

dynamic _decodeCommitTsPlaceholder() {
  try {
    // A core codec that models the placeholder returns its own value.
    return jsonToConvex(const <String, dynamic>{_commitTsKey: null});
  } on ArgumentError {
    // Older core codecs reject the reserved field name; keep the raw map.
    return <String, dynamic>{_commitTsKey: null};
  }
}

/// Encodes a value with the core codec, passing a raw `{"$commitTs": null}`
/// map through unchanged (the core rejects its reserved field name).
dynamic _encodeValue(Object? value) {
  if (!_containsCommitTsPlaceholder(value)) {
    return convexToJson(value);
  }
  if (_isCommitTsPlaceholderJson(value)) {
    return const <String, dynamic>{_commitTsKey: null};
  }
  if (value is List) {
    return value.map(_encodeValue).toList(growable: false);
  }
  final map = value! as Map;
  final keys = map.keys.toList()
    ..sort((left, right) => left.toString().compareTo(right.toString()));
  // Validate non-placeholder field names through the core codec.
  convexToJson(<dynamic, dynamic>{for (final key in keys) key: null});
  return <String, dynamic>{
    for (final key in keys) key.toString(): _encodeValue(map[key]),
  };
}
