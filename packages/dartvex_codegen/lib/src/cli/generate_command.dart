import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as path;

import '../generator/dart_generator.dart';
import '../generator/file_emitter.dart';
import '../spec/spec_parser.dart';
import 'config.dart';
import 'process_runner.dart';

/// Runs the Dartvex code generator command-line entrypoint.
Future<int> runConvexCodegen(
  List<String> args, {
  ProcessRunner? processRunner,
  FileEmitter? fileEmitter,
  void Function(String message)? log,
}) {
  return GenerateCommand(
    processRunner: processRunner ?? const SystemProcessRunner(),
    fileEmitter: fileEmitter ?? const FileEmitter(),
    log: log ?? stdout.writeln,
  ).run(args);
}

/// Coordinates argument parsing, spec loading, and file generation.
class GenerateCommand {
  /// Creates a [GenerateCommand] with injectable process, file, and log handlers.
  GenerateCommand({
    required ProcessRunner processRunner,
    required FileEmitter fileEmitter,
    required void Function(String message) log,
  })  : _processRunner = processRunner,
        _fileEmitter = fileEmitter,
        _log = log;

  final ProcessRunner _processRunner;
  final FileEmitter _fileEmitter;
  final void Function(String message) _log;

  /// Builds the CLI parser for the `generate` subcommand.
  static ArgParser buildParser() {
    return ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption('project')
      ..addOption('spec-file')
      ..addOption('output')
      ..addOption(
        'client-import',
        defaultsTo: 'package:dartvex/dartvex.dart',
      )
      ..addFlag('watch', negatable: false)
      ..addFlag('dry-run', negatable: false)
      ..addFlag('verbose', negatable: false);
  }

  /// Executes the generator command for the provided CLI [args].
  Future<int> run(List<String> args) async {
    if (args.isEmpty) {
      _printUsage();
      return 64;
    }
    final command = args.first;
    if (command != 'generate') {
      _printUsage();
      return 64;
    }

    final parser = buildParser();
    final parsed = parser.parse(args.sublist(1));
    if (parsed['help'] as bool) {
      _log('Usage: dart run dartvex_codegen generate [options]');
      _log(parser.usage);
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
    ).normalize();
    config.validate();

    if (!config.watch) {
      await _generateOnce(config);
      return 0;
    }

    await _generateOnce(config);
    _log('Watching for changes...');
    await for (final _ in _watchEvents(config)) {
      try {
        await _generateOnce(config);
      } catch (error) {
        _log(error.toString());
      }
    }
    return 0;
  }

  Future<void> _generateOnce(GenerateConfig config) async {
    final specSource = await _loadSpecSource(config);
    final spec = const SpecParser().parseString(specSource);
    final output =
        DartGenerator(clientImport: config.clientImport).generate(spec);

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
      );
      _log(
        'Generated ${output.files.length} files in '
        '${path.normalize(config.outputDirectory)}',
      );
    }

    for (final warning in output.warnings) {
      _log('Warning: $warning');
    }
  }

  Future<String> _loadSpecSource(GenerateConfig config) async {
    if (config.specFile != null) {
      final file = File(config.specFile!);
      if (!await file.exists()) {
        throw ArgumentError('Spec file does not exist: ${config.specFile}');
      }
      return file.readAsString();
    }
    final projectDirectory = config.projectDirectory!;
    final project = Directory(projectDirectory);
    if (!await project.exists()) {
      throw ArgumentError(
          'Project directory does not exist: $projectDirectory');
    }
    return _processRunner.runFunctionSpec(
      projectDirectory: projectDirectory,
      verbose: config.verbose,
    );
  }

  Stream<void> _watchEvents(GenerateConfig config) async* {
    final stream = config.specFile != null
        ? File(config.specFile!).watch(events: FileSystemEvent.modify)
        : Directory(config.projectDirectory!).watch(recursive: true);
    Timer? debounce;
    final controller = StreamController<void>();

    final subscription = stream.listen((event) {
      final rawPath = event.path;
      if (_shouldIgnore(rawPath, config)) {
        return;
      }
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 250), () {
        controller.add(null);
      });
    });

    controller.onCancel = () {
      debounce?.cancel();
      subscription.cancel();
    };

    yield* controller.stream;
  }

  bool _shouldIgnore(String eventPath, GenerateConfig config) {
    final normalized = path.normalize(eventPath);
    if (normalized.contains('.dart_tool')) {
      return true;
    }
    if (normalized.contains('node_modules')) {
      return true;
    }
    if (normalized.startsWith(config.outputDirectory)) {
      return true;
    }
    return false;
  }

  void _printUsage() {
    _log('Usage: dart run dartvex_codegen generate [options]');
    _log(buildParser().usage);
  }
}
