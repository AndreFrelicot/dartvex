import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

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
    final outputRoot = path.normalize(path.absolute(directory.path));
    final manifestFile = File(path.join(outputRoot, manifestName));
    final previousFiles = await _readManifest(manifestFile);

    for (final entry in files.entries) {
      final file = _fileFor(outputRoot, entry.key);
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
      final staleFile = _fileFor(outputRoot, previous);
      if (await staleFile.exists()) {
        final existing = await staleFile.readAsString();
        if (existing.startsWith(generatedFileHeader)) {
          await staleFile.delete();
        }
      }
    }

    for (final entry in files.entries) {
      final file = _fileFor(outputRoot, entry.key);
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

  File _fileFor(String outputRoot, String relativePath) =>
      File(_safeJoin(outputRoot, relativePath));

  String _safeJoin(String outputRoot, String relativePath) {
    if (relativePath.isEmpty ||
        relativePath.contains(r'\') ||
        path.isAbsolute(relativePath)) {
      throw FileEmitterException(
        'Refusing to use unsafe generated file path "$relativePath"',
      );
    }

    final normalizedRelative = path.normalize(relativePath);
    if (normalizedRelative == '.' ||
        normalizedRelative == '..' ||
        path.split(normalizedRelative).contains('..')) {
      throw FileEmitterException(
        'Refusing to use unsafe generated file path "$relativePath"',
      );
    }

    final filePath = path.normalize(path.join(outputRoot, normalizedRelative));
    if (!path.isWithin(outputRoot, filePath)) {
      throw FileEmitterException(
        'Refusing to use unsafe generated file path "$relativePath"',
      );
    }
    return filePath;
  }
}
