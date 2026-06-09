import 'dart:convert';

/// The placeholder deployment URL written into committed function specs so a
/// real Convex deployment URL never reaches version control.
const String placeholderDeploymentUrl = 'https://your-deployment.convex.cloud';

/// Returns [rawJson] (a raw `convex function-spec` dump) with its top-level
/// `url` replaced by [placeholderUrl].
///
/// A raw dump bakes the real deployment URL into the top of the JSON; this
/// scrub replaces it while keeping everything else intact — key order is
/// preserved and the output is re-serialized with a 2-space indent to match
/// Convex's own formatting so committed diffs stay minimal. The transform is
/// idempotent: scrubbing already-scrubbed JSON yields identical output.
String scrubFunctionSpec(
  String rawJson, {
  String placeholderUrl = placeholderDeploymentUrl,
}) {
  final Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } on FormatException catch (error) {
    throw FormatException('function-spec is not valid JSON: ${error.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('function-spec root must be a JSON object');
  }
  // Replacing in place preserves the key's position for an existing `url`
  // (LinkedHashMap ordering), so only the URL line changes in a diff.
  decoded['url'] = placeholderUrl;
  return '${const JsonEncoder.withIndent('  ').convert(decoded)}\n';
}
