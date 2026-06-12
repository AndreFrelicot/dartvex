import 'dart:convert';
import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('FileEmitter', () {
    late Directory tempRoot;

    setUp(() async {
      tempRoot = await Directory.systemTemp.createTemp('dartvex_codegen_test_');
    });

    tearDown(() async {
      if (await tempRoot.exists()) {
        await tempRoot.delete(recursive: true);
      }
    });

    test('refuses generated paths outside the output directory', () async {
      final outputDirectory = path.join(tempRoot.path, 'generated');
      final escapedFile = File(path.join(tempRoot.path, 'escape.dart'));

      await expectLater(
        const FileEmitter().emit(
          outputDirectory: outputDirectory,
          files: const <String, String>{
            '../escape.dart': '$generatedFileHeader\n',
          },
          dryRun: false,
        ),
        throwsA(
          isA<FileEmitterException>().having(
            (error) => error.message,
            'message',
            contains('unsafe generated file path "../escape.dart"'),
          ),
        ),
      );

      expect(await escapedFile.exists(), isFalse);
    });

    test('refuses unsafe paths from an existing manifest', () async {
      final outputDirectory = Directory(path.join(tempRoot.path, 'generated'));
      await outputDirectory.create(recursive: true);
      await File(
        path.join(outputDirectory.path, FileEmitter.manifestName),
      ).writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'files': <String>['../stale.dart'],
        }),
      );
      final staleFile = File(path.join(tempRoot.path, 'stale.dart'));
      await staleFile.writeAsString('$generatedFileHeader\n');

      await expectLater(
        const FileEmitter().emit(
          outputDirectory: outputDirectory.path,
          files: const <String, String>{'api.dart': '$generatedFileHeader\n'},
          dryRun: false,
        ),
        throwsA(
          isA<FileEmitterException>().having(
            (error) => error.message,
            'message',
            contains('unsafe generated file path "../stale.dart"'),
          ),
        ),
      );

      expect(await staleFile.exists(), isTrue);
    });

    test('refuses platform separators in generated paths', () async {
      final outputDirectory = path.join(tempRoot.path, 'generated');

      await expectLater(
        const FileEmitter().emit(
          outputDirectory: outputDirectory,
          files: const <String, String>{
            r'modules\escape.dart': '$generatedFileHeader\n',
          },
          dryRun: false,
        ),
        throwsA(
          isA<FileEmitterException>().having(
            (error) => error.message,
            'message',
            contains(r'unsafe generated file path "modules\escape.dart"'),
          ),
        ),
      );
    });
  });
}
