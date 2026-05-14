import 'dart:io';

import 'package:path_provider/path_provider.dart';

Future<String> resolveLocalStorePath() async {
  final directory = await getApplicationSupportDirectory();
  return '${directory.path}${Platform.pathSeparator}dartvex_demo.sqlite';
}
