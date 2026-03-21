import 'package:path/path.dart' as path;

/// Thrown when a raw Convex identifier cannot be mapped safely to Dart.
class NamingException implements Exception {
  /// Creates a naming error.
  NamingException(this.message);

  /// Human-readable failure details.
  final String message;

  @override
  String toString() => message;
}

/// Converts Convex identifiers and module paths into valid Dart symbols.
class Naming {
  /// Creates a naming helper.
  const Naming();

  static const Set<String> _keywords = <String>{
    'abstract',
    'as',
    'assert',
    'async',
    'await',
    'base',
    'break',
    'case',
    'catch',
    'class',
    'const',
    'continue',
    'covariant',
    'default',
    'deferred',
    'do',
    'dynamic',
    'else',
    'enum',
    'export',
    'extends',
    'extension',
    'external',
    'factory',
    'false',
    'final',
    'finally',
    'for',
    'function',
    'get',
    'hide',
    'if',
    'implements',
    'import',
    'in',
    'interface',
    'is',
    'late',
    'library',
    'mixin',
    'new',
    'null',
    'of',
    'on',
    'operator',
    'part',
    'required',
    'rethrow',
    'return',
    'sealed',
    'set',
    'show',
    'static',
    'super',
    'switch',
    'sync',
    'this',
    'throw',
    'true',
    'try',
    'typedef',
    'var',
    'void',
    'when',
    'while',
    'with',
    'yield',
  };

  /// Returns the generated API class name for a module path.
  String moduleClassName(List<String> segments) {
    if (segments.isEmpty) {
      return 'ConvexApi';
    }
    return '${segments.map(typeName).join()}Api';
  }

  /// Returns the getter name used for a nested module accessor.
  String moduleGetterName(String raw) => fieldName(raw);

  /// Converts an arbitrary identifier into a valid PascalCase Dart type name.
  String typeName(String raw) {
    final parts = _split(raw);
    if (parts.isEmpty) {
      return 'GeneratedType';
    }
    final base = parts
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join();
    return _sanitizeTypeName(base);
  }

  /// Converts an arbitrary identifier into a valid camelCase method name.
  String methodName(String raw) {
    final parts = _split(raw);
    if (parts.isEmpty) {
      return 'call';
    }
    final first = parts.first.toLowerCase();
    final rest = parts
        .skip(1)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join();
    return _sanitizeFieldName('$first$rest');
  }

  /// Converts an arbitrary identifier into a valid camelCase field name.
  String fieldName(String raw) {
    final parts = _split(raw);
    if (parts.isEmpty) {
      return 'value';
    }
    final first = parts.first.toLowerCase();
    final rest = parts
        .skip(1)
        .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
        .join();
    return _sanitizeFieldName('$first$rest');
  }

  /// Builds a stable enum value name for a literal union member.
  String enumValueName(Object? value, int index) {
    final raw = switch (value) {
      null => 'null',
      _ => value.toString(),
    };
    final base = fieldName(raw);
    if (base == 'value') {
      return 'value$index';
    }
    return '${base}Value';
  }

  /// Returns the type name suffix generated from a module path.
  String typeSuffixFromPath(List<String> segments) {
    if (segments.isEmpty) {
      return '';
    }
    return segments.map(typeName).join();
  }

  /// Computes a relative import from [fromFile] to [targetFile].
  String relativeImport({
    required String fromFile,
    required String targetFile,
  }) {
    final relative = path.relative(targetFile, from: path.dirname(fromFile));
    final normalized = path.posix.normalize(relative.replaceAll(r'\', '/'));
    if (normalized.startsWith('.')) {
      return normalized;
    }
    return './$normalized';
  }

  List<String> _split(String raw) {
    return raw
        .split(RegExp(r'[^a-zA-Z0-9]+'))
        .where((part) => part.isNotEmpty)
        .map((part) {
      if (part.length == 1) {
        return part.toLowerCase();
      }
      return '${part[0].toLowerCase()}${part.substring(1)}';
    }).toList(growable: false);
  }

  String _sanitizeTypeName(String value) {
    var result = value.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    if (result.isEmpty) {
      result = 'GeneratedType';
    }
    if (RegExp(r'^\d').hasMatch(result)) {
      result = 'V$result';
    }
    if (_keywords.contains(result.toLowerCase())) {
      result = '${result}Type';
    }
    return result;
  }

  String _sanitizeFieldName(String value) {
    var result = value.replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');
    if (result.isEmpty) {
      result = 'value';
    }
    if (RegExp(r'^\d').hasMatch(result)) {
      result = 'v$result';
    }
    if (_keywords.contains(result)) {
      result = '${result}Value';
    }
    return result;
  }
}
