/// Renders [value] as a single-quoted Dart string literal.
String dartSingleQuotedString(String value) {
  return "'${escapeDartStringContent(value)}'";
}

/// Escapes [value] for inclusion inside a single-quoted Dart string literal.
String escapeDartStringContent(String value) {
  final buffer = StringBuffer();
  for (final codeUnit in value.codeUnits) {
    switch (codeUnit) {
      case 0x00:
        buffer.write(r'\0');
      case 0x08:
        buffer.write(r'\b');
      case 0x09:
        buffer.write(r'\t');
      case 0x0a:
        buffer.write(r'\n');
      case 0x0c:
        buffer.write(r'\f');
      case 0x0d:
        buffer.write(r'\r');
      case 0x24:
        buffer.write(r'\$');
      case 0x27:
        buffer.write(r"\'");
      case 0x5c:
        buffer.write(r'\\');
      case 0x7f:
        buffer.write(r'\x7f');
      case 0x2028:
        buffer.write(r'\u2028');
      case 0x2029:
        buffer.write(r'\u2029');
      default:
        if (codeUnit < 0x20) {
          buffer
            ..write(r'\x')
            ..write(codeUnit.toRadixString(16).padLeft(2, '0'));
        } else {
          buffer.writeCharCode(codeUnit);
        }
    }
  }
  return buffer.toString();
}
