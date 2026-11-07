import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;

import '../generator/dart_generator.dart';
import '../generator/file_emitter.dart';
import '../spec/spec_parser.dart';
import 'config.dart';
import 'process_runner.dart';
import 'scrub_command.dart';
import 'watch.dart';

export 'watch.dart' show shouldIgnoreWatchEvent;

/// Top-level usage text listing every subcommand.
const String convexCodegenUsage = '''
Usage: dart run dartvex_codegen <command> [options]

Commands:
  generate   Generate typed Dart bindings from a Convex function spec.
  scrub      Replace the deployment URL in a function-spec dump so it can be
             committed.

Run "dart run dartvex_codegen <command> --help" for command options.''';

/// Runs the Dartvex code generator command-line entrypoint.
///
/// Regular output (generated-file summaries, `--dry-run` file contents, and
/// `--help` text) goes to [log] (stdout by default); errors and generation
/// warnings go to [errorLog] (stderr by default).
Future<int> runConvexCodegen(
  List<String> args, {
  ProcessRunner? processRunner,
  FileEmitter? fileEmitter,
  void Function(String message)? log,
  void Function(String message)? errorLog,
  Future<String> Function()? readStdin,
  void Function(String output)? writeOutput,
}) async {
  final void Function(String message) outputLog = log ?? stdout.writeln;
  final void Function(String message) outputErrorLog =
      errorLog ?? stderr.writeln;
  if (args.isEmpty) {
    outputErrorLog(convexCodegenUsage);
    return 64;
  }
  final command = args.first;
  if (command == '--help' || command == '-h' || command == 'help') {
    outputLog(convexCodegenUsage);
    return 0;
  }
  if (command == 'scrub') {
    return ScrubCommand(
      readStdin: readStdin,
      writeOutput: writeOutput,
      errorLog: errorLog,
    ).run(args.sublist(1));
  }
  return GenerateCommand(
    processRunner: processRunner ?? const SystemProcessRunner(),
    fileEmitter: fileEmitter ?? const FileEmitter(),
    log: outputLog,
    errorLog: outputErrorLog,
  ).run(args);
}

/// Coordinates argument parsing, spec loading, and file generation.
class GenerateCommand {
  /// Creates a [GenerateCommand] with injectable process, file, and log handlers.
  ///
  /// [watchDebounce] and [projectWatchPollDelays] tune `--watch`: after a
  /// burst of filesystem events settles for [watchDebounce], bindings are
  /// regenerated, and in `--project` mode the deployed function spec is
  /// re-read after each of [projectWatchPollDelays] so a `convex dev` push
  /// that completes later is still picked up. Completing [stopWatching] ends
  /// watch mode (`run` then returns 0).
  GenerateCommand({
    required ProcessRunner processRunner,
    required FileEmitter fileEmitter,
    required void Function(String message) log,
    void Function(String message)? errorLog,
    Duration watchDebounce = const Duration(milliseconds: 250),
    List<Duration> projectWatchPollDelays = const <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
    ],
    Future<void>? stopWatching,
  }) : _processRunner = processRunner,
       _fileEmitter = fileEmitter,
       _log = log,
       _errorLog = errorLog ?? log,
       _watchDebounce = watchDebounce,
       _projectWatchPollDelays = projectWatchPollDelays,
       _stopWatching = stopWatching;

  final ProcessRunner _processRunner;
  final FileEmitter _fileEmitter;
  final void Function(String message) _log;
  final void Function(String message) _errorLog;
  final Duration _watchDebounce;
  final List<Duration> _projectWatchPollDelays;
  final Future<void>? _stopWatching;

  /// Builds the CLI parser for the `generate` subcommand.
  static ArgParser buildParser() {
    return ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption(
        'project',
        help:
            'Convex project directory; runs `convex function-spec` there, '
            'which reads the functions deployed to its dev deployment.',
      )
      ..addOption('spec-file', help: 'Read an exported function spec file.')
      ..addOption('output', help: 'Directory for the generated bindings.')
      ..addOption('client-import', defaultsTo: 'package:dartvex/dartvex.dart')
      ..addFlag(
        'watch',
        negatable: false,
        help:
            'Regenerate when the spec file or the Convex project changes. '
            'Run `npx convex dev` alongside so changes are deployed.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Print generated files instead of writing them.',
      )
      ..addFlag(
        'verbose',
        negatable: false,
        help: 'Show the Convex CLI output.',
      );
  }

  /// Executes the generator command for the provided CLI [args].
  Future<int> run(List<String> args) async {
    try {
      return await _run(args);
    } on ArgumentError catch (error) {
      _errorLog(error.message?.toString() ?? error.toString());
      return 64;
    } on FormatException catch (error) {
      _errorLog(error.toString());
      return 65;
    } on Exception catch (error) {
      _errorLog(error.toString());
      return 70;
    }
  }

  Future<int> _run(List<String> args) async {
    if (args.isEmpty) {
      _errorLog(convexCodegenUsage);
      return 64;
    }
    final command = args.first;
    if (command == '--help' || command == '-h' || command == 'help') {
      _log(convexCodegenUsage);
      return 0;
    }
    if (command != 'generate') {
      _errorLog('Unknown command "$command".');
      _errorLog(convexCodegenUsage);
      return 64;
    }

    final parser = buildParser();
    final ArgResults parsed;
    try {
      parsed = parser.parse(args.sublist(1));
    } on FormatException catch (error) {
      _errorLog(error.message);
      _printGenerateUsage(_errorLog);
      return 64;
    }
    if (parsed['help'] as bool) {
      _printGenerateUsage(_log);
      return 0;
    }

    final config = GenerateConfig(
      projectDirectory: parsed['project'] as String?,
      specFile: parsed['spec-file'] as String?,
      outputDirectory: parsed['output'] as String? ?? '',
      clientImport: parsed['client-import'] as String,
      dryRun: parsed['dry-run'] as bool,
      verbose: parsed['verbose'] as bool,
      watch: parsed['watch'] as bool,
    );
    config.validate();
    final normalizedConfig = config.normalize();

    if (!normalizedConfig.watch) {
      await _generateFromSource(
        normalizedConfig,
        await _loadSpecSource(normalizedConfig),
      );
      return 0;
    }
    return _watch(normalizedConfig);
  }

  Future<int> _watch(GenerateConfig config) async {
    await _checkSpecSourceExists(config);
    // Arm the filesystem watches before the initial generation so changes
    // made while it runs are buffered instead of lost.
    final watcher = SourceWatcher.start(
      config,
      debounce: _watchDebounce,
      pollDelays: _projectWatchPollDelays,
    );
    unawaited(_stopWatching?.then((_) => watcher.close()));
    String? lastGeneratedSource;

    Future<void> regenerate() async {
      try {
        final source = await _loadSpecSource(config);
        if (config.specFile != null && source.trim().isEmpty) {
          // A shell redirect (`... > function_spec.json`) truncates the file
          // before the writer produces output; wait for the real write.
          if (config.verbose) {
            _log('Spec file is empty; waiting for it to be written.');
          }
          return;
        }
        if (source == lastGeneratedSource) {
          if (config.verbose) {
            _log('Function spec unchanged; skipping regeneration.');
          }
          return;
        }
        await _generateFromSource(config, source);
        lastGeneratedSource = source;
      } on Exception catch (error) {
        // Includes FormatException from a partially written spec file.
        _errorLog('$error\nWaiting for the next change.');
      } on ArgumentError catch (error) {
        // The spec file or project directory vanished mid-watch.
        _errorLog('${error.message}\nWaiting for the next change.');
      }
    }

    try {
      await regenerate();
      _log('Watching for changes...');
      await for (final _ in watcher.triggers) {
        await regenerate();
      }
    } finally {
      await watcher.close();
    }
    return 0;
  }

  Future<void> _generateFromSource(
    GenerateConfig config,
    String specSource,
  ) async {
    final spec = const SpecParser().parseString(specSource);
    final output = DartGenerator(
      clientImport: config.clientImport,
    ).generate(spec);

    if (config.dryRun) {
      final sortedPaths = output.files.keys.toList()..sort();
      for (final filePath in sortedPaths) {
        _log('=== $filePath ===');
        _log(output.files[filePath]!);
      }
    } else {
      await _fileEmitter.emit(
        outputDirectory: config.outputDirectory,
        files: output.files,
        dryRun: false,
        onWarning: (warning) => _errorLog('Warning: $warning'),
      );
      _log(
        'Generated ${output.files.length} files in '
        '${path.normalize(config.outputDirectory)}',
      );
    }

    for (final warning in output.warnings) {
      _errorLog('Warning: $warning');
    }
  }

  Future<void> _checkSpecSourceExists(GenerateConfig config) async {
    if (config.specFile != null) {
      if (!await File(config.specFile!).exists()) {
        throw ArgumentError('Spec file does not exist: ${config.specFile}');
      }
      return;
    }
    final projectDirectory = config.projectDirectory!;
    if (!await Directory(projectDirectory).exists()) {
      throw ArgumentError(
        'Project directory does not exist: $projectDirectory',
      );
    }
  }

  Future<String> _loadSpecSource(GenerateConfig config) async {
    await _checkSpecSourceExists(config);
    if (config.specFile != null) {
      return File(config.specFile!).readAsString();
    }
    return _processRunner.runFunctionSpec(
      projectDirectory: config.projectDirectory!,
      verbose: config.verbose,
    );
  }

  void _printGenerateUsage(void Function(String message) sink) {
    sink('Usage: dart run dartvex_codegen generate [options]');
    sink(buildParser().usage);
  }
}
