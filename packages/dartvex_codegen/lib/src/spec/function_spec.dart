class FunctionsSpec {
  const FunctionsSpec({
    required this.url,
    required this.functions,
  });

  final String url;
  final List<BaseFunctionSpec> functions;

  Iterable<FunctionSpec> get publicFunctions sync* {
    for (final function in functions.whereType<FunctionSpec>()) {
      if (function.visibility.kind == 'public') {
        yield function;
      }
    }
  }
}

sealed class BaseFunctionSpec {
  const BaseFunctionSpec(this.functionType);

  final String functionType;
}

class HttpFunctionSpec extends BaseFunctionSpec {
  const HttpFunctionSpec({
    required String functionType,
    required this.method,
    required this.path,
  }) : super(functionType);

  final String method;
  final String path;
}

class FunctionSpec extends BaseFunctionSpec {
  const FunctionSpec({
    required String functionType,
    required this.args,
    required this.returns,
    required this.identifier,
    required this.visibility,
  }) : super(functionType);

  final ConvexType args;
  final ConvexType returns;
  final String identifier;
  final Visibility visibility;

  String get functionName => identifier.split(':').last;

  String get convexFunctionName =>
      identifier.replaceAll(RegExp(r'\.[^.:\s]+(?=:)'), '');

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

class Visibility {
  const Visibility(this.kind);

  final String kind;
}

class ConvexField {
  const ConvexField({
    required this.fieldType,
    required this.optional,
  });

  final ConvexType fieldType;
  final bool optional;
}

sealed class ConvexType {
  const ConvexType(this.type);

  final String type;
}

class ConvexAnyType extends ConvexType {
  const ConvexAnyType() : super('any');
}

class ConvexBooleanType extends ConvexType {
  const ConvexBooleanType() : super('boolean');
}

class ConvexStringType extends ConvexType {
  const ConvexStringType() : super('string');
}

class ConvexNumberType extends ConvexType {
  const ConvexNumberType() : super('number');
}

class ConvexNullType extends ConvexType {
  const ConvexNullType() : super('null');
}

class ConvexBigIntType extends ConvexType {
  const ConvexBigIntType() : super('bigint');
}

class ConvexBytesType extends ConvexType {
  const ConvexBytesType() : super('bytes');
}

class ConvexLiteralType extends ConvexType {
  const ConvexLiteralType(this.value) : super('literal');

  final Object? value;
}

class ConvexUnionType extends ConvexType {
  const ConvexUnionType(this.value) : super('union');

  final List<ConvexType> value;
}

class ConvexRecordType extends ConvexType {
  const ConvexRecordType({
    required this.keys,
    required this.values,
  }) : super('record');

  final ConvexType keys;
  final ConvexField values;
}

class ConvexObjectType extends ConvexType {
  const ConvexObjectType(this.value) : super('object');

  final Map<String, ConvexField> value;
}

class ConvexArrayType extends ConvexType {
  const ConvexArrayType(this.value) : super('array');

  final ConvexType value;
}

class ConvexIdType extends ConvexType {
  const ConvexIdType(this.tableName) : super('id');

  final String tableName;
}
