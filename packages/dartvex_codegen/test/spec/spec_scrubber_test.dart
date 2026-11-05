import 'dart:convert';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:test/test.dart';

void main() {
  group('scrubFunctionSpec', () {
    const rawDump = '''
{
  "url": "https://chosen-deployment-name.convex.cloud",
  "functions": [
    {
      "functionType": "Query",
      "args": { "type": "object", "value": {} },
      "returns": null,
      "identifier": "messages.ts:list",
      "visibility": { "kind": "public" }
    },
    {
      "functionType": "HttpAction",
      "method": "GET",
      "path": "/healthz"
    }
  ]
}''';

    test('replaces the real deployment URL with the placeholder', () {
      final scrubbed = scrubFunctionSpec(rawDump);

      final decoded = jsonDecode(scrubbed) as Map<String, dynamic>;
      expect(decoded['url'], 'https://your-deployment.convex.cloud');
      expect(scrubbed, isNot(contains('chosen-deployment-name')));
    });

    test('preserves the functions array (only the url changes)', () {
      final before = jsonDecode(rawDump) as Map<String, dynamic>;
      final after =
          jsonDecode(scrubFunctionSpec(rawDump)) as Map<String, dynamic>;

      expect(after['functions'], before['functions']);
    });

    test('is idempotent', () {
      final once = scrubFunctionSpec(rawDump);
      final twice = scrubFunctionSpec(once);

      expect(twice, once);
    });

    test('emits 2-space indentation and a trailing newline', () {
      final scrubbed = scrubFunctionSpec(rawDump);

      expect(scrubbed, contains('\n  "url":'));
      expect(scrubbed, endsWith('\n'));
    });

    test('honors a custom placeholder URL', () {
      final scrubbed = scrubFunctionSpec(
        rawDump,
        placeholderUrl: 'https://x.example',
      );

      expect(
        (jsonDecode(scrubbed) as Map<String, dynamic>)['url'],
        'https://x.example',
      );
    });

    test('throws a clear error on non-object roots', () {
      expect(() => scrubFunctionSpec('[]'), throwsA(isA<FormatException>()));
    });

    test('skips package-runner banners around the spec (yarn v1)', () {
      const noisy =
          'yarn run v1.22.22\n'
          r'$ convex function-spec'
          '\n$rawDump\n'
          'Done in 1.92s.\n';

      final scrubbed = scrubFunctionSpec(noisy);

      final decoded = jsonDecode(scrubbed) as Map<String, dynamic>;
      expect(decoded['url'], placeholderDeploymentUrl);
      expect(decoded['functions'], hasLength(2));
      expect(scrubbed, isNot(contains('yarn run')));
    });

    test('still rejects text without any function spec', () {
      expect(
        () => scrubFunctionSpec('yarn run v1.22.22\nerror Command failed.'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
    });
  });
}
