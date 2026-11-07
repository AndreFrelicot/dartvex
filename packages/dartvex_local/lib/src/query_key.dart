import 'dart:convert';
import 'dart:typed_data';

import 'package:dartvex/dartvex.dart' show convexToCanonicalJson;

/// Normalizes a Convex query [name] into a stable `module:function` form.
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

/// Serializes a cache key for a query using its canonicalized name and [args].
String serializeQueryKey(String queryName, Map<String, dynamic> args) {
  final normalized = <String, dynamic>{
    'udfPath': canonicalizeQueryName(queryName),
    // Canonical numbers: `10` and `10.0` are the same Convex float64 and the
    // same query for the core client, so they share one cache entry (and the
    // key is the same on the VM and the web).
    'args': convexToCanonicalJson(args),
  };
  return jsonEncode(normalized);
}

/// Recursively canonicalizes JSON-like data for deterministic encoding.
///
/// [Uint8List] values (Convex `bytes`) are returned unchanged: they are also
/// `List`s, and rebuilding them as plain `List<int>` would make the codec
/// encode them as number arrays instead of `{"$bytes": ...}`, changing the
/// query key they produce.
Object? canonicalizeJsonValue(Object? value) {
  if (value is Uint8List) {
    return value;
  }
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
