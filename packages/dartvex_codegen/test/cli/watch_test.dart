import 'dart:async';
import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:dartvex_codegen/src/cli/watch.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('SourceWatcher (per-directory tree)', () {
    late Directory project;
    late GenerateConfig config;
    late SourceWatcher watcher;
    late StreamIterator<void> triggers;

    setUp(() async {
      final root = await Directory.systemTemp.createTemp('dartvex_watch_');
      addTearDown(() => root.delete(recursive: true));
      project = Directory(path.join(root.path, 'backend'));
      await Directory(
        path.join(project.path, 'convex', '_generated'),
      ).create(recursive: true);
      await Directory(
        path.join(project.path, 'node_modules', 'convex'),
      ).create(recursive: true);
      config =
          GenerateConfig(
            projectDirectory: project.path,
            outputDirectory: path.join(project.path, 'lib', 'convex_api'),
            clientImport: 'package:dartvex/dartvex.dart',
            dryRun: false,
            verbose: false,
            watch: true,
          ).normalize();
      await Directory(config.outputDirectory).create(recursive: true);
      // Force the manual tree that Linux needs, on every platform.
      watcher = SourceWatcher.start(
        config,
        debounce: const Duration(milliseconds: 30),
        recursiveWatchSupported: false,
      );
      triggers = StreamIterator<void>(watcher.triggers);
      addTearDown(watcher.close);
    });

    Future<bool> nextTrigger({Duration timeout = const Duration(seconds: 5)}) {
      return triggers.moveNext().timeout(timeout, onTimeout: () => false);
    }

    test('sees edits in nested directories', () async {
      await File(
        path.join(project.path, 'convex', '_generated', 'api.d.ts'),
      ).writeAsString('export {};');

      expect(await nextTrigger(), isTrue);
    });

    test('does not watch ignored or output directories', () {
      final watched = watcher.watchedDirectories.map(
        (directory) => path.relative(directory, from: project.path),
      );
      expect(
        watched,
        containsAll(<String>['.', 'convex', 'convex/_generated']),
      );
      expect(watched, isNot(contains('node_modules')));
      expect(watched, isNot(contains('node_modules/convex')));
      expect(watched, isNot(contains('lib/convex_api')));
    });

    test('watches directories created after startup', () async {
      final created = Directory(path.join(project.path, 'convex', 'models'));
      await created.create();
      expect(await nextTrigger(), isTrue);

      await File(path.join(created.path, 'user.ts')).writeAsString('');
      expect(await nextTrigger(), isTrue);
    });

    test('ignores writes into the output directory', () async {
      await File(
        path.join(config.outputDirectory, 'api.dart'),
      ).writeAsString('// generated');

      expect(
        await nextTrigger(timeout: const Duration(milliseconds: 400)),
        isFalse,
      );
    });
  });
}
