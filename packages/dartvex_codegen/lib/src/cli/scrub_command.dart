import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../spec/spec_scrubber.dart';

/// Runs the `scrub` subcommand: reads a raw `convex function-spec` dump from a
/// file or stdin and writes a committable copy with the real deployment URL
/// replaced by a placeholder.
class ScrubCommand {
  /// Creates a scrub command with injectable IO for testing.
  ScrubCommand({
    Future<String> Function()? readStdin,
    void Function(String output)? writeOutput,
    void Function(String message)? errorLog,
  })  : _readStdin = readStdin ?? _defaultReadStdin,
        _writeOutput = writeOutput ?? stdout.write,
        _errorLog = errorLog ?? stderr.writeln;

  final Future<String> Function() _readStdin;
  final void Function(String output) _writeOutput;
  final void Function(String message) _errorLog;

  static Future<String> _defaultReadStdin() =>
      stdin.transform(utf8.decoder).join();

  /// Builds the CLI parser for the `scrub` subcommand.
  static ArgParser buildParser() {
    return ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption(
        'spec-file',
        abbr: 'f',
        help: 'Read the spec from this file instead of stdin.',
      )
      ..addOption(
        'placeholder-url',
        defaultsTo: placeholderDeploymentUrl,
        help: 'URL written in place of the real deployment URL.',
      );
  }

  /// Executes the scrub command for [args] (excluding the leading `scrub`).
  Future<int> run(List<String> args) async {
    final ArgResults parsed;
    try {
      parsed = buildParser().parse(args);
    } on FormatException catch (error) {
      _errorLog(error.message);
      return 64;
    }
    if (parsed['help'] as bool) {
      _writeOutput('Usage: dart run dartvex_codegen scrub [options]\n');
      _writeOutput('${buildParser().usage}\n');
      return 0;
    }

    final specFile = parsed['spec-file'] as String?;
    final String raw;
    if (specFile != null) {
      final file = File(specFile);
      if (!await file.exists()) {
        _errorLog('Spec file does not exist: $specFile');
        return 64;
      }
      raw = await file.readAsString();
    } else {
      raw = await _readStdin();
    }

    final String scrubbed;
    try {
      scrubbed = scrubFunctionSpec(
        raw,
        placeholderUrl: parsed['placeholder-url'] as String,
      );
    } on FormatException catch (error) {
      _errorLog(error.toString());
      return 65;
    }
    _writeOutput(scrubbed);
    return 0;
  }
}
