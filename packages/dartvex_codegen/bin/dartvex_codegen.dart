import 'dart:io';

import 'package:dartvex_codegen/src/cli/generate_command.dart';

Future<void> main(List<String> args) async {
  int exitCode;
  try {
    exitCode = await runConvexCodegen(args);
  } on Exception catch (error) {
    stderr.writeln(error);
    exitCode = 70;
  }
  if (exitCode != 0) {
    stderr.writeln('dartvex_codegen exited with code $exitCode');
  }
  exit(exitCode);
}
