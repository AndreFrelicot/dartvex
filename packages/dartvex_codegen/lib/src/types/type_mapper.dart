import '../generator/naming.dart';
import '../spec/function_spec.dart';
import 'dart_type.dart';

/// Renders encode and decode expressions for a generated value.
typedef ExpressionRenderer = String Function(String expression);

/// Thrown when Convex types cannot be mapped to valid Dart representations.
class TypeMapperException implements Exception {
  /// Creates a type-mapping failure.
  TypeMapperException(this.message);

  /// Human-readable failure details.
  final String message;

  @override
  String toString() => message;
}

/// Mutable context shared while rendering generated Dart types.
class TypeRenderContext {
  /// Creates a render context with optional naming overrides.
  TypeRenderContext({Naming? naming}) : naming = naming ?? const Naming();

  /// Naming helper used while reserving generated symbols.
  final Naming naming;

  /// Table names referenced by generated ID wrappers.
  final Set<String> tableNames = <String>{};

  /// Non-fatal warnings accumulated during mapping.
  final List<String> warnings = <String>[];
  final Map<String, String> _definitions = <String, String>{};
  final List<String> _definitionOrder = <String>[];
  final Set<String> _reservedTypeNames = <String>{};
  final Map<String, String> _suggestedToReserved = <String, String>{};

  /// Whether the generated file needs `dart:typed_data`.
  bool usesTypedData = false;

  /// Reserves and returns a unique generated type name for [suggestedName].
  String reserveTypeName(String suggestedName) {
    final normalized = naming.typeName(suggestedName);
    final existing = _suggestedToReserved[normalized];
    if (existing != null) {
      return existing;
    }
    var candidate = normalized;
    var suffix = 2;
    while (_reservedTypeNames.contains(candidate)) {
      candidate = '$normalized$suffix';
      suffix += 1;
    }
    _reservedTypeNames.add(candidate);
    _suggestedToReserved[normalized] = candidate;
    return candidate;
  }

  /// Registers a generated type/helper definition if it has not been added yet.
  void addDefinition(String name, String code) {
    final existing = _definitions[name];
    if (existing != null) {
      if (existing != code) {
        throw TypeMapperException('Name collision for generated type "$name"');
      }
      return;
    }
    _definitions[name] = code;
    _definitionOrder.add(name);
  }

  /// Renders all accumulated type definitions in insertion order.
  String renderDefinitions() {
    return _definitionOrder.map((name) => _definitions[name]!).join('\n\n');
  }
}

/// A mapped Dart type plus encode/decode logic for generated bindings.
class MappedType {
  /// Creates a mapped type.
  const MappedType({
    required this.dartType,
    required this.encode,
    required this.decode,
  });

  /// The generated Dart type.
  final DartType dartType;

  /// Renderer that converts a Dart expression into a wire expression.
  final ExpressionRenderer encode;

  /// Renderer that converts a wire expression into a Dart expression.
  final ExpressionRenderer decode;

  /// Convenience accessor for the wrapped type annotation string.
  String get annotation => dartType.annotation;
}

/// Converts Convex schema types into generated Dart types and codecs.
class TypeMapper {
  /// Creates a type mapper with optional naming overrides.
  TypeMapper({Naming? naming}) : _naming = naming ?? const Naming();

  final Naming _naming;

  /// Maps a Convex [type] into Dart using [suggestedName] within [context].
  MappedType mapType(
    ConvexType type, {
    required String suggestedName,
    required TypeRenderContext context,
  }) {
    if (type is ConvexAnyType) {
      return MappedType(
        dartType: const DartPrimitiveType('dynamic'),
        encode: (expression) => expression,
        decode: (expression) => expression,
      );
    }
    if (type is ConvexBooleanType) {
      return MappedType(
        dartType: const DartPrimitiveType('bool'),
        encode: (expression) => expression,
        decode: (expression) =>
            "expectBool($expression, label: '$suggestedName')",
      );
    }
    if (type is ConvexStringType) {
      return MappedType(
        dartType: const DartPrimitiveType('String'),
        encode: (expression) => expression,
        decode: (expression) =>
            "expectString($expression, label: '$suggestedName')",
      );
    }
    if (type is ConvexNumberType) {
      return MappedType(
        dartType: const DartPrimitiveType('double'),
        encode: (expression) => expression,
        decode: (expression) =>
            "expectDouble($expression, label: '$suggestedName')",
      );
    }
    if (type is ConvexNullType) {
      return MappedType(
        dartType: const DartPrimitiveType('Null'),
        encode: (_) => 'null',
        decode: (_) => 'null',
      );
    }
    if (type is ConvexBigIntType) {
      return MappedType(
        dartType: const DartPrimitiveType('BigInt'),
        encode: (expression) => expression,
        decode: (expression) =>
            "expectBigInt($expression, label: '$suggestedName')",
      );
    }
    if (type is ConvexBytesType) {
      context.usesTypedData = true;
      return MappedType(
        dartType: const DartPrimitiveType('Uint8List'),
        encode: (expression) => expression,
        decode: (expression) =>
            "expectBytes($expression, label: '$suggestedName')",
      );
    }
    if (type is ConvexLiteralType) {
      final literalType = _literalDartType(type.value);
      final expectedCode = _literalCode(type.value);
      return MappedType(
        dartType: literalType,
        encode: (expression) => expression,
        decode: (expression) => literalType.annotation == 'Null'
            ? 'null'
            : 'expectLiteral<${literalType.annotation}>($expression, '
                '$expectedCode, label: \'$suggestedName\')',
      );
    }
    if (type is ConvexIdType) {
      context.tableNames.add(type.tableName);
      final typeName = '${_naming.typeName(type.tableName)}Id';
      return MappedType(
        dartType: DartNamedType(typeName),
        encode: (expression) => '$expression.value',
        decode: (expression) =>
            "$typeName(expectString($expression, label: '$suggestedName'))",
      );
    }
    if (type is ConvexArrayType) {
      final item = mapType(
        type.value,
        suggestedName: '${suggestedName}Item',
        context: context,
      );
      return MappedType(
        dartType: DartListType(item.dartType),
        encode: (expression) =>
            '$expression.map((item) => ${item.encode('item')}).toList()',
        decode: (expression) =>
            'expectList($expression, label: \'$suggestedName\')'
            '.map((item) => ${item.decode('item')}).toList()',
      );
    }
    if (type is ConvexRecordType) {
      if (type.keys is! ConvexStringType) {
        context.warnings.add(
          'Record keys for "$suggestedName" are not strings. Falling back to '
          'Map<String, dynamic>.',
        );
        return MappedType(
          dartType: const DartMapType(
            keyType: DartPrimitiveType('String'),
            valueType: DartPrimitiveType('dynamic'),
          ),
          encode: (expression) => expression,
          decode: (expression) =>
              "expectMap($expression, label: '$suggestedName')",
        );
      }
      final value = mapType(
        type.values.fieldType,
        suggestedName: '${suggestedName}Value',
        context: context,
      );
      return MappedType(
        dartType: DartMapType(
          keyType: const DartPrimitiveType('String'),
          valueType: value.dartType,
        ),
        encode: (expression) =>
            "$expression.map((key, value) => MapEntry(key, ${value.encode('value')}))",
        decode: (expression) =>
            "expectMap($expression, label: '$suggestedName')"
            ".map((key, value) => MapEntry(key, ${value.decode('value')}))",
      );
    }
    if (type is ConvexObjectType) {
      if (type.value.isEmpty) {
        context.warnings.add(
          'Empty object type for "$suggestedName" was generated as '
          'Map<String, dynamic>.',
        );
        return MappedType(
          dartType: const DartMapType(
            keyType: DartPrimitiveType('String'),
            valueType: DartPrimitiveType('dynamic'),
          ),
          encode: (expression) => expression,
          decode: (expression) =>
              "expectMap($expression, label: '$suggestedName')",
        );
      }
      final typeName = context.reserveTypeName(suggestedName);

      // Detect field name collisions before generating code.
      final safeNameToRaw = <String, List<String>>{};
      for (final rawName in type.value.keys) {
        final safeName = _naming.fieldName(rawName);
        (safeNameToRaw[safeName] ??= <String>[]).add(rawName);
      }
      for (final entry in safeNameToRaw.entries) {
        if (entry.value.length > 1) {
          throw TypeMapperException(
            'Field name collision in "$typeName": fields '
            '${entry.value.map((name) => '"$name"').join(', ')} '
            'all map to Dart name "${entry.key}".',
          );
        }
      }

      final fields = <DartRecordField>[];
      final encodeBuffer = StringBuffer('<String, dynamic>{');
      final decodeBuffer = StringBuffer(
        '$typeName _decode$typeName(dynamic raw) {\n'
        "  final map = expectMap(raw, label: '$typeName');\n"
        '  return (\n',
      );

      for (final entry in type.value.entries) {
        final rawName = entry.key;
        final escapedName = _escapeStringLiteral(rawName);
        final safeName = _naming.fieldName(rawName);
        final field = entry.value;
        final mappedField = mapType(
          field.fieldType,
          suggestedName: '$typeName${_naming.typeName(rawName)}',
          context: context,
        );
        final fieldType = field.optional
            ? DartNamedType('Optional<${mappedField.annotation}>')
            : mappedField.dartType;
        fields.add(DartRecordField(name: safeName, type: fieldType));
        if (field.optional) {
          encodeBuffer.write(
            "if ($safeName.isDefined) '$escapedName': "
            "${mappedField.encode('$safeName.value')},",
          );
          decodeBuffer.writeln(
            "    $safeName: map.containsKey('$escapedName')"
            " ? Optional.of(${mappedField.decode("map['$escapedName']")})"
            " : const Optional.absent(),",
          );
        } else {
          encodeBuffer.write(
            "'$escapedName': ${mappedField.encode(safeName)},",
          );
          decodeBuffer.writeln(
            "    $safeName: ${mappedField.decode("map['$escapedName']")},",
          );
        }
      }

      encodeBuffer.write('}');
      decodeBuffer
        ..writeln('  );')
        ..write('}');

      final typedef = DartRecordType(fields);
      context.addDefinition(
          typeName, 'typedef $typeName = ${typedef.annotation};');
      context.addDefinition(
        '_encode$typeName',
        'Map<String, dynamic> _encode$typeName($typeName value) {\n'
            '  final (${fields.map((field) => '${field.name}: ${field.name}').join(', ')}) = value;\n'
            '  return ${encodeBuffer.toString()};\n'
            '}',
      );
      context.addDefinition('_decode$typeName', decodeBuffer.toString());
      return MappedType(
        dartType: DartNamedType(typeName),
        encode: (expression) => '_encode$typeName($expression)',
        decode: (expression) => '_decode$typeName($expression)',
      );
    }
    if (type is ConvexUnionType) {
      return _mapUnion(type, suggestedName: suggestedName, context: context);
    }
    throw TypeMapperException('Unsupported Convex type "${type.type}"');
  }

  MappedType _mapUnion(
    ConvexUnionType union, {
    required String suggestedName,
    required TypeRenderContext context,
  }) {
    final nullable = union.value.any((type) => type is ConvexNullType);
    final nonNull =
        union.value.where((type) => type is! ConvexNullType).toList();
    if (nonNull.length == 1) {
      final inner = mapType(
        nonNull.single,
        suggestedName: suggestedName,
        context: context,
      );
      if (!nullable) {
        return inner;
      }
      return MappedType(
        dartType: DartNullableType(inner.dartType),
        encode: (expression) =>
            '$expression == null ? null : ${inner.encode(expression)}',
        decode: (expression) =>
            '$expression == null ? null : ${inner.decode(expression)}',
      );
    }

    if (nonNull.every((type) => type is ConvexLiteralType)) {
      final typeName = context.reserveTypeName(suggestedName);
      final literals = nonNull.cast<ConvexLiteralType>();

      // Compute enum value names and deduplicate collisions.
      final enumNames = <String>[];
      for (var index = 0; index < literals.length; index += 1) {
        enumNames.add(_naming.enumValueName(literals[index].value, index));
      }
      final seen = <String, int>{};
      for (var i = 0; i < enumNames.length; i += 1) {
        final name = enumNames[i];
        if (seen.containsKey(name)) {
          // Rename all occurrences with index suffix.
          for (var j = 0; j < enumNames.length; j += 1) {
            if (enumNames[j] == name) {
              enumNames[j] = '$name$j';
            }
          }
        }
        seen[name] = i;
      }

      final enumBuffer = StringBuffer('enum $typeName {\n');
      for (var index = 0; index < literals.length; index += 1) {
        final literal = literals[index];
        enumBuffer.writeln(
          "  ${enumNames[index]}"
          "(${_literalCode(literal.value)}),",
        );
      }
      enumBuffer
        ..writeln(';')
        ..writeln()
        ..writeln('  const $typeName(this.value);')
        ..writeln('  final Object? value;')
        ..writeln()
        ..writeln('  static $typeName fromJson(dynamic raw) {')
        ..writeln('    switch (raw) {');
      for (var index = 0; index < literals.length; index += 1) {
        final literal = literals[index];
        enumBuffer.writeln(
          "      case ${_literalCode(literal.value)}:"
          " return $typeName.${enumNames[index]};",
        );
      }
      enumBuffer
        ..writeln('      default:')
        ..writeln(
          "        throw FormatException('Expected one of ${literals.map((literal) => literal.value).join(', ')} for $typeName');",
        )
        ..writeln('    }')
        ..writeln('  }')
        ..write('}');
      context.addDefinition(typeName, enumBuffer.toString());
      final dartType = nullable
          ? DartNullableType(DartNamedType(typeName))
          : DartNamedType(typeName);
      return MappedType(
        dartType: dartType,
        encode: (expression) =>
            nullable ? '$expression?.value' : '$expression.value',
        decode: (expression) => nullable
            ? '$expression == null ? null : $typeName.fromJson($expression)'
            : '$typeName.fromJson($expression)',
      );
    }

    final typeName = context.reserveTypeName(suggestedName);
    final cases = <_UnionCase>[];
    final buffer = StringBuffer('sealed class $typeName {\n');
    buffer.writeln('  const $typeName();');
    buffer.writeln('}');
    buffer.writeln();

    for (var index = 0; index < nonNull.length; index += 1) {
      final member = nonNull[index];
      final mappedMember = mapType(
        member,
        suggestedName: '$typeName${index + 1}',
        context: context,
      );
      final caseName = '$typeName${index + 1}Value';
      cases.add(
        _UnionCase(
          className: caseName,
          mappedType: mappedMember,
        ),
      );
      buffer
        ..writeln('class $caseName extends $typeName {')
        ..writeln('  const $caseName(this.value);')
        ..writeln('  final ${mappedMember.annotation} value;')
        ..writeln('}')
        ..writeln();
    }

    context.addDefinition(typeName, buffer.toString().trimRight());
    context.addDefinition(
      '_encode$typeName',
      _renderUnionEncode(typeName, cases),
    );
    context.addDefinition(
      '_decode$typeName',
      _renderUnionDecode(typeName, cases),
    );

    final dartType = nullable
        ? DartNullableType(DartNamedType(typeName))
        : DartNamedType(typeName);
    return MappedType(
      dartType: dartType,
      encode: (expression) => nullable
          ? '$expression == null ? null : _encode$typeName($expression)'
          : '_encode$typeName($expression)',
      decode: (expression) => nullable
          ? '$expression == null ? null : _decode$typeName($expression)'
          : '_decode$typeName($expression)',
    );
  }

  String _renderUnionEncode(String typeName, List<_UnionCase> cases) {
    final buffer =
        StringBuffer('dynamic _encode$typeName($typeName value) {\n');
    buffer.writeln('  switch (value) {');
    for (final unionCase in cases) {
      buffer.writeln(
        '    case ${unionCase.className}(value: final inner):'
        ' return ${unionCase.mappedType.encode('inner')};',
      );
    }
    buffer
      ..writeln('  }')
      ..write('}');
    return buffer.toString();
  }

  String _renderUnionDecode(String typeName, List<_UnionCase> cases) {
    final buffer = StringBuffer('$typeName _decode$typeName(dynamic raw) {\n');
    buffer.writeln('  final errors = <String>[];');
    for (final unionCase in cases) {
      buffer
        ..writeln('  try {')
        ..writeln(
          '    return ${unionCase.className}'
          '(${unionCase.mappedType.decode('raw')});',
        )
        ..writeln(
            "  } catch (e) { errors.add('${unionCase.className}: \$e'); }");
    }
    buffer
      ..writeln(
        "  throw FormatException("
        "'Expected $typeName but received \${describeType(raw)}.\\n'"
        "    'Tried: \${errors.join(\", \")}');",
      )
      ..write('}');
    return buffer.toString();
  }

  DartType _literalDartType(Object? value) {
    if (value == null) {
      return const DartPrimitiveType('Null');
    }
    if (value is bool) {
      return const DartPrimitiveType('bool');
    }
    if (value is num) {
      return const DartPrimitiveType('double');
    }
    if (value is String) {
      return const DartPrimitiveType('String');
    }
    throw TypeMapperException('Unsupported literal value "$value"');
  }

  String _literalCode(Object? value) {
    if (value == null) {
      return 'null';
    }
    if (value is String) {
      return "'${_escapeStringLiteral(value)}'";
    }
    if (value is num) {
      return value.toDouble().toString();
    }
    if (value is bool) {
      return value.toString();
    }
    throw TypeMapperException('Unsupported literal value "$value"');
  }

  static String _escapeStringLiteral(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r')
        .replaceAll('\t', r'\t')
        .replaceAll(r'$', r'\$')
        .replaceAll('\x00', r'\0');
  }
}

class _UnionCase {
  const _UnionCase({
    required this.className,
    required this.mappedType,
  });

  final String className;
  final MappedType mappedType;
}
