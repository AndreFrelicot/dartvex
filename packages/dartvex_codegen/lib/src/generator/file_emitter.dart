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
  ///
  /// An unreadable manifest (for example one left with git merge-conflict
  /// markers) does not abort generation: [onWarning] is told, stale-file
  /// cleanup is skipped for this run, and a fresh manifest is written.
  ///
  /// Every path read, written or deleted must really be inside
  /// [outputDirectory]: a manifest, a generated file or one of their parent
  /// directories that is a symbolic link leading elsewhere makes this throw a
  /// [FileEmitterException] before anything is modified. ([outputDirectory]
  /// itself may be a link.)
  Future<void> emit({
    required String outputDirectory,
    required Map<String, String> files,
    required bool dryRun,
    void Function(String warning)? onWarning,
  }) async {
    if (dryRun) {
      return;
    }

    final directory = Directory(outputDirectory);
    await directory.create(recursive: true);
    final outputRoot = path.normalize(path.absolute(directory.path));
    final resolvedRoot = await directory.resolveSymbolicLinks();
    final manifestFile = File(path.join(outputRoot, manifestName));
    final temporaryManifest = File('${manifestFile.path}.tmp');
    await _assertConfined(resolvedRoot, manifestFile, manifestName);
    await _assertConfined(resolvedRoot, temporaryManifest, '$manifestName.tmp');
    final previousFiles = await _readManifest(manifestFile, onWarning);

    // Check every path before the first modification, so a refused run
    // leaves the existing files as they were.
    for (final relativePath in <String>{...files.keys, ...previousFiles}) {
      await _assertConfined(
        resolvedRoot,
        _fileFor(outputRoot, relativePath),
        relativePath,
      );
    }

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

    // Write-then-rename so an interrupted run (Ctrl+C in --watch) cannot
    // leave a truncated manifest behind.
    final manifestJson = const JsonEncoder.withIndent(
      '  ',
    ).convert(<String, Object?>{'files': files.keys.toList()..sort()});
    await temporaryManifest.writeAsString(manifestJson, flush: true);
    await temporaryManifest.rename(manifestFile.path);
  }

  Future<List<String>> _readManifest(
    File file,
    void Function(String warning)? onWarning,
  ) async {
    if (!await file.exists()) {
      return const <String>[];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } on FormatException catch (error) {
      onWarning?.call(_unreadableManifestWarning(file, error.message));
      return const <String>[];
    } on FileSystemException catch (error) {
      onWarning?.call(_unreadableManifestWarning(file, error.message));
      return const <String>[];
    }
    if (decoded is! Map<String, dynamic>) {
      return const <String>[];
    }
    final files = decoded['files'];
    if (files is! List) {
      return const <String>[];
    }
    return files.whereType<String>().toList(growable: false);
  }

  String _unreadableManifestWarning(File file, String reason) =>
      'Ignoring unreadable generator manifest ${file.path} ($reason). It '
      'will be rewritten; stale generated files from earlier runs are not '
      'deleted this time.';

  File _fileFor(String outputRoot, String relativePath) =>
      File(_safeJoin(outputRoot, relativePath));

  /// Throws unless [file] is really inside the output directory once
  /// symbolic links are followed.
  ///
  /// [_safeJoin] only checks the path text. A symbolic link in the output
  /// tree (the file itself, or one of its parent directories) can still send
  /// a read, write or delete somewhere else, for example in a checkout whose
  /// previously generated output came from an untrusted source.
  Future<void> _assertConfined(
    String resolvedRoot,
    File file,
    String relativePath,
  ) async {
    if (await FileSystemEntity.isLink(file.path)) {
      throw FileEmitterException(
        'Refusing to use generated file path "$relativePath": it is a '
        'symbolic link',
      );
    }
    // The deepest directory that exists: the ones below it are created by
    // this run, inside it.
    var parent = file.parent;
    while (!await parent.exists()) {
      parent = parent.parent;
    }
    final resolvedParent = await parent.resolveSymbolicLinks();
    if (resolvedParent != resolvedRoot &&
        !path.isWithin(resolvedRoot, resolvedParent)) {
      throw FileEmitterException(
        'Refusing to use generated file path "$relativePath": a symbolic '
        'link leads outside the output directory',
      );
    }
  }

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
