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

    test('escapes Object member names Dart forbids in records', () {
      for (final name in <String>[
        'hashCode',
        'noSuchMethod',
        'runtimeType',
        'toString',
      ]) {
        expect(naming.fieldName(name), '${name}Value');
        expect(naming.methodName(name), '${name}Value');
      }
      // Ordinary names are untouched.
      expect(naming.fieldName('hash'), 'hash');
    });

    test('disambiguates system fields that collide with user fields', () {
      expect(
        naming.resolveFieldNames(<String>[
          '_id',
          '_creationTime',
          'id',
          'creationTime',
          'title',
        ]),
        <String, String>{
          '_id': 'systemId',
          '_creationTime': 'systemCreationTime',
          'id': 'id',
          'creationTime': 'creationTime',
          'title': 'title',
        },
      );
      // Without a colliding user field, system fields keep their names.
      expect(
        naming.resolveFieldNames(<String>['_id', 'title']),
        <String, String>{'_id': 'id', 'title': 'title'},
      );
    });
  });
}
