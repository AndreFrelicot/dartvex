import 'dart:convert';
import 'dart:io';

/// Thrown when the external Convex CLI cannot be executed successfully.
class ProcessRunnerException implements Exception {
  /// Creates a process runner failure with optional captured output.
  ProcessRunnerException(this.message, {this.stdout, this.stderr});

  /// Human-readable failure details.
  final String message;

  /// Captured standard output, when available.
  final String? stdout;

  /// Captured standard error, when available.
  final String? stderr;

  @override
  String toString() => message;
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
        lastFailure = ProcessRunnerException(error.message);
        continue;
      }

      final stdoutText = '${result.stdout}'.trim();
      final stderrText = '${result.stderr}'.trim();
      if (result.exitCode == 0) {
        return _extractJson(stdoutText);
      }
      if (verbose) {
        stdout.writeln(stdoutText);
        stderr.writeln(stderrText);
      }
      if (_looksLikeMissingExecutable(stderrText)) {
        lastFailure = ProcessRunnerException(stderrText);
        continue;
      }
      throw ProcessRunnerException(
        'convex function-spec failed in $projectDirectory',
        stdout: stdoutText,
        stderr: stderrText,
      );
    }
    throw ProcessRunnerException(
      'Unable to run "convex function-spec". Install the Convex CLI or use '
      '--spec-file.',
      stderr: lastFailure?.stderr,
    );
  }

  String _extractJson(String stdoutText) {
    if (stdoutText.isEmpty) {
      throw ProcessRunnerException('convex function-spec produced no output.');
    }
    final start = stdoutText.indexOf('{');
    final end = stdoutText.lastIndexOf('}');
    if (start == -1 || end == -1 || end < start) {
      throw ProcessRunnerException(
        'convex function-spec did not emit valid JSON.',
        stdout: stdoutText,
      );
    }
    final candidate = stdoutText.substring(start, end + 1);
    try {
      jsonDecode(candidate);
    } catch (e) {
      throw ProcessRunnerException(
        'convex function-spec output contains invalid JSON: $e',
        stdout: stdoutText,
      );
    }
    return candidate;
  }

  bool _looksLikeMissingExecutable(String stderrText) {
    final lowered = stderrText.toLowerCase();
    return lowered.contains('not found') ||
        lowered.contains('command not found') ||
        lowered.contains('is not recognized');
  }
}
