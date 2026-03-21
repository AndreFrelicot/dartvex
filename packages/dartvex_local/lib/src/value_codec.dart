import 'dart:convert';

import 'query_key.dart';

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
class JsonValueCodec implements ValueCodec {
  /// Creates a JSON value codec.
  const JsonValueCodec();

  @override

  /// Decodes a JSON payload into a Dart value.
  dynamic decode(String value) {
    return jsonDecode(value);
  }

  @override

  /// Decodes a JSON object payload into a mutable map.
  Map<String, dynamic> decodeMap(String value) {
    final decoded = jsonDecode(value);
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
    return jsonEncode(canonicalizeJsonValue(value));
  }
}
