/// Parsed output from `convex function-spec`.
class FunctionsSpec {
  /// Creates a parsed function spec document.
  const FunctionsSpec({
    required this.url,
    required this.functions,
  });

  /// The deployment URL reported by the function spec.
  final String url;

  /// All functions included in the raw spec, including HTTP actions.
  final List<BaseFunctionSpec> functions;

  /// The public query, mutation, and action functions in declaration order.
  Iterable<FunctionSpec> get publicFunctions sync* {
    for (final function in functions.whereType<FunctionSpec>()) {
      if (function.visibility.kind == 'public') {
        yield function;
      }
    }
  }
}

/// Base metadata shared by all spec entries.
sealed class BaseFunctionSpec {
  /// Creates a function spec entry with the given [functionType].
  const BaseFunctionSpec(this.functionType);

  /// The Convex function kind, such as `Query`, `Mutation`, or `HttpAction`.
  final String functionType;
}

/// Spec entry describing an HTTP action endpoint.
class HttpFunctionSpec extends BaseFunctionSpec {
  /// Creates an HTTP action spec.
  const HttpFunctionSpec({
    required String functionType,
    required this.method,
    required this.path,
  }) : super(functionType);

  /// The HTTP method handled by the action.
  final String method;

  /// The route path exposed by the action.
  final String path;
}

/// Spec entry describing a query, mutation, or action function.
class FunctionSpec extends BaseFunctionSpec {
  /// Creates a callable function spec.
  const FunctionSpec({
    required String functionType,
    required this.args,
    required this.returns,
    required this.identifier,
    required this.visibility,
  }) : super(functionType);

  /// The argument schema accepted by the function.
  final ConvexType args;

  /// The return schema produced by the function.
  final ConvexType returns;

  /// The raw Convex identifier, including module path and function name.
  final String identifier;

  /// Visibility information reported by Convex.
  final Visibility visibility;

  /// The leaf function name without its module path.
  String get functionName => identifier.split(':').last;

  /// The canonical Convex function name with file extensions removed.
  String get convexFunctionName =>
      identifier.replaceAll(RegExp(r'\.[^.:\s]+(?=:)'), '');

  /// The module path segments used for generating nested API classes.
  List<String> get modulePathSegments {
    final rawPath = convexFunctionName.split(':').first;
    final segments = rawPath.split('/').where((segment) => segment.isNotEmpty);
    final result = segments
        .map((segment) => segment.replaceAll(RegExp(r'\.[^.]+$'), ''))
        .toList();
    if (result.isNotEmpty && result.last == 'index') {
      result.removeLast();
    }
    return result;
  }
}

/// Wrapper for Convex function visibility.
class Visibility {
  /// Creates a visibility wrapper.
  const Visibility(this.kind);

  /// The raw visibility kind, such as `public` or `internal`.
  final String kind;
}

/// Object-field metadata used inside record and object schemas.
class ConvexField {
  /// Creates a field specification.
  const ConvexField({
    required this.fieldType,
    required this.optional,
  });

  /// The field's schema.
  final ConvexType fieldType;

  /// Whether the field may be omitted from the containing object.
  final bool optional;
}

/// Base class for all Convex schema types.
sealed class ConvexType {
  /// Creates a Convex type descriptor.
  const ConvexType(this.type);

  /// The raw Convex type discriminator.
  final String type;
}

/// Represents the Convex `any` type.
class ConvexAnyType extends ConvexType {
  /// Creates an `any` type descriptor.
  const ConvexAnyType() : super('any');
}

/// Represents the Convex `boolean` type.
class ConvexBooleanType extends ConvexType {
  /// Creates a `boolean` type descriptor.
  const ConvexBooleanType() : super('boolean');
}

/// Represents the Convex `string` type.
class ConvexStringType extends ConvexType {
  /// Creates a `string` type descriptor.
  const ConvexStringType() : super('string');
}

/// Represents the Convex `number` type.
class ConvexNumberType extends ConvexType {
  /// Creates a `number` type descriptor.
  const ConvexNumberType() : super('number');
}

/// Represents the Convex `null` type.
class ConvexNullType extends ConvexType {
  /// Creates a `null` type descriptor.
  const ConvexNullType() : super('null');
}

/// Represents the Convex `bigint` type.
class ConvexBigIntType extends ConvexType {
  /// Creates a `bigint` type descriptor.
  const ConvexBigIntType() : super('bigint');
}

/// Represents the Convex `bytes` type.
class ConvexBytesType extends ConvexType {
  /// Creates a `bytes` type descriptor.
  const ConvexBytesType() : super('bytes');
}

/// Represents a literal value constraint in a Convex schema.
class ConvexLiteralType extends ConvexType {
  /// Creates a literal type descriptor for [value].
  const ConvexLiteralType(this.value) : super('literal');

  /// The exact literal value permitted by the schema.
  final Object? value;
}

/// Represents a union of multiple Convex schema types.
class ConvexUnionType extends ConvexType {
  /// Creates a union type descriptor.
  const ConvexUnionType(this.value) : super('union');

  /// The allowed member types in the union.
  final List<ConvexType> value;
}

/// Represents a map-like record type.
class ConvexRecordType extends ConvexType {
  /// Creates a record type descriptor.
  const ConvexRecordType({
    required this.keys,
    required this.values,
  }) : super('record');

  /// The schema used for keys.
  final ConvexType keys;

  /// The schema used for values.
  final ConvexField values;
}

/// Represents a structured object type.
class ConvexObjectType extends ConvexType {
  /// Creates an object type descriptor.
  const ConvexObjectType(this.value) : super('object');

  /// The named fields in the object schema.
  final Map<String, ConvexField> value;
}

/// Represents an array type.
class ConvexArrayType extends ConvexType {
  /// Creates an array type descriptor.
  const ConvexArrayType(this.value) : super('array');

  /// The schema for each array element.
  final ConvexType value;
}

/// Represents a Convex document ID for [tableName].
class ConvexIdType extends ConvexType {
  /// Creates an ID type descriptor.
  const ConvexIdType(this.tableName) : super('id');

  /// The table name associated with the ID.
  final String tableName;
}
