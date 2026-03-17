import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('GenerateCommand', () {
    late File fixtureFile;

    setUpAll(() {
      fixtureFile = File(path.join('test', 'fixtures', 'function_spec.json'));
    });

    test('generates files from --spec-file', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartvex_codegen_');
      addTearDown(() => tempDir.delete(recursive: true));
      final logs = <String>[];

      final exitCode = await runConvexCodegen(
        <String>[
          'generate',
          '--spec-file',
          fixtureFile.path,
          '--output',
          tempDir.path,
        ],
        log: logs.add,
      );

      expect(exitCode, 0);
      expect(File(path.join(tempDir.path, 'api.dart')).existsSync(), isTrue);
      expect(
        File(path.join(tempDir.path, '.dartvex_codegen_manifest.json'))
            .existsSync(),
        isTrue,
      );
      expect(logs.first, contains('Generated'));
    });

    test('--dry-run prints files without writing output', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartvex_codegen_');
      addTearDown(() => tempDir.delete(recursive: true));
      final logs = <String>[];

      final exitCode = await runConvexCodegen(
        <String>[
          'generate',
          '--spec-file',
          fixtureFile.path,
          '--output',
          tempDir.path,
          '--dry-run',
        ],
        log: logs.add,
      );

      expect(exitCode, 0);
      expect(logs.first, '=== api.dart ===');
      expect(File(path.join(tempDir.path, 'api.dart')).existsSync(), isFalse);
    });

    test('fails clearly when process execution fails', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartvex_codegen_');
      addTearDown(() => tempDir.delete(recursive: true));

      expect(
        () => runConvexCodegen(
          <String>[
            'generate',
            '--project',
            tempDir.path,
            '--output',
            tempDir.path,
          ],
          processRunner: _FailingProcessRunner(),
          log: (_) {},
        ),
        throwsA(isA<ProcessRunnerException>()),
      );
    });

    test('rejects missing input mode', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartvex_codegen_');
      addTearDown(() => tempDir.delete(recursive: true));

      expect(
        () => runConvexCodegen(
          <String>[
            'generate',
            '--output',
            tempDir.path,
          ],
          log: (_) {},
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

class _FailingProcessRunner implements ProcessRunner {
  @override
  Future<String> runFunctionSpec({
    required String projectDirectory,
    required bool verbose,
  }) {
    throw ProcessRunnerException('synthetic failure');
  }
}
