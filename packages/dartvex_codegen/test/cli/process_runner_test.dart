import 'dart:convert';

import 'package:dartvex_codegen/src/cli/process_runner.dart';
import 'package:test/test.dart';

void main() {
  group('ProcessRunner JSON extraction', () {
    test('extracts clean JSON from stdout', () {
      const input = '{"url":"https://test.convex.cloud","functions":[]}';
      final result = extractFunctionSpecJson(input);
      expect(jsonDecode(result), isA<Map<String, dynamic>>());
    });

    test('extracts JSON when prefixed with warnings', () {
      const input =
          'npm warn deprecated package@1.0.0\n{"url":"https://test.convex.cloud","functions":[]}';
      final result = extractFunctionSpecJson(input);
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['url'], 'https://test.convex.cloud');
    });

    test('ignores brace-containing text before and after JSON', () {
      const input =
          'Generated {1} warnings\n{"url":"https://test.convex.cloud","functions":[]}\nGenerated {2} files';
      final result = extractFunctionSpecJson(input);
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['url'], 'https://test.convex.cloud');
    });

    test('skips non-function-spec JSON objects', () {
      const input =
          '{"level":"warn","message":"using cached deployment"}\n{"url":"https://test.convex.cloud","functions":[]}';
      final result = extractFunctionSpecJson(input);
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['url'], 'https://test.convex.cloud');
      expect(decoded['functions'], isEmpty);
    });

    test('throws clear error when JSON objects are not function specs', () {
      const input = '{"level":"warn","message":"no spec here"}';
      expect(
        () => extractFunctionSpecJson(input),
        throwsA(
          isA<ProcessRunnerException>().having(
            (e) => e.message,
            'message',
            contains('Convex function spec'),
          ),
        ),
      );
    });

    test('throws clear error when no JSON present', () {
      expect(
        () => extractFunctionSpecJson('no json here'),
        throwsA(
          isA<ProcessRunnerException>().having(
            (e) => e.message,
            'message',
            contains('did not emit valid JSON'),
          ),
        ),
      );
    });

    test('throws clear error on empty output', () {
      expect(
        () => extractFunctionSpecJson(''),
        throwsA(
          isA<ProcessRunnerException>().having(
            (e) => e.message,
            'message',
            contains('produced no output'),
          ),
        ),
      );
    });

    test('throws clear error when extracted substring is not valid JSON', () {
      // The { and } exist but don't form valid JSON
      const input = 'prefix {not: valid json} suffix {extra}';
      expect(
        () => extractFunctionSpecJson(input),
        throwsA(
          isA<ProcessRunnerException>().having(
            (e) => e.message,
            'message',
            contains('invalid JSON'),
          ),
        ),
      );
    });
  });
}
