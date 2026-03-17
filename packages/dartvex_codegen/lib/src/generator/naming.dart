import 'package:path/path.dart' as path;

class NamingException implements Exception {
  NamingException(this.message);

  final String message;

  @override
  String toString() => message;
}

class Naming {
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

  String moduleClassName(List<String> segments) {
    if (segments.isEmpty) {
      return 'ConvexApi';
    }
    return '${segments.map(typeName).join()}Api';
  }

  String moduleGetterName(String raw) => fieldName(raw);

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

  String typeSuffixFromPath(List<String> segments) {
    if (segments.isEmpty) {
      return '';
    }
    return segments.map(typeName).join();
  }

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
