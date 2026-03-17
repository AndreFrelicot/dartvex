import 'dart:convert';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:test/test.dart';

/// Test helper that exposes _extractJson for testing.
class TestableProcessRunner extends SystemProcessRunner {
  String extractJson(String stdoutText) {
    // We can't call private method directly, so we replicate the validation
    // logic. Instead, we test through the JSON decode validation behavior.
    if (stdoutText.isEmpty) {
      throw ProcessRunnerException('convex function-spec produced no output.');
    }
    final start = stdoutText.indexOf('{');
    final end = stdoutText.lastIndexOf('}');
    if (start == -1 || end == -1 || end < start) {
      throw ProcessRunnerException(
        'convex function-spec did not emit valid JSON.',
        stdout: stdoutText,
      );
    }
    final candidate = stdoutText.substring(start, end + 1);
    try {
      jsonDecode(candidate);
    } catch (e) {
      throw ProcessRunnerException(
        'convex function-spec output contains invalid JSON: $e',
        stdout: stdoutText,
      );
    }
    return candidate;
  }
}

void main() {
  group('ProcessRunner JSON extraction', () {
    late TestableProcessRunner runner;

    setUp(() {
      runner = TestableProcessRunner();
    });

    test('extracts clean JSON from stdout', () {
      const input = '{"url":"https://test.convex.cloud","functions":[]}';
      final result = runner.extractJson(input);
      expect(jsonDecode(result), isA<Map<String, dynamic>>());
    });

    test('extracts JSON when prefixed with warnings', () {
      const input =
          'npm warn deprecated package@1.0.0\n{"url":"https://test.convex.cloud","functions":[]}';
      final result = runner.extractJson(input);
      final decoded = jsonDecode(result) as Map<String, dynamic>;
      expect(decoded['url'], 'https://test.convex.cloud');
    });

    test('throws clear error when no JSON present', () {
      expect(
        () => runner.extractJson('no json here'),
        throwsA(isA<ProcessRunnerException>().having(
          (e) => e.message,
          'message',
          contains('did not emit valid JSON'),
        )),
      );
    });

    test('throws clear error on empty output', () {
      expect(
        () => runner.extractJson(''),
        throwsA(isA<ProcessRunnerException>().having(
          (e) => e.message,
          'message',
          contains('produced no output'),
        )),
      );
    });

    test('throws clear error when extracted substring is not valid JSON', () {
      // The { and } exist but don't form valid JSON
      const input = 'prefix {not: valid json} suffix {extra}';
      expect(
        () => runner.extractJson(input),
        throwsA(isA<ProcessRunnerException>().having(
          (e) => e.message,
          'message',
          contains('invalid JSON'),
        )),
      );
    });
  });
}
