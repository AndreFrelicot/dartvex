import 'dart:convert';
import 'dart:io';

import 'dart_generator.dart';

/// Thrown when generated files cannot be written safely.
class FileEmitterException implements Exception {
  /// Creates a file emission error.
  FileEmitterException(this.message);

  /// Human-readable failure details.
  final String message;

  @override
  String toString() => message;
}

/// Writes generated bindings to disk and cleans up stale generated files.
class FileEmitter {
  /// The manifest file used to track previously generated outputs.
  static const String manifestName = '.dartvex_codegen_manifest.json';

  /// Creates a file emitter.
  const FileEmitter();

  /// Writes [files] into [outputDirectory].
  ///
  /// When [dryRun] is true, this method returns without touching the filesystem.
  Future<void> emit({
    required String outputDirectory,
    required Map<String, String> files,
    required bool dryRun,
  }) async {
    if (dryRun) {
      return;
    }

    final directory = Directory(outputDirectory);
    await directory.create(recursive: true);
    final manifestFile = File('${directory.path}/$manifestName');
    final previousFiles = await _readManifest(manifestFile);

    for (final entry in files.entries) {
      final file = File('${directory.path}/${entry.key}');
      if (await file.exists()) {
        final existing = await file.readAsString();
        if (!existing.startsWith(generatedFileHeader) &&
            !previousFiles.contains(entry.key)) {
          throw FileEmitterException(
            'Refusing to overwrite non-generated file "${entry.key}"',
          );
        }
      }
    }

    for (final previous in previousFiles) {
      if (files.containsKey(previous)) {
        continue;
      }
      final staleFile = File('${directory.path}/$previous');
      if (await staleFile.exists()) {
        final existing = await staleFile.readAsString();
        if (existing.startsWith(generatedFileHeader)) {
          await staleFile.delete();
        }
      }
    }

    for (final entry in files.entries) {
      final file = File('${directory.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }

    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        <String, Object?>{
          'files': files.keys.toList()..sort(),
        },
      ),
    );
  }

  Future<List<String>> _readManifest(File file) async {
    if (!await file.exists()) {
      return const <String>[];
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      return const <String>[];
    }
    final files = decoded['files'];
    if (files is! List) {
      return const <String>[];
    }
    return files.whereType<String>().toList(growable: false);
  }
}
