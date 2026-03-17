import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:path/path.dart' as path;

void main() async {
  final fixture = await File('test/fixtures/function_spec.json').readAsString();
  final spec = const SpecParser().parseString(fixture);
  final output = DartGenerator().generate(spec);

  for (final entry in output.files.entries) {
    final filePath = path.join('test', 'goldens', 'sample', entry.key);
    final file = File(filePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(entry.value);
    print('Wrote $filePath');
  }
}
