import 'package:dart_style/dart_style.dart';

import '../spec/function_spec.dart';
import '../types/type_mapper.dart';
import 'imports.dart';
import 'naming.dart';
import 'string_literals.dart';

/// File header added to every generated Dart binding.
const generatedFileHeader = '// GENERATED CODE - DO NOT MODIFY BY HAND.';

/// Result of a single code generation pass.
class GeneratedOutput {
  /// Creates generated output metadata.
  const GeneratedOutput({
    required this.files,
    required this.warnings,
  });

  /// Generated file contents keyed by relative output path.
  final Map<String, String> files;

  /// Non-fatal warnings emitted while generating types or modules.
  final List<String> warnings;
}

/// Thrown when generated Dart source cannot be emitted safely.
class GenerationException implements Exception {
  /// Creates a generation error.
  GenerationException(this.message);

  /// Human-readable failure details.
  final String message;

  @override
  String toString() => message;
}

/// Generates typed Dart API bindings from a Convex function spec.
class DartGenerator {
  /// Creates a generator with optional naming overrides and client import path.
  DartGenerator({
    Naming? naming,
    this.clientImport = 'package:dartvex/dartvex.dart',
  }) : _naming = naming ?? const Naming();

  final Naming _naming;

  /// The import used for the generated runtime client dependency in modules.
  final String clientImport;

  /// Generates the runtime, API modules, and schema types for [spec].
  GeneratedOutput generate(FunctionsSpec spec) {
    final warnings = <String>[...spec.warnings];
    final root = _buildTree(spec);
    final files = <String, String>{};

    files['runtime.dart'] = _formatOrThrow(_buildRuntimeFile(), 'runtime.dart');

    for (final node in _flattenNodes(root)) {
      if (node.pathSegments.isEmpty) {
        files['api.dart'] =
            _formatOrThrow(_renderNode(node, isRoot: true), 'api.dart');
      } else {
        final filePath = _moduleFilePath(node);
        files[filePath] =
            _formatOrThrow(_renderNode(node, isRoot: false), filePath);
      }
      warnings.addAll(node.renderWarnings);
      warnings.addAll(node.typeWarnings);
    }

    files['schema.dart'] =
        _formatOrThrow(_buildSchemaFile(root.tableNames), 'schema.dart');
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
        _validateModulePathSegment(segment, function.identifier);
        node = node.children.putIfAbsent(
          segment,
          () => _ModuleNode(
              pathSegments: <String>[...node.pathSegments, segment]),
        );
      }
      node.functions.add(function);
    }

    _collectTableNames(root);
    _validateGeneratedMembers(root);
    return root;
  }

  void _validateGeneratedMembers(_ModuleNode root) {
    for (final node in _flattenNodes(root)) {
      final members = <String, String>{};
      final className = _naming.moduleClassName(node.pathSegments);

      void addMember(String memberName, String description) {
        final existing = members[memberName];
        if (existing != null) {
          throw NamingException(
            'Generated member name collision in $className: "$memberName" '
            'is used by $existing and $description. Rename one of the '
            'Convex functions or modules.',
          );
        }
        members[memberName] = description;
      }

      for (final child in node.children.values) {
        addMember(
          _naming.moduleGetterName(child.pathSegments.last),
          'module "${child.pathSegments.join('/')}"',
        );
      }
      for (final function in node.functions) {
        final methodName = _naming.methodName(function.functionName);
        addMember(methodName, 'function "${function.identifier}"');
        // Paginated queries emit a single wrapper method, no Subscribe
        // helper; reserving one would reject names that never collide.
        if (function.functionType == 'Query' &&
            _detectPagination(function) == null) {
          addMember(
            '${methodName}Subscribe',
            'subscription helper for "${function.identifier}"',
          );
        }
      }
    }
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
    final filePath = isRoot ? 'api.dart' : _moduleFilePath(node);
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
      final target = _moduleFilePath(child);
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
    final pagination =
        _detectPagination(function, onSkip: context.warnings.add);
    if (pagination != null) {
      return _renderPaginatedQuery(function, pagination, context: context);
    }

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

    // Generated locals carry a `$` suffix: sanitized Convex argument names can
    // never contain `$`, so a user argument named `raw`, `subscription`, or
    // `query` cannot collide with (and shadow) a generated local.
    methodBuffer
      ..write('Future<${resultType.annotation}> $methodName(')
      ..write(signature)
      ..writeln(') async {');
    final decodeExpression = resultType.decode(r'raw$');
    if (decodeExpression == 'null') {
      // A `v.null()` return needs no decode; skip the binding so the
      // generated method does not hold an unused local.
      methodBuffer
        ..writeln(
          "  await _client.$operation("
          '${dartSingleQuotedString(function.convexFunctionName)}, '
          '$requestArgsExpression);',
        )
        ..writeln('  return null;')
        ..writeln('}');
    } else {
      methodBuffer
        ..writeln(
          "  final raw\$ = await _client.$operation("
          '${dartSingleQuotedString(function.convexFunctionName)}, '
          '$requestArgsExpression);',
        )
        ..writeln('  return $decodeExpression;')
        ..writeln('}');
    }

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
          "  final subscription\$ = _client.subscribe("
          '${dartSingleQuotedString(function.convexFunctionName)}, '
          '$requestArgsExpression);',
        )
        ..writeln(
          '  final typedStream\$ = subscription\$.stream.map((event) {',
        )
        ..writeln(
          '    switch (event) {',
        )
        ..writeln(
          '      case QuerySuccess(:final value):',
        )
        ..writeln(
          '        return TypedQuerySuccess<${resultType.annotation}>(${resultType.decode('value')});',
        )
        ..writeln(
          '      case QueryLoading(:final hasPendingWrites):',
        )
        ..writeln(
          '        return TypedQueryLoading<${resultType.annotation}>('
          'hasPendingWrites: hasPendingWrites);',
        )
        ..writeln(
          '      case QueryError(:final message, :final data, :final logLines):',
        )
        ..writeln(
          '        return TypedQueryError<${resultType.annotation}>('
          'message, data: data, logLines: logLines);',
        )
        ..writeln('    }')
        ..writeln('  });')
        ..writeln(
          '  return TypedConvexSubscription<${resultType.annotation}>('
          'subscription\$, typedStream\$);',
        )
        ..writeln('}');
    }

    return _RenderedFunction(
      methods: methodBuffer.toString(),
      helpers: helperBuffer.toString(),
    );
  }

  /// Detects whether [function] is a Convex paginated query and, if so, returns
  /// the page element type and the non-`paginationOpts` arguments.
  ///
  /// A function paginates when it is a `Query` whose args carry a
  /// `paginationOpts` field (an object with `numItems`/`cursor`, or `any`) and
  /// whose returns is either a `PaginationResult` object (`page` array,
  /// `isDone`, `continueCursor`) or has no validator at all. A returns-less
  /// paginated query still generates a typed wrapper, just over
  /// `Map<String, dynamic>` page items.
  ///
  /// [onSkip] is invoked with a diagnostic when a function that would paginate
  /// is demoted to a plain query method (an argument would collide with the
  /// generated `pageSize` parameter).
  _PaginationInfo? _detectPagination(
    FunctionSpec function, {
    void Function(String warning)? onSkip,
  }) {
    if (function.functionType != 'Query') {
      return null;
    }
    final args = function.args;
    if (args is! ConvexObjectType) {
      return null;
    }
    final paginationOpts = args.value['paginationOpts'];
    if (paginationOpts == null) {
      return null;
    }
    final optsType = paginationOpts.fieldType;
    if (optsType is ConvexObjectType) {
      if (!(optsType.value.containsKey('numItems') &&
          optsType.value.containsKey('cursor'))) {
        return null;
      }
    } else if (optsType is! ConvexAnyType) {
      return null;
    }

    final returns = function.returns;
    final ConvexType? elementType;
    if (returns is ConvexAnyType) {
      // No returns validator: paginate with untyped page items.
      elementType = null;
    } else if (returns is ConvexObjectType) {
      final page = returns.value['page'];
      final pageType = page?.fieldType;
      if (page == null ||
          pageType is! ConvexArrayType ||
          !returns.value.containsKey('isDone') ||
          !returns.value.containsKey('continueCursor')) {
        // Not a PaginationResult shape; fall back to a normal query method.
        return null;
      }
      elementType = pageType.value;
    } else {
      return null;
    }

    final otherArgs = <String, ConvexField>{
      for (final entry in args.value.entries)
        if (entry.key != 'paginationOpts') entry.key: entry.value,
    };
    if (otherArgs.keys.any((key) => _naming.fieldName(key) == 'pageSize')) {
      // The paginated wrapper exposes its own `pageSize` parameter; a user
      // argument with that (sanitized) name would declare it twice. Fall back
      // to a plain query method, which still exposes paginationOpts directly.
      onSkip?.call(
        'Function "${function.identifier}" looks paginated but has an '
        'argument that collides with the generated "pageSize" parameter; '
        'generated as a plain query method instead.',
      );
      return null;
    }
    return _PaginationInfo(elementType: elementType, otherArgs: otherArgs);
  }

  _RenderedFunction _renderPaginatedQuery(
    FunctionSpec function,
    _PaginationInfo info, {
    required TypeRenderContext context,
  }) {
    final mapper = TypeMapper(naming: _naming);
    final functionPrefix = _naming.typeName(function.functionName);
    final methodName = _naming.methodName(function.functionName);

    final String elementAnnotation;
    final String elementDecode;
    final elementType = info.elementType;
    if (elementType == null) {
      elementAnnotation = 'Map<String, dynamic>';
      elementDecode = "expectMap(raw, label: '${functionPrefix}PageItem')";
    } else {
      final mappedElement = mapper.mapType(
        elementType,
        suggestedName: '${functionPrefix}PageItem',
        context: context,
      );
      elementAnnotation = mappedElement.annotation;
      elementDecode = mappedElement.decode('raw');
    }

    final argsFields = <String>[];
    final argsMapEntries = <String>[];
    for (final entry in info.otherArgs.entries) {
      final fieldKey = dartSingleQuotedString(entry.key);
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
        argsMapEntries.add(
          'if ($fieldName.isDefined) $fieldKey: '
          "${mappedField.encode('$fieldName.value')},",
        );
      } else {
        argsFields.add('required ${mappedField.annotation} $fieldName');
        argsMapEntries.add('$fieldKey: ${mappedField.encode(fieldName)},');
      }
    }

    final signature = <String>[...argsFields, 'int pageSize = 20'].join(', ');
    final argsMap = argsMapEntries.isEmpty
        ? 'const <String, dynamic>{}'
        : '<String, dynamic>{${argsMapEntries.join(' ')}}';

    final methodBuffer = StringBuffer()
      ..writeln(
        'TypedConvexPaginatedQuery<$elementAnnotation> '
        '$methodName({$signature}) {',
      )
      // No intermediate local: a user argument named `query` must stay
      // referencable inside the args map below.
      ..writeln('  return TypedConvexPaginatedQuery<$elementAnnotation>(')
      ..writeln('    _client.paginatedQuery(')
      ..writeln('      ${dartSingleQuotedString(function.convexFunctionName)},')
      ..writeln('      $argsMap,')
      ..writeln('      pageSize: pageSize,')
      ..writeln('    ),')
      ..writeln('    (dynamic raw) => $elementDecode,')
      ..writeln('  );')
      ..write('}');

    return _RenderedFunction(
      methods: methodBuffer.toString(),
      helpers: '',
    );
  }

  String _buildSchemaFile(Set<String> tables) {
    final sortedTables = tables.toList()..sort();
    final tableIdClasses = <String, String>{};
    for (final table in sortedTables) {
      final typeName = '${_naming.typeName(table)}Id';
      final existingTable = tableIdClasses[typeName];
      if (existingTable != null) {
        throw NamingException(
          'Generated table ID class name collision: "$typeName" is used by '
          'tables "$existingTable" and "$table". Rename one of the Convex '
          'tables.',
        );
      }
      tableIdClasses[typeName] = table;
    }

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
        ..writeln(
          '  static const String tableName = '
          '${dartSingleQuotedString(table)};',
        )
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

class TypedQueryLoading<T> extends TypedQueryResult<T> {
  const TypedQueryLoading({this.hasPendingWrites = false});

  final bool hasPendingWrites;
}

class TypedQueryError<T> extends TypedQueryResult<T> {
  const TypedQueryError(
    this.message, {
    this.data,
    this.logLines = const <String>[],
  });

  final String message;
  final Object? data;
  final List<String> logLines;
}

class TypedConvexSubscription<T> {
  const TypedConvexSubscription(this._delegate, this.stream);

  final ConvexSubscription _delegate;
  final Stream<TypedQueryResult<T>> stream;

  void cancel() {
    _delegate.cancel();
  }
}

class TypedConvexPaginatedResult<T> {
  const TypedConvexPaginatedResult({
    required this.items,
    required this.status,
    required this.isDone,
    this.error,
  });

  final List<T> items;
  final ConvexPaginationStatus status;
  final bool isDone;
  final Object? error;
}

class TypedConvexPaginatedQuery<T> {
  TypedConvexPaginatedQuery(this._delegate, this._decode);

  final ConvexPaginatedQuery _delegate;
  final T Function(dynamic raw) _decode;

  Stream<TypedConvexPaginatedResult<T>> get stream =>
      _delegate.stream.map(_toTyped);

  TypedConvexPaginatedResult<T> get current => _toTyped(_delegate.current);

  List<T> get items => _delegate.current.results.map(_decode).toList();

  ConvexPaginationStatus get status => _delegate.status;

  bool get isDone => _delegate.isDone;

  bool loadMore([int? numItems]) => _delegate.loadMore(numItems);

  void cancel() {
    _delegate.cancel();
  }

  TypedConvexPaginatedResult<T> _toTyped(ConvexPaginatedResult result) {
    return TypedConvexPaginatedResult<T>(
      items: result.results.map(_decode).toList(),
      status: result.status,
      isDone: result.isDone,
      error: result.error,
    );
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

  String _formatOrThrow(String source, String filePath) {
    try {
      return DartFormatter(
        languageVersion: DartFormatter.latestLanguageVersion,
      ).format(source);
    } catch (e) {
      throw GenerationException(
        'Generated code for "$filePath" could not be formatted: $e',
      );
    }
  }

  String _moduleFilePath(_ModuleNode node) =>
      'modules/${node.pathSegments.join('/')}.dart';

  void _validateModulePathSegment(String segment, String identifier) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains('/') ||
        segment.contains(r'\')) {
      throw GenerationException(
        'Unsafe Convex module path segment "$segment" in "$identifier"; '
        'refusing to generate files outside the output directory.',
      );
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

/// Describes a detected paginated query: its page element type (or `null` for
/// an untyped, returns-less query) and its arguments minus `paginationOpts`.
class _PaginationInfo {
  _PaginationInfo({required this.elementType, required this.otherArgs});

  final ConvexType? elementType;
  final Map<String, ConvexField> otherArgs;
}
