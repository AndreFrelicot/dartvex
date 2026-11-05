import 'dart:convert';

/// Result of scanning free-form text for a Convex function spec JSON object.
class FunctionSpecJsonScan {
  /// Creates a scan result.
  const FunctionSpecJsonScan({
    required this.json,
    required this.foundJsonObject,
    required this.lastError,
  });

  /// The first balanced JSON object that looks like a function spec, or
  /// `null` when none was found.
  final String? json;

  /// Whether any balanced JSON object was decoded, even if it was not a spec.
  final bool foundJsonObject;

  /// The last decode or shape problem seen while scanning, if any.
  final Object? lastError;
}

/// Scans [text] for the first balanced JSON object with a string `url` and a
/// list `functions` field.
///
/// Package runners (npx, yarn v1, pnpm) and the Convex CLI may print banners,
/// warnings, or log objects around the spec; this skips them.
FunctionSpecJsonScan scanFunctionSpecJson(String text) {
  var searchStart = text.indexOf('{');
  Object? lastError;
  var foundJsonObject = false;
  while (searchStart != -1) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var index = searchStart; index < text.length; index += 1) {
      final char = text.codeUnitAt(index);
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (char == 0x5c) {
          escaped = true;
        } else if (char == 0x22) {
          inString = false;
        }
        continue;
      }

      if (char == 0x22) {
        inString = true;
      } else if (char == 0x7b) {
        depth += 1;
      } else if (char == 0x7d) {
        depth -= 1;
        if (depth == 0) {
          final candidate = text.substring(searchStart, index + 1);
          try {
            final decoded = jsonDecode(candidate);
            if (decoded is Map<String, dynamic>) {
              foundJsonObject = true;
              if (_looksLikeFunctionSpec(decoded)) {
                return FunctionSpecJsonScan(
                  json: candidate,
                  foundJsonObject: true,
                  lastError: null,
                );
              }
              lastError =
                  'JSON object is missing string "url" and list "functions" '
                  'fields';
            } else {
              lastError = 'JSON value is ${decoded.runtimeType}, not an object';
            }
          } catch (error) {
            lastError = error;
          }
          break;
        }
        if (depth < 0) {
          break;
        }
      }
    }
    searchStart = text.indexOf('{', searchStart + 1);
  }
  return FunctionSpecJsonScan(
    json: null,
    foundJsonObject: foundJsonObject,
    lastError: lastError,
  );
}

/// Decodes a function spec document, tolerating noise around the JSON.
///
/// Strict JSON is tried first. On failure, the first embedded function spec
/// object is extracted with [scanFunctionSpecJson]; if there is none, the
/// original strict-JSON [FormatException] is rethrown.
Object? decodeFunctionSpecJson(String source) {
  try {
    return jsonDecode(source);
  } on FormatException {
    final scan = scanFunctionSpecJson(source);
    final json = scan.json;
    if (json == null) {
      rethrow;
    }
    return jsonDecode(json);
  }
}

bool _looksLikeFunctionSpec(Map<String, dynamic> object) {
  return object['url'] is String && object['functions'] is List<dynamic>;
}
