import 'dart:async';
import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:dartvex_codegen/src/cli/watch.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

/// Whether dart:io honors `Directory.watch(recursive: true)` here.
final bool _nativeRecursiveWatch = Platform.isMacOS || Platform.isWindows;

void main() {
  // The per-directory tree Linux needs runs everywhere; the native recursive
  // watch macOS and Windows use by default only where dart:io supports it.
  for (final recursive in <bool>[false, true]) {
    group(
      recursive
          ? 'SourceWatcher (native recursive watch)'
          : 'SourceWatcher (per-directory tree)',
      () => _watcherTests(recursive: recursive),
      skip:
          recursive && !_nativeRecursiveWatch
              ? 'Directory.watch(recursive: true) is not supported here'
              : false,
    );
  }

  group('WatchPathFilter', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('dartvex_filter_');
      addTearDown(() => root.delete(recursive: true));
    });

    test(
      'matches the output directory whichever way a symlink spells it',
      () async {
        final real = Directory(path.join(root.path, 'real'));
        final project = Directory(path.join(real.path, 'backend'));
        await Directory(
          path.join(project.path, 'lib', 'convex_api'),
        ).create(recursive: true);
        final link = Link(path.join(root.path, 'link'));
        await link.create(real.path);
        final projectViaLink = path.join(link.path, 'backend');
        final realOutput = path.join(project.path, 'lib', 'convex_api');

        // Project watched through the symlink, output spelled resolved.
        final filter = WatchPathFilter(
          projectDirectory: projectViaLink,
          outputDirectory: realOutput,
        );
        expect(
          filter.ignores(path.join(projectViaLink, 'lib', 'convex_api')),
          isTrue,
        );
        expect(
          filter.ignores(
            path.join(projectViaLink, 'lib', 'convex_api', 'api.dart'),
          ),
          isTrue,
        );
        expect(filter.ignores(path.join(projectViaLink, 'lib')), isFalse);
        expect(
          filter.ignores(path.join(projectViaLink, 'convex', 'schema.ts')),
          isFalse,
        );

        // And the other way around.
        final reversed = WatchPathFilter(
          projectDirectory: project.path,
          outputDirectory: path.join(projectViaLink, 'lib', 'convex_api'),
        );
        expect(
          reversed.ignores(path.join(realOutput, 'modules', 'messages.dart')),
          isTrue,
        );
        expect(
          reversed.ignores(path.join(project.path, 'convex', 'schema.ts')),
          isFalse,
        );
      },
      testOn: '!windows',
    );

    test('canonicalizes an output directory that does not exist yet', () async {
      final real = await Directory(path.join(root.path, 'real')).create();
      final link = Link(path.join(root.path, 'link'));
      await link.create(real.path);

      expect(
        canonicalizeWatchPath(path.join(link.path, 'lib', 'convex_api')),
        path.join(real.resolveSymbolicLinksSync(), 'lib', 'convex_api'),
      );
    }, testOn: '!windows');

    test('only ignores directory names below the project directory', () {
      final project = path.join(root.path, 'node_modules', 'my-app');
      final filter = WatchPathFilter(
        projectDirectory: project,
        outputDirectory: path.join(project, 'lib', 'convex_api'),
      );

      expect(
        filter.ignores(path.join(project, 'convex', 'messages.ts')),
        isFalse,
      );
      expect(
        filter.ignores(path.join(project, 'node_modules', 'convex', 'x.js')),
        isTrue,
      );
      expect(filter.ignores(path.join(project, '.git', 'HEAD')), isTrue);
    });
  });
}

void _watcherTests({required bool recursive}) {
  late Directory project;
  late GenerateConfig config;
  late SourceWatcher watcher;
  late int triggerCount;

  Future<void> createProject(String projectPath) async {
    await Directory(
      path.join(projectPath, 'convex', '_generated'),
    ).create(recursive: true);
    await Directory(
      path.join(projectPath, 'node_modules', 'convex'),
    ).create(recursive: true);
    await Directory(
      path.join(projectPath, 'lib', 'convex_api'),
    ).create(recursive: true);
  }

  /// Starts the watcher, then waits until it has been quiet for a while:
  /// FSEvents (macOS) may report the setup's own directory creations, which
  /// happened shortly before the watch started.
  Future<void> startWatcher(GenerateConfig watchedConfig) async {
    config = watchedConfig;
    watcher = SourceWatcher.start(
      config,
      debounce: const Duration(milliseconds: 30),
      recursiveWatchSupported: recursive,
    );
    addTearDown(watcher.close);
    triggerCount = 0;
    watcher.triggers.listen((_) => triggerCount++);
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    var seen = -1;
    while (seen != triggerCount && DateTime.now().isBefore(deadline)) {
      seen = triggerCount;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    triggerCount = 0;
  }

  /// Whether a trigger arrives within [timeout].
  Future<bool> nextTrigger({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final before = triggerCount;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (triggerCount > before) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return triggerCount > before;
  }

  GenerateConfig configFor(String projectPath, String outputPath) =>
      GenerateConfig(
        projectDirectory: projectPath,
        outputDirectory: outputPath,
        clientImport: 'package:dartvex/dartvex.dart',
        dryRun: false,
        verbose: false,
        watch: true,
      ).normalize();

  group('in a project', () {
    setUp(() async {
      final root = await Directory.systemTemp.createTemp('dartvex_watch_');
      addTearDown(() => root.delete(recursive: true));
      project = Directory(path.join(root.path, 'backend'));
      await createProject(project.path);
      await startWatcher(
        configFor(project.path, path.join(project.path, 'lib', 'convex_api')),
      );
    });

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
        containsAll(<String>['.', 'convex', path.join('convex', '_generated')]),
      );
      expect(watched, isNot(contains('node_modules')));
      expect(watched, isNot(contains(path.join('node_modules', 'convex'))));
      expect(watched, isNot(contains(path.join('lib', 'convex_api'))));
    }, skip: recursive ? 'a recursive watch is a single root watch' : false);

    test('watches directories created after startup', () async {
      final created = Directory(path.join(project.path, 'convex', 'models'));
      await created.create();
      expect(await nextTrigger(), isTrue);

      await File(path.join(created.path, 'user.ts')).writeAsString('');
      expect(await nextTrigger(), isTrue);
    });

    test('ignores writes into the output directory', () async {
      await Directory(
        path.join(config.outputDirectory, 'modules'),
      ).create(recursive: true);
      await File(
        path.join(config.outputDirectory, 'api.dart'),
      ).writeAsString('// generated');
      await File(
        path.join(config.outputDirectory, 'modules', 'messages.dart'),
      ).writeAsString('// generated');

      expect(
        await nextTrigger(timeout: const Duration(milliseconds: 500)),
        isFalse,
      );
    });

    test('ignores writes into ignored directories', () async {
      await File(
        path.join(project.path, 'node_modules', 'convex', 'index.js'),
      ).writeAsString('');

      expect(
        await nextTrigger(timeout: const Duration(milliseconds: 500)),
        isFalse,
      );
    });
  });

  test('ignores the output directory when a symlink spells the project '
      'differently', () async {
    final root = await Directory.systemTemp.createTemp('dartvex_watch_');
    addTearDown(() => root.delete(recursive: true));
    final real = Directory(path.join(root.path, 'real'));
    await createProject(path.join(real.path, 'backend'));
    final link = Link(path.join(root.path, 'link'));
    await link.create(real.path);
    project = Directory(path.join(link.path, 'backend'));
    // `--project` through the symlink, `--output` resolved (as a relative
    // `--output` is, against the resolved current directory).
    final realOutput = path.join(
      real.resolveSymbolicLinksSync(),
      'backend',
      'lib',
      'convex_api',
    );
    await startWatcher(configFor(project.path, realOutput));

    await File(path.join(realOutput, 'api.dart')).writeAsString('// gen');
    expect(
      await nextTrigger(timeout: const Duration(milliseconds: 500)),
      isFalse,
    );

    await File(
      path.join(project.path, 'convex', 'schema.ts'),
    ).writeAsString('export {};');
    expect(await nextTrigger(), isTrue);
  }, testOn: '!windows');
}
