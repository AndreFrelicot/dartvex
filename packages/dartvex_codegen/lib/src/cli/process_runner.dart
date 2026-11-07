import 'dart:io';

import '../spec/spec_json.dart';

/// Thrown when the external Convex CLI cannot be executed successfully.
class ProcessRunnerException implements Exception {
  /// Creates a process runner failure with optional captured output.
  ProcessRunnerException(
    this.message, {
    this.stdout,
    this.stderr,
    this.exitCode,
  });

  /// Maximum number of captured output lines included by [toString].
  static const int outputTailLines = 10;

  /// Human-readable failure details.
  final String message;

  /// Captured standard output, when available.
  final String? stdout;

  /// Captured standard error, when available.
  final String? stderr;

  /// The exit code of the failed process, when it ran.
  final int? exitCode;

  /// Returns [message] followed by the last [outputTailLines] lines of the
  /// captured stderr (or stdout when stderr is empty), so the real Convex CLI
  /// error (for example `No CONVEX_DEPLOYMENT set`) reaches the user.
  @override
  String toString() {
    final stderrText = stderr?.trim() ?? '';
    final output = stderrText.isNotEmpty ? stderrText : (stdout?.trim() ?? '');
    if (output.isEmpty) {
      return message;
    }
    final lines = output.split(RegExp(r'\r?\n'));
    final truncated = lines.length > outputTailLines;
    final tail =
        truncated ? lines.sublist(lines.length - outputTailLines) : lines;
    final buffer =
        StringBuffer(message)
          ..writeln()
          ..write(tail.map((line) => '  $line').join('\n'));
    if (truncated) {
      buffer
        ..writeln()
        ..write('  (output truncated; rerun with --verbose for the full log)');
    }
    return buffer.toString();
  }
}

/// Abstraction for obtaining a Convex function spec from an external process.
abstract class ProcessRunner {
  /// Creates a process runner.
  ProcessRunner();

  /// Runs the function-spec command in [projectDirectory].
  Future<String> runFunctionSpec({
    required String projectDirectory,
    required bool verbose,
  });
}

/// Default [ProcessRunner] that shells out to the Convex CLI.
class SystemProcessRunner implements ProcessRunner {
  /// Creates a system-backed process runner.
  const SystemProcessRunner();

  /// Candidate commands tried when invoking `convex function-spec`.
  static const List<List<String>> _candidates = <List<String>>[
    <String>['convex', 'function-spec'],
    <String>['npx', 'convex', 'function-spec'],
    <String>['pnpm', 'exec', 'convex', 'function-spec'],
    <String>['bunx', 'convex', 'function-spec'],
    <String>['yarn', 'convex', 'function-spec'],
  ];

  @override
  /// Executes `convex function-spec` using the first available CLI candidate.
  Future<String> runFunctionSpec({
    required String projectDirectory,
    required bool verbose,
  }) async {
    ProcessRunnerException? lastFailure;
    for (final candidate in _candidates) {
      final executable = candidate.first;
      final arguments = candidate.sublist(1);
      ProcessResult result;
      try {
        result = await Process.run(
          executable,
          arguments,
          workingDirectory: projectDirectory,
          runInShell: true,
        );
      } on ProcessException catch (error) {
        lastFailure = ProcessRunnerException(
          error.message,
          stderr: error.message,
        );
        continue;
      }

      final stdoutText = '${result.stdout}'.trim();
      final stderrText = '${result.stderr}'.trim();
      if (result.exitCode == 0) {
        return extractFunctionSpecJson(stdoutText);
      }
      if (verbose) {
        stdout.writeln(stdoutText);
        stderr.writeln(stderrText);
      }
      if (looksLikeMissingExecutable(result.exitCode, stderrText)) {
        lastFailure = ProcessRunnerException(
          '${candidate.join(' ')} is not available',
          stdout: stdoutText,
          stderr: stderrText,
          exitCode: result.exitCode,
        );
        continue;
      }
      throw ProcessRunnerException(
        'convex function-spec failed in $projectDirectory '
        '(`${candidate.join(' ')}` exited with code ${result.exitCode}):',
        stdout: stdoutText,
        stderr: stderrText,
        exitCode: result.exitCode,
      );
    }
    throw ProcessRunnerException(
      'Unable to run "convex function-spec". Install the Convex CLI or use '
      '--spec-file.',
      stderr: lastFailure?.stderr,
      exitCode: lastFailure?.exitCode,
    );
  }
}

/// Whether a failed candidate run means the CLI itself is missing, so the
/// next package runner should be tried.
///
/// Only shell "command not found" exit codes (127 on POSIX shells, 9009 for
/// `cmd.exe`) and the package runners' own "no such executable" messages
/// count. Real Convex CLI failures that merely contain "not found" (such as
/// `Deployment "x" not found`) are reported instead of being retried.
bool looksLikeMissingExecutable(int exitCode, String stderrText) {
  if (exitCode == 127 || exitCode == 9009) {
    return true;
  }
  final lowered = stderrText.toLowerCase();
  return lowered.contains('command not found') ||
      lowered.contains('is not recognized as an internal or external') ||
      lowered.contains('command "convex" not found') ||
      lowered.contains('could not determine executable to run');
}

/// Extracts the first balanced Convex function spec JSON object from stdout.
String extractFunctionSpecJson(String stdoutText) {
  if (stdoutText.isEmpty) {
    throw ProcessRunnerException('convex function-spec produced no output.');
  }
  if (!stdoutText.contains('{')) {
    throw ProcessRunnerException(
      'convex function-spec did not emit valid JSON.',
      stdout: stdoutText,
    );
  }
  final scan = scanFunctionSpecJson(stdoutText);
  final json = scan.json;
  if (json != null) {
    return json;
  }
  throw ProcessRunnerException(
    scan.foundJsonObject
        ? 'convex function-spec did not emit a Convex function spec JSON '
            'object.'
        : scan.lastError == null
        ? 'convex function-spec did not emit a complete JSON object.'
        : 'convex function-spec output contains invalid JSON: '
            '${scan.lastError}',
    stdout: stdoutText,
  );
}
