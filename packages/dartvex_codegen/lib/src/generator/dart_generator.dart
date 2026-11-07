import 'package:dart_style/dart_style.dart';

import '../spec/function_spec.dart';
import '../types/type_mapper.dart';
import 'imports.dart';
import 'naming.dart';
import 'string_literals.dart';

/// File header added to every generated Dart binding.
const generatedFileHeader = '// GENERATED CODE - DO NOT MODIFY BY HAND.';

/// Analyzer suppressions emitted below the header of every generated file.
///
/// Generated bindings legitimately contain members a given consumer never
/// references (every object type ships both an encode and a decode helper,
/// and every module imports the shared runtime and schema), and consumers'
/// lint sets vary; without this line `dart analyze` fails on unused-element
/// warnings in projects that do not exclude the generated directory.
const generatedFileIgnores =
    '// ignore_for_file: type=lint, unused_element, unused_import, '
    'unused_local_variable';

/// Result of a single code generation pass.
class GeneratedOutput {
  /// Creates generated output metadata.
  const GeneratedOutput({required this.files, required this.warnings});

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
    final root = _buildTree(spec, warnings);
    final tableIdClassNames = _resolveTableIdClassNames(
      _collectTableNames(root),
    );
    final files = <String, String>{};

    files['runtime.dart'] = _formatOrThrow(_buildRuntimeFile(), 'runtime.dart');

    for (final node in _flattenNodes(root)) {
      final isRoot = node.pathSegments.isEmpty;
      final filePath = isRoot ? 'api.dart' : _moduleFilePath(node);
      final typeContext = TypeRenderContext(
        naming: _naming,
        tableIdClassNames: tableIdClassNames,
      );
      files[filePath] = _formatOrThrow(
        _renderNode(node, isRoot: isRoot, typeContext: typeContext),
        filePath,
      );
      warnings.addAll(typeContext.warnings);
    }

    files['schema.dart'] = _formatOrThrow(
      _buildSchemaFile(tableIdClassNames),
      'schema.dart',
    );
    return GeneratedOutput(files: files, warnings: warnings);
  }

  _ModuleNode _buildTree(FunctionsSpec spec, List<String> warnings) {
    final root = _ModuleNode(pathSegments: const <String>[]);
    final publicFunctions =
        spec.publicFunctions.toList()
          ..sort((left, right) => left.identifier.compareTo(right.identifier));

    for (final baseFunction in spec.functions) {
      if (baseFunction is HttpFunctionSpec) {
        warnings.add(
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
            pathSegments: <String>[...node.pathSegments, segment],
          ),
        );
      }
      node.functions.add(function);
    }

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

  /// Collects every table referenced by a `v.id(...)` in the public functions
  /// under [root].
  ///
  /// This is a pure walk over the validators: it does not map types, so it
  /// cannot disagree with the renderer about generated type names. Record
  /// keys are skipped because id-typed keys are generated as plain `String`
  /// map keys and never reference an ID class.
  Set<String> _collectTableNames(_ModuleNode root) {
    final tables = <String>{};
    void visit(ConvexType type) {
      switch (type) {
        case ConvexIdType(:final tableName):
          tables.add(tableName);
        case ConvexArrayType(:final value):
          visit(value);
        case ConvexRecordType(:final values):
          visit(values.fieldType);
        case ConvexObjectType(:final value):
          for (final field in value.values) {
            visit(field.fieldType);
          }
        case ConvexUnionType(:final value):
          value.forEach(visit);
        case ConvexAnyType() ||
            ConvexBooleanType() ||
            ConvexStringType() ||
            ConvexNumberType() ||
            ConvexNullType() ||
            ConvexBigIntType() ||
            ConvexCommitTsType() ||
            ConvexFunctionHandleType() ||
            ConvexBytesType() ||
            ConvexLiteralType():
          break;
      }
    }

    for (final node in _flattenNodes(root)) {
      for (final function in node.functions) {
        visit(function.returns);
        visit(function.args);
      }
    }
    return tables;
  }

  /// Assigns each table its generated `ConvexTableId` subclass name.
  ///
  /// System tables (`_storage`, `_scheduled_functions`) normally keep their
  /// short names (`StorageId`). When one sanitizes to the same class name as
  /// a user table (`storage`), the system table gets a `System` prefix
  /// (`SystemStorageId`) since system tables cannot be renamed. Any other
  /// collision throws a [NamingException].
  Map<String, String> _resolveTableIdClassNames(Set<String> tables) {
    final sortedTables = tables.toList()..sort();
    final byDefaultName = <String, List<String>>{};
    for (final table in sortedTables) {
      (byDefaultName['${_naming.typeName(table)}Id'] ??= <String>[]).add(table);
    }
    final result = <String, String>{};
    for (final table in sortedTables) {
      final defaultName = '${_naming.typeName(table)}Id';
      final group = byDefaultName[defaultName]!;
      final collidesWithUserTable =
          group.length > 1 &&
          table.startsWith('_') &&
          group.any((other) => !other.startsWith('_'));
      result[table] =
          collidesWithUserTable
              ? 'System${_naming.typeName(table)}Id'
              : defaultName;
    }

    final tableByClass = <String, String>{};
    for (final table in sortedTables) {
      final typeName = result[table]!;
      final existingTable = tableByClass[typeName];
      if (existingTable != null) {
        throw NamingException(
          'Generated table ID class name collision: "$typeName" is used by '
          'tables "$existingTable" and "$table". Rename one of the Convex '
          'tables.',
        );
      }
      tableByClass[typeName] = table;
    }
    return result;
  }

  Iterable<_ModuleNode> _flattenNodes(_ModuleNode root) sync* {
    yield root;
    final children =
        root.children.values.toList()..sort(
          (left, right) => left.pathSegments
              .join('/')
              .compareTo(right.pathSegments.join('/')),
        );
    for (final child in children) {
      yield* _flattenNodes(child);
    }
  }

  String _renderNode(
    _ModuleNode node, {
    required bool isRoot,
    required TypeRenderContext typeContext,
  }) {
    final filePath = isRoot ? 'api.dart' : _moduleFilePath(node);
    final imports =
        ImportManager()
          ..add(clientImport)
          ..add(
            _naming.relativeImport(
              fromFile: filePath,
              targetFile: 'runtime.dart',
            ),
          )
          ..add(
            _naming.relativeImport(
              fromFile: filePath,
              targetFile: 'schema.dart',
            ),
          );

    final childNodes =
        node.children.values.toList()..sort(
          (left, right) =>
              left.pathSegments.last.compareTo(right.pathSegments.last),
        );
    for (final child in childNodes) {
      final target = _moduleFilePath(child);
      imports.add(
        _naming.relativeImport(fromFile: filePath, targetFile: target),
      );
    }

    final methods = <String>[
      for (final function in node.functions)
        _renderFunction(function, context: typeContext),
    ];

    if (typeContext.usesTypedData) {
      imports.add('dart:typed_data');
    }

    final buffer =
        StringBuffer()
          ..writeln(generatedFileHeader)
          ..writeln(generatedFileIgnores)
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
    buffer.writeln('}');

    final definitions = typeContext.renderDefinitions();
    if (definitions.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln(definitions);
    }
    return '${buffer.toString().trimRight()}\n';
  }

  String _renderFunction(
    FunctionSpec function, {
    required TypeRenderContext context,
  }) {
    final pagination = _detectPagination(
      function,
      onSkip: context.warnings.add,
    );
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
        throw GenerationException(
          'Unsupported function type "${function.functionType}" for '
          '${function.identifier}.',
        ),
    };
    final isMutation = function.functionType == 'Mutation';

    final methodBuffer = StringBuffer();
    var requestArgsExpression = 'const <String, dynamic>{}';
    final namedParameters = <String>[];
    final positionalParameters = <String>[];
    final argNames = <String>{};

    if (argsType is ConvexObjectType && argsType.value.isNotEmpty) {
      final argsObject = mapper.mapType(
        argsType,
        suggestedName: '${functionPrefix}Args',
        context: context,
      );
      final fieldNames = mapper.resolveObjectFieldNames(
        argsType.value.keys,
        ownerName: '${functionPrefix}Args',
      );
      final recordAssignments = <String>[];
      for (final entry in argsType.value.entries) {
        final fieldName = fieldNames[entry.key]!;
        argNames.add(fieldName);
        final mappedField = mapper.mapType(
          entry.value.fieldType,
          suggestedName:
              '${functionPrefix}Args'
              '${mapper.fieldTypeSuffix(entry.key, fieldName)}',
          context: context,
        );
        if (entry.value.optional) {
          namedParameters.add(
            'Optional<${mappedField.annotation}> '
            '$fieldName = const Optional.absent()',
          );
        } else {
          namedParameters.add('required ${mappedField.annotation} $fieldName');
        }
        recordAssignments.add('$fieldName: $fieldName');
      }
      requestArgsExpression = argsObject.encode(
        '(${recordAssignments.join(', ')})',
      );
    } else if (argsType is ConvexObjectType && argsType.value.isEmpty) {
      // No arguments.
    } else {
      if (argsType is! ConvexAnyType) {
        // Convex accepts any validator for `args` (for example a union of
        // objects or a record). Such shapes have no named-parameter form, so
        // they take the same untyped map as an unvalidated function.
        context.warnings.add(
          'Function "${function.identifier}" has a non-object top-level args '
          'validator (${argsType.type}); generated with an untyped '
          'Map<String, dynamic> argument.',
        );
      }
      positionalParameters.add(
        'Map<String, dynamic> args = const <String, dynamic>{}',
      );
      requestArgsExpression = 'args';
      argNames.add('args');
    }

    var optimisticArgument = '';
    var optimisticParameter = '';
    if (isMutation) {
      if (argNames.contains('optimisticUpdate')) {
        context.warnings.add(
          'Function "${function.identifier}" has an argument that collides '
          'with the generated "optimisticUpdate" parameter; generated without '
          'optimistic update support.',
        );
      } else {
        // Optimistic updates are forwarded positionally, matching
        // ConvexClient.mutate(name, [args, optimisticUpdate]).
        optimisticArgument = ', optimisticUpdate';
        optimisticParameter = 'OptimisticUpdate? optimisticUpdate';
      }
    }

    String renderSignature({required bool includeOptimistic}) {
      final optimistic = <String>[
        if (includeOptimistic && optimisticParameter.isNotEmpty)
          optimisticParameter,
      ];
      if (positionalParameters.isNotEmpty) {
        final positional = <String>[...positionalParameters, ...optimistic];
        return '[${positional.join(', ')}]';
      }
      final named = <String>[...namedParameters, ...optimistic];
      return named.isEmpty ? '' : '{${named.join(', ')}}';
    }

    final functionNameLiteral = dartSingleQuotedString(
      function.convexFunctionName,
    );

    // Generated locals carry a `$` suffix: sanitized Convex argument names can
    // never contain `$`, so a user argument named `raw`, `subscription`, or
    // `query` cannot collide with (and shadow) a generated local.
    methodBuffer
      ..write('Future<${resultType.annotation}> $methodName(')
      ..write(renderSignature(includeOptimistic: true))
      ..writeln(') async {');
    final decodeExpression = resultType.decode(r'raw$');
    final call =
        '_client.$operation($functionNameLiteral, '
        '$requestArgsExpression$optimisticArgument)';
    if (decodeExpression == 'null') {
      // A `v.null()` return needs no decode; skip the binding so the
      // generated method does not hold an unused local.
      methodBuffer
        ..writeln('  await $call;')
        ..writeln('  return null;')
        ..writeln('}');
    } else {
      methodBuffer
        ..writeln('  final raw\$ = await $call;')
        ..writeln('  return $decodeExpression;')
        ..writeln('}');
    }

    if (function.functionType == 'Query') {
      final annotation = resultType.annotation;
      // Decoding happens inside typedQueryResult (runtime.dart), which turns
      // a decode failure into a TypedQueryError instead of a stream error.
      methodBuffer
        ..writeln()
        ..write('TypedConvexSubscription<$annotation> ${methodName}Subscribe(')
        ..write(renderSignature(includeOptimistic: false))
        ..writeln(') {')
        ..writeln(
          '  final subscription\$ = _client.subscribe('
          '$functionNameLiteral, $requestArgsExpression);',
        )
        ..writeln('  return TypedConvexSubscription<$annotation>(')
        ..writeln('    subscription\$,')
        ..writeln('    subscription\$.stream.map(')
        ..writeln(
          '      (event\$) => typedQueryResult<$annotation>(event\$, '
          '(raw\$) => $decodeExpression, $functionNameLiteral),',
        )
        ..writeln('    ),')
        ..writeln('  );')
        ..writeln('}');
    }

    return methodBuffer.toString();
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
    if (_naming.resolveFieldNames(otherArgs.keys).values.contains('pageSize')) {
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

  String _renderPaginatedQuery(
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
    final fieldNames = mapper.resolveObjectFieldNames(
      info.otherArgs.keys,
      ownerName: '${functionPrefix}Args',
    );
    for (final entry in info.otherArgs.entries) {
      final fieldKey = dartSingleQuotedString(entry.key);
      final fieldName = fieldNames[entry.key]!;
      final mappedField = mapper.mapType(
        entry.value.fieldType,
        suggestedName:
            '${functionPrefix}Args'
            '${mapper.fieldTypeSuffix(entry.key, fieldName)}',
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
    final argsMap =
        argsMapEntries.isEmpty
            ? 'const <String, dynamic>{}'
            : '<String, dynamic>{${argsMapEntries.join(' ')}}';

    final methodBuffer =
        StringBuffer()
          ..writeln(
            'TypedConvexPaginatedQuery<$elementAnnotation> '
            '$methodName({$signature}) {',
          )
          // No intermediate local: a user argument named `query` must stay
          // referencable inside the args map below.
          ..writeln('  return TypedConvexPaginatedQuery<$elementAnnotation>(')
          ..writeln('    _client.paginatedQuery(')
          ..writeln(
            '      ${dartSingleQuotedString(function.convexFunctionName)},',
          )
          ..writeln('      $argsMap,')
          ..writeln('      pageSize: pageSize,')
          ..writeln('    ),')
          ..writeln('    (dynamic raw) => $elementDecode,')
          ..writeln('  );')
          ..write('}');

    return methodBuffer.toString();
  }

  String _buildSchemaFile(Map<String, String> tableIdClassNames) {
    final sortedTables = tableIdClassNames.keys.toList()..sort();
    final buffer =
        StringBuffer()
          ..writeln(generatedFileHeader)
          ..writeln(generatedFileIgnores)
          ..writeln()
          ..writeln("import 'runtime.dart';")
          ..writeln();

    for (final table in sortedTables) {
      final typeName = tableIdClassNames[table]!;
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
$generatedFileIgnores

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
  const TypedQuerySuccess(
    this.value, {
    this.logLines = const <String>[],
    this.hasPendingWrites = false,
  });

  final T value;
  final List<String> logLines;

  /// Whether optimistic updates currently affect [value].
  final bool hasPendingWrites;
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

/// Converts a raw query [event] into a typed result.
///
/// A value that [decode] rejects (for example an enum value added on the
/// server after these bindings were generated) becomes a [TypedQueryError]
/// instead of a stream error, so exhaustive switches over
/// [TypedQueryResult] see every failure.
TypedQueryResult<T> typedQueryResult<T>(
  QueryResult event,
  T Function(dynamic raw) decode,
  String functionName,
) {
  switch (event) {
    case QuerySuccess(:final value, :final logLines, :final hasPendingWrites):
      final T decoded;
      try {
        decoded = decode(value);
      } catch (error) {
        return TypedQueryError<T>(
          'Failed to decode \$functionName result: \$error',
          data: error,
          logLines: logLines,
        );
      }
      return TypedQuerySuccess<T>(
        decoded,
        logLines: logLines,
        hasPendingWrites: hasPendingWrites,
      );
    case QueryLoading(:final hasPendingWrites):
      return TypedQueryLoading<T>(hasPendingWrites: hasPendingWrites);
    case QueryError(:final message, :final data, :final logLines):
      return TypedQueryError<T>(message, data: data, logLines: logLines);
  }
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
    this.hasPendingWrites = false,
  });

  final List<T> items;
  final ConvexPaginationStatus status;
  final bool isDone;
  final Object? error;

  /// Whether optimistic writes currently affect any loaded page in [items].
  final bool hasPendingWrites;
}

class TypedConvexPaginatedQuery<T> {
  TypedConvexPaginatedQuery(this._delegate, this._decode);

  final ConvexPaginatedQuery _delegate;
  final T Function(dynamic raw) _decode;
  ConvexPaginatedResult? _lastRaw;
  TypedConvexPaginatedResult<T>? _lastTyped;

  /// Created once, so a widget passing `stream: query.stream` on every build
  /// keeps the same subscription.
  late final Stream<TypedConvexPaginatedResult<T>> stream = _delegate.stream
      .map(_toTyped);

  /// The latest typed snapshot. Decoded once per raw snapshot and cached.
  TypedConvexPaginatedResult<T> get current => _toTyped(_delegate.current);

  /// The decoded items of [current] (an unmodifiable, cached list).
  List<T> get items => current.items;

  /// The status of [current]; [ConvexPaginationStatus.error] also reports
  /// items that could not be decoded.
  ConvexPaginationStatus get status => current.status;

  bool get isDone => _delegate.isDone;

  bool loadMore([int? numItems]) => _delegate.loadMore(numItems);

  void cancel() {
    _delegate.cancel();
  }

  TypedConvexPaginatedResult<T> _toTyped(ConvexPaginatedResult result) {
    final cached = _lastTyped;
    if (cached != null && identical(result, _lastRaw)) {
      return cached;
    }
    TypedConvexPaginatedResult<T> typed;
    try {
      typed = TypedConvexPaginatedResult<T>(
        items: List<T>.unmodifiable(result.results.map(_decode)),
        status: result.status,
        isDone: result.isDone,
        error: result.error,
        hasPendingWrites: result.hasPendingWrites,
      );
    } catch (error) {
      // An item the bindings cannot decode is reported like a failed page
      // instead of throwing from a getter or erroring the stream.
      typed = TypedConvexPaginatedResult<T>(
        items: List<T>.unmodifiable(<T>[]),
        status: ConvexPaginationStatus.error,
        isDone: result.isDone,
        error: error,
        hasPendingWrites: result.hasPendingWrites,
      );
    }
    _lastRaw = result;
    _lastTyped = typed;
    return typed;
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

/// Decodes a `v.commitTs()` value: a [BigInt] commit timestamp, or
/// [ConvexCommitTsPlaceholder.instance] when the mutation that wrote the field
/// reads it back before committing.
Object expectCommitTs(dynamic value, {String? label}) {
  if (value is BigInt) {
    return value;
  }
  if (value is ConvexCommitTsPlaceholder) {
    return value;
  }
  throw FormatException('Expected \${label ?? 'commitTs'}, got \${describeType(value)}');
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
}

/// Describes a detected paginated query: its page element type (or `null` for
/// an untyped, returns-less query) and its arguments minus `paginationOpts`.
class _PaginationInfo {
  _PaginationInfo({required this.elementType, required this.otherArgs});

  final ConvexType? elementType;
  final Map<String, ConvexField> otherArgs;
}
