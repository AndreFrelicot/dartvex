import 'dart:convert';

String canonicalizeQueryName(String name) {
  final parts = name.split(':');
  late final String moduleName;
  late final String functionName;
  if (parts.length == 1) {
    moduleName = parts.first;
    functionName = 'default';
  } else {
    moduleName = parts.sublist(0, parts.length - 1).join(':');
    functionName = parts.last;
  }
  final normalizedModule = moduleName.endsWith('.js')
      ? moduleName.substring(0, moduleName.length - 3)
      : moduleName;
  return '$normalizedModule:$functionName';
}

String serializeQueryKey(String queryName, Map<String, dynamic> args) {
  final normalized = <String, dynamic>{
    'udfPath': canonicalizeQueryName(queryName),
    'args': canonicalizeJsonValue(args),
  };
  return jsonEncode(normalized);
}

Object? canonicalizeJsonValue(Object? value) {
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort(
        (left, right) => left.key.toString().compareTo(right.key.toString()),
      );
    return <String, Object?>{
      for (final entry in entries)
        entry.key.toString(): canonicalizeJsonValue(entry.value),
    };
  }
  if (value is List) {
    return value.map(canonicalizeJsonValue).toList(growable: false);
  }
  return value;
}
