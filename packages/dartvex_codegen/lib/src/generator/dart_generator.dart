import 'package:dart_style/dart_style.dart';

import '../spec/function_spec.dart';
import '../types/type_mapper.dart';
import 'imports.dart';
import 'naming.dart';

const generatedFileHeader = '// GENERATED CODE - DO NOT MODIFY BY HAND.';

class GeneratedOutput {
  const GeneratedOutput({
    required this.files,
    required this.warnings,
  });

  final Map<String, String> files;
  final List<String> warnings;
}

class DartGenerator {
  DartGenerator({
    Naming? naming,
    this.clientImport = 'package:dartvex/dartvex.dart',
  }) : _naming = naming ?? const Naming();

  final Naming _naming;
  final String clientImport;

  GeneratedOutput generate(FunctionsSpec spec) {
    final warnings = <String>[];
    final root = _buildTree(spec);
    final files = <String, String>{};

    files['runtime.dart'] =
        _formatIfPossible(_buildRuntimeFile(), 'runtime.dart', warnings);

    for (final node in _flattenNodes(root)) {
      if (node.pathSegments.isEmpty) {
        files['api.dart'] = _formatIfPossible(
            _renderNode(node, isRoot: true), 'api.dart', warnings);
      } else {
        final filePath = 'modules/${node.pathSegments.join('/')}.dart';
        files[filePath] = _formatIfPossible(
            _renderNode(node, isRoot: false), filePath, warnings);
      }
      warnings.addAll(node.renderWarnings);
      warnings.addAll(node.typeWarnings);
    }

    files['schema.dart'] = _formatIfPossible(
        _buildSchemaFile(root.tableNames), 'schema.dart', warnings);
    warnings.addAll(root.warnings);
    return GeneratedOutput(files: files, warnings: warnings);
  }

  _ModuleNode _buildTree(FunctionsSpec spec) {
    final root = _ModuleNode(pathSegments: const <String>[]);
    final publicFunctions = spec.publicFunctions.toList()
      ..sort((left, right) => left.identifier.compareTo(right.identifier));

    for (final baseFunction in spec.functions) {
      if (baseFunction is HttpFunctionSpec) {
        root.warnings.add(
          'Skipping HTTP action ${baseFunction.method} ${baseFunction.path}; '
          'this generator currently targets queries, mutations, and actions.',
        );
      }
    }

    for (final function in publicFunctions) {
      var node = root;
      for (final segment in function.modulePathSegments) {
        node = node.children.putIfAbsent(
          segment,
          () => _ModuleNode(
              pathSegments: <String>[...node.pathSegments, segment]),
        );
      }
      node.functions.add(function);
    }

    _collectTableNames(root);
    return root;
  }

  void _collectTableNames(_ModuleNode node) {
    for (final function in node.functions) {
      final typeContext = TypeRenderContext(naming: _naming);
      final mapper = TypeMapper(naming: _naming);
      mapper.mapType(
        function.returns,
        suggestedName: '${_naming.typeName(function.functionName)}Result',
        context: typeContext,
      );
      if (function.args is ConvexObjectType) {
        final argsObject = function.args as ConvexObjectType;
        for (final entry in argsObject.value.entries) {
          mapper.mapType(
            entry.value.fieldType,
            suggestedName:
                '${_naming.typeName(function.functionName)}${_naming.typeName(entry.key)}',
            context: typeContext,
          );
        }
      }
      node.tableNames.addAll(typeContext.tableNames);
    }
    for (final child in node.children.values) {
      _collectTableNames(child);
      node.tableNames.addAll(child.tableNames);
      node.warnings.addAll(child.warnings);
    }
  }

  Iterable<_ModuleNode> _flattenNodes(_ModuleNode root) sync* {
    yield root;
    final children = root.children.values.toList()
      ..sort(
        (left, right) =>
            left.pathSegments.join('/').compareTo(right.pathSegments.join('/')),
      );
    for (final child in children) {
      yield* _flattenNodes(child);
    }
  }

  String _renderNode(_ModuleNode node, {required bool isRoot}) {
    final filePath =
        isRoot ? 'api.dart' : 'modules/${node.pathSegments.join('/')}.dart';
    final imports = ImportManager()
      ..add(clientImport)
      ..add(_naming.relativeImport(
          fromFile: filePath, targetFile: 'runtime.dart'))
      ..add(_naming.relativeImport(
          fromFile: filePath, targetFile: 'schema.dart'));

    final childNodes = node.children.values.toList()
      ..sort(
        (left, right) =>
            left.pathSegments.last.compareTo(right.pathSegments.last),
      );
    for (final child in childNodes) {
      final target = 'modules/${child.pathSegments.join('/')}.dart';
      imports.add(
        _naming.relativeImport(fromFile: filePath, targetFile: target),
      );
    }

    final typeContext = TypeRenderContext(naming: _naming);
    final methods = <String>[];
    final helpers = <String>[];
    for (final function in node.functions) {
      final rendered = _renderFunction(
        function,
        context: typeContext,
      );
      methods.add(rendered.methods);
      helpers.add(rendered.helpers);
    }
    node.typeWarnings = typeContext.warnings;

    if (typeContext.usesTypedData) {
      imports.add('dart:typed_data');
    }

    final buffer = StringBuffer()
      ..writeln(generatedFileHeader)
      ..writeln()
      ..writeln(imports.render())
      ..writeln();

    if (isRoot) {
      buffer
        ..writeln("export 'runtime.dart';")
        ..writeln("export 'schema.dart';")
        ..writeln();
    }

    final className = _naming.moduleClassName(node.pathSegments);
    buffer
      ..writeln('class $className {')
      ..writeln('  const $className(this._client);')
      ..writeln()
      ..writeln('  final ConvexFunctionCaller _client;')
      ..writeln();

    for (final child in childNodes) {
      final childClass = _naming.moduleClassName(child.pathSegments);
      final getterName = _naming.moduleGetterName(child.pathSegments.last);
      buffer.writeln('  $childClass get $getterName => $childClass(_client);');
    }
    if (childNodes.isNotEmpty && methods.isNotEmpty) {
      buffer.writeln();
    }
    for (final method in methods) {
      buffer
        ..writeln(_indent(method.trimRight(), 2))
        ..writeln();
    }
    if (buffer.toString().endsWith('\n\n')) {
      buffer.write('');
    }
    buffer.writeln('}');

    final definitions = typeContext.renderDefinitions();
    if (definitions.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(definitions);
    }
    for (final helper in helpers.where((helper) => helper.isNotEmpty)) {
      buffer
        ..writeln()
        ..writeln(helper.trimRight());
    }
    return '${buffer.toString().trimRight()}\n';
  }

  _RenderedFunction _renderFunction(
    FunctionSpec function, {
    required TypeRenderContext context,
  }) {
    final mapper = TypeMapper(naming: _naming);
    final functionPrefix = _naming.typeName(function.functionName);
    final resultType = mapper.mapType(
      function.returns,
      suggestedName: '${functionPrefix}Result',
      context: context,
    );

    final argsType = function.args;
    final methodName = _naming.methodName(function.functionName);
    final operation = switch (function.functionType) {
      'Query' => 'query',
      'Mutation' => 'mutate',
      'Action' => 'action',
      _ =>
        throw StateError('Unsupported function type ${function.functionType}'),
    };

    final methodBuffer = StringBuffer();
    final helperBuffer = StringBuffer();
    var requestArgsExpression = 'const <String, dynamic>{}';
    String signature;

    if (argsType is ConvexObjectType && argsType.value.isNotEmpty) {
      final argsObject = mapper.mapType(
        argsType,
        suggestedName: '${functionPrefix}Args',
        context: context,
      );
      final argsFields = <String>[];
      final recordAssignments = <String>[];
      for (final entry in argsType.value.entries) {
        final fieldName = _naming.fieldName(entry.key);
        final mappedField = mapper.mapType(
          entry.value.fieldType,
          suggestedName: '${functionPrefix}Args${_naming.typeName(entry.key)}',
          context: context,
        );
        if (entry.value.optional) {
          argsFields.add(
            'Optional<${mappedField.annotation}> '
            '$fieldName = const Optional.absent()',
          );
        } else {
          argsFields.add('required ${mappedField.annotation} $fieldName');
        }
        recordAssignments.add('$fieldName: $fieldName');
      }
      requestArgsExpression =
          argsObject.encode('(${recordAssignments.join(', ')})');
      signature = '{${argsFields.join(', ')}}';
    } else if (argsType is ConvexObjectType && argsType.value.isEmpty) {
      signature = '';
    } else if (argsType is ConvexAnyType) {
      signature = '[Map<String, dynamic> args = const <String, dynamic>{}]';
      requestArgsExpression = 'args';
    } else {
      throw StateError(
        'Top-level arguments for ${function.identifier} must be an object or any',
      );
    }

    methodBuffer
      ..write('Future<${resultType.annotation}> $methodName(')
      ..write(signature)
      ..writeln(') async {')
      ..writeln(
        "  final raw = await _client.$operation("
        "'${function.convexFunctionName}', $requestArgsExpression);",
      )
      ..writeln('  return ${resultType.decode('raw')};')
      ..writeln('}');

    if (function.functionType == 'Query') {
      methodBuffer
        ..writeln()
        ..write(
          'TypedConvexSubscription<${resultType.annotation}> '
          '${methodName}Subscribe(',
        )
        ..write(signature)
        ..writeln(') {')
        ..writeln(
          "  final subscription = _client.subscribe("
          "'${function.convexFunctionName}', $requestArgsExpression);",
        )
        ..writeln(
          '  final typedStream = subscription.stream.map((event) => switch (event) {',
        )
        ..writeln(
          '    QuerySuccess(:final value) => '
          'TypedQuerySuccess<${resultType.annotation}>(${resultType.decode('value')}),',
        )
        ..writeln(
          '    QueryError(:final message) => '
          'TypedQueryError<${resultType.annotation}>(message),',
        )
        ..writeln('  });')
        ..writeln(
          '  return TypedConvexSubscription<${resultType.annotation}>('
          'subscription, typedStream);',
        )
        ..writeln('}');
    }

    return _RenderedFunction(
      methods: methodBuffer.toString(),
      helpers: helperBuffer.toString(),
    );
  }

  String _buildSchemaFile(Set<String> tables) {
    final sortedTables = tables.toList()..sort();
    final buffer = StringBuffer()
      ..writeln(generatedFileHeader)
      ..writeln()
      ..writeln("import 'runtime.dart';")
      ..writeln();

    for (final table in sortedTables) {
      final typeName = '${_naming.typeName(table)}Id';
      buffer
        ..writeln('class $typeName extends ConvexTableId {')
        ..writeln('  const $typeName(super.value);')
        ..writeln()
        ..writeln("  static const String tableName = '$table';")
        ..writeln('}')
        ..writeln();
    }
    return '${buffer.toString().trimRight()}\n';
  }

  String _buildRuntimeFile() {
    return '''
$generatedFileHeader

import 'dart:async';
import 'dart:typed_data';

import '$clientImport';

abstract class ConvexTableId {
  const ConvexTableId(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType &&
      other is ConvexTableId &&
      other.value == value;

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => value;
}

sealed class Optional<T> {
  const Optional();

  const factory Optional.absent() = _OptionalAbsent<T>;
  const factory Optional.of(T value) = _OptionalValue<T>;

  bool get isDefined;
  T get value;
  T? get valueOrNull;
}

class _OptionalAbsent<T> extends Optional<T> {
  const _OptionalAbsent();

  @override
  bool get isDefined => false;

  @override
  T get value => throw StateError('Optional value is absent');

  @override
  T? get valueOrNull => null;

  @override
  bool operator ==(Object other) => other is _OptionalAbsent<T>;

  @override
  int get hashCode => T.hashCode;
}

class _OptionalValue<T> extends Optional<T> {
  const _OptionalValue(this.value);

  @override
  final T value;

  @override
  bool get isDefined => true;

  @override
  T get valueOrNull => value;

  @override
  bool operator ==(Object other) =>
      other is _OptionalValue<T> && other.value == value;

  @override
  int get hashCode => Object.hash(T, value);
}

sealed class TypedQueryResult<T> {
  const TypedQueryResult();
}

class TypedQuerySuccess<T> extends TypedQueryResult<T> {
  const TypedQuerySuccess(this.value);

  final T value;
}

class TypedQueryError<T> extends TypedQueryResult<T> {
  const TypedQueryError(this.message);

  final String message;
}

class TypedConvexSubscription<T> {
  const TypedConvexSubscription(this._delegate, this.stream);

  final ConvexSubscription _delegate;
  final Stream<TypedQueryResult<T>> stream;

  void cancel() {
    _delegate.cancel();
  }
}

Map<String, dynamic> expectMap(dynamic value, {String? label}) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.cast<String, dynamic>();
  }
  throw FormatException('Expected \${label ?? 'object'}, got \${describeType(value)}');
}

List<dynamic> expectList(dynamic value, {String? label}) {
  if (value is List<dynamic>) {
    return value;
  }
  if (value is List) {
    return value.cast<dynamic>();
  }
  throw FormatException('Expected \${label ?? 'list'}, got \${describeType(value)}');
}

String expectString(dynamic value, {String? label}) {
  if (value is String) {
    return value;
  }
  throw FormatException('Expected \${label ?? 'string'}, got \${describeType(value)}');
}

bool expectBool(dynamic value, {String? label}) {
  if (value is bool) {
    return value;
  }
  throw FormatException('Expected \${label ?? 'bool'}, got \${describeType(value)}');
}

double expectDouble(dynamic value, {String? label}) {
  if (value is num) {
    return value.toDouble();
  }
  throw FormatException('Expected \${label ?? 'number'}, got \${describeType(value)}');
}

BigInt expectBigInt(dynamic value, {String? label}) {
  if (value is BigInt) {
    return value;
  }
  throw FormatException('Expected \${label ?? 'bigint'}, got \${describeType(value)}');
}

Uint8List expectBytes(dynamic value, {String? label}) {
  if (value is Uint8List) {
    return value;
  }
  throw FormatException('Expected \${label ?? 'bytes'}, got \${describeType(value)}');
}

T expectLiteral<T>(dynamic value, T expected, {String? label}) {
  if (value == expected) {
    return expected;
  }
  throw FormatException(
    'Expected \${label ?? 'literal'} value \$expected, got \${describeType(value)}',
  );
}

String describeType(dynamic value) {
  if (value == null) {
    return 'null';
  }
  return value.runtimeType.toString();
}
''';
  }

  String _formatIfPossible(
      String source, String filePath, List<String> warnings) {
    try {
      return DartFormatter(
        languageVersion: DartFormatter.latestLanguageVersion,
      ).format(source);
    } catch (e) {
      warnings.add('Generated code for "$filePath" could not be formatted: $e');
      return source;
    }
  }

  String _indent(String source, int spaces) {
    final prefix = ' ' * spaces;
    return source
        .split('\n')
        .map((line) => line.isEmpty ? line : '$prefix$line')
        .join('\n');
  }
}

class _ModuleNode {
  _ModuleNode({required this.pathSegments});

  final List<String> pathSegments;
  final Map<String, _ModuleNode> children = <String, _ModuleNode>{};
  final List<FunctionSpec> functions = <FunctionSpec>[];
  final Set<String> tableNames = <String>{};
  final List<String> warnings = <String>[];
  List<String> renderWarnings = <String>[];
  List<String> typeWarnings = <String>[];
}

class _RenderedFunction {
  const _RenderedFunction({
    required this.methods,
    required this.helpers,
  });

  final String methods;
  final String helpers;
}
