import 'dart:convert';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:test/test.dart';

void main() {
  group('scrub CLI', () {
    test('scrubs stdin to the output sink via runConvexCodegen', () async {
      final output = StringBuffer();

      final exitCode = await runConvexCodegen(
        <String>['scrub'],
        readStdin:
            () async =>
                '{"url":"https://chosen-deployment-name.convex.cloud","functions":[]}',
        writeOutput: output.write,
        errorLog: (_) {},
      );

      expect(exitCode, 0);
      final decoded = jsonDecode(output.toString()) as Map<String, dynamic>;
      expect(decoded['url'], 'https://your-deployment.convex.cloud');
      expect(output.toString(), isNot(contains('chosen-deployment-name')));
    });

    test('reports a clear error when the spec file is missing', () async {
      final errors = <String>[];

      final exitCode = await runConvexCodegen(
        <String>['scrub', '--spec-file', '/no/such/spec.json'],
        writeOutput: (_) {},
        errorLog: errors.add,
      );

      expect(exitCode, 64);
      expect(errors.single, contains('does not exist'));
    });
  });
}
