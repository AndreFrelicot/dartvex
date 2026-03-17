sealed class DartType {
  const DartType();

  String get annotation;
}

class DartPrimitiveType extends DartType {
  const DartPrimitiveType(this.annotation);

  @override
  final String annotation;
}

class DartNamedType extends DartType {
  const DartNamedType(this.name);

  final String name;

  @override
  String get annotation => name;
}

class DartNullableType extends DartType {
  const DartNullableType(this.inner);

  final DartType inner;

  @override
  String get annotation => '${inner.annotation}?';
}

class DartListType extends DartType {
  const DartListType(this.itemType);

  final DartType itemType;

  @override
  String get annotation => 'List<${itemType.annotation}>';
}

class DartMapType extends DartType {
  const DartMapType({
    required this.keyType,
    required this.valueType,
  });

  final DartType keyType;
  final DartType valueType;

  @override
  String get annotation =>
      'Map<${keyType.annotation}, ${valueType.annotation}>';
}

class DartRecordField {
  const DartRecordField({
    required this.name,
    required this.type,
  });

  final String name;
  final DartType type;
}

class DartRecordType extends DartType {
  const DartRecordType(this.fields);

  final List<DartRecordField> fields;

  @override
  String get annotation {
    final rendered = fields
        .map((field) => '${field.type.annotation} ${field.name}')
        .join(', ');
    return '({$rendered})';
  }
}
