import 'dart:convert';

import 'function_spec.dart';

class SpecParserException implements FormatException {
  SpecParserException(this.message, {this.source, this.offset});

  @override
  final String message;

  @override
  final Object? source;

  @override
  final int? offset;

  @override
  String toString() => message;
}

class SpecParser {
  const SpecParser();

  FunctionsSpec parseString(String jsonSource) {
    final decoded = jsonDecode(jsonSource);
    if (decoded is! Map<String, dynamic>) {
      throw SpecParserException('function-spec root must be a JSON object');
    }
    return parseMap(decoded);
  }

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
    return FunctionSpec(
      functionType: functionType,
      args: _parseType(_readMap(map, 'args')),
      returns: _parseType(_readMap(map, 'returns')),
      identifier: _readString(map, 'identifier'),
      visibility: Visibility(_readString(_readMap(map, 'visibility'), 'kind')),
    );
  }

  ConvexType _parseType(Map<String, dynamic> map) {
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
        return ConvexUnionType(
          _readList(map, 'value').map((item) {
            if (item is! Map<String, dynamic>) {
              throw SpecParserException(
                'Union members must be JSON objects',
              );
            }
            return _parseType(item);
          }).toList(growable: false),
        );
      case 'record':
        return ConvexRecordType(
          keys: _parseType(_readMap(map, 'keys')),
          values: _parseField(_readMap(map, 'values')),
        );
      case 'object':
        final value = _readMap(map, 'value');
        return ConvexObjectType(
          value.map(
            (key, rawField) {
              if (rawField is! Map<String, dynamic>) {
                throw SpecParserException(
                  'Object field "$key" must be a JSON object',
                );
              }
              return MapEntry(key, _parseField(rawField));
            },
          ),
        );
      case 'array':
        return ConvexArrayType(_parseType(_readMap(map, 'value')));
      case 'id':
        return ConvexIdType(_readString(map, 'tableName'));
    }
    throw SpecParserException('Unsupported Convex type "$type"');
  }

  ConvexField _parseField(Map<String, dynamic> map) {
    return ConvexField(
      fieldType: _parseType(_readMap(map, 'fieldType')),
      optional: _readBool(map, 'optional'),
    );
  }

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
