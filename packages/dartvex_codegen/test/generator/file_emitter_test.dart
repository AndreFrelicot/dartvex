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

    File outputFile(String relative) =>
        File(path.join(tempRoot.path, 'generated', relative));

    Future<void> emit(
      Map<String, String> files, {
      void Function(String warning)? onWarning,
    }) {
      return const FileEmitter().emit(
        outputDirectory: path.join(tempRoot.path, 'generated'),
        files: files,
        dryRun: false,
        onWarning: onWarning,
      );
    }

    test('writes files and a sorted manifest', () async {
      await emit(const <String, String>{
        'modules/b.dart': '$generatedFileHeader\nb\n',
        'api.dart': '$generatedFileHeader\napi\n',
      });

      expect(await outputFile('api.dart').readAsString(), contains('api'));
      final manifest =
          jsonDecode(await outputFile(FileEmitter.manifestName).readAsString())
              as Map<String, dynamic>;
      expect(manifest['files'], <String>['api.dart', 'modules/b.dart']);
      expect(outputFile('${FileEmitter.manifestName}.tmp').existsSync(), false);
    });

    test('deletes stale generated files that are no longer emitted', () async {
      await emit(const <String, String>{
        'api.dart': '$generatedFileHeader\n',
        'modules/old.dart': '$generatedFileHeader\nold\n',
      });

      await emit(const <String, String>{'api.dart': '$generatedFileHeader\n'});

      expect(outputFile('modules/old.dart').existsSync(), isFalse);
      expect(outputFile('api.dart').existsSync(), isTrue);
    });

    test(
      'keeps a stale manifest entry that lost the generated header',
      () async {
        await emit(const <String, String>{
          'api.dart': '$generatedFileHeader\n',
          'modules/old.dart': '$generatedFileHeader\nold\n',
        });
        await outputFile('modules/old.dart').writeAsString('// hand edited\n');

        await emit(const <String, String>{
          'api.dart': '$generatedFileHeader\n',
        });

        expect(
          await outputFile('modules/old.dart').readAsString(),
          '// hand edited\n',
        );
      },
    );

    test('refuses to overwrite a pre-existing non-generated file', () async {
      await outputFile('api.dart').create(recursive: true);
      await outputFile('api.dart').writeAsString('// my own api\n');

      await expectLater(
        emit(const <String, String>{'api.dart': '$generatedFileHeader\n'}),
        throwsA(
          isA<FileEmitterException>().having(
            (error) => error.message,
            'message',
            contains('Refusing to overwrite non-generated file "api.dart"'),
          ),
        ),
      );
      expect(await outputFile('api.dart').readAsString(), '// my own api\n');
    });

    test('overwrites files it generated before', () async {
      await emit(const <String, String>{
        'api.dart': '$generatedFileHeader\nv1\n',
      });
      await emit(const <String, String>{
        'api.dart': '$generatedFileHeader\nv2\n',
      });

      expect(await outputFile('api.dart').readAsString(), contains('v2'));
    });

    test('recovers from a merge-conflicted manifest with a warning', () async {
      await emit(const <String, String>{
        'api.dart': '$generatedFileHeader\n',
        'modules/old.dart': '$generatedFileHeader\n',
      });
      await outputFile(FileEmitter.manifestName).writeAsString(
        '{\n  "files": [\n<<<<<<< HEAD\n    "a.dart",\n=======\n'
        '    "b.dart",\n>>>>>>> branch\n  ]\n}\n',
      );
      final warnings = <String>[];

      await emit(const <String, String>{
        'api.dart': '$generatedFileHeader\nnew\n',
      }, onWarning: warnings.add);

      expect(warnings.single, contains(FileEmitter.manifestName));
      expect(await outputFile('api.dart').readAsString(), contains('new'));
      // Stale cleanup is skipped for this run rather than guessed.
      expect(outputFile('modules/old.dart').existsSync(), isTrue);
      final manifest =
          jsonDecode(await outputFile(FileEmitter.manifestName).readAsString())
              as Map<String, dynamic>;
      expect(manifest['files'], <String>['api.dart']);
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
