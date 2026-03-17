import 'package:path/path.dart' as path;

class GenerateConfig {
  const GenerateConfig({
    required this.outputDirectory,
    required this.clientImport,
    required this.dryRun,
    required this.verbose,
    required this.watch,
    this.projectDirectory,
    this.specFile,
  });

  final String? projectDirectory;
  final String? specFile;
  final String outputDirectory;
  final String clientImport;
  final bool dryRun;
  final bool verbose;
  final bool watch;

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
