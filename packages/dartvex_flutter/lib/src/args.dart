import 'package:dartvex/dartvex.dart' show convexToJson, jsonToConvex;

/// Deep-copies [args] through the Convex value codec.
///
/// Widgets keep this snapshot as their subscription identity, so a caller
/// mutating the original map (or a nested value) in place is still detected as
/// an args change, and unsupported values fail at the call site. Same
/// round-trip as the core's own argument canonicalization.
Map<String, dynamic> snapshotConvexArgs(Map<String, dynamic>? args) {
  return jsonToConvex(convexToJson(args ?? const <String, dynamic>{}))
      as Map<String, dynamic>;
}
