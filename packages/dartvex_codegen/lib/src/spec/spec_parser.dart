import 'dart:convert';

import 'function_spec.dart';

/// Raised when a Convex function spec cannot be parsed or validated.
class SpecParserException implements FormatException {
  /// Creates a parser exception with optional source metadata.
  SpecParserException(this.message, {this.source, this.offset});

  @override

  /// A human-readable parse failure message.
  final String message;

  @override

  /// The original source object associated with the parse failure, if any.
  final Object? source;

  @override

  /// The character offset of the failure, if known.
  final int? offset;

  @override
  String toString() => message;
}

/// Parses the JSON emitted by `convex function-spec`.
class SpecParser {
  /// Creates a spec parser.
  const SpecParser();

  /// Parses a JSON string into a [FunctionsSpec].
  FunctionsSpec parseString(String jsonSource) {
    final decoded = jsonDecode(jsonSource);
    if (decoded is! Map<String, dynamic>) {
      throw SpecParserException('function-spec root must be a JSON object');
    }
    return parseMap(decoded);
  }

  /// Parses a decoded JSON object into a [FunctionsSpec].
  FunctionsSpec parseMap(Map<String, dynamic> map) {
    final url = _readString(map, 'url');
    final rawFunctions = _readList(map, 'functions');
    return FunctionsSpec(
      url: url,
      functions: rawFunctions.map((item) {
        if (item is! Map<String, dynamic>) {
          throw SpecParserException(
            'Each function entry must be a JSON object',
          );
        }
        return _parseBaseFunctionSpec(item);
      }).toList(growable: false),
    );
  }

  BaseFunctionSpec _parseBaseFunctionSpec(Map<String, dynamic> map) {
    final functionType = _readString(map, 'functionType');
    if (functionType == 'HttpAction') {
      return HttpFunctionSpec(
        functionType: functionType,
        method: _readString(map, 'method'),
        path: _readString(map, 'path'),
      );
    }
    final identifier = _readString(map, 'identifier');
    try {
      return FunctionSpec(
        functionType: functionType,
        args: _parseTypeOrAny(map, 'args',
            context: _appendContext(identifier, 'args')),
        returns: _parseTypeOrAny(map, 'returns',
            context: _appendContext(identifier, 'returns')),
        identifier: identifier,
        visibility: Visibility(_readString(_readMap(map, 'visibility'), 'kind')),
      );
    } on SpecParserException catch (error) {
      // Guarantee the offending function is always named, even for failures
      // (such as visibility) parsed without a threaded context path.
      if (error.message.startsWith(identifier)) {
        rethrow;
      }
      throw SpecParserException(_withContext(error.message, identifier));
    }
  }

  /// Parses the type at [key], treating an absent or null value as the Convex
  /// `any` type.
  ///
  /// `convex function-spec` emits `"returns": null` for functions without an
  /// explicit returns validator (and may omit `args`); both should degrade to
  /// an untyped value instead of aborting the entire generation run.
  ConvexType _parseTypeOrAny(
    Map<String, dynamic> map,
    String key, {
    String context = '',
  }) {
    final value = map[key];
    if (value == null) {
      return const ConvexAnyType();
    }
    return _parseType(_readMap(map, key), context: context);
  }

  ConvexType _parseType(Map<String, dynamic> map, {String context = ''}) {
    final type = _readString(map, 'type');
    switch (type) {
      case 'any':
        return const ConvexAnyType();
      case 'boolean':
        return const ConvexBooleanType();
      case 'string':
        return const ConvexStringType();
      case 'number':
        return const ConvexNumberType();
      case 'null':
        return const ConvexNullType();
      case 'bigint':
        return const ConvexBigIntType();
      case 'bytes':
        return const ConvexBytesType();
      case 'literal':
        return ConvexLiteralType(map['value']);
      case 'union':
        final members = _readList(map, 'value');
        final parsed = <ConvexType>[];
        for (var index = 0; index < members.length; index += 1) {
          final item = members[index];
          final memberContext =
              _appendContext(context, 'union member ${index + 1}');
          if (item is! Map<String, dynamic>) {
            throw SpecParserException(
              _withContext('Union members must be JSON objects', memberContext),
            );
          }
          parsed.add(_parseType(item, context: memberContext));
        }
        return ConvexUnionType(parsed);
      case 'record':
        return ConvexRecordType(
          keys: _parseType(_readMap(map, 'keys'),
              context: _appendContext(context, 'record key')),
          values: _parseField(_readMap(map, 'values'),
              context: _appendContext(context, 'record value')),
        );
      case 'object':
        final value = _readMap(map, 'value');
        return ConvexObjectType(
          value.map(
            (key, rawField) {
              if (rawField is! Map<String, dynamic>) {
                throw SpecParserException(
                  _withContext(
                    'Object field "$key" must be a JSON object',
                    context,
                  ),
                );
              }
              return MapEntry(
                key,
                _parseField(rawField,
                    context: _appendContext(context, 'field "$key"')),
              );
            },
          ),
        );
      case 'array':
        return ConvexArrayType(
          _parseType(_readMap(map, 'value'),
              context: _appendContext(context, 'element')),
        );
      case 'id':
        return ConvexIdType(_readString(map, 'tableName'));
    }
    throw SpecParserException(
      _withContext('Unsupported Convex type "$type"', context),
    );
  }

  ConvexField _parseField(Map<String, dynamic> map, {String context = ''}) {
    return ConvexField(
      fieldType: _parseType(_readMap(map, 'fieldType'), context: context),
      optional: _readBool(map, 'optional'),
    );
  }

  /// Appends [segment] to [context], building an arrow-delimited diagnostic
  /// path such as `messages.ts:list → args → field "filters"`.
  String _appendContext(String context, String segment) =>
      context.isEmpty ? segment : '$context → $segment';

  /// Prefixes [message] with [context] when a context path is present.
  String _withContext(String message, String context) =>
      context.isEmpty ? message : '$context: $message';

  String _readString(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is String) {
      return value;
    }
    throw SpecParserException('Expected "$key" to be a string');
  }

  bool _readBool(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is bool) {
      return value;
    }
    throw SpecParserException('Expected "$key" to be a boolean');
  }

  List<dynamic> _readList(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is List<dynamic>) {
      return value;
    }
    throw SpecParserException('Expected "$key" to be a list');
  }

  Map<String, dynamic> _readMap(Map<String, dynamic> map, String key) {
    final value = map[key];
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.cast<String, dynamic>();
    }
    throw SpecParserException('Expected "$key" to be an object');
  }
}
