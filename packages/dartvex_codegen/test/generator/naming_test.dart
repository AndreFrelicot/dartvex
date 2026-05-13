import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:test/test.dart';

void main() {
  group('Naming', () {
    const naming = Naming();

    test('preserves existing camelCase boundaries', () {
      expect(naming.methodName('pingAction'), 'pingAction');
      expect(naming.methodName('requireAuthEcho'), 'requireAuthEcho');
      expect(naming.fieldName('tokenIdentifier'), 'tokenIdentifier');
    });

    test('still converts separated identifiers to lower camel case', () {
      expect(naming.methodName('send-public'), 'sendPublic');
      expect(naming.fieldName('token_identifier'), 'tokenIdentifier');
    });
  });
}
