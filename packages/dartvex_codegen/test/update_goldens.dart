/// Regenerates golden files from the current generator output.
///
/// Run: dart test/update_goldens.dart
library;

import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:path/path.dart' as path;

void main() async {
  final fixture = await File(
    path.join('test', 'fixtures', 'function_spec.json'),
  ).readAsString();
  final spec = const SpecParser().parseString(fixture);
  final output = DartGenerator().generate(spec);

  for (final entry in output.files.entries) {
    final file = File(path.join('test', 'goldens', 'sample', entry.key));
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
    print('Updated ${entry.key}');
  }
}
