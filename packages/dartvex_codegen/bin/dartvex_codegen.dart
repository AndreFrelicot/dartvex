import 'dart:io';

import 'package:dartvex_codegen/src/cli/generate_command.dart';

Future<void> main(List<String> args) async {
  final exitCode = await runConvexCodegen(args);
  if (exitCode != 0) {
    stderr.writeln('dartvex_codegen exited with code $exitCode');
  }
  exit(exitCode);
}
