import 'dart:async';
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

    test('top-level --help succeeds and lists every command', () async {
      for (final flag in <String>['--help', '-h', 'help']) {
        final logs = <String>[];
        final errors = <String>[];

        final exitCode = await runConvexCodegen(
          <String>[flag],
          log: logs.add,
          errorLog: errors.add,
        );

        expect(exitCode, 0, reason: flag);
        expect(logs.join('\n'), allOf(contains('generate'), contains('scrub')));
        expect(errors, isEmpty);
      }
    });

    test('unknown commands fail with usage on the error sink', () async {
      final logs = <String>[];
      final errors = <String>[];

      final exitCode = await runConvexCodegen(
        <String>['generat'],
        log: logs.add,
        errorLog: errors.add,
      );

      expect(exitCode, 64);
      expect(logs, isEmpty);
      expect(errors.join('\n'), allOf(contains('generat'), contains('scrub')));
    });

    test(
      'warnings go to the error sink, keeping --dry-run output clean',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'dartvex_codegen_',
        );
        addTearDown(() => tempDir.delete(recursive: true));
        final logs = <String>[];
        final errors = <String>[];

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
          errorLog: errors.add,
        );

        expect(exitCode, 0);
        expect(logs, everyElement(isNot(startsWith('Warning:'))));
        expect(errors, isNotEmpty);
        expect(errors, everyElement(startsWith('Warning:')));
      },
    );

    test('reports the captured Convex CLI error output', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartvex_codegen_');
      addTearDown(() => tempDir.delete(recursive: true));
      final errors = <String>[];

      final exitCode = await runConvexCodegen(
        <String>[
          'generate',
          '--project',
          tempDir.path,
          '--output',
          path.join(tempDir.path, 'out'),
        ],
        processRunner: _FakeProcessRunner(<Object>[
          ProcessRunnerException(
            'convex function-spec failed in ${tempDir.path}',
            stderr: 'No CONVEX_DEPLOYMENT set, run `npx convex dev`',
            exitCode: 1,
          ),
        ]),
        log: (_) {},
        errorLog: errors.add,
      );

      expect(exitCode, 70);
      expect(errors.single, contains('No CONVEX_DEPLOYMENT set'));
    });

    group('--watch', () {
      late Directory tempDir;
      late Directory outputDir;

      setUp(() async {
        tempDir = await Directory.systemTemp.createTemp('dartvex_codegen_');
        outputDir = Directory(path.join(tempDir.path, 'out'));
      });

      tearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      Future<void> eventually(
        bool Function() condition, {
        String reason = 'condition',
      }) async {
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('Timed out waiting for $reason');
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      }

      String apiSource() {
        final file = File(path.join(outputDir.path, 'api.dart'));
        return file.existsSync() ? file.readAsStringSync() : '';
      }

      test('regenerates after an atomic spec-file replace and ignores a '
          'truncated spec', () async {
        final specFile = File(path.join(tempDir.path, 'function_spec.json'));
        await specFile.writeAsString(_spec(<String>['index.ts:first']));
        final stop = Completer<void>();
        final logs = <String>[];
        final errors = <String>[];

        final run = GenerateCommand(
          processRunner: _FakeProcessRunner(const <Object>[]),
          fileEmitter: const FileEmitter(),
          log: logs.add,
          errorLog: errors.add,
          watchDebounce: const Duration(milliseconds: 50),
          stopWatching: stop.future,
        ).run(<String>[
          'generate',
          '--spec-file',
          specFile.path,
          '--output',
          outputDir.path,
          '--watch',
        ]);

        await eventually(
          () => apiSource().contains('first('),
          reason: 'initial generation',
        );

        // Truncation (shell redirect) must not be reported as an error.
        await specFile.writeAsString('');
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(errors, isEmpty);

        // Atomic replace: write a temp file and rename it over the spec.
        final replacement = File('${specFile.path}.tmp');
        await replacement.writeAsString(
          _spec(<String>['index.ts:first', 'index.ts:second']),
        );
        await replacement.rename(specFile.path);
        await eventually(
          () => apiSource().contains('second('),
          reason: 'regeneration after rename',
        );

        // A later in-place write still works (the watch survived).
        await specFile.writeAsString(_spec(<String>['index.ts:third']));
        await eventually(
          () => apiSource().contains('third('),
          reason: 'regeneration after rewrite',
        );

        stop.complete();
        expect(await run, 0);
        expect(errors, isEmpty);
        expect(logs, contains('Watching for changes...'));
      });

      test('keeps watching after an initial failure and re-polls the '
          'deployment after a change', () async {
        final project = Directory(path.join(tempDir.path, 'backend'));
        final nested = Directory(path.join(project.path, 'convex', 'lib'));
        await nested.create(recursive: true);
        final stop = Completer<void>();
        final errors = <String>[];
        // 1: initial run fails (transient). 2: the change event, before
        // `convex dev` finished pushing (still the old spec). 3+: pushed.
        final runner = _FakeProcessRunner(<Object>[
          ProcessRunnerException('network blip'),
          _spec(<String>['messages.ts:list']),
          _spec(<String>['messages.ts:list', 'messages.ts:send']),
        ]);

        final run = GenerateCommand(
          processRunner: runner,
          fileEmitter: const FileEmitter(),
          log: (_) {},
          errorLog: errors.add,
          watchDebounce: const Duration(milliseconds: 50),
          projectWatchPollDelays: const <Duration>[
            Duration(milliseconds: 200),
            Duration(milliseconds: 400),
          ],
          stopWatching: stop.future,
        ).run(<String>[
          'generate',
          '--project',
          project.path,
          '--output',
          outputDir.path,
          '--watch',
        ]);

        await eventually(
          () => errors.any((error) => error.contains('network blip')),
          reason: 'initial failure to be logged',
        );
        // A nested edit (Linux needs per-directory watches for this).
        await File(
          path.join(nested.path, 'util.ts'),
        ).writeAsString('export {};');
        await eventually(
          () =>
              File(
                path.join(outputDir.path, 'modules', 'messages.dart'),
              ).existsSync(),
          reason: 'regeneration after nested edit',
        );
        await eventually(
          () => File(
            path.join(outputDir.path, 'modules', 'messages.dart'),
          ).readAsStringSync().contains('send('),
          reason: 'follow-up poll to pick up the pushed spec',
        );

        stop.complete();
        expect(await run, 0);
      });

      test(
        'fails cleanly when the watched project directory disappears',
        () async {
          final project = Directory(path.join(tempDir.path, 'backend'));
          await project.create();
          final errors = <String>[];

          final run = GenerateCommand(
            processRunner: _FakeProcessRunner(<Object>[
              _spec(<String>['messages.ts:list']),
            ]),
            fileEmitter: const FileEmitter(),
            log: (_) {},
            errorLog: errors.add,
            watchDebounce: const Duration(milliseconds: 50),
            projectWatchPollDelays: const <Duration>[],
          ).run(<String>[
            'generate',
            '--project',
            project.path,
            '--output',
            outputDir.path,
            '--watch',
          ]);

          await eventually(
            () => apiSource().isNotEmpty,
            reason: 'initial generation',
          );
          await project.delete(recursive: true);

          expect(await run.timeout(const Duration(seconds: 10)), 70);
          expect(errors.last, contains('Watching stopped unexpectedly'));
        },
        testOn: 'linux',
      );
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

/// Returns the queued results in order (a String is a spec, anything else is
/// thrown); the last entry repeats once the queue is exhausted.
class _FakeProcessRunner implements ProcessRunner {
  _FakeProcessRunner(this._results);

  final List<Object> _results;
  var _calls = 0;

  @override
  Future<String> runFunctionSpec({
    required String projectDirectory,
    required bool verbose,
  }) async {
    if (_results.isEmpty) {
      throw StateError('No spec queued');
    }
    final index = _calls < _results.length ? _calls : _results.length - 1;
    _calls += 1;
    final result = _results[index];
    if (result is String) {
      return result;
    }
    throw result;
  }
}

String _spec(List<String> identifiers) {
  final functions = identifiers
      .map(
        (identifier) =>
            '{"functionType": "Query", '
            '"args": {"type": "object", "value": {}}, '
            '"returns": {"type": "string"}, '
            '"identifier": "$identifier", '
            '"visibility": {"kind": "public"}}',
      )
      .join(', ');
  return '{"url": "https://sample.convex.cloud", "functions": [$functions]}';
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
