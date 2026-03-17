import 'dart:convert';

import 'query_key.dart';

abstract class ValueCodec {
  const ValueCodec();

  String encode(dynamic value);

  dynamic decode(String value);

  Map<String, dynamic> decodeMap(String value);
}

class JsonValueCodec implements ValueCodec {
  const JsonValueCodec();

  @override
  dynamic decode(String value) {
    return jsonDecode(value);
  }

  @override
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
  String encode(dynamic value) {
    return jsonEncode(canonicalizeJsonValue(value));
  }
}
