import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:dartvex_codegen/src/cli/generate_command.dart' as internal;
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

      final exitCode = await runConvexCodegen(<String>[
        'generate',
        '--spec-file',
        fixtureFile.path,
        '--output',
        tempDir.path,
      ], log: logs.add);

      expect(exitCode, 0);
      expect(File(path.join(tempDir.path, 'api.dart')).existsSync(), isTrue);
      expect(
        File(
          path.join(tempDir.path, '.dartvex_codegen_manifest.json'),
        ).existsSync(),
        isTrue,
      );
      expect(logs.first, contains('Generated'));
    });

    test('--dry-run prints files without writing output', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartvex_codegen_');
      addTearDown(() => tempDir.delete(recursive: true));
      final logs = <String>[];

      final exitCode = await runConvexCodegen(<String>[
        'generate',
        '--spec-file',
        fixtureFile.path,
        '--output',
        tempDir.path,
        '--dry-run',
      ], log: logs.add);

      expect(exitCode, 0);
      expect(logs.first, '=== api.dart ===');
      expect(File(path.join(tempDir.path, 'api.dart')).existsSync(), isFalse);
    });

    test('fails clearly when process execution fails', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartvex_codegen_');
      addTearDown(() => tempDir.delete(recursive: true));
      final logs = <String>[];

      final exitCode = await runConvexCodegen(
        <String>[
          'generate',
          '--project',
          tempDir.path,
          '--output',
          tempDir.path,
        ],
        processRunner: _FailingProcessRunner(),
        log: (_) {},
        errorLog: logs.add,
      );

      expect(exitCode, 70);
      expect(logs, contains('synthetic failure'));
    });

    test('rejects missing input mode', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartvex_codegen_');
      addTearDown(() => tempDir.delete(recursive: true));
      final logs = <String>[];

      final exitCode = await runConvexCodegen(
        <String>['generate', '--output', tempDir.path],
        log: (_) {},
        errorLog: logs.add,
      );

      expect(exitCode, 64);
      expect(logs.single, contains('Exactly one of --project or --spec-file'));
    });

    test('rejects missing output path', () async {
      final logs = <String>[];

      final exitCode = await runConvexCodegen(
        <String>['generate', '--spec-file', fixtureFile.path],
        log: (_) {},
        errorLog: logs.add,
      );

      expect(exitCode, 64);
      expect(logs.single, contains('--output is required'));
    });

    test('watch ignore filter treats output path as a directory boundary', () {
      final tempRoot = path.normalize(path.absolute('tmp', 'dartvex_codegen'));
      final config =
          GenerateConfig(
            projectDirectory: path.join(tempRoot, 'project'),
            outputDirectory: path.join(tempRoot, 'build'),
            clientImport: 'package:dartvex/dartvex.dart',
            dryRun: false,
            verbose: false,
            watch: true,
          ).normalize();

      expect(
        internal.shouldIgnoreWatchEvent(
          path.join(config.outputDirectory, 'api.dart'),
          config,
        ),
        isTrue,
      );
      expect(
        internal.shouldIgnoreWatchEvent(
          '${config.outputDirectory}-cache/source.ts',
          config,
        ),
        isFalse,
      );
      expect(
        internal.shouldIgnoreWatchEvent(
          path.join(tempRoot, 'project', 'node_modules', 'convex', 'index.ts'),
          config,
        ),
        isTrue,
      );
      expect(
        internal.shouldIgnoreWatchEvent(
          path.join(tempRoot, 'project', '.dart_tool', 'package_config.json'),
          config,
        ),
        isTrue,
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
