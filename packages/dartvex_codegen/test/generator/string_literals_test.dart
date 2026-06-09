import 'package:dartvex_codegen/src/generator/string_literals.dart';
import 'package:test/test.dart';

void main() {
  group('escapeDartStringContent', () {
    test('escapes NUL as hex, not the unsupported backslash-zero escape', () {
      // In Dart, `\0` is not an escape sequence: '\0' evaluates to the digit
      // '0'. Emitting it for NUL silently changes the literal's value.
      expect(escapeDartStringContent('a\x00b'), r'a\x00b');
    });

    test('escapes the documented control and meta characters', () {
      expect(escapeDartStringContent('\b\t\n\f\r'), r'\b\t\n\f\r');
      expect(escapeDartStringContent(r'$'), r'\$');
      expect(escapeDartStringContent("'"), r"\'");
      expect(escapeDartStringContent('\\'), r'\\');
      expect(escapeDartStringContent('\x7f'), r'\x7f');
      expect(escapeDartStringContent('\u2028\u2029'), r'\u2028\u2029');
    });

    test('hex-escapes remaining C0 control characters', () {
      expect(escapeDartStringContent('\x01\x0b\x1f'), r'\x01\x0b\x1f');
    });

    test('passes printable text through unchanged', () {
      expect(escapeDartStringContent('héllo wörld 123'), 'héllo wörld 123');
    });
  });

  group('dartSingleQuotedString', () {
    test('wraps escaped content in single quotes', () {
      expect(dartSingleQuotedString("it's a\x00test"), r"'it\'s a\x00test'");
    });
  });
}
