import 'package:path/path.dart' as path;

/// Immutable configuration for the `dartvex_codegen generate` command.
class GenerateConfig {
  /// Creates a code generation configuration.
  const GenerateConfig({
    required this.outputDirectory,
    required this.clientImport,
    required this.dryRun,
    required this.verbose,
    required this.watch,
    this.projectDirectory,
    this.specFile,
  });

  /// The Convex project directory used when shelling out to `convex function-spec`.
  final String? projectDirectory;

  /// A pre-generated function spec file to read instead of invoking the CLI.
  final String? specFile;

  /// The output directory for generated bindings.
  final String outputDirectory;

  /// The import path used for the generated runtime client dependency.
  final String clientImport;

  /// Whether generation should print files instead of writing them.
  final bool dryRun;

  /// Whether verbose process output should be forwarded to the console.
  final bool verbose;

  /// Whether the generator should watch for source changes and rerun automatically.
  final bool watch;

  /// Returns a copy with filesystem paths normalized to absolute paths.
  GenerateConfig normalize() {
    return GenerateConfig(
      projectDirectory: projectDirectory == null
          ? null
          : path.normalize(path.absolute(projectDirectory!)),
      specFile:
          specFile == null ? null : path.normalize(path.absolute(specFile!)),
      outputDirectory: path.normalize(path.absolute(outputDirectory)),
      clientImport: clientImport,
      dryRun: dryRun,
      verbose: verbose,
      watch: watch,
    );
  }

  /// Validates that the configuration contains a single spec source and output path.
  void validate() {
    if ((projectDirectory == null) == (specFile == null)) {
      throw ArgumentError(
        'Exactly one of --project or --spec-file must be provided.',
      );
    }
    if (outputDirectory.trim().isEmpty) {
      throw ArgumentError('--output is required.');
    }
  }
}
