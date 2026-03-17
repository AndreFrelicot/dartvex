import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('SpecParser', () {
    test('parses representative function-spec JSON', () async {
      final fixture = await File(
        path.join('test', 'fixtures', 'function_spec.json'),
      ).readAsString();
      final spec = const SpecParser().parseString(fixture);

      expect(spec.url, 'https://sample.convex.cloud');
      expect(spec.functions, hasLength(6));
      expect(
          spec.publicFunctions.map((function) => function.identifier),
          containsAll(<String>[
            'messages.ts:list',
            'messages.ts:send',
            'admin/users.ts:sync',
            'index.ts:health',
          ]));

      final listMessages = spec.publicFunctions.firstWhere(
        (function) => function.identifier == 'messages.ts:list',
      );
      expect(listMessages.modulePathSegments, <String>['messages']);
      expect(listMessages.args, isA<ConvexObjectType>());
      expect(listMessages.returns, isA<ConvexArrayType>());

      final httpAction = spec.functions.last;
      expect(httpAction, isA<HttpFunctionSpec>());
    });

    test('throws on malformed JSON roots', () {
      expect(
        () => const SpecParser().parseString('[]'),
        throwsA(isA<SpecParserException>()),
      );
    });

    test('throws when required fields are missing', () {
      expect(
        () => const SpecParser().parseMap(
          <String, dynamic>{
            'url': 'https://sample.convex.cloud',
            'functions': <dynamic>[
              <String, dynamic>{
                'functionType': 'Query',
              },
            ],
          },
        ),
        throwsA(isA<SpecParserException>()),
      );
    });
  });
}
