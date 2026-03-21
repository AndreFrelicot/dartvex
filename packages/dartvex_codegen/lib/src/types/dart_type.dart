/// Base representation of a Dart type emitted by the generator.
sealed class DartType {
  /// Creates a Dart type wrapper.
  const DartType();

  /// The type annotation rendered into generated source.
  String get annotation;
}

/// A simple primitive or pre-rendered type annotation.
class DartPrimitiveType extends DartType {
  /// Creates a primitive type wrapper.
  const DartPrimitiveType(this.annotation);

  @override
  final String annotation;
}

/// A named Dart type such as a typedef or generated ID wrapper.
class DartNamedType extends DartType {
  /// Creates a named type wrapper.
  const DartNamedType(this.name);

  /// The underlying type name.
  final String name;

  @override
  String get annotation => name;
}

/// A nullable Dart type.
class DartNullableType extends DartType {
  /// Creates a nullable wrapper around [inner].
  const DartNullableType(this.inner);

  /// The non-nullable inner type.
  final DartType inner;

  @override
  String get annotation => '${inner.annotation}?';
}

/// A `List<T>` Dart type.
class DartListType extends DartType {
  /// Creates a list type wrapper.
  const DartListType(this.itemType);

  /// The element type.
  final DartType itemType;

  @override
  String get annotation => 'List<${itemType.annotation}>';
}

/// A `Map<K, V>` Dart type.
class DartMapType extends DartType {
  /// Creates a map type wrapper.
  const DartMapType({
    required this.keyType,
    required this.valueType,
  });

  /// The key type.
  final DartType keyType;

  /// The value type.
  final DartType valueType;

  @override
  String get annotation =>
      'Map<${keyType.annotation}, ${valueType.annotation}>';
}

/// A named field in a generated record type.
class DartRecordField {
  /// Creates a record field definition.
  const DartRecordField({
    required this.name,
    required this.type,
  });

  /// The generated field name.
  final String name;

  /// The generated field type.
  final DartType type;
}

/// A named record type rendered as `({ ... })`.
class DartRecordType extends DartType {
  /// Creates a record type wrapper.
  const DartRecordType(this.fields);

  /// The fields included in the record.
  final List<DartRecordField> fields;

  @override
  String get annotation {
    final rendered = fields
        .map((field) => '${field.type.annotation} ${field.name}')
        .join(', ');
    return '({$rendered})';
  }
}
